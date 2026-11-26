import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:release_desk/src/core/asc.dart';
import 'package:release_desk/src/core/asc_key.dart';
import 'package:release_desk/src/core/errors.dart';
import 'package:release_desk/src/core/flutter_project.dart';
import 'package:release_desk/src/core/github.dart';
import 'package:release_desk/src/core/google.dart';
import 'package:release_desk/src/core/json.dart';
import 'package:release_desk/src/core/release_run.dart';
import 'package:release_desk/src/core/store_languages.dart';
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

/// An App Store Connect client whose requests land in [sent] and get [reply]'s answer.
AscClient _fakeAsc(List<http.Request> sent, Object? Function(http.Request) reply) => AscClient(
  AscKey(keyId: 'ABC123DEFG', issuerId: '00000000-0000-0000-0000-000000000000', pem: testPem),
  client: MockClient((req) async {
    sent.add(req);
    return http.Response(jsonEncode(reply(req)), req.method == 'POST' ? 201 : 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }),
);

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

  group("App Store What's New", () {
    test('updates the languages the version has and adds the others', () async {
      final sent = <http.Request>[];
      final asc = _fakeAsc(
        sent,
        (r) => r.method == 'GET'
            ? {
                'data': [
                  {
                    'type': 'appStoreVersionLocalizations',
                    'id': 'loc-en',
                    'attributes': {'locale': 'en-US'},
                  },
                ],
              }
            : {
                'data': {'type': 'appStoreVersionLocalizations', 'id': 'loc-new'},
              },
      );
      final lines = await asc.writeWhatsNew('v1', {'en-US': 'Faster search.', 'ar-SA': 'بحث أسرع.', 'fr-FR': '  '});
      expect(lines, ['ar-SA: added the language', 'en-US: updated']);
      expect(sent.map((r) => '${r.method} ${r.url.path}'), [
        'GET /v1/appStoreVersions/v1/appStoreVersionLocalizations',
        'POST /v1/appStoreVersionLocalizations',
        'PATCH /v1/appStoreVersionLocalizations/loc-en',
      ]);
      expect(jsonDecode(sent[1].body), {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'attributes': {'locale': 'ar-SA', 'whatsNew': 'بحث أسرع.'},
          'relationships': {
            'appStoreVersion': {
              'data': {'type': 'appStoreVersions', 'id': 'v1'},
            },
          },
        },
      });
      expect(jsonDecode(sent[2].body), {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'id': 'loc-en',
          'attributes': {'whatsNew': 'Faster search.'},
        },
      });
    });

    test("a language added without text leaves What's New out", () async {
      final sent = <http.Request>[];
      final asc = _fakeAsc(
        sent,
        (_) => {
          'data': {'type': 'appStoreVersionLocalizations', 'id': 'loc-de'},
        },
      );
      expect(await asc.addLocalization('v1', 'de-DE'), 'loc-de');
      await asc.addLocalization('v1', 'de-DE', whatsNew: '');
      for (final r in sent) {
        expect((jsonDecode(r.body) as Map)['data']['attributes'], {'locale': 'de-DE'});
      }
    });

    test('uses the editable version with that number, or makes one', () async {
      final sent = <http.Request>[];
      var editable = false;
      final asc = _fakeAsc(
        sent,
        (r) => r.method == 'GET'
            ? {
                'data': [
                  {
                    'type': 'appStoreVersions',
                    'id': 'v-old',
                    'attributes': {
                      'versionString': '2.4.0',
                      'platform': 'IOS',
                      'appVersionState': editable ? 'PREPARE_FOR_SUBMISSION' : 'READY_FOR_DISTRIBUTION',
                    },
                  },
                ],
              }
            : {
                'data': {
                  'type': 'appStoreVersions',
                  'id': 'v-new',
                  'attributes': {'versionString': '2.4.0', 'appVersionState': 'PREPARE_FOR_SUBMISSION'},
                },
              },
      );
      final made = await asc.editableVersion('1001', '2.4.0');
      expect((made.version.id, made.created), ('v-new', true));
      expect(jsonDecode(sent.last.body), {
        'data': {
          'type': 'appStoreVersions',
          'attributes': {'platform': 'IOS', 'versionString': '2.4.0'},
          'relationships': {
            'app': {
              'data': {'type': 'apps', 'id': '1001'},
            },
          },
        },
      });
      editable = true;
      sent.clear();
      final found = await asc.editableVersion('1001', '2.4.0');
      expect((found.version.id, found.created), ('v-old', false));
      expect(sent.map((r) => r.method), ['GET']);
    });
  });

  group('Store languages', () {
    test('have English names and a direction', () {
      expect(StoreLanguages.name('ar-SA'), 'Arabic (Saudi Arabia)');
      expect(StoreLanguages.name('ar'), 'Arabic');
      expect(StoreLanguages.name('iw-IL'), 'Hebrew (Israel)');
      expect(StoreLanguages.name('fil'), 'Filipino (Philippines)');
      expect(StoreLanguages.name('zh-Hans'), 'Chinese, Simplified');
      expect(StoreLanguages.name('es-419'), 'Spanish (Latin America)');
      expect(StoreLanguages.name('xx-YY'), 'xx-YY');
      for (final code in [...StoreLanguages.appStore, ...StoreLanguages.play]) {
        expect(StoreLanguages.name(code), allOf(isNot(code), isNot(matches(RegExp(r'\((\d+|[A-Z]{2})\)')))), reason: code);
      }
      for (final rtl in ['ar', 'ar-SA', 'he', 'iw-IL', 'fa', 'ur']) {
        expect(StoreLanguages.isRightToLeft(rtl), isTrue, reason: rtl);
      }
      for (final ltr in ['fr-FR', 'en-US', 'am', 'hr', 'ARx', 'arx']) {
        expect(StoreLanguages.isRightToLeft(ltr), isFalse, reason: ltr);
      }
      expect(StoreLanguages.appStore.toSet(), hasLength(StoreLanguages.appStore.length));
      expect(StoreLanguages.play.toSet(), hasLength(StoreLanguages.play.length));
    });

    test('only chosen languages with text are sent', () {
      expect(notesIn({'en-US': 'Hi', 'ar-SA': '  ', 'fr-FR': 'Salut'}, ['en-US', 'ar-SA']), {'en-US': 'Hi'});
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

    test('recipes written before the language fields still load', () {
      const json =
          '{"exportOptions":"ios/ExportOptions.plist","entitlements":"ios/Runner/Runner.entitlements","writeBuildNumber":true,'
          '"groupIDs":[],"submitForReview":true,"locales":["ar-SA","en-US"],"androidBuildOn":null,"playTrack":null,"playStatus":null}';
      final r = Recipe.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
      expect(r.appStoreLocales, isNull);
      expect(r.playLocales, isNull);
      expect(r.locales, ['ar-SA', 'en-US']);
      expect(r.appStoreLocalesOrDefault, ['ar-SA', 'en-US']);
      expect(r.playLocalesOrDefault, ['en-US', 'ar']);
      final c =
          (r
                ..appStoreLocales = ['en-US']
                ..playLocales = ['en-US', 'fr-FR'])
              .copy();
      expect(c.appStoreLocales, ['en-US']);
      expect(c.playLocales, ['en-US', 'fr-FR']);
    });
  });

  group('Pipeline', () {
    test('iOS always builds on GitHub here', () {
      expect(StepId.stepsFor(ReleasePlatform.ios).first, StepId.prepare);
      expect(StepId.stepsFor(ReleasePlatform.ios)[1], StepId.cloudBuild);
      expect(StepId.stepsFor(ReleasePlatform.android), [StepId.prepare, StepId.bundle, StepId.checkSigning, StepId.playRelease]);
      expect(StepId.stepsFor(ReleasePlatform.android, cloud: true), [StepId.prepare, StepId.cloudBuild, StepId.playRelease]);
    });

    test("iOS writes App Store What's New after What to Test", () {
      expect(StepId.stepsFor(ReleasePlatform.ios), [
        StepId.prepare,
        StepId.cloudBuild,
        StepId.processing,
        StepId.notes,
        StepId.storeNotes,
        StepId.groups,
        StepId.review,
        StepId.live,
      ]);
      expect(StepId.stepsFor(ReleasePlatform.ios, cloud: true), StepId.stepsFor(ReleasePlatform.ios));
      expect(StepId.storeNotes.title, "App Store What's New");
      for (final cloud in [false, true]) {
        expect(StepId.stepsFor(ReleasePlatform.android, cloud: cloud), isNot(contains(StepId.storeNotes)));
      }
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
