import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/constants.dart';
import 'features/chat/chat_page.dart';
import 'features/connection/connect_page.dart';
import 'features/settings/settings_page.dart';
import 'shared/widgets/adaptive_scaffold.dart';

final GoRouter _router = GoRouter(
  initialLocation: ConnectPage.routePath,
  routes: <RouteBase>[
    ShellRoute(
      builder: (context, state, child) =>
          AdaptiveScaffold(location: state.matchedLocation, child: child),
      routes: <RouteBase>[
        GoRoute(
          path: ConnectPage.routePath,
          builder: (context, state) => const ConnectPage(),
        ),
        GoRoute(
          path: ChatPage.routePath,
          builder: (context, state) => const ChatPage(),
        ),
        GoRoute(
          path: SettingsPage.routePath,
          builder: (context, state) => const SettingsPage(),
        ),
      ],
    ),
  ],
);

/// 应用根组件：Material 3 + go_router（Web 端默认 hash 策略，刷新不 404）。
class LanMessengerApp extends StatelessWidget {
  const LanMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppConstants.appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00A86B)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A86B),
          brightness: Brightness.dark,
        ),
      ),
      routerConfig: _router,
    );
  }
}
