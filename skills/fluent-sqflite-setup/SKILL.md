---
name: fluent-sqflite-setup
description: >-
  Use when the user configures or controls fluent_sqflite databases: FluentDb.init and FluentGroup (several databases,
  dbKey, inMemory, readOnly prebuilt files, directory, removedColumns, archiveRetention, resetOnSchemaError,
  autoRelationFallback, onMigrationPlan), the three settings levels FluentConfig / FluentDbConfig / FluentTableConfig
  (SQLite pragmas journalMode, synchronous, cacheSize, busyTimeout, foreign keys, highIntegrity, read connections,
  isolate mapping, watchdogs, maintenance intervals), FluentDiagnostics and FluentTuning, ExecutionPolicy priorities,
  pauseQueue / resumeQueue (file backups), and the lifecycle: isOpen, configure, close, restart, deleteDatabases.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: setup, settings and lifecycle

## Rules

- `await FluentDb.init([...])` once, before `runApp` and before any database call
  (after `WidgetsFlutterBinding.ensureInitialized()`). Calls before it fail with `notInitialized`.
- One `FluentGroup` per database file. Every provider a relation uses must be in the same group.
- Settings live on three levels; the narrower one wins: table (`FluentTableConfig` on the model) → database
  (`FluentGroup(config: FluentDbConfig(...))`) → global (`FluentDb.init(config: FluentConfig(...))`). Override fields
  are `null` by default on the narrower levels.
- Keep the defaults (WAL, `synchronous: normal`, foreign keys on) unless there is a measured reason. Data that must
  survive a power loss: `FluentDbConfig.highIntegrity`.
- `resetOnSchemaError: true` deletes the database when its start fails: only for caches that can be downloaded again.
- Never copy, replace or delete the database file while it is in use: `pauseQueue` first, or `deleteDatabases`.
- Wrong settings never crash the app: the library falls back to a safe value and reports a `configFallback` warning.

- Never call `FluentDb.close` / `restart` / `deleteDatabases` inside a transaction or provider callback (ignored,
  `ignoredCall`). `ExecutionPolicy get policy` on a provider sets the default of its calls. `batchKeys`
  (`FluentBatchKeys.fromRows` default / `fromModels`) chooses where merged lookups read their keys.

## Opening databases

```dart
abstract final class AppDb {
  static final FluentDbKey main = FluentDbKey('main');   // letters, digits and _ only (it is the file name)
  static final FluentDbKey cache = FluentDbKey('cache');
}

await FluentDb.init([
  FluentGroup(dbKey: AppDb.main, providerList: [users, posts], config: FluentDbConfig.highIntegrity, onMigrationPlan: (plan) => !plan.losesData),
  FluentGroup(dbKey: AppDb.cache, providerList: [images], resetOnSchemaError: true, config: const FluentDbConfig(trashRetention: Duration(days: 1))),
], config: const FluentConfig(diagnostics: FluentDiagnostics.recommend));
```

