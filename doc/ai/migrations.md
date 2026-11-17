# Migrations

Version: 2.0.0. Read this when code written for fluent_sqflite does not compile after an update, or when the analyzer
reports a deprecated member of fluent_sqflite.

Every renamed or removed public member is listed here. From 2.0.0 on, an old name stays in the code with
`@Deprecated('Use <new name> instead')` for at least one minor version before it is removed, so the analyzer points at
every place to change. 2.0.0 itself is a major rewrite: the members below were removed without a deprecation period
(the "Deprecated in" column is `—`).

To migrate: search the code for the text in the "Search for" column and rewrite each match as shown in
"Before → After". Use the new name in new code, never the deprecated one. Then read "Behaviour changes" below: they
compile unchanged but act differently.

In the examples `p` is a provider (`FluentProvider<T>`); the same change applies to the `FluentDb.*<T>` statics and to
the model extensions (`item.save()`, …). Provider methods no longer take `dbName:`; `FluentDb` statics take `dbKey:`.

## Reading

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `findOne` | `findFirst` | — | 2.0.0 | `findOne(` | `p.findOne()` → `p.findFirst(orderBy: 'id')` |
| `findItemsBy` | `find` | — | 2.0.0 | `findItemsBy(` | `p.findItemsBy(v, key: 'c', orderBy: 'x')` → `p.find(where: FluentFilter.eq('c', v), orderBy: 'x')` |
| `findValidItems` | `find` | — | 2.0.0 | `findValidItems(` | `p.findValidItems(...)` → `p.find(...)` (expired rows are always hidden) |
| `findDeletedItems` | `trash.find` | — | 2.0.0 | `findDeletedItems(` | `p.findDeletedItems(limit: 20)` → `p.trash.find(limit: 20)` |
| `rawGetItemBy` | `findMaps` | — | 2.0.0 | `rawGetItemBy(` | `p.rawGetItemBy(v, column: 'c')` → `(await p.findMaps(where: FluentFilter.eq('c', v), limit: 1)).firstOrNull` |
| `rawGetItemsBy` | `findMaps` | — | 2.0.0 | `rawGetItemsBy(` | `p.rawGetItemsBy(v, column: 'c')` → `p.findMaps(where: FluentFilter.eq('c', v))` |
| `where:` string + `whereArgs:` | `where:` `FluentFilter` | — | 2.0.0 | `whereArgs:` | `p.find(where: 'a = ?', whereArgs: [1])` → `p.find(where: FluentFilter('a = ?', [1]))` |
| `localWhere` / `localWhereArgs` / `localFilter` | `where` | — | 2.0.0 | `localWhere` | `p.reactiveSync(..., localWhere: 'a = ?', localWhereArgs: [x])` → `p.watchRemote(..., where: FluentFilter('a = ?', [x]))` |
| `localOrderBy` | `orderBy` | — | 2.0.0 | `localOrderBy:` | `localOrderBy: 'b'` → `orderBy: 'b'` |
| `ignoreLazy:` | `relations:` | — | 2.0.0 | `ignoreLazy:` | `p.findAll(ignoreLazy: true)` → `p.findAll(relations: FluentLoad.all)`; rows only: `relations: FluentLoad.none` |
| `maxDepth: 0` (unlimited) | `maxDepth: 8` | — | 2.0.0 | `maxDepth: 0` | `maxDepth: 0` → a real depth, at most 8 (`relations: FluentLoad.none` loads none) |
| `FluentSyncOptions(ignoreLazy:)` | `watchRemote(relations:)` | — | 2.0.0 | `ignoreLazy:` | `ignoreLazy: true` → `relations: FluentLoad.all` |
| `provider.keysFilter(ids)`, `keyFilter(id)` | `FluentFilter.ids(ids)`, `findByIds` | — | 2.0.0 | `keysFilter(` | `p.find(where: p.keysFilter(ids))` → `p.findByIds(ids)`; `p.deleteWhere(p.keysFilter(ids))` → `p.deleteWhere(FluentFilter.ids(ids))` |
| trash calls on any provider | `trash` / `withTrash`, only for `FluentSoftDeletable` models | — | 2.0.0 | `findDeletedItems(` | they returned nothing for other models: remove the calls, or add `with FluentSoftDeletable` to the model |
| `FluentDataEvent` helpers `hasValidData`, `singleData`, `shouldRenderUi`, `isCachedData`, `isFreshData`, `hasDataPhase`, `isSaving`, `isSyncing` | `FluentRemoteEvent`: `isEmpty`, `items.firstOrNull`, `phase`, `isFresh`, `isFetching`, `hasError` | — | 2.0.0 | `hasValidData` | `e.hasValidData` → `!e.isEmpty`; `e.singleData` → `e.items.firstOrNull`; `e.isCachedData` → `e.phase == FluentRemotePhase.cached`; `e.isFreshData` → `e.isFresh`; `e.isSaving` / `e.isSyncing` → `e.isFetching`; `shouldRenderUi` / `hasDataPhase` → switch on `e.phase` |

