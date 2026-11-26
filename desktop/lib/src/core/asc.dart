import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'asc_key.dart';
import 'errors.dart';
import 'http_util.dart';
import 'json.dart';

/// A store app. App Store apps use Apple's numeric id; Play apps use
/// `play:<package>` so both can live in one list.
class StoreApp {
  const StoreApp({required this.id, required this.name, required this.bundleId, this.sku = '', this.primaryLocale = ''});

  final String id;
  final String name;
  final String bundleId;
  final String sku;
  final String primaryLocale;

  bool get isPlay => id.startsWith('play:');
  String get playPackage => isPlay ? id.substring(5) : bundleId;

  StoreApp copyWith({String? name, String? primaryLocale}) =>
      StoreApp(id: id, name: name ?? this.name, bundleId: bundleId, sku: sku, primaryLocale: primaryLocale ?? this.primaryLocale);
}

class AscBuild {
  const AscBuild({
    required this.id,
    required this.number,
    required this.version,
    required this.platform,
    this.uploaded,
    this.expires,
    required this.processingState,
    required this.expired,
    this.minOS,
    this.iconTemplate,
    this.internalState,
    this.externalState,
    this.reviewState,
    this.groupIds = const [],
    this.usesNonExemptEncryption,
  });

  final String id;

  /// The build number (CFBundleVersion).
  final String number;

  /// The version it belongs to (CFBundleShortVersionString).
  final String version;
  final String platform;
  final DateTime? uploaded;
  final DateTime? expires;
  final String processingState;
  final bool expired;
  final String? minOS;
  final String? iconTemplate;
  final String? internalState;
  final String? externalState;
  final String? reviewState;
  final List<String> groupIds;
  final bool? usesNonExemptEncryption;

  String? iconUrl([int size = 256]) => iconTemplate == null ? null : iconFromTemplate(iconTemplate!, size);

  int get numericNumber => int.tryParse(number.split('.').last) ?? 0;
}

String iconFromTemplate(String t, int size) => t.replaceAll('{w}', '$size').replaceAll('{h}', '$size').replaceAll('{f}', 'png');

class AscBetaGroup {
  AscBetaGroup({
    required this.id,
    required this.name,
    required this.isInternal,
    required this.allBuilds,
    required this.publicLinkEnabled,
    this.publicLink,
    this.created,
    this.testerCount,
  });

  final String id;
  final String name;
  final bool isInternal;
  final bool allBuilds;
  final bool publicLinkEnabled;
  final String? publicLink;
  final DateTime? created;
  int? testerCount;
}

class AscVersion {
  const AscVersion({required this.id, required this.version, required this.platform, required this.state, this.created, this.releaseType});

  final String id;
  final String version;
  final String platform;
  final String state;
  final DateTime? created;
  final String? releaseType;
}

/// Versions Apple still lets you edit and submit.
const editableVersionStates = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'};

class AscBetaLocalization {
  const AscBetaLocalization({required this.id, required this.locale, required this.whatsNew});
  final String id;
  final String locale;
  final String whatsNew;
}

class BuildBetaState {
  const BuildBetaState(this.internalState, this.externalState);
  final String? internalState;
  final String? externalState;
}

/// A thin App Store Connect API client: signs requests, follows pages,
/// retries rate limits and turns JSON:API errors into readable messages.
class AscClient {
  AscClient(this.key, {http.Client? client}) : _http = client ?? http.Client();

  final AscKey key;
  final http.Client _http;
  String? _token;
  DateTime? _tokenUntil;
  static const _base = 'https://api.appstoreconnect.apple.com';

  String _bearer() {
    final now = DateTime.now();
    if (_token != null && _tokenUntil != null && _tokenUntil!.isAfter(now)) return _token!;
    _token = key.token();
    _tokenUntil = now.add(const Duration(minutes: 15));
    return _token!;
  }

