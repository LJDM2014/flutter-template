import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../../shared/app_paths.dart';
import '../connection/connection_providers.dart';
import 'chat_providers.dart';

/// 消息页：会话切换（广播 + 各设备）、消息气泡、输入发送。
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
    ref.read(chatProvider.notifier).send(text);
    _inputController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final chat = ref.watch(chatProvider);
    final connected = connection.conn.phase == LanConnPhase.connected;
    final myDeviceId = ref.watch(deviceIdProvider).value ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      body: SafeArea(
        child: !connected
            ? _EmptyState(theme: theme)
            : Column(
                children: <Widget>[
                  _ConversationSelector(
                    devices: connection.devices,
                    activeId: chat.activeConversationId,
                    myDeviceId: myDeviceId,
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _MessageList(
                      messages: chat.messagesOf(chat.activeConversationId),
                      isBroadcast:
                          chat.activeConversationId == kBroadcastConversation,
                    ),
                  ),
                  const Divider(height: 1),
                  _InputBar(
                    controller: _inputController,
                    onSend: _send,
                    targetLabel:
                        chat.activeConversationId == kBroadcastConversation
                        ? '广播'
                        : connection.devices
                                  .where(
                                    (d) => d.id == chat.activeConversationId,
                                  )
                                  .map((d) => d.nickname)
                                  .firstOrNull ??
                              '设备',
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('尚未连接到局域网中继服务', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('请先在「连接」页接入桌面端，即可与局域网设备互发消息', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// 顶部会话选择器：广播 + 各在线设备。
class _ConversationSelector extends ConsumerWidget {
  const _ConversationSelector({
    required this.devices,
    required this.activeId,
    required this.myDeviceId,
  });

  final List<DeviceProfile> devices;
  final String activeId;
  final String myDeviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = <(String, String, bool)>[
      (kBroadcastConversation, '广播', false),
      for (final device in devices)
        (
          device.id,
          device.nickname.isEmpty
              ? '设备 ${device.id.substring(0, 8)}'
              : device.nickname,
          device.id == myDeviceId,
        ),
    ];
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (id, label, isSelf) = entries[index];
          return ChoiceChip(
            selected: id == activeId,
            label: Text(isSelf ? '$label（本机）' : label),
            onSelected: (_) =>
                ref.read(chatProvider.notifier).switchConversation(id),
          );
        },
      ),
    );
  }
}

/// 消息列表（按时间升序展示，新消息在底部）。
class _MessageList extends StatelessWidget {
  const _MessageList({required this.messages, required this.isBroadcast});

  final List<ChatMessage> messages;
  final bool isBroadcast;

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
        final message = messages[messages.length - 1 - index];
        return _MessageBubble(
          message: message,
          showSender: isBroadcast && !message.mine,
        );
      },
    );
  }
}

/// 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.showSender});

  final ChatMessage message;
  final bool showSender;

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
                message.senderNickname.isEmpty
                    ? '设备 ${message.senderId.substring(0, 8)}'
                    : message.senderNickname,
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
              ],
            ),
          ],
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
