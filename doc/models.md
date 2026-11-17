# Models, keys and columns

A model is a plain class that extends `FluentStorable`; its provider (`FluentProvider<T>`) is the table.

```dart
enum Status { draft, published }

class Post extends FluentStorable with FluentTimestamps {
  Post({this.id, required this.title, this.status = Status.draft, this.tags = const [], this.rating});

  final int? id;
  final String title;
  final Status status;
  final List<String> tags; // stored as JSON
  final double? rating;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'status': status, 'tags': tags, 'rating': rating};

  @override
  Map<String, List<Enum>> get enumValues => {'status': Status.values};
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';

  // Used to infer the columns: give every field a non-null value.
  @override
  Post get modelSample => Post(title: '', tags: const [''], rating: 0);

  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(
    id: json['id'] as int?,
    title: json['title'] as String,
    status: json['status'] as Status,
    tags: (json['tags'] as List).cast<String>(),
    rating: json['rating'] as double?,
  );
}
```

## How columns are inferred

`buildJson()` of `modelSample` decides the columns: `String` → TEXT, `int` / `bool` / `Duration` / `Color` → INTEGER,
`double` → REAL, `DateTime` → INTEGER (epoch ms), `List` / `Map` → JSON TEXT, `Enum` → TEXT (by name), `Uri`, `BigInt`,
`Locale`, `TimeOfDay` → TEXT. Values come back in `fromCacheJson` with their Dart type (`json['created'] as DateTime`).

A field that is `null` in the sample cannot be typed: give the sample a value, or declare the column:

```dart
@override
List<FluentDbColumn> get missingColumns => [FluentDbColumn.timestamp('synced_at')];
```

Column factories: `FluentDbColumn.primary`, `text`, `integer`, `real`, `boolean`, `timestamp`, `blob`, `converted`.
Options: `isNotNull`, `isUnique`, `indexed`, `defaultValue` (a Dart value, or `FluentSqlExpression.currentTimestamp`),
`collation`, `checkConstraint`. `oldName` (rename a column without losing data) belongs to the main constructor only:
`FluentDbColumn(name: 'title', type: FluentDbDataType.text, oldName: 'name')`.

A `defaultValue` is stored like a saved value (the column's converter, an enum converter, the table's `dateTimeFormat`);
when that changes the stored text of a default, the column's `DEFAULT` is updated on the next sync. A `double` NaN
default throws a `FluentSchemaException`; infinity is allowed.

## Keys

The default key is an auto-increment `id`. Saving a model with `id: null` generates it; `model.primaryKeyValue`
returns it afterwards.

```dart
// A text key
@override
FluentDbColumn get primaryKey => FluentDbColumn(name: 'uuid', type: FluentDbDataType.text, isPrimaryKey: true);

// A composite key
@override
List<FluentDbColumn> get primaryKeys => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')];
```

Rows of a composite key are addressed with a `FluentKey`: `stats.findById(FluentKey({'user_id': 7, 'day': '2026-10-20'}))`,
or `model.key`. Override `bool get withoutRowId => true;` to make such tables smaller.

Names derived from a model type or a relation name (the default `tableName`, `<model>_id` / `<relation>_id`
columns, link tables) are snake case by words: `UserName` → `user_name`, `HTTPAuthor` → `http_author`, `userID` →
`user_id`, `Item2` → `item2`, `Box<Note>` → `box_note`. A database written by 1.x (`h_t_t_p_author`, `item_2`) is
adopted at the first start: tables, reference and link columns, link tables and polymorphic type values are renamed,
the data stays (`legacyNameAdopted`). Set `tableName` / `foreignKey` to choose a name yourself.

## Indexes and checks

```dart
@override
List<FluentIndex> get indexes => [FluentIndex.unique(['email']), FluentIndex(['last_name', 'first_name'])];

@override
List<FluentCheck> get checks => [const FluentCheck('"end" >= "start"', name: 'valid_period')];
```

Indexes are added to existing databases on the next start. A new or stricter check never deletes rows: rows that
violate it are moved to a quarantine table (see [Schema](schema.md)).

## Converters

A converter decides exactly how one field is stored:

```dart
@override
List<FluentDbColumn> get missingColumns => [
  FluentDbColumn.converted('address', FluentJsonConverter<Address>(fromJson: Address.fromJson)),
  FluentDbColumn.converted('when', const FluentIsoDateTimeConverter()), // ISO text instead of epoch ms
];
```

Built in: `FluentEnumConverter` (what `enumValues` uses: by name, or `byName: false` for the index),
`FluentIsoDateTimeConverter`, `FluentEpochDateTimeConverter` (`utc: true` reads UTC times back), `FluentJsonConverter`. Write your own by extending
`FluentConverter<D, S>` (`toSql`, `fromSql`, `sqlType`).