  /// One request. [path] starts with `/v1/…`, or is a full `links.next` URL.
  Future<J> send(String method, String path, {Map<String, String> query = const {}, Object? body}) async {
    final Uri url;
    if (path.startsWith('https://')) {
      url = Uri.parse(path);
    } else {
      final keys = query.keys.toList()..sort();
      url = Uri.parse('$_base$path').replace(queryParameters: query.isEmpty ? null : {for (final k in keys) k: query[k]!});
    }
    var attempt = 0;
    while (true) {
      attempt++;
      final req = http.Request(method, url)
        ..headers['Authorization'] = 'Bearer ${_bearer()}'
        ..headers['User-Agent'] = userAgent;
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      http.Response r;
      try {
        r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 60)));
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
        await Future<void>.delayed(Duration(seconds: 3 * attempt));
        continue;
      }
      if (r.statusCode == 401) _token = null;
      final messages = json['errors'].list
          .map((e) => [e['code'].string, e['detail'].string ?? e['title'].string].whereType<String>().join(' '))
          .where((s) => s.isNotEmpty)
          .toList();
      throw ReleaseError.api(r.statusCode, url.path, messages.isEmpty ? [r.reasonPhrase ?? 'HTTP ${r.statusCode}'] : messages);
    }
  }

  /// Every page of a collection: the resources and everything they included.
  Future<({List<J> data, List<J> included})> all(String path, {Map<String, String> query = const {}, int maxPages = 20}) async {
    final data = <J>[];
    final included = <J>[];
    var page = await send('GET', path, query: query);
    for (var i = 0; i < maxPages; i++) {
      data.addAll(page['data'].list);
      included.addAll(page['included'].list);
      final next = page['links']['next'].string;
      if (next == null) break;
      page = await send('GET', next);
    }
    return (data: data, included: included);
  }

  // MARK: Endpoints

  Future<List<StoreApp>> apps() async {
    final r = await all('/v1/apps', query: {'fields[apps]': 'name,bundleId,sku,primaryLocale', 'limit': '200'});
    final list = r.data.map((d) {
      final a = d['attributes'];
      return StoreApp(
        id: d['id'].string ?? '',
        name: a['name'].string ?? '?',
        bundleId: a['bundleId'].string ?? '',
        sku: a['sku'].string ?? '',
        primaryLocale: a['primaryLocale'].string ?? '',
      );
    }).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// The team (App ID prefix) this key belongs to, read from any bundle id.
  Future<String?> teamId() async {
    final r = await send('GET', '/v1/bundleIds', query: {'fields[bundleIds]': 'seedId,identifier', 'limit': '1'});
    return r['data'][0]['attributes']['seedId'].string;
  }

  Future<List<AscBuild>> builds(String appId, {int limit = 40, String? number, String? version}) async {
    final q = <String, String>{
      'filter[app]': appId,
      'sort': '-uploadedDate',
      'limit': '$limit',
      'include': 'preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaGroups',
      'fields[builds]': 'version,uploadedDate,expirationDate,processingState,expired,minOsVersion,iconAssetToken,usesNonExemptEncryption,preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaGroups',
      'fields[preReleaseVersions]': 'version,platform',
      'fields[buildBetaDetails]': 'internalBuildState,externalBuildState',
      'fields[betaAppReviewSubmissions]': 'betaReviewState',
      'fields[betaGroups]': 'name',
      'limit[betaGroups]': '20',
    };
    if (number != null) q['filter[version]'] = number;
    if (version != null) q['filter[preReleaseVersion.version]'] = version;
    final r = await send('GET', '/v1/builds', query: q);
    final inc = _Included(r['included'].list);
    return r['data'].list.map((d) {
      final a = d['attributes'];
      final rel = d['relationships'];
      final pre = inc.resource(rel['preReleaseVersion'])['attributes'];
      final beta = inc.resource(rel['buildBetaDetail'])['attributes'];
      final review = inc.resource(rel['betaAppReviewSubmission'])['attributes'];
      return AscBuild(
        id: d['id'].string ?? '',
        number: a['version'].string ?? '?',
        version: pre['version'].string ?? '?',
        platform: pre['platform'].string ?? 'IOS',
        uploaded: a['uploadedDate'].date,
        expires: a['expirationDate'].date,
        processingState: a['processingState'].string ?? '?',
        expired: a['expired'].boolean ?? false,
        minOS: a['minOsVersion'].string,
        iconTemplate: a['iconAssetToken']['templateUrl'].string,
        internalState: beta['internalBuildState'].string,
        externalState: beta['externalBuildState'].string,
        reviewState: review['betaReviewState'].string,
        groupIds: rel['betaGroups']['data'].list.map((g) => g['id'].string).whereType<String>().toList(),
        usesNonExemptEncryption: a['usesNonExemptEncryption'].boolean,
      );
    }).toList();
  }

  Future<List<AscBetaGroup>> betaGroups(String appId, {bool withTesterCounts = true}) async {
    final r = await all(
      '/v1/betaGroups',
      query: {'filter[app]': appId, 'fields[betaGroups]': 'name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled,publicLink,createdDate', 'limit': '200'},
    );
    final groups = r.data.map((d) {
      final a = d['attributes'];
      return AscBetaGroup(
        id: d['id'].string ?? '',
        name: a['name'].string ?? '?',
        isInternal: a['isInternalGroup'].boolean ?? false,
        allBuilds: a['hasAccessToAllBuilds'].boolean ?? false,
        publicLinkEnabled: a['publicLinkEnabled'].boolean ?? false,
        publicLink: a['publicLink'].string,
        created: a['createdDate'].date,
      );
    }).toList();
    if (withTesterCounts) {
      await Future.wait(
        groups.map((g) async {
          try {
            final page = await send('GET', '/v1/betaGroups/${g.id}/relationships/betaTesters', query: {'limit': '1'});
            g.testerCount = page['meta']['paging']['total'].integer;
          } catch (_) {}
        }),
      );
    }
    groups.sort((a, b) {
      final ia = a.isInternal ? 0 : 1, ib = b.isInternal ? 0 : 1;
      return ia != ib ? ia - ib : a.name.compareTo(b.name);
    });
    return groups;
  }

  Future<List<AscVersion>> versions(String appId) async {
    final r = await send(
      'GET',
      '/v1/apps/$appId/appStoreVersions',
      query: {'fields[appStoreVersions]': 'versionString,platform,appStoreState,appVersionState,createdDate,releaseType', 'limit': '10'},
    );
    return r['data'].list.map((d) {
      final a = d['attributes'];
      return AscVersion(
        id: d['id'].string ?? '',
        version: a['versionString'].string ?? '?',
        platform: a['platform'].string ?? 'IOS',
        state: a['appVersionState'].string ?? a['appStoreState'].string ?? '?',
        created: a['createdDate'].date,
        releaseType: a['releaseType'].string,
      );
    }).toList();
  }

  Future<List<AscBetaLocalization>> betaLocalizations(String buildId) async {
    final r = await send('GET', '/v1/builds/$buildId/betaBuildLocalizations', query: {'limit': '50'});
    return r['data'].list
        .map(
          (d) =>
              AscBetaLocalization(id: d['id'].string ?? '', locale: d['attributes']['locale'].string ?? '', whatsNew: d['attributes']['whatsNew'].string ?? ''),
        )
        .toList();
  }

  /// Writes What to Test for one locale: updates the copied localization if
  /// the build has one, creates it otherwise.
  Future<void> setWhatsNew(String buildId, String locale, String text) async {
    final existing = await betaLocalizations(buildId);
    final lang = locale.split('-').first;
    AscBetaLocalization? loc;
    for (final l in existing) {
      if (l.locale == locale) loc = l;
    }
    if (loc == null) {
      for (final l in existing) {
        if (loc == null && l.locale.startsWith(lang)) loc = l;
      }
    }
    if (loc != null) {
      await send(
        'PATCH',
        '/v1/betaBuildLocalizations/${loc.id}',
        body: {
          'data': {
            'type': 'betaBuildLocalizations',
            'id': loc.id,
            'attributes': {'whatsNew': text},
          },
        },
      );
    } else {
      await send(
        'POST',
        '/v1/betaBuildLocalizations',
        body: {
          'data': {
            'type': 'betaBuildLocalizations',
            'attributes': {'locale': locale, 'whatsNew': text},
            'relationships': {
              'build': {
                'data': {'type': 'builds', 'id': buildId},
              },
            },
          },
        },
      );
    }
  }

  /// The build-side endpoint; the group-side one answers 404 for new builds.
  Future<void> addBuildToGroups(String buildId, List<String> groupIds) async {
    await send(
      'POST',
      '/v1/builds/$buildId/relationships/betaGroups',
      body: {
        'data': [
          for (final id in groupIds) {'type': 'betaGroups', 'id': id},
        ],
      },
    );
  }

  Future<void> submitForBetaReview(String buildId) async {
    await send(
      'POST',
      '/v1/betaAppReviewSubmissions',
      body: {
        'data': {
          'type': 'betaAppReviewSubmissions',
          'relationships': {
            'build': {
              'data': {'type': 'builds', 'id': buildId},
            },
          },
        },
      },
    );
  }

  Future<BuildBetaState> betaState(String buildId) async {
    final r = await send('GET', '/v1/builds/$buildId/buildBetaDetail');
    final a = r['data']['attributes'];
    return BuildBetaState(a['internalBuildState'].string, a['externalBuildState'].string);
  }

  // MARK: App Store versions

  Future<AscVersion> createVersion(String appId, String version) async {
    final r = await send(
      'POST',
      '/v1/appStoreVersions',
      body: {
        'data': {
          'type': 'appStoreVersions',
          'attributes': {'platform': 'IOS', 'versionString': version},
          'relationships': {
            'app': {
              'data': {'type': 'apps', 'id': appId},
            },
          },
        },
      },
    );
    final d = r['data'], a = d['attributes'];
    return AscVersion(
      id: d['id'].string ?? '',
      version: a['versionString'].string ?? version,
      platform: 'IOS',
      state: a['appVersionState'].string ?? a['appStoreState'].string ?? 'PREPARE_FOR_SUBMISSION',
      created: a['createdDate'].date,
      releaseType: a['releaseType'].string,
    );
  }

  /// The App Store version to write What's New into: the editable one with
  /// this version string, created when there is none.
  Future<({AscVersion version, bool created})> editableVersion(String appId, String version) async {
    for (final v in await versions(appId)) {
      if (v.version == version && v.platform == 'IOS' && editableVersionStates.contains(v.state)) return (version: v, created: false);
    }
    return (version: await createVersion(appId, version), created: true);
  }

  /// Whether the app has been on the App Store before (What's New only applies then).
  Future<bool> hasShipped(String appId) async {
    final r = await send(
      'GET',
      '/v1/apps/$appId/appStoreVersions',
      query: {'filter[appStoreState]': 'READY_FOR_SALE,REPLACED_WITH_NEW_VERSION,REMOVED_FROM_SALE,DEVELOPER_REMOVED_FROM_SALE', 'limit': '1'},
    );
    return r['data'].list.isNotEmpty;
  }

  /// Writes What's New of one language of an App Store version.
  Future<void> setVersionWhatsNew(String localizationId, String text) async {
    await send(
      'PATCH',
      '/v1/appStoreVersionLocalizations/$localizationId',
      body: {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'id': localizationId,
          'attributes': {'whatsNew': text},
        },
      },
    );
  }

  /// Adds a language to an App Store version. What's New is left out for an
  /// app's first version, where Apple doesn't allow it.
  Future<String> addLocalization(String versionId, String locale, {String? whatsNew}) async {
    final r = await send(
      'POST',
      '/v1/appStoreVersionLocalizations',
      body: {
        'data': {
          'type': 'appStoreVersionLocalizations',
          'attributes': {'locale': locale, if (whatsNew != null && whatsNew.isNotEmpty) 'whatsNew': whatsNew},
          'relationships': {
            'appStoreVersion': {
              'data': {'type': 'appStoreVersions', 'id': versionId},
            },
          },
        },
      },
    );
    return r['data']['id'].string ?? '';
  }

  /// Writes What's New for each language of an App Store version, adding the
  /// languages it doesn't have yet. Returns one line per language for the log.
  Future<List<String>> writeWhatsNew(String versionId, Map<String, String> notes) async {
    final locs = await send(
      'GET',
      '/v1/appStoreVersions/$versionId/appStoreVersionLocalizations',
      query: {'fields[appStoreVersionLocalizations]': 'locale', 'limit': '50'},
    );
    final existing = <String, String>{};
    for (final d in locs['data'].list) {
      final locale = d['attributes']['locale'].string;
      if (locale != null) existing.putIfAbsent(locale, () => d['id'].string ?? '');
    }
    final lines = <String>[];
    final sorted = notes.entries.where((e) => e.value.trim().isNotEmpty).toList()..sort((a, b) => a.key.compareTo(b.key));
    for (final MapEntry(key: locale, value: text) in sorted) {
      final id = existing[locale];
      if (id != null) {
        await setVersionWhatsNew(id, text);
        lines.add('$locale: updated');
      } else {
        await addLocalization(versionId, locale, whatsNew: text);
        lines.add('$locale: added the language');
      }
    }
    return lines;
  }

  void close() => _http.close();
}

