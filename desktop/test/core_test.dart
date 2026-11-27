import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:release_desk/src/core/app_gallery.dart';
import 'package:release_desk/src/core/asc.dart';
import 'package:release_desk/src/core/asc_key.dart';
import 'package:release_desk/src/core/errors.dart';
import 'package:release_desk/src/core/flutter_project.dart';
import 'package:release_desk/src/core/github.dart';
import 'package:release_desk/src/core/google.dart';
import 'package:release_desk/src/core/json.dart';
import 'package:release_desk/src/core/microsoft_store.dart';
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

http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

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
      expect(CloudTarget.windows.yaml(projectDir: 'mobile', flutterVersion: '3.50.0'), golden('windows_mobile.yml'));
      expect(CloudTarget.windows.yaml(projectDir: '.'), golden('windows_root.yml'));
    });

    test('the Windows workflow builds and uploads with the Store CLI', () {
      final y = CloudTarget.windows.yaml(projectDir: 'mobile', flutterVersion: '3.27.0');
      expect(y, contains('runs-on: windows-latest'));
      expect(y, contains('microsoft/microsoft-store-apppublisher@v1.4'));
      expect(y, contains('msstore package . --version "\${{ inputs.version }}.0"'));
      expect(y, contains('--noCommit'));
      expect(y, contains("if: inputs.upload != 'false'"));
      expect(y, contains('working-directory: mobile'));
      expect(y, contains('flutter-version: 3.27.0'));
      for (final name in CloudTarget.windows.secretNames) {
        expect(y, contains('secrets.$name'));
      }
      expect(y, isNot(contains('\t')));
    });

    test('names and secrets are the shared ones', () {
      expect(CloudTarget.ios.workflowFile, 'release-desk-ios.yml');
      expect(CloudTarget.android.workflowFile, 'release-desk-android.yml');
      expect(CloudTarget.ios.secretNames, ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY']);
      expect(CloudTarget.android.secretNames, ['ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD']);
      expect(CloudTarget.androidArtifact, 'release-desk-aab');
      expect(CloudTarget.windows.workflowFile, 'release-desk-windows.yml');
      expect(CloudTarget.windows.secretNames, ['MS_TENANT_ID', 'MS_SELLER_ID', 'MS_CLIENT_ID', 'MS_CLIENT_SECRET']);
      expect([for (final t in CloudTarget.values) t.runner], ['macOS', 'Linux', 'Windows']);
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
      expect(StepId.stepsFor(ReleasePlatform.android), [StepId.prepare, StepId.bundle, StepId.checkSigning, StepId.playRelease, StepId.agcRelease]);
      expect(StepId.stepsFor(ReleasePlatform.android, cloud: true), [StepId.prepare, StepId.cloudBuild, StepId.playRelease, StepId.agcRelease]);
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

  group('AppGallery', () {
    test('signs in with the client, then calls with its id and token', () async {
      final sent = <http.Request>[];
      final agc = AppGalleryClient(
        clientId: '1234567890',
        secret: 'k3y',
        client: MockClient((req) async {
          sent.add(req);
          if (req.url.path.endsWith('/oauth2/v1/token')) return _json({'access_token': 'tok', 'expires_in': 172800});
          return _json({
            'ret': {'code': 0, 'msg': 'success'},
            'appids': [
              {'key': 'Atlas Notes', 'value': '101'},
              {'key': 'Pocket Budget', 'value': '102'},
            ],
          });
        }),
      );
      final ids = await agc.appIds(['com.example.atlas', 'com.example.budget']);
      expect(ids['com.example.atlas'], (appId: '101', name: 'Atlas Notes'));
      expect(ids['com.example.budget']?.appId, '102');
      expect(sent.map((r) => '${r.method} ${r.url.path}'), ['POST /api/oauth2/v1/token', 'GET /api/publish/v2/appid-list']);
      expect(jsonDecode(sent[0].body), {'grant_type': 'client_credentials', 'client_id': '1234567890', 'client_secret': 'k3y'});
      expect(sent[0].headers['Content-Type'], startsWith('application/json'));
      expect(sent[1].url.queryParameters, {'packageName': 'com.example.atlas,com.example.budget'});
      expect(sent[1].headers['client_id'], '1234567890');
      expect(sent[1].headers['Authorization'], 'Bearer tok');
      // The token is kept for later calls.
      await agc.appIds(['com.example.atlas']);
      expect(sent.where((r) => r.url.path.endsWith('/token')), hasLength(1));
    });

    test('an answer with ret.code other than 0 is an error, even with HTTP 200', () async {
      final agc = AppGalleryClient(
        clientId: 'c',
        secret: 's',
        client: MockClient(
          (req) async => req.url.path.endsWith('/token')
              ? _json({'access_token': 'tok'})
              : _json({
                  'ret': {'code': 204144647, 'msg': 'The app does not exist'},
                }),
        ),
      );
      await expectLater(
        agc.app('101', 'com.example.atlas'),
        throwsA(
          isA<ReleaseError>()
              .having((e) => e.status, 'status', 204144647)
              .having((e) => e.message, 'message', 'AppGallery 204144647 on /api/publish/v2/app-info: The app does not exist'),
        ),
      );
    });

    test('reads the version, state, review notes and What\'s new', () async {
      final agc = AppGalleryClient(
        clientId: 'c',
        secret: 's',
        client: MockClient(
          (req) async => req.url.path.endsWith('/token')
              ? _json({'access_token': 'tok'})
              : _json({
                  'ret': {'code': 0},
                  'appInfo': {'versionNumber': '2.4.0', 'onShelfVersionNumber': '2.3.9', 'releaseState': 5, 'defaultLang': 'en-US'},
                  'auditInfo': {'auditOpinion': 'Screenshots are missing.'},
                  'languages': [
                    {'lang': 'ar', 'appName': 'أطلس', 'newFeatures': 'بحث أسرع'},
                    {'lang': 'en-US', 'appName': 'Atlas Notes', 'newFeatures': 'Faster search'},
                    {'lang': 'fr-FR', 'appName': 'Atlas', 'newFeatures': ''},
                  ],
                }),
        ),
      );
      final a = await agc.app('101', 'com.example.atlas');
      expect(a.name, 'Atlas Notes');
      expect((a.version, a.versionOnShelf, a.stateTitle, a.reviewNote), ('2.4.0', '2.3.9', 'Update in review', 'Screenshots are missing.'));
      expect(a.newFeatures, {'ar': 'بحث أسرع', 'en-US': 'Faster search'});
    });

    test('uploads the bundle, attaches it, waits, writes What\'s new and submits phased', () async {
      final dir = await Directory.systemTemp.createTemp('rd-agc');
      addTearDown(() => dir.delete(recursive: true));
      final aab = File(p.join(dir.path, 'app-release.aab'))..writeAsBytesSync(List.generate(2048, (i) => i % 251));
      final sent = <http.Request>[];
      var polls = 0;
      final agc = AppGalleryClient(
        clientId: 'c',
        secret: 's',
        poll: Duration.zero,
        client: MockClient((req) async {
          sent.add(req);
          final path = req.url.path;
          if (path.endsWith('/oauth2/v1/token')) return _json({'access_token': 'tok'});
          if (req.url.host == 'obs.example.com') return http.Response('', 200);
          final ok = {'code': 0, 'msg': 'success'};
          return switch (path) {
            '/api/publish/v2/upload-url/for-obs' => _json({
              'ret': ok,
              'urlInfo': {
                'objectId': 'cn/obj-1',
                'url': 'https://obs.example.com/upload/obj-1?sig=abc',
                'method': 'PUT',
                'headers': {'Content-Type': 'application/octet-stream', 'x-amz-date': '20261127T100000Z'},
              },
            }),
            '/api/publish/v2/app-file-info' => _json({
              'ret': ok,
              'pkgVersion': ['pkg-9'],
            }),
            '/api/publish/v2/package/compile/status' => _json({
              'ret': ok,
              'pkgStateList': [
                {'pkgId': 'pkg-9', 'successStatus': ++polls < 2 ? 1 : 0},
              ],
            }),
            _ => _json({'ret': ok}),
          };
        }),
      );
      final logs = <String>[];
      await agc.upload('101', aab, log: logs.add);
      await agc.setWhatsNew('101', {'iw-IL': 'שיפורים', 'en-US': 'Faster search', 'ar': 'بحث أسرع'});
      final now = DateTime.utc(2026, 11, 27, 10);
      await agc.submit('101', const AgcRelease.phased(percent: 10, days: 7), now: now);
      await agc.submit('101', const AgcRelease.afterReview());

      final calls = sent.where((r) => !r.url.path.endsWith('/token')).toList();
      expect(calls.map((r) => '${r.method} ${r.url.host == 'obs.example.com' ? 'obs' : r.url.path}'), [
        'GET /api/publish/v2/upload-url/for-obs',
        'PUT obs',
        'PUT /api/publish/v2/app-file-info',
        'GET /api/publish/v2/package/compile/status',
        'GET /api/publish/v2/package/compile/status',
        'PUT /api/publish/v2/app-language-info',
        'PUT /api/publish/v2/app-language-info',
        'PUT /api/publish/v2/app-language-info',
        'POST /api/publish/v2/app-submit',
        'POST /api/publish/v2/app-submit',
      ]);
      expect(calls[0].url.queryParameters, {'appId': '101', 'chineseMainlandFlag': '0', 'contentLength': '2048', 'fileName': 'app-release.aab'});
      // The bytes go to the address AppGallery gave, with every header it asked for and no token.
      expect(calls[1].url.toString(), 'https://obs.example.com/upload/obj-1?sig=abc');
      expect(calls[1].bodyBytes, aab.readAsBytesSync());
      expect(calls[1].headers['x-amz-date'], '20261127T100000Z');
      expect(calls[1].headers['Content-Type'], 'application/octet-stream');
      expect(calls[1].headers.containsKey('Authorization'), isFalse);
      expect(calls[2].url.queryParameters, {'appId': '101', 'releaseType': '1'});
      expect(jsonDecode(calls[2].body), {
        'fileType': 5,
        'files': [
          {'fileName': 'app-release.aab', 'fileDestUrl': 'cn/obj-1'},
        ],
      });
      expect(calls[3].url.queryParameters, {'appId': '101', 'pkgIds': 'pkg-9'});
      expect(logs.last, 'Processed');
      // What's new, one language at a time, sorted, with Hebrew as AppGallery writes it.
      expect(
        [for (final r in calls.sublist(5, 8)) jsonDecode(r.body)],
        [
          {'lang': 'ar', 'newFeatures': 'بحث أسرع'},
          {'lang': 'en-US', 'newFeatures': 'Faster search'},
          {'lang': 'he_IL', 'newFeatures': 'שיפורים'},
        ],
      );
      expect(calls[5].url.queryParameters, {'appId': '101', 'releaseType': '1'});
      // Phased: release type 3, a window starting in ten minutes, the share with two decimals.
      expect(calls[8].url.queryParameters, {'appId': '101', 'releaseType': '3'});
      final phased = jsonDecode(calls[8].body) as Map;
      expect(phased['phasedReleasePercent'], '10.00');
      expect(phased['phasedReleaseDescription'], 'Phased release from Release Desk');
      final time = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$');
      expect(phased['phasedReleaseStartTime'], matches(time));
      expect(DateTime.parse(phased['phasedReleaseStartTime'] as String), now.add(const Duration(minutes: 10)));
      expect(DateTime.parse(phased['phasedReleaseEndTime'] as String), now.add(const Duration(minutes: 10, days: 7)));
      // After review: no body, only the app.
      expect(calls[9].url.queryParameters, {'appId': '101'});
      expect(calls[9].body, isEmpty);
    });

    test('refuses app bundles over 150 MB', () async {
      final dir = await Directory.systemTemp.createTemp('rd-agc');
      addTearDown(() => dir.delete(recursive: true));
      final big = File(p.join(dir.path, 'app-release.aab'));
      (big.openSync(mode: FileMode.write)
            ..setPositionSync(151 * 1024 * 1024)
            ..writeByteSync(0))
          .closeSync();
      final agc = AppGalleryClient(clientId: 'c', secret: 's', client: MockClient((_) async => fail('no call expected')));
      await expectLater(agc.upload('101', big, log: (_) {}), throwsA(isA<ReleaseError>().having((e) => e.message, 'message', contains('150 MB'))));
    });

    test('language codes and states', () {
      expect(AppGalleryClient.language('en-US'), 'en-US');
      expect(AppGalleryClient.language('ar'), 'ar');
      expect(AppGalleryClient.language('iw-IL'), 'he_IL');
      expect(const AgcApp(appId: '1', package: 'p', name: 'n', releaseState: 4).stateTitle, 'In review');
      expect(const AgcApp(appId: '1', package: 'p', name: 'n', releaseState: 99).stateTitle, 'State 99');
      expect(const AgcApp(appId: '1', package: 'p', name: 'n').stateTitle, 'Unknown');
    });
  });

  group('Microsoft Store', () {
    MicrosoftStoreClient fake(List<http.Request> sent, http.Response Function(http.Request) reply) => MicrosoftStoreClient(
      tenantId: 'tenant-1',
      clientId: 'client-1',
      secret: 's+cr&t=',
      client: MockClient((req) async {
        sent.add(req);
        if (req.url.host == 'login.microsoftonline.com') return _json({'access_token': 'tok', 'expires_in': 3600});
        return reply(req);
      }),
    );

    test('signs in with a form body and pages applications with @nextLink', () async {
      final sent = <http.Request>[];
      final ms = fake(
        sent,
        (req) => req.url.queryParameters['skip'] == '0'
            ? _json({
                'value': [
                  {
                    'id': '9NBLGGH4R315',
                    'primaryName': 'Atlas Notes',
                    'packageIdentityName': 'Example.AtlasNotes',
                    'firstPublishedDate': '2025-03-01T10:00:00Z',
                    'lastPublishedApplicationSubmission': {'id': '1152921504621243619'},
                    'pendingApplicationSubmission': {'id': '1152921504621243620'},
                  },
                ],
                '@nextLink': 'applications?skip=1&top=1',
              })
            : _json({
                'value': [
                  {'id': '9WZDNCRFJ3TJ', 'primaryName': 'Pocket Budget', 'packageIdentityName': 'Example.PocketBudget'},
                ],
              }),
      );
      final apps = await ms.applications();
      expect(sent.first.url.toString(), 'https://login.microsoftonline.com/tenant-1/oauth2/token');
      expect(sent.first.headers['Content-Type'], 'application/x-www-form-urlencoded; charset=utf-8');
      expect(
        sent.first.body,
        'grant_type=client_credentials&client_id=client%2D1&client_secret=s%2Bcr%26t%3D&resource=https%3A%2F%2Fmanage%2Edevcenter%2Emicrosoft%2Ecom',
      );
      expect(Uri.splitQueryString(sent.first.body), {
        'grant_type': 'client_credentials',
        'client_id': 'client-1',
        'client_secret': 's+cr&t=',
        'resource': 'https://manage.devcenter.microsoft.com',
      });
      expect(sent.skip(1).map((r) => r.url.toString()), [
        'https://manage.devcenter.microsoft.com/v1.0/my/applications?top=100&skip=0',
        'https://manage.devcenter.microsoft.com/v1.0/my/applications?skip=1&top=1',
      ]);
      expect(sent[1].headers['Authorization'], 'Bearer tok');
      expect(apps.map((a) => a.id), ['9NBLGGH4R315', '9WZDNCRFJ3TJ']);
      expect(apps.first.name, 'Atlas Notes');
      expect(apps.first.packageIdentityName, 'Example.AtlasNotes');
      expect(apps.first.pendingSubmissionId, '1152921504621243620');
      expect(apps.first.firstPublished, DateTime.utc(2025, 3, 1, 10));
      expect(apps.last.lastSubmissionId, isNull);
    });

    test("writes release notes only into the listing's languages and PUTs the whole submission", () async {
      final submission = {
        'id': '1152921504621243620',
        'status': 'PendingCommit',
        'targetPublishMode': 'Immediate',
        'applicationPackages': [
          {'fileName': 'atlas.msixupload', 'fileStatus': 'PendingUpload'},
        ],
        'listings': {
          'en-us': {
            'baseListing': {'title': 'Atlas Notes', 'releaseNotes': 'Old notes', 'keywords': []},
          },
          'ar-sa': {
            'baseListing': {'title': 'أطلس'},
          },
        },
      };
      final sent = <http.Request>[];
      final ms = fake(sent, (req) => req.method == 'GET' ? _json(submission) : _json({}));
      final lines = await ms.setReleaseNotes('9NBLGGH4R315', '1152921504621243620', {'en-US': 'Faster search', 'fr-FR': 'Recherche', 'ar-SA': 'بحث أسرع'});
      expect(lines, ['ar-sa: written', 'en-us: written', 'fr-fr: no listing in this language on the Store, skipped']);
      final calls = sent.skip(1).toList();
      expect(calls.map((r) => '${r.method} ${r.url.path}'), [
        'GET /v1.0/my/applications/9NBLGGH4R315/submissions/1152921504621243620',
        'PUT /v1.0/my/applications/9NBLGGH4R315/submissions/1152921504621243620',
      ]);
      final put = jsonDecode(calls[1].body) as Map;
      expect(put['listings'], {
        'en-us': {
          'baseListing': {'title': 'Atlas Notes', 'releaseNotes': 'Faster search', 'keywords': []},
        },
        'ar-sa': {
          'baseListing': {'title': 'أطلس', 'releaseNotes': 'بحث أسرع'},
        },
      });
      expect(put['applicationPackages'], submission['applicationPackages']);
      expect(put['targetPublishMode'], 'Immediate');
      expect(calls[1].headers['Content-Type'], startsWith('application/json'));

      // No language in common: nothing is written.
      sent.clear();
      expect(await ms.setReleaseNotes('9NBLGGH4R315', '1152921504621243620', {'de-DE': 'Schneller'}), [
        'de-de: no listing in this language on the Store, skipped',
      ]);
      expect(sent.map((r) => r.method), ['GET']);
    });

    test('commits the submission and reads its status and errors', () async {
      final sent = <http.Request>[];
      final ms = fake(
        sent,
        (req) => req.url.path.endsWith('/status')
            ? _json({
                'status': 'CommitFailed',
                'statusDetails': {
                  'errors': [
                    {'code': 'InvalidParameterValue', 'details': 'The package version is not higher.'},
                  ],
                },
              })
            : _json({'status': 'CommitStarted'}),
      );
      await ms.commit('9NBLGGH4R315', '42');
      final commit = sent.last;
      expect('${commit.method} ${commit.url.path}', 'POST /v1.0/my/applications/9NBLGGH4R315/submissions/42/commit');
      expect(commit.contentLength, 0);
      final s = await ms.status('9NBLGGH4R315', '42');
      expect(s.status, 'CommitFailed');
      expect(s.errors, ['InvalidParameterValue The package version is not higher.']);
    });

    test('errors name the Microsoft Store', () async {
      final ms = fake([], (_) => _json({'code': 'InvalidRequest', 'message': 'The submission is not in a state to commit.'}, 409));
      await expectLater(
        ms.commit('9NBLGGH4R315', '42'),
        throwsA(
          isA<ReleaseError>().having(
            (e) => e.message,
            'message',
            'Microsoft Store 409 on /v1.0/my/applications/9NBLGGH4R315/submissions/42/commit: The submission is not in a state to commit.',
          ),
        ),
      );
    });

    test('the app page reads the draft, its listing languages and notes', () async {
      final ms = fake([], (req) {
        final path = req.url.path;
        if (path.endsWith('/9NBLGGH4R315')) {
          return _json({
            'id': '9NBLGGH4R315',
            'primaryName': 'Atlas Notes',
            'lastPublishedApplicationSubmission': {'id': '1'},
            'pendingApplicationSubmission': {'id': '2'},
          });
        }
        if (path.endsWith('/submissions/2/status')) return _json({'status': 'PendingCommit'});
        if (path.endsWith('/submissions/1/status')) return _json({'status': 'Published'});
        return _json({
          'status': 'PendingCommit',
          'listings': {
            'en-us': {
              'baseListing': {'releaseNotes': 'Faster search'},
            },
            'ar-sa': {
              'baseListing': {'releaseNotes': ''},
            },
          },
        });
      });
      final app = await ms.details('9NBLGGH4R315');
      expect(app.pendingStatus, 'PendingCommit');
      expect(app.lastStatus, 'Published');
      expect(app.listingLanguages, ['ar-sa', 'en-us']);
      expect(app.releaseNotes, {'en-us': 'Faster search'});
    });
  });

  group('Stores', () {
    test('app ids tell their store', () {
      expect(StoreProvider.of('1234567890'), StoreProvider.apple);
      expect(StoreProvider.of('play:com.example.app'), StoreProvider.google);
      expect(StoreProvider.of('agc:com.example.app'), StoreProvider.huawei);
      expect(StoreProvider.of('msstore:9NBLGGH4R315'), StoreProvider.microsoft);
      expect(const StoreApp(id: 'msstore:9NBLGGH4R315', name: 'A', bundleId: 'Example.A').storeId, '9NBLGGH4R315');
      expect(const StoreApp(id: 'agc:com.example.app', name: 'A', bundleId: 'com.example.app').store, StoreProvider.huawei);
      expect([for (final s in StoreProvider.values) s.title], ['Apple', 'Google Play', 'AppGallery', 'Microsoft Store']);
    });

    test('new credentials round-trip and keep their secrets apart', () {
      const agc = Credential.agcClient(clientId: '123');
      const ms = Credential.partnerCenter(tenantId: 't', clientId: 'c', sellerId: 's');
      for (final c in [agc, ms, const Credential.googleUser(email: 'a@b.c'), const Credential.appStoreConnectKey(keyId: 'K', issuerId: 'I')]) {
        final back = Credential.fromJson((jsonDecode(jsonEncode(c.toJson())) as Map).cast<String, Object?>());
        expect(back, c);
        expect(back.secretKey, c.secretKey);
      }
      expect(agc.toJson(), {'kind': 'agcClient', 'clientID': '123'});
      expect(ms.toJson(), {'kind': 'partnerCenter', 'tenantID': 't', 'clientID': 'c', 'sellerID': 's'});
      expect((agc.secretKey, agc.store, agc.takesPackages, agc.isGoogle, agc.summary), ('agc.123', StoreProvider.huawei, true, false, 'API client 123'));
      expect((ms.secretKey, ms.store, ms.takesPackages, ms.isGoogle, ms.summary), ('ms.c', StoreProvider.microsoft, false, false, 'Seller s'));
      expect(const Credential.googleUser(email: 'a@b.c').isGoogle, isTrue);
      expect(const Credential.googleUser(email: 'a@b.c').takesPackages, isTrue);
    });

    test('a workspace.json written before the new stores still loads, and the new ones round-trip', () {
      const old =
          '{"version":1,"accounts":[{"id":"a1","provider":"apple","name":"Work","email":null,"teams":[{"id":"t1","name":"Team A","teamID":"ABCDE12345",'
          '"credential":{"kind":"appStoreConnectKey","keyID":"KEY1","issuerID":"iss"},"packages":[]}]},{"id":"a2","provider":"google","name":"dev@example.com",'
          '"email":"dev@example.com","teams":[{"id":"t2","name":"Play Console","teamID":null,"credential":{"kind":"googleUser","email":"dev@example.com"},'
          '"packages":["com.example.app"]}]}],"links":[{"id":"l1","appID":"play:com.example.app","path":"/tmp/app","kind":"flutter","recipe":{'
          '"exportOptions":"ios/ExportOptions.plist","entitlements":"ios/Runner/Runner.entitlements","writeBuildNumber":true,"groupIDs":[],'
          '"submitForReview":true,"locales":["ar-SA","en-US"],"appStoreLocales":null,"playLocales":null,"androidBuildOn":"github","playTrack":"beta",'
          '"playStatus":"completed"}}],"runs":[]}';
      final ws = Workspace.fromJson((jsonDecode(old) as Map).cast<String, Object?>());
      expect(ws.accounts.map((a) => a.provider), [StoreProvider.apple, StoreProvider.google]);
      expect(ws.accounts.first.teams.first.credential.secretKey, 'asc.KEY1');
      final r = ws.link('play:com.example.app')!.recipe;
      expect((r.androidBuildOn, r.playTrack, r.agcToo, r.msLocales, r.msRollout, r.windowsBuildOn), ('github', 'beta', null, null, null, null));

      ws.accounts.addAll([
        Account(
          provider: StoreProvider.huawei,
          name: 'Huawei developer account',
          teams: [
            Team(
              name: 'Client team',
              credential: const Credential.agcClient(clientId: '123'),
              packages: ['com.example.app'],
            ),
          ],
        ),
        Account(
          provider: StoreProvider.microsoft,
          name: 'Partner Center',
          teams: [
            Team(
              name: 'Store',
              teamId: '12345678',
              credential: const Credential.partnerCenter(tenantId: 't', clientId: 'c', sellerId: '12345678'),
            ),
          ],
        ),
      ]);
      r
        ..agcToo = true
        ..msLocales = ['en-us']
        ..msRollout = 20
        ..windowsBuildOn = 'github';
      final text = jsonEncode(ws.toJson());
      final back = Workspace.fromJson((jsonDecode(text) as Map).cast<String, Object?>());
      expect(back.accounts.map((a) => a.provider), StoreProvider.values);
      expect(back.accounts[2].teams.first.credential, const Credential.agcClient(clientId: '123'));
      expect(back.accounts[2].teams.first.packages, ['com.example.app']);
      expect(back.accounts[3].teams.first.credential.sellerId, '12345678');
      final r2 = back.link('play:com.example.app')!.recipe;
      expect((r2.agcToo, r2.msRollout, r2.windowsBuildOn), (true, 20, 'github'));
      expect(r2.msLocales, ['en-us']);
    });

    test('errors name the store they came from', () {
      expect(
        ReleaseError.api(403, 'https://connect-api.cloud.huawei.com/api/publish/v2/app-info', ['x']).message,
        'AppGallery 403 on /api/publish/v2/app-info: x',
      );
      expect(ReleaseError.api(400, 'https://login.microsoftonline.com/t/oauth2/token', ['x']).message, 'Microsoft Store 400 on /t/oauth2/token: x');
      expect(ReleaseError.api(403, 'https://androidpublisher.googleapis.com/x', ['x']).message, startsWith('Google Play'));
    });

    test('a JSON value can be set at a path, making objects on the way', () {
      const v = J({
        'listings': {
          'en-us': {
            'baseListing': {'title': 'A'},
          },
        },
      });
      final w = v.setting(['listings', 'en-us', 'baseListing', 'releaseNotes'], 'Fixed it');
      expect(w['listings']['en-us']['baseListing']['releaseNotes'].string, 'Fixed it');
      expect(w['listings']['en-us']['baseListing']['title'].string, 'A');
      expect(v['listings']['en-us']['baseListing']['releaseNotes'].isNull, isTrue);
      expect(const J(null).setting(['a', 'b'], 1)['a']['b'].integer, 1);
    });

    test('Microsoft Store listing languages have names', () {
      expect(StoreLanguages.name('en-us'), 'English (United States)');
      expect(StoreLanguages.name('ar-sa'), 'Arabic (Saudi Arabia)');
      expect(StoreLanguages.name('zh-hans'), 'Chinese, Simplified');
    });
  });

  group('Store steps', () {
    late Directory logs;
    setUp(() => logs = Directory.systemTemp.createTempSync('rd-logs'));
    tearDown(() => logs.deleteSync(recursive: true));

    ReleaseRun run(ReleasePlatform platform, {bool cloud = false, PlayTarget? play, AgcTarget? agc, MsTarget? ms}) => ReleaseRun(
      plan: ReleasePlan(
        platform: platform,
        app: const StoreApp(id: 'play:com.example.app', name: 'App', bundleId: 'com.example.app'),
        projectRoot: logs.path,
        version: '1.2.0',
        build: 12,
        recipe: Recipe(),
        cloud: cloud ? CloudBuild(const GitHubRepo(owner: 'o', name: 'n', projectDir: '.'), CloudTarget.values[platform.index]) : null,
        play: play,
        appGallery: agc,
        microsoft: ms,
      ),
      logsDir: logs,
    );

    test('an Android run has only the stores it goes to', () {
      const play = PlayTarget(track: 'internal', status: 'completed');
      const agc = AgcTarget(appId: '101', release: AgcRelease.afterReview());
      List<StepId> ids(ReleaseRun r) => r.steps.map((s) => s.id).toList();
      expect(ids(run(ReleasePlatform.android, play: play, agc: agc)), [
        StepId.prepare,
        StepId.bundle,
        StepId.checkSigning,
        StepId.playRelease,
        StepId.agcRelease,
      ]);
      expect(ids(run(ReleasePlatform.android, play: play)), [StepId.prepare, StepId.bundle, StepId.checkSigning, StepId.playRelease]);
      expect(ids(run(ReleasePlatform.android, agc: agc)), [StepId.prepare, StepId.bundle, StepId.checkSigning, StepId.agcRelease]);
      expect(ids(run(ReleasePlatform.android, cloud: true, agc: agc)), [StepId.prepare, StepId.cloudBuild, StepId.agcRelease]);
    });

    test('Windows builds on GitHub, or here with the Store CLI', () {
      const ms = MsTarget(appId: '9NBLGGH4R315', rollout: 0);
      expect(StepId.stepsFor(ReleasePlatform.windows, cloud: true), [StepId.prepare, StepId.cloudBuild, StepId.msSubmit]);
      expect(StepId.stepsFor(ReleasePlatform.windows), [StepId.prepare, StepId.msixBuild, StepId.msixUpload, StepId.msSubmit]);
      expect(run(ReleasePlatform.windows, cloud: true, ms: ms).steps.map((s) => s.id), [StepId.prepare, StepId.cloudBuild, StepId.msSubmit]);
      expect(run(ReleasePlatform.windows, ms: ms).steps.map((s) => s.id), [StepId.prepare, StepId.msixBuild, StepId.msixUpload, StepId.msSubmit]);
      expect([StepId.playRelease, StepId.agcRelease, StepId.msixBuild, StepId.msixUpload, StepId.msSubmit].map((s) => s.title), [
        'Google Play',
        'AppGallery',
        'Build MSIX',
        'Upload to Partner Center',
        'Microsoft Store',
      ]);
    });
  });
}
