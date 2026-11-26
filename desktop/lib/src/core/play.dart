import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'google.dart';
import 'http_util.dart';
import 'json.dart';

class PlayApp {
  const PlayApp(this.packageName, this.name);
  final String packageName;
  final String name;
}

class PlayRelease {
  const PlayRelease({required this.name, required this.versionCodes, required this.status, this.userFraction, this.notes = const {}});

  final String name;
  final List<String> versionCodes;
  final String status;
  final double? userFraction;
  final Map<String, String> notes;

  int get maxCode => versionCodes.map(int.tryParse).whereType<int>().fold(0, (a, b) => a > b ? a : b);

  String get statusLabel => switch (status) {
    'completed' => 'Live',
    'inProgress' => userFraction == null ? 'Rolling out' : 'Rolling out · ${(userFraction! * 100).round()}%',
    'draft' => 'Draft',
    'halted' => 'Halted',
    _ => status.isEmpty ? status : status[0].toUpperCase() + status.substring(1),
  };

  factory PlayRelease.fromJson(J r) => PlayRelease(
    name: r['name'].string ?? '',
    versionCodes: r['versionCodes'].list.map((c) => c.string).whereType<String>().toList(),
    status: r['status'].string ?? '?',
    userFraction: r['userFraction'].number,
    notes: {
      for (final n in r['releaseNotes'].list)
        if (n['language'].string != null) n['language'].string!: n['text'].string ?? '',
    },
  );
}

class PlayTrack {
  const PlayTrack(this.track, this.releases);
  final String track;
  final List<PlayRelease> releases;

  String get title => switch (track) {
    'internal' => 'Internal testing',
    'alpha' => 'Closed testing',
    'beta' => 'Open testing',
    'production' => 'Production',
    _ => track.replaceAll(':', ' · ').split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' '),
  };

  /// Lower sorts first: internal → closed → open → production → the rest.
  int get order => const {'internal': 0, 'alpha': 1, 'beta': 2, 'production': 3}[track] ?? 4;
}

class PlayAppDetails {
  const PlayAppDetails({this.title, this.iconUrl, this.defaultLanguage, this.contactEmail});
  final String? title;
  final String? iconUrl;
  final String? defaultLanguage;
  final String? contactEmail;
}

/// Google Play Developer API (androidpublisher v3) and the Reporting API's
/// app search, signed in as a person with their own Google account.
class PlayClient {
  PlayClient(this.user, {http.Client? client}) : _http = client ?? http.Client();

  final GoogleUser user;
  final http.Client _http;
  String? _token;
  DateTime? _until;
  static const api = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';

  Future<String> _bearer() async {
    if (_token != null && _until != null && _until!.isAfter(DateTime.now())) return _token!;
    final t = await GoogleSignIn.accessToken(user, _http);
    _token = t.token;
    _until = DateTime.now().add(Duration(seconds: t.expiresIn - 120));
    return t.token;
  }

