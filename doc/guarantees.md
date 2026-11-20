# Guarantees

What fluent_sqflite promises, and how each promise is checked. There are 31 guarantees (the numbers `G1` ... `G31` are
stable ids: the test names carry them). Where a promise has a limit, it is stated next to it and collected under
"Limits" at the end. A promise the code cannot keep is a bug; it is fixed (see `FIXED_ISSUES.md`) or listed as a
limit (see `KNOWN_BUGS.md`).

## How they are tested

| Technique | What it does |
|---|---|
| **Fuzz** | A seeded generator produces random calls; every step is applied to the database and to a plain Dart reference model, and the visible state is compared. A failure prints the seed (replay with `FLUENT_SEED=<seed>`). Every fuzz file passed 500 seeds (`FLUENT_FUZZ=500`); the normal suite runs 25 per file. |
| **Fault injection** | A test database factory fails the n-th statement (every statement in turn), statements of one kind, or random ones, with real SQLite errors (`IOERR`, `FULL`, `BUSY`, `READONLY`). |
| **Crash copies** | The database files are copied before every statement of a write; each copy must open intact and hold the state before or after the commit, never a mix. |
| **Chaos** | Long seeded mixes of every call kind, unawaited and nested calls, cross-database transactions, random faults and `init` / `close` / `restart` / `pauseQueue` at random moments; afterwards everything has settled, the data equals the committed state and the library works normally. 500 seeds passed. |
| **Fixtures and golden files** | Real database files written by 1.x, 2.0.0-dev.1 and dev.2 are opened by the current version; generated DDL, stored forms and cursor text are compared with reviewed golden files. |
| **Catalogues** | Table-driven lists of wrong input, settings and models with the expected outcome. |

Every scenario test also checks `PRAGMA integrity_check` / `foreign_key_check` (G19) and that every reported issue has a
fix (G26).

## Data

**G1. Atomic.** A call, or a `FluentDb.transaction`, applies completely or not at all: rows, relations, cascades, link
tables, sync versions and tombstones, schema history. A caught error inside a transaction rolls back only the failed
call. *Tested by:* fault injection at every statement of every write kind (save, saveAll, updates, deletes, soft delete,
transactions, savepoints, relation saves, clear, cleanOrphans, migrations, sync), merged batches, crash copies.
*Note:* `FluentDb.clear` empties its tables in passes inside one transaction and retries a table whose delete failed
in a later pass (a parent waits for its restricting children). The final state is complete, never partial; a retry that
absorbs an error other than a restricting foreign key is published as a `clearRetried` warning (G25).

**G2. Rollback restores the models.** After a rollback (call, transaction, savepoint) the models are as before: keys,
`deletedAt`, timestamps, relation lists. *Tested by:* rollback tests per call kind and the relation fuzz.

**G3. A save never deletes what it did not load.** Saving removes only children and links that were part of the loaded,
unrestricted view: relations with `limit`, `where`, trashed or expired rows, relations that were not loaded, and other
views over the same column (`FluentLoad.all`) are never treated as "missing". A model rebuilt from a read
(`copyWith`) is covered through its lists: each list a read builds remembers its relation, owner and whether it was
loaded, so the same list in a new model removes only what the read showed; an empty list on a model the app built
removes nothing (`relationListKept`) unless `relationSync: replace`. *Tested by:* relation tests and the relation fuzz
(copyWith rebuilds of every load mode and view, built owners with empty lists). *Limit:* a list the app builds with
items (`[...list]`, a new list) is the full state: under a relation without `limit` it replaces the owned rows.

**G4. Schema changes keep data.** A start with a changed model keeps every row and value: renames move, removals are
archived, only explicit steps drop. Rows a new `CHECK` / `UNIQUE` rejects go to a quarantine table
(`__fluent_rejected_<table>_r<rev>`); their children stay in place, and their reference is reported as
`danglingReferences` (naming the quarantine table, with a fix). It is whole again once the parent row is moved back.
A name swap (`a` from `b`, `b` from `a`) exchanges the values once; `oldName` onto a name a live column holds archives
the old holder ("replaced by ...") and then renames. *Tested by:* random version chains (add, remove, rename, type
change, index, unique) of the schema fuzz, a failure at every statement of a migration, crash copies of a migration.

