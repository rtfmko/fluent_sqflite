// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:typed_data';

/// Supported SQLite data types and their mapping from Dart types.
///
/// This enum defines how Dart objects are translated into SQLite storage classes.
enum FluentDbDataType {
  /// Maps to SQLite `TEXT`. Used for [String] and as a default fallback.
  text('TEXT'),

  /// Maps to SQLite `INTEGER`. Used for [int] and [bool] (0 or 1).
  /// and [DateTime] (stored as timestamp).
  integer('INTEGER'),

  /// Maps to SQLite `REAL`. Used for [double] and [num].
  real('REAL'),

  /// Maps to SQLite `BLOB`. Used for binary data like images or files.
  blob('BLOB'),

  /// A special type that bypasses standard mapping.
  ///
  /// Use this when you need to define a column with specific constraints
  /// like `AUTOINCREMENT` or `UNIQUE`.
  /// When using [custom], the `sql` value should not be used directly in queries.
  custom('custom');

  /// The raw SQL keyword associated with this type.
  final String sql;

  const FluentDbDataType(this.sql);

  /// Automatically detects the appropriate [FluentDbDataType] for a given Dart [value].
  ///
  /// Mapping rules:
  /// * [int], [bool], or [DateTime] -> [integer].
  /// * [double] or [num] -> [real].
  /// * [Uint8List] (or any list of bytes) -> [blob].
  /// * Everything else -> [text] (default).
  ///
  /// Example:
  /// ```dart
  /// final FluentDbDataType type = FluentDbDataType.fromType(DateTime.now()); // FluentDbDataType.integer
  /// ```
  static FluentDbDataType fromType(dynamic value) {
    if (value is int || value is bool) return FluentDbDataType.integer;
    if (value is double || value is num) return FluentDbDataType.real;
    if (value is Uint8List) return FluentDbDataType.blob;
    return FluentDbDataType.text;
  }
}

/// Defines the severity levels for database logging.
enum FluentLogLevel {
  /// Detailed information used strictly for development and troubleshooting.
  ///
  /// Examples: SQL query strings, raw database responses, internal state changes.
  debug,

  /// General information about the standard operation of the database.
  ///
  /// Examples: Database initialization, successful migrations, connection status.
  info,

  /// Non-critical issues that do not stop the app but should be noted.
  ///
  /// Examples: Missing optional configurations, slow query warnings,
  /// or usage of deprecated methods.
  warning,

  /// Critical failures that prevent an operation from completing.
  ///
  /// Examples: SQL syntax errors, disk I/O failures, or constraint violations.
  error,

  /// Specific level for logging raw SQL execution statements.
  ///
  /// Useful for performance profiling and auditing query patterns.
  sql,
}

/// Represents the available SQLite journal modes for transaction logging.
///
/// The journal mode determines how the database handles transaction atomicity
/// and rollback journal persistence. Choosing the right mode is critical
/// for balancing performance and data safety.
enum SQLiteJournalMode {
  /// **DELETE (Default):** The rollback journal is deleted at the end of each
  /// transaction. Simplest, but involves file-system overhead for every commit.
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

  /// **WAL (Write-Ahead Logging):** Transactions are written into a separate
  /// `-wal` file. This allows simultaneous readers and a single writer,
  /// significantly improving concurrency in multi-threaded applications.
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

/// Defines the concurrency model and locking behavior utilized by the
/// database layer for task scheduling.
///
/// This enum guides the [FluentEngine] in determining how tasks
/// are queued, processed, and whether concurrent reads/writes are permitted.
enum FluentDbExecutionStrategy {
  /// **Concurrent WAL:** Enables full Write-Ahead Logging concurrency.
  /// Allows the database to handle multiple readers while simultaneously
  /// processing a single write operation. Maximum throughput for UI responsiveness.
  concurrentWAL,

  /// **Sequential WAL:** Uses Write-Ahead Logging but forces strict
  /// task-by-task execution. Used when the WAL mode is active but
  /// read/write contention needs to be explicitly avoided to ensure
  /// operation ordering.
  sequentialWAL,

  /// **Strict Sequential:** The most conservative mode. Implements a
  /// "Single-Writer-Single-Reader" model. Required for legacy journal modes
  /// (DELETE, TRUNCATE) to prevent file-system locks and `SQLITE_BUSY` errors.
  strictSequential,
}

/// Defines the cardinality and navigational behavior of a database relationship.
///
/// This enum allows the ORM/Provider to automatically infer JOIN strategies,
/// foreign key constraints, and collection handling during query execution.
enum FluentDbRelationType {
  /// The framework automatically detects the relationship type based on
  /// context and table schema.
  auto,

