// Declarations the graph refuses or repairs: every skip has a warning with a hint, and the rest of the model keeps working.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers.dart';

FluentRelationLink? _link(FluentProvider p, String name) => p.relationLinks.where((FluentRelationLink l) => l.name == name).firstOrNull;

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  group('skipped declarations', () {
    test('a related model stored in several tables cannot be chosen', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GB2Provider()]);
      expect(_link(a, 'bs'), isNull);
      final FluentIssue issue = declarationIssues(db, 'several tables').single;
      expect(issue.table, 'g_a');
      expect(issue.title, contains('g_b'));
      expect(issue.title, contains('g_b2'));
      expect(issue.fix, contains('extends'));
    });

    test('no provider for the related model', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs)];
      final GAProvider a = GAProvider();
      db = await openG([a]);
      expect(_link(a, 'bs'), isNull);
      expect(declarationIssues(db, 'no provider for GB').single.fix, contains('FluentGroup'));
    });

    test('through without the provider of its link model', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GCProvider()]);
      expect(_link(a, 'cs'), isNull);
      final FluentIssue issue = declarationIssues(db, 'link model GB').single;
      expect(issue.title, contains('no provider'));
    });

    test('through whose link model is stored in several tables', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GB2Provider(), GCProvider()]);
      expect(_link(a, 'cs'), isNull);
      expect(declarationIssues(db, 'link model GB is stored in several tables'), hasLength(1));
    });

    test('a relation whose select returns another shape than its type warns but is built', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'b', type: FluentRelationType.many, select: (GA a) => a.b)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'declared as many').single;
      expect(issue.title, contains('a single model'));
      expect(issue.fix, contains('FluentRelation.one'));
      expect(_link(a, 'b')?.type, FluentRelationType.many);
    });

    test('a single relation whose select returns a list says to use many', () async {
      GBase.declared[GA] = () => [FluentRelation<GA, GB>(name: 'bs', type: FluentRelationType.one, select: (GA a) => a.bs)];
      db = await openG([GAProvider(), GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'declared as one').single;
      expect(issue.title, contains('a list'));
      expect(issue.fix, contains('many'));
    });

    test('an owned list with via names a oneOf the target does not have', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs, via: 'owner')];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'bs'), isNull);
      final FluentIssue issue = declarationIssues(db, 'has no oneOf relation "owner"').single;
      expect(issue.fix, contains("FluentRelation.oneOf<GB>('owner'"));
    });

    test('an owned list with via whose oneOf cannot point to the owner', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs, via: 'owner')];
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: [GC])];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(_link(a, 'bs'), isNull);
      final FluentIssue issue = declarationIssues(db, 'cannot point to GA').single;
      expect(issue.fix, contains('Add GA to the types of GB.owner'));
    });

    test('oneOf without types', () async {
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: const [])];
      final GBProvider b = GBProvider();
      db = await openG([b]);
      expect(_link(b, 'owner'), isNull);
      expect(declarationIssues(db, 'no types').single.fix, contains('types: [Post, Photo]'));
    });

    test('oneOf with a type no provider stores', () async {
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: [GA])];
      final GBProvider b = GBProvider();
      db = await openG([b]);
      expect(_link(b, 'owner'), isNull);
      expect(declarationIssues(db, 'no provider for GA').single.fix, contains('remove GA from types'));
    });

    test('oneOf with a type stored in several tables', () async {
      GBase.declared[GA] = () => [FluentRelation.oneOf<GA>('owner', (GA x) => x.thing, types: [GB])];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GB2Provider()]);
      expect(_link(a, 'owner'), isNull);
      expect(declarationIssues(db, 'GB is stored in several tables'), isNotEmpty);
    });

    test('through whose link model has no reference to the target', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB x) => x.a)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(_link(a, 'cs'), isNull);
      final FluentIssue none = declarationIssues(db, 'has no relation(s) of kind one to GC').single;
      expect(none.fix, contains('FluentRelation.one<GB, GC>'));
    });

    test('through whose link model has several references to the target', () async {
      GBase.declared[GA] = () => [FluentRelation.through<GA, GB, GC>('cs', (GA a) => a.cs)];
      GBase.declared[GB] = () => [
        FluentRelation.one<GB, GA>('a', (GB x) => x.a),
        FluentRelation.one<GB, GC>('c1', (GB x) => x.c),
        FluentRelation.one<GB, GC>('c2', (GB x) => x.c),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(_link(a, 'cs'), isNull);
      final FluentIssue many = declarationIssues(db, '2 relation(s) of kind one to GC').single;
      expect(many.fix, contains('"c1" or "c2"'));
    });

    test('empty name, duplicate name and a relation declared for another model', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>(' ', (GA a) => a.bs),
        FluentRelation.many<GA, GB>('bs', (GA a) => a.bs),
        FluentRelation.many<GA, GB>('bs', (GA a) => a.bs),
        FluentRelation.many<GB, GA>('as', (GB x) => x.as),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(declarationIssues(db, 'the name is empty'), hasLength(1));
      expect(declarationIssues(db, 'the name is used twice'), hasLength(1));
      expect(declarationIssues(db, 'declared for GB, not for GA'), hasLength(1));
      expect(a.relationLinks.map((FluentRelationLink l) => l.name), ['bs']);
    });
  });

  group('auto relations found in buildJson', () {
    test('buildJson of the sample throwing is reported and no field is found', () async {
      GBase.extras[GA] = (GBase m) => throw StateError('needs a value');
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'buildJson of its modelSample threw').single;
      expect(issue.table, 'g_a');
      expect(issue.error.toString(), contains('needs a value'));
      expect(a.relationLinks, isEmpty);
    });

    test('a field holding a model no provider stores', () async {
      GBase.extras[GA] = (GBase m) => {'c': GC()};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(declarationIssues(db, 'no provider of this database stores that model').single.subject, 'c');
      expect(a.relationLinks, isEmpty);
    });

    test('a field holding a model stored in two tables', () async {
      GBase.extras[GA] = (GBase m) => {'b': GB()};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GB2Provider()]);
      final FluentIssue several = declarationIssues(db, 'stored in several tables').single;
      expect(several.title, contains('g_b'));
      expect(several.title, contains('g_b2'));
      expect(a.relationLinks, isEmpty);
    });
  });

  group('auto decisions', () {
    test('prefer that contradicts the shape is ignored with a hint', () async {
      GBase.declared[GA] = () => [
        FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs, prefer: FluentRelationType.one),
        FluentRelation.auto<GA, GC>('c', (GA a) => a.c, prefer: FluentRelationType.many),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(declarationIssues(db, 'prefer: one of "bs"').single.fix, contains('prefer: many or manyToMany'));
      expect(declarationIssues(db, 'prefer: many of "c"').single.fix, contains('prefer: one or oneOwned'));
      expect(_link(a, 'bs')?.type, FluentRelationType.manyToMany);
      expect(_link(a, 'c')?.type, FluentRelationType.one);
    });

    test('prefer that matches the shape is used', () async {
      GBase.declared[GA] = () => [
        FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs, prefer: FluentRelationType.many),
        FluentRelation.auto<GA, GC>('c', (GA a) => a.c, prefer: FluentRelationType.oneOwned),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(_link(a, 'bs')?.type, FluentRelationType.many);
      expect(_link(a, 'bs')?.decidedBy, contains('prefer many'));
      expect(_link(a, 'c')?.type, FluentRelationType.oneOwned);
      expect(declarationIssues(db, 'prefer:'), isEmpty);
    });

    test('a select of unknown type with no signal falls back and says so', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('stuff', (GA a) => a.dyn)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'cannot tell if select returns a list').single;
      expect(issue.fix, contains('List<GB>?'));
      expect(_link(a, 'stuff')?.type, FluentRelationType.manyToMany);
      expect(_link(a, 'stuff')?.decidedBy, contains('select type unknown'));
    });

    test('a select of unknown type uses prefer', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('stuff', (GA a) => a.dyn, prefer: FluentRelationType.many)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'stuff')?.type, FluentRelationType.many);
    });

    test('a select of unknown type is a reference when the owner has the column', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('stuff', (GA a) => a.dyn)];
      GBase.extras[GA] = (GBase m) => {'stuff_id': 1};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'stuff')?.type, FluentRelationType.one);
      expect(_link(a, 'stuff')?.decidedBy, contains('stuff_id'));
    });

    test('a select of unknown type is a list when the target has the owner column', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('stuff', (GA a) => a.dyn)];
      GBase.extras[GB] = (GBase m) => {'ga_id': 1};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'stuff')?.type, FluentRelationType.many);
    });

    test('a single model whose target has an explicit one back is owned', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('b', (GA a) => a.b)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB x) => x.a)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentRelationLink link = _link(a, 'b')!;
      expect(link.type, FluentRelationType.oneOwned);
      expect(link.decidedBy, contains('GB.a references GA'));
    });

    test('a single model whose target declares a list back is a reference', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('b', (GA a) => a.b)];
      GBase.declared[GB] = () => [FluentRelation.many<GB, GA>('as', (GB x) => x.as)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'b')?.type, FluentRelationType.one);
      expect(_link(a, 'b')?.decidedBy, contains('declares list "as" back'));
    });

    test('a list whose target declares a list back is many-to-many', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs)];
      GBase.declared[GB] = () => [FluentRelation.many<GB, GA>('as', (GB x) => x.as)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'bs')?.type, FluentRelationType.manyToMany);
    });

    test('a list whose target declares a one back is many', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('a', (GB x) => x.a)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'bs')?.type, FluentRelationType.many);
      expect(_link(a, 'bs')?.decidedBy, contains('declares one "a" back'));
    });

    test('a list is polymorphic when the target has a oneOf that may hold the owner', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs)];
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: [GA, GC])];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      final FluentRelationLink link = _link(a, 'bs')!;
      expect(link.type, FluentRelationType.many);
      expect(link.typeColumn, 'owner_type');
      expect(link.typeValue, 'g_a');
      expect(link.via, 'owner');
    });

    test('two auto lists of the same type by different owners are shared (many-to-many)', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs)];
      GBase.declared[GC] = () => [FluentRelation.auto<GC, GB>('bs', (GC c) => c.bs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      expect(_link(a, 'bs')?.type, FluentRelationType.manyToMany);
      expect(_link(a, 'bs')?.decidedBy, contains('also listed by GC'));
    });

    test('a list without any signal uses the fallback', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('bs', (GA a) => a.bs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'bs')?.type, FluentRelationType.manyToMany);
      expect(_link(a, 'bs')?.decidedBy, contains('fallback manyToMany'));
    });

    test('auto single model: the target lists the owner', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('b', (GA a) => a.b)];
      GBase.declared[GB] = () => [FluentRelation.auto<GB, GA>('as', (GB x) => x.as)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'b')?.type, FluentRelationType.one);
      expect(_link(a, 'b')?.decidedBy, contains('lists GA'));
    });

    test('auto single model: the owner has the column <name>_id', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('b', (GA a) => a.b)];
      GBase.extras[GA] = (GBase m) => {'b_id': 1};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'b')?.type, FluentRelationType.one);
      expect(_link(a, 'b')?.foreignKeys, ['b_id']);
    });

    test('auto single model: the owner has the column named after the type', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('other', (GA a) => a.b)];
      GBase.extras[GA] = (GBase m) => {'gb_id': 1};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'other')?.type, FluentRelationType.one);
      expect(_link(a, 'other')?.foreignKeys, ['gb_id']);
    });

    test('auto single model: the target has the owner column, so the target owns it', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('other', (GA a) => a.b)];
      GBase.extras[GB] = (GBase m) => {'ga_id': 1};
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'other')?.type, FluentRelationType.oneOwned);
    });

    test('auto single model without any signal is a reference, which never deletes data', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GB>('other', (GA a) => a.b)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(_link(a, 'other')?.type, FluentRelationType.one);
      expect(_link(a, 'other')?.decidedBy, contains('default one'));
      expect(_link(a, 'other')?.onDelete, FluentOnDelete.setNull);
    });

    test('a self-referencing single auto relation is a reference, not a one-to-one pair', () async {
      GBase.declared[GA] = () => [FluentRelation.auto<GA, GA>('a', (GA x) => x.a)];
      final GAProvider a = GAProvider();
      db = await openG([a]);
      expect(_link(a, 'a')?.type, FluentRelationType.one);
      expect(_link(a, 'a')?.oneToOne, isFalse);
    });
  });

  group('owned lists on shared columns', () {
    test('two owned lists of the same type share no column by accident', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>('bs', (GA a) => a.bs),
        FluentRelation.many<GA, GB>('others', (GA a) => a.bs),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentRelationLink first = _link(a, 'bs')!;
      final FluentRelationLink second = _link(a, 'others')!;
      expect(first.foreignKeys, ['ga_id']);
      expect(second.foreignKeys, ['others_ga_id']);
      final FluentIssue issue = declarationIssues(db, 'would share column(s)').single;
      expect(issue.subject, 'others');
      expect(issue.fix, contains('foreignKey: "others_id"'));
    });

    test('an explicit foreignKey on both lists is a deliberate choice, no warning', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>('bs', (GA a) => a.bs, foreignKey: 'x'),
        FluentRelation.many<GA, GB>('others', (GA a) => a.bs, foreignKey: 'x'),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      expect(declarationIssues(db, 'would share'), isEmpty);
      expect(_link(a, 'others')?.foreignKeys, ['x']);
    });

    test('several references back with none named like the owner report which column the list uses', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs)];
      GBase.declared[GB] = () => [FluentRelation.one<GB, GA>('first', (GB x) => x.a), FluentRelation.one<GB, GA>('second', (GB x) => x.a)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'references GA 2 times').single;
      expect(issue.fix, contains('foreignKey'));
      expect(issue.code, contains("foreignKey: 'first_id'"));
      expect(_link(a, 'bs')?.foreignKeys, ['ga_id']);
    });
  });

  group('links as values', () {
    test('describe and toString name every kind', () async {
      GBase.declared[GA] = () => [
        FluentRelation.one<GA, GB>('b', (GA a) => a.b),
        FluentRelation.many<GA, GC>('cs', (GA a) => a.cs),
        FluentRelation.oneOwned<GA, GA>('a', (GA a) => a.a),
        FluentRelation.manyToMany<GA, GB>('bs', (GA a) => a.bs),
        FluentRelation.oneOf<GA>('owner', (GA a) => a.thing, types: [GB, GC]),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()]);
      final Map<String, String> text = {for (final FluentRelationLink l in a.relationLinks) l.name: l.describe()};
      expect(text['b'], contains('→ g_b'));
      expect(text['cs'], contains('← g_c.'));
      expect(text['a'], contains('one owned'));
      expect(text['bs'], contains('↔ g_b via'));
      expect(text['owner'], contains('one of g_b | g_c'));
      expect(_link(a, 'b').toString(), startsWith('FluentRelationLink(g_a.'));
    });

    test('link values for single keys accept plain values and FluentKeys', () async {
      GBase.declared[GA] = () => [FluentRelation.manyToMany<GA, GB>('bs', (GA a) => a.bs)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentRelationLink link = _link(a, 'bs')!;
      expect(link.linkOwnerValues(5), {link.linkOwnerColumns.single: 5});
      expect(link.linkOwnerValues(FluentKey({'id': 6})), {link.linkOwnerColumns.single: 6});
    });
  });
}
