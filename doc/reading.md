# Reading

Every read hides soft-deleted rows (`provider.withTrash.find()` shows them too) and expired rows (`includeExpired: true`).
`relations:` says which relations load — `FluentLoad.eager` (default), `FluentLoad.none` (only the rows) or
`FluentLoad.all` (lazy ones too) — and `maxDepth` how many levels (default 1); see [Relations](relations.md).

```dart
final Post? post = await posts.findById(1);
final List<Post> picked = await posts.findByIds([3, 1, 2]);           // in this order
final List<Post> light = await posts.findAll(relations: FluentLoad.none);
final List<Post> all = await posts.findAll(orderBy: 'created_at DESC');
final Post? newest = await posts.findFirst(orderBy: 'created_at DESC');
final int open = await posts.count(where: FluentFilter.eq('status', Status.draft));
final bool known = await posts.exists(42);
final bool taken = await users.existsWhere(FluentFilter.eq('email', email)); // stops at the first row
final List<Post> trash = await posts.trash.find();       // only the trash
final Post? any = await posts.withTrash.findById(1);     // live or trashed
```

`orderBy` names columns: `'created_at DESC, id'`, `'"name" COLLATE NOCASE'`, `'lower(name) NULLS LAST'`. Anything else
(sub-queries, `CASE`, comments, `;`) fails with `FluentArgumentException`, so a sort order that comes from the UI
can never run SQL of its own. Map the user's choice to a column instead of passing it through:

```dart
final String orderBy = switch (sort) { Sort.newest => 'created_at DESC', Sort.title => 'title COLLATE NOCASE' };
```

## Filters

`FluentFilter` builds safe, parameterized conditions; Dart values (`bool`, `DateTime`, enums, `Duration`) are converted
like on save.

```dart
FluentFilter.eq('status', Status.published)
    .and(FluentFilter.gte('rating', 4.0))
    .and(FluentFilter.contains('title', 'flutter').or(FluentFilter.inList('id', [1, 2, 3])));
```

Also: `notEq`, `gt`, `lt`, `lte`, `between`, `notInList`, `isNull`, `isNotNull`, `like`, `startsWith`, `endsWith`,
`ids([...])` (rows by key, composite keys too), `related` / `notRelated` / `relatedCount` (by related models), `search`.
Raw conditions: `FluentFilter('"views" > ? * 2', [100])`. A column name with a space or a dash is quoted by you
(otherwise it reads as an expression), values are still converted for it: `FluentFilter.eq('"first name"', 'Ann')`.

Values are Dart values and are stored like their column on save when the query runs: the column's converter, the
`enumValues` enum (by name or by index, `storeEnumsAsNames`), the table's `dateTimeFormat`, epoch milliseconds for
timestamp / soft-delete / expiry columns. `contains` / `startsWith` / `endsWith` match `%`, `_` and `\` literally;
`like` keeps its wildcards.

`FluentFilter.ids([...])` takes up to 900 keys (900 divided by the key columns for composite keys); for longer lists
use `findByIds`, which splits them.

## Paging

**`findPage` (recommended):** keyset pagination. Each page starts right after the last row of the previous one, so
rows added or deleted meanwhile never make pages repeat or skip rows, and page 100 is as fast as page 1.

```dart
FluentPage<Post> page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 30);
// later: the next page
page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 30, after: page.next);
if (!page.hasMore) print('the end');
```

The key is added to the order, so equal `orderBy` values have a fixed order. A cursor can be kept as text
(`page.next!.encode()`, `FluentCursor.decode(text)`). An index on the `orderBy` column makes big tables fast.

**`limit` / `offset`:** fine for small, rarely changing lists. Always pass `orderBy` — without it SQLite returns rows in no
defined order, so pages can repeat or skip rows (the library prints a hint with the fix).

`findPage(orderBy:)` names columns the model writes in `buildJson` (or its timestamp / soft-delete columns); others are
refused before the first page. A negative `limit` or `offset` is refused everywhere (`FluentArgumentException`).

## Live queries

```dart
final StreamSubscription<List<Post>> sub = posts.watch(where: FluentFilter.eq('status', Status.published), orderBy: 'created_at DESC')
    .listen((list) => setState(() => _posts = list));

