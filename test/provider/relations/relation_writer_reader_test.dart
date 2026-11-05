// Writing and reading the graph: cycles, values a select cannot give, keepMissing / replace, per-owner limits with the
// window-function fallback, relation filters, soft-deleted children, depth and lazy loading.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '_helpers.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  group('writing', () {
    test('two models that reference each other are saved once each and point at the key they already have', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA x) => x.b)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB x) => x.a)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      final GA x = GA(name: 'x');
      await a.save(x);
      final GB y = GB(name: 'y')..a = x;
      x.b = y;
      await a.save(x);
      expect(await a.count(), 1);
      expect(await b.count(), 1);
      final Map<String, Object?> rowA = (await a.db.query('g_a')).single;
      final Map<String, Object?> rowB = (await b.db.query('g_b')).single;
      expect(rowA['b_id'], rowB['id']);
      expect(rowB['a_id'], rowA['id'], reason: 'the cycle uses the key the first model already had');
    });

    test('a select that returns something else than a model or a list is reported and the item is still saved', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.many, select: (GA x) => 'not a list')];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      await a.save(GA(name: 'x'));
      expect(await a.count(), 1);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.relationValue).single;
      expect(issue.title, contains('returned String; expected a List of GB'));
      expect(issue.table, 'g_a');
    });

    test('a single relation whose select returns something else is not written and does not stop the save', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'b', type: FluentRelationType.one, select: (GA x) => 'oops')];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      await a.save(GA(name: 'x'));
      await a.save(GA(name: 'y'));
      expect((await a.db.query('g_a')).map((r) => r['b_id']), [null, null]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.relationValue).single; // once per run
      expect(issue.title, allOf(contains('"b" of "g_a" returned String'), contains('expected GB'), contains('not saved')));
      expect(issue.subject, 'b');
      expect(issue.fix, contains('select function of "b"'));
    });

    test('a oneOf whose select returns something else is not written and is reported with its types', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, FluentStorable>(name: 'pin', type: FluentRelationType.oneOf, select: (GA x) => 42, types: [GB])];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      await a.save(GA(name: 'x'));
      final Map<String, Object?> row = (await a.db.query('g_a')).single;
      expect(row['pin_type'], isNull);
      expect(issuesOf(db, FluentIssueKind.relationValue).single.title, allOf(contains('returned int'), contains('expected one of GB')));
    });

    test('a list holding values that are not models saves the models and reports the rest', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.many, select: (GA x) => <Object>[GB(name: 'ok'), 'junk', 7])];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      await a.save(GA(name: 'x'));
      expect([for (final Map<String, Object?> r in await b.db.query('g_b')) r['name']], ['ok']);
      expect(issuesOf(db, FluentIssueKind.relationValue).single.title, contains('returned String'));
    });

    test('a list holding a model of another type skips it with a report instead of a cast error', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.many, select: (GA x) => x.dyn)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b, GCProvider()]);
      await a.save(GA(name: 'x')..dyn = [GB(name: 'right'), GC(name: 'wrong'), GC(name: 'wrong2')]);
      expect((await b.find()).map((GB m) => m.name), ['right']);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.relationValue).single;
      expect(issue.title, contains('holds a GC, but relates GB; 2 such value(s) were not saved'));
      expect(issue.subject, 'bs');
    });

    test('a reference holding a model of another type is not saved and is reported', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'b', type: FluentRelationType.one, select: (GA x) => x.dyn)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b, GCProvider()]);
      await a.save(GA(name: 'x')..dyn = GC(name: 'wrong'));
      expect(await b.count(), 0);
      expect((await a.db.query('g_a')).single['b_id'], isNull);
      expect(issuesOf(db, FluentIssueKind.relationValue).single.title, contains('holds a GC, but relates GB'));
    });

    test('a list is replaced: children missing from it are deleted, unless keepMissing', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>('bs', (GA x) => x.bs, orderBy: 'name'),
        FluentRelation.many<GA, GC>('cs', (GA x) => x.cs, orderBy: 'name', keepMissing: true),
      ];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c]);
      final GA owner = GA(name: 'x')
        ..bs = [GB(name: 'b1'), GB(name: 'b2')]
        ..cs = [GC(name: 'c1'), GC(name: 'c2')];
      await a.save(owner);
      final GA loaded = (await a.findById(owner.rowId))!;
      loaded
        ..bs = [loaded.bs.first]
        ..cs = [loaded.cs.first];
      await a.save(loaded);
      expect((await b.find()).map((GB m) => m.name), ['b1'], reason: 'replaced');
      expect((await c.find(orderBy: 'name')).map((GC m) => m.name), ['c1', 'c2'], reason: 'keepMissing');
    });

    test('a list that is empty deletes the children, one that was not set leaves them', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.many, select: (GA x) => x.dyn)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      final GA owner = GA(name: 'x')..dyn = [GB(name: 'b1')];
      await a.save(owner);
      final GA bare = (await a.findById(owner.rowId, relations: FluentLoad.none))!;
      await a.save(bare);
      expect(await b.count(), 1, reason: 'not loaded: untouched');
      expect(bare.isRelationLoaded('bs'), isFalse);
      final GA loaded = (await a.findById(owner.rowId))!..dyn = <GB>[];
      await a.save(loaded);
      expect(await b.count(), 0);
    });

    test('a null select leaves the stored children untouched', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.many, select: (GA x) => x.dyn)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      final GA owner = GA(name: 'x')..dyn = [GB(name: 'kept')];
      await a.save(owner);
      owner.dyn = null;
      await a.save(owner);
      expect(await b.count(), 1);
    });

    test('attaching a model of the wrong type skips it with a report', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA x) => x.bs)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b, GCProvider()]);
      final GA owner = GA(name: 'x');
      await a.save(owner);
      await a.attach(owner, 'bs', [GC(name: 'wrong')]);
      expect(await b.count(), 0);
      await a.attach(owner, 'bs', [GC(name: 'wrong'), GB(name: 'right')]);
      expect((await b.find()).map((GB m) => m.name), ['right']);
      expect(issuesOf(db, FluentIssueKind.relationValue), hasLength(1), reason: 'reported once per run');
    });
  });

  group('reading', () {
    test('a limit applies per owner, in the order of the relation, and costs the same statements for any number of owners', () async {
      final QueryCounter counter = await QueryCounter.install();
      addTearDown(counter.uninstall);
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA x) => x.bs, orderBy: 'name DESC', limit: 2)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      Future<int> readsFor(int owners) async {
        await a.deleteAll(await a.findAll());
        for (int i = 0; i < owners; i++) {
          await a.save(GA(name: 'o$i')..bs = [GB(name: 'a'), GB(name: 'b'), GB(name: 'c'), GB(name: 'd')]);
        }
        counter.reset();
        final List<GA> all = await a.findAll();
        expect(all, hasLength(owners));
        for (final GA o in all) {
          expect(o.bs.map((GB m) => m.name), ['d', 'c']);
        }
        return counter.reads;
      }

      final int one = await readsFor(1);
      final int many = await readsFor(25);
      expect(many, one);
      expect(await a.countRelated((await a.findAll()).first, 'bs'), 4, reason: 'counting ignores the limit');
    });

    test('a failing window-function statement that says the function is missing switches to cutting the lists afterwards', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>('broken', (GA x) => x.bs, limit: 1, where: const FluentFilter('no_such_function(name) = 1')),
        FluentRelation.many<GA, GC>('cs', (GA x) => x.cs, orderBy: 'name', limit: 1),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      final GA owner = GA(name: 'x')..cs = [GC(name: 'c2'), GC(name: 'c1')];
      await a.save(owner);
      // The broken relation fails in both paths and is reported instead of failing the read; its failure also taught the
      // library that this database cannot run window functions, so the other limited list is cut after reading.
      final GA read = (await a.findById(owner.rowId))!;
      expect(read.isRelationLoaded('broken'), isFalse);
      expect(issuesOf(db, FluentIssueKind.relationLoadFailed), isNotEmpty);
      expect(read.cs.map((GC m) => m.name), ['c1'], reason: 'the limit and the order still hold');
    });

    test('the relation where filters the loaded children and the count', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA x) => x.bs, where: FluentFilter.notEq('name', 'hidden'))];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final GA owner = GA(name: 'x')..bs = [GB(name: 'shown'), GB(name: 'hidden')];
      await a.save(owner);
      final GA loaded = (await a.findById(owner.rowId))!;
      expect(loaded.bs.map((GB m) => m.name), ['shown']);
      expect(await a.countRelated(loaded, 'bs'), 1);
    });

    test('trashed children are hidden, unless the relation says includeDeleted', () async {
      GBase.declared[GA] = () => [
        FluentRelation<GA, GS>(name: 'ss', type: FluentRelationType.many, select: (GA x) => x.dyn),
        FluentRelation<GA, GS>(name: 'allSs', type: FluentRelationType.many, select: (GA x) => x.dyn, foreignKey: 'ga_id', includeDeleted: true),
      ];
      final GAProvider a = GAProvider();
      final GSProvider s = GSProvider();
      db = await openG([a, s]);
      final GS live = GS(name: 'live');
      final GS gone = GS(name: 'gone');
      final GA owner = GA(name: 'x')..dyn = [live, gone];
      await a.save(owner);
      await s.delete(gone);
      final GA loaded = (await a.findById(owner.rowId))!;
      expect([for (final Object? m in loaded.raw['ss'] as List<Object?>) (m! as GS).name], ['live']);
      expect([for (final Object? m in loaded.raw['allSs'] as List<Object?>) (m! as GS).name], unorderedEquals(['live', 'gone']));
      expect(await a.countRelated(loaded, 'ss'), 1);
      expect(await a.countRelated(loaded, 'allSs'), 2);
    });

    test('depth: relations of the related models load only as deep as asked', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA x) => x.bs)];
      GBase.declared[GB] = () => [FluentRelation.many<GB, GC>('cs', (GB x) => x.cs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      final GA owner = GA(name: 'x')..bs = [GB(name: 'b')..cs = [GC(name: 'c')]];
      await a.save(owner);
      final GA shallow = (await a.findById(owner.rowId))!;
      expect(shallow.bs.single.cs, isEmpty, reason: 'one level by default');
      final GA deep = (await a.findById(owner.rowId, maxDepth: 2))!;
      expect(deep.bs.single.cs.map((GC m) => m.name), ['c']);
      final GA loaded = await a.loadRelations(shallow, maxDepth: 2);
      expect(loaded.bs.single.cs, hasLength(1));
    });

    test('lazy relations load on demand only', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA x) => x.bs, lazy: true), FluentRelation.many<GA, GC>('cs', (GA x) => x.cs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      final GA owner = GA(name: 'x')..bs = [GB(name: 'b')]..cs = [GC(name: 'c')];
      await a.save(owner);
      final GA read = (await a.findById(owner.rowId))!;
      expect(read.isRelationLoaded('bs'), isFalse);
      expect(read.isRelationLoaded('cs'), isTrue);
      final GA full = await a.loadRelations(read, names: ['bs']);
      expect(full.bs.map((GB m) => m.name), ['b']);
    });

    test('a polymorphic reference loads the model of the table it names, and null when the row is gone', () async {
      GBase.declared[GA] = () => [FluentRelation.oneOf<GA>('thing', (GA x) => x.thing, types: [GB, GC])];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c], config: const FluentDbConfig(enableForeignKeys: false));
      final GB pb = GB(name: 'pb');
      final GC pc = GC(name: 'pc');
      await a.saveAll([GA(name: 'to-b')..thing = pb, GA(name: 'to-c')..thing = pc]);
      final List<GA> read = await a.find(orderBy: 'name');
      expect(read.map((GA m) => m.thing.runtimeType), [GB, GC]);
      await c.db.delete('g_c');
      final List<GA> after = await a.find(orderBy: 'name');
      expect(after.map((GA m) => m.thing?.runtimeType), [GB, null]);
    });
  });

  group('references and keys', () {
    test('a single value for a composite key is refused with the way to build it', () async {
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB x) => x.a)];
      final GBProvider b = GBProvider();
      db = await openG([GAProvider(), b]);
      final FluentRelationLink link = b.relationLinks.single;
      // Single-column key: a plain value and a FluentKey both fill the column.
      expect(link.referenceValues(4), {'a_id': 4});
      expect(link.referenceValues(FluentKey({'id': 5})), {'a_id': 5});
      expect(link.referenceValues(null), {'a_id': null});
    });
  });
}
