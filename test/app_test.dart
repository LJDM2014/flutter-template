import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_template/app.dart';

void main() {
  testWidgets('应用启动后进入连接页并展示导航', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const ProviderScope(child: LanMessengerApp()));
    // 不使用 pumpAndSettle：连接页会发起真实 dart:io 网卡枚举，
    // 在 FakeAsync 环境中永不完成，等待指示器会一直动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 连接页内容
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('连接'), findsWidgets);
    // 底部/侧边导航目的地
    expect(find.text('消息'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
