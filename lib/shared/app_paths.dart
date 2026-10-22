import 'package:flutter/material.dart';

/// 路由路径集中定义，供路由表与底部/侧边导航共用。
abstract final class AppPaths {
  static const String login = '/login';
  static const String register = '/register';
  static const String connect = '/connect';
  static const String chat = '/chat';

  /// 会话列表独立页（阶段⑧页面化；选中会话后回 /chat）。
  static const String chats = '/chats';
  static const String settings = '/settings';
}

/// 一个主导航目的地（连接 / 消息 / 设置）。
class AppDestination {
  const AppDestination({
    required this.path,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const List<AppDestination> kAppDestinations = <AppDestination>[
  AppDestination(
    path: AppPaths.connect,
    icon: Icons.lan_outlined,
    selectedIcon: Icons.lan,
    label: '连接',
  ),
  AppDestination(
    path: AppPaths.chat,
    icon: Icons.chat_bubble_outline,
    selectedIcon: Icons.chat_bubble,
    label: '消息',
  ),
  AppDestination(
    path: AppPaths.settings,
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: '设置',
  ),
];
