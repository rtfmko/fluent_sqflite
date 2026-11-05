// Edge cases of reads: keyset cursors on library-managed columns and NULLs, search paging, columns checks,
// deletedAt handling after a save, restoring under a deleted owner.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

class Doc extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Doc({this.id, required this.title, this.rank});

  final int? id;
  final String title;
  final int? rank;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'rank': rank};

  /// `extra` is a column of the table that buildJson does not write.
  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('title'), FluentDbColumn.integer('rank'), FluentDbColumn.text('extra')];
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String, rank: json['rank'] as int?);
}

class Looser extends FluentStorable {
  Looser({this.id, required this.name});

  final int? id;
  final String name;

  /// The key is left out while it is null, so the sample (no id) names no key.
  @override
  Map<String, dynamic> buildJson() => {if (id != null) 'id': id, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.text('extra')];
}

class Loose extends FluentProvider<Looser> {
  @override
  String get tableName => 'looser';

  @override
  Looser get modelSample => Looser(name: '');

  @override
  Looser fromCacheJson(Map<String, dynamic> json) => Looser(id: json['id'] as int?, name: json['name'] as String);
}

class Owner extends FluentStorable with FluentSoftDeletable, FluentRelations {
  Owner({this.id, required this.name, this.parts});

  final int? id;
  final String name;
  final List<Part>? parts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Owner, Part>('parts', (o) => o.parts)];
}

class Part extends FluentStorable with FluentSoftDeletable {
  Part({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class OwnerProvider extends FluentProvider<Owner> {
  @override
  String get tableName => 'owners';

  @override
  Owner get modelSample => Owner(name: '');

  @override
  Owner fromCacheJson(Map<String, dynamic> json) => Owner(id: json['id'] as int?, name: json['name'] as String, parts: (json['parts'] as List?)?.cast<Part>());
}

class PartProvider extends FluentProvider<Part> {
  @override
  String get tableName => 'parts';

  @override
  Part get modelSample => Part(label: '');

  @override
  Part fromCacheJson(Map<String, dynamic> json) {
    if (json['label'] == 'boom') throw StateError('cannot build this part');
    return Part(id: json['id'] as int?, label: json['label'] as String);
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'redges_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  Future<List<int?>> walk(DocProvider docs, {required String orderBy, bool descending = false, int limit = 1, bool withTrash = false}) async {
    final List<int?> ids = [];
    FluentCursor? after;
    do {
      final FluentPage<Doc> page = withTrash
          ? await docs.withTrash.findPage(orderBy: orderBy, descending: descending, limit: limit, after: after)
          : await docs.findPage(orderBy: orderBy, descending: descending, limit: limit, after: after);
      ids.addAll([for (final Doc d in page.items) d.id]);
      after = page.next;
    } while (after != null);
    return ids;
  }

  group('findPage cursors', () {
    test('NULL values: a cursor that lands on a NULL row continues correctly in both directions', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      await docs.saveAll([
        Doc(id: 1, title: 'a', rank: 2),
        Doc(id: 2, title: 'b'),
        Doc(id: 3, title: 'c', rank: 1),
        Doc(id: 4, title: 'd'),
        Doc(id: 5, title: 'e', rank: 2),
      ]);
      final List<Map<String, Object?>> asc = await docs.db.rawQuery('SELECT id FROM docs ORDER BY rank ASC, id ASC');
      expect(await walk(docs, orderBy: 'rank'), [for (final Map<String, Object?> r in asc) r['id']]);
      final List<Map<String, Object?>> desc = await docs.db.rawQuery('SELECT id FROM docs ORDER BY rank DESC, id DESC');
      expect(await walk(docs, orderBy: 'rank', descending: true), [for (final Map<String, Object?> r in desc) r['id']]);
      expect(await walk(docs, orderBy: 'rank', limit: 2), [for (final Map<String, Object?> r in asc) r['id']]);
      expect(await walk(docs, orderBy: 'rank', descending: true, limit: 2), [for (final Map<String, Object?> r in desc) r['id']]);
    });

    test('library-managed columns (created_at, updated_at, deleted_at) work as the order; every row appears once', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      db.clock.set(DateTime.utc(2030));
      for (int i = 1; i <= 4; i++) {
        await docs.save(Doc(id: i, title: 't$i'));
        db.clock.advance(const Duration(minutes: 1));
      }
      expect(await walk(docs, orderBy: 'created_at'), [1, 2, 3, 4]);
      expect(await walk(docs, orderBy: 'created_at', descending: true), [4, 3, 2, 1]);
      expect(await walk(docs, orderBy: 'updated_at', descending: true, limit: 3), [4, 3, 2, 1]);
      await docs.deleteWhere(FluentFilter.inList('id', [1, 3]));
      db.clock.advance(const Duration(minutes: 5));
      await docs.deleteWhere(FluentFilter.eq('id', 2));
      // Live rows have no deleted_at (NULL), so the trash column puts the live ones first and then by key.
      final List<int?> byDeleted = await walk(docs, orderBy: 'deleted_at', withTrash: true);
      expect(byDeleted.toSet(), {1, 2, 3, 4});
      expect(byDeleted, hasLength(4));
      expect(byDeleted.first, 4, reason: 'NULL (live) sorts first');
      expect(byDeleted.last, 2, reason: 'trashed last, 2 was deleted last');
    });

    test('a column the model does not write cannot be a cursor: typed error with a hint', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      await docs.saveAll([Doc(id: 1, title: 'a'), Doc(id: 2, title: 'b')]);
      await expectLater(
        docs.findPage(orderBy: 'extra', limit: 1),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('Name one column')).having((e) => e.message, 'message', contains('"extra"'))),
      );
    });

