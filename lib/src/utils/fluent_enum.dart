// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:typed_data';
import 'dart:ui';

/// The SQLite type of a column (`FluentDbColumn.type`).
enum FluentDbDataType {
  /// SQLite `TEXT`: [String], and JSON, enum names, `BigInt`, `Uri`, `Locale`, ISO dates.
  text('TEXT'),

  /// SQLite `INTEGER`: [int], `bool` (0 / 1), `DateTime` (epoch milliseconds), `Duration`, `Color`.
  integer('INTEGER'),

  /// SQLite `REAL`: [double].
  real('REAL'),

  /// SQLite `BLOB`: [Uint8List] (binary data).
  blob('BLOB'),

  /// The whole definition comes from `FluentDbColumn.customSql`, which must start with a SQLite type or contain a
  /// `REFERENCES` clause. [sql] is not a type keyword here.
  custom('custom');

  /// The raw SQL keyword associated with this type.
  final String sql;

  const FluentDbDataType(this.sql);

  /// A [FluentDbDataType] for the Dart [value]: [int], [bool], [Duration], [Color] -> [integer]; other numbers ->
  /// [real]; [Uint8List] -> [blob]; everything else (also `DateTime`) -> [text]. Schema inference does not use it
  /// (it stores `DateTime` as INTEGER, see `FluentStorable.tableSchema`).
  ///
  /// Example:
  /// ```dart
  /// final FluentDbDataType type = FluentDbDataType.fromType(123); // FluentDbDataType.integer
  /// ```
  static FluentDbDataType fromType(dynamic value) {
    // Map types that translate to SQLite INTEGER
    if (value is int || value is bool || value is Duration || value is Color) {
      return FluentDbDataType.integer;
    }

    // Map types that translate to SQLite REAL
    if (value is double || value is num) {
      return FluentDbDataType.real;
    }

    // Map types that translate to SQLite BLOB
    if (value is Uint8List) {
      return FluentDbDataType.blob;
    }

    // Map everything else (String, Map, List, Enum, BigInt, Locale, etc.) to TEXT
    return FluentDbDataType.text;
  }
}

/// Where big lists are turned into models (see `FluentConfig.isolateMapping`).
enum FluentIsolateMapping {
  /// Measure the mapping cost per table; lists that would block the UI longer than half a frame are mapped in a
  /// background isolate (when the provider has an `isolateFactory`; otherwise a hint suggests one).
  smart,

  /// Every list of a provider with an `isolateFactory` is mapped in a background isolate.
  always,

  /// Always on the UI isolate (big lists are still sliced, see `FluentConfig.sliceAfterRows`).
  never,
}

/// Where the keys of rows come from when several `findById` / `findByIds` lookups are answered by one query (see
/// `FluentConfig.batchKeys`).
enum FluentBatchKeys {
  /// Fast (default): the key of each returned row is read from the stored row, decoded like the mapping does (the
  /// column's converter or codec). No `buildJson` call per model. Exact whenever the model keeps the key it was
  /// loaded with; a model whose `fromCacheJson` changes the key needs [fromModels]. A hint (`batchKeysMismatch`) is
  /// logged once when a returned row matches none of the requested keys.
  fromRows,

  /// Exact: the key is read from each built model (`buildJson`), also when `fromCacheJson` changes it. Slower:
  /// `buildJson` runs once per returned model, so throughput drops on big batches.
  fromModels,
}

/// Log levels, from the most verbose to the most severe.
///
/// `FluentDb.setupLogging(level: ...)` shows that level and everything more severe. Default: [info] in debug and
/// profile builds, [warning] in release builds.
enum FluentLogLevel {
  /// Every SQL statement (arguments hidden unless `showSqlArguments: true`).
  sql,

  /// Internal details for troubleshooting (scheduling, merging, cache decisions).
  debug,

  /// Normal operation: init, migrations, maintenance.
  info,

  /// Suggestions with code to copy (`FluentIssueType.hint`).
  hint,

  /// Changes the library made by itself while the app runs (`FluentIssueType.autoFix`).
  autoFix,

  /// Something to look at: a call failed (the caller got the error), a setting was wrong and replaced.
  warning,

