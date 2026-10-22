import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_template/features/auth/auth_providers.dart';
import 'package:flutter_template/features/chat/chat_providers.dart';
import 'package:flutter_template/features/connection/connection_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_test_kit.dart';

/// 静态登录态：跳过真实登录流程，为聊天层测试提供账号身份。
class _StaticAuth extends AuthController {
  _StaticAuth(this.user);

  final UserProfile user;

  @override
  AuthState build() =>
      AuthState(phase: AuthPhase.loggedIn, user: user, token: 'test-token');
}

/// 聊天层集成测试：真实中继服务 + 两个独立的 Provider 容器
/// （模拟两个登录用户），覆盖发送/接收/ack 状态流转/本地持久化/定向发送。
void main() {
  late int port;
  late Directory accountDir;
  late TestAccount accountA;
  late TestAccount accountB;
  late LanWsClient clientA;
  late LanWsClient clientB;
  late ProviderContainer containerA;
  late ProviderContainer containerB;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final (dir, store) = await createTempAccountStore();
    accountDir = dir;
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: store,
    );
    expect(status.running, isTrue);
    port = status.port!;
    accountA = await registerAccount(port, 'flow_a', nickname: '甲');
    accountB = await registerAccount(port, 'flow_b', nickname: '乙');
  });

  tearDownAll(() async {
    await clientA.disconnect();
    await clientB.disconnect();
    await HostServer.instance.stop();
    containerA.dispose();
    containerB.dispose();
    if (await accountDir.exists()) {
      await accountDir.delete(recursive: true);
    }
  });

  Future<LanWsClient> makeClient(TestAccount account, String nickname) async {
    final client = LanWsClient(
      userId: account.userId,
      deviceId: 'device-${account.username}',
      nickname: nickname,
      token: account.token,
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
    clientA = await makeClient(accountA, '甲');
    clientB = await makeClient(accountB, '乙');
    await waitFor(
      () => clientA.isConnected && clientB.isConnected,
      what: '双端连接',
    );

    containerA = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: accountA.userId, username: 'flow_a', nickname: '甲'),
          ),
        ),
      ],
    );
    containerB = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: accountB.userId, username: 'flow_b', nickname: '乙'),
          ),
        ),
      ],
    );
    containerA.read(wsClientProvider.notifier).attach(clientA);
    containerB.read(wsClientProvider.notifier).attach(clientB);
    // 读取 provider 触发 build，开始订阅消息流。
    containerA.read(chatProvider);
    containerB.read(chatProvider);

    // —— 广播发送 ——
    containerA.read(chatProvider.notifier).send('大家好');
    expect(
      chatStateOf(containerA).messagesOf(kBroadcastConversation).last.text,
      '大家好',
    );
    expect(
      chatStateOf(containerA).messagesOf(kBroadcastConversation).last.status,
      ChatSendStatus.sending,
      reason: 'ack 未到达前应为发送中',
    );

    // —— B 端接收 ——（会话按发送方 userId 划分）
    await waitFor(
      () => chatStateOf(
        containerB,
      ).messagesOf(accountA.userId).any((m) => m.text == '大家好'),
      what: 'B 收到广播并建立与 A 的会话',
    );
    final received = chatStateOf(
      containerB,
    ).messagesOf(accountA.userId).lastWhere((m) => m.text == '大家好');
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
    containerA.read(chatProvider.notifier).switchConversation(accountB.userId);
    containerA.read(chatProvider.notifier).send('点对点');
    await waitFor(
      () => chatStateOf(
        containerB,
      ).messagesOf(accountA.userId).any((m) => m.text == '点对点'),
      what: 'B 收到定向消息（仍归入与 A 的会话）',
    );
    // 广播会话不应收到定向消息以外的混淆，B 的广播会话只有 A 广播的记录由
    // A 端产生，B 端广播会话应为空（定向消息归入与 A 的会话）。
    expect(
      chatStateOf(containerB).messagesOf(kBroadcastConversation).isEmpty,
      isTrue,
    );
  });

  test('阶段⑥ 离线补投：消息带 replay 标记，未读与提示累计，切会话清零', () async {
    final accountC = await registerAccount(port, 'flow_c', nickname: '丙');
    final accountD = await registerAccount(port, 'flow_d', nickname: '丁');

    // C 上线，向离线的 D 定向发送两条消息后下线。
    final clientC = await makeClient(accountC, '丙');
    await waitFor(() => clientC.isConnected, what: 'C 上线');
    for (final (index, text) in <String>['离线一', '离线二'].indexed) {
      clientC.enqueue(
        MessageEnvelope(
          type: MessageType.chat,
          msgId: 'replay-$index',
          to: accountD.userId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          payload: <String, dynamic>{'text': text},
        ),
      );
    }
    await waitFor(
      () => !clientC.hasPending('replay-0') && !clientC.hasPending('replay-1'),
      what: 'C 的消息被服务端暂存',
    );
    await clientC.disconnect();

    // D 上线：收到补投，replay 标记、未读计数、全局提示状态三者齐备。
    final clientD = await makeClient(accountD, '丁');
    final containerD = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: accountD.userId, username: 'flow_d', nickname: '丁'),
          ),
        ),
      ],
    );
    addTearDown(containerD.dispose);
    containerD.read(wsClientProvider.notifier).attach(clientD);
    containerD.read(chatProvider);

    await waitFor(
      () => chatStateOf(containerD).messagesOf(accountC.userId).length >= 2,
      what: 'D 收到两条补投消息',
    );
    final replayed = chatStateOf(containerD).messagesOf(accountC.userId);
    expect(
      replayed.every((m) => m.isReplay),
      isTrue,
      reason: '补投消息带 replay 标记',
    );
    // D 当前停留在广播会话，与丙的会话未读 +2。
    expect(chatStateOf(containerD).unread[accountC.userId], 2);
    expect(chatStateOf(containerD).replayNotice, 2, reason: '非当前会话补投累计全局提示条数');

    // 切换到该会话：未读清零；提示由 UI 展示后清除。
    containerD.read(chatProvider.notifier).switchConversation(accountC.userId);
    expect(chatStateOf(containerD).unread[accountC.userId] ?? 0, 0);
    containerD.read(chatProvider.notifier).clearReplayNotice();
    expect(chatStateOf(containerD).replayNotice, 0);

    await clientD.disconnect();
  });

  test('阶段⑦ 未连接发送：断线入队、重连补发并转已送达', () async {
    // 接收方保持在线。
    final accountE = await registerAccount(port, 'flow_e', nickname: '戊');
    final clientE = await makeClient(accountE, '戊');
    final containerE = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: accountE.userId, username: 'flow_e', nickname: '戊'),
          ),
        ),
      ],
    );
    addTearDown(containerE.dispose);
    containerE.read(wsClientProvider.notifier).attach(clientE);
    containerE.read(chatProvider);

    // 发送方构造尚未连接的客户端（模拟断线期间输入）。
    final sender = await registerAccount(port, 'flow_s', nickname: '己');
    final clientS = LanWsClient(
      userId: sender.userId,
      deviceId: 'device-flow_s',
      nickname: '己',
      token: sender.token,
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 100),
        maxDelay: const Duration(seconds: 1),
        jitterRatio: 0,
      ),
      heartbeatInterval: Duration.zero,
    );
    final containerS = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: sender.userId, username: 'flow_s', nickname: '己'),
          ),
        ),
      ],
    );
    addTearDown(containerS.dispose);
    containerS.read(wsClientProvider.notifier).attach(clientS);
    containerS.read(chatProvider);

    // 未连接发送：消息不丢弃，本地为「发送中」，envelope 已入待发队列。
    expect(containerS.read(chatProvider.notifier).send('排队消息'), isTrue);
    final queued = chatStateOf(
      containerS,
    ).messagesOf(kBroadcastConversation).last;
    expect(queued.text, '排队消息');
    expect(queued.status, ChatSendStatus.sending);
    expect(clientS.pendingCount, 1, reason: '消息已入待发队列等待补发');

    // 重连后自动补发：对端收到，ack 后转「已送达」。
    await clientS.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
    await waitFor(
      () => chatStateOf(
        containerE,
      ).messagesOf(sender.userId).any((m) => m.text == '排队消息'),
      what: '重连补发后对端收到消息',
    );
    await waitFor(
      () =>
          chatStateOf(
            containerS,
          ).messagesOf(kBroadcastConversation).last.status ==
          ChatSendStatus.sent,
      what: 'ack 后转已送达',
    );

    await clientE.disconnect();
    await clientS.disconnect();
  });

  test('阶段⑦ 重连上限：转慢速轮询不放弃，实例替换可重试，恢复后补发', () async {
    final accountG = await registerAccount(port, 'flow_g', nickname: '庚');
    // 指向不可达地址；退避极短且限制 1 次重试，快速耗尽退避转入慢速轮询。
    final clientG = LanWsClient(
      userId: accountG.userId,
      deviceId: 'device-flow_g',
      nickname: '庚',
      token: accountG.token,
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
        jitterRatio: 0,
        maxAttempts: 1,
      ),
      heartbeatInterval: Duration.zero,
    );
    final containerG = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => _StaticAuth(
            UserProfile(id: accountG.userId, username: 'flow_g', nickname: '庚'),
          ),
        ),
      ],
    );
    addTearDown(containerG.dispose);
    containerG.read(wsClientProvider.notifier).attach(clientG);
    containerG.read(chatProvider);

    await clientG.connect(Uri.parse('ws://127.0.0.1:1/ws'));
    expect(containerG.read(chatProvider.notifier).send('排队消息'), isTrue);

    // R3：退避耗尽后进入慢速轮询（不再进入 disconnected 终态），
    // 消息保持「发送中」等待补发，不标记失败。
    await waitFor(
      () =>
          clientG.state.phase == LanConnPhase.reconnecting &&
          clientG.state.slowPolling,
      what: '退避耗尽转入慢速轮询',
    );
    final queued = chatStateOf(
      containerG,
    ).messagesOf(kBroadcastConversation).last;
    expect(queued.text, '排队消息');
    expect(
      queued.status,
      ChatSendStatus.sending,
      reason: '慢速轮询期间消息保持发送中等待补发',
    );
    expect(clientG.hasPending(queued.msgId), isTrue);

    // 客户端实例被替换（如重新登录）：旧实例待发消息转失败，用户可重试。
    final clientG2 = LanWsClient(
      userId: accountG.userId,
      deviceId: 'device-flow_g',
      nickname: '庚',
      token: accountG.token,
      backoff: BackoffStrategy(
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
        jitterRatio: 0,
        maxAttempts: 1,
      ),
      heartbeatInterval: Duration.zero,
    );
    containerG.read(wsClientProvider.notifier).attach(clientG2);
    await waitFor(
      () =>
          chatStateOf(
            containerG,
          ).messagesOf(kBroadcastConversation).last.status ==
          ChatSendStatus.failed,
      what: '实例替换后发送中消息标记为失败',
    );

    // 重试：置回「发送中」并重新入队（此时仍未连接，等待补发）。
    final msgId = chatStateOf(
      containerG,
    ).messagesOf(kBroadcastConversation).last.msgId;
    containerG
        .read(chatProvider.notifier)
        .retryMessage(kBroadcastConversation, msgId);
    expect(
      chatStateOf(containerG).messagesOf(kBroadcastConversation).last.status,
      ChatSendStatus.sending,
    );
    expect(clientG2.hasPending(msgId), isTrue, reason: '重试后重新入待发队列');

    // 中继恢复（连接真实地址）：重试消息补发并被 ack 转已送达。
    await clientG2.connect(Uri.parse('ws://127.0.0.1:$port/ws'));
    await waitFor(
      () =>
          chatStateOf(
            containerG,
          ).messagesOf(kBroadcastConversation).last.status ==
          ChatSendStatus.sent,
      what: '恢复连接后消息补发并转已送达',
    );
    expect(clientG2.pendingCount, 0, reason: '补发成功后待发队列清空');

    await clientG.disconnect();
    await clientG2.disconnect();
  });
}
