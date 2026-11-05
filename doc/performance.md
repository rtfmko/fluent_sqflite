# Performance

Defaults are tuned for apps; you rarely need to change anything. This page explains what happens and the knobs.

## The engine

Every call goes through a queue per database. Calls keep their order around writes (a read never sees less than the
writes called before it, a write never overtakes an earlier call); reads between two writes are reordered by priority
(`ExecutionPolicy(priority: ...)`). Identical reads in flight are answered once (the callers get their own lists of the same
model objects: copy a model before changing it), adjacent saves of a table are merged (never two saves of one key),
queued `findById` calls become one `IN (...)` query. A read waiting long gains priority, so background reads are not
starved. `FluentDb.engineStats()` shows the queue and these counters.

Lookups queued together (`findById`) run as one `IN (...)` query. The key of each returned row is read from the
stored row (`FluentBatchKeys.fromRows`, default): `buildJson` does not run per model. `batchKeys:
FluentBatchKeys.fromModels` (table, database or global setting) reads the keys from the built models instead, which
costs one `buildJson` per returned model. A row that matches none of the requested keys (a case-insensitive key) is
looked up call by call, and the `batchKeysMismatch` hint is logged once.

```dart
@override
FluentTableConfig get tableConfig => const FluentTableConfig(batchKeys: FluentBatchKeys.fromModels);
```

Each provider can set the default policy of its calls (`ExecutionPolicy get policy`); a call's `policy:` overrides
what it sets, `FluentConfig.defaultPolicy` fills the rest.

## Parallel reads

sqflite runs the statements of one connection one after another. In WAL mode (the default) the library opens
`readConnections` read-only connections (`FluentConfig`, per database `FluentDbConfig`; default 2, up to 4) and runs one read on each at the
same time. Reads inside a transaction use the transaction. In-memory and non-WAL databases have no pool; set
`readConnections: 0` to turn it off.

## Smooth UI with big lists

Turning thousands of rows into models takes time on the UI isolate. Two mechanisms keep frames flowing:

* **Slicing** (always on): lists of `FluentConfig.sliceAfterRows` rows or more (300) are mapped in slices of
  `frameBudget` (4 ms), letting a frame render in between.
* **Background isolate:** give the provider a static factory and big lists are mapped in a background isolate.

```dart
@override
Note Function(Map<String, dynamic> json)? get isolateFactory => Note.fromJson; // static, no provider access
```

`FluentConfig.isolateMapping` (per table `FluentTableConfig.isolateMapping`) decides when: `smart` (default) measures the
mapping cost per table (kept across restarts) and moves lists
that would block the UI longer than half a frame (and prints a hint with this code when the factory is missing),
`always`, or `never`. If a factory cannot be sent to an isolate the library warns once and maps on the UI isolate.

If the isolate itself fails (an unsendable factory, a resource problem), the next 2 batches of that table are mapped
on the UI isolate, then the isolate is tried again; each repeated failure doubles the pause (up to 64 batches). Both
steps are reported as `isolateFallback`.

## Diagnostics and the tuner

The library measures its own calls, suggests fixes and — if you allow it — improves things by itself. One setting
decides all of it, globally (`FluentConfig.diagnostics`) or per database (`FluentDbConfig.diagnostics`, wins):

| Preset | Measures (cost model) | Hints | Changes by itself |
|---|---|---|---|
| `FluentDiagnostics.none` | no (reads run in call order, nothing stored) | no | no |
| `FluentDiagnostics.quiet` | yes | no | no |
| `FluentDiagnostics.recommend` (default) | yes | yes (debug / profile; `hintsInRelease` for release) | no |
| `FluentDiagnostics.auto` | yes | yes | everything in `FluentTuning.full` |

Build your own: `FluentDiagnostics(tuning: FluentTuning.full.copyWith(indexes: false, memory: false))`. Every lever of
the tuner has its own switch — turn off what your app does itself or what misbehaves on some devices:

| `FluentTuning` | What it does |
|---|---|
| `indexes` (+ `maxIndexes`, 5) | creates an index for a read that stays slow (from the query plan), while the database is idle, checks after new measurements that it helps (≥ 20 % faster) and drops it otherwise; the report shows the code to declare it in the model |
| `readConnections` | sizes the read pool by the device's cores when you set no `readConnections` |
| `memory` | on memory pressure frees SQLite's memory and uses a small page cache until the app is back (or 2 min) |
| `background` | when the app goes to the background: writes the stats, runs `PRAGMA optimize`; periodic maintenance waits until it is back |
| `checkpoints` | merges the write-ahead log after many writes (when idle) and when the app goes to the background |
| `frameBudget` | fits the slices of big lists turned into models to the display's refresh rate |

Every change is an `autoFix` issue (`tuned`); a change that does not help or fails is taken back (`tuningReverted`) and
the app keeps working. Nothing runs inside a transaction (index changes go through the queue), and nothing is changed
that only works for a new database file.

### Hints

