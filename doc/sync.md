# Sync

Two tools: `watchRemote` for "show the cache, refresh it from the server" screens, and `FluentSyncable` for full
two-way sync of local changes.

## watchRemote: cache → server → cache

```dart
final Stream<FluentRemoteEvent<Article>> events = articles.watchRemote(
  fetch: () async {
    final Response r = await http.get(uri);
    if (r.statusCode != 200) return FluentRemoteResponse.failed(r.statusCode, r.body);
    return FluentRemoteResponse(parse(r.body));
  },
  where: FluentFilter.eq('category', 'news'),
  orderBy: 'published_at DESC',
  limit: 50,
);
```

Each `FluentRemoteEvent` has `items` (the rows to show) and a `phase`: `cached` (the cache, before the fetch),
`fetching` (the cache while `fetch` runs), `fresh` (the stored answer), `failed` (the cache, with `error`). Helpers:
`isFetching`, `isFresh`, `hasError`, `isEmpty`. While `keepWatching` (default) the stream stays open and emits the rows
again after every change, keeping the last phase.

* `store`: `merge` (default: save the fetched rows), `mirror` (also delete cached rows of `where` the answer does not
  contain), `replace` (swap the cached rows of `where` for the answer), `none` (do not store; `fresh` carries the
  answer). `mirror` and `replace` need the full set: with `limit` they work as `merge`. Rows with local changes not sent
  yet keep them (the fetched version is skipped, like in a pull); rows are matched by the server key.
* `source`: `cacheThenRemote` (default), `remoteOnly` (no `cached` event), `cacheOnly` (no fetch).
* `retries` / `retryDelay`: exponential backoff with jitter; HTTP 4xx other than 408 / 429 are not retried.
* `clearCacheOn: {401}`: those statuses also remove the cached rows of `where`.
* `includeExpired` (default `true`): expired rows are shown until the fetch replaces them.
* Rows are matched by `serverKey` (below). Local changes not sent yet (`FluentSyncable`) are never overwritten or
  deleted, and the `since` of `syncWithServer` is not touched.

`maxAge` skips the fetch while the cache is fresh: when the same query (`where`, `limit`) stored an answer less than
`maxAge` ago, the stream goes straight to `fresh` with the cached rows. Call again without `maxAge` for pull-to-refresh.

```dart
posts.watchRemote(fetch: api.posts, maxAge: const Duration(minutes: 5));
```

No store mode brings back a row deleted on the device whose deletion was not pushed yet. `cancel()` of the
subscription returns at once; an answer that arrives later is ignored.

A big answer can come in pages: pass `fetchPage` instead of `fetch`. It receives a `FluentRemoteRequest` (`page`,
`cursor`) and returns a `FluentRemoteResponse` with `hasMore` and `cursor` while more pages follow. Each page is
retried on its own and stored when it arrives; a `fetching` event with the rows read so far follows each page.
`mirror` and `replace` delete the cached rows the server lacks only after the last page; a failing page, a cancel or
a store error in between keeps the pages stored so far and deletes nothing. `store: none` collects all pages. A server
that never says `hasMore: false` fails the fetch after 10000 pages. `store: mirror` compares the local keys in pages
of 500, so memory stays small for big tables.

```dart
posts.watchRemote(
  fetchPage: (request) async {
    final page = await api.posts(after: request.cursor as String?);
    return FluentRemoteResponse(page.items, hasMore: page.next != null, cursor: page.next);
  },
  store: FluentRemoteStore.mirror, // deletes only after the last page
);
```

## FluentSyncable: push and pull

```dart
class NoteProvider extends FluentProvider<Note> with FluentSyncable<Note> { ... }

final FluentSyncResult<Note> result = await notes.syncWithServer(
  onPush: (FluentSyncBatch<Note> batch) async {
    // batch.changed: new / edited rows, batch.deleted: rows in the trash, batch.deletedKeys: permanent deletes
    final PushAnswer a = await api.push(batch);
    return a.ok ? FluentPushResult.accepted(updated: a.saved, rejected: a.refusedIds) : FluentPushResult.failed(a.error);
  },
  onPull: (FluentPullRequest request) async {  // request.since: serverTime of the previous pull (null the first time)
    final ServerDelta d = await api.changesSince(request.since, cursor: request.cursor);
    return FluentPullResult(items: d.items, deletedKeys: d.deletedIds, serverTime: d.time, hasMore: d.hasMore, cursor: d.next);
  },
);
print('${result.pushed} sent, ${result.pulled} received, ${result.conflicts} conflicts');
```

* **Change tracking is automatic.** Every local write raises the row's `sync_version`; a push marks only the version
  it sent, so edits made meanwhile go with the next push. Rows received from the server are not sent back.
* **Push:** batches of `batchSize` (default 500, `null`: all at once), in key order. `FluentPushResult.accepted` may
  return the server's version of the rows (`updated`: its ids, times; stored as synced) and the keys it refused
  (`rejected`: they stay waiting, counted in `result.rejected`). `FluentPushResult.failed` or an exception keeps
  everything pending.
