/// 端口探测结果（io 与 Web 实现共用）。
class ProbeResult {
  const ProbeResult({required this.reachable, required this.secure});

  /// 不可达。
  static const ProbeResult unreachable = ProbeResult(
    reachable: false,
    secure: false,
  );

  /// 端口是否可连通。
  final bool reachable;

  /// 服务是否为 TLS（wss/https）；明文可达时为 false。
  final bool secure;
}
