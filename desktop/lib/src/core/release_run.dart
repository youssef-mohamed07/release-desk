import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'asc.dart';
import 'errors.dart';
import 'flutter_project.dart';
import 'github.dart';
import 'json.dart';
import 'play.dart';
import 'shell.dart';
import 'workspace.dart';

enum StepId {
  prepare('Prepare'),
  cloudBuild('Build on GitHub'),
  processing('Apple processing'),
  notes('What to Test'),
  groups('TestFlight groups'),
  review('Beta review'),
  live('Live for testers'),
  bundle('Build app bundle'),
  checkSigning('Check signing'),
  playRelease('Upload & release');

  const StepId(this.title);
  final String title;

  /// iOS always builds on GitHub here: Windows and Linux cannot build iOS apps.
  static List<StepId> stepsFor(ReleasePlatform platform, {bool cloud = false}) => switch (platform) {
    ReleasePlatform.ios => const [prepare, cloudBuild, processing, notes, groups, review, live],
    ReleasePlatform.android when cloud => const [prepare, cloudBuild, playRelease],
    ReleasePlatform.android => const [prepare, bundle, checkSigning, playRelease],
  };
}

enum ReleasePlatform { ios, android }

enum StepStatus { pending, running, done, warning, skipped, failed }

class StepState {
  const StepState(this.status, [this.message]);
  static const pending = StepState(StepStatus.pending);
  static const running = StepState(StepStatus.running);
  static const done = StepState(StepStatus.done);
  const StepState.warning(String m) : this(StepStatus.warning, m);
  const StepState.skipped(String m) : this(StepStatus.skipped, m);
  const StepState.failed(String m) : this(StepStatus.failed, m);

  final StepStatus status;
  final String? message;

  bool get isFinished => status != StepStatus.pending && status != StepStatus.running;
}

class RunStep {
  RunStep(this.id);
  final StepId id;
  StepState state = StepState.pending;
  DateTime? started;
  DateTime? finished;
  String? detail;
}

enum LogKind { output, info, success, warning, error }

class LogLine {
  const LogLine(this.id, this.step, this.time, this.kind, this.text);
  final int id;
  final StepId step;
  final DateTime time;
  final LogKind kind;
  final String text;
}

/// Where an Android release goes on Play.
class PlayTarget {
  const PlayTarget({required this.track, required this.status, this.userFraction});
  final String track;

  /// completed, inProgress (staged rollout) or draft.
  final String status;
  final double? userFraction;
}

/// A build made on a GitHub runner.
class CloudBuild {
  const CloudBuild(this.repo, this.target);
  final GitHubRepo repo;
  final CloudTarget target;
}

/// Everything one release run needs, decided before it starts.
class ReleasePlan {
  ReleasePlan({
    required this.platform,
    required this.app,
    required this.projectRoot,
    required this.version,
    required this.build,
    required this.recipe,
    this.teamId,
    this.groups = const [],
    this.whatsNew = const {},
    this.submitForReview = false,
    this.rehearsal = false,
    this.cloud,
    this.play,
    this.startAt,
  });

  final ReleasePlatform platform;
  final StoreApp app;
  final String projectRoot;
  final String version;
  final int build;
  final Recipe recipe;
  final String? teamId;
  final List<AscBetaGroup> groups;
  final Map<String, String> whatsNew;
  final bool submitForReview;

  /// iOS: the GitHub run builds and signs but does not upload. Android: the
  /// bundle is built and checked, nothing goes to Play.
  final bool rehearsal;
  final CloudBuild? cloud;
  final PlayTarget? play;

  /// Resume: skip the steps before this one.
  final StepId? startAt;

  ReleasePlan copyWith({StepId? startAt, bool clearStart = false}) => ReleasePlan(
    platform: platform,
    app: app,
    projectRoot: projectRoot,
    version: version,
    build: build,
    recipe: recipe,
    teamId: teamId,
    groups: groups,
    whatsNew: whatsNew,
    submitForReview: submitForReview,
    rehearsal: rehearsal,
    cloud: cloud,
    play: play,
    startAt: clearStart ? null : (startAt ?? this.startAt),
  );
}

