import 'dart:convert';
import 'dart:io';

import 'package:flutter_template/core/auth/account_store.dart';
import 'package:flutter_template/core/auth/account_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crypto/crypto.dart';

void main() {
  late Directory tempDir;
  late JsonFileAccountStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('account_store_test');
    store = JsonFileAccountStore(tempDir, pbkdf2Iterations: 1000);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('注册', () {
    test('注册成功，昵称缺省为用户名', () async {
      final user = await store.register(
        username: 'alice',
        password: 'password1',
      );
      expect(user.username, 'alice');
      expect(user.nickname, 'alice');
      expect(user.id, isNotEmpty);
      expect(user.salt.length, 32); // 16 字节 hex
      expect(user.passwordHash.length, 64); // 32 字节 hex
      expect(user.createdAt, greaterThan(0));
    });

    test('显式昵称优先生效', () async {
      final user = await store.register(
        username: 'alice',
        password: 'password1',
        nickname: '小明',
      );
      expect(user.nickname, '小明');
    });

    test('用户名不合法抛 INVALID_USERNAME', () async {
      final cases = <String>['ab', 'a' * 25, 'bad-name', '空格 名', ''];
      for (final name in cases) {
        await expectLater(
          store.register(username: name, password: 'password1'),
          throwsA(
            isA<AccountException>().having(
              (e) => e.code,
              'code',
              'INVALID_USERNAME',
            ),
          ),
          reason: '用户名 "$name" 应被拒绝',
        );
      }
    });

    test('弱密码抛 WEAK_PASSWORD', () async {
      await expectLater(
        store.register(username: 'alice', password: 'short'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.code,
            'code',
            'WEAK_PASSWORD',
          ),
        ),
      );
    });

    test('重复用户名抛 USERNAME_TAKEN', () async {
      await store.register(username: 'alice', password: 'password1');
      await expectLater(
        store.register(username: 'alice', password: 'password2'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.code,
            'code',
            'USERNAME_TAKEN',
          ),
        ),
      );
    });
  });

  group('登录', () {
    test('正确凭据签发会话', () async {
      final created = await store.register(
        username: 'alice',
        password: 'password1',
      );
      final session = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      expect(session.token.length, 64); // 32 字节 hex
      expect(session.userId, created.id);
      expect(session.deviceId, 'dev-1');
      expect(session.isExpired, isFalse);
    });

    test('密码错误抛 BAD_CREDENTIALS', () async {
      await store.register(username: 'alice', password: 'password1');
      await expectLater(
        store.verifyLogin(
          username: 'alice',
          password: 'wrong-pass',
          deviceId: 'dev-1',
        ),
        throwsA(
          isA<AccountException>().having(
            (e) => e.code,
            'code',
            'BAD_CREDENTIALS',
          ),
        ),
      );
    });

    test('用户不存在同样抛 BAD_CREDENTIALS（不泄露存在性）', () async {
      await expectLater(
        store.verifyLogin(
          username: 'ghost',
          password: 'password1',
          deviceId: 'dev-1',
        ),
        throwsA(
          isA<AccountException>().having(
            (e) => e.code,
            'code',
            'BAD_CREDENTIALS',
          ),
        ),
      );
    });
  });

  group('token 校验', () {
    test('有效 token 且 userId 匹配时返回会话', () async {
      await store.register(username: 'alice', password: 'password1');
      final session = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      final validated = await store.validateToken(
        token: session.token,
        userId: session.userId,
      );
      expect(validated, isNotNull);
      // 库内记录存的是摘要：validateToken 返回的会话携带 SHA-256(token)。
      expect(
        validated!.token,
        sha256.convert(utf8.encode(session.token)).toString(),
      );
    });

    test('userId 不匹配返回 null', () async {
      await store.register(username: 'alice', password: 'password1');
      final session = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      expect(
        await store.validateToken(token: session.token, userId: 'other-user'),
        isNull,
      );
    });

    test('未知 token 返回 null', () async {
      expect(
        await store.validateToken(token: 'no-such-token', userId: 'u'),
        isNull,
      );
    });

    test('同设备重复登录使旧 token 失效，不同设备互不影响', () async {
      await store.register(username: 'alice', password: 'password1');
      final s1 = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      final s2 = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      expect(
        await store.validateToken(token: s1.token, userId: s1.userId),
        isNull,
        reason: '同设备重登后旧 token 应失效',
      );
      final s3 = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-2',
      );
      expect(
        await store.validateToken(token: s2.token, userId: s2.userId),
        isNotNull,
        reason: '其他设备的会话不应受影响',
      );
      expect(
        await store.validateToken(token: s3.token, userId: s3.userId),
        isNotNull,
      );
    });

    test('过期 token 返回 null 并被清理', () async {
      final shortDir = await Directory.systemTemp.createTemp(
        'account_store_ttl',
      );
      addTearDown(() => shortDir.delete(recursive: true));
      final shortStore = JsonFileAccountStore(
        shortDir,
        tokenTtl: const Duration(milliseconds: 50),
        pbkdf2Iterations: 1000,
      );
      await shortStore.register(username: 'alice', password: 'password1');
      final session = await shortStore.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        await shortStore.validateToken(
          token: session.token,
          userId: session.userId,
        ),
        isNull,
      );
    });
  });

  group('离线消息', () {
    OfflineMessage msg(
      String msgId,
      String to, {
      int timestamp = 0,
      String from = 'u0',
    }) => OfflineMessage(
      msgId: msgId,
      fromUser: from,
      toUser: to,
      text: 'hi-$msgId',
      timestamp: timestamp,
    );

    test('入队 → 取出（时间升序）→ 确认删除', () async {
      await store.enqueueOffline(msg('m1', 'u2', timestamp: 100));
      await store.enqueueOffline(msg('m2', 'u2', timestamp: 50));

      final taken = await store.takeOffline(userId: 'u2');
      expect(taken.map((m) => m.msgId), <String>['m2', 'm1']);

      await store.confirmOffline(msgId: 'm1', userId: 'u2');
      final rest = await store.takeOffline(userId: 'u2');
      expect(rest.map((m) => m.msgId), <String>['m2']);
    });

    test('非收件人确认不删除（防伪造 ack）', () async {
      await store.enqueueOffline(msg('m1', 'u2'));
      await store.confirmOffline(msgId: 'm1', userId: 'u3');
      expect((await store.takeOffline(userId: 'u2')), hasLength(1));
    });

    test('按 msgId 幂等入队', () async {
      await store.enqueueOffline(msg('m1', 'u2'));
      await store.enqueueOffline(msg('m1', 'u2', timestamp: 9));
      final taken = await store.takeOffline(userId: 'u2');
      expect(taken, hasLength(1));
    });

    test('其他用户的消息不可见', () async {
      await store.enqueueOffline(msg('m1', 'u2'));
      expect(await store.takeOffline(userId: 'u3'), isEmpty);
    });

    test('确认不存在的消息不抛异常', () async {
      await store.confirmOffline(msgId: 'ghost', userId: 'u2');
    });
  });

  group('持久化', () {
    test('重开实例后账号与会话数据仍在', () async {
      await store.register(username: 'alice', password: 'password1');
      await store.enqueueOffline(
        OfflineMessage(
          msgId: 'm1',
          fromUser: 'u0',
          toUser: 'u1',
          text: 'hi',
          timestamp: 1,
        ),
      );
      final reopened = JsonFileAccountStore(tempDir, pbkdf2Iterations: 1000);
      final session = await reopened.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      expect(session.token, isNotEmpty);
      final offline = await reopened.takeOffline(userId: 'u1');
      expect(offline, hasLength(1));
      expect(offline.first.text, 'hi');
    });

    test('sessions.json 只存 token 摘要，明文不落盘（R4）', () async {
      await store.register(username: 'alice', password: 'password1');
      final session = await store.verifyLogin(
        username: 'alice',
        password: 'password1',
        deviceId: 'dev-1',
      );
      final raw = await File('${tempDir.path}/sessions.json').readAsString();
      expect(
        raw.contains(session.token),
        isFalse,
        reason: '明文 token 不得写入 sessions.json',
      );
      expect(
        raw.contains(sha256.convert(utf8.encode(session.token)).toString()),
        isTrue,
        reason: 'sessions.json 应包含 SHA-256(token) 摘要',
      );
      // 摘要存储不影响校验：明文 token 仍可通过 validateToken。
      expect(
        await store.validateToken(token: session.token, userId: session.userId),
        isNotNull,
      );
    });

    test('损坏的 JSON 文件按空库处理，不阻断新写入', () async {
      await File('${tempDir.path}/users.json').writeAsString('not-json');
      final reopened = JsonFileAccountStore(tempDir, pbkdf2Iterations: 1000);
      final user = await reopened.register(
        username: 'bob',
        password: 'password1',
      );
      expect(user.username, 'bob');
    });
  });
}
