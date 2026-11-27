import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'errors.dart';

enum StoreProvider {
  apple,
  google,
  huawei,
  microsoft;

  String get title => switch (this) {
    StoreProvider.apple => 'Apple',
    StoreProvider.google => 'Google Play',
    StoreProvider.huawei => 'AppGallery',
    StoreProvider.microsoft => 'Microsoft Store',
  };

  /// The prefix of app ids from this store ("" for App Store Connect, whose ids are Apple's).
  String get appPrefix => switch (this) {
    StoreProvider.apple => '',
    StoreProvider.google => 'play:',
    StoreProvider.huawei => 'agc:',
    StoreProvider.microsoft => 'msstore:',
  };

  /// The store an app id belongs to.
  static StoreProvider of(String appId) => values.where((p) => p.appPrefix.isNotEmpty && appId.startsWith(p.appPrefix)).firstOrNull ?? StoreProvider.apple;

  /// Reads the name kept in workspace.json; unknown names are Apple's, as before.
  static StoreProvider named(Object? name) => values.where((p) => p.name == name).firstOrNull ?? StoreProvider.apple;
}

String newId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// How Release Desk reaches a team. The secret part lives in the OS keychain
/// under [secretKey]; only these ids go into workspace.json.
class Credential {
  const Credential.appStoreConnectKey({required String this.keyId, required String this.issuerId})
    : kind = 'appStoreConnectKey',
      email = null,
      clientId = null,
      tenantId = null,
      sellerId = null;
  const Credential.googleUser({required String this.email})
    : kind = 'googleUser',
      keyId = null,
      issuerId = null,
      clientId = null,
      tenantId = null,
      sellerId = null;

  /// AppGallery Connect API client (Connect API, team level); the key is the secret.
  const Credential.agcClient({required String this.clientId})
    : kind = 'agcClient',
      keyId = null,
      issuerId = null,
      email = null,
      tenantId = null,
      sellerId = null;

  /// A Microsoft Entra app added to Partner Center as Manager; the client secret is the secret.
  const Credential.partnerCenter({required String this.tenantId, required String this.clientId, required String this.sellerId})
    : kind = 'partnerCenter',
      keyId = null,
      issuerId = null,
      email = null;

  factory Credential.fromJson(Map<String, Object?> j) => switch (j['kind']) {
    'googleUser' => Credential.googleUser(email: j['email'] as String? ?? ''),
    'agcClient' => Credential.agcClient(clientId: j['clientID'] as String? ?? ''),
    'partnerCenter' => Credential.partnerCenter(
      tenantId: j['tenantID'] as String? ?? '',
      clientId: j['clientID'] as String? ?? '',
      sellerId: j['sellerID'] as String? ?? '',
    ),
    _ => Credential.appStoreConnectKey(keyId: j['keyID'] as String? ?? '', issuerId: j['issuerID'] as String? ?? ''),
  };

  final String kind;
  final String? keyId;
  final String? issuerId;
  final String? email;
  final String? clientId;
  final String? tenantId;
  final String? sellerId;

  StoreProvider get store => switch (kind) {
    'googleUser' => StoreProvider.google,
    'agcClient' => StoreProvider.huawei,
    'partnerCenter' => StoreProvider.microsoft,
    _ => StoreProvider.apple,
  };

  bool get isGoogle => store == StoreProvider.google;

  /// Stores where apps are added by package name when the API can't list them.
  bool get takesPackages => store == StoreProvider.google || store == StoreProvider.huawei;

  String get secretKey => switch (store) {
    StoreProvider.apple => 'asc.$keyId',
    StoreProvider.google => 'google.$email',
    StoreProvider.huawei => 'agc.$clientId',
    StoreProvider.microsoft => 'ms.$clientId',
  };

  String get summary => switch (store) {
    StoreProvider.apple => 'API key $keyId',
    StoreProvider.google => 'Signed in as $email',
    StoreProvider.huawei => 'API client $clientId',
    StoreProvider.microsoft => 'Seller $sellerId',
  };

