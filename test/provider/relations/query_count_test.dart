// Guards against N+1: the number of SQL statements of a relation load must not grow with the number of rows.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late ArticleProvider articles;

  setUp(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'query_count_${DateTime.now().microsecondsSinceEpoch}');
    final providers = relationProviders();
    articles = providers.whereType<ArticleProvider>().single;
    await db.open(providers);
  });

  tearDown(() async {
    await db.close();
    counter.uninstall();
  });

  Future<void> seed(int count, {int from = 0}) async {
    for (int i = from; i < from + count; i++) {
      await articles.save(
        Article(
          title: 'a$i',
          author: Person(name: 'author$i'),
          editor: Person(name: 'editor$i'),
          comments: [Comment(text: 'c$i', likes: i), Comment(text: 'd$i', likes: 1)],
          tags: [Tag(label: 't${i % 3}')],
        ),
      );
    }
  }

  Future<int> readsOf(Future<Object?> Function() load) async {
    counter.reset();
    await load();
    return counter.reads;
  }

  test('loading relations of 5 or 40 articles takes the same number of queries', () async {
    await seed(5);
    final int few = await readsOf(() => articles.findAll(relations: FluentLoad.all));
    await seed(35, from: 5);
    final int many = await readsOf(() => articles.findAll(relations: FluentLoad.all));
    expect(many, few, reason: 'statements:\n${counter.statements.join('\n')}');
    expect(few, lessThanOrEqualTo(8), reason: 'articles + author/editor + comments + tags (+ link table) + topComments');
  });

  test('two levels deep stays constant too', () async {
    await seed(3);
    final int few = await readsOf(() => articles.findAll(maxDepth: 2));
    await seed(20, from: 3);
    final int many = await readsOf(() => articles.findAll(maxDepth: 2));
    expect(many, few, reason: 'statements:\n${counter.statements.join('\n')}');
  });

  test('saving 5 or 40 article graphs again reads the stored children and links with the same number of queries', () async {
    await seed(40);
    final List<Article> loaded = await articles.findAll(orderBy: 'id');
    Future<int> saveReads(List<Article> some) async {
      counter.reset();
      await articles.saveAll([
        for (final Article a in some) Article(id: a.id, title: '${a.title}!', author: a.author, editor: a.editor, comments: [...a.comments!.take(1), Comment(text: 'more')], tags: a.tags),
      ]);
      return counter.reads;
    }

    // The first save moves dropped comments into the trash: from then on saves also look there (one more read).
    await saveReads(loaded.take(5).toList());
    final int few = await saveReads(loaded.skip(5).take(5).toList());
    final int many = await saveReads(loaded.skip(10).toList());
    expect(many, few, reason: 'the stored children / links are read per chunk of owners, not per owner:\n${counter.statements.join('\n')}');
    final List<Article> after = await articles.findAll(orderBy: 'id');
    expect(after.map((a) => a.comments!.map((c) => c.text).toList()), [for (final Article a in loaded) [a.comments!.first.text, 'more']], reason: 'the dropped comments are gone, the new ones saved');
  });

  test('update(withRelations: true) returns the number of updated owner rows', () async {
    await seed(2);
    final List<Article> all = await articles.findAll();
    final Article changed = Article(id: all.first.id, title: 'new', comments: [Comment(text: 'x')]);
    expect(await articles.update(changed, withRelations: true), 1);
    expect(await articles.update(Article(id: 999, title: 'missing'), withRelations: true), 0);
  });
}