| `FluentGroup` | Meaning |
|---|---|
| `dbKey`, `providerList` | the database and its tables |
| `config` | `FluentDbConfig` of this database |
| `directory` | folder of the file (default: the platform's databases folder) |
| `inMemory` | no file; gone on close (tests, throw-away caches) |
| `readOnly` | open a prebuilt file as it is: no schema sync, no maintenance (`databaseNotFound` when missing) |
| `removedColumns` | `FluentColumnRemoval.archive` (default: keep the data) or `drop` |
| `archiveRetention` | how long archived columns stay (default 30 days; `null`: keep) |
| `historyLimit` | schema history entries kept per table (default 100) |
| `resetOnSchemaError` | recreate the file when the start fails (never for a refused `onMigrationPlan`) |
| `autoRelationFallback` | kind of `auto` lists without any signal (default `manyToMany`) |
| `onMigrationPlan` | decide on the schema changes before a start applies them (see the schema skill) |

With several databases, statics take `dbKey:` when a model lives in more than one (`FluentDb.find<Post>(dbKey: ...)`);
`FluentDb.transaction(dbKey: ...)` covers one file.

## Settings

| `FluentConfig` (global) | Default | Meaning |
|---|---|---|
| `diagnostics` | `FluentDiagnostics.recommend` | what is measured, suggested, tuned (below) |
| `defaultPolicy` | `ExecutionPolicy()` | policy of calls that set none |
| `readConnections` | `null` (2, or by cores with tuning) | read-only connections per database (WAL only) |
| `isolateMapping` | `FluentIsolateMapping.smart` | `smart` / `always` / `never`: map big lists in a background isolate (`isolateFactory`) |
| `sliceAfterRows`, `frameBudget` | 300, 4 ms | lists mapped on the UI isolate yield to frames |
| `transactionWatchdog` | 2 s | after this, reads waiting for a transaction run inside it (with a warning) |
| `pauseWatchdog` | 60 s | a forgotten `pauseQueue` is resumed |
| `trashPurgeInterval`, `trashRetention` | 24 h, 7 days | the trash is emptied of rows older than the retention |
| `optimizeInterval` | 6 h | `PRAGMA optimize` while idle |
| `indexReferences` | `true` | index relation reference columns |
| `autoRelations` | `true` | `buildJson` fields holding models become relations |
| `fullText` | `FluentFullText.auto` | `auto` (FTS5, else FTS4), `fts4` (same everywhere, unranked), `off` (search with LIKE) |

| `FluentDbConfig` (per database) | Default | Meaning |
|---|---|---|
| `journalMode` | `SQLiteJournalMode.wal` | `wal` (parallel reads), `delete`, `truncate`, `persist`, `memory`, `off` |
| `synchronous` | `SQLiteSynchronous.normal` | `off`, `normal` (safe with WAL), `full`, `extra` |
| `cacheSize` | about 10 MB | `SQLiteCacheSize.megaBytes(20)`, `.kiloBytes(...)`, `.pages(...)` |
| `busyTimeout` | 5 s | wait for a lock held by another connection |
| `enableForeignKeys` | `true` | relation deletes rely on it (off: the library cleans dangling references) |
| `tempStoreInMemory` | `true` | sorting / grouping temp data in memory |
| `readConnections`, `trashRetention`, `indexReferences`, `autoRelations`, `fullText`, `diagnostics` | `null` | override the global value |

`FluentDbConfig.highIntegrity` = `journalMode: delete, synchronous: full, tempStoreInMemory: false`.

| `FluentTableConfig` (on the model) | Meaning |
|---|---|
| `dateTimeFormat` | `FluentDateTimeFormat.timestamp` (default, epoch ms) or `iso8601` text |
| `storeEnumsAsNames` | enums stored by name (default) or index |
| `serverKey` | columns that match server rows (sync) |
| `trashRetention`, `indexReferences`, `autoRelations`, `fullText`, `isolateMapping` | override the database / global value |

```dart
@override
FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 90), isolateMapping: FluentIsolateMapping.always);
```

`FluentDb.configure(FluentConfig(...))` replaces the global settings at run time (timers restart). `init(groups)` and
`planMigrations(groups)` without `config:` keep the settings in use (last `configure` / `init(config:)`), not the defaults.
An `init` after a queued `close` / `restart` runs in call order. Zero or negative `trashPurgeInterval`, `optimizeInterval`,
`pauseWatchdog`, `transactionWatchdog` fall back to the defaults (`configFallback`); `null` switches them off.

## Diagnostics and the tuner

`FluentDiagnostics(hints:, hintsInRelease:, costModel:, tuning:)`; presets `none` (nothing measured), `quiet` (measure,
no hints), `recommend` (default: hints with code to copy), `auto` (also `tuning: FluentTuning.full`).
`FluentTuning` levers, each switchable: `indexes` (+ `maxIndexes`), `readConnections`, `memory`, `background`,
`checkpoints`, `frameBudget`; presets `off`, `full`, `noIndexes`; `FluentTuning.full.copyWith(indexes: false)`.
Every change of the tuner is a `tuned` issue and is taken back (`tuningReverted`) when it fails or does not help.

## Scheduling

Calls run through one queue per database. Writes keep call order and run alone; reads between two writes run in
parallel (read connections) by priority. `ExecutionPolicy(priority:, cancelIfDuplicate:)` on a call, on the provider
(`@override ExecutionPolicy get policy`) or globally (`defaultPolicy`); presets `ExecutionPolicy.fast` (priority 10,
the UI waits), `background` (-10, prefetch), `fresh` (never answered by an identical read in flight). There are no
timeouts: a started operation is never abandoned.

```dart
await FluentDb.pauseQueue(dbKey: AppDb.main);   // waits for running calls, holds new ones
try {
  await File(path).copy(backupPath);            // the file is quiet
} finally {
  FluentDb.resumeQueue(dbKey: AppDb.main);      // always resume (pauseWatchdog resumes a forgotten pause)
}
```

## Lifecycle and maintenance

```dart
FluentDb.isOpen();                              // init completed (or isOpen(dbKey: ...))
await FluentDb.restart(update: (groups) => [...groups, FluentGroup(dbKey: extra, providerList: [notes])]);
await FluentDb.deleteDatabases(dbKey: AppDb.main); // sign-out: delete the file, reopen empty (reopen: false keeps it closed)
await FluentDb.close();                         // running calls finish; queued ones of a paused queue (or still
                                                // queued after drainTimeout) fail; later calls fail with engineClosed
await FluentDb.clearExpired<Session>();          // delete rows past timeToLive now (reads hide them anyway; done at start)
await FluentDb.cleanOrphans();                   // rarely needed: dangling references with foreign keys off
```

At start the library synchronizes the schema (three reads when nothing changed), removes expired rows and empties
old trash; later it purges the trash every `trashPurgeInterval` and runs `PRAGMA optimize` while idle. A failing
database closes the others opened by the same `init` and reports `initFailed`.
