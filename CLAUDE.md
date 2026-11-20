# CLAUDE.md

`fluent_sqflite` — a DAO-based ORM on top of `sqflite` for Flutter: automatic schema sync,
migrations, relations, soft delete, streams, and server sync.

## Commands

The Flutter SDK is pinned with FVM (`.fvmrc`, Flutter 3.47.9). The system `dart`
is older than the required SDK (`^3.12.0`, Flutter >= 3.44.0, as sqflite 2.4.5 needs), so always go through FVM:

```bash
fvm flutter pub get
fvm flutter test                                  # all tests (sqflite_common_ffi, no device needed)
fvm flutter test test/provider/crud/write_api_test.dart
fvm dart analyze
(cd packages/fluent_sqflite_test && fvm flutter test)       # the test helpers package
(cd packages/fluent_sqflite_benchmark && fvm flutter test)  # the benchmark package
```

## Architecture

- Public API: `lib/fluent_sqflite.dart` re-exports barrel files (`core.dart`, `models.dart`, ...).
  New public types must be exported from the matching barrel.
- `lib/src/core/fluent_provider` — `FluentProvider<T>`, the per-table DAO, split into `part` files. CRUD:
  `parts/crud/fluent_read.dart` / `fluent_write.dart` / `fluent_remove.dart` / `fluent_watch.dart` (public API, builds
  a `FluentTask` with the final filter), `fluent_execute_crud.dart` (executors), `parts/fluent_crud_helper.dart`
  (visibility, `_writeRows`, soft delete / restore cascade, `_updateFields`, `_sqlError`). The same API is mirrored
  by `FluentDb.*<T>` statics and the active-record extensions in `utils/fluent_extensions.dart`.
- `lib/src/core/fluent_db` — database registry/lifecycle, also split into `parts/`.
- `lib/src/core/fluent_engine` — task execution engine. Scheduling rule:
  the queue is in call order; per database a write is a barrier (starts after all earlier tasks, runs alone, nothing
  later overtakes it); only reads between two writes are reordered (priority, aged weight). Merging (adjacent saves,
  `findById` → `IN`) must never change the order of operations; merged batches fall back to call-by-call on error.
  Adjacent writes that do not merge run as a write group (`_writeGroup`, `_executeWriteGroup`): one transaction, each
  call in its own SAVEPOINT via the provider's write path, callers completed after the commit, run alone when the
  transaction fails; only `_groupableWrites` join. The queue is `_FluentDbQueue` (`fluent_engine_queue.dart`):
  segments, reads indexed by (priority, weight) class — the scheduler never scans every waiting read.
  Queues are per database; read collapsing is keyed by fingerprint + write epoch. Expensive counts are cached by the
  same key (`_countCache`, emptied by every queued write, checked against `PRAGMA data_version` when the task runs:
  never decide anything for a call before it is queued — call order). No timeouts: never abandon a
  started operation. Code inside a task runs in a zone marked `_runningTaskKey` (`pauseQueue` / `shutdown` refuse to
  run from it; `FluentDb.close` / `restart` / `deleteDatabases` are ignored there with `ignoredCall`). Observer, stats
  and tuner hooks are wrapped (`_observe`): they can never stop a task from starting or completing.
  A write that changes other tables (relations, cascades) must call `FluentEngine.touch(provider, action)` so those
  tables publish events. Telemetry (`FluentTableStatsTracker`) is a cost model keyed by query shape (`TableHelper.shape`),
  plus rows returned and per-table mapping cost; kept per database in `__fluent_stats` (written when changed and idle,
  at most every 5 min and on close; in-memory / read-only: memory only).
- Settings: global `FluentConfig` (`init(config:)`, `FluentDb.configure`, read via `FluentEngine().config`) → per database
  `FluentDbConfig` (`FluentGroup.config`, `FluentEngine().dbConfig(db)`) → per table `FluentTableConfig` on the model
  (`FluentStorable.tableConfig`, cached as `_tableConfig` in the provider). Overridable fields are nullable on the
  narrower levels; resolve table ?? database ?? global. Wall-clock time only through `FluentClock` (tests: `testNow`).
