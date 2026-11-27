import 'dart:async';

enum ErrorKind { invalidKey, api, network, command, precondition, cancelled, storage }

/// Everything that can stop a call or a release, with a message a person can
/// act on.
class ReleaseError implements Exception {
  const ReleaseError._(this.kind, this.message, {this.status, this.path});

  const ReleaseError.invalidKey(String message) : this._(ErrorKind.invalidKey, message);
  const ReleaseError.network(String message) : this._(ErrorKind.network, message);
  const ReleaseError.precondition(String message) : this._(ErrorKind.precondition, message);
  const ReleaseError.storage(String message) : this._(ErrorKind.storage, message);
  const ReleaseError.cancelled() : this._(ErrorKind.cancelled, 'Cancelled');

  factory ReleaseError.command(String command, int code, String tail) =>
      ReleaseError._(ErrorKind.command, '$command failed (exit $code)${tail.isEmpty ? '' : '\n$tail'}');

  factory ReleaseError.api(int status, String path, List<String> messages) {
    final google = path.contains('googleapis.com') || path.contains('androidpublisher') || path == 'oauth token';
    final github = path.startsWith('github.com') || path.contains('api.github.com');
    final service = path.contains('huawei.com') || path.contains('myhuaweicloud')
        ? 'AppGallery'
        : path.contains('microsoft') || path.contains('windows.net')
        ? 'Microsoft Store'
        : google
        ? 'Google Play'
        : (github ? 'GitHub' : 'App Store Connect');
    var shown = path;
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) shown = uri.path;
    return ReleaseError._(ErrorKind.api, '$service $status on $shown: ${messages.join('; ')}', status: status, path: path);
  }

  final ErrorKind kind;
  final String message;
  final int? status;
  final String? path;

  /// Google answers 403 "The caller does not have permission" when the
  /// account has no access to the app in Play Console.
  bool get isPlayPermission => kind == ErrorKind.api && status == 403 && (path ?? '').contains('googleapis.com');

  bool get isCancelled => kind == ErrorKind.cancelled;

  @override
  String toString() => message;
}

String describeError(Object e) {
  if (e is ReleaseError) return e.message;
  if (e is TimeoutException) return 'Timed out';
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

/// A cooperative stop signal for a release run: sleeps wake up early and
/// running tools are interrupted.
class CancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void onCancel(void Function() f) {
    if (_cancelled) {
      f();
    } else {
      _listeners.add(f);
    }
  }

  void removeListener(void Function() f) => _listeners.remove(f);

  void check() {
    if (_cancelled) throw const ReleaseError.cancelled();
  }

  /// Waits [d], or less if the run is stopped (then throws).
  Future<void> sleep(Duration d) async {
    check();
    final c = Completer<void>();
    final timer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    void stop() {
      timer.cancel();
      if (!c.isCompleted) c.complete();
    }

    onCancel(stop);
    await c.future;
    removeListener(stop);
    check();
  }
}
