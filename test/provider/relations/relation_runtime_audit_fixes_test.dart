// Regression tests for the relation runtime audit findings (RR-1 .. RR-4, PC-2, PC-4, DOC-6).
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart' as rm;

// ---- RR-1 / RR-2: limited and includeDeleted lists -------------------------------------------------------------

class Owner extends FluentStorable with FluentRelations {
  Owner({this.id, required this.name, this.firstTwo, this.anyOne, this.everything});

  final int? id;
  final String name;
  final List<Row>? firstTwo;
  final List<Row>? anyOne;
  final List<Row>? everything;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<Owner, Row>('firstTwo', (o) => o.firstTwo, foreignKey: 'owner_id', orderBy: 'id', limit: 2),
    FluentRelation.many<Owner, Row>('anyOne', (o) => o.anyOne, foreignKey: 'owner_id', limit: 1),
    FluentRelation.many<Owner, Row>('everything', (o) => o.everything, foreignKey: 'owner_id', orderBy: 'id', includeDeleted: true),
  ];
}

class Row extends FluentStorable with FluentSoftDeletable {
  Row({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class OwnerProvider extends FluentProvider<Owner> {
  @override
  String get tableName => 'fx_owners';

  @override
  Owner get modelSample => Owner(name: '');

  @override
  Owner fromCacheJson(Map<String, dynamic> json) => Owner(
    id: json['id'] as int?,
    name: json['name'] as String,
    firstTwo: (json['firstTwo'] as List?)?.cast<Row>(),
    anyOne: (json['anyOne'] as List?)?.cast<Row>(),
    everything: (json['everything'] as List?)?.cast<Row>(),
  );
}

class RowProvider extends FluentProvider<Row> {
  @override
  String get tableName => 'fx_rows';

  @override
  Row get modelSample => Row(text: '');

  @override
  Row fromCacheJson(Map<String, dynamic> json) => Row(id: json['id'] as int?, text: json['text'] as String);
}

// WITHOUT ROWID children (text key, supplied by the app).
class KOwner extends FluentStorable with FluentRelations {
  KOwner({required this.id, this.noOrder, this.ordered});

  final String id;
  final List<KRow>? noOrder;
  final List<KRow>? ordered;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn(name: 'id', type: FluentDbDataType.text, isPrimaryKey: true)];

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<KOwner, KRow>('noOrder', (o) => o.noOrder, foreignKey: 'owner_id', limit: 2),
    FluentRelation.many<KOwner, KRow>('ordered', (o) => o.ordered, foreignKey: 'owner_id', orderBy: 'label DESC', limit: 2),
  ];
}

class KRow extends FluentStorable {
  KRow({required this.code, required this.label});

  final String code;
  final String label;

  @override
  bool get withoutRowId => true;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true)];

  @override
  Map<String, dynamic> buildJson() => {'code': code, 'label': label};
}

class KOwnerProvider extends FluentProvider<KOwner> {
  @override
  String get tableName => 'fx_kowners';

  @override
  KOwner get modelSample => KOwner(id: '');

  @override
  KOwner fromCacheJson(Map<String, dynamic> json) =>
      KOwner(id: json['id'] as String, noOrder: (json['noOrder'] as List?)?.cast<KRow>(), ordered: (json['ordered'] as List?)?.cast<KRow>());
}

class KRowProvider extends FluentProvider<KRow> {
  @override
  String get tableName => 'fx_krows';

  @override
  KRow get modelSample => KRow(code: '', label: '');

  @override
  KRow fromCacheJson(Map<String, dynamic> json) => KRow(code: json['code'] as String, label: json['label'] as String);
}

// Composite owner key.
class COwner extends FluentStorable with FluentRelations {
  COwner({required this.region, required this.code, this.noOrder, this.ordered, this.ordered_ = false});

  final bool ordered_;

  final String region;
  final int code;
  final List<CRow>? noOrder;
  final List<CRow>? ordered;

  @override
  Map<String, dynamic> buildJson() => {'region': region, 'code': code};

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('region'), FluentDbColumn.integer('code')];

  @override
  List<FluentRelation> get relations => [
    if (ordered_) FluentRelation.many<COwner, CRow>('ordered', (o) => o.ordered, orderBy: 'id DESC', limit: 1) else FluentRelation.many<COwner, CRow>('noOrder', (o) => o.noOrder, limit: 1),
  ];
}

