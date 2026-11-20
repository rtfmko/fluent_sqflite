// How related / notRelated / relatedCount conditions are written as SQL: placeholders in raw SQL around them,
// oneOf references, typed conditions, paths and the errors with a fix.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  late GAProvider a;
  late GBProvider b;
  late GCProvider c;

  Future<void> open() async {
    GBase.declared[GA] = () => [
      FluentRelation.many<GA, GB>('bs', (GA x) => x.bs),
      FluentRelation.oneOf<GA>('thing', (GA x) => x.thing, types: [GB, GC]),
    ];
    GBase.declared[GB] = () => [FluentRelation.one<GB, GC>('c', (GB x) => x.c)];
    a = GAProvider();
    b = GBProvider();
    c = GCProvider();
    db = await openG([a, b, c]);
    await a.saveAll([
      GA(name: 'with-b')..bs = [GB(name: 'b1'), GB(name: 'b2')],
      GA(name: 'with-thing-b')..thing = (GB(name: 'pointed')..c = GC(name: 'deep')),
      GA(name: 'with-thing-c')..thing = GC(name: 'pointed-c'),
      GA(name: 'alone'),
    ]);
  }

  Future<List<String>> names(FluentFilter where) async => [for (final GA x in await a.find(where: where, orderBy: 'name')) x.name];

  group('raw SQL around a related condition', () {
    setUp(open);

    test('placeholders inside strings, quoted identifiers and comments are not counted', () async {
      const FluentFilter raw = FluentFilter(
        "\"name\" <> '?' AND [name] <> '?' AND `name` <> ? /* ? */ AND 1 = ? -- ? is a comment\n AND name <> ?",
        ['x', 1, 'alone'],
      );
      expect(await names(raw.and(FluentFilter.related('bs'))), ['with-b']);
      expect(await names(FluentFilter.related('bs').and(raw)), ['with-b']);
      expect(await names(raw.and(FluentFilter.notRelated('bs'))), ['with-thing-b', 'with-thing-c']);
    });

    test('a comment that never ends swallows the closing parenthesis: SQLite rejects it as a typed error', () async {
      // The placeholder scan stops at the end of the text (nothing after an unterminated comment counts), and the
      // statement itself is invalid because the comment also swallows what the library appends.
      await expectLater(names(FluentFilter.related('bs').and(const FluentFilter('1 = ? -- trailing ?', [1]))), throwsA(isA<FluentQueryException>()));
      await expectLater(names(FluentFilter.related('bs').and(const FluentFilter('1 = ? /* trailing ?', [1]))), throwsA(isA<FluentQueryException>()));
    });

    test('or keeps the arguments of both sides in order', () async {
      final FluentFilter either = FluentFilter.related('bs', FluentFilter.eq('name', 'b2')).or(FluentFilter.eq('name', 'alone'));
      expect(await names(either), ['alone', 'with-b']);
    });
  });

  group('oneOf references', () {
    setUp(open);

    test('related finds the rows pointing to any of the types, or only to one', () async {
      expect(await names(FluentFilter.related('thing')), ['with-thing-b', 'with-thing-c']);
      expect(await names(FluentFilter.related<GB>('thing')), ['with-thing-b']);
      expect(await names(FluentFilter.related<GC>('thing')), ['with-thing-c']);
      expect(await names(FluentFilter.related<GC>('thing', FluentFilter.eq('name', 'pointed-c'))), ['with-thing-c']);
      expect(await names(FluentFilter.related<GC>('thing', FluentFilter.eq('name', 'nope'))), isEmpty);
    });

    test('notRelated is the complement', () async {
      expect(await names(FluentFilter.notRelated('thing')), ['alone', 'with-b']);
      expect(await names(FluentFilter.notRelated<GB>('thing')), ['alone', 'with-b', 'with-thing-c']);
    });

    test('relatedCount counts 0 or 1 with min, max or both', () async {
      expect(await names(FluentFilter.relatedCount('thing', min: 1)), ['with-thing-b', 'with-thing-c']);
      expect(await names(FluentFilter.relatedCount('thing', max: 0)), ['alone', 'with-b']);
      expect(await names(FluentFilter.relatedCount('thing', min: 1, max: 1)), ['with-thing-b', 'with-thing-c']);
      expect(await names(FluentFilter.relatedCount('thing', min: 2, max: 3)), isEmpty);
    });

    test('a path follows only the types that have the next relation', () async {
      expect(await names(FluentFilter.related('thing.c', FluentFilter.eq('name', 'deep'))), ['with-thing-b']);
    });

    test('a path nobody has fails with a hint', () async {
      await expectLater(a.find(where: FluentFilter.related('thing.nothing')), throwsA(isA<FluentArgumentException>()));
    });
  });

  group('conditions that are refused or corrected', () {
    setUp(open);

    test('a type on a relation that is not a oneOf is ignored with a hint', () async {
      expect(await names(FluentFilter.related<GC>('bs')), ['with-b']);
      final FluentIssue issue = db.issues.singleWhere((FluentIssue i) => i.kind == FluentIssueKind.ignoredCall && i.title.contains('always holds GB'));
      expect(issue.subject, 'bs');
      expect(issue.fix, contains("FluentFilter.related('bs'"));
    });

    test('the right type is not an issue', () async {
      expect(await names(FluentFilter.related<GB>('bs')), ['with-b']);
      expect(db.issues.where((FluentIssue i) => i.title.contains('always holds')), isEmpty);
    });

    test('a count with a path and a count without bounds fail with the fix', () async {
      await expectLater(
        a.find(where: FluentFilter.relatedCount('bs.c', min: 1)),
        throwsA(isA<FluentArgumentException>().having((FluentArgumentException e) => e.message, 'message', contains('takes one relation, not a path'))),
      );
      await expectLater(
        a.find(where: FluentFilter.relatedCount('bs')),
        throwsA(isA<FluentArgumentException>().having((FluentArgumentException e) => e.hint, 'hint', contains("relatedCount('bs', min: 1)"))),
      );
    });

    test('an unknown relation names the known ones', () async {
      await expectLater(
        a.find(where: FluentFilter.related('nope')),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.hint, 'hint', contains('Relations of "g_a": bs, thing'))),
      );
    });

    test('a table with no relations says where to declare them', () async {
      await expectLater(
        c.find(where: FluentFilter.related('nope')),
        throwsA(isA<FluentRelationException>().having((FluentRelationException e) => e.hint, 'hint', contains('Declare the relation in GC.relations'))),
      );
    });

    test('a filter with more ids than one statement binds works (the keys go through a temporary table)', () async {
      final List<int> ids = List<int>.generate(5000, (int i) => i);
      expect(await a.find(where: FluentFilter.ids(ids)), isA<List<Object?>>());
    });
  });
}
