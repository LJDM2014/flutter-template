import 'dart:io';

import 'package:flutter_template/core/auth/account_store_io.dart';
import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_template/core/network/host_server_io.dart';
import 'package:flutter_template/core/network/probe_result.dart';
import 'package:flutter_template/core/network/relay_cert.dart';
import 'package:flutter_template/core/network/server_probe_io.dart';
import 'package:flutter_template/core/network/ws_client.dart';
import 'package:flutter_template/core/protocol/message_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import 'server_test_kit.dart';

/// 阶段 R1：中继 TLS（自签证书）端到端验收。
///
/// - ensureRelayCert：证书生成幂等、PEM 可被 SecurityContext 加载；
/// - HostServer + SecurityContext：secure 探测优先命中、https REST 闭环、
///   wss WS 握手与 roster 广播（走生产连接器，自签证书在 IO 端被接受）。
void main() {
  late Directory workDir;
  late Directory accountDir;

  setUpAll(() async {
    workDir = await Directory.systemTemp.createTemp('relay_tls_cert');
    accountDir = await Directory.systemTemp.createTemp('relay_tls_accounts');
  });

  tearDownAll(() async {
    await HostServer.instance.stop();
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
    if (await accountDir.exists()) {
      await accountDir.delete(recursive: true);
    }
  });

  test(
    'ensureRelayCert：证书可被 SecurityContext 加载，二次调用幂等复用',
    () async {
      final first = await ensureRelayCert(workDir);
      expect(first.certificatePemBytes, isNotEmpty);
      expect(first.privateKeyPemBytes, isNotEmpty);

      // PEM 被 dart:io 接受是 TLS 服务的最低要求（DER 拼装正确性由它背书）。
      SecurityContext()
        ..useCertificateChainBytes(first.certificatePemBytes)
        ..usePrivateKeyBytes(first.privateKeyPemBytes);

      // 幂等：文件已落盘，二次调用直接复用（内容一致）。
      expect(await File('${workDir.path}/relay-cert.pem').exists(), isTrue);
      expect(await File('${workDir.path}/relay-key.pem').exists(), isTrue);
      final second = await ensureRelayCert(workDir);
      expect(second.certificatePemBytes, first.certificatePemBytes);
      expect(second.privateKeyPemBytes, first.privateKeyPemBytes);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('HostServer TLS', () {
    late int port;

    setUpAll(() async {
      final cert = await ensureRelayCert(workDir);
      final context = SecurityContext()
        ..useCertificateChainBytes(cert.certificatePemBytes)
        ..usePrivateKeyBytes(cert.privateKeyPemBytes);
      final status = await HostServer.instance.start(
        port: 0,
        accountStore: JsonFileAccountStore(accountDir, pbkdf2Iterations: 1000),
        securityContext: context,
      );
      expect(status.running, isTrue);
      expect(status.secure, isTrue, reason: '带 TLS 上下文启动应标记 secure');
      port = status.port!;
    });

    test('probeServer：TLS 端口 secure 探测可达且标记加密', () async {
      final result = await probeServer('127.0.0.1', port);
      expect(result.reachable, isTrue);
      expect(result.secure, isTrue, reason: 'TLS 服务必须先命中 secure 探测');
    });

    test('https REST：注册/登录/当前用户闭环（接受自签证书）', () async {
      final alice = await registerAccount(
        port,
        'tls_alice',
        nickname: 'TLS甲',
        secure: true,
      );
      expect(alice.token, isNotEmpty);
      final bob = await loginAccount(
        port,
        'tls_alice',
        password: 'password1',
        secure: true,
      );
      expect(bob.userId, alice.userId, reason: '同账号重复登录返回同一用户');

      final (meStatus, me) = await getJson(
        port,
        'api/me',
        bearer: alice.token,
        secure: true,
      );
      expect(meStatus, 200);
      expect(me['user']['username'], 'tls_alice');
    });

    test('wss WS：生产连接器握手成功，roster 广播闭环', () async {
      final alice = await registerAccount(
        port,
        'tls_wsa',
        nickname: '甲',
        deviceId: 'dev-a',
        secure: true,
      );
      final bob = await registerAccount(
        port,
        'tls_wsb',
        nickname: '乙',
        deviceId: 'dev-b',
        secure: true,
      );

      var rosterHasBob = false;
      final clientA = LanWsClient(
        userId: alice.userId,
        deviceId: 'dev-a',
        nickname: alice.nickname,
        token: alice.token,
        backoff: BackoffStrategy(
          baseDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(seconds: 1),
          jitterRatio: 0,
        ),
        heartbeatInterval: Duration.zero,
      );
      clientA.messages.listen((m) {
        if (m.type == MessageType.roster) {
          rosterHasBob = rosterUsersFromPayload(
            m.payload,
          ).any((u) => u.id == bob.userId);
        }
      });
      final clientB = LanWsClient(
        userId: bob.userId,
        deviceId: 'dev-b',
        nickname: bob.nickname,
        token: bob.token,
        backoff: BackoffStrategy(
          baseDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(seconds: 1),
          jitterRatio: 0,
        ),
        heartbeatInterval: Duration.zero,
      );

      // 默认连接器（tls_support_io）对 wss 接受自签证书。
      await clientA.connect(Uri.parse('wss://127.0.0.1:$port/ws'));
      await clientB.connect(Uri.parse('wss://127.0.0.1:$port/ws'));
      await waitFor(
        () => clientA.isConnected && clientB.isConnected && rosterHasBob,
        what: 'wss 双端连接且 A 收到含 B 的 roster',
      );
      await clientA.disconnect();
      await clientB.disconnect();
    });

    test('明文服务 probeServer 探测为可达但 secure=false', () async {
      await HostServer.instance.stop();
      final status = await HostServer.instance.start(
        port: 0,
        accountStore: JsonFileAccountStore(accountDir, pbkdf2Iterations: 1000),
      );
      expect(status.running, isTrue);
      expect(status.secure, isFalse);
      final ProbeResult result = await probeServer('127.0.0.1', status.port!);
      expect(result.reachable, isTrue);
      expect(result.secure, isFalse, reason: '明文服务不应被误判为 TLS');
    });
  });
}
