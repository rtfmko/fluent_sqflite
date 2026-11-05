# AGENTS.md snippet

Paste this block into the `AGENTS.md` (or `CLAUDE.md`, `.cursorrules`, …) of a project that uses fluent_sqflite.

```markdown
## Database: fluent_sqflite 2.x

- Install the package skills once: `dart run skills@ get -p fluent_sqflite` (then follow `.agents/skills/fluent-sqflite-*`).
- Models extend `FluentStorable` (`buildJson`); each table is a `FluentProvider<T>` (`tableName`, `modelSample`,
  `fromCacheJson`). Never write SQL for model tables; the schema is synchronized from the models on start.
- `modelSample` must give every field a non-null value, or declare the column in `missingColumns`.
- Conditions: `FluentFilter.eq(...)`, `.and(...)` — never string concatenation. Paged lists: `findPage(after: page.next)`.
- Many rows: `saveAll`. Atomic work: `FluentDb.transaction(() async { ... })`, short, no outside Futures awaited inside.
- Relations: on the model with `FluentRelations` (`one / oneOwned / many / manyToMany / through / oneOf`), or a field
  in `buildJson` with a typed sample value (`posts: const []`) that the library finds; read them in `fromCacheJson` by
  name. Check the `autoRelations` hint and declare a relation whose guessed kind is wrong.
- `orderBy` names columns only; never pass user input as SQL.
- Schema changes: edit the model (`oldName` to rename). Data changes: a new `FluentDbMigration(id: ...)`; never edit an
  applied step. Check what a release changes with `FluentDb.planMigrations` (`plan.losesData`).
- Tests: the `fluent_sqflite_test` package (`setUpFluentTests`, `FluentTestDb`, `db.settle()`, `db.clock`).
- Errors: catch `FluentException`, branch on `e.code`, apply `e.hint`. Follow `💡` hints printed by the library.
```