class CRow extends FluentStorable {
  CRow({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class COwnerProvider extends FluentProvider<COwner> {
  COwnerProvider({this.ordered = false});

  final bool ordered;

  @override
  String get tableName => 'fx_cowners';

  @override
  COwner get modelSample => COwner(region: '', code: 0, ordered_: ordered);

  @override
  COwner fromCacheJson(Map<String, dynamic> json) => COwner(
    region: json['region'] as String,
    code: json['code'] as int,
    noOrder: (json['noOrder'] as List?)?.cast<CRow>(),
    ordered: (json['ordered'] as List?)?.cast<CRow>(),
  );
}

class CRowProvider extends FluentProvider<CRow> {
  @override
  String get tableName => 'fx_crows';

  @override
  CRow get modelSample => CRow(text: '');

  @override
  CRow fromCacheJson(Map<String, dynamic> json) => CRow(id: json['id'] as int?, text: json['text'] as String);
}

// ---- PC-2: many-to-many between soft-deletable models ----------------------------------------------------------

class Doc extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Doc({this.id, required this.title, this.labels});

  final int? id;
  final String title;
  final List<Label>? labels;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.manyToMany<Doc, Label>('labels', (d) => d.labels, orderBy: 'name')];
}

class Label extends FluentStorable with FluentSoftDeletable {
  Label({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'fx_docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String, labels: (json['labels'] as List?)?.cast<Label>());
}

class LabelProvider extends FluentProvider<Label> {
  @override
  String get tableName => 'fx_labels';

  @override
  Label get modelSample => Label(name: '');

  @override
  Label fromCacheJson(Map<String, dynamic> json) => Label(id: json['id'] as int?, name: json['name'] as String);
}

void main() {
  setUpFluentTests();

  group('RR-1 / RR-2: limited and includeDeleted lists', () {
    late FluentTestDb db;
    late OwnerProvider owners;
    late RowProvider rows;

    setUp(() async {
      db = FluentTestDb(name: 'fx_rr_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      owners = OwnerProvider();
      rows = RowProvider();
      await db.open([owners, rows]);
    });

    tearDown(() => db.close());

    test('RR-1: limited lists with and without orderBy load, in both orders, for several owners', () async {
      await owners.save(Owner(name: 'A', firstTwo: [Row(text: 'a1'), Row(text: 'a2'), Row(text: 'a3')]));
      await owners.save(Owner(name: 'B', firstTwo: [Row(text: 'b1'), Row(text: 'b2'), Row(text: 'b3')]));

      final List<Owner> loaded = await owners.findAll(orderBy: 'id');
      expect(loaded.map((o) => o.firstTwo?.map((r) => r.text).toList()).toList(), [
        ['a1', 'a2'],
        ['b1', 'b2'],
      ]);
      expect(loaded.map((o) => o.anyOne?.map((r) => r.text).toList()).toList(), [
        ['a1'],
        ['b1'],
      ], reason: 'limit 1 by rowid');
      // The other order: the list without orderBy first.
      final Owner full = await owners.loadRelations(loaded.first, names: ['anyOne', 'firstTwo']);
      expect(full.anyOne?.map((r) => r.text), ['a1']);
      expect(full.firstTwo?.map((r) => r.text), ['a1', 'a2']);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
    });

    test('RR-1: a failure that is not about window functions does not switch the window path off', () async {
      await owners.save(Owner(name: 'A', firstTwo: [Row(text: 'a1'), Row(text: 'a2'), Row(text: 'a3')]));
      // A first successful windowed read, then a broken table makes the next one fail with a real error.
      expect((await owners.findAll()).single.firstTwo, hasLength(2));
      await owners.db.execute('ALTER TABLE "fx_rows" RENAME TO "fx_rows_x"');
      final List<Owner> broken = await owners.findAll();
      expect(broken.single.firstTwo, isNull, reason: 'the failing relation is left unloaded (and reported)');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.relationLoadFailed));
      await owners.db.execute('ALTER TABLE "fx_rows_x" RENAME TO "fx_rows"');
      // The window path still works afterwards (not disabled by the unrelated error).
      expect((await owners.findAll()).single.firstTwo?.map((r) => r.text), ['a1', 'a2']);
    });

    test('RR-2: includeDeleted keeps trashed children on load, like findRelated', () async {
      await owners.save(Owner(name: 'A', firstTwo: [Row(text: 'live'), Row(text: 'trashed')]));
      await rows.deleteWhere(FluentFilter.eq('text', 'trashed'));

      final Owner owner = (await owners.findAll()).single;
      expect(owner.everything?.map((r) => r.text), ['live', 'trashed']);
      expect(owner.firstTwo?.map((r) => r.text), ['live']);
      expect((await owners.findRelated<Row>(owner, 'everything')).map((r) => r.text), ['live', 'trashed']);
      expect(await owners.countRelated(owner, 'everything'), 2);
    });
  });

  group('RR-1: WITHOUT ROWID children and composite owners', () {
    test('limited lists with and without orderBy on a WITHOUT ROWID table', () async {
      final FluentTestDb db = FluentTestDb(name: 'fx_rr_k_${DateTime.now().microsecondsSinceEpoch}');
      final KOwnerProvider owners = KOwnerProvider();
      await db.open([owners, KRowProvider()]);
      addTearDown(db.close);
      await owners.save(KOwner(id: 'o1', noOrder: [KRow(code: 'c', label: 'x'), KRow(code: 'a', label: 'z'), KRow(code: 'b', label: 'y')]));
      final KOwner o = (await owners.findAll()).single;
      expect(o.noOrder?.map((r) => r.code), ['a', 'b'], reason: 'ordered by the key');
      expect(o.ordered?.map((r) => r.label), ['z', 'y'], reason: 'label DESC');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
    });

    for (final bool ordered in [false, true]) {
      test('limited list of a composite owner (${ordered ? 'with' : 'without'} orderBy)', () async {
        final FluentTestDb db = FluentTestDb(name: 'fx_rr_c_${DateTime.now().microsecondsSinceEpoch}');
        final COwnerProvider owners = COwnerProvider(ordered: ordered);
        await db.open([owners, CRowProvider()]);
        addTearDown(db.close);
        List<CRow> two(String a, String b) => [CRow(text: a), CRow(text: b)];
        await owners.save(ordered ? COwner(region: 'eu', code: 1, ordered: two('a', 'b')) : COwner(region: 'eu', code: 1, noOrder: two('a', 'b')));
        await owners.save(ordered ? COwner(region: 'us', code: 1, ordered: two('c', 'd')) : COwner(region: 'us', code: 1, noOrder: two('c', 'd')));
        final List<COwner> loaded = await owners.findAll(orderBy: 'region');
        final List<List<String>> texts = [for (final COwner o in loaded) [for (final CRow r in (ordered ? o.ordered : o.noOrder) ?? <CRow>[]) r.text]];
        expect(texts, ordered ? [['b'], ['d']] : [['a'], ['c']]);
      });
    }
  });

  group('PC-2: relation reads ignore the trash scope', () {
    test('trash.find loads live labels of a many-to-many link', () async {
      final FluentTestDb db = FluentTestDb(name: 'fx_pc2_${DateTime.now().microsecondsSinceEpoch}');
      final DocProvider docs = DocProvider();
      final LabelProvider labels = LabelProvider();
      await db.open([docs, labels]);
      addTearDown(db.close);
      await docs.save(Doc(title: 'D', labels: [Label(name: 'live'), Label(name: 'gone')]));
      await labels.deleteWhere(FluentFilter.eq('name', 'gone'));
      final Doc doc = (await docs.findAll()).single;
      await docs.delete(doc);

      final Doc trashed = (await docs.trash.find()).single;
      expect(trashed.labels?.map((l) => l.name), ['live']);
      final Doc viaAll = (await docs.withTrash.find()).single;
      expect(viaAll.labels?.map((l) => l.name), ['live']);
    });
  });

  group('RR-3: argument count', () {
    test('fewer arguments than placeholders with a related condition is a FluentArgumentException', () async {
      final FluentTestDb db = FluentTestDb(name: 'fx_rr3_${DateTime.now().microsecondsSinceEpoch}');
      final List<FluentProvider> providers = rm.relationProviders();
      await db.open(providers);
      addTearDown(db.close);
      final rm.ArticleProvider articles = providers.whereType<rm.ArticleProvider>().single;
      final FluentFilter bad = const FluentFilter('"title" = ? AND "id" > ?', ['A']).and(FluentFilter.related('comments'));
      await expectLater(articles.find(where: bad), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotEmpty)));
    });
  });

