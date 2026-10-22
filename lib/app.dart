import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/constants.dart';
import 'features/auth/auth_pages.dart';
import 'features/auth/auth_providers.dart';
import 'features/chat/chat_page.dart';
import 'features/chat/chat_providers.dart';
import 'features/chat/conversations_page.dart';
import 'features/connection/connect_page.dart';
import 'features/settings/settings_page.dart';
import 'shared/widgets/adaptive_scaffold.dart';

/// 认证状态变化通知器：驱动 go_router 重新执行 redirect 守卫。
class _AuthRefreshListenable extends ChangeNotifier {
  AuthState auth = const AuthState(phase: AuthPhase.loading);

  void notify() => notifyListeners();
}

GoRouter _createRouter(_AuthRefreshListenable listenable) => GoRouter(
  // 登录即连接（阶段⑤）：启动直达消息页——已登录时自动连接在后台进行，
  // 连接过程与失败原因在消息页空态展示；未登录由守卫转登录页。
  initialLocation: ChatPage.routePath,
  refreshListenable: listenable,
  redirect: (context, state) {
    final auth = listenable.auth;
    final location = state.matchedLocation;
    final isAuthPage =
        location == LoginPage.routePath || location == RegisterPage.routePath;
    // 启动恢复中：暂不干预，恢复完成后触发刷新再守卫。
    if (auth.phase == AuthPhase.loading) {
      return null;
    }
    if (!auth.isAuthenticated) {
      return isAuthPage ? null : LoginPage.routePath;
    }
    return isAuthPage ? ConnectPage.routePath : null;
  },
  routes: <RouteBase>[
    GoRoute(
      path: LoginPage.routePath,
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: RegisterPage.routePath,
      builder: (context, state) => const RegisterPage(),
    ),
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
          path: ConversationsPage.routePath,
          builder: (context, state) => const ConversationsPage(),
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
class LanMessengerApp extends ConsumerStatefulWidget {
  const LanMessengerApp({super.key});

  @override
  ConsumerState<LanMessengerApp> createState() => _LanMessengerAppState();
}

class _LanMessengerAppState extends ConsumerState<LanMessengerApp> {
  late final _AuthRefreshListenable _authListenable;
  late final GoRouter _router;

  /// 全局 SnackBar 入口：跨页面提示（如不在消息页时收到离线补投）。
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _authListenable = _AuthRefreshListenable();
    _router = _createRouter(_authListenable);
    // 认证状态每次变化（恢复完成/登录/登出）都触发路由守卫重估。
    ref.listenManual<AuthState>(authProvider, (previous, next) {
      _authListenable
        ..auth = next
        ..notify();
    }, fireImmediately: true);
    // 阶段⑥：不在消息页时收到离线补投 → 全局 SnackBar 提示。
    // 消息页内由未读角标与「以下是离线消息」分隔线表达，不重复提示。
    ref.listenManual<ChatUiState>(chatProvider, (previous, next) {
      final count = next.replayNotice;
      if (count <= 0) {
        return;
      }
      final location = _router.routerDelegate.currentConfiguration.uri
          .toString();
      if (location.startsWith(ChatPage.routePath)) {
        return;
      }
      _scaffoldMessengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('收到 $count 条离线消息')));
      ref.read(chatProvider.notifier).clearReplayNotice();
    });
  }

  @override
  void dispose() {
    _router.dispose();
    _authListenable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppConstants.appTitle,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _scaffoldMessengerKey,
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
