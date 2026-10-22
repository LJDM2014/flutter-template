import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/account_store.dart';
import '../constants.dart';
import '../protocol/message_envelope.dart';
import 'relay_status.dart';

export 'relay_status.dart';

/// 单个已鉴权的客户端会话（以 token 为键，一个账号可多设备同时在线）。
class _Session {
  _Session({
    required this.token,
    required this.profile,
    required this.deviceId,
    required this.channel,
  });

  final String token;
  final UserProfile profile;

  /// 发起该会话的设备标识（登录时提供；同一设备重登会踢旧会话）。
  final String deviceId;
  final WebSocketChannel channel;
}

/// 桌面端内置中继服务（仅 Windows 启动）：REST 账号接口 + 鉴权 WebSocket 中继。
///
/// - REST：POST /api/register、POST /api/login、GET /api/me、
///   POST /api/nickname、POST /api/password（Bearer token）；
/// - WS（/ws）：hello 携带 {id: userId, deviceId, token}，服务端校验通过后
///   注册会话并广播 roster；校验失败回 error 并关闭连接；
/// - chat 消息：先 ack 发送方，再按 to 路由——广播（跳过发送方全部会话）或
///   定向转发给目标用户的全部在线会话；目标不在线时暂存离线消息；
/// - 离线补投：hello 成功后按时间升序补投暂存消息，收到该用户 ack 后删除；
/// - ping → pong 心跳应答；断开连接自动从 roster 移除并广播。
class HostServer {
  HostServer._();

  static final HostServer instance = HostServer._();

  final Map<String, _Session> _sessions = <String, _Session>{}; // 键 = token
  final List<WebSocketChannel> _pending = <WebSocketChannel>[];

  /// 鉴权未完成期间收到的 chat 消息缓冲（键 = 连接）。
  ///
  /// 重连补发时客户端在 hello 后立即 flush 待发队列，而 hello 的会话注册
  /// 是异步的；若不缓冲，这些消息会因「找不到会话」被静默丢弃。
  final Map<WebSocketChannel, List<MessageEnvelope>> _preAuthBuffer =
      <WebSocketChannel, List<MessageEnvelope>>{};
  AccountStore? _accounts;
  bool _allowRegistration = true;

  /// 登录限速（阶段⑧）：按「IP + 用户名」内存计数，60 秒窗口内失败
  /// 达 [_maxLoginFailuresPerMinute] 次即临时封禁，成功登录清零。
  static const int _maxLoginFailuresPerMinute = 5;
  static const int _loginWindowMs = 60 * 1000;
  final Map<String, List<int>> _loginFailures = <String, List<int>>{};
  HttpServer? _http;

  /// 非 null 时以 TLS（wss/https）监听（阶段 R1）。
  SecurityContext? _securityContext;

  bool get isRunning => _http != null;
  int? get port => _http?.port;

  /// 启动中继服务。
  ///
  /// 传入 [securityContext] 时以 TLS（HTTPS/WSS）监听，否则明文（HTTP/WS）。
  Future<RelayStatus> start({
    int port = AppConstants.defaultPort,
    required AccountStore accountStore,
    bool allowRegistration = true,
    SecurityContext? securityContext,
  }) async {
    if (isRunning) {
      return RelayStatus.running(_http!.port, secure: _securityContext != null);
    }
    _accounts = accountStore;
    _allowRegistration = allowRegistration;
    _securityContext = securityContext;
    try {
      final server = await shelf_io.serve(
        _handler,
        InternetAddress.anyIPv4,
        port,
        securityContext: securityContext,
      );
      _http = server;
      return RelayStatus.running(server.port, secure: securityContext != null);
    } catch (error) {
      return RelayStatus.failure('中继服务启动失败（端口可能被占用）：$error');
    }
  }

  Future<void> stop() async {
    final server = _http;
    _http = null;
    // 关闭连接会同步触发 onDone 回调并修改注册表，必须遍历副本。
    for (final channel in List<WebSocketChannel>.of(_pending)) {
      await _closeQuietly(channel);
    }
    _pending.clear();
    _preAuthBuffer.clear();
    for (final session in List<_Session>.of(_sessions.values)) {
      await _closeQuietly(session.channel);
    }
    _sessions.clear();
    await server?.close(force: true);
  }

  /// 强制断开指定用户（或设备）的全部会话（模拟网络中断，用于测试自动重连）。
  Future<void> dropClient(String userId) async {
    final stale = _sessions.values
        .where((s) => s.profile.id == userId || s.deviceId == userId)
        .toList(growable: false);
    if (stale.isEmpty) {
      return;
    }
    for (final session in stale) {
      _sessions.remove(session.token);
      await _closeQuietly(session.channel);
    }
    _broadcastRoster();
  }

