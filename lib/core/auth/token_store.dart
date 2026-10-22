/// token 存储的平台门面（条件导出，R4）。
///
/// - IO（Windows/Android）：flutter_secure_storage（DPAPI / Keystore）；
/// - 其余（Web）：shared_preferences（localStorage）。
///
/// 两个分支的 [PlatformTokenStore] API 完全一致；接口与测试内存实现
/// 见 [TokenStore]（token_store_base.dart）。
library;

export 'token_store_base.dart';
export 'token_store_prefs.dart' if (dart.library.io) 'token_store_secure.dart';
