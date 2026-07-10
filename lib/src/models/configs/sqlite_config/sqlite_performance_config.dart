// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import '../../../utils/utils.dart';
import '../../models.dart';

/// Configuration object for tuning SQLite database performance and integrity behavior.
///
/// This class acts as the central orchestrator for SQLite PRAGMA settings.
/// It determines the [FluentDbExecutionStrategy] used by the engine,
/// balancing between ACID compliance and write/read throughput.
///
/// ### Usage Examples:
///
/// **Standard production setup:**
/// ```dart
/// final SQLitePerformanceConfig config = SQLitePerformanceConfig(
///   journalMode: SQLiteJournalMode.wal,
///   cacheSize: SQLiteCacheSize.megaBytes(10),
///   enableForeignKeys: true,
/// );
/// ```
///
/// **High-Performance (Bulk Imports):**
/// ```dart
/// final SQLitePerformanceConfig bulkConfig = SQLitePerformanceConfig.bulkImport();
/// // Optimized for massive data synchronization by disabling FKs and using WAL.
/// ```
///
/// **High-Integrity (Financial/Critical Data):**
/// ```dart
/// final SQLitePerformanceConfig safeConfig = SQLitePerformanceConfig.highIntegrity();
/// // Uses DELETE mode and FULL synchronous writes to guarantee persistence.
/// ```
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
  final bool? enableConcurrentReads;

  /// Defines how the [FluentEngine] prioritizes and merges tasks in the queue.
  final FluentQueueStrategy queueStrategy;

  /// Maximum number of simultaneous read operations allowed in WAL mode.
  /// This value is clamped between 1 and 8 to prevent SQLite connection
  /// overhead and excessive I/O contention.
  final int _maxConcurrentReads;

  /// Multiplier applied to task weight based on its age in the queue.
  /// Values are clamped between 10 (10%) and 100 (100%).
  /// This helps gradually elevate the priority of stagnant tasks,
  /// preventing "starvation" of lower-priority operations.
  final int _queueAgingPercentage;

  /// Constant value subtracted from the age-based priority boost.
  /// Clamped between 0 and 500. This is used to tune the "aggressiveness"
  /// of the task aging mechanism, preventing premature promotion.
  final int _queueAgingSubtract;

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
    this.queueStrategy = FluentQueueStrategy.smartBatching,
    this.enableConcurrentReads,
    int maxConcurrentReads = 5,
    int queueAgingPercentage = 90,
    int queueAgingSubtract = 10,
  }) : _maxConcurrentReads = maxConcurrentReads,
       _queueAgingPercentage = queueAgingPercentage,
       _queueAgingSubtract = queueAgingSubtract;

  /// Maximum number of simultaneous read operations allowed in WAL mode.
  /// Clamped between 1 and 8 to prevent SQLite connection overhead.
  int get maxConcurrentReads => _maxConcurrentReads.clamp(1, 8);

  /// Multiplier applied to task weight based on its age in the queue.
  /// Used to gradually elevate the priority of stagnant tasks.
  double get queueAgingMultiplier => _queueAgingPercentage.clamp(10, 100) / 100.0;

  /// Constant value subtracted from the age-based priority boost.
  /// Helps tune the "aggressiveness" of task aging.
  int get queueAgingSubtract => _queueAgingSubtract.clamp(0, 500);

  /// **Bulk Import Configuration:**
  /// Optimized for massive data ingestion. Disables constraints and relaxes
  /// synchronization to maximize write throughput.
  factory SQLitePerformanceConfig.bulkImport() =>
      SQLitePerformanceConfig(journalMode: SQLiteJournalMode.wal, synchronous: SQLiteSynchronous.off, enableForeignKeys: false, cacheSize: SQLiteCacheSize.megaBytes(50));

  /// **High-Integrity Configuration:**
  /// Prioritizes data safety over raw speed. Suitable for financial records
  /// or critical local state that must survive app crashes.
  factory SQLitePerformanceConfig.highIntegrity() =>
      SQLitePerformanceConfig(journalMode: SQLiteJournalMode.delete, synchronous: SQLiteSynchronous.full, enableForeignKeys: true, cacheSize: SQLiteCacheSize.megaBytes(10), tempStoreInMemory: false);

  /// **Read-Heavy Configuration:**
  /// Optimized for analytical apps or caches where complex SELECT queries
  /// are more frequent than write operations.
  factory SQLitePerformanceConfig.readOnlyOptimized() => SQLitePerformanceConfig(
    journalMode: SQLiteJournalMode.wal,
    synchronous: SQLiteSynchronous.normal,
    enableForeignKeys: true,
    enableConcurrentReads: true,
    tempStoreInMemory: true,
    cacheSize: SQLiteCacheSize.megaBytes(40),
  );

  /// Determines if the current journal mode supports concurrent read/write operations.
  ///
  /// Only [SQLiteJournalMode.wal] (Write-Ahead Logging) enables true concurrency
  /// in SQLite by allowing readers to operate without being blocked by a writer.
  bool get _isConcurrencyAllowed => journalMode == SQLiteJournalMode.wal;

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
      return enableConcurrentReads ?? _isConcurrencyAllowed ? FluentDbExecutionStrategy.concurrentWAL : FluentDbExecutionStrategy.sequentialWAL;
    }
    // Legacy/Non-WAL modes require strict serialized access to prevent
    // SQLite "Database is locked" errors during simultaneous operations.
    return FluentDbExecutionStrategy.strictSequential;
  }

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('SQLitePerformanceConfig{');
    final List<String> parts = [];

    parts.add('journal: ${journalMode.name}');
    parts.add('sync: ${synchronous.name}');
    parts.add('cache: $cacheSize');
    parts.add('strategy: ${queueStrategy.name}');

    if (enableForeignKeys) parts.add('fk: true');
    if (tempStoreInMemory) parts.add('tempStore: mem');
    if (enableConcurrentReads == true) parts.add('concurrentReads: true');

    parts.add('tuning: [maxReads: $_maxConcurrentReads, aging: $_queueAgingPercentage%, sub: $_queueAgingSubtract]');

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}
