/// 服务器端口可达性探测的平台统一入口。
///
/// 通过条件导入隔离平台差异：
/// - IO（Windows/Android）：原生 TCP connect 探测；
/// - Web：浏览器禁止原始 TCP，用 WebSocket 握手 + 超时竞争近似探测。
library;

export 'server_probe_stub.dart' if (dart.library.io) 'server_probe_io.dart';
