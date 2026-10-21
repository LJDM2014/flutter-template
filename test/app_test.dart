import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_template/app.dart';
import 'package:flutter_template/core/constants.dart';
import 'package:flutter_template/core/network/server_resolver.dart';
import 'package:flutter_template/features/connection/connection_providers.dart';

/// 永远探测不到服务器的解析器：让「登录即连接」在测试中确定性失败，
/// 避免真实网段扫描导致测试缓慢或环境相关。
class _NoServerResolver extends ServerAddressResolver {
  _NoServerResolver()
    : super(
        probe:
            (
              String _,
              int _, {
              Duration timeout = const Duration(milliseconds: 800),
            }) async => false,
        listLocalAddresses: () async => <String>[],
      );
}

void main() {
  testWidgets('未登录时启动进入登录页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const ProviderScope(child: LanMessengerApp()));
    // 不使用 pumpAndSettle：认证恢复与页面内容包含真实异步初始化，
    // 在 FakeAsync 环境中可能永不完成，分步 pump 即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 路由守卫把未登录用户重定向到登录页。
    expect(find.text('登录'), findsWidgets);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });

  testWidgets('已保存会话时启动直达消息页并自动连接（失败时给出提示）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppConstants.prefKeyAuthToken: 'token-abc',
      AppConstants.prefKeyAuthUserId: 'user-1',
      AppConstants.prefKeyAuthUsername: 'saved_user',
      AppConstants.prefKeyAuthNickname: '存档',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 桩解析器：自动连接确定性失败，断言失败提示而非真实网络。
          connectionProvider.overrideWith(
            () => ConnectionController(resolver: _NoServerResolver()),
          ),
        ],
        child: const LanMessengerApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 启动直达消息页（登录即连接，阶段⑤）。
    expect(find.text('消息'), findsWidgets);
    // 自动连接解析不到服务器：空态给出失败原因与重试入口。
    expect(find.text('未检测到可连通的服务器，请确认桌面端中继已启动'), findsOneWidget);
    expect(find.text('自动检测并连接'), findsOneWidget);
    expect(find.text('前往连接设置'), findsOneWidget);
  });
}
