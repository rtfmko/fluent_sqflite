// Regression tests for the sync audit fixes (SYN-1, SYN-2, SYN-4, SYN-5, PC-3).
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class FNote extends FluentStorable {
  FNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class FNoteProvider extends FluentProvider<FNote> with FluentSyncable<FNote> {
  @override
  String get tableName => 'f_notes';

  @override
  FNote get modelSample => FNote(text: '');

  @override
  FNote fromCacheJson(Map<String, dynamic> json) => FNote(id: json['id'] as int?, text: json['text'] as String);
}

class FStamped extends FluentStorable with FluentTimestamps {
  FStamped({this.id, required this.text, DateTime? created, DateTime? updated}) {
    createdAt = created;
    updatedAt = updated;
  }

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class FStampedProvider extends FluentProvider<FStamped> with FluentSyncable<FStamped> {
  @override
  String get tableName => 'f_stamped';

  @override
  FStamped get modelSample => FStamped(text: '');

  @override
  FStamped fromCacheJson(Map<String, dynamic> json) => FStamped(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late FNoteProvider notes;
  late FStampedProvider stamped;

  setUp(() async {
    db = FluentTestDb(name: 'fix_sync_${DateTime.now().microsecondsSinceEpoch}');
    notes = FNoteProvider();
    stamped = FStampedProvider();
    await db.open([notes, stamped]);
  });

  tearDown(() => db.close());

  Future<void> deletedWithPendingTombstone() async {
    await notes.save(FNote(id: 1, text: 'a'));
    await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
    await notes.deleteById(1);
    expect(await notes.pendingChanges(), 1);
  }

  Future<List<Object>> pushDeletions() async {
    final List<Object> sent = [];
    await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sent.addAll(batch.deletedKeys);
        return const FluentPushResult.accepted();
      },
    );
    return sent;
  }

  Future<FluentSyncResult<FNote>> pull(FluentConflictPolicy<FNote> conflicts) => notes.syncWithServer(
    strategy: FluentSyncStrategy.pull,
    conflicts: conflicts,
    onPull: (_) async => FluentPullResult(items: [FNote(id: 1, text: 'server')]),
  );

  group('SYN-1: a pending local deletion is not undone by incoming server rows', () {
    test('keepLocal: the row stays deleted and is counted as a conflict', () async {
      await deletedWithPendingTombstone();
      final FluentSyncResult<FNote> result = await pull(const FluentConflictPolicy.keepLocal());
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(result.pulled, 0);
      expect(result.conflicts, 1);
      expect(await notes.findById(1), isNull);
      expect(await pushDeletions(), [1]);
    });

    test('merge: the callback is not called and the row stays deleted', () async {
      await deletedWithPendingTombstone();
      int calls = 0;
      await pull(
        FluentConflictPolicy.merge((local, remote) async {
          calls++;
          return remote;
        }),
      );
      expect(calls, 0);
      expect(await notes.findById(1), isNull);
      expect(await pushDeletions(), [1]);
    });

    test('keepServer: the server row wins and the tombstone is dropped', () async {
      await deletedWithPendingTombstone();
      await pull(const FluentConflictPolicy.keepServer());
      expect((await notes.findById(1))?.text, 'server');
      expect(await notes.pendingChanges(), 0);
      expect(await pushDeletions(), isEmpty);
    });

    test('a deletion pushed already does not block the pull', () async {
      await deletedWithPendingTombstone();
      await pushDeletions();
      await pull(const FluentConflictPolicy.keepLocal());
      expect((await notes.findById(1))?.text, 'server');
    });

    for (final FluentRemoteStore store in [FluentRemoteStore.merge, FluentRemoteStore.mirror, FluentRemoteStore.replace]) {
      test('watchRemote ${store.name}: the row stays deleted', () async {
        await deletedWithPendingTombstone();
        await notes.watchRemote(fetch: () async => FluentRemoteResponse<FNote>([FNote(id: 1, text: 'server')]), store: store, keepWatching: false).last;
        expect(await notes.findById(1), isNull);
        expect(await pushDeletions(), [1]);
      });
    }
  });

  test('SYN-2: rejected keys that were not in the batch are not counted', () async {
    await notes.save(FNote(id: 1, text: 'a'));
    await notes.save(FNote(id: 2, text: 'b'));
    final FluentSyncResult<FNote> result = await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (_) async => const FluentPushResult.accepted(rejected: [2, 99, 'unknown']),
    );
    expect(result.isSuccess, isTrue);
    expect(result.rejected, 1);
    expect(result.pushed, 1);
    expect(await notes.pendingChanges(), 1);
  });

  test('SYN-4: cancelling watchRemote completes while the fetch is still running', () async {
    final Completer<FluentRemoteResponse<FNote>> answer = Completer();
    final StreamSubscription<FluentRemoteEvent<FNote>> sub = notes.watchRemote(fetch: () => answer.future).listen((_) {});
    await pumpEventQueue();
    await sub.cancel().timeout(const Duration(seconds: 3), onTimeout: () => fail('cancel waited for the fetch'));
    answer.complete(FluentRemoteResponse([FNote(id: 1, text: 'late')]));
    await pumpEventQueue();
    await db.settle();
    expect(await notes.count(), 0, reason: 'the late answer is ignored');
  });

  group('SYN-5: syncWithServer from inside its own callbacks fails fast', () {
    test('from onPush', () async {
      await notes.save(FNote(id: 1, text: 'a'));
      FluentSyncResult<FNote>? inner;
      final FluentSyncResult<FNote> outer = await notes
          .syncWithServer(
            strategy: FluentSyncStrategy.push,
            onPush: (_) async {
              inner = await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
              return const FluentPushResult.accepted();
            },
          )
          .timeout(const Duration(seconds: 5), onTimeout: () => fail('deadlock'));
      expect(outer.isSuccess, isTrue);
      expect(inner!.isSuccess, isFalse);
      expect(inner!.error, isA<FluentSyncException>());
      expect((inner!.error! as FluentSyncException).hint, isNotNull);
    });

    test('from onPull, with another strategy', () async {
      FluentSyncResult<FNote>? inner;
      final FluentSyncResult<FNote> outer = await notes
          .syncWithServer(
            strategy: FluentSyncStrategy.pull,
            onPull: (_) async {
              inner = await notes.syncWithServer(onPush: (_) async => const FluentPushResult.accepted(), onPull: (_) async => const FluentPullResult());
              return const FluentPullResult();
            },
          )
          .timeout(const Duration(seconds: 5), onTimeout: () => fail('deadlock'));
      expect(outer.isSuccess, isTrue);
      expect(inner!.error, isA<FluentSyncException>());
    });

    test('a sync after the first one finished works', () async {
      final FluentSyncResult<FNote> r = await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult());
      expect(r.isSuccess, isTrue);
    });
  });

  test('PC-3: creation / modification times sent by the server are kept', () async {
    final DateTime created = DateTime.fromMillisecondsSinceEpoch(1500000000000);
    final DateTime updated = DateTime.fromMillisecondsSinceEpoch(1600000000000);
    await stamped.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async => FluentPullResult(items: [FStamped(id: 1, text: 'x', created: created, updated: updated)]),
    );
    final FStamped? row = await stamped.findById(1);
    expect(row?.createdAt, created);
    expect(row?.updatedAt, updated);
    expect(await stamped.pendingChanges(), 0);
  });

  test('PC-3: a pulled model without times gets the local ones', () async {
    await stamped.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [FStamped(id: 1, text: 'x')]));
    final FStamped? row = await stamped.findById(1);
    expect(row?.createdAt, isNotNull);
  });
}
