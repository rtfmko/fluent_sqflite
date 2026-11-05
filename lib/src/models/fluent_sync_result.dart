// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../utils/utils.dart';

/// What `syncWithServer` did.
class FluentSyncResult<T> {
  /// Creates a result.
  const FluentSyncResult({
    required this.strategy,
    required this.isSuccess,
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.remoteDeleted = 0,
    this.rejected = 0,
    this.errorMessage,
    this.error,
    this.isCancelled = false,
  });

  /// The strategy that ran.
  final FluentSyncStrategy strategy;

  /// Whether every step succeeded.
  final bool isSuccess;

  /// Whether the sync was stopped through its `FluentCancelToken` ([isSuccess] is false, [error] a
  /// `FluentCancelledException` with code `syncCancelled`). What was stored before the cancel stays.
  final bool isCancelled;

  /// Local changes the server accepted (rows + deletions; refused rows are counted in [rejected]).
  final int pushed;

  /// Server rows written locally.
  final int pulled;

  /// Server rows that met a local change not sent yet (kept local, or merged by `FluentConflictPolicy.merge`).
  final int conflicts;

  /// Rows deleted locally (soft or permanently, see `remoteDeletes`) because the server reported them deleted.
  final int remoteDeleted;

  /// Pushed rows the server refused (`FluentPushResult.accepted(rejected:)`): they stay waiting for the next sync.
  final int rejected;

  /// Why it failed, if [isSuccess] is false.
  final String? errorMessage;

  /// The original error, if any.
  final Object? error;

  /// Number of items handled (pushed + pulled).
  int get itemsProcessed => pushed + pulled;

  @override
  String toString() => 'FluentSyncResult(${strategy.name}, ${isSuccess ? 'ok' : isCancelled ? 'cancelled' : 'failed: $errorMessage'}, pushed: $pushed, pulled: $pulled, conflicts: $conflicts, remoteDeleted: $remoteDeleted${rejected == 0 ? '' : ', rejected: $rejected'})';
}

/// What a `FluentSyncable` table is doing (see [FluentSyncStatus.state]).
enum FluentSyncState {
  /// No sync is running; the last one succeeded (or none ran yet).
  idle,

  /// `syncWithServer` is running (including its retries).
  syncing,

  /// The last sync failed ([FluentSyncStatus.lastError]); the changes wait for the next one.
  failed,
}

/// The sync state of a table, for a "synced / 3 changes waiting / offline" indicator (`watchSyncStatus`).
@immutable
class FluentSyncStatus {
  /// Creates a status (by the library).
  const FluentSyncStatus({required this.state, required this.pending, this.lastSyncedAt, this.lastError});

  /// Running, idle or failed.
  final FluentSyncState state;

  /// Local changes waiting to be sent (changed and trashed rows, deletions).
  final int pending;

  /// When the last sync succeeded (this run), else the time of the last successful pull; `null` if never.
  final DateTime? lastSyncedAt;

  /// The error of the last sync when [state] is [FluentSyncState.failed].
  final Object? lastError;

  /// Whether a sync is running.
  bool get isSyncing => state == FluentSyncState.syncing;

  /// Whether local changes wait to be sent.
  bool get hasPending => pending > 0;

  @override
  bool operator ==(Object other) =>
      other is FluentSyncStatus && other.state == state && other.pending == pending && other.lastSyncedAt == lastSyncedAt && other.lastError == lastError;

  @override
  int get hashCode => Object.hash(state, pending, lastSyncedAt, lastError);

  @override
  String toString() => 'FluentSyncStatus(${state.name}, pending: $pending${lastSyncedAt == null ? '' : ', last: $lastSyncedAt'}${lastError == null ? '' : ', error: $lastError'})';
}

/// The local changes `syncWithServer` sends in one `onPush` call.
class FluentSyncBatch<T> {
  /// Creates a batch (by the library).
  @internal
  FluentSyncBatch({required this.changed, required this.deleted, required this.deletedKeys, required this.versions, required this.tombstones});

  /// New or changed rows (live).
  final List<T> changed;

  /// Rows moved to the trash (models with soft delete).
  final List<T> deleted;

  /// Server keys (`FluentTableConfig.serverKey`, else the primary key) of rows deleted permanently: plain values, or
  /// `FluentKey`s when the key has several columns.
  final List<Object> deletedKeys;

  /// Pushed rows and the version that was read (library bookkeeping).
  @internal
  final List<(Object id, int version)> versions;

  /// Tombstone keys as stored (library bookkeeping).
  @internal
  final List<String> tombstones;

  /// Whether there is nothing to send.
  bool get isEmpty => changed.isEmpty && deleted.isEmpty && deletedKeys.isEmpty;

