// Audit: server sync and remote streams. Tests written to confirm findings; a failing test shows a defect.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class HItem extends FluentStorable with FluentSoftDeletable {
  HItem({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class HItemProvider extends FluentProvider<HItem> with FluentSyncable<HItem> {
  @override
  String get tableName => 'h_items';

  @override
  HItem get modelSample => HItem(name: '');

  @override
  HItem fromCacheJson(Map<String, dynamic> json) => HItem(id: json['id'] as int?, name: json['name'] as String);
}

/// No soft delete: permanent deletes leave tombstones.
class HNote extends FluentStorable {
  HNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class HNoteProvider extends FluentProvider<HNote> with FluentSyncable<HNote> {
  @override
  String get tableName => 'h_notes';

  @override
  HNote get modelSample => HNote(text: '');

  @override
  HNote fromCacheJson(Map<String, dynamic> json) => HNote(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late HItemProvider items;
  late HNoteProvider notes;

  setUp(() async {
    db = FluentTestDb(name: 'audit_sync_${DateTime.now().microsecondsSinceEpoch}');
    items = HItemProvider();
    notes = HNoteProvider();
    await db.open([items, notes]);
  });

  tearDown(() => db.close());

  test('SYN-1: a pull does not bring back a row deleted locally whose deletion is not pushed yet', () async {
    await notes.save(HNote(id: 1, text: 'a'));
    await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await notes.deleteById(1); // hard delete: tombstone waits for the next push
    expect(await notes.pendingChanges(), 1);

    final FluentSyncResult<HNote> pulled = await notes.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async => FluentPullResult(items: [HNote(id: 1, text: 'server edit')]),
    );
    expect(pulled.isSuccess, isTrue, reason: pulled.errorMessage);
    expect(await notes.findById(1), isNull, reason: 'the local delete is a change not sent yet: the row must stay deleted');

    final List<Object> sent = [];
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sent, [1]);
    expect(await notes.findById(1), isNull);
  });

  test('a local edit made during a push stays pending and goes with the next push', () async {
    await items.save(HItem(id: 1, name: 'a'));
    final FluentSyncResult<HItem> first = await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        await items.save(HItem(id: 1, name: 'b'));
        return const FluentPushResult.accepted();
      },
    );
    expect(first.isSuccess, isTrue);
    expect(await items.pendingChanges(), 1);

    final List<String> names = [];
    await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        names.addAll(batch.changed.map((i) => i.name));
        return const FluentPushResult.accepted();
      },
    );
    expect(names, ['b']);
    expect(await items.pendingChanges(), 0);
  });

  test('a row of a synced table deleted during its push leaves a tombstone sent with the next push', () async {
    await notes.save(HNote(id: 1, text: 'a'));
    await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await notes.save(HNote(id: 1, text: 'b'));
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        await notes.deleteById(1);
        return const FluentPushResult.accepted();
      },
    );
    final List<Object> sent = [];
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sent, [1]);
  });

  test('a new row deleted during its first push is deleted on the server with the next push', () async {
    await notes.save(HNote(text: 'new'));
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        await notes.deleteById(batch.changed.single.id);
        return const FluentPushResult.accepted();
      },
    );
    final List<Object> sent = [];
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    expect(sent, hasLength(1), reason: 'the server got the row in the first push, so it must be told about its deletion');
  });

  test('refused rows do not stop the other rows of a batched push', () async {
    for (final String n in ['a', 'b', 'c', 'd', 'e']) {
      await items.save(HItem(name: n));
    }
    final List<HItem> all = await items.findAll(orderBy: 'id');
    final Object refused = all[2].id!;
    int calls = 0;
    final FluentSyncResult<HItem> result = await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: 2,
      onPush: (batch) async {
        calls++;
        final List<Object> inBatch = [for (final HItem i in batch.changed) i.id!];
        return FluentPushResult.accepted(rejected: inBatch.contains(refused) ? [refused] : const []);
      },
    );
    expect(result.isSuccess, isTrue);
    expect(result.pushed, 4);
    expect(result.rejected, 1);
    expect(calls, lessThan(20));
  });

  test('a 4xx error from onPush is not retried; a 500 is', () async {
    await items.save(HItem(name: 'a'));
    int calls = 0;
    final FluentSyncResult<HItem> client = await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      retries: 3,
      retryDelay: const Duration(milliseconds: 1),
      onPush: (batch) async {
        calls++;
        return FluentPushResult.failed(FluentSyncException('bad request', statusCode: 400));
      },
    );
    expect(client.isSuccess, isFalse);
    expect(calls, 1);

    calls = 0;
    await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      retries: 2,
      retryDelay: const Duration(milliseconds: 1),
      onPush: (batch) async {
        calls++;
        return FluentPushResult.failed(FluentSyncException('server down', statusCode: 500));
      },
    );
    expect(calls, 3);
  });

  test('a pull that fails on its second page does not move the since of the next pull', () async {
    int page = 0;
    final FluentSyncResult<HItem> failed = await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        if (request.page == 0) return FluentPullResult(items: [HItem(id: 1, name: 'x')], hasMore: true, cursor: 'c1', serverTime: DateTime(2030));
        throw FluentSyncException('network');
      },
    );
    expect(failed.isSuccess, isFalse);

    DateTime? since = DateTime(1);
    await items.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        page++;
        since = request.since;
        return const FluentPullResult();
      },
    );
    expect(since, isNull, reason: 'the failed pull never reached its last page');
    expect(page, 1);
  });

  test('watchRemote: a fetch answer that arrives after the subscription was cancelled is not stored', () async {
    final Completer<FluentRemoteResponse<HItem>> answer = Completer();
    final StreamSubscription<FluentRemoteEvent<HItem>> sub = items
        .watchRemote(fetch: () => answer.future, source: FluentRemoteSource.remoteOnly)
        .listen((_) {});
    await pumpEventQueue();
    unawaited(sub.cancel());
    answer.complete(FluentRemoteResponse([HItem(id: 1, name: 'late')]));
    await pumpEventQueue();
    await db.settle();
    expect(await items.count(), 0);
  });

  test('watchRemote mirror keeps rows with local changes that were not sent yet', () async {
    await items.save(HItem(id: 1, name: 'local'));
    final FluentRemoteEvent<HItem> last = await items
        .watchRemote(
          fetch: () async => const FluentRemoteResponse<HItem>([]),
          store: FluentRemoteStore.mirror,
          keepWatching: false,
        )
        .last;
    expect(last.phase, FluentRemotePhase.fresh);
    expect(await items.findById(1), isNotNull, reason: 'a change not sent yet is never deleted by a fetch');
  });
}
