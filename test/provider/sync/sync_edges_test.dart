// Sync edges: watchRemote failure paths (store, paging, fetch bookkeeping, cache clearing), relations in stored answers,
// composite server keys and tombstones without a key, missing callbacks, the status stream on errors and cancel.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// A row with a unique code: two rows with the same code cannot be stored together.
class Code extends FluentStorable {
  Code({this.id, required this.code});

  final int? id;
  final String code;

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('code', isUnique: true)];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'code': code};
}

class PlainCodes extends FluentProvider<Code> {
  @override
  String get tableName => 'plain_codes';

  @override
  Code get modelSample => Code(code: '');

  @override
  Code fromCacheJson(Map<String, dynamic> json) => Code(id: json['id'] as int?, code: json['code'] as String);
}

class SyncCodes extends FluentProvider<Code> with FluentSyncable<Code> {
  @override
  String get tableName => 'sync_codes';

  @override
  Code get modelSample => Code(code: '');

  @override
  Code fromCacheJson(Map<String, dynamic> json) => Code(id: json['id'] as int?, code: json['code'] as String);
}

class Folder extends FluentStorable with FluentRelations {
  Folder({this.id, required this.name, this.pages});

  final int? id;
  final String name;
  final List<Page>? pages;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Folder, Page>('pages', (f) => f.pages)];
}

