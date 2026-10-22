/// 本机局域网 IPv4 地址查询的统一入口。
///
/// 通过条件导入隔离平台差异：
/// - Web：无法监听端口也无意义，返回空列表（stub）；
/// - Windows/Android：通过 dart:io 枚举网卡。
library;

export 'lan_ip_stub.dart' if (dart.library.io) 'lan_ip_io.dart';
