---
name: fluent-sqflite-upgrade
description: >-
  Use when the user upgrades fluent_sqflite (for example from 1.x to 2.0) and code no longer compiles, or the analyzer
  reports deprecated fluent_sqflite members: saveItem, findOne, hardDelete, FluentDbRelation, FluentLogger,
  MigrationFailedException, localWhere, markAsSyncedFields and other renamed or removed APIs.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: upgrading

## Steps

1. Run `dart analyze` and collect every error and deprecation that mentions a fluent_sqflite name.
2. Open [references/migrations.md](references/migrations.md). For each table row, search the code for the text in
   "Search for" and rewrite every match as shown in "Before → After". Work table by table (Reading, Writing,
   Deleting, Relations, Sync, Errors, Logging and configuration, Schema).
3. Use the new names only; never keep or reintroduce an old one.
4. Read "Behaviour changes" in the reference and check the code that depends on each item (expired / soft-deleted
   rows in reads, `save` on trashed rows, errors logged as warnings, …).
5. Run `dart analyze` and the tests again. Repeat until nothing fluent_sqflite-related is reported.

## Rules

- The database file needs no manual migration: the schema is adopted and upgraded on the first start of the new
  version (old tracking tables, `deleted_at` / timestamp columns, relations).
- Old string conditions become `FluentFilter('sql with ?', [args])`; prefer the typed builders (`FluentFilter.eq`).
- Shared `Batch` / `executor` parameters become one `FluentDb.transaction(() async { ... })`.
- Provider methods lost `dbName:`; `FluentDb` statics use `dbKey:`. `FluentDb` has only statics: `FluentDb().init` →
  `FluentDb.init`, `closeAll` → `FluentDb.close`.
- Relations: `Map<Type, FluentDbRelation>` → `List<FluentRelation> get relations` on the **model** `with FluentRelations`;
  choose the type by meaning (`one`, `oneOwned`, `many`, `manyToMany`) or `FluentRelation.auto`.
- Exceptions: catch the new class and branch on `e.code`; `originalError` is `cause`.

## Example

```dart
// 1.x
await provider.saveItem(note, saveStrategy: FluentSaveStrategy.patch);
final Note? first = await provider.findOne();
await provider.hardDeleteById(5);
final List<Note> open = await provider.findItemsBy(false, key: 'done');

// 2.0
await provider.save(note, strategy: FluentSaveStrategy.patch);
final Note? first = await provider.findFirst(orderBy: 'id');
await provider.trash.deleteForeverById(5);
final List<Note> open = await provider.find(where: FluentFilter.eq('done', false));
```
