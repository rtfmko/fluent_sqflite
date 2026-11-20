# fluent_sqflite: test plan (guarantees round)

Goal: prove to users that fluent_sqflite never loses or damages their data and behaves as documented in every case.
Audit 2 (2026-11-17) read the code; this round **runs** it: random sequences against a reference model, golden
formats, upgrades from real old databases, injected failures, simulated crashes and chaos runs.

Status: done (2026-11-18). 2545 tests, 5 skipped (4 environment, 1 limit: `-0.0`); every fuzz file passed 500 seeds
(`FLUENT_FUZZ=500`), chaos 500 seeds. Result: `doc/guarantees.md`, `FIXED_ISSUES.md` ("Guarantees round"),
`KNOWN_BUGS.md`. The rest of this file stays as the record (agreed with the user 2026-11-17).

## Starting point

- 1821 tests, line coverage 98.9% (9245 / 9352; `bash tool/mirror_test.sh coverage --coverage` then
  `bash tool/coverage_report.sh` → `.coverage/summary.txt`, `.coverage/uncovered.txt`, git-ignored). The 107 uncovered
  lines are mostly defensive branches. Audit 2 found 40 bugs in covered code: what is missing is **combinations**,
  **old data**, **failures** and **misuse**, not lines.

## Guarantees (the contract)

Every test of this round names the guarantee it checks (`G4: ...` in the test name). A guarantee the code cannot keep
is a bug (fixed, or a skipped test `BUG: ...` for the fix wave) or a documented limit (`KNOWN_BUGS.md` → Known limits
and the guide). Afterwards this list becomes the user-facing page `doc/guarantees.md`.

### Data

| Id | Guarantee |
|---|---|
| G1 | **Atomic.** A call or a `FluentDb.transaction` applies completely or not at all: rows, relations, cascades, link tables, sync versions / tombstones, schema history. |
| G2 | **Rollback restores the models.** After a rollback (call, transaction, savepoint) the app's models are as before: keys, `deletedAt`, timestamps, relation lists. |
| G3 | **A save never deletes what it did not load.** Saving removes only children / links that were part of the loaded, unrestricted view (limit, where, trash, expiry, unloaded relations). |
| G4 | **Schema changes keep data.** A start with a changed model keeps every row and value: renames move, removals archive, rejected rows are quarantined with their children; only explicit steps drop. |
| G5 | **Upgrades keep data.** Databases written by 1.x, 2.0.0-dev.1 and dev.2 open with the current version without loss; stored-format conversions are lossless, run once and are reported. |
| G6 | **Round trip.** Every supported value (all codecs, converters, enums, null, extremes) reads back equal to what was saved, incl. the UTC flag; documented precision limits are reported (`precisionLost`). |
| G9 | **Soft delete is reversible.** delete → restore gives back identical rows, cascaded children included; purge removes only rows past the retention. |
| G19 | **Integrity, whatever happens.** After any scenario of this plan — failures and crashes included — `integrity_check` is ok, `foreign_key_check` is empty, and no committed value is lost or changed. |
| G21 | **Only explicit deletion.** Rows and columns disappear only by an explicit user call (delete, hardDelete, clear, clearTable, deleteDatabases, a migration step, a relation save under G3, a sync mode that deletes) or by the library's own documented clean-up: trash past `trashRetention`, expired cache rows when asked (`clearExpired`), archives past `archiveRetention`, dangling references (`cleanOrphans`, never into quarantine), its own bookkeeping tables. Nothing else, ever. |
| G29 | **Exactly what was asked.** A read returns exactly the requested rows and fields (no internal columns such as `_fs_metadata`, `sync_version`, expiry, archives — unless asked); a save stores exactly the model's fields; an update / patch changes only the given fields; nothing is added, dropped or altered on the way. |

### Behaviour

| Id | Guarantee |
|---|---|
| G7 | **Order and read-your-writes.** Writes apply in call order; a read called after a write sees it; merging, collapsing, batching and the read pool never change a result. |
| G8 | **Consistent visibility.** find / findById / count / exists / findPage / aggregate / pluck / watch / relations agree on which rows exist (trash, expiry, `withTrash`, `includeExpired`). |
| G11 | **Watch converges.** After any change (also by relations, cascades, sync, clear, cleanOrphans) a watch emits a value equal to a fresh query; a cancelled watch emits nothing. |
| G16 | **Paging is exact.** Walking `findPage` visits every visible row exactly once, also with inserts / deletes between pages and with a cursor kept as text. |
| G17 | **Formats are deliberate.** Generated DDL, stored forms (`_fs_metadata`, dates, stamps, enums), cursor text and migration plans match golden files; a change is a reviewed golden update + a CHANGELOG line. |
| G30 | **Isolation.** A call on one table / database never changes another, except through declared relations and their cascades; same table names in several databases never mix. |
| G31 | **Idempotent starts and rounds.** Starting twice with the same models changes nothing the second time; a sync round with nothing new changes nothing; a repeated save of an unchanged model writes the same state. |

