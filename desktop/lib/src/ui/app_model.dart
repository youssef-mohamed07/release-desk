import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../core/asc.dart';
import '../core/asc_key.dart';
import '../core/errors.dart';
import '../core/flutter_project.dart';
import '../core/github.dart';
import '../core/google.dart';
import '../core/json.dart';
import '../core/shell.dart';
import '../core/play.dart';
import '../core/release_run.dart';
import '../core/workspace.dart';

enum RouteKind { overview, activity, team, app, ship }

class AppRoute {
  const AppRoute(this.kind, [this.id]);
  const AppRoute.overview() : this(RouteKind.overview);
  const AppRoute.activity() : this(RouteKind.activity);
  const AppRoute.team(String id) : this(RouteKind.team, id);
  const AppRoute.app(String id) : this(RouteKind.app, id);
  const AppRoute.ship(String id) : this(RouteKind.ship, id);

  final RouteKind kind;
  final String? id;

  @override
  bool operator ==(Object other) => other is AppRoute && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// What the "Build on GitHub" checklist found.
class CloudStatus {
  const CloudStatus({this.repo, this.user, this.workflow, this.secrets, this.error, this.flutterVersion});
  final GitHubRepo? repo;
  final String? user;
  final bool? workflow;
  final Set<String>? secrets;
  final String? error;
  final String? flutterVersion;
}

class TeamState {
  List<StoreApp> apps = [];
  bool loading = false;
  String? error;
  DateTime? refreshed;
}

class AppState {
  List<PlayTrack> tracks = [];
  PlayAppDetails? play;
  List<AscBuild> builds = [];
  List<AscBetaGroup> groups = [];
  List<AscVersion> versions = [];
  bool loading = false;
  String? error;
  DateTime? refreshed;
  bool detailed = false;
}

/// Everything the window shows: the workspace, what the stores said, the
/// runs of this session, and the small preferences.
class AppModel extends ChangeNotifier {
  AppModel({required this.store, required this.secrets}) : workspace = store.load(), logsDir = store.logs {
    github = GitHubClient(savedToken: () => secrets.read(GitHubClient.secretKey));
    final s = store.loadSettings();
    privacy = s['privacy'] == true;
    themeMode = switch (s['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    icons = ((s['icons'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
    drafts = ((s['drafts'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', ((v as Map?) ?? const {}).map((a, b) => MapEntry('$a', '$b'))));
  }

  final WorkspaceStore store;
  final SecretStore secrets;
  final Directory logsDir;
  Workspace workspace;
  late final GitHubClient github;

  AppRoute route = const AppRoute.overview();
  final teams = <String, TeamState>{};
  final apps = <String, AppState>{};
  final runs = <ReleaseRun>[];

  /// Apps whose ship page shows the composer rather than their last run.
  final composing = <String>{};
  bool paletteOpen = false;
  bool privacy = false;
  ThemeMode themeMode = ThemeMode.system;
  Map<String, String> icons = {};
  Map<String, Map<String, String>> drafts = {};

  /// Messages for the person (shown as snack bars).
  final messages = StreamController<String>.broadcast();

  /// Asks the window to open the Connect dialog for a store.
  final connectRequests = StreamController<StoreProvider>.broadcast();

  final _asc = <String, AscClient>{};
  final _play = <String, PlayClient>{};
  final _appTeam = <String, String>{};
  Timer? _settingsTimer;

  void go(AppRoute r) {
    route = r;
    notifyListeners();
  }

  void togglePrivacy() {
    privacy = !privacy;
    _saveSettings();
    notifyListeners();
  }

  void cycleTheme() {
    themeMode = switch (themeMode) {
      ThemeMode.system => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
    };
    _saveSettings();
    notifyListeners();
  }

  void setPalette(bool open) {
    paletteOpen = open;
    notifyListeners();
  }

  void say(String message) => messages.add(message);

  void connect(StoreProvider p) => connectRequests.add(p);

  // MARK: Lookups

  List<({Account account, Team team})> teamsOf(StoreProvider? provider) => [
    for (final a in workspace.accounts)
      if (provider == null || a.provider == provider)
        for (final t in a.teams) (account: a, team: t),
  ];

  List<({Account account, Team team})> get allTeams => teamsOf(null);

  List<StoreApp> get allApps => [for (final t in allTeams) ...?teams[t.team.id]?.apps];

  StoreApp? app(String id) {
    for (final s in teams.values) {
      for (final a in s.apps) {
        if (a.id == id) return a;
      }
    }
    return null;
  }

  Team? teamOfApp(String id) {
    final t = _appTeam[id];
    return t == null ? null : workspace.team(t)?.team;
  }

  AppState appState(String id) => apps.putIfAbsent(id, AppState.new);

  String? iconUrl(String appId, [int size = 256]) {
    if (appId.startsWith('play:')) {
      final u = apps[appId]?.play?.iconUrl ?? icons[appId];
      if (u != null) return '$u=s$size';
      // The same app on the App Store lends its icon.
      final pkg = appId.substring(5);
      for (final twin in allApps) {
        if (!twin.isPlay && twin.bundleId == pkg) return iconUrl(twin.id, size);
      }
      return null;
    }
    for (final b in apps[appId]?.builds ?? const <AscBuild>[]) {
      if (b.iconTemplate != null) return b.iconUrl(size);
    }
    final t = icons[appId];
    return t == null ? null : iconFromTemplate(t, size);
  }

  ReleaseRun? activeRun(String appId) {
    for (final r in runs.reversed) {
      if (r.plan.app.id == appId && (r.phase == RunPhase.running || r.phase == RunPhase.ready)) return r;
    }
    return null;
  }

  ReleaseRun? latestRun(String appId) {
    for (final r in runs.reversed) {
      if (r.plan.app.id == appId) return r;
    }
    return null;
  }

  int get runningCount => runs.where((r) => r.phase == RunPhase.running).length;

  // MARK: Clients

  Future<AscClient> ascClient(Team team) async {
    final c = _asc[team.id];
    if (c != null) return c;
    final cred = team.credential;
    if (cred.isGoogle) throw ReleaseError.precondition('${team.name} is not an App Store Connect team');
    final pem = await secrets.read(cred.secretKey);
    if (pem == null) throw ReleaseError.precondition('The key for ${team.name} is not in the keychain any more. Remove the team and connect it again.');
    return _asc[team.id] = AscClient(AscKey(keyId: cred.keyId!, issuerId: cred.issuerId!, pem: pem));
  }

  Future<PlayClient> playClient(Team team) async {
    final c = _play[team.id];
    if (c != null) return c;
    final json = await secrets.read(team.credential.secretKey);
    if (json == null) throw ReleaseError.precondition('The Google sign-in for ${team.name} is not in the keychain any more. Sign in again.');
    return _play[team.id] = PlayClient(GoogleUser.fromJson((jsonDecode(json) as Map).cast<String, Object?>()));
  }

  Future<AscClient> ascClientForApp(String id) async {
    final t = teamOfApp(id);
    if (t == null) throw const ReleaseError.precondition('No team for this app');
    return ascClient(t);
  }

  // MARK: Loading

  Future<void> refreshAll() => Future.wait([for (final t in allTeams) refreshTeam(t.team)]);

  Future<void> refreshTeam(Team team) async {
    if (team.credential.isGoogle) return _refreshPlay(team);
    final s = teams.putIfAbsent(team.id, TeamState.new)..loading = true;
    notifyListeners();
    try {
      final c = await ascClient(team);
      final list = await c.apps();
      s
        ..apps = list
        ..error = null
        ..refreshed = DateTime.now();
      for (final a in list) {
        _appTeam[a.id] = team.id;
      }
      notifyListeners();
      // A light pass for every app: the latest builds give icons and states.
      await Future.wait(
        list.map((a) async {
          try {
            final builds = await c.builds(a.id, limit: 3);
            final st = appState(a.id);
            if (!st.detailed) st.builds = builds;
            for (final b in builds) {
              if (b.iconTemplate != null) {
                icons[a.id] = b.iconTemplate!;
                break;
              }
            }
          } catch (_) {}
        }),
      );
      _saveSettings();
    } catch (e) {
      s.error = describeError(e);
    } finally {
      s.loading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshPlay(Team team) async {
    final s = teams.putIfAbsent(team.id, TeamState.new)..loading = true;
    notifyListeners();
    try {
      final c = await playClient(team);
      final packages = [...team.packages];
      final found = await c.searchApps();
      for (final a in found ?? const <PlayApp>[]) {
        if (!packages.contains(a.packageName)) packages.add(a.packageName);
      }
      var list = [for (final pkg in packages) StoreApp(id: 'play:$pkg', name: _knownName(pkg), bundleId: pkg)];
      for (final a in list) {
        _appTeam[a.id] = team.id;
      }
      s
        ..apps = list
        ..error = null;
      notifyListeners();
      final results = await Future.wait(
        list.map((a) async {
          try {
            return (a.id, await c.overview(a.bundleId), null);
          } catch (e) {
            return (a.id, null, e);
          }
        }),
      );
      for (final (id, o, e) in results) {
        final st = appState(id);
        if (o != null) {
          st
            ..tracks = o.tracks
            ..play = o.details
            ..error = null
            ..detailed = true;
          if (o.details.iconUrl != null) icons[id] = o.details.iconUrl!;
          final title = o.details.title;
          if (title != null) {
            list = [for (final a in list) a.id == id ? a.copyWith(name: title, primaryLocale: o.details.defaultLanguage) : a];
          }
        } else if (e != null) {
          st.error = playMessage(e, team);
        }
      }
      s
        ..apps = list
        ..refreshed = DateTime.now();
      _saveSettings();
    } catch (e) {
      s.error = playMessage(e, team);
    } finally {
      s.loading = false;
      notifyListeners();
    }
  }

  /// Before Play gives a title, the App Store twin names the app.
  String _knownName(String package) {
    for (final a in allApps) {
      if (!a.isPlay && a.bundleId == package) return a.name;
    }
    for (final a in allApps) {
      if (a.isPlay && a.bundleId == package && a.name != package) return a.name;
    }
    return package;
  }

  String playMessage(Object error, Team team) {
    if (error is ReleaseError && error.isPlayPermission && team.credential.isGoogle) {
      return '${team.credential.email} has no access to this app on Play Console, or the app is in another developer account.';
    }
    return describeError(error);
  }

  Future<void> refreshApp(String appId) async {
    final team = teamOfApp(appId);
    if (team == null) return;
    final st = appState(appId)..loading = true;
    notifyListeners();
    try {
      if (appId.startsWith('play:')) {
        final c = await playClient(team);
        final o = await c.overview(appId.substring(5));
        st
          ..tracks = o.tracks
          ..play = o.details
          ..error = null
          ..refreshed = DateTime.now()
          ..detailed = true;
      } else {
        final c = await ascClient(team);
        final r = await Future.wait([c.builds(appId, limit: 40), c.betaGroups(appId), c.versions(appId)]);
        st
          ..builds = r[0] as List<AscBuild>
          ..groups = r[1] as List<AscBetaGroup>
          ..versions = r[2] as List<AscVersion>
          ..error = null
          ..refreshed = DateTime.now()
          ..detailed = true;
      }
    } catch (e) {
      st.error = appId.startsWith('play:') ? playMessage(e, team) : describeError(e);
    } finally {
      st.loading = false;
      notifyListeners();
    }
  }

  // MARK: Accounts

  /// Checks a key against App Store Connect without saving anything.
  Future<({String? teamId, List<StoreApp> apps})> verifyApple(String keyId, String issuerId, String pem) async {
    final c = AscClient(AscKey(keyId: keyId, issuerId: issuerId, pem: pem));
    try {
      final list = await c.apps();
      String? team;
      try {
        team = await c.teamId();
      } catch (_) {}
      return (teamId: team, apps: list);
    } finally {
      c.close();
    }
  }

  Future<void> connectApple({
    String? accountId,
    required String newAccountName,
    String? email,
    required String teamName,
    String? teamId,
    required String keyId,
    required String issuerId,
    required String pem,
  }) async {
    final cred = Credential.appStoreConnectKey(keyId: keyId.trim(), issuerId: issuerId.trim());
    await secrets.write(cred.secretKey, pem);
    _add(Team(name: teamName, teamId: teamId, credential: cred), StoreProvider.apple, accountId, newAccountName, email);
  }

  /// Saves a person's Google sign-in and shows their Play apps as one
  /// developer account.
  Future<void> connectGoogleUser(GoogleUser user, {String? accountId, required String teamName, required List<String> packages}) async {
    final cred = Credential.googleUser(email: user.email);
    await secrets.write(cred.secretKey, jsonEncode(user.toJson()));
    _add(Team(name: teamName, credential: cred, packages: packages), StoreProvider.google, accountId, user.email, user.email);
  }

  void _add(Team team, StoreProvider provider, String? accountId, String newAccountName, String? email) {
    Account? acc;
    for (final a in workspace.accounts) {
      if (a.id == accountId && a.provider == provider) acc = a;
    }
    if (acc != null) {
      acc.teams.add(team);
    } else {
      workspace.accounts.add(Account(provider: provider, name: newAccountName, email: email, teams: [team]));
    }
    save();
    route = AppRoute.team(team.id);
    notifyListeners();
    unawaited(refreshTeam(team));
  }

  void setPackages(List<String> packages, Team team) {
    team.packages = packages;
    save();
    _play.remove(team.id);
    unawaited(refreshTeam(team));
  }

  Future<void> removeTeam(Team team) async {
    // Its apps' project links go too.
    final ids = {for (final a in teams[team.id]?.apps ?? const <StoreApp>[]) a.id};
    workspace.links.removeWhere((l) => ids.contains(l.appId));
    for (final id in ids) {
      apps.remove(id);
      _appTeam.remove(id);
    }
    await secrets.delete(team.credential.secretKey);
    _asc.remove(team.id)?.close();
    _play.remove(team.id)?.close();
    teams.remove(team.id);
    for (final a in workspace.accounts) {
      a.teams.removeWhere((t) => t.id == team.id);
    }
    workspace.accounts.removeWhere((a) => a.teams.isEmpty);
    save();
    route = const AppRoute.overview();
    notifyListeners();
  }

  Future<OAuthClient?> savedOAuthClient() async {
    final s = await secrets.read(OAuthClient.secretKey);
    if (s == null) return null;
    try {
      return OAuthClient.fromJson((jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Future<void> saveOAuthClient(OAuthClient c) => secrets.write(OAuthClient.secretKey, jsonEncode(c.toJson()));

  Future<void> saveGitHubToken(String? token) async {
    if (token == null || token.trim().isEmpty) {
      await secrets.delete(GitHubClient.secretKey);
    } else {
      await secrets.write(GitHubClient.secretKey, token.trim());
    }
    github.forgetToken();
  }

  // MARK: Projects and runs

  /// Links a store app to its source folder, and the same app on the other
  /// store (same bundle id / package) when it has no folder yet.
  void link(String appId, String path) {
    void set(String id) {
      final l = workspace.link(id);
      if (l != null) {
        l.path = path;
      } else {
        workspace.links.add(ProjectLink(appId: id, path: path));
      }
    }

    set(appId);
    final a = app(appId);
    if (a != null) {
      try {
        final proj = FlutterProject.inspect(path);
        final ids = {proj.iosBundleId, proj.androidPackage}.whereType<String>().toSet();
        for (final twin in allApps) {
          if (twin.id != appId && ids.contains(twin.bundleId) && twin.isPlay != a.isPlay && workspace.link(twin.id) == null) set(twin.id);
        }
      } catch (_) {}
    }
    save();
    notifyListeners();
  }

  void unlink(String appId) {
    workspace.links.removeWhere((l) => l.appId == appId);
    save();
    notifyListeners();
  }

  void updateRecipe(String appId, void Function(Recipe) change) {
    final l = workspace.link(appId);
    if (l == null) return;
    change(l.recipe);
    save();
  }

  Future<ReleaseRun> launch(ReleasePlan plan) async {
    final team = teamOfApp(plan.app.id);
    if (team == null) throw const ReleaseError.precondition('No team for this app');
    final ReleaseRun run;
    if (plan.platform == ReleasePlatform.android) {
      run = ReleaseRun(plan: plan, logsDir: logsDir, playClient: await playClient(team), github: plan.cloud != null ? github : null);
    } else {
      run = ReleaseRun(plan: plan, logsDir: logsDir, apple: await ascClient(team), github: github);
    }
    run.onFinish = _finished;
    var lastPhase = run.phase;
    var lastStep = run.current;
    run.addListener(() {
      if (run.phase != lastPhase || run.current != lastStep) {
        lastPhase = run.phase;
        lastStep = run.current;
        notifyListeners();
      }
    });
    runs.add(run);
    composing.remove(plan.app.id);
    run.start();
    notifyListeners();
    return run;
  }

  /// Runs a stopped release again: iOS from Apple processing when GitHub
  /// already uploaded the build, otherwise from the start.
  Future<ReleaseRun> resume(ReleaseRun run) {
    final uploaded =
        run.plan.platform == ReleasePlatform.ios &&
        !run.plan.rehearsal &&
        run.has(StepId.cloudBuild) &&
        run.step(StepId.cloudBuild).state.status == StepStatus.done;
    return launch(uploaded ? run.plan.copyWith(startAt: StepId.processing) : run.plan.copyWith(clearStart: true));
  }

  bool canResumeFromProcessing(ReleaseRun run) =>
      run.plan.platform == ReleasePlatform.ios &&
      !run.plan.rehearsal &&
      run.has(StepId.cloudBuild) &&
      run.step(StepId.cloudBuild).state.status == StepStatus.done;

  void _finished(ReleaseRun run) {
    workspace.runs.insert(
      0,
      RunRecord(
        id: run.id,
        appId: run.plan.app.id,
        appName: run.plan.app.name,
        version: run.plan.version,
        build: run.plan.build,
        started: run.started ?? DateTime.now(),
        finished: run.finished,
        outcome: run.plan.rehearsal && run.phase == RunPhase.succeeded ? 'rehearsed' : run.phase.name,
        failedStep: run.failedStep?.id.title,
        logPath: run.logFile.path,
      ),
    );
    if (workspace.runs.length > 200) workspace.runs.removeRange(200, workspace.runs.length);
    save();
    final name = '${run.plan.app.name} ${run.plan.version} (${run.plan.build})';
    say(switch (run.phase) {
      RunPhase.succeeded => run.plan.rehearsal ? 'Rehearsal passed: $name' : 'Shipped $name',
      RunPhase.failed => '$name stopped. ${run.failure ?? ''}',
      _ => '$name cancelled',
    });
    notifyListeners();
    unawaited(refreshApp(run.plan.app.id));
  }

  /// Puts the team's App Store Connect key, or the project's Android upload
  /// key, into the repository's Actions secrets so the workflow can sign.
  Future<void> setCloudSecrets(String appId, GitHubRepo repo, CloudTarget target, String projectRoot) async {
    if (target == CloudTarget.android) {
      final proj = FlutterProject.inspect(projectRoot);
      final props = proj.keyProperties();
      if (props.isEmpty) throw const ReleaseError.precondition('This project has no android/key.properties with its upload key.');
      final store = props['storeFile'], storePass = props['storePassword'], alias = props['keyAlias'], keyPass = props['keyPassword'];
      if (store == null || storePass == null || alias == null || keyPass == null) {
        throw const ReleaseError.precondition('android/key.properties needs storeFile, storePassword, keyAlias and keyPassword.');
      }
      // Gradle resolves a relative storeFile from android/app.
      var path = store.startsWith('~') ? p.join(Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '', store.substring(2)) : store;
      if (!p.isAbsolute(path)) path = p.normalize(p.join(projectRoot, 'android', 'app', path));
      final f = File(path);
      if (!f.existsSync()) throw ReleaseError.precondition('Cannot read the keystore at $path');
      await github.setSecret('ANDROID_KEYSTORE_BASE64', base64.encode(f.readAsBytesSync()), repo);
      await github.setSecret('ANDROID_KEYSTORE_PASSWORD', storePass, repo);
      await github.setSecret('ANDROID_KEY_ALIAS', alias, repo);
      await github.setSecret('ANDROID_KEY_PASSWORD', keyPass, repo);
      return;
    }
    final team = teamOfApp(appId);
    final cred = team?.credential;
    if (team == null || cred == null || cred.isGoogle) throw const ReleaseError.precondition('This app has no App Store Connect key');
    final pem = await secrets.read(cred.secretKey);
    if (pem == null) throw const ReleaseError.precondition('The key is not in the keychain any more.');
    await github.setSecret('ASC_KEY_ID', cred.keyId!, repo);
    await github.setSecret('ASC_ISSUER_ID', cred.issuerId!, repo);
    await github.setSecret('ASC_PRIVATE_KEY', pem, repo);
  }

  /// Looks at the project's GitHub repository: who is signed in, whether the
  /// workflow is on the default branch, which secrets are set.
  Future<CloudStatus> cloudStatus(String projectPath, CloudTarget target, {GitHubRepo? known, String? flutterVersion}) async {
    final repo = known ?? await GitHubRepo.detect(projectPath);
    if (repo == null) return const CloudStatus();
    String? user, error;
    bool? workflow;
    Set<String>? present;
    try {
      user = await github.login();
      workflow = await github.hasWorkflow(repo, target.workflowFile);
      present = await github.secretsPresent(repo);
    } catch (e) {
      error = describeError(e);
    }
    var flutter = flutterVersion;
    if (flutter == null) {
      try {
        final out = await Shell.capture('flutter', ['--version', '--machine'], cwd: projectPath);
        final i = out.indexOf('{');
        flutter = J.decode(out.substring(i < 0 ? 0 : i))['frameworkVersion'].string;
      } catch (_) {}
    }
    return CloudStatus(repo: repo, user: user, workflow: workflow, secrets: present, error: error, flutterVersion: flutter);
  }

  /// Commit subjects since the last upload, for drafting release notes.
  Future<List<String>> commitsSince(FlutterProject project, DateTime? since) => project.commits(since: since);

  void bindAppToTeam(String appId, String teamId) => _appTeam[appId] = teamId;

  // MARK: Drafts and saving

  Map<String, String> draft(String appId) => Map.of(drafts[appId] ?? const {});

  void saveDraft(String appId, Map<String, String> notes) {
    final kept = {
      for (final e in notes.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    if (kept.isEmpty) {
      drafts.remove(appId);
    } else {
      drafts[appId] = kept;
    }
    _saveSettings();
  }

  void save() {
    try {
      store.save(workspace);
    } catch (e) {
      say('Could not save: ${describeError(e)}');
    }
  }

  void _saveSettings() {
    _settingsTimer?.cancel();
    _settingsTimer = Timer(const Duration(milliseconds: 400), () {
      try {
        store.saveSettings({
          'privacy': privacy,
          'theme': switch (themeMode) {
            ThemeMode.light => 'light',
            ThemeMode.dark => 'dark',
            _ => 'system',
          },
          'icons': icons,
          'drafts': drafts,
        });
      } catch (_) {}
    });
  }
}

/// Gives the widget tree the model and rebuilds what depends on it.
class ModelScope extends InheritedNotifier<AppModel> {
  const ModelScope({super.key, required AppModel model, required super.child}) : super(notifier: model);

  static AppModel of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ModelScope>()!.notifier!;

  /// Reads the model without listening (for callbacks).
  static AppModel read(BuildContext context) => context.getInheritedWidgetOfExactType<ModelScope>()!.notifier!;
}
