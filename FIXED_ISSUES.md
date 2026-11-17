# fluent_sqflite: fixed issues

Bugs found and fixed, and work finished, during the 2.0 rework, kept as history. Open bugs live in `KNOWN_BUGS.md`,
planned work in `TODO.md`. When a known bug is fixed (with a test),
move it here.

## Audit 2 (2026-11-17, fixed in 2.0.0-dev.2)

Eight areas audited in parallel, every finding checked against the code; all fixed with a regression test and edge
cases. Tests: `test/provider/relations/relations_audit2_test.dart`, `test/engine/engine_audit2_test.dart`,
`test/provider/schema/schema_audit2_test.dart`, `test/provider/crud/crud_audit2_test.dart`,
`test/provider/sync/sync_audit2_test.dart`, `test/db/lifecycle_audit2_test.dart`,
`test/provider/mapping/mapping_audit2_test.dart` (numbered like the items below).

### Relations
1. **HIGH.** Saving a model loaded through a `limit` / `where` relation removed the children the view did not show.
   Now a `limit` relation removes nothing, a `where` relation only rows matching it, trashed / expired children and
   targets are never "missing". Found on the way: links to trashed tags were deleted by a save of the owner.
2. **HIGH.** Saving an `includeDeleted` list restored its trashed children; they now stay in the trash.
3. **MEDIUM.** The writer ignored `unloadedRelations` and deleted children of relations that were never loaded.
4. **MEDIUM-HIGH.** `findParents` through `oneOf` returned parents of other types (or threw); now filtered by type.
5. **Decision.** `insertOnly` on an existing root writes nothing for its relations.

### Engine and transactions
6. **HIGH.** Two adjacent saves of the same new model merged and inserted two rows; one instance never merges twice.
7. **HIGH.** Keys generated in a rolled-back transaction / savepoint stayed on models (rowid reuse overwrote another
   row); `FluentTransactionScope.whenRolledBack` takes them back. Found on the way: a failed merged batch rerun call
   by call kept the keys of its rolled-back attempt.
8. **HIGH.** `FluentDb.clear()` / `purgeArchivedColumns()` inside a transaction deadlocked. `clear` runs in the open
   transaction; inside another task (and `purgeArchivedColumns` inside a transaction) the call is skipped with
   `ignoredCall`.
9. **HIGH.** A transaction on A inside a transaction on B deadlocked on the next write to B: transaction scopes are
   kept per database, a task clears only its own.
10. **MEDIUM.** Merged patch saves of one row lost a patch (`_matchKeys` now uses `keyValueOf`).
11. **LOW-MEDIUM.** A re-entrant `_processNext` could start reads before a taken write; nested passes are deferred.
12. **LOW-MEDIUM.** `cleanOrphans` ran outside the queue without events; now a queued write with `update` events.
13. **LOW.** The tuner counted an earlier run's auto index again (`_servedShapes` refilled at start).

### Schema and migrations
14. **HIGH.** `oldName` + a new column under the old name broke the table; renames are resolved first (chains work),
    the freed name is added empty, a fast start with a snapshot missing a model column takes the full sync, and a
    table missing a model column after the steps is refused (`schemaConflict`).
15. **HIGH, data loss.** Children of a parent quarantined in `__fluent_rejected_*` were deleted by the start-up orphan
    clean-up; references into quarantine tables are kept and reported (`danglingReferences`).
16. **MEDIUM.** The fast start ignored a missing FTS module; it now compares the stored definition with this SQLite.
17. **LOW.** 1.x type values were adopted on every full sync; now only with their table's rename. Unquoted 1.x
    indexes are the model's; found on the way: duplicate 1.x column indexes of renamed tables are dropped.

### CRUD
18. **MEDIUM, regression of the dev.2 cursor check.** ISO text on DateTime columns of `iso8601` tables is accepted.
19. **MEDIUM.** `FluentDb.deleteAll` / `Iterable.deleteAll()` / base-type deletes set `deletedAt` now.
20. **MEDIUM.** `delete` / `restore` change the models after the commit (`whenCommitted`).
21. **MEDIUM.** The soft-delete stamp is always epoch milliseconds; old ISO stamps are converted once at start
    (`storedFormatAdopted`, new issue kind).
22. **LOW.** The `watch` expiry timer follows the library clock (`FluentClockAlarm`).
23. **LOW.** Updates by key skip expired rows (`includeExpired` on `updateById` / `updateWhere`); upsert renews an
    expired row, insertOnly writes over it.
24. **LOW.** Active-record calls all resolve the provider by the runtime type.

### Sync
25. **MEDIUM.** `FluentDb.clear()` kept tombstones (a next user pushed old deletions).
26. **LOW-MEDIUM.** `clearTable()` kept the table's tombstones; they are dropped and counted.
27. **MEDIUM.** A save of a tombstoned key kept the tombstone (push sent upsert + delete); it is dropped in the write.
28. **MEDIUM, confirmed.** `replaceLocally` / `clearLocally` removed unsynced children through FK cascades; found on
    the way: the same through `oneOf` references. Parents of unsynced descendants are kept.

### Lifecycle, settings, logging
29. **MEDIUM.** `init` after a queued `close` / `restart` shared the pending init and was dropped.
30. **MEDIUM.** File paths were not redacted (`<path hidden>` now, also in `FluentGroup.toString`).
31. **MEDIUM.** Per-database config (diagnostics) was unknown during init.
32. **LOW-MEDIUM.** Zero / negative intervals made a busy loop; fallback + `configFallback`, no overlapping runs.
33. **LOW.** `init(config:)` / `planMigrations(config:)` nullable (keep the settings in use); `$e` redacted;
    `setupLogging(removeOnRecord:)`; the test package resets logging per test; `busy` no longer blocks a recreate.

### Values and mapping
34. **MEDIUM.** `defaultValue` is stored like a saved value (converter, dateTimeFormat); NaN fails typed.
35. **MEDIUM.** `aggregate` with groupBy / several min-max keeps the UTC flag.
36. **LOW.** Cursors round-trip bytes and non-finite doubles; garbage text fails typed.
37. **LOW.** ISO-8601 text has six fraction digits; old values are padded once at start (`storedFormatAdopted`).
    Found on the way: `FluentIsoDateTimeConverter` had the same problem.
38. **LOW.** Unquoted column names with spaces get a quoting hint.

### Docs
39-40. Fixed by the docs pass (non-compiling `oldName` examples, install line, wording).

## Known bugs of 2.0.0-dev.1 (fixed 2026-11-17, in 2.0.0-dev.2)