### Sync

| Id | Guarantee |
|---|---|
| G10 | **Sync loses and duplicates nothing.** Every local change is pushed until the server accepts it; pulls never overwrite unpushed local changes except by the chosen conflict policy; clears that drop local changes report it. |
| G23 | **Push is exact.** A push sends every selected change (rows and deletions) once per round, marks as synced exactly what the server accepted, keeps the rest pending, and reports counts (pushed / rejected / pending) truthfully; `pendingChanges()` and the per-row state always match. |
| G24 | **Pull follows the chosen mode.** Every store mode, delete behaviour and conflict policy does exactly its documented effect — update, insert, delete, keep — and nothing else; the `since` cursor moves only after a successful, complete pull. |

### Robustness

| Id | Guarantee |
|---|---|
| G12 | **No hang.** Every public call completes (value or typed error): inside transactions and tasks, nested, across databases, during close / restart / pause. |
| G13 | **No crash.** Errors reach the app only through the returned Future / Stream as typed `FluentException`s with a hint; nothing escapes from timers, streams, isolates or callbacks. |
| G14 | **Crash safe.** A process stopped at any point of a write leaves a database that opens, passes `integrity_check` and holds exactly the last committed state. |
| G18 | **Survives anything, recovers.** Under any random mix of calls, failures (any statement, any moment), `init` / `close` / `restart` at random points and simulated crashes: no hang, no crash, no partial data; every pending call completes; once the failure stops (or after a restart) the library works normally again — no stuck queue, pause, transaction scope or lock — and the data equals the last committed state. |
| G20 | **Outside influence is survived.** A locked / busy file, a full disk, a read-only or deleted file, DDL or writes by another connection, the clock moved back or forth, the app paused / resumed / killed: the library reports it, keeps the data intact and recovers when the cause is gone. |
| G22 | **Bad input never breaks it.** Wrong types, `NaN` / infinities, huge or odd strings, deep / cyclic JSON, nulls in required fields, too many parameters, unknown enum values, bad cursors / filters: converted when that is lossless, otherwise the call is refused with a typed error and a hint and nothing is written. |
| G27 | **Wrong settings never kill it.** Invalid, extreme or contradictory library / database / table settings fall back to a safe value with a `configFallback` warning (or are refused at `init` with a typed error); they never corrupt a database or stop the library. |
| G28 | **Wrong models never cost data.** Misdeclared models, relations and keys (duplicate / missing columns, a key that changes type, relations to unregistered or ambiguous models, cycles, `buildJson` / `fromCacheJson` that disagree or throw) are refused with a typed error or handled with a warning — never data loss, never a broken file. |

### Visibility

| Id | Guarantee |
|---|---|
| G15 | **Private.** SQL arguments, values and paths never reach messages or logs unless `showSqlArguments`. |
| G25 | **Every problem is visible.** Each failure, fallback or automatic change produces a log record (errors once, as documented) and reaches either the caller (typed error) or `FluentDb.onIssue` / `report()`; nothing fails silently. |
| G26 | **It fixes what it can and says how.** A problem the library can solve safely is solved and reported as `autoFix`; every other one carries a hint with a concrete fix (copy-paste code where possible). Every `FluentIssue` has a fix, every `FluentException` a hint. |

(G-numbers are stable ids, grouped by topic; there is no G-number for "coverage".)

## Techniques

1. **Model-based random tests** (data, behaviour, sync): a seeded generator produces operations; each is applied to
   the database and to a plain Dart reference model; after every step the visible state is compared. A failure prints
   the seed and the operations (`runSequence`). Replay: `FLUENT_SEED=<seed>`.
2. **Golden files** (G6, G17): only for formats that are a contract, generated (`FLUENT_GOLDEN_UPDATE=1`), reviewed by
   the lead line by line.
3. **Upgrade fixtures** (G5): real database files written by 1.x / dev.1 / dev.2 in `test/fixtures/` (small, committed)
   with a manifest of the expected rows.
