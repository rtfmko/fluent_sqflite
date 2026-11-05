// Audit (task engine and transactions): expected correct behaviour. A failing test is a confirmed bug.
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
    db = FluentTestDb(name: 'audit_engine_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);
    await db.open([users]);
  });

  tearDown(() => db.close());

  DynamicModel u(int id, String email, String name) => users.row({'id': id, 'email': email, 'name': name});

  /// Holds the database's write slot until the returned completer completes: calls made meanwhile queue up.
  Future<Completer<void>> hold() async {
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    unawaited(
      FluentDb.transaction(() async {
        started.complete();
        await release.future;
      }),
    );
    await started.future;
    return release;
  }

  test('ENG-1: a nested transaction that throws rolls back its own writes', () async {
    // Doc of FluentDb.transaction: "If [action] throws, all its writes are rolled back". A nested transaction joins the
    // open one without a savepoint (fluent_db.dart _transactionOn returns action() directly), so its save survives.
    await FluentDb.transaction(() async {
      await users.save(u(1, 'a@x', 'outer'));
      try {
        await FluentDb.transaction(() async {
          await users.save(u(2, 'b@x', 'inner'));
          throw StateError('inner failed');
        });
      } on StateError {
        // the outer transaction goes on
      }
    });
    expect(await users.count(), 1, reason: 'the inner transaction failed, so its save must be rolled back');
  });

  test('ENG-2: clearing a database whose table cannot be emptied throws a typed exception', () async {
    await users.save(u(1, 'a@x', 'A'));
    await users.db.execute("CREATE TRIGGER audit_no_delete BEFORE DELETE ON users BEGIN SELECT RAISE(ABORT, 'locked'); END");
    // fluent_engine.dart _clearDatabase rethrows the raw DatabaseException of the last pass (`throw lastError!`).
    await expectLater(FluentDb.clear(dbKey: db.key), throwsA(isA<FluentException>()));
  });

  test('ENG-3 (control): a failing save in a merged batch keeps the saves before it', () async {
    final Completer<void> release = await hold();
    final Future<FluentSaveResult> first = users.save(u(1, 'a@x', 'A'));
    final Future<FluentSaveResult> second = users.save(u(2, 'a@x', 'duplicate email'));
    final int splitBefore = FluentDb.engineStats().splitBatches;
    release.complete();
    final Future<void> secondFails = expectLater(second, throwsA(isA<FluentException>()));
    await first;
    await secondFails;
    expect(FluentDb.engineStats().splitBatches - splitBefore, 1, reason: 'the adjacent saves were merged and then split');
    expect(await users.count(), 1);
  });

  test('ENG-4 (control): an identical read queued before a write does not share the result of one after it', () async {
    await users.save(u(1, 'a@x', 'A'));
    final Completer<void> release = await hold();
    final Future<int> before = users.count();
    final Future<FluentSaveResult> saved = users.save(u(2, 'b@x', 'B'));
    final Future<int> after = users.count();
    release.complete();
    expect(await before, 1);
    expect(await after, 2);
    await saved;
  });

  test('ENG-5 (control): a rolled back transaction publishes no change event, a committed one does', () async {
    final List<FluentChangeEvent<dynamic>> events = [];
    final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.where((e) => e.table == 'users').listen(events.add);
    addTearDown(sub.cancel);

    await expectLater(
      FluentDb.transaction(() async {
        await users.save(u(1, 'a@x', 'A'));
        throw StateError('roll back');
      }),
      throwsA(isA<StateError>()),
    );
    await db.settle();
    expect(events, isEmpty);

    await FluentDb.transaction(() async {
      await users.save(u(2, 'b@x', 'B'));
    });
    await db.settle();
    expect(events, hasLength(1));
  });

  test('ENG-6 (control): a lookup batch with a missing key and a repeated key answers in call order', () async {
    await users.saveAll([u(1, 'a@x', 'A'), u(2, 'b@x', 'B'), u(3, 'c@x', 'C')]);
    final Completer<void> release = await hold();
    final List<Future<DynamicModel?>> found = [users.findById(1), users.findById(9), users.findById(2), users.findById(2), users.findById(3)];
    release.complete();
    final List<DynamicModel?> rows = await Future.wait(found);
    expect([for (final DynamicModel? m in rows) m?.primaryKeyValue], [1, null, 2, 2, 3]);
  });

  test('ENG-7 (control): pauseQueue called inside a transaction is ignored and the transaction completes', () async {
    await FluentDb.transaction(() async {
      await users.save(u(1, 'a@x', 'A'));
      await FluentDb.pauseQueue();
    }).timeout(const Duration(seconds: 10));
    expect(await users.count(), 1);
  });
}
