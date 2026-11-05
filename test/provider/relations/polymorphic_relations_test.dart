// FluentRelation.oneOf: a reference to one model of several types (a comment on a post, a photo or a video).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Comment extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Comment({this.id, required this.text, this.target});

  final int? id;
  final String text;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.oneOf<Comment>('target', (c) => c.target, types: [Post, Photo, Video, DayStat]),
  ];
}

/// Declares its comments: they belong to the post (deleted and restored with it).
class Post extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Post({this.id, required this.title, this.comments = const []});

  final int? id;
  final String title;
  final List<Comment> comments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target'),
  ];
}

/// Declares nothing: the comments field is found in buildJson and goes through Comment.target.
class Photo extends FluentStorable {
  Photo({this.id, required this.url, this.comments = const []});

  final int? id;
  final String url;
  final List<Comment> comments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'url': url, 'comments': comments};
}

/// No list of comments: deleting a video only clears the references.
class Video extends FluentStorable {
  Video({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

/// A composite key: the reference uses target_user_id + target_day; its comments are owned through `via`.
class DayStat extends FluentStorable with FluentRelations {
  DayStat({required this.userId, required this.day, this.views = 0, this.comments = const []});

  final int userId;
  final String day;
  final int views;
  final List<Comment> comments;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')];

  @override
  Map<String, dynamic> buildJson() => {'user_id': userId, 'day': day, 'views': views};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<DayStat, Comment>('comments', (s) => s.comments, via: 'target'),
  ];
}

class DayStatProvider extends FluentProvider<DayStat> {
  @override
  String get tableName => 'day_stats';

  @override
  DayStat get modelSample => DayStat(userId: 0, day: '');

  @override
  DayStat fromCacheJson(Map<String, dynamic> json) => DayStat(
    userId: json['user_id'] as int,
    day: json['day'] as String,
    views: json['views'] as int,
    comments: (json['comments'] as List?)?.cast<Comment>() ?? const [],
  );
}

class CommentProvider extends FluentProvider<Comment> {
  @override
  String get tableName => 'comments';

  @override
  Comment get modelSample => Comment(text: '');

  @override
  Comment fromCacheJson(Map<String, dynamic> json) => Comment(id: json['id'] as int?, text: json['text'] as String, target: json['target'] as FluentStorable?);
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '');

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(id: json['id'] as int?, title: json['title'] as String, comments: (json['comments'] as List?)?.cast<Comment>() ?? const []);
}

class PhotoProvider extends FluentProvider<Photo> {
  @override
  String get tableName => 'photos';

  @override
  Photo get modelSample => Photo(url: '');

  @override
  Photo fromCacheJson(Map<String, dynamic> json) => Photo(id: json['id'] as int?, url: json['url'] as String, comments: (json['comments'] as List?)?.cast<Comment>() ?? const []);
}

class VideoProvider extends FluentProvider<Video> {
  @override
  String get tableName => 'videos';

  @override
  Video get modelSample => Video(title: '');

