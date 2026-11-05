// Engine fixes: transaction scopes end with their transaction, tasks start from a clean zone, merged saves keep
// separate calls on the same row apart, nested writes are atomic, pause / shutdown / tuner / stats edge cases.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

/// Users whose reads remember the zone they ran in, the order of the rows they mapped and the engine's active reads.
class ProbeProvider extends DynamicProvider {
  ProbeProvider() : super('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);

  Zone? readZone;
  final List<Object?> mapped = [];
  int? activeReadsSeen;

  /// Busy time per built row (a slow save).
  Duration slowBuild = Duration.zero;

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) {
    readZone ??= Zone.current;
    mapped.add(json['name']);
    activeReadsSeen = FluentEngine().stats.activeReads;
    return super.fromCacheJson(json);
  }

  @override
  DynamicModel row(Map<String, dynamic> values) => _SlowModel(this, values);
}

class _SlowModel extends DynamicModel {
  _SlowModel(this.provider, Map<String, dynamic> values) : super(provider.spec, values: values);

  final ProbeProvider provider;

  @override
  Map<String, dynamic> buildJson() {
    if (provider.slowBuild > Duration.zero) {
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < provider.slowBuild) {}
    }
    return super.buildJson();
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ProbeProvider users;

  Future<void> open({bool persistent = false, FluentConfig config = const FluentConfig()}) async {
    db = FluentTestDb(name: 'fix_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
    users = ProbeProvider();
    await db.open([users], fluentConfig: config);
  }

  tearDown(() async {
    FluentEngine.clock = null;
    await db.close();
  });

  DynamicModel u(int id, String? email, String? name) => users.row({'id': id, 'email': email, 'name': name});

  /// Holds the database's write slot until the returned completer completes: calls made meanwhile queue up.
  Future<(Completer<void>, Future<void>)> hold() async {
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    final Future<void> done = FluentDb.transaction(() async {
      started.complete();
      await release.future;
    });
    await started.future;
    return (release, done);
  }

  Future<String?> nameOf(int id) async => (await users.rawQuery('SELECT name FROM users WHERE id = ?', arguments: [id])).firstOrNull?['name'] as String?;

  group('E2 transaction scope ends with the transaction', () {
    test('a save started after the commit by code created inside the transaction runs on its own', () async {
      await open();
      final Completer<void> gate = Completer<void>();
      late Future<FluentSaveResult> later;
      await FluentDb.transaction(() async {
        await users.save(u(1, 'a@x', 'A'));
        later = gate.future.then((_) => users.save(u(2, 'b@x', 'B')));
      });
      gate.complete();
      expect((await later).saved, 1);
      expect(await users.count(), 2);
    });

    test('inside the transaction the scope is still seen; after it, pauseQueue is not refused', () async {
      await open();
      final Completer<void> gate = Completer<void>();
      late Future<void> paused;
      await FluentDb.transaction(() async {
        expect(FluentTransactionScope.of(users.dbName), isNotNull);
        paused = gate.future.then((_) {
          expect(FluentTransactionScope.of(users.dbName), isNull);
          return FluentDb.pauseQueue();
        });
      });
      gate.complete();
      await paused;
      FluentDb.resumeQueue();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall), isEmpty);
    });
  });

  group('E3 tasks start from a clean zone', () {
    test('a write made by code continuing from a pooled read task uses the main connection', () async {
      await open(persistent: true);
      await users.save(u(1, 'a@x', 'A'));
      users.readZone = null;
      await users.findAll();
      final Zone zone = users.readZone!;
      expect(zone.run(() => FluentReadScope.of(users.dbName)), isNotNull, reason: 'the read ran on the pool');
      // execute runs on the task's executor (a save opens its own transaction on the main connection).
      expect(await zone.run(() => users.execute('UPDATE users SET name = ? WHERE id = 1', arguments: ['B'])), 1);
      final FluentSaveResult saved = await zone.run(() => users.save(u(2, 'b@x', 'B')));
      expect(saved.saved, 1);
      expect(await nameOf(1), 'B');
    });

    test('the tuner creates its automatic index from a read task with a read pool', () async {
      await open(persistent: true, config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
      await users.save(u(1, 'a@x', 'A'));
      users.readZone = null;
      await users.findAll();
      final FluentTask task = FluentTask(table: 'users', dbName: users.dbName, action: FluentDbAction.find, helper: TableHelper(where: '"name" = ?', whereArgs: ['a'], shape: '"name" = ?'));
      users.readZone!.run(() => FluentTuner().proposeIndex(task, users, const ['name']));
      await db.settle();
      final List<String> indexes = [for (final r in await users.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']! as String];
      expect(indexes, contains('fluent_auto_users_name'));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tuningReverted), isEmpty);
    });
  });

  group('E4 / W10 merged saves', () {
    test('two patches of one row queued together both apply, each with its own outcome', () async {
      await open();
      await users.save(u(1, 'a@x', 'old'));
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<FluentSaveResult> first = users.save(u(1, null, 'new'), strategy: FluentSaveStrategy.patch);
      final Future<FluentSaveResult> second = users.save(u(1, 'b@x', null), strategy: FluentSaveStrategy.patch);
      release.complete();
      await done;
      expect((await first).updated, 1);
      expect((await second).updated, 1);
      expect(await nameOf(1), 'new');
      expect((await users.rawQuery('SELECT email FROM users WHERE id = 1')).single['email'], 'b@x');
    });

    test('saves sharing a conflictOn value are not merged; other adjacent saves still are', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final int merged = FluentDb.engineStats().mergedSaves;
      final Future<FluentSaveResult> a = users.save(u(5, 'z@x', 'first'), conflictOn: const ['email']);
      final Future<FluentSaveResult> b = users.save(u(6, 'z@x', 'second'), conflictOn: const ['email']);
      final Future<FluentSaveResult> c = users.save(u(7, 'y@x', 'third'), conflictOn: const ['email']);
      release.complete();
      await done;
      expect((await a).inserted, 1);
      expect((await b).updated, 1);
      expect((await c).inserted, 1);
      expect(await users.count(), 2);
      expect(FluentDb.engineStats().mergedSaves - merged, 2, reason: 'b and c are merged, a stays alone');
    });

    test('a merged batch shares its time by item count', () async {
      await open();
      users.slowBuild = const Duration(milliseconds: 10);
      FluentQueryCost saveCost() => FluentDb.queryStats(table: 'users').queries.firstWhere((FluentQueryCost c) => c.action == 'save');
      await users.saveAll([u(11, '11@x', 'a'), u(12, '12@x', 'b'), u(13, '13@x', 'c'), u(14, '14@x', 'd')]);
      final double perRow = saveCost().averageMs;
      FluentDb.forgetQueryStats();

      final (Completer<void> release, Future<void> done) = await hold();
      final List<Future<FluentSaveResult>> saves = [users.save(u(1, '1@x', 'a')), users.saveAll([u(2, '2@x', 'b'), u(3, '3@x', 'c'), u(4, '4@x', 'd')])];
      release.complete();
      await done;
      await Future.wait(saves);
      users.slowBuild = Duration.zero;
      // Every row costs the same; a share by call gives the one-row call twice the time, then a third (avg ~1.7x).
      expect(saveCost().averageMs, inInclusiveRange(perRow * 0.6, perRow * 1.4));
    });
  });

  group('W4 nested writes are atomic', () {
    test('a failing saveAll inside a transaction leaves none of its rows when the error is caught', () async {
      await open();
      await users.save(u(1, 'a@x', 'A'));
      await FluentDb.transaction(() async {
        try {
          await users.saveAll([u(10, 'ok@x', 'ok'), u(11, 'a@x', 'dup')]);
        } on FluentConstraintException {
          // handled by the app
        }
        await users.save(u(12, 'c@x', 'C'));
      });
      expect(await nameOf(10), isNull);
      expect(await nameOf(12), 'C');
      expect(await users.count(), 2);
    });

    test('nested savepoints roll back only their own part', () async {
      await open();
      await FluentDb.transaction(() async {
        await FluentTransactionScope.inTransaction(users.db, users.dbName, (txn) async {
          await txn.insert('users', {'id': 1, 'email': 'a@x', 'name': 'outer'});
          await expectLater(
            FluentTransactionScope.inTransaction(users.db, users.dbName, (txn) async {
              await txn.insert('users', {'id': 2, 'email': 'b@x', 'name': 'inner'});
              throw StateError('inner fails');
            }),
            throwsStateError,
          );
          await txn.insert('users', {'id': 3, 'email': 'c@x', 'name': 'after'});
        });
      });
      expect([await nameOf(1), await nameOf(2), await nameOf(3)], ['outer', null, 'after']);
    });
  });

  test('E5 a global resumeQueue also releases a waiting database pause', () async {
    await open();
    final (Completer<void> release, Future<void> done) = await hold();
    bool resumed = false;
    final Future<void> paused = FluentEngine().pauseQueue(dbName: users.dbName).then((_) => resumed = true);
    await pumpEventQueue();
    expect(resumed, isFalse, reason: 'the pause waits for the running transaction');
    FluentDb.resumeQueue();
    await paused.timeout(const Duration(seconds: 2));
    expect(resumed, isTrue);
    release.complete();
    await done;
    expect(await users.count(), 0, reason: 'the queue runs');
  });

  group('E6 shutdown', () {
    test('while globally paused it waits for the running transaction; queued calls fail, nothing written', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<void> paused = FluentDb.pauseQueue().catchError((Object _) {});
      final Future<Object> queued = users.save(u(1, 'a@x', 'A')).then<Object>((r) => r, onError: (Object e) => e);
      bool closed = false;
      final Future<void> closing = db.close().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse, reason: 'the running transaction is awaited');
      release.complete();
      await done; // committed, not cancelled
      await closing;
      await paused;
      expect(await queued, isA<FluentCancelledException>());
    });

    test('a paused database does not delay the close; its queued calls fail', () async {
      await open();
      await FluentDb.pauseQueue(dbKey: db.key);
      final Future<Object> queued = users.save(u(1, 'a@x', 'A')).then<Object>((r) => r, onError: (Object e) => e);
      final Stopwatch sw = Stopwatch()..start();
      await db.close();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await queued, isA<FluentCancelledException>());
      expect(db.issues.where((i) => i.kind == FluentIssueKind.shutdownTimeout), isEmpty);
    });

    test('after the drain timeout running calls finish; only queued ones are cancelled', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<Object> queued = users.save(u(1, 'a@x', 'A')).then<Object>((r) => r, onError: (Object e) => e);
      final StreamSubscription<FluentIssue> sub = FluentDb.onIssue().listen((i) {
        if (i.kind == FluentIssueKind.shutdownTimeout && !release.isCompleted) release.complete();
      });
      await FluentEngine().shutdown(drainTimeout: const Duration(milliseconds: 50));
      await sub.cancel();
      await done; // the transaction was not failed
      final Object result = await queued;
      expect(result, isA<FluentCancelledException>());
      expect((result as FluentCancelledException).hint, contains('Nothing of this call was written'));
    });
  });

  test('E7 the page cache is restored once a busy database becomes idle', () async {
    await open(config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
    await FluentTuner().handleMemoryPressure();
    final (Completer<void> release, Future<void> done) = await hold();
    await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
    // (the connection is held by the transaction: the cache is checked after it)
    release.complete();
    await done;
    await db.settle();
    await pumpEventQueue();
    expect((await users.rawQuery('PRAGMA cache_size')).single.values.single, isNot(-FluentTuner.lowMemoryCacheKib));
  });

  group('E9 priorities', () {
    test('a read that collapses onto a queued background read raises its priority', () async {
      await open();
      await users.saveAll([u(1, 'a@x', 'slow'), u(2, 'b@x', 'normal')]);
      final (Completer<void> release, Future<void> done) = await hold();
      users.mapped.clear();
      final Future<List<DynamicModel>> background = users.find(where: FluentFilter.eq('id', 1), policy: ExecutionPolicy.background);
      final Future<List<DynamicModel>> normal = users.find(where: FluentFilter.eq('id', 2));
      final Future<List<DynamicModel>> urgent = users.find(where: FluentFilter.eq('id', 1), policy: ExecutionPolicy.fast);
      release.complete();
      await done;
      await Future.wait([background, normal, urgent]);
      expect(users.mapped, ['slow', 'normal']);
    });

    test('a background read that waited long is not starved by newer urgent reads', () async {
      await open();
      await users.saveAll([u(1, 'a@x', 'old'), u(2, 'b@x', 'new')]);
      int now = 0;
      FluentEngine.clock = () => now;
      final (Completer<void> release, Future<void> done) = await hold();
      users.mapped.clear();
      final Future<List<DynamicModel>> waiting = users.find(where: FluentFilter.eq('id', 1), policy: ExecutionPolicy.background);
      now += 30000;
      final Future<List<DynamicModel>> fresh = users.find(where: FluentFilter.eq('id', 2), policy: ExecutionPolicy.fast);
      release.complete();
      await done;
      await Future.wait([waiting, fresh]);
      expect(users.mapped, ['old', 'new']);
    });
  });

  test('E10 the flush on close waits for a running idle flush and writes what changed meanwhile', () async {
    await open(persistent: true, config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
    await users.save(u(1, 'a@x', 'A'));
    await users.count();
    unawaited(FluentTuner().handleLifecycle(AppLifecycleState.paused)); // starts an idle flush
    final FluentTask late = FluentTask(table: 'users', dbName: users.dbName, action: FluentDbAction.find, helper: TableHelper(where: '"name" = ?', shape: '"name" = ? /* late */'));
    FluentTableStatsTracker().record(late, 5);
    await db.restart([ProbeProvider()]);
    final List<Map<String, Object?>> rows = await FluentDbInternals.lookupByTable('users', db.name)!.rawQuery('SELECT key FROM "${FluentTableStatsTracker.table}"');
    expect(rows.map((r) => r['key']), contains(contains('/* late */')));
  });

  test('E14 hints and warnings are reported once per key, also when the title changes', () async {
    await open();
    final List<FluentIssue> seen = [];
    final StreamSubscription<FluentIssue> sub = FluentDb.onIssue().listen(seen.add);
    FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: '3 rows', fix: 'f'));
    FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: '4 rows', fix: 'f'));
    FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 'other', title: '4 rows', fix: 'f'));
    await pumpEventQueue();
    expect(seen.map((i) => '${i.table}:${i.title}'), ['t:3 rows', 'other:4 rows']);
    await sub.cancel();
  });

  test('E15 reads adopted into a transaction count as running reads', () async {
    await open(config: const FluentConfig(transactionWatchdog: Duration(milliseconds: 30)));
    await users.save(u(1, 'a@x', 'A'));
    final Completer<Future<List<DynamicModel>>> outside = Completer<Future<List<DynamicModel>>>();
    Timer(const Duration(milliseconds: 10), () => outside.complete(Zone.root.run(() => users.findAll())));
    users.activeReadsSeen = null;
    await FluentDb.transaction(() async => await (await outside.future)).timeout(const Duration(seconds: 10));
    expect(users.activeReadsSeen, 1);
    expect(FluentEngine().stats.activeReads, 0);
  });
}
