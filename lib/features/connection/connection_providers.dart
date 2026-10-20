import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../settings/nickname_provider.dart';

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

/// 连接页 UI 状态：连接状态 + 在线设备列表。
class ConnectionUiState {
  const ConnectionUiState({
    this.conn = const LanConnState(phase: LanConnPhase.disconnected),
    this.devices = const <DeviceProfile>[],
  });

  final LanConnState conn;
  final List<DeviceProfile> devices;

  ConnectionUiState copyWith({
    LanConnState? conn,
    List<DeviceProfile>? devices,
  }) => ConnectionUiState(
    conn: conn ?? this.conn,
    devices: devices ?? this.devices,
  );
}

/// 连接控制器：管理 LanWsClient 生命周期并聚合 UI 状态。
class ConnectionController extends Notifier<ConnectionUiState> {
  LanWsClient? _client;
  StreamSubscription<LanConnState>? _stateSub;
  StreamSubscription<MessageEnvelope>? _msgSub;

  @override
  ConnectionUiState build() {
    ref.onDispose(_dispose);
    return const ConnectionUiState();
  }

  /// 连接到「host[:port]」形式的地址；保存为上次使用的地址。
  Future<void> connect(String addressInput) async {
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
    final (host, port) = parsed;

    final deviceId = await ref.read(deviceIdProvider.future);
    final nickname = ref.read(nicknameProvider).value ?? '未命名设备';

    await _dispose();
    final client = LanWsClient(deviceId: deviceId, nickname: nickname);
    _client = client;
    ref.read(wsClientProvider.notifier).attach(client);
    _stateSub = client.states.listen((s) {
      state = state.copyWith(conn: s);
    });
    _msgSub = client.messages.listen(_onMessage);
    await client.connect(Uri.parse('ws://$host:$port/ws'));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.prefKeyServerHost,
      port == AppConstants.defaultPort ? host : '$host:$port',
    );
  }

  Future<void> disconnect() async {
    ref.read(wsClientProvider.notifier).detach();
    await _client?.disconnect();
    state = state.copyWith(
      conn: const LanConnState(phase: LanConnPhase.disconnected),
      devices: const <DeviceProfile>[],
    );
  }

  void _onMessage(MessageEnvelope envelope) {
    if (envelope.type != MessageType.roster) {
      return;
    }
    final raw = envelope.payload['devices'];
    if (raw is! List) {
      return;
    }
    state = state.copyWith(
      devices: <DeviceProfile>[
        for (final item in raw.whereType<Map>())
          DeviceProfile.fromJson(item.cast<String, dynamic>()),
      ],
    );
  }

  /// 解析 host[:port]，缺省端口使用默认中继端口。
  (String, int)? _parseAddress(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final parts = trimmed.split(':');
    if (parts.length > 2) {
      return null;
    }
    final host = parts[0].trim();
    if (host.isEmpty) {
      return null;
    }
    var port = AppConstants.defaultPort;
    if (parts.length == 2) {
      final parsedPort = int.tryParse(parts[1].trim());
      if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
        return null;
      }
      port = parsedPort;
    }
    return (host, port);
  }

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
