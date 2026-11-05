// Filters by related models: FluentFilter.related / notRelated / relatedCount on every relation type, paths,
// self-references, combination with and / or, other operations (count, delete, aggregates, watch) and indexReferences.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ArticleProvider articles;
  late PersonProvider people;
  late CategoryProvider categories;
  late CommentProvider comments;

  Future<void> open({FluentDbConfig config = const FluentDbConfig()}) async {
    db = FluentTestDb(name: 'relation_filter_${DateTime.now().microsecondsSinceEpoch}');
    final List<FluentProvider> providers = relationProviders();
    await db.open(providers, config: config);
    articles = providers.whereType<ArticleProvider>().single;
    people = providers.whereType<PersonProvider>().single;
    categories = providers.whereType<CategoryProvider>().single;
    comments = providers.whereType<CommentProvider>().single;
  }

  Future<void> seed() async {
    final Person boss = Person(name: 'Boss');
    await articles.saveAll([
      Article(title: 'A', author: Person(name: 'Ann', manager: boss), comments: [Comment(text: 'c1', likes: 3), Comment(text: 'c2')], tags: [Tag(label: 'dart')]),
      Article(title: 'B', author: Person(name: 'Bob'), comments: [Comment(text: 'c3')], tags: [Tag(label: 'flutter')]),
      Article(title: 'C', author: Person(name: 'Ann')),
    ]);
  }

  Future<List<String>> titles(FluentFilter where) async => [for (final Article a in await articles.find(where: where, orderBy: 'title')) a.title];

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('relation types', () {
    setUp(() async {
      await open();
      await seed();
    });

    test('one (reference): by a column of the referenced model', () async {
      expect(await titles(FluentFilter.related('author', FluentFilter.eq('name', 'Ann'))), ['A', 'C']);
      expect(await titles(FluentFilter.notRelated('author', FluentFilter.eq('name', 'Ann'))), ['B']);
    });

    test('many (owned): any, none, with a condition, counts', () async {
      expect(await titles(FluentFilter.related('comments')), ['A', 'B']);
      expect(await titles(FluentFilter.notRelated('comments')), ['C']);
      expect(await titles(FluentFilter.related('comments', FluentFilter.gt('likes', 0))), ['A']);
      expect(await titles(FluentFilter.relatedCount('comments', min: 2)), ['A']);
      expect(await titles(FluentFilter.relatedCount('comments', max: 1)), ['B', 'C']);
      expect(await titles(FluentFilter.relatedCount('comments', min: 1, max: 1)), ['B']);
    });

    test('many-to-many through the link table', () async {
      expect(await titles(FluentFilter.related('tags', FluentFilter.eq('label', 'dart'))), ['A']);
      expect(await titles(FluentFilter.notRelated('tags')), ['C']);
    });

    test("soft-deleted related rows and rows outside the relation's where do not count", () async {
      await comments.deleteWhere(FluentFilter.eq('text', 'c3'));
      expect(await titles(FluentFilter.related('comments')), ['A']);
      expect(await titles(FluentFilter.related('topComments')), ['A'], reason: 'topComments: likes > 0');
    });

    test('paths, self-references and nesting', () async {
      expect(await titles(FluentFilter.related('author.manager', FluentFilter.eq('name', 'Boss'))), ['A']);
      expect([for (final Person p in await people.find(where: FluentFilter.related('manager'))) p.name], ['Ann']);

      final Category root = Category(name: 'root', children: [Category(name: 'leaf')]);
      await categories.save(root);
      expect([for (final Category c in await categories.find(where: FluentFilter.related('children'))) c.name], ['root']);
      expect([for (final Category c in await categories.find(where: FluentFilter.related('parent', FluentFilter.eq('name', 'root')))) c.name], ['leaf']);

      // A related condition inside a related condition: articles whose author wrote an article with a comment.
      expect(
        await titles(FluentFilter.related('author', FluentFilter.related('manager')).and(FluentFilter.related('comments', FluentFilter.eq('text', 'c1')))),
        ['A'],
      );
    });

    test('combines with plain conditions and keeps argument order', () async {
      final FluentFilter f = FluentFilter.eq('title', 'B')
          .or(FluentFilter.related('author', FluentFilter.eq('name', 'Ann')).and(FluentFilter.related('comments', FluentFilter.eq('text', 'c2'))))
          .and(FluentFilter.notEq('title', 'Z'));
      expect(await titles(f), ['A', 'B']);
      expect(f.description, contains('related(author: "name" = ?)'));
    });

    test('count, findMaps, aggregates, delete and FluentDb statics accept related filters', () async {
      final FluentFilter byAnn = FluentFilter.related('author', FluentFilter.eq('name', 'Ann'));
      expect(await articles.count(where: byAnn), 2);
      expect(await articles.pluck<String>('title', where: byAnn, orderBy: 'title'), ['A', 'C']);
      expect(await articles.countDistinct('title', where: byAnn), 2);
      expect(await FluentDb.count<Article>(where: byAnn), 2);
      expect(await articles.deleteWhere(FluentFilter.notRelated('comments')), 1);
      expect(await titles(FluentFilter.empty), ['A', 'B']);
    });

    test('watch re-runs when a related table changes', () async {
      final List<List<String>> seen = [];
      final sub = articles.watch(where: FluentFilter.related('comments', FluentFilter.gt('likes', 5)), orderBy: 'title').listen((a) => seen.add([for (final x in a) x.title]));
      await db.settle();
      await comments.updateWhere(FluentFilter.eq('text', 'c3'), {'likes': 10});
      await db.settle();
      await sub.cancel();
      expect(seen, [<String>[], ['B']]);
    });

    test('an unknown relation or a bad count fails with a hint', () async {
      await expectLater(articles.find(where: FluentFilter.related('autor')), throwsA(isA<FluentRelationException>().having((e) => e.hint, 'hint', contains('author'))));
      await expectLater(articles.find(where: FluentFilter.relatedCount('comments')), throwsA(isA<FluentArgumentException>()));
      await expectLater(articles.find(where: FluentFilter.relatedCount('author.manager', min: 1)), throwsA(isA<FluentArgumentException>()));
    });
  });

  group('indexReferences', () {
    Future<Set<String>> indexes(String table) async => {for (final r in await articles.db.rawQuery("PRAGMA index_list('$table')")) '${r['name']}'};

    test('on by default: reference columns and link targets are indexed', () async {
      await open();
      expect(await indexes('comments'), contains('idx_comments_article_id'));
      expect((await indexes('articles')).where((n) => n.contains('author')), isNotEmpty);
    });

    test('off for a database (it wins over the engine): no indexes, and a hint when a relation needs one', () async {
      await open(config: const FluentDbConfig(indexReferences: false));
      expect(await indexes('comments'), isNot(contains('idx_comments_article_id')));
      await seed();
      await articles.find(where: FluentFilter.related('comments'));
      final FluentIssue hint = FluentLog.shownHints.firstWhere((h) => h.kind.name == 'refIndex');
      expect(hint.code, contains('indexReferences: true'));
    });
  });
}
