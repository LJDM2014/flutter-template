import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../core/network/lan_ip.dart';
import '../../core/network/relay_status.dart';
import '../../core/network/ws_client.dart';
import '../../core/protocol/message_envelope.dart';
import '../../shared/app_paths.dart';
import 'connection_providers.dart';

/// 连接页：
/// - 手动输入服务器地址（host[:port]）并连接/断开；
/// - 展示本机内置中继服务状态（仅桌面端）与本机局域网地址；
/// - 连接后实时展示在线设备列表（roster）。
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  static const String routePath = AppPaths.connect;

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  late final TextEditingController _addressController;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(
      text: ':${AppConstants.defaultPort}',
    );
    _loadLastAddress();
  }

  Future<void> _loadLastAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(AppConstants.prefKeyServerHost);
    if (!mounted || saved == null || saved.isEmpty) {
      return;
    }
    setState(() {
      _addressController.text = saved;
    });
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  void _toggleConnection() {
    final connection = ref.read(connectionProvider);
    final controller = ref.read(connectionProvider.notifier);
    final phase = connection.conn.phase;
    if (phase == LanConnPhase.connected ||
        phase == LanConnPhase.connecting ||
        phase == LanConnPhase.reconnecting) {
      controller.disconnect();
    } else {
      controller.connect(_addressController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionProvider);
    final phase = connection.conn.phase;
    final isConnectedish = phase != LanConnPhase.disconnected;

    return Scaffold(
      appBar: AppBar(title: const Text('连接')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: <Widget>[
              _ConnectionBanner(state: connection.conn),
              const SizedBox(height: 16),
              Text('服务器地址', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _addressController,
                enabled: !isConnectedish,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: '例如 192.168.1.100:9090',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _toggleConnection(),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _toggleConnection,
                icon: Icon(isConnectedish ? Icons.link_off : Icons.link),
                label: Text(
                  phase == LanConnPhase.connecting
                      ? '连接中…'
                      : isConnectedish
                      ? '断开'
                      : '连接',
                ),
              ),
              const SizedBox(height: 24),
              _RelayStatusCard(),
              const SizedBox(height: 16),
              _LocalAddressSection(defaultPort: AppConstants.defaultPort),
              const SizedBox(height: 16),
              _DeviceListSection(
                devices: connection.devices,
                myDeviceId: ref.watch(deviceIdProvider).value ?? '',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部连接状态横幅（含重连倒计时与错误提示）。
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state});

  final LanConnState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, color, icon) = switch (state.phase) {
      LanConnPhase.connected => ('已连接', Colors.green, Icons.check_circle),
      LanConnPhase.connecting => (
        '连接中…',
        theme.colorScheme.primary,
        Icons.sync,
      ),
      LanConnPhase.reconnecting => (
        state.retryIn == null
            ? '连接断开，正在重连…'
            : '连接断开，${state.retryIn!.inSeconds + 1}s 后重连…',
        theme.colorScheme.tertiary,
        Icons.restart_alt,
      ),
      LanConnPhase.disconnected when state.error != null => (
        state.error!,
        theme.colorScheme.error,
        Icons.error_outline,
      ),
      LanConnPhase.disconnected => (
        '未连接',
        theme.colorScheme.outline,
        Icons.link_off,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// 本机中继服务状态（桌面端展示；Web/移动端为 null 或 unsupported 时隐藏）。
class _RelayStatusCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final status = RelayRuntime.status;
    if (status == null || !status.running) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.dns, color: theme.colorScheme.primary),
        title: Text(
          '本机中继服务运行中 · :${status.port}',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: const Text('局域网内其他设备连接本机地址即可互通'),
        dense: true,
      ),
    );
  }
}

/// 本机局域网地址展示（Web 端为空态）。
class _LocalAddressSection extends StatelessWidget {
  const _LocalAddressSection({required this.defaultPort});

  final int defaultPort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.wifi, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('本机局域网地址', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<String>>(
              future: listLanIpv4(),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final addresses = snapshot.data ?? const <String>[];
                if (addresses.isEmpty) {
                  return Text(
                    '未获取到局域网地址（Web 端仅作为客户端，无需展示）',
                    style: theme.textTheme.bodySmall,
                  );
                }
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final address in addresses)
                      Chip(
                        label: Text('$address:$defaultPort'),
                        labelStyle: theme.textTheme.bodySmall,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 在线设备列表（连接后由 roster 实时刷新）。
class _DeviceListSection extends StatelessWidget {
  const _DeviceListSection({required this.devices, required this.myDeviceId});

  final List<DeviceProfile> devices;
  final String myDeviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.group_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '在线设备 (${devices.length})',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (devices.isEmpty)
              Text(
                myDeviceId.isEmpty ? '连接后此处展示局域网内的在线设备' : '尚未连接，或局域网内暂无其他设备',
                style: theme.textTheme.bodySmall,
              )
            else
              Column(
                children: <Widget>[
                  for (final device in devices)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.devices_other),
                      title: Text(
                        device.nickname.isEmpty
                            ? '设备 ${device.id.substring(0, 8)}'
                            : device.nickname,
                      ),
                      trailing: device.id == myDeviceId
                          ? const Chip(
                              label: Text('本机'),
                              visualDensity: VisualDensity.compact,
                            )
                          : null,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
