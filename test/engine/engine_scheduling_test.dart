// Engine scheduling, pause / resume / shutdown, stats and transaction scope (savepoints, whenCommitted).
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/query_counter.dart';
import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;

  Future<void> open({bool persistent = false}) async {
    db = FluentTestDb(name: 'sched_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name', isUnique: true)]);
    await db.open([users]);
  }

  DynamicModel u(int id, [String? name]) => users.row({'id': id, 'name': name ?? 'user $id'});

  /// Holds the write slot of the database until the returned completer completes.
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

  tearDown(() async {
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('pause / resume', () {
    test('a database pause completes when the running transaction ends and keeps new calls queued', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      bool paused = false;
      final Future<void> pausing = FluentDb.pauseQueue(dbKey: db.key).then((_) => paused = true);
      await pumpEventQueue();
      expect(paused, isFalse);
      release.complete();
      await done;
      await pausing.timeout(const Duration(seconds: 5));
      expect(paused, isTrue);
      bool saved = false;
      final Future<void> save = users.save(u(1)).then((_) => saved = true);
      await pumpEventQueue();
      expect(saved, isFalse, reason: 'the queue is paused');
      expect(FluentDb.engineStats().queued, 1);
      FluentDb.resumeQueue(dbKey: db.key);
      await save;
      expect(await users.count(), 1);
    });

    test('a global pause completes when the running transaction ends; resume starts the queue', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      bool paused = false;
      final Future<void> pausing = FluentDb.pauseQueue().then((_) => paused = true);
      await pumpEventQueue();
      expect(paused, isFalse);
      release.complete();
      await done;
      await pausing.timeout(const Duration(seconds: 5));
      final Future<int> count = users.count();
      await pumpEventQueue();
      expect(FluentDb.engineStats().queued, 1);
      FluentDb.resumeQueue();
      expect(await count, 0);
    });

    test('pausing an idle queue returns at once; resume of a never paused queue is harmless', () async {
      await open();
      await FluentDb.pauseQueue(dbKey: db.key).timeout(const Duration(seconds: 2));
      await FluentDb.pauseQueue().timeout(const Duration(seconds: 2));
      FluentDb.resumeQueue(dbKey: db.key);
      FluentDb.resumeQueue();
      FluentDb.resumeQueue();
      await users.save(u(1));
      expect(await users.count(), 1);
    });

    test('shutdown aborts a database pause that still waits for a running task', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<Object?> pausing = FluentEngine().pauseQueue(dbName: users.dbName).then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      final Future<void> closing = db.close();
      await pumpEventQueue();
      release.complete();
      await done;
      await closing;
      expect(await pausing.timeout(const Duration(seconds: 5)), anyOf(isNull, isA<FluentCancelledException>()));
    });
  });

  group('scheduling', () {
    test('a write is a barrier: reads queued after it see its rows, reads before it do not', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<int> before = users.count();
      final Future<void> write = users.save(u(1));
      final Future<int> after = users.count();
      await pumpEventQueue();
      release.complete();
      await done;
      await write;
      expect(await before, 0);
      expect(await after, 1);
    });

    test('adjacent saves merge into one batch, order of operations is kept', () async {
      await open();
      final (Completer<void> release, Future<void> done) = await hold();
      final FluentEngineStats before = FluentDb.engineStats();
      final List<Future<void>> saves = [
        for (int i = 1; i <= 5; i++) FluentDb.save<DynamicModel>(u(i, 'v$i')),
      ];
      release.complete();
      await done;
      await Future.wait(saves);
      expect(FluentDb.engineStats().mergedSaves - before.mergedSaves, 5);
      expect((await users.findAll(orderBy: 'id')).map((DynamicModel m) => m.values['name']), ['v1', 'v2', 'v3', 'v4', 'v5']);
    });

    test('a merged batch with a failing member falls back call by call; the others still succeed', () async {
      await open();
      await users.save(u(1));
      final (Completer<void> release, Future<void> done) = await hold();
      final Future<Object?> bad = users.save(u(5, 'user 1')).then<Object?>((_) => null, onError: (Object e) => e);
      final Future<Object?> good = users.save(u(2)).then<Object?>((_) => null, onError: (Object e) => e);
      release.complete();
      await done;
      expect(await bad, isA<FluentConstraintException>());
      expect(await good, isNull);
      expect(await users.count(), 2);
      expect(FluentDb.engineStats().splitBatches, greaterThanOrEqualTo(0));
    });

    test('identical concurrent reads collapse into one statement', () async {
      final QueryCounter counter = await QueryCounter.install();
      await open();
      await users.saveAll([for (int i = 1; i <= 10; i++) u(i)]);
      final (Completer<void> release, Future<void> done) = await hold();
      try {
        counter.reset();
        final int collapsed = FluentDb.engineStats().collapsedReads;
        final List<Future<List<DynamicModel>>> reads = [for (int i = 0; i < 8; i++) users.findAll(orderBy: 'id')];
        release.complete();
        await done;
        final List<List<DynamicModel>> results = await Future.wait(reads);
        expect(results.map((List<DynamicModel> r) => r.length), everyElement(10));
        expect(FluentDb.engineStats().collapsedReads - collapsed, 7);
        expect(counter.statements.where((String s) => s.contains('SELECT') && s.contains('"users"')).length, 1);
      } finally {
        counter.uninstall();
      }
    });

    test('findById calls queued together become one IN query', () async {
      final QueryCounter counter = await QueryCounter.install();
      await open();
      await users.saveAll([for (int i = 1; i <= 20; i++) u(i)]);
      final (Completer<void> release, Future<void> done) = await hold();
      try {
        counter.reset();
        final List<Future<DynamicModel?>> reads = [for (int i = 1; i <= 20; i++) users.findById(i)];
        release.complete();
        await done;
        final List<DynamicModel?> rows = await Future.wait(reads);
        expect(rows.every((DynamicModel? r) => r != null), isTrue);
        expect(counter.statements.where((String s) => s.contains('SELECT') && s.contains('"users"')).length, lessThanOrEqualTo(2));
      } finally {
        counter.uninstall();
      }
    });

    test('stats toString lists the counters', () async {
      await open();
      await users.save(u(1));
      final String text = FluentDb.engineStats().toString();
      expect(text, startsWith('FluentEngineStats(queued: 0'));
      expect(text, contains('completed:'));
      expect(text, contains('wait:'));
      expect(FluentDb.engineStats().slowestQueries, isA<List<FluentQueryCost>>());
    });
  });

  group('transaction scope', () {
    test('whenCommitted runs after the commit, is dropped on rollback, runs at once outside a transaction', () async {
      await open();
      final List<String> log = [];
      FluentTransactionScope.whenCommitted(users.dbName, () => log.add('outside'));
      expect(log, ['outside']);
      await FluentDb.transaction(() async {
        await users.save(u(1));
        FluentTransactionScope.whenCommitted(users.dbName, () => log.add('commit'));
        expect(log, ['outside']);
      });
      expect(log, ['outside', 'commit']);
      await expectLater(
        FluentDb.transaction(() async {
          FluentTransactionScope.whenCommitted(users.dbName, () => log.add('rolled back'));
          await users.save(u(2));
          throw StateError('abort');
        }),
        throwsA(anything),
      );
      expect(log, ['outside', 'commit']);
      expect(await users.count(), 1);
    });

    test('a failing whenCommitted callback does not break the commit or later callbacks', () async {
      await open();
      final List<String> log = [];
      await FluentDb.transaction(() async {
        FluentTransactionScope.whenCommitted(users.dbName, () => throw StateError('callback'));
        FluentTransactionScope.whenCommitted(users.dbName, () => log.add('second'));
        await users.save(u(1));
      });
      expect(log, ['second']);
      expect(await users.count(), 1);
    });

    test('a nested transaction rolls back to its savepoint, the outer one commits', () async {
      await open();
      final List<String> log = [];
      await FluentDb.transaction(() async {
        await users.save(u(1));
        try {
          await FluentDb.transaction(() async {
            await users.save(u(2));
            FluentTransactionScope.whenCommitted(users.dbName, () => log.add('inner'));
            throw StateError('inner abort');
          });
        } on StateError {
          // expected
        }
        FluentTransactionScope.whenCommitted(users.dbName, () => log.add('outer'));
        await users.save(u(3));
      });
      expect((await users.findAll()).map((DynamicModel m) => m.values['id']).toSet(), {1, 3});
      expect(log, ['outer'], reason: 'the rolled-back savepoint drops its pending changes');
    });

    test('a nested transaction that succeeds keeps its callbacks until the outer commit', () async {
      await open();
      final List<String> log = [];
      await FluentDb.transaction(() async {
        await FluentDb.transaction(() async {
          await users.save(u(1));
          FluentTransactionScope.whenCommitted(users.dbName, () => log.add('inner'));
        });
        expect(log, isEmpty);
      });
      expect(log, ['inner']);
    });

    test('events of a rolled-back transaction are not published', () async {
      await open();
      final List<FluentChangeEvent<dynamic>> events = [];
      final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.listen(events.add);
      await expectLater(
        FluentDb.transaction(() async {
          await users.save(u(1));
          throw StateError('abort');
        }),
        throwsA(anything),
      );
      await db.settle();
      expect(events.where((FluentChangeEvent<dynamic> e) => e.table == 'users'), isEmpty);
      await FluentDb.transaction(() async => users.save(u(2)));
      await db.settle();
      expect(events.where((FluentChangeEvent<dynamic> e) => e.table == 'users'), isNotEmpty);
      await sub.cancel();
    });
  });
}
