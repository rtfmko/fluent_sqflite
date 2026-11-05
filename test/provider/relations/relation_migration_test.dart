// Relations that change how they are stored between app versions keep their data.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Version without a back-reference: `User.posts` is many-to-many (nothing says a post has one user).
class Post extends FluentStorable {
  Post({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

/// Version with a back-reference: `User.posts` is a list the user owns (`posts.author_id`).
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
  String get tableName => 'users';

  @override
  User get modelSample => User(name: '');

  @override
  User fromCacheJson(Map<String, dynamic> json) => User(id: json['id'] as int?, name: json['name'] as String, posts: (json['posts'] as List?)?.cast<Post>() ?? const []);
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '');

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(id: json['id'] as int?, title: json['title'] as String);
}

class OwnedUserProvider extends FluentProvider<OwnedUser> {
  @override
  String get tableName => 'users';

  @override
  OwnedUser get modelSample => OwnedUser(name: '');

  @override
  OwnedUser fromCacheJson(Map<String, dynamic> json) =>
      OwnedUser(id: json['id'] as int?, name: json['name'] as String, posts: (json['posts'] as List?)?.cast<OwnedPost>() ?? const []);
}

class OwnedPostProvider extends FluentProvider<OwnedPost> {
  @override
  String get tableName => 'posts';

  @override
  OwnedPost get modelSample => OwnedPost(title: '', author: OwnedUser(name: ''));

  @override
  OwnedPost fromCacheJson(Map<String, dynamic> json) => OwnedPost(id: json['id'] as int?, title: json['title'] as String, author: json['author'] as OwnedUser?);
}

/// Owns its posts through `posts.owner_id` (an explicit list: ON DELETE CASCADE).
class Blog extends FluentStorable with FluentRelations {
  Blog({this.id, required this.title, this.posts});

  final int? id;
  final String title;
  final List<Post>? posts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Blog, Post>('posts', (b) => b.posts, foreignKey: 'owner_id')];
}

/// The next version: the blog no longer lists posts, so `posts.owner_id` is archived.
class PlainBlog extends FluentStorable {
  PlainBlog({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class BlogProvider extends FluentProvider<Blog> {
  @override
  String get tableName => 'blogs';

  @override
  Blog get modelSample => Blog(title: '');

  @override
  Blog fromCacheJson(Map<String, dynamic> json) => Blog(id: json['id'] as int?, title: json['title'] as String, posts: (json['posts'] as List?)?.cast<Post>());
}

class PlainBlogProvider extends FluentProvider<PlainBlog> {
  @override
  String get tableName => 'blogs';

  @override
  PlainBlog get modelSample => PlainBlog(title: '');

  @override
  PlainBlog fromCacheJson(Map<String, dynamic> json) => PlainBlog(id: json['id'] as int?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'relation_migration_${counter++}', persistent: true));
  tearDown(() => db.close());

  test('many-to-many → owned list: the links move into the reference column', () async {
    final UserProvider users = UserProvider();
    await db.open([users, PostProvider()]);
    expect(users.relationLinks.single.type, FluentRelationType.manyToMany);
    await users.save(User(name: 'Ann', posts: [Post(title: 'a'), Post(title: 'b')]));
    await users.save(User(name: 'Bob', posts: [Post(title: 'c')]));

    final OwnedUserProvider owned = OwnedUserProvider();
    await db.restart([owned, OwnedPostProvider()]);
    expect(owned.relationLinks.single.type, FluentRelationType.many);
    final List<OwnedUser> all = await owned.findAll(orderBy: 'name');
    expect(all.first.posts.map((p) => p.title), unorderedEquals(['a', 'b']));
    expect(all.last.posts.single.title, 'c');
    expect(db.issues.map((i) => i.kind), containsAll([FluentIssueKind.relationDataMoved, FluentIssueKind.unusedLinkTable]));
  });

  test('owned list → many-to-many: the references are copied into the link table', () async {
    final OwnedUserProvider owned = OwnedUserProvider();
    await db.open([owned, OwnedPostProvider()]);
    await owned.save(OwnedUser(name: 'Ann', posts: [OwnedPost(title: 'a'), OwnedPost(title: 'b')]));

    final UserProvider users = UserProvider();
    await db.restart([users, PostProvider()]);
    expect(users.relationLinks.single.type, FluentRelationType.manyToMany);
    expect((await users.findAll()).single.posts.map((p) => p.title), unorderedEquals(['a', 'b']));
    expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.relationDataMoved));
  });

  test('a child linked to several owners is not moved: the links stay, a warning says why', () async {
    final UserProvider users = UserProvider();
    final PostProvider posts = PostProvider();
    await db.open([users, posts]);
    final Post shared = Post(title: 'shared');
    await users.save(User(name: 'Ann', posts: [shared]));
    final Post stored = (await posts.findAll()).single;
    await users.save(User(name: 'Bob', posts: [stored]));

    final OwnedUserProvider owned = OwnedUserProvider();
    await db.restart([owned, OwnedPostProvider()]);
    expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.relationChanged));
    expect(await owned.db.query('posts_users'), hasLength(2), reason: 'the links are kept');
  });

  test('a link table of another shape is rebuilt and keeps its links', () async {
    final UserProvider users = UserProvider();
    await db.open([users, PostProvider()]);
    await users.save(User(name: 'Ann', posts: [Post(title: 'a')]));
    // An older version stored an extra column in the link table.
    await users.db.execute('ALTER TABLE posts_users ADD COLUMN "extra" TEXT');
    await users.db.execute(r"UPDATE __fluent_schema SET snapshot = json_remove(snapshot, '$.fingerprint')"); // written by that version

    final UserProvider again = UserProvider();
    await db.restart([again, PostProvider()]);
    final List<String> columns = [for (final r in await again.db.rawQuery('PRAGMA table_info("posts_users")')) r['name']! as String];
    expect(columns, isNot(contains('extra')));
    expect((await again.findAll()).single.posts.single.title, 'a');
  });

  test('an archived reference column no longer acts: deleting the old owner keeps the rows', () async {
    final BlogProvider blogs = BlogProvider();
    await db.open([blogs, PostProvider()]);
    await blogs.save(Blog(title: 'b', posts: [Post(title: 'kept')]));

    final PlainBlogProvider plain = PlainBlogProvider();
    final PostProvider posts = PostProvider();
    await db.restart([plain, posts]);
    final String sql = (await posts.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'posts'")).single['sql']! as String;
    expect(sql, isNot(contains('REFERENCES')), reason: 'archives lose their rules');

    await plain.deleteAll(await plain.findAll());
    final List<Map<String, Object?>> rows = await posts.db.query('posts');
    expect(rows.single['title'], 'kept');
    expect(rows.single['__fluent_removed_owner_id_r2'], isNotNull, reason: 'the archived value stays as it was');
  });
}
