// loadRelations, countRelated, attach, detach, findRelated and findParents: every relation kind, the calls that are
// reported and ignored, and the statement counts.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '_helpers.dart';

List<FluentIssue> _ignored(FluentTestDb db, String text) => [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.ignoredCall && i.title.contains(text)) i];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  void declareAll() {
    GBase.declared[GA] = () => [
      FluentRelation.many<GA, GB>('bs', (GA a) => a.bs, orderBy: 'name'),
      FluentRelation.manyToMany<GA, GC>('cs', (GA a) => a.cs, linkTable: 'ac_links', orderBy: 'name'),
      FluentRelation.one<GA, GC>('c', (GA a) => a.c),
      FluentRelation.oneOf<GA>('thing', (GA a) => a.thing, types: [GB, GC]),
    ];
    GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB b) => b.a)];
  }

  Future<(GAProvider, GBProvider, GCProvider)> openAll({FluentDbConfig config = const FluentDbConfig()}) async {
    declareAll();
    final GAProvider a = GAProvider();
    final GBProvider b = GBProvider();
    final GCProvider c = GCProvider();
    db = await openG([a, b, c], config: config);
    return (a, b, c);
  }

  group('loadRelations', () {
    test('reports unknown names and still loads the known ones', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA saved = await put(a, GA(name: 'x')..bs = [GB(name: 'one')]);
      final GA bare = (await a.findById(saved.rowId, relations: FluentLoad.none))!;
      final GA loaded = await a.loadRelations(bare, names: ['bs', 'nope']);
      expect(loaded.bs.map((GB b) => b.name), ['one']);
      final FluentIssue issue = _ignored(db, 'Unknown relations [nope]').single;
      expect(issue.fix, contains('Known relations: bs, cs, c, thing'));
    });

    test('a model with no relations explains where to declare them', () async {
      final GCProvider c = GCProvider();
      db = await openG([c]);
      final GC row = await put(c, GC(name: 'x'));
      await c.loadRelations(row, names: ['ghost']);
      expect(_ignored(db, 'Unknown relations [ghost]').single.fix, contains('declares no relations'));
    });

    test('a model without a key and a model whose row is gone come back unchanged', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA unsaved = GA(name: 'new');
      expect(identical(await a.loadRelations(unsaved), unsaved), isTrue);
      expect(_ignored(db, 'has no key yet, nothing to load'), hasLength(1));

      final GA gone = GA(id: 404, name: 'gone');
      expect(identical(await a.loadRelations(gone), gone), isTrue);
      final FluentIssue issue = _ignored(db, 'no "g_a" row with key 404').single;
      expect(issue.table, 'g_a');
    });
  });

  group('countRelated', () {
    test('counts every kind of relation, and 0 for unknown names and models without a key', () async {
      final (GAProvider a, GBProvider b, GCProvider c) = await openAll();
      final GC shared = await put(c, GC(name: 'shared'));
      final GA owner = await put(a, GA(name: 'x')
        ..bs = [GB(name: '1'), GB(name: '2'), GB(name: '3')]
        ..cs = [shared, GC(name: 'other')]
        ..c = shared
        ..thing = GB(name: 'pointed'));
      expect(await a.countRelated(owner, 'bs'), 3);
      expect(await a.countRelated(owner, 'cs'), 2);
      expect(await a.countRelated(owner, 'c'), 1);
      expect(await a.countRelated(owner, 'thing'), 1);
      expect(await a.countRelated(owner, 'nope'), 0);
      expect(await a.countRelated(GA(name: 'unsaved'), 'bs'), 0);
    });

    test('a oneOf with no value counts 0', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA owner = await put(a, GA(name: 'x'));
      expect(await a.countRelated(owner, 'thing'), 0);
    });
  });

  group('attach', () {
    test('adds owned children and links without touching the others, and is idempotent for links', () async {
      final (GAProvider a, GBProvider b, GCProvider c) = await openAll();
      final GA owner = await put(a, GA(name: 'x')..bs = [GB(name: 'old')]..cs = [GC(name: 'c0')]);
      await a.attach(owner, 'bs', [GB(name: 'new')]);
      expect((await b.find(orderBy: 'name')).map((GB x) => x.name), ['new', 'old']);
      expect(await a.countRelated(owner, 'bs'), 2);

      final GC extra = await put(c, GC(name: 'c1'));
      await a.attach(owner, 'cs', [extra]);
      await a.attach(owner, 'cs', [extra]);
      expect(await a.countRelated(owner, 'cs'), 2, reason: 'a link exists once');
    });

    test('is ignored and reported for unknown relations, empty lists, models without a key and single references', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA owner = await put(a, GA(name: 'x'));
      await a.attach(owner, 'nope', [GB(name: 'x')]);
      expect(_ignored(db, 'attach: "g_a" has no relation "nope"'), hasLength(1));

      await a.attach(owner, 'bs', const []);
      await a.attach(GA(name: 'unsaved'), 'bs', [GB(name: 'x')]);
      expect(_ignored(db, 'attach: GA has no key yet'), hasLength(1));

      await a.attach(owner, 'c', [GC(name: 'x')]);
      await a.attach(owner, 'thing', [GC(name: 'x')]);
      expect(_ignored(db, 'attach is not used for'), hasLength(2));
      expect(await a.countRelated(owner, 'c'), 0);
    });

    test('through needs a link and skips links of the wrong type', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB b) => b.a), FluentRelation.one<GB, GC>('c', (GB b) => b.c)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c]);
      final GA owner = await put(a, GA(name: 'x'));
      final GC target = await put(c, GC(name: 'target'));

      await a.attach(owner, 'cs', [target]);
      final FluentIssue noLink = _ignored(db, 'links through GB, but no link was given').single;
      expect(noLink.code, contains('link: (related) => GB(...)'));
      expect(await b.count(), 0);

      await a.attach(owner, 'cs', [target], link: (FluentStorable related) => GC(name: 'wrong'));
      final FluentIssue wrong = issuesOf(db, FluentIssueKind.relationValue).single;
      expect(wrong.title, contains('is a GC, not a GB'));
      expect(wrong.fix, contains('Return a GB from link'));
      expect(await b.count(), 0);

      await a.attach(owner, 'cs', [target], link: (FluentStorable related) => GB(name: 'role'));
      await a.attach(owner, 'cs', [target], link: (FluentStorable related) => GB(name: 'again'));
      expect((await b.find()).map((GB x) => x.name), ['role'], reason: 'already linked: no second link model');
    });
  });

  group('detach', () {
    test('removes links only, children by key, and ignores what it cannot do', () async {
      final (GAProvider a, GBProvider b, GCProvider c) = await openAll();
      final GC c1 = GC(name: 'c1');
      final GC c2 = GC(name: 'c2');
      final GA owner = await put(a, GA(name: 'x')
        ..bs = [GB(name: '1'), GB(name: '2')]
        ..cs = [c1, c2]);
      final GA loaded = (await a.findById(owner.rowId))!;

      await a.detach(loaded, 'cs', [loaded.cs.first]);
      expect(await a.countRelated(owner, 'cs'), 1);
      expect(await c.count(), 2, reason: 'shared models stay');

      await a.detach(loaded, 'bs', [loaded.bs.first, GB(name: 'no key')]);
      expect((await b.find()).map((GB x) => x.name), ['2']);

      await a.detach(loaded, 'bs', [GB(name: 'no key')]); // no key at all: nothing
      await a.detach(loaded, 'bs', const []);
      await a.detach(GA(name: 'unsaved'), 'bs', [loaded.bs.last]);
      await a.detach(loaded, 'nope', [loaded.bs.last]);
      expect(_ignored(db, 'detach: "g_a" has no relation "nope"'), hasLength(1));
      await a.detach(loaded, 'c', [GC(id: 1)]);
      await a.detach(loaded, 'thing', [GC(id: 1)]);
      expect(_ignored(db, 'detach is not used for'), hasLength(2));
      expect(await b.count(), 1);
    });

    test('a through relation deletes the link models and keeps the related models', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB b) => b.a), FluentRelation.one<GB, GC>('c', (GB b) => b.c)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c]);
      final GA owner = await put(a, GA(name: 'x'));
      final GC t1 = await put(c, GC(name: 't1'));
      final GC t2 = await put(c, GC(name: 't2'));
      await a.attach(owner, 'cs', [t1, t2], link: (FluentStorable r) => GB(name: 'link'));
      expect(await b.count(), 2);
      await a.detach(owner, 'cs', [t1]);
      expect(await b.count(), 1);
      expect(await c.count(), 2);
    });

    test('detaching more links than one statement can hold is chunked', () async {
      final (GAProvider a, _, GCProvider c) = await openAll();
      final GA owner = await put(a, GA(name: 'x'));
      final List<GC> many = [for (int i = 0; i < 1500; i++) GC(name: 'c$i')];
      final List<GC> saved = await putAll(c, many);
      await a.attach(owner, 'cs', saved);
      expect(await a.countRelated(owner, 'cs'), 1500);
      await a.detach(owner, 'cs', saved);
      expect(await a.countRelated(owner, 'cs'), 0);
      expect(await c.count(), 1500);
    });
  });

  group('findRelated', () {
    test('queries instead of loading: where, orderBy, limit, offset, and the relation order by default', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA owner = await put(a, GA(name: 'x')..bs = [GB(name: 'b'), GB(name: 'a'), GB(name: 'c'), GB(name: 'd')]);
      expect((await a.findRelated<GB>(owner, 'bs')).map((GB x) => x.name), ['a', 'b', 'c', 'd'], reason: 'the relation orderBy');
      expect((await a.findRelated<GB>(owner, 'bs', orderBy: 'name DESC', limit: 2, offset: 1)).map((GB x) => x.name), ['c', 'b']);
      expect((await a.findRelated<GB>(owner, 'bs', where: FluentFilter.gte('name', 'c'))).map((GB x) => x.name), ['c', 'd']);
    });

    test('works for links, references and models without a key', () async {
      final (GAProvider a, _, GCProvider c) = await openAll();
      final GC shared = await put(c, GC(name: 'shared'));
      final GA owner = await put(a, GA(name: 'x')..cs = [shared, GC(name: 'z')]..c = shared);
      expect((await a.findRelated<GC>(owner, 'cs')).map((GC x) => x.name), ['shared', 'z']);
      expect((await a.findRelated<GC>(owner, 'c')).map((GC x) => x.name), ['shared']);
      expect(await a.findRelated<GC>(GA(name: 'unsaved'), 'cs'), isEmpty);
    });

    test('refuses a oneOf, a wrong type and an unknown relation with typed exceptions', () async {
      final (GAProvider a, _, _) = await openAll();
      final GA owner = await put(a, GA(name: 'x'));
      await expectLater(
        a.findRelated<GB>(owner, 'thing'),
        throwsA(isA<FluentArgumentException>().having((FluentArgumentException e) => e.hint, 'hint', contains("loadRelations(model, names: ['thing'])"))),
      );
      await expectLater(
        a.findRelated<GA>(owner, 'bs'),
        throwsA(isA<FluentArgumentException>().having((FluentArgumentException e) => e.hint, 'hint', contains('findRelated<GB>'))),
      );
      await expectLater(a.findRelated<GB>(owner, 'nope'), throwsA(isA<FluentRelationException>()));
    });
  });

  group('findParents', () {
    test('finds the owners of a model, with the same filters as find', () async {
      final (GAProvider a, GBProvider b, _) = await openAll();
      final GA first = await put(a, GA(name: 'first')..bs = [GB(name: 'child')]);
      await a.save(GA(name: 'second'));
      final GB child = (await b.find()).single;
      expect((await b.findParents<GA>(child, via: 'bs')).map((GA x) => x.name), ['first']);
      expect(await b.findParents<GA>(child, via: 'bs', where: FluentFilter.eq('name', 'second')), isEmpty);
      expect((await b.findParents<GA>(child, via: 'bs', limit: 1)).single.rowId, first.rowId);
      expect(await b.findParents<GA>(GB(name: 'unsaved'), via: 'bs'), isEmpty);

      // The polymorphic reference is found by its own name.
      final GA pointing = await put(a, GA(name: 'pointing')..thing = child);
      expect((await b.findParents<GA>(child, via: 'thing')).map((GA x) => x.rowId), [pointing.rowId]);
    });

    test('no relation, an unknown via and several relations give typed exceptions with the fix', () async {
      final (GAProvider a, GBProvider b, GCProvider c) = await openAll();
      final GB child = await put(b, GB(name: 'x'));
      await expectLater(
        c.findParents<GB>(GC(id: 1)),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.hint, 'hint', contains('Declare one in GB.relations'))),
      );
      await expectLater(
        b.findParents<GA>(child, via: 'nope'),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.message, 'message', contains('GA has no relation "nope" to GB'))),
      );
      // GA has two relations to GB (the owned list and the polymorphic reference): the name is needed.
      await expectLater(
        b.findParents<GA>(child),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.message, 'message', contains('GA has 2 relations to GB (bs, thing)'))),
      );
      expect(a.relationLinks, isNotEmpty);
    });

    test('a relation to a model with relations to it from elsewhere names them in the hint', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs), FluentRelation.many<GA, GB>('others', (GA a) => a.bs, foreignKey: 'other_id')];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      final GB child = await put(b, GB(name: 'x'));
      await expectLater(
        b.findParents<GA>(child),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.hint, 'hint', contains("via: 'bs'"))),
      );
      await expectLater(
        b.findParents<GA>(child, via: 'zzz'),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.hint, 'hint', contains('Relations of GA to GB: bs, others'))),
      );
    });
  });

  group('statements', () {
    test('loading relations of many owners costs the same number of statements as of one', () async {
      final QueryCounter counter = await QueryCounter.install();
      addTearDown(counter.uninstall);
      final (GAProvider a, _, _) = await openAll();
      Future<int> readsFor(int owners) async {
        await a.deleteAll(await a.findAll());
        for (int i = 0; i < owners; i++) {
          await a.save(GA(name: 'o$i')..bs = [GB(name: 'b$i')]..cs = [GC(name: 'c$i')]..thing = GC(name: 'p$i'));
        }
        counter.reset();
        final List<GA> all = await a.findAll();
        expect(all, hasLength(owners));
        expect(all.every((GA x) => x.bs.length == 1 && x.cs.length == 1), isTrue);
        return counter.reads;
      }

      final int one = await readsFor(1);
      final int many = await readsFor(30);
      expect(many, one, reason: 'relations are loaded in batches per relation, not per owner');
    });

    test('attach of many links takes a constant number of writes', () async {
      final QueryCounter counter = await QueryCounter.install();
      addTearDown(counter.uninstall);
      final (GAProvider a, _, GCProvider c) = await openAll();
      final GA owner = await put(a, GA(name: 'x'));
      final List<GC> few = await putAll(c, [for (int i = 0; i < 3; i++) GC(name: 'few$i')]);
      final List<GC> lots = await putAll(c, [for (int i = 0; i < 300; i++) GC(name: 'lot$i')]);
      counter.reset();
      await a.attach(owner, 'cs', few);
      final int small = counter.writes + counter.reads;
      counter.reset();
      await a.attach(owner, 'cs', lots);
      final int large = counter.writes + counter.reads;
      expect(large, lessThanOrEqualTo(small + 2), reason: 'statements grow with chunks, not with links');
    });
  });
}