Built-in types: a `RegExp` keeps its flags; a `double` NaN cannot be stored (the save fails with `unsupportedValue`;
infinity is fine); the timestamp format keeps `DateTime` in milliseconds (microseconds are cut and reported once
per column as `precisionLost`: use iso8601 or a converter to keep them). A stored enum value the enum no longer has reads as `null` with a `mappingValue` warning whose
hint has the `UPDATE` that fixes the rows; in a NOT NULL column it is a `FluentSchemaException`.
ISO-8601 text written by the library always has six fraction digits (`2026-01-02T03:04:05.000000Z`); three-digit values of
an earlier version are padded once at start (`storedFormatAdopted`; a read-only database gets a `mappingValue` warning
instead). `aggregate` keeps the UTC flag of a date result.

A converter on a key column is applied once. Keys you pass (`findById`, `FluentKey`, `FluentFilter.ids`, `save`) and
keys on models are Dart values and are converted like on save; keys the library reads from rows, and the reference
columns that point at them, hold the stored form and are never converted again. Server keys in sync (`deletedKeys`,
tombstones) are Dart values.

## Mixins

A mixin adds a feature and the calls that go with it — a model without it does not even see them:

* `FluentTimestamps` — `createdAt` / `updatedAt`, filled by the library (columns `created_at` / `updated_at`).
* `FluentSoftDeletable` — deletes go to a trash (`deletedAt`, `isDeleted`); adds `provider.trash`
  (find, restore, deleteForever, empty) and `provider.withTrash`; see [Writing](writing.md#delete-and-soft-delete).
* `FluentRelations` — relations to other models (`relations`); adds `loadRelations`, `findRelated`, `countRelated`,
  `attach`, `detach`; see [Relations](relations.md).
* `FluentSyncable` (on the provider) — change tracking and push / pull; see [Sync](sync.md).

## Calls on the model

Every call exists on the model itself, on its provider and as a `FluentDb` static — use whichever reads best:

```dart
final Post post = Post(title: 'Hello');
await post.save();                      // = posts.save(post) = FluentDb.save<Post>(post)
await post.delete();
final Post? fresh = await post.refresh();
final Article? owner = (await comment.findParents<Article>()).firstOrNull;
```

## Expiry

`timeToLive` says how long a row lives after it is saved: once the time has passed the row is hidden from every read
and removed by `clearExpired()` and the start-up maintenance (`includeExpired: true` still sees it). Set it per instance,
Writes treat an expired row as missing, like `findById`: `update`, `updateAll`, `patch` skip it, `updateById` /
`updateWhere` skip it unless `includeExpired: true` (its expiry stays), `insertOnly` writes a new row over it, and
`upsert` renews it (the model's `timeToLive`, or no expiry when the model has none). `watch` drops a row when it expires,
following `db.clock` in tests.
or for the whole table — then every save extends the life:

```dart
await (Session(token: t)..timeToLive = const Duration(hours: 1)).save();

class CachedImage extends FluentStorable {
  @override
  Duration? get timeToLive => const Duration(days: 30);
  // ...
}
```

## Database groups

A `FluentGroup` is one database file with its providers. Options: `config` (`FluentDbConfig`), `directory`, `readOnly`
(prebuilt files), `inMemory` (tests, caches), `removedColumns`, `archiveRetention`, `resetOnSchemaError` (throw-away caches
only), `autoRelationFallback`. Use `dbKey` to address a group when a model lives in several databases.

One provider instance belongs to one group: a second group needs its own instance (`init` refuses a shared one).

## Settings

Settings live on three levels; a narrower one wins:

| Level | Where | Holds |
|---|---|---|
| global | `FluentDb.init(groups, config: FluentConfig(...))`, later `FluentDb.configure(...)` | watchdogs, maintenance intervals, mapping of big lists, `diagnostics` (hints / tuner), `defaultPolicy`, and the defaults below |
| database | `FluentGroup(config: FluentDbConfig(...))` | SQLite pragmas (journal, synchronous, cache, foreign keys, busy timeout), `readConnections`, `diagnostics` |
| table | the model's `FluentTableConfig get tableConfig` | how dates and enums are stored, `isolateMapping` |

`FluentDb.init(groups)` without `config:` keeps the settings in use (the last `configure` / `init(config:)`), not the defaults;
the same for `planMigrations`. `trashPurgeInterval`, `optimizeInterval`, `pauseWatchdog` and `transactionWatchdog`: `null`
switches the timer off, zero or a negative value falls back to the default (`configFallback`).

`trashRetention`, `indexReferences` and `fullText` exist on all three levels; on the database and table levels `null`
follows the wider one (the global values are never null),
`readConnections` on the global and database levels.

```dart
await FluentDb.init(groups, config: const FluentConfig(trashRetention: Duration(days: 30)));

FluentGroup(dbKey: AppDb.ledger, providerList: [...], config: FluentDbConfig.highIntegrity); // FULL sync, no WAL

class Draft extends FluentStorable with FluentSoftDeletable {
  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 2));
}
```
