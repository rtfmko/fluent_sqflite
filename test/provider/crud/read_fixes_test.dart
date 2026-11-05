// Read-path fixes: collapsed reads keyed by every value of a filter, filter values converted per column like on save,
// aggregate orderBy checks, read-only rawQuery, LIKE escaping, merged / chunked key lookups, placeholders inside
// string literals, per-row type tags of min / max / distinct projections.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';
import '../../helpers/schema_models.dart';

enum Level { low, mid, high }

/// A converted (epoch) column in an ISO table, enum-by-index and timestamp columns: every way a filter value must be stored like on save.
class Event extends FluentStorable with FluentTimestamps {
  Event({this.id, required this.title, required this.at, required this.day, this.level = Level.low});

  final int? id;
  final String title;
  final DateTime at;
  final DateTime day;
  final Level level;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601, storeEnumsAsNames: false);

  @override
  Map<String, List<Enum>> get enumValues => {'level': Level.values};

  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.converted('at', const FluentEpochDateTimeConverter())];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'at': at, 'day': day, 'level': level};
}

class EventProvider extends FluentProvider<Event> {
  @override
  String get tableName => 'events';

  @override
  Event get modelSample => Event(title: '', at: DateTime(2000), day: DateTime(2000));

  @override
  Event fromCacheJson(Map<String, dynamic> json) =>
      Event(id: json['id'] as int?, title: json['title'] as String, at: json['at'] as DateTime, day: json['day'] as DateTime, level: json['level'] as Level);
}

/// A plain table (default settings) with a local DateTime column.
class Item extends FluentStorable {
  Item({this.id, required this.title, required this.when, this.n = 0});

  final int? id;
  final String title;
  final DateTime when;
  final int n;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'when': when, 'n': n};
}

class ItemProvider extends FluentProvider<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item(title: '', when: DateTime(2000));

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, title: json['title'] as String, when: json['when'] as DateTime, n: json['n'] as int);
}

