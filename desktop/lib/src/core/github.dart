import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'http_util.dart';
import 'json.dart';
import 'shell.dart';

/// Where a project lives on GitHub, read from its git remote.
class GitHubRepo {
  const GitHubRepo({required this.owner, required this.name, required this.projectDir});

  final String owner;
  final String name;

  /// The Flutter project folder relative to the repository root ("." when it is the root).
  final String projectDir;

  String get fullName => '$owner/$name';
  String get actionsUrl => 'https://github.com/$fullName/actions';

  /// Parses `owner/name` out of a git remote URL.
  static ({String owner, String name})? parseRemote(String remote) {
    final m = RegExp(r'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$').firstMatch(remote.trim());
    if (m == null) return null;
    return (owner: m.group(1)!, name: m.group(2)!);
  }

  /// Reads `origin` of the repository that holds [projectRoot].
  static Future<GitHubRepo?> detect(String projectRoot) async {
    try {
      final remote = await Shell.capture('git', ['-C', projectRoot, 'remote', 'get-url', 'origin']);
      final top = (await Shell.capture('git', ['-C', projectRoot, 'rev-parse', '--show-toplevel'])).trim();
      final r = parseRemote(remote.trim());
      if (r == null) return null;
      final rootPath = _canonical(top);
      final projPath = _canonical(projectRoot);
      var rel = p.isWithin(rootPath, projPath) ? p.relative(projPath, from: rootPath) : '.';
      rel = rel.replaceAll(r'\', '/');
      return GitHubRepo(owner: r.owner, name: r.name, projectDir: rel.isEmpty ? '.' : rel);
    } catch (_) {
      return null;
    }
  }

  /// The repository root on disk for a project at [projectRoot].
  String repoRoot(String projectRoot) {
    var root = projectRoot;
    if (projectDir != '.') {
      for (var i = 0; i < projectDir.split('/').length; i++) {
        root = p.dirname(root);
      }
    }
    return root;
  }

  static String _canonical(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return p.normalize(path);
    }
  }
}

class WorkflowRun {
  const WorkflowRun({required this.id, required this.status, this.conclusion, required this.htmlUrl, required this.title});

  factory WorkflowRun.fromJson(J j) => WorkflowRun(
    id: j['id'].integer ?? 0,
    status: j['status'].string ?? '?',
    conclusion: j['conclusion'].string,
    htmlUrl: j['html_url'].string ?? '',
    title: j['display_title'].string ?? '',
  );

  final int id;
  final String status;
  final String? conclusion;
  final String htmlUrl;
  final String title;
}

class WorkflowStep {
  const WorkflowStep({required this.name, required this.status, this.conclusion, this.started, this.completed});
  final String name;
  final String status;
  final String? conclusion;
  final DateTime? started;
  final DateTime? completed;
}

/// GitHub REST calls Release Desk needs for cloud builds. Signs in with the
/// GitHub CLI's token (`gh auth token`) or a token saved in secure storage.
class GitHubClient {
  GitHubClient({required this.savedToken, http.Client? client}) : _http = client ?? http.Client();

  /// Reads a token saved in Release Desk (secure storage), if any.
  final Future<String?> Function() savedToken;
  final http.Client _http;
  String? _token;

  static const secretKey = 'github-token';

  void forgetToken() => _token = null;

  /// The token, from secure storage or the GitHub CLI.
  Future<String> authToken() async {
    if (_token != null) return _token!;
    final saved = await savedToken();
    if (saved != null && saved.trim().isNotEmpty) return _token = saved.trim();
    try {
      final t = (await Shell.capture('gh', ['auth', 'token'])).trim();
      if (t.isNotEmpty && !t.contains(' ')) return _token = t;
    } catch (_) {}
    throw const ReleaseError.precondition('Release Desk needs GitHub: sign in with the GitHub CLI (gh auth login) or save a token in Release Desk.');
  }

  /// The signed-in GitHub user, to show who Release Desk acts as.
  Future<String> login() async => (await send('GET', '/user'))['login'].string ?? '?';