  /// A failure nobody else receives (background work, maintenance, shutdown).
  error,
}

/// SQLite journal modes (`PRAGMA journal_mode`, `FluentDbConfig.journalMode`, default [wal]).
enum SQLiteJournalMode {
  /// **DELETE** (SQLite's own default): the rollback journal is deleted at the end of each transaction.
  delete,

  /// **TRUNCATE:** The journal is truncated to zero length instead of deleted.
  /// Often faster than DELETE on many file systems as it avoids file metadata updates.
  truncate,

  /// **PERSIST:** The journal is left in place but overwritten. Prevents the
  /// need to create/delete the journal file, reducing disk I/O at the cost
  /// of always keeping the file on disk.
  persist,

  /// **MEMORY:** The rollback journal is stored in RAM rather than on disk.
  /// Extremely fast, but risks database corruption if the application
  /// crashes or loses power before a commit is finalized.
  memory,

  /// **WAL** (write-ahead logging, the library's default): changes go to a separate `-wal` file, so readers (the read
  /// connection pool) run while one writer writes.
  wal,

  /// **OFF:** Disables the rollback journal entirely. Maximum performance,
  /// but there is no mechanism to recover the database in the event of a
  /// crash during a write operation.
  off;

  /// Returns the uppercase SQL-compatible string representation for
  /// `PRAGMA journal_mode` commands.
  String get value => name.toUpperCase();
}

/// Defines the `PRAGMA synchronous` setting, which controls how aggressively
/// SQLite forces data to the physical disk platter or flash memory.
///
/// This setting creates a direct trade-off between the integrity of the
/// database in the event of a system crash and the raw performance of write operations.
enum SQLiteSynchronous {
  /// **OFF (0):** SQLite continues immediately after handing data to the
  /// operating system. If the OS crashes, the database may become corrupted.
  /// Highest performance, highest risk.
  off,

  /// **NORMAL (1):** SQLite syncs at critical moments but not at every step.
  /// Significantly safer than OFF and much faster than FULL. Recommended
  /// for WAL (Write-Ahead Logging) mode.
  normal,

  /// **FULL (2):** SQLite waits for the operating system to confirm that
  /// data has been physically written to the storage medium. Guarantees
  /// maximum data integrity in the event of a power failure.
  full,

  /// **EXTRA (3):** Similar to FULL, but includes an extra sync of the
  /// directory meta-data. Extremely safe, but rarely necessary for typical
  /// mobile application workloads.
  extra;

  /// Returns the uppercase SQL-compatible string representation for
  /// `PRAGMA synchronous` commands.
  String get value => name.toUpperCase();
}

/// How `save` / `saveAll` write models whose row may already exist (matched by the key, or by `conflictOn`).
///
/// A row in the trash counts as missing: `upsert` / `insertOnly` bring it back (outcome `restored`), `updateOnly` /
/// `patch` skip it.
enum FluentSaveStrategy {
  /// Inserts new rows; existing rows are left as they are (outcome `skipped`).
  insertOnly,

  /// Updates existing rows with every field of the model and inserts the others (default). A conflict on another
  /// UNIQUE column fails with a `FluentConstraintException`.
  upsert,

  /// Updates existing rows, but `null` fields of the model keep their stored values; missing rows are skipped.
  patch,

  /// Updates existing rows with every field of the model; missing rows are skipped (nothing is inserted).
  updateOnly,
}

/// How `DateTime` values of columns without a converter are stored (`FluentTableConfig.dateTimeFormat`). The
/// library's own time columns (timestamps, soft delete, expiry) are always epoch milliseconds.
enum FluentDateTimeFormat {
  /// ISO 8601 text (`2026-05-25T05:15:10.000Z`): readable in any SQLite browser; sorts correctly only when all values
  /// use the same time zone (e.g. all UTC).
  iso8601,

  /// Milliseconds since epoch as INTEGER (default): compact, fast to compare and index. Microseconds are cut off
  /// (`DateTime.utc(2024, 1, 1, 0, 0, 0, 0, 7)` is read back as `2024-01-01T00:00:00.000Z`, so it is no longer equal
  /// to the saved value). Use [iso8601] or a converter that keeps microseconds when they matter.
  timestamp,
}

