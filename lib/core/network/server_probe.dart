/// 服务器可达性探测的平台统一入口。
///
/// 通过条件导入隔离平台差异：
/// - IO（Windows/Android）：原生 TCP / TLS socket 探测；
/// - Web：浏览器禁止原始连接，用 HTTPS fetch + WebSocket 握手近似探测。
library;

export 'probe_result.dart';
export 'server_probe_stub.dart' if (dart.library.io) 'server_probe_io.dart';