  /// Represents a 1:1 relationship where one record maps to exactly one
  /// related record.
  oneToOne,

  /// Represents a 1:N relationship where one record maps to multiple
  /// related records.
  oneToMany,

  /// Represents an N:1 relationship where multiple records map to one
  /// parent record.
  manyToOne,

  /// Represents an M:N relationship, typically requiring an intermediate
  /// pivot table.
  manyToMany,
}

/// Defines the expected output format for database query results.
///
/// This enum guides the [FluentProvider] on how to deserialize raw SQLite
/// `Map<String, dynamic>` rows into application-level objects.
enum FluentModelCast {
  /// Casts a single query result to a specific [FluentStorable] model.
  model,

  /// Casts multiple query results into a `List` of [FluentStorable] models.
  modelList,

  /// Returns the raw database row as a `Map<String, dynamic>`.
  map,

  /// Returns a `List` of raw database rows as `List<Map<String, dynamic>>`.
  mapList;

  /// Returns `true` if the result is expected to be a collection of items.
  bool get isList => this == FluentModelCast.modelList || this == FluentModelCast.mapList;

  /// Returns `true` if the result should be mapped to a [FluentStorable] class instance.
  bool get isModel => this == FluentModelCast.model || this == FluentModelCast.modelList;
}

/// Represents the supported persistence strategies for [DateTime] values.
///
/// Choosing the correct format is critical for cross-platform compatibility
/// and query efficiency within the SQLite database.
///
enum FluentDateTimeFormat {
  /// Stores dates as ISO 8601 formatted strings (e.g., "2026-05-25T05:15:10Z").
  ///
  /// Pros: Human-readable and provides better chronological sorting via standard string comparison.
  iso8601,

  /// Stores dates as numeric Unix timestamps (milliseconds or seconds).
  ///
  /// Pros: Highly efficient for numerical indexing and range-based queries (BETWEEN).
  timestamp,
}

/// Represents the set of all supported database operations within the engine.
///
/// This enum acts as the primary action-routing mechanism. The `FluentEngine`
/// uses these constants to map the requested [FluentTask] to the appropriate SQLite
/// implementation logic (e.g., executing a raw SQL string vs. performing a
/// column-specific update).
enum FluentDbAction {
  /// Default state; no operation performed.
  none,

  /// General retrieval based on [TableHelper] constraints.
  find,

  /// Fetches all records from the target table.
  findAll,

  /// Fetches only records matching a validity constraint (e.g., `is_deleted = 0`).
  findValidItems,

  /// Fetches records matching specific criteria (key-value pairs).
  findItemsBy,

  /// Retrieves a single record by its primary key identifier.
  findById,

  /// Performs a count of records matching specific criteria.
  count,

  /// Checks if a record exists based on [TableHelper] constraints.
  exists,

  /// Save operation: Handles both insertion and updates based on existence.
  save,

  /// Performs a full-record update (replaces existing record with the provided object).
  update,

  /// Updates a specific column value for a given record.
  updateSingleField,

  /// Updates multiple columns simultaneously for a record or set of records.
  updateMultipleFields,

  /// Updates a record and its nested relationships (cascading update).
  updateWithRelations,

  /// Updates all records in the table that match the provided field-value constraints
  /// with the new values defined in the map.
  updateAll,

  /// Performs a bulk update of multiple records identified by their primary keys
  /// in a single atomic transaction.
  updateMultipleFieldsByIds,

  /// Removes a single record.
  delete,

  /// Removes records matching specific criteria.
  deleteBy,

  /// Mass-deletion of multiple records by their primary keys.
  deleteItemsByIds,

  /// Clears records that have passed their expiration date (TTL cleanup).
  clearExpired,

  /// Completely truncates the table (removes all records).
  clearTable,

  /// Fetches a single raw item (no model mapping applied).
  rawGetItem,

  /// Fetches a list of raw items.
  rawGetItems,

  /// Executes a raw SQL query provided via [TableHelper.sql].
  execute,

  /// Retrieves or validates the current database table schema.
  readSchema,

  /// Analyze system stats
  analyzeStats,

  /// Save system stats
  saveStats,

  /// Restores a soft-deleted record, reverting the deletion flag.
  restore,

  /// Restores a batch of soft-deleted records by their primary keys,
  /// reverting the soft-delete flag to active status.
  restoreItemsByIds,

  /// Permanently removes a record from the database (bypass soft-delete).
  hardDelete,

  /// Permanently removes records matching a specific field/value constraint.
  hardDeleteBy,