**G5. Upgrades keep data.** Databases written by 1.x, 2.0.0-dev.1 and dev.2 open with the current version without
loss; stored-format conversions are lossless, run once and are reported (`storedFormatAdopted`, `legacyNameAdopted`).
*Tested by:* real fixture files with a manifest of the expected rows.

**G6. Round trip.** Every supported value (all codecs, converters, enums, null, extremes) reads back equal to what was
saved, including the UTC flag; a documented precision loss is reported (`precisionLost`). *Tested by:* a value
matrix through save, read, `findMaps`, filter, pluck, update and `watch`, random values, golden stored forms.
*Limit:* `-0.0` is stored as `0.0` (SQLite does that).

**G9. Soft delete is reversible.** delete, then restore gives back identical rows, cascaded children included;
`trash.empty` / the retention purge remove only rows trashed longer ago than the period. *Tested by:* trash tests per
call form, relation cascades, the CRUD and relation fuzz. *Limit:* a soft-delete stamp is `max(now, last + 1)` (two
deletes never share a stamp), so after the clock goes back a stamp can be later than now.

**G19. Integrity, whatever happens.** After any scenario of the test plan, failures and crashes included,
`integrity_check` is ok, `foreign_key_check` is empty and no committed value is lost or changed. *Tested by:* the
check at the end of every scenario test, crash copies, chaos. *The one documented exception* is G4's quarantine: while
rejected parent rows sit in a quarantine table, their children keep their reference and `foreign_key_check` lists them
(reported as `danglingReferences`); moving the parent row back makes it empty again.

**G21. Only explicit deletion.** Rows and columns disappear only by an explicit call (delete, hardDelete, clear,
clearTable, deleteDatabases, a migration step, a relation save under G3, a sync mode that deletes) or by the library's
own documented clean-up: trash past `trashRetention`, expired cache rows (`clearExpired`, also run at start), archives
past `archiveRetention`, dangling references (`cleanOrphans`, never into quarantine) and its own bookkeeping tables.
Nothing else, ever. *Tested by:* reads, watches, every save strategy, restarts, clock moves and maintenance against a
row count; the schema fuzz.

**G29. Exactly what was asked.** A read returns exactly the requested rows and fields (no `_fs_metadata`,
`sync_version`, `synced_version`, `expiry_date` or archives unless asked, also for `findMaps()` without columns and for
`fromCacheJson`); a save stores exactly the model's fields; an update or patch changes only the given fields;
`updateAll` returns the number of distinct rows it updated. *Tested by:* byte-for-byte comparisons of untouched rows
and columns.

## Behaviour

**G7. Order and read-your-writes.** Writes apply in call order, also when unawaited (inside one transaction the calls
run in call order too); a read called after a write sees it; merging, collapsing, batching and the read pool never
change a result. Merged saves insert rows in call order (`saveAll([id 6, new])` gives the new row 7). *Tested by:*
random bursts of unawaited calls on two databases compared with a serial run (one connection and with a read pool).

**G8. Consistent visibility.** `find`, `findById`, `count`, `exists`, `findPage`, `aggregate`, `pluck`, `watch` and
relations agree on which rows exist (trash, expiry, `withTrash`, `includeExpired`). *Tested by:* the same scope checked
through every read call.

**G11. Watch converges.** After any change (also by relations, cascades, sync, clear, cleanOrphans) a watch emits a
value equal to a fresh query; a cancelled watch emits nothing. *Tested by:* watches compared with fresh queries after
cascades, links, SET NULL and the value matrix.

**G16. Paging is exact.** Walking `findPage` visits every visible row exactly once, also with inserts and deletes
between pages and with a cursor kept as text. *Tested by:* the paging fuzz.

**G17. Formats are deliberate.** Generated DDL, stored forms (`_fs_metadata`, dates, stamps, enums), cursor text and
migration plans match golden files; a change is a reviewed golden update plus a CHANGELOG line. *Tested by:* golden
files (`test/golden`). *Limit:* the FTS4 path is untested (the SQLite of the tests has no FTS4).

