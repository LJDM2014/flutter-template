import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';

/// 用户昵称（本地持久化）。
///
/// - build：启动时从 shared_preferences 读取；
/// - save：写回持久化并同步状态。
class NicknameNotifier extends AsyncNotifier<String?> {
  @override
  FutureOr<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefKeyNickname);
  }

  Future<void> save(String nickname) async {
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyNickname, trimmed);
    state = AsyncData<String?>(trimmed);
  }
}

final AsyncNotifierProvider<NicknameNotifier, String?> nicknameProvider =
    AsyncNotifierProvider<NicknameNotifier, String?>(NicknameNotifier.new);
