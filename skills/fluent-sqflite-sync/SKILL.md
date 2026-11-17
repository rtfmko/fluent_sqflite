---
name: fluent-sqflite-sync
description: >-
  Use when the user is syncing fluent_sqflite data with a server or API: watchRemote (cache → server → cache streams,
  FluentRemoteResponse, FluentRemoteEvent phases, store modes, maxAge), FluentSyncable push / pull with
  syncWithServer, FluentSyncBatch, FluentPushResult, FluentPullRequest / FluentPullResult pages, conflict policies,
  server keys (FluentTableConfig.serverKey), remote deletes, tombstones, pendingChanges, retries and watchSyncStatus.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: sync

## Rules

- For a screen that shows cached data and refreshes it from a server, use `watchRemote`. For two-way sync of local
  edits, add `with FluentSyncable<T>` to the provider and call `syncWithServer`.
- Never add `is_synced` flags or "dirty" columns: change tracking is automatic (`sync_version`).
- `onPush` returns `FluentPushResult.accepted()` only when the server stored the batch; `FluentPushResult.failed()`
  or an exception keeps everything pending. Return the server's version of new rows in `accepted(updated: [...])`
  (same local key) so they get the server's id; refused rows go in `rejected`.
- `onPull(request)` must return only changes after `request.since` and should set `serverTime` from the server clock;
  for big answers return `hasMore: true` and a `cursor` (passed back in `request.cursor`). Without `serverTime` the
  device clock is used (the `pullClock` hint). `clearTable` / `FluentDb.clear` reset `since` (the next pull is full) and drop pending tombstones (`unsentChangesDiscarded`).
  A local save of a key with a pending tombstone cancels the deletion. `replaceLocally` / `clearLocally` / `watchRemote` keep
  parents that have unsynced descendants.
- Send `batch.deleted` (soft-deleted rows) and `batch.deletedKeys` (permanent deletes, server keys) to the server,
  not only `batch.changed`.
- When the server has its own id next to a local auto-increment id, set `FluentTableConfig(serverKey: ['server_id'])`
  on the model; never match server rows by the local id.
- Local changes not pushed yet win over pulled rows by default; `conflicts: FluentConflictPolicy.merge(...)` merges,
  `.keepServer()` drops them. `watchRemote(store: replace)` keeps them too.
- `syncWithServer` calls on one provider never overlap; edits and deletes made during a push are kept and sent next time.
- Report the server's deletions in `FluentPullResult.deletedKeys`; choose what happens locally with `remoteDeletes`.

- A local deletion not pushed yet is a conflict for pulls: `keepLocal` / `merge` skip the server row, `keepServer`
  restores it. Server `createdAt` / `updatedAt` are kept. Never call `syncWithServer` of the same provider from its
  own callbacks (it returns a failed result).

- Paged answers: `watchRemote(fetchPage: (FluentRemoteRequest r) async => FluentRemoteResponse(items, hasMore: ...,
  cursor: ...))`; `mirror` / `replace` delete only after the last page. `syncWithServer` pages pulls (`hasMore` /
  `cursor`) and pushes `batchSize` (500) per call.
- Stop a running sync with `syncWithServer(cancel: token)` + `token.cancel()` (`FluentCancelToken`); the result has
  `isCancelled: true` and is not an error. A push answer that arrives after the cancel is ignored: the batch is sent
  again next time.

## watchRemote

```dart
StreamSubscription<FluentRemoteEvent<Article>> sub = articles.watchRemote(
  fetch: () async {
    final http.Response r = await http.get(Uri.parse('$api/articles'));
    if (r.statusCode != 200) return FluentRemoteResponse.failed(r.statusCode, r.body);
    return FluentRemoteResponse([for (final Object? e in jsonDecode(r.body) as List) Article.fromApi(e! as Map<String, dynamic>)]);
  },
  where: FluentFilter.eq('category', 'news'),
  orderBy: 'published_at DESC',
  limit: 50,
).listen((FluentRemoteEvent<Article> e) {
  if (e.hasError) showError(e.error);
  setState(() => _articles = e.items); // e.isFetching: show a refresh indicator
});
```

