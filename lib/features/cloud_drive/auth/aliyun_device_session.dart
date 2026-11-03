import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Device proof for Aliyun's web API (secp256k1, SHA-256, r || low-s || recid).
/// Keys are random per login and persisted only in the OS credential store.
class AliyunDeviceSession {
  AliyunDeviceSession({String? privateKey, String? deviceId})
    : _privateKey = privateKey == null
          ? _randomScalar()
          : BigInt.parse(privateKey, radix: 16),
      deviceId = deviceId ?? _randomHex(16) {
    if (_privateKey <= BigInt.zero || _privateKey >= _n) {
      throw const FormatException('Invalid device key');
    }
  }

  static const webAppId = '5dde4e1bdf9e4966b387ba58f4b3fdc3';
  static final _p = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );
  static final _n = BigInt.parse(
    'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
    radix: 16,
  );
  static final _g = (
    BigInt.parse(
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      radix: 16,
    ),
    BigInt.parse(
      '483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8',
      radix: 16,
    ),
  );

  final BigInt _privateKey;
  final String deviceId;
  String get privateKey => _hex(_privateKey);
  late final String publicKey = () {
    final point = _multiply(_privateKey)!;
    return '04${_hex(point.$1)}${_hex(point.$2)}';
  }();

  String signature(String userId) => signDigest(
    sha256.convert(utf8.encode('$webAppId:$deviceId:$userId:0')).bytes,
  );

  /// RFC 6979 derives a fresh deterministic nonce from this digest and key.
  String signDigest(List<int> digest) {
    if (digest.length != 32) throw const FormatException('Expected SHA-256');
    final z = BigInt.parse(_bytesHex(digest), radix: 16);
    final key = _hexBytes(privateKey);
    final h = _hexBytes(_hex(z % _n));
    var k = List<int>.filled(32, 0);
    var v = List<int>.filled(32, 1);
    List<int> mac(List<int> key, List<int> body) =>
        Hmac(sha256, key).convert(body).bytes;
    k = mac(k, [...v, 0, ...key, ...h]);
    v = mac(k, v);
    k = mac(k, [...v, 1, ...key, ...h]);
    v = mac(k, v);
    while (true) {
      v = mac(k, v);
      final nonce = BigInt.parse(_bytesHex(v), radix: 16);
      if (nonce > BigInt.zero && nonce < _n) {
        final point = _multiply(nonce)!;
        final r = point.$1 % _n;
        var s = (nonce.modInverse(_n) * (z + r * _privateKey)) % _n;
        var recovery = (point.$1 >= _n ? 2 : 0) | (point.$2.isOdd ? 1 : 0);
        if (r != BigInt.zero && s != BigInt.zero) {
          if (s > (_n >> 1)) {
            s = _n - s;
            recovery ^= 1;
          }
          return '${_hex(r)}${_hex(s)}${recovery.toRadixString(16).padLeft(2, '0')}';
        }
      }
      k = mac(k, [...v, 0]);
      v = mac(k, v);
    }
  }

  static (BigInt, BigInt)? _multiply(BigInt scalar) {
    (BigInt, BigInt)? result;
    (BigInt, BigInt)? addend = _g;
    while (scalar > BigInt.zero) {
      if (scalar.isOdd) result = _add(result, addend);
      addend = _add(addend, addend);
      scalar >>= 1;
    }
    return result;
  }

  static (BigInt, BigInt)? _add((BigInt, BigInt)? a, (BigInt, BigInt)? b) {
    if (a == null) return b;
    if (b == null) return a;
    if (a.$1 == b.$1 && (a.$2 + b.$2) % _p == BigInt.zero) return null;
    final slope = a == b
        ? (BigInt.from(3) * a.$1 * a.$1 * (BigInt.two * a.$2).modInverse(_p)) %
              _p
        : ((b.$2 - a.$2) * ((b.$1 - a.$1) % _p).modInverse(_p)) % _p;
    final x = (slope * slope - a.$1 - b.$1) % _p;
    return (x, (slope * (a.$1 - x) - a.$2) % _p);
  }

  static BigInt _randomScalar() {
    while (true) {
      final value = BigInt.parse(_randomHex(32), radix: 16);
      if (value > BigInt.zero && value < _n) return value;
    }
  }

  static String _randomHex(int count) {
    final random = Random.secure();
    return _bytesHex(List.generate(count, (_) => random.nextInt(256)));
  }

  static String _hex(BigInt value) => value.toRadixString(16).padLeft(64, '0');
  static String _bytesHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _hexBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
