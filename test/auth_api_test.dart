import 'dart:io';

import 'package:flutter_template/core/network/host_server.dart';
import 'package:flutter_template/features/auth/auth_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'server_test_kit.dart';

/// AuthApi 客户端集成测试：直连真实中继的 REST 接口，
/// 覆盖注册/登录/me 的成功路径与错误码映射。
void main() {
  late int port;
  late Directory accountDir;
  late AuthApi api;

  setUpAll(() async {
    final (dir, store) = await createTempAccountStore();
    accountDir = dir;
    final status = await HostServer.instance.start(
      port: 0,
      accountStore: store,
    );
    expect(status.running, isTrue);
    port = status.port!;
    api = AuthApi();
  });

  tearDownAll(() async {
    api.close();
    await HostServer.instance.stop();
    if (await accountDir.exists()) {
      await accountDir.delete(recursive: true);
    }
  });

  String base() => 'http://127.0.0.1:$port';

  test('注册即登录：返回 token 与账号资料（不含 passwordHash）', () async {
    final result = await api.register(
      base(),
      username: 'api_user',
      password: 'password1',
      nickname: '接口',
      deviceId: 'device-api',
    );
    expect(result.token, isNotEmpty);
    expect(result.user.username, 'api_user');
    expect(result.user.nickname, '接口');
  });

  test('重复注册返回 USERNAME_TAKEN', () async {
    await expectLater(
      api.register(base(), username: 'api_user', password: 'password1'),
      throwsA(
        isA<AuthApiException>().having((e) => e.code, 'code', 'USERNAME_TAKEN'),
      ),
    );
  });

  test('非法用户名与弱密码返回对应错误码', () async {
    await expectLater(
      api.register(base(), username: 'x', password: 'password1'),
      throwsA(
        isA<AuthApiException>().having(
          (e) => e.code,
          'code',
          'INVALID_USERNAME',
        ),
      ),
    );
    await expectLater(
      api.register(base(), username: 'api_weak', password: 'short'),
      throwsA(
        isA<AuthApiException>().having((e) => e.code, 'code', 'WEAK_PASSWORD'),
      ),
    );
  });

  test('登录成功签发新 token；错误密码返回 BAD_CREDENTIALS', () async {
    final ok = await api.login(
      base(),
      username: 'api_user',
      password: 'password1',
      deviceId: 'device-api-2',
    );
    expect(ok.token, isNotEmpty);
    expect(ok.user.username, 'api_user');

    await expectLater(
      api.login(base(), username: 'api_user', password: 'wrong-pass'),
      throwsA(
        isA<AuthApiException>().having(
          (e) => e.code,
          'code',
          'BAD_CREDENTIALS',
        ),
      ),
    );
  });

  test('me：有效 token 返回资料，坏 token 返回 INVALID_TOKEN', () async {
    final result = await api.login(
      base(),
      username: 'api_user',
      password: 'password1',
      deviceId: 'device-api-3',
    );
    final me = await api.me(base(), result.token);
    expect(me.username, 'api_user');

    await expectLater(
      api.me(base(), 'not-a-real-token'),
      throwsA(
        isA<AuthApiException>().having((e) => e.code, 'code', 'INVALID_TOKEN'),
      ),
    );
  });

  test('服务不可达返回 NETWORK_ERROR', () async {
    // 49091 为未监听端口，连接将被拒绝。
    await expectLater(
      api.login(
        'http://127.0.0.1:49091',
        username: 'api_user',
        password: 'password1',
      ),
      throwsA(
        isA<AuthApiException>().having((e) => e.code, 'code', 'NETWORK_ERROR'),
      ),
    );
  });
}
