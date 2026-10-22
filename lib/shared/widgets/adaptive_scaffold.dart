import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app_paths.dart';

/// 自适应导航壳：
/// - 窄屏（移动端 / 窄窗口）：单列布局 + 底部 NavigationBar；
/// - 宽屏（桌面端 / 宽 Web 窗口）：左侧 NavigationRail + 内容区；
/// - 超宽（>=1200）：Rail 展开 extended 显示文字标签。
///
/// 窗口缩放时布局随宽度自动切换，符合各平台交互习惯。
class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.location,
    required this.child,
  });

  final String location;
  final Widget child;

  static const double _wideBreakpoint = 900;
  static const double _extendedBreakpoint = 1200;

  int _selectedIndexFor(String location) {
    final index =
        kAppDestinations.indexWhere((d) => location.startsWith(d.path));
    return index < 0 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final selectedIndex = _selectedIndexFor(location);

    if (width < _wideBreakpoint) {
      return Scaffold(
        body: SafeArea(child: child),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (i) => context.go(kAppDestinations[i].path),
          destinations: <Widget>[
            for (final d in kAppDestinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: <Widget>[
            NavigationRail(
              selectedIndex: selectedIndex,
              onDestinationSelected: (i) => context.go(kAppDestinations[i].path),
              extended: width >= _extendedBreakpoint,
              labelType: width >= _extendedBreakpoint
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              destinations: <NavigationRailDestination>[
                for (final d in kAppDestinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