  /// Mass-deletion of multiple records by their primary keys (bypass soft-delete).
  hardDeleteItemsByIds,

  /// Fetches all records currently marked as soft-deleted.
  findDeletedItems,

  /// Permanently purges all soft-deleted records that exceeded the retention period.
  purgeSoftDeleted,

  /// Permanently and forcefully removes all soft-deleted records from the table, bypassing retention policies.
  forcePurgeSoftDeleted,

  /// A system-level broadcast indicating that the entire database has been wiped.
  /// UI listeners should intercept this action to clear their local state (e.g., set lists to empty).
  wipeAll,
}

/// Represents the computational or relational complexity of a specific database table.
///
/// This enum is used by the [FluentEngine] and [TableStatsTracker] to
/// dynamically adjust [ExecutionPolicy] settings. For example, "extreme" tables
/// may trigger more aggressive caching, stricter transaction isolation, or
/// background-only execution policies to prevent UI jank.
enum TableComplexity {
  /// Simple tables (e.g., Key-Value stores, basic settings).
  /// High-frequency, low-latency access is expected.
  low,

  /// Standard relational tables with basic indexes and foreign keys.
  medium,

  /// Complex tables with multiple indexes, triggers, or large relationship
  /// chains (e.g., 'UserProfiles' with many dependencies).
  high,

  /// Highly complex, monolithic tables. Often involves cascading deletes,
  /// heavy join requirements, or massive historical datasets.
  /// Operations here require prioritized queueing and strict resource management.
  extreme,
}

/// Defines the specific control-plane commands used to communicate between
/// the main isolate and the background database worker isolate.
///
/// This enum acts as the "protocol" for the [IsolateRequest], ensuring
/// type-safe dispatching of operations to the background engine.
enum IsolateCmd {
  /// No action specified; used as a default or empty command state.
  none,

  /// Performs initial setup of the background isolate, such as opening SQLite
  /// connections, registering schemas, and initializing local caches.
  init,

  /// Triggers the execution of a [FluentTask], such as a query, mutation, or batch operation.
  execute,

  /// Signals the worker to halt a currently processing [FluentTask] identified by its ID.
  cancel,

  /// Signals the worker to perform an orderly shutdown, closing database
  /// handles and flushing buffers before the isolate is destroyed.
  terminate,
}

/// Represents the lifecycle states and communication signals reported by
/// the background worker isolate back to the main application.
///
/// This enum serves as the "handshake protocol" for [IsolateResponse],
/// allowing the [FluentEngine] to track worker health, progress
/// updates, and operational results in real-time.
enum IsolateStatus {
  /// Default state; indicates no specific status update is being reported.
  none,

  /// Confirms that a task was executed successfully with no errors.
  ok,

  /// Signals that the worker isolate has completed its initialization
  /// (e.g., SQLite connection established, schemas verified).
  warmupDone,

  /// Used for long-running tasks to report partial completion percentage
  /// or intermediate results to the UI thread.
  progress,

  /// Confirms that the diagnostic analysis command ([IsolateCmd.analyzeStats])
  /// has been successfully completed.
  analyzeDone,

  /// Confirms that performance metrics ([IsolateCmd.saveStats]) have been
  /// persisted successfully to disk.
  saveDone,

  /// Indicates that the worker encountered a failure during execution;
  /// requires inspection of the `errorCode` field.
  error,

  /// Confirms that the worker isolate has successfully processed the
  /// [IsolateCmd.terminate] command and released system resources.
  terminated,
}

/// Defines the directional order for sorting database query results.
enum SortDirection {
  /// Sorts results in ascending order (smallest to largest).
  asc,

  /// Sorts results in descending order (largest to smallest).
  desc,
}

/// Defines the synchronization behaviors for reconciling local data with a remote server.
///
/// Use these strategies within [FluentDb.syncWithServer] to orchestrate automated
/// data exchange and lifecycle management between your local SQLite database
/// and your backend API.
enum FluentSyncStrategy {
  /// **Purge Strategy:** Identifies soft-deleted records, pushes them to the server
  /// for archival or remote deletion, and performs a permanent batch hard-delete
  /// from the local database upon successful confirmation.
  purgeDeleted,

  /// **Push Strategy:** Identifies active (non-deleted) records that require
  /// synchronization, pushes their state to the server, and optionally updates
  /// local metadata (e.g., `is_synced` or `updated_at` flags) to avoid redundant uploads.
  pushActive,

  /// **Pull Strategy:** Fetches data payloads from the server and performs
  /// a batch upsert (update-or-insert) into the local database, ensuring
  /// that the local state reflects the authoritative source of truth.
  pullAndSave,
}
