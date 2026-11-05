// Sync: change tracking, push batches, pull pages, conflicts, remote deletes, tombstones, server keys, watchRemote.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Item extends FluentStorable with FluentSoftDeletable {
  Item({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class ItemProvider extends FluentProvider<Item> with FluentSyncable<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item(name: '');

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, name: json['name'] as String);
}

/// Without soft delete: permanent deletes leave tombstones.
class Note extends FluentStorable {
  Note({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class NoteProvider extends FluentProvider<Note> with FluentSyncable<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

/// An owner with owned children, both syncable: deleting the owner removes the children through the foreign key.
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

class FolderProvider extends FluentProvider<Folder> with FluentSyncable<Folder> {
  @override
  String get tableName => 'folders';

  @override
  Folder get modelSample => Folder(name: '');

  @override
  Folder fromCacheJson(Map<String, dynamic> json) => Folder(id: json['id'] as int?, name: json['name'] as String, pages: (json['pages'] as List?)?.cast<Page>());
}

class PageProvider extends FluentProvider<Page> with FluentSyncable<Page> {
  @override
  String get tableName => 'pages';

  @override
  Page get modelSample => Page(text: '');

  @override
  Page fromCacheJson(Map<String, dynamic> json) => Page(id: json['id'] as int?, text: json['text'] as String);
}

/// A local auto-increment id, and the server's own id (filled when the server knows the row).
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

void main() {
  setUpFluentTests();

  test('a permanent delete of an owner leaves tombstones for the owned children the cascade removes', () async {
    final FluentTestDb db = FluentTestDb(name: 'sync_cascade');
    final FolderProvider folders = FolderProvider();
    final PageProvider pages = PageProvider();
    await db.open([folders, pages]);

    await folders.save(Folder(id: 1, name: 'f', pages: [Page(id: 10, text: 'a'), Page(id: 11, text: 'b')]));
    await folders.save(Folder(id: 2, name: 'other', pages: [Page(id: 20, text: 'c')]));
    await folders.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await pages.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());

    await folders.deleteById(1);
    expect(await pages.count(), 1, reason: 'the cascade removed the pages of folder 1');

    final List<Object> sent = [];
    await pages.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sent..sort((a, b) => (a as int).compareTo(b as int)), [10, 11]);
    await db.close();
  });

  test('serverKey: server rows, deletions and tombstones use the server id; the push answer fills it', () async {
    final FluentTestDb local = FluentTestDb(name: 'sync_server_key');
    final TicketProvider tickets = TicketProvider();
    await local.open([tickets]);

    await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Ticket(serverId: 's1', title: 'one'), Ticket(serverId: 's2', title: 'two')]));
    await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Ticket(serverId: 's1', title: 'one (edited)')]));
    expect((await tickets.findAll(orderBy: 'server_id')).map((t) => t.title), ['one (edited)', 'two'], reason: 'matched by server_id, not inserted again');

    await tickets.save(Ticket(title: 'made offline'));
    await tickets.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async => FluentPushResult.accepted(updated: [for (final Ticket t in batch.changed) Ticket(id: t.id, serverId: 's3', title: t.title)]),
    );
    expect((await tickets.findFirst(where: FluentFilter.eq('title', 'made offline')))?.serverId, 's3');

    await tickets.deleteWhere(FluentFilter.eq('server_id', 's3'));
    final List<Object> sent = [];
    await tickets.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sent, ['s3'], reason: 'tombstones carry the server key');

    await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: ['s2']));
    expect((await tickets.findAll()).map((t) => t.serverId), ['s1']);
    await local.close();
  });

  late FluentTestDb db;
  late ItemProvider items;
  late NoteProvider notes;

  setUp(() async {
    db = FluentTestDb(name: 'sync_${DateTime.now().microsecondsSinceEpoch}');
    items = ItemProvider();
    notes = NoteProvider();
    await db.open([items, notes]);
  });

  tearDown(() => db.close());

  /// Pushes and returns what was sent: changed names, trashed names, deleted keys.
  Future<({List<String> changed, List<String> deleted, List<Object> keys})> push(ItemProvider p, {int? batchSize}) async {
    final List<String> changed = [], deleted = [];
    final List<Object> keys = [];
    final FluentSyncResult<Item> result = await p.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: batchSize,
      onPush: (batch) async {
        changed.addAll(batch.changed.map((i) => i.name));
        deleted.addAll(batch.deleted.map((i) => i.name));
        keys.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(result.isSuccess, isTrue, reason: result.errorMessage);
    return (changed: changed, deleted: deleted, keys: keys);
  }

  test('every local change is pushed once; edits after a push are pushed again', () async {
    await items.save(Item(id: 1, name: 'a'));
    expect((await push(items)).changed, ['a']);
    expect((await push(items)).changed, isEmpty);

    await items.save(Item(id: 1, name: 'a2'));
    await items.updateById(1, {'name': 'a3'});
    expect((await push(items)).changed, ['a3']);
    expect(await items.pendingChanges(), 0);
  });

  test('an edit made while a push is in flight is pushed with the next one', () async {
    await items.save(Item(id: 1, name: 'v1'));
    await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        await items.save(Item(id: 1, name: 'v2'));
        return const FluentPushResult.accepted();
      },
    );
    expect((await push(items)).changed, ['v2']);
  });

  test('pulled rows are stored as synced (no echo); the since cursor is kept', () async {
    final List<DateTime?> since = [];
    final DateTime serverTime = DateTime(2026, 1, 2, 3);
    for (int i = 0; i < 2; i++) {
      await items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (request) async {
          since.add(request.since);
          return FluentPullResult(items: [Item(id: 7, name: 'server')], serverTime: serverTime);
        },
      );
    }
    expect(since, [null, serverTime]);
    expect((await items.findById(7))?.name, 'server');
    expect((await push(items)).changed, isEmpty);
  });

  test('a local change not pushed yet wins over the server, unless the policy merges or lets the server win', () async {
    await items.save(Item(id: 1, name: 'local'));
    FluentSyncResult<Item> result = await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'remote')]));
    expect(result.conflicts, 1);
    expect((await items.findById(1))?.name, 'local');

    result = await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'remote')]),
      conflicts: FluentConflictPolicy.merge((local, remote) async => Item(id: 1, name: '${local.name}+${remote.name}')),
    );
    expect((await items.findById(1))?.name, 'local+remote');
    expect((await push(items)).changed, ['local+remote'], reason: 'the merge is a local change to send');

    await items.save(Item(id: 1, name: 'mine'));
    result = await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'theirs')]),
      conflicts: const FluentConflictPolicy.keepServer(),
    );
    expect((await items.findById(1))?.name, 'theirs');
    expect(await items.pendingChanges(), 0, reason: 'the local change was dropped');
  });

  test('remote deletes follow the behavior; local changes are not deleted', () async {
    await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'a'), Item(id: 2, name: 'b'), Item(id: 3, name: 'c')]));
    await items.save(Item(id: 3, name: 'c-local'));

    final FluentSyncResult<Item> result = await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: [1, 3]));
    expect(result.remoteDeleted, 1);
    expect((await items.trash.find()).map((i) => i.id), [1], reason: 'soft-deletable: soft delete');
    expect((await items.findById(3))?.name, 'c-local');
    expect((await push(items)).deleted, isEmpty, reason: 'a deletion received from the server is not sent back');

    await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Note(id: 5, text: 'x')]));
    await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: [5]), remoteDeletes: FluentRemoteDeleteBehavior.soft);
    expect(await notes.findById(5), isNotNull, reason: 'soft requested but Note has no soft delete: kept');
    await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: [5]));
    expect(await notes.findById(5), isNull);
  });

  test('local deletions are pushed: trashed rows, and tombstones of permanent deletes', () async {
    await items.saveAll([Item(id: 1, name: 'a'), Item(id: 2, name: 'b')]);
    await push(items);
    await items.deleteById(1);
    expect((await push(items)).deleted, ['a']);
    expect(await items.trash.empty(olderThan: Duration.zero), 1, reason: 'the deletion was pushed, so it may leave the trash');

    final List<Object> sentKeys = [];
    await notes.saveAll([Note(id: 1, text: 'x'), Note(id: 2, text: 'never pushed')]);
    await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await notes.save(Note(id: 3, text: 'local only'));
    await notes.deleteById(1);
    await notes.deleteById(3);
    expect(await notes.pendingChanges(), 1, reason: 'only the row the server knew needs a tombstone');
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sentKeys.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sentKeys, [1]);
    expect(await notes.pendingChanges(), 0);
  });

  test('the trash keeps deletions that were not pushed yet; clearTable leaves no tombstones', () async {
    await items.save(Item(id: 1, name: 'a'));
    await items.delete(Item(id: 1, name: 'a'));
    expect(await items.trash.empty(olderThan: Duration.zero), 0);

    await notes.save(Note(id: 1, text: 'x'));
    await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await notes.clearTable();
    expect(await notes.pendingChanges(), 0);
  });

  test('batches, a rejected push keeps everything pending, concurrent syncs share one run', () async {
    await items.saveAll([for (int i = 1; i <= 5; i++) Item(id: i, name: 'i$i')]);
    final FluentSyncResult<Item> rejected = await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.failed());
    expect(rejected.isSuccess, isFalse);
    expect(await items.pendingChanges(), 5);

    int calls = 0;
    Future<FluentSyncResult<Item>> run() => items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: 2,
      onPush: (batch) async {
        calls++;
        expect(batch.length, lessThanOrEqualTo(2));
        return const FluentPushResult.accepted();
      },
    );
    final List<FluentSyncResult<Item>> both = await Future.wait([run(), run()]);
    expect(both.first.pushed, 5);
    expect(identical(both.first, both.last), isTrue);
    expect(calls, 3);
  });

  test('watchRemote stores every fetched row, keeps local changes, and keeps watching', () async {
    for (int i = 10; i < 15; i++) {
      await items.save(Item(id: i, name: 'old$i'));
    }
    await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await items.save(Item(id: 14, name: 'local14'));

    final List<FluentRemoteEvent<Item>> events = [];
    final StreamSubscription<FluentRemoteEvent<Item>> sub = items
        .watchRemote(
          fetch: () async => FluentRemoteResponse([for (int i = 10; i < 15; i++) Item(id: i, name: 'new$i')]),
          where: FluentFilter.gte('id', 10),
          orderBy: 'id',
          limit: 2,
        )
        .listen(events.add);
    await db.settle();

    expect([for (final Item i in await items.find(where: FluentFilter.gte('id', 10), orderBy: 'id')) i.name], ['new10', 'new11', 'new12', 'new13', 'local14']);
    expect(events.map((e) => e.phase), [FluentRemotePhase.cached, FluentRemotePhase.fetching, FluentRemotePhase.fresh]);
    expect(events.first.items.map((i) => i.name), ['old10', 'old11']);
    expect(events.last.items.map((i) => i.name), ['new10', 'new11'], reason: 'fresh rows are read back from the table');

    await items.updateById(10, {'name': 'live'});
    await db.settle();
    expect(events.last.items.first.name, 'live', reason: 'keepWatching emits later changes');
    expect(events.last.phase, FluentRemotePhase.fresh);
    await sub.cancel();
  });

  test('mirror removes rows missing from a full answer, never with a page limit', () async {
    await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'a'), Item(id: 2, name: 'b')]));
    Future<void> run({int? limit}) =>
        items.watchRemote(fetch: () async => FluentRemoteResponse([Item(id: 1, name: 'a')]), store: FluentRemoteStore.mirror, limit: limit, keepWatching: false).drain<void>();

    await run(limit: 1);
    expect(await items.count(), 2);
    await run();
    expect(await items.count(), 1);
  });

  test('watchRemote: failures keep the cache, 4xx are not retried, clearCacheOn removes the rows', () async {
    await items.save(Item(id: 1, name: 'cached'));
    await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted()); // unsent rows are never cleared
    int calls = 0;
    Future<FluentRemoteEvent<Item>> run(FluentRemoteResponse<Item> response, {Set<int> clearCacheOn = const {}}) =>
        items.watchRemote(fetch: () async {
          calls++;
          return response;
        }, retries: 3, retryDelay: Duration.zero, clearCacheOn: clearCacheOn, keepWatching: false).last;

    FluentRemoteEvent<Item> last = await run(const FluentRemoteResponse.failed(503));
    expect(calls, 4, reason: '5xx is retried');
    expect(last.hasError, isTrue);
    expect(last.items.single.name, 'cached');

    calls = 0;
    last = await run(const FluentRemoteResponse.failed(401), clearCacheOn: {401});
    expect(calls, 1, reason: '4xx is not retried');
    expect((last.error! as FluentSyncException).statusCode, 401);
    expect(last.items, isEmpty, reason: 'clearCacheOn removed the cached rows');
  });

  test('watchRemote sources: remoteOnly waits for the server, cacheOnly never fetches, none does not store', () async {
    await items.save(Item(id: 1, name: 'cached'));
    int calls = 0;
    Future<FluentRemoteResponse<Item>> fetch() async {
      calls++;
      return FluentRemoteResponse([Item(id: 2, name: 'remote')]);
    }

    final List<FluentRemoteEvent<Item>> remote = await items.watchRemote(fetch: fetch, source: FluentRemoteSource.remoteOnly, keepWatching: false).toList();
    expect(remote.map((e) => e.phase), [FluentRemotePhase.fetching, FluentRemotePhase.fresh]);
    expect(remote.first.items, isEmpty);

    final List<FluentRemoteEvent<Item>> cache = await items.watchRemote(fetch: fetch, source: FluentRemoteSource.cacheOnly, keepWatching: false).toList();
    expect(cache.single.phase, FluentRemotePhase.cached);
    expect(calls, 1);

    final FluentRemoteEvent<Item> none = await items.watchRemote(fetch: () async => FluentRemoteResponse([Item(id: 3, name: 'not stored')]), store: FluentRemoteStore.none).last;
    expect(none.items.single.name, 'not stored');
    expect(await items.findById(3), isNull);
  });

  test('watchRemote does not move the since of syncWithServer', () async {
    final DateTime serverTime = DateTime(2026, 5);
    await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(serverTime: serverTime));
    await items.watchRemote(fetch: () async => FluentRemoteResponse([Item(id: 1, name: 'a')]), keepWatching: false).drain<void>();
    DateTime? since;
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        since = request.since;
        return const FluentPullResult();
      },
    );
    expect(since, serverTime);
  });

  test('the since of the next pull is taken before asking the server', () async {
    final DateTime start = DateTime(2026, 6, 1, 12);
    db.clock.set(start);
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async {
        db.clock.advance(const Duration(minutes: 5)); // a slow server
        return FluentPullResult(items: [Item(id: 1, name: 'a')]);
      },
    );
    DateTime? since;
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        since = request.since;
        return const FluentPullResult();
      },
    );
    expect(since, start);
  });

  test('pull pages: every page is stored, the since moves only after the last one', () async {
    final List<FluentPullRequest> requests = [];
    final DateTime first = DateTime(2026, 7);
    Future<FluentPullResult<Item>> pages(FluentPullRequest request) async {
      requests.add(request);
      return switch (request.page) {
        0 => FluentPullResult(items: [Item(id: 1, name: 'a')], serverTime: first, hasMore: true, cursor: 'p1'),
        1 => FluentPullResult(items: [Item(id: 2, name: 'b')], serverTime: DateTime(2030), hasMore: true, cursor: 'p2'),
        _ => FluentPullResult(items: [Item(id: 3, name: 'c')], deletedKeys: const [1]),
      };
    }

    final FluentSyncResult<Item> result = await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: pages);
    expect(result.pulled, 3);
    expect(requests.map((r) => r.cursor), [null, 'p1', 'p2']);
    expect((await items.findAll(orderBy: 'id')).map((i) => i.name), ['b', 'c']);

    requests.clear();
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        requests.add(request);
        if (request.page == 1) throw StateError('offline');
        return FluentPullResult(items: [Item(id: 4, name: 'd')], serverTime: DateTime(2031), hasMore: true, cursor: 'x');
      },
    );
    expect(requests.first.since, first, reason: 'the time of the first page counts');
    expect(await items.findById(4), isNotNull, reason: 'the first page was stored');
    DateTime? since;
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        since = request.since;
        return const FluentPullResult();
      },
    );
    expect(since, first, reason: 'an interrupted pull does not move the since');
  });

  test('push results: refused rows stay waiting, the server version of a row is stored as synced', () async {
    await items.saveAll([for (int i = 1; i <= 4; i++) Item(id: i, name: 'i$i')]);
    int calls = 0;
    final FluentSyncResult<Item> result = await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: 2,
      onPush: (batch) async {
        calls++;
        return FluentPushResult.accepted(rejected: [if (batch.changed.any((i) => i.id == 1)) 1], updated: [for (final Item i in batch.changed) if (i.id == 2) Item(id: 2, name: 'i2 (server)')]);
      },
    );
    expect(result.isSuccess, isTrue);
    expect(result.pushed, 3);
    expect(result.rejected, 1);
    expect(calls, 2, reason: 'the refused row is not sent again in the same sync');
    expect(await items.pendingChanges(), 1);
    expect((await items.findById(2))?.name, 'i2 (server)');
    expect((await push(items)).changed, ['i1'], reason: 'only the refused row is sent next time');
  });

  test('sync retries: 4xx errors are not retried, a failure is logged once', () async {
    int calls = 0;
    final FluentSyncResult<Item> result = await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      retries: 3,
      retryDelay: Duration.zero,
      onPull: (_) async {
        calls++;
        throw FluentSyncException('denied', statusCode: 403);
      },
    );
    expect(result.isSuccess, isFalse);
    expect(calls, 1);
  });
}
