import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 中继服务自签证书（PEM 编码字节）。
class RelayCert {
  const RelayCert({
    required this.certificatePemBytes,
    required this.privateKeyPemBytes,
  });

  /// 证书 PEM（-----BEGIN CERTIFICATE-----）。
  final Uint8List certificatePemBytes;

  /// 私钥 PEM（PKCS#8：-----BEGIN PRIVATE KEY-----）。
  final Uint8List privateKeyPemBytes;
}

/// 确保数据目录下存在中继自签证书（relay-cert.pem + relay-key.pem）。
///
/// - 已存在则直接复用（幂等，重启不换证书）；
/// - 否则生成 RSA-2048 自签证书：CN=LAN Messenger Relay、有效期 10 年、
///   随机序列号、basicConstraints CA:true，以「写临时文件 + rename」原子落盘。
///
/// 自签证书无法被客户端默认信任：客户端接受自签证书（局域网场景明确接受），
/// Web 端需先在浏览器访问一次中继地址完成信任。仅 IO 平台使用，Web 不参与。
Future<RelayCert> ensureRelayCert(Directory dataDir, {Random? random}) async {
  final certFile = File('${dataDir.path}/relay-cert.pem');
  final keyFile = File('${dataDir.path}/relay-key.pem');
  if (await certFile.exists() && await keyFile.exists()) {
    return RelayCert(
      certificatePemBytes: await certFile.readAsBytes(),
      privateKeyPemBytes: await keyFile.readAsBytes(),
    );
  }
  await dataDir.create(recursive: true);
  final rng = random ?? Random.secure();
  final (publicKey, privateKey) = _generateRsaKeyPair(rng);
  final certDer = _buildCertificate(publicKey, privateKey, rng);
  final keyDer = _pkcs8PrivateKey(privateKey);
  final certPem = _pemEncode(certDer, 'CERTIFICATE');
  final keyPem = _pemEncode(keyDer, 'PRIVATE KEY');
  await _atomicWrite(certFile, certPem);
  await _atomicWrite(keyFile, keyPem);
  return RelayCert(
    certificatePemBytes: Uint8List.fromList(certPem),
    privateKeyPemBytes: Uint8List.fromList(keyPem),
  );
}

// ---------------------------------------------------------------------------
// RSA-2048 密钥生成
// ---------------------------------------------------------------------------

(RSAPublicKey, RSAPrivateKey) _generateRsaKeyPair(Random rng) {
  final seed = Uint8List.fromList(<int>[
    for (var i = 0; i < 32; i++) rng.nextInt(256),
  ]);
  final secureRandom = FortunaRandom()..seed(KeyParameter(seed));
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        secureRandom,
      ),
    );
  final pair = generator.generateKeyPair();
  return (pair.publicKey, pair.privateKey);
}

// ---------------------------------------------------------------------------
// X.509 证书 DER 拼装（TBSCertificate → SHA-256 → RSA 签名）
// ---------------------------------------------------------------------------

Uint8List _buildCertificate(
  RSAPublicKey publicKey,
  RSAPrivateKey privateKey,
  Random rng,
) {
  final now = DateTime.now().toUtc();
  // 回拨 24 小时容忍设备间时钟偏差。
  final notBefore = now.subtract(const Duration(hours: 24));
  const validityDays = 10 * 365;
  final notAfter = now.add(const Duration(days: validityDays));

  final sha256WithRsa = _derSequence([
    _derOid('1.2.840.113549.1.1.11'), // sha256WithRSAEncryption
    _derNull(),
  ]);
  final rsaEncryption = _derSequence([
    _derOid('1.2.840.113549.1.1.1'), // rsaEncryption
    _derNull(),
  ]);
  final name = _derName('LAN Messenger Relay');
  final spki = _derSequence([
    rsaEncryption,
    _derBitString(
      _derSequence([
        _derInteger(publicKey.modulus!),
        _derInteger(publicKey.publicExponent!),
      ]),
    ),
  ]);
  // basicConstraints CA:true（自签根，标记 critical）。
  final basicConstraints = _derSequence([
    _derOid('2.5.29.19'),
    _derBoolean(true),
    _derOctetString(_derSequence([_derBoolean(true)])),
  ]);

  final tbs = _derSequence([
    _derExplicit(0, _derInteger(BigInt.from(2))), // version: v3
    _derInteger(_randomSerial(rng)),
    sha256WithRsa,
    name, // issuer（自签：与 subject 相同）
    _derSequence([_derUtcTime(notBefore), _derUtcTime(notAfter)]),
    name, // subject
    spki,
    _derExplicit(3, _derSequence([basicConstraints])),
  ]);

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final signature = signer.generateSignature(tbs);
  return _derSequence([tbs, sha256WithRsa, _derBitString(signature.bytes)]);
}

