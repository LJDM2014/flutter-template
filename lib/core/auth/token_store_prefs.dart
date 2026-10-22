import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'token_store_base.dart';

/// Web 平台实现：shared_preferences（localStorage）。
///
/// 浏览器端没有更高保障的本地存储可用，token 防护依赖同源隔离；
/// 键名沿用 [AppConstants.prefKeyAuthToken]，存量 Web 会话无需迁移。
class PlatformTokenStore implements TokenStore {
  @override
  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefKeyAuthToken);
  }

  @override
  Future<void> writeToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyAuthToken, token);
  }

  @override
  Future<void> deleteToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.prefKeyAuthToken);
  }
}