  Map<String, Object?> toJson() => switch (store) {
    StoreProvider.apple => {'kind': kind, 'keyID': keyId, 'issuerID': issuerId},
    StoreProvider.google => {'kind': kind, 'email': email},
    StoreProvider.huawei => {'kind': kind, 'clientID': clientId},
    StoreProvider.microsoft => {'kind': kind, 'tenantID': tenantId, 'clientID': clientId, 'sellerID': sellerId},
  };

  @override
  bool operator ==(Object other) =>
      other is Credential &&
      other.kind == kind &&
      other.keyId == keyId &&
      other.issuerId == issuerId &&
      other.email == email &&
      other.clientId == clientId &&
      other.tenantId == tenantId &&
      other.sellerId == sellerId;

  @override
  int get hashCode => Object.hash(kind, keyId, issuerId, email, clientId, tenantId, sellerId);
}

/// One developer team (Apple) or developer account (Play).
class Team {
  Team({String? id, required this.name, this.teamId, required this.credential, List<String>? packages}) : id = id ?? newId(), packages = packages ?? [];

  factory Team.fromJson(Map<String, Object?> j) => Team(
    id: j['id'] as String?,
    name: j['name'] as String? ?? '',
    teamId: j['teamID'] as String?,
    credential: Credential.fromJson((j['credential'] as Map?)?.cast<String, Object?>() ?? const {}),
    packages: (j['packages'] as List?)?.whereType<String>().toList(),
  );

  final String id;
  String name;
  String? teamId;
  final Credential credential;

  /// Play and AppGallery apps added by package name (Play has no list of a
  /// developer's apps unless the Reporting API is on; an AppGallery API
  /// client may not read projects).
  List<String> packages;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'teamID': teamId, 'credential': credential.toJson(), 'packages': packages};
}

/// A person's sign-in with a store. It holds the teams that person reaches.
class Account {
  Account({String? id, required this.provider, required this.name, this.email, List<Team>? teams}) : id = id ?? newId(), teams = teams ?? [];

  factory Account.fromJson(Map<String, Object?> j) => Account(
    id: j['id'] as String?,
    provider: StoreProvider.named(j['provider']),
    name: j['name'] as String? ?? '',
    email: j['email'] as String?,
    teams: (j['teams'] as List?)?.whereType<Map>().map((t) => Team.fromJson(t.cast<String, Object?>())).toList(),
  );

  final String id;
  final StoreProvider provider;
  String name;
  String? email;
  List<Team> teams;

  Map<String, Object?> toJson() => {'id': id, 'provider': provider.name, 'name': name, 'email': email, 'teams': teams.map((t) => t.toJson()).toList()};
}

/// What the pipeline follows for one app. Paths are relative to the project.
class Recipe {
  Recipe({
    this.exportOptions = 'ios/ExportOptions.plist',
    this.entitlements = 'ios/Runner/Runner.entitlements',
    this.writeBuildNumber = true,
    List<String>? groupIds,
    this.submitForReview = true,
    List<String>? locales,
    this.appStoreLocales,
    this.playLocales,
    this.androidBuildOn,
    this.playTrack,
    this.playStatus,
    this.agcToo,
    this.msLocales,
    this.msRollout,
    this.windowsBuildOn,
  }) : groupIds = groupIds ?? [],
       locales = locales ?? ['ar-SA', 'en-US'];

  factory Recipe.fromJson(Map<String, Object?> j) => Recipe(
    exportOptions: j['exportOptions'] as String? ?? 'ios/ExportOptions.plist',
    entitlements: j['entitlements'] as String? ?? 'ios/Runner/Runner.entitlements',
    writeBuildNumber: j['writeBuildNumber'] as bool? ?? true,
    groupIds: (j['groupIDs'] as List?)?.whereType<String>().toList(),
    submitForReview: j['submitForReview'] as bool? ?? true,
    locales: (j['locales'] as List?)?.whereType<String>().toList(),
    appStoreLocales: (j['appStoreLocales'] as List?)?.whereType<String>().toList(),
    playLocales: (j['playLocales'] as List?)?.whereType<String>().toList(),
    androidBuildOn: j['androidBuildOn'] as String?,
    playTrack: j['playTrack'] as String?,
    playStatus: j['playStatus'] as String?,
    agcToo: j['agcToo'] as bool?,
    msLocales: (j['msLocales'] as List?)?.whereType<String>().toList(),
    msRollout: (j['msRollout'] as num?)?.toInt(),
    windowsBuildOn: j['windowsBuildOn'] as String?,
  );