4. **Statement-level fault injection** (G1, G13, G19–G20, G25): `FaultyDatabaseFactory` fails the n-th statement,
   statements matching a pattern, reads / writes / commits only, or at random (seeded), with real SQLite errors
   (`IOERR`, `FULL`, `BUSY`, `READONLY`); `die()` simulates the app dying. Matrix of where: single / consecutive
   writes and reads, transactions and savepoints, merged batches, migrations, clear / purge / cleanOrphans, sync
   rounds, relation saves.
5. **Simulated crash** (G14): `captureCrashStates` copies the database files before every statement of a write; each
   copy must open intact and hold the state before or after the commit, never a mix.
6. **Chaos runs** (G12, G18, G30): long seeded mixes of every call kind (all depths and parameters), unawaited calls,
   nested and cross-database transactions, deadlock-prone shapes, random faults at random moments and `init` / `close` /
   `restart` / `deleteDatabases` / `pauseQueue` at random points; after every phase: all calls settled, integrity ok,
   data equal to the reference model's committed state, a clean follow-up round works.
7. **Misuse catalogues** (G22, G27, G28): table-driven lists of wrong inputs, settings and model declarations, each
   with the expected outcome (converted / fallback + issue / typed error), plus a data check that nothing was lost.

## Shared harness (written, `test/helpers/`)

| File | What |
|---|---|
| `faults.dart` | `FaultyDatabaseFactory.install()` / `uninstall()`; `failNth(n, where:)`, `failWhere(where, times:)`, `failRandomly(seed, p, where:)`, `die({copyTo})`, `heal()`, `copyFiles(dir)`, `beforeEach` hook, `calls` / `injected` logs; `SqlCall` (`isRead`, `isWrite`, `isCommit`, `isRollback`, `matches`). ROLLBACK and close never fail unless `includeRecovery: true`. `captureCrashStates(faults, dir, write)`. |
| `fuzz.dart` | `fuzzRuns()` (env `FLUENT_FUZZ`, default 25), `fuzzSeed()` (env `FLUENT_SEED`), `fuzzFrom()` (env `FLUENT_FUZZ_FROM`, first sequence of a slice), `fuzzSeeds(base:, share:)`, `FluentFuzz` (`chance`, `intIn`, `pick`, `weighted`, `subset`, `shuffled`, `string`, `dateTime`, `float`), `FuzzOp`, `runSequence(seed:, steps:, next:, check:)`. |
| `guarantees.dart` | `expectIntegrity(db)` (G19), `waitAllSettled(calls, names:)` (G12 + typed errors), `expectTypedError` (G13 / G26), `expectIssuesHaveFixes` (G26), `LogWatch.install()` / `expectNoLeaks(secrets)` (G15) / `expectLogged` (G25), `expectSameRows(actual, expected, key:)`. |
| `golden.dart` | `expectGolden(name, text)`; update: `FLUENT_GOLDEN_UPDATE=1 FLUENT_GOLDEN_DIR="$PWD/test/golden"`. |
| existing | `schema_models.dart` (`DynamicProvider` for inline tables), `relation_models.dart`, `query_counter.dart`; package `fluent_sqflite_test` (`FluentTestDb`, `db.clock`, `db.settle()`, `db.issues`). |

Every scenario test ends with `expectIntegrity` (G19) and `expectIssuesHaveFixes(db.issues)` (G26); every test that
injects failures settles its calls with `waitAllSettled` (G12 / G13).

## Agents

