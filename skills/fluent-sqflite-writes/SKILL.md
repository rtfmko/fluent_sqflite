---
name: fluent-sqflite-writes
description: >-
  Use when the user is writing data with fluent_sqflite: save / saveAll and FluentSaveStrategy (upsert, insertOnly,
  updateOnly, patch), conflictOn, FluentSaveResult, update, updateById, updateWhere, delete and soft delete with
  FluentSoftDeletable (provider.trash: restore, deleteForever, empty; withTrash reads), clearTable, timestamps, and FluentDb.transaction.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: writing

## Rules

- Write many rows with `saveAll` (one transaction), never with a loop of `save`.
- Group writes that must succeed together in `FluentDb.transaction(() async { ... })`. Inside it, only await calls
  made inside it; never await a database Future created before or outside the transaction.
- Keep transactions short: no network calls, dialogs or delays inside.
- Counters: `updateById(id, {'n': FluentUpdate.increment(1)})` (also `decrement`, `toggle` for a bool, `now` for a
  time), never read-change-save (concurrent calls lose updates).
- Change a few columns with `updateById(id, {'col': value})` / `updateWhere(filter, {...})` instead of loading and
  re-saving the model.
- Server data with its own ids: `saveAll(rows, conflictOn: ['email'])` matches existing rows by unique columns (also
  rows in the trash: restored by `upsert`, a live row wins).
- The strategy applies to the models you pass; related models are always upserted.
- `updateById` / `updateWhere` refuse library columns (soft delete, sync versions, expiry): use `delete` /
  `trash.restore` / save again.
- Never set `deletedAt`, `createdAt` or `updatedAt` yourself: the library writes them. Use `delete` / `restore`.
- `delete` of a `FluentSoftDeletable` model goes to the trash; `provider.trash.deleteForever*` removes it for good.
  `provider.trash` is a `FluentTrash` (only trashed rows: `find`, `count`, `watch`, `restore*`, `deleteForever*`,
  `empty`); `provider.withTrash` a `FluentWithTrash` (reads that see live and trashed rows).
- Expired rows (`timeToLive`): `update` / `updateAll` / `patch` skip them; `updateById` / `updateWhere` too unless
  `includeExpired: true`; `insertOnly` writes a new row over one; `upsert` renews it.
- `deletedAt` is epoch milliseconds and changes on the models after the commit (delete, restore and save alike);
  `FluentDb.deleteAll`, `Iterable.deleteAll()` and deletes through a base type set it.
- Two saves of the same instance are never merged (double tap = one row). Keys generated in a rolled-back transaction /
  savepoint are taken back. `FluentDb.clear` inside a transaction runs in it. `clear`, `cleanOrphans`,
  `purgeArchivedColumns` inside another running task are skipped (`ignoredCall`); `purgeArchivedColumns` inside a
  transaction too: call it after.
- Handle `FluentConstraintException` (`code == FluentErrorCode.uniqueViolation`, …) where a user can cause it.

- `conflictOn` gives the model the key of the matched row. A nested `FluentDb.transaction` is a savepoint.
  `clearTable` on a synced table drops unsent changes (`unsentChangesDiscarded`): sync first. `deleteDatabases` keeps
  read-only files and fails loudly when a file cannot be deleted.

## Save

```dart
final Post post = Post(title: 'Hello');
final FluentSaveResult r = await posts.save(post); // id generated
final Object? newId = post.primaryKeyValue;        // the generated id
await posts.saveAll(list, strategy: FluentSaveStrategy.insertOnly); // keep existing rows
print('${r.inserted} new, ${r.updated} updated, ${r.restored} restored, ${r.skipped} skipped');
```

| Strategy | Row exists | Row missing |
|---|---|---|
| `upsert` (default) | replaced (a trashed row is restored) | inserted |
| `insertOnly` | skipped | inserted |
| `updateOnly` | replaced | skipped |
| `patch` | non-null fields only | skipped |

A saved model with `id: null` gets its generated id: `model.primaryKeyValue`. `r.outcomes` holds one
`FluentRowOutcome` per model (`inserted`, `updated`, `restored`, `skipped`); `r.saved` counts the written ones.

Saving a model saves its relations too (see the relations skill). A list replaces the stored children;
`save(article, relationSync: FluentRelationSyncMode.preserveLocal)` keeps children missing from the list.

## Update and delete

```dart
await posts.update(post);                                     // only if it exists
await posts.updateById(post.id, {'status': Status.published});
await posts.updateWhere(FluentFilter.lt('rating', 1.0), {'status': Status.draft});
await posts.updateById(post.id, {'views': FluentUpdate.increment(1), 'seen_at': FluentUpdate.now}); // atomic, no lost updates

await posts.delete(post);                     // trash
await posts.trash.deleteForeverById(1);       // permanent
await posts.deleteWhere(FluentFilter.eq('status', Status.draft));
await posts.trash.deleteForeverWhere(FluentFilter.ids([4, 5])); // by keys
await posts.trash.restoreById(1);                            // trash calls: soft-delete models only
await posts.trash.empty(olderThan: const Duration(days: 30));
await posts.clearTable();
```

Soft delete cascades to owned soft-deletable children; `restore` brings them back. Unique columns only apply to live
rows. The trash is purged automatically (`FluentTableConfig(trashRetention: ...)` on the model, else the database / global `trashRetention`; `FluentConfig.trashPurgeInterval`).

## Transactions

```dart
await FluentDb.transaction(() async {
  final FluentSaveResult saved = await orders.save(order);
  await stock.updateById(order.stockId, {'reserved': order.quantity});
  if (saved.inserted == 0) throw StateError('not saved'); // rolls everything back
});
```

Nested `FluentDb.transaction` calls join the open one; each call inside is atomic (a savepoint: a caught error leaves
none of its rows). Change events are published after the commit. With several
databases pass `dbKey:` (a transaction covers one database file).

## Models as active records

```dart
await post.save();
await post.delete();
await note.restore();        // FluentSoftDeletable models; note.deleteForever() skips the trash
await [a, b, c].saveAll();
final Post? fresh = await post.refresh();
```

## Events, tags, reset

```dart
await posts.saveAll(fromServer, tag: 'sync');                 // every write takes tag:
FluentDb.onEvent<Post>(tag: 'sync', kinds: {FluentChangeKind.delete}).listen((e) => ...);
await FluentDb.clear(dbKey: AppDb.cache);                     // empty the tables (synced ones are pulled in full next)
await FluentDb.deleteDatabases();                             // sign-out: delete files, reopen empty
```
