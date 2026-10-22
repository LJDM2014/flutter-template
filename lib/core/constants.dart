/// 全局常量：应用信息、默认通信参数、本地持久化键名。
abstract final class AppConstants {
  static const String appTitle = 'LAN Messenger';
  static const String appVersion = '0.1.0';

  /// 桌面端内置 WebSocket 中继服务的默认端口（阶段②启用）。
  static const int defaultPort = 9090;

  // 本地持久化键名（shared_preferences）。
  static const String prefKeyServerHost = 'pref.server_host';

  /// 上次连接的服务器是否为 TLS（wss/https）；缺省 false（明文）。
  static const String prefKeyServerSecure = 'pref.server_secure';
  static const String prefKeyDeviceId = 'pref.device_id';

  /// 登录 token 存储键（R4）。
  ///
  /// - IO 端：flutter_secure_storage 的键名（Windows DPAPI / Android
  ///   Keystore）；首次读取时自动迁移本键在 shared_preferences 中的旧版
  ///   明文副本；
  /// - Web 端：shared_preferences 键名（localStorage，同源隔离）。
  ///
  /// 账号资料（user_id/username/nickname，非敏感）仍存于 shared_preferences。
  static const String prefKeyAuthToken = 'pref.auth.token';
  static const String prefKeyAuthUserId = 'pref.auth.user_id';
  static const String prefKeyAuthUsername = 'pref.auth.username';
  static const String prefKeyAuthNickname = 'pref.auth.nickname';

  /// 桌面端窗口最小尺寸。
  static const double windowMinWidth = 800;
  static const double windowMinHeight = 600;
}
