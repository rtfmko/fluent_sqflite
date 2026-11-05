import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  group('FluentClock', () {
    tearDown(() => FluentClock.testNow = null);

    test('uses the wall clock by default', () {
      expect(FluentClock.isReplaced, isFalse);
      final before = DateTime.now();
      final now = FluentClock.now();
      final after = DateTime.now();
      expect(now.isBefore(before), isFalse);
      expect(now.isAfter(after), isFalse);
      expect(FluentClock.millis, greaterThanOrEqualTo(before.millisecondsSinceEpoch));
    });

    test('a replaced clock drives now and millis, and null restores the wall clock', () {
      final fixed = DateTime.utc(2030, 1, 1, 12);
      FluentClock.testNow = () => fixed;
      expect(FluentClock.isReplaced, isTrue);
      expect(FluentClock.now(), fixed);
      expect(FluentClock.millis, fixed.millisecondsSinceEpoch);
      FluentClock.testNow = null;
      expect(FluentClock.isReplaced, isFalse);
      expect(FluentClock.now().year, isNot(2030));
    });

    test('the replaced function is called on every read (it can move)', () {
      int calls = 0;
      FluentClock.testNow = () => DateTime.utc(2030).add(Duration(seconds: calls++));
      expect(FluentClock.now(), DateTime.utc(2030));
      expect(FluentClock.now(), DateTime.utc(2030, 1, 1, 0, 0, 1));
      expect(FluentClock.millis, DateTime.utc(2030, 1, 1, 0, 0, 2).millisecondsSinceEpoch);
    });
  });
}
