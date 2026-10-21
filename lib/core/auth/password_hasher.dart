import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 密码哈希工具：PBKDF2-HMAC-SHA256（RFC 2898 / RFC 8018）。
///
/// - 盐：[newSalt] 生成 16 字节随机盐，以 hex 形式存储；
/// - 哈希：默认 100,000 次迭代、32 字节输出，以 hex 形式存储；
/// - 校验：[verify] 使用常量时间比较，避免时序侧信道。
///
/// 纯 Dart 实现（基于 package:crypto 的 HMAC-SHA256），三端可用、无原生依赖。
abstract final class PasswordHasher {
  static const int defaultIterations = 100000;
  static const int saltBytes = 16;
  static const int hashBytes = 32;

  /// 生成随机盐（hex 字符串，[saltBytes] 字节）。
  static String newSalt([Random? random]) =>
      _bytesToHex(_randomBytes(saltBytes, random));

  /// 计算密码哈希（hex 字符串）；[saltHex] 为 [newSalt] 产出的 hex 盐。
  static String hash(
    String password,
    String saltHex, {
    int iterations = defaultIterations,
  }) => deriveHex(password, _hexToBytes(saltHex), iterations: iterations);

  /// 常量时间比较哈希；任何参数不一致均返回 false，不泄露失败原因。
  static bool verify(
    String password,
    String saltHex,
    String expectedHashHex, {
    int iterations = defaultIterations,
  }) {
    final actual = hash(password, saltHex, iterations: iterations);
    if (actual.length != expectedHashHex.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expectedHashHex.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// PBKDF2 核心：输出 hex。盐为原始字节（测试向量使用 ASCII 盐）。
  static String deriveHex(
    String password,
    List<int> salt, {
    int iterations = defaultIterations,
    int dkLen = hashBytes,
  }) {
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', '必须 ≥ 1');
    }
    if (dkLen < 1) {
      throw ArgumentError.value(dkLen, 'dkLen', '必须 ≥ 1');
    }
    final mac = Hmac(sha256, utf8.encode(password));
    final blockCount = (dkLen / 32).ceil();
    final derived = <int>[];
    for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
      // U1 = PRF(password, salt || INT_32_BE(blockIndex))
      var u = mac
          .convert(<int>[
            ...salt,
            (blockIndex >> 24) & 0xff,
            (blockIndex >> 16) & 0xff,
            (blockIndex >> 8) & 0xff,
            blockIndex & 0xff,
          ])
          .bytes;
      // T = U1 ^ U2 ^ ... ^ Uc
      final t = List<int>.of(u);
      for (var round = 1; round < iterations; round++) {
        u = mac.convert(u).bytes;
        for (var i = 0; i < t.length; i++) {
          t[i] ^= u[i];
        }
      }
      derived.addAll(t);
    }
    return _bytesToHex(derived.sublist(0, dkLen));
  }

  static List<int> _randomBytes(int count, Random? random) {
    final rng = random ?? Random.secure();
    return <int>[for (var i = 0; i < count; i++) rng.nextInt(256)];
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexToBytes(String hex) {
    if (hex.length.isOdd) {
      throw ArgumentError('盐必须为偶数长度的 hex 字符串');
    }
    return <int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }
}