enum RunPhase { ready, running, succeeded, failed, cancelled }

typedef _StepBody = Future<StepState> Function();

/// One release: the steps run in order and stop at the first failure. The
/// UI listens to it.
class ReleaseRun extends ChangeNotifier {
  ReleaseRun({required this.plan, required Directory logsDir, this.apple, this.playClient, this.github})
    : id = newId(),
      steps = StepId.stepsFor(plan.platform, cloud: plan.cloud != null).map(RunStep.new).toList() {
    final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    final safe = plan.app.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
    logFile = File(p.join(logsDir.path, '$safe ${plan.version} (${plan.build}) $stamp.log'));
    try {
      logFile.parent.createSync(recursive: true);
      _sink = logFile.openWrite();
    } catch (_) {}
  }

  final String id;
  final ReleasePlan plan;
  final List<RunStep> steps;
  final lines = <LogLine>[];
  late final File logFile;
  RunPhase phase = RunPhase.ready;
  DateTime? started;
  DateTime? finished;
  String? failure;
  String? buildId;

  /// The .aab this run built or downloaded.
  String? artifact;
  String? playVersionCode;

  /// The GitHub Actions run of a cloud build.
  String? cloudRunUrl;
  StepId? current;

  final AscClient? apple;
  final PlayClient? playClient;
  final GitHubClient? github;
  void Function(ReleaseRun)? onFinish;

  final cancelToken = CancelToken();
  IOSink? _sink;
  int _nextLine = 0;
  Timer? _notify;

  Duration get elapsed => started == null ? Duration.zero : (finished ?? DateTime.now()).difference(started!);

  double get progress => steps.where((s) => s.state.isFinished).length / steps.length;

  RunStep step(StepId id) => steps.firstWhere((s) => s.id == id);

  bool has(StepId id) => steps.any((s) => s.id == id);

  RunStep? get failedStep {
    for (final s in steps) {
      if (s.state.status == StepStatus.failed) return s;
    }
    return null;
  }

  void start() {
    if (phase != RunPhase.ready) return;
    phase = RunPhase.running;
    started = DateTime.now();
    notifyListeners();
    unawaited(_execute());
  }

  void cancel() {
    if (phase != RunPhase.running) return;
    cancelToken.cancel();
  }

  // MARK: Log

  static String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  void log(String text, [LogKind kind = LogKind.info, StepId? stepId]) {
    final s = stepId ?? current ?? StepId.prepare;
    final now = DateTime.now();
    lines.add(LogLine(_nextLine++, s, now, kind, text));
    if (lines.length > 25000) lines.removeRange(0, lines.length - 20000);
    try {
      _sink?.writeln('${_clock(now)} [${s.name}] $text');
    } catch (_) {}
    _scheduleNotify();
  }

  void _scheduleNotify() {
    _notify ??= Timer(const Duration(milliseconds: 80), () {
      _notify = null;
      notifyListeners();
    });
  }

  void Function(String) _output(StepId s) => (line) {
    final lower = line.toLowerCase();
    final kind = lower.contains('error:') || lower.startsWith('error') ? LogKind.error : (lower.contains('warning:') ? LogKind.warning : LogKind.output);
    log(line, kind, s);
  };

  void _set(StepId id, StepState state, {String? detail}) {
    final s = step(id);
    if (state.status == StepStatus.running) {
      s.started = DateTime.now();
      current = id;
    }
    if (state.isFinished) s.finished = DateTime.now();
    s.state = state;
    if (detail != null) s.detail = detail;
    notifyListeners();
  }

  void _detail(StepId id, String text) {
    if (!has(id)) return;
    step(id).detail = text;
    _scheduleNotify();
  }

  // MARK: Steps

