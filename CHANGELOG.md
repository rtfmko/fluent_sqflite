## 2.0.0-dev.1 (pre-release for testing)

**Note: This release has breaking changes.** Every rename and removal is listed in `doc/ai/migrations.md`.

Plugin now requires the following:

* Dart SDK `>=3.12.0` and Flutter `>=3.44.0`.
* `sqflite: ^2.4.5` (on Android, `sqflite_android` 2.4.5 needs Android Gradle Plugin 9.0 or newer).
* `path: ^1.9.0`.
* The package no longer has native code of its own (the `android/`, `ios/` and `macos/` plugin folders are gone);
  sqflite brings the native part.

### ✨ New

* **Relations without declarations:** fields of `buildJson` that hold other stored models (`List<Post> posts`,
  `Profile? profile`, with a typed value in the sample) become relations; the kind is decided from both sides
  (one-to-many, many-to-many, one-to-one with a single key column) and listed in one `autoRelations` hint with the
  declarations to copy. `FluentConfig` / `FluentDbConfig` / `FluentTableConfig.autoRelations` turns it off.
* **`FluentRelation.through<P, L, C>`:** many-to-many with data on the link (a `Membership` with a role); read-only
  list, `attach(..., link: (g) => Membership(role: 'admin'))`, `detach` through the link model (trash, sync).
* **`FluentRelation.oneOf<P>(types: [...])`:** polymorphic references (`target_type` + `target_id`), owner lists with
  `many(..., via: 'target')`; deletes, the trash and restore cascade like owned lists.
* **Migrations keep relation data:** a relation that changes its kind between versions copies its links; link tables of
  a new shape are rebuilt with their links; unused link tables are reported, never dropped.
* **Faster start:** an unchanged schema costs three reads (fingerprints per table) instead of a write transaction with
  several statements per table; removed columns are archived / dropped in place when SQLite can.
* **`FluentDb.planMigrations(groups)`:** what `init` would change, without changing it: typed `FluentSchemaChange`s,
  the issues it would report, `losesData`, `rebuilds`. `FluentGroup(onMigrationPlan:)` can refuse a start
  (`migrationRefused`); `FluentTestDb.plan` in `fluent_sqflite_test`.
* `oneOf` references to models with composite keys; `FluentFilter.related<R>('target', ...)` on a `oneOf` reference
  (any type, or the type `R`).
* Agent docs: new `fluent-sqflite-setup` skill (init, groups, all settings levels and SQLite pragmas, diagnostics and
  tuner, priorities, pause / resume, lifecycle); the other skills, `llms.txt`, the rules and the AGENTS.md snippet
  cover relations found in `buildJson`, `through`, `oneOf`, migration plans, `orderBy`, column types and converters.
  `docs_test` fails when a public type is not mentioned in the agent docs.
* Fixed in the second audit pass: adjacent saves with different `relationSync` were merged (preserveLocal lost);
  `FluentDb.clear` hung on errors and failed on RESTRICT rules; `clearTable` / `clear` kept the pull cursor; `watch`
  followed only the first relation level and never dropped expired rows; a running sync answered calls for other
  rows; `watchRemote(store: mirror)` is one transaction and compares date / enum server keys correctly; `save` of a
  subclass held in a base-type variable uses the subclass's table. New hint `pullClock`.
* Fixed in the final audit: a column archived without a rebuild kept its `ON DELETE CASCADE` reference (deleting the
  old owner deleted rows); a refused `onMigrationPlan` no longer triggers `resetOnSchemaError`; fields holding models
  are reported when `autoRelations` is off; the `autoRelations` hint copies the exact declaration; a failing `init`
  closes the databases it opened; `planMigrations` reports a failing step in `plan.failure`; a table changed outside
  the library is synchronized again.
* New schema issues with copy-paste fixes: `possibleRename`, `columnTypeChanged`, `columnRestorable`, `stepOnNewTable`.
* Fixed in the full project audit (2026-11-03), each with a regression test (`test/*/*_fixes*_test.dart`):
  * reads: identical-looking reads with different `ids` / `search` / `related` values shared one result; filter values
    ignored column converters, enums stored by index and ISO dates; `aggregate(orderBy:)` was not checked; `rawQuery`
    ran `WITH … DELETE` and writing PRAGMAs; LIKE helpers treated `%` / `_` as wildcards; `watch` missed changes in
    front of an `offset` window and of children in its own table, and kept querying after cancel; `findByIds` and
    relation loads were not chunked (lists over the SQLite variable limit came back unloaded);
  * writes: `update(withRelations: true)` / `updateOnly` dropped new children and cleared references; deep tombstone
    cascades failed with "no such column"; emptying the trash left no tombstones for cascaded children; the same new
    model twice in one save lost its links or deleted itself; `oneOf` rows kept pointing at rows removed by a cascade;
    `conflictOn` added a second row next to a trashed one; long owned / link lists overflowed the variable limit; a
    caught error inside a transaction committed half a batch (savepoints now); library columns could be updated;
  * schema: a rebuild into `NOT NULL` with a default failed every start; tables from older databases never got the
    model's constraints and archived columns kept `NOT NULL`; `purgeArchivedColumns` ran outside the queue with foreign
    keys off and broke the full-text index; concurrent `init` registered providers twice; app indexes named `idx_…`
    were lost on rebuild; rebuilds reset `AUTOINCREMENT`; read-only files ignored their full-text index; quarantine
    failed for a changed key; lost views / triggers did not count in `losesData` (`viewOrTriggerLost`);
  * relations: an auto one-to-one pair switched its key table when an unrelated relation was added; a shared column
    acted on `cascade` while SQL said `SET NULL`; relation `where`s with deferred conditions failed in many-to-many
    loads and `countRelated`; `countRelated` counted hidden rows and loaded every link row;
  * sync: `watchRemote(store: replace)` overwrote unsent edits; a push answer for a row edited meanwhile lost its server
    key (duplicates on the server); a delete during the first push was never sent; concurrent `syncWithServer` calls
    ran together; a merge result overwrote an edit made during the callback; `watchRemote` retried after cancel;
  * engine: code left running after a transaction used the closed transaction; writes started from a read task ran on
    the read-only connection (automatic indexes failed with a read pool); merged saves of one key lost a patch;
    `close` abandoned running calls; a global `resumeQueue` left database pauses waiting; background reads could
    starve; the page cache stayed small after memory pressure; warnings with counts in their title repeated.
