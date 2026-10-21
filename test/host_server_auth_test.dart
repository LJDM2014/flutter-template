import 'dart:io';

import 'package:flutter_template/core/auth/account_store_io.dart';
import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'server_test_kit.dart';

/// 阶段②验收：REST 契约、WS 鉴权拒绝、离线暂存/补投/确认、多设备扇出。
void main() {
  late Directory accountDir;
  late JsonFileAccountStore store;
  late int port;

  setUpAll(() async {
    final (dir, accountStore) = await createTempAccountStore();
    accountDir = dir;
    store = accountStore;
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: store,
    );
    expect(status.running, isTrue);
    port = status.port!;
  });

  tearDownAll(() async {
    await HostServer.instance.stop();
    if (await accountDir.exists()) {
      await accountDir.delete(recursive: true);
    }
  });

  LanWsClient makeClient(
    TestAccount account, {
    void Function(MessageEnvelope)? onMessage,
  }) {
    final client = LanWsClient(
      userId: account.userId,
      deviceId: 'device-${account.username}',
      nickname: account.nickname,
      token: account.token,
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
        jitterRatio: 0,
      ),
      heartbeatInterval: Duration.zero,
    );
    if (onMessage != null) {
      client.messages.listen(onMessage);
    }
    return client;
  }

  group('REST 契约', () {
    test('注册成功返回 token 与公开用户信息（不含凭据材料）', () async {
      final (status, body) = await postJson(port, 'api/register', {
        'username': 'alice',
        'password': 'password1',
        'nickname': '甲',
        'deviceId': 'device-a',
      });
      expect(status, 200);
      expect(body['token'] as String, hasLength(64));
      expect(body['expiresAt'], greaterThan(0));
      final user = body['user'] as Map<String, dynamic>;
      expect(user['username'], 'alice');
      expect(user['nickname'], '甲');
      expect(user['id'], isNotEmpty);
      expect(
        body.toString(),
        isNot(contains('passwordHash')),
        reason: '凭据材料不得下发客户端',
      );
    });

    test('重复用户名 → 409 USERNAME_TAKEN', () async {
      final (status, body) = await postJson(port, 'api/register', {
        'username': 'alice',
        'password': 'password1',
      });
      expect(status, 409);
      expect((body['error'] as Map)['code'], 'USERNAME_TAKEN');
    });

    test('非法用户名 / 弱密码 → 400', () async {
      final (s1, b1) = await postJson(port, 'api/register', {
        'username': 'ab',
        'password': 'password1',
      });
      expect(s1, 400);
      expect((b1['error'] as Map)['code'], 'INVALID_USERNAME');
      final (s2, b2) = await postJson(port, 'api/register', {
        'username': 'carol',
        'password': 'short',
      });
      expect(s2, 400);
      expect((b2['error'] as Map)['code'], 'WEAK_PASSWORD');
    });

    test('登录成功 200；密码错误与未知用户统一 401 BAD_CREDENTIALS', () async {
      final (ok, okBody) = await postJson(port, 'api/login', {
        'username': 'alice',
        'password': 'password1',
        'deviceId': 'device-a2',
      });
      expect(ok, 200);
      expect(okBody['token'] as String, hasLength(64));
      final (bad, badBody) = await postJson(port, 'api/login', {
        'username': 'alice',
        'password': 'wrong-pass',
        'deviceId': 'device-a',
      });
      expect(bad, 401);
      expect((badBody['error'] as Map)['code'], 'BAD_CREDENTIALS');
      final (ghost, ghostBody) = await postJson(port, 'api/login', {
        'username': 'ghost',
        'password': 'password1',
        'deviceId': 'd',
      });
      expect(ghost, 401);
      expect((ghostBody['error'] as Map)['code'], 'BAD_CREDENTIALS');
    });

    test('/api/me：Bearer 有效 200；缺失/无效 401 INVALID_TOKEN', () async {
      final account = await loginAccount(port, 'alice', deviceId: 'device-me');
      final (ok, okBody) = await getJson(port, 'api/me', bearer: account.token);
      expect(ok, 200);
      expect((okBody['user'] as Map)['username'], 'alice');
      final (missing, _) = await getJson(port, 'api/me');
      expect(missing, 401);
      final (invalid, invalidBody) = await getJson(
        port,
        'api/me',
        bearer: 'not-a-token',
      );
      expect(invalid, 401);
      expect((invalidBody['error'] as Map)['code'], 'INVALID_TOKEN');
    });

    test('关闭注册后 → 403 REGISTRATION_DISABLED', () async {
      await HostServer.instance.stop();
      final status = await HostServer.instance.start(
        port: 0,
        accountStore: store,
        allowRegistration: false,
      );
      port = status.port!;
      final (code, body) = await postJson(port, 'api/register', {
        'username': 'eve',
        'password': 'password1',
      });
      expect(code, 403);
      expect((body['error'] as Map)['code'], 'REGISTRATION_DISABLED');
      // 恢复开放注册，供后续用例使用。
      await HostServer.instance.stop();
      final restored = await HostServer.instance.start(
        port: 0,
        accountStore: store,
      );
      port = restored.port!;
    });

    test('未知路径 → 404', () async {
      final (status, _) = await getJson(port, 'api/nothing');
      expect(status, 404);
    });

    test('CORS：OPTIONS 预检直接放行；POST 响应同样携带放行头', () async {
      final client = HttpClient();
      try {
        final pre = await client.openUrl(
          'OPTIONS',
          Uri.parse('http://127.0.0.1:$port/api/login'),
        );
        final preRes = await pre.close();
        expect(preRes.statusCode, 200);
        expect(preRes.headers.value('access-control-allow-origin'), '*');
        expect(
          preRes.headers.value('access-control-allow-headers'),
          contains('Authorization'),
        );

        final post = await client.openUrl(
          'POST',
          Uri.parse('http://127.0.0.1:$port/api/login'),
        );
        post.headers.contentType = ContentType.json;
        post.write('{"username":"alice","password":"wrong-pass"}');
        final postRes = await post.close();
        expect(postRes.statusCode, 401);
        expect(postRes.headers.value('access-control-allow-origin'), '*');
      } finally {
        client.close(force: true);
      }
    });
  });

  group('WS 鉴权', () {
    test('无效 token：收到 error(INVALID_TOKEN) 后连接被服务端关闭', () async {
      final ws = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await ws.ready;
      ws.sink.add(
        const MessageEnvelope(
          type: MessageType.hello,
          timestamp: 1,
          payload: <String, dynamic>{
            'id': 'user-x',
            'deviceId': 'd',
            'token': 'bad-token',
          },
        ).encode(),
      );
      final received = <MessageEnvelope>[];
      await for (final raw in ws.stream.timeout(const Duration(seconds: 5))) {
        if (raw is String) {
          final envelope = MessageEnvelope.tryParse(raw);
          if (envelope != null) {
            received.add(envelope);
          }
        }
      }
      expect(received, hasLength(1));
      expect(received.single.type, MessageType.error);
      expect(received.single.payload['code'], 'INVALID_TOKEN');
    });

    test('缺少 token 的匿名 hello 同样被拒绝', () async {
      final ws = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await ws.ready;
      ws.sink.add(
        const MessageEnvelope(
          type: MessageType.hello,
          timestamp: 1,
          payload: <String, dynamic>{'id': 'anon', 'nickname': '匿名'},
        ).encode(),
      );
      final received = <MessageEnvelope>[];
      await for (final raw in ws.stream.timeout(const Duration(seconds: 5))) {
        if (raw is String) {
          final envelope = MessageEnvelope.tryParse(raw);
          if (envelope != null) {
            received.add(envelope);
          }
        }
      }
      expect(received.single.type, MessageType.error);
      expect(received.single.payload['code'], 'INVALID_TOKEN');
    });

    test('有效 token：连接成功，roster 含 username 的账号身份', () async {
      final account = await registerAccount(port, 'wsuser', nickname: 'Ws用户');
      var rosterHasUser = false;
      final client = makeClient(
        account,
        onMessage: (m) {
          if (m.type == MessageType.roster) {
            rosterHasUser = rosterUsersFromPayload(
              m.payload,
            ).any((u) => u.username == 'wsuser' && u.id == account.userId);
          }
        },
      );
      await client.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(
        () => client.isConnected && rosterHasUser,
        what: '连接成功且 roster 携带账号身份',
      );
      await client.disconnect();
    });
  });

  group('离线消息', () {
    test('目标离线暂存 → 上线补投 → ack 清除 → 不重复补投', () async {
      final alice = await registerAccount(port, 'offline_a', nickname: 'A');
      final bob = await registerAccount(port, 'offline_b', nickname: 'B');

      // A 上线，B 保持离线。
      final clientA = makeClient(alice);
      await clientA.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(() => clientA.isConnected, what: 'A 上线');

      const msgId = 'offline-msg-1';
      clientA.enqueue(
        MessageEnvelope(
          type: MessageType.chat,
          msgId: msgId,
          to: bob.userId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          payload: <String, dynamic>{'text': '离线你好'},
        ),
      );
      await waitFor(() => !clientA.hasPending(msgId), what: 'A 收到 ack（服务端已接收）');
      final stored = await store.takeOffline(userId: bob.userId);
      expect(stored.map((m) => m.msgId), contains(msgId), reason: '离线消息已暂存');

      // B 上线 → 收到补投（msgId/发送方身份保持）。
      final received = <MessageEnvelope>[];
      final clientB = makeClient(
        bob,
        onMessage: (m) {
          if (m.type == MessageType.chat) {
            received.add(m);
          }
        },
      );
      await clientB.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(
        () => received.any((m) => m.msgId == msgId),
        what: 'B 收到离线补投',
      );
      final replayed = received.singleWhere((m) => m.msgId == msgId);
      expect(replayed.payload['text'], '离线你好');
      expect(replayed.from?.id, alice.userId);
      expect(replayed.from?.username, 'offline_a');
      expect(
        replayed.payload['replay'],
        isTrue,
        reason: '补投消息须携带 replay 标记（阶段⑥）',
      );

      // B ack → 服务端删除暂存。
      clientB.enqueue(
        MessageEnvelope(
          type: MessageType.ack,
          msgId: msgId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await waitFor(
        () async => (await store.takeOffline(userId: bob.userId)).isEmpty,
        what: '服务端删除已确认的离线消息',
      );

      // B 重连后不再重复补投。
      final receivedAgain = <MessageEnvelope>[];
      final clientB2 = makeClient(
        bob,
        onMessage: (m) {
          if (m.type == MessageType.chat) {
            receivedAgain.add(m);
          }
        },
      );
      await clientB2.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(receivedAgain, isEmpty, reason: '已确认消息不应重复补投');

      await clientA.disconnect();
      await clientB.disconnect();
      await clientB2.disconnect();
    });
  });

  group('账号资料与登录限速（阶段⑧）', () {
    test('修改昵称：更新资料、广播 roster；非法昵称 400；无效 token 401', () async {
      final account = await registerAccount(port, 'nick_user', nickname: '昵称甲');
      final observer = await registerAccount(port, 'nick_obs', nickname: '观察者');
      final rosters = <MessageEnvelope>[];
      final client = makeClient(
        observer,
        onMessage: (m) {
          if (m.type == MessageType.roster) {
            rosters.add(m);
          }
        },
      );
      addTearDown(client.disconnect);
      await client.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(() => client.isConnected, what: '观察者上线');

      // 主体用户也需在线：_refreshSessionProfiles 刷新其 WS 会话资料才会广播 roster。
      final subjectClient = makeClient(account);
      addTearDown(subjectClient.disconnect);
      await subjectClient.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(() => subjectClient.isConnected, what: 'nick_user 上线');

      final (status, body) = await postJson(port, 'api/nickname', {
        'nickname': '昵称乙',
      }, bearer: account.token);
      expect(status, 200);
      expect((body['user'] as Map)['nickname'], '昵称乙');

      // /api/me 同步反映新昵称。
      final (meStatus, meBody) = await getJson(
        port,
        'api/me',
        bearer: account.token,
      );
      expect(meStatus, 200);
      expect((meBody['user'] as Map)['nickname'], '昵称乙');

      // 在线观察者通过 roster 收到新昵称（WS 会话资料已刷新）。
      await waitFor(() {
        return rosters.any((m) {
          final users = m.payload['users'];
          return users is List &&
              users.any(
                (u) =>
                    u is Map &&
                    u['id'] == account.userId &&
                    u['nickname'] == '昵称乙',
              );
        });
      }, what: 'roster 广播新昵称');

      // 非法昵称与无效 token。
      final (badStatus, badBody) = await postJson(port, 'api/nickname', {
        'nickname': ' ',
      }, bearer: account.token);
      expect(badStatus, 400);
      expect((badBody['error'] as Map)['code'], 'INVALID_NICKNAME');
      final (unauthStatus, unauthBody) = await postJson(port, 'api/nickname', {
        'nickname': '随便',
      }, bearer: 'not-a-token');
      expect(unauthStatus, 401);
      expect((unauthBody['error'] as Map)['code'], 'INVALID_TOKEN');
    });

    test('修改密码：旧密码校验、新密码落盘、其他设备会话吊销', () async {
      final account = await registerAccount(port, 'pwd_user');
      // 第二台设备登录，取得将随改密吊销的会话。
      final (loginStatus, loginBody) = await postJson(port, 'api/login', {
        'username': 'pwd_user',
        'password': 'password1',
        'deviceId': 'device-pwd-b',
      });
      expect(loginStatus, 200);
      final otherToken = loginBody['token'] as String;

      // 旧密码错误。
      final (wrongStatus, wrongBody) = await postJson(port, 'api/password', {
        'oldPassword': 'wrong-pass',
        'newPassword': 'newpassword1',
      }, bearer: account.token);
      expect(wrongStatus, 401);
      expect((wrongBody['error'] as Map)['code'], 'BAD_CREDENTIALS');

      // 新密码过弱。
      final (weakStatus, weakBody) = await postJson(port, 'api/password', {
        'oldPassword': 'password1',
        'newPassword': 'short',
      }, bearer: account.token);
      expect(weakStatus, 400);
      expect((weakBody['error'] as Map)['code'], 'WEAK_PASSWORD');

      // 修改成功：当前 token 保持有效，其他设备 token 被吊销。
      final (okStatus, _) = await postJson(port, 'api/password', {
        'oldPassword': 'password1',
        'newPassword': 'newpassword1',
      }, bearer: account.token);
      expect(okStatus, 200);
      final (meStatus, _) = await getJson(
        port,
        'api/me',
        bearer: account.token,
      );
      expect(meStatus, 200);
      final (revokedStatus, revokedBody) = await getJson(
        port,
        'api/me',
        bearer: otherToken,
      );
      expect(revokedStatus, 401);
      expect((revokedBody['error'] as Map)['code'], 'INVALID_TOKEN');

      // 新密码可登录。
      final (relogin, _) = await postJson(port, 'api/login', {
        'username': 'pwd_user',
        'password': 'newpassword1',
        'deviceId': 'device-pwd-b',
      });
      expect(relogin, 200);
    });

    test('登录限速：同 IP+用户名失败 5 次后 429；其他用户名不受影响', () async {
      await registerAccount(port, 'rate_user');
      for (var i = 0; i < 5; i++) {
        final (status, body) = await postJson(port, 'api/login', {
          'username': 'rate_user',
          'password': 'wrong-pass',
        });
        expect(status, 401, reason: '第 ${i + 1} 次失败仍应为 BAD_CREDENTIALS');
        expect((body['error'] as Map)['code'], 'BAD_CREDENTIALS');
      }
      // 触发封禁后，即便密码正确也拒绝。
      final (blocked, blockedBody) = await postJson(port, 'api/login', {
        'username': 'rate_user',
        'password': 'password1',
      });
      expect(blocked, 429);
      expect((blockedBody['error'] as Map)['code'], 'TOO_MANY_ATTEMPTS');

      // 限速键含用户名：同 IP 下其他用户不受影响。
      final (other, _) = await postJson(port, 'api/login', {
        'username': 'alice',
        'password': 'password1',
      });
      expect(other, 200);
    });
  });

  group('多设备与定向扇出', () {
    test('同账号多设备同时在线均收到定向消息；同设备重登踢旧会话', () async {
      final alice = await registerAccount(port, 'multi_a', nickname: '多设备');
      final bob = await registerAccount(port, 'multi_b', nickname: '单设备');

      final alicePhone = await loginAccount(
        port,
        'multi_a',
        deviceId: 'device-phone',
      );
      final aliceDesk = await loginAccount(
        port,
        'multi_a',
        deviceId: 'device-desk',
      );

      final phoneMsgs = <MessageEnvelope>[];
      final deskMsgs = <MessageEnvelope>[];
      // 多设备会话需使用各自的登录 token。
      final phoneClient =
          LanWsClient(
              userId: alice.userId,
              deviceId: 'device-phone',
              nickname: alice.nickname,
              token: alicePhone.token,
              backoff: BackoffStrategy(
                baseDelay: const Duration(milliseconds: 100),
                maxDelay: const Duration(seconds: 1),
                jitterRatio: 0,
              ),
              heartbeatInterval: Duration.zero,
            )
            ..messages.listen((m) {
              if (m.type == MessageType.chat) {
                phoneMsgs.add(m);
              }
            });
      final deskClient =
          LanWsClient(
              userId: alice.userId,
              deviceId: 'device-desk',
              nickname: alice.nickname,
              token: aliceDesk.token,
              backoff: BackoffStrategy(
                baseDelay: const Duration(milliseconds: 100),
                maxDelay: const Duration(seconds: 1),
                jitterRatio: 0,
              ),
              heartbeatInterval: Duration.zero,
            )
            ..messages.listen((m) {
              if (m.type == MessageType.chat) {
                deskMsgs.add(m);
              }
            });
      await phoneClient.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await deskClient.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(
        () => phoneClient.isConnected && deskClient.isConnected,
        what: '两台设备同时在线',
      );

      final bobClient = makeClient(bob);
      await bobClient.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(() => bobClient.isConnected, what: 'B 上线');

      bobClient.enqueue(
        MessageEnvelope(
          type: MessageType.chat,
          msgId: 'fanout-1',
          to: alice.userId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          payload: <String, dynamic>{'text': '给多设备的消息'},
        ),
      );
      await waitFor(
        () =>
            phoneMsgs.any((m) => m.payload['text'] == '给多设备的消息') &&
            deskMsgs.any((m) => m.payload['text'] == '给多设备的消息'),
        what: '两个会话均收到定向消息',
      );
      expect(phoneMsgs.last.from?.id, bob.userId);

      // 同设备重登：phone 以新 token 再连 → 旧 phone 会话被踢且旧 token 失效。
      final relogin = await loginAccount(
        port,
        'multi_a',
        deviceId: 'device-phone',
      );
      final phone2 = LanWsClient(
        userId: alice.userId,
        deviceId: 'device-phone',
        nickname: alice.nickname,
        token: relogin.token,
        backoff: BackoffStrategy(
          baseDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(seconds: 1),
          jitterRatio: 0,
        ),
        heartbeatInterval: Duration.zero,
      );
      await phone2.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
      await waitFor(() => phone2.isConnected, what: 'phone2 以新会话接入');
      await waitFor(
        () => phoneClient.state.phase != LanConnPhase.connected,
        what: '旧 phone 会话被踢下线',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(deskClient.isConnected, isTrue, reason: '其他设备不受影响');
      expect(phone2.isConnected, isTrue, reason: '新会话保持在线');

      await phoneClient.disconnect();
      await deskClient.disconnect();
      await phone2.disconnect();
      await bobClient.disconnect();
    });
  });
}
