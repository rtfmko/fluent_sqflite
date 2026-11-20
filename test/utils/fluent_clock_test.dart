import 'dart:async';

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

    test('a clock move runs due timers in the zone they were created in, never in the zone of the caller', () async {
      // Crud fuzz seed 57345: a test moved the clock inside a nested transaction; the trash purge ran in that zone,
      // joined the transaction with a savepoint of its own and released it out of order ("no such savepoint").
      final Object key = Object();
      DateTime now = DateTime.utc(2030);
      FluentClock.testNow = () => now;
      final List<Object?> seen = [];
      final FluentClockTimer timer = FluentClockTimer(const Duration(hours: 1), () async => seen.add(Zone.current[key]));
      final FluentClockAlarm alarm = FluentClockAlarm(DateTime.utc(2030, 1, 1, 1).millisecondsSinceEpoch, () => seen.add(Zone.current[key]));
      addTearDown(timer.cancel);
      addTearDown(alarm.cancel);
      runZoned(() {
        now = now.add(const Duration(hours: 2));
        FluentClock.testNow = () => now;
      }, zoneValues: {key: 'caller'});
      await Future<void>.delayed(Duration.zero);
      expect(seen, [null, null], reason: 'both ran, outside the caller zone');
    });
  });
}
