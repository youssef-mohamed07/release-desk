import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'http_util.dart';
import 'json.dart';

/// An app on Huawei AppGallery, as Release Desk shows it.
class AgcApp {
  const AgcApp({
    required this.appId,
    required this.package,
    required this.name,
    this.version,
    this.versionOnShelf,
    this.releaseState,
    this.reviewNote,
    this.newFeatures = const {},
    this.phasedState,
  });

  final String appId;
  final String package;
  final String name;

  /// The version being prepared (draft or in review) and the one on sale.
  final String? version;
  final String? versionOnShelf;
  final int? releaseState;
  final String? reviewNote;

  /// What's new per language of the version being prepared.
  final Map<String, String> newFeatures;
  final String? phasedState;

  /// AppGallery's release states, in words.
  String get stateTitle {
    final s = releaseState;
    if (s == null) return 'Unknown';
    return stateTitles[s] ?? 'State $s';
  }

  static const stateTitles = {
    0: 'Released',
    1: 'Release rejected',
    2: 'Removed',
    3: 'Releasing',
    4: 'In review',
    5: 'Update in review',
    6: 'Removal requested',
    7: 'Draft',
    8: 'Update rejected',
    9: 'Removal rejected',
    10: 'Removed by you',
    11: 'Release canceled',
    12: 'In pre-review',
    13: 'Pre-review failed',
  };
}

/// How an AppGallery release goes out once it passes review: after review,
/// or phased to a percentage of users over some days.
class AgcRelease {
  const AgcRelease.afterReview() : percent = null, days = 0;
  const AgcRelease.phased({required double this.percent, required this.days});

  final double? percent;
  final int days;

  bool get isPhased => percent != null;
}

/// Huawei AppGallery Connect's Publishing API, with an API client (client ID
/// and key) made under Users and permissions → API key → Connect API.
class AppGalleryClient {
  AppGalleryClient({required this.clientId, required this._secret, http.Client? client, this.poll = const Duration(seconds: 20)})
    : _http = client ?? http.Client();

  static const base = 'https://connect-api.cloud.huawei.com/api';

  final String clientId;
  final String _secret;
  final http.Client _http;

  /// How long to wait between asks while AppGallery processes a package.
  final Duration poll;
  String? _token;
  DateTime? _until;