/// 随机正序列号（64 位，全零时取 1）。
BigInt _randomSerial(Random rng) {
  var serial = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    serial = (serial << 8) | BigInt.from(rng.nextInt(256));
  }
  return serial == BigInt.zero ? BigInt.one : serial;
}

/// Name = RDNSequence，仅一个 CN 属性。
Uint8List _derName(String commonName) => _derSequence([
  _derSet([
    _derSequence([_derOid('2.5.4.3'), _der(0x0c, utf8.encode(commonName))]),
  ]),
]);

Uint8List _derUtcTime(DateTime time) {
  final year = time.year.toString().padLeft(4, '0');
  final text =
      '${year.substring(2)}'
      '${time.month.toString().padLeft(2, '0')}'
      '${time.day.toString().padLeft(2, '0')}'
      '${time.hour.toString().padLeft(2, '0')}'
      '${time.minute.toString().padLeft(2, '0')}'
      '${time.second.toString().padLeft(2, '0')}Z';
  return _der(0x17, ascii.encode(text));
}

// ---------------------------------------------------------------------------
// PKCS#8 私钥
// ---------------------------------------------------------------------------

Uint8List _pkcs8PrivateKey(RSAPrivateKey key) {
  final p = key.p!;
  final q = key.q!;
  final d = key.privateExponent!;
  final rsaKey = _derSequence([
    _derInteger(BigInt.zero), // version
    _derInteger(key.modulus!), // n
    _derInteger(key.publicExponent!), // e
    _derInteger(d), // d
    _derInteger(p), // p
    _derInteger(q), // q
    _derInteger(d % (p - BigInt.one)), // dP
    _derInteger(d % (q - BigInt.one)), // dQ
    _derInteger(q.modInverse(p)), // qInv
  ]);
  return _derSequence([
    _derInteger(BigInt.zero),
    _derSequence([_derOid('1.2.840.113549.1.1.1'), _derNull()]),
    _derOctetString(rsaKey),
  ]);
}

// ---------------------------------------------------------------------------
// DER 编码原语
// ---------------------------------------------------------------------------

Uint8List _der(int tag, List<int> content) =>
    Uint8List.fromList([tag, ..._derLength(content.length), ...content]);

List<int> _derLength(int length) {
  if (length < 0x80) {
    return [length];
  }
  final bytes = <int>[];
  var value = length;
  while (value > 0) {
    bytes.insert(0, value & 0xff);
    value >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

Uint8List _derSequence(List<List<int>> children) =>
    _der(0x30, [for (final child in children) ...child]);

Uint8List _derSet(List<List<int>> children) =>
    _der(0x31, [for (final child in children) ...child]);

Uint8List _derInteger(BigInt value) {
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  var bytes = <int>[
    for (var i = 0; i < padded.length; i += 2)
      int.parse(padded.substring(i, i + 2), radix: 16),
  ];
  // 正数且最高位为 1 时补前导 0x00（避免被解释为负数）。
  if (bytes.isNotEmpty && (bytes.first & 0x80) != 0) {
    bytes = [0, ...bytes];
  }
  return _der(0x02, bytes);
}

Uint8List _derBitString(List<int> content) =>
    _der(0x03, [0, ...content]); // unused bits = 0

Uint8List _derOctetString(List<int> content) => _der(0x04, content);

Uint8List _derNull() => Uint8List.fromList(const [0x05, 0x00]);

Uint8List _derOid(String oid) {
  final parts = oid.split('.').map(int.parse).toList(growable: false);
  final body = <int>[parts[0] * 40 + parts[1]];
  for (var i = 2; i < parts.length; i++) {
    var value = parts[i];
    final chunks = <int>[value & 0x7f];
    value >>= 7;
    while (value > 0) {
      chunks.add((value & 0x7f) | 0x80);
      value >>= 7;
    }
    body.addAll(chunks.reversed);
  }
  return _der(0x06, body);
}

Uint8List _derBoolean(bool value) =>
    _der(0x01, value ? const [0xff] : const [0x00]);

/// context-specific 构造标签（explicit tagging）。
Uint8List _derExplicit(int tagNumber, List<int> content) =>
    _der(0xa0 | tagNumber, content);

// ---------------------------------------------------------------------------
// PEM 与落盘
// ---------------------------------------------------------------------------

Uint8List _pemEncode(List<int> der, String label) {
  final base64Text = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < base64Text.length; i += 64)
      base64Text.substring(i, min(i + 64, base64Text.length)),
  ];
  return utf8.encode(
    '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n',
  );
}

/// 原子写盘：先写 .tmp 再 rename，避免中断留下半截文件。
Future<void> _atomicWrite(File file, List<int> bytes) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(file.path);
}
