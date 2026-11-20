---
name: fluent-sqflite-schema
description: >-
  Use when the user is changing a fluent_sqflite model's schema or data between app versions: adding, renaming or
  removing fields, changing types, keys, indexes or CHECK constraints, writing FluentDbMigration steps (rawSql,
  dropColumns, restoreColumns, onMigrate), archived columns, the quarantine of rejected rows, previewing changes with
  FluentDb.planMigrations / FluentGroup.onMigrationPlan, schemaReport, or a migrationFailed / migrationRefused /
  schemaConflict error at start.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: schema changes and migrations

## Rules

- Change the **model**, not the database: the schema is synchronized on every start (only the difference is applied).
  Never run `ALTER TABLE` / `CREATE TABLE` yourself for model tables.
- Rename a field with `oldName` (main constructor `FluentDbColumn(name:, type:, oldName:)`; factories have none); otherwise a rename is "remove + add" and the old data is only archived.
- A removed field is archived (`__fluent_removed_<name>_r<rev>`), not dropped. Drop it on purpose with
  `FluentDbMigration(id: ..., dropColumns: ['x'])`; bring it back with `restoreColumns: {'x': 'y'}`.
- `oldName` plus a new column under the old name: the data moves, the new column starts empty. Two columns with the same
  `oldName`: the first gets the data, the second stays empty (`schemaFallback`). `oldName` onto a name a live column holds:
  the old holder is archived ("replaced by ...") and the rename runs; a swap exchanges the values once. A step that leaves a model column missing
  fails the start (`schemaConflict`), nothing changes.
- A new `NOT NULL` field needs a `defaultValue`, or a step that fills it; until every row has a value it stays nullable.
- Data changes go into one-time steps with a unique `version` or `id`. Never edit or reorder a step that may have
  run on a device: add a new step.
- A new `CHECK` / `UNIQUE` that existing rows violate does not fail: those rows move to
  `__fluent_rejected_<table>_r<rev>` with a warning. Write a step that fixes and moves them back.
- Never set `resetOnSchemaError: true` on a database with user data (it deletes the file on a schema failure).
- `dropColumns` only removes columns the model no longer has; remove the field and add the step in the same release.
- Steps are only marked as applied on a new install (no old data): create rows every install needs in code after init.
- Read the start-up issues: `possibleRename` (removed + added column of the same type: restore with
  `restoreColumns`, use `oldName` next time), `columnTypeChanged` (convert the values with a step),
  `columnRestorable` (the field is back, its old values are archived: restore them explicitly if they are the same).
- An unchanged schema costs three reads at start. A table changed outside the library (its `CREATE TABLE` text
  differs from the last sync) is synchronized again: a column added by hand is archived like a removed field.
- `planMigrations` never throws for a failing step or schema: `plan.failure` says why the start would fail.

- Step labels must be unique per table; a step's `dropColumns` stay readable in that step. `customSql` rules of added
  columns count like flags. A model index never replaces an app index of the same name (`indexSkipped`).

- A rebuild warns about app triggers that no longer fit (`brokenTrigger`, kept). Foreign keys switched on: dangling
  rows are cleaned at that start. `schemaReport()` is queued. 1.x derived names are renamed at the first start.

## Common changes

```dart
// Rename a column (data kept)
@override
List<FluentDbColumn> get missingColumns => [FluentDbColumn(name: 'display_name', type: FluentDbDataType.text, oldName: 'nick')];

// A new required field with a default
FluentDbColumn.text('status', isNotNull: true, defaultValue: 'draft'),

// One-time data steps
@override
List<FluentDbMigration> get migrations => [
  FluentDbMigration(id: 'fill_status', rawSql: ["UPDATE posts SET status = 'draft' WHERE status IS NULL"]),
  FluentDbMigration(id: 'drop_legacy', dropColumns: ['legacy_flag']),
  FluentDbMigration(id: 'bring_back_note', restoreColumns: {'note': 'comment'}),
  FluentDbMigration(
    id: 'split_names',
    onMigrate: (txn) async { // txn: the sqflite Transaction of the schema change
      for (final Map<String, Object?> r in await txn.query('people', columns: ['id', 'full_name'])) {
        final List<String> parts = (r['full_name'] as String? ?? '').split(' ');
        await txn.update('people', {'first_name': parts.first, 'last_name': parts.skip(1).join(' ')}, where: 'id = ?', whereArgs: [r['id']]);
      }
    },
  ),
];
```

Steps run once per database, in declaration order, inside the schema transaction (a failure rolls the whole start
back: `FluentSchemaException` with `code == FluentErrorCode.migrationFailed` and a hint naming the step).

## Rows rejected by a new constraint

```dart
FluentDbMigration(
  id: 'restore_rejected_posts',
  rawSql: [
    'UPDATE "__fluent_rejected_posts_r4" SET "end" = "start" WHERE "end" < "start"',
    'INSERT INTO posts (id, title, start, "end") SELECT id, title, start, "end" FROM "__fluent_rejected_posts_r4"',
    'DROP TABLE "__fluent_rejected_posts_r4"',
  ],
),
```

The warning at start names the exact quarantine table and revision. Children of a quarantined parent keep their reference (`danglingReferences`, whole again once the parent row is moved back).

## Before applying

```dart
for (final FluentMigrationPlan plan in await FluentDb.planMigrations(groups)) { // before init; changes nothing
  debugPrint('$plan');
  plan.losesData; plan.rebuilds; plan.changes; plan.issues; plan.skippedCode; // onMigrate runs only with runCode: true
}
FluentGroup(..., onMigrationPlan: (plan) => !plan.losesData); // refuse a start that would drop data (migrationRefused)
```

In tests: `expect((await db.plan([ProviderV2()])).losesData, isFalse)` (`fluent_sqflite_test`).

`plan.changes` are `FluentSchemaChange`s (`kind`, `table`, `subject`, `description`, `losesData`); kinds
(`FluentSchemaChangeKind`): `createTable`, `addColumn`, `renameTable`, `renameColumn`, `changeColumn`, `archiveColumn`, `dropColumn`,
`purgeArchive`, `restoreColumn`, `rebuildTable`, `primaryKey`, `constraints`, `createIndex`, `dropIndex`,
`quarantineRows`, `runStep`, `linkTable`, `moveRelationData`, `fullText`, `viewOrTriggerLost` (counts in `losesData`). `plan.failure` holds the error a start would
hit. Removed columns: `FluentGroup(removedColumns: FluentColumnRemoval.archive)` (default) or `drop`.

## Inspecting

```dart
for (final FluentSchemaReport r in await FluentDb.schemaReport()) {
  debugPrint('$r'); // r.tables: FluentTableSnapshot (columns, key, indexes, archived: FluentArchivedColumn,
                    // pendingNotNull, steps, relations); r.history: FluentSchemaHistoryEntry (changes, success, error)
}
await FluentDb.purgeArchivedColumns(olderThan: Duration.zero);
```
