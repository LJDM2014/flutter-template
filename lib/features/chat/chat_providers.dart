import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../connection/connection_providers.dart';
import '../settings/nickname_provider.dart';

/// 广播会话（会话列表中的固定项）。
const String kBroadcastConversation = 'broadcast';

/// 单条消息的发送状态。
enum ChatSendStatus { sending, sent }

/// 一条聊天消息（本地展示与持久化模型）。
class ChatMessage {
  const ChatMessage({
    required this.msgId,
    required this.senderId,
    required this.senderNickname,
    required this.text,
    required this.timestamp,
    required this.mine,
    this.status = ChatSendStatus.sent,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    msgId: json['id'] as String? ?? '',
    senderId: json['sid'] as String? ?? '',
    senderNickname: json['sn'] as String? ?? '',
    text: json['t'] as String? ?? '',
    timestamp: (json['ts'] as num?)?.toInt() ?? 0,
    mine: json['mine'] as bool? ?? false,
    status: (json['st'] as String?) == 'sending'
        ? ChatSendStatus.sending
        : ChatSendStatus.sent,
  );

  final String msgId;
  final String senderId;
  final String senderNickname;
  final String text;
  final int timestamp;
  final bool mine;
  final ChatSendStatus status;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': msgId,
    'sid': senderId,
    'sn': senderNickname,
    't': text,
    'ts': timestamp,
    'mine': mine,
    'st': status.name,
  };

  ChatMessage withStatus(ChatSendStatus status) => ChatMessage(
    msgId: msgId,
    senderId: senderId,
    senderNickname: senderNickname,
    text: text,
    timestamp: timestamp,
    mine: mine,
    status: status,
  );
}

/// 聊天页 UI 状态：会话 → 消息列表（按时间升序），及当前会话。
class ChatUiState {
  const ChatUiState({
    this.conversations = const <String, List<ChatMessage>>{},
    this.activeConversationId = kBroadcastConversation,
  });

  final Map<String, List<ChatMessage>> conversations;
  final String activeConversationId;

  List<ChatMessage> messagesOf(String conversationId) =>
      conversations[conversationId] ?? const <ChatMessage>[];

  ChatUiState copyWith({
    Map<String, List<ChatMessage>>? conversations,
    String? activeConversationId,
  }) => ChatUiState(
    conversations: conversations ?? this.conversations,
    activeConversationId: activeConversationId ?? this.activeConversationId,
  );
}

/// 聊天控制器：
/// - 订阅当前 WS 客户端的业务消息与 ack 流；
/// - 按 msgId 去重（重连补发/服务端重传安全）；
/// - 会话按「广播」与「对方设备 id」划分；
/// - 每个会话本地持久化最近 [kMaxPersistedMessages] 条（各端各自保留，不强一致）。
class ChatController extends Notifier<ChatUiState> {
  static const int kMaxPersistedMessages = 200;
  static const int _maxSeenIds = 500;

  StreamSubscription<String>? _ackSub;
  StreamSubscription<MessageEnvelope>? _msgSub;
  final Set<String> _seenMsgIds = <String>{};
  final Set<String> _loadedConversations = <String>{};

  @override
  ChatUiState build() {
    ref.listen<LanWsClient?>(wsClientProvider, (_, next) => _bind(next));
    _bind(ref.read(wsClientProvider));
    ref.onDispose(_unbind);
    _ensureLoaded(kBroadcastConversation);
    return const ChatUiState();
  }

  /// 切换会话（广播或某台设备）。
  void switchConversation(String conversationId) {
    _ensureLoaded(conversationId);
    state = state.copyWith(activeConversationId: conversationId);
  }