**G30. Isolation.** A call on one table or database never changes another, except through declared relations and their
cascades; the same table names in several databases never mix. *Tested by:* identical calls on two databases at once,
clear / rollback on one, chaos on one database with the other checked.

**G31. Idempotent starts and rounds.** Starting twice with the same models changes nothing the second time; a sync round
with nothing new changes nothing; a repeated save of an unchanged model writes the same state. *Tested by:* byte
comparison of the file after the second start, an echo pull, the schema and sync fuzz.

## Sync

**G10. Sync loses and duplicates nothing.** Every local change is pushed until the server accepts it; pulls never
overwrite unpushed local changes except by the chosen conflict policy; clears that drop local changes report it. This
includes a key deleted, saved and deleted again before a push, a push whose answer was lost, and a local change kept
over a server row that was then deleted. *Tested by:* the sync fuzz (soft and hard delete models) and tests per case.

**G23. Push is exact.** A push sends every selected change (rows and deletions) once per round, marks as synced exactly
what the server accepted, keeps the rest pending and reports truthful counts (pushed / rejected / pending);
`pendingChanges()` and the per-row state always match. A push commits a "sent" marker (`synced_version` -1) before
`onPush`, so a change whose answer is lost stays pending. *Tested by:* pushes in pages, failed and thrown answers,
edits during a push, faults while marking.

**G24. Pull follows the chosen mode.** Every store mode, delete behaviour and conflict policy does exactly its
documented effect; the `since` cursor moves only after a successful, complete pull; a page answered after a cancel is
not stored. `keepServer` restores a trashed unpushed row, a server row sent again after a pushed delete comes back
from the trash, `merge` skips trashed rows. *Tested by:* a matrix of modes, policies and states, cancels, faults while
storing a page. *Limit:* a paged `watchRemote` holds the answered keys of all pages until the last page.

## Robustness

