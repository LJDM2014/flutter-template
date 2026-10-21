import 'dart:io';

import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'server_test_kit.dart';

/// 集成测试：真实 shelf 中继服务（token 鉴权）+ LanWsClient（localhost 回环）。
///
/// 覆盖：hello 鉴权/roster、广播与定向转发、ack、心跳应答、
/// 断线自动重连与未确认消息补发。
void main() {
  late int port;
  late Directory accountDir;
  late TestAccount accountA;
  late TestAccount accountB;
  final List<MessageEnvelope> aMessages = <MessageEnvelope>[];
  final List<MessageEnvelope> bMessages = <MessageEnvelope>[];
  late LanWsClient clientA;
  late LanWsClient clientB;

  Uri serverUri() => Uri.parse('ws://127.0.0.1:$port/ws');

  MessageEnvelope chat(String to, String text) => MessageEnvelope(
    type: MessageType.chat,
    msgId: const Uuid().v4(),
    to: to,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    payload: <String, dynamic>{'text': text},
  );

  setUpAll(() async {
    final (dir, store) = await createTempAccountStore();
    accountDir = dir;
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: store,
    );
    expect(status.running, isTrue, reason: '测试中继服务应启动成功');
    port = status.port!;
    accountA = await registerAccount(port, 'integ_a', nickname: '甲');
    accountB = await registerAccount(port, 'integ_b', nickname: '乙');
  });

  tearDownAll(() async {
    await clientA.disconnect();
    await clientB.disconnect();
    await HostServer.instance.stop();
    if (await accountDir.exists()) {
      await accountDir.delete(recursive: true);
    }
  });

  Future<LanWsClient> makeClient(
    TestAccount account,
    void Function(MessageEnvelope) onMessage,
  ) async {
    final client = LanWsClient(
      userId: account.userId,
      deviceId: 'device-${account.username}',
      nickname: account.nickname,
      token: account.token,
      // 加速测试：100ms 退避起步，关闭应用层心跳。
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
        jitterRatio: 0,
      ),
      heartbeatInterval: Duration.zero,
    );
    client.messages.listen(onMessage);
    await client.connect(serverUri());
    return client;
  }

  test('两台客户端接入后收到 roster；广播/定向消息正确转发且发送方收到 ack', () async {
    var rosterCountA = 0;
    var rosterCountB = 0;
    clientA = await makeClient(accountA, (m) {
      if (m.type == MessageType.roster) {
        rosterCountA++;
      } else {
        aMessages.add(m);
      }
    });
    await waitFor(
      () => clientA.isConnected && rosterCountA >= 1,
      what: 'A 连接并收到 roster',
    );

    clientB = await makeClient(accountB, (m) {
      if (m.type == MessageType.roster) {
        rosterCountB++;
      } else {
        bMessages.add(m);
      }
    });
    await waitFor(
      () => clientB.isConnected && rosterCountB >= 1 && rosterCountA >= 2,
      what: 'B 接入后双方 roster 更新为 2 个用户',
    );

    // 广播：A → 所有人（不含 A 自身）
    final broadcast = chat(kBroadcastTarget, '大家好');
    clientA.enqueue(broadcast);
    await waitFor(
      () => bMessages.any(
        (m) => m.type == MessageType.chat && m.payload['text'] == '大家好',
      ),
      what: 'B 收到广播消息',
    );
    expect(
      bMessages.last.from?.id,
      accountA.userId,
      reason: '服务端应回填 from 为发送方账号身份',
    );
    expect(bMessages.last.from?.username, 'integ_a');
    await waitFor(
      () => !clientA.hasPending(broadcast.msgId!),
      what: 'A 收到 ack（待发队列清空）',
    );
    expect(
      aMessages.where((m) => m.payload['text'] == '大家好'),
      isEmpty,
      reason: '广播不应回发给发送方',
    );

    // 定向：A → B（to 为目标用户 id）
    clientA.enqueue(chat(accountB.userId, '点对点'));
    await waitFor(
      () => bMessages.any((m) => m.payload['text'] == '点对点'),
      what: 'B 收到定向消息',
    );
    expect(
      aMessages.any((m) => m.payload['text'] == '点对点'),
      isFalse,
      reason: '定向消息不应回发给发送方',
    );

    // 心跳：客户端发 ping，服务端回 pong（pong 在客户端内部消化）。
    clientA.enqueue(
      MessageEnvelope(
        type: MessageType.ping,
        timestamp: 1,
        payload: <String, dynamic>{'t': 1},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(clientA.isConnected, isTrue, reason: '心跳交互不应破坏连接');
  });

  test('断线后自动重连，离线期间入队的消息在重连后补发', () async {
    // 服务端强制断开 A，模拟网络中断。
    await HostServer.instance.dropClient(accountA.userId);
    await waitFor(
      () =>
          clientA.state.phase == LanConnPhase.reconnecting ||
          clientA.state.phase == LanConnPhase.connecting,
      what: 'A 进入重连阶段',
    );

    // A 离线期间发送的消息应留在待发队列。
    final offlineMsg = chat(kBroadcastTarget, '离线补发');
    clientA.enqueue(offlineMsg);
    expect(clientA.hasPending(offlineMsg.msgId!), isTrue);

    // 自动重连成功（token 仍有效，服务端仍在运行）。
    await waitFor(
      () => clientA.isConnected,
      what: 'A 自动重连成功',
      timeout: const Duration(seconds: 8),
    );

    // 补发成功：B 收到，A 收到 ack 后队列清空。
    await waitFor(
      () => bMessages.any((m) => m.payload['text'] == '离线补发'),
      what: 'B 收到补发消息',
      timeout: const Duration(seconds: 8),
    );
    await waitFor(
      () => !clientA.hasPending(offlineMsg.msgId!),
      what: 'A 收到补发消息的 ack',
      timeout: const Duration(seconds: 8),
    );
  });

  test('主动断开后不再自动重连', () async {
    await clientB.disconnect();
    expect(clientB.state.phase, LanConnPhase.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      clientB.state.phase,
      LanConnPhase.disconnected,
      reason: '主动断开不应触发重连',
    );
  });
}