| # | Agent | Model | Guarantees | Main code (read via Serena) | Test files |
|---|---|---|---|---|---|
| T0 | Uncovered lines | Haiku | — | `.coverage/uncovered.txt` (107 lines) | `.coverage/triage.md` only |
| T1 | Relations | Opus | G1, G3, G8, G9, G11, G21, G29 (relations) | `lib/src/core/fluent_provider/parts/relations/*`, `lib/src/relations/*` | `test/provider/relations/relations_guarantees_test.dart`, `relations_fuzz_test.dart` |
| T2 | Sync | Opus | G10, G23, G24, G31 (sync), G1 | `parts/sync/*`, `parts/fluent_watch_remote.dart`, `lib/src/sync/*` | `test/provider/sync/sync_guarantees_test.dart`, `sync_fuzz_test.dart` |
| T3 | Engine | Opus | G7, G12, G30, G1 (merged batches) | `lib/src/core/fluent_engine/*` | `test/engine/engine_guarantees_test.dart`, `engine_fuzz_test.dart` |
| T4 | CRUD and transactions | Sonnet | G1, G2, G8, G9, G16, G21, G29 | `parts/crud/*`, `parts/fluent_crud_helper.dart`, `fluent_transaction_scope.dart` | `test/provider/crud/crud_guarantees_test.dart`, `crud_fuzz_test.dart` |
| T5 | Schema and upgrades | Sonnet | G4, G5, G17 (DDL, plans), G21 (start), G31 (start) | `parts/schema/*`, `fluent_db/parts/fluent_db_schema.dart`, `parts/relations/fluent_legacy_names.dart` | `test/provider/schema/schema_guarantees_test.dart`, `schema_fuzz_test.dart`, `test/fixtures/`, `test/golden/schema/` |
| T6 | Failures, crashes, outside influence | Sonnet | G1, G13, G14, G15, G19, G20, G25 | write paths, `fluent_db/*`, `fluent_log/*`, `fluent_clock.dart` | `test/db/failures_guarantees_test.dart`, `crash_guarantees_test.dart` |
| T7 | Values and input | Sonnet | G6, G17 (stored forms, cursor), G22, G29 (fields) | `utils/fluent_type_codecs.dart`, `models/db/*`, `models/fluent_page.dart`, `utils/fluent_filter.dart`, `parts/fluent_row_mapping.dart`, `parts/fluent_mapper.dart` | `test/provider/mapping/values_guarantees_test.dart`, `input_guarantees_test.dart`, `test/golden/values/` |
| T8 | Chaos | Opus | G12, G18, G30, G19 (+ G1 / G7 after recovery) | engine, lifecycle, transaction scope | `test/regressions/chaos_test.dart` |
| T9 | Misuse: settings and models | Sonnet | G27, G28, G26 (runtime) | `models/configs/*`, `fluent_db/parts/fluent_db_lifecycle.dart`, `relations/*` graph build, `interfaces/fluent_storable.dart` | `test/db/misuse_guarantees_test.dart` |
| T10 | Hints and logging audit | Haiku | G25, G26 (static) | every `throw` / `FluentLog.raise` / `FluentLog.issue` site in `lib/` | `test/log/hints_guarantees_test.dart` |

Why these models: Opus where a wrong reference model means missed data loss (relations, sync, engine interleavings,
chaos). Sonnet where the scenarios follow directly from the guarantee and the harness. Haiku for mechanical work
(triage of 107 lines; checking every raise / issue site has a hint). Local Ollama (7B) is not used: the work is
reasoning about invariants, and checking its output would cost more than Haiku.

All 11 start at once (separate mirrors, separate test files). Code edits in this round are small fixes only, each in
the agent's own area.

## After the agents

1. The lead checks every report: reruns the tests, reads each `BUG:` skip, reviews every golden line by line, rejects
   tests that pin today's behaviour instead of a guarantee.
2. Fix wave (like audit 2): bugs grouped by area; Sonnet by default, Opus for HIGH bugs in engine / relations / sync.
   The skipped tests are the regression tests: un-skip them.
3. Night-size run once: `FLUENT_FUZZ=2000` over the `*_fuzz_test.dart` files and `chaos_test.dart` (mirror,
   background); failing seeds become regular tests. Split runs: `bash tool/fuzz_parallel.sh <total> <shards> [from]`
   (slices of seeds in parallel mirrors; `from` continues a run on another machine or night).
   Stress: `FLUENT_STRESS=20 bash tool/mirror_test.sh stress test/stress` (the same checks on a big world; scale 1 in
   the normal suite; sizes, timings and memory in `build/stress_report.md` of the copy).
4. Docs pass (Sonnet): `doc/guarantees.md` (the tables above in user words, with the limits), CHANGELOG,
   FIXED_ISSUES, KNOWN_BUGS limits.
5. CI later: the normal suite (25 sequences per fuzz test) + golden + fixtures.

## Budget levers

- Serena symbol reads instead of whole files (the four biggest files are 1 250–1 650 lines).
- Harness, guarantees and briefs are written once (this file); agents do not re-derive them; CLAUDE.md is loaded by
  every agent automatically, so briefs do not repeat it.
- Exact file lists per agent; short reports in a fixed format.
- Haiku for T0 / T10; Sonnet for T4–T7 / T9; Opus only for T1–T3 / T8 and HIGH fixes.

---

# Briefs (paste as the agent prompt: COMMON + the agent's block)

## COMMON

