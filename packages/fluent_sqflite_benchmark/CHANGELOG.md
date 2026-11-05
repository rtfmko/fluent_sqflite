## 2.0.0-dev.1

* First version as its own package (was `package:fluent_sqflite/benchmark.dart`): `FluentBenchmark.run`.
* `FluentBenchmark.runScenarios`: queue, save, relation-load and delete scenarios with `FluentBenchmarkReport` / `FluentBenchmarkResult` (median, statements, engine counters), `compareTo` a baseline and an N+1 check.
