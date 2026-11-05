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

  test('update(withRelations: true) returns the number of updated owner rows', () async {
    await seed(2);
    final List<Article> all = await articles.findAll();
    final Article changed = Article(id: all.first.id, title: 'new', comments: [Comment(text: 'x')]);
    expect(await articles.update(changed, withRelations: true), 1);
    expect(await articles.update(Article(id: 999, title: 'missing'), withRelations: true), 0);
  });
}