```
You write guarantee tests for the Dart/Flutter library fluent_sqflite (repo root E:\Flutter\fluent_sqflite, Windows,
Git Bash). Read TEST_PLAN.md first: the guarantees (G-ids), the techniques and the shared harness in test/helpers/
(faults.dart, fuzz.dart, guarantees.dart, golden.dart — read their doc comments; see test/utils/guarantee_harness_test.dart
for usage). Ten other agents work in parallel on other areas, each with its own test files.

Navigation: use Serena. Load it with ToolSearch "select:mcp__serena__initial_instructions,mcp__serena__activate_project,mcp__serena__serena_repl",
call initial_instructions (it gives your session id), activate_project "E:\Flutter\fluent_sqflite", then use
s.lsp.get_symbols_overview / s.lsp.find_symbol(include_body=True) / s.lsp.find_referencing_symbols /
s.fs.search_for_pattern. Read only the symbols you need; never read the big files whole.

Rules:
- Test the GUARANTEE, not today's behaviour. Each test name starts with its G-id ("G3: ..."). Never weaken an
  assertion to make it pass.
- Random tests: seeded via fuzzSeeds(base: <your unique base, given below>) + runSequence; keep the normal run fast
  (default 25 sequences, each short); heavier variants read FLUENT_FUZZ.
- End every scenario with expectIntegrity(...) and expectIssuesHaveFixes(db.issues); settle concurrent / failing
  calls with waitAllSettled(...). Every file: `@Timeout(Duration(seconds: 60))` + `library;` at the top,
  setUpFluentTests(), FluentTestDb, `.timeout(...)` on anything that could hang. Uninstall FaultyDatabaseFactory in
  tearDown after db.close().
- Run tests ONLY through `bash tool/mirror_test.sh <your agent id, e.g. t1> <your test files>` (never `flutter test` in
  the checkout). Analyzer: `.fvm/flutter_sdk/bin/dart analyze <your files>`.
- When the code breaks a guarantee: if the fix is small and inside your area, fix it (lib edit + keep the test) and
  run the area's existing tests too; otherwise keep the test with `skip: 'BUG: <one line>'`. Never edit other areas'
  lib files beyond one clearly needed line; never revert others' changes. No docs edits (README, doc/, skills/,
  CHANGELOG, KNOWN_BUGS.md, FIXED_ISSUES.md, TEST_PLAN.md). Golden files: generate, never hand-write; list them in
  your report for review.
- Do not run `dart format`. Code style: final locals, trailing commas, the repo's wide lines.

Final report (keep it short):
1. Tests added, grouped by G-id (file + test names, sequences per run).
2. Bugs found: G-id, one-line scenario, seed if random, FIXED (files) or SKIPPED (test name, why not fixed here).
3. Golden files created (paths), fixtures created.
4. What you could not test and why.
5. Results: counts from your mirror run, analyzer result.
```

## T0 — Uncovered lines (Haiku)

```
Agent id: t0. No tests to write. Run: bash tool/mirror_test.sh coverage --coverage, then bash tool/coverage_report.sh.
For every range in .coverage/uncovered.txt, look at the code (Serena find_symbol on the enclosing function) and
classify it: DEAD (cannot run; say why), DEFENSIVE (safety net that should never run; say against what), or
NEEDS-TEST (reachable; describe the exact scenario in one line and which agent area it belongs to: relations, sync,
engine, crud, schema, failures, values, lifecycle). Write the result to .coverage/triage.md as a table
(file:line | class | reason / scenario | area). Do not edit any other file. Report the counts per class.
```

## T1 — Relations (Opus)

```
Agent id: t1. Seed base: 10000. Guarantees: G1, G3, G8, G9, G11, G21, G29 for relations.
Area: lib/src/core/fluent_provider/parts/relations/* (writer, reader, ops, graph, filter), lib/src/relations/*.
Models: test/helpers/relation_models.dart (+ declare your own in the test files when needed).
Tests: test/provider/relations/relations_guarantees_test.dart and relations_fuzz_test.dart.
Build a reference model of an owner/children graph covering: owned lists (many), one / oneOwned, manyToMany, through
(link model with data), oneOf (polymorphic), composite keys, soft delete on some tables. Random operations: save /
saveAll with edited lists, loads with every mode (eager, lazy, FluentLoad.none, depth 0..3, limit, where,
includeDeleted), save of what was loaded (G3: nothing outside the loaded view disappears), attach / detach, delete /
restore (cascade and restore match, G9), hard delete (cascade rules, G21), transactions with rollback around relation
saves (G1, G2 for relation lists), watch of related tables converging (G11), findRelated / countRelated / findParents
agreeing with the reference (G8), returned models carrying exactly their fields (G29).
Add fault injection inside relation saves (fail a link-table insert, a child delete): G1 nothing half-written.
```

## T2 — Sync (Opus)

