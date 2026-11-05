// Regression tests for the relation graph audit findings RG-1 .. RG-4.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- RG-1: Article.comments + Comment.article / Comment.featured ----

/// Rule of `Comment.article` (null: not declared).
FluentOnDelete? articleRule;

class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.comments});

  final int? id;
  final String title;
  final List<Comment>? comments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Article, Comment>('comments', (a) => a.comments)];
}

class Comment extends FluentStorable with FluentRelations {
  Comment({this.id, required this.text, this.article, this.featured});

  final int? id;
  final String text;
  final Article? article;
  final Article? featured;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Comment, Article>('article', (c) => c.article, onDelete: articleRule),
    FluentRelation.one<Comment, Article>('featured', (c) => c.featured),
  ];
}

class ArticleProvider extends FluentProvider<Article> {
  @override
  String get tableName => 'fx_articles';

  @override
  Article get modelSample => Article(title: '');

  @override
  Article fromCacheJson(Map<String, dynamic> json) => Article(id: json['id'] as int?, title: json['title'] as String, comments: (json['comments'] as List?)?.cast<Comment>());
}

class CommentProvider extends FluentProvider<Comment> {
  @override
  String get tableName => 'fx_comments';

  @override
  Comment get modelSample => Comment(text: '');

  @override
  Comment fromCacheJson(Map<String, dynamic> json) => Comment(id: json['id'] as int?, text: json['text'] as String, article: json['article'] as Article?, featured: json['featured'] as Article?);
}

// ---- RG-1 ambiguous: two references, none named like the owner ----

class Doc extends FluentStorable with FluentRelations {
  Doc({this.id, required this.title, this.notes});

  final int? id;
  final String title;
  final List<Note>? notes;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Doc, Note>('notes', (d) => d.notes)];
}

class Note extends FluentStorable with FluentRelations {
  Note({this.id, required this.text, this.draft, this.finalDoc});

  final int? id;
  final String text;
  final Doc? draft;
  final Doc? finalDoc;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Note, Doc>('draft', (n) => n.draft),
    FluentRelation.one<Note, Doc>('finalDoc', (n) => n.finalDoc),
  ];
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'fx_docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String, notes: (json['notes'] as List?)?.cast<Note>());
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'fx_notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String, draft: json['draft'] as Doc?, finalDoc: json['finalDoc'] as Doc?);
}

// ---- RG-3: a RESTRICT list ----

class Parent extends FluentStorable with FluentRelations {
  Parent({this.id, required this.name, this.kids});

  final int? id;
  final String name;
  final List<Kid>? kids;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Parent, Kid>('kids', (p) => p.kids, foreignKey: 'parent_id', onDelete: FluentOnDelete.restrict)];
}

class Kid extends FluentStorable {
  Kid({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class ParentProvider extends FluentProvider<Parent> {
  @override
  String get tableName => 'fx_parents';

  @override
  Parent get modelSample => Parent(name: '');

  @override
  Parent fromCacheJson(Map<String, dynamic> json) => Parent(id: json['id'] as int?, name: json['name'] as String, kids: (json['kids'] as List?)?.cast<Kid>());
}

class KidProvider extends FluentProvider<Kid> {
  @override
  String get tableName => 'fx_kids';

  @override
  Kid get modelSample => Kid(label: '');

  @override
  Kid fromCacheJson(Map<String, dynamic> json) => Kid(id: json['id'] as int?, label: json['label'] as String);
}

// ---- RG-2: a oneOf reference ----

class Pic extends FluentStorable {
  Pic({this.id});

  final int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id};
}

class Vid extends FluentStorable {
  Vid({this.id});

  final int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id};
}

class Tag extends FluentStorable with FluentRelations {
  Tag({this.id, this.target});

  final int? id;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.oneOf<Tag>('target', (t) => t.target, types: [Pic, Vid]),
  ];
}

class PicProvider extends FluentProvider<Pic> {
  @override
  String get tableName => 'fx_pics';

  @override
  Pic get modelSample => Pic();

  @override
  Pic fromCacheJson(Map<String, dynamic> json) => Pic(id: json['id'] as int?);
}

class VidProvider extends FluentProvider<Vid> {
  @override
  String get tableName => 'fx_vids';

  @override
  Vid get modelSample => Vid();

  @override
  Vid fromCacheJson(Map<String, dynamic> json) => Vid(id: json['id'] as int?);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'fx_tags';

