import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/platform/desktop_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 平台差异化初始化：Windows 窗口管理（Web/Android 下为空实现或跳过）。
  await bootstrapDesktop();
  runApp(const ProviderScope(child: LanMessengerApp()));
}
