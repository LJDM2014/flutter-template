import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../auth/auth_providers.dart';
import '../connection/connection_providers.dart';

/// 广播会话（会话列表中的固定项）。
const String kBroadcastConversation = 'broadcast';

/// 单条消息的发送状态。
///
/// [ChatSendStatus.failed] 为终态：重连放弃（重试上限）后标记，
/// 用户点击重试后置回「发送中」并重新入待发队列。
enum ChatSendStatus { sending, sent, failed }

/// 一条聊天消息（本地展示与持久化模型）。
class ChatMessage {
  const ChatMessage({
    required this.msgId,
    required this.senderId,
    required this.senderNickname,
    required this.text,
    required this.timestamp,
    required this.mine,
    this.senderUsername = '',
    this.status = ChatSendStatus.sent,
    this.isReplay = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    msgId: json['id'] as String? ?? '',
    senderId: json['sid'] as String? ?? '',
    senderNickname: json['sn'] as String? ?? '',
    text: json['t'] as String? ?? '',
    timestamp: (json['ts'] as num?)?.toInt() ?? 0,
    mine: json['mine'] as bool? ?? false,
    senderUsername: json['su'] as String? ?? '',
    status: switch (json['st'] as String?) {
      'sending' => ChatSendStatus.sending,
      'failed' => ChatSendStatus.failed,
      _ => ChatSendStatus.sent,
    },
    isReplay: json['rp'] as bool? ?? false,
  );

  final String msgId;
  final String senderId;
  final String senderNickname;

  /// 发送方账号名（服务端回填的账号身份；展示为 @xxx）。
  final String senderUsername;
  final String text;
  final int timestamp;
  final bool mine;
  final ChatSendStatus status;

  /// 是否为服务端离线补投（payload.replay，阶段⑥）；用于「以下是离线消息」分隔线。
  final bool isReplay;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': msgId,
    'sid': senderId,
    'sn': senderNickname,
    'su': senderUsername,
    't': text,
    'ts': timestamp,
    'mine': mine,
    'st': status.name,
    'rp': isReplay,
  };

  ChatMessage withStatus(ChatSendStatus status) => ChatMessage(
    msgId: msgId,
    senderId: senderId,
    senderNickname: senderNickname,
    senderUsername: senderUsername,
    text: text,
    timestamp: timestamp,
    mine: mine,
    status: status,
    isReplay: isReplay,
  );
}

/// 聊天页 UI 状态：会话 → 消息列表（按时间升序），及当前会话。
class ChatUiState {
  const ChatUiState({
    this.conversations = const <String, List<ChatMessage>>{},
    this.activeConversationId = kBroadcastConversation,
    this.unread = const <String, int>{},
    this.error,
    this.replayNotice = 0,
  });

  final Map<String, List<ChatMessage>> conversations;
  final String activeConversationId;

  /// 各会话未读数（消息归属会话 ≠ 当前会话时累计，切会话清零，随会话持久化）。
  final Map<String, int> unread;

  /// 最近一次服务端 error 消息的提示文案（展示后调用 [ChatController.clearError]）。
  final String? error;

  /// 已收到且未提示的离线补投消息条数（app 级 SnackBar 展示后调用
  /// [ChatController.clearReplayNotice]）。
  final int replayNotice;

  List<ChatMessage> messagesOf(String conversationId) =>
      conversations[conversationId] ?? const <ChatMessage>[];