  Future<void> _execute() async {
    log('Release ${plan.app.name} ${plan.version} (${plan.build}) from ${plan.projectRoot}');
    if (plan.rehearsal) {
      log(
        plan.platform == ReleasePlatform.ios ? 'Rehearsal: the GitHub run builds and signs, nothing is uploaded.' : 'Rehearsal: nothing is uploaded.',
        LogKind.warning,
      );
    }
    final List<(StepId, _StepBody)> order = plan.cloud?.target == CloudTarget.android
        ? [(StepId.prepare, _prepareCloud), (StepId.cloudBuild, _cloudBuild), (StepId.playRelease, _releaseToPlay)]
        : plan.platform == ReleasePlatform.ios
        ? [
            (StepId.prepare, _prepareCloud),
            (StepId.cloudBuild, _cloudBuild),
            (StepId.processing, _waitForProcessing),
            (StepId.notes, _writeNotes),
            (StepId.groups, _addToGroups),
            (StepId.review, _submitReview),
            (StepId.live, _waitUntilLive),
          ]
        : [(StepId.prepare, _prepareAndroid), (StepId.bundle, _buildBundle), (StepId.checkSigning, _checkSigning), (StepId.playRelease, _releaseToPlay)];
    const remote = {StepId.processing, StepId.notes, StepId.groups, StepId.review, StepId.live, StepId.playRelease};
    var resuming = plan.startAt != null;
    for (final (id, body) in order) {
      if (cancelToken.isCancelled) break;
      if (resuming && id != plan.startAt) {
        _set(id, const StepState.skipped('Done in the earlier run'));
        continue;
      }
      resuming = false;
      if (plan.rehearsal && remote.contains(id)) {
        _set(id, const StepState.skipped('Rehearsal'));
        continue;
      }
      _set(id, StepState.running);
      log('▸ ${id.title}');
      try {
        final result = await body();
        _set(id, result);
        if (result.status == StepStatus.warning) log(result.message!, LogKind.warning);
        if (result.status == StepStatus.skipped) log('Skipped: ${result.message}');
      } catch (e) {
        final cancelled = cancelToken.isCancelled || (e is ReleaseError && e.isCancelled);
        final message = cancelled ? 'Cancelled' : describeError(e);
        _set(id, StepState.failed(message));
        log(message, LogKind.error);
        failure = cancelled ? null : '${id.title}: $message';
        await _finish(cancelled ? RunPhase.cancelled : RunPhase.failed);
        return;
      }
    }
    if (cancelToken.isCancelled) {
      final c = current;
      if (c != null && !step(c).state.isFinished) _set(c, const StepState.failed('Cancelled'));
      await _finish(RunPhase.cancelled);
    } else {
      log(
        plan.rehearsal
            ? (artifact != null ? 'Rehearsal finished. The bundle is ready at $artifact.' : 'Rehearsal finished.')
            : 'Shipped ${plan.app.name} ${plan.version} (${plan.build}).',
        LogKind.success,
      );
      await _finish(RunPhase.succeeded);
    }
  }

  Future<void> _finish(RunPhase p) async {
    phase = p;
    finished = DateTime.now();
    current = null;
    _notify?.cancel();
    _notify = null;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    notifyListeners();
    onFinish?.call(this);
  }

  AscClient get _asc => apple ?? (throw const ReleaseError.precondition('No App Store Connect key for this app'));

  Future<void> _ensureNewBuild() async {
    _detail(StepId.prepare, 'Checking App Store Connect');
    final existing = await _asc.builds(plan.app.id, limit: 5, number: '${plan.build}', version: plan.version);
    if (existing.isNotEmpty) {
      throw ReleaseError.precondition('Build ${plan.version} (${plan.build}) is already on App Store Connect. Pick a higher build number.');
    }
  }