Phases: `cached` → `fetching` → `fresh` or `failed`; with `keepWatching` (default) later changes re-emit the rows.
`store`: `merge` (default), `mirror` (also delete cached rows of `where` missing from the answer, in one transaction; not with `limit`),
`replace` (swap the rows of `where`; not with `limit`), `none` (do not store). `source`: `cacheThenRemote` (default),
`remoteOnly`, `cacheOnly`. Errors: `retries`, `retryDelay` (no retry on 4xx except 408 / 429), `clearCacheOn: {401}`.
`maxAge: Duration(minutes: 5)` skips the fetch while the stored answer of the same query is younger.

## Push and pull

```dart
class NoteProvider extends FluentProvider<Note> with FluentSyncable<Note> {
  // tableName, modelSample, fromCacheJson ...
}

final FluentSyncResult<Note> result = await notes.syncWithServer(
  onPush: (FluentSyncBatch<Note> batch) async {
    final http.Response r = await http.post(Uri.parse('$api/notes/sync'), body: jsonEncode({
      'changed': [for (final Note n in batch.changed) n.toApi()],
      'deleted': [for (final Note n in batch.deleted) n.id],
      'deletedKeys': batch.deletedKeys,
    }));
    return r.statusCode == 200 ? const FluentPushResult.accepted() : FluentPushResult.failed(r.body);
  },
  onPull: (FluentPullRequest request) async {
    final Uri uri = Uri.parse('$api/notes?since=${request.since?.toIso8601String() ?? ''}&cursor=${request.cursor ?? ''}');
    final Map<String, dynamic> d = jsonDecode((await http.get(uri)).body) as Map<String, dynamic>;
    return FluentPullResult<Note>(
      items: [for (final Object? e in d['items'] as List) Note.fromApi(e! as Map<String, dynamic>)],
      deletedKeys: (d['deleted'] as List).cast<Object>(),
      serverTime: DateTime.parse(d['time'] as String),
      hasMore: d['next'] != null,
      cursor: d['next'],
    );
  },
  conflicts: FluentConflictPolicy.merge((Note local, Note remote) async => local.updatedAt!.isAfter(remote.updatedAt!) ? local : remote),
);
if (!result.isSuccess) debugPrint('sync failed: ${result.errorMessage}');
final int waiting = await notes.pendingChanges();
```

Options: `strategy` (`full` default = push then pull, `push`, `pull`), `where`, `batchSize` (default 500, key order),
`conflicts` (`keepLocal` default, `keepServer`, `merge`), `remoteDeletes` (`auto`, `soft`, `hard`, `keep`),
`relationSync`. A call while a sync of the same strategy and `where` runs gets that run's result; other calls wait
for it, then run. Rows edited again while they are pushed go with the next sync. Owned children deleted by a cascade
are reported in `deletedKeys` of their table.

`remoteDeletes` (`FluentRemoteDeleteBehavior`): `auto` (default: trash for `FluentSoftDeletable` models, else delete),
`soft` (trash; models without a trash keep the rows, with a warning), `hard`, `keep` (ignore the server's deletions). The version columns are `sync_version` / `synced_version`
(`syncVersionColumn` / `syncedVersionColumn` on the provider rename them). `retries: 3, retryDelay: Duration(seconds: 1)` retries a failed sync with exponential backoff and jitter
(not on 4xx except 408 / 429); sync again from the app's connectivity listener when the device is back online.

```dart
notes.watchSyncStatus().listen((FluentSyncStatus s) => setState(() => _status = s)); // state (FluentSyncState idle / syncing / failed), pending, lastSyncedAt, lastError

// The server has its own id: match by it (pull, deletedKeys, watchRemote)
@override
FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);
```

Synced tables need keys made on the device (text / UUID) or a `serverKey`: auto-increment ids collide between devices
(the library prints a `syncKey` hint).
