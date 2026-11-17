// The examples of the README, the guide and the skills, compiled and run: if the API changes, this file breaks first.
// The setup examples spell out default values on purpose (they document them).
// ignore_for_file: avoid_redundant_argument_values
import 'dart:async';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

// --- skills/fluent-sqflite-models ------------------------------------------------------------------------------------

enum Status { draft, published }

class Post extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Post({this.id, required this.title, this.status = Status.draft, this.tags = const [], this.rating});

  final int? id;
  final String title;
  final Status status;
  final List<String> tags;
  final double? rating;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'status': status, 'tags': tags, 'rating': rating};

  @override
  Map<String, List<Enum>> get enumValues => {'status': Status.values};

  @override
  List<FluentIndex> get indexes => [const FluentIndex(['status', 'created_at'])];

  static Post fromJson(Map<String, dynamic> json) => Post(
    id: json['id'] as int?,
    title: json['title'] as String,
    status: json['status'] as Status,
    tags: (json['tags'] as List).cast<String>(),
    rating: json['rating'] as double?,
  );
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '', tags: const [''], rating: 0);

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post.fromJson(json);

  @override
  Post Function(Map<String, dynamic> json)? get isolateFactory => Post.fromJson;
}

// --- skills/fluent-sqflite-relations ---------------------------------------------------------------------------------

class Person extends FluentStorable {
  Person({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Comment extends FluentStorable {
  Comment({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class Tag extends FluentStorable {
  Tag({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.author, this.comments, this.tags});

  final int? id;
  final String title;
  final Person? author;
  final List<Comment>? comments;
  final List<Tag>? tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Article, Person>('author', (a) => a.author),
    FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'id'),
    FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags, lazy: true),
  ];
}

class PersonProvider extends FluentProvider<Person> {
  @override
  String get tableName => 'people';

  @override
  Person get modelSample => Person(name: '');

  @override
  Person fromCacheJson(Map<String, dynamic> json) => Person(id: json['id'] as int?, name: json['name'] as String);
}

class CommentProvider extends FluentProvider<Comment> {
  @override
  String get tableName => 'comments';

  @override
  Comment get modelSample => Comment(text: '');

  @override
  Comment fromCacheJson(Map<String, dynamic> json) => Comment(id: json['id'] as int?, text: json['text'] as String);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'tags';

  @override
  Tag get modelSample => Tag(label: '');

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(id: json['id'] as int?, label: json['label'] as String);
}

class ArticleProvider extends FluentProvider<Article> {
  @override
  String get tableName => 'articles';

  @override
  Article get modelSample => Article(title: '');

  @override
  Article fromCacheJson(Map<String, dynamic> json) => Article(
    id: json['id'] as int?,
    title: json['title'] as String,
    author: json['author'] as Person?,
    comments: (json['comments'] as List?)?.cast<Comment>(),
    tags: (json['tags'] as List?)?.cast<Tag>(),
  );
}

// --- doc/relations.md: relations without declarations, through, oneOf ----------------------------------------------

class Member extends FluentStorable {
  Member({this.id, required this.name, this.notes = const [], this.card});

  final int? id;
  final String name;
  final List<Note> notes;
  final Card? card;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'notes': notes, 'card': card};
}

class Note extends FluentStorable {
  Note({this.id, required this.text, this.author});

  final int? id;
  final String text;
  final Member? author;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'author': author};
}

class Card extends FluentStorable {
  Card({this.id, required this.number, this.member});

  final int? id;
  final String number;
  final Member? member;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'number': number, 'member': member};
}

class Team extends FluentStorable with FluentRelations {
  Team({this.id, required this.title, this.seats = const [], this.members = const []});

  final int? id;
  final String title;
  final List<Seat> seats;
  final List<Member> members;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<Team, Seat>('seats', (t) => t.seats),
    FluentRelation.through<Team, Seat, Member>('members', (t) => t.members),
  ];
}

/// The link with its data: who sits in which team, with a role.
class Seat extends FluentStorable {
  Seat({this.id, required this.role, this.team, this.member});

  final int? id;
  final String role;
  final Team? team;
  final Member? member;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'role': role, 'team': team, 'member': member};
}

class Like extends FluentStorable with FluentRelations {
  Like({this.id, this.target});

  final int? id;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.oneOf<Like>('target', (l) => l.target, types: [Note, Card]),
  ];
}