  Future<String> _bearer() async {
    if (_token != null && _until != null && _until!.isAfter(DateTime.now())) return _token!;
    const url = '$base/oauth2/v1/token';
    final req = http.Request('POST', Uri.parse(url))
      ..headers['Content-Type'] = 'application/json'
      ..headers['User-Agent'] = userAgent
      ..body = jsonEncode({'grant_type': 'client_credentials', 'client_id': clientId, 'client_secret': _secret});
    http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 120)));
    } catch (e) {
      throw ReleaseError.network(describeError(e));
    }
    final json = J.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
    final t = json['access_token'].string;
    if (r.statusCode != 200 || t == null) {
      throw ReleaseError.api(r.statusCode, url, [json['ret']['msg'].string ?? 'AppGallery Connect refused the client ID and key']);
    }
    _token = t;
    _until = DateTime.now().add(Duration(seconds: (json['expires_in'].integer ?? 172800) - 300));
    return t;
  }

  /// Calls the Publishing API. AppGallery answers 200 with a `ret.code`
  /// that is not 0 when something is wrong, so both are checked.
  Future<J> send(String method, String path, {Map<String, String> query = const {}, Object? body}) async {
    final keys = query.keys.toList()..sort();
    final url = Uri.parse('$base$path').replace(queryParameters: query.isEmpty ? null : {for (final k in keys) k: query[k]!});
    var attempt = 0;
    while (true) {
      attempt++;
      http.Response r;
      try {
        final req = http.Request(method, url)
          ..headers['client_id'] = clientId
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
      final code = json['ret']['code'].integer ?? 0;
      if (r.statusCode >= 200 && r.statusCode < 300 && code == 0) return json;
      if (r.statusCode >= 500 && attempt < 4) {
        await Future<void>.delayed(Duration(seconds: 3 * attempt));
        continue;
      }
      if (r.statusCode == 401) _token = null;
      final message = json['ret']['msg'].string ?? r.reasonPhrase ?? 'HTTP ${r.statusCode}';
      throw ReleaseError.api(code != 0 ? code : r.statusCode, '$base$path', [message]);
    }
  }

  /// App ids and names for package names (50 at a time).
  Future<Map<String, ({String appId, String name})>> appIds(List<String> packages) async {
    final out = <String, ({String appId, String name})>{};
    for (var start = 0; start < packages.length; start += 50) {
      final chunk = packages.sublist(start, (start + 50).clamp(0, packages.length));
      final r = await send('GET', '/publish/v2/appid-list', query: {'packageName': chunk.join(',')});
      // The list keeps the order of the request.
      for (final (i, item) in r['appids'].list.indexed) {
        if (i >= chunk.length) break;
        final id = item['value'].string;
        if (id != null) out[chunk[i]] = (appId: id, name: item['key'].string ?? chunk[i]);
      }
    }
    return out;
  }

  /// Every Android app of the team, when the API client may read projects.
  Future<List<({String appId, String package, String name})>> allApps() async {
    final out = <({String appId, String package, String name})>[];
    for (var page = 1; page < 20; page++) {
      final r = await send('GET', '/project-service/v1/projects', query: {'fromPage': '$page', 'pageSize': '100'});
      final projects = r['projectList'].list;
      for (final p in projects) {
        for (final a in p['appList'].list) {
          if ((a['appType'].integer ?? 1) != 1) continue;
          final id = a['appId'].string, pkg = a['packageName'].string;
          if (id != null && pkg != null) out.add((appId: id, package: pkg, name: a['appName'].string ?? pkg));
        }
      }
      if (projects.length < 100) break;
    }
    return out;
  }

  Future<AgcApp> app(String appId, String package) async {
    final r = await send('GET', '/publish/v2/app-info', query: {'appId': appId, 'releaseType': '1'});
    final info = r['appInfo'];
    final languages = r['languages'].list;
    final defaultLang = info['defaultLang'].string;
    final name = languages.where((l) => l['lang'].string == defaultLang).firstOrNull?['appName'].string ?? languages.firstOrNull?['appName'].string ?? package;
    return AgcApp(
      appId: appId,
      package: package,
      name: name,
      version: info['versionNumber'].string,
      versionOnShelf: info['onShelfVersionNumber'].string,
      releaseState: info['releaseState'].integer,
      reviewNote: r['auditInfo']['auditOpinion'].string,
      newFeatures: {
        for (final l in languages)
          if (l['lang'].string != null && (l['newFeatures'].string ?? '').isNotEmpty) l['lang'].string!: l['newFeatures'].string!,
      },
      phasedState: r['phasedReleaseInfo']['state'].string,
    );
  }

  /// Uploads an app bundle or APK, attaches it to the version being
  /// prepared and waits until AppGallery has processed it.
  Future<void> upload(String appId, File file, {required void Function(String) log, CancelToken? cancel}) async {
    final size = await file.length();
    final fileName = file.uri.pathSegments.last;
    final mb = size ~/ (1024 * 1024);
    if (fileName.toLowerCase().endsWith('.aab') && size > 150 * 1024 * 1024) {
      throw ReleaseError.precondition('AppGallery takes app bundles up to 150 MB; this one is $mb MB.');
    }
    final r = await send(
      'GET',
      '/publish/v2/upload-url/for-obs',
      query: {'appId': appId, 'fileName': fileName, 'contentLength': '$size', 'chineseMainlandFlag': '0'},
    );
    final info = r['urlInfo'];
    final url = Uri.tryParse(info['url'].string ?? '');
    final objectId = info['objectId'].string;
    if (url == null || !url.hasScheme || objectId == null) throw const ReleaseError.precondition('AppGallery gave no upload address');
    log('Uploading $fileName ($mb MB)');
    final put = http.StreamedRequest(info['method'].string ?? 'PUT', url)..contentLength = size;
    for (final e in info['headers'].map.entries) {
      if (e.value is String) put.headers[e.key] = e.value! as String;
    }
    http.Response up;
    try {
      final sending = _http.send(put);
      await file.openRead().forEach(put.sink.add);
      await put.sink.close();
      up = await http.Response.fromStream(await sending.timeout(const Duration(minutes: 60)));
    } catch (e) {
      throw ReleaseError.network(describeError(e));
    }
    if (up.statusCode < 200 || up.statusCode >= 300) {
      final text = utf8.decode(up.bodyBytes, allowMalformed: true);
      throw ReleaseError.api(up.statusCode, url.toString(), [text.isEmpty ? 'Upload failed' : (text.length > 300 ? text.substring(0, 300) : text)]);
    }
    final bound = await send(
      'PUT',
      '/publish/v2/app-file-info',
      query: {'appId': appId, 'releaseType': '1'},
      body: {
        'fileType': 5,
        'files': [
          {'fileName': fileName, 'fileDestUrl': objectId},
        ],
      },
    );
    final pkg = bound['pkgVersion'].list.firstOrNull?.string;
    if (pkg == null) {
      log('Attached to the version');
      return;
    }
    log('Attached to the version; AppGallery is processing it');
    for (var i = 0; i < 45; i++) {
      if (cancel != null) {
        await cancel.sleep(poll);
      } else {
        await Future<void>.delayed(poll);
      }
      final s = await send('GET', '/publish/v2/package/compile/status', query: {'appId': appId, 'pkgIds': pkg});
      switch (s['pkgStateList'][0]['successStatus'].integer) {
        case 0:
          log('Processed');
          return;
        case 2:
          throw const ReleaseError.precondition('AppGallery could not process the package. Check it in AppGallery Connect.');
      }
    }
    throw const ReleaseError.precondition('AppGallery is still processing the package after 15 minutes.');
  }

  /// Writes What's new for each language (adding the language when needed).
  Future<void> setWhatsNew(String appId, Map<String, String> notes) async {
    final langs = notes.keys.toList()..sort();
    for (final lang in langs) {
      await send(
        'PUT',
        '/publish/v2/app-language-info',
        query: {'appId': appId, 'releaseType': '1'},
        body: {'lang': language(lang), 'newFeatures': notes[lang]},
      );
    }
  }

  /// Sends the version for review. A phased release needs a version released before.
  Future<void> submit(String appId, AgcRelease release, {DateTime? now}) async {
    if (!release.isPhased) {
      await send('POST', '/publish/v2/app-submit', query: {'appId': appId});
      return;
    }
    final start = (now ?? DateTime.now()).add(const Duration(minutes: 10));
    await send(
      'POST',
      '/publish/v2/app-submit',
      query: {'appId': appId, 'releaseType': '3'},
      body: {
        'phasedReleaseStartTime': time(start),
        'phasedReleaseEndTime': time(start.add(Duration(days: release.days < 1 ? 1 : release.days))),
        'phasedReleasePercent': release.percent!.toStringAsFixed(2),
        'phasedReleaseDescription': 'Phased release from Release Desk',
      },
    );
  }

  /// AppGallery's time format: local time with its offset, like
  /// 2026-11-27T10:00:00+0200.
  static String time(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final offset = l.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    return '${l.year.toString().padLeft(4, '0')}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:${two(l.minute)}:${two(l.second)}'
        '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}${two(minutes % 60)}';
  }

  /// AppGallery's language codes: mostly Play's, but Hebrew is he_IL.
  static String language(String code) => switch (code) {
    'iw-IL' || 'he-IL' || 'he' => 'he_IL',
    _ => code,
  };

  void close() => _http.close();
}
