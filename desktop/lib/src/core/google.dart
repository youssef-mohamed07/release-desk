import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'errors.dart';
import 'json.dart';

/// The OAuth client Release Desk signs in to Google with: a "Desktop app"
/// client the user creates in Google Cloud (the client_secret_….json file).
class OAuthClient {
  const OAuthClient({required this.clientId, required this.clientSecret, this.projectId});

  factory OAuthClient.fromFile(String text) {
    final obj = J.decode(text);
    if (obj.isNull) throw const ReleaseError.invalidKey('That file is not JSON.');
    final c = obj['installed'].isNull ? obj['web'] : obj['installed'];
    final id = c['client_id'].string, secret = c['client_secret'].string;
    if (id == null || secret == null) {
      throw const ReleaseError.invalidKey('That file is not a Google OAuth client (client_secret_….json).');
    }
    return OAuthClient(clientId: id, clientSecret: secret, projectId: c['project_id'].string);
  }

  factory OAuthClient.fromJson(Map<String, Object?> j) =>
      OAuthClient(clientId: j['clientID'] as String? ?? '', clientSecret: j['clientSecret'] as String? ?? '', projectId: j['projectID'] as String?);

  final String clientId;
  final String clientSecret;
  final String? projectId;

  Map<String, Object?> toJson() => {'clientID': clientId, 'clientSecret': clientSecret, 'projectID': projectId};

  static const secretKey = 'google-oauth-client';
}

/// A person signed in with their own Google account: what Release Desk keeps
/// (in the OS keychain) to get fresh access tokens.
class GoogleUser {
  const GoogleUser({required this.email, required this.refreshToken, required this.client});

  factory GoogleUser.fromJson(Map<String, Object?> j) => GoogleUser(
    email: j['email'] as String? ?? '',
    refreshToken: j['refreshToken'] as String? ?? '',
    client: OAuthClient.fromJson((j['client'] as Map?)?.cast<String, Object?>() ?? const {}),
  );

  final String email;
  final String refreshToken;
  final OAuthClient client;

  Map<String, Object?> toJson() => {'email': email, 'refreshToken': refreshToken, 'client': client.toJson()};
}

class GoogleSignIn {
  static const scopes = ['openid', 'email', 'https://www.googleapis.com/auth/androidpublisher', 'https://www.googleapis.com/auth/playdeveloperreporting'];

  /// Opens Google's sign-in in the browser and waits for it to come back to a
  /// one-time listener on 127.0.0.1 (OAuth for installed apps, with PKCE).
  static Future<GoogleUser> signIn(
    OAuthClient client, {
    required Future<void> Function(Uri) open,
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
    http.Client? httpClient,
  }) async {
    final verifier = randomString(64);
    final challenge = pkceChallenge(verifier);
    final state = randomString(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    try {
      final url = authorizationUrl(client, redirect: redirect, challenge: challenge, state: state, loginHint: loginHint);
      final query = waitForRedirect(server, timeout);
      try {
        await open(url);
      } catch (_) {
        query.ignore();
        rethrow;
      }
      final q = await query;
      final error = q['error'];
      if (error != null) {
        throw ReleaseError.precondition(error == 'access_denied' ? 'Google sign-in was cancelled.' : 'Google said: $error');
      }
      final code = q['code'];
      if (q['state'] != state || code == null) {
        throw const ReleaseError.precondition("Google's answer did not match this sign-in. Try again.");
      }
      final token = await tokenRequest({
        'code': code,
        'client_id': client.clientId,
        'client_secret': client.clientSecret,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      }, httpClient);
      final refresh = token['refresh_token'].string;
      if (refresh == null) {
        throw const ReleaseError.precondition('Google gave no refresh token. Remove Release Desk at myaccount.google.com/permissions and sign in again.');
      }
      return GoogleUser(email: emailFromIdToken(token['id_token'].string) ?? 'Google account', refreshToken: refresh, client: client);
    } finally {
      await server.close(force: true);
    }
  }

  static Uri authorizationUrl(OAuthClient client, {required String redirect, required String challenge, required String state, String? loginHint}) =>
      Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': client.clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent select_account',
        'login_hint': ?loginHint,
      });

  static String pkceChallenge(String verifier) => base64UrlNoPad(sha256.convert(utf8.encode(verifier)).bytes);

  static String? emailFromIdToken(String? idToken) {
    if (idToken == null) return null;
    final parts = idToken.split('.');
    if (parts.length < 2) return null;
    try {
      return J.decode(utf8.decode(base64UrlDecodeLoose(parts[1])))['email'].string;
    } catch (_) {
      return null;
    }
  }

  /// Takes the first request to `/` and answers it with a small page.
  static Future<Map<String, String>> waitForRedirect(HttpServer server, Duration timeout) async {
    final c = Completer<Map<String, String>>();
    late final StreamSubscription<HttpRequest> sub;
    sub = server.listen((req) async {
      if (req.uri.path != '/') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final q = req.uri.queryParameters;
      final ok = q.containsKey('code');
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..headers.set('Connection', 'close')
        ..write(_page(ok));
      await req.response.close();
      if (!c.isCompleted) c.complete(q);
    });
    try {
      return await c.future.timeout(timeout, onTimeout: () => throw const ReleaseError.precondition('Google sign-in timed out. Try again.'));
    } finally {
      await sub.cancel();
    }
  }

  /// A fresh access token for a signed-in user.
  static Future<({String token, int expiresIn})> accessToken(GoogleUser user, [http.Client? client]) async {
    final r = await tokenRequest({
      'client_id': user.client.clientId,
      'client_secret': user.client.clientSecret,
      'refresh_token': user.refreshToken,
      'grant_type': 'refresh_token',
    }, client);
    final t = r['access_token'].string;
    if (t == null) throw ReleaseError.precondition('Google did not refresh the sign-in for ${user.email}. Sign in again.');
    return (token: t, expiresIn: r['expires_in'].integer ?? 3600);
  }

  static Future<J> tokenRequest(Map<String, String> form, [http.Client? client]) async {
    final c = client ?? http.Client();
    try {
      final r = await c.post(Uri.parse('https://oauth2.googleapis.com/token'), body: form).timeout(const Duration(seconds: 60));
      final json = J.decode(r.body);
      if (r.statusCode != 200) {
        throw ReleaseError.api(r.statusCode, 'oauth token', [json['error_description'].string ?? json['error'].string ?? 'Google refused the sign-in']);
      }
      return json;
    } on ReleaseError {
      rethrow;
    } catch (e) {
      throw ReleaseError.network(describeError(e));
    } finally {
      if (client == null) c.close();
    }
  }

  static String randomString(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String _page(bool ok) =>
      '''<!doctype html><html><head><meta charset="utf-8"><title>Release Desk</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;font:16px system-ui,-apple-system,"Segoe UI",sans-serif;background:#0b0d1a;color:#fff}
.c{text-align:center}.i{font-size:56px}h1{font-weight:700;margin:.3em 0}p{color:#aab}</style></head>
<body><div class="c"><div class="i">${ok ? '&#9992;&#65039;' : '&#9995;'}</div><h1>${ok ? "You're signed in" : 'Sign-in stopped'}</h1>
<p>${ok ? 'Go back to Release Desk. You can close this tab.' : 'Go back to Release Desk and try again.'}</p></div></body></html>''';
}
