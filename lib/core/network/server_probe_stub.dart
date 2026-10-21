import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Web 平台实现：浏览器无法发起原始 TCP 连接，
/// 以 WebSocket 握手（channel.ready）+ 超时竞争近似探测可达性。
Future<bool> probeHost(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  final channel = WebSocketChannel.connect(Uri.parse('ws://$host:$port/ws'));
  try {
    return await channel.ready
        .then((_) => true)
        .catchError((Object _) => false)
        .timeout(timeout, onTimeout: () => false);
  } catch (_) {
    return false;
  } finally {
    unawaited(channel.sink.close().catchError((Object _) {}));
  }
}