  Future<J> send(String method, String path, {Object? body, String accept = 'application/vnd.github+json'}) async {
    final url = Uri.parse(path.startsWith('https://') ? path : 'https://api.github.com$path');
    final req = http.Request(method, url)
      ..headers['Authorization'] = 'Bearer ${await authToken()}'
      ..headers['Accept'] = accept
      ..headers['X-GitHub-Api-Version'] = '2022-11-28'
      ..headers['User-Agent'] = userAgent;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 60)));
    } catch (e) {
      throw ReleaseError.network(describeError(e));
    }
    final json = J.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      if (r.statusCode == 401) _token = null;
      throw ReleaseError.api(r.statusCode, 'github.com$path', [json['message'].string ?? 'GitHub said no']);
    }
    return json;
  }

  Future<String> defaultBranch(GitHubRepo repo) async => (await send('GET', '/repos/${repo.fullName}'))['default_branch'].string ?? 'main';

  /// Whether the workflow is on the default branch (needed to run it).
  Future<bool> hasWorkflow(GitHubRepo repo, String file) async {
    try {
      await send('GET', '/repos/${repo.fullName}/actions/workflows/$file');
      return true;
    } on ReleaseError catch (e) {
      if (e.status == 404) return false;
      rethrow;
    }
  }

  /// Names of the repository's Actions secrets.
  Future<Set<String>> secretsPresent(GitHubRepo repo) async {
    final r = await send('GET', '/repos/${repo.fullName}/actions/secrets?per_page=100');
    return r['secrets'].list.map((s) => s['name'].string).whereType<String>().toSet();
  }

  /// Sets an Actions secret with the GitHub CLI, which encrypts it for the
  /// repository. The value goes through stdin, never the command line.
  Future<void> setSecret(String name, String value, GitHubRepo repo) async {
    final out = <String>[];
    final code = await Shell.run('gh', ['secret', 'set', name, '--repo', repo.fullName], stdin: utf8.encode(value), onLine: out.add);
    if (code != 0) throw ReleaseError.command('gh secret set $name', code, out.reversed.take(3).toList().reversed.join('\n'));
  }

  /// Starts the workflow; returns once GitHub lists the run.
  Future<WorkflowRun> dispatch(
    GitHubRepo repo,
    String file, {
    required String ref,
    required Map<String, String> inputs,
    required String marker,
    CancelToken? cancel,
  }) async {
    final started = DateTime.now();
    await send('POST', '/repos/${repo.fullName}/actions/workflows/$file/dispatches', body: {'ref': ref, 'inputs': inputs});
    for (var i = 0; i < 40; i++) {
      await (cancel ?? CancelToken()).sleep(const Duration(seconds: 3));
      final r = await send('GET', '/repos/${repo.fullName}/actions/workflows/$file/runs?event=workflow_dispatch&per_page=10');
      for (final run in r['workflow_runs'].list) {
        if ((run['display_title'].string ?? '').contains(marker)) return WorkflowRun.fromJson(run);
      }
      if (DateTime.now().difference(started).inSeconds > 120) break;
    }
    throw const ReleaseError.precondition('GitHub accepted the run but did not list it. Check the Actions tab.');
  }

  Future<WorkflowRun> run(GitHubRepo repo, int id) async => WorkflowRun.fromJson(await send('GET', '/repos/${repo.fullName}/actions/runs/$id'));

  Future<({int? jobId, List<WorkflowStep> steps})> steps(GitHubRepo repo, int runId) async {
    final r = await send('GET', '/repos/${repo.fullName}/actions/runs/$runId/jobs');
    final job = r['jobs'][0];
    if (job.isNull) return (jobId: null, steps: const <WorkflowStep>[]);
    return (
      jobId: job['id'].integer,
      steps: job['steps'].list
          .map(
            (s) => WorkflowStep(
              name: s['name'].string ?? '?',
              status: s['status'].string ?? '?',
              conclusion: s['conclusion'].string,
              started: s['started_at'].date,
              completed: s['completed_at'].date,
            ),
          )
          .toList(),
    );
  }

  /// The last lines of a job's log, for when a step fails.
  Future<List<String>> logTail(GitHubRepo repo, int jobId, {int lines = 40}) async {
    try {
      final r = await getFollowingRedirectWithoutAuth(_http, Uri.parse('https://api.github.com/repos/${repo.fullName}/actions/jobs/$jobId/logs'), {
        'Authorization': 'Bearer ${await authToken()}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': userAgent,
      });
      if (r.statusCode != 200) return const [];
      final all = utf8.decode(r.bodyBytes, allowMalformed: true).split('\n');
      final stamp = RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ');
      // Drop the timestamp GitHub puts in front of every line.
      return all.skip(all.length > lines ? all.length - lines : 0).map((l) => l.replaceFirst(stamp, '').trimRight()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Downloads a run's artifact zip and unpacks it into [dir]; returns the
  /// files it held.
  Future<List<File>> downloadArtifact(GitHubRepo repo, int runId, String name, Directory dir) async {
    final list = await send('GET', '/repos/${repo.fullName}/actions/runs/$runId/artifacts');
    String? url;
    for (final a in list['artifacts'].list) {
      if (a['name'].string == name) url = a['archive_download_url'].string;
    }
    if (url == null) throw ReleaseError.precondition('The run has no $name artifact.');
    final r = await getFollowingRedirectWithoutAuth(_http, Uri.parse(url), {
      'Authorization': 'Bearer ${await authToken()}',
      'Accept': 'application/vnd.github+json',
      'User-Agent': userAgent,
    });
    if (r.statusCode != 200) throw const ReleaseError.precondition('GitHub did not send the artifact.');
    await dir.create(recursive: true);
    await File(p.join(dir.path, '$name.zip')).writeAsBytes(r.bodyBytes);
    return unzipTo(r.bodyBytes, dir);
  }

  /// Unpacks a zip, refusing entries that would land outside [dir].
  static List<File> unzipTo(List<int> zip, Directory dir) {
    final archive = ZipDecoder().decodeBytes(zip);
    final out = <File>[];
    final base = p.normalize(dir.absolute.path);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final target = p.normalize(p.join(base, entry.name));
      if (!p.isWithin(base, target)) continue;
      final f = File(target);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(entry.content);
      out.add(f);
    }
    return out;
  }

  Future<void> cancel(GitHubRepo repo, int runId) async {
    try {
      await send('POST', '/repos/${repo.fullName}/actions/runs/$runId/cancel');
    } catch (_) {}
  }

  void close() => _http.close();
}

/// The cloud builds Release Desk can run on GitHub Actions. The file names,
/// inputs, secrets and artifact are the same as the macOS app's, so both
/// write identical workflows.
enum CloudTarget {
  ios,
  android,
  windows;

  String get workflowFile => switch (this) {
    CloudTarget.ios => 'release-desk-ios.yml',
    CloudTarget.android => 'release-desk-android.yml',
    CloudTarget.windows => 'release-desk-windows.yml',
  };

  /// The runner GitHub starts, in words.
  String get runner => switch (this) {
    CloudTarget.ios => 'macOS',
    CloudTarget.android => 'Linux',
    CloudTarget.windows => 'Windows',
  };

  List<String> get secretNames => switch (this) {
    CloudTarget.ios => const ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY'],
    CloudTarget.android => const ['ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD'],
    CloudTarget.windows => const ['MS_TENANT_ID', 'MS_SELLER_ID', 'MS_CLIENT_ID', 'MS_CLIENT_SECRET'],
  };

  /// The artifact the Android workflow leaves for Release Desk to upload to Play.
  static const androidArtifact = 'release-desk-aab';

  String yaml({
    required String projectDir,
    String exportOptions = 'ios/ExportOptions.plist',
    String entitlements = 'ios/Runner/Runner.entitlements',
    String? teamId,
    String? flutterVersion,
  }) => switch (this) {
    CloudTarget.ios => CloudWorkflow.iosYaml(
      projectDir: projectDir,
      exportOptions: exportOptions,
      entitlements: entitlements,
      teamId: teamId,
      flutterVersion: flutterVersion,
    ),
    CloudTarget.android => CloudWorkflow.androidYaml(projectDir: projectDir, flutterVersion: flutterVersion),
    CloudTarget.windows => CloudWorkflow.windowsYaml(projectDir: projectDir, flutterVersion: flutterVersion),
  };
}

/// The workflows Release Desk adds to a project, ported line for line from
/// the macOS app (Sources/ReleaseKit/GitHub.swift).
class CloudWorkflow {
  static String _flutter(String? version) => version != null ? '          flutter-version: $version' : '          channel: stable';

  /// Builds a signed app bundle on a GitHub Linux runner and leaves it as an
  /// artifact; Release Desk downloads it and releases it on Play itself, so
  /// no Google credential goes to GitHub.
  static String androidYaml({required String projectDir, String? flutterVersion}) => _android
      .replaceAll('__PROJECT_DIR__', projectDir)
      .replaceAll('__FLUTTER__', _flutter(flutterVersion))
      .replaceAll('__AAB_PREFIX__', projectDir == '.' ? '' : '$projectDir/');

  /// Builds the Flutter Windows app as an MSIX with Microsoft's Store CLI
  /// and uploads it to a draft submission in Partner Center. Release Desk
  /// then writes the release notes and commits the submission.
  static String windowsYaml({required String projectDir, String? flutterVersion}) =>
      _windows.replaceAll('__PROJECT_DIR__', projectDir).replaceAll('__FLUTTER__', _flutter(flutterVersion));

  /// Builds the iOS app on a GitHub macOS runner the same way the local
  /// pipeline does, and uploads it. Release Desk then does the TestFlight
  /// steps through the API.
  static String iosYaml({
    required String projectDir,
    String exportOptions = 'ios/ExportOptions.plist',
    String entitlements = 'ios/Runner/Runner.entitlements',
    String? teamId,
    String? flutterVersion,
  }) => _ios
      .replaceAll('__PROJECT_DIR__', projectDir)
      .replaceAll('__FLUTTER__', _flutter(flutterVersion))
      .replaceAll('__ENTITLEMENTS__', entitlements)
      .replaceAll('__EXPORT_OPTIONS__', exportOptions)
      .replaceAll('__TEAM_ID__', teamId ?? '');

  static const _android = r'''
# Written by Release Desk. Builds the Android app bundle on a GitHub runner,
# signed with your upload key, and keeps it as the release-desk-aab artifact.
# Release Desk downloads it and releases it on Google Play.
# Needs the repository secrets ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
# ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD.
name: Release Desk Android
run-name: Release Desk Android ${{ inputs.version }} (${{ inputs.build }}) ${{ inputs.release_desk_id }}

on:
  workflow_dispatch:
    inputs:
      version:
        description: Version name
        required: true
      build:
        description: Version code
        required: true
      release_desk_id:
        description: Set by Release Desk to find this run
        required: false
        default: ""

jobs:
  android:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    defaults:
      run:
        working-directory: __PROJECT_DIR__
    steps:
      - name: Check out
        uses: actions/checkout@v4

      - name: Set up Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
__FLUTTER__
          cache: true

      - name: Upload key
        env:
          KEYSTORE: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          STORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          printf '%s' "$KEYSTORE" | base64 --decode > "$RUNNER_TEMP/upload.jks"
          {
            echo "storeFile=$RUNNER_TEMP/upload.jks"
            echo "storePassword=$STORE_PASSWORD"
            echo "keyAlias=$KEY_ALIAS"
            echo "keyPassword=$KEY_PASSWORD"
          } > android/key.properties

      - name: Build app bundle
        run: flutter build appbundle --release --build-name "${{ inputs.version }}" --build-number "${{ inputs.build }}"

      - name: Check signing
        run: keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab | head -6

      - name: Keep the bundle
        uses: actions/upload-artifact@v4
        with:
          name: release-desk-aab
          path: __AAB_PREFIX__build/app/outputs/bundle/release/app-release.aab
          retention-days: 3

      - name: Remove the key
        if: always()
        run: rm -f "$RUNNER_TEMP/upload.jks" android/key.properties
''';

  static const _windows = r'''
# Written by Release Desk. Builds the Windows app as an MSIX on a GitHub runner
# and uploads it to a draft Microsoft Store submission; Release Desk then writes
# What's new and sends the submission for certification.
# Needs msix_config in pubspec.yaml (run `msstore init .` once and commit it), and
# the repository secrets MS_TENANT_ID, MS_SELLER_ID, MS_CLIENT_ID and MS_CLIENT_SECRET.
name: Release Desk Windows
run-name: Release Desk Windows ${{ inputs.version }} (${{ inputs.build }}) ${{ inputs.release_desk_id }}

on:
  workflow_dispatch:
    inputs:
      version:
        description: Version (x.y.z); the package gets x.y.z.0
        required: true
      build:
        description: Build number
        required: true
      rollout:
        description: Package rollout percentage, 0 for everyone
        required: false
        default: "0"
      upload:
        description: Upload to Partner Center (false for a rehearsal)
        required: false
        default: "true"
      release_desk_id:
        description: Set by Release Desk to find this run
        required: false
        default: ""

jobs:
  windows:
    runs-on: windows-latest
    timeout-minutes: 60
    defaults:
      run:
        working-directory: __PROJECT_DIR__
    steps:
      - name: Check out
        uses: actions/checkout@v4

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
__FLUTTER__
          cache: true

      - name: Set up the Microsoft Store CLI
        uses: microsoft/microsoft-store-apppublisher@v1.4

      - name: Sign in to Partner Center
        env:
          TENANT: ${{ secrets.MS_TENANT_ID }}
          SELLER: ${{ secrets.MS_SELLER_ID }}
          CLIENT: ${{ secrets.MS_CLIENT_ID }}
          SECRET: ${{ secrets.MS_CLIENT_SECRET }}
        run: msstore reconfigure --tenantId "$env:TENANT" --sellerId "$env:SELLER" --clientId "$env:CLIENT" --clientSecret "$env:SECRET"

      - name: Get packages
        run: flutter pub get

      - name: Build the MSIX
        run: msstore package . --version "${{ inputs.version }}.0" --output release-desk-msix

      - name: Upload to a draft submission
        if: inputs.upload != 'false'
        run: |
          $publish = @("publish", ".", "-i", "release-desk-msix", "-v", "--noCommit")
          if ([int]"${{ inputs.rollout }}" -gt 0) { $publish += @("--packageRolloutPercentage", "${{ inputs.rollout }}") }
          msstore @publish
''';

  static const _ios = r'''
# Written by Release Desk. Builds the iOS app on a GitHub macOS runner,
# signs it with Apple's cloud signing and uploads it to App Store Connect.
# Release Desk starts it and then does the TestFlight steps itself.
# Needs the repository secrets ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY.
name: Release Desk iOS
run-name: Release Desk iOS ${{ inputs.version }} (${{ inputs.build }}) ${{ inputs.release_desk_id }}

on:
  workflow_dispatch:
    inputs:
      version:
        description: Version (CFBundleShortVersionString)
        required: true
      build:
        description: Build number (CFBundleVersion)
        required: true
      upload:
        description: Upload to App Store Connect (false builds and signs only)
        type: boolean
        default: true
      release_desk_id:
        description: Set by Release Desk to find this run
        required: false
        default: ""

jobs:
  ios:
    runs-on: macos-latest
    timeout-minutes: 75
    defaults:
      run:
        working-directory: __PROJECT_DIR__
    env:
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
    steps:
      - name: Check out
        uses: actions/checkout@v4

      - name: Pick the newest Xcode
        run: |
          XC=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
          sudo xcode-select -s "$XC"
          xcodebuild -version

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
__FLUTTER__
          cache: true

      - name: API key
        env:
          ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
        run: |
          mkdir -p "$RUNNER_TEMP/keys"
          printf '%s' "$ASC_PRIVATE_KEY" > "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8"

      - name: Archive
        run: flutter build ipa --release --no-codesign --build-name "${{ inputs.version }}" --build-number "${{ inputs.build }}"

      - name: Pre-sign
        run: |
          APP=build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
          for f in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib "$APP"/PlugIns/*.appex; do
            [ -e "$f" ] && codesign -f -s - "$f"
          done
          if [ -f "__ENTITLEMENTS__" ]; then
            codesign -f -s - --entitlements "__ENTITLEMENTS__" "$APP"
          else
            codesign -f -s - "$APP"
          fi

      - name: Export and sign
        run: |
          OPTS="__EXPORT_OPTIONS__"
          if [ ! -f "$OPTS" ]; then
            OPTS="$RUNNER_TEMP/ExportOptions.plist"
            /usr/libexec/PlistBuddy -c "Add :method string app-store-connect" -c "Add :destination string export" \
              -c "Add :signingStyle string automatic" -c "Add :teamID string __TEAM_ID__" "$OPTS"
          fi
          xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive -exportPath build/ios/release-desk \
            -exportOptionsPlist "$OPTS" -allowProvisioningUpdates \
            -authenticationKeyPath "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8" \
            -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
          ls -la build/ios/release-desk

      - name: Upload
        if: ${{ inputs.upload }}
        run: |
          xcrun altool --upload-app -f build/ios/release-desk/*.ipa -t ios \
            --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
            --p8-file-path "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8"

      - name: Remove the key
        if: always()
        run: rm -rf "$RUNNER_TEMP/keys"
''';
}
