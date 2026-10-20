import 'relay_status.dart';

export 'relay_status.dart';

/// Web 端桩：浏览器无法监听端口，中继服务不可用。
class HostServer {
  HostServer._();

  static final HostServer instance = HostServer._();

  bool get isRunning => false;
  int? get port => null;

  Future<RelayStatus> start({int port = 9090}) async =>
      const RelayStatus.unsupported();

  /// 测试钩子的桩实现（Web 端无真实会话，空操作）。
  Future<void> dropClient(String deviceId) async {}

  Future<void> stop() async {}
}
