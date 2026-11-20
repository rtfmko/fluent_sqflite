// Guarantee tests of relations (TEST_PLAN.md, T1): atomic relation writes under injected failures (G1), models
// after a rollback (G2), saves that never delete what they did not load (G3), relation reads that agree (G8),
// reversible soft delete (G9), watches that converge (G11), deletion only by explicit calls (G21) and exactly the
// stored fields (G29). Models: _graph_models.dart.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/faults.dart';
import '../../helpers/guarantees.dart';
import '_graph_models.dart';

const List<String> _tables = ['owners', 'persons', 'profiles', 'kids', 'tags', 'owners_tags', 'notes', 'groups', 'memberships'];

/// Every row of every graph table, sorted (a full picture of the stored state). [trashFlag]: soft-delete stamps
/// become `T` (a retry after a failure takes a new stamp).
Future<Map<String, List<String>>> dump(Database db, {bool trashFlag = false}) async => {
  for (final String t in _tables)
    t: [
      for (final Map<String, Object?> r in await db.rawQuery('SELECT * FROM "$t"'))
        {for (final MapEntry<String, Object?> e in r.entries) e.key: trashFlag && e.key == 'deleted_at' && e.value != null ? 'T' : e.value}.toString(),
    ]..sort(),
};

/// Ids of a seeded graph.
class Fx {
  late int ann, bob, g1, g2, o1, o2, k1, k2, k3, k4, p1, n1, n2, nAnn, m1;
}

/// Two owners: o1 (boss ann, profile p1, kids k1 n=2 / k2 n=7 / k3 n=9, tags a|x + b|x, notes n1 n2, group g1 via
/// membership m1) and o2 (boss bob, kid k4, tag a|y); a note on ann; tags a|x, a|y, b|x; groups g1, g2.
Future<Fx> seedGraph(Graph g) async {
  final Fx fx = Fx();
  final Person ann = Person(name: 'ann'), bob = Person(name: 'bob');
  await g.persons.saveAll([ann, bob]);
  final Group g1 = Group(title: 'g1'), g2 = Group(title: 'g2');
  await g.groups.saveAll([g1, g2]);
  await g.tags.saveAll([Tag(ns: 'a', label: 'x', title: 'ax'), Tag(ns: 'a', label: 'y', title: 'ay'), Tag(ns: 'b', label: 'x', title: 'bx')]);
  final List<Kid> kids = [Kid(text: 'k1', n: 2), Kid(text: 'k2', n: 7), Kid(text: 'k3', n: 9)];
  final List<Note> notes = [Note(text: 'n1'), Note(text: 'n2')];
  final Profile p1 = Profile(bio: 'p1');
  final Owner o1 = Owner(name: 'o1', boss: ann, profile: p1, kids: kids, tags: [Tag(ns: 'a', label: 'x', title: 'ax'), Tag(ns: 'b', label: 'x', title: 'bx')], notes: notes);
  final Kid k4 = Kid(text: 'k4', n: 5);
  final Owner o2 = Owner(name: 'o2', boss: bob, kids: [k4], tags: [Tag(ns: 'a', label: 'y', title: 'ay')]);
  await g.owners.saveAll([o1, o2]);
  final Note nAnn = Note(text: 'on ann', target: ann);
  await g.notes.save(nAnn);
  Membership? m1;
  await g.owners.attach(o1, 'groups', [g1], link: (_) => m1 = Membership(role: 'admin'));
  int id(FluentStorable m) => m.primaryKeyValue! as int;
  fx
    ..ann = id(ann)
    ..bob = id(bob)
    ..g1 = id(g1)
    ..g2 = id(g2)
    ..o1 = id(o1)
    ..o2 = id(o2)
    ..k1 = id(kids[0])
    ..k2 = id(kids[1])
    ..k3 = id(kids[2])
    ..k4 = id(k4)
    ..p1 = id(p1)
    ..n1 = id(notes[0])
    ..n2 = id(notes[1])
    ..nAnn = id(nAnn)
    ..m1 = id(m1!);
  return fx;
}

