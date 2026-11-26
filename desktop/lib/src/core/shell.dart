import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// Runs command line tools (flutter, git, gh, keytool) and streams each line.
/// An app opened from a desktop launcher often has a bare PATH, so the usual
/// install folders of Flutter, the GitHub CLI and Java are added to it.
class Shell {
  static Future<Map<String, String>>? _env;

  static String get home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  static Future<Map<String, String>> environment() => _env ??= _buildEnvironment();

  static Future<Map<String, String>> _buildEnvironment() async {
    final env = Map<String, String>.from(Platform.environment);
    final sep = Platform.isWindows ? ';' : ':';
    final pathKey = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
    var path = env[pathKey] ?? '';
    if (Platform.isMacOS) {
      // A login zsh knows where Homebrew and Flutter are.
      try {
        final r = await Process.run('/bin/zsh', ['-lc', r'print -r -- $PATH']).timeout(const Duration(seconds: 8));
        final line = '${r.stdout}'.trim().split('\n').last;
        if (r.exitCode == 0 && line.contains('/')) path = line;
      } catch (_) {}
    }
    final extra = <String>[
      if (Platform.isWindows) ...[
        p.join(home, 'flutter', 'bin'),
        r'C:\src\flutter\bin',
        r'C:\flutter\bin',
        p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'fvm', 'default', 'bin'),
        r'C:\Program Files\GitHub CLI',
        r'C:\Program Files\Git\cmd',
        r'C:\Program Files\Android\Android Studio\jbr\bin',
      ] else ...[
        p.join(home, 'flutter', 'bin'),
        p.join(home, 'development', 'flutter', 'bin'),
        p.join(home, 'snap', 'flutter', 'common', 'flutter', 'bin'),
        p.join(home, 'fvm', 'default', 'bin'),
        p.join(home, '.local', 'bin'),
        '/snap/bin',
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/android-studio/jbr/bin',
        p.join(home, 'android-studio', 'jbr', 'bin'),
        '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin',
      ],
    ];
    final parts = path.split(sep).where((s) => s.isNotEmpty).toList();
    for (final e in extra) {
      if (!parts.contains(e) && Directory(e).existsSync()) parts.add(e);
    }
    final java = Platform.environment['JAVA_HOME'];
    if (java != null && java.isNotEmpty) {
      final bin = p.join(java, 'bin');
      if (!parts.contains(bin)) parts.add(bin);
    }
    env[pathKey] = parts.join(sep);
    env['LANG'] ??= 'en_US.UTF-8';
    return env;
  }

  /// Runs and returns all output; throws on a non-zero exit.
  static Future<String> capture(String exe, List<String> args, {String? cwd, CancelToken? cancel}) async {
    final lines = <String>[];
    final code = await run(exe, args, cwd: cwd, cancel: cancel, onLine: lines.add, keepBlankLines: true);
    if (code != 0) {
      throw ReleaseError.command(
        [exe, ...args].join(' '),
        code,
        lines.where((l) => l.trim().isNotEmpty).toList().reversed.take(8).toList().reversed.join('\n'),
      );
    }
    return lines.join('\n');
  }

  /// Runs [exe] (a path, or a name looked up on PATH) and calls [onLine] for
  /// every line of stdout and stderr. Stopping [cancel] interrupts it.
  static Future<int> run(
    String exe,
    List<String> args, {
    String? cwd,
    List<int>? stdin,
    CancelToken? cancel,
    required void Function(String) onLine,
    bool keepBlankLines = false,
  }) async {
    cancel?.check();
    final env = await environment();
    final Process process;
    try {
      process = await Process.start(exe, args, workingDirectory: cwd, environment: env, includeParentEnvironment: false, runInShell: Platform.isWindows);
    } on ProcessException catch (e) {
      throw ReleaseError.command(exe, -1, e.message.isEmpty ? '$exe was not found. Is it installed and on PATH?' : e.message);
    }
    if (stdin != null) {
      process.stdin.add(stdin);
    }
    unawaited(process.stdin.close().catchError((_) {}));

    void stop() {
      if (Platform.isWindows) {
        Process.run('taskkill', ['/T', '/F', '/PID', '${process.pid}']).ignore();
      } else {
        process.kill(ProcessSignal.sigint);
        Timer(const Duration(seconds: 3), () => process.kill(ProcessSignal.sigterm));
      }
    }

    cancel?.onCancel(stop);
    final splitter = LineSplitter2(onLine, keepBlankLines: keepBlankLines);
    final out = process.stdout.listen(splitter.feed).asFuture<void>();
    final err = process.stderr.listen(splitter.feed).asFuture<void>();
    final code = await process.exitCode;
    // Give a helper that keeps the pipe open two seconds to let go.
    await Future.wait([out, err]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    splitter.flush();
    cancel?.removeListener(stop);
    if (cancel?.isCancelled ?? false) throw const ReleaseError.cancelled();
    return code;
  }

  /// Opens a file, folder or URL with the system.
  static Future<void> open(String target) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [target]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [target]);
    } else {
      await Process.run('xdg-open', [target]);
    }
  }

  /// Shows a file in the system file manager.
  static Future<void> reveal(String file) async {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', file]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', file]);
    } else {
      final dir = FileSystemEntity.isDirectorySync(file) ? file : p.dirname(file);
      await Process.run('xdg-open', [dir]);
    }
  }
}

/// Turns chunks of bytes into lines; carriage returns (progress bars) count
/// as line ends too.
class LineSplitter2 {
  LineSplitter2(this.onLine, {this.keepBlankLines = false});

  final void Function(String) onLine;
  final bool keepBlankLines;
  final _buffer = <int>[];
  bool _lastWasCR = false;

  void feed(List<int> data) {
    for (final b in data) {
      if (b == 0x0A && _lastWasCR) {
        _lastWasCR = false;
        continue;
      }
      _lastWasCR = b == 0x0D;
      if (b == 0x0A || b == 0x0D) {
        _emit();
      } else {
        _buffer.add(b);
      }
    }
  }

  void _emit() {
    final line = utf8.decode(_buffer, allowMalformed: true);
    _buffer.clear();
    if (keepBlankLines || line.trim().isNotEmpty) onLine(line);
  }

  void flush() {
    if (_buffer.isNotEmpty) _emit();
  }
}
