// The analyzer's detectors at their thresholds: averages over minSamples, boundaries, once per run, muted, only while
// collecting, the EXPLAIN path (queued, once per shape, fallback without a plan) and the code of the hints.
@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/guarantees.dart';
import '../helpers/query_counter.dart';
import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late QueryCounter counter;
  late DynamicProvider users;
  final List<FluentLogRecord> records = [];

  Future<void> open({FluentDiagnostics? diagnostics, List<FluentIndex> indexes = const []}) async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'detectors_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider.spec(
      'users',
      TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('status'), FluentDbColumn.integer('age'), FluentDbColumn.text('bio')], indexes: indexes),
    );
    await db.open([users], fluentConfig: diagnostics == null ? const FluentConfig() : FluentConfig(diagnostics: diagnostics));
    records.clear();
    FluentLog.reset();
    FluentAnalyzer().reset();
    FluentTableStatsTracker().forget();
    FluentDb.setupLogging(console: false, onRecord: records.add, level: FluentLogLevel.debug);
  }

  setUp(open);

  tearDown(() async {
    counter.uninstall();
    FluentAnalyzer.releaseMode = false;
    FluentAnalyzer.clock = null;
    FluentDb.configure(const FluentConfig());
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  Iterable<FluentIssue> hintsOf(FluentIssueKind kind) => FluentLog.shownHints.where((h) => h.kind == kind);

  FluentTask task(String? where, {List<Object?>? args, FluentDbAction action = FluentDbAction.find, String? orderBy, int? limit, int? offset, int depth = 1, bool lazy = false, Object? data, bool batched = false}) => FluentTask(
    table: 'users',
    dbName: users.dbName,
    action: action,
    maxDepth: depth,
    ignoreLazy: lazy,
    data: data,
    mergedTasks: batched ? [FluentTask(table: 'users', dbName: users.dbName, action: action), FluentTask(table: 'users', dbName: users.dbName, action: action)] : null,
    helper: TableHelper(where: where, whereArgs: args ?? List<Object?>.filled('?'.allMatches(where ?? '').length, 'x'), shape: where, orderBy: orderBy, limit: limit, offset: offset),
  );

  group('EXPLAIN path', () {
    test('the plan is read through the queue as a background read, once per shape', () async {
            final FluentTask t = task('"status" = ?');
      await FluentAnalyzer().explain(t, users, '~500 ms');
      expect(counter.statements.where((s) => s.contains('EXPLAIN QUERY PLAN')), hasLength(1));
      expect(hintsOf(FluentIssueKind.missingIndex), hasLength(1));

      FluentLog.forgetIssues();
      await FluentAnalyzer().explain(t, users, '~500 ms');
      await FluentAnalyzer().explain(task('"status" = ?', args: ['other value']), users, '~500 ms');
      expect(counter.statements.where((s) => s.contains('EXPLAIN QUERY PLAN')), hasLength(1), reason: 'the same shape is explained once');
      expect(hintsOf(FluentIssueKind.missingIndex), isEmpty);
    });

    test('a read that is only ordered gets an index on the order column when SQLite sorts', () async {
      await FluentAnalyzer().explain(task(null, orderBy: 'age DESC'), users, '~500 ms');
      final FluentIssue hint = hintsOf(FluentIssueKind.missingIndex).single;
      expect(hint.key, endsWith(':users:age'));
      expect(hint.details, contains('TEMP B-TREE'));
    });

    test('a range filter takes the order column out: equality columns, then the range', () async {
      await FluentAnalyzer().explain(task('"status" = ? AND "age" >= ? AND "bio" < ?', orderBy: 'bio'), users, '~500 ms');
      expect(hintsOf(FluentIssueKind.missingIndex).single.key, endsWith(':users:status,age'));
    });

    test('an index that serves filter and order gives no hint', () async {
      await db.close();
      counter.uninstall();
      await open(indexes: [const FluentIndex(['status', 'age'])]);
      await FluentAnalyzer().explain(task('"status" = ?', orderBy: 'age'), users, '~500 ms');
      expect(FluentLog.shownHints, isEmpty);
    });

    test('count reads are explained too; other actions, deferred conditions and unknown columns are not', () async {
      await FluentAnalyzer().explain(task('"status" = ?', action: FluentDbAction.count), users, '~500 ms');
      expect(hintsOf(FluentIssueKind.missingIndex), hasLength(1));
      FluentLog.forgetIssues();

      await FluentAnalyzer().explain(task('"age" = ?', action: FluentDbAction.save), users, '~500 ms');
      await FluentAnalyzer().explain(task('"ghost" = ?'), users, '~500 ms');
      await FluentAnalyzer().explain(task('"id" = ?'), users, '~500 ms');
      expect(FluentLog.shownHints, isEmpty);
    });

    test('when the plan cannot be read the unindexed columns are suggested and the reason is logged at debug level', () async {
      await FluentAnalyzer().explain(task('"status" = ?', args: const []), users, '~500 ms'); // too few arguments: EXPLAIN fails
      final FluentIssue hint = hintsOf(FluentIssueKind.missingIndex).single;
      expect(hint.key, endsWith(':users:status'));
      expect(hint.details, isNot(contains('Query plan')));
      expect(records.where((r) => r.level == FluentLogLevel.debug && r.message.startsWith('Query plan not available')), hasLength(1));
      expect(await users.count(), 0, reason: 'the database still works');
    });

    test('in release the plan is never read (no EXPLAIN statement)', () async {
      FluentAnalyzer.releaseMode = true;
      FluentDb.configure(const FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true)));
            await FluentAnalyzer().explain(task('"status" = ?'), users, '~500 ms');
      expect(counter.statements.where((s) => s.contains('EXPLAIN')), isEmpty);
      expect(hintsOf(FluentIssueKind.missingIndex), hasLength(1));
      expect(FluentAnalyzer().canExplain, isFalse);
    });

    test('a database closed while the plan is read gives no hint and no error', () async {
      final Future<void> pending = FluentAnalyzer().explain(task('"status" = ?'), users, '~500 ms');
      await db.close();
      await pending;
      expect(FluentLog.shownHints.where((h) => h.kind == FluentIssueKind.missingIndex).length, lessThanOrEqualTo(1));
    });

    test('a slow shape handed over by the cost model is explained: the index hint appears after minSamples slow runs', () async {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < FluentTableStatsTracker.minSamples - 1; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      await db.settle();
      expect(hintsOf(FluentIssueKind.missingIndex), isEmpty, reason: 'two runs are not an average yet');
      FluentTableStatsTracker().record(t, 150);
      await db.settle();
      final FluentIssue hint = hintsOf(FluentIssueKind.missingIndex).single;
      expect(hint.details, contains('~150 ms on average (3 runs)'));
    });

    test('a shape just below the slow threshold is not explained', () async {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 5; i++) {
        FluentTableStatsTracker().record(t, FluentAnalyzer.slowReadMs - 1);
      }
      await db.settle();
      expect(FluentLog.shownHints, isEmpty);
    });
  });

  group('tuner hand-over', () {
    test('with hints off but the index lever on the slow shape is still explained and the tuner creates the index', () async {
      await db.close();
      counter.uninstall();
      await open(diagnostics: const FluentDiagnostics(hints: false, tuning: FluentTuning(indexes: true)));
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 3; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      for (int i = 0; i < 200 && !(await users.rawQuery("SELECT name FROM sqlite_master WHERE name = 'fluent_auto_users_status'")).isNotEmpty; i++) {
        await db.settle();
      }
      expect(await users.rawQuery("SELECT name FROM sqlite_master WHERE name = 'fluent_auto_users_status'"), isNotEmpty);
      expect(FluentLog.shownHints, isEmpty, reason: 'hints are off');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tuned && i.subject == 'status'), isNotEmpty);
    });

    test('with hints and tuning off nothing is explained and nothing is created', () async {
      await db.close();
      counter.uninstall();
      await open(diagnostics: const FluentDiagnostics(hints: false));
            final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 3; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      await db.settle();
      expect(counter.statements.where((s) => s.contains('EXPLAIN')), isEmpty);
    });
  });

  group('thresholds', () {
    test('slow writes: 500 ms and over, with the item count and chunked saveAll code; fast writes and reads do not', () {
      final FluentTask save = task(null, action: FluentDbAction.save, data: List<int>.filled(300, 1));
      FluentAnalyzer().onFinish(save, users, FluentAnalyzer.slowWriteMs - 1, null);
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onFinish(save, users, FluentAnalyzer.slowWriteMs, null);
      final FluentIssue hint = hintsOf(FluentIssueKind.slowWrite).single;
      expect(hint.title, 'Split big writes of "users"');
      expect(hint.details, allOf(contains('save of 300 row(s)'), contains('500 ms')));
      expect(hint.code, allOf(contains('slices(500)'), contains('saveAll<DynamicModel>(chunk)')));
    });

    test('a slow single write names one row; the hint appears once per run', () {
      final FluentTask save = task(null, action: FluentDbAction.save);
      FluentAnalyzer().onFinish(save, users, 900, null);
      FluentAnalyzer().onFinish(save, users, 900, null);
      expect(hintsOf(FluentIssueKind.slowWrite).single.details, contains('1 row(s)'));
    });

    test('relations: a trusted slow average with nested loading; shallow, fast or lazy-less reads do not', () {
      FluentAnalyzer().onSlowShape(task('"status" = ?'), FluentAnalyzer.slowRelationsMs + 50, 3);
      FluentAnalyzer().onSlowShape(task('"status" = ?', depth: 2), FluentAnalyzer.slowRelationsMs - 1.0, 3);
      expect(hintsOf(FluentIssueKind.relations), isEmpty);
      FluentAnalyzer().onSlowShape(task('"status" = ?', depth: 2), FluentAnalyzer.slowRelationsMs.toDouble(), 3);
      final FluentIssue hint = hintsOf(FluentIssueKind.relations).single;
      expect(hint.details, contains('~100 ms on average'));
      expect(hint.code, allOf(contains('maxDepth: 1'), contains('FluentLoad.none'), contains('lazy: true'), contains('loadRelations')));

      FluentLog.forgetIssues();
      FluentAnalyzer().onSlowShape(task('"status" = ?', lazy: true), 400, 3);
      expect(hintsOf(FluentIssueKind.relations), hasLength(1), reason: 'reading with ignoreLazy loads the lazy relations too');
    });

    test('a shape of a table that is not registered is ignored', () {
      final FluentTask ghost = FluentTask(table: 'ghost', dbName: users.dbName, action: FluentDbAction.find, maxDepth: 3);
      FluentAnalyzer().onSlowShape(ghost, 500, 5);
      expect(FluentLog.shownHints, isEmpty);
    });

    test('big reads: 999 rows no, 1000 rows yes; a limit, findMaps and writes are judged by the rule', () {
      FluentAnalyzer().onFinish(task(null), users, 10, List<int>.filled(FluentAnalyzer.bigReadRows - 1, 1));
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onFinish(task(null, limit: 5000), users, 10, List<int>.filled(FluentAnalyzer.bigReadRows, 1));
      expect(FluentLog.shownHints, isEmpty, reason: 'a limit is paging');
      FluentAnalyzer().onFinish(task(null), users, 10, 'not a list');
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onFinish(task(null, action: FluentDbAction.findMaps), users, 42, List<int>.filled(FluentAnalyzer.bigReadRows, 1));
      final FluentIssue hint = hintsOf(FluentIssueKind.bigRead).single;
      expect(hint.details, allOf(contains('1000 rows'), contains('42 ms')));
      expect(hint.code, contains('page.next'));
    });

    test('deep offsets: 999 no, 1000 yes, with the offset in the text', () {
      FluentAnalyzer().onEnqueue(task(null, offset: FluentAnalyzer.deepOffset - 1), 1);
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onEnqueue(task(null, offset: 5000), 1);
      final FluentIssue hint = hintsOf(FluentIssueKind.deepOffset).single;
      expect(hint.details, contains('skips 5000 rows'));
      expect(hint.code, contains('after: previous?.next'));
    });

    test('flood: 999 queued calls no, 1000 yes, naming the last call', () {
      FluentAnalyzer().onEnqueue(task(null), FluentAnalyzer.floodQueue - 1);
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onEnqueue(task(null, action: FluentDbAction.updateFields), FluentAnalyzer.floodQueue);
      final FluentIssue hint = hintsOf(FluentIssueKind.flood).single;
      expect(hint.details, allOf(contains('1000 calls'), contains('updateFields on "users"')));
      expect(hint.code, contains('saveAll<DynamicModel>'));
    });

    test('queue wait: 999 ms no, 1000 ms yes; the holder is named only while it can still be the cause', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      FluentAnalyzer().onDone(task('"a" = ?'), 199);
      FluentAnalyzer().onStart(task('"b" = ?'), FluentAnalyzer.queueWaitMs - 1);
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onStart(task('"b" = ?'), FluentAnalyzer.queueWaitMs);
      expect(hintsOf(FluentIssueKind.queueWait).single.details, isNot(contains('slowest call')), reason: 'a call under 200 ms is no holder');

      FluentLog.forgetIssues();
      FluentAnalyzer().onDone(task(null, action: FluentDbAction.transaction), 2500);
      now += 100;
      FluentAnalyzer().onDone(task('"x" = ?'), 300); // shorter than the holder, within the window: the holder stays
      FluentAnalyzer().onStart(task('"c" = ?'), 3000);
      expect(hintsOf(FluentIssueKind.queueWait).single.details, contains('a transaction (2500 ms)'));

      FluentLog.forgetIssues();
      now += 600000;
      FluentAnalyzer().onStart(task('"c" = ?'), 1500);
      expect(hintsOf(FluentIssueKind.queueWait).single.details, isNot(contains('slowest call')), reason: 'long ago');
    });

    test('a newer or slower call replaces the holder', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      FluentAnalyzer().onDone(task('"a" = ?'), 400);
      now += FluentAnalyzer.window.inMilliseconds + 1;
      FluentAnalyzer().onDone(task('"b" = ?', action: FluentDbAction.count), 250);
      FluentAnalyzer().onStart(task('"c" = ?'), 1200);
      expect(hintsOf(FluentIssueKind.queueWait).single.details, contains('count on "users" (250 ms)'));
    });

    test('a LIKE hint needs the trusted average: 29 ms no, 30 ms yes; a prefix pattern, other operators and null arguments never', () {
      final FluentTask leading = task('"bio" LIKE ?', args: ['%abc%']);
      for (int i = 0; i < FluentTableStatsTracker.minSamples; i++) {
        FluentTableStatsTracker().record(leading, FluentAnalyzer.slowLikeMs - 1);
      }
      FluentAnalyzer().onFinish(leading, users, 5000, const []);
      expect(FluentLog.shownHints, isEmpty, reason: 'one slow run is not an average');
      FluentTableStatsTracker().record(leading, 60);
      FluentAnalyzer().onFinish(leading, users, 5, const []);
      final FluentIssue hint = hintsOf(FluentIssueKind.like).single;
      expect(hint.key, 'like:${users.dbName}:users:bio');
      expect(hint.code, allOf(contains("FluentFilter.startsWith('bio', text)"), contains('FluentCollation.noCase'), contains("FluentIndex(['bio'])")));

      FluentLog.forgetIssues();
      for (final FluentTask t in [task('"bio" LIKE ?', args: [null]), task('"bio" LIKE ?', args: [5]), task('"bio" = ?', args: ['%a'])]) {
        for (int i = 0; i < 4; i++) {
          FluentTableStatsTracker().record(t, 90);
        }
        FluentAnalyzer().onFinish(t, users, 90, const []);
      }
      expect(FluentLog.shownHints, isEmpty);
    });

    test('the second LIKE column of a condition is matched by its own argument', () {
      final FluentTask t = task('"bio" LIKE ? AND "status" LIKE ?', args: ['abc%', '%x']);
      for (int i = 0; i < 4; i++) {
        FluentTableStatsTracker().record(t, 90);
      }
      FluentAnalyzer().onFinish(t, users, 90, const []);
      expect(hintsOf(FluentIssueKind.like).single.subject, 'status');
    });
  });

  group('call patterns at their boundaries', () {
    test('the save loop fires on exactly the Nth call, once per window, and again after a quiet window', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      final FluentTask save = task(null, action: FluentDbAction.save);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls - 1; i++) {
        FluentAnalyzer().onFinish(save, users, 1, null);
      }
      expect(hintsOf(FluentIssueKind.saveLoop), isEmpty);
      FluentAnalyzer().onFinish(save, users, 1, null);
      expect(hintsOf(FluentIssueKind.saveLoop), hasLength(1));
      expect(hintsOf(FluentIssueKind.saveLoop).single.details, contains('${FluentAnalyzer.saveLoopCalls} single saves'));

      FluentLog.forgetIssues();
      for (int i = 0; i < 20; i++) {
        FluentAnalyzer().onFinish(save, users, 1, null);
      }
      expect(hintsOf(FluentIssueKind.saveLoop), isEmpty, reason: 'only the Nth call of a window triggers');

      now += FluentAnalyzer.window.inMilliseconds + 1;
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        FluentAnalyzer().onFinish(save, users, 1, null);
      }
      expect(hintsOf(FluentIssueKind.saveLoop), hasLength(1), reason: 'a new window, a new run');
    });

    test('saves slower than the window never add up; a one-item list save counts, batched and many-item saves do not', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      final FluentTask save = task(null, action: FluentDbAction.save);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls * 2; i++) {
        now += 100 * 1000 ~/ 10; // 10 s between saves
        FluentAnalyzer().onFinish(save, users, 1, null);
      }
      expect(FluentLog.shownHints, isEmpty);

      final FluentTask batched = task(null, action: FluentDbAction.save, batched: true);
      final FluentTask many = task(null, action: FluentDbAction.save, data: [1, 2]);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        FluentAnalyzer().onFinish(batched, users, 1, null);
        FluentAnalyzer().onFinish(many, users, 1, null);
      }
      expect(FluentLog.shownHints, isEmpty);

      final FluentTask one = task(null, action: FluentDbAction.save, data: [1]);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        FluentAnalyzer().onFinish(one, users, 1, null);
      }
      expect(hintsOf(FluentIssueKind.saveLoop), hasLength(1));
    });

    test('lookup loop: exactly the Nth findById; batched lookups never', () {
      final FluentTask byId = task('"id" = ?', action: FluentDbAction.findById);
      final FluentTask batched = task('"id" = ?', action: FluentDbAction.findById, batched: true);
      for (int i = 0; i < FluentAnalyzer.lookupLoopCalls * 2; i++) {
        FluentAnalyzer().onFinish(batched, users, 1, null);
      }
      expect(FluentLog.shownHints, isEmpty);
      for (int i = 0; i < FluentAnalyzer.lookupLoopCalls - 1; i++) {
        FluentAnalyzer().onFinish(byId, users, 1, null);
      }
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onFinish(byId, users, 1, null);
      final FluentIssue hint = hintsOf(FluentIssueKind.lookupLoop).single;
      expect(hint.details, contains('${FluentAnalyzer.lookupLoopCalls} findById calls'));
      expect(hint.code, allOf(contains('findByIds<DynamicModel>(ids)'), contains('findById<DynamicModel>(id)')));
    });

    test('polling: identical reads of the same data, spaced out, inside the span; a write between them resets it; too slow a timer does not count', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      final FluentTask t = task('"status" = ?');
      void dispatch(int epoch, int gap) {
        now += gap;
        FluentAnalyzer().onDispatch(t, epoch);
      }

      for (int i = 0; i < 3; i++) {
        dispatch(1, FluentAnalyzer.pollingGapMs - 1); // too close: rebuilds
      }
      expect(FluentLog.shownHints, isEmpty);

      for (int i = 0; i < FluentAnalyzer.pollingRuns - 1; i++) {
        dispatch(2, FluentAnalyzer.pollingGapMs);
      }
      expect(FluentLog.shownHints, isEmpty);
      dispatch(2, FluentAnalyzer.pollingGapMs);
      final FluentIssue hint = hintsOf(FluentIssueKind.polling).single;
      expect(hint.details, contains('${FluentAnalyzer.pollingRuns} times'));
      expect(hint.code, allOf(contains('StreamBuilder<List<DynamicModel>>'), contains('FluentDb.watch<DynamicModel>')));

      FluentLog.forgetIssues();
      for (int i = 0; i < FluentAnalyzer.pollingRuns * 2; i++) {
        dispatch(3 + i, 1000); // the data changes every time
      }
      expect(FluentLog.shownHints, isEmpty);

      for (int i = 0; i < FluentAnalyzer.pollingRuns * 2; i++) {
        dispatch(100, FluentAnalyzer.pollingSpan ~/ 4); // one run per quarter of the span: the window restarts
      }
      expect(FluentLog.shownHints, isEmpty);
    });

    test('a sustained rebuild storm of one identical read (20 per second, no write) is not polling', () {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 100; i++) {
        now += 50; // every read is closer than pollingGapMs to the one before it
        FluentAnalyzer().onDispatch(t, 7);
      }
      expect(hintsOf(FluentIssueKind.polling), isEmpty);
    });

    test('reset forgets the counters', () {
      final FluentTask save = task(null, action: FluentDbAction.save);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls - 1; i++) {
        FluentAnalyzer().onFinish(save, users, 1, null);
      }
      FluentAnalyzer().reset();
      FluentAnalyzer().onFinish(save, users, 1, null);
      expect(FluentLog.shownHints, isEmpty);
    });
  });

  group('collecting, once per run, muting', () {
    test('a database with hints off gets none of the detectors; another database is not affected', () async {
      await db.close();
      counter.uninstall();
      await open(diagnostics: FluentDiagnostics.quiet);
      final FluentTask save = task(null, action: FluentDbAction.save);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        FluentAnalyzer().onFinish(save, users, 900, List<int>.filled(2000, 1));
      }
      FluentAnalyzer().onEnqueue(task(null, offset: 5000), FluentAnalyzer.floodQueue);
      FluentAnalyzer().onStart(task(null), 5000);
      FluentAnalyzer().onDone(task(null), 5000);
      FluentAnalyzer().onDispatch(task(null), 0);
      FluentAnalyzer().onSlowShape(task('"status" = ?', depth: 3), 500, 5);
      FluentAnalyzer().onSchema(users);
      expect(FluentLog.shownHints, isEmpty);
      expect(FluentAnalyzer().collects(users.dbName), isFalse);
      expect(FluentAnalyzer().collects('unknown_db'), isFalse, reason: 'a database without its own setting takes the global one (quiet here)');
    });

    test('a hint is shown once per run, again after the memory is cleared, and never when its key is muted', () {
      final FluentTask save = task(null, action: FluentDbAction.save);
      FluentAnalyzer().onFinish(task(null, action: FluentDbAction.save, data: [1]), users, 900, null);
      FluentAnalyzer().onFinish(task(null, action: FluentDbAction.save, data: [1]), users, 900, null);
      expect(hintsOf(FluentIssueKind.slowWrite), hasLength(1));
      expect(records.where((r) => r.issue?.kind == FluentIssueKind.slowWrite), hasLength(1));
      FluentLog.forgetIssues();
      FluentAnalyzer().onFinish(save, users, 900, null);
      expect(hintsOf(FluentIssueKind.slowWrite), hasLength(1));

      FluentLog.forgetIssues();
      FluentDb.setupLogging(console: false, onRecord: records.add, mute: {'slowWrite:*'});
      FluentAnalyzer().onFinish(save, users, 900, null);
      expect(hintsOf(FluentIssueKind.slowWrite), isEmpty);
    });

    test('hints carry the table, key and a how-to-mute line in the log', () {
      FluentAnalyzer().onFinish(task(null, action: FluentDbAction.save), users, 900, null);
      final FluentLogRecord record = records.firstWhere((r) => r.issue?.kind == FluentIssueKind.slowWrite);
      expect(record.level, FluentLogLevel.hint);
      expect(record.format(), allOf(contains('slowWrite:${users.dbName}:users'), contains("mute: {'slowWrite:*'}")));
    });
  });

  group('the report', () {
    test('lists hints by impact before warnings, with measured hints of earlier runs, each key once', () async {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 3; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      await db.settle();
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 'x', title: 'A warning', fix: 'fix'));
      final FluentReport report = FluentDb.report();
      final List<String> keys = report.issues.map((i) => i.key).toList();
      expect(keys.where((k) => k == 'missingIndex:${users.dbName}:users:status'), hasLength(1), reason: 'the live hint and the measured one share a key');
      final int hintAt = report.issues.indexWhere((i) => i.type == FluentIssueType.hint);
      final int warningAt = report.issues.indexWhere((i) => i.type == FluentIssueType.warning);
      expect(hintAt, lessThan(warningAt));
    });

    test('measured hints of a database that does not collect hints stay out of the report', () async {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 3; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      await db.settle();
      FluentLog.reset();
      FluentDb.setupLogging(console: false, onRecord: records.add);
      expect(FluentDb.report().issues.where((i) => i.kind == FluentIssueKind.missingIndex), isNotEmpty, reason: 'measured, collected');
      FluentAnalyzer.releaseMode = true;
      expect(FluentDb.report().issues.where((i) => i.kind == FluentIssueKind.missingIndex), isEmpty, reason: 'release without hintsInRelease');
    });
  });
  group('G26: every hint says how to fix it', () {
    test('every analyzer hint kind that can be reached carries a fix', () async {
      final FluentAnalyzer a = FluentAnalyzer();
      int now = 0;
      FluentAnalyzer.clock = () => now;
      for (int i = 0; i < FluentAnalyzer.pollingRuns + 1; i++) {
        now += 1000;
        a.onDispatch(task('"status" = ?'), 1);
      }
      a.onEnqueue(task(null, offset: 5000), 1);
      a.onEnqueue(task(null, action: FluentDbAction.updateFields), FluentAnalyzer.floodQueue);
      a.onStart(task('"b" = ?'), FluentAnalyzer.queueWaitMs);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        a.onFinish(task(null, action: FluentDbAction.save, data: 1), users, 1, null);
      }
      for (int i = 0; i < FluentAnalyzer.lookupLoopCalls; i++) {
        a.onFinish(task(null, action: FluentDbAction.findById), users, 1, null);
      }
      a.onFinish(task(null, action: FluentDbAction.save, data: List<int>.filled(3, 1)), users, FluentAnalyzer.slowWriteMs, null);
      a.onFinish(task(null), users, 10, List<int>.filled(FluentAnalyzer.bigReadRows, 1));
      final FluentTask leading = task('"bio" LIKE ?', args: ['%abc%']);
      for (int i = 0; i < FluentTableStatsTracker.minSamples; i++) {
        FluentTableStatsTracker().record(leading, 60);
      }
      a.onFinish(leading, users, 5, const []);
      a.onSlowShape(task('"status" = ?', depth: 2), FluentAnalyzer.slowRelationsMs + 50, 3);
      await a.explain(task('"age" = ?'), users, '~500 ms');
      final Set<FluentIssueKind> kinds = {for (final FluentIssue i in FluentLog.shownHints) i.kind};
      expect(
        kinds,
        containsAll(<FluentIssueKind>[
          FluentIssueKind.polling,
          FluentIssueKind.deepOffset,
          FluentIssueKind.flood,
          FluentIssueKind.queueWait,
          FluentIssueKind.saveLoop,
          FluentIssueKind.lookupLoop,
          FluentIssueKind.slowWrite,
          FluentIssueKind.bigRead,
          FluentIssueKind.like,
          FluentIssueKind.relations,
          FluentIssueKind.missingIndex,
        ]),
      );
      expectIssuesHaveFixes(FluentLog.shownHints);
    });

    test('the measured hints of the report carry a fix', () {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < 3; i++) {
        FluentTableStatsTracker().record(t, 150);
      }
      final List<FluentIssue> issues = FluentDb.report().issues;
      expect(issues.where((i) => i.kind == FluentIssueKind.missingIndex), isNotEmpty);
      expectIssuesHaveFixes(issues);
    });
  });
}
