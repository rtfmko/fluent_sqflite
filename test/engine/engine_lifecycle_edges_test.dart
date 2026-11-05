// Engine lifecycle edges: stats timer on close, failures inside transactions and merged batches,
// a re-init while a pooled read is in flight, and an unregistered table.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

/// Fails to map rows once [failMapping] is on.
class FlakyProvider extends DynamicProvider {
  FlakyProvider() : super('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name', isUnique: true)]);

  bool failMapping = false;

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) {
    if (failMapping) throw StateError('cannot map');
    return super.fromCacheJson(json);
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late FlakyProvider users;

  Future<void> open({bool persistent = true}) async {
    db = FluentTestDb(name: 'edges_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
    users = FlakyProvider();
    await db.open([users]);
  }

  DynamicModel u(int id, [String? name]) => users.row({'id': id, 'name': name ?? 'user $id'});

  tearDown(() async {
    FluentEngine.statsFlushInterval = const Duration(minutes: 5);
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  test('close while the stats timer is armed cancels it and still writes the stats', () async {
    await open();
    await users.save(u(1));
    await users.findAll(orderBy: 'id'); // first flush happens, the next change arms the timer (5 min)
    await db.settle();
    await users.find(where: FluentFilter.eq('name', 'user 1'));
    await users.find(where: FluentFilter.eq('id', 1));
    await db.settle();
    await db.close();
    expect(FluentDb.isOpen(), isFalse);
  });

  test('a failing call inside a transaction fails alone, the transaction goes on', () async {
    await open();
    await users.save(u(1));
    await FluentDb.transaction(() async {
      await expectLater(users.save(u(2, 'user 1')), throwsA(isA<FluentConstraintException>()));
      await users.save(u(3));
    });
    expect((await users.findAll(orderBy: 'id')).map((DynamicModel m) => m.values['id']), [1, 3]);
  });

  test('merged findById batch whose mapping throws: every caller gets the error, the engine goes on', () async {
    await open();
    await users.saveAll([for (int i = 1; i <= 5; i++) u(i)]);
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    final Future<void> done = FluentDb.transaction(() async {
      started.complete();
      await release.future;
    });
    await started.future;
    users.failMapping = true;
    final List<Future<Object?>> reads = [for (int i = 1; i <= 5; i++) users.findById(i).then<Object?>((DynamicModel? r) => r, onError: (Object e) => e)];
    release.complete();
    await done;
    final List<Object?> results = await Future.wait(reads);
    expect(results, everyElement(isNotNull));
    expect(results.whereType<DynamicModel>(), isEmpty);
    users.failMapping = false;
    expect((await users.findById(1))!.values['id'], 1);
  });

  test('a task for a table nobody registered fails with a typed error', () async {
    await open();
    final FluentTask task = FluentTask(table: 'ghost', dbName: users.dbName, action: FluentDbAction.find, helper: TableHelper());
    Object? error;
    try {
      await FluentEngine().dispatch(task);
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect(await users.count(), 0, reason: 'the engine still works');
  });

  test('a re-init while a pooled read runs lets that read finish and closes its connection afterwards', () async {
    await open();
    await users.saveAll([for (int i = 1; i <= 3; i++) u(i)]);
    expect(FluentEngine().readConnectionCount(db.name), greaterThan(0));
    final Future<List<Map<String, dynamic>>> slow = users.rawQuery('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1500000) SELECT COUNT(*) AS n FROM c');
    await pumpEventQueue(times: 5);
    await FluentEngine().initMultiple(configs: {}, dbRelationsCount: {}, dbNameWithDb: {});
    final List<Map<String, dynamic>> rows = await slow;
    expect(rows.single['n'], 1500000);
    expect(FluentEngine().readConnectionCount(db.name), 0);
  });
}
