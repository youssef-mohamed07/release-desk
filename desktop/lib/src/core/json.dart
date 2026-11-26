import 'dart:convert';

/// A forgiving view over decoded JSON. App Store Connect speaks JSON:API,
/// where one response mixes resources of many types, so the clients read
/// into this first and map the parts they need into typed models.
class J {
  const J(this.value);

  /// Decodes [text]; anything that is not JSON reads as null.
  factory J.decode(String text) {
    if (text.trim().isEmpty) return const J(null);
    try {
      return J(jsonDecode(text));
    } on FormatException {
      return const J(null);
    }
  }

  final Object? value;

  J operator [](Object key) {
    final v = value;
    if (key is String && v is Map) return J(v[key]);
    if (key is int && v is List && key >= 0 && key < v.length) return J(v[key]);
    return const J(null);
  }

  bool get isNull => value == null;

  String? get string {
    final v = value;
    if (v is String) return v;
    if (v is int) return '$v';
    if (v is double) return v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    if (v is bool) return '$v';
    return null;
  }

  int? get integer {
    final v = value;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  double? get number {
    final v = value;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  bool? get boolean => value is bool ? value as bool : null;

  List<J> get list {
    final v = value;
    return v is List ? v.map(J.new).toList() : const [];
  }

  Map<String, Object?> get map {
    final v = value;
    return v is Map ? v.map((k, v) => MapEntry('$k', v)) : const {};
  }

  DateTime? get date {
    final s = string;
    return s == null ? null : DateTime.tryParse(s);
  }
}

String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> base64UrlDecodeLoose(String s) {
  var b = s.replaceAll('-', '+').replaceAll('_', '/');
  while (b.length % 4 != 0) {
    b += '=';
  }
  return base64.decode(b);
}
