import 'dart:convert';

/// 消息协议类型（三端共享，扩展新类型只加枚举与对应 payload 结构）。
enum MessageType {
  hello, // 客户端 → 服务端：首次声明身份 {id, nickname}
  roster, // 服务端 → 全员：在线设备列表 {devices: [...]}
  chat, // 客户端 → 服务端 → 目标设备：文本消息 {text}
  ack, // 服务端 → 发送方：确认收到 {msgId}
  ping, // 客户端 → 服务端：心跳 {t}
  pong, // 服务端 → 客户端：心跳应答 {t}
  unknown, // 兼容：无法识别的类型，不崩溃
}

MessageType messageTypeFromName(String? name) => MessageType.values
    .where((t) => t != MessageType.unknown)
    .firstWhere((t) => t.name == name, orElse: () => MessageType.unknown);

/// 设备身份（协议中的 from 字段与 roster 成员）。
class DeviceProfile {
  const DeviceProfile({required this.id, required this.nickname});

  factory DeviceProfile.fromJson(Map<String, dynamic> json) => DeviceProfile(
    id: json['id'] as String? ?? '',
    nickname: json['nickname'] as String? ?? '',
  );

  final String id;
  final String nickname;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'nickname': nickname,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile && other.id == id && other.nickname == nickname;

  @override
  int get hashCode => Object.hash(id, nickname);

  @override
  String toString() => 'DeviceProfile($id, $nickname)';
}

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
            .let(DeviceProfile.fromJson),
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
  final DeviceProfile? from;
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
    DeviceProfile? from,
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