/// Looks up `included` resources by type and id.
class _Included {
  _Included(List<J> items) {
    for (final i in items) {
      final t = i['type'].string, id = i['id'].string;
      if (t != null && id != null) _map['$t/$id'] = i;
    }
  }

  final _map = <String, J>{};

  J resource(J relationship) {
    final d = relationship['data'];
    final t = d['type'].string, id = d['id'].string;
    if (t == null || id == null) return const J(null);
    return _map['$t/$id'] ?? const J(null);
  }
}

// MARK: - Human words for Apple's states

enum StateTone { good, active, waiting, bad, muted }

({String label, StateTone tone}) describeState(String? raw) {
  switch (raw) {
    case null:
      return (label: '—', tone: StateTone.muted);
    case 'VALID':
      return (label: 'Processed', tone: StateTone.good);
    case 'PROCESSING':
      return (label: 'Processing', tone: StateTone.active);
    case 'FAILED' || 'INVALID':
      return (label: 'Failed', tone: StateTone.bad);
    case 'IN_BETA_TESTING':
      return (label: 'Testing', tone: StateTone.good);
    case 'READY_FOR_BETA_TESTING':
      return (label: 'Ready to test', tone: StateTone.good);
    case 'READY_FOR_BETA_SUBMISSION':
      return (label: 'Ready to submit', tone: StateTone.waiting);
    case 'WAITING_FOR_BETA_REVIEW':
      return (label: 'Waiting for review', tone: StateTone.active);
    case 'IN_BETA_REVIEW':
      return (label: 'In review', tone: StateTone.active);
    case 'BETA_REJECTED' || 'REJECTED':
      return (label: 'Rejected', tone: StateTone.bad);
    case 'BETA_APPROVED' || 'APPROVED':
      return (label: 'Approved', tone: StateTone.good);
    case 'WAITING_FOR_REVIEW':
      return (label: 'Waiting for review', tone: StateTone.active);
    case 'IN_REVIEW':
      return (label: 'In review', tone: StateTone.active);
    case 'MISSING_EXPORT_COMPLIANCE':
      return (label: 'Needs export compliance', tone: StateTone.waiting);
    case 'EXPIRED':
      return (label: 'Expired', tone: StateTone.muted);
    case 'IN_EXPORT_COMPLIANCE_REVIEW':
      return (label: 'Compliance review', tone: StateTone.active);
    case 'PROCESSING_EXCEPTION':
      return (label: 'Processing error', tone: StateTone.bad);
    case 'PREPARE_FOR_SUBMISSION':
      return (label: 'Preparing', tone: StateTone.waiting);
    case 'READY_FOR_SALE' || 'READY_FOR_DISTRIBUTION':
      return (label: 'On the App Store', tone: StateTone.good);
    case 'PENDING_DEVELOPER_RELEASE':
      return (label: 'Pending your release', tone: StateTone.waiting);
    case 'DEVELOPER_REJECTED':
      return (label: 'Pulled back', tone: StateTone.muted);
    case 'METADATA_REJECTED':
      return (label: 'Metadata rejected', tone: StateTone.bad);
    case 'ACCEPTED':
      return (label: 'Accepted', tone: StateTone.good);
    case 'WAITING':
      return (label: 'Waiting', tone: StateTone.waiting);
    default:
      final s = raw.replaceAll('_', ' ').toLowerCase();
      return (label: s.isEmpty ? s : s[0].toUpperCase() + s.substring(1), tone: StateTone.muted);
  }
}
