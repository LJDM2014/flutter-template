/// 全局常量：应用信息、默认通信参数、本地持久化键名。
abstract final class AppConstants {
  static const String appTitle = 'LAN Messenger';
  static const String appVersion = '0.1.0';

  /// 桌面端内置 WebSocket 中继服务的默认端口（阶段②启用）。
  static const int defaultPort = 9090;

  // 本地持久化键名（shared_preferences）。
  static const String prefKeyNickname = 'pref.nickname';
  static const String prefKeyServerHost = 'pref.server_host';
  static const String prefKeyDeviceId = 'pref.device_id';

  /// 桌面端窗口最小尺寸。
  static const double windowMinWidth = 800;
  static const double windowMinHeight = 600;
}