1. **LOW.** A damaged `_fs_metadata` value lost the UTC flag of a `DateTime`. Now the tag pairs still readable in the
   damaged text and the tags intact rows of the table gave the column are used before the column kind
   (`_FluentRowPlan._seenTags`). Test: `test/provider/mapping/mapping_edges_test.dart` ("damaged metadata keeps the
   UTC flag"). What is left (no intact row, unreadable text) is a known limit in `KNOWN_BUGS.md`.
2. **LOW.** `FluentTask.staticWeight`: a `find` without a helper weighed 40, with a helper and no `limit` 80, so an
   unfiltered find looked cheaper. The unbounded weight now applies with or without a helper. Tests:
   `test/engine/engine_test.dart` (order of weights), `test/models/models_misc_test.dart`.
3. **LOW.** `findPage` cursor values were not checked against the columns; a wrong value failed later in SQL (or read
   a wrong page). Now a cursor with a missing key column, a non-stored value or text for a numeric column fails with
   a `FluentArgumentException` and a hint before any SQL. Test: `test/provider/crud/pagination_test.dart`.
4. **LOW.** The maintenance timers (trash purge, `PRAGMA optimize`) were real `Timer.periodic`. Now
   `FluentClockTimer` runs them by library time: moving `db.clock` runs them, a failing run is reported and the timer
   keeps going, a clock moved back never stalls it, `close` cancels it. Tests:
   `test/db/fluent_db_lifecycle_edges_test.dart` (group "timers").

## Audit 1 (2026-11-04, was `KNOWN_BUGS.md`)

The item numbers are used by `test/regressions/known_bugs_test.dart`.

Audit of `lib/` (working tree, uncommitted v2.0.0 refactor).

### Status (2026-11-04)

Worked through. Regression tests: `test/regressions/known_bugs_test.dart` (numbered like the items below) and
`test/regressions/audit_bugs_test.dart` (items 1, 2). 562 tests pass, analyzer clean.

* **Fixed, with a test:** 1, 2, 3, 4, 5, 8, 9, 11, 12, 16, 19, 22, 23, 24, 26, 28, 32, 33, 39, 40, 41, 42, 43, 44,
  45, 46, 47, 49 / 67, 50, 54 (missing `removedAt`), 58, 60, 61 (`FluentGroup`, `FluentDbColumn`), 62, 65, 66.
* **Fixed, checked by reading** (hard to reproduce in a test): 6, 7 (link rebuild keeps every link, asides get a free
  name), 10 (no reset for busy / locked / read-only files), 13 (post-commit work outside the retry), 14 (borrowed read
  connections closed after their read), 15 (factory errors come back as text, only isolate failures switch it off),
  18, 20, 21 (registry copied before awaiting), 25 (docs: `null` leaves the expiry alone; how to clear it), 29, 30,
  31, 34 (cached per schema), 35, 36, 37, 38, 48, 51 (debug logs), 53 (`Expando`), 55, 56, 57 (default folder only),
  64 (deletes before upserts), 68 (only links to the deleted table), 69 (one sample per schema compile).
* **Not a bug / by design:** 17 (`_closeAll` already clears the registry), 52 (text keys match SQLite affinity),
  54 bootstrap part (no older date exists), 59 (a running app cannot read its code; documented), 61 `TableHelper`
  (internal, never cleared), 63 (sqflite serializes PRAGMA / EXPLAIN with open transactions; documented), 27 / 70
  (mirror must compare the whole scope; paged in round 3), the `autoCorrectAllowed: false` part of 4 (the user's
  explicit choice).
* **Found on the way, fixed:** sqflite's `insert` / `update` / `query` / `delete` helpers quote only SQL keywords, so
  tables and columns with a quote, a space or a dash could not be saved; the library now passes quoted names (tests
  58b, 58c).

Status: **confirmed** = reproduced by a failing test or checked directly; **read** = found by reading the code only.

### Confirmed

1. **HIGH, confirmed.** `buildJson` is called in the scheduler (`_matchKeys`, `lib/src/core/fluent_engine/fluent_engine.dart` ~602), outside the error handler. A throwing save never completes its Future, and later writes of that database wedge.
2. **MED, confirmed.** `fluentValueKey` (`lib/src/utils/fluent_filter.dart` ~489-494) falls back to the text form of the value. Distinct objects with the same `toString` share a read-collapse key.
3. **HIGH, read.** `FluentKey`: `==` uses `mapEquals` (order-free), `hashCode` depends on entry order (`lib/src/models/db/fluent_key.dart` 52-55). Equal keys in different order end up duplicated in `Set` and `Map`.
4. **HIGH, read.** Empty primary key falls back to `id` via `putIfAbsent`, which returns an existing non-PK `id` column (`lib/src/core/fluent_provider/parts/fluent_schema.dart` ~208). The key becomes a non-PK column, so upserts and updates by key stop finding rows. Same pattern near ~230 when `autoCorrectAllowed` is false.
5. **HIGH, read.** `FluentProvider` `hashCode` and `==` use mutable `_dbName` and `_db` (`lib/src/core/fluent_provider/fluent_provider.dart` 355-359). `FluentGroup.providerList` is a `Set`, and `_getSortedProviders` uses `contains`, so membership breaks after `setDbName` or `setDb`.

### Read: data loss and corruption

6. **HIGH, read.** `_rebuildLinkTable` (`lib/src/core/fluent_provider/parts/relations/fluent_relation_graph.dart` ~1152-1181): `INSERT OR IGNORE` silently drops links when a new NOT NULL key column is not among the common columns.
7. **MED-HIGH, read.** Same function, no-common-columns path (~1156): `DROP TABLE IF EXISTS __fluent_old_<table>` deletes links kept aside by an earlier rebuild.
8. **MED-HIGH, read.** External-content FTS is tied to rowid (`lib/src/core/fluent_provider/parts/schema/fluent_full_text.dart` ~166-184). For tables without an INTEGER PK, `VACUUM` may renumber rowids, and there is no rebuild on VACUUM. Search can return wrong rows.
9. **MED, read.** Schema rebuild (`fluent_schema_sync.dart` ~721-727): archived columns on disk that are missing from `snapshot.archived` are not carried into the new table and are lost without a warning.
10. **MED, read.** `resetOnSchemaError` (`lib/src/core/fluent_db/parts/fluent_db_lifecycle.dart` ~223-246) deletes the file on any error except `migrationRefused`, including busy or locked files.
11. **MED, read.** `deleteDatabases(reopen: false)` (lifecycle ~519-521) stores all groups in `_lastConfig`, including deleted ones. A later `restart()` recreates the deleted files.
12. **MED, read.** Auto list relation with two owners (`fluent_relation_graph.dart` ~957-963): the `otherOwners` check runs before the column check, so the relation becomes `manyToMany`, its columns are ignored, and cascades do not run. Confidence medium.

### Read: wrong behaviour without data loss

13. **MED, read.** `_executeInMain` (`fluent_engine.dart` ~935-973): post-commit work runs inside the `try`. An exception there re-runs every call of a batch, so inserts and increments happen twice.
14. **MED, read.** `initMultiple` (`fluent_engine.dart` ~242) closes read connections that running reads still borrow.
15. **MED, read.** `_mapInIsolate` (`lib/src/core/fluent_provider/parts/fluent_row_mapping.dart` ~251): any error, including one thrown by a user factory, permanently disables isolate mapping for the provider.
16. **MED, read.** `_FluentRowPlan.build` (row mapping ~37-52) catches only `TypeError` from user factories; other exceptions escape untyped.
17. **MED, read.** `_init` (lifecycle ~219-258): a non-retry failure does not call `_reset()`, so groups registered earlier stay in the registry while `_isInitialized` is false.
18. **MED, read.** `_init` (lifecycle ~274, ~282): read-pool opening and `FluentTuner().start` run outside `try`. A failure leaves the engine and databases open.
19. **MED, read.** `_restart` (lifecycle ~447-450): the user `update` callback runs after the engine shut down, without error handling; `_isInitialized` stays true if it throws.
20. **MED, read.** `planMigrations` is documented as serialized but is not (lifecycle ~14-15; `fluent_db.dart` ~804).
21. **MED, read.** Iterating `_groupedRegistry` across `await` while `close` or `register` modify it can throw `ConcurrentModificationError` (maintenance ~98-110; `schemaReport` ~703-718).
22. **MED, read.** Composite-key rebuild (`fluent_schema.dart` ~255-267) drops `valueKind`, `indexed` and `isUnique`: enum, bool and DateTime key columns filter wrongly.
23. **MED, read.** `_prepareSqlJson` (`lib/src/core/fluent_provider/parts/fluent_mapper.dart` ~21): `addAll(metadata)` into an unmodifiable map returned by `buildJson` throws `UnsupportedError`.
24. **MED, read.** Filter value encoding (`fluent_mapper.dart` ~101-107): `on Object` silently uses the raw value when the converter fails, so filters return wrong rows.
25. **MED, read.** `timeToLive` null (`fluent_mapper.dart` ~80-85): the expiry column is not written, so an upsert keeps the old expiry. The docs contradict themselves (`lib/src/interfaces/fluent_storable.dart` ~187-189).
26. **MED, read.** `findPage` (`lib/src/core/fluent_provider/parts/crud/fluent_read.dart` ~298): the sort-column check uses `tableColumns`, which includes internal columns; the error appears later, in `_storedValue`.
27. **MED, read.** `watchRemote` with `mirror` (`lib/src/core/fluent_provider/parts/fluent_watch_remote.dart` ~323): reads all visible keys without a limit on every fetch.
28. **MED, read.** `_executeSave` (`lib/src/core/fluent_provider/parts/crud/fluent_execute_crud.dart` ~114-129): `_syncDeletedAt` changes user models before commit; a rollback leaves them changed.
29. **MED, read.** `_tupleFilter` (`fluent_relation_graph.dart` ~224-227): `as Object` on a null id throws a `TypeError`; for composite keys a null silently matches nothing.
30. **MED, read.** `_zipKey` (`fluent_relation_graph.dart` ~202): a plain id for a composite key goes into the first column only; the rest become NULL.
31. **MED, read.** `_findRelations` (`fluent_relation_graph.dart` ~779-781): a `buildJson` error silently disables auto relations.
32. **MED, read.** `_throughLink` (`fluent_relation_graph.dart` ~751-755): a self-through without `parentVia` or `childVia` is dropped silently.
33. **MED, read.** Relation REFERENCES (`fluent_relation_graph.dart` ~1074-1076): a PK column gets no REFERENCES; a user REFERENCES suppresses the declared `onDelete`. The library then assumes a cascade that SQL does not perform.
34. **MED, read.** Full-text helpers: `fullTextColumns` (`fluent_full_text.dart` 24-45) logs issues on every access.
35. **MED, read.** Tuner `_drop` (`lib/src/core/fluent_tuner/fluent_tuner.dart` ~248-260) decrements the counter and reports "Dropped" even when the provider is null.
36. **MED, read.** Tuner index name `fluent_auto_<table>_<cols>` (~197) ignores the query shape, so two shapes share one index and dropping it hurts the other (~251).
37. **MED, read.** Tuner `_checking` entries (~50, ~191, ~238) are removed only on measurement or failure; a shape that never reaches the sample count keeps its entry forever.
38. **MED, read.** `_isWrite` (`lib/src/core/fluent_table_stats_tracker/fluent_table_stats_tracker.dart` ~249) scans all enum values on each call from `slowest` and `measuredHints`.
39. **MED, read.** Log redaction (`lib/src/core/fluent_log/fluent_log.dart` ~241): the `args [...]` regex matches only at the end of the text. Confirmed by reading.
40. **MED, read.** Log sink (`fluent_log.dart` ~110-119): `onRecord` receives unredacted `message`, `context` and `error`. Confirmed by reading.
41. **MED, read.** `FluentLogRecord.format` (`lib/src/models/fluent_log_record.dart` ~71-84): `message`, `hint` and `context` are printed without redaction.
42. **MED, read.** `json` codec (`lib/src/utils/fluent_type_codecs.dart` ~56-63): corrupt JSON silently returns the raw string.
43. **MED, read.** Locale codec (`fluent_type_codecs.dart` ~45-46): three-part tags such as `zh-Hant-TW` lose script and region.
44. **MED, read.** `FluentEpochDateTimeConverter.fromSql` (`lib/src/models/db/fluent_converter.dart` ~109): returns a local DateTime, so a UTC value does not compare equal after a round trip.
45. **MED, read.** `FluentGroup.providerList` is built with `toSet()`, which silently merges two equal provider instances (`lib/src/models/fluent_group.dart` ~105).
46. **MED, read.** `deleteDatabases` checks `_lastConfig` rather than the open registry (lifecycle ~436-519).
47. **MED, read.** `keyFilter(null)` returns a null-safe filter while `keysFilter` rejects null (`fluent_provider.dart` ~422, ~230-239).
48. **MED, read.** `_polymorphicCascade` (`fluent_crud_helper.dart` ~917) converts owner arguments with the child's table settings.
49. **MED, read.** Owned-children load (`fluent_relation_reader.dart` ~112-127) loads all children and truncates by `limit` afterwards.
50. **MED, unverified.** `FluentClock.isReplaced` (`lib/src/utils/fluent_clock.dart` ~15) relies on `identical` over a static tear-off. If tear-offs are not canonical, the flag is always true.

### Low

51. Silent catches: `fluent_watch.dart` ~116, `fluent_crud_helper.dart` ~720, `fluent_watch_remote.dart` ~159.
52. `_valuesKey` (`fluent_crud_helper.dart` ~543) compares text forms, so `1` and `'1'` collide.
53. Static `_hubs` and `_running` in `lib/src/sync/fluent_syncable.dart` 58-62 are never cleared.
54. Archive `removedAt` is reset to now at bootstrap (`fluent_schema_sync.dart` ~530). `FluentArchivedColumn.fromJson` defaults `removedAt` to epoch 0, so an archive with missing JSON expires at once (`lib/src/models/schema/fluent_schema_report.dart` 29).
55. `_reset` (`lib/src/core/fluent_db/parts/fluent_db_locator.dart` 11-19) does not cancel the trash and optimize timers.
56. Read-only groups still get trash purge and optimize writes (maintenance ~95-111).
57. The fixed legacy file name `fluent_system.db` is deleted in the shared folder (lifecycle ~356-367).
58. `orderBy` validator (`fluent_crud_helper.dart` 114-124) rejects valid `""`-escaped identifiers.
59. `FluentDbMigration.contentHash` (`lib/src/models/db/fluent_db_migration.dart` 71-87) ignores the body of `onMigrate`, so an edited step is not reported.
60. `fluentRetryDelay` (`lib/src/utils/fluent_retry.dart` 15) has no cap and produces an infinite delay for very large attempts (`2^attempt`).
61. `copyWith` on `FluentDbColumn`, `TableHelper` and `FluentGroup` cannot set nullable fields to null.
62. `FluentTableSnapshot.fromJson` (`fluent_schema_report.dart` 81-97) uses bare casts, so a corrupt snapshot fails at start with an unhelpful `TypeError`.
63. Tuner `_pragma` and analyzer `explain` run outside the queue; their behaviour under concurrent writes is untested.
64. Telemetry: the stats batch writes upserts before deletes (`fluent_table_stats_tracker.dart` ~214, `fluent_engine.dart` ~875).
65. `FluentDbKey` implementation has no `==` or `hashCode`; the library keys databases by string, so this is only a usability gap.
66. `_changesData` (`lib/src/models/task/fluent_task.dart` 115-117) matches keywords anywhere in a `WITH` statement, and `isStreamOp` misses SQL that starts with a comment.

### Performance

67. Relation `limit` is applied after loading all children (see item 49).
68. Link-table orphan `DELETE` scans the whole table on every hard delete when foreign keys are not enforced (`fluent_relation_graph.dart` ~1287-1293).
69. `modelSample` (a user getter that builds a model) is read about five times per schema recompute (`fluent_schema.dart` 126-141) and once per provider on each trash purge (maintenance ~101).
70. `watchRemote` `mirror` reads all visible keys per fetch (item 27).

### Could not confirm

- `case FluentRelationType.one` in the relation graph switch has no `break` (`fluent_relation_graph.dart` 499-512). `fvm dart analyze` on that file reports no issues, so it is not a compile error; keep watching it.
- Auto list with two owners (item 12) is not reproduced by a test.
- Rejected: `linkSource` drops the soft-delete filter when visibility has arguments. Visibility never produces arguments, so the filter is applied.

## Fixed and finished, by area (was `TODO.md`)

### Review order (top → down)

1. Base types: models, configs, enums, filter, sanitizer ✅ (round 2 done)
   Done out of order: 7. Relations ✅, 4. Schema & migrations ✅
   Next: 2. Errors & logging ← **next**
2. Errors & logging (unified "what → why → how to fix" format)
3. Model layer: `FluentStorable`, columns, schema inference, mapper
4. Schema & migrations ✅ (sync v2)
5. `FluentDb.init` & lifecycle
6. CRUD
7. Relations & soft delete
8. Engine: queue, ordering, transactions, batching
9. Sync: `reactiveSync`, `syncWithServer`
10. Telemetry: stats tracker, system DB

---

### 1. Base types & model layer

#### Done
- [x] `ExecutionPolicy` value equality; one default chunk size (`ExecutionPolicy.defaultChunkSize`).
- [x] `FluentEngineConfig ==` includes `alertPauseDuration`.
- [x] `FluentDbColumn` immutable (`copyWith` instead of mutation); FK clause appended to user `customSql` instead of replacing it.
- [x] Primary key auto-correction actually applied (in `getFullSchema`), with hint.
- [x] `closeAll()` safe after a failed `init`; `dropDatabase` uses the `.db` path; invalid DB name message not duplicated.
- [x] New test harness (`test/helpers/`), old tests removed.

#### Done (round 2 — all covered by tests in `test/models`, `test/<component>`)
- [x] Identifiers always quoted in generated SQL (reserved words like `order` work); `FluentFilter` quotes plain column names.
- [x] Registration checks with hints: unknown index columns, default value vs column type, composite key + AUTOINCREMENT,
      duplicate key columns, missing key column added, relations to composite-key tables disabled, anonymous / duplicate relations.
- [x] Column: typed `defaultValue` (auto-escaped) + `FluentSqlExpression`; `collation`; boolean `CHECK (x IN (0,1))`.
- [x] `FluentIndex`: multi-column, unique, partial; created on existing DBs at startup; duplicate data → hint, init continues.
- [x] Table-level `CHECK` constraints (`FluentCheck`).
- [x] Composite primary key: `primaryKeys`, `FluentKey`, `item.key`, `PRIMARY KEY (a, b)`, `withoutRowId`;
      CRUD by key through `keyFilter` / `keysFilter` / `matchFilter` in `FluentProvider`.
- [x] Relations keyed by name (`mapToKey`): `relations` is a `List`; several relations to one type get `<name>_id` columns.
- [x] Per-column converters (`FluentConverter` + enum / ISO date / epoch date / JSON).
- [x] Versioned migration steps: `rawSql`, `dropColumns`, `onMigrate` (`__fluent_migrations`; fresh tables only record versions).
- [x] DB config: `FluentGroup.directory`, `FluentGroup.readOnly`, `SQLitePerformanceConfig.busyTimeout`.

#### Known limits of round 2 (keep in mind)
- [x] Changed `CHECK`s rebuild the table; rows the new schema rejects (CHECK / UNIQUE) go to `__fluent_rejected_<table>_r<rev>`
      with a warning + restore hint, never deleted; when every row would be rejected the change fails (2026-10-26).
- [x] One conversion table `FluentTypeCodecs` (built-in types, same tags as before) for writing and reading; `enumValues`
      creates a `FluentEnumConverter` (name or index, reads both); converter columns ignore old per-row tags (2026-10-26).
- [x] Writes on a `readOnly` database fail with the raw SQLite error — now `FluentQueryException` (`readOnly`) + hint.

#### Deferred (decided, do later)
- [x] `primaryKeyValue`: key column names cached per instance (`Expando`), one `buildJson()` per access, falls back to
      the generated id recorded after insert (2026-10-20).
- [x] `FluentDbColumn.timestamp` maps to `BLOB` (docs say INTEGER). Change only together with the migration fixes (type change triggers a table rebuild).
- [x] Multi-column foreign keys (relations to composite-key tables) — done in the relations module (2026-10-20).
- [x] `Color` / `Locale` come from `dart:ui`; only `TimeOfDay` is imported from material (2026-10-26).

### 2. Errors & logging — reworked (2026-10-25), tests: `test/log/errors_logging_test.dart`

Decisions: errors the caller receives are logged as warnings (errors only for failures nobody receives);
`FluentErrorCode` is an enum; SQL arguments / paths hidden by default; release default level = warning.

#### Fixed
- [x] Default output lost the cause and stack trace → `FluentLogRecord.format` prints the cause (redacted) and, for
      errors, the first stack lines.
- [x] Merged-batch failures logged twice → errors are logged once in `FluentProvider.internalExecute` (skipped for the
      merged batch itself); `FluentLog.raise` defers inside provider calls; a `reported` flag prevents repeats.
- [x] Raw `SqfliteFfiException` from reads → mapped by `_sqlError` (no such table / column, constraints, read-only).
- [x] `setupDefaultDebug` ignored after the first log → `setupLogging(level:)` applies at any time.
- [x] Cancellations → `FluentCancelledException` (`cancelled` / `engineClosed` / `engineReset`).
- [x] Doubled not-initialized messages; `toggleLogging(false)` printing; hint only in the log (now on the exception).

#### Done
- [x] One hierarchy: `FluentException` (`message`, `code`, `hint`, `cause`, `stackTrace`) + 9 classes by meaning; old
      classes removed; no raw `ArgumentError` / `StateError` / `UnimplementedError` / `DatabaseException` to users.
- [x] Logging API: `FluentDb.setupLogging({level, onRecord, console, colors, showSqlArguments, enabled})`,
      `FluentLogRecord`, `FluentLogLevel.hint`, `debugPrint`, colors only on desktop, release default warning.
- [x] `FluentHint` + `FluentDb.onHint` (once per key and run, always printed in debug); slow-filter index hint uses it.
- [x] Masking: `FluentLog.redact` (args, FFI parameters, database path) in exceptions' `toString` and log output.
- [x] Every warning / error has a hint; levels aligned; outdated texts rewritten ("what → why → how to fix").
- [x] Dead `FluentDbSummary` / `FluentDbHealthReport` removed (were the 15 analyzer infos).

#### Later
- [x] Error codes table with fixes in the AI docs: `doc/ai/error-codes.md` (a test checks every code is listed).
- [x] More analyzer hints → §10 "Analyzer / optimizer" (2026-10-27).
- [x] `FluentDb.*` statics threw lookup errors synchronously (`.catchError` missed them) → `Future.sync` /
      `_safeStream`: failed futures and stream error events (also `transaction`, `reactiveSync`, relation ops).

### 4a. Schema sync v2 — done (2026-10-20), covered by `test/provider/schema/schema_sync_test.dart`

**Snapshot & sync**
- [x] `__fluent_schema` (same DB file): per table — column definitions, key, CHECKs, WITHOUT ROWID, our indexes,
      revision, archived columns, pending NOT NULL, applied steps (label + content hash). Replaces `__fluent_migrations`.
- [x] Model == snapshot → no DDL (fast start). First start on an existing DB bootstraps the snapshot from PRAGMA.
- [x] New column → `ADD COLUMN`; rename (`oldName`) → `RENAME COLUMN` (SQLite ≥ 3.25) else rebuild;
      type / key / constraint change → safe rebuild; changed index → drop + create; removed index → drop (ours only).
- [x] NOT NULL without default on a non-empty table → added nullable + warning; enforced on a later start once no NULLs remain.
- [x] `FluentDbColumn.timestamp` → INTEGER (one rebuild for existing tables).
- [x] No double work on first start (tables are created by the sync, not in `onCreate` + sync).

**Removed columns**
- [x] Default soft: rename to `__fluent_removed_<name>_r<revision>`, constraints dropped, never read/written.
- [x] Hard: `dropColumns` (removes the live column AND its archives) or `FluentGroup(removedColumns: FluentColumnRemoval.drop)`.
- [x] Restore only explicitly: `restoreColumns: {'name': 'title'}` (type must match); `oldName` maps live columns only,
      with a hint when an archive of that name exists.
- [x] Auto purge: `FluentGroup(archiveRetention: Duration(days: 30))` default, `null` disables;
      `FluentDb.purgeArchivedColumns(olderThan: ...)` (required parameter).

**One-time steps**
- [x] Label `version` (int) or `id` (String), one of them required; run in declaration order; label = "applied".
- [x] Content hash per applied step: changed after applying → warning (won't rerun, use a new label).

**History & report**
- [x] `__fluent_schema_history`: every applied change and every failure (written after rollback);
      `FluentGroup(historyLimit: 100)` per table.
- [x] `FluentDb.schemaReport()`: current state + history, readable `toString()`.

**Safety & maintenance**
- [x] User triggers / views saved before a rebuild and recreated after (warning with SQL when impossible).
- [x] No silent DB deletion: only `FluentGroup(resetOnSchemaError: true)`.
- [x] Start-up orphan clean-up only with FKs off or after `foreign_key_check` found violations; partial index on `expiry_date`.

### 4. Schema & migrations — confirmed bugs
- [x] 🔴 Table rebuild cascaded deletes into child tables — fixed: FKs are switched off before the schema transaction, `PRAGMA foreign_key_check` after (test: relations_test "Schema rebuild keeps related data").
- [x] 🔴 A column removed from the model is silently dropped with its data (also when a relation fails to resolve). Default must keep unknown columns; dropping only via explicit migration step.
- [x] 🟠 Adding a `NOT NULL` (no default) or `UNIQUE` column fails `init` (`ALTER TABLE ADD COLUMN` limits). Fall back to rebuild / clear error with hint. In `isDev` this currently deletes the whole DB file.
- [x] 🟠 `FluentDbDataType.custom` columns rebuild the table on every start (`CUSTOM` vs disk type).
- [x] 🟡 Constraint changes (NOT NULL / UNIQUE / DEFAULT / FK / CHECK) are never migrated on existing tables.
- [x] 🟡 Removed indexes are never dropped.

- [x] 🟠 Changed index definition is ignored (`CREATE INDEX IF NOT EXISTS` keeps the old one); removed indexes stay (probe 2026-10-20).
- [x] 🟠 Primary key changes are never applied (single → composite key left `pk` as before).
- [x] 🟡 Every start re-analyses every table (PRAGMA + index DDL) even when nothing changed; on first start tables are
      created in `onCreate` and then analysed again.
- [x] 🟡 Start-up maintenance runs `cleanupOrphans` (`NOT EXISTS` scans) and `clearExpiredItems` (unindexed
      `expiry_date`) on every table every start.
- [x] 🟡 A rebuild silently drops user triggers / views on the table.

### 4b. Migrations review (2026-10-28), tests: `schema_sync_test.dart`, `schema_features_test.dart`, `relation_migration_test.dart`
- [x] 🔴 `dropColumns` removed a column that was still in the model (the `FluentDbMigration.columns` overlay in
      `getFullSchema`): later writes to it were silently lost. Now kept with a warning; the overlay and
      `FluentDbMigration.columns` were removed (`oldName` on the model's column renames).
- [x] 🟠 A rebuild dropped the app's own indexes; triggers of **other** tables using the rebuilt table made the rename
      fail ("error in trigger … no such table"). Both are recreated now (warning when one no longer fits).
- [x] 🟠 Link tables were never migrated (only `CREATE IF NOT EXISTS`): a new shape is rebuilt keeping the links; a
      relation that changes its kind (many-to-many ↔ owned list) copies the data (`relationDataMoved`, or
      `relationChanged` when children are shared); unused link tables get a hint (`unusedLinkTable`), never dropped.
- [x] 🟡 `onMigrate` ran with a raw transaction: provider calls inside would wait for the start forever. It runs in a
      transaction scope now. `PRAGMA table_info` is quoted.
- [x] ⚡ Fast start: a fingerprint per table (model, steps, relations, settings) → an unchanged schema costs three
      reads, no write transaction, no `foreign_keys` switching; `foreign_key_check` only after a change. Removed
      columns are archived with `RENAME COLUMN` / dropped with `DROP COLUMN` when SQLite can (else rebuild); a step's
      `dropColumns` of a just removed field drops at once instead of archive + rebuild. Stats load without a DDL.
- [x] Hints / warnings: `columnTypeChanged`, `possibleRename` (keys and library columns are never candidates),
      `columnRestorable` (decided: never restore by itself, the name may mean something else), `stepOnNewTable`.
- [x] Full audit, second pass (2026-10-28), every module (engine, CRUD, transactions, watch, sync, mapping, tuner,
      analyzer, lifecycle, extensions), fixed with tests in `test/regressions/regressions_test.dart`: merged saves mixed
      `relationSync` / `syncWrite` (preserveLocal lost, children deleted); `FluentDb.clear` hung forever on any error
      and failed on RESTRICT rules (passes now); `clearTable` / `clear` kept the pull cursor and `maxAge` (emptied tables
      were never pulled in full again); `watch` saw only the first relation level, one `oneOf` target, no `through`
      link model, and never dropped expired rows; a running sync answered calls for other rows; a push looped while a
      row was edited; no hint for pulls without `serverTime` (`pullClock`); `watchRemote` mirror wrote in two steps and
      compared server keys as different types (date / enum keys: every row deleted); `save` through a base-type
      variable used the base table; touched-table events of a merged batch carried the first call's tag.
- [x] Debug-only `EXPLAIN` of the analyzer runs through the queue as a background read; the isolate fallback tries the
      isolate again after a back-off (2026-11-05, `round3/engine_test.dart`).
- [x] Audit (2026-10-28), fixed with tests: a column archived in place kept `REFERENCES … ON DELETE CASCADE` and deleted
      rows of the old owner (now any column with REFERENCES / UNIQUE / CHECK / key is rebuilt); a refused
      `onMigrationPlan` wiped the file with `resetOnSchemaError`; `autoRelations: false` dropped model fields silently;
      the `autoRelations` hint code was not equivalent (`foreignKey`, `onDelete`, `via`); a failing database left the
      others of the same `init` open; `orderBy` accepted any SQL (now columns only, checked when the task runs);
      found relations built the json once per relation; the polymorphic cascade loaded every key (sub-query now);
      `planMigrations` threw for a failing step (`plan.failure`); `foreign_key_check` skipped after link / relation
      changes; manual DDL on model tables was missed by the fast path (the table's SQL is part of the snapshot).
- [x] Full project audit (2026-11-03), six areas, ~65 findings, all fixed with tests (`engine_fixes`, `read_fixes`,
      `write_fixes`, `relation_fixes(_storage)`, `schema_fixes`, `sync_fixes`, `sync_filter_conversion`); the list is in
      CHANGELOG. Decisions: filter values convert per column at run time; `rawQuery` refuses writes; `conflictOn`
      matches trashed rows like keys; strategies apply to root models only; an auto 1-1 pair keeps its stored side; a
      shared `one` + owned column uses the declared rule, else the reference's; `close` never abandons running calls.
- [x] Comment review (2026-11-04): every comment checked against the code by area, public docs with checked
      examples; bugs found on the way fixed with tests in `comment_review_fixes_test.dart`,
      `sync_filter_conversion_test.dart`, `write_fixes_test.dart` (see CHANGELOG).
- [x] Audit 2 (2026-11-04, eleven areas): every finding fixed or decided; regression tests in
      `test/*/…_audit_probes_test.dart` and `test/*/…_audit_fixes_test.dart`.
- [x] Round 3 (2026-11-05, `test/*/…_round3_test.dart`): new naming rule with adoption of 1.x names; `precisionLost` for cut
      microseconds; OBS-8 / DB-11 / ENG-3 / ENG-10 tested in full (ENG-3 found a real hang: `close` inside a
      transaction); converters on key columns applied once; typed match keys; `FluentBatchKeys`; paged
      `watchRemote` and mirror; `brokenTrigger`; foreign keys off → on; `schemaReport` queued; benchmark scenarios;
      `syncWithServer(cancel:)` with `FluentCancelToken` (`round3/sync_cancel_test.dart`).
- [x] Coverage by component (2026-11-05): tests moved into `test/<component>/`, about 99 % line coverage; fixed on the
      way: wrong-typed relation values (raw `TypeError`), a failing analyzer EXPLAIN hung its caller (it ran in
      `Zone.root`; errors do not cross error zones), false `polling` hints in rebuild storms, `toString` of models.
- [x] Dead code removed after the coverage round (`eventFailed`, a stats timer cancel, unreachable throws in the
      provider / aggregate / update / relation reader and writer, `byModel`); non-model values of `one` / `oneOf` /
      list relations are reported (`relationValue`).
- [x] Audit 1 (2026-11-04, the first section of this file): every item checked; fixes with regression tests in
      `test/regressions/known_bugs_test.dart` and `test/regressions/audit_bugs_test.dart`; status per item above.
- [x] Names sqflite's own helpers do not quote (quotes, spaces, dashes in table / column names): every `insert` /
      `update` / `query` / `delete` of the library gets quoted names (`quotedKeys`, `quotedAll`), internal filters
      quote their columns (2026-11-04; `known_bugs_test` 58b, 58c).

### 5. Lifecycle
- [x] `FluentSystemDb` (telemetry DB) stays open after `closeAll()` — closed on shutdown (engine review).
- [x] `FluentGroup(inMemory: true)`: no file, each group its own database, data gone on close (2026-10-26).

### 6. CRUD
#### Read API review (2026-10-20), tests: `test/provider/crud/read_api_test.dart`, `test/provider/mapping/serialization_test.dart`
- [x] 🔴 `findAll` / `findOne` returned soft-deleted rows; `findById` / `exists` saw them too, while `count`,
      `findItemsBy`, `find`, raw lookups hid them. Now every read hides soft-deleted rows; `findDeletedItems` is the trash.
- [x] `FluentDb` facade dropped parameters: `orderBy` (findAll / findItemsBy / findDeletedItems),
      `where` / `whereArgs` / `orderBy` (findValidItems).
- [x] Identifiers in `count`, soft-delete and expiry conditions are quoted.
- [x] Four copies of "fast path / relational path" hydration in the find executors replaced by `_assembleRows`.
- [x] Type safety: only plain SQLite values are written; column kinds (`FluentValueKind`) restore types even for rows
      without `_fs_metadata` (raw SQL, older versions); UTC dates keep their zone; Dart values (bool, DateTime, enum,
      Duration) work as query arguments; raw maps never expose internal columns; `fromCacheJson` type errors name
      the received types with a hint; non-JSON values in collections fail with the field name and a hint.
- [x] Raw `where` strings replaced by `FluentFilter` everywhere (raw SQL stays available via `FluentFilter(sql, args)`).
- [x] `limit` / `offset` without `orderBy` give an unstable order — documented (doc/reading.md) + a hint; `findPage`
      (keyset pagination) added (2026-10-26).

#### Write API & consolidation (2026-10-20), tests: `write_api_test.dart`, `transaction_test.dart`, `read_api_test.dart`
- [x] 🔴 `FluentDb.transaction(action, {dbKey})` (static, no `modelTypes`): a zone-scoped `FluentTransactionScope`
      replaces the shared `_transactionExecutor` field; the transaction is one exclusive engine task, calls inside run
      directly in it (no deadlock), nested calls join, change events are published after the commit (none on rollback).
      Internal multi-statement operations use the open transaction too (`_runInTransaction`).
- [x] 🔴 Upsert: `UPDATE` by key, then plain `INSERT` for missing rows (two batches per call, any SQLite version):
      a conflict on another UNIQUE column throws `FluentConstraintException` with a hint and rolls the save back.
      Duplicate keys in one call are written once (last wins; first for `insertOnly`).
- [x] 🔴 Soft delete: one stamp format (`DateTime` per table config, INTEGER column), strictly increasing stamps,
      re-deleting keeps the first stamp, `delete(item)` no longer rewrites the row, `save` never changes the deleted state,
      `deletedAt` is loaded into models, owned soft-deletable children are deleted / restored with the same stamp,
      purge matches legacy ISO stamps too and cleans orphans.
- [x] 🟠 Batch parameters (`batch`, `sharedBatch`, `executor`) removed: transactions cover them.
- [x] 🟠 Field updates keep type metadata exact (stale tags removed, one SELECT only for rows that carry metadata);
      unknown / key columns fail with a hint instead of returning 0.
- [x] 🟠 All writes map SQLite errors to typed exceptions with hints (`_writeError`: UNIQUE, FOREIGN KEY, NOT NULL,
      CHECK, read-only, missing table).
- [x] 🟠 `patch` updates existing rows without touching `null` fields; `insertOnly` / `updateOnly` report skipped rows.
- [x] ⚡ Row JSON built once per save; `noResult` batches when no generated key is needed; no extra metadata SELECT.
- [x] Compact API (provider = `FluentDb.*<T>` = active record): `findById`, `find`, `findFirst`, `findAll`,
      `findDeleted`, `count`, `exists`, `findMaps`, `rawQuery`, `execute`, `watch`; `save` / `saveAll` →
      `FluentSaveResult` (`conflictOn`), `update` / `updateAll` (`withRelations`), `updateById`, `updateWhere`;
      `delete` / `deleteAll` / `deleteById` / `deleteWhere` (`hard`), `restore` / `restoreById` / `restoreWhere`,
      `purgeDeleted({olderThan})`, `clearExpired`, `clearTable`. Old names removed (2.0).
- [x] Expired rows are hidden from every read (also related rows) unless `includeExpired: true`.
- [x] `FluentTimestamps` mixin (`createdAt` / `updatedAt` managed by the library).
- [x] `watch(...)`: live query re-run after changes of the table or its relation tables (coalesced).
- [x] Change events are not published for writes that changed nothing.
- [x] Schema: a key column also listed in `tableSchema` (or inferred from `buildJson`) no longer loses its PRIMARY KEY.
- [x] Engine: merged saves keep their strategy / `conflictOn` and every caller gets its own outcomes.
- [x] `patch` merges type tags exactly: patched fields get their new tags, untouched fields keep theirs (`_mergePatchTags`).
- [x] Mixed-type collections (`FluentDb.saveAll` / `updateAll` / `deleteAll`) of one database run in one transaction;
      several database files → warning + one transaction per file.
- [x] `watch` skips changes whose rows are neither shown nor matching (one `count` by key); other changes re-run it.

### 6b. Soft delete review (2026-10-21) — fixed, tests: `test/provider/crud/soft_delete_test.dart`, `write_api_test.dart`
- [x] 🔴 UNIQUE on soft-deletable tables = partial unique index `WHERE deleted_at IS NULL` (column UNIQUE and
      `FluentIndex.unique` without `where`): the trash keeps no values; restoring a taken value → typed error.
      `conflictOn` matches live rows only.
- [x] 🟠 `save` onto a trashed key brings the row back (with the children deleted together with it), writes the new
      data, outcome `restored` + warning; `insertOnly` too; `updateOnly` / `patch` / `update` / `updateById` skip the trash.
- [x] 🟠 Init warning + hint for owned relations soft-deletable owner → non-soft-deletable children.
- [x] 🟠 `findDeleted` owners load the children deleted together with them (same stamp).
- [x] 🟠 Restoring a row whose owner is still in the trash is skipped with a warning + hint (also on revive).
- [x] 🟡 Partial trash index `idx_<table>_deleted_at WHERE deleted_at IS NOT NULL`.
- [x] 🟡 Periodic trash purge (`FluentEngineConfig.trashPurgeInterval`, default daily) + `FluentSoftDeletable.softDeleteRetention`.
- [x] 🟡 `includeDeleted: true` on `find` / `findFirst` / `findAll` / `findById` / `count` / `exists` / `findMaps` / `watch`.
- [x] 🟡 A `deletedAt` set by hand is reported on save (warning + hint); saved models drop `deletedAt`.

### 6c. Reactivity & telemetry — reworked (2026-10-21), tests: `test/provider/crud/reactivity_test.dart`
- [x] 🔴 Every table a call changes publishes an event: graph saves (children, link targets), attach / detach,
      soft-delete / restore cascades, hard deletes through foreign keys (children, cleared references, link rows).
      Zone-scoped collector (`FluentEngine.touch`); inside a transaction they come after the commit.
- [x] 🔴 `loadRelations` / `ensureLoaded` / `countOf` (reads) and `attach` / `detach` (writes) run as engine tasks.
- [x] 🟠 `execute` publishes an event when the SQL changes rows (INSERT / UPDATE / DELETE / REPLACE).
- [x] 🟡 `wipeAll` carries the model type.
- [x] `watch` coalesces changes within one frame (`coalesce`, default 16 ms); `watchById` (+ `FluentDb.watchById`).
- [x] Telemetry = cost model per query shape (table + action + caller's condition without values + order / limit /
      depth): moving average (forgets gradually), shapes unused for `telemetryRetention` (30 days) dropped, at most 500
      (LRU). Persisted only when changed, while the queue is idle (at most every `saveInterval`), and on `closeAll`.
      No table scans. Old per-table stats (rowCount, complexity, ...) and the `__fluent_table_stats` table removed.
- [x] Read weights use the learned average of the shape (after 3 runs); `engineStats().slowestQueries`.
- [x] Slow-read hint (≥ 100 ms, once per shape and session) with the index code to add; `FluentDb.optimizationReport()`
      ("can be made faster": indexes, relation depth, paging, batched saves — each with example code).
- [x] `PRAGMA optimize` on `closeAll` and every `optimizeInterval` (6 h).
- [x] Index tips ignore LIKE (a leading % cannot use an index) → `like` hint + full-text search (§10, 2026-10-27).

### 7. Relations — rewritten (2026-10-20), covered by `test/provider/relations/relations_test.dart`

#### Done
- [x] New API: `FluentRelation<P, C>` with full constructor + shortcuts `one` / `oneOwned` / `many` / `manyToMany`;
      optional `foreignKey`, `linkTable`, `linkParentKey`, `linkChildKey`, `onDelete`, `lazy`, `keepMissing`,
      `orderBy`, `where`, `limit`, `includeDeleted`.
- [x] Relations resolved once at init into `FluentRelationLink`s (user declarations never mutated); invalid declarations
      (empty / duplicate name, unknown type, unregistered provider) are skipped with a hint;
      relation tree in the debug log.
- [x] One naming source: `<name>_id` for references, back-reference column or `<model>_id` for owned children,
      `<table>_<table>` link tables (sorted, shared by both sides). Old `owner_uuid` heuristic removed.
- [x] Save order referenced → self → owned children → links, one transaction, generated ids from batch results;
      instances deduplicated by identity; `null` = don't touch; lists replace (owned children deleted / soft-deleted,
      links removed) unless `keepMissing`.
- [x] Loading: one batched query per relation and level for all rows (find/findAll no longer N+1), depth limit,
      soft-deleted rows hidden, `orderBy` / `where` / `limit`, values passed to `fromCacheJson` and `getRelation`.
- [x] Self-references (trees, `Person.manager`) save and load.
- [x] Deletes via SQLite FK (`CASCADE` for owned / links, `SET NULL` for references); `cleanupOrphans` only fixes truly
      dangling references (also at start-up, and after deletes when FKs are disabled).
- [x] `loadRelations`, `ensureLoaded`, `countOf`, `attach`, `detach` (provider + `FluentDb`).
- [x] Registry: per-DB indexes by model / provider / table, cached `modelType` (also fixed double soft-delete purge).

- [x] `FluentRelation.auto` (2026-10-20): two-pass resolution over the whole database — select shape (list / single, read from
      the function type), explicit / auto back-references, models listed by several owners (shared → manyToMany),
      `<model>_id` columns; fallback `prefer` → `FluentGroup.autoRelationFallback` (default manyToMany) / `one`;
      reason in the debug tree. Explicit types are checked against the select shape (warning + hint).
      Tests: `test/provider/relations/auto_relations_test.dart`.
- [x] Relations to / from composite-key tables (2026-10-20): one reference column per key column (`<name>_<key>`),
      table-level `FOREIGN KEY (a, b) REFERENCES t(a, b)` + index, link tables with all key columns of both sides;
      writer / reader / `countOf` / `attach` / `detach` / orphan clean-up work on column tuples.
      Tests: `test/provider/relations/composite_relations_test.dart`.

#### Later
- [x] Query by relation ("articles where author.name = …") — `FluentFilter.related` (EXISTS subqueries, §10, 2026-10-27).
- [x] Data on many-to-many links (2026-10-28): `FluentRelation.through<P, L, C>` (read-only list through the link
      model's `one` relations, `parentVia` / `childVia`), `attach(link:)`, `detach` through the link provider (trash,
      sync), links in the trash / expired hidden; an automatic link table becomes a link model by its table name.
      Tests: `test/provider/relations/through_relations_test.dart`.
- [x] Polymorphic relations (2026-10-28): `FluentRelation.oneOf<P>(types:)` (`<name>_type` + `<name>_id`, no SQL FK),
      owner lists with `many(via:)` or found in `buildJson`; the library cascades hard / soft delete and restore, clears
      references of non-owning targets, cleans orphans. Tests: `test/provider/relations/polymorphic_relations_test.dart`.
- [x] Polymorphic follow-ups (2026-10-28): composite target keys (one column per key column, `<name>_<key>`);
      `FluentFilter.related<R>` / `notRelated` / `relatedCount` on the `oneOf` side (an OR over the targets, `R` picks
      one, paths follow the targets that have the next relation).
- [x] Relations without declarations (2026-10-28): fields of `buildJson` holding stored models (`FluentConfig` /
      `FluentDbConfig` / `FluentTableConfig.autoRelations`, default on); one-to-one pairs store one key; ambiguous
      back-references warn; the `autoRelations` hint lists every decision with declarations to copy.
      Tests: `test/provider/relations/auto_relations_test.dart`.
- [x] Reactive streams that also fire when related rows change — touched-table events (reactivity review).
- [x] Query-count test (`test/provider/relations/query_count_test.dart`, `test/helpers/query_counter.dart`): relation loads take the
      same number of statements for 5 or 40 rows, also two levels deep.
- [x] `update(withRelations: true)` returns the number of updated owner rows (checked, test in `query_count_test`).

### 8. Engine
#### Engine correctness review (2026-10-21) — fixed, tests: `test/engine/engine_test.dart`
- [x] 🔴 Collapsing only within one write epoch: a read called after a write is never answered by an earlier read.
- [x] 🔴 Timeouts removed from `ExecutionPolicy` (a started operation is never abandoned; an abandoned write could
      still commit). `chunkSize` removed too (dead option).
- [x] 🔴 `closeAll` stops the engine first: calls already made finish (up to 5 s), telemetry is flushed, the system DB is
      closed, then the files; calls after closing fail with a clear `FluentEngineException` + hint.
- [x] 🟠 One queue per database; the scheduler only looks at the head (20 000 unawaited saves: ~0.6 s, was quadratic).
- [x] 🟠 Expected failures (`Fluent*Exception`, already logged with a hint) are logged at debug, without an alert.
- [x] 🟠 `hardReset` uses a generation counter: tasks still running when it happened no longer touch new counters.
- [x] 🟡 Transaction watchdog (`FluentEngineConfig.transactionWatchdog`, default 2 s): warning + hint, and reads waiting
      behind the transaction run inside it (resolves "awaits a call made outside"); writes keep waiting.
- [x] 🟡 `pauseQueue` from inside a task / transaction: warning + hint, the pause is cancelled (the task goes on).
- [x] 🟡 System telemetry DB: one shared open, `FluentGroup.directory` respected, closed on shutdown.
- [x] Adopted reads see the transaction's uncommitted data (by design, only after the watchdog fired) — the watchdog
      warning now says so, with a hint. Document in the guide.

#### Scheduling / batching / weights — reworked (2026-10-20), tests: `test/engine/engine_test.dart`
- [x] 🔴 Writes are barriers per database: a write starts after every earlier task of its database, runs alone, and no
      later task overtakes it (delete → save and save → findById keep call order; writers are never starved).
- [x] 🔴 Read collapsing works again: the expiry check uses SQLite's `now` (no argument), so identical reads keep one
      fingerprint; "now" is taken when the query runs. Collapsed callers get their own copy of a list result.
- [x] 🟠 Merged saves: only directly adjacent saves of one table with the same strategy / conflictOn are merged; a failing
      batch is re-run call by call (only the faulty call fails); every call publishes its own event (items, tag).
- [x] 🟠 Aging by real waiting time (`SQLitePerformanceConfig.readAgingPerSecond`), applied when the next read is
      chosen; the timer-based queue rewrite is gone. Priorities / weights only order reads between two writes.
- [x] 🟡 No-op background analysis (`analyzeTable` tasks, unused `analyzeStats`, `analyzeInterval`) removed.
- [x] 🟡 Weights: static cost + moving average per `table + action` + relations; merged batches split their duration.
- [x] 🟡 `FluentDbExecutionStrategy` is `concurrent` / `sequential`; queue strategies `fifo` (call order),
      `smartPriority` (priority + aged weight), `smartBatching` (+ merging).
- [x] `findById` batching: queued lookups of one table (same options) share one `IN (...)` query (DataLoader).
- [x] `FluentDb.engineStats()`: queue length, running tasks, waits, collapsed / merged / batched / split counters.
- [x] `clearTable` / `clearDatabase` no longer cancel tasks queued after them (they were called later, they run later).
- [x] One model type (or provider class) for several tables: registry keeps all; init warning with hint; calls by type
      fail with `ambiguousProvider` + hint; relations to such a type are skipped with a hint; change events and
      `watch` are keyed by database + table (`FluentChangeEvent.table` / `dbName`) (2026-10-26).

- [x] 🔴 `FluentDb.transaction` deadlock — fixed in the CRUD rework (zone-scoped transaction, see section 6).
- [x] 🟡 Writes ordered by weight — fixed (write barriers, see above).
- [x] 🟡 Auto-batched saves: isolation of failures — fixed (see above). Merged calls still share the first call's timeout.
- [x] Reads that keep the UI smooth (2026-10-26), tests: `read_performance_test.dart`, `benchmark_test.dart`:
      * `SQLitePerformanceConfig.readConnections` (default 2, 0–4) replaces `maxConcurrentReads`: a pool of read-only
        WAL connections, one read per connection (`FluentReadScope`); reads inside transactions use the transaction;
        no pool for in-memory / non-WAL databases. Sync bookkeeping tables are created at init (never by reads).
      * Big lists are sliced across frames on the UI isolate (`sliceAfterRows` 300, `frameBudget` 4 ms).
      * `FluentEngineConfig.isolateMapping` smart / always / never + `FluentProvider.isolateFactory` (static factory):
        `smart` measures the mapping cost per table and moves lists over half a frame to a background isolate; without
        a factory it shows a hint with the code to add. One mapping plan (`_FluentRowPlan`) for both paths.
      * `package:fluent_sqflite/benchmark.dart` (`FluentBenchmark.run()`) for real devices. FFI, 5000 rows:
        4 parallel reads 8 ms → 2 ms with the pool; longest UI stall of findAll 38 ms → 5 ms sliced → 3 ms isolate.

### 9. Sync
#### Sync — reworked (2026-10-21), tests: `test/provider/sync/sync_test.dart`
- [x] 🔴 Automatic change tracking: `sync_version` (raised by every local write) / `synced_version` (version sent);
      a push marks only the version it sent, so edits made meanwhile stay pending.
- [x] 🔴 Server rows (pull, reactiveSync) are stored as synced: no echo.
- [x] 🔴 `reactiveSync` stores every API row (decided against the database, not the cached page).
- [x] 🟠 Conflicts: a local change not sent yet wins by default; `onConflict(local, remote)` merges (the result is a
      local change to send). Checked again inside the write transaction.
- [x] 🟠 Deletions: trashed rows go in `FluentSyncBatch.deleted`; permanent deletes of rows the server knows leave
      tombstones (`__fluent_tombstones`, `batch.deletedKeys`); the trash purge keeps deletions not pushed yet;
      clearTable / clearExpired / cache resets leave no tombstones. Remote deletes: `FluentRemoteDeleteBehavior`
      auto / soft (no soft delete → warning + kept) / hard / keep; rows with local changes are not deleted.
- [x] 🟠 `syncDeletions` only without a page limit (warning otherwise); cache clears never remove unsent changes;
      `replace` is one transaction; persistence errors are logged and reported as an error event.
- [x] 🟡 Strategies push / pull / full (default); `batchSize`; one sync per provider at a time (a concurrent call
      shares it); no retries for 4xx (except 408 / 429); `FluentFilter` instead of raw where strings.
- [x] Added: `onPull(since)` with the stored last pull (`__fluent_sync_state`, `FluentPullResult.serverTime`),
      `pullConflictOn`, `pendingChanges()`, `reactiveSync(keepWatching: true)`, `saveAll(relationSync: ...)`.
- [x] Owned children of a permanently deleted syncable owner get tombstones before the cascade removes them
      (`_tombstoneCascade`, recursive) (2026-10-26).

### 10. Roadmap — agreed ideas (2026-10-21)

#### Stage 1 status (2026-10-26)
Module reviews are finished: models, schema, relations, CRUD, soft delete, engine, reactivity / telemetry, sync, errors &
logging, lifecycle, reads (pool, slicing, isolate, findPage), docs (README, guide, AI docs, skills, example), analyzer
(2026-10-27), model-level features + sync freshness / status + schema hints (2026-10-27), settings + query stats +
public surface (2026-10-27), API simplification (2026-10-27), issues + diagnostics + tuner (2026-10-27), CRUD + engine review (2026-10-27). 307 tests.
Left in stage 1: quality & infrastructure, device checks of the tuner, and the doc items
in "Docs & examples".

#### Open items to close first
- [x] Errors & logging module review — done (§2).
- [x] Lifecycle: shared model types, in-memory databases, read-only hint — done (2026-10-26).
- [x] Schema: CHECK migration with quarantine, unified converters — done (2026-10-26).

#### Analyzer / optimizer (hints)
- [x] A dedicated hint type (`FluentHint`: title, why, copy-paste code, key for once-per-session dedupe) and log level
      (`FluentLogLevel.hint`), always printed with `debugPrint` in debug builds.
- [x] `FluentDb.onHint` stream.
- [x] `FluentAnalyzer` (2026-10-27, `core/fluent_analyzer/`): observes engine calls, never changes scheduling. Sources:
      `EXPLAIN QUERY PLAN` of slow read shapes (debug / profile, once per shape, outside the queue; index only on a full
      scan with a filter or a temp B-tree for the order; equality → range / order column order; fallback: filtered
      columns no index starts with); measured: unpaged reads ≥ 1000 rows, offset ≥ 1000, slow `LIKE '%…'`, slow nested
      relation loads, writes ≥ 1 s; patterns: ≥ 50 awaited single saves / 2 s, ≥ 30 awaited `findById` / 2 s (N+1),
      ≥ 1000 queued calls, the same read 10× spread over time with unchanged data (polling → `watch`), queue waits ≥ 1 s
      naming the slow call before. Thresholds are constants on `FluentAnalyzer`. The engine's ">300 ms" warning is gone
      (debug log + the analyzer).
- [x] One mechanism: `FluentDb.optimizationReport()` = hints of this run + hints derived from the persisted cost model
      (same keys); `FluentOptimizationTip` removed.
- [x] `setupLogging(hints: false)` (out of console / onRecord, still on `onHint` and in the report) and
      `muteHints: {'key', 'prefix:*'}` (dropped everywhere); printed hints show their key and the mute snippet.
- [x] Hints reach `onRecord` (level `hint`, `analyzerHint`) whatever the level; never printed in release.
      `FluentEngineConfig.analyzeInRelease` (default false): cheap checks only, for Sentry / Crashlytics via `onHint`.
- [x] Schema sources (2026-10-27, `FluentAnalyzer.onSchema` at init): `enumValues`, `redundantIndex`, `syncKey`;
      foreign keys are indexed by `indexReferences` (`refIndex` when off); soft delete / owned-children combinations
      were already init warnings.

#### Model-level features (less raw SQL)
- [x] Queries by relation (2026-10-27): `FluentFilter.related` / `notRelated` / `relatedCount`, paths, deferred
      conditions in `FluentFilter.deferred` resolved by the provider at execution (`_withDeferredResolved`).
- [x] Aggregates (2026-10-27): `sum` (0 when empty) / `avg` / `min<V>` / `max<V>` / `countDistinct` / `aggregate`
      (outer query for `having` / `orderBy` on result names); `watchValue`.
- [x] Projections (2026-10-27): `findMaps(columns:, distinct:)` (decoded values), `pluck<V>`.
- [x] `indexReferences` global + per database (database wins), `refIndex` hint (2026-10-27).
- [x] Cursor (keyset) pagination: `findPage(orderBy: ..., after: page.next)` (2026-10-26).
- [x] Full-text search (2026-10-27): `FluentIndex.fullText`, `search` (FTS5 rank), `FluentFilter.search`; FTS5 → FTS4
      fallback (info log), `fullText: off` → `LIKE` + hint; triggers keep the external-content table in step; rebuilt
      on schema revision change.
- [x] `reactiveSync` `FluentSyncOptions.maxAge` (2026-10-27): fetch time per query in `__fluent_fetch_state`, marked only
      after the answer was stored.
- [x] `watchSyncStatus` (2026-10-27) + `syncWithServer(retries:, retryDelay:)` (backoff × 2, ±50 % jitter). "On reconnect"
      stays the app's job (no connectivity plugin in the core); documented with connectivity_plus.

#### Bigger features (later)
- [x] Many-to-many with data on the link (`through:` model) — §7.
- [x] Polymorphic relations — §7.
- [x] Heavy row → model mapping in an isolate for big lists (2026-10-26).
- [x] Migration preview (2026-10-28): `FluentDb.planMigrations(groups, runCode:)` → `FluentMigrationPlan` (typed
      `FluentSchemaChange`s, captured issues, `losesData`, `rebuilds`, `skippedCode`): the real sync in a rolled-back
      transaction, before init; `FluentGroup.onMigrationPlan` refuses a start (`migrationRefused`);
      `FluentTestDb.plan`. Tests: `test/provider/schema/migration_plan_test.dart`.

#### Settings, hints and analysis — one model (before 2.0)
The knobs grew one by one and overlapped; reviewed together, centralized and simplified.
- [x] Settings (2026-10-27, `test/db/settings_test.dart`): three levels, the narrower wins — global `FluentConfig`
      (was `FluentEngineConfig`; `init(config:)`, `FluentDb.configure`) → database `FluentDbConfig` (was
      `SQLitePerformanceConfig`, `FluentGroup.config`) → table `FluentTableConfig` on the model (moved from the
      provider). `trashRetention` / `indexReferences` / `fullText` on all levels, `readConnections` global + database.
      Removed: `purgeDuration`, `isDev`, `softDeleteRetention(Period)`, `globalPolicy` (→ `defaultPolicy`),
      `maxPauseDuration` + `alertPauseDuration` (→ `pauseWatchdog`, auto-resume + warning; `pauseTimeout` code gone),
      `saveInterval`, `telemetryRetention`, `enableConcurrentReads`, `queueStrategy`, `FluentDbExecutionStrategy`,
      `readAgingPerSecond` (constant), `bulkImport` / `readOnlyOptimized`, `changeCurrentPerformanceConfig`,
      `sanitizeTypes`. `restart` keeps the global settings (it used to fall back to the defaults).
- [x] Query stats (2026-10-27): kept per database in `__fluent_stats` (only changed shapes, idle database, ≥ 5 min apart,
      on close; in-memory / read-only in memory); rows returned + per-table mapping cost (smart isolate mapping knows
      it right after start); `fluent_system.db` removed and deleted at start; `FluentDb.queryStats()` replaces
      `report()` / `dumpReport()`. One wall clock `FluentClock` (`testNow`) for timestamps, trash, expiry, sync, stats.
- [x] Public surface (2026-10-27): extensions on `String` / `Map` / `DateTime`, `ExecutionPolicy.withTag`,
      `FluentDbAction.isWriteOp`, `FluentUtils`, `fluentSqlLiteral` hidden from the export; the registry index is
      private; dead `SortDirection`, `TableComplexity`, `FluentSyncOptions.sortDirection`, task / policy `toMap` removed.
- [x] One place that decides "observe / suggest / act" (2026-10-27): `FluentDiagnostics` (global + per database:
      cost model, hints, hints in release, tuner) replaces `analyzeInRelease` + `hints` + scattered checks.
- [x] One issue pipeline (2026-10-27, `test/log/diagnostics_test.dart`): `FluentIssue` for hints / automatic changes /
      warnings / background errors (every former warning has a kind, a key and a required fix), `onIssue`, `report()`
      grouped by impact, `mute`; one set of thresholds in the analyzer (reads 100 ms average, writes 500 ms, queue 1 s);
      the engine alerts and `FluentSystemAlert` / `onAlert` removed; exceptions without a hint closed (source test).

#### DB tuner — first version done (2026-10-27), tests: `test/log/diagnostics_test.dart`
- [x] `FluentDiagnostics.auto` / `FluentTuning` levers (each switchable): indexes (verified, reverted, capped),
      readConnections (cores), memory (pressure → shrink + small cache, restored), background (maintenance on pause,
      periodic maintenance deferred), checkpoints (after writes / on pause), frameBudget (refresh rate).

Original plan:
Do it after the settings review above; the analyzer already observes, the tuner would also act.
- Modes, global + per database (database wins): `off` (no suggestions, no actions — the cost model keeps running for
  scheduling), `recommend` (default: hints only, as today), `auto` (applies safe changes at run time and reports them).
- `auto` levers (reversible, bounded, with hysteresis, never inside a transaction, each change logged and listed in a
  report, learned values persisted for the next start): read connections (cores, real parallelism), page cache size
  (memory; `PRAGMA shrink_memory` on memory pressure), frame budget (display refresh rate), maintenance frequency
  (`PRAGMA optimize`, trash purge, telemetry flush; less in background), WAL checkpoints (write volume).
- Automatic indexes in `auto` (on by default there, may change): from `EXPLAIN` findings, created when idle after
  several slow runs, capped in number, reported with the code to make them permanent in the model.
- At database creation: choose what can only be set then (`auto_vacuum = INCREMENTAL`, page size) and review the
  schema (suggestions).
- Device signals: without plugins — CPU count, app lifecycle, memory pressure, refresh rate; battery / thermal through
  a hook the app calls (`FluentDb.reportDeviceState(lowPower: ...)`, e.g. from battery_plus).

#### API simplification review — done (2026-10-27), tests: `test/provider/crud/api_test.dart`, `test/docs/doc_examples_test.dart`
- [x] Public / internal split: `lib/fluent_sqflite.dart` exports only the public API (explicit `hide` list); the library
      imports `src/internal.dart`. Provider internals (`db`, `executor`, key helpers, `internalExecute`, registration)
      live in the hidden `FluentProviderInternals`, model internals in `FluentStorableInternals`, registry internals in
      `FluentDbInternals`; internal enums in `utils/fluent_internal_enum.dart` (`FluentDbAction`). Dead code removed
      (`mapToModel*`, `transformResponseAsync`, `createTable`, `generate*Sql`, `defaultForeignKey`, `setTableName`, ...).
- [x] `FluentDb` static only; lookups `providerOf<T>()` / `provider<P>()`; lifecycle `init`, `close`, `restart`,
      `clear`, `deleteDatabases`, `isOpen`; `cleanOrphans` / `forgetQueryStats` statics; `toggleLogging` removed.
      `clear` no longer skips user tables whose names match `__fluent_%` with `_` as a wildcard (LIKE now escaped).
- [x] Calls follow the model's mixins: trash calls only for `FluentSoftDeletable`, relation calls only for
      `FluentRelations` (relations moved from the provider to the model) — on the provider, `FluentDb` and the model.
- [x] Reads: `relations: FluentLoad.none / eager / all` (replaces `ignoreLazy`, `maxDepth: 0` = unlimited is gone);
      `model.loadRelations()` returns a loaded copy (`ensureLoaded` / `getRelation` / dynamic fields removed);
      `findRelated`, `findParents(via:)`, `countRelated`, `findByIds`, `FluentFilter.ids`, `isDeleted`.
- [x] `tag:` on every write (provider too), `ExecutionPolicy` = priority + collapsing + 3 presets; change events carry
      `FluentChangeKind`; `timeToLive` replaces `expiryDate` / `expiryDuration`; `FluentDataEvent` helpers trimmed.
- [x] Reads honour `FluentClock.testNow` for expiry (they used SQLite's clock only).
- [x] `includeDeleted:` / `delete(hard:)` removed: soft-delete models get `provider.trash` (find / count / watch /
      restore* / deleteForever* / empty) and `provider.withTrash` (reads that see the trash); `FluentDb.trash<T>()`,
      `withTrash<T>()`, `note.deleteForever()`. Tests: `soft_delete_test.dart`.
- [x] Sync reviewed together (see "Sync review" below).

#### Sync review (2026-10-27), tests: `sync_test.dart`, `sync_status_test.dart`
- [x] Fixed: `reactiveSync` moved the `since` of `syncWithServer` (now `applyPull(rememberAs:)` only from a pull); the
      next `since` is taken before `onPull` (rows changed during a slow pull are not skipped); mirror deleted every row
      when fetched rows carried no local key (now matched by `serverKey`, refused without one); errors logged twice.
- [x] `FluentTableConfig.serverKey`: pull, `deletedKeys` (both ways), tombstones and `watchRemote` match by the server's
      id; `serverKeyIgnored` / `tombstoneWithoutKey` issues; the `syncKey` hint is skipped with a server key.
- [x] `FluentPushResult` (`updated` stored as synced by key, `rejected` stay pending and are skipped in the same sync),
      `FluentPullRequest` / paged pulls (`hasMore`, `cursor`; `since` moves after the last page),
      `FluentConflictPolicy` (`keepLocal`, `keepServer`, `merge`).
- [x] Optimized: conflicts of a pull read in a few queries (was one per row), mirror reads only key columns, push
      batches in key order with a default size of 500, one retry rule for both APIs (exponential + jitter, no retry
      on 4xx except 408 / 429).
- [x] `reactiveSync` → `watchRemote` with flat parameters; `FluentSyncOptions` and the pipeline enums removed.

#### CRUD + engine review (2026-10-27), tests: `api_test.dart`, `engine_test.dart`
- [x] Fixed: `FluentLoad.none` weighted as unbounded depth; `FluentDb.clear` doc (no cancellation, ordered write);
      `conflictOn` hint code.
- [x] Dead code removed: `cancelTask`, `hardReset`, `destroy`, `FluentErrorCode.cancelled` / `engineReset`, task
      `isSystem` / `force` / `relations` / `statsKey`, `_dbTables`, `FluentDbAction.none` / `readSchema`, five
      `TableHelper` fields, `hasRelationLinks`, `matchFilter`.
- [x] Hot paths: model facts cached in the provider (no model sample per call), lazy task fingerprint / weight / cost
      key, one task copy in `executeTask`, debug lines built only when debug is on, read selection without sorting the
      queue, lookup grouping in one pass.
- [x] `FluentUpdate` (increment / decrement / now / toggle) in `updateById` / `updateWhere`; `existsWhere`.
- [x] Keys of batched lookups from the stored rows, decoded per column (`FluentBatchKeys.fromRows`, default;
      `fromModels` reads them from `buildJson`) (2026-11-05).

#### Quality & infrastructure
- [x] Query-count test guarding against N+1 in relation loading.
- [x] Benchmarks (queue, save, relation loads, deletes) to catch performance regressions:
      `FluentBenchmark.runScenarios` with baselines and N+1 detection (2026-11-05).
- [x] Test helpers for users (2026-10-27): package `packages/fluent_sqflite_test` (`setUpFluentTests`, `FluentTestDb`
      in memory / persistent + `restart`, `FluentTestClock`, `settle`, `issues` / `failOnWarnings`); the library's own
      tests use it. The benchmark moved to `packages/fluent_sqflite_benchmark`.

### Docs & examples
- [x] Documentation for AI assistants (2026-10-26): `llms.txt`, `doc/ai/` (README with the ten rules, `migrations.md`
      in the "search for / before → after" format, `error-codes.md`, `agents-snippet.md`) and agent skills in
      `skills/fluent-sqflite-*` (Dart package skills + agentskills.io spec; `test/docs/docs_test.dart` checks names,
      descriptions, sizes, links, reference copies and the error-code table; `doc_examples_test.dart` runs the examples).
- [x] 2.0 ships without `@Deprecated` aliases for 1.x names (decided 2026-10-26): the migration table and the
      upgrade skill cover the move.
- [x] Deprecation policy from 2.0 on (rule, in CLAUDE.md): renames keep the old name with `@Deprecated` for at least
      one minor version and get a row in `doc/ai/migrations.md` (+ the copy in the upgrade skill).
- [x] README with installation, quick start, positioning (2026-10-26).
- [x] `example/` app (REST → cache → paged list with `reactiveSync` / `findPage`, benchmark screen) (2026-10-26).

### ✅ Completed earlier
- [x] Stream-based data fetching.
- [x] SoftDelete.
- [x] syncWithServer.
- [x] Fluent engine / system DB refactor.