```
Agent id: t2. Seed base: 20000. Guarantees: G10, G23, G24, G31 (sync rounds), G1.
Area: lib/src/core/fluent_provider/parts/sync/*, parts/fluent_watch_remote.dart, lib/src/sync/*. Look at the existing
tests in test/provider/sync/ for models and fake servers.
Tests: test/provider/sync/sync_guarantees_test.dart and sync_fuzz_test.dart.
Write a fake server with its own state (rows, deletions, versions) that can: accept, reject some keys, fail the call,
answer late, change rows on its side between rounds, paginate. Random local edits (save, patch, delete, hardDelete,
restore, clearLocally, replaceLocally) between syncWithServer rounds with every conflict policy, pushOnlyUnsynced,
cancel tokens. Invariants after a final quiet round: local == server (G10), nothing lost or doubled, every push sent
each pending change once and marked exactly the accepted ones (G23), pendingChanges() and per-row state agree (G23),
each store mode / delete behaviour / conflict policy of pull and watchRemote does exactly its documented effect
(G24, table-driven), the since cursor moves only after a complete pull (G24), a round with nothing new changes
nothing (G31). Inject failures in the middle of push bookkeeping and pull pages (G1).
```

## T3 — Engine (Opus)

```
Agent id: t3. Seed base: 30000. Guarantees: G7, G12, G30, G1 (merged batches).
Area: lib/src/core/fluent_engine/* (fluent_engine.dart, fluent_transaction_scope.dart), the provider's task entry
(FluentProvider.internalExecute / executor).
Tests: test/engine/engine_guarantees_test.dart and engine_fuzz_test.dart.
Random interleavings of UNAWAITED calls on two databases with same-named tables (G30): saves that merge (also the
same instance twice, patches of one row, conflictOn), findById floods, identical reads that collapse, counts,
transactions (nested, savepoints, cross-database A-in-B-in-A), pause / resume of one or all databases, policies /
priorities. The result of every call must equal a serial run of the same calls in call order (G7): build the serial
reference by replaying the ops awaited one by one on a fresh database. Every call settles (G12). A catalogue of
deadlock-prone shapes (G12): each public call (save, find, count, transaction, clear, cleanOrphans,
purgeArchivedColumns, close, restart, pauseQueue, syncWithServer) made from inside a transaction, a running task, a
converter, a watch listener, an onRecord sink and onMigrate — each completes or is refused with ignoredCall.
Inject a failure into a merged batch (G1: the batch falls back call by call, each caller gets its own outcome).
```

## T4 — CRUD and transactions (Sonnet)

```
Agent id: t4. Seed base: 40000. Guarantees: G1, G2, G8, G9, G16, G21, G29.
Area: lib/src/core/fluent_provider/parts/crud/*, parts/fluent_crud_helper.dart, lib/src/core/fluent_engine/fluent_transaction_scope.dart,
soft delete / timestamps / timeToLive.
Tests: test/provider/crud/crud_guarantees_test.dart and crud_fuzz_test.dart.
Reference model of one or two tables (one with soft delete + timestamps + timeToLive). Random ops: save / saveAll with
every strategy (upsert, insertOnly, updateOnly, patch) and conflictOn, update / updateById / updateWhere with
FluentUpdate, delete / restore / hardDelete / purgeTrash / clearExpired, clock moves (db.clock), transactions with
commit / rollback / nested savepoints. After each step compare rows AND the app's model objects (G2: after a rollback
keys, deletedAt, timestamps are as before). G8: one matrix test that runs find / findById / count / exists / findPage /
aggregate / pluck / watch under every scope (default, withTrash, trash, includeExpired) and compares their answers.
G16: findPage walks (asc / desc, every orderBy kind incl. DateTime, iso8601 tables) with random inserts / deletes
between pages and cursors round-tripped through encode / decode. G21: rows disappear only by the explicit calls above
(the reference model decides). G29: returned models / findMaps rows have exactly the expected fields. Every call ×
its parameters (depth 0..3, limit / offset / orderBy, tags, policies) at least once.
```

## T5 — Schema and upgrades (Sonnet)