  Future<J> send(String method, String url, {Object? body, File? upload}) async {
    var attempt = 0;
    while (true) {
      attempt++;
      http.Response r;
      try {
        final bearer = await _bearer();
        if (upload != null) {
          final length = await upload.length();
          final req = http.StreamedRequest(method, Uri.parse(url))
            ..headers['Authorization'] = 'Bearer $bearer'
            ..headers['Content-Type'] = 'application/octet-stream'
            ..headers['User-Agent'] = userAgent
            ..contentLength = length;
          final sending = _http.send(req);
          await upload.openRead().forEach(req.sink.add);
          await req.sink.close();
          r = await http.Response.fromStream(await sending.timeout(const Duration(minutes: 60)));
        } else {
          final req = http.Request(method, Uri.parse(url))
            ..headers['Authorization'] = 'Bearer $bearer'
            ..headers['User-Agent'] = userAgent;
          if (body != null) {
            req.headers['Content-Type'] = 'application/json';
            req.body = jsonEncode(body);
          }
          r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 120)));
        }
      } on ReleaseError {
        rethrow;
      } catch (e) {
        if (isTransportError(e) && attempt < 3 && upload == null) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        throw ReleaseError.network(describeError(e));
      }
      final json = J.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
      if (r.statusCode >= 200 && r.statusCode < 300) return json;
      if ((r.statusCode == 429 || r.statusCode >= 500) && attempt < 4 && upload == null) {
        await Future<void>.delayed(Duration(seconds: 3 * attempt));
        continue;
      }
      if (r.statusCode == 401) _token = null;
      throw ReleaseError.api(r.statusCode, url, [json['error']['message'].string ?? r.reasonPhrase ?? 'HTTP ${r.statusCode}']);
    }
  }

  /// Apps this account can see. Needs the Play Developer Reporting API on in
  /// the OAuth client's Cloud project; null when it is not.
  Future<List<PlayApp>?> searchApps() async {
    final apps = <PlayApp>[];
    String? page;
    do {
      var url = 'https://playdeveloperreporting.googleapis.com/v1beta1/apps:search?pageSize=100';
      if (page != null) url += '&pageToken=${Uri.encodeQueryComponent(page)}';
      J r;
      try {
        r = await send('GET', url);
      } on ReleaseError catch (e) {
        if (e.status == 403 || e.status == 404) return null;
        rethrow;
      }
      for (final a in r['apps'].list) {
        final p = a['packageName'].string;
        if (p != null) apps.add(PlayApp(p, a['displayName'].string ?? p));
      }
      page = r['nextPageToken'].string;
    } while (page != null);
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return apps;
  }

  // MARK: Edits

  Future<String> _openEdit(String package) async {
    final r = await send('POST', '$api/$package/edits', body: <String, Object?>{});
    final id = r['id'].string;
    if (id == null) throw ReleaseError.precondition('Play did not open an edit for $package');
    return id;
  }

  Future<void> _closeEdit(String package, String edit) async {
    try {
      await send('DELETE', '$api/$package/edits/$edit');
    } catch (_) {}
  }

  /// Tracks, their releases and the store listing title and icon, read in a
  /// throwaway edit.
  Future<({List<PlayTrack> tracks, PlayAppDetails details})> overview(String package) async {
    final edit = await _openEdit(package);
    try {
      final t = await send('GET', '$api/$package/edits/$edit/tracks');
      J? d;
      try {
        d = await send('GET', '$api/$package/edits/$edit/details');
      } catch (_) {}
      final lang = d?['defaultLanguage'].string;
      String? title, icon;
      if (lang != null) {
        try {
          final l = await send('GET', '$api/$package/edits/$edit/listings/$lang');
          title = l['title'].string;
          icon = (await send('GET', '$api/$package/edits/$edit/listings/$lang/icon'))['images'][0]['url'].string;
        } catch (_) {}
      }
      final tracks = t['tracks'].list.map((tr) => PlayTrack(tr['track'].string ?? '?', tr['releases'].list.map(PlayRelease.fromJson).toList())).toList()
        ..sort((a, b) => a.order != b.order ? a.order - b.order : a.track.compareTo(b.track));
      return (tracks: tracks, details: PlayAppDetails(title: title, iconUrl: icon, defaultLanguage: lang, contactEmail: d?['contactEmail'].string));
    } finally {
      await _closeEdit(package, edit);
    }
  }

  /// Uploads an .aab and releases it to a track in one edit. [log] receives
  /// progress lines.
  Future<({String versionCode, String status})> release({
    required String package,
    required File bundle,
    required String track,
    required String name,
    required String status,
    double? userFraction,
    Map<String, String> notes = const {},
    required void Function(String) log,
  }) async {
    final edit = await _openEdit(package);
    var committed = false;
    try {
      log('Uploading ${bundle.uri.pathSegments.last} to edit $edit…');
      final up = await send(
        'POST',
        'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$package/edits/$edit/bundles?uploadType=media',
        upload: bundle,
      );
      final code = up['versionCode'].string;
      if (code == null) throw const ReleaseError.precondition('Play did not return a version code');
      log('Play read version code $code');
      var finalStatus = status;
      for (var attempt = 0; attempt < 2; attempt++) {
        final rel = <String, Object?>{
          'name': name,
          'versionCodes': [code],
          'status': finalStatus,
        };
        if (finalStatus == 'inProgress' && userFraction != null) rel['userFraction'] = userFraction;
        final ns = notes.entries.where((e) => e.value.trim().isNotEmpty).toList()..sort((a, b) => a.key.compareTo(b.key));
        if (ns.isNotEmpty) {
          rel['releaseNotes'] = [
            for (final n in ns) {'language': n.key, 'text': n.value},
          ];
        }
        try {
          await send(
            'PUT',
            '$api/$package/edits/$edit/tracks/$track',
            body: {
              'track': track,
              'releases': [rel],
            },
          );
          break;
        } on ReleaseError catch (e) {
          // Apps never published yet only take draft releases.
          if (attempt == 0 && e.message.toLowerCase().contains('draft app')) {
            log('This app is still a draft on Play, so the release goes in as a draft.');
            finalStatus = 'draft';
          } else {
            rethrow;
          }
        }
      }
      log('Track $track → $name ($code), $finalStatus');
      await send('POST', '$api/$package/edits/$edit:commit');
      committed = true;
      log('Edit committed');
      return (versionCode: code, status: finalStatus);
    } finally {
      if (!committed) await _closeEdit(package, edit);
    }
  }

  void close() => _http.close();
}
