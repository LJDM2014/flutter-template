import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../core/network/server_resolver.dart';
import '../../core/protocol/message_envelope.dart';
import '../connection/connection_providers.dart';
import 'auth_api.dart';

/// 认证阶段：启动恢复中 / 未登录 / 已登录。
enum AuthPhase { loading, loggedOut, loggedIn }

/// 认证状态快照（路由守卫与连接层消费）。
class AuthState {
  const AuthState({required this.phase, this.user, this.token = ''});

  final AuthPhase phase;
  final UserProfile? user;
  final String token;

  bool get isAuthenticated => phase == AuthPhase.loggedIn && user != null;

  /// 展示名：昵称为空时回退用户名。
  String get displayName {
    final u = user;
    if (u == null) {
      return '';
    }
    return u.nickname.isNotEmpty ? u.nickname : u.username;
  }
}

/// 认证控制器：
/// - 启动时从 shared_preferences 恢复 token 与账号资料；已保存服务器地址时
///   先经 /api/me 校验，token 失效即清会话转登录页（阶段⑤「登录即连接」前置）；
/// - 注册/登录成功后持久化会话；
/// - 登出时清空本地会话并断开 WS；
/// - WS authFailed（token 失效/被踢）时自动登出，路由守卫随状态刷新转登录页。
class AuthController extends Notifier<AuthState> {
  final AuthApi _api = AuthApi();

  @override
  AuthState build() {
    unawaited(_restore());
    return const AuthState(phase: AuthPhase.loading);
  }

