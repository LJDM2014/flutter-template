import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/features/chat/chat_providers.dart';
import 'package:flutter_template/features/connection/connection_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 聊天层集成测试：真实中继服务 + 两个独立的 Provider 容器
/// （模拟两台设备），覆盖发送/接收/ack 状态流转/本地持久化/定向发送。
void main() {
  late int port;
  late LanWsClient clientA;
  late LanWsClient clientB;
  late ProviderContainer containerA;
  late ProviderContainer containerB;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final status = await HostServer.instance.start(port: 0);
    expect(status.running, isTrue);
    port = status.port!;
  });

  tearDownAll(() async {
    await clientA.disconnect();
    await clientB.disconnect();
    await HostServer.instance.stop();
    containerA.dispose();
    containerB.dispose();
  });

  Future<LanWsClient> makeClient(String deviceId, String nickname) async {
    final client = LanWsClient(
      deviceId: deviceId,
      nickname: nickname,
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
        jitterRatio: 0,
      ),
      heartbeatInterval: Duration.zero,
    );
    await client.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
    return client;
  }

  Future<void> waitFor(
    FutureOr<bool> Function() probe, {
    String what = 'condition',
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probe()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('等待超时：$what');
  }

  ChatUiState chatStateOf(ProviderContainer container) =>
      container.read(chatProvider);

  test('广播消息：跨容器送达、ack 流转、本地持久化、定向发送', () async {
    clientA = await makeClient('client-a', '甲');
    clientB = await makeClient('client-b', '乙');
    await waitFor(
      () => clientA.isConnected && clientB.isConnected,
      what: '双端连接',
    );

    containerA = ProviderContainer();
    containerB = ProviderContainer();
    containerA.read(wsClientProvider.notifier).attach(clientA);
    containerB.read(wsClientProvider.notifier).attach(clientB);
    // 读取 provider 触发 build，开始订阅消息流。
    containerA.read(chatProvider);
    containerB.read(chatProvider);

    // —— 广播发送 ——
    await containerA.read(chatProvider.notifier).send('大家好');
    expect(
      chatStateOf(containerA).messagesOf(kBroadcastConversation).last.text,
      '大家好',
    );
    expect(
      chatStateOf(containerA).messagesOf(kBroadcastConversation).last.status,
      ChatSendStatus.sending,
      reason: 'ack 未到达前应为发送中',
    );

    // —— B 端接收 ——
    await waitFor(
      () => chatStateOf(
        containerB,
      ).messagesOf('client-a').any((m) => m.text == '大家好'),
      what: 'B 收到广播并建立与 A 的会话',
    );
    final received = chatStateOf(
      containerB,
    ).messagesOf('client-a').lastWhere((m) => m.text == '大家好');
    expect(received.mine, isFalse);
    expect(received.senderNickname, '甲');

    // —— A 端 ack 后状态变为已送达 ——
    await waitFor(
      () =>
          chatStateOf(containerA)
              .messagesOf(kBroadcastConversation)
              .lastWhere((m) => m.text == '大家好')
              .status ==
          ChatSendStatus.sent,
      what: 'A 的消息被 ack 标记为已送达',
    );

    // —— 本地持久化（A 端） ——
    await waitFor(() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs
              .getString('pref.chat.$kBroadcastConversation')
              ?.contains('大家好') ??
          false;
    }, what: 'A 端广播会话已持久化');

    // —— 定向发送：A → B ——
    containerA.read(chatProvider.notifier).switchConversation('client-b');
    await containerA.read(chatProvider.notifier).send('点对点');
    await waitFor(
      () => chatStateOf(
        containerB,
      ).messagesOf('client-a').any((m) => m.text == '点对点'),
      what: 'B 收到定向消息（仍归入与 A 的会话）',
    );
    // 广播会话不应收到定向消息以外的混淆，B 的广播会话只有 A 广播的记录由
    // A 端产生，B 端广播会话应为空（定向消息归入 client-a 会话）。
    expect(
      chatStateOf(containerB).messagesOf(kBroadcastConversation).isEmpty,
      isTrue,
    );
  });
}
