/// TLS 支持工具的平台统一入口（自签证书场景）。
///
/// - IO（Windows/Android）：wss 连接与 https 请求使用接受自签证书的客户端；
/// - Web：浏览器策略管理证书信任，代码内不可绕过，走默认实现。
library;

export 'tls_support_stub.dart' if (dart.library.io) 'tls_support_io.dart';
