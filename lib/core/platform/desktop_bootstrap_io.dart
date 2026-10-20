import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../constants.dart';
import '../network/host_server.dart';

/// 非 Web 平台的启动逻辑。
///
/// - Windows：初始化窗口（最小尺寸、标题、居中），并启动内置 WebSocket 中继服务；
/// - Android：跳过窗口管理，不启动服务（桌面端作为唯一中继）。
Future<void> bootstrapDesktop() async {
  if (!Platform.isWindows) {
    return;
  }
  await windowManager.ensureInitialized();
  final options = WindowOptions(
    title: AppConstants.appTitle,
    minimumSize: Size(
      AppConstants.windowMinWidth,
      AppConstants.windowMinHeight,
    ),
    center: true,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  // 启动局域网中继服务，结果写入 RelayRuntime 供连接页展示。
  RelayRuntime.status = await HostServer.instance.start();
}
