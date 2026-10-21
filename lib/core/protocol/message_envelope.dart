import 'dart:convert';

/// 消息协议类型（三端共享，扩展新类型只加枚举与对应 payload 结构）。
enum MessageType {
  hello, // 客户端 → 服务端：首次声明身份 {id, nickname, username?, token?}
  roster, // 服务端 → 全员：在线用户列表 {users: [...]}
  chat, // 客户端 → 服务端 → 目标用户：文本消息 {text}
  ack, // 双向：服务端→发送方确认收到 / 客户端→服务端确认离线补投落盘 {msgId}
  ping, // 客户端 → 服务端：心跳 {t}
  pong, // 服务端 → 客户端：心跳应答 {t}
  error, // 服务端 → 客户端：错误通知 {code, message}，通常随后关闭连接
  unknown, // 兼容：无法识别的类型，不崩溃
}

MessageType messageTypeFromName(String? name) => MessageType.values
    .where((t) => t != MessageType.unknown)
    .firstWhere((t) => t.name == name, orElse: () => MessageType.unknown);

/// 用户身份（协议中的 from 字段与 roster 成员）。
class UserProfile {
  const UserProfile({
    required this.id,
    this.username = '',
    required this.nickname,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String? ?? '',
    username: json['username'] as String? ?? '',
    nickname: json['nickname'] as String? ?? '',
  );

  final String id;

  /// 登录名；匿名/旧协议载荷中缺失时为空串。
  final String username;
  final String nickname;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'username': username,
    'nickname': nickname,
  };

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.id == id &&
      other.username == username &&
      other.nickname == nickname;

  @override
  int get hashCode => Object.hash(id, username, nickname);

  @override
  String toString() => 'UserProfile($id, $username, $nickname)';
}

/// roster 成员列表的 payload 键（v2 起为 users，旧服务端为 devices，解析时兼容）。
const String kRosterUsersKey = 'users';
const String kRosterLegacyDevicesKey = 'devices';

/// 从 roster payload 解析在线成员列表（兼容旧 devices 键）。
List<UserProfile> rosterUsersFromPayload(Map<String, dynamic> payload) {
  final raw = payload[kRosterUsersKey] ?? payload[kRosterLegacyDevicesKey];
  if (raw is! List) {
    return const <UserProfile>[];
  }
  return <UserProfile>[
    for (final item in raw.whereType<Map>())
      UserProfile.fromJson(item.cast<String, dynamic>()),
  ];
}

/// 构建 roster payload（统一 users 键）。
Map<String, dynamic> rosterPayload(List<UserProfile> users) =>
    <String, dynamic>{
      kRosterUsersKey: <Map<String, dynamic>>[
        for (final user in users) user.toJson(),
      ],
    };

/// 广播目标（to 字段）：发给除发送者外的所有设备。
const String kBroadcastTarget = '*';

/// 统一消息信封：三端收发的最小协议单元。
///
/// JSON 形如：
/// ```json
/// {
///   "type": "chat",
///   "msgId": "uuid",
///   "from": {"id": "...", "nickname": "..."},
///   "to": "*" 或目标设备 id,
///   "timestamp": 1710000000000,
///   "payload": {"text": "hello"}
/// }
/// ```
class MessageEnvelope {
  const MessageEnvelope({
    required this.type,
    this.msgId,
    this.from,
    this.to = kBroadcastTarget,
    required this.timestamp,
    this.payload = const <String, dynamic>{},
  });

  factory MessageEnvelope.fromJson(Map<String, dynamic> json) =>
      MessageEnvelope(
        type: messageTypeFromName(json['type'] as String?),
        msgId: json['msgId'] as String?,
        from: (json['from'] as Map<String, dynamic>?)
            ?.cast<String, dynamic>()
            .let(UserProfile.fromJson),
        to: json['to'] as String? ?? kBroadcastTarget,
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        payload:
            (json['payload'] as Map<String, dynamic>?) ??
            const <String, dynamic>{},
      );

  /// 解析 JSON 字符串；非法 JSON 返回 null（由调用方决定是否忽略）。
  static MessageEnvelope? tryParse(String raw) {
    try {
      final decoded = const JsonDecoder().convert(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return MessageEnvelope.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  final MessageType type;
  final String? msgId;
  final UserProfile? from;
  final String to;
  final int timestamp;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type.name,
    if (msgId != null) 'msgId': msgId,
    if (from != null) 'from': from!.toJson(),
    'to': to,
    'timestamp': timestamp,
    'payload': payload,
  };

  String encode() => jsonEncode(toJson());

  MessageEnvelope copyWith({
    MessageType? type,
    String? msgId,
    UserProfile? from,
    String? to,
    int? timestamp,
    Map<String, dynamic>? payload,
  }) => MessageEnvelope(
    type: type ?? this.type,
    msgId: msgId ?? this.msgId,
    from: from ?? this.from,
    to: to ?? this.to,
    timestamp: timestamp ?? this.timestamp,
    payload: payload ?? this.payload,
  );

  @override
  String toString() =>
      'MessageEnvelope(${type.name}, msgId=$msgId, from=$from, to=$to)';
}

extension _Let<T> on T {
  R let<R>(R Function(T value) block) => block(this);
}