- Public surface: `lib/fluent_sqflite.dart` is the public API and hides everything internal by name; code in `lib/`
  imports `src/internal.dart` (or the barrels), never the public file. Internal members go into hidden extensions
  (`FluentProviderInternals`, `FluentStorableInternals`, `FluentDbInternals`) or private names; internal enums into
  `utils/fluent_internal_enum.dart`. A new public top-level name must be wanted by users; otherwise add it to the
  `hide` list. Tests may import `src/internal.dart`; `test/docs` uses the public file only.
- `FluentDb` has only static members. Calls depend on the model's mixins: trash calls are extensions on
  `FluentProvider<T extends FluentSoftDeletable>`, relation calls on `FluentProvider<T extends FluentRelations>`
  (relations are declared on the model); the same split applies to the `FluentDb` statics (generic bounds) and the
  model extensions in `utils/fluent_extensions.dart`. Writes take `tag:` (carried on `FluentTask.tag`, never in the policy).
- Models extend `FluentStorable` (`buildJson`, `tableSchema`, `migrations`, `timeToLive`); providers implement
  `tableName`, `modelSample`, `fromCacheJson`. See `test/helpers/relation_models.dart`.
- Mixins/extensions: `relations/`, `soft_delete/`, `timestamps/`, `sync/` (`FluentSyncable`). Sync internals live in
  `parts/sync/fluent_sync_core.dart` (versions, tombstones, pull). Every local write of a syncable table must go
  through `_setRows` / `_writeRows` / `_hardDeleteWhere` so `sync_version` / tombstones stay right; writes received
  from the server pass `synced: true` (`TableHelper.syncWrite`). Rows and deletions are matched with the server by
  `_serverKey` (`FluentTableConfig.serverKey`, else the primary key); only a `syncWithServer` pull moves the `since`
  (`applyPull(rememberAs:)`). `watchRemote` (`parts/fluent_watch_remote.dart`) is the cache → server → cache stream;
  both share the retry rule in `utils/fluent_retry.dart`.
- Filters are type-safe via `FluentFilter` (`lib/src/utils/fluent_filter.dart`). Conditions that need the provider
  (`related`, `search`) are `FluentDeferredCondition`s: the clause holds `\u0001<n>\u0001` markers, `and` / `or`
  renumber them, the provider writes them as SQL when the task runs (`parts/relations/fluent_relation_filter.dart`,
  `_withDeferredResolved`; code that builds SQL itself calls `_resolveRelated`). Full-text indexes live in
  `parts/schema/fluent_full_text.dart` (FTS table + triggers, `__fluent_fts` meta).
- Errors: one hierarchy in `lib/src/exceptions` — `FluentException` (`message`, `code` = `FluentErrorCode`, `hint`,
  `cause`, `stackTrace`) with `FluentConfigException`, `FluentSchemaException`, `FluentArgumentException`,
  `FluentConstraintException`, `FluentQueryException`, `FluentRelationException`, `FluentSyncException`,
  `FluentCancelledException`, `FluentEngineException`. Never throw raw `ArgumentError` / `StateError` /
  `DatabaseException` to users; keep the original error as `cause`; the hint lives on the exception.
