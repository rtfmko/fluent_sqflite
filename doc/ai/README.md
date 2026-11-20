# fluent_sqflite for AI assistants

Version: 2.0.0. This folder and [`skills/`](../../skills/) are written for coding agents. Humans: see the
[guide](../../README.md#learn-more).

## Install the skills in a project

```bash
dart run skills@ get -p fluent_sqflite
```

The skills are copied into the project's `.agents/skills/` and picked up automatically. Each covers one area:

| Skill | Use when |
|---|---|
| [fluent-sqflite-models](../../skills/fluent-sqflite-models/SKILL.md) | declaring models / providers, keys, column types, converters |
| [fluent-sqflite-setup](../../skills/fluent-sqflite-setup/SKILL.md) | `FluentDb.init`, groups, settings and pragmas, diagnostics, priorities, lifecycle |
| [fluent-sqflite-queries](../../skills/fluent-sqflite-queries/SKILL.md) | reading, filters, search, aggregates, `findPage`, `watch` |
| [fluent-sqflite-writes](../../skills/fluent-sqflite-writes/SKILL.md) | save strategies, updates, soft delete, transactions |
| [fluent-sqflite-relations](../../skills/fluent-sqflite-relations/SKILL.md) | relations (also `through`, `oneOf`, found in `buildJson`), loading, saving graphs |
| [fluent-sqflite-schema](../../skills/fluent-sqflite-schema/SKILL.md) | schema changes between app versions, migration steps, migration plans |
| [fluent-sqflite-sync](../../skills/fluent-sqflite-sync/SKILL.md) | `watchRemote`, push / pull sync |
| [fluent-sqflite-testing](../../skills/fluent-sqflite-testing/SKILL.md) | tests: `FluentTestDb`, moving time, waiting for streams |
| [fluent-sqflite-troubleshooting](../../skills/fluent-sqflite-troubleshooting/SKILL.md) | errors, warnings, hints, performance |
| [fluent-sqflite-upgrade](../../skills/fluent-sqflite-upgrade/SKILL.md) | code that broke after an update |

## References

* [migrations.md](migrations.md) — every renamed or removed member, with search text and before → after.
* [error-codes.md](error-codes.md) — every `FluentErrorCode`: meaning, cause, fix.
* [issues.md](issues.md) — every `FluentIssueKind` (hints, automatic changes, warnings, background errors).
* [Guarantees](../guarantees.md) — the 31 promises of the library (atomic, no data loss, no hang, ...), how they are tested, their limits.
* [AGENTS.md snippet](agents-snippet.md) — rules to paste into a project's `AGENTS.md` / `CLAUDE.md`.

## Ten rules that prevent most mistakes

1. Never write SQL for model tables (`CREATE` / `ALTER` / `INSERT`): use the model and the provider API.
2. `modelSample` gives every field a non-null value (columns are inferred from it), or the column is in `missingColumns`.
3. `await FluentDb.init([...])` before any call; relation providers in the same `FluentGroup`.
4. Conditions are `FluentFilter`s with Dart values; never concatenate strings. `orderBy` names columns only: map user
   choices to column names.
5. Many rows: `saveAll`; atomic work: `FluentDb.transaction`; never await an outside Future inside a transaction.
6. Paged lists: `findPage(after: page.next)`; with `limit` / `offset` always `orderBy`.
7. Relations on the model (`with FluentRelations`, `relations` getter), read in `fromCacheJson` by name. A field put into
   `buildJson` with a typed sample value is found without a declaration (check the `autoRelations` hint).
8. Schema changes: change the model; data changes: a `FluentDbMigration` with a new `id`; never edit an applied step.
   Check a release with `FluentDb.planMigrations` (`losesData`) or guard it with `FluentGroup(onMigrationPlan:)`.
9. Errors: catch `FluentException`, branch on `e.code`, apply `e.hint`.
10. Big lists: a static factory in `isolateFactory`; follow `💡` hints from the log.
