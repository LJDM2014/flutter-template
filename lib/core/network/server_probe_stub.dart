import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'probe_result.dart';

/// Web 平台实现：浏览器无法发起原始 TCP/TLS 连接。
///
/// - probeHost：以 WebSocket 握手（channel.ready）+ 超时竞争近似探测可达性；
/// - probeServer：以 fetch 请求 /api/me 近似探测——任何 HTTP 响应（含 401）
///   均视为可达。自签证书未受信时 https 请求会失败（需先在浏览器访问一次
///   中继地址完成信任），故 secure 探测在前、明文回退在后。
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

Future<ProbeResult> probeServer(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  final secure = await _reachable(Uri.parse('https://$host:$port/api/me'), timeout);
  if (secure) {
    return const ProbeResult(reachable: true, secure: true);
  }
  final plain = await _reachable(Uri.parse('http://$host:$port/api/me'), timeout);
  return plain
      ? const ProbeResult(reachable: true, secure: false)
      : ProbeResult.unreachable;
}

/// 发起请求；任何 HTTP 响应（含 401/404）都说明服务在线。
Future<bool> _reachable(Uri url, Duration timeout) async {
  try {
    final response = await http.get(url).timeout(timeout);
    return response.statusCode > 0;
  } catch (_) {
    return false;
  }
}
