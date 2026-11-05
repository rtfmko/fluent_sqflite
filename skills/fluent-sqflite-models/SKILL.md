---
name: fluent-sqflite-models
description: >-
  Use when the user is working with fluent_sqflite models and setup: declaring a FluentStorable model and its
  FluentProvider, keys (auto id, text, composite FluentKey), columns, indexes, checks, enums, converters, expiry,
  FluentTimestamps / FluentSoftDeletable, column types and FluentDbColumn options, overriding the key, column names
  and WITHOUT ROWID, and opening databases with FluentDb.init and FluentGroup (settings: see fluent-sqflite-setup).
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: models and setup

## Rules

- A model extends `FluentStorable` and implements `buildJson()`; its table is a `FluentProvider<T>` subclass with
  `tableName`, `modelSample` and `fromCacheJson`. Never write `CREATE TABLE`: the schema comes from the model.
- Columns are inferred from `modelSample.buildJson()`. Give **every field a non-null value** in `modelSample`
  (`tags: const ['']`, `rating: 0`, `syncedAt: DateTime(2000)`), or declare the column in `missingColumns`. A `null`
  in the sample makes init fail with a schema report.
- A field that holds other stored models (`List<Post> posts`, `Person? author`) is a relation, never a column: put it
  in `buildJson` with a typed value in the sample (`posts: const []`, `author: Person(name: '')`) and the library
  finds it, or declare it (see the relations skill).
- `fromCacheJson` receives Dart types: `DateTime`, `bool`, enums (with `enumValues`), `Duration`, `List<dynamic>` /
  `Map<String, dynamic>` for JSON. Cast lists: `(json['tags'] as List).cast<String>()`. Nullable columns: `as T?`.
- Default key: auto-increment `id`. Save with `id: null` to generate it; read it back with `model.primaryKeyValue`.
  Composite keys: override `primaryKeys`, address rows with `FluentKey({'a': 1, 'b': 'x'})` or `model.key`.
- Every enum field needs `enumValues` (`{'status': Status.values}`) to come back as the enum (stored by name).
- Add a static factory with the body of `fromCacheJson` and return it from `isolateFactory`: big lists are then
  mapped in a background isolate. It must not use the provider.
- Call `await FluentDb.init([...])` once, before any database call, after `WidgetsFlutterBinding.ensureInitialized()`.
  Every provider used by a relation must be in the same `FluentGroup`.
- One model type per table. If the same type must live in two tables, give each its own subtype
  (`class ArchivedNote extends Note`); otherwise calls by type fail with `ambiguousProvider`.
- Database names (`FluentDbKey('app')`) use letters, digits and `_` only.

- NaN doubles cannot be saved; the timestamp format keeps milliseconds (cut microseconds are reported:
  `precisionLost`); unknown stored enum values read as `null` (nullable) with a `mappingValue` warning. One provider
  instance per group.
- Default names: `HTTPAuthor` → `http_author`, `Item2` → `item2`, `Box<Note>` → `box_note`; 1.x names
  (`h_t_t_p_author`, `item_2`) are renamed at the first start (`legacyNameAdopted`). Raw SQL uses the new names.
- A converter on a key column is applied once: pass Dart keys to calls; never convert keys yourself.

## Model and provider

```dart
import 'package:fluent_sqflite/fluent_sqflite.dart';

enum Status { draft, published }

class Post extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Post({this.id, required this.title, this.status = Status.draft, this.tags = const [], this.rating});

  final int? id;
  final String title;
  final Status status;
  final List<String> tags;
  final double? rating;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'status': status, 'tags': tags, 'rating': rating};

  @override
  Map<String, List<Enum>> get enumValues => {'status': Status.values};

  @override
  List<FluentIndex> get indexes => [const FluentIndex(['status', 'created_at'])];

  static Post fromJson(Map<String, dynamic> json) => Post(
    id: json['id'] as int?,
    title: json['title'] as String,
    status: json['status'] as Status,
    tags: (json['tags'] as List).cast<String>(),
    rating: json['rating'] as double?,
  );
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  @override
  Post get modelSample => Post(title: '', tags: const [''], rating: 0);

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post.fromJson(json);

  @override
  Post Function(Map<String, dynamic> json)? get isolateFactory => Post.fromJson;
}
```

## Opening the database