  String exportOptions;
  String entitlements;
  bool writeBuildNumber;
  List<String> groupIds;
  bool submitForReview;

  /// Languages of What to Test (TestFlight).
  List<String> locales;

  /// Languages of the App Store version's What's New; null means the same as [locales].
  List<String>? appStoreLocales;

  /// Languages of a Google Play release's What's new; null means English and Arabic.
  List<String>? playLocales;

  /// The App Store What's New languages in effect.
  List<String> get appStoreLocalesOrDefault => appStoreLocales ?? locales;

  /// The Play What's new languages in effect.
  List<String> get playLocalesOrDefault => playLocales ?? ['en-US', 'ar'];

  /// Android: "github" to build on GitHub Actions instead of this computer.
  String? androidBuildOn;

  /// Android: the track and status used last time.
  String? playTrack;
  String? playStatus;

  /// A Google Play app whose builds also go to AppGallery.
  bool? agcToo;

  /// Languages of a Microsoft Store release's What's new (listing keys like en-us).
  List<String>? msLocales;

  /// Microsoft Store package rollout percentage used last time (0 = everyone).
  int? msRollout;

  /// Windows: "github" to build the MSIX on GitHub Actions instead of this
  /// computer (only Windows can build it here).
  String? windowsBuildOn;

  Recipe copy() => Recipe.fromJson(toJson());

  Map<String, Object?> toJson() => {
    'exportOptions': exportOptions,
    'entitlements': entitlements,
    'writeBuildNumber': writeBuildNumber,
    'groupIDs': groupIds,
    'submitForReview': submitForReview,
    'locales': locales,
    'appStoreLocales': appStoreLocales,
    'playLocales': playLocales,
    'androidBuildOn': androidBuildOn,
    'playTrack': playTrack,
    'playStatus': playStatus,
    'agcToo': agcToo,
    'msLocales': msLocales,
    'msRollout': msRollout,
    'windowsBuildOn': windowsBuildOn,
  };
}

/// A store app tied to the source folder it is built from.
class ProjectLink {
  ProjectLink({String? id, required this.appId, required this.path, Recipe? recipe}) : id = id ?? newId(), recipe = recipe ?? Recipe();

  factory ProjectLink.fromJson(Map<String, Object?> j) => ProjectLink(
    id: j['id'] as String?,
    appId: j['appID'] as String? ?? '',
    path: j['path'] as String? ?? '',
    recipe: Recipe.fromJson((j['recipe'] as Map?)?.cast<String, Object?>() ?? const {}),
  );

  final String id;
  final String appId;
  String path;
  Recipe recipe;

  Map<String, Object?> toJson() => {'id': id, 'appID': appId, 'path': path, 'kind': 'flutter', 'recipe': recipe.toJson()};
}

class RunRecord {
  RunRecord({
    required this.id,
    required this.appId,
    required this.appName,
    required this.version,
    required this.build,
    required this.started,
    this.finished,
    required this.outcome,
    this.failedStep,
    this.logPath,
  });

  factory RunRecord.fromJson(Map<String, Object?> j) => RunRecord(
    id: j['id'] as String? ?? newId(),
    appId: j['appID'] as String? ?? '',
    appName: j['appName'] as String? ?? '',
    version: j['version'] as String? ?? '',
    build: (j['build'] as num?)?.toInt() ?? 0,
    started: DateTime.tryParse(j['started'] as String? ?? '') ?? DateTime.now(),
    finished: DateTime.tryParse(j['finished'] as String? ?? ''),
    outcome: j['outcome'] as String? ?? 'failed',
    failedStep: j['failedStep'] as String?,
    logPath: j['logPath'] as String?,
  );

  final String id;
  final String appId;
  final String appName;
  final String version;
  final int build;
  final DateTime started;
  final DateTime? finished;

  /// succeeded, rehearsed, failed or cancelled.
  final String outcome;
  final String? failedStep;
  final String? logPath;

