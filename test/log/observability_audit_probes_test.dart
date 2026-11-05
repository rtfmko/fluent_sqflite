// Observability audit (errors, logging, issues, stats). Tests named OBS-n demonstrate a finding and are written as the
// expected correct behaviour: they FAIL while the finding stands. The other tests confirm risky spots that are correct.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  setUp(() {
    FluentLog.reset();
  });

  tearDown(() {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
  });

  group('redaction', () {
    test('OBS-1: SQL arguments that span several lines are hidden', () {
      // sqflite prints `args [v1, v2]` with each value as its toString(): a multi-line value breaks the `.` match.
      const String text = 'SqfliteFfiException(constraint, UNIQUE constraint failed: notes.id) sql INSERT INTO notes VALUES (?) '
          'args [first line\nsecret second line]';
      expect(FluentLog.redact(text), isNot(contains('secret')));
    });

    test('OBS-2: an argument holding "]" is hidden to the end of the argument list', () {
      // args ['[1]', 'hunter2'] prints as `[[1]], hunter2]`: the match stops at the first `]` followed by a comma.
      expect(FluentLog.redact('SqfliteFfiException(x) sql INSERT INTO t VALUES (?, ?) args [[1]], hunter2] (code 19)'), isNot(contains('hunter2')));
    });

    test('sql() hides its arguments unless showSqlArguments is on (checked, fine)', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, level: FluentLogLevel.sql, onRecord: records.add);
      FluentLog.sql('SELECT * FROM users WHERE email = ?', arguments: ['hunter2']);
      expect(records.single.message, isNot(contains('hunter2')));
      expect(records.single.message, contains('1 hidden'));
    });
  });

  group('sinks', () {
    test('OBS-3: the error handed to onRecord does not carry SQL arguments', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, onRecord: records.add);
      // A raw sqflite error reported without a FluentException (e.g. a maintenance failure): its text holds the arguments.
      FluentLog.report(Exception('SqfliteFfiException(constraint) sql DELETE FROM users WHERE id IN (?) args [hunter2]'), tag: 'FluentDb:purge');
      expect(records, hasLength(1));
      expect('${records.single.error}', isNot(contains('hunter2')));
    });

    test('OBS-4: the database path is not in the close record unless showSqlArguments is on', () async {
      final FluentTestDb db = FluentTestDb(name: 'obs_path_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final DynamicProvider items = DynamicProvider('items', () => [FluentDbColumn.integer('id')]);
      await db.open([items]);
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(console: false, level: FluentLogLevel.debug, onRecord: records.add);

      await db.close();

      final List<FluentLogRecord> closed = records.where((r) => r.message == 'Database closed successfully').toList();
      expect(closed, isNotEmpty, reason: 'the close is logged at debug level');
      for (final FluentLogRecord r in closed) {
        expect('${r.context}', isNot(contains('obs_path_')), reason: 'paths are hidden unless showSqlArguments (doc/errors-and-logging.md)');
      }
    });
  });

  group('issues (checked, fine)', () {
    test('a hint or warning is reported once per run, numbers in its title ignored', () {
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.ignoredCall, title: 'Skipped 3 rows', fix: 'Pass valid rows'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.ignoredCall, title: 'Skipped 4 rows', fix: 'Pass valid rows'));
      expect(FluentLog.seen, hasLength(1));
    });

    test('an automatic change is reported every time', () {
      for (int i = 0; i < 3; i++) {
        FluentLog.publish(const FluentIssue(kind: FluentIssueKind.tuned, title: 'Setting applied', fix: 'nothing'));
      }
      expect(FluentLog.seen.where((i) => i.kind == FluentIssueKind.tuned), hasLength(3));
    });

    test('a muted prefix hides every issue of that kind from the report and the stream', () {
      FluentLog.configure(mute: {'ignoredCall:*'});
      final List<FluentIssue> streamed = [];
      final sub = FluentLog.issues.listen(streamed.add);
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.ignoredCall, title: 'Skipped', fix: 'x', table: 'users', subject: 'a'));
      expect(FluentLog.seen, isEmpty);
      expect(streamed, isEmpty);
      sub.cancel();
    });
  });

  group('stats (checked, fine)', () {
    test('changes are taken once and come back after a failed write', () {
      final FluentTableStatsTracker tracker = FluentTableStatsTracker();
      tracker.forget();
      tracker.recordMapping('stats_db_a', 'users', 12.5);
      expect(tracker.dirtyDatabases, contains('stats_db_a'));

      final changes = tracker.takeChanges('stats_db_a');
      expect(changes.upserts, hasLength(1));
      expect(tracker.dirtyDatabases, isNot(contains('stats_db_a')));

      tracker.restoreChanges('stats_db_a', changes);
      expect(tracker.dirtyDatabases, contains('stats_db_a'));
      tracker.forget();
    });

    test('rows unused for longer than the retention are dropped when loaded', () {
      final FluentTableStatsTracker tracker = FluentTableStatsTracker();
      tracker.forget();
      final int oldMillis = DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch;
      tracker.load('stats_db_b', [
        {'key': 'users|find|id=?', 'tbl': 'users', 'action': 'find', 'shape': 'id=?', 'avg_ms': 4.0, 'avg_rows': 1.0, 'samples': 9, 'failures': 0, 'last_used': oldMillis},
      ]);
      expect(tracker.costs(db: 'stats_db_b'), isEmpty);
      expect(tracker.takeChanges('stats_db_b').deletes, contains('users|find|id=?'));
    });
  });
}
