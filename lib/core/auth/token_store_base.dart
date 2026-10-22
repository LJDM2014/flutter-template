/// 登录 token 的本地存储抽象（R4：token 不再明文写入 shared_preferences）。
///
/// - IO 平台（Windows/Android）：flutter_secure_storage
///   （Windows DPAPI / Android Keystore），见 token_store_secure.dart；
/// - Web：shared_preferences（localStorage；浏览器端无更高保障的本地
///   存储，隔离边界由同源策略提供），见 token_store_prefs.dart；
/// - 平台门面见 token_store.dart；测试可注入 [InMemoryTokenStore]。
library;

import 'dart:async';

/// 登录 token 存储接口（仅针对 token，职责单一）。
abstract interface class TokenStore {
  /// 读取持久化的 token；无存量返回 null。
  Future<String?> readToken();

  /// 覆写持久化 token。
  Future<void> writeToken(String token);

  /// 删除持久化 token（登出/会话失效）。
  Future<void> deleteToken();
}

/// 内存实现：供测试注入（无持久化能力，进程结束即失）。
class InMemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> writeToken(String token) async {
    _token = token;
  }

  @override
  Future<void> deleteToken() async {
    _token = null;
  }
}