  @override
  Video fromCacheJson(Map<String, dynamic> json) => Video(id: json['id'] as int?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late CommentProvider comments;
  late PostProvider posts;
  late PhotoProvider photos;
  late VideoProvider videos;
  late DayStatProvider stats;

  setUp(() async {
    comments = CommentProvider();
    posts = PostProvider();
    photos = PhotoProvider();
    videos = VideoProvider();
    stats = DayStatProvider();
    db = FluentTestDb();
    await db.open([comments, posts, photos, videos, stats]);
  });

  tearDown(() => db.close());

  Future<Comment> comment(String text) async => (await comments.find(where: FluentFilter.eq('text', text))).single;

  test('a reference stores the table and the key; it loads as the right model', () async {
    await comments.saveAll([Comment(text: 'on post', target: Post(title: 'p')), Comment(text: 'on photo', target: Photo(url: 'u'))]);

    final Map<String, Object?> row = (await comments.db.query('comments', where: 'text = ?', whereArgs: ['on post'])).single;
    expect(row['target_type'], 'posts');
    expect((await comment('on post')).target, isA<Post>().having((p) => p.title, 'title', 'p'));
    expect((await comment('on photo')).target, isA<Photo>().having((p) => p.url, 'url', 'u'));
  });

  test('a list through the reference holds only the rows of its own table, also with equal keys', () async {
    final Post post = Post(title: 'p');
    final Photo photo = Photo(url: 'u');
    await posts.save(post);
    await photos.save(photo); // the same id 1 in another table
    await comments.saveAll([Comment(text: 'a', target: post), Comment(text: 'b', target: photo), Comment(text: 'c', target: photo)]);

    expect((await posts.findAll()).single.comments.map((c) => c.text), ['a']);
    expect((await photos.findAll()).single.comments.map((c) => c.text), unorderedEquals(['b', 'c']));
    expect(photos.relationLinks.single.type, FluentRelationType.many, reason: 'found in buildJson, through Comment.target');
  });

  test('saving an owner saves its list with the reference filled in', () async {
    await posts.save(Post(title: 'p', comments: [Comment(text: 'first'), Comment(text: 'second')]));
    final Post loaded = (await posts.findAll()).single;
    expect(loaded.comments.map((c) => c.text), unorderedEquals(['first', 'second']));
    expect((await comment('first')).target, isA<Post>());
  });

  test('deleting: an owning side takes its rows along, the trash brings them back; otherwise the reference is cleared', () async {
    final Post post = Post(title: 'p');
    final Video video = Video(title: 'v');
    await comments.saveAll([Comment(text: 'on post', target: post), Comment(text: 'on video', target: video)]);

    await posts.delete((await posts.findAll()).single);
    expect(await comments.count(), 1, reason: 'the comment of the post went to the trash with it');
    await posts.trash.restore((await posts.trash.find()).single);
    expect(await comments.count(), 2);

    await posts.trash.deleteForever((await posts.findAll()).single);
    expect(await comments.withTrash.count(), 1, reason: 'deleted for good with the post');

    await videos.delete((await videos.findAll()).single); // not soft-deletable: deleted for good
    final Comment kept = await comment('on video');
    expect(kept.target, isNull);
    expect((await comments.db.query('comments')).single['target_type'], isNull);
  });

  test('filters: from the owning side, and on the reference itself over its types', () async {
    await comments.saveAll([Comment(text: 'a', target: Post(title: 'with')), Comment(text: 'b', target: Photo(url: 'x')), Comment(text: 'c')]);
    await posts.save(Post(title: 'without'));

    expect((await posts.find(where: FluentFilter.related('comments'))).single.title, 'with');
    Future<List<String>> texts(FluentFilter where) async => [for (final Comment c in await comments.find(where: where, orderBy: 'text')) c.text];
    expect(await texts(FluentFilter.related('target')), ['a', 'b']);
    expect(await texts(FluentFilter.notRelated('target')), ['c']);
    expect(await texts(FluentFilter.related<Post>('target', FluentFilter.eq('title', 'with'))), ['a']);
    expect(await texts(FluentFilter.related<Photo>('target')), ['b']);
    expect(await texts(FluentFilter.relatedCount<Post>('target', min: 1)), ['a']);
    await expectLater(comments.find(where: FluentFilter.related<Comment>('target')), throwsA(isA<FluentArgumentException>()));
  });

  test('a type with a composite key: one column per key column, loading, owned list, cascade', () async {
    final DayStat stat = DayStat(userId: 7, day: '2026-10-20', views: 3);
    await comments.save(Comment(text: 'busy day', target: stat));
    final Map<String, Object?> row = (await comments.db.query('comments')).single;
    expect([row['target_type'], row['target_user_id'], row['target_day'], row['target_id']], ['day_stats', 7, '2026-10-20', null]);

    expect((await comment('busy day')).target, isA<DayStat>().having((s) => s.views, 'views', 3));
    expect((await stats.findAll()).single.comments.single.text, 'busy day');
    expect(await comments.count(where: FluentFilter.related<DayStat>('target', FluentFilter.gt('views', 1))), 1);

    await stats.delete((await stats.findAll()).single);
    expect(await comments.withTrash.count(), 0, reason: 'the list is owned: deleted with the stat');
  });

  test('a model that is not one of the types is reported and not saved as a reference', () async {
    await comments.save(Comment(text: 'odd', target: Comment(text: 'not allowed')));
    expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.relationValue));
    expect((await comment('odd')).target, isNull);
  });
}
