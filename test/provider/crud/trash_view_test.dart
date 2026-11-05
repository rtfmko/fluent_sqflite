// withTrash: every read of FluentWithTrash sees live and trashed rows, with all its parameters.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Item extends FluentStorable with FluentSoftDeletable {
  Item({this.id, required this.title, this.score, this.group = 'a'});

  final int? id;
  final String title;
  final int? score;
  final String group;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'score': score, 'grp': group};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('title'), FluentDbColumn.integer('score'), FluentDbColumn.text('grp')];
}

class ItemProvider extends FluentProvider<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item(title: '');

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, title: json['title'] as String, score: json['score'] as int?, group: json['grp'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ItemProvider items;

  setUp(() async {
    db = FluentTestDb(name: 'trashview_${DateTime.now().microsecondsSinceEpoch}');
    items = ItemProvider();
    await db.open([items]);
    // live: 1 (score 10, a), 2 (score 20, b); trashed: 3 (score 30, a), 4 (score 40, b)
    await items.saveAll([
      Item(id: 1, title: 'one', score: 10),
      Item(id: 2, title: 'two', score: 20, group: 'b'),
      Item(id: 3, title: 'three', score: 30),
      Item(id: 4, title: 'four', score: 40, group: 'b'),
    ]);
    await items.deleteWhere(FluentFilter.inList('id', [3, 4]));
  });

  tearDown(() => db.close());

  test('plain reads hide the trashed rows, withTrash shows them (find with where / orderBy / limit / offset)', () async {
    expect([for (final Item i in await items.find(orderBy: 'id')) i.id], [1, 2]);
    expect([for (final Item i in await items.withTrash.find(orderBy: 'id')) i.id], [1, 2, 3, 4]);
    expect([for (final Item i in await items.withTrash.find(where: FluentFilter.eq('grp', 'a'), orderBy: 'id')) i.id], [1, 3]);
    expect([for (final Item i in await items.withTrash.find(orderBy: 'id', limit: 2, offset: 1)) i.id], [2, 3]);
    expect([for (final Item i in await items.withTrash.findAll(orderBy: 'id', limit: 3)) i.id], [1, 2, 3]);
    expect([for (final Item i in await items.withTrash.findByIds([2, 4])) i.id]..sort(), [2, 4]);
    expect((await items.withTrash.findById(3))?.title, 'three');
    expect(await items.findById(3), isNull);
  });

  test('withTrash.findFirst honours where and orderBy', () async {
    expect((await items.withTrash.findFirst(where: FluentFilter.eq('grp', 'b'), orderBy: 'score DESC'))?.id, 4);
    expect(await items.withTrash.findFirst(where: FluentFilter.eq('grp', 'zzz')), isNull);
  });

  test('withTrash.findPage walks live and trashed rows by key, ascending and descending', () async {
    final FluentPage<Item> first = await items.withTrash.findPage(limit: 3);
    expect([for (final Item i in first.items) i.id], [1, 2, 3]);
    final FluentPage<Item> second = await items.withTrash.findPage(limit: 3, after: first.next);
    expect([for (final Item i in second.items) i.id], [4]);
    expect(second.next, isNull);
    final FluentPage<Item> desc = await items.withTrash.findPage(descending: true, orderBy: 'score', limit: 2, where: FluentFilter.gt('score', 10));
    expect([for (final Item i in desc.items) i.id], [4, 3]);
    expect([for (final Item i in (await items.findPage(limit: 5)).items) i.id], [1, 2], reason: 'the plain page hides the trash');
  });

  test('count / exists / existsWhere see the trash through withTrash only', () async {
    expect(await items.count(), 2);
    expect(await items.withTrash.count(), 4);
    expect(await items.withTrash.count(where: FluentFilter.eq('grp', 'b')), 2);
    expect(await items.exists(3), isFalse);
    expect(await items.withTrash.exists(3), isTrue);
    expect(await items.existsWhere(FluentFilter.eq('title', 'four')), isFalse);
    expect(await items.withTrash.existsWhere(FluentFilter.eq('title', 'four')), isTrue);
    expect(await items.withTrash.existsWhere(FluentFilter.eq('title', 'nothing')), isFalse);
  });

  test('findMaps: columns, distinct, where, orderBy, limit and offset on the whole table', () async {
    final List<Map<String, dynamic>> maps = await items.withTrash.findMaps(columns: ['id', 'title'], orderBy: 'id', limit: 2, offset: 1);
    expect(maps, [
      {'id': 2, 'title': 'two'},
      {'id': 3, 'title': 'three'},
    ]);
    final List<Map<String, dynamic>> groups = await items.withTrash.findMaps(columns: ['grp'], distinct: true, orderBy: 'grp');
    expect(groups, [
      {'grp': 'a'},
      {'grp': 'b'},
    ]);
    expect(await items.withTrash.findMaps(columns: ['id'], where: FluentFilter.eq('grp', 'a'), orderBy: 'id'), [
      {'id': 1},
      {'id': 3},
    ]);
    expect(await items.findMaps(columns: ['id'], orderBy: 'id'), hasLength(2));
  });

  test('pluck and countDistinct pass all their parameters', () async {
    expect(await items.withTrash.pluck<int>('score', orderBy: 'score DESC', limit: 2, offset: 1), [30, 20]);
    expect(await items.withTrash.pluck<String>('grp', distinct: true, orderBy: 'grp'), ['a', 'b']);
    expect(await items.withTrash.pluck<int>('id', where: FluentFilter.eq('grp', 'a'), orderBy: 'id'), [1, 3]);
    expect(await items.withTrash.countDistinct('grp'), 2);
    expect(await items.withTrash.countDistinct('score', where: FluentFilter.gt('score', 10)), 3);
  });

  test('sum / avg / min / max over live and trashed rows, with where', () async {
    expect(await items.sum('score'), 30);
    expect(await items.withTrash.sum('score'), 100);
    expect(await items.withTrash.sum('score', where: FluentFilter.eq('grp', 'b')), 60);
    expect(await items.withTrash.avg('score'), 25.0);
    expect(await items.withTrash.avg('score', where: FluentFilter.eq('grp', 'a')), 20.0);
    expect(await items.withTrash.min<int>('score'), 10);
    expect(await items.withTrash.min<int>('score', where: FluentFilter.gt('score', 15)), 20);
    expect(await items.withTrash.max<int>('score'), 40);
    expect(await items.withTrash.max<int>('score', where: FluentFilter.eq('grp', 'a')), 30);
    expect(await items.withTrash.avg('score', where: FluentFilter.eq('grp', 'zzz')), isNull);
    expect(await items.withTrash.max<int>('score', where: FluentFilter.eq('grp', 'zzz')), isNull);
  });

  test('aggregate groups the whole table, with having / orderBy / limit', () async {
    final List<Map<String, dynamic>> rows = await items.withTrash.aggregate(
      values: {'n': const FluentAggregate.count(), 'total': const FluentAggregate.sum('score')},
      groupBy: ['grp'],
      orderBy: 'grp',
    );
    expect(rows, [
      {'grp': 'a', 'n': 2, 'total': 40},
      {'grp': 'b', 'n': 2, 'total': 60},
    ]);
    final List<Map<String, dynamic>> big = await items.withTrash.aggregate(
      values: {'total': const FluentAggregate.sum('score')},
      groupBy: ['grp'],
      having: FluentFilter.gt('total', 50),
      orderBy: 'grp',
      limit: 1,
    );
    expect(big, [
      {'grp': 'b', 'total': 60},
    ]);
    final List<Map<String, dynamic>> live = await items.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['grp'], where: FluentFilter.eq('grp', 'a'));
    expect(live, [
      {'grp': 'a', 'n': 1},
    ]);
  });

  test('FluentDb.withTrash resolves the provider per call', () async {
    expect(await FluentDb.withTrash<Item>().count(), 4);
    expect(await FluentDb.withTrash<Item>().sum('score'), 100);
    expect(await FluentDb.trash<Item>().count(), 2);
  });
}
