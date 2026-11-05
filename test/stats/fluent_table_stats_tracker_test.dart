// The cost model: shapes, moving averages, forgetting, eviction, hints of the report and the persistence in __fluent_stats.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  late FluentTableStatsTracker tracker;
  int engineNow = 1 << 40;

  Future<void> open({bool persistent = false, FluentDbConfig config = const FluentDbConfig(), bool restart = false}) async {
    if (restart) {
      await db.restart([users], config: config);
    } else {
      db = FluentTestDb(name: 'stats_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
      users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      await db.open([users], config: config);
    }
    tracker = FluentTableStatsTracker()..forget();
    tracker.dirtyDatabases.toList().forEach(tracker.takeChanges);
  }

  setUp(() {
    engineNow += 1 << 30;
    FluentEngine.clock = () => engineNow;
  });

  tearDown(() async {
    FluentEngine.clock = null;
    FluentEngine.statsFlushInterval = const Duration(minutes: 5);
    FluentEngine.statsWriteGate = null;
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  FluentTask task(String shape, {FluentDbAction action = FluentDbAction.find, String? table, String? orderBy, int? limit, int depth = 1, bool lazy = false, Object? data, String? where}) => FluentTask(
    table: table ?? 'users',
    dbName: db.name,
    action: action,
    maxDepth: depth,
    ignoreLazy: lazy,
    data: data,
    helper: TableHelper(where: where ?? shape, whereArgs: List<Object?>.filled('?'.allMatches(where ?? shape).length, 1), shape: shape, orderBy: orderBy, limit: limit),
  );

  FluentQueryCost? costOf(FluentTask t) {
    for (final FluentQueryCost c in tracker.costs(db: db.name)) {
      if (c.action == t.action.name && c.shape == FluentTableStatsTracker.shapeOf(t)) return c;
    }
    return null;
  }

  group('shapes', () {
    setUp(open);

    test('values do not matter: parameter lists collapse, order / limit / depth / lazy are part of the shape', () {
      expect(FluentTableStatsTracker.shapeOf(task('"id" IN (?, ?, ?)')), '"id" IN (?…)');
      expect(FluentTableStatsTracker.shapeOf(task('"id" IN (?,?)')), '"id" IN (?…)');
      expect(FluentTableStatsTracker.shapeOf(task('"id" = ?')), '"id" = ?', reason: 'a single placeholder stays');
      expect(FluentTableStatsTracker.shapeOf(task('"a" = ?', orderBy: 'age DESC', limit: 5)), '"a" = ? ORDER BY age DESC LIMIT');
      expect(FluentTableStatsTracker.shapeOf(task('"a" = ?', depth: 3)), '"a" = ? depth=3');
      expect(FluentTableStatsTracker.shapeOf(task('"a" = ?', lazy: true)), '"a" = ? depth=1+lazy');
      expect(FluentTableStatsTracker.shapeOf(task('"a" = ?', depth: 3, lazy: true)), '"a" = ? depth=3+lazy');
      expect(FluentTableStatsTracker.shapeOf(task('"a" = ?', action: FluentDbAction.save, depth: 3)), '"a" = ?', reason: 'writes have no relation depth');
      expect(FluentTableStatsTracker.shapeOf(FluentTask(table: 'users', dbName: db.name, action: FluentDbAction.find)), '', reason: 'no helper: the empty shape');
    });

    test('the shape falls back to the where clause, and keyOf names database, table, action and shape', () {
      final FluentTask t = FluentTask(table: 'users', dbName: db.name, action: FluentDbAction.find, helper: TableHelper(where: '"x" IN (?, ?)'));
      expect(FluentTableStatsTracker.shapeOf(t), '"x" IN (?…)');
      expect(FluentTableStatsTracker.keyOf(t), '${db.name}|users|find|"x" IN (?…)');
    });
  });

  group('recording', () {
    setUp(open);

    test('a new run weighs 20 %, the first sets the average, rows average the same way', () {
      final FluentTask t = task('"status" = ?');
      tracker.record(t, 100, rows: 10);
      expect(costOf(t)!.averageMs, 100);
      expect(costOf(t)!.averageRows, 10);
      tracker.record(t, 50, rows: 20);
      expect(costOf(t)!.averageMs, closeTo(90, 1e-9));
      expect(costOf(t)!.averageRows, closeTo(12, 1e-9));
      expect(costOf(t)!.samples, 2);
    });

    test('averageMs is trusted only after minSamples runs', () {
      final FluentTask t = task('"status" = ?');
      for (int i = 0; i < FluentTableStatsTracker.minSamples - 1; i++) {
        tracker.record(t, 10);
        expect(tracker.averageMs(t), isNull);
      }
      tracker.record(t, 10);
      expect(tracker.averageMs(t), 10);
      expect(tracker.averageMs(task('"other" = ?')), isNull, reason: 'a shape never seen');
    });

    test('a write is measured per item, and a write never keeps rows', () {
      final FluentTask t = task('', action: FluentDbAction.save, data: List<int>.filled(10, 1));
      tracker.record(t, 100, rows: 7);
      final FluentQueryCost c = tracker.costs(db: db.name).single;
      expect(c.averageMs, closeTo(10, 1e-9));
      expect(c.averageRows, isNull);
      tracker.record(task('', action: FluentDbAction.save, data: <int>[]), 4);
      expect(tracker.costs(db: db.name).single.samples, 2, reason: 'an empty batch counts as one item');
    });

    test('transactions, tasks without a table and databases without the cost model are not measured', () {
      tracker.record(task('', action: FluentDbAction.transaction), 5);
      tracker.record(task('"a" = ?', table: ''), 5);
      tracker.recordFailure(task('"a" = ?', table: ''));
      tracker.recordMapping(db.name, 'users', 5);
      expect(tracker.costs(db: db.name), isEmpty);
      expect(tracker.hasChanges, isTrue, reason: 'only the mapping row exists');
      tracker.forget();
      tracker.takeChanges(db.name);

      final FluentTask other = FluentTask(table: 'users', dbName: 'no_model_db', action: FluentDbAction.find, helper: TableHelper(shape: 'x'));
      tracker.record(other, 5);
      expect(tracker.costs(db: 'no_model_db'), anyElement(isA<FluentQueryCost>()), reason: 'an unknown database uses the global default (cost model on)');
    });

    test('failures are counted on the shape and do not touch its average', () {
      final FluentTask t = task('"status" = ?');
      tracker.record(t, 20);
      tracker
        ..recordFailure(t)
        ..recordFailure(t);
      final FluentQueryCost c = costOf(t)!;
      expect(c.failures, 2);
      expect(c.samples, 1);
      expect(c.averageMs, 20);
      tracker.recordFailure(task('"never" = ?'));
      expect(costOf(task('"never" = ?'))!.failures, 1, reason: 'a failure creates the shape');
    });

    test('mapping costs average 70 / 30 per table and stay out of costs() and slowest()', () {
      expect(tracker.mappingMicros(db.name, 'users'), isNull);
      tracker.recordMapping(db.name, 'users', 100);
      tracker.recordMapping(db.name, 'users', 200);
      expect(tracker.mappingMicros(db.name, 'users'), closeTo(130, 1e-9));
      expect(tracker.mappingMicros(db.name, 'orders'), isNull);
      expect(tracker.costs(db: db.name), isEmpty);
      for (int i = 0; i < 5; i++) {
        tracker.recordMapping(db.name, 'users', 1000);
      }
      expect(tracker.slowest(), isEmpty);
    });

    test('the database setting costModel: off keeps a database out of the model', () async {
      await db.close();
      await open(config: const FluentDbConfig(diagnostics: FluentDiagnostics.none));
      tracker.record(task('"a" = ?'), 5);
      tracker.recordFailure(task('"a" = ?'));
      tracker.recordMapping(db.name, 'users', 3);
      expect(tracker.costs(db: db.name), isEmpty);
      expect(tracker.mappingMicros(db.name, 'users'), isNull);
    });
  });

  group('slowest and costs', () {
    setUp(open);

    test('costs are sorted slowest first and filtered by database and table; slowest needs minSamples and skips writes', () {
      final FluentTask fast = task('"a" = ?');
      final FluentTask slow = task('"b" = ?');
      final FluentTask orders = task('"c" = ?', table: 'orders');
      final FluentTask write = task('', action: FluentDbAction.save);
      for (int i = 0; i < 3; i++) {
        tracker
          ..record(fast, 5)
          ..record(slow, 50)
          ..record(orders, 40)
          ..record(write, 90);
      }
      tracker.record(task('"d" = ?'), 70); // one run: not trusted
      expect([for (final FluentQueryCost c in tracker.costs(db: db.name)) c.averageMs], [90, 70, 50, 40, 5]);
      expect(tracker.costs(db: db.name, table: 'orders').single.shape, '"c" = ?');
      expect(tracker.costs(db: 'elsewhere'), isEmpty);
      expect([for (final FluentQueryCost c in tracker.slowest()) c.shape], ['"b" = ?', '"c" = ?', '"a" = ?']);
      expect(tracker.slowest(1).single.shape, '"b" = ?');
      expect(FluentDb.queryStats(dbKey: db.key, table: 'orders').queries.single.averageMs, 40);
    });
  });

  group('forgetting', () {
    setUp(open);

    test('forget() by table, by database and everything; the rows are deleted on the next write', () {
      tracker
        ..record(task('"a" = ?'), 5)
        ..record(task('"b" = ?', table: 'orders'), 5);
      tracker.takeChanges(db.name);
      tracker.forget(db: db.name, table: 'orders');
      expect(tracker.costs(db: db.name).map((c) => c.table), ['users']);
      final changes = tracker.takeChanges(db.name);
      expect(changes.upserts, isEmpty);
      expect(changes.deletes, ['orders|find|"b" = ?']);
      tracker.forget(db: db.name);
      expect(tracker.costs(), isEmpty);
      tracker.record(task('"z" = ?'), 5);
      tracker.forget();
      expect(tracker.costs(), isEmpty);
      expect(tracker.takeChanges(db.name).upserts, isEmpty, reason: 'a forgotten shape is not written any more');
    });

    test('forgetKey drops one shape (and lets the slow-shape hint fire again); an unknown key is ignored', () {
      final FluentTask t = task('"a" = ?', depth: 2);
      tracker.forgetKey('nothing|here|at|all');
      expect(tracker.hasChanges, isFalse);

      FluentLog.reset();
      FluentDb.setupLogging(console: false);
      void runSlow() {
        for (int i = 0; i < FluentTableStatsTracker.minSamples; i++) {
          tracker.record(t, 150);
        }
      }

      runSlow();
      expect(FluentLog.shownHints.where((h) => h.kind == FluentIssueKind.relations), hasLength(1));
      FluentLog.forgetIssues();
      tracker.record(t, 150);
      expect(FluentLog.shownHints.where((h) => h.kind == FluentIssueKind.relations), isEmpty, reason: 'handed to the analyzer once per run');

      tracker.forgetKey(t.costKey);
      expect(tracker.costs(db: db.name), isEmpty);
      expect(tracker.takeChanges(db.name).deletes, [FluentTableStatsTracker.keyOf(t).substring(db.name.length + 1)]);
      runSlow();
      expect(FluentLog.shownHints.where((h) => h.kind == FluentIssueKind.relations), hasLength(1), reason: 'measured again, handed over again');
    });

    test('discard drops a database from memory without writing anything', () {
      tracker
        ..record(task('"a" = ?'), 5)
        ..forget(db: db.name, table: 'users');
      tracker.record(task('"a" = ?'), 5);
      tracker.discard(db.name);
      expect(tracker.costs(db: db.name), isEmpty);
      expect(tracker.hasChanges, isFalse);
      expect(tracker.dirtyDatabases, isEmpty);
    });

    test('at most capacity shapes are kept: the least recently used go', () {
      for (int i = 0; i < FluentTableStatsTracker.capacity; i++) {
        db.clock.advance(const Duration(milliseconds: 1));
        tracker.record(task('"c" = $i'), 1);
      }
      expect(tracker.costs(db: db.name), hasLength(FluentTableStatsTracker.capacity));
      db.clock.advance(const Duration(milliseconds: 1));
      tracker.record(task('"c" = new'), 1);
      expect(tracker.costs(db: db.name), hasLength(FluentTableStatsTracker.capacity));
      final Set<String> shapes = {for (final FluentQueryCost c in tracker.costs(db: db.name)) c.shape};
      expect(shapes, contains('"c" = new'));
      expect(shapes, isNot(contains('"c" = 0')), reason: 'the oldest one was dropped');
      expect(shapes, contains('"c" = 1'));
      expect(tracker.takeChanges(db.name).deletes, ['users|find|"c" = 0']);
    });
  });

  group('changes', () {
    setUp(open);

    test('takeChanges hands over each change once, restoreChanges puts them back for the next flush', () {
      final FluentTask t = task('"a" = ?');
      tracker.record(t, 5, rows: 3);
      tracker.recordMapping(db.name, 'users', 7);
      tracker.record(task('"b" = ?', table: 'orders'), 5);
      expect(tracker.dirtyDatabases, {db.name});
      final changes = tracker.takeChanges(db.name);
      expect(changes.upserts.map((r) => r['key']), unorderedEquals(['users|find|"a" = ?', 'users|map|', 'orders|find|"b" = ?']));
      final Map<String, Object?> row = changes.upserts.firstWhere((r) => r['action'] == 'find');
      expect(row, containsPair('avg_ms', 5.0));
      expect(row, containsPair('avg_rows', 3.0));
      expect(row, containsPair('samples', 1));
      expect(row, containsPair('failures', 0));
      expect(row, containsPair('tbl', 'users'));
      expect(tracker.takeChanges(db.name).upserts, isEmpty);

      tracker.restoreChanges(db.name, changes);
      expect(tracker.hasChanges, isTrue);
      expect(tracker.takeChanges(db.name).upserts, hasLength(3));
    });

    test('a measurement forgotten and taken again keeps its delete and its upsert (the upsert wins when written)', () {
      final FluentTask t = task('"a" = ?');
      tracker.record(t, 5);
      tracker.forget(db: db.name);
      tracker.record(t, 9);
      final changes = tracker.takeChanges(db.name);
      expect(changes.deletes, ['users|find|"a" = ?']);
      expect(changes.upserts.single['avg_ms'], 9.0);
    });
  });

  group('load', () {
    setUp(open);

    Map<String, Object?> stored(String shape, {int? lastUsed, Object? avgMs = 12, Object? samples = 4, String action = 'find', String tbl = 'users'}) => {
      'key': '$tbl|$action|$shape',
      'tbl': tbl,
      'action': action,
      'shape': shape,
      'avg_ms': avgMs,
      'avg_rows': 3,
      'samples': samples,
      'failures': 1,
      'last_used': lastUsed ?? FluentClock.millis,
    };

    test('rows come back as shapes; the ones unused for the retention are dropped and deleted on the next write', () {
      final int old = FluentClock.now().subtract(FluentTableStatsTracker.retention + const Duration(days: 1)).millisecondsSinceEpoch;
      tracker.load(db.name, [stored('"a" = ?'), stored('"old" = ?', lastUsed: old)]);
      final FluentQueryCost c = tracker.costs(db: db.name).single;
      expect(c.shape, '"a" = ?');
      expect(c.averageMs, 12);
      expect(c.averageRows, 3);
      expect(c.samples, 4);
      expect(c.failures, 1);
      final changes = tracker.takeChanges(db.name);
      expect(changes.deletes, ['users|find|"old" = ?']);
      expect(changes.upserts, isEmpty, reason: 'loaded rows are not written back unchanged');
      expect(tracker.averageMs(task('"a" = ?')), 12, reason: 'trusted right after the load (4 samples)');
    });

    test('missing or odd values fall back to zero instead of failing', () {
      tracker.load(db.name, [
        {'key': 'k', 'tbl': 'users', 'action': 'find', 'shape': '"x" = ?', 'avg_ms': null, 'avg_rows': null, 'samples': null, 'failures': null, 'last_used': null},
      ]);
      expect(tracker.costs(db: db.name), isEmpty, reason: 'last_used 0 is older than the retention');
      tracker.load(db.name, [stored('"y" = ?', avgMs: 7, samples: 2)]);
      expect(tracker.costs(db: db.name).single.averageMs, 7);
    });

    test('a load of more than capacity rows evicts the oldest', () {
      final int now = FluentClock.millis;
      tracker.load(db.name, [for (int i = 0; i < FluentTableStatsTracker.capacity + 3; i++) stored('"s$i" = ?', lastUsed: now - 1000 + i)]);
      expect(tracker.costs(db: db.name), hasLength(FluentTableStatsTracker.capacity));
      final Set<String> shapes = {for (final FluentQueryCost c in tracker.costs(db: db.name)) c.shape};
      expect(shapes, isNot(contains('"s0" = ?')));
      expect(shapes, contains('"s${FluentTableStatsTracker.capacity + 2}" = ?'));
    });
  });

  group('hints of the report (measuredHints)', () {
    setUp(open);

    void measure(FluentTask t, double ms, {int runs = FluentTableStatsTracker.minSamples}) {
      for (int i = 0; i < runs; i++) {
        tracker.record(t, ms.round());
      }
    }

    FluentIssue only(FluentIssueKind kind) => tracker.measuredHints().singleWhere((h) => h.kind == kind);

    test('a slow filter no index starts with: missingIndex with the columns and the model code', () {
      measure(task('"status" = ? AND "age" > ?'), 150);
      final FluentIssue h = only(FluentIssueKind.missingIndex);
      expect(h.table, 'users');
      expect(h.key, 'missingIndex:${db.name}:users:status,age');
      expect(h.title, 'Add an index on users(status, age)');
      expect(h.details, allOf(contains('150 ms'), contains('3 runs')));
      expect(h.code, contains("FluentIndex(['status', 'age'])"));
      expect(h.code, contains('DynamicModel'));
    });

    test('fast, untrusted, indexed, key, unique and LIKE filters give no index hint', () {
      measure(task('"status" = ?'), 99); // fast enough
      measure(task('"age" = ?'), 500, runs: FluentTableStatsTracker.minSamples - 1); // not trusted yet
      measure(task('"id" = ?'), 500); // the key
      measure(task('"email" = ?'), 500); // unique
      measure(task('"status" LIKE ?', limit: 5), 500); // a LIKE cannot use an index
      measure(task('"nothere" = ?', limit: 5), 500); // unknown column
      expect(tracker.measuredHints().where((h) => h.kind == FluentIssueKind.missingIndex), isEmpty);
    });

    test('an indexed leading column is enough, even with more filtered columns', () {
      measure(task('"id" = ? AND "status" = ?', limit: 5), 500);
      expect(tracker.measuredHints().where((h) => h.kind == FluentIssueKind.missingIndex), isEmpty);
    });

    test('a slow read of deep relations: relations hint; depth=1 and writes do not', () {
      measure(task('"email" = ?', depth: 3), 200);
      final FluentIssue h = only(FluentIssueKind.relations);
      expect(h.title, 'Load fewer relation levels of "users"');
      expect(h.details, contains('depth=3'));
      expect(h.code, contains('maxDepth: 1'));
      expect(h.code, contains('lazy: true'));
    });

    test('a slow unpaged find: bigRead with findPage; a limit, other actions and writes do not', () {
      measure(task('"email" = ?'), 200);
      final FluentIssue h = only(FluentIssueKind.bigRead);
      expect(h.title, 'Read "users" in pages');
      expect(h.code, contains('findPage<DynamicModel>'));

      tracker.forget();
      measure(task('"email" = ?', limit: 10), 200);
      measure(task('"email" = ?', action: FluentDbAction.count), 200);
      measure(task('"email" = ?', action: FluentDbAction.save), 200);
      expect(tracker.measuredHints(), isEmpty);
    });

    test('the model is named by the table when the table is not registered', () {
      measure(task('"x" = ?', table: 'ghost'), 200);
      final FluentIssue h = only(FluentIssueKind.bigRead);
      expect(h.table, 'ghost');
      expect(h.code, contains('findPage<ghost>'));
    });

    test('many slow single saves: saveLoop; fewer than 200 or cheap ones do not', () {
      final FluentTask save = task('', action: FluentDbAction.save);
      measure(save, 3, runs: 199);
      expect(tracker.measuredHints(), isEmpty);
      tracker.record(save, 3);
      final FluentIssue h = only(FluentIssueKind.saveLoop);
      expect(h.details, contains('200 single saves'));
      expect(h.code, contains('saveAll<DynamicModel>'));

      tracker.forget();
      measure(save, 1, runs: 300);
      expect(tracker.measuredHints(), isEmpty, reason: 'cheap saves');
    });

    test('hints are ordered by total time (average x runs)', () {
      measure(task('"status" = ?'), 120);
      measure(task('"age" = ?'), 120, runs: 10);
      final List<FluentIssue> hints = tracker.measuredHints();
      expect(hints.map((h) => h.subject), ['age', 'status']);
    });

    test('the report adds them once, skips muted keys, and keeps them out when the database does not collect hints', () async {
      FluentLog.reset();
      FluentDb.setupLogging(console: false);
      measure(task('"status" = ?'), 120);
      expect(FluentDb.report().issues.where((i) => i.kind == FluentIssueKind.missingIndex), hasLength(1));
      FluentDb.setupLogging(console: false, mute: {'missingIndex:*'});
      expect(FluentDb.report().issues.where((i) => i.kind == FluentIssueKind.missingIndex), isEmpty);

      FluentDb.setupLogging(console: false);
      await db.close();
      await open(config: const FluentDbConfig(diagnostics: FluentDiagnostics(hints: false)));
      measure(task('"status" = ?'), 120);
      expect(FluentDb.report().issues.where((i) => i.kind == FluentIssueKind.missingIndex), isEmpty);
    });
  });

  group('persistence', () {
    Future<List<Map<String, Object?>>> stored() => users.db.rawQuery('SELECT * FROM "${FluentTableStatsTracker.table}" ORDER BY key');

    test('a real read is measured with its rows, written when the database is idle, and loaded again after a restart', () async {
      await open(persistent: true);
      await users.saveAll([for (int i = 0; i < 5; i++) users.row({'id': i, 'email': 'e$i', 'status': 'a', 'age': i})]);
      await users.find(where: FluentFilter.eq('status', 'a'));
      await db.settle();
      await users.count(); // a task that finishes after the first flush: flush runs after the task
      await db.settle();
      final FluentQueryCost find = FluentDb.queryStats(dbKey: db.key).queries.firstWhere((c) => c.action == 'find');
      expect(find.averageRows, 5);
      expect(find.shape, contains('"status" = ?'));

      await db.restart([users]);
      final FluentQueryCost loaded = FluentDb.queryStats(dbKey: db.key).queries.firstWhere((c) => c.action == 'find');
      expect(loaded.averageRows, 5, reason: 'written at the restart (close) or earlier, loaded at the start');
      expect(loaded.samples, greaterThanOrEqualTo(1));
    });

    test('written at most every statsFlushInterval, and always on close', () async {
      await open(persistent: true);
      FluentEngine.statsFlushInterval = const Duration(milliseconds: 200);
      await users.count();
      await db.settle();
      expect((await stored()).map((r) => r['action']), contains('count'), reason: 'the first change is written at once');

      FluentTableStatsTracker().record(task('"age" = ? /* later */'), 8);
      await users.findById(1);
      await db.settle();
      expect((await stored()).map((r) => r['shape']), isNot(contains('"age" = ? /* later */')), reason: 'inside the interval: a timer waits');

      engineNow += 200; // the interval is over for the clock; the armed timer then flushes
      for (int i = 0; i < 100 && !(await stored()).any((r) => '${r['shape']}'.contains('later')); i++) {
        await db.settle();
      }
      expect((await stored()).map((r) => r['shape']), contains('"age" = ? /* later */'));

      FluentEngine.statsFlushInterval = const Duration(minutes: 5);
      FluentTableStatsTracker().record(task('"age" = ? /* at close */'), 8);
      await users.findById(1);
      await db.settle();
      expect((await stored()).map((r) => r['shape']), isNot(contains('"age" = ? /* at close */')));
      final String path = users.db.path;
      await db.close(keepFile: true);
      final Database raw = await openDatabase(path, readOnly: true, singleInstance: false);
      try {
        final List<Map<String, Object?>> rows = await raw.rawQuery('SELECT shape FROM "${FluentTableStatsTracker.table}"');
        expect(rows.map((r) => r['shape']), contains('"age" = ? /* at close */'));
      } finally {
        await raw.close();
        await databaseFactory.deleteDatabase(path);
      }
    });

    test('a busy database is not written; the flush waits until it is idle', () async {
      await open(persistent: true);
      await users.count();
      await db.settle();
      engineNow += FluentEngine.statsFlushInterval.inMilliseconds + 1;
      final Completer<void> inside = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> tx = FluentDb.transaction(() async {
        FluentTableStatsTracker().record(task('"age" = ? /* busy */'), 8);
        inside.complete();
        await release.future;
      });
      await inside.future;
      expect(await FluentEngine().whenIdle(const Duration(milliseconds: 50)), isFalse);
      release.complete();
      await tx;
      await db.settle();
      await users.count();
      await db.settle();
      expect((await stored()).map((r) => r['shape']), contains('"age" = ? /* busy */'));
    });

    test('a failed write keeps the changes for the next flush', () async {
      await open(persistent: true);
      FluentEngine.statsFlushInterval = const Duration(milliseconds: 20);
      int gates = 0;
      FluentEngine.statsWriteGate = (String _) async {
        gates++;
        if (gates == 1) await users.db.execute('DROP TABLE "${FluentTableStatsTracker.table}"');
      };
      FluentTableStatsTracker().record(task('"age" = ? /* retried */'), 8);
      await users.count();
      await db.settle();
      expect(gates, greaterThanOrEqualTo(1));
      await users.db.execute(FluentTableStatsTracker.createTableSql);
      FluentEngine.statsWriteGate = null;
      engineNow += 10000;
      await users.count();
      await db.settle();
      for (int i = 0; i < 100 && !(await stored()).any((r) => '${r['shape']}'.contains('retried')); i++) {
        engineNow += 10000;
        await users.count();
        await db.settle();
      }
      expect((await stored()).map((r) => r['shape']), contains('"age" = ? /* retried */'));
    });

    test('forgetQueryStats deletes the stored rows on the next write', () async {
      await open(persistent: true);
      await users.count();
      await db.settle();
      expect(await stored(), isNotEmpty);
      FluentDb.forgetQueryStats(dbKey: db.key, table: 'users');
      expect(FluentDb.queryStats(dbKey: db.key, table: 'users').queries, isEmpty);
      engineNow += FluentEngine.statsFlushInterval.inMilliseconds + 1;
      await db.settle();
      await db.restart([users]);
      expect(FluentDb.queryStats(dbKey: db.key, table: 'users').queries.where((c) => c.action == 'count'), isEmpty);
    });

    test('rows unused for longer than the retention are not loaded and are deleted at the first write', () async {
      await open(persistent: true);
      await users.count();
      await db.settle();
      await users.db.insert(FluentTableStatsTracker.table, {'key': 'users|find|"old" = ?', 'tbl': 'users', 'action': 'find', 'shape': '"old" = ?', 'avg_ms': 5.0, 'samples': 9, 'failures': 0, 'last_used': 1});
      await db.restart([users]);
      expect(FluentDb.queryStats(dbKey: db.key).queries.where((c) => c.shape == '"old" = ?'), isEmpty);
      await users.count();
      await db.settle();
      await db.restart([users]);
      expect((await stored()).where((r) => r['shape'] == '"old" = ?'), isEmpty);
    });

    test('in-memory databases keep the numbers in memory only and drop the pending writes at close', () async {
      await open();
      await users.count();
      await db.settle();
      expect(FluentDb.queryStats(dbKey: db.key).queries, isNotEmpty);
      expect(FluentTableStatsTracker().hasChanges, isTrue, reason: 'never written: still pending');
      final String name = db.name;
      await db.close();
      expect(FluentTableStatsTracker().dirtyDatabases.contains(name), isFalse, reason: 'the close drops what cannot be written');
    });

    test('the cost model off: no stats table is created', () async {
      await open(persistent: true, config: const FluentDbConfig(diagnostics: FluentDiagnostics.none));
      expect(await users.rawQuery("SELECT name FROM sqlite_master WHERE name = '${FluentTableStatsTracker.table}'"), isEmpty);
    });
  });
}
