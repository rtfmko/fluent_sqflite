// Guarantee tests of CRUD and transactions (TEST_PLAN.md, agent T4): G1, G2, G8, G9, G16, G21, G29.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/faults.dart';
import '../../helpers/guarantees.dart';
import 'crud_guarantee_models.dart';

class _Boom implements Exception {
  @override
  String toString() => 'boom';
}

/// Everything a Doc model holds, as text (the app's view of one model object).
String docState(Doc d) =>
    '${d.primaryKeyValue}|${d.title}|${d.qty}|${d.note}|${d.code}|${d.flag}|${d.seen?.millisecondsSinceEpoch}|c${d.createdAt?.millisecondsSinceEpoch}|u${d.updatedAt?.millisecondsSinceEpoch}|d${d.deletedAt?.millisecondsSinceEpoch}';

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  late FluentTestDb db;
  late DocProvider docs;
  late LeaseProvider leases;
  late StampProvider stamps;
  final DateTime t0 = DateTime.utc(2026, 3, 1, 12);

  Future<void> open({FluentConfig fluentConfig = const FluentConfig()}) async {
    db.clock.set(t0);
    docs = DocProvider();
    leases = LeaseProvider();
    stamps = StampProvider();
    await db.open([docs, leases, stamps], fluentConfig: fluentConfig);
  }

  setUp(() async {
    faults = await FaultyDatabaseFactory.install();
    db = FluentTestDb(persistent: true);
    await open();
  });

  tearDown(() async {
    faults.heal();
    await db.close();
    faults.uninstall();
  });

  /// Every column of every row, including the ones the library keeps (G1 / G21: nothing changed).
  Future<List<Map<String, Object?>>> rawRows(String table) async => (await docs.db.rawQuery('SELECT * FROM "$table" ORDER BY id')).map((r) => Map<String, Object?>.of(r)).toList();

  Future<String> everything() async => jsonEncode([await rawRows('docs'), await rawRows('leases'), await rawRows('stamps')]);

  Future<void> finish() async {
    await db.settle();
    await expectIntegrity(docs.db);
    expectIssuesHaveFixes(db.issues);
  }

  Future<void> seed() async {
    await docs.saveAll([
      Doc(id: 1, title: 'one', qty: 10, note: 'n1', code: 'c1', flag: true, seen: DateTime.fromMillisecondsSinceEpoch(1700000000000)),
      Doc(id: 2, title: 'two', qty: 20),
      Doc(id: 3, title: 'three', qty: 30, note: 'n3'),
    ]);
    db.clock.advance(const Duration(seconds: 5));
    await docs.deleteById(3);
    await leases.saveAll([Lease(id: 1, val: 'l1'), Lease(id: 2, val: 'l2')]);
    db.clock.advance(const Duration(seconds: 5));
  }

  group('G1 / G2: a call applies completely or not at all, the models stay as they were', () {
    test('G1: saveAll with one unique violation writes nothing and gives no model a key', () async {
      await docs.save(Doc(id: 1, title: 'a', code: 'x'));
      final String before = await everything();
      final List<Doc> items = [Doc(title: 'n1'), Doc(title: 'n2'), Doc(title: 'dup', code: 'x'), Doc(title: 'n4')];
      final List<String> states = items.map(docState).toList();
      try {
        await docs.saveAll(items);
        fail('the unique violation must reach the caller');
      } catch (e) {
        expect(e, isA<FluentConstraintException>());
        expectTypedError(e);
      }
      expect(await everything(), before, reason: 'G1: nothing of the failed saveAll');
      expect(items.map(docState).toList(), states, reason: 'G2: no key was injected into a model of the failed call');
      await finish();
    });

    test('G1 / G2: a rolled-back transaction restores rows and models (keys, deletedAt, timestamps)', () async {
      await seed();
      final Doc one = (await docs.findById(1))!;
      final Doc two = (await docs.findById(2))!;
      final Doc trashed = (await docs.withTrash.findById(3))!;
      final Doc fresh = Doc(title: 'fresh');
      final Doc modified = Doc(id: 2, title: 'two*', qty: 99);
      final List<Doc> all = [one, two, trashed, fresh, modified];
      final List<String> states = all.map(docState).toList();
      final String before = await everything();
      db.clock.advance(const Duration(minutes: 1));
      await expectLater(
        FluentDb.transaction(() async {
          await docs.save(fresh);
          expect(fresh.primaryKeyValue, isNotNull, reason: 'a key is visible to later calls of the transaction');
          await docs.save(modified);
          await docs.delete(one);
          expect(one.deletedAt, isNull, reason: 'the stamp is applied after the commit');
          await docs.trash.restore(trashed);
          await docs.updateById(2, {'qty': FluentUpdate.increment(5)});
          await docs.deleteWhere(FluentFilter.gt('qty', 50));
          await leases.save(Lease(val: 'in txn'));
          await docs.trash.deleteForeverById(3);
          throw _Boom();
        }),
        throwsA(isA<_Boom>()),
      );
      expect(await everything(), before, reason: 'G1: rows, timestamps and the sequence of keys as before');
      expect(all.map(docState).toList(), states, reason: 'G2: every model as before the transaction');
      expect(fresh.primaryKeyValue, isNull, reason: 'G2: the generated key is taken back');
      // The next save gets the key the rolled-back one had (nothing was left behind).
      final Doc next = Doc(title: 'next');
      await docs.save(next);
      expect(next.primaryKeyValue, 4);
      await finish();
    });

    test('G2: a committed transaction gives the models the stored stamps and keys', () async {
      await seed();
      final Doc fresh = Doc(title: 'fresh');
      final Doc one = (await docs.findById(1))!;
      final Doc trashed = (await docs.withTrash.findById(3))!;
      db.clock.advance(const Duration(minutes: 1));
      await FluentDb.transaction(() async {
        await docs.save(fresh);
        await docs.delete(one);
        await docs.trash.restore(trashed);
      });
      expect(fresh.primaryKeyValue, isNotNull);
      expect(one.deletedAt, isNotNull, reason: 'G2: the stamp stored with the delete is on the model after the commit');
      expect(one.deletedAt!.millisecondsSinceEpoch, greaterThanOrEqualTo(db.clock.now.millisecondsSinceEpoch), reason: 'stamps never go back (strictly increasing within the process)');
      expect((await rawRows('docs')).firstWhere((r) => r['id'] == 1)['deleted_at'], one.deletedAt!.millisecondsSinceEpoch);
      expect(trashed.deletedAt, isNull);
      expect((await docs.withTrash.findById(1))!.deletedAt?.millisecondsSinceEpoch, one.deletedAt!.millisecondsSinceEpoch);
      await finish();
    });

    test('G1 / G2: a failed inner savepoint drops only its own writes and models; the outer transaction commits', () async {
      await seed();
      final Doc outer = Doc(title: 'outer');
      final Doc inner = Doc(title: 'inner');
      final Doc one = (await docs.findById(1))!;
      await FluentDb.transaction(() async {
        await docs.save(outer);
        try {
          await FluentDb.transaction(() async {
            await docs.save(inner);
            await docs.delete(one);
            await docs.updateById(2, {'qty': 777});
            throw _Boom();
          });
        } on _Boom {
          // the app handles it
        }
        expect(inner.primaryKeyValue, isNull, reason: 'G2: the savepoint took the key back');
        await docs.updateById(1, {'note': 'after'});
      });
      expect(outer.primaryKeyValue, isNotNull);
      expect(inner.primaryKeyValue, isNull);
      expect(one.deletedAt, isNull);
      expect(await docs.findById(2).then((d) => d!.qty), 20, reason: 'G1: the savepoint rolled back its update');
      expect(await docs.findById(1).then((d) => d!.note), 'after');
      expect(await docs.findMaps(where: FluentFilter.eq('title', 'inner')), isEmpty);
      expect(await docs.findMaps(where: FluentFilter.eq('title', 'outer')), hasLength(1));
      await finish();
    });

    test('G1: a failing call inside a transaction that the app catches leaves none of its writes (also the other calls commit)', () async {
      await docs.save(Doc(id: 1, title: 'a', code: 'x'));
      await FluentDb.transaction(() async {
        await docs.save(Doc(id: 2, title: 'ok'));
        try {
          await docs.saveAll([Doc(id: 3, title: 'half'), Doc(id: 4, title: 'dup', code: 'x')]);
        } on FluentConstraintException {
          // caught
        }
        await docs.save(Doc(id: 5, title: 'ok2'));
      });
      expect((await docs.findAll(orderBy: 'id')).map((d) => d.id), [1, 2, 5], reason: 'the half-written saveAll is not kept');
      await finish();
    });

    // Every statement of each scenario fails once (writes and the COMMIT): typed error with hint, state as before, the
    // next call works (heal + run again).
    final Map<String, (Future<void> Function() arrange, Future<Object?> Function() act, List<Doc> Function() models)> scenarios = {};
    List<Doc> noModels() => [];
    late List<Doc> current;
    scenarios['saveAll of three new models'] = (
      () async => current = [Doc(title: 'a'), Doc(title: 'b', code: 'k'), Doc(title: 'c')],
      () => docs.saveAll(current),
      () => current,
    );
    scenarios['saveAll updates + inserts, patch'] = (
      () async {
        await seed();
        current = [Doc(id: 1, title: 'one!', qty: 11), Doc(id: 2, title: 'two!', note: 'x'), Doc(id: 8, title: 'new')];
      },
      () => docs.saveAll(current, strategy: FluentSaveStrategy.patch),
      () => current,
    );
    scenarios['saveAll with conflictOn'] = (
      () async {
        await seed();
        current = [Doc(title: 'by code', code: 'c1'), Doc(title: 'new', code: 'c9')];
      },
      () => docs.saveAll(current, conflictOn: ['code']),
      () => current,
    );
    scenarios['saveAll over a row in the trash (restore)'] = (
      () async {
        await seed();
        current = [Doc(id: 3, title: 'three again'), Doc(id: 9, title: 'nine')];
      },
      () => docs.saveAll(current),
      () => current,
    );
    scenarios['deleteWhere (soft)'] = (
      () async {
        await seed();
        current = [(await docs.findById(1))!, (await docs.findById(2))!];
      },
      () => docs.deleteWhere(FluentFilter.gt('qty', 0)),
      () => current,
    );
    scenarios['deleteAll(models)'] = (
      () async {
        await seed();
        current = [(await docs.findById(1))!, (await docs.findById(2))!];
      },
      () => docs.deleteAll(current),
      () => current,
    );
    scenarios['trash.restoreWhere'] = (() async => seed(), () => docs.trash.restoreWhere(FluentFilter.gt('qty', 0)), noModels);
    scenarios['trash.deleteForeverWhere'] = (() async => seed(), () => docs.trash.deleteForeverWhere(FluentFilter.gt('qty', 0)), noModels);
    scenarios['updateWhere'] = (() async => seed(), () => docs.updateWhere(FluentFilter.gt('qty', 0), {'qty': FluentUpdate.increment(3), 'note': 'w', 'flag': FluentUpdate.toggle}), noModels);
    scenarios['updateById'] = (() async => seed(), () => docs.updateById(1, {'title': 'renamed', 'seen': FluentUpdate.now}), noModels);
    scenarios['clearTable'] = (() async => seed(), () => docs.clearTable(), noModels);
    scenarios['transaction with several writes'] = (
      () async {
        await seed();
        current = [Doc(title: 'a'), Doc(title: 'b')];
      },
      () => FluentDb.transaction<void>(() async {
        await docs.saveAll(current);
        await docs.deleteById(1);
        await docs.updateById(2, {'qty': 5});
        await leases.save(Lease(val: 'x'));
        await docs.trash.restoreById(3);
      }),
      () => current,
    );
    scenarios['transaction with a savepoint'] = (
      () async {
        await seed();
        current = [Doc(title: 'a'), Doc(title: 'b')];
      },
      () => FluentDb.transaction<void>(() async {
        await docs.save(current[0]);
        await FluentDb.transaction<void>(() async {
          await docs.save(current[1]);
          await docs.deleteById(2);
        });
        await docs.updateById(1, {'qty': 1});
      }),
      () => current,
    );
    scenarios['clearExpired'] = (
      () async {
        await seed();
        db.clock.advance(const Duration(hours: 2));
      },
      () => leases.clearExpired(),
      noModels,
    );

    for (final MapEntry<String, (Future<void> Function(), Future<Object?> Function(), List<Doc> Function())> s in scenarios.entries) {
      test('G1 / G2 / G13: ${s.key}: a failure at any statement changes nothing and the next call works', () async {
        final (Future<void> Function() arrange, Future<Object?> Function() act, List<Doc> Function() models) = s.value;
        bool completedWithoutFault = false;
        for (int n = 0; n < 40 && !completedWithoutFault; n++) {
          await docs.clearTable();
          await leases.clearTable();
          // clearTable resets the key sequence of nothing: keys are rowids, so a cleared table starts at 1 again.
          faults.heal();
          faults.injected.clear();
          db.clock.set(t0);
          await arrange();
          final String before = await everything();
          final List<String> modelsBefore = models().map(docState).toList();
          faults.failNth(n, where: (c) => c.isWrite || c.isCommit);
          Object? error;
          try {
            await act();
          } catch (e) {
            error = e;
          }
          faults.heal();
          if (faults.injected.isEmpty) {
            expect(error, isNull, reason: 'no fault fired: the call must succeed');
            completedWithoutFault = true;
            expect(n, greaterThan(0), reason: 'the scenario sent no write at all');
            break;
          }
          expect(error, isNotNull, reason: 'G1: a failed statement ($n: ${faults.injected.first}) reaches the caller');
          expectTypedError(error!, reason: '${s.key} statement $n: ${faults.injected.first}');
          expect(await everything(), before, reason: 'G1: ${s.key}, statement $n (${faults.injected.first}) left traces');
          expect(models().map(docState).toList(), modelsBefore, reason: 'G2: ${s.key}, statement $n changed a model');
          await expectIntegrity(docs.db, reason: '${s.key} statement $n');
          await act(); // the library works again
        }
        expect(completedWithoutFault, isTrue, reason: 'more than 40 statements?');
        await finish();
      });
    }

    test('G1: every FaultKind at a write and at the commit is reported typed and rolls back', () async {
      await seed();
      for (final FaultKind kind in FaultKind.values) {
        for (final bool atCommit in [false, true]) {
          final String before = await everything();
          faults.failNth(0, where: atCommit ? (c) => c.isCommit : (c) => c.isWrite, kind: kind);
          Object? error;
          try {
            await docs.saveAll([Doc(title: 'x-${kind.name}'), Doc(id: 1, title: 'one!')]);
          } catch (e) {
            error = e;
          }
          faults.heal();
          expect(error, isNotNull, reason: '${kind.name} atCommit=$atCommit');
          expectTypedError(error!, reason: kind.name);
          expect(await everything(), before, reason: 'G1: ${kind.name} atCommit=$atCommit');
        }
      }
      await finish();
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // G8
  // ---------------------------------------------------------------------------------------------------------------
  group('G8: every read agrees on which rows exist', () {
    // 1 live; 2 live, expires in 1 h; 3 trashed; 4 trashed, expires in 1 h; 5 live, 1 day; 6 trashed, 1 day. After 2 h: 2 and 4 are expired.
    Future<void> states() async {
      await docs.saveAll([
        Doc(id: 1, title: 'live', qty: 10),
        Doc(id: 2, title: 'live ttl', qty: 20, timeToLive: const Duration(hours: 1)),
        Doc(id: 3, title: 'trashed', qty: 30),
        Doc(id: 4, title: 'trashed ttl', qty: 40, timeToLive: const Duration(hours: 1)),
        Doc(id: 5, title: 'live day', qty: 50, timeToLive: const Duration(days: 1)),
        Doc(id: 6, title: 'trashed day', qty: 60, timeToLive: const Duration(days: 1)),
      ]);
      await docs.deleteWhere(FluentFilter.inList('id', [3, 4, 6]));
      db.clock.advance(const Duration(hours: 2));
    }

    final Map<String, (bool withTrash, bool includeExpired, List<int> expected)> scopes = {
      'default': (false, false, [1, 5]),
      'includeExpired': (false, true, [1, 2, 5]),
      'withTrash': (true, false, [1, 3, 5, 6]),
      'withTrash + includeExpired': (true, true, [1, 2, 3, 4, 5, 6]),
    };

    for (final MapEntry<String, (bool, bool, List<int>)> scope in scopes.entries) {
      test('G8: find / findById / findByIds / count / exists / findPage / aggregate / pluck / watch agree under "${scope.key}"', () async {
        await states();
        final (bool all, bool exp, List<int> expected) = scope.value;
        final String r = scope.key;
        // The reads of one provider or of its withTrash view, same arguments.
        Future<List<Doc>> find({FluentFilter? where, String? orderBy = 'id', int? limit, int? offset}) =>
            all ? docs.withTrash.find(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: exp) : docs.find(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: exp);
        Future<int> count({FluentFilter? where}) => all ? docs.withTrash.count(where: where, includeExpired: exp) : docs.count(where: where, includeExpired: exp);
        Future<Doc?> byId(int id) => all ? docs.withTrash.findById(id, includeExpired: exp) : docs.findById(id, includeExpired: exp);
        Future<bool> exists(int id) => all ? docs.withTrash.exists(id, includeExpired: exp) : docs.exists(id, includeExpired: exp);
        Future<bool> existsWhere(FluentFilter w) => all ? docs.withTrash.existsWhere(w, includeExpired: exp) : docs.existsWhere(w, includeExpired: exp);

        expect((await find()).map((d) => d.primaryKeyValue), expected, reason: '$r find');
        expect((await (all ? docs.withTrash.findAll(orderBy: 'id', includeExpired: exp) : docs.findAll(orderBy: 'id', includeExpired: exp))).map((d) => d.primaryKeyValue), expected, reason: '$r findAll');
        expect(await count(), expected.length, reason: '$r count');
        expect(await count(where: FluentFilter.gt('qty', 25)), expected.where((i) => i * 10 > 25).length, reason: '$r count where');
        expect((await find(where: FluentFilter.gt('qty', 25))).map((d) => d.primaryKeyValue), expected.where((i) => i * 10 > 25), reason: '$r find where');
        expect((await find(limit: 2, offset: 1)).map((d) => d.primaryKeyValue), expected.skip(1).take(2), reason: '$r find limit/offset');
        expect(await existsWhere(FluentFilter.eq('title', 'live')), expected.contains(1), reason: '$r existsWhere');
        for (int id = 1; id <= 6; id++) {
          expect((await byId(id))?.primaryKeyValue, expected.contains(id) ? id : isNull, reason: '$r findById($id)');
          expect(await exists(id), expected.contains(id), reason: '$r exists($id)');
        }
        expect(
          (await (all ? docs.withTrash.findByIds([6, 1, 2, 3, 4, 5, 99], includeExpired: exp) : docs.findByIds([6, 1, 2, 3, 4, 5, 99], includeExpired: exp))).map((d) => d.primaryKeyValue),
          [6, 1, 2, 3, 4, 5].where(expected.contains),
          reason: '$r findByIds keeps the order of the ids',
        );
        expect((await (all ? docs.withTrash.findFirst(orderBy: 'id DESC', includeExpired: exp) : docs.findFirst(orderBy: 'id DESC', includeExpired: exp)))?.primaryKeyValue, expected.last, reason: '$r findFirst');
        expect((await (all ? docs.withTrash.findMaps(columns: ['id'], orderBy: 'id', includeExpired: exp) : docs.findMaps(columns: ['id'], orderBy: 'id', includeExpired: exp))).map((m) => m['id']), expected, reason: '$r findMaps');
        expect(await (all ? docs.withTrash.pluck<int>('id', orderBy: 'id', includeExpired: exp) : docs.pluck<int>('id', orderBy: 'id', includeExpired: exp)), expected, reason: '$r pluck');
        // Paging visits the same rows.
        final List<int> paged = [];
        FluentCursor? after;
        do {
          final FluentPage<Doc> page = all ? await docs.withTrash.findPage(limit: 2, after: after, includeExpired: exp) : await docs.findPage(limit: 2, after: after, includeExpired: exp);
          paged.addAll(page.items.map((d) => d.primaryKeyValue! as int));
          after = page.next;
        } while (after != null);
        expect(paged, expected, reason: '$r findPage');
        // Aggregates.
        final Map<String, FluentAggregate> values = {'n': const FluentAggregate.count(), 's': const FluentAggregate.sum('qty'), 'lo': const FluentAggregate.min('id'), 'hi': const FluentAggregate.max('id'), 'd': const FluentAggregate.countDistinct('title')};
        final Map<String, dynamic> agg = (await (all ? docs.withTrash.aggregate(values: values, includeExpired: exp) : docs.aggregate(values: values, includeExpired: exp))).single;
        expect(agg['n'], expected.length, reason: '$r aggregate count');
        expect(agg['s'], expected.fold<int>(0, (a, i) => a + i * 10), reason: '$r aggregate sum');
        expect(agg['lo'], expected.isEmpty ? null : expected.first, reason: '$r aggregate min');
        expect(agg['hi'], expected.isEmpty ? null : expected.last, reason: '$r aggregate max');
        expect(agg['d'], expected.length, reason: '$r aggregate countDistinct');
        expect(await (all ? docs.withTrash.sum('qty', includeExpired: exp) : docs.sum('qty', includeExpired: exp)), expected.fold<int>(0, (a, i) => a + i * 10), reason: '$r sum');
        expect(await (all ? docs.withTrash.max<int>('id', includeExpired: exp) : docs.max<int>('id', includeExpired: exp)), expected.last, reason: '$r max');
        expect(await (all ? docs.withTrash.min<int>('id', includeExpired: exp) : docs.min<int>('id', includeExpired: exp)), expected.first, reason: '$r min');
        // The watch's first value.
        final List<Doc> watched = await (all ? docs.withTrash.watch(orderBy: 'id', includeExpired: exp) : docs.watch(orderBy: 'id', includeExpired: exp)).first.timeout(const Duration(seconds: 5));
        expect(watched.map((d) => d.primaryKeyValue), expected, reason: '$r watch');
        final Doc? watchedOne = await (all ? docs.withTrash.watchById(3, includeExpired: exp) : docs.watchById(3, includeExpired: exp)).first.timeout(const Duration(seconds: 5));
        expect(watchedOne?.primaryKeyValue, expected.contains(3) ? 3 : isNull, reason: '$r watchById');
        await finish();
      });
    }

    test('G8: the trash shows exactly the trashed rows (expired ones too) and agrees with withTrash', () async {
      await states();
      expect((await docs.trash.find(orderBy: 'id')).map((d) => d.primaryKeyValue), [3, 4, 6]);
      expect(await docs.trash.count(), 3);
      expect(await docs.trash.count(where: FluentFilter.gt('qty', 35)), 2);
      final List<Map<String, dynamic>> viaWithTrash = await docs.withTrash.findMaps(columns: ['id'], where: FluentFilter.isNotNull('deleted_at'), orderBy: 'id', includeExpired: true);
      expect(viaWithTrash.map((m) => m['id']), [3, 4, 6]);
      expect((await docs.trash.watch(orderBy: 'id').first.timeout(const Duration(seconds: 5))).map((d) => d.primaryKeyValue), [3, 4, 6]);
      // Trashed rows are not found by the live reads, whatever the ttl.
      expect(await docs.findById(3), isNull);
      expect(await docs.exists(3, includeExpired: true), isFalse);
      expect(await docs.count(includeExpired: true), 3);
      await finish();
    });

    test('G8: a row that expires between two reads leaves every read at the same moment; includeExpired still sees it', () async {
      await docs.save(Doc(id: 1, title: 'ttl', timeToLive: const Duration(minutes: 30)));
      expect(await docs.count(), 1);
      db.clock.advance(const Duration(minutes: 31));
      expect(await docs.count(), 0);
      expect(await docs.findAll(), isEmpty);
      expect(await docs.exists(1), isFalse);
      expect(await docs.findById(1), isNull);
      expect(await docs.pluck<int>('id'), isEmpty);
      expect(await docs.sum('qty'), 0);
      expect(await docs.findById(1, includeExpired: true), isNotNull);
      expect(await docs.count(includeExpired: true), 1);
      expect(await docs.clearExpired(), 1, reason: 'G21: the expired row goes only when asked');
      expect(await docs.count(includeExpired: true), 0);
      await finish();
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // G9
  // ---------------------------------------------------------------------------------------------------------------
  group('G9: soft delete is reversible', () {
    Map<String, Object?> withoutStamp(Map<String, Object?> r) => {...r, 'deleted_at': null};

    test('G9: delete then restore gives back identical rows (every call form), models included', () async {
      final List<Doc> items = [
        for (int i = 1; i <= 8; i++)
          Doc(id: i, title: 'doc $i', qty: i * 3, note: i.isEven ? 'note $i' : null, code: i % 3 == 0 ? 'c$i' : null, flag: i % 4 == 0 ? true : (i % 5 == 0 ? false : null), seen: i.isOdd ? DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000) : null),
      ];
      for (final Doc d in items) {
        await docs.save(d);
        db.clock.advance(const Duration(seconds: 7));
      }
      final List<Map<String, Object?>> before = await rawRows('docs');
      final List<String> states = [for (final Doc d in await docs.findAll(orderBy: 'id')) docState(d)];

      final List<Doc> loaded = await docs.findAll(orderBy: 'id');
      db.clock.advance(const Duration(minutes: 1));
      await docs.delete(loaded[0]); // delete(item)
      await docs.deleteAll([loaded[1], loaded[2]]);
      await docs.deleteById(4);
      await docs.deleteWhere(FluentFilter.gte('qty', 15));
      expect(await docs.count(), 0);
      expect(await docs.trash.count(), 8);
      expect((await rawRows('docs')).map(withoutStamp).toList(), before.map(withoutStamp).toList(), reason: 'G9: a delete changes only deleted_at');
      db.clock.advance(const Duration(hours: 5));

      expect(await docs.trash.restore(loaded[0]), 1); // restore(item)
      expect(loaded[0].deletedAt, isNull);
      expect(await docs.trash.restoreById(2), 1);
      expect(await docs.trash.restoreWhere(FluentFilter.gte('id', 3)), 6);
      expect(await rawRows('docs'), before, reason: 'G9: identical rows after delete + restore, updated_at included');
      expect([for (final Doc d in await docs.findAll(orderBy: 'id')) docState(d)], states);
      await finish();
    });

    test('G9: delete twice keeps the first stamp (returns 0), restore of a live row changes nothing', () async {
      await docs.saveAll([Doc(id: 1, title: 'a'), Doc(id: 2, title: 'b')]);
      final Doc a = (await docs.findById(1))!;
      expect(await docs.delete(a), 1);
      final Object? first = (await rawRows('docs')).first['deleted_at'];
      expect(first, isNotNull);
      db.clock.advance(const Duration(hours: 1));
      expect(await docs.delete(a), 0);
      expect(await docs.deleteById(1), 0);
      expect((await rawRows('docs')).first['deleted_at'], first);
      final String before = jsonEncode(await rawRows('docs'));
      expect(await docs.trash.restoreById(2), 0, reason: 'a live row is not "restored"');
      expect(await docs.trash.restoreById(99), 0);
      expect(await docs.delete(Doc(id: 99, title: 'never stored')), 0);
      expect(jsonEncode(await rawRows('docs')), before);
      await finish();
    });

    test('G9: trash.empty / retention remove only rows trashed longer ago than the period; live rows and fresher trash stay', () async {
      await open(fluentConfig: const FluentConfig(trashRetention: Duration(days: 1), trashPurgeInterval: Duration(hours: 6)));
      await docs.saveAll([for (int i = 1; i <= 6; i++) Doc(id: i, title: 'd$i')]);
      await docs.deleteById(1);
      db.clock.advance(const Duration(hours: 10));
      await docs.deleteById(2);
      db.clock.advance(const Duration(hours: 10));
      await docs.deleteById(3);
      db.clock.advance(const Duration(hours: 1));
      await db.settle();
      // 1 was trashed 21 h ago, 2: 11 h, 3: 1 h: nothing is past the retention of one day.
      expect((await docs.trash.find(orderBy: 'id')).map((d) => d.primaryKeyValue), [1, 2, 3]);
      expect(await docs.trash.empty(olderThan: const Duration(hours: 12)), 1, reason: 'only row 1 is older than 12 h');
      expect((await docs.trash.find(orderBy: 'id')).map((d) => d.primaryKeyValue), [2, 3]);
      expect(await docs.count(), 3, reason: 'live rows are never purged');
      db.clock.advance(const Duration(hours: 14)); // 2: 25 h, 3: 15 h
      await db.settle();
      expect((await docs.trash.find(orderBy: 'id')).map((d) => d.primaryKeyValue), [3], reason: 'the retention purge removed the row trashed more than a day ago only');
      expect((await docs.findAll(orderBy: 'id')).map((d) => d.primaryKeyValue), [4, 5, 6]);
      expect(await docs.trash.empty(olderThan: Duration.zero), 1, reason: 'Duration.zero empties the trash');
      expect(await docs.withTrash.count(), 3);
      await finish();
    });

    test('G9: deleteForever removes live and trashed rows for good; only explicit', () async {
      await docs.saveAll([for (int i = 1; i <= 4; i++) Doc(id: i, title: 'd$i')]);
      await docs.deleteById(2);
      expect(await docs.trash.deleteForeverById(2), 1);
      expect(await docs.trash.deleteForeverById(1), 1, reason: 'a live row too');
      expect(await docs.trash.deleteForeverWhere(FluentFilter.eq('id', 3)), 1);
      expect(await docs.trash.deleteForever(Doc(id: 4, title: 'x')), 1);
      expect(await docs.withTrash.count(), 0);
      await finish();
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // G21
  // ---------------------------------------------------------------------------------------------------------------
  group('G21: rows disappear only by an explicit call', () {
    test('G21: reads, watches, saves of every strategy, restarts, clock moves and maintenance never remove a row', () async {
      await seed();
      final List<Map<String, Object?>> before = await rawRows('docs');
      final List<Map<String, Object?>> leasesBefore = await rawRows('leases');
      final StreamSubscription<List<Doc>> sub = docs.watch().listen((_) {});
      final StreamSubscription<List<Doc>> sub2 = docs.trash.watch().listen((_) {});
      Future<void> same(String step) async {
        await db.settle();
        expect((await rawRows('docs')).length, before.length, reason: 'G21: $step removed a row');
        expect((await rawRows('docs')).map((r) => r['id']).toList(), before.map((r) => r['id']).toList(), reason: step);
      }

      await docs.findAll();
      await docs.withTrash.findAll();
      await docs.trash.find();
      await docs.findPage(limit: 1);
      await docs.aggregate(values: {'n': const FluentAggregate.count()});
      await same('reads');
      await docs.saveAll([Doc(id: 1, title: 'x')], strategy: FluentSaveStrategy.insertOnly);
      await docs.saveAll([Doc(id: 2, title: 'y')], strategy: FluentSaveStrategy.patch);
      await docs.saveAll([Doc(id: 3, title: 'z')], strategy: FluentSaveStrategy.updateOnly); // skipped: it is in the trash
      await docs.saveAll([Doc(id: 3, title: 'z')]); // restores
      await docs.updateWhere(FluentFilter.eq('title', 'nothing matches'), {'qty': 1});
      await docs.updateById(99, {'qty': 1});
      await same('saves and updates');
      expect(await docs.clearExpired(), 0, reason: 'no row has a time to live');
      expect(await docs.trash.empty(olderThan: const Duration(days: 30)), 0);
      expect(await docs.trash.empty(), 0, reason: 'the retention (7 days) has not passed');
      await FluentDb.cleanOrphans();
      await same('maintenance');
      db.clock.advance(const Duration(days: 3));
      await same('three days later');
      await sub.cancel();
      await sub2.cancel();
      await leases.save(Lease(id: 9, val: 'fresh'));
      expect((await rawRows('leases')).map((r) => r['id']).toList(), [...leasesBefore.map((r) => r['id']), 9], reason: 'expired rows stay until clearExpired (reads hide them)');
      await db.restart([docs, leases, stamps]);
      await same('a restart');
      expect((await rawRows('leases')).map((r) => r['id']).toList(), [9], reason: 'documented: clearExpired also runs at start; the live row stays');
      await finish();
    });

    test('G21: expired rows leave only through clearExpired (not by reads, saves of other rows or a restart); the rest stays', () async {
      await leases.saveAll([Lease(id: 1, val: 'a'), Lease(id: 2, val: 'b')]);
      db.clock.advance(const Duration(minutes: 30));
      await leases.save(Lease(id: 3, val: 'c')); // expires 30 minutes after the first two
      db.clock.advance(const Duration(minutes: 45)); // 1 and 2 are expired, 3 lives
      expect((await leases.findAll(orderBy: 'id')).map((l) => l.primaryKeyValue), [3]);
      await leases.count();
      await leases.save(Lease(id: 4, val: 'd'));
      expect((await rawRows('leases')).map((r) => r['id']), [1, 2, 3, 4], reason: 'G21: nothing was cleared yet');
      expect(await leases.clearExpired(), 2);
      expect((await rawRows('leases')).map((r) => r['id']), [3, 4]);
      await finish();
    });

    test('G21: the explicit calls remove exactly what they say', () async {
      await seed();
      expect(await docs.deleteWhere(FluentFilter.gt('qty', 100)), 0);
      expect(await docs.trash.deleteForeverById(2), 1);
      expect((await rawRows('docs')).map((r) => r['id']), [1, 3]);
      expect(await docs.clearTable(), 2);
      expect(await rawRows('docs'), isEmpty);
      expect((await rawRows('leases')).length, 2, reason: 'G30: another table keeps its rows');
      await finish();
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // G29
  // ---------------------------------------------------------------------------------------------------------------
  group('G29: exactly what was asked', () {
    const Set<String> publicColumns = {'id', 'title', 'qty', 'note', 'code', 'flag', 'seen', 'created_at', 'updated_at', 'deleted_at'};

    test('G29: findMaps / pluck / aggregate / find return exactly the requested fields, no internal columns', () async {
      final DateTime seen = DateTime.fromMillisecondsSinceEpoch(1700000000123);
      await docs.save(Doc(id: 1, title: 'a', qty: 5, note: 'n', code: 'c', flag: true, seen: seen, timeToLive: const Duration(days: 1)));
      final Map<String, dynamic> all = (await docs.findMaps()).single;
      expect(all.keys.toSet(), publicColumns, reason: 'the managed columns of the mixins and the model fields; no _fs_metadata, no expiry_date');
      expect(all['title'], 'a');
      expect(all['qty'], 5);
      expect(all['note'], 'n');
      expect(all['code'], 'c');
      expect(all['flag'], true);
      expect((all['seen'] as DateTime).millisecondsSinceEpoch, seen.millisecondsSinceEpoch);
      expect(all['created_at'], isNotNull);
      expect(all['deleted_at'], isNull);
      expect((await docs.findMaps(columns: ['title', 'qty'])).single, {'title': 'a', 'qty': 5});
      expect((await docs.findMaps(columns: ['qty'], distinct: true)).single, {'qty': 5});
      expect(await docs.pluck<String>('title'), ['a']);
      expect((await docs.aggregate(values: {'n': const FluentAggregate.count(), 'mx': const FluentAggregate.max('qty')}, groupBy: ['flag'])).single, {'flag': true, 'n': 1, 'mx': 5});
      expect((await docs.aggregate(values: {'n': const FluentAggregate.count()})).single.keys, ['n']);
      expect((await docs.findMaps(columns: ['expiry_date'])).single.keys, ['expiry_date'], reason: 'an internal column comes only when asked for, and then alone');
      final Doc loaded = (await docs.findById(1))!;
      expect(docState(loaded).split('|').sublist(0, 7).join('|'), '1|a|5|n|c|true|${seen.millisecondsSinceEpoch}');
      expect(loaded.deletedAt, isNull);
      expect(loaded.timeToLive, isNull, reason: 'a model read back does not carry the time to live of the saved one');
      await finish();
    });

    test('G29: save stores exactly the model fields; the columns the library keeps are its own', () async {
      db.clock.set(DateTime.utc(2026, 3, 1, 12, 0, 1));
      final Doc forged = Doc(id: 1, title: 'a', qty: 5)
        ..createdAt = DateTime.utc(2000)
        ..updatedAt = DateTime.utc(2001);
      await docs.save(forged);
      final Map<String, Object?> row = (await rawRows('docs')).single;
      expect(row['created_at'], db.clock.now.millisecondsSinceEpoch, reason: 'the library stamps rows; a hand-set createdAt is not stored');
      expect(row['updated_at'], db.clock.now.millisecondsSinceEpoch);
      expect(row['deleted_at'], isNull);
      expect(row['expiry_date'], isNull, reason: 'no timeToLive: no expiry');
      final Object? meta = row['_fs_metadata'];
      if (meta != null) {
        expect((jsonDecode(meta as String) as Map<String, dynamic>).keys.toSet().difference({'id', 'title', 'qty', 'note', 'code', 'flag', 'seen'}), isEmpty, reason: 'type tags only for model fields');
      }
      final Doc live = Doc(id: 2, title: 'b')..deletedAt = DateTime.utc(2020);
      await docs.save(live);
      expect((await rawRows('docs')).last['deleted_at'], isNull, reason: 'a deletedAt set by hand does not trash the row (only delete does)');
      expect(live.deletedAt, isNull);
      final Doc expiring = Doc(id: 3, title: 'ttl', timeToLive: const Duration(hours: 2));
      await docs.save(expiring);
      expect((await rawRows('docs')).last['expiry_date'], db.clock.now.add(const Duration(hours: 2)).millisecondsSinceEpoch);
      await finish();
    });

    test('G29: patch changes only the non-null fields, upsert / update write all, updateOnly never inserts', () async {
      await docs.save(Doc(id: 1, title: 'one', qty: 10, note: 'keep', code: 'k', flag: true, seen: DateTime.fromMillisecondsSinceEpoch(1700000000000)));
      db.clock.advance(const Duration(minutes: 1));
      final Map<String, Object?> before = (await rawRows('docs')).single;
      await docs.save(Doc(id: 1, title: 'patched', qty: 11), strategy: FluentSaveStrategy.patch);
      final Doc patched = (await docs.findById(1))!;
      expect([patched.title, patched.qty, patched.note, patched.code, patched.flag, patched.seen?.millisecondsSinceEpoch], ['patched', 11, 'keep', 'k', true, 1700000000000], reason: 'null fields keep their stored values');
      final Map<String, Object?> after = (await rawRows('docs')).single;
      expect({for (final String k in after.keys) if (after[k] != before[k]) k}.difference({'_fs_metadata'}), {'title', 'qty', 'updated_at'}, reason: 'only the patched columns (and updated_at) changed');
      await docs.save(Doc(id: 1, title: 'full'));
      final Doc full = (await docs.findById(1))!;
      expect([full.title, full.qty, full.note, full.code, full.flag, full.seen], ['full', 0, null, null, null, null], reason: 'upsert writes every field of the model');
      expect((await docs.saveAll([Doc(id: 5, title: 'x')], strategy: FluentSaveStrategy.updateOnly)).skipped, 1);
      expect(await docs.update(Doc(id: 6, title: 'x')), 0);
      expect(await docs.findById(5), isNull);
      expect(await docs.findById(6), isNull);
      expect(await docs.update(Doc(id: 1, title: 'updated', qty: 3)), 1);
      expect((await docs.findById(1))!.title, 'updated');
      await finish();
    });

    test('G29: updateById / updateWhere change only the given fields (and updated_at) of the targeted live rows', () async {
      await docs.saveAll([
        Doc(id: 1, title: 'a', qty: 1, note: 'x'),
        Doc(id: 2, title: 'b', qty: 2, note: 'x'),
        Doc(id: 3, title: 'c', qty: 3, note: 'x'),
        Doc(id: 4, title: 'd', qty: 4, note: 'x', timeToLive: const Duration(minutes: 10)),
      ]);
      await docs.deleteById(3);
      db.clock.advance(const Duration(minutes: 20)); // 4 is expired
      final List<Map<String, Object?>> before = await rawRows('docs');
      expect(await docs.updateById(1, {'qty': FluentUpdate.increment(5), 'flag': FluentUpdate.toggle, 'seen': FluentUpdate.now}), 1);
      expect(await docs.updateWhere(FluentFilter.gt('qty', 0), {'note': 'changed'}), 2, reason: 'the live rows 1 and 2; not the trashed 3, not the expired 4');
      expect(await docs.updateById(3, {'note': 'no'}), 0, reason: 'a row in the trash counts as missing');
      expect(await docs.updateById(4, {'note': 'no'}), 0, reason: 'an expired row counts as missing');
      expect(await docs.updateById(4, {'note': 'yes'}, includeExpired: true), 1);
      final List<Map<String, Object?>> after = await rawRows('docs');
      Set<String> changed(int id) {
        final Map<String, Object?> b = before.firstWhere((r) => r['id'] == id);
        final Map<String, Object?> a = after.firstWhere((r) => r['id'] == id);
        return {for (final String k in a.keys) if (a[k] != b[k]) k};
      }

      expect(changed(1).difference({'_fs_metadata'}), {'qty', 'flag', 'seen', 'note', 'updated_at'});
      expect(changed(2), {'note', 'updated_at'});
      expect(changed(3), isEmpty, reason: 'the trashed row is byte-identical');
      expect(changed(4).difference({'_fs_metadata'}), {'note', 'updated_at'}, reason: 'the expiry stays as it was');
      expect((await docs.findById(1))!.qty, 6);
      expect((await docs.findById(1))!.flag, true);
      await expectLater(docs.updateById(1, {'id': 9}), throwsA(isA<FluentArgumentException>()), reason: 'a key column cannot be updated');
      await expectLater(docs.updateById(1, {'deleted_at': 5}), throwsA(isA<FluentArgumentException>()));
      await expectLater(docs.updateById(1, {'nope': 5}), throwsA(isA<FluentArgumentException>()));
      expect(await docs.updateById(null, {'qty': 1}), 0);
      expect(await docs.updateById(1, {}), 0);
      await finish();
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Every call x its parameters
  // ---------------------------------------------------------------------------------------------------------------
  group('Parameters: every call x depth 0..3, limit / offset / orderBy, policies, tags', () {
    setUp(() async {
      await docs.saveAll([for (int i = 1; i <= 12; i++) Doc(id: i, title: 't${(13 - i).toString().padLeft(2, '0')}', qty: i % 3)]);
    });

    test('G8: relations / maxDepth / policy do not change which rows a read returns', () async {
      const List<ExecutionPolicy> policies = [ExecutionPolicy(), ExecutionPolicy.fast, ExecutionPolicy.background, ExecutionPolicy.fresh, ExecutionPolicy(priority: 3, cancelIfDuplicate: true)];
      final List<int> ids = [for (int i = 1; i <= 12; i++) i];
      for (final FluentLoad load in FluentLoad.values) {
        for (int depth = 0; depth <= 3; depth++) {
          for (final ExecutionPolicy policy in policies) {
            final String r = '$load depth $depth $policy';
            expect((await docs.find(orderBy: 'id', relations: load, maxDepth: depth, policy: policy)).map((d) => d.primaryKeyValue), ids, reason: r);
            expect((await docs.findAll(orderBy: 'id', relations: load, maxDepth: depth, policy: policy)).length, 12, reason: r);
            if (policy == policies.first) expect((await docs.findById(4, relations: load, maxDepth: depth, policy: policy))?.primaryKeyValue, 4, reason: r);
            expect((await docs.findByIds([3, 2, 1], relations: load, maxDepth: depth, policy: policy)).map((d) => d.primaryKeyValue), [3, 2, 1], reason: r);
            expect((await docs.findFirst(orderBy: 'id', relations: load, maxDepth: depth, policy: policy))?.primaryKeyValue, 1, reason: r);
            expect((await docs.findPage(limit: 5, relations: load, maxDepth: depth, policy: policy)).items.length, 5, reason: r);
            expect(await docs.count(policy: policy), 12, reason: r);
            expect(await docs.exists(1, policy: policy), isTrue, reason: r);
            expect(await docs.existsWhere(FluentFilter.eq('id', 99), policy: policy), isFalse, reason: r);
            expect((await docs.findMaps(orderBy: 'id', policy: policy)).length, 12, reason: r);
            expect((await docs.pluck<int>('id', orderBy: 'id', policy: policy)), ids, reason: r);
            expect((await docs.watch(orderBy: 'id', relations: load, maxDepth: depth, policy: policy).first).length, 12, reason: r);
          }
        }
      }
      await finish();
    });

    test('G8: limit / offset / orderBy return exactly the slice of the full order', () async {
      final List<String> orders = ['id', 'id DESC', 'title', 'title DESC, id', 'qty, id DESC', 'qty DESC, title'];
      for (final String order in orders) {
        final List<Doc> full = await docs.find(orderBy: order);
        expect(full.length, 12);
        for (final (int? limit, int? offset) in [(null, null), (3, null), (5, 2), (100, 0), (0, 0), (2, 11), (3, 50)]) {
          final List<Doc> slice = await docs.find(orderBy: order, limit: limit, offset: offset);
          final List<Object?> expected = full.skip(offset ?? 0).take(limit ?? 1 << 30).map((d) => d.primaryKeyValue).toList();
          expect(slice.map((d) => d.primaryKeyValue).toList(), expected, reason: '$order limit $limit offset $offset');
          expect((await docs.findMaps(columns: ['id'], orderBy: order, limit: limit, offset: offset)).map((m) => m['id']).toList(), expected, reason: 'findMaps $order $limit $offset');
          expect((await docs.pluck<int>('id', orderBy: order, limit: limit, offset: offset)), expected, reason: 'pluck $order $limit $offset');
        }
        expect((await docs.findFirst(orderBy: order))?.primaryKeyValue, full.first.primaryKeyValue);
        expect((await docs.findAll(orderBy: order, limit: 4)).map((d) => d.primaryKeyValue), full.take(4).map((d) => d.primaryKeyValue));
      }
      await finish();
    });

    test('G8: the tag of a write reaches its change event with the right kind', () async {
      final List<FluentChangeEvent<Doc>> events = [];
      final StreamSubscription<FluentChangeEvent<Doc>> sub = FluentDb.onEvent<Doc>().listen(events.add);
      Future<void> step(String tag, Future<Object?> Function() call, FluentChangeKind kind) async {
        events.clear();
        await call();
        await db.settle();
        final Set<FluentChangeKind> kinds = events.where((e) => e.tag == tag).map((e) => e.kind).toSet();
        expect(kinds, contains(kind), reason: '$tag: ${events.map((e) => '${e.kind}/${e.tag}')}');
        expect(kinds.difference({kind, if (kind == FluentChangeKind.clear) FluentChangeKind.delete}), isEmpty, reason: '$tag: no other kind');
        expect(events.where((e) => e.tag != tag), isEmpty, reason: '$tag: no event without or with another tag');
      }

      await step('save', () => docs.save(Doc(id: 20, title: 'n'), tag: 'save'), FluentChangeKind.save);
      await step('saveAll', () => docs.saveAll([Doc(id: 21, title: 'n')], tag: 'saveAll'), FluentChangeKind.save);
      await step('update', () => docs.update(Doc(id: 20, title: 'm'), tag: 'update'), FluentChangeKind.update);
      await step('updateById', () => docs.updateById(20, {'qty': 1}, tag: 'updateById'), FluentChangeKind.update);
      await step('updateWhere', () => docs.updateWhere(FluentFilter.eq('id', 20), {'qty': 2}, tag: 'updateWhere'), FluentChangeKind.update);
      await step('delete', () => docs.delete(Doc(id: 20, title: 'm'), tag: 'delete'), FluentChangeKind.delete);
      await step('deleteById', () => docs.deleteById(21, tag: 'deleteById'), FluentChangeKind.delete);
      await step('restore', () => docs.trash.restoreById(20, tag: 'restore'), FluentChangeKind.restore);
      await step('deleteForever', () => docs.trash.deleteForeverById(21, tag: 'deleteForever'), FluentChangeKind.delete);
      await step('deleteWhere', () => docs.deleteWhere(FluentFilter.eq('id', 20), tag: 'deleteWhere'), FluentChangeKind.delete);
      await step('empty', () => docs.trash.empty(olderThan: Duration.zero, tag: 'empty'), FluentChangeKind.delete);
      await step('clearTable', () => docs.clearTable(tag: 'clearTable'), FluentChangeKind.clear);
      await sub.cancel();
      await finish();
    });
  });

  group('G26: hints raised by CRUD patterns carry a fix', () {
    test('G26: the N+1 lookup hint (lookupLoop) says how to fix it', () async {
      await docs.saveAll([for (int i = 1; i <= 3; i++) Doc(id: i, title: 't$i')]);
      for (int i = 0; i < 40; i++) {
        await docs.findById(1 + i % 3);
      }
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.lookupLoop), isNotEmpty, reason: 'the hint is published');
      expectIssuesHaveFixes(db.issues);
    });
  });

  group('G29: counts tell the truth', () {
    test('G29: updateAll with the same key twice reports the one row it updated', () async {
      await docs.save(Doc(id: 5, title: 'a'));
      expect(await docs.updateAll([Doc(id: 5, title: 'b'), Doc(id: 5, title: 'c')]), 1, reason: 'the row is written once (the last one wins) and counted once');
      expect((await docs.findById(5))!.title, 'c');
    });
  });
}
