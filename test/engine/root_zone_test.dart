// Tasks dispatched from the root zone (the analyzer's query plans, timers of the app). An error cannot cross from one
// error zone into another in Dart: code must await a task in the zone that started it (the analyzer once started
// its EXPLAIN in `Zone.root` and awaited it from a task zone, so a failing plan hung and crashed the test runner).
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();
  late FluentTestDb db;
  late DynamicProvider users;

  setUp(() async {
    db = FluentTestDb(name: 'root_zone');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
    await db.open([users]);
  });
  tearDown(() => db.close());

  FluentTask raw(String sql) => FluentTask(
    action: FluentDbAction.rawQuery,
    table: 'users',
    dbName: users.dbName,
    helper: TableHelper(sql: sql),
    policy: ExecutionPolicy.background,
    maxDepth: 0,
  );

  Future<List<Map<String, dynamic>>> run(FluentTask task) =>
      FluentDbInternals.executeTask<FluentStorable, List<Map<String, dynamic>>>(provider: users, task: task);

  /// Starts and awaits [task] inside [zone]; returns the rows or the error.
  Future<Object?> inZone(Zone zone, FluentTask task) {
    final Completer<Object?> outcome = Completer<Object?>();
    zone.run(() async {
      try {
        final List<Map<String, dynamic>> rows = await run(task);
        outcome.complete(rows);
      } catch (e) {
        outcome.complete(e);
      }
    });
    return outcome.future;
  }

  test('a failing task started and awaited in the root zone fails with a typed error', () async {
    final Object? r = await inZone(Zone.root, raw('SELECT * FROM users WHERE missing_column = 1')).timeout(const Duration(seconds: 5));
    expect(r, isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.sqlError));
  });

  test('a failing task in a forked root zone, and a later task, both complete', () async {
    final Zone forked = Zone.root.fork();
    expect(await inZone(forked, raw('SELECT nope FROM users')).timeout(const Duration(seconds: 5)), isA<FluentException>());
    await users.save(users.row({'id': 1, 'name': 'Ann'}));
    final Object? rows = await inZone(forked, raw('SELECT * FROM users')).timeout(const Duration(seconds: 5));
    expect((rows! as List<Map<String, dynamic>>).single['name'], 'Ann');
  });

  test('a successful task started in the root zone returns its rows', () async {
    await users.save(users.row({'id': 1, 'name': 'Ann'}));
    final Object? rows = await inZone(Zone.root, raw('SELECT * FROM users')).timeout(const Duration(seconds: 5));
    expect((rows! as List<Map<String, dynamic>>).single['name'], 'Ann');
  });
}
