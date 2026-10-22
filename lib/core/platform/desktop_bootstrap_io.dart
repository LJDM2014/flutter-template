import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../auth/account_store_io.dart';
import '../constants.dart';
// io-only 文件直接使用具体实现：TLS 上下文参数仅 IO 版 HostServer 提供，
// 走条件门面会让分析器按 Web 平台解析到 stub 而报参数不存在。
import '../network/host_server_io.dart';
import '../network/relay_cert.dart';

/// 非 Web 平台的启动逻辑。
///
/// - Windows：初始化窗口（最小尺寸、标题、居中），并启动内置 WebSocket 中继服务
///   （默认 TLS 加密：自签证书，客户端以 wss/https 访问；证书生成失败时降级明文）；
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
  // 启动局域网中继服务（含账号 REST 接口），结果写入 RelayRuntime 供连接页展示。
  RelayRuntime.status = await HostServer.instance.start(
    accountStore: await createDefaultAccountStore(),
    securityContext: await _buildTlsContext(),
  );
}

/// 构建中继 TLS 上下文：首次启动自动生成自签证书并持久化，后续复用。
/// 证书生成或加载失败时返回 null（降级为明文服务，保持可用性）。
Future<SecurityContext?> _buildTlsContext() async {
  try {
    final cert = await ensureRelayCert(await defaultAppDataDirectory());
    return SecurityContext()
      ..useCertificateChainBytes(cert.certificatePemBytes)
      ..usePrivateKeyBytes(cert.privateKeyPemBytes);
  } catch (_) {
    // 证书生成/加载失败：降级为明文服务（保持可用性），客户端探测会走 http/ws。
    return null;
  }
}