```
Agent id: t5. Seed base: 50000. Guarantees: G4, G5, G17 (DDL, migration plans), G21 (start-up), G31 (starts).
Area: lib/src/core/fluent_provider/parts/schema/*, lib/src/core/fluent_db/parts/fluent_db_schema.dart,
parts/relations/fluent_legacy_names.dart. DynamicProvider (test/helpers/schema_models.dart) declares table shapes
inline; FluentTestDb(persistent: true) + restart([...]) changes versions.
Tests: test/provider/schema/schema_guarantees_test.dart, schema_fuzz_test.dart; fixtures in test/fixtures/;
goldens in test/golden/schema/.
1) Random version chains (3–6 versions) of 1–3 tables with data: add / remove / rename (oldName, chains, reuse of a
   freed name) / type change / NOT NULL with default / index / unique / check / relation kind change; after each
   restart every row and value is where the guarantee says (moved, archived, quarantined with children) (G4), a second
   start changes nothing (G31), nothing else disappeared (G21).
2) Same table names in two databases; a table dropped and recreated under its name; a rename onto a name an archive /
   quarantine / 1.x table holds.
3) A failure at every statement of a representative migration (FaultyDatabaseFactory.failNth over the migration's
   statements): the start fails typed, the file is unchanged and intact, the next start without the fault succeeds.
4) Upgrade fixtures (G5): create databases with 2.0.0-dev.1 (git worktree of commit ebab34b in the scratch / temp
   folder, a small test there that writes representative data: soft delete, iso8601 table, relations, sync rows) and,
   if the 1.x code (tag archive/master-before-2.0) cannot run on this SDK, build the 1.x layout by hand like the
   existing legacy-name tests do. Commit the .db files + a manifest; open them with the current code and check every
   row, value, relation, trash state and sync state. Delete the worktree afterwards.
5) Goldens (G17): the DDL generated for a set of representative models, and planMigrations() output for a set of
   version changes.
```

## T6 — Failures, crashes, outside influence (Sonnet)

```
Agent id: t6. Seed base: 60000. Guarantees: G1, G13, G14, G15, G19, G20, G25.
Area: write paths of the provider, lib/src/core/fluent_db/*, lib/src/core/fluent_log/*, lib/src/utils/fluent_clock.dart.
Tests: test/db/failures_guarantees_test.dart and crash_guarantees_test.dart.
1) Fault matrix (G1, G13, G19, G25): for each operation kind — single save / saveAll / update / delete / restore,
   a transaction with several writes, a savepoint, a merged batch of unawaited saves, a relation save, clear /
   clearTable / purgeTrash / cleanOrphans / purgeArchivedColumns, a read, consecutive reads and writes — fail the 1st,
   2nd, ..., last statement (and the COMMIT) with each FaultKind: the caller gets a typed error with a hint, the data
   equals the state before, integrity ok, the failure is logged (LogWatch.expectLogged), the next call works.
2) Crash (G14): captureCrashStates over representative writes (single, batch, transaction with relations, migration,
   sync bookkeeping) — every copy opens with FluentTestDb-like init on the copy, passes integrity, holds before-or-after.
3) Outside influence (G20): BUSY from another connection holding a write lock (open a second raw connection with
   databaseFactoryFfi and BEGIN EXCLUSIVE), FULL / READONLY / IOERR via faults, the file deleted or replaced while
   closed, DDL / writes by another connection between calls, db.clock moved back and forth around expiry / trash /
   timers, app lifecycle pause / resume if reachable. Data intact, reported, recovers.
4) Privacy (G15): LogWatch over a full scenario with secret-looking values and a database in a directory with a user
   name in the path; expectNoLeaks; then the same with showSqlArguments: true shows them.
```

## T7 — Values and input (Sonnet)

```
Agent id: t7. Seed base: 70000. Guarantees: G6, G17 (stored forms, cursor text), G22, G29 (fields).
Area: lib/src/utils/fluent_type_codecs.dart, lib/src/models/db/* (converters, columns, defaults), lib/src/models/fluent_page.dart,
lib/src/utils/fluent_filter.dart, parts/fluent_row_mapping.dart, parts/fluent_mapper.dart.
Tests: test/provider/mapping/values_guarantees_test.dart, input_guarantees_test.dart; goldens in test/golden/values/.
1) Round-trip matrix (G6), table-driven: every supported type (bool, int extremes, double incl. -0.0 / tiny / huge,
   String incl. unicode / quotes / empty, DateTime UTC / local / micros / extremes, Duration, BigInt, Uri, RegExp with
   flags, Color, Locale, TimeOfDay, enums by name / index, JSON lists / maps nested, Uint8List, null) × table date
   format (timestamp, iso8601) × plain column / explicit converter / enum converter → save, read back, eq filter, order
   by, min / max, pluck, watch: all equal to the original (incl. isUtc); precision limits reported.
2) Goldens (G17): the stored form + _fs_metadata of each value of the matrix; FluentCursor.encode() of representative
   cursors.
3) Bad input (G22), table-driven: wrong types for a column, NaN / ±Infinity, a 10 MB string, deep / cyclic JSON, a
   Map with non-string keys, null in a NOT NULL column, unknown enum values, 50 000 ids in FluentFilter.ids, garbage
   cursors, orderBy injection attempts, filter values of the wrong type: each is converted losslessly or refused typed
   with a hint, and nothing was written (count / rows unchanged).
4) G29: find / findMaps / pluck / aggregate return exactly the requested fields; a patch changes only its fields.
Random test: random values per type with fuzz (FluentFuzz.string / dateTime / float) round-tripped.
```

