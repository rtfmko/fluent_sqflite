// Audit: relation reading / writing / operations and the filter builder.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/relation_models.dart';

// Own models: a post with three relations over the same notes table (reference column post_id) that differ in
// limit / orderBy / includeDeleted.
class Post extends FluentStorable with FluentRelations {
  Post({this.id, required this.title, this.notes, this.allNotes, this.recent});

  final int? id;
  final String title;
  final List<Note>? notes;
  final List<Note>? allNotes;
  final List<Note>? recent;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    // Declared first: its windowed read (limit + orderBy) runs before the one without orderBy.
    FluentRelation.many<Post, Note>('notes', (p) => p.notes, foreignKey: 'post_id', orderBy: 'id', limit: 2),
    FluentRelation.many<Post, Note>('allNotes', (p) => p.allNotes, foreignKey: 'post_id', orderBy: 'id', includeDeleted: true),
    FluentRelation.many<Post, Note>('recent', (p) => p.recent, foreignKey: 'post_id', limit: 1),
  ];
}

class Note extends FluentStorable with FluentSoftDeletable {
  Note({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '');

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(
    id: json['id'] as int?,
    title: json['title'] as String,
    notes: (json['notes'] as List?)?.cast<Note>(),
    allNotes: (json['allNotes'] as List?)?.cast<Note>(),
    recent: (json['recent'] as List?)?.cast<Note>(),
  );
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  group('Relation loads on a post / note graph', () {
    late FluentTestDb db;
    late PostProvider posts;
    late NoteProvider notes;

    setUp(() async {
      db = FluentTestDb(name: 'rr_posts_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      posts = PostProvider();
      notes = NoteProvider();
      await db.open([posts, notes]);
    });

    tearDown(() => db.close());

    // RR-A: a relation declared with includeDeleted: true should show its trashed children on load. The reader drops
    // them (fluent_relation_reader.dart ~124-125 skips every child with a stamp unless the owner's stamp matches,
    // and that check does not look at link.relation.includeDeleted).
    test('RR-A: a relation with includeDeleted shows its trashed children when loaded', () async {
      await posts.save(Post(title: 'P', notes: [Note(text: 'live'), Note(text: 'trashed')]));
      await notes.deleteWhere(FluentFilter.eq('text', 'trashed'));

      final Post post = (await posts.findAll()).single;
      expect(post.allNotes?.map((n) => n.text), unorderedEquals(['live', 'trashed']));
    });

    // RR-B: a windowed (limit + perOwner) read of a relation without orderBy orders by `rowid` in the outer SELECT
    // of a subquery that does not expose rowid. Expected: the load works after another windowed read succeeded.
    test('RR-B: a limited relation without orderBy loads after a limited relation with orderBy', () async {
      await posts.save(Post(title: 'P', notes: [Note(text: 'a'), Note(text: 'b'), Note(text: 'c')]));

      final Post post = (await posts.findAll()).single;
      expect(post.notes?.map((n) => n.text), ['a', 'b'], reason: 'limit 2 by id');
      expect(post.recent?.map((n) => n.text), ['a'], reason: 'limit 1 without orderBy');
    });

    // Cause of RR-B, checked on SQLite alone: rowid is not visible through a subquery.
    test('RR-B cause: rowid is not visible in the outer SELECT of a subquery', () async {
      await posts.save(Post(title: 'P'));
      await expectLater(posts.db.rawQuery('SELECT * FROM (SELECT *, 1 AS x FROM "posts") ORDER BY rowid'), throwsA(isA<DatabaseException>()));
    });

    // Expected to pass when run alone: the limited relation without orderBy works when no windowed read ran before.
    test('RR-B alone: a limited relation without orderBy loads', () async {
      await posts.save(Post(title: 'P', notes: [Note(text: 'a'), Note(text: 'b')]));
      final Post post = (await posts.findAll(relations: FluentLoad.none)).single;
      final Post full = await posts.loadRelations(post, names: ['recent']);
      expect(full.recent?.map((n) => n.text), ['a']);
    });

    // RR-C (chunking guard, expected to pass): owners above one statement's parameter chunk are split, and each owner
    // still gets exactly its own children.
    test('owners beyond one chunk each get their own children', () async {
      const int count = 950;
      await posts.saveAll([for (int i = 0; i < count; i++) Post(title: 'p$i', notes: [Note(text: 'n$i')])]);

      final List<Post> loaded = await posts.findAll(orderBy: 'id', relations: FluentLoad.eager);
      expect(loaded.length, count);
      for (int i = 0; i < count; i++) {
        expect(loaded[i].notes?.map((n) => n.text), ['n$i'], reason: 'post p$i');
      }
    });
  });

  group('Relation operations on the article graph', () {
    late FluentTestDb db;
    late ArticleProvider articles;
    late CommentProvider comments;

    setUp(() async {
      final List<FluentProvider> providers = relationProviders();
      db = FluentTestDb(name: 'rr_articles_${DateTime.now().microsecondsSinceEpoch}');
      await db.open(providers);
      articles = providers.whereType<ArticleProvider>().single;
      comments = providers.whereType<CommentProvider>().single;
      await articles.saveAll([
        Article(title: 'A', author: Person(name: 'Ann'), comments: [Comment(text: 'c1', likes: 3), Comment(text: 'c2')], tags: [Tag(label: 'dart')]),
        Article(title: 'B', author: Person(name: 'Bob'), comments: [Comment(text: 'c3')], tags: [Tag(label: 'flutter')]),
        Article(title: 'C', author: Person(name: 'Ann')),
      ]);
    });

    tearDown(() => db.close());

    Future<Article> article(String title) async => (await articles.find(where: FluentFilter.eq('title', title))).single;

    // Expected to pass: `and` / `or` renumber the markers of the deferred conditions of the right-hand side.
    test('three related conditions combined with or / and keep their own sub-filters', () async {
      final FluentFilter where = FluentFilter.related('comments', FluentFilter.gt('likes', 2))
          .or(FluentFilter.related('tags', FluentFilter.eq('label', 'flutter')))
          .and(FluentFilter.related('author', FluentFilter.eq('name', 'Bob')));
      expect([for (final Article a in await articles.find(where: where)) a.title], ['B']);
    });

    // Expected to pass: a hand-written filter with a '?' inside a string literal does not shift the arguments of a
    // related condition that follows it.
    test('a literal ? in a hand-written filter does not shift the arguments of a related condition', () async {
      final FluentFilter where = const FluentFilter("\"title\" <> '?' AND \"title\" = ?", ['A']).and(FluentFilter.related('comments'));
      expect([for (final Article a in await articles.find(where: where)) a.title], ['A']);
    });

    // Expected to pass: LIKE wildcards in contains() are plain text.
    test('contains treats % and _ as plain text', () async {
      await articles.save(Article(title: 'a%b'));
      await articles.save(Article(title: 'axb'));
      expect([for (final Article a in await articles.find(where: FluentFilter.contains('title', '%'))) a.title], ['a%b']);
      expect(await articles.find(where: FluentFilter.contains('title', '_')), isEmpty, reason: 'no title has a literal underscore');
    });

    // Expected to pass: a trashed comment leaves the count and the list of the relation.
    test('countRelated and findRelated agree and hide trashed children', () async {
      final Article a = await article('A');
      expect(await articles.countRelated(a, 'comments'), 2);
      await comments.deleteWhere(FluentFilter.eq('text', 'c1'));
      expect(await articles.countRelated(a, 'comments'), 1);
      expect((await articles.findRelated<Comment>(a, 'comments')).map((c) => c.text), ['c2']);
    });

    // Expected to pass: attach / detach of a many-to-many list keep the other links.
    test('attach then detach a many-to-many list keeps the rest', () async {
      final Article c = await article('C');
      final Tag t = Tag(label: 'sql');
      await articles.attach(c, 'tags', [t]);
      expect((await articles.loadRelations(c, names: ['tags'])).tags?.map((x) => x.label), ['sql']);
      await articles.detach(c, 'tags', [t]);
      expect(await articles.countRelated(c, 'tags'), 0);
    });

    // Expected to pass: an unknown relation name in findRelated is a typed exception, not a raw error.
    test('findRelated of an unknown relation throws FluentRelationException', () async {
      final Article a = await article('A');
      await expectLater(articles.findRelated<Comment>(a, 'nope'), throwsA(isA<FluentRelationException>()));
    });
  });

  group('Filter values and fingerprints (no database)', () {
    // Expected to pass: values of different types never share a read key.
    test('1 and \'1\' and 1.0 have different value keys', () {
      expect(fluentValueKey(1), isNot(fluentValueKey('1')));
      expect(fluentValueKey(1), isNot(fluentValueKey(1.0)));
    });

    // Expected to pass: the fingerprint of a related condition holds its value.
    test('related conditions with different values have different fingerprints', () {
      final FluentFilter x = FluentFilter.related<Comment>('comments', FluentFilter.eq('text', 'x'));
      final FluentFilter y = FluentFilter.related<Comment>('comments', FluentFilter.eq('text', 'y'));
      expect(fluentFilterKey(x), isNot(fluentFilterKey(y)));
    });

    // Expected to pass: FluentKey equality and hashCode ignore the order of the columns.
    test('FluentKey hashCode is order-free', () {
      final FluentKey a = FluentKey({'a': 1, 'b': 2});
      final FluentKey b = FluentKey({'b': 2, 'a': 1});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });

    // Expected to pass: LIKE escaping of the contains / startsWith helpers.
    test('contains escapes the wildcards and the escape character', () {
      final FluentFilter f = FluentFilter.contains('t', r'50%_\x');
      expect(f.whereArgs.single, r'%50\%\_\\x%');
    });

    // Expected to pass: eq / notEq with null become IS NULL / IS NOT NULL.
    test('null values give IS NULL and IS NOT NULL', () {
      expect(FluentFilter.eq('a', null).whereClause, '"a" IS NULL');
      expect(FluentFilter.notEq('a', null).whereClause, '"a" IS NOT NULL');
    });

    // Expected to pass: an empty inList matches nothing and an empty notInList matches everything.
    test('empty inList / notInList', () {
      expect(FluentFilter.inList('a', const []).whereClause, '1 = 0');
      expect(FluentFilter.notInList('a', const []).whereClause, '1 = 1');
    });
  });
}
