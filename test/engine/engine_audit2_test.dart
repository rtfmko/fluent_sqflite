// Audit 2, engine and transactions (KNOWN_BUGS items 6-13): merged saves of one model / one row, keys of rolled-back
// inserts, clear / purge / cleanOrphans inside transactions and tasks, transactions on two databases, a re-entrant
// scheduler pass, and automatic indexes of an earlier run.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';

const Duration _limit = Duration(seconds: 5);

void main() {
  setUpFluentTests();

  group('one database', () {
    late FluentTestDb db;
    late DynamicProvider users;

    DynamicProvider usersTable() =>
        DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name'), FluentDbColumn.text('note')]);

    setUp(() async {
      db = FluentTestDb(name: 'engine_audit2_${DateTime.now().microsecondsSinceEpoch}');
      users = usersTable();
      await db.open([users]);
    });

    tearDown(() async {
      FluentEngine.observerProbe = null;
      await db.close().timeout(_limit);
    });

    /// Holds the queue with an open transaction until the returned completer completes, so the calls made meanwhile
    /// queue up behind it (and adjacent saves are merged).
    Future<Completer<void>> hold() async {
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      unawaited(
        FluentDb.transaction(() async {
          started.complete();
          await release.future;
        }),
      );
      await started.future.timeout(_limit);
      return release;
    }

    int merged() => FluentDb.engineStats().mergedSaves;

    group('item 6: adjacent saves of the same new model', () {
      test('a double tap on a new model without a key stores one row', () async {
        final DynamicModel m = users.row({'id': null, 'email': null, 'name': 'tap'});
        final Completer<void> release = await hold();
        final Future<FluentSaveResult> f1 = users.save(m);
        final Future<FluentSaveResult> f2 = users.save(m);
        release.complete();
        await f1.timeout(_limit);
        await f2.timeout(_limit);
        final List<DynamicModel> rows = await users.findAll();
        expect(rows, hasLength(1), reason: 'the second save updates the row the first inserted');
        expect(m.primaryKeyValue, rows.single['id']);
      });

      test('edge: the model inside a saveAll list and then saved alone is stored once; other new models still merge', () async {
        final DynamicModel a = users.row({'id': null, 'email': 'a@x', 'name': 'a'});
        final DynamicModel b = users.row({'id': null, 'email': 'b@x', 'name': 'b'});
        final DynamicModel c = users.row({'id': null, 'email': 'c@x', 'name': 'c'});
        final int before = merged();
        final Completer<void> release = await hold();
        final Future<FluentSaveResult> f1 = users.saveAll([a, b]);
        final Future<FluentSaveResult> f2 = users.save(c); // another new model: merged with the first call
        final Future<FluentSaveResult> f3 = users.save(a); // the same instance again: a new batch
        release.complete();
        await Future.wait([f1, f2, f3]).timeout(_limit);
        expect(merged() - before, 2, reason: 'saveAll([a, b]) + save(c) merged, save(a) ran on its own');
        final List<DynamicModel> rows = await users.findAll(orderBy: 'id');
        expect(rows.map((r) => r['email']), ['a@x', 'b@x', 'c@x']);
      });
    });

    group('item 10: merged patch saves match the key the library keeps', () {
      test('two patch saves of one row (generated key kept in metadata) keep both patches', () async {
        final DynamicModel a = users.row({'id': null, 'email': 'a@x', 'name': 'A', 'note': 'n0'});
        await users.save(a);
        final Object? id = a.primaryKeyValue;
        expect(a.buildJson()['id'], isNull, reason: 'the key lives in metadata only');
        final DynamicModel b = users.row({'id': id, 'email': null, 'name': null, 'note': 'fromB'});
        final Completer<void> release = await hold();
        a.values['name'] = 'fromA';
        a.values['note'] = null;
        final Future<FluentSaveResult> f1 = users.save(a, strategy: FluentSaveStrategy.patch);
        final Future<FluentSaveResult> f2 = users.save(b, strategy: FluentSaveStrategy.patch);
        release.complete();
        await Future.wait([f1, f2]).timeout(_limit);
        final DynamicModel? row = await users.findById(id);
        expect(row?['note'], 'fromB');
        expect(row?['name'], 'fromA', reason: 'sequential patches: name from a, note from b');
      });

      test('edge: patch saves of two different rows with keys in metadata are still merged', () async {
        final DynamicModel a = users.row({'id': null, 'email': 'a@x', 'name': 'A'});
        final DynamicModel b = users.row({'id': null, 'email': 'b@x', 'name': 'B'});
        await users.saveAll([a, b]);
        final int before = merged();
        final Completer<void> release = await hold();
        a.values['name'] = 'A2';
        b.values['name'] = 'B2';
        final Future<FluentSaveResult> f1 = users.save(a, strategy: FluentSaveStrategy.patch);
        final Future<FluentSaveResult> f2 = users.save(b, strategy: FluentSaveStrategy.patch);
        release.complete();
        await Future.wait([f1, f2]).timeout(_limit);
        expect(merged() - before, 2);
        expect((await users.findAll(orderBy: 'id')).map((r) => r['name']), ['A2', 'B2']);
      });
    });

    group('item 7: keys of a rolled-back insert are taken back', () {
      test('a key generated in a rolled-back transaction is not reused for another row', () async {
        final DynamicModel a = users.row({'id': null, 'email': 'a@x', 'name': 'A'});
        Object? inside;
        await expectLater(
          FluentDb.transaction(() async {
            await users.save(a);
            inside = a.primaryKeyValue;
            throw StateError('roll back');
          }).timeout(_limit),
          throwsStateError,
        );
        expect(inside, isNotNull, reason: 'visible at once inside the transaction');
        expect(a.primaryKeyValue, isNull, reason: 'the row is gone, so is its key');
        final DynamicModel x = users.row({'id': null, 'email': 'x@x', 'name': 'X'});
        await users.save(x);
        a.values['name'] = 'A2';
        await users.save(a);
        final List<DynamicModel> rows = await users.findAll(orderBy: 'id');
        expect(rows.map((r) => r['email']).toSet(), {'a@x', 'x@x'}, reason: 'x must not be overwritten by a');
      });

      test('edge: a rolled-back savepoint takes back only its own keys; a committed transaction keeps them', () async {
        final DynamicModel kept = users.row({'id': null, 'email': 'k@x', 'name': 'K'});
        final DynamicModel dropped = users.row({'id': null, 'email': 'd@x', 'name': 'D'});
        await FluentDb.transaction(() async {
          await users.save(kept);
          try {
            await FluentDb.transaction(() async {
              await users.save(dropped);
              expect(dropped.primaryKeyValue, isNotNull);
              throw StateError('roll back the savepoint');
            });
          } on StateError {
            // the outer transaction goes on
          }
        }).timeout(_limit);
        expect(kept.primaryKeyValue, isNotNull);
        expect(dropped.primaryKeyValue, isNull);
        expect(await users.findById(kept.primaryKeyValue), isNotNull);
      });

      test('edge: a failing save inside a transaction (caught) takes back the keys it gave', () async {
        final DynamicModel first = users.row({'id': null, 'email': 'same@x', 'name': '1'});
        final DynamicModel fresh = users.row({'id': null, 'email': 'fresh@x', 'name': '2'});
        final DynamicModel clash = users.row({'id': null, 'email': 'same@x', 'name': '3'});
        await users.save(first);
        await FluentDb.transaction(() async {
          // One call, two rows: the second violates UNIQUE(email), the savepoint of the call rolls back both.
          await expectLater(users.saveAll([fresh, clash]), throwsA(isA<FluentException>()));
        }).timeout(_limit);
        expect(fresh.primaryKeyValue, isNull);
        expect(await users.count(), 1);
      });
    });

    group('item 8: clear and purgeArchivedColumns inside a transaction or task', () {
      test('clear inside a transaction runs in it; the event follows the commit', () async {
        await users.save(users.row({'id': 1, 'email': 'a@x', 'name': 'A'}));
        final List<FluentChangeEvent<dynamic>> events = [];
        final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.listen(events.add);
        await FluentDb.transaction(() async {
          await FluentDb.clear().timeout(_limit);
          expect(await users.count(), 0, reason: 'the transaction sees the empty table');
          await pumpEventQueue();
          expect(events.where((e) => e.kind == FluentChangeKind.clear), isEmpty, reason: 'not before the commit');
        }).timeout(_limit);
        await db.settle();
        await sub.cancel();
        expect(await users.count(), 0);
        expect(events.where((e) => e.kind == FluentChangeKind.clear && e.table == 'users'), hasLength(1));
      });

      test('edge: a rolled-back transaction keeps the rows and publishes no clear', () async {
        await users.save(users.row({'id': 1, 'email': 'a@x', 'name': 'A'}));
        final List<FluentChangeEvent<dynamic>> events = [];
        final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.listen(events.add);
        await expectLater(
          FluentDb.transaction(() async {
            await FluentDb.clear(dbKey: db.key);
            throw StateError('roll back');
          }).timeout(_limit),
          throwsStateError,
        );
        await db.settle();
        await sub.cancel();
        expect(await users.count(), 1);
        expect(events.where((e) => e.kind == FluentChangeKind.clear), isEmpty);
      });

      test('edge: clear inside another task of the database is skipped and reported, never hangs', () async {
        await users.save(users.row({'id': 1, 'email': 'a@x', 'name': 'A'}));
        await FluentEngine()
            .dispatch(
              FluentTask(
                action: FluentDbAction.transaction,
                dbName: db.name,
                data: () async {
                  await FluentDb.clear().timeout(_limit);
                  return null;
                },
              ),
            )
            .timeout(_limit);
        expect(await users.count(), 1);
        expect(db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall && i.subject == 'clear'), hasLength(1));
      });

      test('purgeArchivedColumns inside a transaction completes (skipped and reported)', () async {
        await FluentDb.transaction(() async {
          await FluentDb.purgeArchivedColumns(olderThan: Duration.zero).timeout(_limit);
        }).timeout(_limit);
        await db.settle();
        expect(db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall && i.subject == 'purgeArchivedColumns'), hasLength(1));
      });
    });

    group('item 12: cleanOrphans', () {
      test('edge: inside a transaction it joins it; inside another task it is skipped and reported', () async {
        await FluentDb.transaction(() => FluentDb.cleanOrphans().timeout(_limit)).timeout(_limit);
        await FluentEngine()
            .dispatch(
              FluentTask(
                action: FluentDbAction.transaction,
                dbName: db.name,
                data: () async {
                  await FluentDb.cleanOrphans().timeout(_limit);
                  return null;
                },
              ),
            )
            .timeout(_limit);
        await db.settle();
        expect(db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall && i.subject == 'cleanOrphans'), hasLength(1));
      });
    });
  });

  group('purgeArchivedColumns with an archived column', () {
    test('item 8: skipped inside a transaction (archive kept), done outside it', () async {
      final FluentTestDb db = FluentTestDb(name: 'engine_audit2_purge_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final DynamicProvider v1 = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.text('note')]);
      await db.open([v1]);
      await v1.save(v1.row({'id': 1, 'name': 'a', 'note': 'n'}));
      final DynamicProvider v2 = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      await db.restart([v2]);
      Future<int> columns() async => (await v2.rawQuery("PRAGMA table_info('t')")).length;
      final int archived = await columns();
      expect(archived, greaterThan(2), reason: 'the removed column is archived');
      db.clock.advance(const Duration(minutes: 1)); // older than Duration.zero
      await FluentDb.transaction(() => FluentDb.purgeArchivedColumns(olderThan: Duration.zero)).timeout(_limit);
      expect(await columns(), archived, reason: 'nothing purged inside the transaction');
      await FluentDb.purgeArchivedColumns(olderThan: Duration.zero).timeout(_limit);
      expect(await columns(), archived - 1, reason: 'the archive is purged');
      expect(await v2.count(), 1);
      await db.close().timeout(_limit);
    });
  });

  group('item 12: cleanOrphans is queued and publishes events', () {
    test('the cleaned table publishes a change event; earlier queued writes run first', () async {
      final FluentTestDb db = FluentTestDb(name: 'engine_audit2_orphans_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final PersonProvider people = PersonProvider();
      await db.open([people, ProfileProvider()], config: const FluentDbConfig(enableForeignKeys: false));
      final List<String> fk = [for (final Map<String, Object?> r in await people.db.rawQuery("PRAGMA foreign_key_list('people')")) r['from']! as String];
      await people.db.execute('INSERT INTO people (name, ${fk.first.quotedIdentifier}) VALUES (?, ?)', ['orphan', 12345]);
      final List<FluentChangeEvent<dynamic>> events = [];
      final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.listen(events.add);
      final Future<FluentSaveResult> before = people.save(Person(name: 'saved before'));
      await FluentDb.cleanOrphans().timeout(_limit);
      expect(await before.timeout(_limit), isNotNull);
      await db.settle();
      await sub.cancel();
      expect(events.where((e) => e.table == 'people' && e.kind == FluentChangeKind.update), isNotEmpty);
      final List<Map<String, Object?>> orphans = await people.db.rawQuery('SELECT * FROM people WHERE ${fk.first.quotedIdentifier} = 12345');
      expect(orphans, isEmpty);
      await db.close().timeout(_limit);
    });
  });

  group('item 9: transactions on two databases', () {
    late DynamicProvider a;
    late DynamicProvider b;
    late FluentDbKey keyA;
    late FluentDbKey keyB;

    setUp(() async {
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      a = DynamicProvider('a_items', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      b = DynamicProvider('b_items', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      keyA = FluentDbKey('audit2_a_${DateTime.now().microsecondsSinceEpoch}');
      keyB = FluentDbKey('audit2_b_${DateTime.now().microsecondsSinceEpoch}');
      await FluentDb.init([
        FluentGroup(dbKey: keyA, providerList: [a], inMemory: true),
        FluentGroup(dbKey: keyB, providerList: [b], inMemory: true),
      ]);
    });

    tearDown(() async {
      FluentEngine.observerProbe = null;
      await FluentEngine().whenIdle(_limit);
      await FluentDb.close().timeout(_limit);
    });

    test('a write to B inside a transaction on A inside a transaction on B joins B', () async {
      await FluentDb.transaction(dbKey: keyB, () async {
        await b.save(b.row({'id': 1, 'name': 'b1'}));
        await FluentDb.transaction(dbKey: keyA, () async {
          await a.save(a.row({'id': 1, 'name': 'a1'}));
          await b.save(b.row({'id': 2, 'name': 'b2'})).timeout(_limit);
          expect(await b.count().timeout(_limit), 2);
        });
      }).timeout(_limit);
      expect(await b.count(), 2);
      expect(await a.count(), 1);
    });

    test('edge: the outer transaction on B rolls back the B write made inside A; A keeps its commit', () async {
      await expectLater(
        FluentDb.transaction(dbKey: keyB, () async {
          await FluentDb.transaction(dbKey: keyA, () async {
            await a.save(a.row({'id': 1, 'name': 'a1'}));
            await b.save(b.row({'id': 2, 'name': 'b2'})).timeout(_limit);
          });
          throw StateError('roll back B');
        }).timeout(_limit),
        throwsStateError,
      );
      expect(await b.count(), 0);
      expect(await a.count(), 1);
    });

    test('edge: a transaction on B inside A inside B is a savepoint of the outer B transaction', () async {
      await FluentDb.transaction(dbKey: keyB, () async {
        await FluentDb.transaction(dbKey: keyA, () async {
          try {
            await FluentDb.transaction(dbKey: keyB, () async {
              await b.save(b.row({'id': 3, 'name': 'b3'}));
              throw StateError('roll back the savepoint');
            }).timeout(_limit);
          } on StateError {
            // only the savepoint is rolled back
          }
          await b.save(b.row({'id': 4, 'name': 'b4'})).timeout(_limit);
        });
      }).timeout(_limit);
      expect((await b.findAll()).map((r) => r['id']), [4]);
    });

    test('item 8 edge: clear of B inside a transaction on A inside B runs in the B transaction', () async {
      await b.save(b.row({'id': 1, 'name': 'b1'}));
      await FluentDb.transaction(dbKey: keyB, () async {
        await FluentDb.transaction(dbKey: keyA, () async {
          await FluentDb.clear(dbKey: keyB).timeout(_limit);
          await FluentDb.clear(dbKey: keyA).timeout(_limit);
        });
      }).timeout(_limit);
      expect(await b.count(), 0);
    });

    test('item 11: a re-entrant pass started from a hook never starts a read before a write taken by the same pass', () async {
      await FluentEngine().pauseQueue();
      // Both databases: a write at the head and a read behind it. One pass takes both writes; the first one started
      // calls the database from its hook (a synchronous log sink, an observer), which schedules again.
      final Future<FluentSaveResult> wa = a.save(a.row({'id': 1, 'name': 'a1'}));
      final Future<int> ra = a.count();
      final Future<FluentSaveResult> wb = b.save(b.row({'id': 1, 'name': 'b1'}));
      final Future<int> rb = b.count();
      bool fired = false;
      Future<int>? reentrant;
      FluentEngine.observerProbe = (hook) {
        if (hook != 'onStart' || fired) return;
        fired = true;
        reentrant = a.count();
      };
      FluentEngine().resumeQueue();
      await Future.wait([wa, wb]).timeout(_limit);
      expect(fired, isTrue);
      expect(await ra.timeout(_limit), 1, reason: 'a read queued after a write sees it');
      expect(await rb.timeout(_limit), 1, reason: 'a read queued after a write sees it');
      expect(await reentrant!.timeout(_limit), 1);
    });
  });

  group('item 13: automatic indexes of an earlier run', () {
    test('a read proposing an index that exists from an earlier run is served by it, not counted again', () async {
      final DynamicProvider users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      final FluentTestDb db = FluentTestDb(name: 'engine_audit2_tuner_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final FluentConfig config = FluentConfig(diagnostics: FluentDiagnostics(tuning: FluentTuning.full.copyWith(maxIndexes: 2)));
      await db.open([users], fluentConfig: config);
      await users.execute('CREATE INDEX "fluent_auto_users_status" ON "users" ("status")');
      final DynamicProvider again = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      await db.restart([again], fluentConfig: config);
      FluentTask read(String column) => FluentTask(
        table: again.tableName,
        dbName: again.dbName,
        action: FluentDbAction.find,
        helper: TableHelper(where: '"$column" = ?', whereArgs: const ['a'], shape: '"$column" = ?'),
      );
      FluentTuner().proposeIndex(read('status'), again, const ['status']);
      FluentTuner().proposeIndex(read('age'), again, const ['age']);
      await db.settle();
      final Set<String> indexes = {for (final r in await again.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']! as String};
      expect(indexes, containsAll(['fluent_auto_users_status', 'fluent_auto_users_age']), reason: 'the cap of 2 holds both');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tuned && i.subject == 'status'), isEmpty, reason: 'not created again');
      await db.close().timeout(_limit);
    });

    test('edge: the earlier index still counts against the cap', () async {
      final DynamicProvider users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      final FluentTestDb db = FluentTestDb(name: 'engine_audit2_tuner2_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final FluentConfig config = FluentConfig(diagnostics: FluentDiagnostics(tuning: FluentTuning.full.copyWith(maxIndexes: 1)));
      await db.open([users], fluentConfig: config);
      await users.execute('CREATE INDEX "fluent_auto_users_status" ON "users" ("status")');
      final DynamicProvider again = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      await db.restart([again], fluentConfig: config);
      FluentTuner().proposeIndex(
        FluentTask(table: 'users', dbName: again.dbName, action: FluentDbAction.find, helper: TableHelper(where: '"age" = ?', whereArgs: const ['a'], shape: '"age" = ?')),
        again,
        const ['age'],
      );
      await db.settle();
      final Set<String> indexes = {for (final r in await again.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']! as String};
      expect(indexes, isNot(contains('fluent_auto_users_age')));
      await db.close().timeout(_limit);
    });
  });
}
