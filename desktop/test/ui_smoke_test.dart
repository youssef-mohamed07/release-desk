// Renders every screen with made-up data and fails on any layout or build
// error. With RD_SHOTS=<folder> it also writes a PNG of each screen there.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide StepState;
import 'package:path/path.dart' as p;
import 'package:release_desk/src/core/app_gallery.dart';
import 'package:release_desk/src/core/asc.dart';
import 'package:release_desk/src/core/flutter_project.dart';
import 'package:release_desk/src/core/github.dart';
import 'package:release_desk/src/core/microsoft_store.dart';
import 'package:release_desk/src/core/play.dart';
import 'package:release_desk/src/ui/theme.dart' show ToggleRow, debugFontFamilyFallback, debugHomeOverride;
import 'package:release_desk/src/ui/overview.dart' show debugUserNameOverride;
import 'package:release_desk/src/core/release_run.dart';
import 'package:release_desk/src/core/workspace.dart';
import 'package:release_desk/src/ui/app_model.dart';
import 'package:release_desk/src/ui/command_palette.dart';
import 'package:release_desk/src/ui/connect.dart';
import 'package:release_desk/src/ui/root.dart';
import 'package:release_desk/src/ui/ship.dart' show debugOnWindows;

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
  Future<List<({String package, String name})>> verifyAppGallery(String clientId, String secret, List<String> packages) async => [
    (package: 'com.example.atlas', name: 'Atlas Notes'),
  ];

  @override
  Future<List<MsApp>> verifyMicrosoft(String tenantId, String clientId, String secret) async => [
    MsApp(id: '9NBLGGH4R315', name: 'Atlas Notes', packageIdentityName: 'Example.AtlasNotes'),
  ];

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
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('name: atlas_notes\nversion: 2.4.0+57\n\nmsix_config:\n  msstore_appId: 9NBLGGH4R315\n');
  Directory(p.join(project.path, 'windows')).createSync();
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
  final huawei = Team(
    name: 'AppGallery',
    credential: const Credential.agcClient(clientId: '1234567890123456789'),
    packages: ['com.example.atlas'],
  );
  final microsoft = Team(
    name: 'Northwind Store',
    teamId: '12345678',
    credential: const Credential.partnerCenter(tenantId: 'tenant', clientId: 'client', sellerId: '12345678'),
  );
  m.workspace
    ..accounts = [
      Account(provider: StoreProvider.apple, name: 'Work Apple ID', teams: [apple]),
      Account(provider: StoreProvider.google, name: 'dev@example.com', email: 'dev@example.com', teams: [google]),
      Account(provider: StoreProvider.huawei, name: 'Huawei developer account', teams: [huawei]),
      Account(provider: StoreProvider.microsoft, name: 'Partner Center', teams: [microsoft]),
    ]
    ..links = [
      ProjectLink(appId: '1001', path: project.path),
      ProjectLink(appId: 'play:com.example.atlas', path: project.path),
      ProjectLink(appId: 'agc:com.example.atlas', path: project.path),
      ProjectLink(appId: 'msstore:9NBLGGH4R315', path: project.path),
    ]
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
  m.teams[huawei.id] = TeamState()..apps = [const StoreApp(id: 'agc:com.example.atlas', name: 'Atlas Notes', bundleId: 'com.example.atlas')];
  m.bindAppToTeam('agc:com.example.atlas', huawei.id);
  m.agcAppIds['agc:com.example.atlas'] = '101234567';
  m.teams[microsoft.id] = TeamState()..apps = [const StoreApp(id: 'msstore:9NBLGGH4R315', name: 'Atlas Notes', bundleId: 'Example.AtlasNotes')];
  m.bindAppToTeam('msstore:9NBLGGH4R315', microsoft.id);
  m.apps['agc:com.example.atlas'] = AppState()
    ..detailed = true
    ..agc = const AgcApp(
      appId: '101234567',
      package: 'com.example.atlas',
      name: 'Atlas Notes',
      version: '2.4.0',
      versionOnShelf: '2.3.9',
      releaseState: 5,
      reviewNote: 'Add a screenshot of the Arabic layout.',
      newFeatures: {'en-US': 'Faster search on the notes list.', 'ar': 'بحث أسرع في قائمة الملاحظات.'},
    );
  m.apps['msstore:9NBLGGH4R315'] = AppState()
    ..detailed = true
    ..ms = MsApp(
      id: '9NBLGGH4R315',
      name: 'Atlas Notes',
      packageIdentityName: 'Example.AtlasNotes',
      firstPublished: DateTime.utc(2025, 3, 1),
      lastSubmissionId: '1152921504621243619',
      pendingSubmissionId: '1152921504621243620',
      lastStatus: 'Published',
      pendingStatus: 'PendingCommit',
      listingLanguages: ['ar-sa', 'en-us'],
      releaseNotes: {'en-us': 'Faster search on the notes list.'},
    );
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
  final groups = run.steps.indexOf(run.step(StepId.groups));
  final done = switch (phase) {
    RunPhase.succeeded => run.steps.length,
    RunPhase.failed => groups,
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
    run.steps[groups].state = const StepState.failed('App Store Connect 409 on /v1/builds/relationships: the group is not ready');
    run.steps[groups].finished = DateTime.now();
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

String jsonEncodeWorkspace(AppModel m) => jsonEncode(m.workspace.toJson());

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
      expect(find.text('What to Test'), findsOneWidget);
      expect(find.text("App Store What's New"), findsOneWidget);
      expect(find.text('Language'), findsNWidgets(2));
      m.go(const AppRoute.ship('play:com.example.atlas'));
      await shoot(tester, '$tag-06-ship-play');
      expect(find.text("What's new"), findsOneWidget);
      expect(find.textContaining('Production included'), findsOneWidget);
      m.go(const AppRoute.activity());
      await shoot(tester, '$tag-07-activity');
      m.go(const AppRoute.app('agc:com.example.atlas'));
      await shoot(tester, '$tag-14-appgallery');
      expect(find.text('Update in review'), findsWidgets);
      expect(find.text('Review notes'), findsOneWidget);
      expect(find.text('Arabic  ·  ar'), findsOneWidget);
      m.go(const AppRoute.app('msstore:9NBLGGH4R315'));
      await shoot(tester, '$tag-15-microsoft');
      expect(find.text('Listing languages'), findsOneWidget);
      expect(find.text('Published submission'), findsOneWidget);
      m.go(const AppRoute.ship('agc:com.example.atlas'));
      await shoot(tester, '$tag-16-ship-appgallery');
      expect(find.text('Huawei AppGallery'), findsOneWidget);
      expect(find.text('After review'), findsOneWidget);
      expect(find.textContaining('Play Internal · Full rollout + AppGallery review'), findsOneWidget);
      m.go(const AppRoute.ship('msstore:9NBLGGH4R315'));
      await shoot(tester, '$tag-17-ship-windows');
      expect(find.text('msix_config in pubspec.yaml'), findsOneWidget);
      expect(find.text('Build on GitHub'), findsOneWidget);
      expect(find.text('This computer'), findsNothing);
      expect(find.textContaining('Secrets MS_TENANT_ID'), findsOneWidget);
      expect(find.text('Set from Partner Center'), findsOneWidget);
      m.privacy = true;
      m.go(const AppRoute.overview());
      await shoot(tester, '$tag-08-privacy');
      m.privacy = false;
      expect(dir.existsSync(), isTrue);
      await tearDownApp(tester);
    });
  }

  testWidgets('ship notes pick their languages', (tester) async {
    final (m, _) = await setUp(tester);
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    }

    Future<void> tap(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
      await settle();
    }

    final rtl = find.byWidgetPredicate((w) => w is TextField && w.textDirection == TextDirection.rtl);
    final boxes = find.byWidgetPredicate((w) => w is TextField && w.minLines == 6);
    Recipe recipe(String id) => m.workspace.link(id)!.recipe;

    // iOS: What to Test and the App Store card, both in Arabic and English.
    m.go(const AppRoute.ship('1001'));
    await settle();
    expect(find.text('Arabic (Saudi Arabia)'), findsNWidgets(2));
    expect(rtl, findsNWidgets(2));
    expect(boxes, findsNWidgets(4));
    await tap(find.text('Language').last);
    await tap(find.text('Catalan  ·  ca'));
    expect(recipe('1001').appStoreLocales, ['ar-SA', 'en-US', 'ca']);
    expect(recipe('1001').locales, ['ar-SA', 'en-US']);
    expect(boxes, findsNWidgets(5));
    await tester.enterText(boxes.at(4), 'Nova cerca.');
    await tester.pump();
    expect(m.draft('store.1001'), {'ca': 'Nova cerca.'});
    expect(m.draft('1001'), isEmpty);
    expect(find.text('11/4000'), findsOneWidget);
    await tap(find.byTooltip('Remove Catalan'));
    expect(recipe('1001').appStoreLocales, ['ar-SA', 'en-US']);
    expect(boxes, findsNWidgets(4));

    // Play: English and Arabic until another language is picked.
    m.go(const AppRoute.ship('play:com.example.atlas'));
    await settle();
    expect(recipe('play:com.example.atlas').playLocales, isNull);
    expect(find.text('Arabic'), findsOneWidget);
    expect(rtl, findsOneWidget);
    await tap(find.text('Language'));
    await tap(find.text('Afrikaans  ·  af'));
    expect(recipe('play:com.example.atlas').playLocales, ['en-US', 'ar', 'af']);
    await tester.enterText(boxes.at(2), 'x' * 501);
    await tester.pump();
    expect((tester.widget(find.text('501/500')) as Text).style?.color, Colors.orange);
    await tap(find.byTooltip('Remove Arabic'));
    expect(recipe('play:com.example.atlas').playLocales, ['en-US', 'af']);
    expect(rtl, findsNothing);
    await tearDownApp(tester);
  });

  testWidgets('the Android Ship screen sends one build to Play, AppGallery or both', (tester) async {
    final (m, _) = await setUp(tester);
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    }

    final agcSwitch = find.descendant(of: find.widgetWithText(ToggleRow, 'Huawei AppGallery'), matching: find.byType(Switch));
    final playSwitch = find.descendant(of: find.widgetWithText(ToggleRow, 'Google Play'), matching: find.byType(Switch));
    // Scrolls a control to the middle, clear of the floating launch bar, and taps it.
    Future<void> tapInView(Finder f) async {
      await Scrollable.ensureVisible(tester.element(f.first), alignment: 0.4);
      await tester.pump();
      await tester.tap(f.first);
      await settle();
    }

    // From the Play page, AppGallery is off until it is turned on, and then stays on.
    m.go(const AppRoute.ship('play:com.example.atlas'));
    await settle();
    expect(find.text('After review'), findsNothing);
    await tapInView(agcSwitch);
    expect(find.text('After review'), findsOneWidget);
    expect(find.textContaining('Play Internal · Full rollout + AppGallery review'), findsOneWidget);
    await tapInView(playSwitch);
    expect(find.text('Track'), findsNothing);
    expect(find.text('Use a version code above the last one on the store.'), findsOneWidget);
    expect(find.textContaining('Upload → AppGallery review'), findsOneWidget);
    await tapInView(find.text('Phased'));
    expect(find.text('Over 7 days'), findsOneWidget);
    expect(find.textContaining('AppGallery review · phased 10%'), findsOneWidget);
    await tapInView(agcSwitch);
    expect(find.textContaining('Choose a store'), findsOneWidget);
    await tearDownApp(tester);
  });

  testWidgets('the Windows Ship screen builds here on Windows', (tester) async {
    debugOnWindows = true;
    addTearDown(() => debugOnWindows = null);
    final (m, _) = await setUp(tester);
    m.go(const AppRoute.ship('msstore:9NBLGGH4R315'));
    await shoot(tester, 'dark-20-ship-windows-local');
    expect(find.text('This computer'), findsOneWidget);
    expect(find.text('msstore reconfigure'), findsOneWidget);
    expect(find.text('Install the Microsoft Store CLI'), findsOneWidget);
    expect(find.textContaining('MSIX build → submission → certification'), findsOneWidget);
    expect(find.text(' 2.4.0.0'), findsOneWidget);
    await Scrollable.ensureVisible(tester.element(find.text('Gradual')), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('Gradual'));
    await tester.pump();
    expect(find.textContaining('certification · 10%'), findsOneWidget);
    await Scrollable.ensureVisible(tester.element(find.text('GitHub Actions')), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('GitHub Actions'));
    await shoot(tester, 'dark-21-ship-windows-github');
    expect(find.text('msstore reconfigure'), findsNothing);
    expect(find.text('Set from Partner Center'), findsOneWidget);
    expect(m.workspace.link('msstore:9NBLGGH4R315')!.recipe.windowsBuildOn, 'github');
    await tearDownApp(tester);
  });

  testWidgets('AppGallery and Partner Center connect through the form', (tester) async {
    final (m, _) = await setUp(tester, empty: true);
    final ctx = tester.element(find.byType(RootView));
    Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
    Future<void> type(String hint, String text) async {
      await tester.ensureVisible(field(hint));
      await tester.enterText(field(hint), text);
      await tester.pump();
    }

    Future<void> press(String label) async {
      await tester.ensureVisible(find.text(label).last);
      await tester.tap(find.text(label).last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    showConnectDialog(ctx, StoreProvider.huawei);
    await shoot(tester, 'dark-18-connect-appgallery');
    expect(find.text('AppGallery Connect API client'), findsOneWidget);
    await type('e.g. 1234567890123456789', '1234567890123456789');
    await type('Key', 'agc-secret');
    await type('com.example.app, com.example.other', 'com.example.atlas');
    await type('e.g. Huawei developer account', 'Huawei developer account');
    await type('e.g. Client team', 'AppGallery');
    await press('Verify');
    expect(find.text('It works · 1 app'), findsOneWidget);
    expect(find.text('Atlas Notes · com.example.atlas'), findsOneWidget);
    await press('Connect');
    expect(m.workspace.accounts.single.provider, StoreProvider.huawei);
    final agc = m.workspace.accounts.single.teams.single;
    expect(agc.credential, const Credential.agcClient(clientId: '1234567890123456789'));
    expect(agc.packages, ['com.example.atlas']);
    expect(await (m.secrets as MemorySecretStore).read('agc.1234567890123456789'), 'agc-secret');
    expect(jsonEncodeWorkspace(m), isNot(contains('agc-secret')));

    showConnectDialog(ctx, StoreProvider.microsoft);
    await shoot(tester, 'dark-19-connect-microsoft');
    expect(find.text('Seller ID'), findsOneWidget);
    // Verify waits for every field.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Verify')).onPressed, isNull);
    final ids = field('xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx');
    await tester.ensureVisible(ids.first);
    await tester.enterText(ids.first, 'tenant-1');
    await tester.enterText(ids.last, 'client-1');
    await type('Client secret', 'ms-secret');
    await type('e.g. 12345678', '87654321');
    await type('e.g. Partner Center', 'Partner Center');
    await type('e.g. Client team', 'Northwind Store');
    await press('Verify');
    expect(find.text('It works · 1 app'), findsOneWidget);
    await press('Connect');
    final ms = m.workspace.accounts.last.teams.single;
    expect(m.workspace.accounts.last.provider, StoreProvider.microsoft);
    expect(ms.credential, const Credential.partnerCenter(tenantId: 'tenant-1', clientId: 'client-1', sellerId: '87654321'));
    expect(ms.teamId, '87654321');
    expect(await (m.secrets as MemorySecretStore).read('ms.client-1'), 'ms-secret');
    expect(jsonEncodeWorkspace(m), isNot(contains('ms-secret')));
    await tearDownApp(tester);
  });

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
    await tester.tap(find.text('AppGallery').last);
    await tester.pump();
    expect(find.text('AppGallery Connect API client'), findsOneWidget);
    await tester.tap(find.text('Microsoft Store').last);
    await tester.pump();
    expect(find.text('Partner Center'), findsWidgets);
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
