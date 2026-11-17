# fluent_sqflite: known bugs

Real bugs that are not fixed yet. Planned work lives in `TODO.md`; fixed bugs and finished work in `FIXED_ISSUES.md`.
When a bug here is fixed, add a regression test and move the item to
`FIXED_ISSUES.md`. When auditing again, check these items first instead of reporting them as new.

## Open

None (audit 2 is fixed, see `FIXED_ISSUES.md`).

## Known limits (decided, not bugs)

- Only triggers recreated by a rebuild are checked (`brokenTrigger`); a SQLite build that compiles triggers only when
  they fire reports nothing.
- A row whose `_fs_metadata` is unreadable and no intact row of the table showed its tags reads a `DateTime` as
  local time (same instant); the damage is reported as `mappingValue`, re-saving the row fixes it.
- A model rebuilt from a read without some relations (e.g. `copyWith`) does not carry `unloadedRelations`: saving it
  treats its empty lists as "remove all" (the read's own model is protected).
- `purgeArchivedColumns` inside a transaction (or a task) of the database is skipped with `ignoredCall`: the purge
  needs the main connection and switches foreign keys, which a transaction cannot.
- ISO-8601 values of plain columns without a declared `DateTime` kind are not padded at start (only metadata knows
  their type); they get a `mappingValue` warning when read.
- `-0.0` is stored as `0.0` (SQLite normalizes it).
- A paged `watchRemote` holds the answered keys of all pages until the last page.
- An edited `onMigrate` body cannot be detected (a running app cannot read its code).
- A bootstrapped archive's retention starts at adoption (no older date exists).
- `FluentException.cause` stays the raw error (its `toString` is redacted).
- The timestamp format keeps milliseconds; cut microseconds are reported as `precisionLost`.
- A `dbKey` with no open database fails with `providerNotFound`.
- A damaged (non-database) file fails `init` with `invalidConfiguration`.
- `countRelated(item, 'unknown')` returns 0 with a warning (fall back and report).
- Defensive branches left uncovered on purpose (engine pause double completion, the tuner's `_giveUp`, bookkeeping
  after a failed write): safety nets against hangs.
- The FTS4 path is not tested: the FFI SQLite of the tests has no FTS4 (device check in `TODO.md`).
