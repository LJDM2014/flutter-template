import 'dart:io';

import 'probe_result.dart';

/// IO 平台（Windows/Android）实现：以 TCP 连接探测 host:port 可达性。
///
/// 探测成功后立即销毁 socket，不影响对端中继服务。
Future<bool> probeHost(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// 服务探测：先 TLS 后明文。
///
/// TLS 探测必须先于明文——TLS 服务端口对原始 TCP 同样「可连通」，
/// 若明文探测在前会把加密服务误判为明文。自签证书通过 onBadCertificate 接受
/// （局域网自签场景），握手成功即认定 TLS 服务在线。
Future<ProbeResult> probeServer(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  try {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    socket.destroy();
    return const ProbeResult(reachable: true, secure: true);
  } catch (_) {
    // 非 TLS 服务（或不可达）：回退明文探测。
  }
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return const ProbeResult(reachable: true, secure: false);
  } catch (_) {
    return ProbeResult.unreachable;
  }
}