- Logging (`core/fluent_log/fluent_log.dart`, configured via `FluentDb.setupLogging`): every error is logged **once**.
  Throw with `throw FluentLog.raise(e, tag: ...)`; inside a provider call it defers to
  `FluentProvider.internalExecute`, which maps `DatabaseException` → typed (`_sqlError`) and logs (`FluentLog.report`,
  skipped for merged batches, which re-run call by call). Errors the caller receives → warning; failures nobody
  receives (background, maintenance, timers) → `FluentLog.report` (error level). Recoverable misconfig → a warning
  `FluentIssue` (`FluentLog.issue`) with a hint.
  Everything that is not an exception to the caller is a `FluentIssue` (`models/fluent_issue.dart`): kind
  (`FluentIssueKind`, decides the type hint / autoFix / warning / error), title, details, fix (required), code, key
  `<kind>:<db>:<table>:<subject>`. Report with `FluentLog.issue(kind, message, hint: ...)` or `FluentLog.publish(issue)`;
  never `print` / free-text warnings. Hints and warnings once per run, autoFix and errors every time; muted by
  `setupLogging(mute:)`; hints only while `FluentAnalyzer().collects(db)` (`FluentDiagnostics`). A new kind gets a doc
  comment and a row in `doc/ai/issues.md` (generated table; `docs_test` checks it). Wrong calls / settings never throw
  when a safe fallback exists: fall back and report. Any automatic change at run time is an `autoFix` issue.
  Usage / engine / plan hints live in `core/fluent_analyzer/` (`FluentAnalyzer`, engine hooks
  `onDispatch` / `onEnqueue` / `onStart` / `onDone` / `onFinish`): observe only, never change scheduling; thresholds are
  its constants (the only hint thresholds; reads judged by their average over `minSamples` runs); `EXPLAIN` only when
  `canExplain` (not in release). The tuner (`core/fluent_tuner/`, `FluentTuning` levers, each switchable) acts only
  through the queue or on idle databases, reports `tuned` and takes back what fails or does not help (`tuningReverted`);
  a new lever gets its own `FluentTuning` switch. SQL arguments and
  database paths never appear in messages unless `FluentLog.showSqlArguments`; error texts go through `FluentLog.redact`.

## Conventions

- Strict analyzer (`strict-casts`, `strict-inference`, `strict-raw-types`) and
  `public_member_api_docs`: every public member needs a `///` doc comment.
- Relative imports inside `lib`, trailing commas, `final` locals, no `print` (use `FluentLog`).
- Generated SQL always quotes identifiers (`name.quotedIdentifier`, `FluentFilter` quotes plain columns). sqflite's
  `insert` / `update` / `query` / `delete` quote only keywords: pass `table.quotedIdentifier`, `row.quotedKeys`,
  `columns.quotedAll`; internal filters on stored column names pass `column.quotedIdentifier` (a name with a space is
  otherwise taken as an expression).
- Never build `WHERE pk = ?` by hand: use `keyFilter(id)` / `keysFilter(ids)` (+ `keysPerChunk`) of
  `FluentProviderInternals` (users get `FluentFilter.ids`) — they handle simple and composite keys (`FluentKey`).
- Relations: users declare `FluentRelation` (`one` / `oneOwned` / `many` / `manyToMany` / `through` / `oneOf`, full
  constructor or shortcuts) in `FluentRelations.relations` on the model, or not at all: `_findRelations` turns
  `buildJson` fields holding stored models into `auto` declarations (`autoRelations` setting; the sample decides,
  generic `_stores` test, never type names). At init `buildFluentRelationGraph` resolves them into
  `FluentRelationLink`s (columns, link tables, delete rules) and reports the decisions (`autoRelations` hint) — never
  mutate the user's declarations. `through` is a many-to-many link whose table is the link model's (`linkModel`,
  `isThrough`, read it via `linkSource`; never write its table directly, go through the link provider). `oneOf` /
  owned lists through it are polymorphic (`typeColumn` / `typeValue`, `referenceValues` includes the type; every
  filter on an owned link adds `typeFilter` / `typeCondition`): no SQL FK, so `_polymorphicCascade` deletes / clears
  before a hard delete. Relation storage between versions: `FluentTableSnapshot.relations` + `fluentMigrateRelations`.
  Code lives in `parts/relations/`: graph (+ schema, orphan clean-up), writer (`_saveGraph`), reader
  (`_processRowsBatch`, batched per relation; `FluentLoad.none` travels as task depth 0), ops (`loadRelations`,
  `findRelated`, `findParents`, `countRelated`, `attach`, `detach`).
  Deletes rely on SQLite FK cascade; `cleanupOrphans` only fixes truly dangling references.
  References may span several columns (composite keys): use the link's column lists (`foreignKeys`,
  `referencedColumns`, `linkOwnerColumns`, `linkTargetColumns`) with `referenceValues` / `_rowTuple` / `_tupleFilter`,
  never the joined display getters (`foreignKey`, `linkOwnerColumn`).
