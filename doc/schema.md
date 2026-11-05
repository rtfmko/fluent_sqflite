# Schema and migrations

You do not write `CREATE TABLE` or `ALTER TABLE`. On every start, `FluentDb.init` compares each model with the schema it
applied last time (stored in `__fluent_schema`) and applies only the difference. An unchanged schema costs three reads
and no transaction: every table keeps a fingerprint of its model, steps, relations and settings.

| Change in the model | What happens |
|---|---|
| new field | column added (`NOT NULL` without default stays nullable until every row has a value) |
| `oldName: 'x'` on a column | column renamed, data kept |
| type / key / constraint / `CHECK` changed | table rebuilt with its data, triggers, views and your own indexes |
| field removed | column **archived** as `__fluent_removed_<name>_r<rev>` (renamed in place when SQLite can, deleted after `archiveRetention`, default 30 days) |
| new index | created |
| a relation changes its kind (many-to-many ↔ owned list) | the links are copied to the new place (see [Relations](relations.md)) |

## Nothing is lost implicitly

* **Removed columns** are archived, not dropped. Drop them for good with a step (`dropColumns`) or
  `FluentGroup(removedColumns: FluentColumnRemoval.drop)`; bring them back with `restoreColumns`.
* **Rows a new constraint rejects** (a new `CHECK`, a new `UNIQUE`) are moved to the quarantine table
  `__fluent_rejected_<table>_r<rev>` with a warning that says how to fix and restore them. When *every* row would be
  rejected the schema itself is probably wrong: the change fails and the table stays as it was.
* **Changes that keep the data but probably not as meant** are reported with code to copy: a column type that
  changes on a table with rows (`columnTypeChanged`: convert the values with a step), a removed and an added
  column of the same type (`possibleRename`: bring the values back with `restoreColumns`, and use `oldName` next
  time), a column back in the model whose earlier values are archived (`columnRestorable`: the library never
  restores them by itself, the name may mean something else now).
* A failing change rolls back the whole start; the error (`FluentSchemaException`, code `migrationFailed`) says which
  step failed and how to fix it. `FluentGroup(resetOnSchemaError: true)` recreates the file instead — for
  throw-away caches only.

Rules written in `customSql` of an added column (`NOT NULL`, `UNIQUE`, `PRIMARY KEY`, `DEFAULT`) are handled like the
flags. A model index never replaces an index of the app with the same name: it is skipped with an `indexSkipped`
warning until you rename it. On a device without FTS5 / FTS4 an existing full-text index and its triggers are dropped
(`fullTextFallback`): writes keep working and searches use `LIKE`.

If a rebuild removes a column that a trigger of yours uses, SQLite would only fail when the trigger fires. The start
tries every recreated trigger (nothing is executed or changed) and warns with `brokenTrigger`: the trigger is kept,
the issue shows `DROP TRIGGER IF EXISTS …` plus your original SQL to adapt. Switching `enableForeignKeys` from off to
on checks the data at that start: rows that point nowhere are reported (`danglingReferences`) and cleaned by the
start-up maintenance. Tables and columns a 1.x database named by the old naming rule are renamed at the first start
(`legacyNameAdopted`, a `renameTable` change in the plan).

## One-time steps

For data changes, give the model migration steps. Each needs a `version` or an `id`, runs once per database, in
declaration order, inside the schema transaction:

```dart
@override
List<FluentDbMigration> get migrations => [
  FluentDbMigration(id: 'fill_status', rawSql: ["UPDATE posts SET status = 'draft' WHERE status IS NULL"]),
  FluentDbMigration(version: 3, dropColumns: ['legacy_flag']),
  FluentDbMigration(id: 'restore_note', restoreColumns: {'note': 'comment'}),
  FluentDbMigration(id: 'split_names', onMigrate: (txn) async { /* any Dart code with the transaction */ }),
];
```

Do not edit a step after it ran (the library warns): add a new one.

* Steps change data that exists, so on a new install (the table is just created) they are only marked as applied.
  Rows every install needs belong in code after `init` (the library hints when a step inserts rows).
* `dropColumns` removes only columns the model no longer has (a column still in the model is kept with a warning).
  In the release that removes the field it is dropped at once, without being archived first.
* Provider calls work inside `onMigrate` (they join the schema transaction); tables after this one in the group may
  not be synchronized yet, so prefer SQL on `txn` there.

Step labels (`id`, else `v<version>`) must be unique per table: a duplicate fails the start (`schemaConflict`) before
anything runs. Columns in a step's `dropColumns` can still be read by the same step's `rawSql` / `onMigrate`; they are
dropped right after it, in the same transaction.

## Before applying: the plan

`FluentDb.planMigrations(groups)` shows what `init` would change, without changing it: one `FluentMigrationPlan` per
database with every change (`FluentSchemaChange`: `kind`, `table`, `subject`, `description`), the issues the start
would report, `losesData` (a column or an archive deleted for good) and `rebuilds`. Call it before `init`: in a debug
screen, a test, a release check. The sync runs in a transaction that is rolled back; a file that does not exist is
planned in memory and not created. `onMigrate` code is left out (listed in `skippedCode`) unless `runCode: true`.
A view or trigger a rebuild cannot recreate is a `viewOrTriggerLost` change and counts in `losesData`.

A table from an older database (no snapshot yet) is compared with what is really on disk: when its rules differ from
the model (`NOT NULL`, `UNIQUE`, `REFERENCES`, `CHECK`, defaults) it is rebuilt once. Rebuilds keep row ids, the
`AUTOINCREMENT` counter and the app's own indexes (whatever their name); a `NOT NULL` column with a default gets the
default for its NULL rows.

```dart
for (final FluentMigrationPlan plan in await FluentDb.planMigrations(groups)) {
  debugPrint('$plan');                // users: archived column "nick", added column "display", rebuilt table, ...
  if (plan.losesData) { /* stop the release */ }
}
```

`FluentGroup(onMigrationPlan: ...)` decides at every start, before anything is applied: it is called with the plan
when something would change; returning `false` stops that database with `FluentSchemaException`
(`migrationRefused`, the plan in the hint) and changes nothing.

```dart
FluentGroup(dbKey: AppDb.main, providerList: [...], onMigrationPlan: (plan) => !plan.losesData)
```

In tests: `await db.plan([UserProviderV2()])` of `fluent_sqflite_test` (see [Testing](testing.md)).

Read-only groups are not planned (their plan is empty; the file is not opened).

## Reports

```dart
for (final FluentSchemaReport r in await FluentDb.schemaReport()) {
  print(r); // state of every table + the change history (__fluent_schema_history)
}
await FluentDb.purgeArchivedColumns(olderThan: Duration.zero); // drop archived columns now (a queued write)
```

`FluentDb.schemaReport()` runs in the queue (after earlier calls, before later ones), so it never shows a half-done
sync.
