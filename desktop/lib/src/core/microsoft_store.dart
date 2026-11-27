import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'http_util.dart';
import 'json.dart';

/// An app in Partner Center, as Release Desk shows it.
class MsApp {
  MsApp({
    required this.id,
    required this.name,
    required this.packageIdentityName,
    this.firstPublished,
    this.lastSubmissionId,
    this.pendingSubmissionId,
    this.lastStatus,
    this.pendingStatus,
    List<String>? listingLanguages,
    Map<String, String>? releaseNotes,
  }) : listingLanguages = listingLanguages ?? [],
       releaseNotes = releaseNotes ?? {};

  final String id;
  final String name;
  final String packageIdentityName;
  final DateTime? firstPublished;
  final String? lastSubmissionId;
  final String? pendingSubmissionId;

  /// Filled when the app page reads its submissions.
  String? lastStatus;
  String? pendingStatus;
  List<String> listingLanguages;
  Map<String, String> releaseNotes;
}

/// Partner Center's Microsoft Store submission API (MSIX apps), with a
/// Microsoft Entra app added to Partner Center with the Manager role.
class MicrosoftStoreClient {
  MicrosoftStoreClient({required this.tenantId, required this.clientId, required this._secret, http.Client? client}) : _http = client ?? http.Client();

  static const base = 'https://manage.devcenter.microsoft.com/v1.0/my/';

  final String tenantId;
  final String clientId;
  final String _secret;
  final http.Client _http;
  String? _token;
  DateTime? _until;

  /// Percent-encodes everything but letters and digits, as the macOS app does.
  static String _enc(String s) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a)) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  Future<String> _bearer() async {
    if (_token != null && _until != null && _until!.isAfter(DateTime.now())) return _token!;
    final url = 'https://login.microsoftonline.com/$tenantId/oauth2/token';
    final req = http.Request('POST', Uri.parse(url))
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8'
      ..headers['User-Agent'] = userAgent
      ..body =
          'grant_type=client_credentials&client_id=${_enc(clientId)}&client_secret=${_enc(_secret)}&resource=${_enc('https://manage.devcenter.microsoft.com')}';
    http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 120)));
    } catch (e) {
      throw ReleaseError.network(describeError(e));
    }
    final json = J.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
    final t = json['access_token'].string;
    if (r.statusCode != 200 || t == null) {
      final message = json['error_description'].string?.split('\r\n').first ?? json['error'].string ?? 'Microsoft Entra refused the client';
      throw ReleaseError.api(r.statusCode, url, [message]);
    }
    _token = t;
    _until = DateTime.now().add(Duration(seconds: (json['expires_in'].integer ?? 3600) - 120));
    return t;
  }

  /// One call. [path] is relative to [base] (as `@nextLink` is), or a full URL.
  Future<J> send(String method, String path, {Object? body}) async {
    final url = path.startsWith('https://') ? path : '$base$path';
    var attempt = 0;
    while (true) {
      attempt++;
      http.Response r;
      try {
        // An empty POST still sends Content-Length: 0, which Partner Center wants.
        final req = http.Request(method, Uri.parse(url))
          ..headers['Authorization'] = 'Bearer ${await _bearer()}'
          ..headers['User-Agent'] = userAgent;
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 120)));
      } on ReleaseError {
        rethrow;
      } catch (e) {
        if (isTransportError(e) && attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        throw ReleaseError.network(describeError(e));
      }
      final json = J.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
      if (r.statusCode >= 200 && r.statusCode < 300) return json;
      if ((r.statusCode == 429 || r.statusCode >= 500) && attempt < 4) {
        await Future<void>.delayed(Duration(seconds: 4 * attempt));
        continue;
      }
      if (r.statusCode == 401) _token = null;
      final message = json['message'].string ?? json['error']['message'].string ?? r.reasonPhrase ?? 'HTTP ${r.statusCode}';
      throw ReleaseError.api(r.statusCode, url, [message]);
    }
  }

  static MsApp _app(J j) => MsApp(
    id: j['id'].string ?? '',
    name: j['primaryName'].string ?? j['id'].string ?? '?',
    packageIdentityName: j['packageIdentityName'].string ?? '',
    firstPublished: j['firstPublishedDate'].date,
    lastSubmissionId: j['lastPublishedApplicationSubmission']['id'].string,
    pendingSubmissionId: j['pendingApplicationSubmission']['id'].string,
  );

  Future<List<MsApp>> applications() async {
    final out = <MsApp>[];
    String? next = 'applications?top=100&skip=0';
    for (var pages = 0; next != null && pages < 20; pages++) {
      final r = await send('GET', next);
      out.addAll(r['value'].list.map(_app));
      next = r['@nextLink'].string;
    }
    return out;
  }

  Future<MsApp> application(String id) async => _app(await send('GET', 'applications/$id'));

  Future<J> submission(String appId, String id) => send('GET', 'applications/$appId/submissions/$id');

  Future<({String status, List<String> errors})> status(String appId, String submissionId) async {
    final r = await send('GET', 'applications/$appId/submissions/$submissionId/status');
    final errors = r['statusDetails']['errors'].list.map((e) => '${e['code'].string ?? ''} ${e['details'].string ?? ''}'.trim()).toList();
    return (status: r['status'].string ?? '?', errors: errors);
  }

  /// The app with its submissions read: status, listing languages and release notes.
  Future<MsApp> details(String id) async {
    final app = await application(id);
    final pending = app.pendingSubmissionId;
    if (pending != null) {
      try {
        app.pendingStatus = (await status(id, pending)).status;
      } catch (_) {}
    }
    final sub = pending ?? app.lastSubmissionId;
    if (sub != null) {
      J? s;
      try {
        s = await submission(id, sub);
      } catch (_) {}
      if (s != null) {
        if (pending == null) app.lastStatus = s['status'].string;
        for (final e in s['listings'].map.entries) {
          app.listingLanguages.add(e.key);
          final notes = J(e.value)['baseListing']['releaseNotes'].string;
          if (notes != null && notes.isNotEmpty) app.releaseNotes[e.key] = notes;
        }
        app.listingLanguages.sort();
      }
    }
    final last = app.lastSubmissionId;
    if (app.lastStatus == null && last != null) {
      try {
        app.lastStatus = (await status(id, last)).status;
      } catch (_) {}
    }
    return app;
  }

  /// Writes release notes into the languages the submission has; returns a line per language.
  Future<List<String>> setReleaseNotes(String appId, String submissionId, Map<String, String> notes) async {
    var s = await submission(appId, submissionId);
    final languages = s['listings'].map.keys.toSet();
    final lines = <String>[];
    final langs = notes.keys.toList()..sort();
    for (final lang in langs) {
      final key = lang.toLowerCase();
      if (!languages.contains(key)) {
        lines.add('$key: no listing in this language on the Store, skipped');
        continue;
      }
      s = s.setting(['listings', key, 'baseListing', 'releaseNotes'], notes[lang]);
      lines.add('$key: written');
    }
    if (lines.any((l) => l.endsWith('written'))) {
      await send('PUT', 'applications/$appId/submissions/$submissionId', body: s.value);
    }
    return lines;
  }

  Future<void> commit(String appId, String submissionId) async {
    await send('POST', 'applications/$appId/submissions/$submissionId/commit');
  }

  void close() => _http.close();
}