- Reads: every read hides soft-deleted and expired rows through `_visibility()` (relations: `_relationVisibility`);
  the trash scope (`_TrashScope`, a zone value set by `provider.trash` / `withTrash`) shows trashed rows,
  `includeExpired: true` shows expired rows. Writes go through `_write` (open
  transaction or a new one, typed errors); never use `db.transaction` directly in provider code — use
  `_runInTransaction` / `FluentTransactionScope.inTransaction`, so calls inside join instead of deadlocking.
- Transactions: `FluentTransactionScope` (zone value) holds the open transaction; `executor` returns it,
  `FluentDbInternals.executeTask` runs tasks directly inside it. `save` never writes `deleted_at` / timestamps (the row writer does).
  `auto` relations are decided in `_decideAuto` (graph pass 2) from all declarations + schemas; the resolved type
  lives on `FluentRelationLink.type` — use `link.type` / `link.isList`, never `link.relation.type`.
- Schema: `parts/schema/fluent_schema_sync.dart` (`syncTable`) compares the model with the snapshot in
  `__fluent_schema` and applies only the difference; history goes to `__fluent_schema_history`. FluentDb runs it
  per group in one transaction with foreign keys off (`_runSchemaTransaction`). Never drop user data implicitly:
  removed columns are archived unless the group / a `dropColumns` step says otherwise; rows a rebuilt table rejects
  (CHECK / UNIQUE) go to `__fluent_rejected_<table>_r<rev>` (`_copyRows`). Start: `fluentSchemaUpToDate` skips the
  whole sync when every table's `fingerprint` (`_fingerprint`: definitions, steps, link statements, relation storage,
  settings) matches — anything a full sync reads must be part of the fingerprint. Every change is a typed
  `FluentSchemaChange` collected in `ctx.changes` (history stores the descriptions); `planMigrations` /
  `onMigrationPlan` run the same `_syncTables` in a rolled-back transaction with issues captured
  (`FluentLog.captureIssues`), so a new change kind needs no separate planning code. The snapshot also keeps a hash of
  the table's `sqlite_master.sql` (`tableSql`), so DDL from outside takes the full sync. A column kept in place
  (`RENAME COLUMN` archive) must have no rules (`REFERENCES`, `UNIQUE`, `CHECK`, key): rules on archives act on data.
- Merging saves: every helper field that changes how a save writes (`saveStrategy`, `conflictOn`, `syncMode`,
  `syncWrite`) must be equal (`_adjacentSaves`). An action handled in `_executeInMain` must complete its caller on
  error too. Emptying a synced table also resets `__fluent_sync_state` / `__fluent_fetch_state`.
- `orderBy` from callers is checked when the task runs (`_checkedOrderBy` in `_queryTask`): columns only, never raw SQL. Prefer one `ALTER TABLE` over a
  rebuild (`_removeInPlace`); a rebuild recreates views, triggers (also of other tables) and the app's own indexes.
- Filter values stay Dart values (`FluentFilterArgs` keeps the column of each argument); they are converted per column
  only when SQL is built: every `whereArgs` sent to sqflite goes through `_sqlArgs` (`_args`). Long user lists
  (`FluentFilter.ids` / `inList` / `notInList` over `FluentFilterInternals.maxListArguments`) are deferred conditions
  that become a temporary table of the task (`parts/fluent_value_lists.dart`): code that resolves a filter itself
  calls `_flushValueLists` before its statement (SQL built before the task: `_resolveDetached`). Deferred conditions put
  every value into `fingerprint` (read collapsing). Lists of keys sent to SQL are chunked below `_maxParamsPerChunk`.
