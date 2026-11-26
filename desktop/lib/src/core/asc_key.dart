import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import 'errors.dart';
import 'json.dart';

/// An App Store Connect API key: the public ids plus the private key, which
/// only ever lives in the OS keychain or in memory.
class AscKey {
  AscKey({required String keyId, required String issuerId, required this.pem}) : keyId = keyId.trim(), issuerId = issuerId.trim(), _d = parsePrivateKey(pem);

  final String keyId;
  final String issuerId;
  final String pem;
  final BigInt _d;

  static final ECDomainParameters _curve = ECCurve_prime256v1();

  /// A signed ES256 token, valid for 19 minutes (Apple allows at most 20).
  String token({Duration lifetime = const Duration(minutes: 19), DateTime? now}) {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final header = {'alg': 'ES256', 'kid': keyId, 'typ': 'JWT'};
    final payload = {'iss': issuerId, 'iat': t, 'exp': t + lifetime.inSeconds, 'aud': 'appstoreconnect-v1'};
    final input = '${base64UrlNoPad(utf8.encode(jsonEncode(header)))}.${base64UrlNoPad(utf8.encode(jsonEncode(payload)))}';
    final sig = signES256(_d, Uint8List.fromList(utf8.encode(input)));
    return '$input.${base64UrlNoPad(sig)}';
  }

  /// The private scalar of a P-256 key in a PKCS#8 PEM (what Apple's .p8
  /// files hold). A SEC1 "EC PRIVATE KEY" PEM works too.
  static BigInt parsePrivateKey(String pem) {
    const bad = ReleaseError.invalidKey('That file is not an App Store Connect private key (.p8).');
    final body = pem.split(RegExp(r'\r?\n')).where((l) => !l.startsWith('-----')).join().replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) throw bad;
    final Uint8List der;
    try {
      der = base64.decode(body);
    } on FormatException {
      throw bad;
    }
    try {
      final outer = ASN1Parser(der).nextObject();
      if (outer is! ASN1Sequence) throw bad;
      final els = outer.elements ?? const <ASN1Object>[];
      Uint8List? scalar;
      if (els.length >= 3 && els[1] is ASN1Sequence && els[2] is ASN1OctetString) {
        // PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING }
        final alg = (els[1] as ASN1Sequence).elements ?? const <ASN1Object>[];
        final oid = alg.isNotEmpty && alg[0] is ASN1ObjectIdentifier ? (alg[0] as ASN1ObjectIdentifier).objectIdentifierAsString : null;
        if (oid != null && oid != '1.2.840.10045.2.1') throw bad; // id-ecPublicKey
        final inner = ASN1Parser((els[2] as ASN1OctetString).octets!).nextObject();
        scalar = _sec1Scalar(inner);
      } else {
        scalar = _sec1Scalar(outer);
      }
      if (scalar == null || scalar.isEmpty || scalar.length > 32) throw bad;
      final d = _toBigInt(scalar);
      if (d == BigInt.zero || d >= _curve.n) throw bad;
      return d;
    } on ReleaseError {
      rethrow;
    } catch (_) {
      throw bad;
    }
  }

  /// ECPrivateKey ::= SEQUENCE { version INTEGER (1), privateKey OCTET STRING, [0] params, [1] publicKey }
  static Uint8List? _sec1Scalar(ASN1Object o) {
    if (o is! ASN1Sequence) return null;
    final els = o.elements ?? const <ASN1Object>[];
    if (els.length < 2 || els[1] is! ASN1OctetString) return null;
    return (els[1] as ASN1OctetString).octets;
  }

  /// ECDSA P-256 with SHA-256 (RFC 6979 deterministic k), as JOSE wants it:
  /// r and s, 32 bytes each, big-endian and left-padded.
  static Uint8List signES256(BigInt d, Uint8List message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _curve)));
    final sig = signer.generateSignature(message) as ECSignature;
    return Uint8List.fromList([..._fixed32(sig.r), ..._fixed32(sig.s)]);
  }

  /// The public key that belongs to [d] (for checking signatures).
  static ECPublicKey publicKeyFor(BigInt d) => ECPublicKey((_curve.G * d)!, _curve);

  /// Checks a raw r‖s ES256 signature.
  static bool verifyES256(ECPublicKey key, Uint8List message, Uint8List signature) {
    if (signature.length != 64) return false;
    final verifier = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(key));
    final r = _toBigInt(signature.sublist(0, 32));
    final s = _toBigInt(signature.sublist(32));
    return verifier.verifySignature(message, ECSignature(r, s));
  }

  static BigInt _toBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static List<int> _fixed32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}
