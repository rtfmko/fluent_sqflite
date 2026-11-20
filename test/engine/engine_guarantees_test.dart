// Guarantee tests of the engine (TEST_PLAN.md, agent T3): order and read-your-writes (G7), no hang (G12), isolation
// of databases with same-named tables (G30), merged batches that fail (G1).
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/faults.dart';
import '../helpers/guarantees.dart';
import '../helpers/schema_models.dart';

const Duration _limit = Duration(seconds: 5);

List<FluentDbColumn> _itemColumns() => [FluentDbColumn.integer('id'), FluentDbColumn.text('code', isUnique: true), FluentDbColumn.text('name'), FluentDbColumn.integer('qty')];

DynamicProvider _items([String table = 'items']) => DynamicProvider(table, _itemColumns);

/// A model's stored values without the library's internals, for comparisons.
Map<String, Object?> _row(DynamicModel m) => {for (final String c in const ['id', 'code', 'name', 'qty']) c: m[c]};

Future<List<Map<String, Object?>>> _all(DynamicProvider p) async => [for (final DynamicModel m in await p.find(orderBy: 'id')) _row(m)];

/// `FluentTestDb.settle` for databases opened without it: no call queued or running, and no change for one frame.
Future<void> _settle() async {
  final FluentEngine engine = FluentEngine();
  for (int round = 0; round < 100; round++) {
    if (!await engine.whenIdle(_limit)) fail('G12: the library is still busy after $_limit');
    bool changed = false;
    final StreamSubscription<Object?> changes = engine.changeStream.listen((_) => changed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await changes.cancel();
    if (!changed && engine.isIdle) return;
  }
  fail('G12: the library never became quiet');
}

/// A converter that calls back into the library once when the value `fire` is written (user code running inside a
/// task: G12).
class _HookConverter extends FluentConverter<String, String> {
  const _HookConverter();

  static void Function()? onFire;

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(String value) {
    if (value == 'fire') {
      final void Function()? hook = onFire;
      onFire = null;
      hook?.call();
    }
    return value;
  }

  @override
  String fromSql(String value) => value;
}

/// An owner with one owned badge whose code is UNIQUE (merged saves on a table with relations, G7).
class _Owner extends FluentStorable with FluentRelations {
  _Owner({this.id, required this.name, this.badge});

  final int? id;
  final String name;
  final _Badge? badge;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.oneOwned<_Owner, _Badge>('badge', (o) => o.badge)];
}

class _Badge extends FluentStorable {
  _Badge({this.id, required this.code});

  final int? id;
  final String code;

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('code', isUnique: true)];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'code': code};
}

class _OwnerProvider extends FluentProvider<_Owner> {
  @override
  String get tableName => 'owners';

  @override
  _Owner get modelSample => _Owner(name: '');

  @override
  _Owner fromCacheJson(Map<String, dynamic> json) => _Owner(id: json['id'] as int?, name: json['name'] as String, badge: json['badge'] as _Badge?);
}

class _BadgeProvider extends FluentProvider<_Badge> {
  @override
  String get tableName => 'badges';

  @override
  _Badge get modelSample => _Badge(code: '');

  @override
  _Badge fromCacheJson(Map<String, dynamic> json) => _Badge(id: json['id'] as int?, code: json['code'] as String);
}

class _SyncNote extends FluentStorable {
  _SyncNote({this.id, required this.text});

  final String? id;
  final String text;