  Future<int> _highestOnPlay() async {
    final play = playClient;
    if (play == null) return 0;
    _detail(StepId.prepare, 'Checking Play');
    final tracks = (await play.overview(plan.app.playPackage)).tracks;
    var highest = 0;
    for (final t in tracks) {
      for (final r in t.releases) {
        if (r.maxCode > highest) highest = r.maxCode;
      }
    }
    log('Highest version code on Play: $highest');
    if (plan.build <= highest && !plan.rehearsal) {
      throw ReleaseError.precondition('Version code ${plan.build} is not above Play\'s highest ($highest).');
    }
    return highest;
  }

  void _writePubspec(FlutterProject? project, {String suffix = ''}) {
    if (project == null) return;
    if (plan.rehearsal) {
      log('Rehearsal leaves pubspec.yaml as it is.');
    } else if (plan.recipe.writeBuildNumber && (project.version != plan.version || project.buildNumber != plan.build)) {
      project.writeVersion(plan.version, plan.build);
      log('pubspec.yaml → version: ${plan.version}+${plan.build}$suffix', LogKind.success);
    }
  }

  Future<StepState> _prepareCloud() async {
    final cloud = plan.cloud, gh = github;
    if (cloud == null || gh == null) throw const ReleaseError.precondition('No GitHub repository for this project');
    final who = await gh.login();
    log('GitHub ${cloud.repo.fullName} as $who, project folder ${cloud.repo.projectDir}');
    if (cloud.target == CloudTarget.ios) {
      await _ensureNewBuild();
    } else {
      await _highestOnPlay();
    }
    _detail(StepId.prepare, 'Checking the workflow');
    if (!await gh.hasWorkflow(cloud.repo, cloud.target.workflowFile)) {
      throw ReleaseError.precondition(
        "${cloud.target.workflowFile} is not on ${cloud.repo.fullName}'s default branch yet. Add it from the Ship screen and push it.",
      );
    }
    final present = await gh.secretsPresent(cloud.repo);
    final missing = cloud.target.secretNames.where((s) => !present.contains(s)).toList();
    if (missing.isNotEmpty) {
      throw ReleaseError.precondition('The repository has no ${missing.join(', ')} secret yet. Set them from the Ship screen.');
    }
    log('Workflow and secrets are in place', LogKind.success);
    FlutterProject? project;
    try {
      project = FlutterProject.inspect(plan.projectRoot, entitlements: plan.recipe.entitlements);
    } catch (_) {}
    _writePubspec(project, suffix: ' (the cloud build gets the number as --build-number)');
    return StepState.done;
  }

