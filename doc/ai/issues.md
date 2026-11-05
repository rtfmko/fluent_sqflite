# Issues

Version: 2.0.0. Besides the errors your code receives (see [error-codes.md](error-codes.md)), fluent_sqflite reports
**issues** (`FluentIssue`): what it suggests, what it changed by itself, what it ignored and what failed in the
background. Every issue has a `kind` (below), a `type`, a `title` (what), `details` (why), a `fix` (how) and
often `code` to copy. Its `key` is `<kind>:<database>:<table>:<subject>`.

* **hint** — it works, but could be faster or safer; shown once per run, grouped by `impact` in `FluentDb.report()`.
* **autoFix** — the library changed something while the app runs (a fallback, a tuner change or its revert);
  always reported, nothing changes silently.
* **warning** — something in the code or setup is wrong; the library ignored it or fell back to a safe choice.
* **error** — something failed that no caller receives (maintenance, listeners, background work).

Route them: `FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error})` for crash reporting,
`FluentDb.onIssue(types: {FluentIssueType.hint})` for a debug panel, `FluentDb.report()` for the overview.
Mute what does not apply to your app: `FluentDb.setupLogging(mute: {'unordered:*', 'missingIndex:app:logs:*'})`.
Hints are collected according to `FluentDiagnostics` (`FluentConfig.diagnostics`, per database
`FluentDbConfig.diagnostics`); the tuner (`FluentDiagnostics.auto`, `FluentTuning`) reports its changes as `tuned` /
`tuningReverted`.

