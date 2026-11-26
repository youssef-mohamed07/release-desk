// Renders every screen with made-up data and fails on any layout or build
// error. With RD_SHOTS=<folder> it also writes a PNG of each screen there.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide StepState;
import 'package:path/path.dart' as p;
import 'package:release_desk/src/core/asc.dart';
import 'package:release_desk/src/core/flutter_project.dart';
import 'package:release_desk/src/core/github.dart';
import 'package:release_desk/src/core/play.dart';
import 'package:release_desk/src/ui/theme.dart' show debugFontFamilyFallback, debugHomeOverride;
import 'package:release_desk/src/ui/overview.dart' show debugUserNameOverride;
import 'package:release_desk/src/core/release_run.dart';
import 'package:release_desk/src/core/workspace.dart';
import 'package:release_desk/src/ui/app_model.dart';
import 'package:release_desk/src/ui/command_palette.dart';
import 'package:release_desk/src/ui/connect.dart';
import 'package:release_desk/src/ui/root.dart';

/// RD_PROMO: screens for the promo video, with a stand-in person and a ready release.
final promo = Platform.environment['RD_PROMO'] != null;

/// A model that never calls a store, GitHub or git.
class FakeModel extends AppModel {
  FakeModel({required super.store, required super.secrets});

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshTeam(Team team) async {}

  @override
  Future<void> refreshApp(String appId) async {}

  @override
  Future<CloudStatus> cloudStatus(String projectPath, CloudTarget target, {GitHubRepo? known, String? flutterVersion}) async => CloudStatus(
    repo: const GitHubRepo(owner: 'example-org', name: 'atlas-notes', projectDir: 'mobile'),
    user: 'octocat',
    workflow: target == CloudTarget.ios,
    secrets: target == CloudTarget.ios ? {'ASC_KEY_ID', 'ASC_ISSUER_ID', if (promo) 'ASC_PRIVATE_KEY'} : <String>{},
  );

  @override
  Future<List<String>> commitsSince(FlutterProject project, DateTime? since) async => [
    'Faster search on the notes list',
    'Fix the share sheet on iPad',
    'Arabic layout for settings',
  ];
}

Future<void> _loadFonts() async {
  final cache = p.join(Platform.environment['FLUTTER_ROOT'] ?? p.join(Platform.environment['HOME']!, 'flutter'), 'bin', 'cache', 'artifacts', 'material_fonts');
  final roboto = FontLoader('Roboto');
  for (final f in Directory(cache).listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('Roboto-') && f.path.endsWith('.ttf'))) {
    roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File(p.join(cache, 'MaterialIcons-Regular.otf')).readAsBytesSync())));
  await icons.load();
  // Roboto has no ⌘, → or Arabic; on a Mac, borrow them from system fonts.
  final fallback = <String>[];
  for (final (family, file) in [('RDSymbols', '/System/Library/Fonts/Apple Symbols.ttf'), ('RDArabic', '/System/Library/Fonts/SFArabic.ttf')]) {
    if (!File(file).existsSync()) continue;
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(file).readAsBytesSync())))).load();
    fallback.add(family);
  }
  if (fallback.isNotEmpty) debugFontFamilyFallback = fallback;
  for (final mono in ['/System/Library/Fonts/SFNSMono.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']) {
    if (File(mono).existsSync()) {
      for (final family in ['Menlo', 'Consolas', 'DejaVu Sans Mono']) {
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(mono).readAsBytesSync())))).load();
      }
      break;
    }
  }
}

AscBuild _build(String n, String state, {String? internal, String? external, String? review, int daysAgo = 1}) => AscBuild(
  id: 'b$n',
  number: n,
  version: '2.4.0',
  platform: 'IOS',
  uploaded: DateTime.now().subtract(Duration(days: daysAgo, hours: 3)),
  expires: DateTime.now().add(Duration(days: 89 - daysAgo)),
  processingState: state,
  expired: false,
  internalState: internal,
  externalState: external,
  reviewState: review,
  groupIds: const ['g1', 'g2'],
);