## Writing

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `saveItem` | `save` | — | 2.0.0 | `saveItem(` | `p.saveItem(x, saveStrategy: s)` → `p.save(x, strategy: s)` |
| `saveItems` | `saveAll` | — | 2.0.0 | `saveItems(` | `p.saveItems(xs, saveStrategy: s)` → `p.saveAll(xs, strategy: s)` (returns `FluentSaveResult`) |
| `saveStrategy:` | `strategy:` | — | 2.0.0 | `saveStrategy:` | `saveStrategy: FluentSaveStrategy.patch` → `strategy: FluentSaveStrategy.patch` |
| `updateByKey` | `updateById` | — | 2.0.0 | `updateByKey(` | `p.updateByKey(id, 'c', v)` → `p.updateById(id, {'c': v})` |
| `updateFieldsMultiple` | `updateById` | — | 2.0.0 | `updateFieldsMultiple(` | `p.updateFieldsMultiple(id, fields)` → `p.updateById(id, fields)` |
| `updateFieldsMultipleByIds` | `updateWhere` | — | 2.0.0 | `updateFieldsMultipleByIds(` | `p.updateFieldsMultipleByIds(ids, f)` → `p.updateWhere(FluentFilter.ids(ids), f)` |
| `updateWithRelations` | `update(withRelations: true)` | — | 2.0.0 | `updateWithRelations(` | `p.updateWithRelations(x, syncMode: m)` → `p.update(x, withRelations: true, syncMode: m)` |
| `updateAllWithRelations` | `updateAll(withRelations: true)` | — | 2.0.0 | `updateAllWithRelations(` | `p.updateAllWithRelations(xs)` → `p.updateAll(xs, withRelations: true)` |
| `updateAndFetch` | `update` + `findById` | — | 2.0.0 | `updateAndFetch(` | `final y = await p.updateAndFetch(x)` → `await p.update(x); final y = await p.findById(x.primaryKeyValue)` |
| `batch:` / `sharedBatch:` / `executor:` parameters | `FluentDb.transaction` | — | 2.0.0 | `sharedBatch:` | `p.saveItem(a, batch: b); p.deleteBy(..., batch: b)` → `await FluentDb.transaction(() async { await p.save(a); await p.deleteWhere(...); })` |
| `FluentDb().transaction(modelTypes:, action:)` | `FluentDb.transaction(action)` | — | 2.0.0 | `modelTypes:` | `FluentDb().transaction(modelTypes: [A], action: () async {...})` → `FluentDb.transaction(() async {...})` |
| `ExecutionPolicy(customTag:)`, `policy.withTag(t)` | `tag:` of every write | — | 2.0.0 | `customTag:` | `p.save(x, policy: ExecutionPolicy(customTag: 'api'))` → `p.save(x, tag: 'api')` |
| `ExecutionPolicy.bulkUpload`, `streamOnly`, `heavyQuery`, `rootDefault`, `merge`, `flatten`, `copyWith`, `effectivePriority` | `ExecutionPolicy.background` / `fast` / `fresh` | — | 2.0.0 | `ExecutionPolicy.` | `ExecutionPolicy.bulkUpload` → `ExecutionPolicy.background`; `streamOnly` / `heavyQuery` → remove them (identical reads are shared by default) |
| `FluentChangeEvent.action` (`FluentDbAction`), `customTag`, `onEvent(actions:)` | `kind` (`FluentChangeKind`), `tag`, `onEvent(kinds:)` | — | 2.0.0 | `actions:` | `onEvent<T>(actions: [FluentDbAction.save])` → `onEvent<T>(kinds: {FluentChangeKind.save})`; `e.action == FluentDbAction.hardDelete` → `e.kind == FluentChangeKind.delete`; `e.customTag` → `e.tag` |
| `FluentDbAction` | `FluentChangeKind` | — | 2.0.0 | `FluentDbAction.` | internal now; events carry `FluentChangeKind` (`save`, `update`, `delete`, `restore`, `clear`) |
| `expiryDate`, `expiryDuration` | `timeToLive` | — | 2.0.0 | `expiryDate` | `s..expiryDate = DateTime.now().add(d)` → `s..timeToLive = d`; a table-wide life: `@override Duration? get timeToLive => d;` |
| `FluentStorable.fromJsonWithExpiry` | — | — | 2.0.0 | `fromJsonWithExpiry(` | `FluentStorable.fromJsonWithExpiry(json, X.fromJson)` → `X.fromJson(json)` |

## Deleting

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `hardDelete` | `trash.deleteForever` | — | 2.0.0 | `hardDelete(` | `p.hardDelete(x)` → `p.trash.deleteForever(x)`; without `FluentSoftDeletable` `delete` is already permanent: `p.delete(x)` |
| `hardDeleteById` | `trash.deleteForeverById` | — | 2.0.0 | `hardDeleteById(` | `p.hardDeleteById(id)` → `p.trash.deleteForeverById(id)` (other models: `p.deleteById(id)`) |
| `hardDeleteAll` | `trash.deleteForeverWhere` | — | 2.0.0 | `hardDeleteAll(` | `p.hardDeleteAll(xs)` → `p.trash.deleteForeverWhere(FluentFilter.ids([for (final x in xs) x.primaryKeyValue]))` (other models: `p.deleteAll(xs)`) |
| `hardDeleteBy` | `trash.deleteForeverWhere` | — | 2.0.0 | `hardDeleteBy(` | `p.hardDeleteBy(v, key: 'c')` → `p.trash.deleteForeverWhere(FluentFilter.eq('c', v))` (other models: `p.deleteWhere(...)`) |
| `hardDeleteItemsByIds` | `trash.deleteForeverWhere` | — | 2.0.0 | `hardDeleteItemsByIds(` | `p.hardDeleteItemsByIds(ids)` → `p.trash.deleteForeverWhere(FluentFilter.ids(ids))` (other models: `p.deleteWhere(...)`) |
| `hardDeleteWhere` | `trash.deleteForeverWhere` | — | 2.0.0 | `hardDeleteWhere(` | `p.hardDeleteWhere(where: 'a = ?', whereArgs: [1])` → `p.trash.deleteForeverWhere(FluentFilter('a = ?', [1]))` (other models: `p.deleteWhere(...)`) |
| `deleteBy` | `deleteWhere` | — | 2.0.0 | `deleteBy(` | `p.deleteBy(v, key: 'c')` → `p.deleteWhere(FluentFilter.eq('c', v))` |
| `deleteItemsByIds` | `deleteWhere` | — | 2.0.0 | `deleteItemsByIds(` | `p.deleteItemsByIds(ids)` → `p.deleteWhere(FluentFilter.ids(ids))` |
| `restore` / `restoreById` on the provider or `FluentDb` | `trash.restore` / `trash.restoreById` | — | 2.0.0 | `.restore` | `p.restore(x)` → `p.trash.restore(x)` (or `x.restore()`); `FluentDb.restoreById<T>(id)` → `FluentDb.trash<T>().restoreById(id)` |
| `restoreAll` | `trash.restoreWhere` | — | 2.0.0 | `restoreAll(` | `p.restoreAll(xs)` → `p.trash.restoreWhere(FluentFilter.ids([for (final x in xs) x.primaryKeyValue]))` |
| `restoreItemsByIds` | `trash.restoreWhere` | — | 2.0.0 | `restoreItemsByIds(` | `p.restoreItemsByIds(ids)` → `p.trash.restoreWhere(FluentFilter.ids(ids))` |
| `restoreAndFetch` | `trash.restore` + `findById` | — | 2.0.0 | `restoreAndFetch(` | `final y = await p.restoreAndFetch(x)` → `await p.trash.restore(x); final y = await p.findById(x.primaryKeyValue)` |
| `restoreAndFetchById` | `trash.restoreById` + `findById` | — | 2.0.0 | `restoreAndFetchById(` | `p.restoreAndFetchById(id)` → `await p.trash.restoreById(id); await p.findById(id)` |
| `purgeSoftDeleted` | `trash.empty` | — | 2.0.0 | `purgeSoftDeleted(` | `p.purgeSoftDeleted()` → `p.trash.empty()` |
| `forcePurgeSoftDeleted` | `trash.empty(olderThan: Duration.zero)` | — | 2.0.0 | `forcePurgeSoftDeleted(` | `p.forcePurgeSoftDeleted()` → `p.trash.empty(olderThan: Duration.zero)` |
| `clearExpiredItems` | `clearExpired` | — | 2.0.0 | `clearExpiredItems(` | `p.clearExpiredItems()` → `p.clearExpired()` |