| Kind | Type | Impact | Reported | When |
|---|---|---|---|---|
| `missingIndex` | hint | high | once per run | An index would serve a slow read (from the query plan or the measured costs). |
| `slowRead` | hint | high | once per run | A read is slow on average and no index would help (big result, heavy relations, ...). |
| `lookupLoop` | hint | high | once per run | `findById` called in a loop (N+1): read the keys at once. |
| `saveLoop` | hint | high | once per run | `save` called in a loop: one `saveAll` is one transaction. |
| `flood` | hint | high | once per run | Thousands of calls queued at once. |
| `queueWait` | hint | high | once per run | Calls wait long in the queue behind a slow call. |
| `syncKey` | hint | high | once per run | A synced table uses auto-increment keys: two devices create the same id. |
| `relations` | hint | medium | once per run | Reads load relations several levels deep and are slow. |
| `bigRead` | hint | medium | once per run | An unpaged read returns thousands of rows. |
| `deepOffset` | hint | medium | once per run | A deep `offset`: keyset paging (`findPage`) costs the same on every page. |
| `like` | hint | medium | once per run | `LIKE '%…'` cannot use an index: full-text search can. |
| `polling` | hint | medium | once per run | The same query polled while nothing changed: `watch` reads only after changes. |
| `slowWrite` | hint | medium | once per run | A single write took long. |
| `isolate` | hint | medium | once per run | Big lists would map faster in a background isolate (`isolateFactory`). |
| `refIndex` | hint | medium | once per run | A relation filter needs an index on the reference column (`indexReferences` is off). |
| `enumValues` | hint | medium | once per run | An enum field without `enumValues` comes back as a String. |
| `unordered` | hint | low | once per run | Paged reads without `orderBy` can repeat or skip rows. |
| `redundantIndex` | hint | low | once per run | An index repeats another index or the key. |
| `fullTextOff` | hint | low | once per run | Full-text search is off for a table that searches. |
| `autoRelations` | hint | low | once per run | Relations were decided automatically (`auto`, or fields found in `buildJson`); the hint lists them. |
| `columnRestorable` | hint | medium | once per run | A column is back in the model while its earlier values are archived: `restoreColumns` brings them back. |
| `stepOnNewTable` | hint | medium | once per run | A migration step that inserts rows was only marked as applied, because the table was just created. |
| `pullClock` | hint | high | once per run | Pulls return no `serverTime`: the next `since` comes from the device clock. |
| `unusedLinkTable` | hint | low | once per run | A link table no relation uses any more is kept with its links. |
| `queueResumed` | autoFix | — | every time | A paused queue ran past `FluentConfig.pauseWatchdog` and was resumed. |
| `transactionWatchdog` | autoFix | — | every time | A transaction ran long while reads waited; the waiting reads were let in (they see its uncommitted changes). |
| `isolateFallback` | autoFix | — | every time | Rows of a table could not be sent to a background isolate; they are mapped on the UI isolate. |
| `readPoolFallback` | autoFix | — | every time | The read connections could not be opened; reads run on the main connection. |
| `fullTextFallback` | autoFix | — | every time | The device has no FTS5 / FTS4; searches fall back (FTS4 or `LIKE`). |
| `databaseRecreated` | autoFix | — | every time | A database was deleted and created again after a failed start (`resetOnSchemaError`). |
| `columnArchived` | autoFix | — | every time | A column removed from the model was archived with its data. |
| `columnKeptNullable` | autoFix | — | every time | A new NOT NULL column without a default stays nullable for the existing rows. |
| `relationDataMoved` | autoFix | — | every time | A relation changed how it is stored (e.g. many-to-many → owned list); its data was copied to the new place. |
| `rowsQuarantined` | autoFix | — | every time | Rows a new constraint rejects were moved to a quarantine table. |
| `trashRevived` | autoFix | — | every time | Saved models whose rows were in the trash were restored. |
| `tuned` | autoFix | — | every time | The tuner applied a setting (`FluentDiagnostics.auto`). |
| `tuningReverted` | autoFix | — | every time | The tuner took a setting back (it did not help, or it failed). |
| `configFallback` | warning | — | once per run | A setting that cannot work was replaced by a safe one. |
| `duplicateGroup` | warning | — | once per run | The same database name was given twice to `init`. |
| `noGroups` | warning | — | once per run | `init` got no group with providers. |
| `sharedModelType` | warning | — | once per run | One model type is stored in several tables: calls by type cannot choose. |
| `circularReference` | warning | — | once per run | Tables reference each other in a cycle. |
| `ignoredCall` | warning | — | once per run | A call could not do what was asked and did nothing (unknown relation, no key, wrong place, ...). |
| `crossDatabase` | warning | — | once per run | A collection of models spans several databases: each is written in its own transaction. |
| `schemaFallback` | warning | — | once per run | The model declares something invalid (key, default value, column type); a safe choice was used. |
| `indexSkipped` | warning | — | once per run | An index of the model was not created (unknown columns, duplicates in the data, an index of the app with the same name). |
| `viewOrTrigger` | warning | — | once per run | A view, trigger or index of the app could not be recreated after a table rebuild. |
| `columnTypeChanged` | warning | — | once per run | A column changed its type on a table with rows; values that do not fit stay as they were. |
| `possibleRename` | warning | — | once per run | A column was removed and one of the same type added: probably a rename without `oldName`. |
| `relationChanged` | warning | — | once per run | A relation changed how it is stored, but its data could not be moved (shared children, composite keys, children that already point to another owner). |
| `migrationSkipped` | warning | — | once per run | A migration step was not run (no id, changed after it ran, nothing to do). |
| `danglingReferences` | warning | — | once per run | Rows reference rows that do not exist (rows of `RESTRICT` links are left alone and reported). |
| `relationDeclaration` | warning | — | once per run | A relation declaration is invalid or ambiguous; it was skipped or interpreted. |
| `relationSoftDelete` | warning | — | once per run | A soft-deletable model owns children without soft delete (or the other way round). |
| `foreignKeysOff` | warning | — | once per run | Foreign keys are off: owned children are not deleted with their owner by SQLite. |
| `relationValue` | warning | — | once per run | A relation field held a value of the wrong type; the relation was skipped for that model. |
| `conflictOn` | warning | — | once per run | `conflictOn` columns are not unique: one save may update several rows. |
| `deletedAtIgnored` | warning | — | once per run | A save carried `deletedAt`; the rows stay live (delete them to move them to the trash). |
| `trashStays` | warning | — | once per run | Restored rows stay in the trash because their owner is deleted. |
| `mappingValue` | warning | — | once per run | A stored value could not be read as the model expects; the field got a fallback. |
| `precisionLost` | warning | — | once per run | A saved value lost part of itself in its stored form (the microseconds of a `DateTime` in the timestamp format, which keeps milliseconds); the rest was saved. |
| `batchKeysMismatch` | hint | — | once per run | Merged `findById` lookups read the keys of the stored rows (`FluentBatchKeys.fromRows`), but a returned row matched none of the requested keys (another form of the same key, e.g. case-insensitive); those keys were looked up call by call. |
| `legacyNameAdopted` | autoFix | — | every time | A table, link table or column a 1.x database stored under its 1.x name (derived from a type or relation name with the old rule) was renamed to the current name; its data is kept. |
| `brokenTrigger` | warning | — | once per run | A trigger of the app was recreated after a table rebuild but no longer fits the table (it uses a removed or renamed column); it is kept and fails when it fires. The hint has the SQL to recreate it. |
| `fullTextSkipped` | warning | — | once per run | A column of a full-text index was skipped, or the table cannot have one. |
| `remoteDeleteKept` | warning | — | once per run | The server deleted rows the model cannot keep in a trash; they are kept. |
| `serverKeyIgnored` | warning | — | once per run | `FluentTableConfig.serverKey` names unknown columns; the primary key is used. |
| `tombstoneWithoutKey` | warning | — | every time | A permanently deleted row has no server key yet, so the server cannot be told about the deletion. |
| `unsentChangesDiscarded` | warning | — | every time | `clearTable` emptied a synced table that still had local changes the server never received (run `syncWithServer` first). |
| `initFailed` | warning | — | every time | A database could not be opened. |
| `syncFailed` | warning | — | every time | A synchronization failed. |
| `apiFailed` | warning | — | every time | `fetch` of `watchRemote` failed. |
| `syncStoreFailed` | warning | — | every time | `watchRemote` could not store the answer of `fetch`. |
| `shutdownTimeout` | warning | — | every time | The engine stopped before every queued call finished. |
| `closeFailed` | warning | — | every time | A connection could not be closed (harmless). |
| `fileDeleteFailed` | error | — | every time | A database file could not be deleted (`deleteDatabases(reopen: false)`, `resetOnSchemaError`); `deleteDatabases(reopen: true)` throws instead, so signed-out data is never served. |
| `maintenanceFailed` | error | — | every time | Start-up or periodic maintenance failed (expired rows, dangling references, trash). |
| `relationLoadFailed` | error | — | every time | Loading a relation failed; it was left unloaded. |
| `callbackFailed` | error | — | every time | A callback of the app (`onSuccess`, ...) threw. |
| `engineFailure` | error | — | every time | An unexpected internal failure. |
