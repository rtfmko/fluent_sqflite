// Regression tests of the write path: strategies with relations, cascades (tombstones, polymorphic clean-up, trash
// purge), list replacement in chunks, field updates, deletedAt after delete, conflictOn on trashed rows, repeated
// models in one save.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';

// --- Three levels of owned, syncable tables -------------------------------------------------------------------------

class SFolder extends FluentStorable with FluentRelations {
  SFolder({this.id, required this.name, this.pages});

  final int? id;
  final String name;
  final List<SPage>? pages;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<SFolder, SPage>('pages', (f) => f.pages)];
}

class SPage extends FluentStorable with FluentRelations {
  SPage({this.id, required this.text, this.lines});

  final int? id;
  final String text;
  final List<SLine>? lines;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<SPage, SLine>('lines', (p) => p.lines)];
}

class SLine extends FluentStorable {
  SLine({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class SFolderProvider extends FluentProvider<SFolder> with FluentSyncable<SFolder> {
  @override
  String get tableName => 's_folders';

  @override
  SFolder get modelSample => SFolder(name: '');

  @override
  SFolder fromCacheJson(Map<String, dynamic> json) => SFolder(id: json['id'] as int?, name: json['name'] as String, pages: (json['pages'] as List?)?.cast<SPage>());
}

class SPageProvider extends FluentProvider<SPage> with FluentSyncable<SPage> {
  @override
  String get tableName => 's_pages';

  @override
  SPage get modelSample => SPage(text: '');

  @override
  SPage fromCacheJson(Map<String, dynamic> json) => SPage(id: json['id'] as int?, text: json['text'] as String, lines: (json['lines'] as List?)?.cast<SLine>());
}

class SLineProvider extends FluentProvider<SLine> with FluentSyncable<SLine> {
  @override
  String get tableName => 's_lines';

  @override
  SLine get modelSample => SLine(text: '');

  @override
  SLine fromCacheJson(Map<String, dynamic> json) => SLine(id: json['id'] as int?, text: json['text'] as String);
}

// --- A soft-deletable, syncable owner with soft-deletable, syncable children -----------------------------------------

class TFolder extends FluentStorable with FluentRelations, FluentSoftDeletable {
  TFolder({this.id, required this.name, this.pages});

  final int? id;
  final String name;
  final List<TPage>? pages;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<TFolder, TPage>('pages', (f) => f.pages)];
}

class TPage extends FluentStorable with FluentSoftDeletable {
  TPage({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class TFolderProvider extends FluentProvider<TFolder> with FluentSyncable<TFolder> {
  @override
  String get tableName => 't_folders';

  @override
  TFolder get modelSample => TFolder(name: '');

  @override
  TFolder fromCacheJson(Map<String, dynamic> json) => TFolder(id: json['id'] as int?, name: json['name'] as String, pages: (json['pages'] as List?)?.cast<TPage>());
}

class TPageProvider extends FluentProvider<TPage> with FluentSyncable<TPage> {
  @override
  String get tableName => 't_pages';

  @override
  TPage get modelSample => TPage(text: '');

  @override
  TPage fromCacheJson(Map<String, dynamic> json) => TPage(id: json['id'] as int?, text: json['text'] as String);
}

// --- Polymorphic notes on posts owned by a blog ---------------------------------------------------------------------

class RBlog extends FluentStorable with FluentRelations {
  RBlog({this.id, required this.name, this.posts});

  final int? id;
  final String name;
  final List<RPost>? posts;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<RBlog, RPost>('posts', (b) => b.posts)];
}

class RPost extends FluentStorable with FluentRelations {
  RPost({this.id, required this.title, this.notes});

  final int? id;
  final String title;
  final List<RNote>? notes;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<RPost, RNote>('notes', (p) => p.notes, via: 'target')];
}

class RNote extends FluentStorable with FluentRelations {
  RNote({this.id, required this.text, this.target});

  final int? id;
  final String text;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [FluentRelation.oneOf<RNote>('target', (n) => n.target, types: [RPost])];
}

class RBlogProvider extends FluentProvider<RBlog> {
  @override
  String get tableName => 'r_blogs';

  @override
  RBlog get modelSample => RBlog(name: '');

  @override
  RBlog fromCacheJson(Map<String, dynamic> json) => RBlog(id: json['id'] as int?, name: json['name'] as String, posts: (json['posts'] as List?)?.cast<RPost>());
}

class RPostProvider extends FluentProvider<RPost> {
  @override
  String get tableName => 'r_posts';

  @override
  RPost get modelSample => RPost(title: '');

  @override
  RPost fromCacheJson(Map<String, dynamic> json) => RPost(id: json['id'] as int?, title: json['title'] as String, notes: (json['notes'] as List?)?.cast<RNote>());
}

class RNoteProvider extends FluentProvider<RNote> {
  @override
  String get tableName => 'r_notes';

  @override
  RNote get modelSample => RNote(text: '');

  @override
  RNote fromCacheJson(Map<String, dynamic> json) => RNote(id: json['id'] as int?, text: json['text'] as String, target: json['target'] as FluentStorable?);
}

// --- Type metadata, soft-deletable tickets with a server key ---------------------------------------------------------

class MetaNote extends FluentStorable with FluentSoftDeletable {
  MetaNote({this.id, required this.title, this.syncedAt});

  final int? id;
  final String title;
  final DateTime? syncedAt;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'synced_at': syncedAt};
}

class MetaNoteProvider extends FluentProvider<MetaNote> with FluentSyncable<MetaNote> {
  @override
  String get tableName => 'meta_notes';

  @override
  MetaNote get modelSample => MetaNote(title: '', syncedAt: DateTime.utc(2000));

  @override
  MetaNote fromCacheJson(Map<String, dynamic> json) => MetaNote(id: json['id'] as int?, title: json['title'] as String, syncedAt: json['synced_at'] as DateTime?);
}

class STicket extends FluentStorable with FluentSoftDeletable {
  STicket({this.id, this.serverId, required this.title});

  final int? id;
  final String? serverId;
  final String title;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('server_id', isUnique: true), FluentDbColumn.text('title')];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'server_id': serverId, 'title': title};
}