Future<FakeModel> _seed(Directory dir) async {
  final project = Directory(p.join(dir.path, 'Developer', 'atlas', 'mobile'))..createSync(recursive: true);
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('name: atlas_notes\nversion: 2.4.0+57\n');
  Directory(p.join(project.path, 'android', 'app')).createSync(recursive: true);
  File(p.join(project.path, 'android', 'app', 'build.gradle.kts')).writeAsStringSync('applicationId = "com.example.atlas"\n');

  final store = WorkspaceStore(Directory(p.join(dir.path, 'support')));
  final m = FakeModel(store: store, secrets: MemorySecretStore());
  final apple = Team(
    name: 'Northwind Studio',
    teamId: 'ABCDE12345',
    credential: const Credential.appStoreConnectKey(keyId: 'KEY1234567', issuerId: 'issuer'),
  );
  final google = Team(
    name: 'Play Console',
    credential: const Credential.googleUser(email: 'dev@example.com'),
    packages: ['com.example.atlas'],
  );
  m.workspace
    ..accounts = [
      Account(provider: StoreProvider.apple, name: 'Work Apple ID', teams: [apple]),
      Account(provider: StoreProvider.google, name: 'dev@example.com', email: 'dev@example.com', teams: [google]),
    ]
    ..links = [ProjectLink(appId: '1001', path: project.path), ProjectLink(appId: 'play:com.example.atlas', path: project.path)]
    ..runs = [
      RunRecord(
        id: 'r1',
        appId: '1001',
        appName: 'Atlas Notes',
        version: '2.3.9',
        build: 55,
        started: DateTime.now().subtract(const Duration(days: 2)),
        finished: DateTime.now().subtract(const Duration(days: 2, minutes: -24)),
        outcome: 'succeeded',
      ),
      RunRecord(
        id: 'r2',
        appId: 'play:com.example.atlas',
        appName: 'Atlas Notes',
        version: '2.3.9',
        build: 55,
        started: DateTime.now().subtract(const Duration(days: 3)),
        finished: DateTime.now().subtract(const Duration(days: 3, minutes: -6)),
        outcome: 'failed',
        failedStep: 'Check signing',
      ),
    ];
  final apps = [
    const StoreApp(id: '1001', name: 'Atlas Notes', bundleId: 'com.example.atlas', primaryLocale: 'en-US'),
    const StoreApp(id: '1002', name: 'Pocket Budget', bundleId: 'com.example.budget', primaryLocale: 'ar-SA'),
    const StoreApp(id: '1003', name: 'Trail Maps', bundleId: 'com.example.trails', primaryLocale: 'en-GB'),
    const StoreApp(id: '1004', name: 'Quiet Hours', bundleId: 'com.example.quiet', primaryLocale: 'en-US'),
  ];
  m.teams[apple.id] = TeamState()..apps = apps;
  m.teams[google.id] = TeamState()..apps = [const StoreApp(id: 'play:com.example.atlas', name: 'Atlas Notes', bundleId: 'com.example.atlas')];
  for (final a in apps) {
    m.bindAppToTeam(a.id, apple.id);
  }
  m.bindAppToTeam('play:com.example.atlas', google.id);
  final groups = [
    AscBetaGroup(id: 'g1', name: 'Team', isInternal: true, allBuilds: true, publicLinkEnabled: false, testerCount: 4),
    AscBetaGroup(
      id: 'g2',
      name: 'Public beta',
      isInternal: false,
      allBuilds: false,
      publicLinkEnabled: true,
      publicLink: 'https://testflight.apple.com/join/AbCdEf12',
      testerCount: 128,
    ),
  ];
  m.apps['1001'] = AppState()
    ..detailed = true
    ..builds = [
      _build('57', 'VALUE', internal: 'IN_BETA_TESTING', external: 'WAITING_FOR_BETA_REVIEW', review: 'WAITING_FOR_REVIEW', daysAgo: 0),
      _build('56', 'VALID', internal: 'IN_BETA_TESTING', external: 'IN_BETA_TESTING', review: 'APPROVED', daysAgo: 6),
      _build('55', 'VALID', internal: 'IN_BETA_TESTING', external: 'IN_BETA_TESTING', review: 'APPROVED', daysAgo: 12),
    ]
    ..groups = groups
    ..versions = [
      AscVersion(id: 'v1', version: '2.4', platform: 'IOS', state: 'PREPARE_FOR_SUBMISSION', created: DateTime.now().subtract(const Duration(days: 3))),
      AscVersion(id: 'v2', version: '2.3', platform: 'IOS', state: 'READY_FOR_DISTRIBUTION', created: DateTime.now().subtract(const Duration(days: 40))),
    ];
  m.apps['1002'] = AppState()..builds = [_build('12', 'PROCESSING', daysAgo: 0)];
  m.apps['1003'] = AppState()..builds = [_build('301', 'VALID', internal: 'IN_BETA_TESTING', external: 'BETA_REJECTED', review: 'REJECTED', daysAgo: 20)];
  m.apps['play:com.example.atlas'] = AppState()
    ..detailed = true
    ..play = const PlayAppDetails(title: 'Atlas Notes', defaultLanguage: 'en-US')
    ..tracks = [
      const PlayTrack('internal', [
        PlayRelease(name: '2.4.0 (57)', versionCodes: ['57'], status: 'completed', notes: {'en-US': 'Faster search.'}),
      ]),
      const PlayTrack('alpha', []),
      const PlayTrack('beta', [
        PlayRelease(name: '2.3.9 (55)', versionCodes: ['55'], status: 'inProgress', userFraction: 0.2),
      ]),
      const PlayTrack('production', [
        PlayRelease(name: '2.3.8 (54)', versionCodes: ['54'], status: 'completed'),
      ]),
    ];
  return m;
}

