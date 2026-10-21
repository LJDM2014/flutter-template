import 'dart:io';

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
