import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:release_desk/src/core/asc.dart';
import 'package:release_desk/src/core/asc_key.dart';
import 'package:release_desk/src/core/errors.dart';
import 'package:release_desk/src/core/flutter_project.dart';
import 'package:release_desk/src/core/github.dart';
import 'package:release_desk/src/core/google.dart';
import 'package:release_desk/src/core/json.dart';
import 'package:release_desk/src/core/release_run.dart';
import 'package:release_desk/src/core/workspace.dart';

// A throwaway P-256 key made for these tests with
// `openssl ecparam -genkey -name prime256v1 | openssl pkcs8 -topk8 -nocrypt`.
const testPem = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvlcceGHWMYrLO40D
IC1PQpPX45P/oxdBlQJKzKY9DaChRANCAAQLoGj0j7veCRDBTyHtSgHRMFZcKSgw
DAVaAUO+Ciu4/YNAgNYA3h3KkzUGFdHT96M9RH5gjEnbXF7So7RL0+cP
-----END PRIVATE KEY-----''';

Uint8List _der(String pem) => base64.decode(pem.split('\n').where((l) => !l.startsWith('-----')).join());

BigInt _big(List<int> b) => b.fold(BigInt.zero, (r, x) => (r << 8) | BigInt.from(x));

void main() {
  group('App Store Connect ES256', () {
    test('reads the private key that matches the public key in the file', () {
      final d = AscKey.parsePrivateKey(testPem);
      final q = AscKey.publicKeyFor(d).Q!;
      final der = _der(testPem);
      // The PKCS#8 file ends with the public point 04‖X‖Y.
      final xy = der.sublist(der.length - 64);
      expect(q.x!.toBigInteger(), _big(xy.sublist(0, 32)));
      expect(q.y!.toBigInteger(), _big(xy.sublist(32)));
    });

    test('token is a JWT whose raw r‖s signature verifies with the public key', () {
      final key = AscKey(keyId: 'ABC123DEFG', issuerId: '00000000-0000-0000-0000-000000000000', pem: testPem);
      final token = key.token(now: DateTime.fromMillisecondsSinceEpoch(1700000000000));
      final parts = token.split('.');
      expect(parts, hasLength(3));
      final header = J.decode(utf8.decode(base64UrlDecodeLoose(parts[0])));
      expect(header['alg'].string, 'ES256');
      expect(header['kid'].string, 'ABC123DEFG');
      expect(header['typ'].string, 'JWT');
      final claims = J.decode(utf8.decode(base64UrlDecodeLoose(parts[1])));
      expect(claims['aud'].string, 'appstoreconnect-v1');
      expect(claims['iat'].integer, 1700000000);
      expect(claims['exp'].integer, 1700000000 + 19 * 60);
      final sig = Uint8List.fromList(base64UrlDecodeLoose(parts[2]));
      expect(sig, hasLength(64));
      final pub = AscKey.publicKeyFor(AscKey.parsePrivateKey(testPem));
      final input = Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}'));
      expect(AscKey.verifyES256(pub, input, sig), isTrue);
      final tampered = Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}x'));
      expect(AscKey.verifyES256(pub, tampered, sig), isFalse);
    });

    test('signatures stay 64 bytes for many messages (left padding)', () {
      final d = AscKey.parsePrivateKey(testPem);
      final pub = AscKey.publicKeyFor(d);
      for (var i = 0; i < 40; i++) {
        final m = Uint8List.fromList(utf8.encode('message $i'));
        final s = AscKey.signES256(d, m);
        expect(s, hasLength(64));
        expect(AscKey.verifyES256(pub, m, s), isTrue);
      }
    });

    test('refuses files that are not a P-256 private key', () {
      expect(() => AscKey.parsePrivateKey('not a key'), throwsA(isA<ReleaseError>()));
      expect(() => AscKey.parsePrivateKey('-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----'), throwsA(isA<ReleaseError>()));
    });
  });

  group('GitHub', () {
    String golden(String name) => File(p.join('test', 'golden', name)).readAsStringSync();

    test('workflows match the macOS app line for line', () {
      expect(CloudTarget.ios.yaml(projectDir: 'mobile', teamId: 'ABCDE12345', flutterVersion: '3.50.0'), golden('ios_mobile.yml'));
      expect(CloudTarget.ios.yaml(projectDir: '.'), golden('ios_root.yml'));
      expect(CloudTarget.android.yaml(projectDir: 'mobile', flutterVersion: '3.50.0'), golden('android_mobile.yml'));
      expect(CloudTarget.android.yaml(projectDir: '.'), golden('android_root.yml'));
    });

    test('names and secrets are the shared ones', () {
      expect(CloudTarget.ios.workflowFile, 'release-desk-ios.yml');
      expect(CloudTarget.android.workflowFile, 'release-desk-android.yml');
      expect(CloudTarget.ios.secretNames, ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY']);
      expect(CloudTarget.android.secretNames, ['ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD']);
      expect(CloudTarget.androidArtifact, 'release-desk-aab');
    });

    test('repository is read from the remote', () {
      expect(GitHubRepo.parseRemote('git@github.com:Some-Org/some-app.git')?.name, 'some-app');
      expect(GitHubRepo.parseRemote('https://github.com/Some-Org/some-app.git')?.owner, 'Some-Org');
      expect(GitHubRepo.parseRemote('https://github.com/Some-Org/some.app')?.name, 'some.app');
      expect(GitHubRepo.parseRemote('https://gitlab.com/a/b.git'), isNull);
      const repo = GitHubRepo(owner: 'o', name: 'n', projectDir: 'apps/mobile');
      expect(repo.repoRoot(p.join('/x', 'repo', 'apps', 'mobile')), p.join('/x', 'repo'));
    });

    test('repository and project folder come from git', () async {
      final dir = await Directory.systemTemp.createTemp('rd-git');
      addTearDown(() => dir.delete(recursive: true));
      final app = Directory(p.join(dir.path, 'mobile'))..createSync();
      await Process.run('git', ['-C', dir.path, 'init', '-q']);
      await Process.run('git', ['-C', dir.path, 'remote', 'add', 'origin', 'git@github.com:Some-Org/some-app.git']);
      final repo = await GitHubRepo.detect(app.path);
      expect(repo?.fullName, 'Some-Org/some-app');
      expect(repo?.projectDir, 'mobile');
    });

    test('artifact zips cannot write outside their folder', () async {
      final dir = await Directory.systemTemp.createTemp('rd-zip');
      addTearDown(() => dir.delete(recursive: true));
      final archive = Archive()
        ..addFile(ArchiveFile('app-release.aab', 3, [1, 2, 3]))
        ..addFile(ArchiveFile('../evil.txt', 1, [1]));
      final files = GitHubClient.unzipTo(ZipEncoder().encode(archive), dir);
      expect(files.map((f) => p.basename(f.path)), ['app-release.aab']);
      expect(File(p.join(dir.parent.path, 'evil.txt')).existsSync(), isFalse);
    });
  });

  group('Google sign-in', () {
    test('PKCE challenge follows RFC 7636', () {
      expect(GoogleSignIn.pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('reads the Desktop OAuth client file', () {
      final c = OAuthClient.fromFile(
        jsonEncode({
          'installed': {'client_id': 'id.apps.googleusercontent.com', 'client_secret': 'shh', 'project_id': 'proj'},
        }),
      );
      expect(c.clientId, 'id.apps.googleusercontent.com');
      expect(c.projectId, 'proj');
      expect(() => OAuthClient.fromFile('{}'), throwsA(isA<ReleaseError>()));
    });

    test('authorization URL asks for offline access with S256', () {
      const c = OAuthClient(clientId: 'cid', clientSecret: 's');
      final u = GoogleSignIn.authorizationUrl(c, redirect: 'http://127.0.0.1:5000', challenge: 'ch', state: 'st');
      expect(u.queryParameters['code_challenge_method'], 'S256');
      expect(u.queryParameters['access_type'], 'offline');
      expect(u.queryParameters['scope'], contains('androidpublisher'));
      expect(u.queryParameters.containsKey('login_hint'), isFalse);
    });

    test('loopback listener takes the redirect', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final wait = GoogleSignIn.waitForRedirect(server, const Duration(seconds: 10));
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/?code=abc&state=xyz'));
      final res = await req.close();
      expect(res.statusCode, 200);
      await res.drain<void>();
      final q = await wait;
      expect(q['code'], 'abc');
      expect(q['state'], 'xyz');
      client.close();
      await server.close(force: true);
    });
  });

  group('Flutter project', () {
    test('reads versions and ids, and rewrites the version line', () async {
      final dir = await Directory.systemTemp.createTemp('rd-proj');
      addTearDown(() => dir.delete(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: shop_app\ndescription: x\nversion: 2.3.4+56 # keep\n');
      Directory(p.join(dir.path, 'ios', 'Runner.xcodeproj')).createSync(recursive: true);
      File(p.join(dir.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
          .writeAsStringSync('PRODUCT_BUNDLE_IDENTIFIER = com.example.shop.RunnerTests;\nPRODUCT_BUNDLE_IDENTIFIER = com.example.shop;\n');
      Directory(p.join(dir.path, 'android', 'app')).createSync(recursive: true);
      File(p.join(dir.path, 'android', 'app', 'build.gradle.kts'))
          .writeAsStringSync('android {\n  defaultConfig {\n    applicationId = "com.example.shop"\n  }\n}\n');
      File(p.join(dir.path, 'android', 'key.properties')).writeAsStringSync('storePassword=a\nkeyPassword=b\nkeyAlias=upload\nstoreFile=../upload.jks\n');
      final proj = FlutterProject.inspect(dir.path);
      expect(proj.name, 'shop_app');
      expect(proj.version, '2.3.4');
      expect(proj.buildNumber, 56);
      expect(proj.iosBundleId, 'com.example.shop');
      expect(proj.androidPackage, 'com.example.shop');
      expect(proj.hasUploadKey, isTrue);
      expect(proj.keyProperties()['keyAlias'], 'upload');
      proj.writeVersion('2.4.0', 60);
      expect(File(proj.pubspec).readAsStringSync(), contains('version: 2.4.0+60 # keep'));
    });
  });

  group('Workspace', () {
    test('round-trips without any secret in it', () {
      final ws = Workspace(
        accounts: [
          Account(
            provider: StoreProvider.apple,
            name: 'Work',
            teams: [
              Team(
                name: 'Team A',
                teamId: 'ABCDE12345',
                credential: const Credential.appStoreConnectKey(keyId: 'KEY1234567', issuerId: 'issuer'),
              ),
            ],
          ),
          Account(
            provider: StoreProvider.google,
            name: 'dev@example.com',
            teams: [
              Team(
                name: 'Play Console',
                credential: const Credential.googleUser(email: 'dev@example.com'),
                packages: ['com.example.app'],
              ),
            ],
          ),
        ],
        links: [ProjectLink(appId: '123', path: '/tmp/app')],
      );
      final text = jsonEncode(ws.toJson());
      expect(text, isNot(contains('PRIVATE KEY')));
      final back = Workspace.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
      expect(back.accounts, hasLength(2));
      expect(back.accounts.first.teams.first.credential.secretKey, 'asc.KEY1234567');
      expect(back.accounts.last.teams.first.credential.isGoogle, isTrue);
      expect(back.accounts.last.teams.first.packages, ['com.example.app']);
      expect(back.link('123')?.recipe.locales, ['ar-SA', 'en-US']);
    });
  });

  group('Pipeline', () {
    test('iOS always builds on GitHub here', () {
      expect(StepId.stepsFor(ReleasePlatform.ios).first, StepId.prepare);
      expect(StepId.stepsFor(ReleasePlatform.ios)[1], StepId.cloudBuild);
      expect(StepId.stepsFor(ReleasePlatform.android), [StepId.prepare, StepId.bundle, StepId.checkSigning, StepId.playRelease]);
      expect(StepId.stepsFor(ReleasePlatform.android, cloud: true), [StepId.prepare, StepId.cloudBuild, StepId.playRelease]);
    });

    test("Apple's states read as words", () {
      expect(describeState('IN_BETA_TESTING').label, 'Testing');
      expect(describeState('SOMETHING_NEW').label, 'Something new');
      expect(describeState(null).tone, StateTone.muted);
    });

    test('a stopped sleep throws cancelled', () async {
      final t = CancelToken();
      final f = t.sleep(const Duration(seconds: 30));
      t.cancel();
      await expectLater(f, throwsA(isA<ReleaseError>().having((e) => e.isCancelled, 'cancelled', isTrue)));
    });
  });
}
