import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_template/core/auth/account_store_io.dart';
import 'package:flutter_test/flutter_test.dart' show fail;

/// 测试辅助工具：临时账号库 + REST 注册/登录客户端 + 原始 HTTP 契约探测。
///
/// 供 host_server_auth_test / chat_flow_test / lan_network_integration_test
/// 等需要真实中继服务与账号体系的测试共用。

/// 在临时目录创建 JSON 账号库（低迭代数加速测试）。
Future<(Directory, JsonFileAccountStore)> createTempAccountStore() async {
  final dir = await Directory.systemTemp.createTemp('host_server_test');
  return (dir, JsonFileAccountStore(dir, pbkdf2Iterations: 1000));
}

/// TestWidgetsFlutterBinding 会拦截 HttpClient 并对所有请求返回 400；
/// 中继契约测试需要真实回环连接，用空 HttpOverrides 覆盖回去。
class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() action) =>
    HttpOverrides.runWithHttpOverrides(action, _RealHttpOverrides());

/// 注册/登录成功后的账号快照。
class TestAccount {
  const TestAccount({
    required this.userId,
    required this.username,
    required this.nickname,
    required this.token,
  });

  final String userId;
  final String username;
  final String nickname;
  final String token;
}

TestAccount _accountFrom(Map<String, dynamic> body) {
  final user = body['user'] as Map<String, dynamic>;
  return TestAccount(
    userId: user['id'] as String,
    username: user['username'] as String,
    nickname: user['nickname'] as String? ?? '',
    token: body['token'] as String,
  );
}

/// 注册并登录一个测试账号（注册即登录）。
Future<TestAccount> registerAccount(
  int port,
  String username, {
  String nickname = '',
  String deviceId = '',
  String password = 'password1',
  bool secure = false,
}) async {
  final (status, body) = await postJson(
    port,
    'api/register',
    <String, dynamic>{
      'username': username,
      'password': password,
      if (nickname.isNotEmpty) 'nickname': nickname,
      'deviceId': deviceId,
    },
    secure: secure,
  );
  if (status != 200) {
    throw StateError('注册失败($status)：$body');
  }
  return _accountFrom(body);
}

/// 登录已有账号（可指定不同 deviceId 获取新会话 token）。
Future<TestAccount> loginAccount(
  int port,
  String username, {
  String deviceId = '',
  String password = 'password1',
  bool secure = false,
}) async {
  final (status, body) = await postJson(
    port,
    'api/login',
    <String, dynamic>{'username': username, 'password': password, 'deviceId': deviceId},
    secure: secure,
  );
  if (status != 200) {
    throw StateError('登录失败($status)：$body');
  }
  return _accountFrom(body);
}

/// POST JSON（可带 Bearer），返回 (状态码, 响应体)。
///
/// [secure] 为 true 时走 https 并接受自签证书（TLS 中继测试用）。
Future<(int, Map<String, dynamic>)> postJson(
  int port,
  String path,
  Map<String, dynamic> payload, {
  String? bearer,
  bool secure = false,
}) => _withRealHttp(() async {
  final client = HttpClient()
    ..badCertificateCallback = secure ? (_, _, _) => true : null;
  try {
    final request = await client.postUrl(
      Uri.parse('${secure ? 'https' : 'http'}://127.0.0.1:$port/$path'),
    );
    request.headers.contentType = ContentType.json;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    request.write(jsonEncode(payload));
    final response = await request.close();
    return (response.statusCode, await _decode(response));
  } finally {
    client.close(force: true);
  }
});

/// GET（可带 Bearer），返回 (状态码, 响应体)。
///
/// [secure] 为 true 时走 https 并接受自签证书（TLS 中继测试用）。
Future<(int, Map<String, dynamic>)> getJson(
  int port,
  String path, {
  String? bearer,
  bool secure = false,
}) => _withRealHttp(() async {
  final client = HttpClient()
    ..badCertificateCallback = secure ? (_, _, _) => true : null;
  try {
    final request = await client.getUrl(
      Uri.parse('${secure ? 'https' : 'http'}://127.0.0.1:$port/$path'),
    );
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    final response = await request.close();
    return (response.statusCode, await _decode(response));
  } finally {
    client.close(force: true);
  }
});

/// 轮询等待条件成立，超时 fail。
Future<void> waitFor(
  FutureOr<bool> Function() probe, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await probe()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待超时：$what');
}

Future<Map<String, dynamic>> _decode(HttpClientResponse response) async {
  final raw = await response.transform(utf8.decoder).join();
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return <String, dynamic>{'raw': raw};
  }
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.cast<String, dynamic>();
  }
  return <String, dynamic>{'raw': raw};
}