## T8 — Chaos (Opus)

```
Agent id: t8. Seed base: 80000. Guarantees: G12, G18, G30, G19 (+ G1 / G7 after recovery).
Area: the whole library from the outside; engine (lib/src/core/fluent_engine/*), lifecycle
(lib/src/core/fluent_db/parts/fluent_db_lifecycle.dart), transaction scope.
Tests: test/regressions/chaos_test.dart (normal run: a few short phases per seed; FLUENT_FUZZ scales them).
Two file databases (same-named tables, one with soft delete + relations + a syncable table with a fake server).
Each seed runs phases. In a phase: a burst of unawaited calls of every kind (reads / writes at every depth and
parameter, transactions nested and cross-database, watch subscriptions, sync rounds), with FaultyDatabaseFactory
failing random statements (failRandomly) and, at random moments, init / close / restart / deleteDatabases(reopen) /
pauseQueue / resumeQueue / die()+heal()+restart (the app crashed and started again). Keep a reference model of the
COMMITTED state: an op counts as committed only when its future completed successfully (and its transaction
committed). After each phase: waitAllSettled on everything (G12), heal, expectIntegrity on both files (G19), the data
equals the reference committed state (G18 / G1), a clean round of every call kind works and agrees with a serial
replay (G18 / G7), the other database was never affected by calls on the first (G30). Minimise a failing seed by hand
when you can (shortest phase that fails) and report it.
```

## T9 — Misuse: settings and models (Sonnet)

```
Agent id: t9. Seed base: 90000. Guarantees: G27, G28, G26 (runtime).
Area: lib/src/models/configs/* (FluentConfig, FluentDbConfig, FluentTableConfig), lib/src/core/fluent_db/parts/fluent_db_lifecycle.dart,
the relation graph build (parts/relations/fluent_relation_graph.dart buildFluentRelationGraph), lib/src/interfaces/fluent_storable.dart,
lib/src/core/fluent_provider/fluent_provider.dart (registration).
Tests: test/db/misuse_guarantees_test.dart.
1) Settings (G27), table-driven + a small random generator of configs: zero / negative / huge durations and sizes,
   contradictory combinations (readOnly + migrations, inMemory + read pool, journal modes, cache sizes, diagnostics /
   tuning presets), changed between restarts and via configure() at runtime. Each: fallback + configFallback warning
   or a typed refusal at init; the database and its data intact (expectIntegrity, rows unchanged); the library keeps
   working.
2) Models (G28), table-driven: duplicate columns, a key column missing / changing type between versions, composite
   keys with nullable parts, buildJson and fromCacheJson that disagree / throw / return extra fields, a modelSample
   that throws, relations to unregistered / ambiguous models, relation cycles, a relation whose foreign key collides
   with a column, two providers for one table, a table name that is a SQL keyword or has spaces / quotes. Each:
   typed refusal or warning; existing data in a persistent database is never lost (restart with the bad model, then
   restart with the good one: all rows back).
3) G26 runtime: every issue collected in these tests has a fix; every exception has a hint.
```

## T10 — Hints and logging audit (Haiku)

```
Agent id: t10. Guarantees: G25, G26 (static).
Area: every `throw`, `FluentLog.raise(`, `FluentLog.issue(`, `FluentLog.report(`, `FluentLog.publish(` site in lib/
(use Serena s.fs.search_for_pattern).
Tests: test/log/hints_guarantees_test.dart.
1) List every raise / issue / exception construction site; for each check: a typed Fluent*Exception (never raw
   ArgumentError / StateError / DatabaseException thrown to users), a non-empty hint / fix, the original error kept as
   cause, messages through FluentLog.redact when they embed `$e`. Write the list to .coverage/hints_audit.md
   (file:line | kind | ok / problem).
2) Write a test that enumerates FluentIssueKind.values and FluentErrorCode.values and checks each is documented with a
   fix in doc/ai/issues.md / doc/ai/error-codes.md (beyond what test/docs/docs_test.dart already checks: the fix /
   "how" column must not be empty).
3) Report problems found (sites without hint, raw throws) — do not fix lib code; the lead assigns them.
```
