import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/network/server_probe.dart';
import '../../core/network/server_resolver.dart';
import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../auth/auth_providers.dart';

/// 设备唯一 ID：首次生成后持久化，用于 hello 注册与消息去重。
final FutureProvider<String> deviceIdProvider = FutureProvider<String>((
  ref,
) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(AppConstants.prefKeyDeviceId);
  if (saved != null && saved.isNotEmpty) {
    return saved;
  }
  final id = const Uuid().v4();
  await prefs.setString(AppConstants.prefKeyDeviceId, id);
  return id;
});

/// 持有当前活跃的 WS 客户端（未连接为 null），供聊天等业务层订阅。
class ActiveWsClient extends Notifier<LanWsClient?> {
  @override
  LanWsClient? build() => null;

  void attach(LanWsClient client) => state = client;
  void detach() => state = null;
}

final NotifierProvider<ActiveWsClient, LanWsClient?> wsClientProvider =
    NotifierProvider<ActiveWsClient, LanWsClient?>(ActiveWsClient.new);

/// 连接页 UI 状态：连接状态 + 在线用户列表。
class ConnectionUiState {
  const ConnectionUiState({
    this.conn = const LanConnState(phase: LanConnPhase.disconnected),
    this.devices = const <UserProfile>[],
    this.autoConnecting = false,
  });

  final LanConnState conn;

  /// 在线成员（用户身份；阶段③接入账号体系后由「设备」语义切换为「用户」）。
  final List<UserProfile> devices;

  /// 正在执行「登录即连接」的自动连接（地址解析 + 建连）。
  final bool autoConnecting;

  ConnectionUiState copyWith({
    LanConnState? conn,
    List<UserProfile>? devices,
    bool? autoConnecting,
  }) => ConnectionUiState(
    conn: conn ?? this.conn,
    devices: devices ?? this.devices,
    autoConnecting: autoConnecting ?? this.autoConnecting,
  );
}

/// 连接控制器：管理 LanWsClient 生命周期并聚合 UI 状态。
///
/// 阶段⑤「登录即连接」：监听认证状态，从未登录变为已登录（登录/注册成功、
/// 启动恢复会话）且未连接时，自动解析服务器地址并发起连接。
class ConnectionController extends Notifier<ConnectionUiState> {
  ConnectionController({ServerAddressResolver? resolver})
    : _resolver = resolver ?? ServerAddressResolver();

  LanWsClient? _client;
  StreamSubscription<LanConnState>? _stateSub;
  StreamSubscription<MessageEnvelope>? _msgSub;
  final ServerAddressResolver _resolver;
  bool _autoConnecting = false;

  @override
  ConnectionUiState build() {
    ref.onDispose(_dispose);
    // 登录即连接：认证从未登录变为已登录时自动连接。
    ref.listen<AuthState>(authProvider, (previous, next) {
      final wasAuthenticated = previous?.isAuthenticated ?? false;
      if (!wasAuthenticated && next.isAuthenticated) {
        unawaited(autoConnect());
      }
    });
    // 控制器创建时认证已完成恢复（如启动即进入消息页）：补一次检查。
    if (ref.read(authProvider).isAuthenticated) {
      unawaited(autoConnect());
    }
    return const ConnectionUiState();
  }

  /// 启动时自动检测服务器地址：
  /// 探测上次保存的地址，不可达时自动寻找可连通地址并覆盖持久化，
  /// 从而「去掉不通的旧地址、换用可连通地址」。
  ///
  /// 仅在未连接状态下执行；返回解析结果，全部候选均不可达时返回 null。
  Future<ResolvedServer?> autoResolveAddress() async {
    if (state.conn.phase != LanConnPhase.disconnected) {
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(AppConstants.prefKeyServerHost);
    final resolved = await _resolver.resolve(
      savedAddress: saved,
      fallbackPort: AppConstants.defaultPort,
    );
    if (resolved == null) {
      return null;
    }
    final formatted = formatHostPort(
      resolved.host,
      resolved.port,
      AppConstants.defaultPort,
    );
    final savedSecure =
        prefs.getBool(AppConstants.prefKeyServerSecure) ?? false;
    if (saved != formatted || savedSecure != resolved.secure) {
      // 旧地址不可达（或首次自动发现）：以可连通地址覆盖（含 TLS 标记）。
      await prefs.setString(AppConstants.prefKeyServerHost, formatted);
      await prefs.setBool(AppConstants.prefKeyServerSecure, resolved.secure);
    }
    return resolved;
  }

  /// 「登录即连接」：登录成功或启动恢复会话后自动解析地址并连接。
  ///
  /// 未登录、已连接/正在连接、或已在自动连接中时跳过；全部候选地址不可达时
  /// 在连接状态中给出错误提示（消息页空态与连接页横幅均会展示）。
  Future<void> autoConnect() async {
    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated) {
      return;
    }
    if (state.conn.phase != LanConnPhase.disconnected || _autoConnecting) {
      return;
    }
    _autoConnecting = true;
    state = state.copyWith(autoConnecting: true);
    try {
      final resolved = await autoResolveAddress();
      if (resolved == null) {
        state = state.copyWith(
          conn: const LanConnState(
            phase: LanConnPhase.disconnected,
            error: '未检测到可连通的服务器，请确认桌面端中继已启动',
          ),
        );
        return;
      }
      // 解析期间用户可能已手动连接，避免重复建连。
      if (state.conn.phase != LanConnPhase.disconnected) {
        return;
      }
      await connect(
        formatHostPort(resolved.host, resolved.port, AppConstants.defaultPort),
        secure: resolved.secure,
      );
    } finally {
      _autoConnecting = false;
      state = state.copyWith(autoConnecting: false);
    }
  }

