import 'dart:math';

import 'lan_ip.dart';
import 'server_probe.dart';

/// 解析结果：可连通的服务器 host 与端口，及是否为 TLS（wss/https）服务。
class ResolvedServer {
  const ResolvedServer({
    required this.host,
    required this.port,
    this.secure = false,
  });

  final String host;
  final int port;

  /// 服务端是否以 TLS 提供（wss/https）；false 为明文（ws/http）。
  final bool secure;
}

/// 解析「host[:port]」；端口缺省使用 [fallbackPort]，格式非法返回 null。
(String, int)? parseHostPort(String input, int fallbackPort) {
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
  var port = fallbackPort;
  if (parts.length == 2) {
    final parsedPort = int.tryParse(parts[1].trim());
    if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
      return null;
    }
    port = parsedPort;
  }
  return (host, port);
}

/// 将 (host, port) 还原为「host[:port]」；端口等于默认端口时省略端口。
String formatHostPort(String host, int port, int defaultPort) =>
    port == defaultPort ? host : '$host:$port';

/// 展开私有 IPv4 所属 /24 网段的 1~254 主机地址（排除自身）；
/// 非私有地址或格式非法返回空（回环/公网/链路本地不做网段扫描）。
List<String> expandSubnet(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) {
    return const [];
  }
  final octets = [for (final part in parts) int.tryParse(part)];
  if (octets.any((o) => o == null || o < 0 || o > 255)) {
    return const [];
  }
  final a = octets[0]!;
  final b = octets[1]!;
  final c = octets[2]!;
  final last = octets[3]!;
  final isPrivate =
      a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
  if (!isPrivate) {
    return const [];
  }
  return [
    for (var i = 1; i <= 254; i++)
      if (i != last) '$a.$b.$c.$i',
  ];
}

/// 服务器地址自动解析器：启动时探测并选出可连通的中继地址。
///
/// 探测顺序：
/// 1. 上次保存的地址（快速路径，通常直接命中）；
/// 2. 本机回环 127.0.0.1（客户端与内置中继同机时）；
/// 3. 浏览器来源主机（Web 端从服务机访问页面时，Uri.base.host 即服务机）；
/// 4. 本机各网卡局域网 IPv4；
/// 5. 各网卡所属 /24 网段扫描（仅私有网段，批内并发，按序早停）。
///
/// 每次探测先 TLS 后明文（[ProbeResult.secure] 随结果返回），避免把
/// TLS 服务误判为明文可达。
class ServerAddressResolver {
  ServerAddressResolver({
    Future<ProbeResult> Function(String host, int port, {Duration timeout})?
    probe,
    Future<List<String>> Function()? listLocalAddresses,
    this.probeTimeout = const Duration(milliseconds: 800),
    this.scanTimeout = const Duration(milliseconds: 400),
    this.scanConcurrency = 64,
  }) : _probe = probe ?? probeServer,
       _listLocalAddresses = listLocalAddresses ?? listLanIpv4;

  final Future<ProbeResult> Function(String host, int port, {Duration timeout})
  _probe;
  final Future<List<String>> Function() _listLocalAddresses;

  /// 优先级候选（保存地址/回环/本机地址）的单次探测超时。
  final Duration probeTimeout;

  /// 网段扫描的单次探测超时（目标在本地二层，失败应快速超时）。
  final Duration scanTimeout;

  /// 网段扫描的并发批大小。
  final int scanConcurrency;

  /// 依次探测候选地址，返回第一个可连通的地址；全部不可达返回 null。
  Future<ResolvedServer?> resolve({
    String? savedAddress,
    required int fallbackPort,
  }) async {
    final parsed = savedAddress == null || savedAddress.isEmpty
        ? null
        : parseHostPort(savedAddress, fallbackPort);
    // 保存过自定义端口则全网段按该端口探测，否则使用默认中继端口。
    final port = parsed?.$2 ?? fallbackPort;

    final localIps = await _listLocalAddresses();
    final tried = <String>{};

    Future<ProbeResult> reachable(String host) async {
      if (tried.contains(host)) {
        return ProbeResult.unreachable;
      }
      tried.add(host);
      return _probe(host, port, timeout: probeTimeout);
    }

    final priority = <String>[
      if (parsed != null) parsed.$1,
      '127.0.0.1',
      if (Uri.base.host.isNotEmpty && Uri.base.host != '127.0.0.1')
        Uri.base.host,
      ...localIps,
    ];
    for (final host in priority) {
      final result = await reachable(host);
      if (result.reachable) {
        return ResolvedServer(host: host, port: port, secure: result.secure);
      }
    }

    final scanHosts = <String>[
      for (final ip in localIps)
        for (final host in expandSubnet(ip))
          if (!tried.contains(host)) host,
    ];
    final found = await _scanFirstReachable(scanHosts, port);
    return found == null
        ? null
        : ResolvedServer(host: found.$1, port: port, secure: found.$2);
  }

  /// 按序分批并发探测，返回首个可连通的 (host, secure)（批内按地址升序优先）。
  Future<(String, bool)?> _scanFirstReachable(
    List<String> hosts,
    int port,
  ) async {
    for (var i = 0; i < hosts.length; i += scanConcurrency) {
      final batch = hosts.sublist(i, min(i + scanConcurrency, hosts.length));
      final results = await Future.wait(<Future<ProbeResult>>[
        for (final host in batch) _probe(host, port, timeout: scanTimeout),
      ]);
      for (var j = 0; j < batch.length; j++) {
        if (results[j].reachable) {
          return (batch[j], results[j].secure);
        }
      }
    }
    return null;
  }
}