* First audit (now in `FIXED_ISSUES.md`) worked through, with regression tests in `test/regressions/known_bugs_test.dart`:
  a save whose `buildJson` throws no longer blocks the queue of its database; read keys of values without their own
  `toString` no longer collide; `FluentKey` hashes ignore the column order; a model without `primaryKeys` uses its
  `id` column as the key; providers are equal by instance (group membership survives `setDbName`, two providers of
  one table fail clearly); link table rebuilds never drop links (the old table is kept aside under a free name);
  full-text indexes are rebuilt after `VACUUM` on tables without INTEGER key; archives the snapshot does not know
  survive a rebuild; a damaged schema snapshot no longer stops the start (steps never run twice);
  `resetOnSchemaError` never deletes a busy / locked or read-only file; `deleteDatabases(reopen: false)` is not undone
  by `restart`; a failure while starting the engine closes what was opened; `restart(update:)` callback errors leave
  the databases open; `planMigrations` is serialized; the bookkeeping after a committed write never runs the calls
  again; a read connection a running read borrows is closed after the read; factory errors of any type arrive as
  `FluentSchemaException` and no longer switch isolate mapping off; composite key columns keep their value kind;
  unmodifiable `buildJson` maps save; a filter value the converter fails on throws instead of matching wrong rows;
  `findPage` refuses columns the model does not carry before reading; model changes of a save (`deletedAt`) wait for
  the commit, and rolled-back savepoints publish no events; a plain id for a composite key is refused instead of
  filling one column; auto list relations with their own column on the child stay `many` when another model lists the
  same type; self-`through` relations without `parentVia` / `childVia`, failing `buildJson` of samples and own
  `REFERENCES` with another delete rule are reported; a key column referencing another table gets a `FOREIGN KEY`;
  relation `limit` is applied by SQLite per owner (`ROW_NUMBER`, SQLite 3.25+); with foreign keys off a hard delete
  checks only the links to its table; corrupt stored JSON is reported; locales keep script and region;
  `FluentEpochDateTimeConverter(utc: true)`; SQL arguments are hidden anywhere in log texts, also for `onRecord`;
  the tuner shares one automatic index between read shapes, forgets unmeasured checks after an hour and never
  reports a drop it did not do; retry delays are capped (`fluentMaxRetryDelay`); `copyWith` of `FluentGroup` /
  `FluentDbColumn` clears nullable fields with `null`; `FluentDbKey(name)` keys compare by name; raw SQL writes are
  found after comments and behind `WITH`; `orderBy` accepts `""`-escaped identifiers; maintenance skips read-only
  databases; tables and columns whose names hold a quote, a space or a dash save, read, delete, link and sync (sqflite's
  own helpers quote only keywords).
* Tests by component (`test/engine`, `test/db`, `test/provider/{crud,mapping,relations,schema,sync}`, `test/models`,
  ...), coverage from 89 % to about 99 %: wrong-typed relation values no longer throw a raw `TypeError` (skipped with
  `relationValue`), the analyzer's query plan no longer hangs when it fails, the `polling` hint ignores rebuild storms,
  `FluentStorable.toString` prints the key; relation selects that return a non-model are reported; dead code removed.
* Remaining limits removed (round 3, tests in `test/*/…_round3_test.dart`): names derived from type names follow a word
  rule (`HTTPAuthor` → `http_author`, `Item2` → `item2`, `Box<Note>` → `box_note`) and 1.x databases are renamed at
  start with their data; cut microseconds are reported (`precisionLost`); converters on key columns are applied once
  everywhere (encrypted keys work); keys match by the column's stored form; merged lookups read keys from rows
  (`FluentBatchKeys`); `watchRemote(fetchPage:)` pages server answers and `mirror` compares in pages; app triggers
  broken by a rebuild are reported (`brokenTrigger`); switching foreign keys on cleans dangling rows at once;
  `schemaReport` and the analyzer's query plans run through the queue; `close` / `restart` / `shutdown` inside a
  transaction no longer hang; background mapping retries after a failure; observer / tuner hooks can never break a
  task; the benchmark package measures queue, save, relation loads and deletes (`FluentBenchmark.runScenarios`);
  `syncWithServer(cancel: FluentCancelToken())` stops a running sync (`isCancelled`).
* Second audit worked through, with regression tests in `test/*/…_audit_probes_test.dart` and
  `test/*/…_audit_fixes_test.dart`: limited relation lists without `orderBy` load again (regression of the window read); `includeDeleted`
  relations show trashed children; trash scopes no longer leak into relation loads; pulls never restore a row deleted
  locally whose deletion is not pushed; one provider in two groups is refused; customSql `NOT NULL` / `UNIQUE` on an
  added column no longer fails the start; nested transactions use savepoints; `conflictOn` saves give the model the
  matched key; unknown stored enum values and bad stored data no longer break every read; `deleteDatabases` keeps
  read-only files and fails loudly when a file stays; SQL arguments no longer leak through multi-line or `]` values
  or through `FluentLogRecord.error` (`FluentRedactedError`); `dropColumns` of a step stay readable in that step;
  duplicate step labels, NaN values, negative limits, `FluentFilter.ids` over 900 keys and too few filter arguments
  fail with typed errors; app indexes of the same name are never replaced; FTS indexes are dropped where no FTS
  module exists; every provider call reports errors through its Future / Stream; `FluentWithTrash.pluck` /
  `countDistinct`; plus about forty smaller fixes (see `doc/ai/migrations.md`).