  /// 连接到「host[:port]」形式的地址；保存为上次使用的地址（含 TLS 标记）。
  ///
  /// 需先登录：WS 接入携带账号 token（未登录时给出错误提示）。
  /// [secure] 为 null 时自动探测（TLS 优先），决定 wss/https 还是 ws/http。
  Future<void> connect(String addressInput, {bool? secure}) async {
    final parsed = _parseAddress(addressInput);
    if (parsed == null) {
      state = state.copyWith(
        conn: const LanConnState(
          phase: LanConnPhase.disconnected,
          error: '地址格式无效，应为 host[:port]',
        ),
      );
      return;
    }
    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated) {
      state = state.copyWith(
        conn: const LanConnState(
          phase: LanConnPhase.disconnected,
          error: '请先登录账号',
        ),
      );
      return;
    }
    final (host, port) = parsed;
    var isSecure = secure;
    if (isSecure == null) {
      final result = await probeServer(host, port);
      isSecure = result.reachable && result.secure;
    }
    final user = auth.user!;
    final deviceId = await ref.read(deviceIdProvider.future);

    await _dispose();
    // userId/token 来自登录会话；deviceId 用于同设备重登时服务端踢旧会话。
    final client = LanWsClient(
      userId: user.id,
      deviceId: deviceId,
      nickname: auth.displayName,
      token: auth.token,
    );
    _client = client;
    ref.read(wsClientProvider.notifier).attach(client);
    _stateSub = client.states.listen((s) {
      state = state.copyWith(conn: s);
      if (s.phase == LanConnPhase.authFailed) {
        // token 失效/被踢：清空本地会话，路由守卫将转登录页。
        unawaited(ref.read(authProvider.notifier).onAuthFailed());
      }
    });
    _msgSub = client.messages.listen(_onMessage);
    await client.connect(
      Uri.parse('${isSecure ? 'wss' : 'ws'}://$host:$port/ws'),
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.prefKeyServerHost,
      formatHostPort(host, port, AppConstants.defaultPort),
    );
    await prefs.setBool(AppConstants.prefKeyServerSecure, isSecure);
  }

  Future<void> disconnect() async {
    ref.read(wsClientProvider.notifier).detach();
    await _client?.disconnect();
    state = state.copyWith(
      conn: const LanConnState(phase: LanConnPhase.disconnected),
      devices: const <UserProfile>[],
    );
  }

  void _onMessage(MessageEnvelope envelope) {
    if (envelope.type != MessageType.roster) {
      return;
    }
    // 兼容旧服务端 devices 键，统一从 payload 解析成员列表。
    state = state.copyWith(devices: rosterUsersFromPayload(envelope.payload));
  }

  /// 解析 host[:port]，缺省端口使用默认中继端口。
  (String, int)? _parseAddress(String input) =>
      parseHostPort(input, AppConstants.defaultPort);

  /// 仅做与 ref 无关的清理；onDispose 回调中不允许使用 ref。
  Future<void> _dispose() async {
    await _stateSub?.cancel();
    await _msgSub?.cancel();
    _stateSub = null;
    _msgSub = null;
    await _client?.disconnect();
    _client = null;
  }
}

final NotifierProvider<ConnectionController, ConnectionUiState>
connectionProvider = NotifierProvider<ConnectionController, ConnectionUiState>(
  ConnectionController.new,
);