  @override
  Tag get modelSample => Tag();

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(id: json['id'] as int?);
}

// ---- RG-4: many-to-many becomes an owned list ----

class Post extends FluentStorable {
  Post({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class OwnedPost extends FluentStorable {
  OwnedPost({this.id, required this.title, this.author});

  final int? id;
  final String title;
  final OwnedUser? author;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'author': author};
}

class User extends FluentStorable {
  User({this.id, required this.name, this.posts = const []});

  final int? id;
  final String name;
  final List<Post> posts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'posts': posts};
}

class OwnedUser extends FluentStorable {
  OwnedUser({this.id, required this.name, this.posts = const []});

  final int? id;
  final String name;
  final List<OwnedPost> posts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'posts': posts};
}

class UserProvider extends FluentProvider<User> {
  @override
  String get tableName => 'fx_users';

  @override
  User get modelSample => User(name: '');

  @override
  User fromCacheJson(Map<String, dynamic> json) => User(id: json['id'] as int?, name: json['name'] as String, posts: (json['posts'] as List?)?.cast<Post>() ?? const []);
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'fx_posts';

  @override
  Post get modelSample => Post(title: '');

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(id: json['id'] as int?, title: json['title'] as String);
}

class OwnedUserProvider extends FluentProvider<OwnedUser> {
  @override
  String get tableName => 'fx_users';

  @override
  OwnedUser get modelSample => OwnedUser(name: '');

  @override
  OwnedUser fromCacheJson(Map<String, dynamic> json) => OwnedUser(id: json['id'] as int?, name: json['name'] as String, posts: (json['posts'] as List?)?.cast<OwnedPost>() ?? const []);
}

class OwnedPostProvider extends FluentProvider<OwnedPost> {
  @override
  String get tableName => 'fx_posts';

  @override
  OwnedPost get modelSample => OwnedPost(title: '', author: OwnedUser(name: ''));

  @override
  OwnedPost fromCacheJson(Map<String, dynamic> json) => OwnedPost(id: json['id'] as int?, title: json['title'] as String, author: json['author'] as OwnedUser?);
}

Future<Map<String, String>> foreignKeys(FluentProvider p) async => {
  for (final r in await p.db.rawQuery('PRAGMA foreign_key_list("${p.tableName}")')) '${r['from']}': '${r['table']}.${r['to']} ON DELETE ${r['on_delete']}',
};

FluentRelationLink linkOf(FluentProvider p, String name) => p.relationLinks.singleWhere((l) => l.name == name);

