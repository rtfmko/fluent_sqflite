// Sync guarantees (TEST_PLAN.md, T2): G10 nothing lost or doubled, G23 exact push, G24 pull follows the chosen mode,
// G31 a quiet round changes nothing, G1 a failure inside push bookkeeping or a pull page leaves nothing half-done.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/faults.dart';
import '../../helpers/guarantees.dart';
import 'sync_fake_server.dart';

/// Soft delete: a delete moves the row to the trash; the push sends it as `deleted`.
class GItem extends FluentStorable with FluentSoftDeletable {
  GItem({this.id, required this.name});

  final int? id;
  final String name;

  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true); // not auto-increment: keys are shared with the server

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class GItems extends FluentProvider<GItem> with FluentSyncable<GItem> {
  @override
  String get tableName => 'g_items';

  @override
  GItem get modelSample => GItem(name: '');

  @override
  GItem fromCacheJson(Map<String, dynamic> json) => GItem(id: json['id'] as int?, name: json['name'] as String);
}

/// No soft delete: a delete removes the row and leaves a tombstone.
class GNote extends FluentStorable {
  GNote({this.id, required this.name});

  final int? id;
  final String name;

  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true); // not auto-increment: keys are shared with the server

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class GNotes extends FluentProvider<GNote> with FluentSyncable<GNote> {
  @override
  String get tableName => 'g_notes';

  @override
  GNote get modelSample => GNote(name: '');

  @override
  GNote fromCacheJson(Map<String, dynamic> json) => GNote(id: json['id'] as int?, name: json['name'] as String);
}

FakeServer<GItem> itemServer() => FakeServer<GItem>(idOf: (m) => m.id!, nameOf: (m) => m.name, make: (id, name) => GItem(id: id, name: name));
FakeServer<GNote> noteServer() => FakeServer<GNote>(idOf: (m) => m.id!, nameOf: (m) => m.name, make: (id, name) => GNote(id: id, name: name));

/// Local state of one row before the pull (G24 table).
/// trashSynced: in the trash and that deletion was pushed (the server may restore the row).
enum LocalState { absent, clean, pendingEdit, pendingTrash, trashSynced, tombstone }

