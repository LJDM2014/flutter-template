import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_template/core/constants.dart';
import 'package:flutter_template/core/network/host_server_io.dart';
import 'package:flutter_template/core/network/server_resolver.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/features/auth/auth_providers.dart';
import 'package:flutter_template/features/connection/connection_providers.dart';

import 'server_test_kit.dart';

/// 阶段⑤「登录即连接」：
/// 1. 启动恢复 token 经 /api/me 校验——无效即登出并清会话；
/// 2. 校验通过以服务端资料为准；
/// 3. 服务器不可达时乐观恢复；
/// 4. 恢复会话后自动解析地址并连接真实中继（登录即连接）；
/// 5. 自动连接失败时给出明确错误提示。

/// /api/me 桩服务：按给定状态码与响应体应答。
Future<HttpServer> _startMeStub({
  required int status,
  required Map<String, dynamic> body,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final payload = utf8.encode(jsonEncode(body));
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    await request.response.addStream(Stream<List<int>>.value(payload));
    await request.response.close();
  });
  return server;
}

/// 永远探测不到服务器的解析器（确定性失败，避免真实网段扫描）。
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

Map<String, Object> _sessionPrefs({
  required String token,
  required String userId,
  String username = 'saved_user',
  String nickname = '本地昵称',
  required String serverHost,
}) => <String, Object>{
  AppConstants.prefKeyAuthToken: token,
  AppConstants.prefKeyAuthUserId: userId,
  AppConstants.prefKeyAuthUsername: username,
  AppConstants.prefKeyAuthNickname: nickname,
  AppConstants.prefKeyServerHost: serverHost,
};

void main() {
  tearDown(() async {
    await HostServer.instance.stop();
  });

  test('恢复的 token 已失效：/api/me 返回 INVALID_TOKEN 时清会话并登出', () async {
    final stub = await _startMeStub(
      status: 401,
      body: <String, dynamic>{
        'error': <String, dynamic>{'code': 'INVALID_TOKEN', 'message': '凭证无效'},
      },
    );
    SharedPreferences.setMockInitialValues(
      _sessionPrefs(
        token: 'dead-token',
        userId: 'user-1',
        serverHost: '127.0.0.1:${stub.port}',
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await waitFor(
      () => container.read(authProvider).phase == AuthPhase.loggedOut,
      what: '无效 token 恢复后转未登录',
    );

    // 本地会话已被清空，下次启动直接进登录页。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.prefKeyAuthToken), isNull);
    expect(prefs.getString(AppConstants.prefKeyAuthUserId), isNull);
    stub.close(force: true);
  });

  test('恢复的 token 有效：进入已登录且资料以服务端为准', () async {
    final stub = await _startMeStub(
      status: 200,
      body: <String, dynamic>{
        'user': <String, dynamic>{
          'id': 'user-1',
          'username': 'server_user',
          'nickname': '服务端昵称',
        },
      },
    );
    SharedPreferences.setMockInitialValues(
      _sessionPrefs(
        token: 'good-token',
        userId: 'user-1',
        serverHost: '127.0.0.1:${stub.port}',
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await waitFor(
      () => container.read(authProvider).isAuthenticated,
      what: '有效 token 恢复为已登录',
    );

    final auth = container.read(authProvider);
    expect(auth.user?.nickname, '服务端昵称');
    expect(auth.token, 'good-token');
    stub.close(force: true);
  });

  test('服务器不可达：乐观恢复已登录（由连接层兜底重试）', () async {
    // 127.0.0.1:1 无监听，连接立即被拒 → NETWORK_ERROR（非 INVALID_TOKEN）。
    SharedPreferences.setMockInitialValues(
      _sessionPrefs(
        token: 'token-xyz',
        userId: 'user-1',
        serverHost: '127.0.0.1:1',
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await waitFor(
      () => container.read(authProvider).isAuthenticated,
      what: '服务器不可达时仍乐观恢复会话',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.prefKeyAuthToken), 'token-xyz');
  });

  test('登录即连接：恢复会话后自动连接真实中继并收到 roster', () async {
    final (dir, store) = await createTempAccountStore();
    addTearDown(() async => dir.delete(recursive: true));
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: store,
    );
    expect(status.running, isTrue);
    final port = status.port!;

    // 注册账号并写入本地会话（模拟上次登录留存的 token）。
    final account = await registerAccount(port, 'auto_user', deviceId: 'dev-1');
    SharedPreferences.setMockInitialValues(<String, Object>{
      ..._sessionPrefs(
        token: account.token,
        userId: account.userId,
        username: account.username,
        nickname: account.nickname,
        serverHost: '127.0.0.1:$port',
      ),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 先读连接状态（创建控制器并监听认证变化），恢复完成后应自动连接。
    container.read(connectionProvider);
    await waitFor(
      () => container.read(authProvider).isAuthenticated,
      what: 'token 校验通过',
    );
    await waitFor(
      () =>
          container.read(connectionProvider).conn.phase ==
          LanConnPhase.connected,
      what: '登录即连接成功',
      timeout: const Duration(seconds: 10),
    );

    // roster 到位：在线列表包含自己（按用户身份）。
    final devices = container.read(connectionProvider).devices;
    expect(devices.any((d) => d.id == account.userId), isTrue);

    // 解析出的地址已持久化为上次使用的地址。
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.prefKeyServerHost), '127.0.0.1:$port');
  });

  test('自动连接失败：无可连通服务器时连接状态给出错误提示', () async {
    SharedPreferences.setMockInitialValues(
      _sessionPrefs(
        token: 'token-xyz',
        userId: 'user-1',
        serverHost: '127.0.0.1:1',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        connectionProvider.overrideWith(
          () => ConnectionController(resolver: _NoServerResolver()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await waitFor(
      () => container.read(connectionProvider).conn.error != null,
      what: '自动连接失败提示',
      timeout: const Duration(seconds: 10),
    );
    expect(
      container.read(connectionProvider).conn.error,
      '未检测到可连通的服务器，请确认桌面端中继已启动',
    );
    expect(
      container.read(connectionProvider).conn.phase,
      LanConnPhase.disconnected,
    );
  });
}