  Handler get _handler =>
      const Pipeline().addMiddleware(_cors).addHandler(_route);

  /// CORS 中间件：浏览器端 Web 客户端与桌面端中继跨域（不同 origin），
  /// REST 的 JSON POST 会先发 OPTIONS 预检；无 CORS 头时浏览器直接拦截。
  /// WebSocket 握手不受 CORS 约束，此处统一放行即可。
  static const Map<String, String> _corsHeaders = <String, String>{
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  };

  /// CORS 中间件（shelf 的 Middleware = Handler Function(Handler)）。
  static Handler _cors(Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final response = await innerHandler(request);
      return response.change(headers: _corsHeaders);
    };
  }

  FutureOr<Response> _route(Request request) {
    switch (request.url.path) {
      case 'ws':
        return webSocketHandler(_onConnection)(request);
      case 'api/register':
        return _handleRegister(request);
      case 'api/login':
        return _handleLogin(request);
      case 'api/me':
        return _handleMe(request);
      case 'api/nickname':
        return _handleNickname(request);
      case 'api/password':
        return _handlePassword(request);
      default:
        return Response.notFound('only /ws and /api/* are supported');
    }
  }

  // ---------------------------------------------------------------------------
  // REST：注册 / 登录 / 当前用户
  // ---------------------------------------------------------------------------

  Future<Response> _handleRegister(Request request) async {
    final accounts = _accounts;
    if (accounts == null) {
      return _jsonError(503, 'UNAVAILABLE', '账号服务未就绪');
    }
    if (!_allowRegistration) {
      return _jsonError(403, 'REGISTRATION_DISABLED', '本服务器已关闭注册');
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      return _jsonError(400, 'BAD_REQUEST', '请求体必须是 JSON 对象');
    }
    final username = body['username'];
    final password = body['password'];
    if (username is! String || password is! String) {
      return _jsonError(400, 'BAD_REQUEST', 'username 与 password 为必填字符串');
    }
    try {
      final user = await accounts.register(
        username: username,
        password: password,
        nickname: body['nickname'] is String
            ? body['nickname'] as String
            : null,
      );
      // 注册即登录：直接签发会话。
      final session = await accounts.verifyLogin(
        username: username.trim(),
        password: password,
        deviceId: body['deviceId'] is String ? body['deviceId'] as String : '',
      );
      return _json(<String, dynamic>{
        'token': session.token,
        'expiresAt': session.expiresAt,
        'user': _publicUser(user),
      });
    } on AccountException catch (error) {
      return _jsonError(_statusCodeFor(error.code), error.code, error.message);
    }
  }

  Future<Response> _handleLogin(Request request) async {
    final accounts = _accounts;
    if (accounts == null) {
      return _jsonError(503, 'UNAVAILABLE', '账号服务未就绪');
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      return _jsonError(400, 'BAD_REQUEST', '请求体必须是 JSON 对象');
    }
    final username = body['username'];
    final password = body['password'];
    if (username is! String || password is! String) {
      return _jsonError(400, 'BAD_REQUEST', 'username 与 password 为必填字符串');
    }
    // 登录限速：按「IP + 用户名」统计失败次数，超限直接拒绝（阶段⑧）。
    final rateKey = _loginRateKey(request, username);
    if (rateKey != null && _isLoginRateLimited(rateKey)) {
      return _jsonError(429, 'TOO_MANY_ATTEMPTS', '尝试过于频繁，请一分钟后再试');
    }
    try {
      final session = await accounts.verifyLogin(
        username: username,
        password: password,
        deviceId: body['deviceId'] is String ? body['deviceId'] as String : '',
      );
      if (rateKey != null) {
        _loginFailures.remove(rateKey);
      }
      final user = await accounts.getUserById(userId: session.userId);
      if (user == null) {
        return _jsonError(401, 'BAD_CREDENTIALS', '用户名或密码错误');
      }
      return _json(<String, dynamic>{
        'token': session.token,
        'expiresAt': session.expiresAt,
        'user': _publicUser(user),
      });
    } on AccountException catch (error) {
      if (error.code == 'BAD_CREDENTIALS' && rateKey != null) {
        _recordLoginFailure(rateKey);
      }
      return _jsonError(_statusCodeFor(error.code), error.code, error.message);
    }
  }

  /// 限速键：仅取得到客户端 IP 时启用；否则返回 null（不限速，与现状一致）。
  String? _loginRateKey(Request request, String username) {
    final info = request.context['shelf.io.connection_info'];
    if (info is! HttpConnectionInfo) {
      return null;
    }
    return '${info.remoteAddress.address}|${username.trim()}';
  }

  /// 窗口内失败次数达到上限即临时封禁（惰性清理过期记录）。
  bool _isLoginRateLimited(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final failures =
        _loginFailures[key]?.where((t) => now - t < _loginWindowMs).toList()
          ?..sort();
    if (failures == null || failures.isEmpty) {
      _loginFailures.remove(key);
      return false;
    }
    _loginFailures[key] = failures;
    return failures.length >= _maxLoginFailuresPerMinute;
  }

  void _recordLoginFailure(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final failures = <int>[];
    final previous = _loginFailures[key];
    if (previous != null) {
      failures.addAll(previous.where((t) => now - t < _loginWindowMs));
    }
    failures.add(now);
    failures.sort();
    _loginFailures[key] = failures;
  }

  Future<Response> _handleMe(Request request) async {
    final accounts = _accounts;
    if (accounts == null) {
      return _jsonError(503, 'UNAVAILABLE', '账号服务未就绪');
    }
    final token = _bearerToken(request);
    if (token.isEmpty) {
      return _jsonError(401, 'INVALID_TOKEN', '缺少 Bearer 凭证');
    }
    final user = await accounts.getUserByToken(token: token);
    if (user == null) {
      return _jsonError(401, 'INVALID_TOKEN', '凭证无效或已过期');
    }
    return _json(<String, dynamic>{'user': _publicUser(user)});
  }

  /// 修改昵称（阶段⑧）：更新账号资料，刷新该用户全部在线 WS 会话资料
  /// 并广播 roster，其他端立即可见。
  Future<Response> _handleNickname(Request request) async {
    final accounts = _accounts;
    if (accounts == null) {
      return _jsonError(503, 'UNAVAILABLE', '账号服务未就绪');
    }
    final token = _bearerToken(request);
    if (token.isEmpty) {
      return _jsonError(401, 'INVALID_TOKEN', '缺少 Bearer 凭证');
    }
    final body = await _readJsonBody(request);
    final nickname = body?['nickname'];
    if (nickname is! String) {
      return _jsonError(400, 'BAD_REQUEST', 'nickname 为必填字符串');
    }
    try {
      final user = await accounts.updateNickname(
        token: token,
        nickname: nickname,
      );
      _refreshSessionProfiles(user);
      return _json(<String, dynamic>{'user': _publicUser(user)});
    } on AccountException catch (error) {
      return _jsonError(_statusCodeFor(error.code), error.code, error.message);
    }
  }

  /// 修改密码（阶段⑧）：旧密码校验 + 新哈希落盘；该用户其他设备会话被
  /// 吊销（需重新登录），当前 token 保持有效。
  Future<Response> _handlePassword(Request request) async {
    final accounts = _accounts;
    if (accounts == null) {
      return _jsonError(503, 'UNAVAILABLE', '账号服务未就绪');
    }
    final token = _bearerToken(request);
    if (token.isEmpty) {
      return _jsonError(401, 'INVALID_TOKEN', '缺少 Bearer 凭证');
    }
    final body = await _readJsonBody(request);
    final oldPassword = body?['oldPassword'];
    final newPassword = body?['newPassword'];
    if (oldPassword is! String || newPassword is! String) {
      return _jsonError(400, 'BAD_REQUEST', 'oldPassword 与 newPassword 为必填字符串');
    }
    try {
      final user = await accounts.changePassword(
        token: token,
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      return _json(<String, dynamic>{'user': _publicUser(user)});
    } on AccountException catch (error) {
      return _jsonError(_statusCodeFor(error.code), error.code, error.message);
    }
  }

  String _bearerToken(Request request) {
    final auth = request.headers['authorization'] ?? '';
    return auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
  }

  /// 用最新账号资料替换该用户全部在线会话的 profile，并广播 roster。
  void _refreshSessionProfiles(AccountUser user) {
    final profile = UserProfile(
      id: user.id,
      username: user.username,
      nickname: user.nickname,
    );
    var touched = false;
    for (final entry in _sessions.entries) {
      if (entry.value.profile.id != user.id) {
        continue;
      }
      final session = entry.value;
      _sessions[entry.key] = _Session(
        token: session.token,
        profile: profile,
        deviceId: session.deviceId,
        channel: session.channel,
      );
      touched = true;
    }
    if (touched) {
      _broadcastRoster();
    }
  }

  Map<String, dynamic> _publicUser(AccountUser user) => <String, dynamic>{
    'id': user.id,
    'username': user.username,
    'nickname': user.nickname,
  };

  int _statusCodeFor(String code) => switch (code) {
    'USERNAME_TAKEN' => 409,
    'BAD_CREDENTIALS' || 'INVALID_TOKEN' => 401,
    'TOO_MANY_ATTEMPTS' => 429,
    _ => 400,
  };

  Future<Map<String, dynamic>?> _readJsonBody(Request request) async {
    try {
      final raw = await request.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  Response _json(Map<String, dynamic> body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  Response _jsonError(int status, String code, String message) =>
      _json(<String, dynamic>{
        'error': <String, dynamic>{'code': code, 'message': message},
      }, status: status);

  // ---------------------------------------------------------------------------
  // WebSocket：接入鉴权与消息中继
  // ---------------------------------------------------------------------------

  void _onConnection(WebSocketChannel channel, String? protocol) {
    _pending.add(channel);
    channel.stream.listen(
      (dynamic data) => _onData(channel, data),
      onDone: () => _onClosed(channel),
      onError: (Object _) => _onClosed(channel),
      cancelOnError: true,
    );
  }

  void _onData(WebSocketChannel channel, dynamic raw) {
    if (raw is! String) {
      return;
    }
    final envelope = MessageEnvelope.tryParse(raw);
    if (envelope == null) {
      return;
    }
    switch (envelope.type) {
      case MessageType.hello:
        unawaited(_register(channel, envelope));
      case MessageType.chat:
        if (_pending.contains(channel)) {
          // 会话尚未注册完成：暂存，待鉴权通过后按序转发。
          _preAuthBuffer
              .putIfAbsent(channel, () => <MessageEnvelope>[])
              .add(envelope);
        } else {
          _forwardChat(channel, envelope);
        }
      case MessageType.ping:
        _send(channel, envelope.copyWith(type: MessageType.pong));
      case MessageType.ack:
        _confirmOffline(channel, envelope);
      case MessageType.roster:
      case MessageType.pong:
      case MessageType.error:
      case MessageType.unknown:
        break;
    }
  }

  /// hello 鉴权：校验 token 与 userId 匹配，成功后注册会话、
  /// 踢同设备旧会话、广播 roster 并补投离线消息。
  Future<void> _register(
    WebSocketChannel channel,
    MessageEnvelope envelope,
  ) async {
    final accounts = _accounts;
    final token = envelope.payload['token'];
    final id = envelope.payload['id'];
    if (accounts == null) {
      await _reject(channel, 'INVALID_TOKEN', '账号服务未就绪');
      return;
    }
    if (token is! String || id is! String || token.isEmpty || id.isEmpty) {
      await _reject(channel, 'INVALID_TOKEN', '缺少登录凭证，请先登录');
      return;
    }
    final session = await accounts.validateToken(token: token, userId: id);
    if (session == null) {
      await _reject(channel, 'INVALID_TOKEN', '登录已失效，请重新登录');
      return;
    }
    final user = await accounts.getUserById(userId: id);
    if (user == null) {
      await _reject(channel, 'INVALID_TOKEN', '账号不存在');
      return;
    }
    // 等待鉴权期间连接可能已断开。
    if (!_pending.remove(channel)) {
      return;
    }
    // 踢旧会话：同 token 重连保留新连接；同设备重登踢旧 token。
    final stale = _sessions.values
        .where(
          (s) =>
              !identical(s.channel, channel) &&
              (s.token == token ||
                  (s.deviceId.isNotEmpty && s.deviceId == session.deviceId)),
        )
        .toList(growable: false);
    for (final old in stale) {
      _sessions.remove(old.token);
      await _closeQuietly(old.channel);
    }
    _sessions[token] = _Session(
      token: token,
      profile: UserProfile(
        id: user.id,
        username: user.username,
        nickname: user.nickname,
      ),
      deviceId: session.deviceId,
      channel: channel,
    );
    _broadcastRoster();
    await _replayOffline(user.id, channel);
    // 离线补投（更早的消息）完成后，再转发鉴权期间排队的本端消息。
    final buffered = _preAuthBuffer.remove(channel);
    if (buffered != null) {
      for (final envelope in buffered) {
        _forwardChat(channel, envelope);
      }
    }
  }

  /// 补投该用户的离线消息（按时间升序，msgId 保持不变以便客户端去重）。
  Future<void> _replayOffline(String userId, WebSocketChannel channel) async {
    final accounts = _accounts;
    if (accounts == null) {
      return;
    }
    final messages = await accounts.takeOffline(userId: userId);
    for (final message in messages) {
      final sender = await accounts.getUserById(userId: message.fromUser);
      _send(
        channel,
        MessageEnvelope(
          type: MessageType.chat,
          msgId: message.msgId,
          from: sender == null
              ? UserProfile(id: message.fromUser, nickname: '')
              : UserProfile(
                  id: sender.id,
                  username: sender.username,
                  nickname: sender.nickname,
                ),
          to: message.toUser,
          timestamp: message.timestamp,
          // replay 标记：客户端据此区分实时消息与离线补投（未读提示/分隔线）。
          payload: <String, dynamic>{'text': message.text, 'replay': true},
        ),
      );
    }
  }

  /// 客户端 ack：确认离线补投消息已落盘，服务端删除暂存记录。
  void _confirmOffline(WebSocketChannel channel, MessageEnvelope envelope) {
    final accounts = _accounts;
    final msgId = envelope.msgId;
    final session = _findByChannel(channel);
    if (accounts == null || msgId == null || session == null) {
      return;
    }
    unawaited(
      accounts.confirmOffline(msgId: msgId, userId: session.profile.id),
    );
  }

  void _forwardChat(WebSocketChannel channel, MessageEnvelope envelope) {
    final session = _findByChannel(channel);
    if (session == null) {
      return; // 未鉴权的连接不允许发言
    }
    final accounts = _accounts;
    if (accounts == null) {
      return;
    }
    final msgId = envelope.msgId;
    if (msgId != null) {
      _send(
        channel,
        MessageEnvelope(type: MessageType.ack, msgId: msgId, timestamp: _now()),
      );
    }
    // from 由服务端覆盖为账号资料，客户端不可伪造身份。
    final forwarded = envelope.copyWith(
      from: session.profile,
      timestamp: _now(),
    );
    final target = envelope.to;
    if (target == kBroadcastTarget) {
      for (final other in _sessions.values) {
        if (other.profile.id != session.profile.id) {
          _send(other.channel, forwarded);
        }
      }
      return;
    }
    // 定向：投递给目标用户的全部在线会话（多设备）。
    final destinations = _sessions.values
        .where((s) => s.profile.id == target)
        .toList(growable: false);
    if (destinations.isNotEmpty) {
      for (final destination in destinations) {
        _send(destination.channel, forwarded);
      }
      return;
    }
    // 目标不在线：暂存离线消息，待其上线补投（仍先 ack 发送方）。
    final text = envelope.payload['text'];
    if (text is String && text.isNotEmpty) {
      unawaited(
        accounts.enqueueOffline(
          OfflineMessage(
            msgId: msgId ?? const Uuid().v4(),
            fromUser: session.profile.id,
            toUser: target,
            text: text,
            timestamp: _now(),
          ),
        ),
      );
    }
  }

  /// 鉴权失败：回 error 后主动关闭连接（客户端应停止重连并转登录）。
  Future<void> _reject(
    WebSocketChannel channel,
    String code,
    String message,
  ) async {
    _pending.remove(channel);
    _preAuthBuffer.remove(channel);
    _send(
      channel,
      MessageEnvelope(
        type: MessageType.error,
        timestamp: _now(),
        payload: <String, dynamic>{'code': code, 'message': message},
      ),
    );
    await _closeQuietly(channel);
  }

  _Session? _findByChannel(WebSocketChannel channel) {
    for (final session in _sessions.values) {
      if (identical(session.channel, channel)) {
        return session;
      }
    }
    return null;
  }

  Future<void> _onClosed(WebSocketChannel channel) async {
    _pending.remove(channel);
    _preAuthBuffer.remove(channel);
    final removed = _sessions.values
        .where((s) => identical(s.channel, channel))
        .toList(growable: false);
    for (final session in removed) {
      _sessions.remove(session.token);
    }
    if (removed.isNotEmpty) {
      _broadcastRoster();
    }
  }

  void _broadcastRoster() {
    // 同一用户多会话时 roster 只列一次。
    final users = <String, UserProfile>{};
    for (final session in _sessions.values) {
      users[session.profile.id] = session.profile;
    }
    final roster = MessageEnvelope(
      type: MessageType.roster,
      timestamp: _now(),
      payload: rosterPayload(users.values.toList(growable: false)),
    );
    for (final session in _sessions.values) {
      _send(session.channel, roster);
    }
  }

  void _send(WebSocketChannel channel, MessageEnvelope envelope) {
    try {
      channel.sink.add(envelope.encode());
    } catch (_) {
      // 发送失败：连接层会触发 onDone/onError，走统一的清理与 roster 广播。
    }
  }

  Future<void> _closeQuietly(WebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } catch (_) {}
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;
}
