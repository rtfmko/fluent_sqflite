import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/relation_models.dart';

Future<List<String>> columns(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<Map<String, String>> foreignKeys(Database db, String table) async => {
  for (final r in await db.rawQuery("PRAGMA foreign_key_list('$table')")) '${r['from']}': '${r['table']}.${r['to']} ON DELETE ${r['on_delete']}',
};

Future<int> count(Database db, String table) async => (await db.rawQuery('SELECT COUNT(*) AS c FROM "$table"')).first['c']! as int;

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ArticleProvider articles;
  late PersonProvider people;
  late CategoryProvider categories;
  late Database sql;

  setUp(() async {
    db = FluentTestDb(name: 'relations_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    final providers = relationProviders();
    await db.open(providers);
    articles = providers.whereType<ArticleProvider>().single;
    people = providers.whereType<PersonProvider>().single;
    categories = providers.whereType<CategoryProvider>().single;
    sql = articles.db;
  });

  tearDown(() => db.close());

  Article sample() => Article(
    title: 'First',
    author: Person(name: 'Ann'),
    editor: Person(name: 'Bob'),
    comments: [Comment(text: 'c1', likes: 1), Comment(text: 'c2', likes: 5), Comment(text: 'c3')],
    tags: [Tag(label: 'sql'), Tag(label: 'dart')],
  );

  group('Schema is derived from the declarations', () {
    test('reference columns, owned columns and link tables', () async {
      expect(await columns(sql, 'articles'), containsAll(['author_id', 'editor_id']));
      expect(await foreignKeys(sql, 'articles'), {'author_id': 'people.id ON DELETE SET NULL', 'editor_id': 'people.id ON DELETE SET NULL'});
      expect(await foreignKeys(sql, 'comments'), {'article_id': 'articles.id ON DELETE CASCADE'});
      expect(await foreignKeys(sql, 'profiles'), {'person_id': 'people.id ON DELETE CASCADE'});
      expect(await foreignKeys(sql, 'categories'), {'parent_id': 'categories.id ON DELETE SET NULL'});
      expect(await columns(sql, 'articles_tags'), unorderedEquals(['article_id', 'tag_id']));
      expect(articles.relationLinks.map((l) => l.name), ['author', 'editor', 'comments', 'tags', 'topComments']);
    });
  });

  group('Saving a model graph', () {
    test('new models with references, an owned list and many-to-many are saved in the right order', () async {
      await articles.save(sample());

      expect(await count(sql, 'people'), 2);
      expect(await count(sql, 'comments'), 3);
      expect(await count(sql, 'tags'), 2);
      expect(await count(sql, 'articles_tags'), 2);

      final row = (await sql.query('articles')).single;
      final ann = (await sql.query('people', where: 'name = ?', whereArgs: ['Ann'])).single;
      final bob = (await sql.query('people', where: 'name = ?', whereArgs: ['Bob'])).single;
      expect(row['author_id'], ann['id']);
      expect(row['editor_id'], bob['id']);
      expect((await sql.query('comments')).map((c) => c['article_id']).toSet(), {row['id']});
    });

    test('one instance referenced several times is saved once', () async {
      final ann = Person(name: 'Ann');
      await articles.save(Article(title: 'A', author: ann, editor: ann));
      await articles.save(Article(title: 'B', author: ann));

      expect(await count(sql, 'people'), 1);
      expect((await sql.query('articles')).map((a) => a['author_id']).toSet(), hasLength(1));
    });

    test('existing models are referenced, not duplicated or overwritten', () async {
      await people.save(Person(id: 1, name: 'Ann'));
      await people.save(Person(id: 2, name: 'Cid, unrelated'));

      await articles.save(Article(id: 10, title: 'A', author: Person(id: 1, name: 'Ann')));

      expect(await count(sql, 'people'), 2);
      expect((await sql.query('people', where: 'id = 2')).single['name'], 'Cid, unrelated');
      expect((await sql.query('articles')).single['author_id'], 1);
    });

    test('lists are replaced: removed children are deleted, removed tags are only unlinked', () async {
      await articles.save(sample());
      final saved = (await articles.findById(1))!;

      await articles.save(Article(
        id: saved.id,
        title: saved.title,
        comments: [saved.comments!.first],
        tags: [saved.tags!.firstWhere((t) => t.label == 'dart')],
      ));

      expect(await count(sql, 'comments'), 3, reason: 'soft-deletable children are soft-deleted');
      expect((await articles.findById(1))!.comments!.map((c) => c.text), ['c1']);
      expect(await count(sql, 'tags'), 2, reason: 'shared models are never deleted through a link');
      expect(await count(sql, 'articles_tags'), 1);
    });

    test('null means "not loaded": stored children and links stay untouched', () async {
      await articles.save(sample());
      await articles.save(Article(id: 1, title: 'Renamed'));

      final loaded = (await articles.findById(1))!;
      expect(loaded.title, 'Renamed');
      expect(loaded.comments, hasLength(3));
      expect(loaded.tags, hasLength(2));
      expect(loaded.author?.name, 'Ann', reason: 'a null reference keeps the stored value');
    });
  });

  group('Loading', () {
    test('references, lists and links are loaded as typed models', () async {
      await articles.save(sample());
      final loaded = (await articles.findById(1))!;

      expect(loaded.author?.name, 'Ann');
      expect(loaded.editor?.name, 'Bob');
      expect(loaded.comments!.map((c) => c.text), ['c1', 'c2', 'c3']);
      expect(loaded.tags!.map((t) => t.label), ['dart', 'sql'], reason: 'orderBy: label');
      expect(loaded.isRelationLoaded('author'), isTrue);
      expect(loaded.topComments, isNull, reason: 'lazy relations are not loaded with the row');
      expect(loaded.isRelationLoaded('topComments'), isFalse);
    });

    test('many rows are loaded with their own children', () async {
      for (int i = 0; i < 5; i++) {
        await articles.save(Article(title: 'A$i', author: Person(name: 'P$i'), comments: [for (int c = 0; c <= i; c++) Comment(text: 'a$i-c$c')]));
      }
      final all = await articles.findAll();

      expect(all, hasLength(5));
      for (final a in all) {
        final int n = int.parse(a.title.substring(1));
        expect(a.author?.name, 'P$n');
        expect(a.comments, hasLength(n + 1));
        expect(a.comments!.every((c) => c.text.startsWith('a$n-')), isTrue);
      }
    });

    test('lazy relations on demand, filtered + ordered + limited, and counted', () async {
      await articles.save(sample());
      final article = (await articles.findById(1))!;

      final full = await articles.loadRelations(article, names: ['topComments']);
      expect(full.topComments!.map((c) => c.text), ['c2', 'c1'], reason: 'likes > 0, likes DESC, limit 2');
      expect(full.comments, hasLength(3), reason: 'eager relations stay loaded');

      expect(await articles.countRelated(article, 'comments'), 3);
      expect(await articles.countRelated(article, 'topComments'), 2);
      expect(await articles.countRelated(article, 'tags'), 2);
      expect(await articles.countRelated(article, 'author'), 1);
    });

    test('soft-deleted children are hidden', () async {
      await articles.save(sample());
      final comment = (await articles.findById(1))!.comments!.first;

      await FluentDb.delete<Comment>(comment);
      expect((await articles.findById(1))!.comments!.map((c) => c.text), ['c2', 'c3']);
      expect(await count(sql, 'comments'), 3, reason: 'soft delete keeps the row');
    });
  });

  group('attach / detach', () {
    test('many-to-many links are added and removed without touching other links', () async {
      await articles.save(sample());
      final article = (await articles.findById(1))!;

      await articles.attach(article, 'tags', [Tag(label: 'flutter')]);
      expect(await articles.countRelated(article, 'tags'), 3);

      final sqlTag = article.tags!.firstWhere((t) => t.label == 'sql');
      await articles.detach(article, 'tags', [sqlTag]);
      expect((await articles.findById(1))!.tags!.map((t) => t.label), ['dart', 'flutter']);
      expect(await count(sql, 'tags'), 3);
    });

    test('owned children are added and removed', () async {
      await articles.save(sample());
      final article = (await articles.findById(1))!;

      await articles.attach(article, 'comments', [Comment(text: 'c4')]);
      expect(await articles.countRelated(article, 'comments'), 4);

      await articles.detach(article, 'comments', [article.comments!.first]);
      expect((await articles.findById(1))!.comments!.map((c) => c.text), ['c2', 'c3', 'c4']);
    });
  });

  group('Deleting follows the meaning of each relation', () {
    test('deleting an article removes its comments and links, never the people or tags', () async {
      await people.save(Person(name: 'Cid, unrelated'));
      await articles.save(sample());

      await articles.deleteById(1);

      expect(await count(sql, 'articles'), 0);
      expect(await count(sql, 'comments'), 0);
      expect(await count(sql, 'articles_tags'), 0);
      expect(await count(sql, 'people'), 3);
      expect(await count(sql, 'tags'), 2);
    });

    test('deleting a referenced person clears the reference instead of deleting the article', () async {
      await articles.save(sample());
      final ann = (await articles.findById(1))!.author!;

      await people.deleteById(ann.id);

      final row = (await sql.query('articles')).single;
      expect(row['author_id'], isNull);
      expect(row['editor_id'], isNotNull);
    });
  });

  group('Self-references', () {
    test('a category tree is saved and loaded level by level', () async {
      await categories.save(Category(
        name: 'root',
        children: [
          Category(name: 'b', children: [Category(name: 'b1')]),
          Category(name: 'a'),
        ],
      ));

      expect(await count(sql, 'categories'), 4);
      final root = (await categories.find(where: FluentFilter.eq('name', 'root'), maxDepth: 2)).single;
      expect(root.children!.map((c) => c.name), ['a', 'b']);
      expect(root.children!.last.children!.map((c) => c.name), ['b1']);

      final leaf = (await categories.find(where: FluentFilter.eq('name', 'b1'))).single;
      expect(leaf.parent?.name, 'b');
    });

    test('a person can reference another person (and themselves without looping)', () async {
      final boss = Person(name: 'Boss');
      await people.save(Person(name: 'Dev', manager: boss, profile: Profile(bio: 'writes code')));

      final dev = (await people.find(where: FluentFilter.eq('name', 'Dev'))).single;
      expect(dev.manager?.name, 'Boss');
      expect(dev.profile?.bio, 'writes code');
    });
  });

  group('Schema rebuild keeps related data', () {
    test('rebuilding the parent table does not cascade-delete children', () async {
      await articles.save(sample());

      // Restart with a renamed column on "articles": forces a table rebuild.
      final providers = relationProviders();
      final renamed = _RenamedArticleProvider();
      await db.restart([...providers.where((p) => p is! ArticleProvider), renamed]);

      expect(await count(renamed.db, 'comments'), 3);
      expect(await count(renamed.db, 'articles_tags'), 2);
      expect((await renamed.db.query('articles')).single['headline'], 'First');
    });
  });

  group('Fault tolerance', () {
    test('invalid declarations are skipped with a hint, the rest works', () async {
      final broken = _BrokenProvider();
      final other = FluentTestDb(name: 'broken_relations', persistent: true);
      await other.open([broken, PersonProvider(), ProfileProvider()]);

      expect(broken.relationLinks.map((l) => l.name), ['ok']);
      await broken.save(_Note(text: 'n', owner: Person(name: 'Ann')));
      expect((await broken.findAll()).single.owner?.name, 'Ann');
      await other.close();
    });
  });
}

class _RenamedArticleProvider extends ArticleProvider {
  @override
  Article get modelSample => _RenamedArticle(title: '');

  @override
  Article fromCacheJson(Map<String, dynamic> json) => super.fromCacheJson({...json, 'title': json['headline']});
}

class _RenamedArticle extends Article {
  _RenamedArticle({required super.title});

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'headline': title};

  @override
  List<FluentDbColumn> get tableSchema => [for (final FluentDbColumn c in super.tableSchema) c.name == 'headline' ? c.copyWith(oldName: 'title') : c];
}

class _Note extends FluentStorable with FluentRelations {
  _Note({this.id, required this.text, this.owner});

  final int? id;
  final String text;
  final Person? owner;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<_Note, Person>('ok', (n) => n.owner),
    FluentRelation.one<_Note, Person>('ok', (n) => n.owner), // duplicate name
    FluentRelation.one<_Note, _Unregistered>('ghost', (n) => null), // provider not registered
    const FluentRelation(name: 'anonymous', type: FluentRelationType.one, select: _none), // no types
    FluentRelation.one<_Note, Person>('', (n) => n.owner), // empty name
  ];
}

class _Unregistered extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': null};
}

class _BrokenProvider extends FluentProvider<_Note> {
  @override
  String get tableName => 'notes';

  @override
  _Note get modelSample => _Note(text: '');

  @override
  _Note fromCacheJson(Map<String, dynamic> json) => _Note(id: json['id'] as int?, text: json['text'] as String, owner: json['ok'] as Person?);
}

Object? _none(FluentStorable _) => null;
