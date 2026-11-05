import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  group('fluentRetryDelay', () {
    test('doubles with every attempt, within the jitter band of 50 % to 150 %', () {
      const base = Duration(seconds: 1);
      for (int attempt = 0; attempt < 8; attempt++) {
        final nominal = base.inMilliseconds * (1 << attempt);
        for (int i = 0; i < 50; i++) {
          final d = fluentRetryDelay(base, attempt).inMilliseconds;
          expect(d, greaterThanOrEqualTo((nominal * 0.5).floor() - 1), reason: 'attempt $attempt');
          expect(d, lessThanOrEqualTo((nominal * 1.5).ceil() + 1), reason: 'attempt $attempt');
        }
      }
    });

    test('is capped at the maximum', () {
      expect(fluentMaxRetryDelay, const Duration(hours: 1));
      for (int i = 0; i < 20; i++) {
        expect(fluentRetryDelay(const Duration(minutes: 30), 10), fluentMaxRetryDelay);
        expect(fluentRetryDelay(const Duration(seconds: 1), 30), fluentMaxRetryDelay);
      }
    });

    test('a huge or negative attempt number does not overflow', () {
      expect(fluentRetryDelay(const Duration(seconds: 1), 1000), fluentMaxRetryDelay);
      final negative = fluentRetryDelay(const Duration(seconds: 2), -5);
      expect(negative.inMilliseconds, inInclusiveRange(1000 - 1, 3000 + 1)); // treated as attempt 0
    });

    test('a zero base gives no delay', () {
      expect(fluentRetryDelay(Duration.zero, 3), Duration.zero);
    });

    test('the jitter really varies', () {
      final delays = {for (int i = 0; i < 30; i++) fluentRetryDelay(const Duration(seconds: 10), 2).inMicroseconds};
      expect(delays.length, greaterThan(1));
    });
  });

  group('fluentRetryCanHelp', () {
    FluentSyncException status(int? code) => FluentSyncException('x', statusCode: code);

    test('server errors, timeouts, rate limits and missing status codes are worth retrying', () {
      expect(fluentRetryCanHelp(status(500)), isTrue);
      expect(fluentRetryCanHelp(status(503)), isTrue);
      expect(fluentRetryCanHelp(status(599)), isTrue);
      expect(fluentRetryCanHelp(status(408)), isTrue);
      expect(fluentRetryCanHelp(status(429)), isTrue);
      expect(fluentRetryCanHelp(status(null)), isTrue);
      expect(fluentRetryCanHelp(status(302)), isTrue);
      expect(fluentRetryCanHelp(status(399)), isTrue);
    });

    test('client errors will not change by retrying', () {
      for (final int code in [400, 401, 403, 404, 409, 410, 422, 499]) {
        expect(fluentRetryCanHelp(status(code)), isFalse, reason: '$code');
      }
    });

    test('errors that are no sync exception (network, parsing) are retried', () {
      expect(fluentRetryCanHelp(Exception('socket')), isTrue);
      expect(fluentRetryCanHelp(null), isTrue);
      expect(fluentRetryCanHelp('text'), isTrue);
      expect(fluentRetryCanHelp(FluentConfigException('x')), isTrue);
    });
  });
}
