---
name: fluent-sqflite-queries
description: >-
  Use when the user is reading data with fluent_sqflite: findById, find, findFirst, findAll, count, exists,
  FluentFilter conditions, filters by relations (related / notRelated / relatedCount), full-text search
  (FluentIndex.fullText, search), projections (findMaps columns, pluck), aggregates (sum, avg, min, max,
  countDistinct, aggregate), ordering, paging with findPage / FluentCursor or limit and offset, live queries with
  watch / watchById / watchValue, rawQuery, and the FluentDb static read API.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: reading

## Rules

- Build conditions with `FluentFilter`, never by string concatenation. Pass Dart values as they are
  (`FluentFilter.eq('done', true)`, `FluentFilter.gte('created_at', DateTime(2026))`, enums): each is stored like its column on save (converter, enum by name or index, `dateTimeFormat`).
- `contains` / `startsWith` / `endsWith` take the text literally (`%` / `_` escaped); `like` keeps wildcards.
- Reads hide soft-deleted and expired rows. Use `provider.trash.find()` for the trash, `provider.withTrash.find()` /
  `includeExpired: true` to see them too.
- For "load more" lists use `findPage` with `after: page.next`. Do not page with `offset` on lists that change.
- Always pass `orderBy` with `limit` / `offset`: without it the order is undefined (the library prints a hint).
- `orderBy` may only name columns (`ASC` / `DESC`, `COLLATE`, `NULLS FIRST` / `LAST`, a function of one column);
  never pass user input through: map the user's choice to a column name. Expressions → `rawQuery`.
- Cancel `watch` subscriptions in `dispose`.
- Use provider calls (`posts.find(...)`) or the statics (`FluentDb.find<Post>(...)`); pass `dbKey:` only when the
  model is registered in several databases.
- Prefer the model API to SQL: `FluentFilter.related` instead of `IN (SELECT ...)` / joins, `aggregate` instead of
  `GROUP BY`, `findMaps(columns:)` / `pluck` for light lists, `search` instead of `LIKE '%...%'`.
- `rawQuery` is for read-only SQL (`SELECT` / `VALUES` / `WITH … SELECT` / reading `PRAGMA`, one statement), returns
  stored values and sees all rows; writing SQL fails with `FluentArgumentException`: use `execute`.
- `aggregate(orderBy:)` names group columns or value names only.
- Projections are maps (never partial models: saving one would overwrite the missing columns).

- `FluentFilter.ids` / `inList` / `notInList` take any number of values in every call (beyond 900 the library uses a
  temporary table; never chunk key lists yourself); `findPage(orderBy:)` needs columns `buildJson` writes; negative
  `limit` / `offset` are refused.

## Basic reads

```dart
final Post? post = await posts.findById(1);
final List<Post> drafts = await posts.find(
  where: FluentFilter.eq('status', Status.draft).and(FluentFilter.contains('title', 'dart')),
  orderBy: 'created_at DESC',
  limit: 20,
);
final Post? newest = await posts.findFirst(orderBy: 'created_at DESC');
final int count = await posts.count(where: FluentFilter.gte('rating', 4.0));
final bool known = await posts.exists(42);
final List<Post> trash = await posts.trash.find();         // soft-delete models only
final List<Post> picked = await posts.findByIds([3, 1, 2]);  // in this order
final bool any = await posts.existsWhere(FluentFilter.eq('status', Status.draft)); // first row is enough
```

Filter builders: `eq`, `notEq`, `gt`, `gte`, `lt`, `lte`, `between`, `inList`, `notInList`, `isNull`, `isNotNull`,
`like`, `contains`, `startsWith`, `endsWith`; combine with `.and(...)` / `.or(...)`; raw: `FluentFilter('"a" > ?', [1])`; a column with a space / dash goes quoted: `FluentFilter.eq('"first name"', 'Ann')`.
Several keys: `FluentFilter.ids([1, 2, 3])` (composite keys: `FluentKey`s).

## Paging

```dart
FluentPage<Post> page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 30);
final List<Post> shown = [...page.items];

Future<void> loadMore() async {
  if (!page.hasMore) return;
  page = await posts.findPage(orderBy: 'created_at', descending: true, limit: 30, after: page.next);
  shown.addAll(page.items);
}
```

`orderBy` is one column name (default: the key); the key is added automatically, so ties have a fixed order. Use the
same `orderBy` / `descending` for every page of a cursor. Store a cursor with `page.next!.encode()` and
`FluentCursor.decode(text)` (it round-trips bytes and non-finite doubles; garbage text fails with `FluentArgumentException`).
Cursors on `DateTime` columns of iso8601 tables work.

## Live queries

```dart
late final StreamSubscription<List<Post>> _sub;

@override
void initState() {
  super.initState();
  _sub = posts.watch(where: FluentFilter.eq('status', Status.published), orderBy: 'created_at DESC', limit: 50)
      .listen((list) => setState(() => _posts = list));
}

@override
void dispose() {
  _sub.cancel();
  super.dispose();
}
```

`watchById(id)` follows one model. Watchers update after changes of their table or of any table their relations
load from (every `maxDepth` level), and when a shown row expires (`timeToLive`). A change that cannot alter the
result does not re-run the query.

## Relations, search, projections, aggregates

```dart
await articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann')));
await articles.find(where: FluentFilter.notRelated('comments'));
await articles.find(where: FluentFilter.relatedCount('comments', min: 5));
await articles.find(where: FluentFilter.related('author.company', FluentFilter.eq('country', 'UA'))); // a path
await comments.find(where: FluentFilter.related<Post>('target', FluentFilter.eq('title', 'x')));    // a oneOf: one type

// Model: List<FluentIndex> get indexes => [FluentIndex.fullText(['title', 'body'])];
final List<Note> found = await notes.search(query, limit: 30);   // ranked; FluentFilter.search(query) combines

final List<Map<String, dynamic>> rows = await posts.findMaps(columns: ['id', 'title'], orderBy: 'id');
final List<String> emails = await users.pluck<String>('email');
final num total = await orders.sum('total');                     // 0 when empty; avg / min<V> / max<V> / countDistinct
final List<Map<String, dynamic>> report = await orders.aggregate(
  groupBy: ['status'],
  values: {'n': const FluentAggregate.count(), 'revenue': const FluentAggregate.sum('total')},
  orderBy: 'revenue DESC',
);
orders.watchValue(() => orders.sum('total'));                    // a live value
```

Search: every word must occur, the last one as a prefix; user input is never query syntax. FTS5 (ranked) or FTS4 on
devices without FTS5; `FluentDbConfig(fullText: FluentFullText.off)` searches with `LIKE`.

## Relations while reading

`relations: FluentLoad.eager` (default) loads the non-lazy relations one level deep (`maxDepth: 2` for more);
`FluentLoad.none` only the rows (load later with `model.loadRelations()`), `FluentLoad.all` the lazy ones too.
See the `fluent-sqflite-relations` skill.