ReleaseRun _run(FakeModel m, Directory dir, RunPhase phase) {
  final plan = ReleasePlan(
    platform: ReleasePlatform.ios,
    app: m.app('1001')!,
    projectRoot: dir.path,
    version: '2.4.0',
    build: 58,
    recipe: Recipe(),
    groups: m.apps['1001']!.groups,
    whatsNew: const {'en-US': 'Faster search.'},
    submitForReview: true,
    cloud: const CloudBuild(GitHubRepo(owner: 'example-org', name: 'atlas-notes', projectDir: 'mobile'), CloudTarget.ios),
  );
  final run = ReleaseRun(plan: plan, logsDir: Directory(p.join(dir.path, 'logs')));
  run.phase = phase;
  run.started = DateTime.now().subtract(const Duration(minutes: 23, seconds: 41));
  if (phase != RunPhase.running) run.finished = DateTime.now();
  final done = switch (phase) {
    RunPhase.succeeded => 7,
    RunPhase.failed => 4,
    _ => 2,
  };
  for (final (i, s) in run.steps.indexed) {
    if (i <= done) s.started = run.started!.add(Duration(minutes: i * 3));
    if (i < done) {
      s.state = StepState.done;
      s.finished = s.started!.add(const Duration(minutes: 2, seconds: 40));
    }
  }
  run.step(StepId.prepare).detail = 'Workflow and secrets are in place';
  run.step(StepId.cloudBuild).detail = 'Built on GitHub and uploaded';
  if (phase == RunPhase.running) {
    run.steps[2].state = StepState.running;
    run.steps[2].detail = 'Processing · 4 min';
    run.current = run.steps[2].id;
  }
  if (phase == RunPhase.failed) {
    run.steps[4].state = const StepState.failed('App Store Connect 409 on /v1/builds/relationships: the group is not ready');
    run.steps[4].finished = DateTime.now();
    run.failure = 'TestFlight groups: the group is not ready';
  }
  for (final (s, k, t) in [
    (StepId.prepare, LogKind.info, 'Release Atlas Notes 2.4.0 (58)'),
    (StepId.prepare, LogKind.success, 'Workflow and secrets are in place'),
    (StepId.cloudBuild, LogKind.info, 'Starting release-desk-ios.yml on example-org/atlas-notes@main'),
    (StepId.cloudBuild, LogKind.output, '▸ Archive'),
    (StepId.cloudBuild, LogKind.success, '✓ Archive 6m 12s'),
    (StepId.cloudBuild, LogKind.warning, 'warning: deprecated API in a plugin'),
    (StepId.processing, LogKind.info, 'State PROCESSING'),
    (StepId.processing, LogKind.success, 'Build b58 is processed'),
    (StepId.groups, LogKind.error, 'Group not ready for the build yet (404), trying again in 60 s'),
  ]) {
    run.log(t, k, s);
  }
  return run;
}

