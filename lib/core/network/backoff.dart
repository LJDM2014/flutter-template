import 'dart:math';

/// 指数退避重连策略（纯逻辑，可单元测试）。
///
/// 延迟序列：base * 2^attempt，上限 [maxDelay]，并附加 ±[jitterRatio] 抖动，
/// 避免大量客户端同时重连造成惊群。
class BackoffStrategy {
  BackoffStrategy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterRatio = 0.2,
    this.maxAttempts,
  }) : assert(jitterRatio >= 0 && jitterRatio <= 1),
       assert(maxAttempts == null || maxAttempts > 0);

  final Duration baseDelay;
  final Duration maxDelay;

  /// 抖动比例（0~1），实际延迟在理论值 ±该比例内随机。
  final double jitterRatio;

  /// 最大尝试次数；null 表示无限重试。
  final int? maxAttempts;

  /// 第 [attempt] 次（从 0 计）失败后的等待时长。
  ///
  /// 超过 [maxAttempts] 返回 null（停止重连）。
  Duration? delayFor(int attempt) {
    final max = maxAttempts;
    if (max != null && attempt >= max) {
      return null;
    }
    final doubled = baseDelay * (1 << attempt.clamp(0, 30));
    var delay = doubled > maxDelay ? maxDelay : doubled;
    if (jitterRatio > 0) {
      final jitterMs = delay.inMilliseconds * jitterRatio;
      final offset = (jitterMs * (2 * _random.nextDouble() - 1)).round().clamp(
        -delay.inMilliseconds ~/ 2,
        delay.inMilliseconds ~/ 2,
      );
      delay = Duration(milliseconds: delay.inMilliseconds + offset);
    }
    if (delay < Duration.zero) {
      delay = Duration.zero;
    }
    return delay;
  }

  final Random _random = Random();
}