- Changes to the app's models that only hold after a commit (e.g. `deletedAt` after a save) go through
  `FluentTransactionScope.whenCommitted`; a rolled-back savepoint drops its pending events and those changes.
  Generated keys are injected at once (later calls of the same transaction need them).
- Names: `FluentUtils.toSnakeCase` is the 2.0 word rule; the relation graph is built once more with the 1.x rule
  (`FluentUtils.withLegacyNames`, `_legacyNames`, `parts/relations/fluent_legacy_names.dart`) and the start renames
  what a 1.x database stored under those names (`fluentAdoptLegacyNames` before the tables, reference columns via
  `oldName`, `fluentAdoptLegacyTypeValues` after). Anything new that derives a name from a type or relation name must
  go through `toSnakeCase` so both builds see it.
- Key values: keys from users, models or the server are Dart values (converted once by the key column); values read
  from rows are stored values and are never converted again (`stored:` on `_keyFilterOf` / `_keysFilterOf` /
  `_tupleFilter`, `_storedId`, `_dartIdOf`). Match keys (`_valuesKey(columns, values)`) normalize by column affinity.
- Keys: `buildJson` wins over the key the library keeps (`metadata`); a key a `conflictOn` save replaced
  (`forceKey`) wins while `buildJson` still returns the value it replaced (`_keyValue`, used by `primaryKeyValue`,
  `key` and the row writer).
- Every public call reports errors through its Future / Stream, also when the provider is not registered (`_run`
  wraps in `Future.sync`; `FluentDb.trash` / `withTrash` resolve the provider per call).
- Nested `FluentDb.transaction` calls run in a SAVEPOINT (`FluentTransactionScope.savepoint`); reads a transaction
  adopts run in their caller's zone and are awaited before the commit.
- Nested writes: `FluentTransactionScope.inTransaction` joins with a SAVEPOINT (sent lazily: `scope.txn` is a
  `_FluentLazyTxn` that prepends pending SAVEPOINT / RELEASE statements to the next statement or batch; a rollback is
  always its own `execute`, never batched); a scope is `closed` after its body, and
  every task starts in a zone cleaned of the caller's task / read / transaction scope. `init` / `close` / `restart` /
  `deleteDatabases` are serialized. The `autoRelations` hint is published by `keepOneToOneSides` (after the stored
  one-to-one sides are read), not by the graph build.
- Types: built-in Dart ↔ SQLite conversions live only in `utils/fluent_type_codecs.dart` (`FluentTypeCodecs`, tags
  shared with `_fs_metadata` / `FluentValueKind`); a column has one path — explicit converter, enum converter from
  `enumValues`, or its value-kind codec. Never add type special cases to the sanitizer or the mapper.
- Registry: one model type / provider class may serve several tables (`_FluentProviderIndex.allByModel` /
  `allByProvider`); lookups by type must fail with `ambiguousProvider` then. Change events and watchers are keyed by
  database + table (`FluentChangeEvent.dbName` / `table`), never by model type.
- Read path: the engine lends a pooled read-only connection to each read task (`FluentReadScope`, picked up by
  `FluentProvider.executor`); code running in a read task must never write (create bookkeeping tables at init, e.g.
  `prepareSyncTables`). Rows become models only through `_FluentRowPlan` (`parts/fluent_row_mapping.dart`,
  `_mapRows`): sliced on the UI isolate or in a background isolate with `isolateFactory`. The plan must stay sendable
  (no provider, database or closures over them); build it in the class (`_plan`), not in an extension — extensions only
  know the static `T`.
- Errors follow "what → why → how to fix": log with `hint`, throw a typed `Fluent*Exception`; recoverable
  misconfiguration → a warning `FluentIssue` + hint + fallback. Planned work goes into `TODO.md`, bugs not fixed yet into `KNOWN_BUGS.md`; a fixed bug (with its test) moves to `FIXED_ISSUES.md`.