**G12. No hang.** Every public call completes, with a value or a typed error: inside transactions and tasks, nested,
across databases, during close / restart / pause. A call that would close a wait cycle between databases (a
transaction holding A waits for B while B's transaction waits for A) fails with `FluentErrorCode.deadlock`
(`FluentEngineException`) instead of waiting; the other side completes. A read on another database counts as waiting
while the transaction watchdog cannot let it in (a write queued before it there, or the watchdog off); a read the
watchdog lets in is never refused. *Tested by:* every public call made from every place where app code runs inside
the library, A to B and B to A at once, A to B to C to A, reads behind a queued write (two and three databases,
watchdog on and off), chaos with cross-database calls and reads in both directions.

**G13. No crash.** Errors reach the app only through the returned Future / Stream as typed `FluentException`s with a
hint; nothing escapes from timers, streams, isolates or callbacks. SQL errors of `BEGIN`, `COMMIT`, `RELEASE`,
`cleanOrphans` and `purgeArchivedColumns` are typed (`FluentQueryException`); an exception thrown by app code inside a
write (e.g. `buildJson`) arrives as `FluentArgumentException` with the original as `cause`; sync errors are
`FluentSyncException`. *Tested by:* fault injection of every `FaultKind`, the static scan for raw throws.

**G14. Crash safe.** A process stopped at any point of a write leaves a database that opens, passes `integrity_check`
and holds exactly the last committed state. *Tested by:* crash copies before every statement of single and merged
writes, transactions, trash and clear, sync bookkeeping and a migration.

**G18. Survives anything, recovers.** Under any random mix of calls, failures, `init` / `close` / `restart` at random
points and simulated crashes: no hang, no crash, no partial data; every pending call completes; once the failure stops
the library works normally again (no stuck queue, pause, transaction scope or lock) and the data equals the last
committed state. *Tested by:* chaos runs, 500 seeds.

**G20. Outside influence is survived.** A locked or busy file, a full disk, a read-only or deleted file, a garbage file,
DDL or writes by another connection, the clock moved back or forth, a process that dies: the library reports it, keeps
the data intact and recovers when the cause is gone. *Tested by:* fault injection and real second connections.
*Also tested by:* app pause / resume / detach through the Flutter binding (`test/db/lifecycle_guarantees_test.dart`): calls during the pause complete and see earlier writes, the background work (optimize, checkpoint) runs only on an idle database, a detached app loses no committed row.

**G22. Bad input never breaks it.** Wrong types, `NaN` / infinities, huge or odd strings, deep JSON, nulls in required
fields, too many parameters, unknown enum values, bad cursors and filters: converted when that is lossless, otherwise
the call is refused with a typed error and a hint, and nothing is written. Text that is not a number, or an integer
beyond int64, into an `INTEGER` / `REAL` column is refused (`unsupportedValue`; numeric text still converts); a
`String` with a lone UTF-16 surrogate is refused. *Tested by:* catalogues of wrong input, random strings, 50 000 ids.

**G27. Wrong settings never kill it.** Invalid, extreme or contradictory settings fall back to a safe value with a
`configFallback` warning (or are refused at `init` with a typed error): negative or huge `trashRetention` /
`archiveRetention`, negative `historyLimit` / `busyTimeout`, out-of-range `readConnections`. They never corrupt a
database or stop the library. *Tested by:* a catalogue of settings, random settings between restarts.

**G28. Wrong models never cost data.** Misdeclared models, relations and keys (duplicate or missing columns, a key that
changes type, relations to unregistered or ambiguous models, cycles, `buildJson` / `fromCacheJson` that disagree or
throw, an empty table name) are refused with a typed error or handled with a warning (duplicate column names:
`schemaFallback`), never data loss, never a broken file. `missingColumns` may override a `buildJson` field (a
converter) without a warning. *Tested by:* a catalogue of bad models.

## Visibility

**G15. Private.** SQL arguments, values and paths never reach messages or logs unless `showSqlArguments`; this holds
for the title, details and fix of issues delivered through `onIssue` / `report()` too. *Tested by:* planted secrets
searched in every log record and error text.

**G25. Every problem is visible.** Each failure, fallback or automatic change produces a log record (errors once, as
documented) and reaches either the caller (typed error) or `FluentDb.onIssue` / `report()`; nothing fails silently.
`FluentDb.clear` failures are logged with an I/O-specific hint. *Tested by:* a static scan of every throw site and
tests per kind.

**G26. It fixes what it can and says how.** A problem the library can solve safely is solved and reported as `autoFix`;
every other one carries a hint with a concrete fix. Every `FluentIssue` has a fix, every `FluentException` a hint.
*Tested by:* a static scan of every `FluentLog.issue` / `FluentIssue(` / typed exception in `lib/`, plus a check of
every issue of every scenario test.

## Limits

* `-0.0` is stored as `0.0` (SQLite normalizes it).
* A soft-delete stamp is `max(now, last + 1)`: after the clock goes back, a stamp can be later than now.
* The FTS4 path is untested (no FTS4 in the SQLite of the tests).
* Rows a new constraint rejects live in a quarantine table; until the parent row is moved back its children are
  reported as `danglingReferences` (the exception to G19).
* The limits of `KNOWN_BUGS.md` ("Known limits") apply: a new non-empty list in a rebuilt model (G3), unreadable
  `_fs_metadata`, millisecond timestamps (`precisionLost`), a paged `watchRemote` holding its keys.

Run the long tests yourself: `FLUENT_FUZZ=500 fvm flutter test` over the `*_fuzz_test.dart` files and
`test/regressions/chaos_test.dart`. `FLUENT_FUZZ_FROM=<n>` starts at sequence `n` (another slice of a big run);
`bash tool/fuzz_parallel.sh <total> <shards> [from]` runs the slices at once, each in its own copy of the checkout;
`FLUENT_TEST_TMP=<dir>` puts the test databases on another disk.

The stress tests (`test/stress`) check the same guarantees on a big world: a table of wide and huge rows, deep
relation trees and thousands of related records (with statement-count guards against N+1), 200 tables in 10
databases under concurrent callers. They run small in the normal suite; `FLUENT_STRESS=20` scales them up (sizes,
timings and memory go to `build/stress_report.md`; timings are reported, never asserted).
