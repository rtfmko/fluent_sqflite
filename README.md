# fluent_sqflite

A model-driven database layer for Flutter on top of [sqflite](https://pub.dev/packages/sqflite). Declare a model, call
methods — the library creates and migrates the tables, loads relations, keeps a soft-delete trash, streams live
queries and syncs with your server. No SQL needed; raw SQL stays available as an escape hatch.

```dart
final List<Article> top = await articles.find(where: FluentFilter.gte('likes', 100), orderBy: 'likes DESC', limit: 20);
```

## Why

* **Models instead of SQL.** Tables, columns, keys, indexes and relations come from your model. Schema changes are
  applied automatically on start — safely: removed columns are archived, rows a new constraint rejects are moved
  to a quarantine table, nothing is deleted without you asking.
* **Relations that just work.** A field `List<Post> posts` is enough: the library finds it, decides the kind from both
  sides and tells you what it decided. Or declare `one`, `oneOwned`, `many`, `manyToMany`, `through` (data on the
  link) and `oneOf` (one of several types): saved as a graph, loaded in batches (no N+1), deleted with the right cascade.
* **Smooth UI.** Reads run on a pool of read-only connections; big lists are turned into models in slices across
  frames or in a background isolate.
* **Offline first.** `watch` streams, `watchRemote` (cache → server → cache), full push / pull sync with conflicts,
  tombstones and incremental pulls.
* **Errors that explain themselves.** Every error says what happened, why, and how to fix it — with a stable
  `FluentErrorCode` and a `hint` (often with code to copy). An analyzer suggests indexes, paging and more.

## Install

```yaml
dependencies:
  fluent_sqflite: ^2.0.0
```

Works on Android and iOS (sqflite). For desktop use [sqflite_common_ffi](https://pub.dev/packages/sqflite_common_ffi); for tests,
[fluent_sqflite_test](packages/fluent_sqflite_test/README.md).

## Quick start

**1. A model** — a plain class that says how it is stored:

```dart
class Note extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Note({this.id, required this.title, this.done = false});

  final int? id; // the key: `id` by default, generated on insert
  final String title;
  final bool done;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'done': done};

  static Note fromJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, title: json['title'] as String, done: json['done'] as bool);
}
```

**2. A provider** — the table of the model:

```dart
class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(title: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note.fromJson(json);

  @override
  Note Function(Map<String, dynamic> json)? get isolateFactory => Note.fromJson; // optional: big lists in the background
}
```

**3. Open the database** once at start-up:

```dart
final NoteProvider notes = NoteProvider();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FluentDb.init([FluentGroup(dbKey: FluentDbKey('app'), providerList: [notes])]);
  runApp(const MyApp());
}
```

**4. Use it:**

```dart
await notes.save(Note(title: 'Buy milk'));
final List<Note> open = await notes.find(where: FluentFilter.eq('done', false), orderBy: 'created_at DESC');
await notes.updateById(1, {'done': true});
await notes.deleteById(1);           // soft delete: goes to the trash
await notes.trash.restoreById(1);    // back from the trash

notes.watch(orderBy: 'created_at DESC').listen((list) => print('${list.length} notes'));

// Stable "load more" paging (keyset): no repeated or skipped rows while new ones arrive.
FluentPage<Note> page = await notes.findPage(orderBy: 'created_at', descending: true, limit: 30);
page = await notes.findPage(orderBy: 'created_at', descending: true, limit: 30, after: page.next);
```

The same calls exist as statics (`FluentDb.find<Note>(...)`) and on models (`note.save()`, `note.delete()`).

## Learn more

| Topic | |
|---|---|
| [Models, keys, columns](doc/models.md) | `FluentStorable`, composite keys, indexes, checks, converters, enums, expiry |
| [Reading](doc/reading.md) | filters, ordering, `findPage`, `watch`, raw SQL |
| [Writing](doc/writing.md) | save strategies, `conflictOn`, field updates, soft delete, timestamps, transactions |
| [Relations](doc/relations.md) | `one` / `oneOwned` / `many` / `manyToMany` / `through` / `oneOf` / `auto`, relations without declarations, loading, `attach` / `detach` |
| [Schema and migrations](doc/schema.md) | automatic schema sync, migration steps, archive, quarantine, reports |
| [Sync](doc/sync.md) | `watchRemote`, `FluentSyncable` push / pull, conflicts, server keys, tombstones |
| [Performance](doc/performance.md) | read pool, isolate mapping, analyzer hints, `fluent_sqflite_benchmark` |
| [Errors and logging](doc/errors-and-logging.md) | `FluentException`, `FluentErrorCode`, `setupLogging`, hints |
| [Testing](doc/testing.md) | `fluent_sqflite_test`: `FluentTestDb`, moving the clock, `settle`, issues |
| [Upgrading from 1.x](doc/ai/migrations.md) | every renamed or removed member |

**AI assistants:** the package ships [agent skills](skills/) (install with `dart run skills@ get`) and an
[`llms.txt`](llms.txt). See [doc/ai](doc/ai/README.md).

An example app (REST → cache → paged list, plus an on-device benchmark) is in [example/](example/lib/main.dart).

## License

Apache-2.0.

Documentation and architectural improvements were refined with the help of Google Gemini.