  group('RR-4: countRelated of a oneOf relation', () {
    test('a oneOf relation has no where: count, load and filter agree', () {
      // The oneOf factory takes no where / orderBy / limit; a load reads the target by key only
      // (applyListOptions: false), and the relation filter ignores it too. The count does the same.
      final FluentRelation<Owner, FluentStorable> relation = FluentRelation.oneOf<Owner>('x', (o) => null, types: [Row]);
      expect(relation.where, isNull);
      final String reader = File('lib/src/core/fluent_provider/parts/relations/fluent_relation_reader.dart').readAsStringSync();
      expect(reader, contains('applyListOptions: false'));
    });
  });

  group('PC-4: unchunked key lists', () {
    late FluentTestDb db;
    late OwnerProvider owners;
    late RowProvider rows;

    setUp(() async {
      db = FluentTestDb(name: 'fx_pc4_${DateTime.now().microsecondsSinceEpoch}');
      owners = OwnerProvider();
      rows = RowProvider();
      await db.open([owners, rows]);
    });

    tearDown(() => db.close());

    test('detach of an owned list removes thousands of children in chunks', () async {
      await owners.save(Owner(name: 'A', everything: [for (int i = 0; i < 2000; i++) Row(text: 'r$i')]));
      final Owner owner = (await owners.findAll(relations: FluentLoad.none)).single;
      final List<Row> all = await rows.findAll();
      expect(all, hasLength(2000));
      await owners.detach(owner, 'everything', all);
      expect(await rows.count(), 0);
    });

    test('detach of a many-to-many list removes thousands of links in chunks', () async {
      final FluentTestDb db2 = FluentTestDb(name: 'fx_pc4m_${DateTime.now().microsecondsSinceEpoch}');
      final DocProvider docs = DocProvider();
      final LabelProvider labels = LabelProvider();
      await db2.open([docs, labels]);
      addTearDown(db2.close);
      await docs.save(Doc(title: 'D', labels: [for (int i = 0; i < 2000; i++) Label(name: 'l$i')]));
      final Doc doc = (await docs.findAll(relations: FluentLoad.none)).single;
      final List<Label> all = await labels.findAll();
      expect(await docs.countRelated(doc, 'labels'), 2000);
      await docs.detach(doc, 'labels', all);
      expect(await docs.countRelated(doc, 'labels'), 0);
      expect(await labels.count(), 2000, reason: 'the labels stay');
    });

    test('FluentFilter.ids with more keys than one statement binds is accepted (no chunking by the caller)', () async {
      final List<int> many = [for (int i = 1; i <= 5000; i++) i];
      expect(await rows.count(where: FluentFilter.ids(many)), 0);
      expect(await rows.count(where: FluentFilter.ids([1, 2, 3])), 0);
    });
  });

  group('DOC-6: internal parts of FluentFilter', () {
    test('the deferred conditions and the marker are not public members', () {
      final String src = File('lib/src/utils/fluent_filter.dart').readAsStringSync();
      expect(RegExp(r'^\s+final List<FluentDeferredCondition> deferred;', multiLine: true).hasMatch(src), isFalse);
      expect(RegExp(r'^\s+static final RegExp relatedMarker', multiLine: true).hasMatch(src), isFalse);
      expect(File('lib/fluent_sqflite.dart').readAsStringSync(), contains('FluentFilterInternals'));
    });

    test('the library still reads them through the internal extension', () {
      expect(FluentFilter.related('x').deferred, hasLength(1));
      expect(FluentFilter.eq('a', 1).deferred, isEmpty);
      expect(FluentFilterInternals.marker.hasMatch(FluentFilter.related('x').whereClause), isTrue);
    });
  });
}
