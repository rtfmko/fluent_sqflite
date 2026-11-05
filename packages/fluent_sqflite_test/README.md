# fluent_sqflite_test

Test helpers for [fluent_sqflite](../../README.md): run database code in plain `flutter test` on the Dart VM (no
device), with a database per test, a clock you can move, waiting for streams, and the issues the library raised.

```yaml
dev_dependencies:
  fluent_sqflite_test: ^2.0.0
```

```dart
void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late NoteProvider notes;

  setUp(() async {
    notes = NoteProvider();
    db = FluentTestDb();
    await db.open([notes]);
  });

  tearDown(() => db.close());

  test('the trash is emptied after its retention', () async {
    final Note note = Note(title: 'a');
    await notes.save(note);
    await notes.delete(note);
    db.clock.advance(const Duration(days: 8));
    expect(await notes.trash.empty(), 1);
  });
}
```

* `FluentTestDb` — in memory by default; `persistent: true` + `restart([...])` to test schema changes.
* `db.clock` — `advance` / `set` the time the library sees (expiry, trash retention, timestamps, sync).
* `db.settle()` — wait for `watch` streams instead of `Future.delayed`.
* `db.issues`, `db.warnings`, `failOnWarnings: true` — check what the library reported.

The guide: [Testing](../../doc/testing.md).
