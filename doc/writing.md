# Writing

## Save

```dart
final FluentSaveResult r = await posts.save(Post(title: 'Hello'));   // insert (id generated) or update by key
await posts.saveAll(list);                                          // one transaction
print('${r.inserted} inserted, ${r.updated} updated, ${r.restored} restored, ${r.skipped} skipped');
```

Strategies (`strategy:`):

| Strategy | Row exists | Row missing |
|---|---|---|
| `upsert` (default) | replaced | inserted |
| `insertOnly` | skipped | inserted |
| `updateOnly` | replaced | skipped |
| `patch` | only non-null fields change | skipped |

`updateOnly` and `patch` also skip rows that are in the trash; `upsert` of a trashed key restores the row
(outcome `restored`). The strategy (and `conflictOn`) applies to the models you pass: related models in the graph are
always upserted, and a reference whose target could not be saved keeps its stored value.

`conflictOn: ['email']` matches existing rows by unique columns instead of the key (rows in the trash too, like a key:
a live row wins; a trashed match is restored by `upsert` / `insertOnly`) — for data from a server whose
ids differ from the local ones:

```dart
await users.saveAll(fromServer, conflictOn: ['email']);
```

Related models are saved with the owner (see [Relations](relations.md)); `relationSync: FluentRelationSyncMode.replace`
removes children missing from the lists.

With `conflictOn` the saved model takes the key of the row it matched: the key it carried is replaced until you change
it yourself.

## Update

```dart
await posts.update(post);                                              // only if it exists
await posts.update(post, withRelations: true);                         // also its relations
await posts.updateById(1, {'status': Status.published, 'rating': 5.0}); // just these fields
await posts.updateWhere(FluentFilter.lt('rating', 1), {'status': Status.draft});
```

## Counters and computed values

`updateById` / `updateWhere` take `FluentUpdate` values that SQLite computes from the stored row in the same
statement, so concurrent calls never lose an update (reading the model, changing it and saving it back can):

```dart
await posts.updateById(id, {'views': FluentUpdate.increment(1), 'seen_at': FluentUpdate.now});
await carts.updateWhere(FluentFilter.eq('user_id', u), {'items': FluentUpdate.decrement(1)});
await todos.updateById(id, {'done': FluentUpdate.toggle});
```

`increment` / `decrement` need a number column, `toggle` a bool column; `now` is stored like every `DateTime` of the column.

## Delete and soft delete

Models with `FluentSoftDeletable` go to a **trash**: hidden from reads, kept until purged. The trash calls
(`provider.trash`: `find`, `count`, `watch`, `restore`, `restoreById`, `restoreWhere`, `deleteForever`,
`deleteForeverById`, `deleteForeverWhere`, `empty`; `provider.withTrash`: reads that also see the trash) exist only
for such models.

```dart
await posts.delete(post);            // trash (or permanent for models without soft delete)
await posts.trash.deleteForeverById(1); // permanent
await posts.deleteWhere(FluentFilter.eq('status', Status.draft));
await posts.trash.deleteForeverWhere(FluentFilter.ids([4, 5, 6])); // by keys
await posts.trash.restoreById(1);    // or post.restore(); post.isDeleted tells where it is
await posts.trash.empty(olderThan: const Duration(days: 30)); // empty the trash
await posts.clearTable();                    // synced table: the next pull asks for everything again
```

Soft deletes cascade to owned soft-deletable children, and `restore` brings back what was deleted together. Unique
columns only apply to live rows, so a deleted row never blocks a value. The trash is purged automatically: per model
with `trashRetention` (`FluentConfig`, per database `FluentDbConfig`, per table the model's `tableConfig`), plus
`FluentConfig.trashPurgeInterval`.

`clearTable` on a synced table also drops the changes the server never received and reports `unsentChangesDiscarded`:
run `syncWithServer` first.

## Timestamps

With `FluentTimestamps`, `createdAt` is set on insert and `updatedAt` on every change — by the library, never by `save`.

## Transactions

```dart
await FluentDb.transaction(() async {
  await orders.save(order);
  await stock.updateById(order.stockId, {'reserved': order.quantity});
});
```

Every call inside runs in one SQLite transaction (nested `transaction` calls join it). If the body throws, everything is
rolled back and change events are not published. Each call inside is atomic on its own (a savepoint): when you catch
its error, none of its rows stay. Timers or listeners created inside run outside the transaction once it ends. Keep transactions short: other calls of the database wait. Do not
await a call created *outside* the transaction from inside it — it waits behind the transaction; after
`FluentConfig.transactionWatchdog` (2 s) the library warns and lets waiting reads run inside it (they then see its
uncommitted changes). With several databases pass `dbKey`.

A `FluentDb.transaction` inside another one runs in a savepoint: if it throws, only its own writes (and their events)
are rolled back, and the error reaches the outer body, which may catch it and go on.

## Through `FluentDb` and models

`FluentDb.save<Post>(post)`, `FluentDb.deleteById<Post>(1)`, … and on models: `post.save()`, `post.update()`,
`post.delete()`, `post.restore()`, `post.deleteForever()`; on lists: `list.saveAll()`, `list.deleteAll()`.

## Change events and tags

Every write takes `tag:`; listeners can tell where a change came from and filter by its kind:

```dart
await posts.saveAll(fromServer, tag: 'sync');

FluentDb.onEvent<Post>(kinds: {FluentChangeKind.delete}).listen((e) => debugPrint('${e.items.length} posts deleted'));
FluentDb.onEvent<Post>(tag: 'sync').listen((e) => showSnack('${e.kind.name} from the server'));
```

Kinds: `save`, `update`, `delete`, `restore`, `clear`. `watch` streams follow these events by themselves.

## Signing out, resetting

```dart
await FluentDb.clear(dbKey: AppDb.cache);  // empty every table (also behind RESTRICT rules), keep the file
await FluentDb.deleteDatabases();          // delete the files and open fresh, empty databases (sign-out)
await FluentDb.close();                    // close everything (FluentDb.init opens again)
```

Watchers receive empty results first. `clear` is a write like any other: calls made before it finish first, calls
made after it see the empty tables.

`deleteDatabases` keeps read-only (prebuilt) files. When a file cannot be deleted, `reopen: true` fails with a
`FluentConfigException` (the old rows are never served again) and `reopen: false` reports `fileDeleteFailed`.
`FluentDb.clear()` fails with a typed error when the database is closed or a table cannot be emptied.