class Doc extends FluentStorable {
  Doc({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentIndex> get indexes => const [FluentIndex.fullText(['title'])];
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String);
}

DynamicProvider pairs() => DynamicProvider.spec(
  'pairs',
  TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b'), FluentDbColumn.text('label')], keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')]),
);

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('collapsed reads (R1)', () {
    late ItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_collapse_${DateTime.now().microsecondsSinceEpoch}');
      items = ItemProvider();
      await db.open([items]);
      await items.saveAll([Item(title: 'a', when: DateTime(2020)), Item(title: 'b', when: DateTime(2021))]);
    });

    test('findByIds with different ids at once get their own rows', () async {
      final List<List<Item>> found = await Future.wait([items.findByIds([1]), items.findByIds([2])]);
      expect(found.map((l) => l.map((i) => i.title).toList()), [['a'], ['b']]);
    });

    test('count, findMaps and find with different ids', () async {
      final List<int> counts = await Future.wait([items.count(where: FluentFilter.ids([1])), items.count(where: FluentFilter.ids([1, 2]))]);
      expect(counts, [1, 2]);
      final List<List<Map<String, dynamic>>> maps = await Future.wait([
        items.findMaps(where: FluentFilter.ids([1]), columns: ['title']),
        items.findMaps(where: FluentFilter.ids([2]), columns: ['title']),
      ]);
      expect(maps, [[{'title': 'a'}], [{'title': 'b'}]]);
    });

    test('ids of different types and nested and / or keep their values', () async {
      final List<List<Item>> found = await Future.wait([
        items.find(where: FluentFilter.eq('n', 0).and(FluentFilter.ids([1]).or(FluentFilter.ids([1])))),
        items.find(where: FluentFilter.eq('n', 0).and(FluentFilter.ids([2]).or(FluentFilter.ids([2])))),
        items.find(where: FluentFilter.ids(['2'])),
      ]);
      expect(found.map((l) => l.map((i) => i.title).toList()), [['a'], ['b'], ['b']]);
    });

    test('fingerprints of deferred conditions hold every value', () {
      expect(const FluentKeyCondition([1]).fingerprint, isNot(const FluentKeyCondition([2]).fingerprint));
      expect(const FluentKeyCondition([1]).fingerprint, isNot(const FluentKeyCondition(['1']).fingerprint));
      expect(const FluentSearchCondition('a').fingerprint, isNot(const FluentSearchCondition('b').fingerprint));
      expect(const FluentSearchCondition('a').fingerprint, isNot(const FluentSearchCondition('a', prefix: false).fingerprint));
      String related(FluentFilter f) => (f.deferred.single as FluentRelatedCondition).fingerprint;
      expect(related(FluentFilter.related('x', FluentFilter.eq('n', 1))), isNot(related(FluentFilter.related('x', FluentFilter.eq('n', 2)))));
      expect(related(FluentFilter.related('x', FluentFilter.ids([1]))), isNot(related(FluentFilter.related('x', FluentFilter.ids([2])))));
      expect(related(FluentFilter.relatedCount('x', min: 1)), isNot(related(FluentFilter.relatedCount('x', min: 2))));
      expect(related(FluentFilter.related('x')), isNot(related(FluentFilter.notRelated('x'))));
      // Logs keep the redacted form.
      expect(const FluentSearchCondition('secret').toString(), 'search(?)');
    });
  });

  test('collapsed search reads (R1)', () async {
    db = FluentTestDb(name: 'read_fixes_search_${DateTime.now().microsecondsSinceEpoch}');
    final DocProvider docs = DocProvider();
    await db.open([docs]);
    await docs.saveAll([Doc(title: 'apple pie'), Doc(title: 'banana bread')]);
    final List<List<Doc>> found = await Future.wait([docs.find(where: FluentFilter.search('apple')), docs.find(where: FluentFilter.search('banana'))]);
    expect(found.map((l) => l.map((d) => d.title).toList()), [['apple pie'], ['banana bread']]);
  });

  test('collapsed related reads (R1)', () async {
    db = FluentTestDb(name: 'read_fixes_related_${DateTime.now().microsecondsSinceEpoch}');
    final List<FluentProvider> providers = relationProviders();
    await db.open(providers);
    final ArticleProvider articles = providers.whereType<ArticleProvider>().single;
    await articles.saveAll([Article(title: 'A', author: Person(name: 'Ann')), Article(title: 'B', author: Person(name: 'Bob'))]);
    final List<List<Article>> found = await Future.wait([
      articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann'))),
      articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Bob'))),
    ]);
    expect(found.map((l) => l.map((a) => a.title).toList()), [['A'], ['B']]);
    final List<int> counts = await Future.wait([
      articles.count(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann'))),
      articles.count(where: FluentFilter.related('author', FluentFilter.eq('name', 'Nobody'))),
    ]);
    expect(counts, [1, 0]);
  });

  group('filter values converted per column (R4)', () {
    late EventProvider events;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_convert_${DateTime.now().microsecondsSinceEpoch}');
      events = EventProvider();
      await db.open([events]);
      await events.saveAll([
        Event(title: 'early', at: DateTime.utc(2020), day: DateTime(2020)),
        Event(title: 'late', at: DateTime.utc(2024, 6), day: DateTime(2024), level: Level.high),
      ]);
    });

    Future<List<String>> titles(FluentFilter where) async => [for (final Event e in await events.find(where: where, orderBy: 'id')) e.title];

    test('a column with a converter (epoch ms in an ISO table)', () async {
      expect((await events.db.query('events', orderBy: 'id')).first['at'], DateTime.utc(2020).millisecondsSinceEpoch);
      expect(await titles(FluentFilter.gt('at', DateTime.utc(2022))), ['late']);
      expect(await titles(FluentFilter.between('at', DateTime.utc(2019), DateTime.utc(2021))), ['early']);
      expect(await titles(FluentFilter.eq('at', DateTime.utc(2020))), ['early']);
    });

    test('a value-kind column with the table dateTimeFormat (ISO)', () async {
      expect(await titles(FluentFilter.gte('day', DateTime(2023))), ['late']);
      expect(await titles(FluentFilter.lt('day', DateTime(2023))), ['early']);
    });

    test('an enum stored by index (storeEnumsAsNames: false)', () async {
      expect(await titles(FluentFilter.eq('level', Level.high)), ['late']);
      expect(await titles(FluentFilter.inList('level', [Level.low, Level.mid])), ['early']);
      expect(await titles(FluentFilter.notInList('level', [Level.low])), ['late']);
      expect(await titles(FluentFilter.notEq('level', Level.low)), ['late']);
      expect(await titles(FluentFilter.eq('level', 2)), ['late'], reason: 'a stored value is used as it is');
    });

    test('timestamp columns are compared as epoch milliseconds', () async {
      final DateTime past = DateTime.now().subtract(const Duration(days: 1));
      expect(await titles(FluentFilter.gt('created_at', past)), ['early', 'late']);
      expect(await titles(FluentFilter.lt('updated_at', past)), isEmpty);
    });

    test('count, exists, findMaps, aggregate, updateWhere, deleteWhere and watch convert alike', () async {
      final FluentFilter late = FluentFilter.gt('at', DateTime.utc(2022));
      expect(await events.count(where: late), 1);
      expect(await events.existsWhere(FluentFilter.eq('level', Level.mid)), isFalse);
      expect(await events.existsWhere(FluentFilter.eq('level', Level.high)), isTrue);
      expect(await events.findMaps(where: late, columns: ['title']), [{'title': 'late'}]);
      expect(await events.aggregate(values: {'n': const FluentAggregate.count()}, where: late), [{'n': 1}]);
      final List<Map<String, dynamic>> byLevel = await events.aggregate(
        groupBy: ['level'],
        values: {'n': const FluentAggregate.count()},
        having: FluentFilter.eq('level', Level.high),
      );
      expect(byLevel, [{'level': Level.high, 'n': 1}]);
      final List<int> watched = [];
      final StreamSubscription<List<Event>> sub = events.watch(where: late).listen((l) => watched.add(l.length));
      await db.settle();
      expect(await events.updateWhere(late, {'title': 'later'}), 1);
      expect(await titles(FluentFilter.eq('title', 'later')), ['later']);
      expect(await events.deleteWhere(FluentFilter.eq('level', Level.high)), 1);
      await db.settle();
      expect(watched.last, 0);
      await sub.cancel();
    });

    test('a hand-written FluentFilter uses the table settings', () async {
      expect(await titles(FluentFilter('"day" > ?', [DateTime(2023)])), ['late']);
      expect(const FluentFilter('"day" > ?', [true]).whereArgs, [1]);
    });

    test('FluentFilter keeps Dart values until a provider converts them', () {
      final FluentFilter f = FluentFilter.eq('level', Level.high).and(FluentFilter.gt('at', DateTime.utc(2022)));
      final FluentFilterArgs args = f.whereArgs as FluentFilterArgs;
      expect(args.raw, [Level.high, DateTime.utc(2022)]);
      expect(args.columns, ['level', 'at']);
      expect(f.whereArgs, ['high', DateTime.utc(2022).millisecondsSinceEpoch], reason: 'read directly: default settings');
    });
  });

  group('aggregate orderBy (R2)', () {
    late ItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_agg_${DateTime.now().microsecondsSinceEpoch}');
      items = ItemProvider();
      await db.open([items]);
      await items.saveAll([Item(title: 'a', when: DateTime(2020), n: 1), Item(title: 'a', when: DateTime(2021), n: 2), Item(title: 'b', when: DateTime(2021), n: 5)]);
    });

    test('result names order the groups', () async {
      final List<Map<String, dynamic>> rows = await items.aggregate(groupBy: ['title'], values: {'total': const FluentAggregate.sum('n')}, orderBy: 'total DESC');
      expect(rows, [{'title': 'b', 'total': 5}, {'title': 'a', 'total': 3}]);
      expect(await items.aggregate(groupBy: ['title'], values: {'total': const FluentAggregate.sum('n')}, orderBy: '"title" ASC, total'), hasLength(2));
    });

    test('SQL and unknown names are refused', () async {
      for (final String order in ['(SELECT 1)', 'total; DROP TABLE items', 'n', 'lower(title)', 'items.title']) {
        await expectLater(
          items.aggregate(groupBy: ['title'], values: {'total': const FluentAggregate.sum('n')}, orderBy: order),
          throwsA(isA<FluentArgumentException>()),
          reason: order,
        );
      }
    });
  });

  group('rawQuery is read-only (R3)', () {
    late ItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_raw_${DateTime.now().microsecondsSinceEpoch}');
      items = ItemProvider();
      await db.open([items]);
      await items.save(Item(title: 'a', when: DateTime(2020)));
    });

    test('writing statements are refused', () async {
      for (final String sql in [
        'WITH q AS (SELECT 1) DELETE FROM items',
        'with q(x) as materialized (select 1) insert into items(title) values (1)',
        'WITH RECURSIVE q AS (SELECT 1) UPDATE items SET n = 1',
        'WITH q AS (SELECT 1) REPLACE INTO items(id, title) VALUES (1, 2)',
        'PRAGMA user_version = 5',
        'PRAGMA main.user_version=5',
        'PRAGMA journal_mode(DELETE)',
        'PRAGMA optimize',
        'PRAGMA wal_checkpoint',
        'SELECT 1; DELETE FROM items',
        'DELETE FROM items',
      ]) {
        await expectLater(items.rawQuery(sql), throwsA(isA<FluentArgumentException>()), reason: sql);
      }
      expect(await items.count(), 1);
    });

    test('reading statements run', () async {
      expect(await items.rawQuery("SELECT 'DELETE; x = 1' AS t, replace(title, 'a', 'b') AS r FROM items"), [{'t': 'DELETE; x = 1', 'r': 'b'}]);
      expect(await items.rawQuery('WITH q AS (SELECT title AS "delete" FROM items) SELECT * FROM q'), [{'delete': 'a'}]);
      expect(await items.rawQuery('-- comment; DELETE\nSELECT 1 AS one; '), [{'one': 1}]);
      expect(await items.rawQuery('WITH q AS (VALUES (1)) VALUES (2)'), hasLength(1));
      expect(await items.rawQuery('PRAGMA table_info(items)'), isNotEmpty);
      expect(await items.rawQuery('PRAGMA main.table_info("items")'), isNotEmpty);
      expect(await items.rawQuery('PRAGMA user_version'), hasLength(1));
    });
  });

  group('watch (R5, R6, R7)', () {
    test('with offset, a change in front of the window re-runs the query', () async {
      db = FluentTestDb(name: 'read_fixes_offset_${DateTime.now().microsecondsSinceEpoch}');
      final ItemProvider items = ItemProvider();
      await db.open([items]);
      final List<Item> saved = [Item(title: 'a', when: DateTime(2020)), Item(title: 'b', when: DateTime(2020)), Item(title: 'c', when: DateTime(2020))];
      await items.saveAll(saved);
      final List<List<String>> seen = [];
      final StreamSubscription<List<Item>> sub = items.watch(orderBy: 'id', offset: 1, limit: 1).listen((l) => seen.add([for (final Item i in l) i.title]));
      await db.settle();
      expect(seen.last, ['b']);
      await items.delete((await items.findById(1))!);
      await db.settle();
      expect(seen.last, ['c']);
      await sub.cancel();
    });

    test('a self-referencing table re-runs on changes of loaded children', () async {
      db = FluentTestDb(name: 'read_fixes_self_${DateTime.now().microsecondsSinceEpoch}');
      final List<FluentProvider> providers = relationProviders();
      await db.open(providers);
      final CategoryProvider categories = providers.whereType<CategoryProvider>().single;
      await categories.save(Category(name: 'root', children: [Category(name: 'child')]));
      final List<List<String>> seen = [];
      final StreamSubscription<List<Category>> sub = categories
          .watch(where: FluentFilter.eq('name', 'root'))
          .listen((l) => seen.add([for (final Category c in l) for (final Category k in c.children ?? const <Category>[]) k.name]));
      await db.settle();
      expect(seen.last, ['child']);
      final Category child = (await categories.findFirst(where: FluentFilter.eq('name', 'child')))!;
      await categories.update(Category(id: child.id, name: 'renamed', parent: child.parent));
      await db.settle();
      expect(seen.last, ['renamed']);
      await sub.cancel();
    });

    test('no query runs after the subscription is cancelled', () async {
      final QueryCounter counter = await QueryCounter.install();
      try {
        db = FluentTestDb(name: 'read_fixes_cancel_${DateTime.now().microsecondsSinceEpoch}');
        final ItemProvider items = ItemProvider();
        await db.open([items]);
        await items.save(Item(title: 'a', when: DateTime(2020)));
        final List<int> events = [];
        final StreamSubscription<List<Item>> sub = items.watch().listen((l) => events.add(l.length));
        final StreamSubscription<int> values = items.watchValue(() => items.count()).listen(events.add);
        counter.reset();
        await sub.cancel(); // the first refresh is in flight
        await values.cancel();
        await db.settle();
        // The refresh in flight stops: no expiry lookup (and so no expiry timer) after the cancel.
        expect(counter.statements.where((s) => s.contains('MIN("expiry_date")')), isEmpty);
        counter.reset();
        await items.save(Item(title: 'b', when: DateTime(2020)));
        await db.settle();
        expect(counter.reads, 0);
        expect(events, isEmpty);
      } finally {
        counter.uninstall();
      }
    });
  });

  group('LIKE helpers (R8)', () {
    late ItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_like_${DateTime.now().microsecondsSinceEpoch}');
      items = ItemProvider();
      await db.open([items]);
      await items.saveAll([for (final String t in ['50% off', '500 off', 'a_b', 'axb', r'c:\dir', 'c:Xdir']) Item(title: t, when: DateTime(2020))]);
    });

    Future<List<String>> titles(FluentFilter where) async => [for (final Item i in await items.find(where: where, orderBy: 'id')) i.title];

    test('wildcards in the value are plain text', () async {
      expect(await titles(FluentFilter.contains('title', '0%')), ['50% off']);
      expect(await titles(FluentFilter.startsWith('title', 'a_')), ['a_b']);
      expect(await titles(FluentFilter.endsWith('title', r'\dir')), [r'c:\dir']);
      expect(await titles(FluentFilter.contains('title', 'off')), ['50% off', '500 off']);
    });

    test('like() keeps its pattern', () async {
      expect(await titles(FluentFilter.like('title', 'a_b')), ['a_b', 'axb']);
    });
  });

  group('key lookups (R9, R10, R11)', () {
    test('merged findById with a composite key in another column order', () async {
      db = FluentTestDb(name: 'read_fixes_pairs_${DateTime.now().microsecondsSinceEpoch}');
      final DynamicProvider p = pairs();
      await db.open([p]);
      await p.saveAll([p.row({'a': 1, 'b': 2, 'label': 'x'}), p.row({'a': 3, 'b': 4, 'label': 'y'})]);
      final List<DynamicModel?> found = await Future.wait([
        p.findById(FluentKey({'b': 2, 'a': 1})),
        p.findById(FluentKey({'b': 4, 'a': 3})),
        p.findById(FluentKey({'a': 9, 'b': 9})),
      ]);
      expect(found.map((m) => m?['label']), ['x', 'y', null]);
      expect((await p.findByIds([FluentKey({'b': 4, 'a': 3}), FluentKey({'b': 2, 'a': 1})])).map((m) => m['label']), ['y', 'x']);
    });

    test('composite keysFilter is one flat clause', () async {
      db = FluentTestDb(name: 'read_fixes_flat_${DateTime.now().microsecondsSinceEpoch}');
      final DynamicProvider p = pairs();
      await db.open([p]);
      final FluentFilter f = p.keysFilter([for (int i = 0; i < 3; i++) FluentKey({'a': i, 'b': i})]);
      expect(f.whereClause, '("a" = ? AND "b" = ?) OR ("a" = ? AND "b" = ?) OR ("a" = ? AND "b" = ?)');
      expect(f.whereArgs, [0, 0, 1, 1, 2, 2]);
      await p.saveAll([for (int i = 0; i < 600; i++) p.row({'a': i, 'b': i, 'label': '$i'})]);
      final List<DynamicModel> found = await p.findByIds([for (int i = 599; i >= 0; i--) FluentKey({'b': i, 'a': i})]);
      expect(found, hasLength(600));
      expect(found.first['label'], '599');
    });

    test('findByIds splits long lists and keeps their order', () async {
      final QueryCounter counter = await QueryCounter.install();
      try {
        db = FluentTestDb(name: 'read_fixes_chunks_${DateTime.now().microsecondsSinceEpoch}');
        final ItemProvider items = ItemProvider();
        await db.open([items]);
        await items.saveAll([for (int i = 0; i < 2000; i++) Item(title: '$i', when: DateTime(2020))]);
        counter.reset();
        final List<Item> found = await items.findByIds([for (int i = 2100; i > 0; i--) i]);
        expect(found, hasLength(2000));
        expect(found.first.id, 2000);
        expect(found.last.id, 1);
        expect(counter.statements.where((s) => s.contains(RegExp(r'FROM "?items"?'))).length, greaterThan(1));
      } finally {
        counter.uninstall();
      }
    });
  });

  test('placeholders inside string literals are not arguments (R12)', () async {
    db = FluentTestDb(name: 'read_fixes_literal_${DateTime.now().microsecondsSinceEpoch}');
    final ItemProvider items = ItemProvider();
    await db.open([items]);
    await items.saveAll([Item(title: 'a', when: DateTime(2020)), Item(title: 'what?', when: DateTime(2020))]);
    final List<Item> found = await items.find(where: const FluentFilter("\"title\" <> 'what?' AND \"title\" <> ?", ['x']).and(FluentFilter.ids([1, 2])));
    expect(found.map((i) => i.title), ['a']);
  });

  group('per-row type tags (R13, R14)', () {
    late ItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'read_fixes_tags_${DateTime.now().microsecondsSinceEpoch}');
      items = ItemProvider();
      await db.open([items]);
      await items.saveAll([Item(title: 'utc', when: DateTime.utc(2030)), Item(title: 'local', when: DateTime(2020)), Item(title: 'local2', when: DateTime(2020))]);
    });

    test('min / max keep a UTC DateTime', () async {
      final DateTime? latest = await items.max<DateTime>('when');
      expect(latest, DateTime.utc(2030));
      expect(latest!.isUtc, isTrue);
      final DateTime? first = await items.min<DateTime>('when');
      expect(first!.isUtc, isFalse);
      final List<Map<String, dynamic>> grouped = await items.aggregate(groupBy: ['n'], values: {'last': const FluentAggregate.max('when')});
      expect((grouped.single['last'] as DateTime).isUtc, isTrue);
      expect(grouped.single.keys, ['n', 'last']);
    });

    test('distinct projections keep a UTC DateTime', () async {
      final List<Map<String, dynamic>> rows = await items.findMaps(columns: ['when'], distinct: true, orderBy: '"when"');
      expect(rows, hasLength(2));
      expect((rows.last['when'] as DateTime).isUtc, isTrue);
      expect(rows.last.keys, ['when']);
      expect(await items.pluck<DateTime>('when', distinct: true, orderBy: '"when"', limit: 1), [DateTime(2020)]);
    });

    test('rows without tags read by the column kind', () async {
      final List<Item> all = await items.find(orderBy: 'id');
      expect(all.map((i) => i.when.isUtc), [true, false, false]);
    });
  });
}