posts.watchById(1).listen((post) => print(post?.title));
```

A watcher re-runs when its table or a table its relations load from changes (every `maxDepth` level), but only when
the change can alter its result; changes of one frame are coalesced (`coalesce`, default 16 ms). Rows that expire
(`timeToLive`) leave the result on their own: the watcher looks again when the next shown row expires. Cancel the
subscription when the widget goes away.

For values that are not lists of models (sums, counts, projections), `watchValue` re-runs any query after a change
and emits only when the result differs:

```dart
StreamBuilder<num>(
  stream: orders.watchValue(() => orders.sum('total', where: FluentFilter.eq('status', OrderStatus.paid))),
  builder: (context, s) => Text('${s.data ?? 0}'),
);
```

## Filters by relations

Filter by the models of a relation without SQL: `related` (at least one), `notRelated` (none), `relatedCount`.
The name is the one declared in `relations`; a path follows several relations.

```dart
await articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann')));
await articles.find(where: FluentFilter.related('comments'));                     // with at least one comment
await articles.find(where: FluentFilter.notRelated('tags'));                      // without tags
await articles.find(where: FluentFilter.relatedCount('comments', min: 5));
await articles.find(where: FluentFilter.related('author.company', FluentFilter.eq('country', 'UA')));
```

They work for every relation type (one, owned, many-to-many, a model related to itself), combine with `and` / `or`
and work in every read, `count`, aggregates, `deleteWhere` / `updateWhere` and `watch` (which then also follows the
related tables). Related rows in the trash, expired ones and rows outside the relation's own `where` do not count.
Reference columns are indexed, so these filters stay fast (see `indexReferences` in [performance](performance.md)).

## Search

Declare a full-text index and search its columns:

```dart
@override
List<FluentIndex> get indexes => [FluentIndex.fullText(['title', 'body'])];

final List<Note> found = await notes.search(query, limit: 30);           // best matches first
await notes.find(where: FluentFilter.search(query).and(FluentFilter.eq('archived', false)));
```

* Every word must occur, in any indexed column; the last word also matches longer words (search as you type,
  `prefix: false` turns it off). Punctuation, quotes and operators in the text are separators, so user input never
  breaks the query. An empty text matches every row.
* Case and diacritics are ignored in every language. There is no stemming: "cats" does not find "cat".
* The library keeps a SQLite FTS table (`__fluent_fts_<table>`) up to date with every write (triggers), fills it from
  existing rows when the index is added and rebuilds it when the table changes.
* `fullText` (`FluentConfig`, per database `FluentDbConfig`, per table `FluentTableConfig`): `auto` (default) uses FTS5 and ranks by relevance; where the device's SQLite has
  no FTS5 (some Android versions) it uses FTS4 (no ranking) and logs it. `fts4` gives the same behaviour on every
  device; `off` keeps no FTS tables and compares words with `LIKE` (slow on big tables, a hint says so).
* The table needs a rowid (not `withoutRowId`).

## Projections and aggregates

```dart
final List<Map<String, dynamic>> rows = await posts.findMaps(columns: ['id', 'title', 'created_at'], orderBy: 'id');
final List<String> emails = await users.pluck<String>('email', orderBy: 'email');
final List<Status> used = await posts.pluck<Status>('status', distinct: true);

final num revenue = await orders.sum('total', where: FluentFilter.eq('status', OrderStatus.paid)); // 0 when empty
final double? average = await orders.avg('total');
final DateTime? first = await orders.min<DateTime>('created_at');
final int customers = await orders.countDistinct('customer_id');

final List<Map<String, dynamic>> byStatus = await orders.aggregate(
  groupBy: ['status'],
  values: {'orders': const FluentAggregate.count(), 'revenue': const FluentAggregate.sum('total')},
  having: FluentFilter.gt('revenue', 1000),   // result names
  orderBy: 'revenue DESC',
);
byStatus.first['status']; // OrderStatus.paid: group columns, min and max come back as Dart values
```

Maps hold Dart values (`DateTime`, enums, lists, converted values), like models. They are not models on purpose: a
model built from some columns would carry defaults in the others, and saving it would overwrite them. `sum` / `avg`
take numeric columns; aggregates skip the trash and expired rows like every read.

## Raw SQL

```dart
final List<Map<String, dynamic>> rows = await posts.rawQuery('SELECT status, COUNT(*) AS n FROM posts GROUP BY status');
await posts.execute('UPDATE posts SET rating = 0 WHERE rating IS NULL');
```

The escape hatch for what the model API cannot express. `rawQuery` only runs read-only SQL (`SELECT`, `VALUES`, `WITH … SELECT`, reading `PRAGMA`s; one statement; anything
that writes fails with `FluentArgumentException`), returns
stored values and sees all rows (no soft-delete or expiry filter); `execute` runs statements that change data.

## Through `FluentDb` and models

Every read is also a static (`FluentDb.find<Post>(...)`, `FluentDb.findPage<Post>(...)`) — `dbKey` selects the
database when a model lives in several. `post.refresh()` reloads a model, `post.exists()` checks it.