  Future<StepState> _cloudBuild() async {
    final cloud = plan.cloud, gh = github;
    if (cloud == null || gh == null) throw const ReleaseError.precondition('No GitHub repository');
    final ref = await gh.defaultBranch(cloud.repo);
    final marker = 'rd-${id.substring(0, 8)}';
    _detail(StepId.cloudBuild, 'Starting on $ref');
    final ios = cloud.target == CloudTarget.ios;
    log('Starting ${cloud.target.workflowFile} on ${cloud.repo.fullName}@$ref${plan.rehearsal && ios ? ' (no upload)' : ''}');
    final inputs = {'version': plan.version, 'build': '${plan.build}', 'release_desk_id': marker};
    if (ios) inputs['upload'] = plan.rehearsal ? 'false' : 'true';
    var run = await gh.dispatch(cloud.repo, cloud.target.workflowFile, ref: ref, inputs: inputs, marker: marker, cancel: cancelToken);
    cloudRunUrl = run.htmlUrl;
    log('Run ${run.id}: ${run.htmlUrl}');
    final seen = <String, String>{};
    int? jobId;
    final began = DateTime.now();
    try {
      while (run.status != 'completed') {
        await cancelToken.sleep(const Duration(seconds: 8));
        run = await gh.run(cloud.repo, run.id);
        final s = await gh.steps(cloud.repo, run.id);
        jobId = s.jobId ?? jobId;
        for (final st in s.steps) {
          final state = st.conclusion ?? st.status;
          if (seen[st.name] == state) continue;
          seen[st.name] = state;
          switch (state) {
            case 'in_progress':
              log('▸ ${st.name}');
            case 'success':
              final d = st.started != null && st.completed != null ? shortDuration(st.completed!.difference(st.started!)) : '';
              log('✓ ${st.name} $d', LogKind.success);
            case 'failure':
              log('✗ ${st.name}', LogKind.error);
            case 'skipped':
              log('– ${st.name} skipped');
          }
        }
        String? now;
        for (final st in s.steps) {
          if (st.status == 'in_progress') now = st.name;
        }
        now ??= run.status == 'queued' ? 'Waiting for a ${ios ? 'macOS' : 'Linux'} runner' : run.status;
        _detail(StepId.cloudBuild, '$now · ${DateTime.now().difference(began).inMinutes} min');
      }
    } catch (e) {
      if (cancelToken.isCancelled) {
        await gh.cancel(cloud.repo, run.id);
        log('Cancelled the GitHub run');
      }
      rethrow;
    }
    if (run.conclusion != 'success') {
      if (jobId != null) {
        for (final line in await gh.logTail(cloud.repo, jobId, lines: 30)) {
          log(line, LogKind.output);
        }
      }
      throw ReleaseError.precondition('The GitHub run ended ${run.conclusion ?? 'badly'}. Its log is above and on GitHub.');
    }
    if (!ios) {
      _detail(StepId.cloudBuild, 'Downloading the app bundle');
      final dir = Directory(p.join(Directory.systemTemp.path, 'ReleaseDesk-aab-${run.id}'));
      final files = await gh.downloadArtifact(cloud.repo, run.id, CloudTarget.androidArtifact, dir);
      final aab = files.where((f) => f.path.toLowerCase().endsWith('.aab')).firstOrNull;
      if (aab == null) throw const ReleaseError.precondition('The artifact has no .aab file.');
      artifact = aab.path;
      log('Built on GitHub: ${p.basename(aab.path)} · ${formatBytes(aab.lengthSync())}', LogKind.success);
      return StepState.done;
    }
    log(plan.rehearsal ? 'Built and signed on GitHub' : 'Built on GitHub and uploaded to App Store Connect', LogKind.success);
    return StepState.done;
  }

  Future<StepState> _waitForProcessing() async {
    final began = DateTime.now();
    var lastState = '';
    while (DateTime.now().difference(began).inMinutes < 60) {
      final list = await _asc.builds(plan.app.id, limit: 2, number: '${plan.build}', version: plan.version);
      final build = list.firstOrNull;
      final state = build?.processingState ?? 'NOT_LISTED';
      if (state != lastState) {
        log(build == null ? 'Not listed yet' : 'State $state');
        lastState = state;
      }
      final minutes = DateTime.now().difference(began).inMinutes;
      _detail(StepId.processing, '${build == null ? 'Waiting for Apple to list it' : describeState(state).label} · $minutes min');
      if (build != null) {
        if (state == 'VALID') {
          buildId = build.id;
          log('Build ${build.id} is processed', LogKind.success);
          return StepState.done;
        }
        if (state == 'FAILED' || state == 'INVALID') {
          throw ReleaseError.precondition('Apple marked the build $state. Check the email from App Store Connect.');
        }
      }
      await cancelToken.sleep(const Duration(seconds: 30));
    }
    throw const ReleaseError.precondition('Still processing after an hour.');
  }

  Future<StepState> _writeNotes() async {
    final notes = plan.whatsNew.entries.where((e) => e.value.trim().isNotEmpty).toList()..sort((a, b) => a.key.compareTo(b.key));
    if (notes.isEmpty) return const StepState.skipped('No text');
    for (final n in notes) {
      _detail(StepId.notes, n.key);
      await _asc.setWhatsNew(buildId!, n.key, n.value);
      log('What to Test (${n.key}) written');
    }
    return StepState.done;
  }