/// Policy under test.
enum Policy { keepLocal, keepServer, merge }

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late GItems items;
  late GNotes notes;
  late FakeServer<GItem> si;
  late FakeServer<GNote> sn;

  setUp(() async {
    db = FluentTestDb();
    items = GItems();
    notes = GNotes();
    si = itemServer();
    sn = noteServer();
    await db.open([items, notes]);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Map<int, String>> liveOf(FluentProvider p) async => {for (final Map<String, dynamic> r in await p.findMaps()) r['id'] as int: r['name'] as String};
  Future<Set<int>> trashOf() async => {for (final GItem i in await items.trash.find()) i.id!};

  /// Server and local hold [rows], synced.
  Future<void> seedItems(Map<int, String> rows) async {
    rows.forEach(si.edit);
    expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
  }

  Future<void> seedNotes(Map<int, String> rows) async {
    rows.forEach(sn.edit);
    expect((await sn.sync(notes, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
  }

  Future<void> finish() async {
    await expectIntegrity(items.db);
    expectIssuesHaveFixes(db.issues);
  }

  group('G23 push is exact', () {
    test('G23: a push in pages sends each pending change once (rows, trash, deletions) and marks exactly the accepted ones', () async {
      await seedItems({1: 'a', 2: 'b', 3: 'c', 4: 'd'});
      await items.save(GItem(id: 1, name: 'a2'));
      await items.deleteById(2); // trash
      await items.trash.deleteForeverById(3); // tombstone (the server knows 3)
      await items.save(GItem(id: 6, name: 'new'));
      await items.save(GItem(id: 7, name: 'refused'));
      si.rejectKeys = {7};
      expect(await items.pendingChanges(), 5);

      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.push, batchSize: 2);
      expect(r.isSuccess, isTrue, reason: r.errorMessage);
      final List<String> sent = [
        for (final ReceivedBatch b in si.received) ...[...b.changed.keys.map((k) => 'row $k'), ...b.deleted.keys.map((k) => 'trash $k'), ...b.deletedKeys.map((k) => 'key $k')],
      ];
      expect(sent.toSet(), {'row 1', 'trash 2', 'key 3', 'row 6', 'row 7'}, reason: 'every pending change is sent');
      expect(sent, hasLength(sent.toSet().length), reason: 'nothing is sent twice in one round: $sent');
      expect(r.pushed, 4, reason: 'pushed counts what the server accepted');
      expect(r.rejected, 1);
      final SyncState s = await SyncState.read(db, items);
      expect(s.pending, {7}, reason: 'only the refused row stays pending');
      expect(s.tombstones, isEmpty);
      expect(await items.pendingChanges(), 1, reason: 'pendingChanges agrees with the per-row state');
      expect(si.alive, {1: 'a2', 4: 'd', 6: 'new'});
      await finish();
    });

    test('G23: a failed or thrown push answer marks nothing of its batch; batches accepted before stay marked; the next push sends the rest', () async {
      for (final PushAnswer failure in [PushAnswer.fail, PushAnswer.throwError]) {
        await items.clearTable();
        si = itemServer();
        for (int i = 1; i <= 6; i++) {
          await items.save(GItem(id: i, name: 'v$i'));
        }
        si.pushAnswers.addAll([PushAnswer.accept, failure]);
        final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.push, batchSize: 2);
        expect(r.isSuccess, isFalse);
        expect(r.pushed, 2, reason: 'the accepted first batch is counted ($failure)');
        final SyncState s = await SyncState.read(db, items);
        expect(s.pending, {3, 4, 5, 6}, reason: 'the failed batch and the unsent rows stay pending ($failure)');
        expect(await items.pendingChanges(), 4);
        final FluentSyncResult<GItem> again = await si.sync(items, strategy: FluentSyncStrategy.push, batchSize: 2);
        expect(again.isSuccess, isTrue);
        expect(again.pushed, 4);
        expect(si.alive, {for (int i = 1; i <= 6; i++) i: 'v$i'}, reason: 'G10: nothing lost');
        expect(await items.pendingChanges(), 0);
      }
      await finish();
    });

    test('G23: rejected keys that were not in the batch refuse nothing', () async {
      await items.save(GItem(id: 1, name: 'a'));
      si.rejectForeign = {99, 1000};
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.push);
      expect(r.isSuccess, isTrue);
      expect(r.rejected, 0);
      expect(r.pushed, 1);
      expect(await items.pendingChanges(), 0);
      await finish();
    });

    test('G23: pendingChanges(where:) counts the pending rows of the filter plus every deletion', () async {
      await seedNotes({1: 'a', 2: 'b'});
      await notes.save(GNote(id: 3, name: 'x'));
      await notes.save(GNote(id: 4, name: 'y'));
      await notes.deleteById(1); // tombstone
      expect(await notes.pendingChanges(), 3);
      expect(await notes.pendingChanges(where: FluentFilter.eq('name', 'x')), 2);
      final FluentSyncResult<GNote> r = await sn.sync(notes, strategy: FluentSyncStrategy.push, where: FluentFilter.eq('name', 'x'));
      expect(r.isSuccess, isTrue);
      expect(sn.received.single.changed.keys, [3], reason: 'where limits the rows');
      expect(sn.received.single.deletedKeys, [1], reason: 'deletions are always sent');
      expect((await SyncState.read(db, notes)).pending, {4});
      expect(await notes.pendingChanges(), 1);
      await finish();
    });

    test('G23: an edit made while its push is in flight stays pending and is sent with the next push', () async {
      await items.save(GItem(id: 1, name: 'v1'));
      await items.save(GItem(id: 2, name: 'w1'));
      si.duringPush = (call, batch) async {
        if (call == 0) await items.save(GItem(id: 1, name: 'v2'));
      };
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.push);
      expect(r.isSuccess, isTrue);
      expect(si.alive, {1: 'v1', 2: 'w1'});
      expect((await SyncState.read(db, items)).pending, {1});
      si.duringPush = null;
      await si.sync(items, strategy: FluentSyncStrategy.push);
      expect(si.alive, {1: 'v2', 2: 'w1'});
      expect(await items.pendingChanges(), 0);
      await finish();
    });
  });

  group('G24 pull follows the chosen mode', () {
    // Conflict policy x local state x server change, for both models. Expected: what the documentation says.
    for (final bool soft in [true, false]) {
      for (final LocalState state in LocalState.values) {
        if (soft && state == LocalState.tombstone) continue;
        if (!soft && (state == LocalState.pendingTrash || state == LocalState.trashSynced)) continue;
        for (final bool serverDeletes in [false, true]) {
          if (state == LocalState.trashSynced && serverDeletes) continue; // the server has it deleted already
          for (final Policy policy in Policy.values) {
            final String name = 'G24: ${soft ? 'soft' : 'hard'} model, local ${state.name}, server ${serverDeletes ? 'deletes' : 'edits'}, ${policy.name}';
            final bool known = _knownBug(soft, state, serverDeletes, policy) != null;
            test(name, skip: _knownBug(soft, state, serverDeletes, policy), () async {
              if (soft) {
                await _g24Case<GItem>(db, items, si, (n) => GItem(id: 1, name: n), (m) => m.name, state, serverDeletes, policy, trashOf);
              } else {
                await _g24Case<GNote>(db, notes, sn, (n) => GNote(id: 1, name: n), (m) => m.name, state, serverDeletes, policy, null);
              }
              if (!known) await finish();
            });
          }
        }
      }
    }

    test('G24: remoteDeletes auto / soft / hard / keep do exactly their effect on a clean row', () async {
      for (final FluentRemoteDeleteBehavior mode in FluentRemoteDeleteBehavior.values) {
        await items.clearTable();
        await notes.clearTable();
        si = itemServer();
        sn = noteServer();
        await seedItems({1: 'a', 2: 'b'});
        await seedNotes({1: 'a', 2: 'b'});
        si.delete(1);
        sn.delete(1);
        final FluentSyncResult<GItem> ri = await si.sync(items, strategy: FluentSyncStrategy.pull, remoteDeletes: mode);
        final FluentSyncResult<GNote> rn = await sn.sync(notes, strategy: FluentSyncStrategy.pull, remoteDeletes: mode);
        expect(ri.isSuccess && rn.isSuccess, isTrue);
        final bool keep = mode == FluentRemoteDeleteBehavior.keep;
        expect(await liveOf(items), keep ? {1: 'a', 2: 'b'} : {2: 'b'}, reason: 'items, $mode');
        expect(await trashOf(), mode == FluentRemoteDeleteBehavior.auto || mode == FluentRemoteDeleteBehavior.soft ? {1} : <int>{}, reason: 'items trash, $mode');
        final bool noteKept = keep || mode == FluentRemoteDeleteBehavior.soft;
        expect(await liveOf(notes), noteKept ? {1: 'a', 2: 'b'} : {2: 'b'}, reason: 'notes, $mode');
        if (mode == FluentRemoteDeleteBehavior.soft) expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.remoteDeleteKept));
        expect(ri.remoteDeleted, keep ? 0 : 1, reason: 'items remoteDeleted, $mode');
        expect(rn.remoteDeleted, noteKept ? 0 : 1, reason: 'notes remoteDeleted, $mode');
        expect(await items.pendingChanges(), 0, reason: 'a remote delete is not a local change');
        expect(await notes.pendingChanges(), 0, reason: 'a remote delete leaves no tombstone');
      }
      await finish();
    });

    test('G24: the since cursor moves only after a complete pull; pages before a failure stay stored', () async {
      for (int i = 1; i <= 5; i++) {
        si.edit(i, 'v$i');
      }
      si
        ..pageSize = 2
        ..failPullPage = 1;
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.pull);
      expect(r.isSuccess, isFalse);
      expect(await liveOf(items), {1: 'v1', 2: 'v2'}, reason: 'page 0 is stored, page 1 failed');
      expect((await SyncState.read(db, items)).lastPull, isNull, reason: 'since did not move');
      final FluentSyncResult<GItem> again = await si.sync(items, strategy: FluentSyncStrategy.pull);
      expect(again.isSuccess, isTrue);
      expect(si.pullRequests.last.since, isNull, reason: 'the next pull asks from the old since');
      expect(await liveOf(items), si.alive);
      expect((await SyncState.read(db, items)).lastPull, si.clock);
      await finish();
    });

    test('G24: a cancel between pages keeps the pages stored so far and does not move since', () async {
      await seedItems({1: 'a'});
      final int since = (await SyncState.read(db, items)).lastPull!;
      for (int i = 2; i <= 6; i++) {
        si.edit(i, 'v$i');
      }
      final FluentCancelToken cancel = FluentCancelToken();
      si
        ..pageSize = 2
        ..duringPull = (request) async {
          if (request.page == 1) cancel.cancel();
        };
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.pull, cancel: cancel);
      expect(r.isCancelled, isTrue);
      expect(await liveOf(items), {1: 'a', 2: 'v2', 3: 'v3'});
      expect((await SyncState.read(db, items)).lastPull, since);
      si.duringPull = null;
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      expect(await liveOf(items), si.alive);
      await finish();
    });

    test('G24: a page answered after a cancel is not stored, also when a local edit ran while it was fetched', () async {
      for (final FluentConflictPolicy<GNote> policy in [const FluentConflictPolicy<GNote>.keepServer(), const FluentConflictPolicy<GNote>.keepLocal()]) {
        await notes.clearTable();
        sn = noteServer();
        await seedNotes({1: 'a', 2: 'b'});
        sn
          ..edit(1, 'a2')
          ..edit(2, 'b2')
          ..pageSize = 1;
        final FluentCancelToken cancel = FluentCancelToken();
        sn.duringPull = (request) async {
          if (request.page == 1) {
            await notes.save(GNote(id: 2, name: 'local'));
            cancel.cancel();
          }
        };
        final FluentSyncResult<GNote> r = await sn.sync(notes, strategy: FluentSyncStrategy.pull, conflicts: policy, cancel: cancel);
        expect(r.isCancelled, isTrue);
        expect(await liveOf(notes), {1: 'a2', 2: 'local'}, reason: 'page 1 came after the cancel: not stored (${policy.serverWins})');
        expect((await SyncState.read(db, notes)).pending, {2});
      }
      await finish();
    });

    test('G24: server changes made while a pull runs come with the next pull (not lost)', () async {
      for (int i = 1; i <= 4; i++) {
        si.edit(i, 'v$i');
      }
      si
        ..pageSize = 2
        ..duringPull = (request) async {
          if (request.page == 1) {
            si.edit(1, 'changed during the pull');
            si.delete(4);
          }
        };
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      si.duringPull = null;
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      expect(await liveOf(items), si.alive);
      expect(await liveOf(items), {1: 'changed during the pull', 2: 'v2', 3: 'v3'});
      await finish();
    });

    test('G24: watchRemote merge / mirror / replace / none store exactly their effect and keep unsent local changes', () async {
      for (final FluentRemoteStore store in FluentRemoteStore.values) {
        for (final bool paged in [false, true]) {
          await items.clearTable();
          si = itemServer();
          await seedItems({1: 'a', 2: 'b', 3: 'c'});
          final int? since = (await SyncState.read(db, items)).lastPull;
          await items.save(GItem(id: 3, name: 'local edit'));
          final List<GItem> answer = [GItem(id: 1, name: 'a2'), GItem(id: 3, name: 'server c'), GItem(id: 4, name: 'd')];
          final List<FluentRemoteEvent<GItem>> events = await items
              .watchRemote(
                fetch: paged ? null : () async => FluentRemoteResponse(answer),
                fetchPage: !paged
                    ? null
                    : (request) async => FluentRemoteResponse(answer.sublist(request.page * 2, (request.page * 2 + 2).clamp(0, 3)), hasMore: request.page == 0, cursor: request.page + 1),
                store: store,
                keepWatching: false,
              )
              .toList()
              .timeout(const Duration(seconds: 10));
          expect(events.last.phase, FluentRemotePhase.fresh, reason: '$store paged=$paged: ${events.last.error}');
          final Map<int, String> expected = switch (store) {
            FluentRemoteStore.merge => {1: 'a2', 2: 'b', 3: 'local edit', 4: 'd'},
            FluentRemoteStore.mirror => {1: 'a2', 3: 'local edit', 4: 'd'},
            FluentRemoteStore.replace => {1: 'a2', 3: 'local edit', 4: 'd'},
            FluentRemoteStore.none => {1: 'a', 2: 'b', 3: 'local edit'},
          };
          expect(await liveOf(items), expected, reason: '$store paged=$paged');
          final SyncState s = await SyncState.read(db, items);
          expect(s.pending, {3}, reason: '$store paged=$paged: only the local edit is pending; fetched rows are synced');
          expect(s.tombstones, isEmpty, reason: '$store paged=$paged: a cache store tells the server nothing');
          expect(s.lastPull, since, reason: '$store paged=$paged: watchRemote does not move the since of syncWithServer');
          if (store == FluentRemoteStore.none) expect(events.last.items.map((i) => i.name), ['a2', 'server c', 'd'], reason: 'none returns the answer');
        }
      }
      await finish();
    });

    test('G24: a pull without serverTime reports pullClock and uses the device time', () async {
      si.edit(1, 'a');
      si.omitServerTime = true;
      db.clock.set(DateTime.fromMillisecondsSinceEpoch(5000000));
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      expect((await SyncState.read(db, items)).lastPull, 5000000);
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.pullClock));
      await finish();
    });
  });

  group('G31 idempotent rounds', () {
    test('G31: a sync round with nothing new changes nothing (rows, versions, tombstones, since)', () async {
      await seedItems({1: 'a', 2: 'b'});
      await items.save(GItem(id: 3, name: 'c'));
      await items.deleteById(2);
      await si.sync(items);
      await si.sync(items); // the echo of the pushed rows
      final String before = (await SyncState.read(db, items)).dump;
      final FluentSyncResult<GItem> r = await si.sync(items);
      expect(r.isSuccess, isTrue);
      expect(r.pushed, 0);
      expect(r.pulled, 0);
      expect((await SyncState.read(db, items)).dump, before);
      await finish();
    });

    test('G31: pulling the same server rows twice (an echo) changes nothing', () async {
      await seedNotes({1: 'a', 2: 'b'});
      final String before = (await SyncState.read(db, notes)).dump.split('\nsince').first;
      sn.edit(1, 'a'); // same value, new version
      await sn.sync(notes, strategy: FluentSyncStrategy.pull);
      expect((await SyncState.read(db, notes)).dump.split('\nsince').first, before);
      await finish();
    });
  });

  group('G10 nothing lost', () {
    test('G10: a key deleted, saved again and deleted again before a push still reaches the server as deleted', () async {
      await seedNotes({1: 'a'});
      await notes.deleteById(1);
      await notes.save(GNote(id: 1, name: 'again'));
      await notes.deleteById(1);
      expect(await notes.pendingChanges(), 1, reason: 'the deletion is still to be sent');
      await sn.sync(notes);
      expect(sn.alive, isEmpty);
      expect(await liveOf(notes), sn.alive);
      await finish();
    });

    test('G10: a new row edited while its first push ran, then deleted, is deleted on the server', () async {
      si.duringPush = (call, batch) async {
        if (call == 0) await notes.save(GNote(id: 1, name: 'v2'));
      };
      await notes.save(GNote(id: 1, name: 'v1'));
      await sn.sync(notes, strategy: FluentSyncStrategy.push);
      expect(sn.alive, {1: 'v1'});
      await notes.deleteById(1);
      expect(await notes.pendingChanges(), 1, reason: 'the deletion is to be sent');
      sn.duringPush = null;
      await sn.sync(notes);
      expect(sn.alive, isEmpty);
      await finish();
    });

    test('G10: a row deleted for good while its first push runs is deleted on the server by the next push', () async {
      sn.duringPush = (call, batch) async {
        if (call == 0) await notes.deleteById(1);
      };
      await notes.save(GNote(id: 1, name: 'v1'));
      await sn.sync(notes, strategy: FluentSyncStrategy.push);
      expect(await notes.pendingChanges(), 1);
      sn.duringPush = null;
      await sn.sync(notes);
      expect(sn.alive, isEmpty);
      expect(await liveOf(notes), isEmpty);
      await finish();
    });

    test('G10: a row whose push answer was lost (cancel, failure after the server stored it), then deleted, is deleted on the server', () async {
      for (final PushAnswer answer in [PushAnswer.accept, PushAnswer.throwError]) {
        await notes.clearTable();
        sn = noteServer();
        final FluentCancelToken cancel = FluentCancelToken();
        sn.duringPush = (call, batch) async {
          // The server stores the batch; the device never learns it (cancelled, or the connection broke).
          for (final GNote n in batch.changed) {
            sn.edit(n.id!, n.name);
          }
          if (answer == PushAnswer.accept) cancel.cancel();
        };
        if (answer != PushAnswer.accept) sn.pushAnswers.add(answer);
        await notes.save(GNote(id: 1, name: 'v1'));
        final FluentSyncResult<GNote> r = await sn.sync(notes, strategy: FluentSyncStrategy.push, cancel: cancel);
        expect(r.isSuccess, isFalse);
        expect(sn.alive, {1: 'v1'});
        await notes.deleteById(1);
        expect(await notes.pendingChanges(), 1, reason: 'the deletion is to be sent ($answer)');
        sn.duringPush = null;
        expect((await sn.sync(notes)).isSuccess, isTrue);
        expect(sn.alive, isEmpty, reason: '$answer');
      }
      await finish();
    });

    test('G10: a local row that kept its change against a server row (keepLocal / merge), then deleted, is deleted on the server', () async {
      for (final FluentConflictPolicy<GNote> policy in [const FluentConflictPolicy<GNote>.keepLocal(), FluentConflictPolicy<GNote>.merge((l, r) async => GNote(id: l.id, name: '${l.name}+${r.name}'))]) {
        await notes.clearTable();
        sn = noteServer();
        await notes.save(GNote(id: 1, name: 'made offline'));
        sn.edit(1, 'made on the server'); // the same key, on both sides
        expect((await sn.sync(notes, strategy: FluentSyncStrategy.pull, conflicts: policy)).isSuccess, isTrue);
        await notes.deleteById(1);
        expect(await notes.pendingChanges(), 1, reason: 'the server has the key: its deletion is to be sent');
        expect((await sn.sync(notes)).isSuccess, isTrue);
        expect(sn.alive, isEmpty);
        expect(await liveOf(notes), isEmpty);
      }
      await finish();
    });

    test('G13: a failed sync reports a typed error with a hint and keeps the callback error as cause', () async {
      await items.save(GItem(id: 1, name: 'a'));
      final FluentSyncResult<GItem> failed = await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.failed('HTTP 503'));
      expectTypedError(failed.error!);
      expect((failed.error! as FluentException).cause, 'HTTP 503');
      final StateError boom = StateError('offline');
      final FluentSyncResult<GItem> thrown = await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => throw boom);
      expectTypedError(thrown.error!);
      expect((thrown.error! as FluentException).cause, same(boom));
      final FluentSyncResult<GItem> missing = await items.syncWithServer(strategy: FluentSyncStrategy.pull);
      expectTypedError(missing.error!);
      final FluentSyncException typed = FluentSyncException('unauthorized', statusCode: 401, hint: 'log in');
      final FluentSyncResult<GItem> own = await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => throw typed, retries: 3, retryDelay: Duration.zero);
      expect(own.error, same(typed), reason: 'a FluentException of the app is kept as it is (its status decides the retries)');
      expect(await items.pendingChanges(), 1);
      await finish();
    });

    test('G10: clearTable with unsent changes reports them; clearLocally keeps them', () async {
      await seedNotes({1: 'a', 2: 'b'});
      await notes.save(GNote(id: 3, name: 'unsent'));
      expect(await notes.clearLocally(FluentFilter.empty), 2);
      expect(await liveOf(notes), {3: 'unsent'}, reason: 'clearLocally keeps the unsent row');
      await notes.deleteById(3);
      await notes.save(GNote(id: 4, name: 'unsent too'));
      await notes.clearTable();
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.unsentChangesDiscarded));
      // clearTable resets since: the next pull brings everything back.
      await sn.sync(notes, strategy: FluentSyncStrategy.pull);
      expect(await liveOf(notes), sn.alive);
      await finish();
    });

    test('G10: replaceLocally keeps unsent rows and unsent deletions', () async {
      await seedNotes({1: 'a', 2: 'b', 3: 'c'});
      await notes.save(GNote(id: 1, name: 'local'));
      await notes.deleteById(2);
      await notes.replaceLocally(FluentFilter.empty, [GNote(id: 1, name: 'server'), GNote(id: 2, name: 'server'), GNote(id: 5, name: 'e')]);
      expect(await liveOf(notes), {1: 'local', 5: 'e'});
      final SyncState s = await SyncState.read(db, notes);
      expect(s.pending, {1});
      expect(s.tombstones, {2});
      await finish();
    });
  });

  group('G1 failures inside sync bookkeeping', () {
    late FaultyDatabaseFactory faults;
    late FluentTestDb fdb;

    setUp(() async {
      await db.close();
      faults = await FaultyDatabaseFactory.install();
      fdb = FluentTestDb(persistent: true);
      items = GItems();
      notes = GNotes();
      si = itemServer();
      sn = noteServer();
      await fdb.open([items, notes]);
    });

    tearDown(() async {
      faults.heal();
      await fdb.close();
      faults.uninstall();
    });

    test('G1: a failure while marking a push leaves every change pending (nothing half-marked); the next push repairs it', () async {
      await seedNotes({1: 'a', 2: 'b'});
      await notes.save(GNote(id: 3, name: 'c'));
      await notes.save(GNote(id: 1, name: 'a2'));
      await notes.deleteById(2);
      final SyncState before = await SyncState.read(fdb, notes);
      faults.failWhere((c) => c.method == 'batch' && c.matches('synced_version'), times: 1);
      final FluentSyncResult<GNote> r = await sn.sync(notes, strategy: FluentSyncStrategy.push);
      expect(r.isSuccess, isFalse);
      expectTypedError(r.error!);
      final SyncState after = await SyncState.read(fdb, notes);
      expect(after.pending, before.pending, reason: 'G1: nothing marked');
      expect(after.tombstones, before.tombstones, reason: 'G1: no tombstone dropped');
      expect(after.lastPull, before.lastPull);
      expect(await liveOf(notes), {1: 'a2', 3: 'c'});
      expect(await notes.pendingChanges(), 3);
      final FluentSyncResult<GNote> again = await sn.sync(notes);
      expect(again.isSuccess, isTrue);
      expect(await notes.pendingChanges(), 0);
      expect(await liveOf(notes), sn.alive, reason: 'G10: converged');
      await expectIntegrity(notes.db);
      expectIssuesHaveFixes(fdb.issues);
    });

    test('G1: a failure while storing a pull page stores nothing of that page and keeps since; earlier pages stay', () async {
      for (int i = 1; i <= 6; i++) {
        si.edit(i, 'v$i');
      }
      si.delete(6);
      si
        ..pageSize = 2
        ..duringPull = (request) async {
          if (request.page == 1) faults.failWhere((c) => c.isWrite && c.matches('g_items'), times: 1);
        };
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.pull);
      expect(r.isSuccess, isFalse);
      expectTypedError(r.error!);
      expect(await liveOf(items), {1: 'v1', 2: 'v2'}, reason: 'G1: page 1 is not half-stored');
      expect((await SyncState.read(fdb, items)).lastPull, isNull);
      si.duringPull = null;
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      expect(await liveOf(items), si.alive);
      await expectIntegrity(items.db);
      expectIssuesHaveFixes(fdb.issues);
    });

    test('G1: a failure while saving the since of the last page rolls back that page', () async {
      for (int i = 1; i <= 3; i++) {
        si.edit(i, 'v$i');
      }
      faults.failWhere((c) => c.isWrite && c.matches('__fluent_sync_state'), times: 1);
      final FluentSyncResult<GItem> r = await si.sync(items, strategy: FluentSyncStrategy.pull);
      expect(r.isSuccess, isFalse);
      expect(await liveOf(items), isEmpty, reason: 'G1: rows and since are written together');
      expect((await SyncState.read(fdb, items)).lastPull, isNull);
      expect((await si.sync(items, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
      expect(await liveOf(items), si.alive);
      await expectIntegrity(items.db);
    });

    test('G1: a failure while storing the server answer of a push keeps the rows pending and the server key unknown', () async {
      await notes.save(GNote(id: 1, name: 'a'));
      // The answer carries the server's version of the row; storing it fails.
      final FluentSyncResult<GNote> r = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          faults.failWhere((c) => c.isWrite && c.matches('g_notes') && !c.matches('synced_version" = ?'), times: 1);
          return FluentPushResult.accepted(updated: [GNote(id: 1, name: 'server form')]);
        },
      );
      // Either the whole answer is stored, or the sync fails and the row stays as it was (pending or marked, never a mix).
      final SyncState s = await SyncState.read(fdb, notes);
      final Map<int, String> live = await liveOf(notes);
      if (r.isSuccess) {
        expect(live, {1: 'server form'});
      } else {
        expectTypedError(r.error!);
        expect(live, {1: 'a'});
      }
      expect(await notes.pendingChanges(), s.pending.length + s.tombstones.length);
      await expectIntegrity(notes.db);
    });
  });

  // Sync bookkeeping reads while a transaction on the same database is open. Before the fix the transaction watchdog
  // let them into that transaction: a push batch carried its changes, which were rolled back afterwards (chaos seed
  // 81828 of the night run: the server kept a rolled-back value, the device's committed row counted as synced). Now
  // they wait for the commit, past the transaction watchdog; after `committedReadTimeout` they are refused with the
  // transient `databaseBusy` (with `retries` the sync runs later). They never read uncommitted data.
  group('G10 sync never sends or merges a rolled-back change', () {
    late FluentTestDb wdb;

    setUp(() async {
      await db.close();
      wdb = FluentTestDb(persistent: true);
      items = GItems();
      notes = GNotes();
      si = itemServer();
      sn = noteServer();
    });

    tearDown(() => wdb.close());

    /// Opens the database: the watchdog fires after 20 ms (long before the transactions end), sync reads wait at most
    /// 300 ms.
    Future<void> open() => wdb.open([items, notes], fluentConfig: const FluentConfig(transactionWatchdog: Duration(milliseconds: 20), committedReadTimeout: Duration(milliseconds: 300)));

    /// How long the transactions of a test run: shorter than the bound (the sync waits and succeeds), or longer
    /// ([refused]: the sync is refused).
    int holdMs(bool refused) => refused ? 600 : 100;

    /// Holds the running transaction open until [done] or for [ms].
    Future<void> hold(bool Function() done, int ms) async {
      final Stopwatch sw = Stopwatch()..start();
      while (!done() && sw.elapsedMilliseconds < ms) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    /// Runs [change] in a transaction of [ms] that rolls back while a push started outside it waits; [duringPush] runs
    /// inside the push call. Returns the push result: a success (it read the committed rows) or refused (`databaseBusy`).
    Future<FluentSyncResult<GNote>> pushDuringRolledBack(int ms, Future<void> Function() change, {Future<void> Function()? duringPush}) async {
      late Future<FluentSyncResult<GNote>> push;
      bool done = false;
      sn.duringPush = (call, batch) async => duringPush?.call();
      await FluentDb.transaction<Object?>(() async {
        await change();
        push = Zone.root.run(() => sn.sync(notes, strategy: FluentSyncStrategy.push));
        unawaited(push.whenComplete(() => done = true));
        await hold(() => done, ms);
        throw const _Rollback();
      }, dbKey: wdb.key).then<Object?>((v) => v, onError: (Object e) => e is _Rollback ? null : throw e).timeout(const Duration(seconds: 10));
      final FluentSyncResult<GNote> r = await push.timeout(const Duration(seconds: 10));
      sn.duringPush = null;
      if (!r.isSuccess) expect((r.error! as FluentException).code, FluentErrorCode.databaseBusy, reason: 'refused, typed');
      return r;
    }

    Future<void> converges() async {
      final FluentSyncResult<GNote> quiet = await sn.sync(notes).timeout(const Duration(seconds: 10));
      expect(quiet.isSuccess, isTrue);
      expect(await notes.pendingChanges(), 0);
      expect(sn.alive, await liveOf(notes), reason: 'G10: the server holds the committed rows after a quiet sync');
      await expectIntegrity(notes.db);
      expectIssuesHaveFixes(wdb.issues);
    }

    for (final bool refused in [false, true]) {
      final String mode = refused ? 'refused after committedReadTimeout' : 'waiting for the rollback';
      test('G10: an edit rolled back while its push waits is never sent ($mode)', () async {
        await open();
        await seedNotes({1: 'x'});
        final FluentSyncResult<GNote> r = await pushDuringRolledBack(holdMs(refused), () => notes.save(GNote(id: 1, name: '')));
        expect(r.isSuccess, !refused);
        expect(sn.received.where((b) => b.changed[1] == ''), isEmpty, reason: 'the rolled-back value never reached the server');
        expect(await liveOf(notes), {1: 'x'}, reason: 'the edit was rolled back');
        await converges();
      });

      test('G10: an edit rolled back while its push waits, then committed again with the same version, is sent ($mode)', () async {
        await open();
        await seedNotes({1: 'x'});
        await notes.save(GNote(id: 1, name: 'p')); // pending: the push has something to send
        await pushDuringRolledBack(holdMs(refused), () => notes.save(GNote(id: 1, name: '')), duringPush: () => notes.save(GNote(id: 1, name: 'y')));
        expect(sn.received.where((b) => b.changed[1] == ''), isEmpty);
        expect(await liveOf(notes), {1: refused ? 'p' : 'y'});
        await converges();
      });

      test('G10: a deletion rolled back while its push waits is never sent ($mode)', () async {
        await open();
        await seedNotes({1: 'x', 2: 'k'});
        await pushDuringRolledBack(holdMs(refused), () async => notes.deleteById(1));
        expect(sn.received.where((b) => b.deletedKeys.contains(1)), isEmpty);
        expect(await liveOf(notes), {1: 'x', 2: 'k'});
        await converges();
      });

      test('G10: a new row rolled back while its push waits is never sent ($mode)', () async {
        await open();
        await seedNotes({2: 'k'});
        await pushDuringRolledBack(holdMs(refused), () => notes.save(GNote(id: 1, name: 'never')));
        expect(sn.received.where((b) => b.changed.containsKey(1)), isEmpty);
        expect(await liveOf(notes), {2: 'k'});
        await converges();
      });

      test('G10: a merge never sees a local change that is rolled back afterwards ($mode)', () async {
        await open();
        await seedNotes({1: 'base'});
        await notes.save(GNote(id: 1, name: 'loc')); // pending
        sn.edit(1, 'srv');
        // The pull page arrives while a transaction (outside the sync) holds an uncommitted edit of row 1; the merge's
        // read of the local rows waits behind it. The merge callback commits an edit of its own, so a merge built from
        // the rolled-back row would find the version it read again (before the fix: 'dirty+srv' was written).
        final List<String> seen = [];
        Future<Object?>? txn;
        bool merged = false;
        sn.duringPull = (request) async {
          if (txn != null) return;
          final Completer<void> started = Completer<void>();
          txn = Zone.root.run(
            () => FluentDb.transaction<Object?>(() async {
              await notes.save(GNote(id: 1, name: 'dirty'));
              started.complete();
              await hold(() => merged, holdMs(refused));
              throw const _Rollback();
            }, dbKey: wdb.key).then<Object?>((v) => v, onError: (Object e) => e is _Rollback ? null : throw e),
          );
          await started.future;
        };
        final FluentSyncResult<GNote> r = await sn
            .sync(
              notes,
              strategy: FluentSyncStrategy.pull,
              conflicts: FluentConflictPolicy<GNote>.merge((l, r) async {
                seen.add(l.name);
                if (!merged) {
                  merged = true;
                  await notes.save(GNote(id: 1, name: 'loc2'));
                }
                return GNote(id: l.id, name: '${l.name}+${r.name}');
              }),
            )
            .timeout(const Duration(seconds: 10));
        await txn!.timeout(const Duration(seconds: 10));
        sn.duringPull = null;
        expect(r.isSuccess, !refused);
        if (!r.isSuccess) expect((r.error! as FluentException).code, FluentErrorCode.databaseBusy);
        expect(seen, isNot(contains('dirty')), reason: 'the merge never got the uncommitted row');
        expect((await liveOf(notes))[1], isNot(contains('dirty')));
        await converges();
      });
    }

    test('G12: a transaction that awaits a sync started outside it gets the sync refused (databaseBusy), never hangs', () async {
      await open();
      await seedNotes({1: 'x'});
      final FluentSyncResult<GNote> r = await FluentDb.transaction(() async {
        await notes.save(GNote(id: 1, name: 'in txn'));
        return Zone.root.run(() => sn.sync(notes, strategy: FluentSyncStrategy.push));
      }, dbKey: wdb.key).timeout(const Duration(seconds: 10));
      expect(r.isSuccess, isFalse);
      expect((r.error! as FluentException).code, FluentErrorCode.databaseBusy);
      expect(await liveOf(notes), {1: 'in txn'}, reason: 'the transaction committed');
      await converges();
    });

    test('G10: a sync refused while a long transaction runs succeeds with retries once the transaction ends', () async {
      await open();
      await seedNotes({1: 'x'});
      await notes.save(GNote(id: 1, name: 'p'));
      late Future<FluentSyncResult<GNote>> sync;
      await FluentDb.transaction(() async {
        await notes.save(GNote(id: 2, name: 'import'));
        sync = Zone.root.run(
          () => notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: sn.onPush, onPull: sn.onPull, retries: 5, retryDelay: const Duration(milliseconds: 50)),
        );
        await hold(() => false, 600); // longer than committedReadTimeout: the first attempt is refused
      }, dbKey: wdb.key).timeout(const Duration(seconds: 10));
      final FluentSyncResult<GNote> r = await sync.timeout(const Duration(seconds: 10));
      expect(r.isSuccess, isTrue, reason: 'the retry ran after the transaction: ${r.errorMessage}');
      expect(sn.alive, {1: 'p', 2: 'import'});
      await converges();
    });
  });
}