## Relations

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentDbRelation` | `FluentRelation` | — | 2.0.0 | `FluentDbRelation` | `{Person: FluentDbRelation<Article, Person>(mapToKey: 'author', entitySelector: (a) => a.author, castType: FluentModelCast.model)}` → `[FluentRelation.one<Article, Person>('author', (a) => a.author)]` |
| `relations` as `Map<Type, FluentDbRelation>` | `List<FluentRelation> get relations` | — | 2.0.0 | `Map<Type, FluentDbRelation` | `Map<Type, FluentDbRelation<...>> get relations => {...}` → `List<FluentRelation> get relations => [...]` (on the model, `with FluentRelations`) |
| `FluentDbRelationType`, `FluentModelCast` | `FluentRelationType` | — | 2.0.0 | `FluentModelCast.` | `oneToMany` + `modelList` → `FluentRelation.many`; a single referenced model → `FluentRelation.one`; a single owned child → `FluentRelation.oneOwned`; `pivotTable` → `FluentRelation.manyToMany(linkTable: ...)`; unsure → `FluentRelation.auto` |
| `mapToKey` / `entitySelector` / `localKey` / `pivotTable` | `name` / `select` / `foreignKey` / `linkTable` | — | 2.0.0 | `mapToKey:` | `mapToKey: 'tags', pivotTable: 'article_tags'` → `FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags, linkTable: 'article_tags')` |
| `autoLoad` / `isLazy` | `lazy` | — | 2.0.0 | `autoLoad:` | `autoLoad: false` → `lazy: true` |
| `onDeleteCascade` | `onDelete` | — | 2.0.0 | `onDeleteCascade:` | `onDeleteCascade: false` → `onDelete: FluentOnDelete.setNull` |
| `FluentRelationUpdateMode` | `keepMissing` / `FluentRelationSyncMode` | — | 2.0.0 | `FluentRelationUpdateMode` | `updateMode: FluentRelationUpdateMode.skipOnNull` → remove it (a `null` relation is always left untouched) |
| `isPolymorphic` / `polyTypeColumn` | `FluentRelation.oneOf` + `many(via:)` | — | 2.0.0 | `isPolymorphic:` | → `FluentRelation.oneOf<Comment>('target', (c) => c.target, types: [Post, Photo])`; the list on the owner: `FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target')` (columns `target_type` + `target_id`) |
| `switch` over `FluentRelationType` | new value `FluentRelationType.oneOf` | — | 2.0.0 | `case FluentRelationType.` | add a `case FluentRelationType.oneOf:` (an exhaustive `switch` no longer compiles without it) |
| `FluentRelationsMixin<T>` on the provider | `FluentRelations` on the model | — | 2.0.0 | `FluentRelationsMixin` | move `List<FluentRelation> get relations` from `class XProvider extends FluentProvider<X> with FluentRelationsMixin<X>` to `class X extends FluentStorable with FluentRelations` |
| `relationNamed`, `relationsTo` | — | — | 2.0.0 | `relationNamed(` | read `relations` directly |
| `ensureLoaded` | `loadRelations` | — | 2.0.0 | `ensureLoaded(` | `await p.ensureLoaded(x); x.getRelation('tags')` → `final full = await x.loadRelations(); full.tags` |
| `getRelation`, `getDynamicValue`, `isFieldLoaded` | the model's fields, `isRelationLoaded` | — | 2.0.0 | `getRelation(` | `x.getRelation('tags')` → `x.tags` (from `loadRelations`); `x.isFieldLoaded('tags')` → `x.isRelationLoaded('tags')` |
| `countOf` | `countRelated` | — | 2.0.0 | `countOf(` | `p.countOf(x, 'comments')` → `x.countRelated('comments')` |

