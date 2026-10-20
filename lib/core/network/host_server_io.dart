import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants.dart';
import '../protocol/message_envelope.dart';
import 'relay_status.dart';

export 'relay_status.dart';

/// 单个已注册客户端会话。
class _Session {
  _Session({required this.profile, required this.channel});

  final DeviceProfile profile;
  final WebSocketChannel channel;
}

/// 桌面端内置 WebSocket 中继服务（仅 Windows 启动）。
///
/// - 多客户端接入（路径 /ws）；
/// - hello 注册身份后向全员广播 roster；
/// - chat 消息：先 ack 发送方，再广播（跳过发送方）或定向转发给 to 指定设备；
/// - ping → pong 心跳应答；
/// - 断开连接自动从 roster 移除并广播。
class HostServer {
  HostServer._();

  static final HostServer instance = HostServer._();

  final Map<String, _Session> _sessions = <String, _Session>{};
  final List<WebSocketChannel> _pending = <WebSocketChannel>[];
  HttpServer? _http;

  bool get isRunning => _http != null;
  int? get port => _http?.port;

  Future<RelayStatus> start({int port = AppConstants.defaultPort}) async {
    if (isRunning) {
      return RelayStatus.running(_http!.port);
    }
    try {
      final server = await shelf_io.serve(
        _handler,
        InternetAddress.anyIPv4,
        port,
      );
      _http = server;
      return RelayStatus.running(server.port);
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
    for (final session in List<_Session>.of(_sessions.values)) {
      await _closeQuietly(session.channel);
    }
    _sessions.clear();
    await server?.close(force: true);
  }

  /// 强制断开指定设备的连接（模拟网络中断，用于测试自动重连）。
  Future<void> dropClient(String deviceId) async {
    final session = _sessions[deviceId];
    if (session != null) {
      _sessions.remove(deviceId);
      await _closeQuietly(session.channel);
      _broadcastRoster();
    }
  }

  Handler get _handler => const Pipeline().addHandler(_route);

  FutureOr<Response> _route(Request request) {
    if (request.url.path == 'ws') {
      return webSocketHandler(_onConnection)(request);
    }
    return Response.notFound('only /ws is supported');
  }

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
        _register(channel, envelope);
      case MessageType.chat:
        _forwardChat(channel, envelope);
      case MessageType.ping:
        _send(channel, envelope.copyWith(type: MessageType.pong));
      case MessageType.roster:
      case MessageType.ack:
      case MessageType.pong:
      case MessageType.unknown:
        break;
    }
  }

  void _register(WebSocketChannel channel, MessageEnvelope envelope) {
    final id = envelope.payload['id'] as String?;
    final nickname = envelope.payload['nickname'] as String? ?? '';
    if (id == null || id.isEmpty) {
      _send(
        channel,
        MessageEnvelope(
          type: MessageType.roster,
          timestamp: _now(),
          payload: <String, dynamic>{'devices': <Object>[]},
        ),
      );
      return;
    }
    _pending.remove(channel);
    // 同一设备重连：踢掉旧连接，保留最新会话。
    final old = _sessions[id];
    if (old != null && !identical(old.channel, channel)) {
      _closeQuietly(old.channel);
    }
    _sessions[id] = _Session(
      profile: DeviceProfile(id: id, nickname: nickname),
      channel: channel,
    );
    _broadcastRoster();
  }

  void _forwardChat(WebSocketChannel channel, MessageEnvelope envelope) {
    final session = _findByChannel(channel);
    if (session == null) {
      return; // 未 hello 的连接不允许发言
    }
    final msgId = envelope.msgId;
    if (msgId != null) {
      _send(
        channel,
        MessageEnvelope(type: MessageType.ack, msgId: msgId, timestamp: _now()),
      );
    }
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
    } else {
      final destination = _sessions[target];
      if (destination != null) {
        _send(destination.channel, forwarded);
      }
    }
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
    final entry = _sessions.entries
        .where((e) => identical(e.value.channel, channel))
        .toList(growable: false);
    for (final e in entry) {
      _sessions.remove(e.key);
    }
    if (entry.isNotEmpty) {
      _broadcastRoster();
    }
  }

  void _broadcastRoster() {
    final roster = MessageEnvelope(
      type: MessageType.roster,
      timestamp: _now(),
      payload: <String, dynamic>{
        'devices': <Map<String, dynamic>>[
          for (final session in _sessions.values) session.profile.toJson(),
        ],
      },
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