Future<List<Object?>> col(Database db, String sql) async => [for (final r in await db.rawQuery(sql)) r.values.first];

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  late FluentTestDb db;
  late Graph g;
  late Fx fx;
  Database raw() => g.owners.db;

  Future<void> open({Graph? graph}) async {
    g = graph ?? Graph();
    db = FluentTestDb();
    await db.open(g.all);
    fx = await seedGraph(g);
    await db.settle(); // start-up maintenance done before faults are injected
  }

  setUp(() async => faults = await FaultyDatabaseFactory.install());

  tearDown(() async {
    faults.heal();
    await FluentTestDb.closeCurrent();
    faults.uninstall();
  });

  Future<void> finish() async {
    await expectIntegrity(raw());
    expectIssuesHaveFixes(db.issues);
  }

  // -------------------------------------------------------------------------------------------------------------------
  group('G1: a failure at any write statement of a relation write leaves nothing behind', () {
    /// Runs [op] once without faults (the expected result), then again on fresh databases failing its 1st, 2nd, ...
    /// write (cycling through every FaultKind) until it no longer meets a fault. Each failed run: typed error, the
    /// stored state unchanged, integrity ok, and the same op run again afterwards gives the fault-free result.
    Future<void> matrix(String name, Future<void> Function() op, {Future<void> Function()? prepare}) async {
      await open();
      await prepare?.call();
      await op();
      final Map<String, List<String>> expected = await dump(raw(), trashFlag: true);
      int failures = 0;
      for (int n = 0; n < 80; n++) {
        await open();
        await prepare?.call();
        final Map<String, List<String>> before = await dump(raw());
        final int injected = faults.injected.length;
        final FaultKind kind = FaultKind.values[n % FaultKind.values.length];
        faults.failNth(n, where: (c) => c.isWrite && !c.matches('"deleted_at" < ?'), kind: kind);
        Object? error;
        try {
          await op().timeout(const Duration(seconds: 10));
        } catch (e) {
          error = e;
        }
        faults.heal();
        if (faults.injected.length == injected) {
          expect(error, isNull, reason: '$name: no fault, no error');
          expect(failures, greaterThan(0), reason: '$name: at least one write was failed');
          return;
        }
        failures++;
        expect(error, isNotNull, reason: '$name: write #$n failed (${kind.name}) but the call succeeded: ${faults.injected.last}');
        expectTypedError(error!, reason: '$name write #$n');
        expect(await dump(raw()), before, reason: 'G1: $name, write #$n (${faults.injected.last}) failed: nothing of it stays');
        await expectIntegrity(raw(), reason: '$name write #$n');
        await op(); // works again once the failure is gone
        expect(await dump(raw(), trashFlag: true), expected, reason: 'G1: $name after write #$n failed and was retried');
      }
      fail('$name: more than 80 writes');
    }

    test('G1: saving a new graph (reference, owned child, list, links, polymorphic notes)', () async {
      await matrix('create', () async {
        await g.owners.save(Owner(
          name: 'new',
          boss: Person(name: 'cid'),
          profile: Profile(bio: 'np'),
          kids: [Kid(text: 'a', n: 1), Kid(text: 'b', n: 6)],
          tags: [Tag(ns: 'a', label: 'x', title: 'ax'), Tag(ns: 'c', label: 'z', title: 'cz')],
          notes: [Note(text: 'nn')],
        ));
      });
      await finish();
    });

    test('G1: saving an edited graph (child removal = soft delete, link replacement, owned child replaced)', () async {
      await matrix('edit', () async {
        final Owner o = await g.owners.loadRelations((await g.owners.findById(fx.o1))!, names: ['kids']);
        o
          ..name = 'o1*'
          ..kids = [o.kids![1]..n = 1, Kid(text: 'new', n: 3)]
          ..tags = [Tag(ns: 'a', label: 'y', title: 'ay'), Tag(ns: 'c', label: 'z', title: 'cz')]
          ..profile = Profile(bio: 'p*')
          ..notes = [o.notes!.first..text = 'n1*']
          ..memberships = [];
        await g.owners.save(o);
      });
      await finish();
    });

    test('G1: soft delete with cascade, restore with cascade', () async {
      await matrix('soft delete', () => g.owners.delete(Owner(id: fx.o1, name: 'o1')));
      await matrix('restore', () => g.owners.trash.restore(Owner(id: fx.o1, name: 'o1')), prepare: () async {
        await g.kids.delete(Kid(id: fx.k3, text: 'k3')); // trashed on its own: stays in the trash
        await g.owners.delete(Owner(id: fx.o1, name: 'o1'));
      });
      await finish();
    });

    test('G1: permanent deletes (cascade, polymorphic clean-up, SET NULL, links)', () async {
      await matrix('owner forever', () => g.owners.trash.deleteForever(Owner(id: fx.o1, name: 'o1')));
      await matrix('person', () => g.persons.delete(Person(id: fx.ann, name: 'ann')));
      await matrix('tag forever', () => g.tags.trash.deleteForever(Tag(ns: 'a', label: 'x')));
      await matrix('group', () => g.groups.delete(Group(id: fx.g1, title: 'g1')));
      await finish();
    });

    test('G1: attach and detach through the link model', () async {
      await matrix('attach', () => g.owners.attach(Owner(id: fx.o1, name: 'o1'), 'groups', [Group(id: fx.g2, title: 'g2'), Group(title: 'g3')], link: (_) => Membership(role: 'm')));
      await matrix('detach', () => g.owners.detach(Owner(id: fx.o1, name: 'o1'), 'groups', [Group(id: fx.g1, title: 'g1')]));
      await matrix('attach tags', () => g.owners.attach(Owner(id: fx.o2, name: 'o2'), 'tags', [Tag(ns: 'b', label: 'x', title: 'bx'), Tag(ns: 'd', label: 'q', title: 'dq')]));
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G2: after a failure or a rollback the models are as before', () {
    test('G2: a failed graph save injects no keys; the same instances save once afterwards', () async {
      await open();
      final List<Kid> kids = [Kid(text: 'a'), Kid(text: 'b')];
      final Profile profile = Profile(bio: 'p');
      final Owner o = Owner(name: 'x', profile: profile, kids: kids, tags: [Tag(ns: 'z', label: 'z')]);
      faults.failWhere((c) => c.matches('INSERT') && c.matches('owners_tags'), times: 1);
      await expectLater(g.owners.save(o), throwsA(isA<FluentException>()));
      expect([o.primaryKeyValue, profile.primaryKeyValue, for (final Kid k in kids) k.primaryKeyValue], everyElement(isNull), reason: 'G2: keys of a failed save');
      await g.owners.save(o);
      expect(await g.owners.count(), 3, reason: 'one new owner, not two');
      expect(await col(raw(), 'SELECT COUNT(*) FROM kids WHERE owner_id = ${o.primaryKeyValue}'), [2]);
      expect(await col(raw(), 'SELECT COUNT(*) FROM profiles WHERE owner_id = ${o.primaryKeyValue}'), [1]);
      await finish();
    });

    test('G2: a FluentDb.transaction that rolls back restores keys, deletedAt and relation lists', () async {
      await open();
      final Owner o1 = (await g.owners.findById(fx.o1))!;
      final List<Tag> tagsBefore = List.of(o1.tags!);
      final Kid kid = Kid(text: 'in txn');
      final Owner fresh = Owner(name: 'fresh', kids: [kid]);
      final Owner o2 = Owner(id: fx.o2, name: 'o2');
      final Map<String, List<String>> before = await dump(raw());
      await expectLater(
        FluentDb.transaction(() async {
          await g.owners.save(fresh);
          await g.owners.delete(o2);
          o1.tags = [];
          await g.owners.save(o1);
          throw StateError('rollback');
        }),
        throwsA(anything),
      );
      expect(await dump(raw()), before, reason: 'G1: nothing of the transaction stays');
      expect(fresh.primaryKeyValue, isNull, reason: 'G2: a generated key is taken back');
      expect(kid.primaryKeyValue, isNull, reason: 'G2: a child key is taken back');
      expect(o2.deletedAt, isNull, reason: 'G2: deletedAt is as before');
      expect(o1.tags, isEmpty, reason: 'the app changed the list itself');
      o1.tags = tagsBefore;
      await g.owners.save(o1);
      await g.owners.save(fresh);
      expect(await g.owners.count(), 3);
      await finish();
    });

    test('G2: a savepoint that rolls back drops its relation writes and keys, the outer transaction commits', () async {
      await open();
      final Kid inner = Kid(text: 'inner');
      final Owner o = Owner(name: 'inner owner', kids: [inner]);
      final Kid outer = Kid(text: 'outer');
      await FluentDb.transaction(() async {
        await g.owners.save(Owner(id: fx.o2, name: 'o2', kids: [outer]));
        await expectLater(
          FluentDb.transaction(() async {
            await g.owners.save(o);
            await g.owners.delete(Owner(id: fx.o1, name: 'o1'));
            throw StateError('inner');
          }),
          throwsA(anything),
        );
      });
      expect(o.primaryKeyValue, isNull, reason: 'G2');
      expect(inner.primaryKeyValue, isNull, reason: 'G2');
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o2} AND deleted_at IS NULL ORDER BY id'), ['outer'], reason: 'the outer save replaced k4 by "outer"; k4 is in the trash');
      expect(await col(raw(), 'SELECT deleted_at FROM owners WHERE id = ${fx.o1}'), [null], reason: 'G1: the inner delete is rolled back');
      expect(await g.kids.trash.count(), 1, reason: 'k4 removed from the outer list');
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G3: a save never deletes what it did not load', () {
    test('G3: relations: none, lazy lists and a depth cut remove nothing', () async {
      await open();
      final Map<String, List<String>> before = await dump(raw());
      await g.owners.save((await g.owners.findById(fx.o1, relations: FluentLoad.none))!);
      await g.owners.save((await g.owners.findById(fx.o1))!); // kids lazy, memberships' groups cut by maxDepth 1
      for (final FluentLoad mode in FluentLoad.values) {
        for (int depth = 1; depth <= 3; depth++) {
          await g.owners.saveAll(await g.owners.findAll(relations: mode, maxDepth: depth));
        }
      }
      expect(await dump(raw()), before, reason: 'G3 / G31: saving what was read changes nothing');

      final Owner none = (await g.owners.findById(fx.o1, relations: FluentLoad.none))!;
      none
        ..kids = [Kid(text: 'added')]
        ..tags = [Tag(ns: 'a', label: 'y', title: 'ay')]
        ..notes = [Note(text: 'added')]
        ..memberships = [];
      await g.owners.save(none);
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k1', 'k2', 'k3', 'added'], reason: 'G3: merged, nothing removed');
      expect(await col(raw(), "SELECT tag_ns || tag_label FROM owners_tags WHERE owner_id = ${fx.o1} ORDER BY 1"), ['ax', 'ay', 'bx']);
      expect(await col(raw(), "SELECT COUNT(*) FROM notes WHERE target_type = 'owners' AND target_id = ${fx.o1}"), [3]);
      expect(await g.memberships.count(), 1, reason: 'G3: an empty list that was never read removes nothing');
      await finish();
    });

    test('G3: a relation whose load failed stays unloaded and a save of the model removes nothing', () async {
      await open();
      faults.failWhere((c) => c.isRead && c.matches('FROM "kids"'), times: 1);
      final Owner o = (await g.owners.findById(fx.o1, relations: FluentLoad.all))!;
      faults.heal();
      expect(o.isRelationLoaded('kids'), isFalse, reason: 'a failed load is left unloaded');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isNotEmpty, reason: 'G25: the failed load is reported');
      o.kids = [Kid(text: 'new')];
      await g.owners.save(o);
      expect(await g.owners.countRelated(o, 'kids'), 4, reason: 'G3: k1..k3 kept, the new kid added');
      await finish();
    });

    test('G3: trashed and expired children, trashed link targets and filtered / limited views are not "missing"', () async {
      await open();
      await g.kids.delete(Kid(id: fx.k1, text: 'k1')); // in the trash
      final Kid expiring = Kid(text: 'ttl', n: 8)..timeToLive = const Duration(hours: 1);
      final Owner o0 = (await g.owners.findById(fx.o1, relations: FluentLoad.none))!..kids = [expiring];
      await g.owners.save(o0);
      db.clock.advance(const Duration(hours: 2)); // expiring is now hidden
      await g.tags.delete(Tag(ns: 'b', label: 'x')); // a linked tag in the trash
      final Map<String, List<String>> before = await dump(raw());

      // The full list shows k2 + k3 only; the save keeps k1 (trash), "ttl" (expired) and the link to b|x (trash).
      final Owner o = await g.owners.loadRelations((await g.owners.findById(fx.o1))!, names: ['kids']);
      expect([for (final Kid k in o.kids!) k.text], ['k2', 'k3'], reason: 'G8');
      expect([for (final Tag t in o.tags!) t.title], ['ax'], reason: 'G8: trashed tag hidden');
      await g.owners.save(o);
      expect(await dump(raw()), before, reason: 'G3: hidden rows and links survive a save of the visible list');

      // Views: a limit removes nothing, a where removes only what it shows, includeDeleted does not restore.
      final Owner top = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['topKids']);
      top.topKids = [];
      await g.owners.save(top);
      expect(await dump(raw()), before, reason: 'G3: a limited view removes nothing');

      final Owner all = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['allKids']);
      expect([for (final Kid k in all.allKids!) k.text], ['k1', 'k2', 'k3'], reason: 'G8: includeDeleted shows the trash (not expired rows)');
      for (final Kid k in all.allKids!) {
        k.n = 0;
      }
      await g.owners.save(all);
      expect(await col(raw(), 'SELECT deleted_at IS NOT NULL FROM kids WHERE id = ${fx.k1}'), [1], reason: 'G3: a child read from the trash is not restored by the parent');
      expect(await col(raw(), 'SELECT n FROM kids WHERE id = ${fx.k1}'), [2], reason: 'and not written');

      final Owner big = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['bigKids']);
      expect(big.bigKids, isEmpty, reason: 'k2 / k3 now have n = 0');
      await g.owners.updateById(fx.o1, {'name': 'o1'}); // nothing
      await g.kids.updateById(fx.k3, {'n': 9});
      final Owner big2 = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['bigKids']);
      big2.bigKids = [];
      await g.owners.save(big2);
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k2', 'ttl'], reason: 'G3: only k3 (shown by where n >= 5) is removed; k2 (n = 0) and the expired row stay');
      await finish();
    });

    test('G3: a child added to one list is not removed by another loaded list over the same column (FluentLoad.all)', () async {
      await open();
      final Owner o = (await g.owners.findById(fx.o1, relations: FluentLoad.all))!;
      expect([for (final Kid k in o.allKids!) k.text], ['k1', 'k2', 'k3']);
      final Kid added = Kid(text: 'added', n: 6);
      o.kids = [...o.kids!, added];
      await g.owners.save(o);
      expect(await col(raw(), 'SELECT deleted_at FROM kids WHERE id = ${added.primaryKeyValue}'), [null], reason: 'G3: the new kid was in no list the owner was read with');
      expect(await col(raw(), 'SELECT COUNT(*) FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL'), [4]);
      await finish();
    });

    test('G3: a model rebuilt with copyWith from a limited / filtered / includeDeleted view removes only what the view showed', () async {
      await open();
      await g.kids.delete(Kid(id: fx.k1, text: 'k1')); // in the trash: only allKids shows it
      final Map<String, List<String>> before = await dump(raw());

      // limit: the rebuilt owner carries the same (edited) list instance; a limit removes nothing.
      final Owner top = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['topKids']);
      top.topKids!.clear();
      await g.owners.save(top.copyWith(name: 'o1'));
      // includeDeleted: the trashed kid is neither restored nor written, nothing is removed.
      final Owner all = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['allKids']);
      expect([for (final Kid k in all.allKids!) k.text], ['k1', 'k2', 'k3']);
      await g.owners.save(all.copyWith(name: 'o1'));
      expect(await dump(raw()), before, reason: 'G3: rebuilt from limited / includeDeleted views, nothing changed');

      // where (n >= 5 shows k2, k3): dropping k3 from the read list removes k3 only.
      final Owner big = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['bigKids']);
      big.bigKids!.removeWhere((k) => k.text == 'k3');
      await g.owners.save(big.copyWith(name: 'renamed'));
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k2'], reason: 'G3: only k3 (shown and dropped) is removed');
      expect(await col(raw(), 'SELECT deleted_at IS NOT NULL FROM kids WHERE id = ${fx.k1}'), [1], reason: 'k1 stays in the trash');
      expect(await col(raw(), 'SELECT name FROM owners WHERE id = ${fx.o1}'), ['renamed']);
      await finish();
    });

    for (final bool constDefaults in [false, true]) {
      final String defaults = constDefaults ? 'const []' : '[]';
      test('G3: a model rebuilt with copyWith from a read without its lists (none, lazy, depth cut; defaults $defaults) removes nothing', () async {
        await open(graph: Graph(owners: DenseOwnerProvider(constDefaults: constDefaults)));
        final Map<String, List<String>> before = await dump(raw());
        final List<Owner> reads = [
          (await g.owners.findById(fx.o1, relations: FluentLoad.none))!,
          (await g.owners.findById(fx.o1))!, // kids / topKids / bigKids / allKids are lazy
          ...await g.owners.findAll(relations: FluentLoad.none),
          // Owners loaded at level 1 of a membership: their lists are cut by maxDepth.
          for (final Membership m in await g.memberships.findAll(relations: FluentLoad.all)) m.owner!,
        ];
        for (final Owner o in reads) {
          expect(o.kids, isEmpty, reason: 'the default of a list that was not loaded');
          await g.owners.save(o.copyWith(name: o.name));
          await g.owners.saveAll([o.copyWith()]);
        }
        expect(await dump(raw()), before, reason: 'G3: rebuilt models with empty, unloaded lists remove nothing');
        // A rebuilt model whose list never got load info (a shared const []) is a model the app built: kept + reported.
        final List<FluentIssue> kept = [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.relationListKept) i];
        expect(kept.isNotEmpty, constDefaults, reason: 'reported only when the list carried no load info');
        for (final FluentIssue i in kept) {
          expect(i.fix, contains('FluentRelationSyncMode.replace'));
        }

        if (!constDefaults) {
          // New children put into the read (unloaded) list itself are added, nothing is removed.
          final Owner none = (await g.owners.findById(fx.o1, relations: FluentLoad.none))!;
          none.kids!.add(Kid(text: 'added'));
          none.tags!.add(Tag(ns: 'a', label: 'y', title: 'ay'));
          await g.owners.save(none.copyWith(name: 'o1'));
          expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k1', 'k2', 'k3', 'added']);
          expect(await col(raw(), "SELECT tag_ns || tag_label FROM owners_tags WHERE owner_id = ${fx.o1} ORDER BY 1"), ['ax', 'ay', 'bx']);
        }
        await finish();
      });
    }

    test('G3: an unloaded list stays unloaded under relationSync: replace; a loaded one rebuilt still replaces', () async {
      await open(graph: Graph(owners: DenseOwnerProvider()));
      final Map<String, List<String>> before = await dump(raw());
      final Owner none = (await g.owners.findById(fx.o1, relations: FluentLoad.none))!;
      await g.owners.save(none.copyWith(), relationSync: FluentRelationSyncMode.replace);
      expect(await dump(raw()), before, reason: 'G3: a list the read did not load is never the full state');

      final Owner full = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['kids', 'tags']);
      full.kids!.removeWhere((k) => k.text == 'k2');
      full.tags!.clear();
      await g.owners.save(full.copyWith(name: 'o1'));
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k1', 'k3'], reason: 'the loaded list is the full state');
      expect(await col(raw(), 'SELECT COUNT(*) FROM owners_tags WHERE owner_id = ${fx.o1}'), [0]);
      await finish();
    });

    test('G3: a list read for another owner or relation only adds; a copied list ([...list]) is the app\'s own list', () async {
      await open();
      // o2's loaded kids given to o1: k4 moves to o1, o1's kids stay.
      final Owner o2 = await g.owners.loadRelations((await g.owners.findById(fx.o2, relations: FluentLoad.none))!, names: ['kids']);
      final Owner o1 = (await g.owners.findById(fx.o1, relations: FluentLoad.none))!;
      await g.owners.save(o1.copyWith(kids: o2.kids));
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k1', 'k2', 'k3', 'k4'], reason: 'G3: a list read for o2 removes nothing of o1');

      // The limited view given as the full list: nothing outside the view is removed.
      final Owner top = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['topKids']);
      await g.owners.save(top.copyWith(kids: top.topKids));
      expect(await col(raw(), 'SELECT COUNT(*) FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL'), [4], reason: 'G3: a list read for topKids removes nothing from kids');

      // A copy of a limited view under the limited relation: the limit still removes nothing.
      final Map<String, List<String>> before = await dump(raw());
      await g.owners.save(top.copyWith(topKids: [...top.topKids!]..removeAt(0)));
      expect(await dump(raw()), before, reason: 'G3: a relation with a limit removes nothing, whatever the list');

      // A copy of a full list is the app's own list (non-empty): it replaces the owned set.
      final Owner full = await g.owners.loadRelations((await g.owners.findById(fx.o1, relations: FluentLoad.none))!, names: ['kids']);
      await g.owners.save(full.copyWith(kids: [...full.kids!.where((k) => k.text != 'k4')]));
      expect(await col(raw(), 'SELECT text FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL ORDER BY id'), ['k1', 'k2', 'k3'], reason: 'an app-built list with items is the full state');
      await finish();
    });

    test('G3: an empty list on a model the app built removes nothing (reported with a fix); relationSync: replace clears', () async {
      await open();
      final Map<String, List<String>> before = await dump(raw());
      await g.owners.save(Owner(id: fx.o1, name: 'o1', kids: [], tags: [], notes: [], memberships: []));
      expect(await dump(raw()), before, reason: 'G3: empty lists of a built model are not "remove all"');
      final List<FluentIssue> kept = [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.relationListKept) i];
      expect({for (final FluentIssue i in kept) i.key.split(':').last}, {'kids', 'tags', 'notes', 'memberships'});
      for (final FluentIssue i in kept) {
        expect(i.type, FluentIssueType.warning);
        expect(i.fix, contains('relationSync: FluentRelationSyncMode.replace'));
      }
      // A built model with nothing stored for it: no report.
      final Owner fresh = Owner(name: 'fresh', kids: [], tags: []);
      final int reported = db.issues.length;
      await g.owners.save(fresh);
      await g.owners.save(Owner(id: fresh.id, name: 'fresh', kids: [], tags: []));
      expect(db.issues.length, reported);

      await g.owners.save(Owner(id: fx.o1, name: 'o1', kids: [], tags: [], notes: [], memberships: []), relationSync: FluentRelationSyncMode.replace);
      expect(await col(raw(), 'SELECT COUNT(*) FROM kids WHERE owner_id = ${fx.o1} AND deleted_at IS NULL'), [0], reason: 'replace clears on purpose');
      expect(await col(raw(), 'SELECT COUNT(*) FROM owners_tags WHERE owner_id = ${fx.o1}'), [0]);
      expect(await col(raw(), "SELECT COUNT(*) FROM notes WHERE target_type = 'owners' AND target_id = ${fx.o1}"), [0]);
      expect(await g.memberships.count(), 0);
      await finish();
    });

    test('G3: insertOnly of an existing owner writes no relation', () async {
      await open();
      final Map<String, List<String>> before = await dump(raw());
      await g.owners.save(Owner(id: fx.o1, name: 'other', kids: [], tags: [], notes: [], memberships: []), strategy: FluentSaveStrategy.insertOnly);
      expect(await dump(raw()), before);
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G9: soft delete is reversible', () {
    test('G9: delete → restore of an owner gives back identical rows, cascaded children included', () async {
      await open();
      await g.kids.delete(Kid(id: fx.k3, text: 'k3')); // trashed on its own before: must stay trashed with its stamp
      final Map<String, List<String>> before = await dump(raw());
      expect(await g.owners.delete(Owner(id: fx.o1, name: 'o1')), 1);
      expect(await col(raw(), 'SELECT COUNT(DISTINCT deleted_at) FROM kids WHERE owner_id = ${fx.o1}'), [2], reason: 'k1 / k2 share the owner stamp, k3 keeps its own');
      expect(await g.memberships.count(), 0, reason: 'the membership went with its owner');
      expect(await g.kids.trash.restore(Kid(id: fx.k1, text: 'k1')), 0, reason: 'a child of an owner in the trash stays there');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.trashStays), isNotEmpty);
      expect(await g.owners.trash.restore(Owner(id: fx.o1, name: 'o1')), 1);
      expect(await dump(raw()), before, reason: 'G9: identical rows after delete → restore');
      await finish();
    });

    test('G9 / G21: trash.empty removes only rows past the retention, with their owned rows', () async {
      await open();
      await g.owners.delete(Owner(id: fx.o1, name: 'o1'));
      db.clock.advance(const Duration(days: 3));
      await g.owners.delete(Owner(id: fx.o2, name: 'o2'));
      final Map<String, List<String>> before = await dump(raw());
      expect(await g.owners.trash.empty(olderThan: const Duration(days: 2)), 1);
      final Map<String, List<String>> after = await dump(raw());
      expect(await col(raw(), 'SELECT id FROM owners'), [fx.o2]);
      expect(await col(raw(), 'SELECT id FROM kids ORDER BY id'), [fx.k4], reason: 'o1 kids purged with it');
      expect(await col(raw(), 'SELECT COUNT(*) FROM profiles'), [0]);
      expect(await col(raw(), 'SELECT id FROM notes'), [fx.nAnn], reason: 'notes owned via the polymorphic list go with o1; the note on ann stays');
      expect(after['persons'], before['persons']);
      expect(after['tags'], before['tags']);
      expect(after['groups'], before['groups']);
      expect(await col(raw(), 'SELECT owner_id FROM owners_tags'), [fx.o2]);
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G21: rows disappear only by explicit calls and their documented rules', () {
    test('G21: deleting forever an owner removes exactly its owned rows and links', () async {
      await open();
      await g.kids.delete(Kid(id: fx.k2, text: 'k2'));
      final Map<String, List<String>> before = await dump(raw());
      await g.owners.trash.deleteForever(Owner(id: fx.o1, name: 'o1'));
      final Map<String, List<String>> after = await dump(raw());
      expect(await col(raw(), 'SELECT id FROM owners'), [fx.o2]);
      expect(await col(raw(), 'SELECT id FROM kids'), [fx.k4], reason: 'live and trashed kids of o1 gone');
      expect(await col(raw(), 'SELECT COUNT(*) FROM profiles'), [0]);
      expect(await col(raw(), 'SELECT id FROM notes'), [fx.nAnn]);
      expect(await col(raw(), 'SELECT COUNT(*) FROM memberships'), [0]);
      expect(await col(raw(), 'SELECT owner_id FROM owners_tags'), [fx.o2]);
      for (final String t in ['persons', 'tags', 'groups']) {
        expect(after[t], before[t], reason: 'G21: $t untouched');
      }
      await finish();
    });

    test('G21: deleting a referenced model clears references, never deletes the referencing rows', () async {
      await open();
      final Map<String, List<String>> before = await dump(raw());
      await g.persons.delete(Person(id: fx.ann, name: 'ann'));
      expect(await col(raw(), 'SELECT boss_id FROM owners WHERE id = ${fx.o1}'), [null], reason: 'SET NULL');
      expect(await g.owners.count(), 2);
      expect((await raw().rawQuery('SELECT target_type, target_id FROM notes WHERE id = ${fx.nAnn}')).single.values, [null, null], reason: 'polymorphic reference cleared');
      await g.groups.delete(Group(id: fx.g1, title: 'g1'));
      expect(await col(raw(), 'SELECT group_id FROM memberships'), [null]);
      await g.tags.trash.deleteForever(Tag(ns: 'a', label: 'x'));
      final Map<String, List<String>> after = await dump(raw());
      expect(after['owners_tags']!.length, before['owners_tags']!.length - 1, reason: 'only the link to a|x');
      expect(after['kids'], before['kids']);
      expect(after['profiles'], before['profiles']);
      expect(after['notes']!.length, before['notes']!.length);
      expect(after['memberships']!.length, before['memberships']!.length);
      await finish();
    });

    test('G21: cleanOrphans on a consistent graph removes nothing; detach of a group keeps the group', () async {
      await open();
      await g.owners.delete(Owner(id: fx.o2, name: 'o2'));
      final Map<String, List<String>> before = await dump(raw());
      await FluentDb.cleanOrphans();
      expect(await dump(raw()), before, reason: 'G21: nothing dangling, nothing removed');
      await g.owners.detach(Owner(id: fx.o1, name: 'o1'), 'groups', [Group(id: fx.g1, title: 'g1')]);
      await g.owners.detach(Owner(id: fx.o1, name: 'o1'), 'tags', [Tag(ns: 'a', label: 'x')]);
      expect(await g.groups.count(), 2);
      expect(await g.tags.count(), 3);
      expect(await g.memberships.trash.count(), 1, reason: 'a soft-deletable link goes to the trash');
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G8: relation reads agree on visibility', () {
    test('G8: an owner in the trash shows the children deleted with it; live reads, counts and filters hide them', () async {
      await open();
      await g.kids.delete(Kid(id: fx.k3, text: 'k3'));
      await g.owners.delete(Owner(id: fx.o1, name: 'o1'));
      final Owner trashed = (await g.owners.trash.find(relations: FluentLoad.all)).single;
      expect([for (final Kid k in trashed.kids!) k.text], ['k1', 'k2'], reason: 'deleted together with it (not k3)');
      expect(await g.owners.count(where: FluentFilter.related<Kid>('kids')), 1, reason: 'only o2 has live kids');
      expect(await g.kids.count(), 1);
      expect(await g.kids.withTrash.count(), 4);
      expect([for (final Owner k in await g.kids.findParents<Owner>(Kid(id: fx.k4, text: ''), via: 'kids', relations: FluentLoad.none)) k.id], [fx.o2]);
      expect(await g.kids.findParents<Owner>(Kid(id: fx.k1, text: ''), via: 'kids'), isEmpty, reason: 'its owner is in the trash');
      expect([for (final Owner o in await g.tags.findParents<Owner>(Tag(ns: 'a', label: 'x'), relations: FluentLoad.none)) o.id], isEmpty, reason: 'o1 (its only owner) is in the trash');
      expect([for (final Owner o in await g.owners.withTrash.find(where: FluentFilter.related<Tag>('tags', FluentFilter.eq('ns', 'a')), relations: FluentLoad.none, orderBy: 'id')) o.id], [fx.o1, fx.o2]);
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G11: watches converge after relation writes', () {
    test('G11: owner / kid / trash watches equal a fresh query after cascades, links and SET NULL', () async {
      await open();
      final List<List<Owner>> owners = [];
      final List<List<Kid>> kids = [];
      final List<List<Owner>> trash = [];
      final List<StreamSubscription<Object?>> subs = [
        g.owners.watch(orderBy: 'id').listen(owners.add),
        g.kids.watch(orderBy: 'id').listen(kids.add),
        g.owners.trash.watch(orderBy: 'id', relations: FluentLoad.none).listen(trash.add),
      ];
      String ownersText(List<Owner> l) => [for (final Owner o in l) '${o.id}:${o.name}:${o.boss?.id}:${o.tags!.map((t) => t.title)}:${o.groups!.map((x) => x.id)}:${o.notes!.length}'].join(' ');
      Future<void> converged(String after) async {
        await db.settle();
        expect(ownersText(owners.last), ownersText(await g.owners.find(orderBy: 'id')), reason: 'G11 owners after $after');
        expect([for (final Kid k in kids.last) k.id], [for (final Kid k in await g.kids.find(orderBy: 'id')) k.id], reason: 'G11 kids after $after');
        expect([for (final Owner o in trash.last) o.id], [for (final Owner o in await g.owners.trash.find(orderBy: 'id', relations: FluentLoad.none)) o.id], reason: 'G11 trash after $after');
      }

      await converged('start');
      await g.tags.delete(Tag(ns: 'b', label: 'x'));
      await converged('a linked tag went to the trash');
      await g.owners.detach(Owner(id: fx.o1, name: 'o1'), 'groups', [Group(id: fx.g1, title: 'g1')]);
      await converged('detach');
      await g.persons.delete(Person(id: fx.ann, name: 'ann'));
      await converged('SET NULL of a boss');
      await g.owners.delete(Owner(id: fx.o1, name: 'o1'));
      await converged('soft delete with cascade');
      await g.owners.trash.restore(Owner(id: fx.o1, name: 'o1'));
      await converged('restore');
      await g.owners.trash.deleteForever(Owner(id: fx.o2, name: 'o2'));
      await converged('FK cascade of a permanent delete');
      await g.notes.save(Note(text: 'late', target: Owner(id: fx.o1, name: 'o1')));
      await converged('a note saved through its own table');

      await subs.first.cancel();
      final int seen = owners.length;
      await g.owners.save(Owner(name: 'after cancel'));
      await db.settle();
      expect(owners.length, seen, reason: 'G11: a cancelled watch emits nothing');
      for (final StreamSubscription<Object?> s in subs.skip(1)) {
        await s.cancel();
      }
      await finish();
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  group('G29: models carry exactly their fields', () {
    test('G29: relation rows reach fromCacheJson without internal columns; loaded models equal what was stored', () async {
      final _CapturingKids kids = _CapturingKids();
      await open(graph: Graph(kids: kids));
      final Owner o = await g.owners.loadRelations((await g.owners.findById(fx.o1))!, names: ['kids', 'allKids']);
      await g.kids.find();
      await g.owners.findRelated<Kid>(o, 'kids');
      expect(kids.seen, isNotEmpty);
      for (final Map<String, dynamic> json in kids.seen) {
        final List<String> internal = [for (final String k in json.keys) if (k.startsWith('_fs') || k.startsWith('_unloaded') || k == 'sync_version') k];
        expect(internal, isEmpty, reason: 'G29: internal columns in $json');
      }
      expect([for (final Kid k in o.kids!) (k.id, k.text, k.n)], [(fx.k1, 'k1', 2), (fx.k2, 'k2', 7), (fx.k3, 'k3', 9)]);
      expect(o.tags!.map((t) => (t.ns, t.label, t.title)), [('a', 'x', 'ax'), ('b', 'x', 'bx')]);
      expect((o.profile!.id, o.profile!.bio), (fx.p1, 'p1'));
      expect((o.boss!.id, o.boss!.name), (fx.ann, 'ann'));
      expect([for (final Membership m in o.memberships!) (m.id, m.role)], [(fx.m1, 'admin')]);
      final List<Map<String, dynamic>> maps = await g.owners.findMaps(where: FluentFilter.eq('id', fx.o1));
      expect(maps.single.keys.where((k) => k.startsWith('_fs') || k == 'expiry_date'), isEmpty, reason: 'G29: findMaps without internal columns');
      await finish();
    });

    test(
      'G29: the expiry column does not reach fromCacheJson (direct reads and relation loads)',
      () async {
        final _CapturingKids kids = _CapturingKids();
        await open(graph: Graph(kids: kids));
        await g.kids.find();
        await g.owners.loadRelations((await g.owners.findById(fx.o1))!, names: ['kids']);
        for (final Map<String, dynamic> json in kids.seen) {
          expect(json.containsKey('expiry_date'), isFalse, reason: 'G29: $json');
        }
        await finish();
      },
    );
  });
}

class _CapturingKids extends KidProvider {
  final List<Map<String, dynamic>> seen = [];

  @override
  Kid fromCacheJson(Map<String, dynamic> json) {
    seen.add(Map.of(json));
    return super.fromCacheJson(json);
  }
}