## Registry and lifecycle

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentDb()` instance calls | `FluentDb` statics | — | 2.0.0 | `FluentDb()` | `FluentDb().init(groups)` → `FluentDb.init(groups)`; `FluentDb().restart(updateConfig: f)` → `FluentDb.restart(update: f)` |
| `closeAll` | `FluentDb.close` | — | 2.0.0 | `closeAll(` | `FluentDb().closeAll()` → `FluentDb.close()` |
| `destroyAllDatabases`, `destroyAllDatabasesAndRestart`, `dropDatabase`, `dropAll` | `FluentDb.deleteDatabases` | — | 2.0.0 | `destroyAllDatabases` | `destroyAllDatabasesAndRestart()` → `FluentDb.deleteDatabases()`; `destroyAllDatabases()` → `FluentDb.deleteDatabases(reopen: false)`; `dropDatabase(k)` → `FluentDb.deleteDatabases(dbKey: k, reopen: false)` |
| `clearSelectedDatabase`, `clearAllDatabases` | `FluentDb.clear` | — | 2.0.0 | `clearSelectedDatabase(` | `FluentDb.clearSelectedDatabase(k)` → `FluentDb.clear(dbKey: k)`; `clearAllDatabases()` → `FluentDb.clear()` |
| `isInitialized`, `isDatabaseOpen`, `isModelStorageReady` | `FluentDb.isOpen` | — | 2.0.0 | `isDatabaseOpen(` | `FluentDb().isDatabaseOpen('app')` → `FluentDb.isOpen(dbKey: FluentDbKey('app'))`; `isInitialized` → `FluentDb.isOpen()` |
| `reset` | — | — | 2.0.0 | `.reset()` | remove it (`close` resets the registry) |
| `providerByType<T>(dbName:)` | `providerOf<T>(dbKey:)` | — | 2.0.0 | `providerByType<` | `FluentDb.providerByType<User>()` → `FluentDb.providerOf<User>()` |
| `provider<P>(dbName:)` | `provider<P>(dbKey:)` | — | 2.0.0 | `provider<` | `FluentDb.provider<UserProvider>(dbName: 'app')` → `FluentDb.provider<UserProvider>(dbKey: FluentDbKey('app'))` |
| `getProviderByTable`, `providerByModel`, `providerForType` | `providerOf<T>()` / `provider<P>()` | — | 2.0.0 | `getProviderByTable(` | `FluentDb.getProviderByTable('users')` → `FluentDb.provider<UserProvider>()`; `providerByModel(x)` → `FluentDb.providerOf<X>()` |
| `cleanOrphans(group)`, `resetPerformanceStats(dbKey:, tableName:)` | `FluentDb.cleanOrphans({dbKey})`, `FluentDb.forgetQueryStats({dbKey, table})` | — | 2.0.0 | `resetPerformanceStats(` | `FluentDb().resetPerformanceStats(dbKey: k, tableName: 't')` → `FluentDb.forgetQueryStats(dbKey: k, table: 't')` |
| `FluentDb.executeTask`, `FluentProvider.db` / `executor` / `dbOrNull` / `modelType` / `relationLinks` / `defaultForeignKey` / `setTableName` / `refreshSchema` / `getFullSchema` / `createTable` / `generateCreateTableSql` / `mapToModel*` / `transformResponseAsync` | — | — | 2.0.0 | `.db.` | internal, no longer exported: use the provider API, `rawQuery` / `execute` for own SQL |
| `FluentIndex.nameFor` / `createSql`, `FluentCheck.sql`, `FluentStorable.clearSchemaCache` | — | — | 2.0.0 | `createSql(` | internal: indexes and checks are created from the model |

## Sync

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentSyncStrategy.pushActive` / `pullAndSave` / `purgeDeleted` | `push` / `pull` / `full` | — | 2.0.0 | `FluentSyncStrategy.` | `strategy: FluentSyncStrategy.pushActive` → `strategy: FluentSyncStrategy.push` |
| `onPush(List<T>)` | `onPush(FluentSyncBatch<T>)` | — | 2.0.0 | `onPush:` | `onPush: (items) async => api.send(items)` → `onPush: (batch) async => api.send(batch.changed, deleted: batch.deleted, deletedKeys: batch.deletedKeys)` |
| `onPush` → `bool` | `onPush` → `FluentPushResult<T>` | — | 2.0.0 | `onPush:` | `return ok;` → `return ok ? const FluentPushResult.accepted() : const FluentPushResult.failed();` |
| `onPull()` → `List<T>` | `onPull(FluentPullRequest)` → `FluentPullResult<T>` | — | 2.0.0 | `onPull:` | `onPull: () async => api.all()` → `onPull: (request) async => FluentPullResult(items: await api.changes(request.since), serverTime: serverNow)` |
| `markAsSyncedFields` / `pushOnlyUnsynced` / `is_synced` column | automatic change tracking | — | 2.0.0 | `markAsSyncedFields:` | `markAsSyncedFields: {'is_synced': 1}, pushOnlyUnsynced: true` → remove both (every local change is tracked and pushed once) |
| `additionalWhere` / `additionalWhereArgs` / `additionalFilter` | `where` | — | 2.0.0 | `additionalWhere` | `additionalWhere: 'a = ?', additionalWhereArgs: [x]` → `where: FluentFilter('a = ?', [x])` |
| `reactiveSync` | `watchRemote` | — | 2.0.0 | `reactiveSync(` | `p.reactiveSync(fetchFromApi: f, options: const FluentSyncOptions(limit: 20))` → `p.watchRemote(fetch: f, limit: 20)` |
| `FluentSyncOptions` | named parameters of `watchRemote` | — | 2.0.0 | `FluentSyncOptions(` | `limit`, `maxDepth`, `relations`, `keepWatching`, `maxAge` keep their names; `retryCount` → `retries`, `baseRetryBackoff` → `retryDelay`, `relationSyncMode` → `relationSync`, `loadOnlyValidCache: true` → `includeExpired: false` |
| `fetchFromApi` → `FluentApiResponse` | `fetch` → `FluentRemoteResponse` | — | 2.0.0 | `FluentApiResponse` | `FluentApiResponse.list(data: xs, statusCode: c)` → `FluentRemoteResponse(xs)` (or `FluentRemoteResponse.failed(c, error)`); `.single(data: x)` → `.single(x)`; `.empty()` → `const FluentRemoteResponse([])` |
| `FluentDataEvent`, `FluentPipelinePhase`, `FluentDataSource` | `FluentRemoteEvent`, `FluentRemotePhase` | — | 2.0.0 | `FluentDataEvent` | `e.data` → `e.items`; phases `cacheReady` → `cached`, `loadingApi` → `fetching`, `apiReady` / `completed` → `fresh`, `error` → `failed`; `e.source == FluentDataSource.api` → `e.isFresh`; `when(...)` → `switch (e.phase)` |
| `mergeStrategy: FluentMergeStrategy.*` | `store: FluentRemoteStore.*` | — | 2.0.0 | `FluentMergeStrategy.` | `upsert` → `merge`, `syncDeletions` → `mirror`, `replace` / `none` keep their names |
| `executionStrategy: FluentExecutionStrategy.*` | `source: FluentRemoteSource.*` | — | 2.0.0 | `FluentExecutionStrategy.` | `cacheThenApiYieldThenSave` / `cacheThenApiThenSave` → `cacheThenRemote` (data is always shown after it is stored), `apiOnly` → `remoteOnly`, `cacheOnly` keeps its name |
| `statusBehaviors` / `defaultErrorBehavior` (`FluentApiErrorBehavior`) | `clearCacheOn` | — | 2.0.0 | `statusBehaviors:` | `statusBehaviors: {401: FluentApiErrorBehavior.clearCacheAndYieldError}` → `clearCacheOn: {401}`; errors always end in a `failed` event with the cache |
| `validStatusCodes` | — | — | 2.0.0 | `validStatusCodes:` | remove it: 200–299 count as success |
| `emptyApiBehavior` (`FluentEmptyApiBehavior`) | `store` | — | 2.0.0 | `emptyApiBehavior:` | `clearCache` → `store: FluentRemoteStore.mirror` (an empty full answer removes the cached rows); `preserveCache` → the default `merge` |
| `onSuccess` / `onError` / `beforeSave` / `awaitPersistence` | the event stream / `fetch` | — | 2.0.0 | `onSuccess:` | react to `fresh` / `failed` events; transform rows inside `fetch`; storing is always awaited |
| `pullConflictOn:` | `FluentTableConfig(serverKey:)` | — | 2.0.0 | `pullConflictOn:` | `syncWithServer(..., pullConflictOn: ['server_id'])` → in the model: `FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);` |
| `onConflict:` | `conflicts: FluentConflictPolicy.merge(...)` | — | 2.0.0 | `onConflict:` | `onConflict: (l, r) async => m` → `conflicts: FluentConflictPolicy.merge((l, r) async => m)` |
| `FluentDb.reactiveSync<T>` | `FluentDb.watchRemote<T>` | — | 2.0.0 | `FluentDb.reactiveSync` | same parameters as `watchRemote` |

## Errors

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentNotInitializedException` | `FluentConfigException` | — | 2.0.0 | `FluentNotInitializedException` | `on FluentNotInitializedException` → `on FluentConfigException catch (e) when (e.code == FluentErrorCode.notInitialized)` |
| `ProviderNotFoundException` | `FluentConfigException` | — | 2.0.0 | `ProviderNotFoundException` | → `FluentConfigException`, `code == FluentErrorCode.providerNotFound` |
| `AmbiguousProviderException` | `FluentConfigException` | — | 2.0.0 | `AmbiguousProviderException` | → `FluentConfigException`, `code == FluentErrorCode.ambiguousProvider` |
| `FluentDatabaseNameException` | `FluentConfigException` | — | 2.0.0 | `FluentDatabaseNameException` | → `FluentConfigException`, `code == FluentErrorCode.invalidDatabaseName` |
| `FluentDatabaseNotFoundException` | `FluentConfigException` | — | 2.0.0 | `FluentDatabaseNotFoundException` | → `FluentConfigException`, `code == FluentErrorCode.databaseNotFound` |
| `FluentConfigurationException` | `FluentConfigException` | — | 2.0.0 | `FluentConfigurationException` | → `FluentConfigException`, `code == FluentErrorCode.invalidConfiguration` |
| `MigrationFailedException` | `FluentSchemaException` | — | 2.0.0 | `MigrationFailedException` | → `FluentSchemaException`, `code == FluentErrorCode.migrationFailed` |
| `InvalidSqlTypeException` | `FluentArgumentException` | — | 2.0.0 | `InvalidSqlTypeException` | → `FluentArgumentException`, `code == FluentErrorCode.unsupportedValue` |
| `FluentSQFLiteException` | `FluentQueryException` | — | 2.0.0 | `FluentSQFLiteException` | `on FluentSQFLiteException` → `on FluentQueryException` |
| `FluentApiException`, `FluentSyncableException` | `FluentSyncException` | — | 2.0.0 | `FluentApiException` | `e.statusCode` stays: `on FluentSyncException catch (e) { e.statusCode }` (`code == FluentErrorCode.apiError`) |
| `FluentTaskCancelledException` | `FluentCancelledException` | — | 2.0.0 | `FluentTaskCancelledException` | → `FluentCancelledException` (code `engineClosed`) |
| `FluentBatchException`, `FluentBaseException` | `FluentException` | — | 2.0.0 | `FluentBatchException` | → catch `FluentException` (or the specific class) |
| `originalError` | `cause` | — | 2.0.0 | `.originalError` | `e.originalError` → `e.cause` |
| `DatabaseException` from reads | `FluentQueryException` | — | 2.0.0 | `on DatabaseException` | `on DatabaseException` around fluent_sqflite calls → `on FluentException` (SQLite errors are wrapped; the original is `cause`) |

## Logging and configuration

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentDb.setupLogging(userLogger:, internalLogger:)` | `FluentDb.setupLogging(level:, onRecord:)` | — | 2.0.0 | `userLogger:` | `setupLogging(userLogger: FluentLogger(onError: send))` → `setupLogging(onRecord: (r) { if (r.level == FluentLogLevel.error) send(r.message, r.error, r.stackTrace); })` |
| `FluentLogger`, `FluentTelemetry` | `FluentLogRecord` + `onRecord` | — | 2.0.0 | `FluentLogger(` | a custom `FluentTelemetry` class → one `onRecord` callback |
| `FluentDb.setupDefault()` | `FluentDb.setupLogging()` | — | 2.0.0 | `setupDefault(` | `FluentDb.setupDefault()` → remove it (the default is on) |
| `FluentDb.setupDefaultDebug()` | `setupLogging(level: FluentLogLevel.debug)` | — | 2.0.0 | `setupDefaultDebug(` | `FluentDb.setupDefaultDebug()` → `FluentDb.setupLogging(level: FluentLogLevel.debug)` |
| `FluentDb.isLoggingEnable`, `FluentDb.toggleLogging` | `FluentDb.setupLogging(enabled:)` | — | 2.0.0 | `toggleLogging(` | `FluentDb.toggleLogging(false)` → `FluentDb.setupLogging(enabled: false)`; `isLoggingEnable` → remove it (you set it) |
| `FluentEngineConfig` | `FluentConfig` | — | 2.0.0 | `FluentEngineConfig` | `init(groups, engineConfig: FluentEngineConfig(...))` → `init(groups, config: FluentConfig(...))` |
| `SQLitePerformanceConfig`, `FluentGroup(performanceConfig:)` | `FluentDbConfig`, `FluentGroup(config:)` | — | 2.0.0 | `SQLitePerformanceConfig` | `FluentGroup(..., performanceConfig: SQLitePerformanceConfig(...))` → `FluentGroup(..., config: FluentDbConfig(...))` |
| `FluentDb.changeFluentEngineConfig(configs:)` | `FluentDb.configure` | — | 2.0.0 | `changeFluentEngineConfig(` | `FluentDb.changeFluentEngineConfig(configs: c)` → `FluentDb.configure(c)` |
| `changeCurrentPerformanceConfig` | — | — | 2.0.0 | `changeCurrentPerformanceConfig` | remove it; set pragmas in `FluentGroup(config:)` |
| `FluentDb.init(purgeDuration:)`, `FluentDb.softDeleteRetentionPeriod` | `FluentConfig.trashRetention` (or `FluentDbConfig` / `FluentTableConfig`) | — | 2.0.0 | `purgeDuration:` | `init(groups, purgeDuration: d)` → `init(groups, config: FluentConfig(trashRetention: d))` |
| `FluentSoftDeletable.softDeleteRetention` | `FluentTableConfig.trashRetention` | — | 2.0.0 | `softDeleteRetention =>` | `Duration? get softDeleteRetention => d;` → `FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: d);` |
| `FluentProvider.tableConfig` | `FluentStorable.tableConfig` | — | 2.0.0 | `get tableConfig` | move the override from the provider to the model |
| `FluentTableConfig(sanitizeTypes:)`, `FluentTableConfig.copyWith` | — | — | 2.0.0 | `sanitizeTypes:` | remove it (values are always converted) |
| `FluentDb.globalPolicy` | `FluentConfig.defaultPolicy` | — | 2.0.0 | `globalPolicy` | `FluentDb.globalPolicy = p` → `init(groups, config: FluentConfig(defaultPolicy: p))` |
| `FluentEngineConfig(maxPauseDuration:, alertPauseDuration:)` | `FluentConfig(pauseWatchdog:)` | — | 2.0.0 | `PauseDuration:` | `maxPauseDuration: d` → `pauseWatchdog: d` (resumes with a warning; `null` never resumes) |
| `FluentEngineConfig(saveInterval:, telemetryRetention:)` | — | — | 2.0.0 | `saveInterval:` | remove them (stats are written when changed, kept 30 days) |
| `SQLitePerformanceConfig.maxConcurrentReads`, `enableConcurrentReads` | `readConnections` | — | 2.0.0 | `ConcurrentReads` | `maxConcurrentReads: 5` → `readConnections: 2`; `enableConcurrentReads: false` → `readConnections: 0` |
| `queueAgingPercentage` / `queueAgingSubtract`, `readAgingPerSecond` | — | — | 2.0.0 | `Aging` | remove it (waiting reads age automatically) |
| `queueStrategy`, `FluentQueueStrategy`, `FluentDbExecutionStrategy`, `executionStrategy` | — | — | 2.0.0 | `Strategy.` | remove it (merging and priorities are always on; `readConnections: 0` runs reads one at a time) |
| `SQLitePerformanceConfig.bulkImport()`, `readOnlyOptimized()` | — | — | 2.0.0 | `bulkImport(` | remove it (`saveAll` writes in one transaction; `bulkImport` turned data safety off) |
| `SQLitePerformanceConfig.highIntegrity()` | `FluentDbConfig.highIntegrity` | — | 2.0.0 | `highIntegrity()` | `SQLitePerformanceConfig.highIntegrity()` → `FluentDbConfig.highIntegrity` |
| `FluentDb.report()` (query statistics), `FluentDb.dumpReport(...)` | `FluentDb.queryStats()` | — | 2.0.0 | `dumpReport(` | the 1.x statistics `FluentDb.report()` → `debugPrint('${FluentDb.queryStats()}')` (in 2.0 `FluentDb.report()` is the issue report, `FluentReport`, see below); `dumpReport(key, 't')` → `FluentDb.queryStats(dbKey: key, table: 't')` |
| `FluentErrorCode.pauseTimeout` | — | — | 2.0.0 | `pauseTimeout` | remove the branch (a long pause is resumed with a warning) |
| `ExecutionPolicy(timeout:)`, `chunkSize` | — | — | 2.0.0 | `timeout:` | remove it (a started operation is never abandoned) |
| `FluentEngineConfig(analyzeInterval:)` | — | — | 2.0.0 | `analyzeInterval:` | remove it (`optimizeInterval` runs `PRAGMA optimize`) |
| `FluentDb.init(isDev:)` | `FluentGroup(resetOnSchemaError: true)` | — | 2.0.0 | `isDev:` | `init(groups, isDev: true)` → `FluentGroup(..., resetOnSchemaError: true)` (caches only) |
| `FluentDbSummary`, `FluentDbHealthReport` | `FluentDb.engineStats()`, `FluentDb.report()` | — | 2.0.0 | `FluentDbSummary` | → `FluentDb.engineStats()` / `FluentDb.report()` |
| `FluentSyncOptions(sortDirection:)`, `SortDirection`, `TableComplexity`, `ExecutionPolicy.toMap` / `fromMap` | — | — | 2.0.0 | `sortDirection:` | remove it (never had an effect) |
| `String.quotedIdentifier`, `Map.tryGetDateTime`, color getters on `String`, `FluentUtils`, `fluentSqlLiteral` | — | — | 2.0.0 | `quotedIdentifier` | internal helpers, no longer exported: write the SQL through `FluentFilter` / model-level calls |
| `FluentHint` (`title`, `why`, `code`) | `FluentIssue` (`title`, `details`, `fix`, `code`, `kind`, `type`) | — | 2.0.0 | `FluentHint` | `(FluentHint h) => h.why` → `(FluentIssue i) => i.details`; `h.kind == 'index'` → `i.kind == FluentIssueKind.missingIndex` |
| `FluentDb.onHint` | `FluentDb.onIssue(types: {FluentIssueType.hint})` | — | 2.0.0 | `onHint` | `FluentDb.onHint.listen(f)` → `FluentDb.onIssue(types: {FluentIssueType.hint}).listen(f)` |
| `FluentDb.onAlert`, `FluentSystemAlert` | `FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error})` | — | 2.0.0 | `onAlert(` | slow-query alerts are `missingIndex` / `slowRead` hints; background failures are `error` issues; errors of your calls arrive at the call |
| `FluentDb.optimizationReport()`, `FluentOptimizationReport` | `FluentDb.report()`, `FluentReport` | — | 2.0.0 | `optimizationReport(` | `debugPrint('${FluentDb.optimizationReport()}')` → `debugPrint('${FluentDb.report()}')`; `report.hints` → `report.ofType(FluentIssueType.hint)` / `report.hints(FluentIssueImpact.high)` |
| `setupLogging(hints:)`, `setupLogging(muteHints:)` | `setupLogging(level:)`, `setupLogging(mute:)` | — | 2.0.0 | `muteHints:` | `muteHints: {'unordered:*'}` → `mute: {'unordered:*'}`; `hints: false` → `level: FluentLogLevel.warning` (or `FluentDiagnostics.quiet`) |
| hint key prefix `index:` | `missingIndex:` | — | 2.0.0 | `'index:` | `mute: {'index:app:*'}` → `mute: {'missingIndex:app:*'}` |
| `FluentConfig(analyzeInRelease:)` | `FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true))` | — | 2.0.0 | `analyzeInRelease` | `FluentConfig(analyzeInRelease: true)` → `FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true))` |
| `FluentLogRecord.analyzerHint` | `FluentLogRecord.issue` | — | 2.0.0 | `analyzerHint` | `r.analyzerHint` → `r.issue` (set for every issue, not only hints) |
| `FluentConfig.readConnections` (`int`, default 2) | `int?` (default `null`: 2, or by cores with `FluentTuning.readConnections`) | — | 2.0.0 | `config.readConnections` | reading it: `config.readConnections ?? 2` |
| `FluentErrorCode.cancelled`, `FluentErrorCode.engineReset` | `FluentErrorCode.engineClosed` | — | 2.0.0 | `engineReset` | remove the branches: nothing produces them any more (calls are only dropped when the databases close) |

## Schema

| Old name | New name | Deprecated in | Removed in | Search for | Before → After |
|---|---|---|---|---|---|
| `FluentDbMigration` without `version` / `id` | `FluentDbMigration(id: ...)` | — | 2.0.0 | `FluentDbMigration(` | `FluentDbMigration(rawSql: [...])` → `FluentDbMigration(id: 'fill_status', rawSql: [...])` (steps without a label are skipped with a warning) |
| `FluentDbMigration(columns: [...])` | `oldName` / the column in the model | — | 2.0.0 | `FluentDbMigration(columns:` | `FluentDbMigration(columns: [FluentDbColumn.text('title', oldName: 'name')])` → `FluentDbColumn(name: 'title', type: FluentDbDataType.text, oldName: 'name')` in `missingColumns` / `tableSchema` (the model is the only place for columns) |
| `defaultValue` as SQL text | `defaultValue` as a Dart value | — | 2.0.0 | `defaultValue: "'` | `defaultValue: "'active'"` → `defaultValue: 'active'`; `defaultValue: 'CURRENT_TIMESTAMP'` → `defaultValue: FluentSqlExpression.currentTimestamp` |
| mutable `FluentDbColumn` fields | `copyWith` | — | 2.0.0 | `column.isNotNull =` | `c.isNotNull = true` → `c = c.copyWith(isNotNull: true)` |

## Behaviour changes

These compile unchanged but act differently; check the code that depends on them.

* Expired rows are hidden from **every** read unless `includeExpired: true`.
* `syncWithServer` pushes in batches of 500 by default (`batchSize: null` sends everything at once), in key order.
* `deletedKeys` (push and pull) are server keys (`FluentTableConfig.serverKey`, else the primary key).
* `watchRemote` emits the stored rows (read back with `where` / `orderBy` / `limit`), not the raw answer, and keeps
  watching by default (`keepWatching: true`); expired rows are shown by default (`includeExpired: true`).
* Reads never return soft-deleted rows (`findAll`, `findById`, `exists` did); use `p.trash.find()` (only the trash) or `p.withTrash.find()` / `findById` / `count` (both).
* `save` never changes the soft-delete state; `upsert` of a key that is in the trash restores the row.
* `patch` / `updateOnly` skip rows that do not exist (and rows in the trash).
* Removed model fields are archived instead of dropped; `deleted_at` and `FluentDbColumn.timestamp` are INTEGER
  (tables are rebuilt once, automatically).
* Rows a new constraint rejects are moved to `__fluent_rejected_<table>_r<rev>` instead of failing the start.
* `dropColumns` of a column that is still in the model keeps it (with a warning); before, the column was removed from
  the schema and later writes to it were silently lost.
* Model fields that hold other stored models (`List<Post> posts`, `Person? author` in `buildJson`) become relations
  without a declaration (`FluentConfig(autoRelations: false)` turns that off). Before, a list was stored as a JSON
  column and a single model failed the start.
* `orderBy` may only name columns (with `ASC` / `DESC`, `COLLATE`, `NULLS FIRST` / `LAST`, a function of one column);
  other SQL (`CASE`, sub-queries) fails with `FluentArgumentException` — use `rawQuery` for it.
* A database whose `init` fails closes the other databases opened by the same `init` call.
* `clearTable` / `FluentDb.clear` of a synced table reset its pull position: the next pull has `since == null`.
* `watch` also re-runs for changes of deeper relation levels and when a shown row expires.
* Steps are only marked as applied when their table is created; a step that inserts rows gets a `stepOnNewTable` hint.
* Errors are logged once as warnings when your code receives them; SQL arguments are hidden in logs (`showSqlArguments`).
* A model type registered for several tables can no longer be found by type (`ambiguousProvider`): call its provider.
* Relations load one level deep by default (`lazy: true` or `relations: FluentLoad.none` to opt out).
* Change events of a hard delete report `FluentChangeKind.delete` like a soft delete; events of `clearTable` /
  `FluentDb.clear` report `FluentChangeKind.clear`.
* With `FluentClock.testNow` set, reads compare expiry with the test clock, not SQLite's.
* Library warnings are `FluentIssue`s: each one once per run (not on every call), with a `kind` you can mute. The pause
  watchdog, isolate / read-pool / full-text fallbacks, archived columns and quarantined rows are reported as `autoFix`
  (log level `autoFix`, between `hint` and `warning`) instead of `warning`.
* Slow-read hints need an average of ≥ 100 ms over 3 runs (before: one read ≥ 300 ms); slow writes ≥ 500 ms (before 1 s).
* `findMaps` returns Dart values (`DateTime`, enums, `bool`, lists) instead of stored values; `rawQuery` still returns
  stored values.
* Filter values are stored like their column when the query runs (converter, enum by index with
  `storeEnumsAsNames: false`, `dateTimeFormat: iso8601`); before, they always used the default settings.
* `contains` / `startsWith` / `endsWith` escape `%`, `_` and `\` (use `like` for wildcards).
* `rawQuery` refuses SQL that writes (`WITH … DELETE`, `PRAGMA x = …`, several statements): use `execute`.
* `aggregate(orderBy:)` names group columns or value names only.
* `watch` with `offset`, or with relations to its own table, re-runs on every change of the table.
* The save strategy and `conflictOn` apply to the models you pass; related models are always upserted (before,
  `update(withRelations: true)` dropped new children and cleared references to new models).
* `conflictOn` matches rows in the trash like a key does (restored by `upsert` / `insertOnly`) instead of adding a
  second row; a server write updates the trashed row in place.
* `updateById` / `updateWhere` refuse library columns (soft delete, sync versions, expiry, metadata).
* After `delete`, `model.deletedAt` is the stamp stored (only rows that exist; a trashed row keeps its first stamp).
* Each call inside `FluentDb.transaction` is atomic (a savepoint): a caught error leaves none of its rows.
* `FluentDb.close` lets queued calls run for up to 5 seconds, then fails the ones still waiting; running calls are never abandoned; queued calls of a paused queue fail at once.
* A global `resumeQueue()` also ends database pauses.
* Adjacent saves of the same key are no longer merged: each call gets its own outcome.
* Hints and warnings are shown once per issue key (titles that differ only by a number count as one).
* A table adopted from an older database is rebuilt once when its rules differ from the model.
* `purgeArchivedColumns` runs as a queued write; `schemaReport` never creates tables.
* `init`, `close`, `restart` and `deleteDatabases` run one after another; concurrent `init` calls share one start.
* An auto one-to-one pair keeps the table that stored its key; a `one` + owned list over one column share one delete
  rule (the declared one, else `setNull`).
* `watchRemote(store: replace)` keeps rows with unsent local changes; `syncWithServer` calls on one provider never
  overlap; a merge result never overwrites an edit made while the callback ran.
* `FluentKey({})` throws `FluentArgumentException` (was `ArgumentError`).
* `aggregate(having:)` refuses related / search / ids conditions (`FluentArgumentException`): put them in `where`.
* Default names keep existing underscores: a relation named `main_author` uses `main_author_id` (was `main__author_id`).
* Providers are equal by instance (was: by class, database and table); two providers of one table in a group throw.
* `keyFilter(null)` throws `FluentArgumentException` for simple keys (like `keysFilter`).
* `FluentGroup.copyWith` / `FluentDbColumn.copyWith`: passing `null` clears a nullable field (was: kept it); leave
  the argument out to keep it.
* A filter value of a converter's Dart type that the converter fails on throws `FluentArgumentException` (was: the
  raw value was used); `FluentConverter.acceptsValue` tells the two apart.
* `findPage(orderBy:)` refuses the expiry, sync and internal columns before reading.
* A plain id given for a composite key in relations throws `FluentArgumentException` (was: filled the first column).
* `deleteDatabases(reopen: false)` forgets the deleted groups: a later `restart()` no longer recreates them.
* Auto list relations whose child has a `<owner>_id` column resolve to `many` even when another model lists the same
  type (was: `manyToMany`).
* A key column that references another table (one-to-one on the shared key) gets a table-level `FOREIGN KEY`; the
  table is rebuilt once.
* Saving a `double` NaN throws `FluentArgumentException` (`unsupportedValue`) (was: stored as NULL).
* A `RegExp` with non-default flags is stored with its flags (tag `regexp_flags`); older versions cannot read those.
* A stored enum value the enum no longer has: a nullable column reads `null` with a `mappingValue` warning, a NOT NULL
  column throws `FluentSchemaException` (was: every read of the table threw). `FluentEnumConverter(nullIfUnknown:)`.
* A stored value a codec cannot read throws `FluentSchemaException` naming the column (was: an untyped error).
* `buildJson` wins over the generated key the library kept (a key changed after the first save is used); a key a
  `conflictOn` save replaced wins until the model's own key changes.
* `FluentLogRecord.error` / `FluentIssue.error` of an error that is not a `FluentException` is a `FluentRedactedError`
  unless `FluentLog.showSqlArguments` is on; redaction hides everything after `args [`.
* Log timestamps follow `FluentClock`; the leading-`LIKE` hint is judged by the average of `minSamples` runs.
* `FluentTestDb.plan` leaves another open test database open (was: reset the registry under it).
* A list and a back-reference named like its owner delete the children with the owner (CASCADE; was: SET NULL);
  existing tables are rebuilt once. Declare `onDelete` on the reference to keep SET NULL.
* `cleanupOrphans` leaves dangling rows of `RESTRICT` links alone (`danglingReferences` warning).
* Moving links into an owned column keeps a child's existing other owner (`relationChanged` warning).
* A pull / `watchRemote` store never restores a row whose local deletion is not pushed yet (a conflict: `keepServer`
  restores it and drops the deletion). Pulled `createdAt` / `updatedAt` are kept.
* `FluentSyncResult.rejected` / `pushed` count only keys of the batch; `watchRemote` `cancel()` returns at once;
  `syncWithServer` called from its own callbacks returns a failed result (was: waited forever).
* `save(conflictOn:)` gives the model the key of the matched row.
* `findPage(orderBy:)` refuses columns `buildJson` does not write before reading; negative `limit` / `offset` throw
  `FluentArgumentException`.
* `FluentWithTrash.pluck` / `countDistinct` added. `clearTable` on a synced table reports `unsentChangesDiscarded`.
* Provider calls (also on unregistered providers) and `FluentDb.trash` / `withTrash` report every error through the
  returned Future / Stream (was: some threw at the call).
* `FluentFilter.deferred` / `relatedMarker` are no longer public. `FluentFilter.ids` takes at most 900 keys (fewer for
  composite keys): use `findByIds` for longer lists. Fewer arguments than `?` throws `FluentArgumentException`.
* `trash.find(relations:)` / `withTrash` load related rows with the relation's own visibility; `includeDeleted`
  relations show their trashed children. A failing limited relation read is reported (`relationLoadFailed`).
* Two migration steps with the same label throw `FluentSchemaException` (`schemaConflict`) at start (was: the second
  was skipped). A pending step's `dropColumns` stay readable in that step. A model index never adopts or replaces an
  app index of the same name (`indexSkipped`). `customSql` rules of added columns count like flags. Without FTS5 /
  FTS4 an existing full-text index is dropped (`fullTextFallback`). A second quarantine table is `..._r<rev>_<n>`.
* One provider instance in two groups throws `FluentConfigException` at `init` / `planMigrations`.
* `deleteDatabases` keeps read-only files; a file that cannot be deleted makes `reopen: true` throw
  `FluentConfigException` and `reopen: false` report `fileDeleteFailed`. `resetOnSchemaError` is ignored for in-memory
  groups. `planMigrations` returns an empty plan for read-only file groups. Paths are logged only with
  `showSqlArguments`.
* A nested `FluentDb.transaction` runs in a savepoint (was: its writes were committed with the outer one even when it
  threw). `FluentDb.clear()` throws typed errors, also on a closed / missing database (was: logged success).
  `FluentEngineStats.completed` counts finished tasks. Collapsed `findMaps` calls get their own maps.
* Names derived from type and relation names follow a new rule: `HTTPAuthor` → `http_author` (was `h_t_t_p_author`),
  `Item2` → `item2` (was `item_2`), `Box<Note>` → `box_note` (was `box_<_note_>`), `userID` → `user_id`. The first
  start renames a 1.x table, its reference columns, link tables and link columns, and polymorphic `*_type` values to
  the new names (`legacyNameAdopted`, a `renameTable` change in the plan); data and relations are kept. A table that
  exists under both names is not renamed (`schemaFallback` warning). Raw SQL that names such tables must use the new
  names; set `tableName` / `foreignKey` to keep any name you want.
* A saved `DateTime` with microseconds in the timestamp format is reported once per column (`precisionLost`); the
  value is still stored in milliseconds.
* `FluentProvider.policy` is documented as the default of the table's calls (call → provider → `FluentConfig.defaultPolicy`).
* A converter on a key column (e.g. String ↔ String encryption) is applied once: saves, upserts, `conflictOn`,
  updates, deletes, relations, soft delete / restore and sync work with it (before: the key was converted twice).
  With a converted key, `deletedKeys`, tombstones and `FluentSyncBatch.versions` carry the Dart key.
* New `FluentBatchKeys` / `batchKeys` setting (`FluentConfig`, `FluentDbConfig`, `FluentTableConfig`): merged
  `findById` lookups read the keys from the stored rows (`fromRows`, default; no `buildJson` per model) or from the
  models (`fromModels`, slower). A row that matches no requested key is looked up call by call (`batchKeysMismatch`).
* Keys are matched by the column's stored form (save / sync / trash paths): `1` and `'1'` match in TEXT and INTEGER
  columns, `'01'` matches `1` only in INTEGER columns, `null` never matches the text `'null'`.
* `watchRemote` takes `fetchPage: (FluentRemoteRequest r) => ...` for paged answers (`FluentRemoteResponse.hasMore`,
  `cursor`); `fetch:` is optional now (existing code is unchanged). `mirror` / `replace` delete only after the last
  page; a failing page keeps the pages stored so far. `store: mirror` reads the local keys in pages of 500.
* A table rebuild reports app triggers that no longer fit the table (`brokenTrigger`); they are kept.
* Switching `enableForeignKeys` from off to on checks and cleans dangling rows at that start. The first start after
  the upgrade runs one full schema sync (the fingerprint includes the foreign-key setting).
* `FluentDb.schemaReport()` is queued like a write (after earlier calls, before later ones).
* `FluentDb.close` / `restart` / `deleteDatabases` and `FluentEngine.shutdown` called inside a transaction or a task
  are ignored with an `ignoredCall` warning (was: they waited for themselves).
* Background mapping (`isolateFactory`) tries the isolate again after a failure (after 2 batches, doubling up to
  64) instead of staying off until the restart (`isolateFallback`).
* The query plan behind index hints runs as a background read through the queue (debug / profile only).
* `syncWithServer(cancel: FluentCancelToken())` stops a running sync (`token.cancel()`): an answer still on its way
  is ignored, no further batch / page is asked for, stored batches and pages stay, an unfinished pull keeps its
  `since`. The result has `isCancelled: true` (`FluentCancelledException`, code `syncCancelled`); it is not retried and
  not logged as a failure.
* A model of the wrong type in a relation (a list, a reference, `attach`) is skipped with a `relationValue` warning
  (was: a raw `TypeError`); the owner and the other related models are saved.
* `FluentStorable.toString` prints the key value (`key: 3`) instead of the key column definition.
* The `polling` hint measures the gap from the last identical read seen: a sustained rebuild storm (reads closer than
  200 ms) never counts as polling.
* A relation whose select returns something that is not a model (a `one`, a `oneOf`, or non-models inside a list) is
  reported once per run as `relationValue` (was: a `one` / `oneOf` was ignored silently); the item is still saved.
* `FluentIssueKind.eventFailed` is removed: a change event cannot fail to publish (a listener that throws reports to
  its own zone).
* `FluentDb.init(groups)` and `FluentDb.planMigrations(groups)` without `config:` keep the settings in use (the last
  `FluentDb.configure` / `init(config:)`); they no longer reset to the defaults. Pass `config: const FluentConfig()` to
  reset on purpose.
* `updateById` / `updateWhere` skip expired rows like `findById` does; pass `includeExpired: true` to update them too
  (their expiry stays). `update`, `updateAll` and `patch` skip expired rows; `insertOnly` writes a new row over one;
  `upsert` renews it.
* `setupLogging(onRecord: null)` keeps the sink set earlier; remove it with `setupLogging(removeOnRecord: true)`
  (`FluentLog.configure(removeOnRecord: true)`). Paths in messages show as `<path hidden>` unless `showSqlArguments`.
* The soft-delete stamp `deleted_at` is always epoch milliseconds; stamps stored as ISO text are converted once at start
  (`storedFormatAdopted`). ISO-8601 text written by the library has six fraction digits; older three-digit values are
  padded once at start. Code or SQL that reads those columns directly sees the new forms.
* `deletedAt` of a model changes after the commit for `delete` and `restore` (like `save`), not right after the call.
* A save no longer removes relation children / links it cannot judge: relations with `limit`, trashed or expired rows,
  and relations the model was read without (`unloadedRelations`) keep their rows.
* A zero or negative `trashPurgeInterval`, `optimizeInterval`, `pauseWatchdog` or `transactionWatchdog` falls back to the
  default (`configFallback`); `null` still switches the timer off.
* `fluent_sqflite_test` resets logging after every test: call `setupLogging` in `setUp` or in the test, not `setUpAll`.
