// Relations found in buildJson: models that hold other stored models and declare nothing.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class User extends FluentStorable {
  User({this.id, required this.name, this.posts = const [], this.profile});

  final int? id;
  final String name;
  final List<Post> posts;
  final Profile? profile;

  /// How often buildJson ran (saves read the found relations from one build).
  static int builds = 0;

  @override
  Map<String, dynamic> buildJson() {
    builds++;
    return {'id': id, 'name': name, 'posts': posts, 'profile': profile};
  }
}

class Post extends FluentStorable {
  Post({this.id, required this.title, this.author, this.tags = const []});

  final int? id;
  final String title;
  final User? author;
  final List<Tag> tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'author': author, 'tags': tags};
}

class Profile extends FluentStorable {
  Profile({this.id, required this.bio, this.user});

  final int? id;
  final String bio;
  final User? user;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'bio': bio, 'user': user};
}

class Tag extends FluentStorable {
  Tag({this.id, required this.label, this.posts = const []});

  final int? id;
  final String label;
  final List<Post> posts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label, 'posts': posts};
}

/// A model of a table that is not registered.
class Draft extends FluentStorable {
  Draft({this.id});

  final int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id};
}

class Note extends FluentStorable {
  Note({this.id, required this.text, this.drafts = const []});

  final int? id;
  final String text;
  final List<Draft> drafts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'drafts': drafts};
}

class UserProvider extends FluentProvider<User> {
  @override
  String get tableName => 'users';

  @override
  User get modelSample => User(name: '', profile: Profile(bio: ''));

  @override
  User fromCacheJson(Map<String, dynamic> json) => User(
    id: json['id'] as int?,
    name: json['name'] as String,
    posts: (json['posts'] as List?)?.cast<Post>() ?? const [],
    profile: json['profile'] as Profile?,
  );
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '', author: User(name: ''));

  @override
  Post fromCacheJson(Map<String, dynamic> json) =>
      Post(id: json['id'] as int?, title: json['title'] as String, author: json['author'] as User?, tags: (json['tags'] as List?)?.cast<Tag>() ?? const []);
}

class ProfileProvider extends FluentProvider<Profile> {
  @override
  String get tableName => 'profiles';

  @override
  Profile get modelSample => Profile(bio: '', user: User(name: ''));

  @override
  Profile fromCacheJson(Map<String, dynamic> json) => Profile(id: json['id'] as int?, bio: json['bio'] as String, user: json['user'] as User?);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'tags';

  @override
  Tag get modelSample => Tag(label: '');

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(id: json['id'] as int?, label: json['label'] as String, posts: (json['posts'] as List?)?.cast<Post>() ?? const []);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

Future<List<String>> columnsOf(FluentProvider p, String table) async => [for (final r in await p.db.rawQuery('PRAGMA table_info("$table")')) r['name']! as String];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late UserProvider users;
  late PostProvider posts;
  late ProfileProvider profiles;
  late TagProvider tags;

  setUp(() async {
    users = UserProvider();
    posts = PostProvider();
    profiles = ProfileProvider();
    tags = TagProvider();
    db = FluentTestDb();
    await db.open([users, posts, profiles, tags]);
  });

  tearDown(() => db.close());

  test('the kind of every field is decided from both sides', () async {
    String kind(FluentProvider p, String name) => p.relationLinks.singleWhere((FluentRelationLink l) => l.name == name).type.name;
    expect(kind(users, 'posts'), 'many', reason: 'Post.author points back');
    expect(kind(posts, 'author'), 'one');
    expect(kind(posts, 'tags'), 'manyToMany', reason: 'both sides list each other');
    expect(kind(tags, 'posts'), 'manyToMany');
    expect(kind(profiles, 'user'), 'one', reason: 'one-to-one: fewer relations point to Profile, so it stores the key');
    expect(kind(users, 'profile'), 'oneOwned');

    expect(await columnsOf(posts, 'posts'), containsAll(['author_id']));
    expect(await columnsOf(users, 'users'), isNot(contains('profile_id')), reason: 'one-to-one stores one key, not two');
    expect(await columnsOf(users, 'users'), isNot(contains('posts')), reason: 'relation fields are never columns');
    expect(await columnsOf(profiles, 'profiles'), contains('user_id'));
  });

  test('models are saved and loaded through the found relations', () async {
    await users.save(User(name: 'Ann', posts: [Post(title: 'a', tags: [Tag(label: 'x')]), Post(title: 'b')], profile: Profile(bio: 'hi')));

    final User ann = (await users.findAll()).single;
    expect(ann.posts.map((p) => p.title), unorderedEquals(['a', 'b']));
    expect(ann.profile?.bio, 'hi');
    final Post a = (await posts.find(where: FluentFilter.eq('title', 'a'))).single;
    expect(a.tags.single.label, 'x');
    expect(a.author?.name, 'Ann');
  });

  test('saving builds the json of a model once for all its found relations', () async {
    final User ann = User(name: 'Ann', posts: [Post(title: 'a')], profile: Profile(bio: 'hi'));
    User.builds = 0;
    await users.save(ann);
    expect(User.builds, lessThanOrEqualTo(3), reason: 'the row, its key, and one build for both relations (not one per relation)');
  });

  test('a hint lists the decided relations with declarations to copy', () async {
    final FluentIssue hint = db.issues.singleWhere((i) => i.kind == FluentIssueKind.autoRelations);
    // posts.author_id is also Post.author (a reference): one delete rule for both, the reference's.
    expect(hint.code, contains("FluentRelation.many<User, Post>('posts', (m) => m.posts, foreignKey: 'author_id', onDelete: FluentOnDelete.setNull),"));
    expect(hint.details, contains('share the reference posts.author_id'));
    // Copying the declaration keeps the decision exactly: the guessed one-to-one never deletes the profile.
    expect(hint.code, contains("FluentRelation.oneOwned<User, Profile>('profile', (m) => m.profile, foreignKey: 'user_id', onDelete: FluentOnDelete.setNull),"));
    expect(hint.code, contains('(add: with FluentRelations)'));
    expect(hint.details, contains('one-to-one'));
  });

  test('autoRelations: false keeps fields without declaration out of the database', () async {
    await db.close();
    final UserProvider plain = UserProvider();
    final FluentTestDb off = FluentTestDb(name: 'off');
    await off.open([plain, PostProvider(), ProfileProvider(), TagProvider()], fluentConfig: const FluentConfig(autoRelations: false));
    expect(plain.relationLinks, isEmpty);
    expect(await columnsOf(plain, 'users'), isNot(contains('posts')));
    await off.close();
  });

  test('autoRelations: false reports the fields it leaves out', () async {
    await db.close();
    final FluentTestDb off = FluentTestDb(name: 'off_report');
    await off.open([UserProvider(), PostProvider(), ProfileProvider(), TagProvider()], fluentConfig: const FluentConfig(autoRelations: false));
    expect(off.warnings.where((i) => i.kind == FluentIssueKind.relationDeclaration && i.subject == 'posts'), isNotEmpty);
    await off.close();
  });

  test('a field holding a model no provider stores is reported', () async {
    await db.close();
    final FluentTestDb other = FluentTestDb(name: 'unregistered');
    await other.open([NoteProvider()]);
    expect(other.warnings.where((i) => i.kind == FluentIssueKind.relationDeclaration && i.subject == 'drafts'), isNotEmpty);
    await other.close();
  });
}
