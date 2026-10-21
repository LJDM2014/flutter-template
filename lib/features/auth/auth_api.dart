import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/protocol/message_envelope.dart';

/// 认证接口异常：携带服务端错误码（INVALID_USERNAME / WEAK_PASSWORD /
/// USERNAME_TAKEN / BAD_CREDENTIALS / INVALID_TOKEN / REGISTRATION_DISABLED 等），
/// 供 UI 按码提示。
class AuthApiException implements Exception {
  const AuthApiException(this.code, this.message, {this.statusCode = 0});

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => '$code: $message';
}

/// 注册/登录成功结果。
class AuthResult {
  const AuthResult({required this.token, required this.user});

  final String token;
  final UserProfile user;
}

/// 账号 REST 客户端：/api/register、/api/login、/api/me。
///
/// 基于 package:http，三端（Web/Windows/Android）通用；
/// [baseUrl] 形如 `http://192.168.1.5:9090`。
class AuthApi {
  AuthApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 注册并登录（注册即登录，服务端直接签发 token）。
  Future<AuthResult> register(
    String baseUrl, {
    required String username,
    required String password,
    String nickname = '',
    String deviceId = '',
  }) async {
    final body = await _post('$baseUrl/api/register', <String, dynamic>{
      'username': username,
      'password': password,
      if (nickname.isNotEmpty) 'nickname': nickname,
      'deviceId': deviceId,
    });
    return _resultFrom(body);
  }

  /// 登录已有账号。
  Future<AuthResult> login(
    String baseUrl, {
    required String username,
    required String password,
    String deviceId = '',
  }) async {
    final body = await _post('$baseUrl/api/login', <String, dynamic>{
      'username': username,
      'password': password,
      'deviceId': deviceId,
    });
    return _resultFrom(body);
  }

  /// 用 token 拉取当前账号资料（会话恢复时校验 token 是否仍有效）。
  Future<UserProfile> me(String baseUrl, String token) async {
    final response = await _send(
      () => _client.get(
        Uri.parse('$baseUrl/api/me'),
        headers: <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw _errorFrom(body, response.statusCode);
    }
    return UserProfile.fromJson((body['user'] as Map).cast<String, dynamic>());
  }

  /// 修改昵称（阶段⑧）。服务端校验 1-24 字符；成功返回新资料。
  Future<UserProfile> updateNickname(
    String baseUrl,
    String token,
    String nickname,
  ) async {
    final body = await _post('$baseUrl/api/nickname', <String, dynamic>{
      'nickname': nickname,
    }, token: token);
    return UserProfile.fromJson((body['user'] as Map).cast<String, dynamic>());
  }

  /// 修改密码（阶段⑧）。旧密码错误 BAD_CREDENTIALS / 新密码弱 WEAK_PASSWORD；
  /// 成功后该用户其他设备会话被吊销，当前 token 保持有效。
  Future<UserProfile> changePassword(
    String baseUrl,
    String token, {
    required String oldPassword,
    required String newPassword,
  }) async {
    final body = await _post('$baseUrl/api/password', <String, dynamic>{
      'oldPassword': oldPassword,
      'newPassword': newPassword,
    }, token: token);
    return UserProfile.fromJson((body['user'] as Map).cast<String, dynamic>());
  }

  /// 执行请求并把底层网络异常统一映射为 NETWORK_ERROR。
  Future<http.Response> _send(Future<http.Response> Function() action) async {
    try {
      return await action();
    } on AuthApiException {
      rethrow;
    } catch (_) {
      throw const AuthApiException(
        'NETWORK_ERROR',
        '无法连接服务器，请确认桌面端已启动、地址与端口正确',
      );
    }
  }

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    String token = '',
  }) async {
    final response = await _send(
      () => _client.post(
        Uri.parse(url),
        headers: <String, String>{
          'Content-Type': 'application/json',
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      ),
    );
    final decoded = _decode(response);
    if (response.statusCode != 200) {
      throw _errorFrom(decoded, response.statusCode);
    }
    return decoded;
  }

  AuthResult _resultFrom(Map<String, dynamic> body) => AuthResult(
    token: body['token'] as String? ?? '',
    user: UserProfile.fromJson((body['user'] as Map).cast<String, dynamic>()),
  );

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // 落到空 map 分支。
    }
    return <String, dynamic>{};
  }

  AuthApiException _errorFrom(Map<String, dynamic> body, int statusCode) {
    final error = body['error'];
    if (error is Map) {
      return AuthApiException(
        error['code'] as String? ?? 'UNKNOWN',
        error['message'] as String? ?? '请求失败',
        statusCode: statusCode,
      );
    }
    return AuthApiException(
      'NETWORK_ERROR',
      '服务不可达或响应异常($statusCode)',
      statusCode: statusCode,
    );
  }

  void close() => _client.close();
}

/// 表单校验规则（与设计文档/服务端一致）：用户名 3-24 位字母数字下划线，密码 ≥ 8 位。
abstract final class AuthValidators {
  static final RegExp _usernamePattern = RegExp(r'^\w{3,24}$');

  static String? username(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) {
      return '请输入用户名';
    }
    if (!_usernamePattern.hasMatch(v)) {
      return '用户名须为 3-24 位字母、数字或下划线';
    }
    return null;
  }

  static String? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) {
      return '请输入密码';
    }
    if (v.length < 8) {
      return '密码至少 8 位';
    }
    return null;
  }

  static String? nickname(String? value) =>
      (value ?? '').trim().length > 24 ? '昵称最多 24 个字符' : null;
}