* Code comments reviewed against the code (every public member: what it does, defaults, errors, a checked example).
  Fixed on the way: concurrent `syncWithServer` calls with different `ids` / `search` / `related` filters shared one
  run, and `watchRemote(maxAge:)` shared one fetch time between such filters; a server write into a trashed row reset
  the models' `deletedAt`; `countRelated` of a `one` ignored the relation's `where`; `having` with related / search /
  ids conditions sent markers to SQL (now `FluentArgumentException`); `watchById` with a key that does not fit threw
  instead of a stream error; `FluentKey({})` threw a raw `ArgumentError`; `toSnakeCase` doubled existing
  underscores; `FluentDb.clear` reported success for a closed database; task descriptions in logs showed SQL
  arguments.

* `FluentUpdate.increment` / `decrement` / `now` / `toggle` in `updateById` / `updateWhere`: computed by SQLite in the same
  statement (atomic counters, no lost updates). `existsWhere(filter)` on the provider and `FluentDb` (first row is enough).
* Engine and CRUD hot paths: model facts (soft-delete / expiry / timestamp columns) read once instead of building a
  model sample per call; task fingerprints, weights and cost keys computed lazily once; debug lines built only when
  debug is on (saves called `buildJson` twice per model); the scheduler picks the next reads without sorting the whole
  queue and groups lookups in one pass.

* **Issues:** everything the library tells you besides the errors of your calls is a `FluentIssue` — `hint`, `autoFix`
  (a change the library made by itself), `warning`, `error` (background failures) — with a stable `FluentIssueKind`,
  `title`, `details`, `fix`, `code` and a mutable `key`. `FluentDb.onIssue(types:, kinds:)` routes them (e.g. only
  warnings and errors to Crashlytics), `FluentDb.report()` groups them (hints by impact, automatic changes, warnings,
  errors), `setupLogging(mute:)` drops any of them. All kinds are documented in `doc/ai/issues.md`.
* **Diagnostics in one place:** `FluentDiagnostics` (`FluentConfig.diagnostics`, per database `FluentDbConfig.diagnostics`)
  switches the cost model, hints (also in release) and the tuner; presets `none`, `quiet`, `recommend` (default), `auto`.
* **Tuner** (`FluentDiagnostics.auto`, every lever switchable in `FluentTuning`): automatic indexes for slow reads
  (checked, dropped when they do not help, capped), read pool by cores, memory pressure, background maintenance, WAL
  checkpoints, frame budget by refresh rate. Every change is reported (`tuned`) and taken back when it fails or does not
  help (`tuningReverted`).

* `findRelated<R>(name, where:, orderBy:, limit:)`, `findParents<P>(via:)`, `findByIds`, `FluentFilter.ids`,
  `model.loadRelations()`, `isDeleted`, calls on the model for relations and the trash (`article.attach(...)`,
  `note.restore()`), `FluentDb.findByIds` / `findRelated` / `findParents`.
* **Separate packages for tests and measuring:** `fluent_sqflite_test` (`setUpFluentTests`, `FluentTestDb` in memory or
  persistent with `restart`, `db.clock` to move time, `db.settle()` for streams, `db.issues` / `failOnWarnings`) and
  `fluent_sqflite_benchmark` (`FluentBenchmark`, was `package:fluent_sqflite/benchmark.dart`).
* `FluentClock.testNow` also moves the expiry check of reads.
* **Trash as its own API** (soft-delete models only): `provider.trash` (`find`, `count`, `watch`, `restore`, `restoreById`,
  `restoreWhere`, `deleteForever`, `deleteForeverById`, `deleteForeverWhere`, `empty`) and `provider.withTrash` (reads,
  aggregates, search and watches that also see trashed rows); `FluentDb.trash<T>()` / `withTrash<T>()`, `note.deleteForever()`.
* **`watchRemote`** (replaces `reactiveSync`): cache → server → cache in one stream of `FluentRemoteEvent`s (`cached`,
  `fetching`, `fresh`, `failed`; `items` are always the rows to show, read back after storing). Flat parameters instead
  of `FluentSyncOptions`: `store` (`merge` / `mirror` / `replace` / `none`), `source` (`cacheThenRemote` / `remoteOnly` /
  `cacheOnly`), `retries`, `retryDelay`, `clearCacheOn`, `maxAge`, `keepWatching` (default on), `includeExpired`.
  `fetch` returns `FluentRemoteResponse` (`(items)`, `.single`, `.failed(status)`).