class _Rollback implements Exception {
  const _Rollback();
}

/// The G24 cases the code does not keep yet (BUG skips; see the report).
String? _knownBug(bool soft, LocalState state, bool serverDeletes, Policy policy) => null;

/// One G24 case: row 1 in local [state], the server edits or deletes it, a pull with [policy]; checks the documented
/// effect on row 1 (and that row 2 is untouched).
Future<void> _g24Case<T extends FluentStorable>(
  FluentTestDb db,
  FluentSyncable<T> p,
  FakeServer<T> server,
  T Function(String name) make,
  String Function(T model) nameOf,
  LocalState state,
  bool serverDeletes,
  Policy policy,
  Future<Set<int>> Function()? trashOf,
) async {
  final bool soft = trashOf != null;
  if (state != LocalState.absent) {
    server
      ..edit(1, 'base')
      ..edit(2, 'other');
    expect((await server.sync(p, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
  } else {
    server.edit(2, 'other');
  }
  switch (state) {
    case LocalState.pendingEdit:
      await p.save(make('local'));
    case LocalState.pendingTrash:
    case LocalState.tombstone:
      await p.deleteById(1);
    case LocalState.trashSynced:
      await p.deleteById(1);
      expect((await server.sync(p, strategy: FluentSyncStrategy.push)).isSuccess, isTrue);
    case LocalState.absent:
    case LocalState.clean:
      break;
  }
  if (serverDeletes) {
    if (state == LocalState.absent) server.edit(1, 'base');
    server.delete(1);
  } else {
    server.edit(1, 'server');
  }
  final FluentConflictPolicy<T> conflicts = switch (policy) {
    Policy.keepLocal => FluentConflictPolicy<T>.keepLocal(),
    Policy.keepServer => FluentConflictPolicy<T>.keepServer(),
    Policy.merge => FluentConflictPolicy<T>.merge((l, r) async => make('${nameOf(l)}+${nameOf(r)}')),
  };
  final FluentSyncResult<T> r = await server.sync(p, strategy: FluentSyncStrategy.pull, conflicts: conflicts);
  expect(r.isSuccess, isTrue, reason: r.errorMessage);

  // The expected row 1 after the pull.
  final bool localChange = state == LocalState.pendingEdit || state == LocalState.pendingTrash || state == LocalState.tombstone;
  final bool serverWins = !localChange || policy == Policy.keepServer;
  String? live;
  bool inTrash = false;
  bool pending = false;
  bool tombstone = false;
  if (serverWins) {
    if (serverDeletes) {
      inTrash = soft && state != LocalState.absent; // a server row newer than the local trash brings it back
    } else {
      live = 'server';
    }
  } else if (state == LocalState.pendingEdit) {
    live = policy == Policy.merge && !serverDeletes ? 'local+server' : 'local';
    pending = true;
  } else if (state == LocalState.pendingTrash) {
    inTrash = true;
    pending = true;
  } else {
    tombstone = true;
  }
  final SyncState s = await SyncState.read(db, p);
  final Map<int, String> liveRows = {for (final Map<String, dynamic> row in await p.findMaps()) row['id'] as int: row['name'] as String};
  expect(liveRows[2], 'other', reason: 'the other row is untouched');
  expect(liveRows[1], live, reason: 'live value of row 1');
  if (trashOf != null) expect((await trashOf()).contains(1), inTrash, reason: 'row 1 in the trash');
  expect(s.pending.contains(1), pending, reason: 'row 1 has a change to push');
  if (!(serverDeletes && state == LocalState.tombstone)) expect(s.tombstones.contains(1), tombstone, reason: 'row 1 has a pending deletion');
  expect(await p.pendingChanges(), s.pending.length + s.tombstones.length, reason: 'G23: pendingChanges agrees');
  expect(s.lastPull, server.clock, reason: 'the complete pull moved since to the server time');
  await expectIntegrity(p.db);
}
