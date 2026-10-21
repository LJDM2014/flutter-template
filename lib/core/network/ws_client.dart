import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/message_envelope.dart';
import 'backoff.dart';

/// 连接阶段。
///
/// [LanConnPhase.authFailed] 为不可恢复终态：服务端拒绝令牌（如已失效/被踢），
/// 客户端不再自动重连，应转登录页重新获取 token。
enum LanConnPhase {
  disconnected,
  connecting,
  connected,
  reconnecting,
  authFailed,
}

/// 对外暴露的连接状态快照。
class LanConnState {
  const LanConnState({
    required this.phase,
    this.address,
    this.retryIn,
    this.error,
  });

  final LanConnPhase phase;
  final String? address;

  /// 重连等待倒计时（reconnecting 阶段非空）。
  final Duration? retryIn;
  final String? error;

  @override
  String toString() =>
      'LanConnState(${phase.name}, retryIn=$retryIn, error=$error)';
}

/// 局域网 WebSocket 客户端（纯 Dart，无 Flutter 依赖，可被单元/集成测试）。
///
/// 职责：
/// - 建立连接并在断开后按指数退避自动重连（[BackoffStrategy]）；
/// - 心跳保活：定期 ping，连续超时未收到 pong 主动断开触发重连；
/// - 可靠性：携带 msgId 且未收到 ack 的消息保留在待发队列，重连成功后补发。
///
/// 协议内部消息（hello/ping/pong/ack）在本层消化；业务消息（roster/chat）
/// 通过 [messages] 流向上层。
class LanWsClient {
  LanWsClient({
    required this.userId,
    required this.deviceId,
    this.nickname = '',
    this.token = '',
    BackoffStrategy? backoff,
    this.heartbeatInterval = const Duration(seconds: 15),
    FutureOr<WebSocketChannel> Function(Uri uri)? connector,
  }) : _backoff = backoff ?? BackoffStrategy(),
       _connector = connector ?? WebSocketChannel.connect;

  /// 登录账号 id（阶段②起服务端据此校验 token；匿名直连将被拒绝）。
  final String userId;

  /// 设备标识：同一账号多设备会话时，服务端据此踢同设备旧连接。
  final String deviceId;
  String nickname;

  /// 登录令牌；非空时随 hello 上报，服务端（阶段②起）据此鉴权。
  final String token;
  final Duration heartbeatInterval;

  final BackoffStrategy _backoff;
  final FutureOr<WebSocketChannel> Function(Uri uri) _connector;

  final StreamController<LanConnState> _stateController =
      StreamController<LanConnState>.broadcast();
  final StreamController<MessageEnvelope> _messageController =
      StreamController<MessageEnvelope>.broadcast();
  final StreamController<String> _ackController =
      StreamController<String>.broadcast();

  /// 未确认消息队列（msgId → envelope），重连后按序补发。
  final Map<String, MessageEnvelope> _pending = <String, MessageEnvelope>{};

  Uri? _uri;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  int _missedPongs = 0;
  bool _running = false;
  int _generation = 0;
  Completer<void>? _closedSignal;
  LanConnState _state = const LanConnState(phase: LanConnPhase.disconnected);

  LanConnState get state => _state;
  bool get isConnected => _state.phase == LanConnPhase.connected;

  Stream<LanConnState> get states => _stateController.stream;
  Stream<MessageEnvelope> get messages => _messageController.stream;

  /// 已被服务端确认的消息 id 流（聊天层据此把「发送中」标记为「已送达」）。
  Stream<String> get acks => _ackController.stream;

  /// 开始连接并进入自动重连循环。
  Future<void> connect(Uri uri) async {
    if (_running && _uri == uri) {
      return;
    }
    _generation += 1; // 使旧的重连循环退出
    _uri = uri;
    await _teardownSocket();
    _running = true;
    unawaited(_runLoop(_generation));
  }

  /// 主动断开并停止重连。
  Future<void> disconnect() async {
    _running = false;
    _generation += 1;
    _uri = null;
    _signalClosed();
    await _teardownSocket();
    _setState(const LanConnState(phase: LanConnPhase.disconnected));
  }

  /// 入队一条业务消息；已连接则立即发送，否则等重连后补发。
  void enqueue(MessageEnvelope envelope) {
    final msgId = envelope.msgId;
    if (msgId == null || msgId.isEmpty) {
      _sendNow(envelope);
      return;
    }
    _pending[msgId] = envelope;
    if (isConnected) {
      _sendNow(envelope);
    }
  }

  /// 发送方收到 ack 后移除待确认消息。
  void acknowledge(String msgId) {
    _pending.remove(msgId);
  }

