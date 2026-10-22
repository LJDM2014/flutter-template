import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import 'token_store_base.dart';

/// IO 平台实现：flutter_secure_storage（Windows DPAPI / Android Keystore）。
///
/// token 不以明文形式出现在 shared_preferences 文件中；存储键沿用
/// [AppConstants.prefKeyAuthToken]。
class PlatformTokenStore implements TokenStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> readToken() async {
    var token = await _storage.read(key: AppConstants.prefKeyAuthToken);
    if (token == null || token.isEmpty) {
      token = await _migrateLegacyPlaintext();
    }
    return token;
  }

  /// R4 迁移：旧版本把明文 token 写在 shared_preferences；首次读取时
  /// 搬迁至安全存储并删除明文副本。迁移失败按无 token 处理，不阻塞启动。
  Future<String?> _migrateLegacyPlaintext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(AppConstants.prefKeyAuthToken);
      if (legacy == null || legacy.isEmpty) {
        return null;
      }
      await _storage.write(key: AppConstants.prefKeyAuthToken, value: legacy);
      await prefs.remove(AppConstants.prefKeyAuthToken);
      return legacy;
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> writeToken(String token) =>
      _storage.write(key: AppConstants.prefKeyAuthToken, value: token);

  @override
  Future<void> deleteToken() =>
      _storage.delete(key: AppConstants.prefKeyAuthToken);
}