- Documentation is English only. Human guide: `README.md` + `doc/*.md`; agents: `llms.txt`, `doc/ai/`, and package
  skills in `skills/fluent-sqflite-<area>/SKILL.md` (folder = `name`, lowercase + hyphens, description starts with
  "Use when", under 500 lines; big tables in `references/`). `doc/ai/migrations.md` and `doc/ai/error-codes.md` are
  copied into the upgrade / troubleshooting skills — keep the copies identical (`test/docs/docs_test.dart` checks it,
  plus links and that every `FluentErrorCode` is documented). Every public API change updates the guide, the matching
  skill and `test/docs/doc_examples_test.dart`; every rename or removal adds a row to `doc/ai/migrations.md`
  (renames keep the old name `@Deprecated` for at least one minor version).
- Do not run `dart format` on whole files: the code uses a wider line length than the formatter
  default, and it would produce huge unrelated diffs.

## Tests

**Hung tests are killed, never waited for.** A hung test blocks everyone: its `flutter_tester.exe` keeps
`build/native_assets/windows/sqlite3.dll` locked, and every later `flutter test` in the checkout fails with "failed to
delete … sqlite3.dll".
- Always run tests with a hard limit: `timeout 600 fvm flutter test ...` (single files: `timeout 300`). Every test file
  that waits on streams, transactions, timers or shutdown gets `@Timeout(Duration(seconds: 20))`, and awaited futures
  that may never complete get `.timeout(...)`.
- If a run hangs or the DLL is locked: find the process (`tasklist //FI "IMAGENAME eq flutter_tester.exe"`) and
  kill it (`taskkill //PID <pid> //F`) at once. If the kill is not allowed, ask the user to kill it right away; do
  not work around it with copies of the repo.
- A hang is a bug: find the test, make it fail fast, and fix the library if it waits for itself.
- Agents that run tests get the same rules in their brief. Several `flutter test` runs at once in one checkout fight
  over that DLL too: parallel agents run their tests in their own synced copy (`bash tool/mirror_test.sh <name> [args]`:
  mirrors the checkout without `build/`, runs `flutter test` there with a 10-minute limit), while editing files in the
  checkout itself.

Layout: tests live by component, like `lib/src`: `test/engine`, `test/db`, `test/log`, `test/analyzer`, `test/tuner`,
`test/stats`, `test/models`, `test/interfaces`, `test/utils`, `test/provider/{crud,mapping,relations,schema,sync}`;
`test/regressions` holds cross-cutting bug reproductions, `test/stress` the scaled stress runs (`FLUENT_STRESS`), `test/docs` the documentation checks, `test/helpers` shared
models. Name a file after what it tests (`<area>_test.dart`); a file from an audit round keeps a suffix
(`_audit_fixes`, `_audit_probes`, `_round3`). Performance tests assert statement counts or complexity (N+1 guards),
never wall-clock times.

Tests use the same helpers apps use: the `fluent_sqflite_test` package (`packages/fluent_sqflite_test`, a path
dev dependency). Every test file that opens a database calls `setUpFluentTests()`: FFI sqflite, a per-file temp databases directory, logging
off (set `FLUENT_LOG=1` to see library logs). `FluentTestDb(name: ...)` + `open([...providers])` initializes a group
in memory; `persistent: true` for files (`restart(...)` with a newer schema, read pool, stats). Wait for streams with
`db.settle()`, move time with `db.clock`, never `FluentClock.testNow` or `Future.delayed`. The package uses internals
(`FluentClock`, `FluentDbInternals.reset`, `FluentEngine.whenIdle`, `FluentLog.forgetIssues`): keep them working.
The benchmark lives in `packages/fluent_sqflite_benchmark`. `test/helpers/schema_models.dart` has
`DynamicProvider` for declaring table shapes inline in schema/migration tests. `test/helpers/query_counter.dart`
counts SQL statements (N+1 guards); `FluentGroup(inMemory: true)` opens a database without a file.
Roadmap: `TODO.md`; open bugs: `KNOWN_BUGS.md`; fixed bugs and finished work: `FIXED_ISSUES.md`.
