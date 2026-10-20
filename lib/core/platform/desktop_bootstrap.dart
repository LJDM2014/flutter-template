/// 平台差异化启动逻辑的统一入口。
///
/// 业务层不得直接引用平台 API，统一通过本文件的条件导入隔离：
/// - Web（无 dart:io）：空实现；
/// - Windows/Android：执行桌面窗口初始化（内部按平台判断）。
library;

export 'desktop_bootstrap_stub.dart' if (dart.library.io) 'desktop_bootstrap_io.dart';
