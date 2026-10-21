import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../../shared/app_paths.dart';
import '../connection/connection_providers.dart';
import 'chat_providers.dart';

/// 消息页：会话切换（广播 + 各用户）、消息气泡、输入发送。
///
/// 未连接时展示引导空态；连接后广播/定向发送到当前会话目标。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  static const String routePath = AppPaths.chat;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      return;
    }
    // send 返回 false（尚无客户端/未登录）时保留输入，等待连接后再发。
    if (ref.read(chatProvider.notifier).send(text)) {
      _inputController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final chat = ref.watch(chatProvider);
    final connected = connection.conn.phase == LanConnPhase.connected;

    // 服务端 error 消息全局提示（展示一次后清除）。
    ref.listen<ChatUiState>(chatProvider, (previous, next) {
      final error = next.error;
      if (error != null && previous?.error != error) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error)));
        ref.read(chatProvider.notifier).clearError();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: <Widget>[
          // 会话列表独立页（阶段⑧页面化，替代横向选择条）。
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: '会话列表',
            onPressed: () => context.go(AppPaths.chats),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: !connected
                  ? _EmptyState(theme: theme, conn: connection.conn)
                  : _MessageList(
                      messages: chat.messagesOf(chat.activeConversationId),
                      isBroadcast:
                          chat.activeConversationId == kBroadcastConversation,
                      onRetry: (msgId) => ref
                          .read(chatProvider.notifier)
                          .retryMessage(chat.activeConversationId, msgId),
                    ),
            ),
            const Divider(height: 1),
            // 断线期间输入栏保持可用：消息入待发队列，重连后自动补发（阶段⑦）。
            _InputBar(
              controller: _inputController,
              onSend: _send,
              targetLabel: _targetLabelOf(chat, connection.devices),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前会话的发送目标展示名（断线时在线列表可能为空，需从消息记录取名）。
String _targetLabelOf(ChatUiState chat, List<UserProfile> devices) {
  final id = chat.activeConversationId;
  if (id == kBroadcastConversation) {
    return '广播';
  }
  for (final device in devices) {
    if (device.id == id) {
      return peerDisplayName(
        profile: device,
        messages: const <ChatMessage>[],
        userId: id,
      );
    }
  }
  return peerDisplayName(
    profile: null,
    messages: chat.messagesOf(id),
    userId: id,
  );
}

/// 会话对方的展示名：在线资料优先，其次消息记录中对方的昵称/账号名，最后 id 前缀。
String peerDisplayName({
  UserProfile? profile,
  required List<ChatMessage> messages,
  required String userId,
}) {
  if (profile != null) {
    if (profile.nickname.isNotEmpty) {
      return profile.nickname;
    }
    if (profile.username.isNotEmpty) {
      return profile.username;
    }
  }
  for (final message in messages.reversed) {
    if (message.mine) {
      continue;
    }
    if (message.senderNickname.isNotEmpty) {
      return message.senderNickname;
    }
    if (message.senderUsername.isNotEmpty) {
      return message.senderUsername;
    }
    break;
  }
  return '用户 ${userId.length > 8 ? userId.substring(0, 8) : userId}';
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({required this.theme, required this.conn});

  final ThemeData theme;
  final LanConnState conn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoConnecting = ref.watch(
      connectionProvider.select((s) => s.autoConnecting),
    );
    // 自动连接进行中（地址解析阶段，连接阶段由 conn.phase 表达）。
    if (autoConnecting || conn.phase == LanConnPhase.connecting) {
      return _CenterHint(
        icon: Icons.sync,
        spin: true,
        text: autoConnecting && conn.phase == LanConnPhase.disconnected
            ? '正在寻找可连通的服务器…'
            : '正在连接服务器…',
      );
    }
    if (conn.phase == LanConnPhase.reconnecting) {
      return _CenterHint(
        icon: Icons.restart_alt,
        spin: true,
        text: conn.retryIn == null
            ? '连接断开，正在重连…'
            : '连接断开，${conn.retryIn!.inSeconds + 1}s 后重连…',
      );
    }
    final error = conn.phase == LanConnPhase.authFailed
        ? '登录已失效，请重新登录'
        : conn.error;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            error != null ? Icons.cloud_off_outlined : Icons.forum_outlined,
            size: 64,
            color: error != null
                ? theme.colorScheme.error
                : theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            error ?? '尚未连接到局域网中继服务',
            style: theme.textTheme.titleMedium?.copyWith(
              color: error != null ? theme.colorScheme.error : null,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            error != null
                ? '可重试自动检测，或前往连接页手动指定服务器地址'
                : '登录后将自动接入桌面端中继，即可与局域网用户互发消息',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (error != null) ...<Widget>[
            FilledButton.icon(
              onPressed: () =>
                  ref.read(connectionProvider.notifier).autoConnect(),
              icon: const Icon(Icons.radar),
              label: const Text('自动检测并连接'),
            ),
            const SizedBox(height: 8),
          ],
          TextButton(
            onPressed: () => context.go(AppPaths.connect),
            child: const Text('前往连接设置'),
          ),
        ],
      ),
    );
  }
}

