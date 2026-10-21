import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/protocol/message_envelope.dart';
import '../../shared/app_paths.dart';
import '../auth/auth_providers.dart';
import '../connection/connection_providers.dart';
import 'chat_page.dart';
import 'chat_providers.dart';

/// 会话列表独立页（阶段⑧「会话列表独立页面化」）：
/// 广播会话固定首位，其后为用户会话（在线资料 + 离线历史合并），按最近
/// 消息时间降序；每行展示最近消息预览、时间与未读角标。点击进入该会话
/// 并返回消息页，替代消息页内不可扩展的横向会话选择条。
class ConversationsPage extends ConsumerWidget {
  const ConversationsPage({super.key});

  static const String routePath = AppPaths.chats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final chat = ref.watch(chatProvider);
    final myUserId = ref.watch(authProvider).user?.id ?? '';

    final known = <String, UserProfile>{
      for (final device in connection.devices) device.id: device,
    };
    // 在线用户与离线历史会话合并为用户会话行。
    final rows = <_ConversationRow>[
      for (final device in known.values)
        _ConversationRow(
          id: device.id,
          name: peerDisplayName(
            profile: device,
            messages: const <ChatMessage>[],
            userId: device.id,
          ),
          online: true,
          isSelf: device.id == myUserId,
          messages: chat.messagesOf(device.id),
          unread: chat.unread[device.id] ?? 0,
        ),
      for (final id in chat.conversations.keys)
        if (id != kBroadcastConversation && !known.containsKey(id))
          _ConversationRow(
            id: id,
            name: peerDisplayName(
              profile: null,
              messages: chat.messagesOf(id),
              userId: id,
            ),
            online: false,
            isSelf: false,
            messages: chat.messagesOf(id),
            unread: chat.unread[id] ?? 0,
          ),
    ]..sort((a, b) => b.lastTimestamp.compareTo(a.lastTimestamp));

    return Scaffold(
      appBar: AppBar(title: const Text('会话列表')),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.campaign_outlined,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            title: const Text('广播'),
            subtitle: Text(
              chat.messagesOf(kBroadcastConversation).isEmpty
                  ? '向局域网内所有用户广播消息'
                  : _previewOf(
                      chat.messagesOf(kBroadcastConversation).last,
                      myUserId,
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              ref
                  .read(chatProvider.notifier)
                  .switchConversation(kBroadcastConversation);
              context.go(AppPaths.chat);
            },
          ),
          for (final row in rows)
            ListTile(
              leading: Stack(
                children: <Widget>[
                  CircleAvatar(
                    child: Text(
                      row.name.isEmpty
                          ? '?'
                          : row.name.characters.first.toUpperCase(),
                    ),
                  ),
                  if (row.online)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              title: Text(row.isSelf ? '${row.name}（本机）' : row.name),
              subtitle: Text(
                row.lastMessage == null
                    ? (row.online ? '在线，开始对话' : '暂无消息')
                    : _previewOf(row.lastMessage!, myUserId),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _trailingOf(theme, row),
              onTap: () {
                ref.read(chatProvider.notifier).switchConversation(row.id);
                context.go(AppPaths.chat);
              },
            ),
        ],
      ),
    );
  }

  /// 最近消息预览：自己发送的加「我:」前缀。
  static String _previewOf(ChatMessage message, String myUserId) =>
      message.mine ? '我: ${message.text}' : message.text;

  static Widget? _trailingOf(ThemeData theme, _ConversationRow row) {
    final unread = row.unread;
    final time = row.lastTimestamp == 0 ? null : row.lastTimeLabel;
    if (unread == 0 && time == null) {
      return null;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (time != null) Text(time, style: theme.textTheme.labelSmall),
        if (unread > 0) ...<Widget>[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            constraints: const BoxConstraints(minWidth: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              unread > 99 ? '99+' : '$unread',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                height: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 会话列表一行的展示数据。
class _ConversationRow {
  const _ConversationRow({
    required this.id,
    required this.name,
    required this.online,
    required this.isSelf,
    required this.messages,
    required this.unread,
  });

  final String id;
  final String name;
  final bool online;
  final bool isSelf;
  final List<ChatMessage> messages;

  /// 未读数（消息归属会话 ≠ 当前会话时累计）。
  final int unread;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  int get lastTimestamp => lastMessage?.timestamp ?? 0;

  String get lastTimeLabel {
    final timestamp = lastTimestamp;
    if (timestamp == 0) {
      return '';
    }
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return sameDay
        ? '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'
        : '${time.year}/${time.month}/${time.day}';
  }
}
