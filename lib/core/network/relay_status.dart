/// 中继服务启动结果（io 实现与 Web 桩共用）。
class RelayStatus {
  const RelayStatus._({
    required this.running,
    this.port,
    this.error,
    this.secure = false,
  });

  const RelayStatus.running(this.port, {this.secure = false})
    : running = true,
      error = null;

  const RelayStatus.failure(String error)
      : this._(running: false, error: error);

  const RelayStatus.unsupported()
      : this._(running: false, error: '当前平台不支持内置中继服务');

  final bool running;
  final int? port;
  final String? error;

  /// 是否以 TLS（wss/https）提供；仅 running 时有意义。
  final bool secure;

  @override
  String toString() => running
      ? 'RelayStatus(running${secure ? ', tls' : ''} :$port)'
      : 'RelayStatus(error: $error)';
}

/// 中继服务运行时快照（由平台启动逻辑写入，连接页读取展示）。
///
/// MVP 内服务随应用启动/常驻，不做动态变更，静态持有即可。
abstract final class RelayRuntime {
  static RelayStatus? status;
}