    test('a sample that does not write the key cannot vouch for the fields: the cursor fails when it is built', () async {
      final Loose loose = Loose();
      await db.open([loose]);
      await loose.saveAll([for (int i = 1; i <= 3; i++) Looser(id: i, name: 'n$i')]);
      expect((await loose.findPage(orderBy: 'extra', limit: 5)).items, hasLength(3), reason: 'a last page needs no cursor');
      await expectLater(
        loose.findPage(orderBy: 'extra', limit: 1),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('buildJson writes')).having((e) => e.message, 'message', contains('"extra"'))),
      );
    });

    test('limit larger than the table, an empty table and a where with no match give one empty / short page', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      FluentPage<Doc> page = await docs.findPage();
      expect(page.items, isEmpty);
      expect(page.next, isNull);
      await docs.saveAll([Doc(id: 1, title: 'a'), Doc(id: 2, title: 'b')]);
      page = await docs.findPage(limit: 100);
      expect(page.items, hasLength(2));
      expect(page.next, isNull);
      page = await docs.findPage(limit: 2);
      expect(page.next, isNull, reason: 'exactly a full page and nothing after it');
      page = await docs.findPage(where: FluentFilter.eq('title', 'zzz'));
      expect(page.items, isEmpty);
    });
  });

  group('search paging', () {
    test('search honours limit / offset / where on the full-text index', () async {
      final TableSpec spec = TableSpec(
        columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('title'), FluentDbColumn.integer('n')],
        indexes: const [FluentIndex.fullText(['title'])],
      );
      final DynamicProvider p = DynamicProvider.spec('articles', spec);
      await db.open([p]);
      await p.saveAll([for (int i = 1; i <= 6; i++) p.row({'id': i, 'title': 'apple pie $i', 'n': i})]);
      await p.save(p.row({'id': 7, 'title': 'banana', 'n': 7}));
      expect(await p.search('apple', orderBy: 'id'), hasLength(6));
      expect([for (final DynamicModel m in await p.search('apple', orderBy: 'id', limit: 2, offset: 1)) m['id']], [2, 3]);
      expect([for (final DynamicModel m in await p.search('apple', where: FluentFilter.gt('n', 3), orderBy: 'id', limit: 2)) m['id']], [4, 5]);
      expect(await p.search('apple', limit: 3, offset: 5), hasLength(1));
      expect(await p.search('banana'), hasLength(1));
      expect(await p.search('zebra'), isEmpty);
    });
  });

  group('writes that touch deletedAt', () {
    test('a deletedAt set by hand on a live row is ignored, cleared on the model and reported once', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      final Doc doc = Doc(id: 1, title: 'a')..deletedAt = DateTime.utc(2020);
      final FluentSaveResult r = await docs.save(doc);
      expect(r.inserted, 1);
      expect(doc.deletedAt, isNull);
      expect(await docs.count(), 1, reason: 'the row is live');
      final FluentIssue issue = db.issues.firstWhere((FluentIssue i) => i.kind == FluentIssueKind.deletedAtIgnored);
      expect(issue.fix, contains('delete()'));
    });

    test('saving a trashed model restores it and does not report deletedAt', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      final Doc doc = Doc(id: 1, title: 'a');
      await docs.save(doc);
      await docs.delete(doc);
      expect(doc.deletedAt, isNotNull);
      final FluentSaveResult r = await docs.save(doc);
      expect(r.outcomes, [FluentRowOutcome.restored]);
      expect(doc.deletedAt, isNull);
      expect(db.issues.where((FluentIssue i) => i.kind == FluentIssueKind.deletedAtIgnored), isEmpty);
    });

    test('updateOnly / patch with a model that has no key yet are skipped, upsert inserts', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      expect((await docs.save(Doc(title: 'a'), strategy: FluentSaveStrategy.updateOnly)).outcomes, [FluentRowOutcome.skipped]);
      expect((await docs.save(Doc(title: 'a'), strategy: FluentSaveStrategy.patch)).outcomes, [FluentRowOutcome.skipped]);
      expect(await docs.count(), 0);
      expect((await docs.save(Doc(title: 'a'))).outcomes, [FluentRowOutcome.inserted]);
    });
  });

  group('restore under a deleted owner', () {
    test('saving a trashed child whose owner is still in the trash leaves it trashed (skipped)', () async {
      final OwnerProvider owners = OwnerProvider();
      final PartProvider parts = PartProvider();
      await db.open([owners, parts]);
      final Owner owner = Owner(name: 'o', parts: [Part(label: 'p1'), Part(label: 'p2')]);
      await owners.save(owner);
      await owners.delete(owner);
      expect(await parts.count(), 0);
      final Part child = (await parts.trash.find(orderBy: 'id')).first;
      final FluentSaveResult r = await parts.save(Part(id: child.id, label: 'edited'));
      expect(r.outcomes, [FluentRowOutcome.skipped]);
      expect(await parts.count(), 0, reason: 'the owner is still deleted');
      await owners.trash.restore(owner);
      expect((await parts.findAll(orderBy: 'id')).map((Part p) => p.label), ['p1', 'p2'], reason: 'restoring the owner brings the children back');
    });

    test('a child trashed on its own can be restored by saving it while its owner is live', () async {
      final OwnerProvider owners = OwnerProvider();
      final PartProvider parts = PartProvider();
      await db.open([owners, parts]);
      await owners.save(Owner(name: 'o', parts: [Part(label: 'p1')]));
      final Part child = (await parts.findAll()).single;
      await parts.delete(child);
      expect(await parts.count(), 0);
      final FluentSaveResult r = await parts.save(Part(id: child.id, label: 'back'));
      expect(r.outcomes, [FluentRowOutcome.restored]);
      expect((await parts.findAll()).single.label, 'back');
    });
  });

  group('hydration of loaded relations', () {
    test('a child that fromCacheJson cannot build leaves the relation unloaded and reports it; the owner is still returned', () async {
      final OwnerProvider owners = OwnerProvider();
      final PartProvider parts = PartProvider();
      await db.open([owners, parts]);
      await owners.save(Owner(name: 'o', parts: [Part(label: 'ok'), Part(label: 'boom')]));
      final Owner found = (await owners.findAll()).single;
      expect(found.name, 'o');
      expect(found.isRelationLoaded('parts'), isFalse);
      await db.settle();
      final FluentIssue issue = db.issues.firstWhere((FluentIssue i) => i.kind == FluentIssueKind.relationLoadFailed);
      expect(issue.title, contains('"parts"'));
      expect(issue.error, isA<FluentSchemaException>().having((FluentSchemaException e) => e.message, 'message', contains('Building Part')));
      expect((await owners.findAll(relations: FluentLoad.none)).single.name, 'o');
      expect((await parts.find(where: FluentFilter.eq('label', 'ok'))).single.label, 'ok');
      await expectLater(parts.findAll(), throwsA(isA<FluentSchemaException>().having((e) => e.message, 'message', contains('Building Part')).having((e) => e.cause, 'cause', isA<StateError>())));
    });
  });

  group('columns checks', () {
    test('findMaps / pluck refuse an empty column list and unknown columns with the list of valid ones', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      await expectLater(docs.findMaps(columns: []), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('Pass the columns'))));
      await expectLater(docs.findMaps(columns: ['nope']), throwsA(isA<FluentArgumentException>()));
      await expectLater(docs.pluck<int>('nope'), throwsA(isA<FluentArgumentException>()));
    });
  });
}
