// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:async';

import '../core/core.dart';
import '../core/fluent_sqlite_internal.dart';
import '../exceptions/exceptions.dart';
import '../interfaces/interfaces.dart';
import '../models/models.dart';
import '../utils/utils.dart';

/// The sync state of one provider, shared by its status watchers.
class _SyncHub {
  FluentSyncState state = FluentSyncState.idle;
  DateTime? lastSyncedAt;
  Object? lastError;
  final StreamController<void> changes = StreamController<void>.broadcast(sync: true);

  void set(FluentSyncState next, {Object? error, bool synced = false}) {
    state = next;
    lastError = error;
    if (synced) lastSyncedAt = FluentClock.now();
    changes.add(null);
  }
}

/// Two-way synchronization of a provider's table with a server.
///
/// Change tracking is automatic: every local write (save, update, delete, restore) marks the row as changed, so
/// [syncWithServer] always knows what to send — including edits made while a previous push was in flight. Rows
/// received from the server are stored as synced (they are not sent back), and never overwrite a local change that
/// was not sent yet (unless the conflict policy says so). Permanent deletes of rows the server knows are remembered
/// (tombstones) and sent too. Rows are matched with the server by `FluentTableConfig.serverKey` (else the key).
///
/// ```dart
/// class TodoProvider extends FluentProvider<Todo> with FluentSyncable<Todo> { ... }
///
/// final FluentSyncResult<Todo> result = await todos.syncWithServer(
///   onPush: (batch) async {
///     await api.send(changed: batch.changed, trashed: batch.deleted, deleted: batch.deletedKeys);
///     return const FluentPushResult.accepted();
///   },
///   onPull: (request) async {
///     final page = await api.changesSince(request.since, cursor: request.cursor);
///     return FluentPullResult(items: page.items, deletedKeys: page.deletedIds, hasMore: page.hasMore, cursor: page.next);
///   },
/// );
/// ```
mixin FluentSyncable<T extends FluentStorable> on FluentProvider<T> {
  /// Column counting local changes of a row (kept by the library).
  String get syncVersionColumn => 'sync_version';

  /// Column holding the last version sent to the server (kept by the library).
  String get syncedVersionColumn => 'synced_version';

  /// Syncs running per provider: a second call while one runs waits for it (and shares it when it does the same).
  static final Map<Object, (String, Future<Object?>)> _running = {};

  /// The fetch and stream state of each provider instance; weak, so providers of closed groups are released.
  static final Expando<_SyncHub> _hubs = Expando('fluentSyncHub');

  _SyncHub get _hub => _hubs[this] ??= _SyncHub();

  /// Zone value: the providers whose sync callbacks (`onPush`, `onPull`, the merge) are running in this zone.
  static final Object _callbackKey = Object();

  /// Runs a sync callback of this provider in a zone that marks it, so a `syncWithServer` call from inside it is
  /// refused instead of waiting for the sync that waits for the callback.
  Future<R> _inCallback<R>(Future<R> Function() callback) {
    final Set<Object> inside = {...?(Zone.current[_callbackKey] as Set<Object>?), this};
    return runZoned(callback, zoneValues: {_callbackKey: inside});
  }

  /// Synchronizes with the server.
  ///
  /// * [strategy]: [FluentSyncStrategy.push], [FluentSyncStrategy.pull], or [FluentSyncStrategy.full] (default:
  ///   push, then pull). `onPush` is required for push / full, `onPull` for pull / full; a missing one fails the sync.
  /// * [onPush]: sends a [FluentSyncBatch] (changed rows, trashed rows, server keys of deleted rows) and answers with
  ///   a [FluentPushResult]: `accepted` (optionally with the server's version of the rows and the refused primary
  ///   keys) or `failed`. Changes go in calls of at most [batchSize] items, in key order (`null`: all at once). The
  ///   server's version of a row is never inserted (a row deleted during the push stays deleted); a row edited
  ///   during the push takes only its server key columns and stays pending.
  /// * [onPull]: returns what changed on the server since `request.since` (`null` the first time) as a
  ///   [FluentPullResult]; with `hasMore` it is called again with `request.cursor` for the next page. Only a pull
  ///   that reached its last page moves the `since` of the next one.
  /// * [where]: limits the rows that are pushed (deletions are always sent).
  /// * [conflicts]: a server row (or deletion) whose local row has a change not sent yet —
  ///   [FluentConflictPolicy.keepLocal] (default), [FluentConflictPolicy.keepServer], or [FluentConflictPolicy.merge]
  ///   (the merged model is saved and sent with the next push, unless the row was edited again while the callback
  ///   ran: then that edit wins).
  /// * [remoteDeletes]: what to do with rows the server deleted: [FluentRemoteDeleteBehavior.auto] (default: soft
  ///   delete when the model has it, else delete), `soft`, `hard`, or `keep`.
  /// * [relationSync]: how relation lists of server rows replace local ones ([FluentRelationSyncMode]).
  /// * [retries]: how often a failed sync (an error or `FluentPushResult.failed`) is tried again, after [retryDelay]
  ///   doubled each time with ±50 % random jitter; HTTP 4xx errors (`FluentSyncException.statusCode`) other than
  ///   408 / 429 are not retried.
  /// * [cancel]: stops the sync when [FluentCancelToken.cancel] is called — also while it waits for a running sync,
  ///   for an answer of [onPush] / [onPull] (which is then ignored) or for a retry. Batches pushed and pages pulled
  ///   before stay stored; an unfinished pull does not move its `since`. The result has `isCancelled: true`.
  ///
  /// Calls on one provider never overlap: a call made while a sync runs waits for it; when that sync has the same
  /// [strategy] and [where], the call returns its result instead of syncing again. A call from inside this provider's
  /// own [onPush] / [onPull] / merge callback would wait for itself: it returns a failed result at once
  /// (`FluentSyncException`, code `syncFailed`); start the next sync after the running one returned.
  ///
  /// A row deleted locally whose deletion was not pushed yet is never brought back by a pull: it counts as a conflict
  /// (`keepLocal` / `merge` skip the server row, `keepServer` stores it and drops the pending deletion).
  ///
  /// Never throws: failures are reported in the result (`isSuccess`, `errorMessage`, `error`), in [watchSyncStatus],
  /// and logged once per sync (`FluentIssueKind.syncFailed`). Nothing local is lost; what was not sent waits for the
  /// next sync. To sync when the device is back online, call it from your connectivity listener.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentSyncResult<Todo> result = await todos.syncWithServer(
  ///   strategy: FluentSyncStrategy.push,
  ///   where: FluentFilter.eq('list_id', 7),
  ///   onPush: (batch) async {
  ///     final saved = await api.send(batch.changed);
  ///     return FluentPushResult.accepted(updated: saved); // the server's ids / times, stored as synced
  ///   },
  ///   retries: 3,
  /// );
  /// if (!result.isSuccess) showError(result.errorMessage);
  /// ```
  Future<FluentSyncResult<T>> syncWithServer({
    FluentSyncStrategy strategy = FluentSyncStrategy.full,
    Future<FluentPushResult<T>> Function(FluentSyncBatch<T> batch)? onPush,
    Future<FluentPullResult<T>> Function(FluentPullRequest request)? onPull,
    FluentFilter? where,
    int? batchSize = 500,
    FluentConflictPolicy<T> conflicts = const FluentConflictPolicy.keepLocal(),
    FluentRemoteDeleteBehavior remoteDeletes = FluentRemoteDeleteBehavior.auto,
    FluentRelationSyncMode? relationSync,
    int retries = 0,
    Duration retryDelay = const Duration(seconds: 1),
    FluentCancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) return _cancelledResult(strategy);
    if ((Zone.current[_callbackKey] as Set<Object>?)?.contains(this) ?? false) {
      // Waiting would never end: this sync is waiting for the callback that is calling.
      final FluentSyncException error = FluentSyncException(
        'syncWithServer of "$tableName" was called from inside its own onPush / onPull / merge callback',
        hint: 'Call syncWithServer after the running sync has finished (e.g. after its Future completes), not from its callbacks.',
      );
      FluentLog.issue(FluentIssueKind.syncFailed, error.message, table: tableName, tag: 'sync:$tableName', hint: error.hint!, error: error);
      return FluentSyncResult(strategy: strategy, isSuccess: false, errorMessage: error.message, error: error);
    }
    // One sync per provider at a time: a call waits for the running one (and again for any that started meanwhile);
    // a run of the same strategy and rows answers it too.
    final String what = '${strategy.name}|${fluentFilterKey(where)}';
    for (;;) {
      final (String, Future<Object?>)? running = _running[this];
      if (running == null) break;
      final Object? result;
      try {
        result = await _unlessCancelled(running.$2, cancel);
      } on _SyncCancelled {
        return _cancelledResult(strategy);
      } catch (_) {
        continue; // the run reported its own failure; check again
      }
      // A run cancelled by another caller's token does not answer this call.
      if (running.$1 == what && !(result is FluentSyncResult && result.isCancelled)) return result! as FluentSyncResult<T>;
    }
    Future<FluentSyncResult<T>> attempts() async {
      final bool configured = (strategy == FluentSyncStrategy.pull || onPush != null) && (strategy == FluentSyncStrategy.push || onPull != null);
      for (int attempt = 0;; attempt++) {
        final FluentSyncResult<T> result = await _sync(strategy, onPush, onPull, where, batchSize, conflicts, remoteDeletes, relationSync, cancel);
        if (result.isSuccess || result.isCancelled) return result;
        if (!configured || attempt >= retries || !fluentRetryCanHelp(result.error)) {
          // One log per failed sync (not per attempt).
          FluentLog.issue(
            FluentIssueKind.syncFailed,
            'Sync of "$tableName" failed: ${result.errorMessage}',
            table: tableName,
            tag: 'sync:$tableName',
            hint: configured ? 'Nothing local was lost; the remaining changes are sent with the next sync.' : 'Pass the callback the strategy needs.',
            error: result.error,
          );
          return result;
        }
        final Duration wait = fluentRetryDelay(retryDelay, attempt);
        FluentLog.debug('Sync of "$tableName" failed (${result.errorMessage}), retry in ${wait.inMilliseconds} ms (${attempt + 1} of $retries)', tag: 'sync:$tableName');
        try {
          await _unlessCancelled(Future<void>.delayed(wait), cancel);
        } on _SyncCancelled {
          return _cancelledResult(strategy);
        }
      }
    }

    _hub.set(FluentSyncState.syncing);
    // Registered before its first await (no other call can start in between); waiters resume after the clean-up.
    late final Future<FluentSyncResult<T>> run;
    run = () async {
      try {
        final FluentSyncResult<T> result = await attempts();
        final bool calm = result.isSuccess || result.isCancelled;
        _hub.set(calm ? FluentSyncState.idle : FluentSyncState.failed, error: calm ? null : (result.error ?? result.errorMessage), synced: result.isSuccess);
        return result;
      } finally {
        if (identical(_running[this]?.$2, run)) _running.remove(this);
      }
    }();
    _running[this] = (what, run);
    return run;
  }

  /// The sync state of this table now, and again whenever it changes: a sync starts, ends or fails, or a local write
  /// changes the number of changes waiting to be sent. Equal states are not repeated; changes within [coalesce] are
  /// read once. A failed read of the count is delivered as a stream error.
  ///
  /// ```dart
  /// StreamBuilder<FluentSyncStatus>(
  ///   stream: todos.watchSyncStatus(),
  ///   builder: (context, s) => s.data?.hasPending ?? false ? Text('${s.data!.pending} changes not sent') : const Text('Synced'),
  /// );
  /// ```
  Stream<FluentSyncStatus> watchSyncStatus({Duration coalesce = const Duration(milliseconds: 16)}) {
    late final StreamController<FluentSyncStatus> controller;
    final List<StreamSubscription<Object?>> subscriptions = [];
    FluentSyncStatus? last;
    DateTime? lastPulled;
    Timer? frame;
    bool running = false;
    bool dirty = false;

    Future<void> refresh() async {
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          final int pending = await pendingChanges();
          if (controller.isClosed) return;
          final _SyncHub hub = _hub;
          final FluentSyncStatus status = FluentSyncStatus(state: hub.state, pending: pending, lastSyncedAt: hub.lastSyncedAt ?? lastPulled, lastError: hub.lastError);
          if (status != last) {
            last = status;
            controller.add(status);
          }
        } while (dirty);
      } catch (e, s) {
        if (!controller.isClosed) controller.addError(e, s);
      } finally {
        running = false;
      }
    }

    void schedule() => frame ??= Timer(coalesce, () {
      frame = null;
      refresh();
    });

    controller = StreamController<FluentSyncStatus>(
      onListen: () async {
        subscriptions
          ..add(_hub.changes.stream.listen((_) => schedule()))
          ..add(FluentEngine().changeStream.where((e) => e.dbName == dbName && e.table == tableName).listen((_) => schedule()));
        try {
          lastPulled = await lastPull();
        } catch (_) {
          // Shown without a time; the sync itself reports database problems.
        }
        await refresh();
      },
      onCancel: () async {
        frame?.cancel();
        for (final StreamSubscription<Object?> s in subscriptions) {
          await s.cancel();
        }
      },
    );
    return controller.stream;
  }

  /// Number of local changes waiting to be sent (changed and trashed rows, deletions), within [where] (which limits
  /// the rows; deletions are always counted), e.g. `await todos.pendingChanges()`.
  Future<int> pendingChanges({FluentFilter? where}) => pendingSyncCount(where: where);

  Future<FluentSyncResult<T>> _sync(
    FluentSyncStrategy strategy,
    Future<FluentPushResult<T>> Function(FluentSyncBatch<T> batch)? onPush,
    Future<FluentPullResult<T>> Function(FluentPullRequest request)? onPull,
    FluentFilter? where,
    int? batchSize,
    FluentConflictPolicy<T> conflicts,
    FluentRemoteDeleteBehavior remoteDeletes,
    FluentRelationSyncMode? relationSync,
    FluentCancelToken? cancel,
  ) async {
    void stopIfCancelled() {
      if (cancel?.isCancelled ?? false) throw const _SyncCancelled();
    }

    final bool push = strategy != FluentSyncStrategy.pull;
    final bool pull = strategy != FluentSyncStrategy.push;
    int pushed = 0;
    final List<Object> rejected = [];
    // The error reaches the app typed: an error of the callbacks (or none) is wrapped, kept as the cause.
    FluentSyncResult<T> failed(String message, {Object? error, bool misconfigured = false}) => FluentSyncResult(
      strategy: strategy,
      isSuccess: false,
      pushed: pushed,
      rejected: rejected.length,
      errorMessage: message,
      error: error is FluentException
          ? error
          : FluentSyncException(
              'Sync of "$tableName" failed: ${FluentLog.redact(message)}',
              hint: misconfigured
                  ? 'Pass the callbacks the strategy needs: onPush for push / full, onPull for pull / full.'
                  : 'Nothing local was lost; what was not sent or fetched is synced by the next syncWithServer call. The cause is the error of onPush / onPull.',
              cause: error,
            ),
    );

    if (push && onPush == null) return failed('onPush is missing (needed by ${strategy.name})', misconfigured: true);
    if (pull && onPull == null) return failed('onPull is missing (needed by ${strategy.name})', misconfigured: true);

    FluentPullStats stats = (pulled: 0, conflicts: 0, remoteDeleted: 0);
    try {
      if (push) {
        // Rows sent in this sync and edited again meanwhile wait for the next sync (no endless round trips).
        final Set<String> sent = {};
        for (int round = 0; round < 10000; round++) {
          stopIfCancelled();
          final FluentSyncBatch<T> batch = await pendingSyncBatch(where: where, limit: batchSize, skip: rejected);
          if (batch.isEmpty) break;
          final List<String> keys = [for (final (Object id, int _) in batch.versions) _syncKeyText(id)];
          if (keys.isNotEmpty && batch.deletedKeys.isEmpty && keys.every(sent.contains)) break;
          sent.addAll(keys);
          // From now on the server may have these rows (also when the answer fails, is cancelled or the row is edited
          // meanwhile): deleting one later must tell the server.
          await markSent(batch);
          // A cancel stops waiting: the batch stays pending (the server may have it already; it is sent again).
          final FluentPushResult<T> answer = await _unlessCancelled(_inCallback(() => onPush!(batch)), cancel);
          stopIfCancelled(); // cancelled while the answer was on its way: it is ignored (the batch is sent again)
          if (!answer.isAccepted) {
            return failed('the server did not accept the changes (FluentPushResult.failed${answer.error == null ? '' : ': ${FluentLog.redact('${answer.error}')}'})', error: answer.error);
          }
          // Only keys of this batch count: an unknown key refuses nothing that was sent.
          final Set<String> inBatch = {for (final (Object id, int _) in batch.versions) _syncKeyText(id)};
          final Set<String> seen = {};
          final List<Object> refused = [for (final Object id in answer.rejected) if (inBatch.contains(_syncKeyText(id)) && seen.add(_syncKeyText(id))) id];
          if (refused.length < answer.rejected.length) {
            FluentLog.debug('${answer.rejected.length - refused.length} rejected key(s) of "$tableName" were not in the pushed batch; ignored', tag: 'sync:$tableName');
          }
          rejected.addAll(refused);
          final int marked = await markPushed(batch, rejected: refused, updated: answer.updated);
          // The server's version of the rows (its ids, times): stored as synced unless edited meanwhile (then only
          // its server key is kept); rows deleted meanwhile are not brought back.
          if (answer.updated.isNotEmpty) await applyPull(FluentPullResult<T>(), remote: answer.updated, byKey: true, relationSync: relationSync);
          pushed += batch.length - refused.length;
          // Without a batch size everything was sent at once; when nothing was marked (every row edited meanwhile),
          // nothing refused and no deletion sent, another round would send the same rows: they go with the next sync.
          if (batchSize == null || (marked == 0 && refused.isEmpty && batch.tombstones.isEmpty)) break;
        }
        if (rejected.isNotEmpty) FluentLog.debug('${rejected.length} row(s) of "$tableName" were refused by the server; they stay waiting', tag: 'sync:$tableName');
      }
      if (pull) {
        // Taken before asking: rows changed on the server while the pull runs come again next time.
        final DateTime started = FluentClock.now();
        final DateTime? since = await lastPull();
        DateTime? serverTime;
        Object? cursor;
        for (int page = 0; page < 10000; page++) {
          stopIfCancelled();
          final FluentPullResult<T> answer = await _unlessCancelled(_inCallback(() => onPull!(FluentPullRequest(since: since, cursor: cursor, page: page))), cancel);
          stopIfCancelled(); // cancelled while the answer was on its way: it is ignored
          if (page == 0) serverTime = answer.serverTime;
          if (page == 0 && serverTime == null) _hintServerTime();
          final FluentPullStats applied = await _applyPage(answer, conflicts, remoteDeletes, relationSync, rememberAs: answer.hasMore ? null : serverTime ?? started);
          stats = (pulled: stats.pulled + applied.pulled, conflicts: stats.conflicts + applied.conflicts, remoteDeleted: stats.remoteDeleted + applied.remoteDeleted);
          if (!answer.hasMore) break;
          cursor = answer.cursor;
        }
      }
    } on _SyncCancelled {
      FluentLog.debug('Sync of "$tableName" cancelled (pushed: $pushed, pulled: ${stats.pulled})', tag: 'sync:$tableName');
      return _cancelledResult(strategy, pushed: pushed, pulled: stats.pulled, conflicts: stats.conflicts, remoteDeleted: stats.remoteDeleted, rejected: rejected.length);
    } catch (e) {
      return failed(FluentLog.redact('$e'), error: e);
    }
    return FluentSyncResult(
      strategy: strategy,
      isSuccess: true,
      pushed: pushed,
      pulled: stats.pulled,
      conflicts: stats.conflicts,
      remoteDeleted: stats.remoteDeleted,
      rejected: rejected.length,
    );
  }

  /// The result of a sync stopped by its [FluentCancelToken], with what it did before.
  FluentSyncResult<T> _cancelledResult(FluentSyncStrategy strategy, {int pushed = 0, int pulled = 0, int conflicts = 0, int remoteDeleted = 0, int rejected = 0}) {
    final FluentCancelledException error = FluentCancelledException(
      'syncWithServer of "$tableName" was cancelled',
      code: FluentErrorCode.syncCancelled,
      hint: 'Nothing stored was lost; the rest is sent and fetched with the next sync.',
    );
    return FluentSyncResult(
      strategy: strategy,
      isSuccess: false,
      isCancelled: true,
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      remoteDeleted: remoteDeleted,
      rejected: rejected,
      errorMessage: error.message,
      error: error,
    );
  }

  /// [future], or a [_SyncCancelled] as soon as [cancel] is cancelled (the late result of [future] is ignored).
  static Future<R> _unlessCancelled<R>(Future<R> future, FluentCancelToken? cancel) {
    if (cancel == null) return future;
    if (cancel.isCancelled) {
      future.ignore();
      return Future<R>.error(const _SyncCancelled());
    }
    final Completer<R> done = Completer<R>();
    future.then((R v) {
      if (!done.isCompleted) done.complete(v);
    }, onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
    });
    cancel.whenCancelled.then((_) {
      if (!done.isCompleted) done.completeError(const _SyncCancelled());
    });
    return done.future;
  }

  /// Text form of a row key for comparing batches.
  static String _syncKeyText(Object id) => id is FluentKey ? '${id.values}' : '$id';

  /// A pull answered without `serverTime`: the next `since` comes from the device clock, which may run ahead of the
  /// server and skip changes.
  void _hintServerTime() {
    FluentLog.issue(
      FluentIssueKind.pullClock,
      'Pulls of "$tableName" return no serverTime, so the next "since" is the time of this device.',
      details: 'A device clock ahead of the server makes the next pull skip the changes made in between.',
      table: tableName,
      database: dbName,
      tag: 'sync:$tableName',
      hint: "Return the server's time with the answer.",
      code: 'return FluentPullResult(items: items, serverTime: DateTime.parse(response.headers[\'date\']!));',
    );
  }

  /// Applies one page of a pull with the conflict policy.
  Future<FluentPullStats> _applyPage(
    FluentPullResult<T> answer,
    FluentConflictPolicy<T> conflicts,
    FluentRemoteDeleteBehavior remoteDeletes,
    FluentRelationSyncMode? relationSync, {
    DateTime? rememberAs,
  }) async {
    final Map<int, ({T model, Object id, int version})> local =
        conflicts.serverWins || answer.items.isEmpty ? <int, ({T model, Object id, int version})>{} : await unpushedCounterparts(answer.items);
    // A merge is written only if its local row still has the version it was made from (see applyPull).
    final List<({T model, Object id, int version})> resolved = [];
    final Future<T> Function(T local, T remote)? merge = conflicts.merge;
    if (merge != null) {
      for (final MapEntry<int, ({T model, Object id, int version})> e in local.entries) {
        resolved.add((model: await _inCallback(() => merge(e.value.model, answer.items[e.key])), id: e.value.id, version: e.value.version));
      }
    }
    final FluentPullStats applied = await applyPull(
      answer,
      remote: [for (int i = 0; i < answer.items.length; i++) if (!local.containsKey(i)) answer.items[i]],
      resolved: resolved,
      serverWins: conflicts.serverWins,
      remoteDeletes: remoteDeletes,
      relationSync: relationSync,
      rememberAs: rememberAs,
      serverHas: [for (final ({T model, Object id, int version}) l in local.values) l.id],
    );
    if (local.isNotEmpty && merge == null) {
      FluentLog.debug('${local.length} server row(s) of "$tableName" kept their local version (changes not sent yet)', tag: 'sync:$tableName');
    }
    return (pulled: applied.pulled, conflicts: applied.conflicts + local.length, remoteDeleted: applied.remoteDeleted);
  }
}

/// Thrown inside a sync when its [FluentCancelToken] is cancelled; turned into a cancelled result.
class _SyncCancelled implements Exception {
  const _SyncCancelled();
}
