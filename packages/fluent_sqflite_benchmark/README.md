# fluent_sqflite_benchmark

Benchmarks of [fluent_sqflite](../../README.md): parallel reads (read connection pool), how long a big list blocks
the UI isolate while it becomes models, and scenarios for the queue, saves, relation loads and deletes that catch
performance regressions.

Add it to an app only for the run, and run in profile or release mode on a real phone:

```yaml
dependencies:
  fluent_sqflite_benchmark: ^2.0.0
```

```dart
import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart';

debugPrint(await FluentBenchmark.run()); // reads: rows 5000, parallelReads 20 by default

final FluentBenchmarkReport report = await FluentBenchmark.runScenarios(); // queue, save, relations, deletes
debugPrint(report.toString());
assert(report.nPlusOneSuspects.isEmpty); // relation loads send the same statements for 4x the parents
```

## Scenarios

`runScenarios({suites, size = 200, bulkSizes = [1000, 10000], runs = 5, warmUp = 1})`: every scenario runs `warmUp`
untimed and `runs` timed times; the result holds the median, min, max, time per call or row, the SQL statements one
run sends and what the engine did (`collapsedReads`, `mergedSaves`, `batchedLookups`, `tasks`).

| Group (`report['group']`) | What it measures |
|---|---|
| `queue.concurrentReads` | `size` concurrent `findById` calls (merged into `IN` queries) |
| `queue.identicalReads` / `queue.distinctReads` | equal reads answered once / different reads on the read pool |
| `queue.readsAndWrites` | reads and saves called together (writes are barriers) |
| `queue.sequentialCalls` | awaited calls one by one: the overhead of a single task |
| `save.single` / `save.merged` | `size` awaited saves / the same saves called together (adjacent saves merge) |
| `save.saveAll` | one `saveAll` per entry of `bulkSizes` (1k and 10k rows by default) |
| `save.conflictOn` | upsert of `size` rows by a unique column |
| `save.graphChildren` / `save.graphManyToMany` | saves of models with one-to-many children / many-to-many links |
| `relations.one` / `many` / `manyToMany` | eager loads for `size` and `4 * size` parents (statements must not grow) |
| `relations.nested` | eager `many` with `maxDepth: 2` |
| `relations.limited` | a relation with `limit` (the last 3 of 10 children per parent) |
| `deletes.softCascade` / `deletes.trashForever` | soft delete with cascade to children / permanent delete from the trash |
| `deletes.hardByFilter` | `deleteWhere` of a table without soft delete |

Run a part with `suites: {FluentBenchmarkSuite.save}`; use small sizes in tests (`size: 30, bulkSizes: [100, 400], runs: 3`).

Statements are counted through a wrapper of the database factory (`FluentStatementCounter`); when the platform factory
cannot be wrapped, `statements` is `null` and only the times are reported.

## Catching regressions

```dart
final String baseline = jsonEncode((await FluentBenchmark.runScenarios()).toJson()); // store it in a file
// ... after a change:
final FluentBenchmarkReport now = await FluentBenchmark.runScenarios();
final slower = now.compareTo(FluentBenchmarkReport.fromJson(jsonDecode(baseline) as Map<String, dynamic>)).where((d) => d.regressed);
slower.forEach(debugPrint); // SLOWER relations.many (120 parents): 2.7 ms -> 4.1 ms (x1.52)
```

Compare runs on the same device. `tolerance` (default 25 %) and `minimum` (2 ms) keep timer noise out. The N+1 check
(`nPlusOneSuspects`) needs no baseline: it compares the statements of the small and the large relation load.

The databases are created as temporary files and deleted afterwards. See [Performance](../../doc/performance.md).
