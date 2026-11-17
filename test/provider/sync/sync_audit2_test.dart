@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class A2Note extends FluentStorable {
  A2Note({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class A2Notes extends FluentProvider<A2Note> with FluentSyncable<A2Note> {
  @override
  String get tableName => 'a2_notes';

  @override
  A2Note get modelSample => A2Note(text: '');

  @override
  A2Note fromCacheJson(Map<String, dynamic> json) => A2Note(id: json['id'] as int?, text: json['text'] as String);
}

/// The server key is a column of its own, filled in by the server.
class A2Ticket extends FluentStorable {
  A2Ticket({this.id, this.serverId, required this.title});

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

class A2Tickets extends FluentProvider<A2Ticket> with FluentSyncable<A2Ticket> {
  @override
  String get tableName => 'a2_tickets';

  @override
  A2Ticket get modelSample => A2Ticket(title: '');

  @override
  A2Ticket fromCacheJson(Map<String, dynamic> json) => A2Ticket(id: json['id'] as int?, serverId: json['server_id'] as String?, title: json['title'] as String);
}

/// Composite server key.
class A2Doc extends FluentStorable {
  A2Doc({this.id, this.org, this.ref, required this.title});

  final int? id;
  final String? org;
  final String? ref;
  final String title;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['org', 'ref']);

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('org'), FluentDbColumn.text('ref'), FluentDbColumn.text('title')];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'org': org, 'ref': ref, 'title': title};
}

class A2Docs extends FluentProvider<A2Doc> with FluentSyncable<A2Doc> {
  @override
  String get tableName => 'a2_docs';

  @override
  A2Doc get modelSample => A2Doc(title: '');

  @override
  A2Doc fromCacheJson(Map<String, dynamic> json) => A2Doc(id: json['id'] as int?, org: json['org'] as String?, ref: json['ref'] as String?, title: json['title'] as String);
}

class A2Folder extends FluentStorable with FluentRelations {
  A2Folder({this.id, required this.name, this.pages});

  final int? id;
  final String name;
  final List<A2Page>? pages;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<A2Folder, A2Page>('pages', (f) => f.pages)];
}

