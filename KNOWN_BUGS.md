# fluent_sqflite: known bugs

Real bugs that are not fixed yet. Planned work lives in `TODO.md`; fixed bugs and finished work in `FIXED_ISSUES.md`.
When a bug here is fixed, add a regression test and move the item to
`FIXED_ISSUES.md`. When auditing again, check these items first instead of reporting them as new.

## Open

None.

## Known limits (decided, not bugs)

- Only triggers recreated by a rebuild are checked (`brokenTrigger`); a SQLite build that compiles triggers only when
  they fire reports nothing.
- A row whose `_fs_metadata` is unreadable and no intact row of the table showed its tags reads a `DateTime` as
  local time (same instant); the damage is reported as `mappingValue`, re-saving the row fixes it.
- A relation list is protected by its instance: a model rebuilt from a read (`copyWith`) that keeps the read list
  removes only what the read showed, an empty list without a read behind it removes nothing (`relationListKept`). A
  new list with items (`[...list]`, `where(...).toList()`) is the app's full state and replaces the owned rows of a
  relation without `limit`.
- `purgeArchivedColumns` inside a transaction (or a task) of the database is skipped with `ignoredCall`: the purge
  needs the main connection and switches foreign keys, which a transaction cannot.
- ISO-8601 values of plain columns without a declared `DateTime` kind are not padded at start (only metadata knows
  their type); they get a `mappingValue` warning when read.
- `-0.0` is stored as `0.0` (SQLite normalizes it; not reported).
- A local `DateTime` stored as ISO text (no offset) in the hour repeated when the clocks go back reads back as the
  first instant with that wall-clock time (one hour earlier); reported as `precisionLost`. UTC values and the
  timestamp format keep the instant.
- A soft-delete stamp is `max(now, last + 1)`: after the clock goes back, a stamp can be later than now.
- Rows a new constraint rejects go to a quarantine table; their children stay in place and are reported as
  `danglingReferences` until the parent row is moved back (the one exception to "`foreign_key_check` is empty").
- A paged `watchRemote` holds the answered keys of all pages until the last page.
- An edited `onMigrate` body cannot be detected (a running app cannot read its code).
- A bootstrapped archive's retention starts at adoption (no older date exists).
- `FluentException.cause` stays the raw error (its `toString` is redacted).
- The timestamp format keeps milliseconds; cut microseconds are reported as `precisionLost`.
- `countRelated(item, 'unknown')` returns 0 with a warning (fall back and report).
- Defensive branches left uncovered on purpose (engine pause double completion, the tuner's `_giveUp`, bookkeeping
  after a failed write): safety nets against hangs.
- The FTS4 path is not tested: the FFI SQLite of the tests has no FTS4 (device check in `TODO.md`).
