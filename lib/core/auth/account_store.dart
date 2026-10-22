/// 账号体系数据模型与存储接口（服务端专用，阶段①协议与模型层）。
///
/// 实现类见 `account_store_io.dart`（JSON 文件 MVP 实现）；
/// 阶段②可替换为 SQLite 实现而不影响调用方。
library;

/// 账号操作统一异常：code 与 REST 错误码一一对应。
class AccountException implements Exception {
  const AccountException(this.code, this.message);

  /// INVALID_USERNAME / INVALID_NICKNAME / WEAK_PASSWORD / USERNAME_TAKEN /
  /// BAD_CREDENTIALS / INVALID_TOKEN
  final String code;
  final String message;

  @override
  String toString() => 'AccountException($code, $message)';
}

/// 服务端账号模型（含凭据材料，仅服务端可见，禁止下发客户端）。
class AccountUser {
  const AccountUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.passwordHash,
    required this.salt,
    required this.createdAt,
  });

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id: json['id'] as String? ?? '',
    username: json['username'] as String? ?? '',
    nickname: json['nickname'] as String? ?? '',
    passwordHash: json['passwordHash'] as String? ?? '',
    salt: json['salt'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String username;
  final String nickname;

  /// PBKDF2-HMAC-SHA256 哈希（hex）。
  final String passwordHash;

  /// 16 字节随机盐（hex）。
  final String salt;
  final int createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'username': username,
    'nickname': nickname,
    'passwordHash': passwordHash,
    'salt': salt,
    'createdAt': createdAt,
  };
}

/// 一次登录会话（token 凭证）。
///
/// R4 起存储层只持久化 [token] 的 SHA-256 摘要；[AccountStore.verifyLogin]
/// 的返回值是唯一携带明文 token 的会话对象（下发给客户端，仅此一次）。
class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.deviceId,
    required this.createdAt,
    required this.expiresAt,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    token: json['token'] as String? ?? '',
    userId: json['userId'] as String? ?? '',
    deviceId: json['deviceId'] as String? ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
  );

  final String token;
  final String userId;

  /// 发起登录的设备标识（同一设备重复登录由服务端踢旧会话）。
  final String deviceId;
  final int createdAt;
  final int expiresAt;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'token': token,
    'userId': userId,
    'deviceId': deviceId,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
  };
}

/// 待补投的离线消息（目标用户不在线时暂存，补投确认后删除）。
class OfflineMessage {
  const OfflineMessage({
    required this.msgId,
    required this.fromUser,
    required this.toUser,
    required this.text,
    required this.timestamp,
  });

  factory OfflineMessage.fromJson(Map<String, dynamic> json) => OfflineMessage(
    msgId: json['msgId'] as String? ?? '',
    fromUser: json['fromUser'] as String? ?? '',
    toUser: json['toUser'] as String? ?? '',
    text: json['text'] as String? ?? '',
    timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
  );

  final String msgId;
  final String fromUser;
  final String toUser;
  final String text;
  final int timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'msgId': msgId,
    'fromUser': fromUser,
    'toUser': toUser,
    'text': text,
    'timestamp': timestamp,
  };
}

/// 账号 / 会话 / 离线消息存储接口。
///
/// 实现约定：
/// - 用户名全局唯一；
/// - token 全局唯一，可按过期时间与 userId 校验；
/// - 离线消息按 msgId 幂等（重复入队只保留一条）；
/// - 所有方法以 Future 暴露，便于替换持久化实现。
abstract class AccountStore {
  /// 注册新用户；昵称缺省取用户名。
  ///
  /// 校验失败抛 [AccountException]：
  /// INVALID_USERNAME / WEAK_PASSWORD / USERNAME_TAKEN。
  Future<AccountUser> register({
    required String username,
    required String password,
    String? nickname,
  });

  /// 校验用户名 + 密码，签发会话 token。
  ///
  /// 凭据错误（含用户不存在）统一抛 BAD_CREDENTIALS，避免用户名枚举。
  /// 返回会话的 [AuthSession.token] 为明文 token（仅此一次）；存储层只
  /// 持久化其 SHA-256 摘要，后续校验传入明文 token 由实现摘要比对。
  Future<AuthSession> verifyLogin({
    required String username,
    required String password,
    required String deviceId,
  });

  /// 校验 token：存在、未过期且 userId 匹配时返回会话，否则返回 null
  /// （过期会话被惰性清理）。
  Future<AuthSession?> validateToken({
    required String token,
    required String userId,
  });

  /// 按用户 id 查询账号；不存在返回 null。
  Future<AccountUser?> getUserById({required String userId});

  /// 按 token 查询账号（token 须存在且未过期）；无效返回 null。
  /// 供 REST /api/me 等仅有 token 场景使用。
  Future<AccountUser?> getUserByToken({required String token});

  /// 更新昵称（token 须有效）。返回更新后的账号资料。
  /// 昵称为空或超长抛 INVALID_NICKNAME；token 无效抛 INVALID_TOKEN。
  Future<AccountUser> updateNickname({
    required String token,
    required String nickname,
  });

  /// 修改密码：校验旧密码后写入新哈希与新盐。
  ///
  /// - 旧密码错误抛 BAD_CREDENTIALS；新密码过弱抛 WEAK_PASSWORD；
  ///   token 无效抛 INVALID_TOKEN；
  /// - 成功后吊销该用户除当前 token 外的全部会话（其他设备需重新登录），
  ///   当前 token 保持有效。
  Future<AccountUser> changePassword({
    required String token,
    required String oldPassword,
    required String newPassword,
  });

  /// 暂存一条离线消息（按 msgId 幂等）。
  Future<void> enqueueOffline(OfflineMessage message);

  /// 取出某用户全部待补投消息（按时间升序；不删除，
  /// 由客户端 ack 后经 [confirmOffline] 删除）。
  Future<List<OfflineMessage>> takeOffline({required String userId});

  /// 确认离线消息已落盘到客户端，删除暂存记录。
  ///
  /// 仅当 [msgId] 存在且归属 [userId]（toUser 匹配）时删除，
  /// 防止其他用户伪造 ack 清除他人离线消息。
  Future<void> confirmOffline({required String msgId, required String userId});
}
