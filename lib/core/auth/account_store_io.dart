import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'account_store.dart';
import 'password_hasher.dart';

/// 基于 JSON 文件的 [AccountStore] 实现（MVP；阶段②可替换 SQLite）。
///
/// - 目录内三个文件：users.json / sessions.json / offline.json；
/// - 惰性加载 + 内存操作 + 原子写盘（先写 .tmp 再 rename）；
/// - 内部串行队列保证并发写安全；
/// - 文件损坏时按空库处理，不影响新写入。
class JsonFileAccountStore implements AccountStore {
  JsonFileAccountStore(
    Directory directory, {
    this.tokenTtl = const Duration(days: 7),
    this.pbkdf2Iterations = PasswordHasher.defaultIterations,
    Random? random,
  }) : _random = random ?? Random.secure(),
       _usersFile = File('${directory.path}/users.json'),
       _sessionsFile = File('${directory.path}/sessions.json'),
       _offlineFile = File('${directory.path}/offline.json');

  final Duration tokenTtl;
  final int pbkdf2Iterations;
  final Random _random;

  final File _usersFile;
  final File _sessionsFile;
  final File _offlineFile;

  final Map<String, AccountUser> _users =
      <String, AccountUser>{}; // 键 = username
  final Map<String, AuthSession> _sessions =
      <String, AuthSession>{}; // 键 = token
  final Map<String, OfflineMessage> _offline =
      <String, OfflineMessage>{}; // 键 = msgId
  bool _loaded = false;

  /// 串行化全部读改写，避免并发请求交错破坏一致性。
  Future<void> _lock = Future<void>.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<AccountUser> register({
    required String username,
    required String password,
    String? nickname,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final name = username.trim();
    _validateUsername(name);
    if (password.length < 8) {
      throw const AccountException('WEAK_PASSWORD', '密码至少需要 8 位');
    }
    if (_users.containsKey(name)) {
      throw const AccountException('USERNAME_TAKEN', '用户名已被占用');
    }
    final trimmedNickname = nickname?.trim() ?? '';
    final salt = PasswordHasher.newSalt(_random);
    final user = AccountUser(
      id: const Uuid().v4(),
      username: name,
      nickname: trimmedNickname.isEmpty ? name : trimmedNickname,
      passwordHash: PasswordHasher.hash(
        password,
        salt,
        iterations: pbkdf2Iterations,
      ),
      salt: salt,
      createdAt: _now(),
    );
    _users[name] = user;
    await _persist(_usersFile, _users.values);
    return user;
  });

  @override
  Future<AuthSession> verifyLogin({
    required String username,
    required String password,
    required String deviceId,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final user = _users[username.trim()];
    // 用户不存在与密码错误统一报错，避免用户名枚举。
    if (user == null ||
        !PasswordHasher.verify(
          password,
          user.salt,
          user.passwordHash,
          iterations: pbkdf2Iterations,
        )) {
      throw const AccountException('BAD_CREDENTIALS', '用户名或密码错误');
    }
    _sessions.removeWhere(
      (token, session) => session.userId == user.id && session.isExpired,
    );
    // 同设备重新登录：使该设备旧会话失效（旧 token 无法再通过校验）。
    if (deviceId.isNotEmpty) {
      _sessions.removeWhere(
        (token, session) =>
            session.userId == user.id && session.deviceId == deviceId,
      );
    }
    final now = _now();
    final session = AuthSession(
      token: _newToken(),
      userId: user.id,
      deviceId: deviceId,
      createdAt: now,
      expiresAt: now + tokenTtl.inMilliseconds,
    );
    _sessions[session.token] = session;
    await _persist(_sessionsFile, _sessions.values);
    return session;
  });

  @override
  Future<AuthSession?> validateToken({
    required String token,
    required String userId,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final session = _sessions[token];
    if (session == null) {
      return null;
    }
    if (session.isExpired) {
      _sessions.remove(token);
      await _persist(_sessionsFile, _sessions.values);
      return null;
    }
    if (session.userId != userId) {
      return null;
    }
    return session;
  });

  @override
  Future<AccountUser?> getUserById({required String userId}) =>
      _synchronized(() async {
        await _ensureLoaded();
        return _userById(userId);
      });

  @override
  Future<AccountUser?> getUserByToken({required String token}) =>
      _synchronized(() async {
        await _ensureLoaded();
        final session = _sessions[token];
        if (session == null) {
          return null;
        }
        if (session.isExpired) {
          _sessions.remove(token);
          await _persist(_sessionsFile, _sessions.values);
          return null;
        }
        return _userById(session.userId);
      });

  AccountUser? _userById(String userId) {
    for (final user in _users.values) {
      if (user.id == userId) {
        return user;
      }
    }
    return null;
  }

  /// 按 token 取有效会话（过期视为无效；过期清理交给按需路径处理）。
  AuthSession? _sessionByToken(String token) {
    final session = _sessions[token];
    if (session == null || session.isExpired) {
      return null;
    }
    return session;
  }

