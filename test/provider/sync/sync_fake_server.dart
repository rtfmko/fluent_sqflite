// A fake sync server with its own state for the sync guarantee tests (TEST_PLAN.md, T2): rows with versions,
// deletions, pages, rejects, failures, late answers and its own edits between (or during) rounds.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A row as the server keeps it.
class ServerRow {
  ServerRow(this.name, {required this.deleted, required this.version});

  /// The value.
  final String name;

  /// Whether the server deleted it.
  final bool deleted;

  /// The server version of the last change (the `since` clock).
  final int version;

  @override
  String toString() => deleted ? '<deleted v$version>' : '$name v$version';
}

/// One batch the server received.
class ReceivedBatch {
  ReceivedBatch(this.call, this.changed, this.deleted, this.deletedKeys, {required this.accepted, required this.rejected});

  /// The push call number (0-based, over the whole test).
  final int call;

  /// Changed rows: id → name.
  final Map<int, String> changed;

  /// Trashed rows: id → name.
  final Map<int, String> deleted;

  /// Deleted keys (tombstones).
  final List<int> deletedKeys;

  /// Whether the server accepted the batch.
  final bool accepted;

  /// The keys it refused (not applied).
  final Set<int> rejected;

  /// Every row key the batch carried (changed + trashed), in order.
  Iterable<int> get rowKeys => [...changed.keys, ...deleted.keys];

  @override
  String toString() => '#$call ${accepted ? 'ok' : 'FAILED'} changed=$changed deleted=$deleted keys=$deletedKeys rejected=$rejected';
}

/// How the server answers a push call.
enum PushAnswer {
  /// Applies the batch (minus [FakeServer.rejectKeys]).
  accept,

  /// `FluentPushResult.failed` (nothing applied).
  fail,

  /// Throws (nothing applied).
  throwError,
}

/// A server of int-keyed rows with one text value.
class FakeServer<T extends FluentStorable> {
  FakeServer({required this.idOf, required this.nameOf, required this.make});

  /// The key of a model.
  final int Function(T model) idOf;

  /// The value of a model.
  final String Function(T model) nameOf;

  /// A model of the server's row.
  final T Function(int id, String name) make;

  /// The server's rows (also the deleted ones, to report deletions).
  final Map<int, ServerRow> rows = {};

  /// The version clock (also the `serverTime` of a pull, in epoch milliseconds).
  int clock = 1000;

  // ---- push behaviour ----

  /// The answer of the next push calls, one per call (then [PushAnswer.accept]).
  final List<PushAnswer> pushAnswers = [];

  /// Keys the server refuses while set (only keys of the batch are reported).
  Set<int> rejectKeys = {};

  /// Also report these keys as rejected (not in the batch: the library must ignore them).
  Set<int> rejectForeign = {};

  /// Runs inside each push call before the answer (local edits while the push is in flight, a late answer).
  Future<void> Function(int call, FluentSyncBatch<T> batch)? duringPush;

  /// Every push call, in order.
  final List<ReceivedBatch> received = [];

  int _pushCalls = 0;

  // ---- pull behaviour ----

  /// Rows (and deletions) per pull page.
  int pageSize = 1000;

  /// Fail the pull page with this number (0-based) of the next pull, by a throw.
  int? failPullPage;

  /// Return no `serverTime` (the library then uses the device clock).
  bool omitServerTime = false;

  /// Runs inside each pull call before the answer (server edits or local edits between pages).
  Future<void> Function(FluentPullRequest request)? duringPull;

  /// Every pull request, in order.
  final List<FluentPullRequest> pullRequests = [];

  List<(int, ServerRow)>? _snapshot;
  int _snapshotClock = 0;

  /// The server's live rows: id → name.
  Map<int, String> get alive => {for (final MapEntry<int, ServerRow> e in rows.entries) if (!e.value.deleted) e.key: e.value.name};

  /// The server changes a row on its side.
  void edit(int id, String name) => rows[id] = ServerRow(name, deleted: false, version: ++clock);

  /// The server deletes a row on its side.
  void delete(int id) {
    if (rows[id] case final ServerRow r when !r.deleted) rows[id] = ServerRow(r.name, deleted: true, version: ++clock);
  }

  /// Removes every rule (a quiet server).
  void quiet() {
    pushAnswers.clear();
    rejectKeys = {};
    rejectForeign = {};
    duringPush = null;
    duringPull = null;
    failPullPage = null;
    omitServerTime = false;
  }