class A2Page extends FluentStorable {
  A2Page({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

A2Folder _folder(Map<String, dynamic> json) => A2Folder(id: json['id'] as int?, name: json['name'] as String, pages: (json['pages'] as List?)?.cast<A2Page>());

class A2Folders extends FluentProvider<A2Folder> {
  @override
  String get tableName => 'a2_folders';

  @override
  A2Folder get modelSample => A2Folder(name: '');

  @override
  A2Folder fromCacheJson(Map<String, dynamic> json) => _folder(json);
}

class A2SyncFolders extends FluentProvider<A2Folder> with FluentSyncable<A2Folder> {
  @override
  String get tableName => 'a2_sync_folders';

  @override
  A2Folder get modelSample => A2Folder(name: '');

  @override
  A2Folder fromCacheJson(Map<String, dynamic> json) => _folder(json);
}

class A2Pages extends FluentProvider<A2Page> with FluentSyncable<A2Page> {
  @override
  String get tableName => 'a2_pages';

  @override
  A2Page get modelSample => A2Page(text: '');

  @override
  A2Page fromCacheJson(Map<String, dynamic> json) => A2Page(id: json['id'] as int?, text: json['text'] as String);
}

/// Polymorphic: a comment on a post (owned, deleted with it) or on a video (the reference is cleared).
class A2Comment extends FluentStorable with FluentRelations {
  A2Comment({this.id, required this.text, this.target});

  final int? id;
  final String text;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.oneOf<A2Comment>('target', (c) => c.target, types: [A2Post, A2Video]),
  ];
}

class A2Post extends FluentStorable with FluentRelations {
  A2Post({this.id, required this.title, this.comments = const []});

  final int? id;
  final String title;
  final List<A2Comment> comments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<A2Post, A2Comment>('comments', (p) => p.comments, via: 'target'),
  ];
}

class A2Video extends FluentStorable {
  A2Video({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class A2Comments extends FluentProvider<A2Comment> with FluentSyncable<A2Comment> {
  @override
  String get tableName => 'a2_comments';

  @override
  A2Comment get modelSample => A2Comment(text: '');

  @override
  A2Comment fromCacheJson(Map<String, dynamic> json) => A2Comment(id: json['id'] as int?, text: json['text'] as String, target: json['target'] as FluentStorable?);
}

class A2Posts extends FluentProvider<A2Post> {
  @override
  String get tableName => 'a2_posts';

  @override
  A2Post get modelSample => A2Post(title: '');

  @override
  A2Post fromCacheJson(Map<String, dynamic> json) => A2Post(id: json['id'] as int?, title: json['title'] as String, comments: (json['comments'] as List?)?.cast<A2Comment>() ?? const []);
}

class A2Videos extends FluentProvider<A2Video> {
  @override
  String get tableName => 'a2_videos';

  @override
  A2Video get modelSample => A2Video(title: '');

  @override
  A2Video fromCacheJson(Map<String, dynamic> json) => A2Video(id: json['id'] as int?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;

  setUp(() => db = FluentTestDb(name: 'sync_audit2_${counter++}_${DateTime.now().microsecondsSinceEpoch}'));
  tearDown(() => db.close());

  Future<void> pushOk<M extends FluentStorable>(FluentSyncable<M> p) async {
    final FluentSyncResult<M> r = await p.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => FluentPushResult<M>.accepted()).timeout(const Duration(seconds: 10));
    expect(r.isSuccess, isTrue, reason: r.errorMessage);
  }

  Future<FluentSyncBatch<M>?> pushSeen<M extends FluentStorable>(FluentSyncable<M> p) async {
    FluentSyncBatch<M>? seen;
    await p
        .syncWithServer(
          strategy: FluentSyncStrategy.push,
          onPush: (b) async {
            seen = b;
            return FluentPushResult<M>.accepted();
          },
        )
        .timeout(const Duration(seconds: 10));
    return seen;
  }

  group('25: FluentDb.clear drops tombstones', () {
    test('the next user does not push the previous user deletions', () async {
      final A2Notes notes = A2Notes();
      await db.open([notes]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await pushOk(notes);
      await notes.deleteById(1);
      expect(await notes.pendingChanges(), 1);
      await FluentDb.clear();
      expect(await notes.pendingChanges(), 0);
      expect(await pushSeen(notes), isNull);
    });

    test('tombstones of every synced table are dropped, a later delete still works', () async {
      final A2Notes notes = A2Notes();
      final A2Tickets tickets = A2Tickets();
      await db.open([notes, tickets]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await tickets.save(A2Ticket(id: 1, serverId: 's1', title: 't'));
      await pushOk(notes);
      await pushOk(tickets);
      await notes.deleteById(1);
      await tickets.deleteById(1);
      await FluentDb.clear();
      expect(await notes.pendingChanges() + await tickets.pendingChanges(), 0);
      await notes.save(A2Note(id: 2, text: 'b'));
      await pushOk(notes);
      await notes.deleteById(2);
      final FluentSyncBatch<A2Note>? seen = await pushSeen(notes);
      expect(seen!.deletedKeys, [2]);
    });
  });

  group('26: clearTable drops the tombstones of the table', () {
    test('pendingChanges is 0 and the loss is reported', () async {
      final A2Notes notes = A2Notes();
      await db.open([notes]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await notes.save(A2Note(id: 2, text: 'b'));
      await pushOk(notes);
      await notes.deleteById(1);
      expect(await notes.pendingChanges(), 1);
      await notes.clearTable();
      expect(await notes.pendingChanges(), 0);
      expect(await pushSeen(notes), isNull);
      final Iterable<FluentIssue> issues = db.issues.where((i) => i.kind == FluentIssueKind.unsentChangesDiscarded);
      expect(issues, hasLength(1), reason: 'the unsent deletion of key 1 is counted');
    });

    test('only the tombstones of that table go; nothing pending: no second issue', () async {
      final A2Notes notes = A2Notes();
      final A2Tickets tickets = A2Tickets();
      await db.open([notes, tickets]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await tickets.save(A2Ticket(id: 1, serverId: 's1', title: 't'));
      await pushOk(notes);
      await pushOk(tickets);
      await notes.deleteById(1);
      await tickets.deleteById(1);
      await tickets.clearTable();
      expect(await notes.pendingChanges(), 1);
      expect(await tickets.pendingChanges(), 0);
      final int before = db.issues.where((i) => i.kind == FluentIssueKind.unsentChangesDiscarded).length;
      await notes.clearTable();
      expect(await notes.pendingChanges(), 0);
      await notes.clearTable();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.unsentChangesDiscarded).length, before + 1, reason: 'the empty second clear reports nothing');
    });
  });

  group('27: a local save drops the tombstone of its key', () {
    test('delete then save with the same id sends only the upsert', () async {
      final A2Notes notes = A2Notes();
      await db.open([notes]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await pushOk(notes);
      await notes.deleteById(1);
      await notes.save(A2Note(id: 1, text: 'b'));
      final FluentSyncBatch<A2Note>? seen = await pushSeen(notes);
      expect(seen!.changed.map((n) => n.id), [1]);
      expect(seen.deletedKeys, isEmpty);
      expect(await notes.pendingChanges(), 0);
    });

    test('a save of another key keeps the tombstone; a rolled back save keeps it too', () async {
      final A2Notes notes = A2Notes();
      await db.open([notes]);
      await notes.save(A2Note(id: 1, text: 'a'));
      await pushOk(notes);
      await notes.deleteById(1);
      await notes.save(A2Note(id: 2, text: 'other'));
      await expectLater(
        FluentDb.transaction(() async {
          await notes.save(A2Note(id: 1, text: 'undone'));
          throw StateError('rollback');
        }),
        throwsA(anything),
      );
      final FluentSyncBatch<A2Note>? seen = await pushSeen(notes);
      expect(seen!.changed.map((n) => n.id), [2]);
      expect(seen.deletedKeys, [1]);
    });

    test('a batch save drops the tombstones of the rewritten keys only', () async {
      final A2Notes notes = A2Notes();
      await db.open([notes]);
      await notes.saveAll([A2Note(id: 1, text: 'a'), A2Note(id: 2, text: 'b'), A2Note(id: 3, text: 'c')]);
      await pushOk(notes);
      await notes.deleteById(1);
      await notes.deleteById(2);
      await notes.saveAll([A2Note(id: 2, text: 'b2'), A2Note(id: 4, text: 'd')]);
      final FluentSyncBatch<A2Note>? seen = await pushSeen(notes);
      expect(seen!.changed.map((n) => n.id).toSet(), {2, 4});
      expect(seen.deletedKeys, [1]);
    });

    test('server key set by the server only: saved again with that key, the tombstone goes', () async {
      final A2Tickets tickets = A2Tickets();
      await db.open([tickets]);
      await tickets.save(A2Ticket(id: 1, serverId: 's1', title: 'a'));
      await pushOk(tickets);
      await tickets.deleteById(1);
      expect(await tickets.pendingChanges(), 1);
      await tickets.save(A2Ticket(id: 7, serverId: 's1', title: 'again'));
      final FluentSyncBatch<A2Ticket>? seen = await pushSeen(tickets);
      expect(seen!.deletedKeys, isEmpty);
      expect(seen.changed.map((t) => t.serverId), ['s1']);
    });

    test('a new row without a server key keeps the tombstone of another', () async {
      final A2Tickets tickets = A2Tickets();
      await db.open([tickets]);
      await tickets.save(A2Ticket(id: 1, serverId: 's1', title: 'a'));
      await pushOk(tickets);
      await tickets.deleteById(1);
      await tickets.save(A2Ticket(title: 'new, no server id yet'));
      final FluentSyncBatch<A2Ticket>? seen = await pushSeen(tickets);
      expect(seen!.deletedKeys, ['s1']);
      expect(seen.changed, hasLength(1));
    });

    test('composite server key', () async {
      final A2Docs docs = A2Docs();
      await db.open([docs]);
      await docs.saveAll([A2Doc(id: 1, org: 'o', ref: 'r1', title: 'a'), A2Doc(id: 2, org: 'o', ref: 'r2', title: 'b')]);
      await pushOk(docs);
      await docs.deleteById(1);
      await docs.deleteById(2);
      await docs.save(A2Doc(id: 1, org: 'o', ref: 'r1', title: 'back'));
      final FluentSyncBatch<A2Doc>? seen = await pushSeen(docs);
      expect(seen!.changed.map((d) => d.ref), ['r1']);
      expect(seen.deletedKeys, hasLength(1));
      expect((seen.deletedKeys.single as FluentKey)['ref'], 'r2');
    });
  });

  group('28: replaceLocally / clearLocally keep unsynced children', () {
    Future<void> setUpTree(A2SyncFolders folders, A2Pages pages) async {
      await db.open([folders, pages]);
      await folders.save(A2Folder(id: 1, name: 'f1', pages: [A2Page(id: 10, text: 'p10'), A2Page(id: 11, text: 'p11')]));
      await folders.save(A2Folder(id: 2, name: 'f2', pages: [A2Page(id: 20, text: 'p20')]));
      await pushOk(folders);
      await pushOk(pages);
      expect(await folders.pendingChanges() + await pages.pendingChanges(), 0);
      await pages.save(A2Page(id: 10, text: 'edited locally'));
      expect(await pages.pendingChanges(), 1);
    }

    test('replaceLocally keeps the folder of an unsynced page and the page', () async {
      final A2SyncFolders folders = A2SyncFolders();
      final A2Pages pages = A2Pages();
      await setUpTree(folders, pages);
      await folders.replaceLocally(FluentFilter.empty, [A2Folder(id: 3, name: 'f3')]);
      expect((await folders.findAll()).map((f) => f.id).toSet(), {1, 3}, reason: 'folder 1 holds an unsynced page');
      expect((await pages.findAll()).map((p) => p.id).toSet(), {10, 11});
      expect((await pages.findById(10))!.text, 'edited locally');
      expect(await pages.pendingChanges(), 1);
    });

    test('clearLocally does the same', () async {
      final A2SyncFolders folders = A2SyncFolders();
      final A2Pages pages = A2Pages();
      await setUpTree(folders, pages);
      expect(await folders.clearLocally(FluentFilter.empty), 1);
      expect((await folders.findAll()).map((f) => f.id), [1]);
      expect((await pages.findAll()).map((p) => p.id).toSet(), {10, 11});
    });

    test('a parent that is not syncable itself is kept too', () async {
      final A2Folders folders = A2Folders();
      final A2Pages pages = A2Pages();
      await db.open([folders, pages]);
      await folders.save(A2Folder(id: 1, name: 'f1', pages: [A2Page(id: 10, text: 'p10')]));
      await folders.save(A2Folder(id: 2, name: 'f2', pages: [A2Page(id: 20, text: 'p20')]));
      await pushOk(pages);
      await pages.save(A2Page(id: 20, text: 'edited'));
      await folders.replaceLocally(FluentFilter.empty, [A2Folder(id: 3, name: 'f3')]);
      expect((await folders.findAll()).map((f) => f.id).toSet(), {2, 3});
      expect((await pages.findAll()).map((p) => p.id), [20]);
    });

    test('everything synced: the cascade still removes the children', () async {
      final A2SyncFolders folders = A2SyncFolders();
      final A2Pages pages = A2Pages();
      await db.open([folders, pages]);
      await folders.save(A2Folder(id: 1, name: 'f1', pages: [A2Page(id: 10, text: 'p10')]));
      await pushOk(folders);
      await pushOk(pages);
      await folders.replaceLocally(FluentFilter.empty, [A2Folder(id: 3, name: 'f3')]);
      expect((await folders.findAll()).map((f) => f.id), [3]);
      expect(await pages.findAll(), isEmpty);
    });
  });

  group('28b: polymorphic (oneOf) children', () {
    late A2Comments comments;
    late A2Posts posts;
    late A2Videos videos;

    setUp(() async {
      comments = A2Comments();
      posts = A2Posts();
      videos = A2Videos();
      await db.open([comments, posts, videos]);
    });

    test('an unsynced comment keeps its post (cascade rule) and its video (set-null rule); synced ones go', () async {
      final A2Video v1 = A2Video(id: 1, title: 'v1');
      final A2Video v2 = A2Video(id: 2, title: 'v2');
      await videos.saveAll([v1, v2]);
      await posts.save(A2Post(id: 1, title: 'p1'));
      await posts.save(A2Post(id: 2, title: 'p2'));
      final A2Post p1 = (await posts.findById(1))!;
      final A2Post p2 = (await posts.findById(2))!;
      await comments.save(A2Comment(id: 10, text: 'on p1', target: p1));
      await comments.save(A2Comment(id: 20, text: 'on p2', target: p2));
      await comments.save(A2Comment(id: 30, text: 'on v1', target: v1));
      await comments.save(A2Comment(id: 40, text: 'on v2', target: v2));
      await pushOk(comments);
      await comments.save(A2Comment(id: 10, text: 'p1 edited', target: p1));
      await comments.save(A2Comment(id: 30, text: 'v1 edited', target: v1));
      expect(await comments.pendingChanges(), 2);

      await posts.replaceLocally(FluentFilter.empty, [A2Post(id: 3, title: 'p3')]);
      expect((await posts.findAll()).map((p) => p.id).toSet(), {1, 3}, reason: 'post 2 has only a synced comment');
      expect((await comments.findAll()).map((c) => c.id).toSet(), {10, 30, 40});

      expect(await videos.clearLocally(FluentFilter.empty), 1);
      expect((await videos.findAll()).map((v) => v.id), [1], reason: 'video 1 has an unsynced comment, video 2 is cleared');
      expect((await comments.findAll()).map((c) => c.id).toSet(), {10, 30, 40});
      expect((await comments.findById(30))!.text, 'v1 edited');
      expect(await comments.pendingChanges(), 2);
    });

    test('everything synced: the comments of a replaced post still go', () async {
      await posts.save(A2Post(id: 1, title: 'p1'));
      final A2Post p1 = (await posts.findById(1))!;
      await comments.save(A2Comment(id: 10, text: 'on p1', target: p1));
      await pushOk(comments);
      await posts.replaceLocally(FluentFilter.empty, [A2Post(id: 2, title: 'p2')]);
      expect((await posts.findAll()).map((p) => p.id), [2]);
      expect(await comments.findAll(), isEmpty);
    });
  });
}