class STicketProvider extends FluentProvider<STicket> with FluentSyncable<STicket> {
  @override
  String get tableName => 's_tickets';

  @override
  STicket get modelSample => STicket(title: '');

  @override
  STicket fromCacheJson(Map<String, dynamic> json) => STicket(id: json['id'] as int?, serverId: json['server_id'] as String?, title: json['title'] as String);
}

/// Pushes everything pending of [p] and returns the deleted keys it sent.
Future<List<Object>> pushAll<T extends FluentStorable>(FluentSyncable<T> p) async {
  final List<Object> keys = [];
  final FluentSyncResult<T> result = await p.syncWithServer(
    strategy: FluentSyncStrategy.push,
    onPush: (batch) async {
      keys.addAll(batch.deletedKeys);
      return const FluentPushResult.accepted();
    },
  );
  expect(result.isSuccess, isTrue, reason: result.errorMessage);
  return keys;
}

List<int> sortedInts(Iterable<Object?> values) => [for (final Object? v in values) v! as int]..sort();

void main() {
  setUpFluentTests();

  group('W1: the caller strategy applies to the root rows only', () {
    late FluentTestDb db;
    late ArticleProvider articles;
    late PersonProvider people;
    late CommentProvider comments;
    late TagProvider tags;

    setUp(() async {
      db = FluentTestDb(name: 'w1_${DateTime.now().microsecondsSinceEpoch}');
      articles = ArticleProvider();
      people = PersonProvider();
      comments = CommentProvider();
      tags = TagProvider();
      await db.open([people, ProfileProvider(), comments, tags, articles, CategoryProvider()]);
      await articles.save(Article(id: 1, title: 'a', author: Person(id: 1, name: 'ann')));
    });

    tearDown(() => db.close());

    Future<Map<String, Object?>> row() async => (await articles.db.query('articles', where: 'id = 1')).single;

    test('update(withRelations: true) saves new children, references and links', () async {
      final Person bob = Person(name: 'bob');
      final int updated = await articles.update(
        Article(id: 1, title: 'b', author: bob, comments: [Comment(text: 'c')], tags: [Tag(label: 't')]),
        withRelations: true,
      );
      expect(updated, 1);
      expect(bob.primaryKeyValue, isNotNull, reason: 'the new author is inserted');
      expect((await row())['author_id'], bob.primaryKeyValue, reason: 'the reference points to the new author, it is not cleared');
      final Article loaded = (await articles.findById(1, relations: FluentLoad.all))!;
      expect(loaded.title, 'b');
      expect(loaded.comments!.map((c) => c.text), ['c']);
      expect(loaded.tags!.map((t) => t.label), ['t']);
    });

    test('update of a missing root writes nothing below it', () async {
      final int updated = await articles.update(Article(id: 2, title: 'x', comments: [Comment(text: 'c')], tags: [Tag(label: 't')]), withRelations: true);
      expect(updated, 0);
      expect(await comments.count(), 0);
      expect(await tags.count(), 0);
    });

    test('patch / updateOnly save new children and references with upsert', () async {
      final Person cid = Person(name: 'cid');
      final FluentSaveResult patched = await articles.save(Article(id: 1, title: 'p', author: cid, comments: [Comment(text: 'new')]), strategy: FluentSaveStrategy.patch);
      expect(patched.outcomes, [FluentRowOutcome.updated]);
      expect((await row())['author_id'], cid.primaryKeyValue);
      expect((await comments.findAll()).map((c) => c.text), ['new']);

      final FluentSaveResult updated = await articles.save(Article(id: 1, title: 'u', author: Person(id: 1, name: 'ann2'), tags: [Tag(label: 'x')]), strategy: FluentSaveStrategy.updateOnly);
      expect(updated.outcomes, [FluentRowOutcome.updated]);
      expect((await row())['author_id'], 1);
      expect((await people.findById(1))!.name, 'ann2');
      expect((await articles.findById(1, relations: FluentLoad.all))!.tags!.map((t) => t.label), ['x']);
    });

    test('insertOnly: a new root gets its new children and references', () async {
      final Person dan = Person(name: 'dan');
      final Article a = Article(title: 'i', author: dan, comments: [Comment(text: 'k')]);
      final FluentSaveResult result = await articles.save(a, strategy: FluentSaveStrategy.insertOnly);
      expect(result.outcomes, [FluentRowOutcome.inserted]);
      final Map<String, Object?> stored = (await articles.db.query('articles', where: 'id = ?', whereArgs: [a.primaryKeyValue])).single;
      expect(stored['author_id'], dan.primaryKeyValue);
      expect((await comments.findAll()).map((c) => c.text), ['k']);
    });
  });

  group('W2: tombstones of owned children at any depth', () {
    late FluentTestDb db;
    late SFolderProvider folders;
    late SPageProvider pages;
    late SLineProvider lines;

    setUp(() async {
      db = FluentTestDb(name: 'w2_${DateTime.now().microsecondsSinceEpoch}');
      folders = SFolderProvider();
      pages = SPageProvider();
      lines = SLineProvider();
      await db.open([folders, pages, lines]);
      await folders.save(SFolder(id: 1, name: 'f', pages: [SPage(id: 10, text: 'a', lines: [SLine(id: 100, text: 'x'), SLine(id: 101, text: 'y')]), SPage(id: 11, text: 'b')]));
      await folders.save(SFolder(id: 2, name: 'g', pages: [SPage(id: 20, text: 'c', lines: [SLine(id: 200, text: 'z')])]));
      await pushAll(folders);
      await pushAll(pages);
      await pushAll(lines);
    });

    tearDown(() => db.close());

    test('deleting a folder tombstones its pages and their lines', () async {
      expect(await folders.deleteById(1), 1);
      expect(sortedInts(await pushAll(lines)), [100, 101]);
      expect(sortedInts(await pushAll(pages)), [10, 11]);
      expect(sortedInts(await pushAll(folders)), [1]);
      expect(await lines.count(), 1);
    });

    test('a filter qualified with the table name works through the cascade', () async {
      expect(await folders.deleteWhere(const FluentFilter('"s_folders"."name" = ?', ['g'])), 1);
      expect(sortedInts(await pushAll(lines)), [200]);
      expect(sortedInts(await pushAll(pages)), [20]);
    });

    test('a deferred relation filter works through the cascade', () async {
      expect(await folders.deleteWhere(FluentFilter.related('pages', FluentFilter.eq('text', 'c'))), 1);
      expect(sortedInts(await pushAll(lines)), [200]);
    });

    test('deleting the middle level tombstones the lines only below it', () async {
      expect(await pages.deleteById(10), 1);
      expect(sortedInts(await pushAll(lines)), [100, 101]);
      expect(await pushAll(folders), isEmpty);
    });
  });

  group('W3: the trash purge tombstones the children the cascade removes', () {
    late FluentTestDb db;
    late TFolderProvider folders;
    late TPageProvider pages;

    setUp(() async {
      db = FluentTestDb(name: 'w3_${DateTime.now().microsecondsSinceEpoch}');
      folders = TFolderProvider();
      pages = TPageProvider();
      await db.open([folders, pages]);
      await folders.save(TFolder(id: 1, name: 'f', pages: [TPage(id: 10, text: 'a'), TPage(id: 11, text: 'b')]));
      await pushAll(folders);
      await pushAll(pages);
    });

    tearDown(() => db.close());

    test('children trashed with the owner but not pushed get tombstones', () async {
      await folders.deleteById(1); // the pages go to the trash with it
      await pushAll(folders); // only the folder's deletion reaches the server
      expect(await folders.trash.empty(olderThan: Duration.zero), 1);
      expect(await pages.withTrash.count(), 0);
      expect(sortedInts(await pushAll(pages)), [10, 11]);
      expect(await pushAll(folders), isEmpty, reason: 'the folder deletion was already pushed');
    });

    test('children whose deletion was pushed get no tombstone', () async {
      await folders.deleteById(1);
      await pushAll(folders);
      await pushAll(pages);
      await folders.trash.empty(olderThan: Duration.zero);
      expect(await pushAll(pages), isEmpty);
    });
  });

  group('REL2: polymorphic clean-up for rows removed by the cascade', () {
    late FluentTestDb db;
    late RBlogProvider blogs;
    late RPostProvider posts;
    late RNoteProvider notes;

    setUp(() async {
      db = FluentTestDb(name: 'rel2_${DateTime.now().microsecondsSinceEpoch}');
      blogs = RBlogProvider();
      posts = RPostProvider();
      notes = RNoteProvider();
      await db.open([blogs, posts, notes]);
      await blogs.save(RBlog(id: 1, name: 'b', posts: [RPost(id: 1, title: 'p', notes: [RNote(text: 'n1'), RNote(text: 'n2')])]));
      await blogs.save(RBlog(id: 2, name: 'keep', posts: [RPost(id: 2, title: 'q', notes: [RNote(text: 'n3')])]));
    });

    tearDown(() => db.close());

    test('deleting the blog removes the notes of its posts; a new post 1 inherits nothing', () async {
      expect(await blogs.deleteById(1), 1);
      expect(await posts.count(), 1);
      expect((await notes.findAll()).map((n) => n.text), ['n3']);
      await posts.save(RPost(id: 1, title: 'fresh'));
      expect((await posts.findById(1))!.notes, isEmpty);
    });

    test('a filter qualified with the table name works', () async {
      expect(await blogs.deleteWhere(const FluentFilter('"r_blogs"."name" = ?', ['keep'])), 1);
      expect((await notes.findAll(orderBy: 'text')).map((n) => n.text), ['n1', 'n2']);
    });
  });

  group('W5 / REL1: list replacement', () {
    late FluentTestDb db;
    late ArticleProvider articles;
    late CommentProvider comments;
    late TagProvider tags;
    late QueryCounter counter;

    setUp(() async {
      counter = await QueryCounter.install();
      db = FluentTestDb(name: 'w5_${DateTime.now().microsecondsSinceEpoch}');
      articles = ArticleProvider();
      comments = CommentProvider();
      tags = TagProvider();
      await db.open([PersonProvider(), ProfileProvider(), comments, tags, articles, CategoryProvider()]);
    });

    tearDown(() async {
      await db.close();
      counter.uninstall();
    });

    int maxParams() => counter.statements.map((s) => '?'.allMatches(s).length).fold(0, (a, b) => a > b ? a : b);

    test('replacing a long owned list stays below the bound-variable limit', () async {
      final List<Comment> all = [for (int i = 0; i < 1001; i++) Comment(text: 'c$i')];
      await articles.save(Article(id: 1, title: 'a', comments: all));
      counter.reset();
      await articles.save(Article(id: 1, title: 'a', comments: all.sublist(1)), relationSync: FluentRelationSyncMode.replace);
      expect(maxParams(), lessThan(1000));
      expect(await comments.count(), 1000);
      expect(await comments.trash.count(), 1);
      expect((await comments.trash.find()).single.text, 'c0');
    });

    test('replacing a long many-to-many list stays below the bound-variable limit', () async {
      final List<Tag> all = [for (int i = 0; i < 1001; i++) Tag(label: 't$i')];
      await articles.save(Article(id: 1, title: 'a', tags: all));
      counter.reset();
      await articles.save(Article(id: 1, title: 'a', tags: all.sublist(1)), relationSync: FluentRelationSyncMode.replace);
      expect(maxParams(), lessThan(1000));
      final String link = (await articles.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%article%tag%'")).single['name']! as String;
      expect((await articles.db.rawQuery('SELECT COUNT(*) AS n FROM "$link"')).single['n'], 1000);
    });

    test('replacing keeps listed children, removes the others; an empty list removes all only with relationSync: replace', () async {
      final Comment a = Comment(text: 'a'), b = Comment(text: 'b');
      await articles.save(Article(id: 1, title: 't', comments: [a, b]));
      await articles.save(Article(id: 1, title: 't', comments: [b, Comment(text: 'c')]));
      expect((await comments.findAll(orderBy: 'text')).map((c) => c.text), ['b', 'c']);
      // G3: an empty list on a model the app built is not "remove all" (reported with the fix).
      await articles.save(Article(id: 1, title: 't', comments: []));
      expect(await comments.count(), 2);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationListKept), isNotEmpty);
      await articles.save(Article(id: 1, title: 't', comments: []), relationSync: FluentRelationSyncMode.replace);
      expect(await comments.count(), 0);
    });

    test('REL1: the same new child twice in one list is saved once and kept', () async {
      final Comment c = Comment(text: 'c');
      await articles.save(Article(id: 1, title: 'a', comments: [c, c, Comment(text: 'other')]));
      expect((await comments.findAll(orderBy: 'text')).map((x) => x.text), ['c', 'other']);
      expect(await comments.trash.count(), 0);

      final Comment only = Comment(text: 'only');
      await articles.save(Article(id: 2, title: 'b', comments: [only, only]));
      expect((await comments.find(where: FluentFilter.eq('article_id', 2))).map((x) => x.text), ['only']);
    });

    test('REL1: the same new tag in two articles of one save links both', () async {
      final Tag t = Tag(label: 't');
      await articles.saveAll([Article(title: 'a', tags: [t]), Article(title: 'b', tags: [t])]);
      expect(await tags.count(), 1);
      for (final Article a in await articles.findAll(relations: FluentLoad.all)) {
        expect(a.tags!.map((x) => x.label), ['t'], reason: a.title);
      }
    });

    test('REL1: the same new root twice in saveAll is written once and both entries get its key', () async {
      final Article a = Article(title: 'twice', comments: [Comment(text: 'k')]);
      final FluentSaveResult result = await articles.saveAll([a, a]);
      expect(result.outcomes, [FluentRowOutcome.inserted, FluentRowOutcome.inserted]);
      expect(await articles.count(), 1);
      expect(await comments.count(), 1);
    });
  });

  group('W6 / W7: field updates', () {
    late FluentTestDb db;
    late MetaNoteProvider notes;
    late QueryCounter counter;

    setUp(() async {
      counter = await QueryCounter.install();
      db = FluentTestDb(name: 'w6_${DateTime.now().microsecondsSinceEpoch}');
      notes = MetaNoteProvider();
      await db.open([notes]);
      await notes.saveAll([for (int i = 1; i <= 3; i++) MetaNote(id: i, title: 'n$i', syncedAt: DateTime.utc(2024, 1, i))]);
    });

    tearDown(() async {
      await db.close();
      counter.uninstall();
    });

    Future<List<Object?>> metas() async => [for (final Map<String, Object?> r in await notes.db.query('meta_notes', orderBy: 'id')) r['_fs_metadata']];

    test('W6: an update of untagged columns leaves the stored tags alone, without a statement per row', () async {
      expect(await metas(), everyElement('{"synced_at":"datetime_utc"}'));
      counter.reset();
      expect(await notes.updateWhere(FluentFilter.gt('id', 0), {'title': 'x'}), 3);
      // BEGIN, the UPDATE, COMMIT: no batch rewriting the metadata of every row.
      expect(counter.writes, 3, reason: counter.statements.join('\n'));
      expect(await metas(), everyElement('{"synced_at":"datetime_utc"}'));
      expect((await notes.findById(2))!.syncedAt, DateTime.utc(2024, 1, 2));
    });

    test('W6: tags of updated columns are still replaced or removed', () async {
      await notes.updateById(1, {'synced_at': DateTime(2024, 2, 5)}); // local time: the column kind, no tag
      await notes.updateById(2, {'synced_at': DateTime.utc(2024, 2, 6)});
      expect(await metas(), [null, '{"synced_at":"datetime_utc"}', '{"synced_at":"datetime_utc"}']);
      expect((await notes.findById(1))!.syncedAt, DateTime(2024, 2, 5));
      expect((await notes.findById(2))!.syncedAt!.isUtc, isTrue);
      await notes.updateWhere(FluentFilter.eq('id', 1), {'synced_at': DateTime.utc(2024, 3, 7)});
      expect((await metas()).first, '{"synced_at":"datetime_utc"}', reason: 'rows without metadata get the new tag');
    });

    test('W7: internal columns are refused with a hint', () async {
      for (final String column in ['deleted_at', 'sync_version', 'synced_version', 'expiry_date', '_fs_metadata']) {
        await expectLater(
          notes.updateById(1, {column: 1}),
          throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotEmpty).having((e) => e.message, 'message', contains(column))),
          reason: column,
        );
      }
      await expectLater(notes.updateWhere(FluentFilter.eq('id', 1), {'deleted_at': FluentUpdate.now}), throwsA(isA<FluentArgumentException>()));
      expect(await notes.count(), 3, reason: 'nothing was changed');
      expect(await notes.updateById(1, {'title': 'ok'}), 1);
    });
  });

  group('W8: deletedAt after delete', () {
    late FluentTestDb db;
    late MetaNoteProvider notes;

    setUp(() async {
      db = FluentTestDb(name: 'w8_${DateTime.now().microsecondsSinceEpoch}');
      notes = MetaNoteProvider();
      await db.open([notes]);
    });

    tearDown(() => db.close());

    test('only deleted models get deletedAt, the stamp that was stored', () async {
      final MetaNote a = MetaNote(id: 1, title: 'a'), missing = MetaNote(id: 9, title: 'x');
      await notes.save(a);
      a.deletedAt = DateTime(2000); // set by hand: replaced by the real stamp
      db.clock.advance(const Duration(minutes: 5));
      expect(await notes.deleteAll([a, missing]), 1);
      final MetaNote stored = (await notes.withTrash.findById(1))!;
      expect(stored.deletedAt, isNotNull);
      expect(a.deletedAt, stored.deletedAt);
      expect(missing.deletedAt, isNull);
    });

    test('a model already in the trash keeps the stamp of its first delete', () async {
      final MetaNote a = MetaNote(id: 1, title: 'a');
      await notes.save(a);
      await notes.delete(a);
      final DateTime first = a.deletedAt!;
      db.clock.advance(const Duration(minutes: 5));
      final MetaNote again = MetaNote(id: 1, title: 'a');
      expect(await notes.delete(again), 0);
      expect(again.deletedAt, first);
    });
  });

  group('W9: conflictOn matches rows in the trash', () {
    late FluentTestDb db;
    late STicketProvider tickets;

    setUp(() async {
      db = FluentTestDb(name: 'w9_${DateTime.now().microsecondsSinceEpoch}');
      tickets = STicketProvider();
      await db.open([tickets]);
    });

    tearDown(() => db.close());

    test('a local save brings the trashed row back instead of adding a second one', () async {
      await tickets.save(STicket(serverId: 's1', title: 'a'));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      final STicket again = STicket(serverId: 's1', title: 'b');
      final FluentSaveResult result = await tickets.save(again, conflictOn: ['server_id']);
      expect(result.outcomes, [FluentRowOutcome.restored]);
      expect(await tickets.withTrash.count(), 1);
      expect((await tickets.findAll()).single.title, 'b');
      expect(again.primaryKeyValue, isNotNull);
    });

    test('updateOnly / insertOnly on a trashed match: skipped / restored', () async {
      await tickets.save(STicket(serverId: 's1', title: 'a'));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      expect((await tickets.save(STicket(serverId: 's1', title: 'u'), conflictOn: ['server_id'], strategy: FluentSaveStrategy.updateOnly)).outcomes, [FluentRowOutcome.skipped]);
      expect(await tickets.count(), 0);
      expect((await tickets.save(STicket(serverId: 's1', title: 'i'), conflictOn: ['server_id'], strategy: FluentSaveStrategy.insertOnly)).outcomes, [FluentRowOutcome.restored]);
      expect((await tickets.withTrash.findAll()).map((t) => t.title), ['i']);
    });

    test('a live row wins over a trashed row with the same server key', () async {
      await tickets.save(STicket(serverId: 's1', title: 'old'));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      await tickets.save(STicket(serverId: 's1', title: 'live')); // by key: a new row (the unique index covers live rows)
      expect(await tickets.withTrash.count(), 2);
      expect((await tickets.save(STicket(serverId: 's1', title: 'live2'), conflictOn: ['server_id'])).outcomes, [FluentRowOutcome.updated]);
      expect((await tickets.findAll()).single.title, 'live2');
      expect((await tickets.trash.find()).single.title, 'old');
    });

    test('a pull of a row whose trash was pushed brings it back, matched by conflictOn (no second row) (G10 / G24, sync round)', () async {
      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [STicket(serverId: 's1', title: 'one')]));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      final List<String> deleted = [];
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          deleted.addAll(batch.deleted.map((t) => t.serverId!));
          return const FluentPushResult.accepted();
        },
      );
      expect(deleted, ['s1']);

      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [STicket(serverId: 's1', title: 'one (edited)')]));
      expect(await tickets.withTrash.count(), 1, reason: 'no second row with the same server key');
      expect(await tickets.count(), 1, reason: 'the server row is newer than the pushed deletion: back from the trash');
      expect((await tickets.findAll()).single.title, 'one (edited)');
      expect(await tickets.pendingChanges(), 0);
    });

    test('a server write into a trashed row leaves the models\' deletedAt alone (no deletedAtIgnored)', () async {
      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [STicket(serverId: 's1', title: 'one')]));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      final DateTime stamp = DateTime.utc(2026);
      final STicket fromServer = STicket(serverId: 's1', title: 'server')..deletedAt = stamp;
      await tickets.applyPull(const FluentPullResult<STicket>(), remote: [fromServer], serverWins: true);
      expect(fromServer.deletedAt, stamp);
      expect(await tickets.count(), 1, reason: 'the server wins: the row is back from the trash');
    });

    test('a server write with serverWins replaces a local delete that was not pushed (G24 keepServer, sync round)', () async {
      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [STicket(serverId: 's1', title: 'one')]));
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's1'));
      expect(await tickets.pendingChanges(), 1);
      await tickets.applyPull(const FluentPullResult<STicket>(), remote: [STicket(serverId: 's1', title: 'server')], serverWins: true);
      expect(await tickets.withTrash.count(), 1, reason: 'no second row');
      expect((await tickets.findAll()).single.title, 'server');
      expect(await tickets.pendingChanges(), 0, reason: 'the server won over the local delete: nothing to push');
    });
  });
}