  Future<StepState> _addToGroups() async {
    final automatic = plan.groups.where((g) => g.isInternal && g.allBuilds);
    final targets = plan.groups.where((g) => !(g.isInternal && g.allBuilds)).toList();
    for (final g in automatic) {
      log('${g.name} gets every build automatically');
    }
    if (targets.isEmpty) return plan.groups.isEmpty ? const StepState.skipped('No groups chosen') : StepState.done;
    final names = targets.map((g) => g.name).join(', ');
    for (var attempt = 1; attempt <= 25; attempt++) {
      try {
        _detail(StepId.groups, names);
        await _asc.addBuildToGroups(buildId!, targets.map((g) => g.id).toList());
        log('Added to $names', LogKind.success);
        return StepState.done;
      } on ReleaseError catch (e) {
        // Apple answers 404 for a few minutes after processing ends.
        if (e.status != 404 || attempt >= 25) rethrow;
        _detail(StepId.groups, 'Apple is not ready for it yet · try ${attempt + 1} in 60 s');
        log('Group not ready for the build yet (404), trying again in 60 s');
        await cancelToken.sleep(const Duration(seconds: 60));
      }
    }
    throw ReleaseError.precondition('Could not add the build to $names');
  }

  Future<StepState> _submitReview() async {
    if (!plan.submitForReview) return const StepState.skipped('Turned off');
    if (!plan.groups.any((g) => !g.isInternal)) return const StepState.skipped('Only internal groups');
    try {
      await _asc.submitForBetaReview(buildId!);
      log('Submitted for beta app review', LogKind.success);
      return StepState.done;
    } on ReleaseError catch (e) {
      if (e.message.contains('ANOTHER_BUILD_IN_REVIEW')) {
        return const StepState.warning('Another build of this version is in review. Submit this one when that review ends.');
      }
      if (e.status == 409 && e.message.toLowerCase().contains('already')) return const StepState.warning('Already submitted.');
      rethrow;
    }
  }

  Future<StepState> _waitUntilLive() async {
    final external = plan.groups.any((g) => !g.isInternal);
    final began = DateTime.now();
    var last = '';
    while (DateTime.now().difference(began).inMinutes < 10) {
      final s = await _asc.betaState(buildId!);
      final state = (external ? s.externalState : s.internalState) ?? '?';
      if (state != last) {
        log('${external ? 'External' : 'Internal'} testing: $state');
        last = state;
      }
      _detail(StepId.live, describeState(state).label);
      if (state == 'IN_BETA_TESTING') {
        log('Testers can install ${plan.version} (${plan.build}) now', LogKind.success);
        return StepState.done;
      }
      if (state == 'BETA_REJECTED') throw const ReleaseError.precondition('Beta review rejected the build.');
      await cancelToken.sleep(const Duration(seconds: 20));
    }
    return StepState.warning('Still ${describeState(last).label.toLowerCase()}. Apple emails when it is ready.');
  }

  // MARK: Android

  Future<StepState> _prepareAndroid() async {
    final project = FlutterProject.inspect(plan.projectRoot);
    log('Flutter project ${project.name}, pubspec ${project.version}+${project.buildNumber}, package ${project.androidPackage ?? '?'}');
    final pkg = project.androidPackage;
    if (pkg != null && pkg != plan.app.playPackage) {
      throw ReleaseError.precondition('The project builds $pkg, but the Play app is ${plan.app.playPackage}.');
    }
    try {
      final out = await Shell.capture('flutter', ['--version', '--machine'], cwd: plan.projectRoot, cancel: cancelToken);
      final j = J.decode(out.substring(out.indexOf('{').clamp(0, out.length)));
      log('Flutter ${j['frameworkVersion'].string ?? '?'}, Dart ${j['dartSdkVersion'].string ?? '?'}');
    } on ReleaseError catch (e) {
      if (e.isCancelled) rethrow;
      throw ReleaseError.precondition('Flutter is not available here: ${e.message}');
    }
    String? warning;
    if (!project.hasUploadKey) {
      const text = 'No android/key.properties: the bundle would be signed with the debug key, which Play refuses.';
      if (plan.rehearsal) {
        warning = text;
      } else {
        throw const ReleaseError.precondition(text);
      }
    }
    await _highestOnPlay();
    _writePubspec(project);
    return warning == null ? StepState.done : StepState.warning(warning);
  }