  /// 向服务端确认收到消息（离线补投的落盘凭证）。
  ///
  /// 直接发送、不进入待发队列——服务端不会对 ack 再回 ack。
  void sendAck(String msgId) {
    _sendNow(
      MessageEnvelope(
        type: MessageType.ack,
        msgId: msgId,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 当前未确认（待补发）消息数，可用于 UI 提示。
  int get pendingCount => _pending.length;

  /// 指定消息是否仍在待发队列中。
  bool hasPending(String msgId) => _pending.containsKey(msgId);

  Future<void> _runLoop(int generation) async {
    var attempt = 0;
    var lastError = '';
    while (_running && _uri != null && generation == _generation) {
      _setState(
        LanConnState(
          phase: LanConnPhase.connecting,
          address: _uri.toString(),
          error: lastError.isEmpty ? null : lastError,
        ),
      );
      try {
        final channel = await _connector(_uri!);
        await channel.ready;
        _channel = channel;
        _missedPongs = 0;
        attempt = 0;
        lastError = '';
        _setState(
          LanConnState(phase: LanConnPhase.connected, address: _uri.toString()),
        );
        _subscription = channel.stream.listen(
          _onData,
          onError: (Object error) => _signalClosed(),
          onDone: _signalClosed,
        );
        _startHeartbeat();
        _sendHello();
        _flushPending();
        await (_closedSignal = Completer<void>()).future;
      } catch (error) {
        lastError = error.toString();
      } finally {
        _stopHeartbeat();
        await _teardownSocket();
      }
      if (!_running || generation != _generation) {
        break;
      }
      final delay = _backoff.delayFor(attempt);
      if (delay == null) {
        lastError = lastError.isEmpty ? '重连次数已达上限' : lastError;
        _setState(
          LanConnState(
            phase: LanConnPhase.disconnected,
            address: _uri?.toString(),
            error: lastError,
          ),
        );
        break;
      }
      attempt += 1;
      _setState(
        LanConnState(
          phase: LanConnPhase.reconnecting,
          address: _uri?.toString(),
          retryIn: delay,
          error: lastError.isEmpty ? null : lastError,
        ),
      );
      await Future<void>.delayed(delay);
      if (!_running || generation != _generation) {
        break;
      }
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) {
      return;
    }
    final envelope = MessageEnvelope.tryParse(raw);
    if (envelope == null) {
      return;
    }
    switch (envelope.type) {
      case MessageType.ack:
        final msgId = envelope.msgId;
        if (msgId != null) {
          acknowledge(msgId);
          if (!_ackController.isClosed) {
            _ackController.add(msgId);
          }
        }
      case MessageType.pong:
        _missedPongs = 0;
      case MessageType.roster:
      case MessageType.chat:
        _messageController.add(envelope);
      case MessageType.error:
        _messageController.add(envelope);
        // 服务端鉴权拒绝：进入终态并停止自动重连（上层应转登录页）。
        final code = envelope.payload['code'];
        if (code == 'INVALID_TOKEN' || code == 'UNAUTHORIZED') {
          _running = false;
          _generation += 1;
          _setState(
            LanConnState(
              phase: LanConnPhase.authFailed,
              address: _uri?.toString(),
              error: '登录已失效，请重新登录',
            ),
          );
          _signalClosed();
        }
      case MessageType.hello:
      case MessageType.ping:
      case MessageType.unknown:
        break;
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    if (heartbeatInterval <= Duration.zero) {
      return; // 测试可禁用
    }
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      _missedPongs += 1;
      if (_missedPongs > 2) {
        // 连续未收到 pong，判定连接已死，主动断开触发重连。
        _signalClosed();
        return;
      }
      _sendNow(
        MessageEnvelope(
          type: MessageType.ping,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          payload: <String, dynamic>{
            't': DateTime.now().millisecondsSinceEpoch,
          },
        ),
      );
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _sendHello() {
    _sendNow(
      MessageEnvelope(
        type: MessageType.hello,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: <String, dynamic>{
          'id': userId,
          'deviceId': deviceId,
          'nickname': nickname,
          if (token.isNotEmpty) 'token': token,
        },
      ),
    );
  }

  void _flushPending() {
    for (final envelope in List<MessageEnvelope>.of(_pending.values)) {
      _sendNow(envelope);
    }
  }

  void _sendNow(MessageEnvelope envelope) {
    final sink = _channel?.sink;
    if (sink == null) {
      return;
    }
    try {
      sink.add(envelope.encode());
    } catch (_) {
      // 发送失败交由重连机制处理，消息保留在待发队列。
    }
  }

  void _signalClosed() {
    _closedSignal?.complete();
    _closedSignal = null;
  }

  Future<void> _teardownSocket() async {
    _stopHeartbeat();
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    _closedSignal = null;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  void _setState(LanConnState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }
}