void main() {
  final shots = Platform.environment['RD_SHOTS'];

  setUpAll(() async {
    if (shots != null) await _loadFonts();
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull, reason: name);
    if (shots == null) return;
    final element = find.byType(MaterialApp).evaluate().first;
    final image = await captureImage(element);
    final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
    Directory(shots).createSync(recursive: true);
    File(p.join(shots, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  Future<(FakeModel, Directory)> setUp(WidgetTester tester, {bool empty = false, ThemeMode theme = ThemeMode.dark}) async {
    // RD_SCALE renders sharper shots (2 for videos); RD_PROMO uses a stand-in person and home.
    final scale = double.tryParse(Platform.environment['RD_SCALE'] ?? '') ?? 1.5;
    tester.view.physicalSize = Size(1380 * scale, 880 * scale);
    tester.view.devicePixelRatio = scale;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('rd-ui');
    if (promo) {
      debugHomeOverride = dir.path;
      debugUserNameOverride = 'Nour';
    }
    addTearDown(() => dir.deleteSync(recursive: true));
    final m = empty ? FakeModel(store: WorkspaceStore(Directory(p.join(dir.path, 'support'))), secrets: MemorySecretStore()) : await _seed(dir);
    m.themeMode = theme;
    await tester.pumpWidget(ReleaseDeskApp(model: m));
    return (m, dir);
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  for (final theme in [ThemeMode.dark, ThemeMode.light]) {
    final tag = theme.name;
    testWidgets('pages render ($tag)', (tester) async {
      final (m, dir) = await setUp(tester, theme: theme);
      await shoot(tester, '$tag-01-overview');
      m.go(const AppRoute.app('1001'));
      await shoot(tester, '$tag-02-app');
      m.go(const AppRoute.app('play:com.example.atlas'));
      await shoot(tester, '$tag-03-play');
      m.go(AppRoute.team(m.workspace.accounts.first.teams.first.id));
      await shoot(tester, '$tag-04-team');
      m.go(const AppRoute.ship('1001'));
      if (promo) {
        await tester.pump(const Duration(milliseconds: 600));
        final notes = find.byWidgetPredicate((w) => w is TextField && w.minLines == 6);
        await tester.enterText(notes.at(0), '• بحث أسرع في قائمة الملاحظات\n• إصلاح المشاركة على iPad\n• واجهة الإعدادات بالعربية');
        await tester.enterText(notes.at(1), '• Faster search on the notes list\n• Fix the share sheet on iPad\n• Arabic layout for settings');
        FocusManager.instance.primaryFocus?.unfocus();
      }
      await shoot(tester, '$tag-05-ship-ios');
      m.go(const AppRoute.ship('play:com.example.atlas'));
      await shoot(tester, '$tag-06-ship-play');
      m.go(const AppRoute.activity());
      await shoot(tester, '$tag-07-activity');
      m.privacy = true;
      m.go(const AppRoute.overview());
      await shoot(tester, '$tag-08-privacy');
      m.privacy = false;
      expect(dir.existsSync(), isTrue);
      await tearDownApp(tester);
    });
  }

  testWidgets('launch console in every phase', (tester) async {
    final (m, dir) = await setUp(tester);
    for (final phase in [RunPhase.running, RunPhase.succeeded, RunPhase.failed]) {
      m.runs.add(_run(m, dir, phase));
      m.composing.remove('1001');
      m.go(const AppRoute.ship('1001'));
      await shoot(tester, 'dark-09-console-${phase.name}');
    }
    await tearDownApp(tester);
  });

  testWidgets('welcome, connect and palette', (tester) async {
    final (m, _) = await setUp(tester, empty: true);
    await shoot(tester, 'dark-10-welcome');
    final ctx = tester.element(find.byType(RootView));
    showConnectDialog(ctx, StoreProvider.apple);
    await shoot(tester, 'dark-11-connect-apple');
    await tester.tap(find.text('Google Play').last);
    await shoot(tester, 'dark-12-connect-google');
    Navigator.of(ctx).pop();
    await tester.pump();
    await tearDownApp(tester);
    expect(m.workspace.accounts, isEmpty);
  });

  testWidgets('command palette opens and finds an app', (tester) async {
    final (m, _) = await setUp(tester);
    m.setPalette(true);
    await tester.pump();
    expect(find.byType(CommandPalette), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'ship atlas');
    await shoot(tester, 'dark-13-palette');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(m.route, const AppRoute.ship('1001'));
    expect(m.paletteOpen, isFalse);
    await tearDownApp(tester);
  });
}