  // A key made on the device, as synced tables should have.
  @override
  FluentDbColumn get primaryKey => FluentDbColumn.text('id');

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.text('id'), FluentDbColumn.text('text')];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class _SyncNotes extends FluentProvider<_SyncNote> with FluentSyncable<_SyncNote> {
  @override
  String get tableName => 'sync_notes';

  @override
  _SyncNote get modelSample => _SyncNote(text: '');

  @override
  _SyncNote fromCacheJson(Map<String, dynamic> json) => _SyncNote(id: json['id'] as String?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  group('one database', () {
    late FluentTestDb db;
    late DynamicProvider items;

    setUp(() async {
      db = FluentTestDb();
      items = _items();
      await db.open([items]);
    });

    tearDown(() async {
      FluentDb.resumeQueue();
      await db.close().timeout(_limit);
    });

    DynamicModel item(int? id, {String? code, String? name, int? qty}) => items.row({'id': id, 'code': code, 'name': name, 'qty': qty});

    test('G7: patches of one row called back to back apply in call order; each read called between them sees the writes before it', () async {
      await items.save(item(1, code: 'a', name: 'n0', qty: 0));
      await FluentDb.pauseQueue(dbKey: db.key);
      final List<Future<Object?>> calls = [];
      final List<String> names = [];
      for (int i = 1; i <= 6; i++) {
        calls.add(items.save(item(1, name: 'n$i', qty: i.isEven ? i : null), strategy: FluentSaveStrategy.patch));
        names.add('patch $i');
        calls.add(items.findById(1));
        names.add('read after patch $i');
        calls.add(items.findById(1, policy: ExecutionPolicy.background));
        names.add('background read after patch $i');
      }
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled(calls, names: names);
      int qty = 0;
      for (int i = 1; i <= 6; i++) {
        if (i.isEven) qty = i;
        for (final int k in [3 * (i - 1) + 1, 3 * (i - 1) + 2]) {
          final DynamicModel m = r[k].value! as DynamicModel;
          expect(m['name'], 'n$i', reason: names[k]);
          expect(m['qty'], qty, reason: '${names[k]}: a patch keeps the fields it leaves null');
        }
      }
      expect(await _all(items), [
        {'id': 1, 'code': 'a', 'name': 'n6', 'qty': 6},
      ]);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: the same new model saved twice without awaiting stores one row and keeps the last values', () async {
      final DynamicModel m = item(null, code: 'x', name: 'tap');
      final List<Settled> r = await waitAllSettled([items.save(m), items.save(m)]);
      expect((r[0].value! as FluentSaveResult).inserted, 1);
      expect((r[1].value! as FluentSaveResult).updated, 1, reason: 'the second save updates the row the first inserted');
      expect(await items.count(), 1);
      expect(m.primaryKeyValue, isNotNull);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: merged saves give new models the same keys as a serial run (seed 30500 of engine_fuzz_test)', () async {
      await FluentDb.pauseQueue(dbKey: db.key);
      final List<DynamicModel> all = [item(6, name: 'keyed'), item(null, code: 'c1', name: 'new in the same call')];
      final DynamicModel later = item(null, name: 'new in a later call');
      final List<Future<Object?>> calls = [items.saveAll(all), items.save(later), items.save(later)];
      FluentDb.resumeQueue(dbKey: db.key);
      await waitAllSettled(calls);
      // One call per item, in call order: 6, then SQLite's next key 7, then 8.
      expect([...all.map((m) => m.primaryKeyValue), later.primaryKeyValue], [6, 7, 8]);
      expect((await _all(items)).map((m) => m['id']), [6, 7, 8]);
      expectIssuesHaveFixes(db.issues);
    });

    // Seeds 130587, 132275, 132729, 133130, 133161, 133824, 134722, 134972, 31136, 32376, 32725, 34380, 34837 of
    // engine_fuzz_test: one merged call wrote every update before every insert, so a later call's update freed a
    // UNIQUE value an earlier call's insert needed.
    for (final (String shape, List<Future<Object?>> Function(DynamicModel Function(int?, {String? code, String? name})) calls) in [
      ('a new model', (item) => [items.save(item(null, code: 'c2', name: 'new')), items.save(item(1, code: 'c4', name: 'moved'))]),
      ('a missing key', (item) => [items.saveAll([item(5, code: 'c2', name: 'new')]), items.save(item(1, code: 'c4', name: 'moved'))]),
      ('the same new model twice', (item) {
        final DynamicModel m = item(null, code: 'c2', name: 'new');
        return [items.save(m), items.save(m), items.save(item(1, code: 'c4', name: 'moved'))];
      }),
    ]) {
      test('G7: merged saves keep the order of inserts and updates across calls — $shape inserted before a later update frees its UNIQUE value fails, as in a serial run', () async {
        await items.save(item(1, code: 'c2', name: 'old'));
        await FluentDb.pauseQueue(dbKey: db.key);
        final List<Future<Object?>> fired = calls((id, {code, name}) => item(id, code: code, name: name));
        final int mergedBefore = FluentDb.engineStats().mergedSaves;
        FluentDb.resumeQueue(dbKey: db.key);
        final List<Settled> r = await waitAllSettled(fired);
        expect(FluentDb.engineStats().mergedSaves, greaterThan(mergedBefore), reason: 'the saves were merged');
        for (int i = 0; i < r.length - 1; i++) {
          expect(r[i].failed, isTrue, reason: 'call $i inserts code c2 while row 1 still holds it');
          expect(r[i].error, isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.uniqueViolation));
        }
        expect((r.last.value! as FluentSaveResult).updated, 1);
        expect(await _all(items), [
          {'id': 1, 'code': 'c4', 'name': 'moved', 'qty': null},
        ]);
        await expectIntegrity(items.db);
        expectIssuesHaveFixes(db.issues);
      });
    }

    test('G7: merged saves of an insert, an update freeing a UNIQUE value and an insert taking it all succeed, in call order', () async {
      await items.save(item(1, code: 'c1', name: 'old'));
      await FluentDb.pauseQueue(dbKey: db.key);
      final DynamicModel fresh = item(null, code: 'c2', name: 'new');
      final List<Future<Object?>> fired = [items.save(fresh), items.save(item(1, code: 'c3', name: 'moved')), items.save(item(null, code: 'c1', name: 'reuses the freed code'))];
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled(fired);
      expect(r.where((s) => s.failed), isEmpty, reason: 'in call order nothing clashes: c1 is freed before it is inserted again');
      expect(await _all(items), [
        {'id': 1, 'code': 'c3', 'name': 'moved', 'qty': null},
        {'id': 2, 'code': 'c2', 'name': 'new', 'qty': null},
        {'id': 3, 'code': 'c1', 'name': 'reuses the freed code', 'qty': null},
      ]);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: a new model saved and then deleted without awaiting is deleted, as in a serial run', () async {
      final DynamicModel m = item(null, code: 'x', name: 'gone');
      final List<Settled> r = await waitAllSettled([items.save(m), items.delete(m)], names: ['save', 'delete']);
      expect(r[1].value, 1, reason: 'the delete was called after the save: it removes the row the save inserted');
      expect(await items.count(), 0);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: conflictOn saves of one unique value called back to back write one row, the last one wins', () async {
      final List<Settled> r = await waitAllSettled([
        for (int i = 0; i < 5; i++) items.save(item(null, code: 'c', name: 'v$i'), conflictOn: ['code']),
        items.find(where: FluentFilter.eq('code', 'c')),
      ]);
      expect(r.where((s) => s.failed), isEmpty);
      final List<DynamicModel> seen = (r.last.value! as List).cast<DynamicModel>();
      expect(seen.map((m) => m['name']), ['v4']);
      expect((await _all(items)).map((m) => m['name']), ['v4']);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: a findById flood interleaved with writes: every lookup sees exactly the writes called before it', () async {
      await FluentDb.pauseQueue(dbKey: db.key);
      final Map<int, String?> state = {};
      final List<Future<Object?>> calls = [];
      final List<Object?> expected = [];
      final List<String> names = [];
      for (int step = 0; step < 60; step++) {
        final int id = step % 7;
        if (step % 5 == 0) {
          state[id] = 's$step';
          calls.add(items.save(item(id, name: 's$step')));
          expected.add(null);
          names.add('save $id = s$step');
        } else if (step % 11 == 0) {
          state.remove(id);
          calls.add(items.deleteById(id));
          expected.add(null);
          names.add('delete $id');
        } else {
          calls.add(items.findById(id).then((m) => m == null ? '<none>' : m['name']));
          expected.add(state.containsKey(id) ? state[id] : '<none>');
          names.add('findById $id');
        }
      }
      final int batchedBefore = FluentDb.engineStats().batchedLookups;
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled(calls, names: names);
      for (int i = 0; i < r.length; i++) {
        if (names[i].startsWith('findById')) expect(r[i].value, expected[i], reason: '${names[i]} (call $i)');
      }
      expect(FluentDb.engineStats().batchedLookups, greaterThan(batchedBefore), reason: 'the flood was answered by batched lookups');
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: identical reads collapse, but never across a write called between them', () async {
      final int collapsedBefore = FluentDb.engineStats().collapsedReads;
      await FluentDb.pauseQueue(dbKey: db.key);
      final Future<int> before1 = items.count();
      final Future<int> before2 = items.count();
      final Future<FluentSaveResult> write = items.save(item(1, name: 'a'));
      final Future<int> after1 = items.count();
      final Future<int> after2 = items.count(policy: ExecutionPolicy.fast);
      final Future<List<DynamicModel>> list1 = items.find();
      final Future<FluentSaveResult> write2 = items.save(item(2, name: 'b'));
      final Future<List<DynamicModel>> list2 = items.find();
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled([before1, before2, write, after1, after2, list1, write2, list2]);
      expect([r[0].value, r[1].value, r[3].value, r[4].value], [0, 0, 1, 1]);
      expect((r[5].value! as List).length, 1);
      expect((r[7].value! as List).length, 2);
      expect(FluentDb.engineStats().collapsedReads, greaterThan(collapsedBefore));
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: priorities reorder reads only between two writes: an urgent read never overtakes an earlier write', () async {
      await FluentDb.pauseQueue(dbKey: db.key);
      final Future<int> slowBefore = items.count(policy: ExecutionPolicy.background);
      final Future<FluentSaveResult> write = items.save(item(1, name: 'a'));
      final Future<int> fastAfter = items.count(policy: ExecutionPolicy.fast, where: FluentFilter.eq('name', 'a'));
      final Future<int> slowAfter = items.count(policy: const ExecutionPolicy(priority: -100), where: FluentFilter.isNotNull('name'));
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled([slowBefore, write, fastAfter, slowAfter]);
      expect([r[0].value, r[2].value, r[3].value], [0, 1, 1]);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7 / G1: Future.wait of saves inside a transaction, one failing and caught: the others commit, the failing caller gets its typed error', () async {
      await items.save(item(1, code: 'taken', name: 'first'));
      final List<Settled> inner = await FluentDb.transaction(
        () => waitAllSettled([
          items.save(item(2, code: 'a', name: 'ok a')),
          items.save(item(3, code: 'taken', name: 'clash')),
          items.save(item(4, code: 'b', name: 'ok b')),
        ], names: ['save 2', 'save 3 (unique clash)', 'save 4']),
        dbKey: db.key,
      ).timeout(_limit);
      expect([for (final Settled s in inner) s.failed], [false, true, false]);
      expect(inner[1].error, isA<FluentConstraintException>());
      expect((await _all(items)).map((m) => m['id']), [1, 2, 4], reason: 'G1: every call that reported success is committed, the failed one wrote nothing');
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G7: unawaited writes inside a transaction apply in call order and a read called after them sees them', () async {
      final List<Object?> seen = await FluentDb.transaction(() async {
        final List<Future<Object?>> calls = [
          items.save(item(1, name: 'a')),
          items.save(item(1, name: 'b'), strategy: FluentSaveStrategy.patch),
          items.updateById(1, {'qty': FluentUpdate.increment(5)}),
          items.save(item(2, name: 'c')),
          items.deleteById(2),
          items.find(orderBy: 'id').then((l) => [for (final DynamicModel m in l) _row(m)]),
        ];
        return [for (final Settled s in await waitAllSettled(calls)) s.value];
      }, dbKey: db.key).timeout(_limit);
      expect(seen.last, [
        {'id': 1, 'code': null, 'name': 'b', 'qty': 5},
      ]);
      expect(await _all(items), seen.last);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G1: two nested transactions running side by side, one rolled back: only its writes are undone', () async {
      await FluentDb.transaction(() async {
        final List<Settled> r = await waitAllSettled([
          FluentDb.transaction<void>(() async {
            await items.save(item(1, name: 'kept'));
            await items.save(item(2, name: 'kept too'));
          }, dbKey: db.key),
          FluentDb.transaction<void>(() async {
            await items.save(item(3, name: 'undone'));
            await pumpEventQueue();
            throw StateError('roll back the savepoint');
          }, dbKey: db.key),
        ], typedErrors: false);
        expect(r[0].failed, isFalse);
        expect(r[1].error, isA<StateError>());
      }, dbKey: db.key).timeout(_limit);
      expect((await _all(items)).map((m) => m['id']), [1, 2]);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });
  });

  group('G7: saves on a table with relations', () {
    late FluentTestDb db;
    late _OwnerProvider owners;
    late _BadgeProvider badges;

    setUp(() async {
      db = FluentTestDb();
      owners = _OwnerProvider();
      badges = _BadgeProvider();
      await db.open([owners, badges]);
    });

    tearDown(() async {
      FluentDb.resumeQueue();
      await db.close().timeout(_limit);
    });

    test('G7: unawaited saves of a table with relations are never merged — an owned child inserted before a later call frees its UNIQUE value fails, as in a serial run', () async {
      await owners.save(_Owner(id: 1, name: 'a', badge: _Badge(code: 'x')));
      final Object? badgeId = (await badges.find()).single.id;
      await FluentDb.pauseQueue(dbKey: db.key);
      final int mergedBefore = FluentDb.engineStats().mergedSaves;
      final List<Future<Object?>> fired = [
        owners.save(_Owner(name: 'b', badge: _Badge(code: 'x'))),
        owners.save(_Owner(id: 1, name: 'a', badge: _Badge(id: badgeId as int?, code: 'y'))),
      ];
      FluentDb.resumeQueue(dbKey: db.key);
      final List<Settled> r = await waitAllSettled(fired, names: ['insert a badge with x', 'move badge x to y']);
      expect(r[0].error, isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.uniqueViolation), reason: 'called first, x is still taken');
      expect(r[1].failed, isFalse, reason: '${r[1].error}');
      expect((await owners.find()).map((o) => o.id), [1], reason: 'the failing call wrote nothing');
      expect((await badges.find()).map((b) => b.code), ['y']);
      expect(FluentDb.engineStats().mergedSaves, mergedBefore, reason: 'each call saves its own graph');
      await expectIntegrity(owners.db);
      expectIssuesHaveFixes(db.issues);
    });
  });

  group('G1: merged batches that fail', () {
    late FaultyDatabaseFactory faults;
    late FluentTestDb db;
    late DynamicProvider items;

    setUp(() async {
      faults = await FaultyDatabaseFactory.install();
      db = FluentTestDb(persistent: true);
      items = _items();
      await db.open([items]);
    });

    tearDown(() async {
      faults.heal();
      FluentDb.resumeQueue();
      await db.close().timeout(_limit);
      faults.uninstall();
    });

    DynamicModel item(int? id, {String? code, String? name}) => items.row({'id': id, 'code': code, 'name': name, 'qty': null});

    /// Queues [calls] while the queue is paused, so the adjacent saves merge into one batch.
    Future<List<Settled>> merged(List<Future<Object?>> Function() calls, {List<String>? names}) async {
      await FluentDb.pauseQueue(dbKey: db.key);
      final List<Future<Object?>> fired = calls();
      FluentDb.resumeQueue(dbKey: db.key);
      return waitAllSettled(fired, names: names);
    }

    test('G1: a merged batch with a UNIQUE clash falls back call by call: only the clashing caller fails, typed', () async {
      await items.save(item(1, code: 'taken'));
      final FluentEngineStats before = FluentDb.engineStats();
      final List<Settled> r = await merged(() => [
        items.save(item(2, code: 'a')),
        items.saveAll([item(3, code: 'b'), item(4, code: 'taken')]),
        items.save(item(5, code: 'c')),
      ]);
      final FluentEngineStats after = FluentDb.engineStats();
      expect(after.mergedSaves, greaterThan(before.mergedSaves), reason: 'the saves were merged');
      expect(after.splitBatches, before.splitBatches + 1);
      expect([for (final Settled s in r) s.failed], [false, true, false]);
      expect(r[1].error, isA<FluentConstraintException>());
      expect((await _all(items)).map((m) => m['id']), [1, 2, 5], reason: 'G1: the failed saveAll wrote nothing (not even its first row)');
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    for (final FaultKind kind in FaultKind.values) {
      test('G1: a ${kind.name} on the first statement of a merged batch: every caller still gets its own outcome, nothing is doubled', () async {
        faults.failNth(0, where: (c) => c.isWrite, kind: kind);
        final List<Settled> r = await merged(() => [for (int i = 1; i <= 4; i++) items.save(item(i, code: 'c$i'))]);
        expect(faults.injected, hasLength(1));
        expect(r.where((s) => s.failed), isEmpty, reason: 'the batch was re-run call by call after the injected failure');
        expect((await _all(items)).map((m) => m['id']), [1, 2, 3, 4]);
        await expectIntegrity(items.db);
        expectIssuesHaveFixes(db.issues);
      });
    }

    test('G1: the batch and then the first separate call fail: exactly that caller fails typed, the rest are stored once', () async {
      faults.failWhere((c) => c.isWrite, times: 2);
      final List<Settled> r = await merged(() => [for (int i = 1; i <= 4; i++) items.save(item(i, code: 'c$i'))]);
      expect([for (final Settled s in r) s.failed], [true, false, false, false]);
      expect((await _all(items)).map((m) => m['id']), [2, 3, 4]);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G1: the COMMIT of a merged batch fails: nothing of the batch stays half-written and every caller completes', () async {
      faults.failWhere((c) => c.isCommit, times: 1);
      final List<Settled> r = await merged(() => [for (int i = 1; i <= 4; i++) items.save(item(i, code: 'c$i'))]);
      final List<int> stored = [for (final Map<String, Object?> m in await _all(items)) m['id']! as int];
      for (int i = 0; i < 4; i++) {
        expect(stored.contains(i + 1), !r[i].failed, reason: 'G1: save ${i + 1} reported ${r[i].failed ? 'failure' : 'success'}');
      }
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G1: a batched findById lookup that fails is re-run per call: every caller gets its own row', () async {
      for (int i = 1; i <= 5; i++) {
        await items.save(item(i, code: 'c$i', name: 'n$i'));
      }
      faults.failNth(0, where: (c) => c.isRead && c.matches(' IN '));
      final List<Settled> r = await merged(() => [for (int i = 1; i <= 6; i++) items.findById(i).then((m) => m?['name'])]);
      expect(faults.injected, hasLength(1), reason: 'the lookups were batched into one IN query');
      expect([for (final Settled s in r) s.value], ['n1', 'n2', 'n3', 'n4', 'n5', null]);
      expectIssuesHaveFixes(db.issues);
    });
  });

  group('G30: two databases with same-named tables', () {
    late DynamicProvider a;
    late DynamicProvider b;
    late FluentDbKey keyA;
    late FluentDbKey keyB;
    final List<FluentIssue> issues = [];
    StreamSubscription<FluentIssue>? issueSub;

    setUp(() async {
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      a = _items();
      b = _items();
      final int now = DateTime.now().microsecondsSinceEpoch;
      keyA = FluentDbKey('g30_a_$now');
      keyB = FluentDbKey('g30_b_$now');
      issues.clear();
      issueSub = FluentDb.onIssue().listen(issues.add);
      await FluentDb.init([
        FluentGroup(dbKey: keyA, providerList: [a], inMemory: true),
        FluentGroup(dbKey: keyB, providerList: [b], inMemory: true),
      ]);
    });

    tearDown(() async {
      FluentDb.resumeQueue();
      await FluentEngine().whenIdle(_limit);
      await FluentDb.close().timeout(_limit);
      FluentDbInternals.reset();
      await issueSub?.cancel();
    });

    DynamicModel row(DynamicProvider p, int id, String name) => p.row({'id': id, 'code': '${p.dbName}_$id', 'name': name, 'qty': id});

    test('G30: identical reads, merged saves and lookups on both databases at once never mix', () async {
      await FluentDb.pauseQueue();
      final List<Future<Object?>> calls = [
        for (int i = 1; i <= 4; i++) a.save(row(a, i, 'a$i')),
        for (int i = 1; i <= 2; i++) b.save(row(b, i, 'b$i')),
        a.count(),
        b.count(),
        a.find(orderBy: 'id').then((l) => l.map((m) => m['name']).toList()),
        b.find(orderBy: 'id').then((l) => l.map((m) => m['name']).toList()),
        for (int i = 1; i <= 4; i++) a.findById(i).then((m) => m?['name']),
        for (int i = 1; i <= 4; i++) b.findById(i).then((m) => m?['name']),
      ];
      FluentDb.resumeQueue();
      final List<Settled> r = await waitAllSettled(calls);
      expect([for (final Settled s in r.skip(6)) s.value], [
        4,
        2,
        ['a1', 'a2', 'a3', 'a4'],
        ['b1', 'b2'],
        'a1', 'a2', 'a3', 'a4',
        'b1', 'b2', null, null,
      ]);
      await expectIntegrity(a.db);
      await expectIntegrity(b.db);
      expectIssuesHaveFixes(issues);
    });

    test('G30: clear, clearTable, deleteWhere and a rolled-back transaction on one database leave the other untouched', () async {
      for (int i = 1; i <= 3; i++) {
        await a.save(row(a, i, 'a$i'));
        await b.save(row(b, i, 'b$i'));
      }
      final List<Map<String, Object?>> bRows = await _all(b);
      await FluentDb.clear(dbKey: keyA).timeout(_limit);
      expect(await _all(b), bRows);
      await a.save(row(a, 9, 'a9'));
      await a.clearTable().timeout(_limit);
      expect(await _all(b), bRows);
      await a.save(row(a, 9, 'a9'));
      await a.deleteWhere(FluentFilter.gt('id', 0)).timeout(_limit);
      expect(await _all(b), bRows);
      await expectLater(
        FluentDb.transaction(() async {
          await a.save(row(a, 5, 'a5'));
          await b.save(row(b, 5, 'b5')); // another database: not part of this transaction
          throw StateError('roll back A');
        }, dbKey: keyA).timeout(_limit),
        throwsStateError,
      );
      expect(await a.count(), 0);
      expect((await _all(b)).map((m) => m['id']), [1, 2, 3, 5], reason: 'the write to B is not part of the transaction on A');
      await expectIntegrity(a.db);
      await expectIntegrity(b.db);
      expectIssuesHaveFixes(issues);
    });

    test('G30: a watch on one database emits nothing for writes to the same-named table of the other', () async {
      final List<int> seen = [];
      final StreamSubscription<List<DynamicModel>> sub = b.watch().listen((l) => seen.add(l.length));
      await _settle();
      final int initial = seen.length;
      for (int i = 1; i <= 3; i++) {
        await a.save(row(a, i, 'a$i'));
      }
      await a.clearTable();
      await FluentDb.clear(dbKey: keyA);
      await _settle();
      expect(seen.length, initial, reason: 'no event of database A reaches a watch of database B');
      await b.save(row(b, 1, 'b1'));
      await _settle();
      expect(seen.last, 1, reason: 'a write to B still reaches it');
      await sub.cancel();
      expectIssuesHaveFixes(issues);
    });

    test('G30 / G12: pausing one database holds only its calls; the other keeps running; resume completes them in order', () async {
      await FluentDb.pauseQueue(dbKey: keyA).timeout(_limit);
      final Future<FluentSaveResult> aw = a.save(row(a, 1, 'a1'));
      final Future<int> ar = a.count();
      await b.save(row(b, 1, 'b1')).timeout(_limit);
      expect(await b.count().timeout(_limit), 1);
      bool aDone = false;
      unawaited(aw.then((_) => aDone = true));
      await pumpEventQueue(times: 50);
      expect(aDone, isFalse, reason: 'A is paused');
      FluentDb.resumeQueue(dbKey: keyA);
      final List<Settled> r = await waitAllSettled([aw, ar]);
      expect(r[1].value, 1, reason: 'the read called after the write sees it');
      expectIssuesHaveFixes(issues);
    });

    test('G30 / G12: a transaction on A inside one on B inside one on A: every write lands in its own database', () async {
      await FluentDb.transaction(() async {
        await a.save(row(a, 1, 'a1'));
        await FluentDb.transaction(() async {
          await b.save(row(b, 1, 'b1'));
          await FluentDb.transaction(() async {
            await a.save(row(a, 2, 'a2'));
            await b.save(row(b, 2, 'b2'));
          }, dbKey: keyA).timeout(_limit);
        }, dbKey: keyB).timeout(_limit);
      }, dbKey: keyA).timeout(_limit);
      expect((await _all(a)).map((m) => m['name']), ['a1', 'a2']);
      expect((await _all(b)).map((m) => m['name']), ['b1', 'b2']);
      await expectIntegrity(a.db);
      await expectIntegrity(b.db);
      expectIssuesHaveFixes(issues);
    });
  });

  group('G12: wait cycles between databases are refused, never waited for', () {
    late DynamicProvider a;
    late DynamicProvider b;
    late DynamicProvider c;
    late FluentDbKey keyA;
    late FluentDbKey keyB;
    late FluentDbKey keyC;
    final List<FluentIssue> issues = [];
    StreamSubscription<FluentIssue>? issueSub;

    /// Opens the three databases with the transaction watchdog [watchdog] (`null`: off).
    Future<void> open(Duration? watchdog) => FluentDb.init(
      [
        FluentGroup(dbKey: keyA, providerList: [a], inMemory: true),
        FluentGroup(dbKey: keyB, providerList: [b], inMemory: true),
        FluentGroup(dbKey: keyC, providerList: [c], inMemory: true),
      ],
      config: FluentConfig(transactionWatchdog: watchdog),
    );

    setUp(() async {
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      a = _items();
      b = _items();
      c = _items();
      final int now = DateTime.now().microsecondsSinceEpoch;
      keyA = FluentDbKey('g12_a_$now');
      keyB = FluentDbKey('g12_b_$now');
      keyC = FluentDbKey('g12_c_$now');
      issues.clear();
      issueSub = FluentDb.onIssue().listen(issues.add);
      await open(const Duration(milliseconds: 100));
    });

    tearDown(() async {
      await FluentEngine().whenIdle(_limit);
      await FluentDb.close().timeout(_limit);
      FluentDbInternals.reset();
      await issueSub?.cancel();
    });

    DynamicModel row(DynamicProvider p, int id) => p.row({'id': id, 'code': null, 'name': '${p.dbName}_$id', 'qty': id});
    Future<List<Object?>> ids(DynamicProvider p) async => [for (final Map<String, Object?> m in await _all(p)) m['id']];
    Future<void> integrity() async {
      for (final DynamicProvider p in [a, b, c]) {
        await expectIntegrity(p.db);
      }
      expectIssuesHaveFixes(issues);
    }

    void expectDeadlock(Settled s, {String? cycle}) {
      expect(s.failed, isTrue, reason: 'G12: the call that closes the cycle is refused');
      expectTypedError(s.error!);
      final FluentException e = s.error! as FluentException;
      expect(e.code, FluentErrorCode.deadlock);
      if (cycle != null) expect(e.message, contains(cycle));
    }

    test('G12: A→B and B→A at once — the call closing the cycle is refused, its transaction rolls back, the other commits', () async {
      final Completer<void> aIn = Completer<void>(), bIn = Completer<void>();
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        aIn.complete();
        await bIn.future;
        await FluentDb.transaction(() => b.save(row(b, 2)), dbKey: keyB);
        return 'ab';
      }, dbKey: keyA);
      final Future<Object?> ba = FluentDb.transaction(() async {
        await b.save(row(b, 3));
        bIn.complete();
        await aIn.future;
        await Future<void>.delayed(const Duration(milliseconds: 20)); // A→B waits first: this call closes the cycle
        await FluentDb.transaction(() => a.save(row(a, 4)), dbKey: keyA);
        return 'ba';
      }, dbKey: keyB);
      final List<Settled> r = await waitAllSettled([ab, ba], names: ['A→B', 'B→A'], timeout: _limit);
      expect(r[0].value, 'ab');
      expectDeadlock(r[1], cycle: '"${keyA.dbName}" → "${keyB.dbName}" → "${keyA.dbName}"'.replaceAll('"', ''));
      expect(await ids(a), [1]);
      expect(await ids(b), [2], reason: 'G1: the refused transaction on B rolled back as a whole');
      await integrity();
    });

    test('G12: three databases A→B→C→A — the third call is refused, the other two commit in turn', () async {
      final List<Completer<void>> holding = [Completer<void>(), Completer<void>(), Completer<void>()];
      final Completer<void> aWaits = Completer<void>(), bWaits = Completer<void>();
      Future<Object?> txn(DynamicProvider own, FluentDbKey key, int i, Future<void> Function() before, DynamicProvider next, FluentDbKey nextKey, Completer<void>? signal) =>
          FluentDb.transaction(() async {
            await own.save(row(own, i));
            holding[i - 1].complete();
            await Future.wait([for (final Completer<void> h in holding) h.future]);
            await before();
            final Future<Object?> call = FluentDb.transaction(() => next.save(row(next, 10 + i)), dbKey: nextKey);
            signal?.complete(); // the wait is registered when the call is made
            await call;
            return i;
          }, dbKey: key);
      final List<Future<Object?>> calls = [
        txn(a, keyA, 1, () async {}, b, keyB, aWaits),
        txn(b, keyB, 2, () => aWaits.future, c, keyC, bWaits),
        txn(c, keyC, 3, () => bWaits.future, a, keyA, null),
      ];
      final List<Settled> r = await waitAllSettled(calls, names: ['A→B', 'B→C', 'C→A'], timeout: _limit);
      expect([r[0].value, r[1].value], [1, 2]);
      expectDeadlock(r[2], cycle: '${keyA.dbName} → ${keyB.dbName} → ${keyC.dbName} → ${keyA.dbName}');
      expect(await ids(a), [1]);
      expect(await ids(b), [2, 11]);
      expect(await ids(c), [12], reason: 'G1: the refused transaction on C rolled back; B→C committed after it');
      await integrity();
    });

    test('G12: a cycle closed by an unawaited call — that call fails through its own future, the body that made it goes on', () async {
      final Completer<void> aIn = Completer<void>(), aWaits = Completer<void>();
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        aIn.complete();
        final Future<Object?> call = FluentDb.transaction(() => b.save(row(b, 2)), dbKey: keyB);
        aWaits.complete();
        await call;
        return 'ab';
      }, dbKey: keyA);
      Future<Object?>? unawaitedCall;
      final Future<Object?> ba = FluentDb.transaction(() async {
        await b.save(row(b, 3));
        await aIn.future;
        await aWaits.future;
        unawaitedCall = a.save(row(a, 4)); // not awaited here
        unawaited(unawaitedCall!.then<void>((_) {}, onError: (Object _) {}));
        await b.save(row(b, 5));
        return 'ba';
      }, dbKey: keyB);
      final List<Settled> r = await waitAllSettled([ab, ba], names: ['A→B', 'B→A'], timeout: _limit);
      expect([r[0].value, r[1].value], ['ab', 'ba']);
      expectDeadlock((await waitAllSettled([unawaitedCall!], timeout: _limit)).single);
      expect(await ids(a), [1]);
      expect(await ids(b), [2, 3, 5]);
      await integrity();
    });

    test('G12: no false positive — A→B, then B→A one after the other, and again, all commit', () async {
      for (int round = 0; round < 3; round++) {
        final int base = round * 10;
        await FluentDb.transaction(() async {
          await a.save(row(a, base + 1));
          await FluentDb.transaction(() => b.save(row(b, base + 2)), dbKey: keyB);
          await b.save(row(b, base + 3));
          await c.count();
        }, dbKey: keyA).timeout(_limit);
        await FluentDb.transaction(() async {
          await b.save(row(b, base + 4));
          await FluentDb.transaction(() => a.save(row(a, base + 5)), dbKey: keyA);
          await a.find();
        }, dbKey: keyB).timeout(_limit);
      }
      expect(await ids(a), [1, 5, 11, 15, 21, 25]);
      expect(await ids(b), [2, 3, 4, 12, 13, 14, 22, 23, 24]);
      await integrity();
    });

    test('G12: no false positive — nested A→B→A (one chain) and a plain writer to B beside it all complete', () async {
      final Completer<void> inB = Completer<void>();
      final Future<Object?> chain = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        await FluentDb.transaction(() async {
          await b.save(row(b, 2));
          inB.complete();
          await a.save(row(a, 3)); // joins the outer transaction on A
          await FluentDb.transaction(() => a.save(row(a, 4)), dbKey: keyA); // a savepoint of it
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }, dbKey: keyB);
        return 'chain';
      }, dbKey: keyA);
      await inB.future.timeout(_limit);
      final Future<Object?> beside = b.save(row(b, 5)); // waits for the chain's transaction on B, no cycle
      final List<Settled> r = await waitAllSettled([chain, beside], timeout: _limit);
      expect(r[0].value, 'chain');
      expect(r[1].failed, isFalse);
      expect(await ids(a), [1, 3, 4]);
      expect(await ids(b), [2, 5]);
      await integrity();
    });

    test('G12: a read across databases is not refused while the watchdog lets it into the transaction it waits for', () async {
      final Completer<void> bIn = Completer<void>(), aReads = Completer<void>();
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        await bIn.future;
        final Future<int> read = b.count();
        aReads.complete();
        return read;
      }, dbKey: keyA);
      final Future<Object?> ba = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        bIn.complete();
        await aReads.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await a.save(row(a, 3)); // waits for A, whose transaction waits for a read on B
        return 'ba';
      }, dbKey: keyB);
      final List<Settled> r = await waitAllSettled([ab, ba], names: ['A reads B', 'B writes A'], timeout: _limit);
      expect(r[0].value, 1, reason: 'the read ran inside the transaction on B (watchdog) and saw its row');
      expect(r[1].value, 'ba');
      expect(await ids(a), [1, 3]);
      expect(await ids(b), [2]);
      await integrity();
    });

    /// A transaction on B that holds B and then writes to A, a plain write to B (row 9) queued behind it, and a
    /// transaction on A that reads B behind that write. The read cannot be let into B's transaction (it must not pass
    /// the queued write: G7), so read and write to A close a wait cycle. [readFirst]: the read is made before B's
    /// write to A (that write closes the cycle), else after it (the read closes it).
    ({Future<Object?> ab, Future<Object?> ba, Future<Object?> write}) readBehindWrite({required bool readFirst}) {
      final Completer<void> aIn = Completer<void>(), bIn = Completer<void>(), queued = Completer<void>(), aReads = Completer<void>(), bWaits = Completer<void>();
      final Future<Object?> ba = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        bIn.complete();
        await aIn.future;
        await queued.future;
        if (readFirst) {
          await aReads.future;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final Future<Object?> call = a.save(row(a, 4)); // waits for A
        bWaits.complete();
        await call;
        return 'ba';
      }, dbKey: keyB);
      final Future<Object?> write = bIn.future.then((_) async {
        final Future<Object?> w = b.save(row(b, 9)); // queued behind the transaction on B
        await Future<void>.delayed(const Duration(milliseconds: 10));
        queued.complete();
        return w;
      });
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        aIn.complete();
        await queued.future;
        if (!readFirst) await bWaits.future;
        final Future<int> read = b.count(); // behind the queued write on B
        aReads.complete();
        return await read;
      }, dbKey: keyA);
      return (ab: ab, ba: ba, write: write);
    }

    test('G12: a read across databases behind a queued write closes the cycle — the read is refused, the other side commits', () async {
      final calls = readBehindWrite(readFirst: false);
      final List<Settled> r = await waitAllSettled([calls.ab, calls.ba, calls.write], names: ['A reads B', 'B writes A', 'write to B'], timeout: _limit);
      expectDeadlock(r[0], cycle: '${keyB.dbName} → ${keyA.dbName} → ${keyB.dbName}');
      expect(r[1].value, 'ba');
      expect(r[2].failed, isFalse);
      expect(await ids(a), [4], reason: 'G1: the refused transaction on A rolled back as a whole');
      expect(await ids(b), [2, 9]);
      await integrity();
    });

    test('G12: a read across databases behind a queued write waits first — the call closing the cycle is refused, the read sees the write (G7)', () async {
      final calls = readBehindWrite(readFirst: true);
      final List<Settled> r = await waitAllSettled([calls.ab, calls.ba, calls.write], names: ['A reads B', 'B writes A', 'write to B'], timeout: _limit);
      expect(r[0].value, 1, reason: 'G7: the read ran after the write queued before it, never inside the transaction ahead of it');
      expectDeadlock(r[1], cycle: '${keyA.dbName} → ${keyB.dbName} → ${keyA.dbName}');
      expect(r[2].failed, isFalse);
      expect(await ids(a), [1]);
      expect(await ids(b), [9], reason: 'G1: the refused transaction on B rolled back as a whole');
      await integrity();
    });

    test('G12: with the transaction watchdog off, a read across databases that closes a cycle is refused too', () async {
      await FluentEngine().whenIdle(_limit);
      await FluentDb.close().timeout(_limit);
      await open(null);
      final Completer<void> bIn = Completer<void>(), bWaits = Completer<void>();
      final Future<Object?> ba = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        bIn.complete();
        final Future<Object?> call = a.save(row(a, 4)); // waits for A
        bWaits.complete();
        await call;
        return 'ba';
      }, dbKey: keyB);
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        await bIn.future;
        await bWaits.future;
        return await b.count(); // waits for the transaction on B: nobody lets it in
      }, dbKey: keyA);
      final List<Settled> r = await waitAllSettled([ab, ba], names: ['A reads B', 'B writes A'], timeout: _limit);
      expectDeadlock(r[0], cycle: '${keyB.dbName} → ${keyA.dbName} → ${keyB.dbName}');
      expect(r[1].value, 'ba');
      expect(await ids(a), [4]);
      expect(await ids(b), [2]);
      await integrity();
    });

    test('G12: no false positive — a read that waited behind a queued transaction is let into it once it runs; that transaction may then call back', () async {
      final Completer<void> b1In = Completer<void>(), release = Completer<void>(), aReads = Completer<void>();
      final Future<Object?> b1 = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        b1In.complete();
        await release.future;
        return 'b1';
      }, dbKey: keyB);
      await b1In.future.timeout(_limit);
      final Future<Object?> b2 = FluentDb.transaction(() async {
        // Queued behind b1; the read from A queues behind it.
        await b.save(row(b, 3));
        await aReads.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await a.save(row(a, 5)); // A's transaction waits for its read, which no longer waits behind a queued write: no cycle
        return 'b2';
      }, dbKey: keyB);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final Future<Object?> ab = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        final Future<int> read = b.count(); // behind the queued transaction b2
        aReads.complete();
        release.complete(); // b1 commits, b2 starts and lets the read in (watchdog)
        return await read;
      }, dbKey: keyA);
      final List<Settled> r = await waitAllSettled([b1, b2, ab], names: ['b1', 'b2', 'A reads B'], timeout: _limit);
      expect([r[0].value, r[1].value], ['b1', 'b2']);
      expect(r[2].value, 2, reason: 'the read ran inside b2 (watchdog), after b1 committed: rows 2 and 3');
      expect(await ids(a), [1, 5]);
      expect(await ids(b), [2, 3]);
      await integrity();
    });

    test('G12: a pause does not wait for a transaction that waits for a call the pause holds; resume completes everything', () async {
      for (final FluentDbKey? paused in [null, keyA]) {
        final int base = paused == null ? 0 : 10;
        final Completer<void> aBusy = Completer<void>(), release = Completer<void>(), bIn = Completer<void>(), bWaits = Completer<void>();
        final Future<Object?> at = FluentDb.transaction(() async {
          await a.save(row(a, base + 1));
          aBusy.complete();
          await release.future;
          return 'a';
        }, dbKey: keyA);
        await aBusy.future.timeout(_limit);
        final Future<Object?> bt = FluentDb.transaction(() async {
          await b.save(row(b, base + 2));
          bIn.complete();
          final Future<Object?> call = a.save(row(a, base + 3)); // queued behind the transaction on A
          bWaits.complete();
          await call;
          return 'b';
        }, dbKey: keyB);
        await bWaits.future.timeout(_limit);
        final Future<void> pause = FluentDb.pauseQueue(dbKey: paused);
        release.complete(); // A's transaction ends; B's call on A is held by the pause now
        await pause.timeout(_limit, onTimeout: () => fail('G12: pauseQueue waited for a transaction that waits for the pause'));
        FluentDb.resumeQueue(dbKey: paused);
        final List<Settled> r = await waitAllSettled([at, bt], names: ['A', 'B waits for A'], timeout: _limit);
        expect([r[0].value, r[1].value], ['a', 'b']);
      }
      expect(await ids(a), [1, 3, 11, 13]);
      expect(await ids(b), [2, 12]);
      await integrity();
    });

    test('G7: a slow transaction that keeps working never lets a waiting read see its uncommitted changes (watchdog 100 ms)', () async {
      // Engine fuzz seed 55228, chaos seeds 95039 / 100030 (under load): a transaction ran longer than the watchdog, so
      // a read called after it ran inside it, saw half of its writes, and in chaos a write that was rolled back.
      final Completer<void> started = Completer<void>();
      final Future<Object?> tx = FluentDb.transaction(() async {
        for (int i = 1; i <= 30; i++) {
          await a.save(row(a, i));
          if (i == 1) started.complete();
          await Future<void>.delayed(const Duration(milliseconds: 10)); // busy: never idle for a whole watchdog period
        }
        return 'done';
      }, dbKey: keyA);
      await started.future.timeout(_limit);
      final Future<int> read = a.count(); // called after the transaction started: sees all of it (G7)
      final List<Settled> r = await waitAllSettled([tx, read], names: ['slow transaction', 'read behind it'], timeout: _limit);
      expect(r[0].value, 'done');
      expect(r[1].value, 30, reason: 'the read ran after the commit, not inside the working transaction');
    });

    test('G12: a pause does not wait for a transaction whose read was collapsed onto an identical read the pause holds', () async {
      // Chaos seeds 98265 / 98534: B's transaction reads A; the read is answered by an identical read queued on A
      // outside any transaction, so the queued task's caller showed no transaction. The global pause waited for B's
      // transaction, B for the read, the read for the resume that comes after the pause.
      await a.save(row(a, 1));
      await FluentDb.pauseQueue(dbKey: keyA).timeout(_limit);
      final Future<int> outside = a.count(); // queued on the paused database
      final Completer<void> bReads = Completer<void>();
      final Future<Object?> bt = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        final Future<int> read = a.count(); // collapses onto the queued read
        bReads.complete();
        return await read;
      }, dbKey: keyB);
      await bReads.future.timeout(_limit);
      await FluentDb.pauseQueue().timeout(_limit, onTimeout: () => fail('G12: pauseQueue waited for a transaction that waits for the pause'));
      FluentDb.resumeQueue();
      final List<Settled> r = await waitAllSettled([outside, bt], names: ['read outside', 'B reads A'], timeout: _limit);
      expect([r[0].value, r[1].value], [1, 1]);
      expect(await ids(b), [2]);
      await integrity();
    });

    test('G12: three databases — A reads B behind a queued write, B waits for C, C calls A: the call closing the cycle is refused', () async {
      final Completer<void> cIn = Completer<void>(), bWaits = Completer<void>(), queued = Completer<void>(), aReads = Completer<void>();
      final Future<Object?> ct = FluentDb.transaction(() async {
        await c.save(row(c, 3));
        cIn.complete();
        await aReads.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await a.save(row(a, 30)); // closes A → B → C → A
        return 'c';
      }, dbKey: keyC);
      final Future<Object?> bt = FluentDb.transaction(() async {
        await b.save(row(b, 2));
        await cIn.future;
        final Future<Object?> call = c.save(row(c, 20)); // waits for C
        bWaits.complete();
        await call;
        return 'b';
      }, dbKey: keyB);
      final Future<Object?> write = bWaits.future.then((_) async {
        final Future<Object?> w = b.save(row(b, 9)); // queued behind the transaction on B
        await Future<void>.delayed(const Duration(milliseconds: 10));
        queued.complete();
        return w;
      });
      final Future<Object?> at = FluentDb.transaction(() async {
        await a.save(row(a, 1));
        await queued.future;
        final Future<int> read = b.count(); // behind the queued write on B
        aReads.complete();
        return await read;
      }, dbKey: keyA);
      final List<Settled> r = await waitAllSettled([at, bt, ct, write], names: ['A reads B', 'B writes C', 'C writes A', 'write to B'], timeout: _limit);
      expectDeadlock(r[2], cycle: '${keyA.dbName} → ${keyB.dbName} → ${keyC.dbName} → ${keyA.dbName}');
      expect(r[1].value, 'b');
      expect(r[3].failed, isFalse);
      expect(r[0].value, 2, reason: 'G7: the read ran after B committed and after the write queued before it: rows 2 and 9');
      expect(await ids(a), [1]);
      expect(await ids(b), [2, 9]);
      expect(await ids(c), [20], reason: 'G1: the refused transaction on C rolled back as a whole');
      await integrity();
    });
  });

  group('G12: deadlock-prone shapes — every call made from inside completes or is refused with ignoredCall', () {
    // Each public call from each place where user code runs inside the library. A call that cannot be awaited there
    // (a synchronous callback, a running task: awaiting a queued call would wait for the task) is made unawaited
    // and awaited after the context ended.
    final Map<String, Future<Object?> Function(_Ctx ctx)> calls = {
      'save': (c) => c.items.save(c.items.row({'id': 100, 'code': null, 'name': 'inner', 'qty': 1})),
      'find': (c) => c.items.find(),
      'count': (c) => c.items.count(),
      'transaction': (c) => FluentDb.transaction(() => c.items.save(c.items.row({'id': 101, 'code': null, 'name': 'inner txn', 'qty': 1})), dbKey: c.db.key),
      'clear': (c) => FluentDb.clear(dbKey: c.db.key),
      'cleanOrphans': (c) => FluentDb.cleanOrphans(dbKey: c.db.key),
      'purgeArchivedColumns': (c) => FluentDb.purgeArchivedColumns(olderThan: Duration.zero, dbKey: c.db.key),
      'close': (c) => FluentDb.close(),
      'restart': (c) => FluentDb.restart(),
      'pauseQueue': (c) => FluentDb.pauseQueue(dbKey: c.db.key),
      'syncWithServer': (c) => FluentDb.syncWithServer<_SyncNote>(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult<_SyncNote>.accepted(), dbKey: c.db.key),
    };

    // Each context runs `call` once and returns when the context ended; the call's future is stored in ctx.inner.
    final Map<String, Future<void> Function(_Ctx ctx, Future<Object?> Function() call)> contexts = {
      'a transaction': (c, call) => FluentDb.transaction(() async {
        c.inner = call();
        await c.inner!.timeout(_limit);
      }, dbKey: c.db.key),
      'a running task': (c, call) async {
        await FluentEngine().dispatch(
          FluentTask(
            action: FluentDbAction.transaction,
            dbName: c.db.name,
            data: () async {
              c.inner = call();
              return null;
            },
          ),
        );
      },
      'a converter': (c, call) async {
        _HookConverter.onFire = () => c.inner = call();
        await c.hooked.save(c.hooked.row({'id': 1, 'tag': 'fire'}));
        _HookConverter.onFire = null;
      },
      'a watch listener': (c, call) async {
        final Completer<void> fired = Completer<void>();
        final StreamSubscription<List<DynamicModel>> sub = c.items.watch().listen((_) {
          if (fired.isCompleted) return;
          c.inner = call();
          fired.complete();
        });
        await fired.future.timeout(_limit);
        await c.inner!.then<void>((_) {}, onError: (Object _) {}).timeout(_limit);
        await sub.cancel();
      },
      'an onRecord sink': (c, call) async {
        bool armed = true;
        FluentDb.setupLogging(
          enabled: true,
          level: FluentLogLevel.debug,
          console: false,
          onRecord: (r) {
            if (!armed || !FluentEngine().isInsideTask) return;
            armed = false;
            c.inner = call();
          },
        );
        // A save that fails (UNIQUE clash): its error is logged inside the task.
        await c.items.save(c.items.row({'id': 50, 'code': 'one', 'name': 'trigger', 'qty': 0})).then<void>((_) {}, onError: (Object _) {});
        FluentDb.setupLogging(removeOnRecord: true, enabled: false);
        if (armed) fail('no log record was written inside a task');
      },
      'onMigrate': (c, call) async {
        final DynamicProvider v2 = DynamicProvider.spec(
          'items',
          TableSpec(
            columns: _itemColumns,
            migrations: [
              FluentDbMigration(
                version: 2,
                onMigrate: (txn) async {
                  c.inner = call();
                  try {
                    await c.inner!.timeout(_limit);
                  } on TimeoutException {
                    c.hungInside = true;
                  } catch (_) {
                    // the outcome is checked after the start
                  }
                },
              ),
            ],
          ),
        );
        c.items = v2;
        await c.db.restart([v2, c.hooked, c.sync]);
      },
    };

    for (final MapEntry<String, Future<void> Function(_Ctx, Future<Object?> Function())> context in contexts.entries) {
      for (final MapEntry<String, Future<Object?> Function(_Ctx)> call in calls.entries) {
        test('G12: ${call.key} from ${context.key}', () async {
          final _Ctx c = _Ctx(FluentTestDb(persistent: true), _items(), DynamicProvider('hooked', () => [FluentDbColumn.integer('id'), FluentDbColumn.converted('tag', const _HookConverter())]), _SyncNotes());
          await c.db.open([c.items, c.hooked, c.sync]);
          await c.items.save(c.items.row({'id': 1, 'code': 'one', 'name': 'one', 'qty': 1}));
          await c.sync.save(_SyncNote(id: 'n1', text: 'pending'));
          try {
            final Future<void> ctx = context.value(c, () => call.value(c));
            final List<Settled> outer = await waitAllSettled([ctx], names: ['the context (${context.key})'], typedErrors: false);
            expect(c.hungInside, isFalse, reason: 'G12: ${call.key} awaited inside ${context.key} never completed');
            expect(c.inner, isNotNull, reason: 'the context ran the call');
            await waitAllSettled([c.inner!], names: [call.key]);
            if (outer.single.failed) expectTypedError(outer.single.error!, reason: 'the context');
            FluentDb.resumeQueue();
            // The library works afterwards (G12: no stuck queue, pause, scope or lock).
            if (!FluentDb.isOpen(dbKey: c.db.key)) await FluentDb.restart().timeout(_limit);
            if (!FluentDb.isOpen(dbKey: c.db.key)) await c.db.open([c.items, c.hooked, c.sync]).timeout(_limit);
            final List<Settled> after = await waitAllSettled([
              c.items.save(c.items.row({'id': 200, 'code': null, 'name': 'after', 'qty': 0})),
              c.items.findById(200),
              FluentDb.transaction(() => c.items.count(), dbKey: c.db.key),
            ], names: ['save after', 'read after', 'transaction after']);
            expect((after[1].value as DynamicModel?)?['name'], 'after');
            await expectIntegrity(c.items.db);
            expectIssuesHaveFixes(c.db.issues);
          } finally {
            _HookConverter.onFire = null;
            FluentDb.resumeQueue();
            await c.db.close().timeout(_limit);
          }
        });
      }
    }
  });
}

class _Ctx {
  _Ctx(this.db, this.items, this.hooked, this.sync);

  final FluentTestDb db;
  DynamicProvider items;
  final DynamicProvider hooked;
  final _SyncNotes sync;
  Future<Object?>? inner;
  bool hungInside = false;
}