  @override
  Future<AccountUser> updateNickname({
    required String token,
    required String nickname,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final session = _sessionByToken(token);
    final user = session == null ? null : _userById(session.userId);
    if (user == null) {
      throw const AccountException('INVALID_TOKEN', '凭证无效或已过期');
    }
    final name = nickname.trim();
    if (name.isEmpty || name.length > 24) {
      throw const AccountException('INVALID_NICKNAME', '昵称须为 1-24 个字符');
    }
    final updated = AccountUser(
      id: user.id,
      username: user.username,
      nickname: name,
      passwordHash: user.passwordHash,
      salt: user.salt,
      createdAt: user.createdAt,
    );
    _users[user.username] = updated;
    await _persist(_usersFile, _users.values);
    return updated;
  });

  @override
  Future<AccountUser> changePassword({
    required String token,
    required String oldPassword,
    required String newPassword,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final session = _sessionByToken(token);
    final user = session == null ? null : _userById(session.userId);
    if (user == null) {
      throw const AccountException('INVALID_TOKEN', '凭证无效或已过期');
    }
    if (!PasswordHasher.verify(
      oldPassword,
      user.salt,
      user.passwordHash,
      iterations: pbkdf2Iterations,
    )) {
      throw const AccountException('BAD_CREDENTIALS', '旧密码错误');
    }
    if (newPassword.length < 8) {
      throw const AccountException('WEAK_PASSWORD', '密码至少需要 8 位');
    }
    final salt = PasswordHasher.newSalt(_random);
    final updated = AccountUser(
      id: user.id,
      username: user.username,
      nickname: user.nickname,
      passwordHash: PasswordHasher.hash(
        newPassword,
        salt,
        iterations: pbkdf2Iterations,
      ),
      salt: salt,
      createdAt: user.createdAt,
    );
    _users[user.username] = updated;
    // 吊销该用户其他设备的会话，当前 token 保持有效（改密后其他设备需重登）。
    _sessions.removeWhere((t, s) => s.userId == user.id && t != token);
    await _persist(_usersFile, _users.values);
    await _persist(_sessionsFile, _sessions.values);
    return updated;
  });

  @override
  Future<void> enqueueOffline(OfflineMessage message) =>
      _synchronized(() async {
        await _ensureLoaded();
        _offline[message.msgId] = message; // 按 msgId 幂等
        await _persist(_offlineFile, _offline.values);
      });

  @override
  Future<List<OfflineMessage>> takeOffline({required String userId}) =>
      _synchronized(() async {
        await _ensureLoaded();
        final messages =
            _offline.values
                .where((m) => m.toUser == userId)
                .toList(growable: false)
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return List<OfflineMessage>.of(messages);
      });

  @override
  Future<void> confirmOffline({
    required String msgId,
    required String userId,
  }) => _synchronized(() async {
    await _ensureLoaded();
    final message = _offline[msgId];
    // 仅允许收件人本人确认，防止伪造 ack 清除他人离线消息。
    if (message == null || message.toUser != userId) {
      return;
    }
    _offline.remove(msgId);
    await _persist(_offlineFile, _offline.values);
  });

  void _validateUsername(String name) {
    final valid = RegExp(r'^[a-zA-Z0-9_]{3,24}$').hasMatch(name);
    if (!valid) {
      throw const AccountException('INVALID_USERNAME', '用户名须为 3-24 位字母、数字或下划线');
    }
  }

  String _newToken() =>
      _bytesToHex(<int>[for (var i = 0; i < 32; i++) _random.nextInt(256)]);

  Future<void> _ensureLoaded() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    _users.addAll(_loadMap<AccountUser>(_usersFile, AccountUser.fromJson));
    _sessions.addAll(
      _loadMap<AuthSession>(_sessionsFile, AuthSession.fromJson),
    );
    _offline.addAll(
      _loadMap<OfflineMessage>(_offlineFile, OfflineMessage.fromJson),
    );
  }

  /// 读取 JSON 列表文件为 Map（按各自主键）；文件缺失或损坏时返回空。
  static Map<String, T> _loadMap<T>(
    File file,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    try {
      if (!file.existsSync()) {
        return <String, T>{};
      }
      final raw = file.readAsStringSync();
      if (raw.isEmpty) {
        return <String, T>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <String, T>{};
      }
      final result = <String, T>{};
      for (final item in decoded.whereType<Map>()) {
        final value = fromJson(item.cast<String, dynamic>());
        final key = switch (value) {
          AccountUser() => value.username,
          AuthSession() => value.token,
          OfflineMessage() => value.msgId,
          _ => null,
        };
        if (key != null && key.isNotEmpty) {
          result[key] = value;
        }
      }
      return result;
    } on FormatException {
      return <String, T>{};
    } on FileSystemException {
      return <String, T>{};
    }
  }

  /// 原子写盘：先写 .tmp 再 rename 覆盖，避免写一半崩溃损坏数据。
  Future<void> _persist(File file, Iterable<Object?> values) async {
    final json = jsonEncode(<Object?>[for (final v in values) _toJsonOf(v)]);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
  }

  static Object? _toJsonOf(Object? value) => switch (value) {
    AccountUser() => value.toJson(),
    AuthSession() => value.toJson(),
    OfflineMessage() => value.toJson(),
    _ => value,
  };

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}

/// 便捷构造：默认使用 JSON 文件账号库（目录不存在时自动创建）。
///
/// 供桌面端启动使用；阶段② MVP 存储。
Future<AccountStore> createDefaultAccountStore() async {
  final base =
      Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      Directory.systemTemp.path;
  final dir = Directory('$base/LanMessenger/accounts');
  await dir.create(recursive: true);
  return JsonFileAccountStore(dir);
}