/// 空态居中提示（图标可选旋转动画，用于连接中/重连中）。
class _CenterHint extends StatelessWidget {
  const _CenterHint({
    required this.icon,
    required this.text,
    this.spin = false,
  });

  final IconData icon;
  final String text;
  final bool spin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconWidget = Icon(icon, size: 64, color: theme.colorScheme.primary);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          spin
              ? const SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : iconWidget,
          const SizedBox(height: 12),
          Text(text, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }
}

/// 消息列表（按时间升序展示，新消息在底部）。
/// 首条离线补投消息前插入「以下是离线消息」分隔线（阶段⑥）。
class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.isBroadcast,
    required this.onRetry,
  });

  final List<ChatMessage> messages;
  final bool isBroadcast;
  final void Function(String msgId) onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (messages.isEmpty) {
      return Center(
        child: Text(
          isBroadcast ? '向局域网内所有设备广播消息' : '向对方发送定向消息',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        // reverse 列表：index 0 是最新一条，换算回时间升序下标。
        final chronological = messages.length - 1 - index;
        final message = messages[chronological];
        final showReplayDivider =
            message.isReplay &&
            (chronological == 0 || !messages[chronological - 1].isReplay);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showReplayDivider) ...<Widget>[
              const _ReplayDivider(),
              const SizedBox(height: 4),
            ],
            _MessageBubble(
              message: message,
              showSender: isBroadcast && !message.mine,
              onRetry: message.status == ChatSendStatus.failed
                  ? () => onRetry(message.msgId)
                  : null,
            ),
          ],
        );
      },
    );
  }
}

/// 「以下是离线消息」分隔线。
class _ReplayDivider extends StatelessWidget {
  const _ReplayDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '以下是离线消息',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

/// 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.showSender,
    this.onRetry,
  });

  final ChatMessage message;
  final bool showSender;

  /// 非空表示发送失败，点击气泡触发重试。
  final VoidCallback? onRetry;

  /// 发送者展示名：昵称优先，其次账号名，最后 id 前缀。
  String get _senderLabel {
    if (message.senderNickname.isNotEmpty) {
      return message.senderNickname;
    }
    if (message.senderUsername.isNotEmpty) {
      return '@${message.senderUsername}';
    }
    final id = message.senderId;
    return '用户 ${id.length > 8 ? id.substring(0, 8) : id}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = DateTime.fromMillisecondsSinceEpoch(message.timestamp);
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final bubbleColor = message.mine
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Align(
      alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // 发送失败的气泡点击重试（阶段⑦）。
        onTap: onRetry,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.72,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(message.mine ? 12 : 2),
              bottomRight: Radius.circular(message.mine ? 2 : 12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (showSender)
                Text(
                  _senderLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              Text(message.text, style: theme.textTheme.bodyMedium),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(hhmm, style: theme.textTheme.labelSmall),
                  if (message.mine &&
                      message.status == ChatSendStatus.sending) ...<Widget>[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.schedule,
                      size: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                  if (message.mine &&
                      message.status == ChatSendStatus.failed) ...<Widget>[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.error_outline,
                      size: 12,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '发送失败，点击重试',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部输入栏。
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.targetLabel,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: '发给：$targetLabel',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: onSend,
            icon: const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }
}
