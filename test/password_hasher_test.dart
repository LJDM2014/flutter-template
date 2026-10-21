import 'dart:math';

import 'package:flutter_template/core/auth/password_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PBKDF2-HMAC-SHA256 标准测试向量（RFC 7914 §11）', () {
    test('iterations=1', () {
      expect(
        PasswordHasher.deriveHex('password', 'salt'.codeUnits, iterations: 1),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('iterations=2', () {
      expect(
        PasswordHasher.deriveHex('password', 'salt'.codeUnits, iterations: 2),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('iterations=4096', () {
      expect(
        PasswordHasher.deriveHex(
          'password',
          'salt'.codeUnits,
          iterations: 4096,
        ),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('多块输出（dkLen=40）', () {
      expect(
        PasswordHasher.deriveHex(
          'passwordPASSWORDpassword',
          'saltSALTsaltSALTsaltSALTsaltSALTsalt'.codeUnits,
          iterations: 4096,
          dkLen: 40,
        ),
        '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1'
        'c635518c7dac47e9',
      );
    });
  });

  group('hash / verify', () {
    test('同盐同密码哈希一致且 verify 通过', () {
      const salt = '0123456789abcdef0123456789abcdef';
      final h1 = PasswordHasher.hash('correct horse', salt, iterations: 100);
      final h2 = PasswordHasher.hash('correct horse', salt, iterations: 100);
      expect(h1, h2);
      expect(h1.length, 64); // 32 字节 hex
      expect(
        PasswordHasher.verify('correct horse', salt, h1, iterations: 100),
        isTrue,
      );
    });

    test('不同盐产生不同哈希', () {
      final h1 = PasswordHasher.hash('pw123456', 'aaaa', iterations: 100);
      final h2 = PasswordHasher.hash('pw123456', 'bbbb', iterations: 100);
      expect(h1, isNot(h2));
    });

    test('密码错误 verify 失败', () {
      const salt = '0123456789abcdef0123456789abcdef';
      final hash = PasswordHasher.hash('right-password', salt, iterations: 100);
      expect(
        PasswordHasher.verify('wrong-password', salt, hash, iterations: 100),
        isFalse,
      );
      // 哈希被篡改同样失败
      expect(
        PasswordHasher.verify(
          'right-password',
          salt,
          '${hash.substring(0, 62)}zz',
          iterations: 100,
        ),
        isFalse,
      );
    });

    test('newSalt 长度固定且随机', () {
      final a = PasswordHasher.newSalt();
      final b = PasswordHasher.newSalt();
      expect(a.length, PasswordHasher.saltBytes * 2);
      expect(a, isNot(b));
      // 显式注入 Random 时同种子结果确定（可复现）
      final c = PasswordHasher.newSalt(Random(1));
      final d = PasswordHasher.newSalt(Random(1));
      expect(c, d);
    });

    test('非法参数抛 ArgumentError', () {
      expect(
        () => PasswordHasher.deriveHex('p', <int>[1], iterations: 0),
        throwsArgumentError,
      );
      expect(
        () => PasswordHasher.deriveHex('p', <int>[1], dkLen: 0),
        throwsArgumentError,
      );
    });
  });
}
