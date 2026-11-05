---
name: fluent-sqflite-testing
description: >-
  Use when the user writes or fixes tests of code that uses fluent_sqflite: the fluent_sqflite_test package
  (setUpFluentTests, FluentTestDb in memory or persistent, restart for schema changes, db.clock to move time for
  expiry / trash retention / sync, db.settle instead of Future.delayed for watch streams, db.issues and
  failOnWarnings), and running the on-device benchmark (fluent_sqflite_benchmark).
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: testing

## Rules

- Add `fluent_sqflite_test` to `dev_dependencies` (until it is on pub.dev: `git:` url
  `https://github.com/rtfmko/fluent_sqflite.git`, `path: packages/fluent_sqflite_test`) and call `setUpFluentTests()` once at the top of `main()`. Do not
  call `sqfliteFfiInit` / `databaseFactory = ...` or `FluentDb.init` / `FluentDb.close` by hand in tests.
- One `FluentTestDb` per test: `open` in `setUp`, `close` in `tearDown`. It is in memory unless `persistent: true`.
- Use `persistent: true` only for `restart` (schema changes between versions) or read connections.
- Never wait with `Future.delayed` for `watch` / `watchValue` / `watchRemote`: `await db.settle()`.
- Never wait real days for expiry or the trash: `db.clock.advance(...)` / `db.clock.set(...)`.
- Check warnings with `db.warnings` or `FluentTestDb(failOnWarnings: true)`, not by reading logs.

- Regression benchmarks: `FluentBenchmark.runScenarios(suites: {...})` (queue, save, relations, deletes) with
  `report.nPlusOneSuspects` and `report.compareTo(baseline)`.

## A test file

```dart
import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late TodoProvider todos;

  setUp(() async {
    todos = TodoProvider();
    db = FluentTestDb(failOnWarnings: true);
    await db.open([todos]);
  });

  tearDown(() => db.close());

  test('watch shows new todos', () async {
    final List<int> sizes = [];
    final sub = todos.watch().listen((rows) => sizes.add(rows.length));
    await db.settle();
    await todos.save(Todo(title: 'a'));
    await db.settle();
    expect(sizes, [0, 1]);
    await sub.cancel();
  });

  test('expired rows are hidden', () async {
    await todos.save(Todo(title: 'a')); // Todo.timeToLive: 1 day
    db.clock.advance(const Duration(days: 2));
    expect(await todos.count(), 0);
  });
}
```

## Schema changes

```dart
final FluentTestDb db = FluentTestDb(persistent: true);
await db.open([TodoProviderV1()]);
await v1.save(...);
await db.restart([TodoProviderV2()]); // same file, new schema: check the data and db.issues
```

## API

- `setUpFluentTests({bool? logging})`: FFI SQLite, a temporary databases directory per file, logs off (on with
  `logging: true` or `FLUENT_LOG`), closes a database left open.
- `FluentTestDb({name, persistent = false, failOnWarnings = false})`: `open(providers, config:, fluentConfig:,
  removedColumns:, archiveRetention:, historyLimit:, resetOnSchemaError:)`, `restart(providers, ...)`,
  `close({keepFile})`, `settle({frame, timeout})`, `clock`, `issues`, `warnings`, `key`, `isOpen`,
  `FluentTestDb.closeCurrent()`.
- `db.plan(providers, removedColumns:, runCode:)` → `FluentMigrationPlan` (closes this database first, leaves another open one open, changes nothing):
  `expect(plan.losesData, isFalse)`; `open` / `restart` take `onMigrationPlan:`.
- `FluentTestClock`: `now`, `set(DateTime)`, `advance(Duration)`, `reset()`, `isMoved`.

## Benchmark on a phone

```dart
// dependencies: fluent_sqflite_benchmark (only for the run)
import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart';

debugPrint(await FluentBenchmark.run()); // parallel reads, longest UI stall while mapping
```