  Future<StepState> _buildBundle() async {
    _detail(StepId.bundle, 'flutter build appbundle');
    final args = ['build', 'appbundle', '--release', '--build-name', plan.version, '--build-number', '${plan.build}'];
    log('\$ flutter ${args.join(' ')}');
    final code = await Shell.run('flutter', args, cwd: plan.projectRoot, cancel: cancelToken, onLine: _output(StepId.bundle));
    if (code != 0) throw ReleaseError.command('flutter build appbundle', code, '');
    final aab = File(p.join(plan.projectRoot, 'build', 'app', 'outputs', 'bundle', 'release', 'app-release.aab'));
    if (!aab.existsSync()) throw ReleaseError.precondition('No bundle at ${aab.path}');
    artifact = aab.path;
    log('app-release.aab · ${formatBytes(aab.lengthSync())}', LogKind.success);
    return StepState.done;
  }

  Future<StepState> _checkSigning() async {
    final candidates = <String>[
      if ((Platform.environment['JAVA_HOME'] ?? '').isNotEmpty)
        p.join(Platform.environment['JAVA_HOME']!, 'bin', Platform.isWindows ? 'keytool.exe' : 'keytool'),
      if (Platform.isWindows) r'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe',
      if (Platform.isLinux) '/opt/android-studio/jbr/bin/keytool',
      if (Platform.isMacOS) '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool',
      'keytool',
    ];
    for (final tool in candidates) {
      if (p.isAbsolute(tool) && !File(tool).existsSync()) continue;
      String out;
      try {
        out = await Shell.capture(tool, ['-printcert', '-jarfile', artifact!], cancel: cancelToken);
      } on ReleaseError catch (e) {
        if (e.isCancelled) rethrow;
        continue;
      }
      final lines = out.split('\n');
      final owner = lines.where((l) => l.contains('Owner:')).map((l) => l.replaceFirst(RegExp(r'^\s*Owner:\s*'), '')).firstOrNull ?? '?';
      final sha = lines.where((l) => l.contains('SHA256:')).map((l) => l.trim()).firstOrNull ?? '';
      log('Signed by $owner');
      if (sha.isNotEmpty) log(sha);
      if (owner.contains('Android Debug')) {
        if (plan.rehearsal) return const StepState.warning('Signed with the debug key; Play would refuse it.');
        throw const ReleaseError.precondition('The bundle is signed with the debug key. Set android/key.properties to the upload key.');
      }
      return StepState.done;
    }
    return const StepState.warning('keytool not found, signature not checked');
  }

  Future<StepState> _releaseToPlay() async {
    final play = playClient, target = plan.play;
    if (play == null || target == null) throw const ReleaseError.precondition('No Play account for this app');
    _detail(StepId.playRelease, '${target.track} · ${target.status}');
    final result = await play.release(
      package: plan.app.playPackage,
      bundle: File(artifact!),
      track: target.track,
      name: '${plan.version} (${plan.build})',
      status: target.status,
      userFraction: target.userFraction,
      notes: plan.whatsNew,
      log: (s) => log(s, LogKind.info, StepId.playRelease),
    );
    playVersionCode = result.versionCode;
    log('Released ${plan.version} (${result.versionCode}) to ${target.track}', LogKind.success);
    return result.status == target.status ? StepState.done : StepState.warning('Saved as a ${result.status} release: this app is not published on Play yet.');
  }

  @override
  void dispose() {
    _notify?.cancel();
    super.dispose();
  }
}

String shortDuration(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return s >= 60 ? '${s ~/ 60}m ${s % 60}s' : '${s}s';
}

String formatBytes(int n) {
  if (n < 1024) return '$n bytes';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
