/// 桌面端内置中继服务的统一入口（条件导入隔离平台差异）。
///
/// - Web：浏览器无法监听端口，返回 unsupported 状态（stub）；
/// - Windows/Android：基于 shelf 的 WebSocket 中继（实际仅 Windows 启动）。
library;

export 'host_server_stub.dart' if (dart.library.io) 'host_server_io.dart';

export 'relay_status.dart';