Future<int> count(FluentProvider p) async => (await p.db.rawQuery('SELECT COUNT(*) AS c FROM "${p.tableName}"')).first['c']! as int;

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() {
    articleRule = null;
    db = FluentTestDb(name: 'rg_fix_${counter++}', persistent: true);
  });
  tearDown(() => db.close());

  group('RG-1 shared column of an owned list and its back-reference', () {
    test('Comment.article + Comment.featured + Article.comments: shared article_id, CASCADE, no ambiguity issue', () async {
      final ArticleProvider articles = ArticleProvider();
      final CommentProvider comments = CommentProvider();
      await db.open([articles, comments]);
      expect(linkOf(articles, 'comments').foreignKeys, ['article_id']);
      expect(linkOf(articles, 'comments').onDelete, FluentOnDelete.cascade);
      expect(linkOf(comments, 'article').onDelete, FluentOnDelete.cascade);
      expect((await foreignKeys(comments))['article_id'], 'fx_articles.id ON DELETE CASCADE');
      expect((await foreignKeys(comments))['featured_id'], 'fx_articles.id ON DELETE SET NULL');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDeclaration), isEmpty);

      final Article article = Article(title: 'A', comments: [Comment(text: 'c1'), Comment(text: 'c2')]);
      await articles.save(article);
      await articles.delete(article);
      expect(await count(comments), 0);
    });

    test('an explicitly declared rule on the reference wins', () async {
      articleRule = FluentOnDelete.setNull;
      final ArticleProvider articles = ArticleProvider();
      final CommentProvider comments = CommentProvider();
      await db.open([articles, comments]);
      expect((await foreignKeys(comments))['article_id'], 'fx_articles.id ON DELETE SET NULL');
      expect(linkOf(articles, 'comments').onDelete, FluentOnDelete.setNull);
    });

    test('an existing database gets the CASCADE foreign key on the next start', () async {
      articleRule = FluentOnDelete.setNull;
      final ArticleProvider old = ArticleProvider();
      final CommentProvider oldComments = CommentProvider();
      await db.open([old, oldComments]);
      await old.save(Article(title: 'A', comments: [Comment(text: 'c1')]));
      expect((await foreignKeys(oldComments))['article_id'], 'fx_articles.id ON DELETE SET NULL');

      articleRule = null;
      final ArticleProvider articles = ArticleProvider();
      final CommentProvider comments = CommentProvider();
      await db.restart([articles, comments]);
      expect((await foreignKeys(comments))['article_id'], 'fx_articles.id ON DELETE CASCADE');
      final Article stored = (await articles.findAll()).single;
      await articles.delete(stored);
      expect(await count(comments), 0, reason: 'the comments are deleted with their article');
    });

    test('really ambiguous: several references, none named like the owner, use their own column and say so', () async {
      final DocProvider docs = DocProvider();
      final NoteProvider notes = NoteProvider();
      await db.open([docs, notes]);
      expect(linkOf(docs, 'notes').foreignKeys, ['doc_id']);
      final FluentIssue issue = db.issues.singleWhere((i) => i.kind == FluentIssueKind.relationDeclaration);
      expect(issue.title, contains('own column doc_id'));
      expect(issue.code, contains("foreignKey: 'draft_id'"));
    });
  });

  group('RG-2 referenceValues', () {
    test('a oneOf reference throws a typed exception instead of indexing out of range', () async {
      final TagProvider tags = TagProvider();
      await db.open([tags, PicProvider(), VidProvider()]);
      final FluentRelationLink link = linkOf(tags, 'target');
      expect(() => link.referenceValues(1), throwsA(isA<FluentRelationException>()));
    });
  });

  group('RG-3 cleanupOrphans respects RESTRICT', () {
    test('dangling rows of a RESTRICT list are left alone and reported', () async {
      final ParentProvider parents = ParentProvider();
      final KidProvider kids = KidProvider();
      await db.open([parents, kids], config: const FluentDbConfig(enableForeignKeys: false));
      await kids.db.insert('fx_kids', {'label': 'lost', 'parent_id': 99});
      await kids.db.insert('fx_kids', {'label': 'free', 'parent_id': null});
      await kids.cleanupOrphans(kids.db);
      expect(await count(kids), 2, reason: 'RESTRICT never deletes or clears');
      final List<Map<String, Object?>> rows = await kids.db.query('fx_kids', orderBy: 'label');
      expect(rows.first['parent_id'], null);
      expect(rows.last['parent_id'], 99);
      final FluentIssue issue = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.danglingReferences);
      expect(issue.title, contains('1 row(s)'));
      expect(issue.title, contains('RESTRICT'));
    });
  });

  group('RG-4 links moved into an owned column', () {
    test('a child that already points to another owner keeps it; the conflict is reported', () async {
      final UserProvider users = UserProvider();
      final PostProvider posts = PostProvider();
      await db.open([users, posts]);
      await users.save(User(name: 'Ann', posts: [Post(title: 'a')]));
      await users.save(User(name: 'Bob', posts: [Post(title: 'c')]));
      final int bob = (await users.db.query('fx_users', where: 'name = ?', whereArgs: ['Bob'])).single['id']! as int;
      // An older app version already wrote a (different) reference for post "a" (the link table says Ann).
      await users.db.execute('ALTER TABLE fx_posts ADD COLUMN author_id INTEGER');
      await users.db.update('fx_posts', {'author_id': bob}, where: 'title = ?', whereArgs: ['a']);

      final OwnedUserProvider owned = OwnedUserProvider();
      await db.restart([owned, OwnedPostProvider()]);
      final Map<String, Object?> a = (await owned.db.query('fx_posts', where: 'title = ?', whereArgs: ['a'])).single;
      final Map<String, Object?> c = (await owned.db.query('fx_posts', where: 'title = ?', whereArgs: ['c'])).single;
      expect(a['author_id'], bob, reason: 'no silent change of the owner');
      expect(c['author_id'], bob, reason: 'a NULL reference is filled from the link table');
      final FluentIssue warning = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.relationChanged);
      expect(warning.title, contains('1 OwnedPost row(s)'));
      expect(await owned.db.query('fx_posts_fx_users'), hasLength(2), reason: 'the link table is kept');
    });
  });
}