* **Pull:** `hasMore` + `cursor` page through big answers; each page is stored when it arrives, and the `since` of the
  next pull moves only after the last page (the `serverTime` of the first page, else the device time when the pull
  started — a device clock ahead of the server skips changes, so return `serverTime`; the `pullClock` hint says so).
  An emptied table (`clearTable`, `FluentDb.clear`) is pulled in full again, and its pending deletions (tombstones) are
  dropped (counted in `unsentChangesDiscarded`).
* **Push:** rows edited again while they are being sent go with the next sync (one sync never loops on them).
* **Deletes:** soft deletes are pushed as `deleted`; permanent deletes (also of owned children removed by the cascade)
  leave tombstones, pushed as `deletedKeys` (server keys). A local save of a key with a pending tombstone cancels the
  deletion: the push sends only the upsert.
* **Refreshing the cache:** `replaceLocally` / `clearLocally` (also used by `watchRemote`) keep parent rows that still have
  unsynced descendants (foreign-key cascade and `oneOf`), so a refresh may leave a few old parents.
* **Conflicts** (a server row whose local row has a change not sent yet): `conflicts:` `FluentConflictPolicy.keepLocal()`
  (default; the change is sent with the next push), `.keepServer()` (the change is dropped), or
  `.merge((local, remote) async => merged)` (the merged model is saved and sent; a local edit made while the callback
  runs wins and stays pending).
* **During a push:** a row edited meanwhile gets only the server key from the answer and stays pending; a row deleted
  meanwhile leaves a tombstone (so the server learns about it). Calls of `syncWithServer` on one provider run one
  after the other; one with the same strategy and `where` shares the running result.
* **Remote deletes:** `remoteDeletes` = `auto` (soft delete when possible, default), `soft`, `hard`, `keep`.
* `strategy`: `full` (push, then pull — default), `push`, `pull`; concurrent calls share one run. `pendingChanges()`
  counts what waits to be sent.
* `retries` / `retryDelay`: a failed sync is tried again after `retryDelay`, doubled each time, with ±50 % random
  jitter; HTTP 4xx errors (`FluentSyncException.statusCode`) other than 408 / 429 are not retried. A failed sync is
  logged once. To sync when the device is back online, call `syncWithServer` from your connectivity listener (e.g.
  connectivity_plus).

A row deleted on the device whose deletion was not pushed yet is never brought back by a pull: it counts as a
conflict. `keepLocal` and `merge` skip the server row (the merge callback is not called for it), `keepServer` stores
it and drops the pending deletion. Rows received from the server keep the `createdAt` / `updatedAt` their model
carries. Calling `syncWithServer` of the same provider from its own `onPush` / `onPull` / merge callback returns a
failed result (`FluentSyncException`) at once instead of waiting for itself: start the next sync after it returned.

### Server keys

Synced rows need a key both sides agree on. Either the key is made on the device (a text / UUID primary key), or the
server has its own id and the model says so:

```dart
@override
FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);
```

Pulled rows, `deletedKeys` (both ways) and `watchRemote` then match rows by `server_id`; the local `id` stays local.
New local rows get their `server_id` from the push answer: `FluentPushResult.accepted(updated: [...])` with the same
local `id`. Auto-increment ids without a `serverKey` collide between devices (the library prints a `syncKey` hint).

### Sync status

```dart
StreamBuilder<FluentSyncStatus>(
  stream: notes.watchSyncStatus(),
  builder: (context, s) {
    final FluentSyncStatus? st = s.data;
    if (st == null || st.isSyncing) return const Text('Syncing…');
    if (st.state == FluentSyncState.failed) return Text('Not synced: ${st.pending} changes waiting');
    return Text(st.hasPending ? '${st.pending} changes not sent' : 'Synced');
  },
);
```

`FluentSyncStatus`: `state` (`idle`, `syncing`, `failed`), `pending`, `lastSyncedAt`, `lastError`. It updates when a
sync starts or ends and after every local write.

The statics `FluentDb.syncWithServer<Note>(...)`, `FluentDb.watchRemote<Note>(...)`, `FluentDb.pendingChanges<Note>()`
and `FluentDb.watchSyncStatus<Note>()` do the same.

Both directions work in portions: `onPull` pages through `hasMore` / `cursor` (`since` moves only after the last
page), `onPush` gets `batchSize` changes (default 500) per call in key order. Rejected rows stay pending, and a failed
batch keeps the earlier batches synced; the next sync sends only the rest.

A running sync can be stopped (a screen that closes, a sign-out): pass a `FluentCancelToken` and cancel it. The sync
returns at once; an answer of `onPush` / `onPull` still on its way is ignored when it arrives (a pushed batch stays
pending and is sent again, so the server should accept a repeated batch). Batches and pages stored before stay; a
pull that did not reach its last page keeps its `since`, so the next sync asks for those changes again.

```dart
final FluentCancelToken token = FluentCancelToken();
final Future<FluentSyncResult<Todo>> sync = todos.syncWithServer(onPush: push, onPull: pull, cancel: token);
// in dispose():
token.cancel();
if ((await sync).isCancelled) return; // not an error
```
