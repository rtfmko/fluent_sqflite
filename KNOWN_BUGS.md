# fluent_sqflite: known bugs

Real bugs that are not fixed yet. Planned work lives in `TODO.md`; fixed bugs and finished work in `FIXED_ISSUES.md`.
When a bug here is fixed, add a regression test and move the item to
`FIXED_ISSUES.md`. When auditing again, check these items first instead of reporting them as new.

## Open

1. **LOW.** A damaged `_fs_metadata` value restores the instant of a `DateTime` but loses its UTC flag: the model gets
   a local time (a test in `test/provider/crud` pins the current behaviour).
2. **LOW.** `FluentTask.staticWeight`: a `find` without a helper weighs 40, with any helper and no `limit` 80. The
   unbounded-find weight is added only when a helper exists, so an unfiltered `find` looks cheaper than a filtered one.
3. **LOW.** `findPage` cursor values on a column with a converter are not checked against the column type; a wrong
   value fails later in SQL instead of with a typed error and a hint.
4. **LOW.** The maintenance timers (trash purge, `PRAGMA optimize`) are real `Timer.periodic`, not `FluentClock`, so
   tests cannot move them with `db.clock`.

## Known limits (decided, not bugs)

- Only triggers recreated by a rebuild are checked (`brokenTrigger`); a SQLite build that compiles triggers only when
  they fire reports nothing.
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