  /// 启动恢复：本地有 token 时先经 /api/me 校验再进入 loggedIn。
  ///
  /// - token 失效（INVALID_TOKEN）：清空本地会话，转登录页；
  /// - 服务器不可达 / 校验超时：乐观恢复为 loggedIn（可离线查看本地历史），
  ///   连接层重试失败会给到明确提示。
  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConstants.prefKeyAuthToken);
    final userId = prefs.getString(AppConstants.prefKeyAuthUserId);
    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      state = const AuthState(phase: AuthPhase.loggedOut);
      return;
    }
    final savedHost = prefs.getString(AppConstants.prefKeyServerHost) ?? '';
    if (savedHost.isEmpty) {
      // 无服务器地址可校验：保持乐观恢复，由 WS authFailed 兜底。
      state = AuthState(
        phase: AuthPhase.loggedIn,
        user: _localUser(prefs, userId),
        token: token,
      );
      return;
    }
    try {
      final profile = await _api
          .me(_baseUrl(savedHost), token)
          .timeout(const Duration(seconds: 3));
      // 校验通过：以服务端资料为准（昵称可能已被其他设备更新）。
      state = AuthState(phase: AuthPhase.loggedIn, user: profile, token: token);
    } on AuthApiException catch (error) {
      if (error.code == 'INVALID_TOKEN') {
        await _clearSession(prefs);
        state = const AuthState(phase: AuthPhase.loggedOut);
        return;
      }
      state = AuthState(
        phase: AuthPhase.loggedIn,
        user: _localUser(prefs, userId),
        token: token,
      );
    } catch (_) {
      // 校验超时等异常：乐观恢复，不阻塞进入应用。
      state = AuthState(
        phase: AuthPhase.loggedIn,
        user: _localUser(prefs, userId),
        token: token,
      );
    }
  }

  UserProfile _localUser(SharedPreferences prefs, String userId) => UserProfile(
    id: userId,
    username: prefs.getString(AppConstants.prefKeyAuthUsername) ?? '',
    nickname: prefs.getString(AppConstants.prefKeyAuthNickname) ?? '',
  );

  /// 注册并登录（注册即登录）。失败抛 [AuthApiException] 供 UI 提示。
  Future<void> register({
    required String address,
    required String username,
    required String password,
    String nickname = '',
  }) async {
    final deviceId = await ref.read(deviceIdProvider.future);
    final result = await _api.register(
      _baseUrl(address),
      username: username,
      password: password,
      nickname: nickname,
      deviceId: deviceId,
    );
    await _applySession(result);
  }

  /// 登录。失败抛 [AuthApiException] 供 UI 提示。
  Future<void> login({
    required String address,
    required String username,
    required String password,
  }) async {
    final deviceId = await ref.read(deviceIdProvider.future);
    final result = await _api.login(
      _baseUrl(address),
      username: username,
      password: password,
      deviceId: deviceId,
    );
    await _applySession(result);
  }

  /// 修改昵称（阶段⑧）：服务端更新后同步本地持久化与状态。
  /// 失败抛 [AuthApiException]（INVALID_NICKNAME / INVALID_TOKEN / NETWORK_ERROR）。
  Future<void> changeNickname(String nickname) async {
    final token = state.token;
    if (token.isEmpty) {
      throw const AuthApiException('INVALID_TOKEN', '未登录');
    }
    final savedHost = await _savedServerHost();
    final profile = await _api.updateNickname(
      _baseUrl(savedHost),
      token,
      nickname,
    );
    await _applyProfile(profile);
  }

  /// 修改密码（阶段⑧）：成功后当前设备会话保持，其他设备被服务端吊销。
  /// 失败抛 [AuthApiException]（BAD_CREDENTIALS / WEAK_PASSWORD 等）。
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final token = state.token;
    if (token.isEmpty) {
      throw const AuthApiException('INVALID_TOKEN', '未登录');
    }
    final savedHost = await _savedServerHost();
    final profile = await _api.changePassword(
      _baseUrl(savedHost),
      token,
      oldPassword: oldPassword,
      newPassword: newPassword,
    );
    await _applyProfile(profile);
  }

  /// 已保存的服务器地址；缺失时按网络错误提示（设置页场景必然已连接过）。
  Future<String> _savedServerHost() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(AppConstants.prefKeyServerHost) ?? '';
    if (host.isEmpty) {
      throw const AuthApiException('NETWORK_ERROR', '尚未保存服务器地址，请先连接一次中继');
    }
    return host;
  }

  /// 服务端资料变更后同步本地持久化与会话状态。
  Future<void> _applyProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyAuthUsername, profile.username);
    await prefs.setString(AppConstants.prefKeyAuthNickname, profile.nickname);
    state = AuthState(
      phase: AuthPhase.loggedIn,
      user: profile,
      token: state.token,
    );
  }

  /// 主动登出：断开 WS、清空本地会话。
  Future<void> signOut() async {
    await ref.read(connectionProvider.notifier).disconnect();
    final prefs = await SharedPreferences.getInstance();
    await _clearSession(prefs);
    state = const AuthState(phase: AuthPhase.loggedOut);
  }

  /// WS 鉴权失败终态回调：清空本地会话（不断开——服务端已拒绝并关闭连接）。
  Future<void> onAuthFailed() async {
    final prefs = await SharedPreferences.getInstance();
    await _clearSession(prefs);
    state = const AuthState(phase: AuthPhase.loggedOut);
  }

  /// 清空本地持久化的登录会话（token + 账号资料）。
  Future<void> _clearSession(SharedPreferences prefs) async {
    await prefs.remove(AppConstants.prefKeyAuthToken);
    await prefs.remove(AppConstants.prefKeyAuthUserId);
    await prefs.remove(AppConstants.prefKeyAuthUsername);
    await prefs.remove(AppConstants.prefKeyAuthNickname);
  }

  Future<void> _applySession(AuthResult result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyAuthToken, result.token);
    await prefs.setString(AppConstants.prefKeyAuthUserId, result.user.id);
    await prefs.setString(
      AppConstants.prefKeyAuthUsername,
      result.user.username,
    );
    await prefs.setString(
      AppConstants.prefKeyAuthNickname,
      result.user.nickname,
    );
    state = AuthState(
      phase: AuthPhase.loggedIn,
      user: result.user,
      token: result.token,
    );
  }

  /// 「host[:port]」→「http://host[:port]」；缺省端口补默认值 9090，
  /// 避免「127.0.0.1」这类输入落到 80 端口被拒绝。
  String _baseUrl(String address) {
    final trimmed = address.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final parsed = parseHostPort(trimmed, AppConstants.defaultPort);
    if (parsed == null) {
      throw const FormatException('地址格式无效，应为 host[:port]');
    }
    final (host, port) = parsed;
    return 'http://$host:$port';
  }
}

final NotifierProvider<AuthController, AuthState> authProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