  ChatUiState copyWith({
    Map<String, List<ChatMessage>>? conversations,
    String? activeConversationId,
    Map<String, int>? unread,
    String? error,
    bool clearError = false,
    int? replayNotice,
    bool clearReplayNotice = false,
  }) => ChatUiState(
    conversations: conversations ?? this.conversations,
    activeConversationId: activeConversationId ?? this.activeConversationId,
    unread: unread ?? this.unread,
    error: clearError ? null : (error ?? this.error),
    replayNotice: clearReplayNotice ? 0 : (replayNotice ?? this.replayNotice),
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
  static const String _unreadKey = 'pref.chat.unread';

  StreamSubscription<String>? _ackSub;
  StreamSubscription<MessageEnvelope>? _msgSub;
  StreamSubscription<LanConnState>? _connSub;
  LanWsClient? _boundClient;
  final Set<String> _seenMsgIds = <String>{};
  final Set<String> _loadedConversations = <String>{};

  @override
  ChatUiState build() {
    ref.listen<LanWsClient?>(wsClientProvider, (_, next) => _bind(next));
    _bind(ref.read(wsClientProvider));
    ref.onDispose(_unbind);
    _ensureLoaded(kBroadcastConversation);
    unawaited(_loadUnread());
    return const ChatUiState();
  }

  /// 切换会话（广播或某个用户）；同时清零该会话未读。
  void switchConversation(String conversationId) {
    _ensureLoaded(conversationId);
    state = state.copyWith(activeConversationId: conversationId);
    if ((state.unread[conversationId] ?? 0) > 0) {
      final unread = <String, int>{...state.unread}..remove(conversationId);
      state = state.copyWith(unread: unread);
      _persistUnread(unread);
    }
  }

  /// 清除服务端错误提示（UI 展示后调用）。
  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// 清除离线补投全局提示（app 级 SnackBar 展示后调用）。
  void clearReplayNotice() {
    if (state.replayNotice > 0) {
      state = state.copyWith(clearReplayNotice: true);
    }
  }

  /// 发送消息到当前会话。
  ///
  /// 已连接立即发送；未连接时同样构造 envelope 入待发队列（阶段⑦：消息不再
  /// 丢弃，UI 显示「发送中」，重连后自动补发转「已送达」）。返回是否已受理
  /// ——尚无客户端（未发起过连接）或未登录时返回 false，输入不应被清空。
  bool send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final client = ref.read(wsClientProvider);
    if (client == null) {
      return false;
    }
    final auth = ref.read(authProvider);
    final user = auth.user;
    if (user == null) {
      return false;
    }
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
        senderId: user.id,
        senderNickname: auth.displayName,
        text: trimmed,
        timestamp: now,
        mine: true,
        status: ChatSendStatus.sending,
      ),
    );
    // enqueue 内部按连接状态分流：已连接立即发送，否则留待重连补发。
    client.enqueue(envelope);
    return true;
  }

  /// 重试发送失败的消息：置回「发送中」并按原 msgId 重新入待发队列
  /// （幂等覆盖同 id 的 pending 条目），重连后自动补发。
  void retryMessage(String conversationId, String msgId) {
    final client = ref.read(wsClientProvider);
    if (client == null) {
      return;
    }
    final message = state
        .messagesOf(conversationId)
        .firstWhere(
          (m) => m.msgId == msgId,
          orElse: () => const ChatMessage(
            msgId: '',
            senderId: '',
            senderNickname: '',
            text: '',
            timestamp: 0,
            mine: false,
          ),
        );
    if (message.msgId.isEmpty || message.status != ChatSendStatus.failed) {
      return;
    }
    final target = conversationId == kBroadcastConversation
        ? kBroadcastTarget
        : conversationId;
    client.enqueue(
      MessageEnvelope(
        type: MessageType.chat,
        msgId: message.msgId,
        to: target,
        timestamp: message.timestamp,
        payload: <String, dynamic>{'text': message.text},
      ),
    );
    _replaceMessage(conversationId, message.withStatus(ChatSendStatus.sending));
  }

  void _bind(LanWsClient? client) {
    final previous = _boundClient;
    _unbind();
    _boundClient = client;
    if (client == null) {
      return;
    }
    if (previous != null && !identical(previous, client)) {
      // 客户端实例被替换（重新登录/手动重连）：旧实例待发队列中的消息不再
      // 自动补发，标记为失败等待用户重试。
      _markAllFailed();
    }
    _ackSub = client.acks.listen(_onAck);
    _msgSub = client.messages.listen(_onEnvelope);
    _connSub = client.states.listen(_onConnState);
  }

  void _unbind() {
    _ackSub?.cancel();
    _msgSub?.cancel();
    _connSub?.cancel();
    _ackSub = null;
    _msgSub = null;
    _connSub = null;
  }

  /// 连接放弃（重连上限，disconnected 且带错误）时，把仍在「发送中」的
  /// 消息标记为失败，等待用户点击重试。
  void _onConnState(LanConnState conn) {
    if (conn.phase == LanConnPhase.disconnected && conn.error != null) {
      _markAllFailed();
    }
  }

  void _onAck(String msgId) {
    for (final conversationId in state.conversations.keys.toList(
      growable: false,
    )) {
      final messages = state.messagesOf(conversationId);
      final index = messages.indexWhere(
        (m) => m.msgId == msgId && m.status != ChatSendStatus.sent,
      );
      if (index >= 0) {
        _replaceMessage(
          conversationId,
          messages[index].withStatus(ChatSendStatus.sent),
        );
      }
    }
  }

  void _onEnvelope(MessageEnvelope envelope) {
    switch (envelope.type) {
      case MessageType.chat:
        _onChat(envelope);
      case MessageType.error:
        // 服务端错误（如离线暂存失败、权限类拒绝）：全局提示。
        final code = envelope.payload['code'];
        final message = envelope.payload['message'] as String? ?? '服务端错误';
        state = state.copyWith(error: '$message（$code）');
      case MessageType.roster:
      case MessageType.hello:
      case MessageType.ack:
      case MessageType.ping:
      case MessageType.pong:
      case MessageType.unknown:
        break;
    }
  }

  void _onChat(MessageEnvelope envelope) {
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
    final isReplay = envelope.payload['replay'] == true;
    _append(
      sender.id,
      ChatMessage(
        msgId: msgId,
        senderId: sender.id,
        senderNickname: sender.nickname,
        senderUsername: sender.username,
        text: text,
        timestamp: envelope.timestamp,
        mine: false,
        isReplay: isReplay,
      ),
    );
    // 未读与离线提示：消息归属会话 ≠ 当前会话时累计（阶段⑥）。
    if (sender.id != state.activeConversationId) {
      _bumpUnread(sender.id);
      if (isReplay) {
        state = state.copyWith(replayNotice: state.replayNotice + 1);
      }
    }
    // 确认已收到并持久化：服务端据此删除离线暂存（对非暂存消息是安全空操作）。
    ref.read(wsClientProvider)?.sendAck(msgId);
  }

  void _bumpUnread(String conversationId) {
    final unread = <String, int>{...state.unread};
    unread[conversationId] = (unread[conversationId] ?? 0) + 1;
    state = state.copyWith(unread: unread);
    _persistUnread(unread);
  }

  /// 把仍在「发送中」的消息标记为发送失败（连接放弃/客户端被替换时）。
  void _markAllFailed() {
    for (final conversationId in state.conversations.keys.toList(
      growable: false,
    )) {
      final messages = state.messagesOf(conversationId);
      if (!messages.any((m) => m.status == ChatSendStatus.sending)) {
        continue;
      }
      state = state.copyWith(
        conversations: <String, List<ChatMessage>>{
          for (final entry in state.conversations.entries)
            entry.key: entry.key == conversationId
                ? <ChatMessage>[
                    for (final m in entry.value)
                      m.status == ChatSendStatus.sending
                          ? m.withStatus(ChatSendStatus.failed)
                          : m,
                  ]
                : entry.value,
        },
      );
      _persist(conversationId);
    }
  }

  void _replaceMessage(String conversationId, ChatMessage message) {
    final messages = state.messagesOf(conversationId);
    final index = messages.indexWhere((m) => m.msgId == message.msgId);
    if (index < 0) {
      return;
    }
    final updated = <ChatMessage>[...messages];
    updated[index] = message;
    state = state.copyWith(
      conversations: <String, List<ChatMessage>>{
        for (final entry in state.conversations.entries) entry.key: entry.value,
        conversationId: updated,
      },
    );
    _persist(conversationId);
  }

  Future<void> _loadUnread() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_unreadKey);
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || state.unread.isNotEmpty) {
        return;
      }
      state = state.copyWith(
        unread: <String, int>{
          for (final entry in decoded.entries)
            '${entry.key}': (entry.value as num?)?.toInt() ?? 0,
        },
      );
    } on FormatException {
      // 历史数据损坏时忽略。
    }
  }

  Future<void> _persistUnread(Map<String, int> unread) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_unreadKey, jsonEncode(unread));
    } on JsonUnsupportedObjectError {
      // 序列化失败不应影响 UI。
    }
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
