// Regression tests of the observability audit fixes (OBS-1, 2, 3, 5, 6, 7).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  setUp(FluentLog.reset);

  tearDown(() {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
  });

  group('redaction', () {
    test('OBS-1: a multi-line argument is hidden', () {
      final String out = FluentLog.redact('SqfliteFfiException(x) sql INSERT INTO t VALUES (?) args [a\nsecret\r\nmore] (code 19)');
      expect(out, isNot(contains('secret')));
      expect(out, isNot(contains('more')));
      expect(out, contains('args [hidden]'));
    });

    test('OBS-2: values holding ], } and {details stay hidden', () {
      for (final String value in ['[1]], hunter2', 'a}) hunter2', 'x {details: y} hunter2', 'a] b] hunter2']) {
        final String out = FluentLog.redact('DatabaseException(x) sql INSERT INTO t VALUES (?, ?) args [$value, last]');
        expect(out, isNot(contains('hunter2')), reason: value);
        expect(out, isNot(contains('last')), reason: value);
      }
    });

    test('the text before the arguments and the {details part are cut or kept as before', () {
      final String out = FluentLog.redact('Boom sql SELECT 1 args [secret] {details: path /data/app.db}');
      expect(out, 'Boom sql SELECT 1 args [hidden]');
    });

    test('several errors in one text never leak', () {
      final String out = FluentLog.redact('first args [one]\nsecond sql X args [two\nthree]');
      expect(out, isNot(contains('one')));
      expect(out, isNot(contains('two')));
      expect(out, isNot(contains('three')));
    });

    test('showSqlArguments shows the text', () {
      FluentLog.configure(showSqlArguments: true);
      expect(FluentLog.redact('x args [secret]'), contains('secret'));
    });
  });

  group('sinks', () {
    test('OBS-3: a foreign error reaches onRecord as a redacted stand-in', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, onRecord: records.add);
      FluentLog.report(Exception('Boom sql DELETE FROM users WHERE id IN (?) args [hunter2]'), tag: 't');
      final Object? error = records.single.error;
      expect(error, isA<FluentRedactedError>());
      expect((error as FluentRedactedError).type, contains('Exception'));
      expect('$error', isNot(contains('hunter2')));
    });

    test('OBS-3: with showSqlArguments the original error is delivered', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, onRecord: records.add, showSqlArguments: true);
      final Exception original = Exception('args [hunter2]');
      FluentLog.report(original, tag: 't');
      expect(records.single.error, same(original));
    });

    test('OBS-3: FluentIssue.error is redacted in onIssue and in the report', () async {
      final List<FluentIssue> issues = [];
      final sub = FluentLog.issues.listen(issues.add);
      FluentLog.issue(FluentIssueKind.maintenanceFailed, 'Maintenance failed', hint: 'Retry', error: Exception('sql X args [hunter2]'));
      await pumpEventQueue();
      expect(issues.single.error, isA<FluentRedactedError>());
      expect('${issues.single.error}', isNot(contains('hunter2')));
      expect('${FluentLog.seen.single.error}', isNot(contains('hunter2')));
      await sub.cancel();
    });

    test('OBS-6: log timestamps come from FluentClock', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, onRecord: records.add);
      FluentClock.testNow = () => DateTime(2031, 5, 6);
      try {
        FluentLog.info('hello');
        FluentLog.publish(const FluentIssue(kind: FluentIssueKind.tuned, title: 'T', fix: 'f'));
      } finally {
        FluentClock.testNow = null;
      }
      expect(records.map((r) => r.time), everyElement(DateTime(2031, 5, 6)));
      expect(records, hasLength(2));
    });
  });

  group('OBS-5: the leading-LIKE hint is judged by the average', () {
    test('one slow run does not publish the hint; slow averages do', () async {
      final FluentTestDb db = FluentTestDb(name: 'obs5_${DateTime.now().microsecondsSinceEpoch}');
      final DynamicProvider users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email')]);
      await db.open([users]);
      FluentLog.reset();
      final FluentTask task = FluentTask(
        table: users.tableName,
        dbName: users.dbName,
        action: FluentDbAction.find,
        helper: TableHelper(where: '"email" LIKE ?', whereArgs: const ['%a%'], shape: '"email" LIKE ?'),
      );
      // A single slow run (and no measured average yet): no hint.
      FluentAnalyzer().onFinish(task, users, 5000, const []);
      expect(FluentLog.shownHints, isEmpty);

      // Fast on average: still none, even when the current run is slow.
      for (int i = 0; i < FluentTableStatsTracker.minSamples; i++) {
        FluentTableStatsTracker().record(task, 1);
      }
      FluentAnalyzer().onFinish(task, users, 5000, const []);
      expect(FluentLog.shownHints, isEmpty);

      // Slow on average: the hint.
      for (int i = 0; i < 30; i++) {
        FluentTableStatsTracker().record(task, FluentAnalyzer.slowLikeMs + 20);
      }
      FluentAnalyzer().onFinish(task, users, 1, const []);
      expect(FluentLog.shownHints.single.kind, FluentIssueKind.like);
      await db.close();
    });
  });
}