  /// Number of changes in the batch.
  int get length => changed.length + deleted.length + deletedKeys.length;
}

/// What `onPush` of `syncWithServer` answers.
///
/// ```dart
/// onPush: (batch) async {
///   final res = await api.send(batch);
///   return res.ok ? FluentPushResult.accepted(updated: res.saved, rejected: res.refusedIds) : FluentPushResult.failed(res.error);
/// },
/// ```
class FluentPushResult<T> {
  /// The server stored the batch.
  ///
  /// * [updated]: the server's version of pushed rows (same primary key as sent), e.g. with the id or time the server
  ///   gave them; stored as synced. It never inserts a row (one deleted during the push stays deleted); a row edited
  ///   during the push, or in the trash, only takes its server key columns (`FluentTableConfig.serverKey`), and an
  ///   edited row stays pending.
  /// * [rejected]: primary keys of pushed rows the server refused; they stay waiting and are not sent again in this
  ///   sync (the result counts them). Deletions by key are always taken as sent.
  const FluentPushResult.accepted({this.updated = const [], this.rejected = const []}) : isAccepted = true, error = null;

  /// The server did not take the batch (nothing is marked as sent); the sync fails with [error] and is retried when
  /// `retries` allow it (not when [error] is a `FluentSyncException` with an HTTP 4xx status other than 408 / 429).
  const FluentPushResult.failed([this.error]) : isAccepted = false, updated = const [], rejected = const [];

  /// Whether the server stored the batch.
  final bool isAccepted;

  /// The server's version of pushed rows (see [FluentPushResult.accepted]).
  final List<T> updated;

  /// Primary keys of pushed rows the server refused.
  final List<Object> rejected;

  /// Why the push failed, for [FluentSyncResult.error].
  final Object? error;
}

/// What `onPull` of `syncWithServer` is asked for.
@immutable
class FluentPullRequest {
  /// Creates a request (by the library).
  @internal
  const FluentPullRequest({this.since, this.cursor, this.page = 0});

  /// The time of the last successful pull (`serverTime` of its first page, else the device time when it started);
  /// `null` the first time: send everything.
  final DateTime? since;

  /// The `cursor` of the previous page when it said `hasMore`; `null` for the first page.
  final Object? cursor;

  /// The number of this page in the pull, from 0.
  final int page;

  @override
  String toString() => 'FluentPullRequest(since: $since, page: $page${cursor == null ? '' : ', cursor: $cursor'})';
}

/// What the server sent for `syncWithServer` (`onPull`).
class FluentPullResult<T> {
  /// Creates a pull result.
  const FluentPullResult({this.items = const [], this.deletedKeys = const [], this.serverTime, this.hasMore = false, this.cursor});

  /// Rows that are new or changed on the server.
  final List<T> items;

  /// Server keys (`FluentTableConfig.serverKey`, else the primary key) of rows deleted on the server: plain values,
  /// or `FluentKey`s when the key has several columns.
  final List<Object> deletedKeys;

  /// The server's time of this answer; the `since` of the next pull (the device time when the pull started when
  /// `null`). With pages, the time of the first page counts.
  final DateTime? serverTime;

  /// Whether more pages follow: `onPull` is called again with [cursor] (each page is stored when it arrives).
  final bool hasMore;

  /// Where the next page starts (any value your API understands), passed back in [FluentPullRequest.cursor].
  final Object? cursor;
}

/// What a pull does with a server row whose local row has a change not sent yet.
class FluentConflictPolicy<T> {
  /// The local change wins: the server row (or deletion) is skipped and the change is sent with the next push
  /// (default).
  const FluentConflictPolicy.keepLocal() : serverWins = false, merge = null;

  /// The server row wins: it overwrites the local change, which is dropped (also for rows the server deleted).
  const FluentConflictPolicy.keepServer() : serverWins = true, merge = null;

  /// [merge] combines both versions; the result is saved as a local change and sent with the next push. When the
  /// local row changes again while [merge] runs, that newer edit wins and the merge is dropped. Deletions from the
  /// server are handled like [FluentConflictPolicy.keepLocal].
  ///
  /// ```dart
  /// conflicts: FluentConflictPolicy.merge((local, remote) async => remote.copyWith(title: local.title)),
  /// ```
  const FluentConflictPolicy.merge(Future<T> Function(T local, T remote) this.merge) : serverWins = false;

  /// Whether server rows overwrite local changes ([FluentConflictPolicy.keepServer]).
  final bool serverWins;

  /// The merge of [FluentConflictPolicy.merge].
  final Future<T> Function(T local, T remote)? merge;
}
