# Testing

The `fluent_sqflite_test` package runs your database code in plain `flutter test` on the Dart VM — no device or
emulator — and gives tests what they need: a database per test, a clock you can move, a way to wait for streams, and
the issues the library raised.

```yaml
dev_dependencies:
  fluent_sqflite_test: ^2.0.0
```

Until the package is on pub.dev, depend on it from the repository (it always matches the library version):

```yaml
dev_dependencies:
  fluent_sqflite_test:
    git:
      url: https://github.com/rtfmko/fluent_sqflite.git
      path: packages/fluent_sqflite_test
```

```dart
import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests(); // SQLite through FFI, a temporary directory, logs off

  late FluentTestDb db;
  late NoteProvider notes;

  setUp(() async {
    notes = NoteProvider();
    db = FluentTestDb();          // in memory: no file, every test starts empty
    await db.open([notes]);
  });

  tearDown(() => db.close());

  test('saves and reads', () async {
    await notes.save(Note(title: 'a'));
    expect((await notes.findAll()).single.title, 'a');
  });
}
```

## FluentTestDb

* `FluentTestDb({name, persistent, failOnWarnings})`; `open(providers, config:, fluentConfig:, ...)` takes the options
  of `FluentGroup` and `FluentDb.init`. One test database is open at a time: opening another closes the first.
* `close()` closes it, removes its file and puts the clock back (`close(keepFile: true)` to inspect the file).
* `persistent: true` stores a file in the temporary directory. Needed for `restart` and for read connections (an
  in-memory database has no read pool).
* `restart(newProviders)` closes and opens the same file again: test a schema change between app versions.

```dart
final FluentTestDb db = FluentTestDb(persistent: true);
await db.open([NoteProviderV1()]);
await notesV1.save(...);
await db.restart([NoteProviderV2()]); // the new schema runs against the old data
```

## Planned migrations

`db.plan(newProviders)` shows what opening the file with newer models would change, without changing it (another open
test database stays open; see
`FluentDb.planMigrations` in [Schema](schema.md)): guard releases against data loss.

```dart
final FluentTestDb db = FluentTestDb(persistent: true);
await db.open([NoteProviderV1()]);
await notesV1.save(...);
final FluentMigrationPlan plan = await db.plan([NoteProviderV2()]);
expect(plan.losesData, isFalse);
expect(plan.warnings, isEmpty);             // no possible rename, no type change of stored values
await db.restart([NoteProviderV2()]);       // then apply it
```

`open` / `restart` also take `onMigrationPlan:`.

## Time

`db.clock` is the time the library sees: timestamps, soft-delete stamps, expiry (`timeToLive`), trash retention,
sync times and `maxAge`. It is the real time until the test moves it.

```dart
await notes.delete(note);
db.clock.advance(const Duration(days: 8));    // past the default trash retention of 7 days
expect(await notes.trash.empty(), 1);

db.clock.set(DateTime(2026, 1, 1));           // stopped at a fixed moment
```

## Streams

`await db.settle()` waits until no call is queued or running and no change happened for one frame (watch streams
refresh within a frame). Use it instead of `Future.delayed` after writes a stream should show:

```dart
final List<int> sizes = [];
notes.watch().listen((rows) => sizes.add(rows.length));
await db.settle();
await notes.save(Note(title: 'a'));
await db.settle();
expect(sizes, [0, 1]);
```

## Issues

`db.issues` holds every issue the library raised since `open` (hints when diagnostics collect them, automatic changes,
warnings, errors); `db.warnings` only warnings and errors. With `FluentTestDb(failOnWarnings: true)`, `close()` fails
the test when there are any. `FluentDiagnostics.none` in `fluentConfig` makes a database fully predictable (no
measuring, no hints, no tuning).

Library logs are off in tests; `setUpFluentTests(logging: true)` or the `FLUENT_LOG` environment variable turns them on.
