import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'shell.dart';

/// What Release Desk reads from a Flutter project folder.
class FlutterProject {
  const FlutterProject({
    required this.root,
    required this.name,
    required this.version,
    required this.buildNumber,
    this.iosBundleId,
    this.androidPackage,
    required this.hasUploadKey,
    required this.hasEntitlements,
  });

  final String root;
  final String name;
  final String version;
  final int buildNumber;
  final String? iosBundleId;
  final String? androidPackage;

  /// android/key.properties exists, so release builds use an upload key.
  final bool hasUploadKey;
  final bool hasEntitlements;

  String get pubspec => p.join(root, 'pubspec.yaml');

  static FlutterProject inspect(String root, {String entitlements = 'ios/Runner/Runner.entitlements'}) {
    final file = File(p.join(root, 'pubspec.yaml'));
    if (!file.existsSync()) throw ReleaseError.precondition('No pubspec.yaml in $root. Pick the Flutter app folder.');
    final pubspec = file.readAsStringSync();
    final name = firstMatch(r'^name:\s*(\S+)', pubspec) ?? p.basename(root);
    final full = firstMatch(r'^version:\s*([^\s#]+)', pubspec) ?? '1.0.0+1';
    final plus = full.indexOf('+');
    final version = plus < 0 ? full : full.substring(0, plus);
    final number = plus < 0 ? 1 : (int.tryParse(full.substring(plus + 1)) ?? 1);

    String? bundle;
    final pbx = File(p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    if (pbx.existsSync()) {
      final ids = allMatches(
        r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;',
        pbx.readAsStringSync(),
      ).where((s) => !s.contains('Tests') && !s.contains(r'$(')).toList()..sort((a, b) => a.length.compareTo(b.length));
      bundle = ids.isEmpty ? null : ids.first;
    }

    String? package;
    for (final f in ['build.gradle.kts', 'build.gradle']) {
      final g = File(p.join(root, 'android', 'app', f));
      if (g.existsSync()) {
        package = firstMatch(r'applicationId\s*=?\s*"([^"]+)"', g.readAsStringSync());
        if (package != null) break;
      }
    }
    return FlutterProject(
      root: root,
      name: name,
      version: version,
      buildNumber: number,
      iosBundleId: bundle,
      androidPackage: package,
      hasUploadKey: File(p.join(root, 'android', 'key.properties')).existsSync(),
      hasEntitlements: File(p.join(root, entitlements)).existsSync(),
    );
  }

  /// Rewrites `version:` in pubspec.yaml, keeping the rest of the file.
  void writeVersion(String version, int build) {
    final f = File(pubspec);
    final text = f.readAsStringSync();
    final re = RegExp(r'^version:\s*[^\s#]+', multiLine: true);
    if (!re.hasMatch(text)) throw const ReleaseError.precondition('pubspec.yaml has no version: line');
    f.writeAsStringSync(text.replaceFirst(re, 'version: $version+$build'));
  }

  /// Commit subjects since a date, newest first, for drafting What to Test.
  Future<List<String>> commits({DateTime? since, int limit = 30}) async {
    final args = ['-C', root, 'log', '--no-merges', '-n', '$limit', '--format=%s'];
    if (since != null) args.add('--since=${since.toUtc().toIso8601String()}');
    try {
      final out = await Shell.capture('git', args);
      return out.split('\n').where((s) => s.trim().isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// The upload key settings in android/key.properties.
  Map<String, String> keyProperties() {
    final f = File(p.join(root, 'android', 'key.properties'));
    if (!f.existsSync()) return const {};
    final props = <String, String>{};
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i > 0) props[t.substring(0, i).trim()] = t.substring(i + 1).trim();
    }
    return props;
  }
}

String? firstMatch(String pattern, String text) {
  final m = allMatches(pattern, text);
  return m.isEmpty ? null : m.first;
}

List<String> allMatches(String pattern, String text) =>
    RegExp(pattern, multiLine: true).allMatches(text).map((m) => m.groupCount >= 1 ? m.group(1) : null).whereType<String>().toList();

/// Where Flutter projects are looked for: the usual code folders, the
/// folders of projects already linked, and their parents.
class ProjectScanner {
  static List<String> roots(Iterable<String> linkedPaths) {
    final home = Shell.home;
    final roots = <String>[
      for (final d in ['Developer', 'dev', 'Projects', 'projects', 'src', 'code', 'Code', 'StudioProjects', 'Documents/GitHub', 'source/repos', 'git'])
        p.join(home, d),
    ];
    for (final l in linkedPaths) {
      var u = p.dirname(l);
      if (const ['mobile', 'app', 'flutter'].contains(p.basename(l))) u = p.dirname(u);
      if (u != home && !roots.contains(u)) roots.add(u);
    }
    return roots.where((r) => Directory(r).existsSync()).toList();
  }

  /// Runs on a background isolate: it reads many small files.
  static List<FlutterProject> projects(List<String> roots) {
    final out = <FlutterProject>[];
    final seen = <String>{};
    for (final dir in roots) {
      List<FileSystemEntity> tops;
      try {
        tops = Directory(dir).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final top in tops.whereType<Directory>()) {
        for (final sub in ['', 'mobile', 'app', 'apps/mobile', 'flutter']) {
          final root = sub.isEmpty ? top.path : p.join(top.path, sub);
          if (seen.contains(root) || !File(p.join(root, 'pubspec.yaml')).existsSync()) continue;
          try {
            final proj = FlutterProject.inspect(root);
            if (proj.iosBundleId == null && proj.androidPackage == null) continue;
            seen.add(root);
            out.add(proj);
          } catch (_) {}
        }
      }
    }
    out.sort((a, b) => a.root.length.compareTo(b.root.length));
    return out;
  }
}