Hints are `FluentIssue`s of type `hint` (see [Errors and logging](errors-and-logging.md#issues-hints-automatic-changes-warnings)).
Reads are judged by their average over 3 runs, never by one spike.

| Kind | When | Suggests |
|---|---|---|
| `missingIndex` | a read shape takes ≥ 100 ms on average and its query plan reads every row or sorts in a temp B-tree | the `FluentIndex` that serves the filter: equality columns first, then the range or the order |
| `bigRead` | an unpaged read returned ≥ 1000 rows | `findPage` |
| `deepOffset` | `offset` ≥ 1000 | `findPage` (each page costs the same) |
| `unordered` | `limit` / `offset` without `orderBy` | an `orderBy`, or `findPage` |
| `like` | a slow `LIKE '%…'` (`contains` / `endsWith`), by its average | `startsWith` with an index on a NOCASE column |
| `relations` | reads loading nested relations take ≥ 100 ms on average | `maxDepth: 1`, `relations: FluentLoad.none`, `lazy: true` |
| `isolate` | big lists are mapped on the UI isolate | an `isolateFactory` |
| `saveLoop` | ≥ 50 awaited single saves of one table within 2 s | `saveAll` |
| `lookupLoop` | ≥ 30 awaited `findById` calls of one table within 2 s (N+1) | `findByIds(ids)` |
| `flood` | ≥ 1000 calls queued at once | `saveAll`, awaiting the calls |
| `polling` | the same read ran 10 times, spread over time, while the data did not change | `watch` |
| `queueWait` | a call waited ≥ 1 s in the queue | shorter transactions, smaller write chunks (names the slow call before it) |
| `slowWrite` | one write took ≥ 500 ms | smaller chunks |
| `refIndex` | a relation load or filter reads reference columns that have no index (`indexReferences` off) | turning it on, or one `FluentIndex` |
| `enumValues` | at `init`: an enum field without `enumValues` (reads return a String) | the `enumValues` entry |
| `redundantIndex` | at `init`: an index whose columns start another index or the key | removing it |
| `syncKey` | at `init`: a synced table with an auto-increment key (devices create the same ids) | a text key, or `FluentTableConfig(serverKey:)` |
| `fullTextOff` | a search ran without a full-text index (`fullText: off`, or no FTS in the device's SQLite) | `fullText: auto` |

The index advice comes from SQLite itself: for a slow query shape the library runs `EXPLAIN QUERY PLAN` once (debug and
profile builds only, outside the queue, so it never delays your calls) and suggests an index only when the plan shows a
full scan with a filter or a temp B-tree for the order. In release (`hintsInRelease`) it uses the filtered columns no
index starts with instead. Small tables never get one: they are not slow.

```dart
debugPrint('${FluentDb.report()}');
// Important — fix first (2)
//   • Add an index on notes(folder_id, updated_at)
//     ...
// Medium (1) / Small wins (1) / Changed automatically / Warnings
```

To learn what is slow on real devices: `FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true))` and
`FluentDb.onIssue(types: {FluentIssueType.hint}).listen(...)`. Keep hints out of crash reporting so they do not mix
with crashes. `PRAGMA optimize` runs on close and every 6 h (`optimizeInterval`).

The query plan behind an index hint runs as a background-priority read through the queue (debug and profile only),
so it never waits on or blocks a transaction of the app.

## Query stats

The engine measures every query shape (table, operation, condition without values): average time, rows returned, runs,
failures, and per table the cost of turning a row into a model. It schedules reads with these numbers and the analyzer
builds hints from them. They are kept in each database's own `__fluent_stats` table — written only when they changed,
while the database is idle, at most every 5 minutes and on close — so they are known right after a restart and go away
with the database. In-memory and read-only databases keep them in memory only; shapes unused for 30 days are dropped.

```dart
debugPrint('${FluentDb.queryStats()}');                                  // every measured shape, slowest first
final FluentQueryStats notes = FluentDb.queryStats(dbKey: AppDb.main, table: 'notes');
```

## Relation indexes

Reference columns of relations (`author_id`, composite references, many-to-many link targets) get an index, so relation
loads, relation filters and deletes of referenced rows never read whole tables. Turn it off globally with
`FluentConfig(indexReferences: false)`, per database with `FluentDbConfig(indexReferences: ...)`, or per table in the
model's `tableConfig`; the narrower setting wins (off globally, on for one database: that database keeps its indexes). Turned off, the
indexes are dropped on the next start and a `refIndex` hint appears when a relation needs one.

## Measuring on a device

```dart
// dependencies: fluent_sqflite_benchmark (a separate package; add it only for the run)
import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart';

debugPrint(await FluentBenchmark.run()); // parallel reads, longest UI stall while mapping 5000 rows
```

Run it in profile or release mode on a real phone (the example app has a button for it).

### Benchmarks and regressions

`fluent_sqflite_benchmark` (add it to an app only for the run, profile mode on a real phone) measures more than reads:

```dart
final report = await FluentBenchmark.runScenarios(); // queue, save, relations, deletes
debugPrint(report.toString());
```

Each scenario runs after a warm-up several times; the result holds the median, the time per call or row, the SQL
statements one run sends and what the engine did (`collapsedReads`, `mergedSaves`, `batchedLookups`).

* queue: many concurrent `findById` (merged into `IN` queries), equal reads (answered once), reads between writes
  (writes are barriers), the overhead of one awaited call.
* save: single saves, saves called together (merged), `saveAll` of 1k / 10k rows (`bulkSizes`), `conflictOn` upserts,
  saves with one-to-many children and many-to-many links.
* relations: eager one / many / manyToMany, nested (`maxDepth: 2`) and limited lists for size and 4× size parents.
  Statements must not grow with the parents; `report.nPlusOneSuspects` lists the groups where they do.
* deletes: soft delete with cascade, permanent delete from the trash, hard delete by filter.

Keep a report as a baseline (`jsonEncode(report.toJson())`) and compare after a change on the same device:
`report.compareTo(FluentBenchmarkReport.fromJson(...))` marks scenarios more than 25 % slower (`tolerance`, `minimum`).
One `saveAll` is far cheaper per row than single saves (adjacent saves are merged when called together), and a
relation load costs one batched query per relation, whatever the number of parents.

## Tips

* Index the columns you filter and sort by (`indexed: true`, `FluentIndex`); follow the index hints.
* Page long lists with `findPage`, not `offset`.
* Save many rows with `saveAll` (one transaction), not a loop of `save`.
* Mark big relations `lazy: true` and load them when needed.