* **Sync:** `FluentTableConfig.serverKey` (match server rows, deletions and tombstones by the server's own id);
  `FluentPushResult` (`accepted(updated:, rejected:)` / `failed`); paged pulls (`FluentPullRequest.cursor`,
  `FluentPullResult.hasMore` / `cursor`); `conflicts: FluentConflictPolicy.keepLocal / keepServer / merge`;
  `FluentSyncResult.rejected`.

### ⚠️ Breaking changes

* `orderBy` only names columns (`'created_at DESC, id'`, `COLLATE`, `NULLS LAST`, `lower(name)`); other SQL fails with
  `FluentArgumentException`, so a sort order from user input can never inject SQL. Use `rawQuery` for expressions.
* `FluentDbMigration.columns` removed: columns live in the model only (`oldName` on the column renames it).
* `dropColumns` keeps a column that is still in the model (with a warning) instead of dropping it from the schema.
* `FluentRelationType.oneOf` added: exhaustive `switch`es over `FluentRelationType` need a case for it.
* `buildJson` fields holding stored models are relations now (a list was a JSON column, a single model failed the start).

* `FluentErrorCode.cancelled` and `engineReset` removed (nothing produced them); internal dead code removed
  (`cancelTask`, `hardReset`, unused task / helper fields, `FluentDbAction.none` / `readSchema`).

* Diagnostics: `FluentHint` → `FluentIssue`, `onHint` → `onIssue`, `optimizationReport` → `report` (`FluentReport`),
  `setupLogging(hints:, muteHints:)` → `setupLogging(mute:)` (hints follow `level`), `analyzeInRelease` →
  `FluentDiagnostics(hintsInRelease:)`, `FluentLogRecord.analyzerHint` → `issue`, hint kind `index` → `missingIndex`.
  `FluentDb.onAlert` / `FluentSystemAlert` removed (slow queries are hints, background failures `error` issues).
  New log level `autoFix`. One set of thresholds: reads ≥ 100 ms on average over 3 runs, writes ≥ 500 ms, queue wait ≥ 1 s.

* **One public API, the internals hidden.** `package:fluent_sqflite/fluent_sqflite.dart` exports only what apps use;
  the engine, registry, schema sync, row mapping, internal extensions and enums live in `src/internal.dart`. Hidden:
  `FluentProvider.db` / `executor` / `keyFilter` / `keysFilter` / `modelType` / `relationLinks` and the schema / mapping
  helpers, `FluentDb.executeTask`, `FluentDbAction`, `ExecutionPolicy.merge` / `flatten`. Removed as dead code:
  `mapToModel*`, `transformResponseAsync`, `createTable`, `generateCreateTableSql`, `generateIndicesSql`,
  `defaultForeignKey`, `setTableName`, `FluentStorable.clearSchemaCache`.
* **`FluentDb` is static only:** `FluentDb.init`, `FluentDb.close` (was `closeAll`), `FluentDb.restart(update:)`,
  `FluentDb.clear({dbKey})` (was `clearSelectedDatabase` / `clearAllDatabases`), `FluentDb.deleteDatabases({dbKey,
  reopen})` (was `destroyAllDatabases`, `destroyAllDatabasesAndRestart`, `dropDatabase`, `dropAll`),
  `FluentDb.isOpen({dbKey})` (was `isInitialized`, `isDatabaseOpen`, `isModelStorageReady`). Provider lookups:
  `FluentDb.providerOf<T>()` (was `providerByType`) and `FluentDb.provider<P>()`, both with `dbKey:`;
  `getProviderByTable`, `providerByModel`, `providerForType` removed. `cleanOrphans({dbKey})` and
  `forgetQueryStats({dbKey, table})` (was `resetPerformanceStats`) are statics. `toggleLogging` / `isLoggingEnabled`
  removed (`setupLogging(enabled:)`).
* **Relations are declared on the model** (`with FluentRelations`), not on the provider (`FluentRelationsMixin`
  removed). The relation calls exist only for such models; `countOf` → `countRelated`; `ensureLoaded`,
  `getRelation`, `getDynamicValue`, `isFieldLoaded` removed (`loadRelations` returns a loaded copy,
  `isRelationLoaded`).
* **Calls follow the model's mixins:** the trash calls (`provider.trash`, `provider.withTrash`) exist only for
  `FluentSoftDeletable` models (provider, `FluentDb` and model).
* **Reads take `relations: FluentLoad.none / eager / all`** instead of `ignoreLazy`; `maxDepth: 0` no longer means
  unlimited (at most 8). `FluentSyncOptions(ignoreLazy:)` → `watchRemote(relations:)`.
* **Tags:** every write takes `tag:` (provider too); `ExecutionPolicy(customTag:)` removed. `ExecutionPolicy` keeps
  `priority`, `cancelIfDuplicate` and the presets `fast`, `background`, `fresh`.
* **Change events:** `FluentChangeEvent.kind` (`FluentChangeKind`: `save`, `update`, `delete`, `restore`, `clear`)
  replaces `action`; `tag` replaces `customTag`; `onEvent(kinds:)` replaces `actions:`.
* **Expiry:** `FluentStorable.timeToLive` (a `Duration`, per instance or per table) replaces `expiryDate` /
  `expiryDuration`; `fromJsonWithExpiry` removed.
* `reactiveSync` → `watchRemote`: `FluentSyncOptions`, `FluentApiResponse`, `FluentDataEvent` (and its helpers),
  `FluentPipelinePhase`, `FluentDataSource`, `FluentMergeStrategy`, `FluentExecutionStrategy`, `FluentEmptyApiBehavior`,
  `FluentApiErrorBehavior`, `onSuccess` / `onError` / `beforeSave` / `awaitPersistence` / `validStatusCodes` removed
  (see the migration table).
* `syncWithServer`: `onPush` returns `FluentPushResult` (was `bool`), `onPull` takes a `FluentPullRequest` (was
  `since`), `pullConflictOn` → `FluentTableConfig.serverKey`, `onConflict` → `conflicts: FluentConflictPolicy.merge`,
  `batchSize` defaults to 500; `deletedKeys` are server keys. A failed sync is logged once.
* `findMaps` returns Dart values (`DateTime`, enums, `bool`, lists, converted values) instead of stored values.
* **Settings: three levels, the narrower wins.** Global `FluentConfig` (was `FluentEngineConfig`;
  `init(groups, config:)`, `FluentDb.configure` replaces `changeFluentEngineConfig`) → database `FluentDbConfig` (was
  `SQLitePerformanceConfig`; `FluentGroup(config:)` replaces `performanceConfig:`) → table `FluentTableConfig` on the
  model (`FluentStorable.tableConfig`, moved from the provider). `trashRetention`, `indexReferences`, `fullText` exist
  on every level, `readConnections` globally and per database. Removed: `init(purgeDuration:, isDev:)`,
  `FluentDb.softDeleteRetentionPeriod`, `FluentSoftDeletable.softDeleteRetention` (→ `trashRetention`),
  `FluentDb.globalPolicy` (→ `FluentConfig.defaultPolicy`), `maxPauseDuration` / `alertPauseDuration` (→ `pauseWatchdog`,
  resumes with a warning; `FluentErrorCode.pauseTimeout` removed), `saveInterval`, `telemetryRetention`,
  `enableConcurrentReads`, `queueStrategy` / `FluentQueueStrategy`, `FluentDbExecutionStrategy`, `readAgingPerSecond`,
  `bulkImport()` / `readOnlyOptimized()` (`highIntegrity` is a constant), `changeCurrentPerformanceConfig`,
  `FluentTableConfig.sanitizeTypes`.
* **Query stats live in each database** (`__fluent_stats`), not in `fluent_system.db` (deleted at start): written only
  when they changed, while the database is idle, at most every 5 minutes and on close; in-memory / read-only databases
  keep them in memory. `FluentDb.queryStats({dbKey, table})` (`FluentQueryStats`, `FluentQueryCost.averageRows`)
  replaces `FluentDb.report()` / `dumpReport()`.
* Internal helpers are no longer exported: `String.quotedIdentifier` / `quotedIfPlain`, color getters on `String`,
  `Map.tryGetDateTime`, `DateTime.toFluentTimestamp`, `ExecutionPolicy.withTag`, `FluentDbAction.isWriteOp`,
  `FluentUtils`, `fluentSqlLiteral`. Removed as unused: `SortDirection`, `TableComplexity`,
  `FluentSyncOptions.sortDirection`, `ExecutionPolicy.toMap` / `fromMap`.
Every renamed or removed member, with search text and before → after: [doc/ai/migrations.md](doc/ai/migrations.md).

* The package is no longer a Flutter plugin (it had no native code): the `flutter: plugin:` section is removed.
* **Errors: one hierarchy.** Every error is a `FluentException` with `message`, `code` (`FluentErrorCode`, for UI texts
  / localization), `hint` (how to fix it), `cause` (the original error, was `originalError`) and `stackTrace`.
  Classes: `FluentConfigException`, `FluentSchemaException`, `FluentArgumentException`, `FluentConstraintException`,
  `FluentQueryException`, `FluentRelationException`, `FluentSyncException`, `FluentCancelledException`,
  `FluentEngineException`. Removed: `FluentNotInitializedException`, `ProviderNotFoundException`,
  `AmbiguousProviderException`, `FluentDatabaseNameException`, `FluentDatabaseNotFoundException`,
  `FluentConfigurationException` (→ `FluentConfigException` + code), `MigrationFailedException` (→
  `FluentSchemaException`, `migrationFailed`), `InvalidSqlTypeException` (→ `FluentArgumentException`,
  `unsupportedValue`), `FluentSQFLiteException` (→ `FluentQueryException`), `FluentApiException` /
  `FluentSyncableException` (→ `FluentSyncException`), `FluentTaskCancelledException`, `FluentBatchException`,
  `FluentBaseException`. SQLite errors of reads (`rawQuery`, raw filters) are typed too (no raw `DatabaseException`).
* Cancelled calls (`cancelTask`, calls after `closeAll`, `hardReset`) fail with `FluentCancelledException`
  (`cancelled` / `engineClosed` / `engineReset`).
* **Logging reworked.** `FluentDb.setupLogging({level, onRecord, console, colors, showSqlArguments, enabled})`
  replaces `setupLogging(userLogger:, internalLogger:)`, `setupDefault()` / `setupDefaultDebug()`; `FluentTelemetry` and
  `FluentLogger` are removed — `onRecord` receives structured `FluentLogRecord`s (level, message, tag, hint, context,
  error, stackTrace, code). `FluentLogLevel` gained `hint` and is ordered `sql < debug < info < hint < warning < error`.
  Defaults: `info` in debug / profile, `warning` in release; output via `debugPrint`; ANSI colors only on desktop.
  `isLoggingEnable` → `isLoggingEnabled`. `FluentDbSummary` / `FluentDbHealthReport` (unused) removed.
* SQL arguments and database paths are hidden in logs and error texts by default (`showSqlArguments: true` to see them).
* `maxConcurrentReads` removed (one connection runs its statements in turn); use `readConnections`.
* `FluentChangeEvent` carries `table` and `dbName` (required); `FluentEngine.broadcastSystemAction(action, provider)`.
* `FluentEnumConverter<E>` is `FluentConverter<E, Object>` with `byName` (default `true`); reading accepts a name or an index.
* One model type (or provider class) registered for several tables: calls that find the provider by type
  (`FluentDb.find<T>()`, `FluentDb.provider<P>()`, `model.save()`) fail with `ambiguousProvider` + hint instead of
  silently using the last registered provider; relations to such a type are skipped with a hint.
* Sync rewritten: `FluentSyncStrategy` is push / pull / full; `onPush(FluentSyncBatch)` (changed, deleted,
  deletedKeys), `onPull(since) → FluentPullResult`; `is_synced` / `syncCompleteState` / `markAsSyncedFields` /
  `pushOnlyUnsynced` / raw where strings removed (change tracking is automatic through `sync_version` /
  `synced_version`; existing rows are pushed once). `watchRemote(where:, orderBy:)` replaces
  `localWhere` / `localWhereArgs` / `localFilter` / `localOrderBy`.
* Telemetry: per-table stats replaced by a cost model per query shape (see `FluentDb.queryStats()` above).
* Soft delete: UNIQUE columns of soft-deletable models are partial unique indexes over live rows (tables are rebuilt
  once); `save` of a key in the trash restores the row (outcome `FluentRowOutcome.restored`); updates skip the trash.
* `ExecutionPolicy.timeout` and `ExecutionPolicy.chunkSize` removed (operations are never abandoned once started).
* Calls made after `FluentDb.close()` fail with `FluentCancelledException` (`engineClosed`) until the next `init`.
* Engine: `queueAgingPercentage` / `queueAgingSubtract` and `analyzeInterval` removed (reads age automatically,
  `optimizeInterval` runs `PRAGMA optimize`).
* **Compact CRUD API** (provider, `FluentDb.*<T>` and active record share it): `findById`, `find`, `findFirst`,
  `findAll`, `findDeleted`, `count`, `exists`, `findMaps`, `rawQuery`, `execute`; `save` / `saveAll` (return
  `FluentSaveResult`), `update` / `updateAll` (`withRelations`), `updateById`, `updateWhere`; `delete` / `deleteAll` /
  `deleteById` / `deleteWhere` (`hard: true` for permanent), `restore` / `restoreById` / `restoreWhere`,
  `purgeDeleted({olderThan})`, `clearExpired`, `clearTable`. Removed: `saveItem(s)`, `findOne`, `findItemsBy`,
  `findValidItems`, `findDeletedItems`, `rawGetItemBy(s)`, `hardDelete*`, `deleteBy`, `deleteItemsByIds`, `updateByKey`,
  `updateFieldsMultiple*`, `updateWithRelations`, `updateAllWithRelations`, `updateAndFetch`, `restoreAndFetch*`,
  `restoreAll`, `restoreItemsByIds`, `purgeSoftDeleted`, `forcePurgeSoftDeleted`, `clearExpiredItems`, and the
  `batch` / `sharedBatch` / `executor` / `dbName` parameters of provider methods.
* Filters are `FluentFilter`s (`where:`); raw SQL conditions: `FluentFilter('a = ?', [1])`.
* Expired rows (`timeToLive`) are hidden from every read unless `includeExpired: true`.
* `save` never changes the soft-delete state (it used to restore deleted rows); use `delete` / `restore`.
* No `includeDeleted:` on reads and no `hard:` on deletes: use `withTrash` / `trash.deleteForever*`; `restore*` and
  `purgeDeleted` moved to `trash` (`trash.restore`, `trash.empty`). `delete` of other models is permanent as before.
* `deleted_at` is an INTEGER timestamp (existing tables are rebuilt once; old ISO values keep working).
* `FluentDb.transaction(action, {dbKey})` is static and needs no `modelTypes`.
* `FluentDbAction` lists the new operations (`find`, `findMaps`, `updateFields`, `hardDelete`, `purgeDeleted`, ...).
* **Schema sync v2.** The applied schema is stored per table in `__fluent_schema` (replaces `__fluent_migrations`,
  adopted automatically). Columns removed from a model are **archived** (`__fluent_removed_<name>_r<revision>`)
  instead of being dropped; use `FluentGroup(removedColumns: FluentColumnRemoval.drop)` or a `dropColumns` step to delete.
* One-time migration steps need a `version` or an `id` and run in declaration order (previously sorted by version).
* `FluentDb.init(isDev:)` is gone (it deleted the database file on errors); use `FluentGroup(resetOnSchemaError: true)`.
* `FluentDbColumn.timestamp` is `INTEGER` (was `BLOB`); existing tables are rebuilt once.
* **Relations rewritten.** `FluentDbRelation`, `FluentModelCast`, `FluentDbRelationType`, `FluentRelationUpdateMode`
  are replaced by `FluentRelation<P, C>` with four types (`one`, `oneOwned`, `many`, `manyToMany`), a full constructor
  and shortcuts (`FluentRelation.one/oneOwned/many/manyToMany`). Columns, link tables and delete rules are derived
  automatically; `foreignKey`, `linkTable`, `onDelete`, `lazy`, `keepMissing`, `orderBy`, `where`, `limit`,
  `includeDeleted` are optional overrides. Relations load eagerly one level by default (`lazy: true` to opt out).
* `FluentDbColumn.defaultValue` is an `Object?` written as a plain Dart value and escaped automatically
  (`'active'` → `DEFAULT 'active'`). Use `FluentSqlExpression` for SQL expressions such as `CURRENT_TIMESTAMP`.
* `FluentDbColumn` is immutable; derive changes with `copyWith`.
* `FluentDbMigration.columns` is optional (defaults to `[]`).
* All generated identifiers are quoted, `FluentDbColumn.sqlDefinition` now returns `"name" TYPE ...`.

### Added

* Filters by relations: `FluentFilter.related(name, [where])`, `notRelated`, `relatedCount(min:, max:)`, paths
  (`'author.company'`); every relation type, every read / count / aggregate / `deleteWhere` / `watch`.
* Full-text search: `FluentIndex.fullText([...])`, `provider.search(text)` (ranked with FTS5), `FluentFilter.search`;
  FTS5 with FTS4 fallback, `fullText` setting (`auto` / `fts4` / `off` → `LIKE`).
* Projections and aggregates: `findMaps(columns:, distinct:)`, `pluck<V>`, `sum`, `avg`, `min<V>`, `max<V>`,
  `countDistinct`, `aggregate(groupBy:, values: {...: FluentAggregate.sum(...)}, having:, orderBy:)`; `watchValue`.
* `watchRemote(maxAge:)` skips the fetch while the same query's stored answer is younger.
* `watchSyncStatus()` / `FluentDb.watchSyncStatus<T>()` (`FluentSyncStatus`: `idle` / `syncing` / `failed`, `pending`,
  `lastSyncedAt`, `lastError`); `syncWithServer(retries:, retryDelay:)` with exponential backoff and jitter.
* Schema hints at `init`: enum fields without `enumValues`, redundant indexes, auto-increment keys on synced tables.
* `indexReferences` setting: relation reference columns are indexed (default on); off, a hint appears when a relation
  needs the index.
* **Keyset pagination:** `findPage({orderBy, descending, limit, after})` → `FluentPage<T>` (`items`, `next`,
  `hasMore`); `FluentCursor` (`encode` / `decode`). Pages never repeat or skip rows while rows change.
* A hint (`FluentHint`) for paged reads (`limit` / `offset`) without `orderBy`.
* Filters by keys, also composite (`FluentFilter.ids` since the API review).
* **Documentation:** README, a guide in `doc/`, docs for AI assistants (`llms.txt`, `doc/ai/` with the 1.x → 2.0
  migration table and the error-code reference) and agent skills in `skills/` (`dart run skills@ get -p fluent_sqflite`).
* `example/`: a REST → cache → paged list app with an on-device benchmark screen.
* **Reads that keep the UI smooth.** A pool of read-only WAL connections runs reads in parallel
  (`readConnections`, default 2); big lists are turned into models in slices across frames
  (`FluentConfig.sliceAfterRows` / `frameBudget`); with `FluentProvider.isolateFactory` (a static factory) lists
  are mapped in a background isolate — `isolateMapping` `smart` (default: measured per table, kept across restarts,
  moved when over half a frame, with a hint when the factory is missing) / `always` / `never`.
* `package:fluent_sqflite/benchmark.dart`: `FluentBenchmark.run()` measures parallel reads and UI stalls on a device.
* `FluentGroup(inMemory: true)`: a database without a file (tests, throw-away caches); each group is its own database.
* Schema changes never drop rows: rows a new CHECK / UNIQUE rejects are moved to `__fluent_rejected_<table>_r<rev>` with
  a warning that says how to fix and restore them.
* Analyzer (`FluentAnalyzer`): hints (`FluentHint`: title, why, code to copy, key) printed once per run in debug /
  profile builds, sent to `onRecord` and published on `FluentDb.onHint`. Index advice from `EXPLAIN QUERY PLAN` of slow
  reads; hints for big unpaged reads, deep offsets, `LIKE '%…'`, nested relation loads, slow writes, loops of awaited
  `save` / `findById`, flooded queues, polling (→ `watch`) and long queue waits. `setupLogging(hints:, muteHints:)`;
  `FluentConfig.analyzeInRelease` to collect hints from release builds.
* Sync: conflicts (`onConflict`, local wins by default), remote deletes (`FluentRemoteDeleteBehavior`), tombstones for
  permanent deletes, incremental pulls (`since`), `batchSize`, `pendingChanges()`, `saveAll(relationSync:)`.
* `watchById`; `watch(coalesce:)`; `FluentDb.optimizationReport()` (every hint, `FluentOptimizationReport.hints`);
  `FluentEngineStats.slowestQueries`; `FluentConfig.optimizeInterval` (`PRAGMA optimize`).
* `trashRetention` setting; periodic trash purge
  (`FluentConfig.trashPurgeInterval`); `FluentSaveResult.restored`.
* `FluentConfig.transactionWatchdog` (default 2 s): warns about transactions that block other calls and runs the
  waiting reads inside them, so a transaction awaiting a call made outside it no longer hangs forever.
* `FluentDb.engineStats()` (`FluentEngineStats`): queue, running tasks, waits, collapsed / merged / batched counters.
* Queued `findById` calls of one table are answered by one `IN (...)` query.
* `FluentDb.transaction` works: every call inside uses one SQLite transaction (nested calls join it), change events
  are published after the commit, nothing is published on rollback.
* `saveAll(conflictOn: ['email'])`: match existing rows by unique columns instead of the key (e.g. server ids).
* `FluentSaveResult` (`inserted` / `updated` / `skipped`, per-item `outcomes`).
* `updateWhere(filter, fields)`, `deleteWhere(filter)`, `restoreWhere(filter)`, `findMaps(where: ...)`.
* `watch(...)` / `FluentDb.watch<T>(...)`: live query stream, re-run after changes of the table or its relations.
* `FluentTimestamps` mixin: `createdAt` / `updatedAt` filled by the library.
* Soft delete cascades to owned soft-deletable children; restore brings back those deleted together with the owner.
* `FluentRelation.auto` / `FluentRelationType.auto`: the relation type is decided at init from the whole database
  (select returns a list or a model, declarations on the other side, shared models, `*_id` columns), with `prefer`
  per relation and `FluentGroup.autoRelationFallback` (default `manyToMany`, never deletes shared data).
  Explicit relation types are checked against the select shape.
* Schema sync v2: unchanged models start without any DDL; column renames via `RENAME COLUMN`; type / key / constraint /
  index changes applied with a safe rebuild that keeps data, triggers and views; NOT NULL columns without default
  on existing rows stay nullable until filled; `restoreColumns` steps; content hash warnings for edited steps.
* `FluentGroup.removedColumns`, `archiveRetention` (default 30 days), `historyLimit` (default 100), `resetOnSchemaError`.
* `FluentDb.schemaReport()` (state + `__fluent_schema_history`) and `FluentDb.purgeArchivedColumns(olderThan:)`.
* Relations to and from composite-key tables (multi-column foreign keys and link tables).
* `FluentProvider.rawQuery` / `FluentDb.rawQuery` for read-only SQL returning clean maps.
* Relation operations: `loadRelations`, `countRelated`, `attach`, `detach` (provider, `FluentDb` and model), relation tree in the debug log.
* Composite primary keys: `FluentStorable.primaryKeys`, `FluentKey` value object, `item.key`;
  CRUD by key (`findById(FluentKey({...}))`, `exists`, `update*`, `delete*`, `restore*`), optional `withoutRowId`.
* `FluentIndex` (multi-column, unique, partial) via `FluentStorable.indexes`; indexes are added to existing databases on start.
* Table-level `CHECK` constraints via `FluentStorable.checks`.
* Column options: `collation` (`FluentCollation`), boolean columns guarded by `CHECK (x IN (0, 1))`,
  convenience parameters on `FluentDbColumn.text/integer/real/boolean` factories.
* Column converters: `FluentConverter`, `FluentEnumConverter`, `FluentIsoDateTimeConverter`,
  `FluentEpochDateTimeConverter`, `FluentJsonConverter`, `FluentDbColumn.converted`.
* Versioned one-time migration steps: `FluentDbMigration(version:, rawSql:, dropColumns:, onMigrate:)`,
  tracked in `__fluent_migrations`.
* `FluentGroup.directory` (custom database folder) and `FluentGroup.readOnly`.
* `FluentDbConfig.busyTimeout` (default 5 s).
* `FluentIdentifier` string extension (`quotedIdentifier`, `quotedIfPlain`).

### Fixed

* Reads with `relations: FluentLoad.none` were scheduled as the heaviest reads (depth 0 was weighted as unbounded).
* `FluentDb.clear` documented a cancellation of pending calls it does not do (it is an ordered write).
* The `conflictOn` warning suggested a `FluentIndex` constructor that does not exist.
* SQLite errors were classified by the statement text too (a read-only error of `CREATE TABLE ... PRIMARY KEY` became a
  "UNIQUE violation"); only SQLite's own messages are matched now.
* Sync: owned children removed by the cascade of a permanently deleted owner get tombstones (the server learns about them).
* `watch` of a table no longer re-queries on writes to another table (or database) with the same model type.
* Built-in type conversions live in one table (`FluentTypeCodecs`) for writing and reading; `enumValues` columns use an
  enum converter; rows written by older versions (index, name, per-row tags) still read back.
* Errors are logged once: a failing call of a merged batch is no longer logged twice, errors are not logged again by
  the engine / init / maintenance; the default output prints the cause (and the stack of background errors), which
  was lost before; `setupLogging(level: debug)` works after the first log line; `toggleLogging(false)` prints nothing;
  a failing `onRecord` callback never breaks a database call.
* `FluentDb.*` statics (and the active-record extensions) no longer throw synchronously when no / several providers
  match: the error arrives as a failed future (`watch` / `reactiveSync`: an error event), so `.catchError` sees it.
* Sync: local edits after a push are sent again; edits made during a push are not lost; pulled rows are not sent back;
  `reactiveSync` stores rows beyond the cached page, never wipes unsent changes, reports persistence errors, does not
  retry 4xx; `syncDeletions` does not delete on paged answers; concurrent syncs do not push twice.
* Reactivity: related tables (children, link targets, cascades, foreign-key deletes) publish change events, so their
  `watch` streams update; relation operations run in the engine queue (call order, events); `execute` that changes
  rows publishes an event; `wipeAll` reaches `onEvent<Model>`.
* Soft delete: deleted rows no longer block unique values; the trash view loads the children deleted with an owner;
  restoring a child of a deleted owner no longer creates a visible orphan; the trash has its own index.
* Engine: a read called after a write is never answered by an earlier identical read; `closeAll` lets calls already
  made finish before closing the files (no raw `database_closed` errors) and flushes telemetry; queue cost is linear
  (thousands of unawaited calls); `pauseQueue` inside a transaction no longer hangs; expected errors are not
  reported twice as critical; the telemetry database is opened once, in the configured directory, and closed.
* Engine: operations of a database keep call order around writes (a later read or write never overtakes a write);
  writes are no longer starved by reads; identical reads in flight are collapsed again (each caller gets its own list);
  a failing call in a merged save batch no longer fails the other calls; merged saves publish one event per call.
* Upsert no longer drops a row silently on a conflict with another UNIQUE column (it throws a typed error).
* `FluentSaveStrategy.patch` leaves `null` fields untouched; `insertOnly` / `updateOnly` report skipped rows.
* Soft delete: one stamp format, re-deleting keeps the first stamp, `delete(item)` no longer overwrites the row,
  `deletedAt` is loaded; purge also removes rows stamped by older versions.
* Field updates keep type metadata exact (UTC dates in bulk updates were read back as integers).
* All write errors are typed `Fluent*Exception`s with hints (updates threw raw SQLite errors).
* A key column also listed in `tableSchema` / `buildJson` no longer creates a table without PRIMARY KEY.
* Auto-batched saves keep each call's strategy and results; writes that change nothing publish no event.
* `patch` keeps the type tags of untouched fields and replaces those of patched ones.
* `FluentDb.saveAll` / `updateAll` / `deleteAll` with several model types of one database are atomic.
* `watch` no longer re-runs for saved / deleted rows that are neither shown nor matching.
* Read API: `findAll` / `findOne` / `findById` / `exists` no longer return soft-deleted rows (all reads agree;
  use `findDeletedItems` for the trash). The `FluentDb` facade passes `orderBy` (and `where` for `findValidItems`).
* Serialization: UTC dates keep `isUtc`; rows without type metadata (raw SQL, older versions) are restored from column
  kinds; `bool` / `DateTime` / enum / `Duration` work as query arguments; raw maps no longer contain `_fs_metadata` or
  archived columns; `fromCacheJson` type errors and non-encodable values report the field and a hint.
* Relations: references (`author`, `editor`) are stored on the model instead of overwriting the referenced rows;
  deleting a model no longer deletes unrelated rows; many-to-many links survive auto-increment ids; shared
  instances are saved once; self-references (trees) save and load; reading no longer runs queries per row.
* Table rebuilds (renames / type changes) no longer cascade-delete child rows: foreign keys are switched off
  outside the schema transaction and checked afterwards.
* Provider registry: real per-database indexes (no duplicates, no linear scans); `modelType` is cached.
* SQL keywords (`order`, `group`, ...) can be used as table/column names.
* Primary key auto-correction is actually applied; FK clauses no longer overwrite a column's `customSql`.
* `ExecutionPolicy` value equality; single default chunk size.
* `closeAll()` after a failed `init`; `dropDatabase` path; duplicated invalid-name message.
* A unique index over duplicate data no longer breaks `init` (error with a hint instead).

## 0.0.1

* Initial release.