class Page extends FluentStorable {
  Page({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

Folder _folderFromJson(Map<String, dynamic> json) => Folder(id: json['id'] as int?, name: json['name'] as String, pages: (json['pages'] as List?)?.cast<Page>());

class PlainFolders extends FluentProvider<Folder> {
  @override
  String get tableName => 'plain_folders';

  @override
  Folder get modelSample => Folder(name: '');

  @override
  Folder fromCacheJson(Map<String, dynamic> json) => _folderFromJson(json);
}

class SyncFolders extends FluentProvider<Folder> with FluentSyncable<Folder> {
  @override
  String get tableName => 'sync_folders';

  @override
  Folder get modelSample => Folder(name: '');

  @override
  Folder fromCacheJson(Map<String, dynamic> json) => _folderFromJson(json);
}

class PagesProvider extends FluentProvider<Page> {
  @override
  String get tableName => 'pages';

  @override
  Page get modelSample => Page(text: '');

  @override
  Page fromCacheJson(Map<String, dynamic> json) => Page(id: json['id'] as int?, text: json['text'] as String);
}

/// Server key of two columns.
class Doc extends FluentStorable {
  Doc({this.id, this.org, this.ref, required this.title});

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

class DocProvider extends FluentProvider<Doc> with FluentSyncable<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, org: json['org'] as String?, ref: json['ref'] as String?, title: json['title'] as String);
}

/// One server key column the server fills in.
class Ticket extends FluentStorable {
  Ticket({this.id, this.serverId, required this.title});

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

class TicketProvider extends FluentProvider<Ticket> with FluentSyncable<Ticket> {
  @override
  String get tableName => 'tickets';

  @override
  Ticket get modelSample => Ticket(title: '');

  @override
  Ticket fromCacheJson(Map<String, dynamic> json) => Ticket(id: json['id'] as int?, serverId: json['server_id'] as String?, title: json['title'] as String);
}

Iterable<FluentIssue> issuesOf(FluentTestDb db, FluentIssueKind kind) => db.issues.where((i) => i.kind == kind);

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;

  setUp(() => db = FluentTestDb(name: 'sync_edges_${counter++}_${DateTime.now().microsecondsSinceEpoch}'));
  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('watchRemote', () {
    late PlainCodes codes;

    setUp(() async {
      codes = PlainCodes();
      await db.open([codes]);
      await codes.save(Code(id: 1, code: 'keep'));
    });

    test('fetch and fetchPage together: fetchPage wins and an ignoredCall issue says so', () async {
      int fetchCalls = 0;
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(
            fetch: () async {
              fetchCalls++;
              return FluentRemoteResponse([Code(id: 2, code: 'from fetch')]);
            },
            fetchPage: (_) async => FluentRemoteResponse([Code(id: 3, code: 'from page')]),
            keepWatching: false,
          )
          .last;
      expect(fetchCalls, 0);
      expect(last.items.map((c) => c.code), containsAll(['keep', 'from page']));
      expect(issuesOf(db, FluentIssueKind.ignoredCall).single.fix, contains('fetchPage'));
    });

    test('neither fetch nor fetchPage: the stream fails with a typed argument error and a hint', () async {
      await expectLater(
        codes.watchRemote(),
        emitsError(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('fetchPage'))),
      );
    });

    test('an answer the table rejects is a failed event, the cache keeps its rows and syncStoreFailed is reported', () async {
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(
            fetch: () async => FluentRemoteResponse([Code(id: 5, code: 'dup'), Code(id: 6, code: 'dup')]),
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.failed);
      expect(last.hasError, isTrue);
      expect(await codes.findAll(), hasLength(1));
      expect(issuesOf(db, FluentIssueKind.syncStoreFailed), hasLength(1));
    });

    test('a rejected page of a paged answer stops the paging and nothing of that page is stored', () async {
      int calls = 0;
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(
            fetchPage: (request) async {
              calls++;
              return FluentRemoteResponse([Code(id: 5, code: 'dup'), Code(id: 6, code: 'dup')], hasMore: true, cursor: 'next');
            },
            keepWatching: false,
          )
          .last;
      expect(calls, 1);
      expect(last.phase, FluentRemotePhase.failed);
      expect(await codes.findAll(), hasLength(1));
      expect(issuesOf(db, FluentIssueKind.syncStoreFailed), hasLength(1));
    });

    test('mirror: when removing the rows the server lacks fails after the last page the event fails and the rows stay', () async {
      await codes.db.execute("CREATE TRIGGER no_delete BEFORE DELETE ON plain_codes BEGIN SELECT RAISE(ABORT, 'no deletes'); END");
      int page = 0;
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(
            fetchPage: (request) async {
              page++;
              return page == 1 ? FluentRemoteResponse([Code(id: 7, code: 'p1')], hasMore: true, cursor: 1) : FluentRemoteResponse([Code(id: 8, code: 'p2')]);
            },
            store: FluentRemoteStore.mirror,
            keepWatching: false,
          )
          .last;
      expect(page, 2);
      expect(last.phase, FluentRemotePhase.failed);
      expect((await codes.findAll()).map((c) => c.code), containsAll(['keep', 'p1', 'p2']), reason: 'the pages were stored, the delete was refused');
      expect(issuesOf(db, FluentIssueKind.syncStoreFailed), hasLength(1));
    });

    test('maxAge: a failed bookkeeping write of a paged answer is a failed event', () async {
      await codes.db.execute('CREATE TABLE IF NOT EXISTS "__fluent_fetch_state" (query TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL)');
      await codes.db.execute("CREATE TRIGGER no_mark BEFORE INSERT ON __fluent_fetch_state BEGIN SELECT RAISE(ABORT, 'no bookkeeping'); END");
      int page = 0;
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(
            fetchPage: (request) async {
              page++;
              return page == 1 ? FluentRemoteResponse([Code(id: 7, code: 'p1')], hasMore: true, cursor: 1) : FluentRemoteResponse([Code(id: 8, code: 'p2')]);
            },
            maxAge: const Duration(hours: 1),
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.failed);
      expect(last.hasError, isTrue);
      expect(issuesOf(db, FluentIssueKind.syncStoreFailed), hasLength(1));
      expect((await codes.findAll()).map((c) => c.code), containsAll(['p1', 'p2']));
    });

    test('maxAge: a failed bookkeeping write of a single answer is a failed event too', () async {
      await codes.db.execute('CREATE TABLE IF NOT EXISTS "__fluent_fetch_state" (query TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL)');
      await codes.db.execute("CREATE TRIGGER no_mark BEFORE INSERT ON __fluent_fetch_state BEGIN SELECT RAISE(ABORT, 'no bookkeeping'); END");
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(fetch: () async => FluentRemoteResponse([Code(id: 9, code: 'one')]), maxAge: const Duration(hours: 1), keepWatching: false)
          .last;
      expect(last.phase, FluentRemotePhase.failed);
      expect(issuesOf(db, FluentIssueKind.syncStoreFailed), hasLength(1));
    });

    test('clearCacheOn: when clearing the cache fails the event still carries the status of the fetch error', () async {
      await codes.db.execute("CREATE TRIGGER no_delete BEFORE DELETE ON plain_codes BEGIN SELECT RAISE(ABORT, 'no deletes'); END");
      final FluentRemoteEvent<Code> last = await codes
          .watchRemote(fetch: () async => const FluentRemoteResponse<Code>.failed(401), clearCacheOn: {401}, keepWatching: false)
          .last;
      expect(last.hasError, isTrue);
      expect((last.error! as FluentSyncException).statusCode, 401);
      expect(last.items.map((c) => c.code), ['keep'], reason: 'the refused delete left the cache alone');
    });
  });

  group('watchRemote with relations', () {
    test('a model with relations stores the owned rows of the answer and mirror removes the folders the server lacks', () async {
      final PlainFolders folders = PlainFolders();
      final PagesProvider pages = PagesProvider();
      await db.open([folders, pages]);
      await folders.save(Folder(id: 9, name: 'old', pages: [Page(id: 90, text: 'old page')]));

      final FluentRemoteEvent<Folder> last = await folders
          .watchRemote(
            fetch: () async => FluentRemoteResponse([
              Folder(id: 1, name: 'f', pages: [Page(id: 10, text: 'a'), Page(id: 11, text: 'b')]),
            ]),
            store: FluentRemoteStore.mirror,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect((await folders.findAll()).map((f) => f.name), ['f']);
      expect((await pages.findAll()).map((p) => p.text).toSet(), {'a', 'b'}, reason: 'the old folder cascaded its page away');
    });
  });

  group('sync keys and tombstones', () {
    test('a composite server key: deletions are reported as FluentKey of both columns', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      await docs.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [Doc(org: 'o1', ref: 'r1', title: 'one'), Doc(org: 'o1', ref: 'r2', title: 'two')]),
      );
      await docs.deleteWhere(FluentFilter.eq('ref', 'r1'));
      final List<Object> sent = [];
      final FluentSyncResult<Doc> result = await docs.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sent.addAll(batch.deletedKeys);
          return const FluentPushResult.accepted();
        },
      );
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      final FluentKey key = sent.single as FluentKey;
      expect(key.values, {'org': 'o1', 'ref': 'r1'});
      // The server tells it deleted the other one: matched by both columns.
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(deletedKeys: [FluentKey({'org': 'o1', 'ref': 'r2'})]));
      expect(await docs.findAll(), isEmpty);
    });

    test('a row the server knows but whose server key was never stored cannot be reported as deleted: tombstoneWithoutKey', () async {
      final TicketProvider tickets = TicketProvider();
      await db.open([tickets]);
      await tickets.save(Ticket(title: 'no key'));
      await tickets.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
      await tickets.deleteWhere(FluentFilter.eq('title', 'no key'));
      final List<Object> sent = [];
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sent.addAll(batch.deletedKeys);
          return const FluentPushResult.accepted();
        },
      );
      expect(sent, isEmpty);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.tombstoneWithoutKey).single;
      expect(issue.title, contains('1 deleted row(s)'));
      expect(issue.fix, contains('FluentPushResult.accepted(updated'));
    });

    test('a composite key with one empty column is also a tombstone without key', () async {
      final DocProvider docs = DocProvider();
      await db.open([docs]);
      await docs.save(Doc(org: 'o', title: 'half key'));
      await docs.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
      await docs.deleteWhere(FluentFilter.eq('title', 'half key'));
      expect(issuesOf(db, FluentIssueKind.tombstoneWithoutKey), hasLength(1));
    });
  });

  group('sync with relations', () {
    test('a pulled folder stores its pages, and the answer of a push is stored as synced', () async {
      final SyncFolders folders = SyncFolders();
      final PagesProvider pages = PagesProvider();
      await db.open([folders, pages]);

      await folders.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [
          Folder(id: 1, name: 'pulled', pages: [Page(id: 10, text: 'p1')]),
        ]),
      );
      expect((await folders.findById(1))?.pages?.map((p) => p.text), ['p1']);
      expect(await folders.pendingChanges(), 0);

      await folders.save(Folder(id: 2, name: 'local', pages: [Page(id: 20, text: 'p2')]));
      expect(await folders.pendingChanges(), greaterThan(0));
      final FluentSyncResult<Folder> pushed = await folders.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async => FluentPushResult.accepted(updated: [for (final Folder f in batch.changed) Folder(id: f.id, name: '${f.name} (server)', pages: f.pages)]),
      );
      expect(pushed.isSuccess, isTrue, reason: pushed.errorMessage);
      expect((await folders.findById(2))?.name, 'local (server)');
      expect(await folders.pendingChanges(), 0, reason: 'the server answer is stored as synced');
    });

    test('watchRemote with store: replace swaps the folders and their pages and stores them as synced', () async {
      final SyncFolders folders = SyncFolders();
      final PagesProvider pages = PagesProvider();
      await db.open([folders, pages]);
      await folders.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [
          Folder(id: 1, name: 'old', pages: [Page(id: 10, text: 'old page')]),
        ]),
      );
      final FluentRemoteEvent<Folder> last = await folders
          .watchRemote(
            fetch: () async => FluentRemoteResponse([
              Folder(id: 2, name: 'new', pages: [Page(id: 20, text: 'new page')]),
            ]),
            store: FluentRemoteStore.replace,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect((await folders.findAll()).map((f) => f.name), ['new']);
      expect((await pages.findAll()).map((p) => p.text), ['new page']);
      expect(await folders.pendingChanges(), 0);
    });
  });

  group('syncWithServer arguments', () {
    test('push without onPush and pull without onPull fail with a message, nothing is called', () async {
      final SyncCodes codes = SyncCodes();
      await db.open([codes]);
      final FluentSyncResult<Code> push = await codes.syncWithServer(strategy: FluentSyncStrategy.push);
      expect(push.isSuccess, isFalse);
      expect(push.errorMessage, contains('onPush is missing'));
      final FluentSyncResult<Code> pull = await codes.syncWithServer(strategy: FluentSyncStrategy.pull);
      expect(pull.isSuccess, isFalse);
      expect(pull.errorMessage, contains('onPull is missing'));
      final FluentSyncResult<Code> both = await codes.syncWithServer(onPull: (_) async => const FluentPullResult());
      expect(both.errorMessage, contains('onPush is missing'));
    });
  });

  group('watchSyncStatus', () {
    test('a failing read of the pending count arrives as a stream error and the stream goes on', () async {
      final SyncCodes codes = SyncCodes();
      await db.open([codes]);
      final List<Object> errors = [];
      final List<FluentSyncStatus> statuses = [];
      final StreamSubscription<FluentSyncStatus> sub = codes.watchSyncStatus(coalesce: Duration.zero).listen(statuses.add, onError: errors.add);
      await db.settle();
      expect(statuses, isNotEmpty);
      await codes.db.execute('DROP TABLE "sync_codes"');
      await codes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult());
      await db.settle();
      expect(errors, isNotEmpty);
      await sub.cancel();
    });

    test('cancelling with an update scheduled stops the timer: nothing arrives after the cancel', () async {
      final SyncCodes codes = SyncCodes();
      await db.open([codes]);
      final List<FluentSyncStatus> statuses = [];
      final StreamSubscription<FluentSyncStatus> sub = codes.watchSyncStatus(coalesce: const Duration(hours: 1)).listen(statuses.add);
      await db.settle();
      final int before = statuses.length;
      await codes.save(Code(id: 1, code: 'x')); // schedules a refresh an hour from now
      await pumpEventQueue();
      await sub.cancel();
      expect(statuses.length, before);
    });
  });
}
