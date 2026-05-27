// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import '../../utils/utils.dart';
import '../models.dart';

/// Configuration object for tuning SQLite database performance and integrity behavior.
///
/// This class encapsulates the standard pragma settings required for high-performance,
/// production-grade database interactions. It serves as the single source of truth
/// when initializing new database connections or migration pipelines.
/// *
///     ### Usage Example:
///
///     final SQLitePerformanceConfig config = SQLitePerformanceConfig(
///       journalMode: SQLiteJournalMode.wal,
///       cacheSize: SQLiteCacheSize.megaBytes(10),
///       enableForeignKeys: true,
///     );
///   */
class SQLitePerformanceConfig {
  /// Enables relational constraints. While essential for data integrity,
  /// disabling this can provide a slight speed boost for bulk import operations.
  final bool enableForeignKeys;

  /// Defines the transaction logging strategy. [SQLiteJournalMode.wal] is highly
  /// recommended for concurrency.
  final SQLiteJournalMode journalMode;

  /// Determines how aggressively writes are flushed to physical storage.
  /// [SQLiteSynchronous.normal] balances speed and safety.
  final SQLiteSynchronous synchronous;

  /// Sets the memory budget for the database page cache.
  final SQLiteCacheSize cacheSize;

  /// If true, stores temporary indices and tables in RAM (`PRAGMA temp_store = MEMORY`),
  /// reducing disk I/O for complex sorting/grouping operations.
  final bool tempStoreInMemory;

  /// Optimizes the database for multi-threaded access.
  final bool enableConcurrentReads;

  /// Configuration object for tuning SQLite database performance and integrity behavior.
  ///
  /// This class encapsulates the standard `PRAGMA` settings required for high-performance,
  /// production-grade database interactions. It serves as the single source of truth
  /// when initializing new database connections or migration pipelines.
  ///
  /// [Image of the SQLite execution pipeline showing how configuration pragmas
  /// influence query processing, cache hits, and write-ahead logging synchronization]
  const SQLitePerformanceConfig({
    this.enableForeignKeys = true,
    this.journalMode = SQLiteJournalMode.wal,
    this.synchronous = SQLiteSynchronous.normal,
    this.cacheSize = SQLiteCacheSize.defaultSize,
    this.tempStoreInMemory = true,
    this.enableConcurrentReads = true,
  });

  /// **Bulk Import Configuration:**
  /// Optimized for massive data ingestion. Disables constraints and relaxes
  /// synchronization to maximize write throughput.
  factory SQLitePerformanceConfig.bulkImport() =>
      const SQLitePerformanceConfig(enableForeignKeys: false, journalMode: SQLiteJournalMode.wal, synchronous: SQLiteSynchronous.off, tempStoreInMemory: true, enableConcurrentReads: false);

  /// **High-Integrity Configuration:**
  /// Prioritizes data safety over raw speed. Suitable for financial records
  /// or critical local state that must survive app crashes.
  factory SQLitePerformanceConfig.highIntegrity() =>
      const SQLitePerformanceConfig(enableForeignKeys: true, journalMode: SQLiteJournalMode.delete, synchronous: SQLiteSynchronous.full, tempStoreInMemory: false, enableConcurrentReads: false);

  /// **Read-Heavy Configuration:**
  /// Optimized for analytical apps or caches where complex SELECT queries
  /// are more frequent than write operations.
  factory SQLitePerformanceConfig.readOnlyOptimized() => SQLitePerformanceConfig(
    enableForeignKeys: true,
    journalMode: SQLiteJournalMode.memory,
    synchronous: SQLiteSynchronous.normal,
    cacheSize: SQLiteCacheSize.megaBytes(20),
    tempStoreInMemory: true,
    enableConcurrentReads: true,
  );

  /// Determines the optimal execution strategy based on the current SQLite configuration.
  ///
  /// **Logic:**
  /// 1. **WAL-Enabled:** If the database is using Write-Ahead Logging, it checks if
  ///    [enableConcurrentReads] is permitted.
  ///    - Returns `concurrentWAL` if reads are allowed to overlap with writes.
  ///    - Returns `sequentialWAL` if reads/writes must be serialized despite WAL.
  /// 2. **Strict Mode:** For legacy journal modes (DELETE, TRUNCATE, etc.) or
  ///    non-WAL configurations, it defaults to `strictSequential` to ensure
  ///    database file integrity and prevent locking errors.
  FluentDbExecutionStrategy get executionStrategy {
    if (journalMode == SQLiteJournalMode.wal) {
      return enableConcurrentReads ? FluentDbExecutionStrategy.concurrentWAL : FluentDbExecutionStrategy.sequentialWAL;
    }
    // Legacy/Non-WAL modes require strict serialized access to prevent
    // SQLite "Database is locked" errors during simultaneous operations.
    return FluentDbExecutionStrategy.strictSequential;
  }

  @override
  String toString() {
    return 'SQLitePerformanceConfig{enableForeignKeys: $enableForeignKeys, journalMode: $journalMode, synchronous: $synchronous, cacheSize: $cacheSize, tempStoreInMemory: $tempStoreInMemory, enableConcurrentReads: $enableConcurrentReads}';
  }
}