class MemberProvider extends FluentProvider<Member> {
  @override
  String get tableName => 'members';

  @override
  Member get modelSample => Member(name: '', card: Card(number: ''));

  @override
  Member fromCacheJson(Map<String, dynamic> json) =>
      Member(id: json['id'] as int?, name: json['name'] as String, notes: (json['notes'] as List?)?.cast<Note>() ?? const [], card: json['card'] as Card?);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '', author: Member(name: ''));

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String, author: json['author'] as Member?);
}

class CardProvider extends FluentProvider<Card> {
  @override
  String get tableName => 'cards';

  @override
  Card get modelSample => Card(number: '', member: Member(name: ''));

  @override
  Card fromCacheJson(Map<String, dynamic> json) => Card(id: json['id'] as int?, number: json['number'] as String, member: json['member'] as Member?);
}

class TeamProvider extends FluentProvider<Team> {
  @override
  String get tableName => 'teams';

  @override
  Team get modelSample => Team(title: '');

  @override
  Team fromCacheJson(Map<String, dynamic> json) =>
      Team(id: json['id'] as int?, title: json['title'] as String, seats: (json['seats'] as List?)?.cast<Seat>() ?? const [], members: (json['members'] as List?)?.cast<Member>() ?? const []);
}

class SeatProvider extends FluentProvider<Seat> {
  @override
  String get tableName => 'seats';

  @override
  Seat get modelSample => Seat(role: '', team: Team(title: ''), member: Member(name: ''));

  @override
  Seat fromCacheJson(Map<String, dynamic> json) => Seat(id: json['id'] as int?, role: json['role'] as String);
}

class LikeProvider extends FluentProvider<Like> {
  @override
  String get tableName => 'likes';

  @override
  Like get modelSample => Like();

