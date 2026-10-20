import 'package:flutter_template/core/network/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackoffStrategy 指数退避', () {
    test('无抖动时严格按 2 的幂增长', () {
      final strategy = BackoffStrategy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(minutes: 1),
        jitterRatio: 0,
      );
      expect(strategy.delayFor(0), const Duration(seconds: 1));
      expect(strategy.delayFor(1), const Duration(seconds: 2));
      expect(strategy.delayFor(2), const Duration(seconds: 4));
      expect(strategy.delayFor(3), const Duration(seconds: 8));
    });

    test('延迟封顶不超过 maxDelay', () {
      final strategy = BackoffStrategy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
        jitterRatio: 0,
      );
      expect(strategy.delayFor(5), const Duration(seconds: 30));
      expect(strategy.delayFor(20), const Duration(seconds: 30));
    });

    test('达到 maxAttempts 后停止重连（返回 null）', () {
      final strategy = BackoffStrategy(
        baseDelay: const Duration(milliseconds: 100),
        maxAttempts: 3,
        jitterRatio: 0,
      );
      expect(strategy.delayFor(0), isNotNull);
      expect(strategy.delayFor(2), isNotNull);
      expect(strategy.delayFor(3), isNull);
      expect(strategy.delayFor(10), isNull);
    });

    test('无限重试模式下永不返回 null', () {
      final strategy = BackoffStrategy(jitterRatio: 0);
      for (var attempt = 0; attempt < 40; attempt++) {
        expect(strategy.delayFor(attempt), isNotNull);
      }
    });

    test('抖动使延迟在理论值 ±比例内波动', () {
      final strategy = BackoffStrategy(
        baseDelay: const Duration(seconds: 10),
        maxDelay: const Duration(minutes: 10),
        jitterRatio: 0.2,
      );
      final theoretical = const Duration(seconds: 10).inMilliseconds;
      for (var i = 0; i < 50; i++) {
        final delay = strategy.delayFor(0)!;
        expect(delay.inMilliseconds, inInclusiveRange(
          (theoretical * 0.8).floor(),
          (theoretical * 1.2).ceil(),
        ));
      }
    });
  });
}
