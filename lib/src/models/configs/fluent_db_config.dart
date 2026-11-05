// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/fluent_enum.dart';
import 'fluent_diagnostics.dart';
import 'sqlite_cache_size.dart';

/// Settings of one database (`FluentGroup.config`): SQLite pragmas, plus overrides of the global [FluentConfig].
///
/// The override fields ([readConnections], [trashRetention], [indexReferences], [autoRelations], [fullText],
/// [diagnostics], [batchKeys]) are `null` by default: the database follows `FluentConfig`. A table may override some of them again
/// in its model's `tableConfig`.
///
/// ```dart
/// FluentGroup(dbKey: AppDb.ledger, providerList: [...], config: FluentDbConfig.highIntegrity);
/// FluentGroup(dbKey: AppDb.cache, providerList: [...], config: const FluentDbConfig(trashRetention: Duration(days: 1)));
/// ```
class FluentDbConfig {
  /// Whether SQLite enforces foreign keys (`PRAGMA foreign_keys`, default `true`). Relation deletes rely on them;
  /// without them the library cleans dangling references itself.
  final bool enableForeignKeys;

  /// The journal mode (default [SQLiteJournalMode.wal]: readers never block the writer, and parallel reads work).
  final SQLiteJournalMode journalMode;

  /// How strictly writes are flushed to storage (default [SQLiteSynchronous.normal], safe with WAL).
  final SQLiteSynchronous synchronous;

  /// The memory budget of the page cache (default about 10 MB).
  final SQLiteCacheSize cacheSize;

  /// Keeps temporary tables and indexes of sorting / grouping in memory (`PRAGMA temp_store = MEMORY`, default `true`).
  final bool tempStoreInMemory;

  /// How long SQLite waits for a lock held by another connection before failing with `database is locked`
  /// (`PRAGMA busy_timeout`, default 5 s). `null` keeps the SQLite default (fail at once).
  final Duration? busyTimeout;

  /// Extra read-only connections of this database (0–4); `null` follows `FluentConfig.readConnections`. Only used
  /// in WAL mode.
  final int? readConnections;

  /// How long soft-deleted rows of this database stay in the trash; `null` follows `FluentConfig.trashRetention`.
  final Duration? trashRetention;

  /// Whether relation reference columns of this database get an index; `null` follows `FluentConfig.indexReferences`.
  final bool? indexReferences;

  /// Whether model fields holding stored models become relations without a declaration; `null` follows
  /// `FluentConfig.autoRelations`.
  final bool? autoRelations;

  /// How full-text indexes of this database are kept; `null` follows `FluentConfig.fullText`.
  final FluentFullText? fullText;

  /// What the library measures, suggests and tunes for this database; `null` follows `FluentConfig.diagnostics`.
  final FluentDiagnostics? diagnostics;

  /// Where the keys of batched `findById` / `findByIds` lookups come from; `null` follows `FluentConfig.batchKeys`.
  final FluentBatchKeys? batchKeys;

  /// Creates the settings of a database.
  const FluentDbConfig({
    this.enableForeignKeys = true,
    this.journalMode = SQLiteJournalMode.wal,
    this.synchronous = SQLiteSynchronous.normal,
    this.cacheSize = SQLiteCacheSize.defaultSize,
    this.tempStoreInMemory = true,
    this.busyTimeout = const Duration(seconds: 5),
    this.readConnections,
    this.trashRetention,
    this.indexReferences,
    this.autoRelations,
    this.fullText,
    this.diagnostics,
    this.batchKeys,
  });

  /// Data safety over speed, for records that must survive a crash or a power loss (payments, ledgers): rollback
  /// journal and `synchronous = FULL`. Reads run one at a time (no WAL).
  static const FluentDbConfig highIntegrity = FluentDbConfig(journalMode: SQLiteJournalMode.delete, synchronous: SQLiteSynchronous.full, tempStoreInMemory: false);

  @override
  String toString() => 'FluentDbConfig{journal: ${journalMode.name}, sync: ${synchronous.name}, cache: $cacheSize'
      '${enableForeignKeys ? '' : ', fk: off'}${readConnections == null ? '' : ', readConnections: $readConnections'}}';
}