  /// 发送消息到当前会话；未连接时入队待发（由重连机制补发）。
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final client = ref.read(wsClientProvider);
    if (client == null || !client.isConnected) {
      return;
    }
    final myId = await ref.read(deviceIdProvider.future);
    final nickname = ref.read(nicknameProvider).value ?? '未命名设备';
    final conversationId = state.activeConversationId;
    final target = conversationId == kBroadcastConversation
        ? kBroadcastTarget
        : conversationId;
    final now = DateTime.now().millisecondsSinceEpoch;
    final envelope = MessageEnvelope(
      type: MessageType.chat,
      msgId: const Uuid().v4(),
      to: target,
      timestamp: now,
      payload: <String, dynamic>{'text': trimmed},
    );
    _append(
      conversationId,
      ChatMessage(
        msgId: envelope.msgId!,
        senderId: myId,
        senderNickname: nickname,
        text: trimmed,
        timestamp: now,
        mine: true,
        status: ChatSendStatus.sending,
      ),
    );
    client.enqueue(envelope);
  }

  void _bind(LanWsClient? client) {
    _unbind();
    if (client == null) {
      return;
    }
    _ackSub = client.acks.listen(_onAck);
    _msgSub = client.messages.listen(_onEnvelope);
  }

  void _unbind() {
    _ackSub?.cancel();
    _msgSub?.cancel();
    _ackSub = null;
    _msgSub = null;
  }

  void _onAck(String msgId) {
    final conversations = <String, List<ChatMessage>>{};
    final changedConversationIds = <String>[];
    for (final entry in state.conversations.entries) {
      final index = entry.value.indexWhere(
        (m) => m.msgId == msgId && m.status == ChatSendStatus.sending,
      );
      if (index < 0) {
        conversations[entry.key] = entry.value;
      } else {
        final updated = <ChatMessage>[...entry.value];
        updated[index] = updated[index].withStatus(ChatSendStatus.sent);
        conversations[entry.key] = updated;
        changedConversationIds.add(entry.key);
      }
    }
    if (changedConversationIds.isEmpty) {
      return;
    }
    state = state.copyWith(conversations: conversations);
    for (final conversationId in changedConversationIds) {
      _persist(conversationId);
    }
  }

  void _onEnvelope(MessageEnvelope envelope) {
    if (envelope.type != MessageType.chat) {
      return;
    }
    final msgId = envelope.msgId;
    final text = envelope.payload['text'] as String?;
    final sender = envelope.from;
    if (msgId == null || msgId.isEmpty || text == null || sender == null) {
      return;
    }
    // 按 msgId 去重：重连补发、重复转发只展示一次。
    if (_seenMsgIds.contains(msgId)) {
      return;
    }
    _seenMsgIds.add(msgId);
    if (_seenMsgIds.length > _maxSeenIds) {
      _seenMsgIds.remove(_seenMsgIds.first);
    }
    _append(
      sender.id,
      ChatMessage(
        msgId: msgId,
        senderId: sender.id,
        senderNickname: sender.nickname,
        text: text,
        timestamp: envelope.timestamp,
        mine: false,
      ),
    );
  }

  void _append(String conversationId, ChatMessage message) {
    final conversations = <String, List<ChatMessage>>{
      for (final entry in state.conversations.entries) entry.key: entry.value,
    };
    conversations[conversationId] = <ChatMessage>[
      ...state.messagesOf(conversationId),
      message,
    ];
    state = state.copyWith(conversations: conversations);
    _persist(conversationId);
  }

  void _ensureLoaded(String conversationId) {
    if (_loadedConversations.contains(conversationId)) {
      return;
    }
    _loadedConversations.add(conversationId);
    unawaited(_loadFromPrefs(conversationId));
  }

  Future<void> _loadFromPrefs(String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chatKey(conversationId));
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      // 仅当内存中还没有该会话的消息时才回填，避免覆盖新消息。
      if (state.messagesOf(conversationId).isNotEmpty) {
        return;
      }
      final messages = <ChatMessage>[
        for (final item in decoded.whereType<Map>())
          ChatMessage.fromJson(item.cast<String, dynamic>()),
      ];
      state = state.copyWith(
        conversations: <String, List<ChatMessage>>{
          for (final entry in state.conversations.entries)
            entry.key: entry.value,
          conversationId: messages,
        },
      );
    } on FormatException {
      // 历史数据损坏时忽略，不影响新消息。
    }
  }

  Future<void> _persist(String conversationId) async {
    final messages = state.messagesOf(conversationId);
    if (messages.isEmpty) {
      return;
    }
    final trimmed = messages.length > kMaxPersistedMessages
        ? messages.sublist(messages.length - kMaxPersistedMessages)
        : messages;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _chatKey(conversationId),
        jsonEncode(<Object>[for (final message in trimmed) message.toJson()]),
      );
    } on JsonUnsupportedObjectError {
      // 序列化失败不应影响 UI。
    }
  }

  String _chatKey(String conversationId) => 'pref.chat.$conversationId';
}

final NotifierProvider<ChatController, ChatUiState> chatProvider =
    NotifierProvider<ChatController, ChatUiState>(ChatController.new);