  @override
  Like fromCacheJson(Map<String, dynamic> json) => Like(id: json['id'] as int?, target: json['target'] as FluentStorable?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late PostProvider posts;
  late ArticleProvider articles;

  setUp(() async {
    db = FluentTestDb(name: 'docs_${DateTime.now().microsecondsSinceEpoch}');
    posts = PostProvider();
    articles = ArticleProvider();
    await db.open([posts, articles, PersonProvider(), CommentProvider(), TagProvider()]);
  });

  tearDown(() => db.close());

  test('reading and writing examples (queries / writes skills, README)', () async {
    final Post post = Post(title: 'Hello dart', tags: const ['a'], rating: 4.5);
    final FluentSaveResult r = await posts.save(post);
    expect(r.inserted, 1);
    expect(post.primaryKeyValue, isNotNull, reason: 'the generated id');

    await posts.saveAll([for (int i = 0; i < 5; i++) Post(title: 'p$i', rating: i.toDouble())]);
    final List<Post> drafts = await posts.find(
      where: FluentFilter.eq('status', Status.draft).and(FluentFilter.contains('title', 'dart')),
      orderBy: 'created_at DESC',
      limit: 20,
    );
    expect(drafts.single.tags, ['a']);
    expect(await posts.count(where: FluentFilter.gte('rating', 4.0)), 2);

    await posts.updateById(post.primaryKeyValue, {'status': Status.published});
    expect((await posts.findById(post.primaryKeyValue))?.status, Status.published);

    FluentPage<Post> page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 4);
    final List<Post> shown = [...page.items];
    while (page.hasMore) {
      page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 4, after: page.next);
      shown.addAll(page.items);
    }
    expect(shown, hasLength(6));

    await FluentDb.transaction(() async {
      await posts.save(Post(title: 'in tx'));
      await posts.deleteWhere(FluentFilter.eq('title', 'p0'));
    });
    expect((await posts.trash.find()).single.title, 'p0', reason: 'soft delete goes to the trash');
    await posts.trash.restoreWhere(FluentFilter.eq('title', 'p0'));
    await posts.trash.deleteForeverWhere(FluentFilter.ids([post.primaryKeyValue]));
    expect(await posts.withTrash.exists(post.primaryKeyValue), isFalse);
  });

  test('relation examples (relations skill)', () async {
    final Tag dart = Tag(label: 'dart');
    await articles.save(Article(title: 'Hi', author: Person(name: 'Ann'), comments: [Comment(text: 'first')], tags: [dart]));
    final Article a = (await articles.findAll()).single;
    expect(a.author?.name, 'Ann');
    expect(a.comments?.single.text, 'first');
    expect(a.tags, isNull, reason: 'lazy');
    final Article withTags = await articles.loadRelations(a, names: ['tags']);
    expect(withTags.tags?.single.label, 'dart');
    expect(await articles.countRelated(a, 'comments'), 1);
    await articles.attach(a, 'tags', [Tag(label: 'flutter')]);
    expect((await articles.loadRelations(a, names: ['tags'])).tags, hasLength(2));
  });

  test('relations loaded later, queried and followed back (relations guide and skill)', () async {
    final Person ann = Person(name: 'Ann');
    await Article(title: 'Hi', author: ann, comments: [Comment(text: 'first'), Comment(text: 'second')], tags: [Tag(label: 'dart')]).save();
    final Article bare = (await FluentDb.findFirst<Article>(relations: FluentLoad.none))!;
    expect(bare.isRelationLoaded('comments'), isFalse);
    final Article full = await bare.loadRelations();
    expect(full.tags?.single.label, 'dart', reason: 'lazy ones too');
    expect((await bare.loadRelations(names: ['comments'])).comments, hasLength(2));
    expect((await full.findRelated<Comment>('comments', orderBy: 'id DESC', limit: 1)).single.text, 'second');
    expect(await full.countRelated('comments'), 2);
    final Comment first = full.comments!.first;
    expect((await first.findParents<Article>()).firstOrNull?.title, 'Hi');
    final Person stored = (await FluentDb.findFirst<Person>())!;
    expect((await stored.findParents<Article>(via: 'author')).single.title, 'Hi');
    await full.attach('tags', [Tag(label: 'flutter')]);
    expect(await full.countRelated('tags'), 2);
  });

  test('model calls, tags, change kinds and reset (models / writing guide, writes skill)', () async {
    final Post post = Post(title: 'Hello');
    await post.save();
    await post.delete();
    expect(post.isDeleted, isTrue);
    await post.restore();
    expect((await post.refresh())?.title, 'Hello');
    expect((await posts.findByIds([post.primaryKeyValue])).single.title, 'Hello');

    final List<String> seen = [];
    final StreamSubscription<FluentChangeEvent<Post>> sub = FluentDb.onEvent<Post>(tag: 'sync').listen((e) => seen.add(e.kind.name));
    await posts.saveAll([Post(title: 'from server')], tag: 'sync');
    await pumpEventQueue();
    expect(seen, ['save']);
    await sub.cancel();

    await FluentDb.clear(dbKey: FluentDbKey(db.name));
    expect(await posts.count(), 0);
    await FluentDb.deleteDatabases();
    expect(FluentDb.isOpen(), isTrue);
  });

  test('computed updates and existsWhere (writing / reading guide, writes / queries skills)', () async {
    final Post post = Post(title: 'p', rating: 1);
    await post.save();
    await posts.updateById(post.primaryKeyValue, {'rating': FluentUpdate.increment(2)});
    expect((await post.refresh())?.rating, 3);
    expect(await posts.existsWhere(FluentFilter.eq('title', 'p')), isTrue);
    expect(await FluentDb.existsWhere<Post>(FluentFilter.eq('title', 'x')), isFalse);
  });

  test('model-level query examples (reading guide, queries / relations skills)', () async {
    await articles.save(Article(title: 'Hi', author: Person(name: 'Ann'), comments: [Comment(text: 'first')]));
    await articles.save(Article(title: 'Quiet'));
    expect((await articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann')))).single.title, 'Hi');
    expect((await articles.find(where: FluentFilter.notRelated('comments'))).single.title, 'Quiet');
    expect(await articles.find(where: FluentFilter.relatedCount('comments', min: 5)), isEmpty);

    await posts.saveAll([Post(title: 'a', rating: 2), Post(title: 'b', status: Status.published, rating: 4)]);
    final List<Map<String, dynamic>> rows = await posts.findMaps(columns: ['id', 'title', 'created_at'], orderBy: 'id');
    expect(rows.first['created_at'], isA<DateTime>());
    expect(await posts.pluck<Status>('status', distinct: true, orderBy: 'status'), [Status.draft, Status.published]);
    expect(await posts.sum('rating'), 6);
    final List<Map<String, dynamic>> byStatus = await posts.aggregate(
      groupBy: ['status'],
      values: {'posts': const FluentAggregate.count(), 'rating': const FluentAggregate.avg('rating')},
      orderBy: 'rating DESC',
    );
    expect(byStatus.first['status'], Status.published);
    expect(await posts.watchValue(() => posts.sum('rating')).first, 6);
  });

  test('settings examples (models guide and skill, performance guide)', () async {
    const FluentConfig global = FluentConfig(trashRetention: Duration(days: 30));
    expect(global.indexReferences, isTrue);
    expect(FluentDbConfig.highIntegrity.journalMode, SQLiteJournalMode.delete);
    expect(const FluentTableConfig(trashRetention: Duration(days: 90)).fullText, isNull, reason: 'null = follow the database');
    await posts.findAll();
    final FluentQueryStats stats = FluentDb.queryStats(table: 'posts');
    expect(stats.queries, isNotEmpty);
    FluentDb.configure(const FluentConfig(optimizeInterval: null));
    expect(FluentDb.config.optimizeInterval, isNull);
    FluentDb.configure(const FluentConfig());
  });

  test('expired rows, logging sink and init without config (writing guide, setup and troubleshooting skills)', () async {
    final Post session = Post(title: 's')..timeToLive = const Duration(hours: 1);
    await posts.save(session);
    db.clock.advance(const Duration(hours: 2));
    expect(await posts.updateById(session.primaryKeyValue, {'rating': 3.0}), 0, reason: 'an expired row is missing');
    expect(await posts.updateById(session.primaryKeyValue, {'rating': 3.0}, includeExpired: true), 1);
    expect(await posts.updateWhere(FluentFilter.eq('title', 's'), {'rating': 4.0}, includeExpired: true), 1);

    FluentDb.setupLogging(onRecord: (_) {});
    FluentDb.setupLogging(removeOnRecord: true); // onRecord: null would keep the sink

    await db.close();
    FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 3)));
    await FluentDb.init([FluentGroup(dbKey: FluentDbKey('docs_init'), providerList: [PostProvider()], inMemory: true)]);
    try {
      expect(FluentDb.config.trashRetention, const Duration(days: 3), reason: 'init without config keeps what configure set');
    } finally {
      await FluentDb.close();
      FluentDb.configure(const FluentConfig());
    }
  });

  test('sync examples (sync guide and skill)', () async {
    final FluentRemoteEvent<Post> event = await posts
        .watchRemote(fetch: () async => const FluentRemoteResponse<Post>.failed(503), maxAge: const Duration(minutes: 5), keepWatching: false)
        .last;
    expect(event.hasError && event.phase == FluentRemotePhase.failed, isTrue);
    expect(const FluentConflictPolicy<Post>.keepServer().serverWins, isTrue);
    expect(const FluentPushResult<Post>.accepted().isAccepted, isTrue);
    expect(const FluentTableConfig(serverKey: ['server_id']).serverKey, ['server_id']);
    const FluentSyncStatus status = FluentSyncStatus(state: FluentSyncState.idle, pending: 3);
    expect(status.hasPending && !status.isSyncing, isTrue);
  });

  test('analyzer examples (performance guide, troubleshooting skill)', () async {
    FluentDb.setupLogging(mute: {'unordered:*', 'missingIndex:app:logs:*'});
    const FluentConfig release = FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true));
    expect(release.diagnostics.hintsInRelease, isTrue);
    expect(FluentDiagnostics.auto.tuning, FluentTuning.full);
    expect(FluentTuning.full.copyWith(indexes: false), FluentTuning.noIndexes);
    final FluentReport report = FluentDb.report();
    expect(report.toString(), isNotEmpty);
    for (final FluentIssue h in report.ofType(FluentIssueType.hint)) {
      expect(h.key, startsWith('${h.kind.name}:'));
    }
    final StreamSubscription<FluentIssue> crashes = FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error}).listen((_) {});
    await crashes.cancel();
    FluentDb.setupLogging(mute: const {});
  });

  test('relations without declarations, through and oneOf (relations guide and skill)', () async {
    await db.close();
    final MemberProvider members = MemberProvider();
    final TeamProvider teams = TeamProvider();
    final LikeProvider likes = LikeProvider();
    final FluentTestDb other = FluentTestDb(name: 'docs_relations');
    await other.open([members, NoteProvider(), CardProvider(), teams, SeatProvider(), likes]);

    // Found in buildJson: notes (Note.author points back) and a one-to-one card.
    await members.save(Member(name: 'Ann', notes: [Note(text: 'hi')], card: Card(number: '42')));
    final Member ann = (await members.findAll()).single;
    expect(ann.notes.single.text, 'hi');
    expect(ann.card?.number, '42');
    expect(other.issues.where((i) => i.kind == FluentIssueKind.autoRelations), isNotEmpty);

    // through: the seat carries the role.
    await teams.save(Team(title: 'core'));
    final Team core = (await teams.findAll()).single;
    await core.attach('members', [ann], link: (_) => Seat(role: 'lead'));
    expect((await teams.findAll()).single.members.single.name, 'Ann');
    expect(await teams.count(where: FluentFilter.related('members', FluentFilter.eq('name', 'Ann'))), 1);

    // oneOf: a like on a note or a card.
    await likes.save(Like(target: ann.notes.single));
    expect((await likes.findAll()).single.target, isA<Note>());
    expect(await likes.count(where: FluentFilter.related<Note>('target', FluentFilter.eq('text', 'hi'))), 1);
    expect(await likes.count(where: FluentFilter.related<Card>('target')), 0);
    await other.close();
  });

  test('migration plan (schema guide and skill)', () async {
    final List<FluentMigrationPlan> plans = await FluentDb.planMigrations([
      FluentGroup(dbKey: FluentDbKey('docs_plan'), providerList: [PostProvider()], onMigrationPlan: (plan) => !plan.losesData),
    ]);
    final FluentMigrationPlan plan = plans.single;
    expect(plan.isNewDatabase, isTrue);
    expect(plan.losesData, isFalse);
    expect(plan.changes.first.kind, FluentSchemaChangeKind.createTable);
    expect('$plan', contains('created table'));
  });

  test('settings, priorities, pause and lifecycle (setup skill)', () async {
    // The settings objects of the skill compile with these values.
    final List<Object> settings = [
      const FluentConfig(diagnostics: FluentDiagnostics.recommend, isolateMapping: FluentIsolateMapping.smart, sliceAfterRows: 300, fullText: FluentFullText.auto),
      FluentDbConfig.highIntegrity,
      FluentDbConfig(journalMode: SQLiteJournalMode.wal, synchronous: SQLiteSynchronous.normal, cacheSize: SQLiteCacheSize.megaBytes(20), busyTimeout: const Duration(seconds: 5)),
      const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601, isolateMapping: FluentIsolateMapping.always, trashRetention: Duration(days: 90)),
      FluentDiagnostics(tuning: FluentTuning.full.copyWith(indexes: false)),
      FluentGroup(dbKey: FluentDbKey('docs_setup'), providerList: [PostProvider()], removedColumns: FluentColumnRemoval.archive, onMigrationPlan: (plan) => !plan.losesData),
    ];
    expect(settings, hasLength(6));

    await posts.save(Post(title: 'p'));
    expect(await posts.find(policy: ExecutionPolicy.fast), hasLength(1));
    await FluentDb.pauseQueue(dbKey: db.key);
    try {
      expect(FluentDb.isOpen(dbKey: db.key), isTrue); // the file is quiet here (e.g. copy it)
    } finally {
      FluentDb.resumeQueue(dbKey: db.key);
    }
    expect(await posts.count(policy: ExecutionPolicy.background), 1);
  });

  test('filters, rawQuery, savepoints and library columns (reading / writing guides, queries / writes skills)', () async {
    await posts.saveAll([Post(title: '50% off'), Post(title: '500 points', status: Status.published)]);
    expect((await posts.find(where: FluentFilter.contains('title', '50%'))).map((p) => p.title), ['50% off']);
    expect(await posts.count(where: FluentFilter.eq('status', Status.published)), 1);
    expect(() => posts.rawQuery('WITH q AS (SELECT 1) DELETE FROM posts'), throwsA(isA<FluentArgumentException>()));
    expect(await posts.rawQuery('SELECT COUNT(*) AS n FROM posts'), [{'n': 2}]);

    await FluentDb.transaction(() async {
      await posts.save(Post(title: 'kept'));
      try {
        await posts.updateWhere(FluentFilter.eq('id', 1), {'deleted_at': null}); // library column: use trash.restore
      } on FluentArgumentException {
        // a caught error rolls back only its own call (a savepoint); the save above stays
      }
    });
    expect(await posts.count(), 3);
  });

  test('error examples (troubleshooting skill)', () async {
    final FluentFilter sameTitle = FluentFilter.eq('title', 'x');
    expect(sameTitle.whereArgs, ['x']);
    try {
      await posts.find(where: const FluentFilter('"nope" = 1'));
      fail('expected an error');
    } on FluentException catch (e) {
      expect(e.code, FluentErrorCode.sqlError);
      expect(e.hint, isNotNull);
    }
  });

  test('known bugs fixes: utc epoch converter, copyWith clears with null, converter value check', () {
    const FluentEpochDateTimeConverter converter = FluentEpochDateTimeConverter(utc: true);
    final DateTime at = DateTime.utc(2026, 11, 4, 9);
    expect(converter.fromSql(converter.toSql(at)), at);
    expect(converter.acceptsValue(at), isTrue);
    expect(converter.acceptsValue(1700000000000), isFalse, reason: 'a stored value is used as it is in filters');
    final FluentGroup group = FluentGroup(dbKey: FluentDbKey('docs_copy'), providerList: const []);
    expect(group.copyWith(archiveRetention: null).archiveRetention, isNull);
    expect(group.copyWith(historyLimit: 5).archiveRetention, group.archiveRetention);
    expect(FluentDbColumn.text('note', defaultValue: 'x').copyWith(defaultValue: null).defaultValue, isNull);
  });

  test('audit 2 fixes: withTrash pluck / countDistinct, redacted errors, enum converter, NaN, FluentDb.trash', () async {
    await posts.saveAll([Post(title: 'a', rating: 1), Post(title: 'b', rating: 1)]);
    final Post gone = Post(title: 'c', rating: 2);
    await posts.save(gone);
    await posts.delete(gone);
    expect(await posts.withTrash.pluck<String>('title', orderBy: 'title'), ['a', 'b', 'c']);
    expect(await posts.withTrash.countDistinct('rating'), 2);
    expect(await FluentDb.trash<Post>().count(), 1);

    const FluentRedactedError redacted = FluentRedactedError(type: 'SqfliteFfiException', message: 'UNIQUE constraint failed');
    expect('$redacted', 'SqfliteFfiException: UNIQUE constraint failed');

    const FluentEnumConverter<Status> lenient = FluentEnumConverter(Status.values, nullIfUnknown: true);
    expect(lenient.nullIfUnknown, isTrue);

    await expectLater(posts.save(Post(title: 'nan', rating: double.nan)), throwsA(isA<FluentArgumentException>()));
    await expectLater(posts.find(limit: -1), throwsA(isA<FluentArgumentException>()));
  });

  test('round 3: paged watchRemote, batchKeys, provider policy', () async {
    final List<String> titles = [];
    final Stream<FluentRemoteEvent<Post>> stream = posts.watchRemote(
      fetchPage: (request) async {
        final int page = request.page;
        return FluentRemoteResponse([Post(title: 'p$page')], hasMore: page < 1, cursor: 'after-$page');
      },
      store: FluentRemoteStore.mirror,
      keepWatching: false,
    );
    await for (final FluentRemoteEvent<Post> e in stream) {
      if (e.isFresh) titles.addAll(e.items.map((p) => p.title));
    }
    expect(titles..sort(), ['p0', 'p1']);

    const FluentTableConfig config = FluentTableConfig(batchKeys: FluentBatchKeys.fromModels);
    expect(config.batchKeys, FluentBatchKeys.fromModels);
    expect(const FluentConfig().batchKeys, FluentBatchKeys.fromRows);
    expect(posts.policy, const ExecutionPolicy());
  });

  test('round 3: FluentCancelToken stops syncWithServer', () async {
    final FluentCancelToken token = FluentCancelToken()..cancel();
    expect(token.isCancelled, isTrue);
    const FluentSyncResult<Post> done = FluentSyncResult(strategy: FluentSyncStrategy.pull, isSuccess: false, isCancelled: true);
    expect(done.isCancelled, isTrue);
    expect('$done', contains('cancelled'));
    expect(FluentErrorCode.syncCancelled.name, 'syncCancelled');
  });
}