```dart
final PostProvider posts = PostProvider();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FluentDb.init([
    FluentGroup(dbKey: FluentDbKey('app'), providerList: [posts]),
    FluentGroup(dbKey: FluentDbKey('cache'), providerList: [ImageCacheProvider()], resetOnSchemaError: true),
  ]);
  runApp(const App());
}
```

`FluentGroup` options (`inMemory`, `readOnly`, `directory`, `removedColumns`, `resetOnSchemaError`, `onMigrationPlan`,
…), the three settings levels (`FluentConfig` → `FluentDbConfig` with the SQLite pragmas → `FluentTableConfig`),
diagnostics, priorities and the lifecycle are in the **fluent-sqflite-setup** skill.

```dart
@override
FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 90), storeEnumsAsNames: true);
```

## Columns, keys, converters

```dart
@override
List<FluentDbColumn> get missingColumns => [
  FluentDbColumn.timestamp('synced_at'),                                   // a field that can be null
  FluentDbColumn.text('email', isUnique: true, collation: FluentCollation.noCase),
  FluentDbColumn.text('nick', oldName: 'nickname'),                       // rename, data kept
  FluentDbColumn.converted('address', FluentJsonConverter<Address>(fromJson: Address.fromJson)),
  FluentDbColumn.integer('level', defaultValue: 1),
];

@override
List<FluentDbColumn> get primaryKeys => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')];

@override
List<FluentCheck> get checks => [const FluentCheck('"end" >= "start"')];

@override
List<FluentIndex> get indexes => [
  const FluentIndex(['status', 'created_at']),                                // multi-column
  const FluentIndex.unique(['email']),                                        // no duplicates
  const FluentIndex(['due'], where: '"done_at" IS NULL'),                    // partial: only open tasks
  const FluentIndex.fullText(['title', 'body']),                              // search (queries skill)
];
```

Defaults are Dart values (`defaultValue: 'active'`); SQL expressions use `FluentSqlExpression.currentTimestamp`.

Column builders: `FluentDbColumn.primary`, `.text`, `.integer`, `.real`, `.boolean`, `.timestamp`, `.blob`,
`.converted(name, converter)`; the full constructor `FluentDbColumn(name:, type: FluentDbDataType.x, ...)` adds
`isNotNull`, `isUnique`, `indexed`, `defaultValue`, `checkConstraint` (`'"age" >= 0'`), `collation`
(`FluentCollation.noCase` / `binary` / `rTrim`), `oldName`, `converter`. Types inferred from the sample without
declaring them: `int`, `double`, `bool`, `String`, `DateTime`, `Uint8List`, `Duration`, `BigInt`, `Uri`, `Color`,
`Locale`, `TimeOfDay`, enums, `List` / `Map` (JSON).

Converters: `FluentEnumConverter(Status.values, byName: true)`, `FluentJsonConverter<T>(fromJson: ...)`,
`FluentIsoDateTimeConverter()` / `FluentEpochDateTimeConverter(utc: true)` for one column; dates of a whole table as text:
`FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601)`. Own types: `extends FluentConverter<D, S>`.

```dart
// A text / UUID key instead of the auto-increment id (needed for sync between devices)
@override
FluentDbColumn get primaryKey => FluentDbColumn(name: 'uuid', type: FluentDbDataType.text, isPrimaryKey: true);

@override
bool get withoutRowId => true;          // compact tables with a non-integer key (no full-text index then)

@override
String get expiryColumn => 'expires_at'; // also: softDeleteColumn, createdAtColumn / updatedAtColumn of the mixins
```

## Mixins and calls on the model

`FluentTimestamps` (`createdAt` / `updatedAt`), `FluentSoftDeletable` (trash: adds `provider.trash` /
`provider.withTrash`, `isDeleted`), `FluentRelations` (adds `loadRelations`, `findRelated`, `countRelated`, `attach`,
`detach`; see the relations skill). A model without a mixin does not see its calls. Every call also exists on the
model: `await post.save()`, `await post.delete()`, `await note.restore()`, `await post.refresh()`.

## Expiry

```dart
await (Session(token: t)..timeToLive = const Duration(hours: 1)).save(); // hidden after an hour, removed by clearExpired()

@override
Duration? get timeToLive => const Duration(days: 30); // the whole table: every save extends the life
```