/// Which relations a read loads with the models.
enum FluentLoad {
  /// None: only the rows themselves (fastest). Load relations later with `loadRelations`.
  none,

  /// The relations declared without `lazy: true` (default).
  eager,

  /// Every relation, the lazy ones too.
  all,
}

/// What kind of change a [FluentChangeEvent] reports (`FluentDb.onEvent(kinds: {...})`).
enum FluentChangeKind {
  /// Models were inserted or updated by `save` / `saveAll` (also inside relation writes).
  save,

  /// Existing rows were changed: `update`, `updateById`, `updateWhere`, relation links (`attach`, `detach`).
  update,

  /// Rows were deleted: soft or hard deletes, `trash.empty`, `clearExpired`.
  delete,

  /// Soft-deleted rows came back (`restore`).
  restore,

  /// The whole table was emptied (`clearTable`, `FluentDb.clear`, `FluentDb.deleteDatabases`).
  clear,
}

/// How a database keeps full-text indexes (`FluentIndex.fullText`), see `FluentDbConfig.fullText`.
enum FluentFullText {
  /// FTS5 (ranking by relevance), or FTS4 where the device's SQLite has no FTS5 (an info log says so).
  auto,

  /// FTS4 everywhere: the same behaviour on every device, no ranking by relevance.
  fts4,

  /// No full-text tables: searches compare the words with `LIKE` (slow on big tables; a hint says so).
  off,
}

/// What `syncWithServer` does.
enum FluentSyncStrategy {
  /// Send local changes (changed rows, soft-deleted rows, hard-delete tombstones) to the server.
  push,

  /// Receive changes from the server and apply them locally.
  pull,

  /// [push], then [pull] (default): local changes reach the server before its answer is applied.
  full,
}

/// What happens locally to rows the server reports as deleted (`FluentPullResult.deletedKeys`).
enum FluentRemoteDeleteBehavior {
  /// Soft delete when the model supports it, otherwise delete permanently (default).
  auto,

  /// Soft delete; for models without soft delete the rows are kept, with a warning and a hint.
  soft,

  /// Delete permanently.
  hard,

  /// Keep the rows (ignore remote deletions).
  keep,
}

/// Where `watchRemote` stands (see `FluentRemoteEvent.phase`).
enum FluentRemotePhase {
  /// The rows come from the local cache; no fetch ran (yet).
  cached,

  /// `fetch` is running; the rows are the cache.
  fetching,

  /// The answer of `fetch` was stored (or the cache is younger than `maxAge`); the rows are the stored ones.
  fresh,

  /// `fetch` or storing its answer failed (`FluentRemoteEvent.error`); the rows are the cache.
  failed,
}

/// How `watchRemote` stores the rows `fetch` returns.
enum FluentRemoteStore {
  /// Save them (insert or update); other cached rows stay (default). Works with `limit` (pages).
  merge,

  /// Save them and delete the cached rows of `where` the answer does not contain (matched by `serverKey`): the answer
  /// is the full set. Not with `limit` (falls back to [merge]); nothing is deleted when a fetched row has no server
  /// key. Rows with changes not sent yet (`FluentSyncable`) stay.
  mirror,

  /// Replace the cached rows of `where` with the answer in one transaction (permanent delete, then insert). Not
  /// with `limit` (falls back to [merge]).
  replace,

  /// Do not store; `fresh` events carry the fetched rows themselves.
  none,
}

/// Where the rows of `watchRemote` come from.
enum FluentRemoteSource {
  /// The cache at once, then the server (default).
  cacheThenRemote,

  /// Only after the server answered (no `cached` event first).
  remoteOnly,

  /// Only the cache; `fetch` is not called.
  cacheOnly,
}

/// What a write with relations (`update(withRelations: true, syncMode: ...)`, `save(relationSync: ...)`) does with
/// related rows that are missing from the model's relation lists.
enum FluentRelationSyncMode {
  /// Keep them: the lists only add or update related rows (partial data, additive updates). The default of
  /// `update(withRelations: true)`; `save` without `relationSync` follows each relation's `keepMissing`.
  preserveLocal,

  /// The lists are the full state: related rows missing from them are removed (owned children deleted, links
  /// unlinked).
  replace,
}