  Map<String, Object?> toJson() => {
    'id': id,
    'appID': appId,
    'appName': appName,
    'version': version,
    'build': build,
    'started': started.toUtc().toIso8601String(),
    'finished': finished?.toUtc().toIso8601String(),
    'outcome': outcome,
    'failedStep': failedStep,
    'logPath': logPath,
  };
}

/// Accounts, teams, project links and run history: everything but secrets.
class Workspace {
  Workspace({List<Account>? accounts, List<ProjectLink>? links, List<RunRecord>? runs}) : accounts = accounts ?? [], links = links ?? [], runs = runs ?? [];

  factory Workspace.fromJson(Map<String, Object?> j) => Workspace(
    accounts: (j['accounts'] as List?)?.whereType<Map>().map((a) => Account.fromJson(a.cast<String, Object?>())).toList(),
    links: (j['links'] as List?)?.whereType<Map>().map((l) => ProjectLink.fromJson(l.cast<String, Object?>())).toList(),
    runs: (j['runs'] as List?)?.whereType<Map>().map((r) => RunRecord.fromJson(r.cast<String, Object?>())).toList(),
  );

  List<Account> accounts;
  List<ProjectLink> links;
  List<RunRecord> runs;

  ProjectLink? link(String appId) {
    for (final l in links) {
      if (l.appId == appId) return l;
    }
    return null;
  }

  ({Account account, Team team})? team(String id) {
    for (final a in accounts) {
      for (final t in a.teams) {
        if (t.id == id) return (account: a, team: t);
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'accounts': accounts.map((a) => a.toJson()).toList(),
    'links': links.map((l) => l.toJson()).toList(),
    'runs': runs.map((r) => r.toJson()).toList(),
  };
}

/// Where Release Desk keeps its files:
/// Windows `%APPDATA%\Release Desk`, Linux `~/.config/release-desk`,
/// macOS the app's own Application Support folder.
class WorkspaceStore {
  WorkspaceStore(this.folder);

  final Directory folder;

  static Future<WorkspaceStore> standard() async {
    final env = Platform.environment;
    Directory dir;
    if (Platform.isWindows && (env['APPDATA'] ?? '').isNotEmpty) {
      dir = Directory(p.join(env['APPDATA']!, 'Release Desk'));
    } else if (Platform.isLinux) {
      final xdg = env['XDG_CONFIG_HOME'];
      dir = Directory(p.join(xdg != null && xdg.isNotEmpty ? xdg : p.join(env['HOME'] ?? '.', '.config'), 'release-desk'));
    } else {
      dir = await getApplicationSupportDirectory();
    }
    await dir.create(recursive: true);
    return WorkspaceStore(dir);
  }

  File get _workspaceFile => File(p.join(folder.path, 'workspace.json'));
  File get _settingsFile => File(p.join(folder.path, 'settings.json'));
  Directory get logs => Directory(p.join(folder.path, 'Logs'));

  Workspace load() {
    try {
      final f = _workspaceFile;
      if (!f.existsSync()) return Workspace();
      return Workspace.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>());
    } catch (_) {
      return Workspace();
    }
  }

  void save(Workspace ws) => _writeAtomic(_workspaceFile, const JsonEncoder.withIndent('  ').convert(ws.toJson()));

  /// Small preferences (privacy mode, theme, icon templates, note drafts).
  Map<String, Object?> loadSettings() {
    try {
      final f = _settingsFile;
      return f.existsSync() ? (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>() : {};
    } catch (_) {
      return {};
    }
  }

  void saveSettings(Map<String, Object?> s) => _writeAtomic(_settingsFile, const JsonEncoder.withIndent('  ').convert(s));

  void _writeAtomic(File f, String text) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(f.path);
  }
}

/// Secrets: App Store Connect keys, Google sign-ins, AppGallery and Partner
/// Center client secrets, the OAuth client and a GitHub token. Kept in the OS keychain, never in workspace.json.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// DPAPI on Windows, libsecret on Linux, the Keychain on macOS.
class OsSecretStore implements SecretStore {
  OsSecretStore() : _storage = const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false, accountName: 'app.releasedesk.desktop'));

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      throw ReleaseError.storage('Could not read from the system keychain: ${describeError(e)}');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      throw ReleaseError.storage('Could not save to the system keychain: ${describeError(e)}');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