  /// The `onPush` callback.
  Future<FluentPushResult<T>> onPush(FluentSyncBatch<T> batch) async {
    final int call = _pushCalls++;
    final PushAnswer answer = pushAnswers.isEmpty ? PushAnswer.accept : pushAnswers.removeAt(0);
    final Map<int, String> changed = {for (final T m in batch.changed) idOf(m): nameOf(m)};
    final Map<int, String> deleted = {for (final T m in batch.deleted) idOf(m): nameOf(m)};
    final List<int> keys = [for (final Object k in batch.deletedKeys) k as int];
    await duringPush?.call(call, batch);
    if (answer != PushAnswer.accept) {
      received.add(ReceivedBatch(call, changed, deleted, keys, accepted: false, rejected: const {}));
      if (answer == PushAnswer.throwError) throw FluentSyncException('the fake server is down', hint: 'test');
      return const FluentPushResult.failed('refused by the fake server');
    }
    final Set<int> refused = {for (final int id in [...changed.keys, ...deleted.keys]) if (rejectKeys.contains(id)) id};
    received.add(ReceivedBatch(call, changed, deleted, keys, accepted: true, rejected: refused));
    for (final MapEntry<int, String> e in changed.entries) {
      if (!refused.contains(e.key)) edit(e.key, e.value);
    }
    for (final MapEntry<int, String> e in deleted.entries) {
      if (!refused.contains(e.key)) rows[e.key] = ServerRow(e.value, deleted: true, version: ++clock);
    }
    keys.forEach(delete);
    return FluentPushResult.accepted(rejected: [...refused, ...rejectForeign]);
  }

  /// The `onPull` callback: changes after `since` in key order, in pages of [pageSize] over a snapshot taken at page 0.
  Future<FluentPullResult<T>> onPull(FluentPullRequest request) async {
    pullRequests.add(request);
    await duringPull?.call(request);
    if (request.page == 0) {
      final int since = request.since?.millisecondsSinceEpoch ?? 0;
      _snapshotClock = clock;
      _snapshot = [for (final int id in rows.keys.toList()..sort()) if (rows[id]!.version > since) (id, rows[id]!)];
    }
    if (failPullPage == request.page) {
      failPullPage = null;
      throw FluentSyncException('pull page ${request.page} failed', hint: 'test');
    }
    final List<(int, ServerRow)> all = _snapshot!;
    final int from = (request.cursor as int?) ?? 0;
    final List<(int, ServerRow)> page = all.sublist(from, (from + pageSize).clamp(0, all.length));
    final bool more = from + pageSize < all.length;
    return FluentPullResult<T>(
      items: [for (final (int id, ServerRow r) in page) if (!r.deleted) make(id, r.name)],
      deletedKeys: [for (final (int id, ServerRow r) in page) if (r.deleted) id],
      hasMore: more,
      cursor: more ? from + pageSize : null,
      serverTime: omitServerTime ? null : DateTime.fromMillisecondsSinceEpoch(_snapshotClock),
    );
  }

  /// A sync with this server's callbacks.
  Future<FluentSyncResult<T>> sync(
    FluentSyncable<T> provider, {
    FluentSyncStrategy strategy = FluentSyncStrategy.full,
    FluentConflictPolicy<T> conflicts = const FluentConflictPolicy.keepLocal(),
    FluentRemoteDeleteBehavior remoteDeletes = FluentRemoteDeleteBehavior.auto,
    int? batchSize = 500,
    FluentFilter? where,
    FluentCancelToken? cancel,
  }) => provider
      .syncWithServer(strategy: strategy, onPush: onPush, onPull: onPull, conflicts: conflicts, remoteDeletes: remoteDeletes, batchSize: batchSize, where: where, cancel: cancel)
      .timeout(const Duration(seconds: 15));
}

/// The sync bookkeeping of a table as stored: row versions and tombstones.
class SyncState {
  SyncState(this.rows, this.pending, this.tombstones, this.lastPull);

  /// Every row (trash included): id → full stored row.
  final Map<int, Map<String, Object?>> rows;

  /// Keys of rows with `sync_version > synced_version`.
  final Set<int> pending;

  /// Keys of the tombstones.
  final Set<int> tombstones;

  /// The stored `since` (epoch ms) or null.
  final int? lastPull;

  /// Reads it from [db] for [table].
  static Future<SyncState> read(FluentTestDb db, FluentProvider provider) async {
    final Database raw = provider.db;
    final String table = provider.tableName;
    final List<Map<String, Object?>> rows = await raw.rawQuery('SELECT * FROM "$table"');
    final bool hasTomb = (await raw.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_tombstones'")).isNotEmpty;
    final bool hasState = (await raw.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_sync_state'")).isNotEmpty;
    final List<Map<String, Object?>> tombs = hasTomb ? await raw.rawQuery('SELECT key FROM __fluent_tombstones WHERE tbl = ?', [table]) : const [];
    final List<Map<String, Object?>> state = hasState ? await raw.rawQuery('SELECT last_pull FROM __fluent_sync_state WHERE tbl = ?', [table]) : const [];
    return SyncState(
      {for (final Map<String, Object?> r in rows) r['id']! as int: r},
      {for (final Map<String, Object?> r in rows) if ((r['sync_version']! as int) > (r['synced_version']! as int)) r['id']! as int},
      {for (final Map<String, Object?> t in tombs) int.parse(t['key']! as String)},
      state.isEmpty ? null : state.first['last_pull'] as int?,
    );
  }

  /// Rows as text for an exact before / after comparison (G31).
  String get dump => [for (final int id in rows.keys.toList()..sort()) '${rows[id]}', 'tombstones: ${tombstones.toList()..sort()}', 'since: $lastPull'].join('\n');
}
