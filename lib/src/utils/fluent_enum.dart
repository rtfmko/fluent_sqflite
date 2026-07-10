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

/// Defines how the internal queue sorts and groups incoming database tasks.
enum FluentQueueStrategy {
  /// Strict First-In, First-Out. Tasks are executed in the exact order they were requested.
  /// Ignores priority and execution weight. Best for financial data or strict logs.
  fifo,

  /// Sorts tasks based on 'force' flags, developer-defined priorities, and dynamic weight
  /// (row count, memory payload). Best for UI responsiveness.
  smartPriority,

  /// The ultimate optimization. Uses smart sorting AND actively looks ahead in the queue
  /// to merge identical adjacent operations (e.g., multiple single INSERTS into one BATCH).
  smartBatching,
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

/// Defines how the database should handle incoming data during save operations.
///
/// This strategy dictates the SQL conflict resolution and update logic,
/// ensuring data integrity during synchronization from APIs or local mutations.
enum FluentSaveStrategy {
  /// **"Insert only"**
  /// Adds new records. If a record already exists, it is ignored
  /// (the database keeps the existing version).
  insertOnly,

  /// **"Replace everything" (Default)**
  /// The "nuclear" option: if the record exists, it is completely overwritten
  /// by the new data. If not, it is created.
  upsert,

  /// **"Update fields only"**
  /// Updates only the specific fields provided. Does not touch other
  /// existing data in the row. Requires the record to already exist.
  patch,

  /// **"Strict update"**
  /// Updates existing records only. If the record does not exist in the
  /// database, nothing happens (no creation).
  updateOnly,
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

  /// Performs a transactional batch update of multiple entities along with their relational graphs.
  updateAllWithRelations,

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

  /// Removes records based on a condition, applying soft-delete if supported by the model.
  deleteWhere,

  /// Permanently removes records from the database, bypassing soft-delete mechanisms.
  hardDeleteWhere,

  /// Mass-deletion of multiple records by their primary keys.
  deleteItemsByIds,

  /// Clears records that have passed their expiration date (TTL cleanup).
  clearExpired,

  /// Completely truncates the table (removes all records).
  clearTable,

  /// Performs an atomic wipe of all user-defined tables in the database.
  clearDatabase,

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

  /// Analyze table count
  analyzeTable,

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

/// Defines the behavior for updating relational associations during a parent entity's save operation.
enum FluentRelationUpdateMode {
  /// Skip update if the field is `null`. If empty `[]`, clear existing database relations. (Default for most cases)
  skipOnNull,

  /// Skip update if the field is empty `[]`. If `null`, clear existing database relations.
  skipOnEmpty,

  /// Skip update if the field is `null` OR empty `[]`. Only process if valid data exists.
  skipOnNullOrEmpty,

  /// Always enforce the state. `null` or empty `[]` will aggressively wipe existing database relations.
  forceOverwrite,

  /// Never update this relation automatically through the parent's lifecycle.
  readOnly,
}

/// Represents the distinct lifecycle phases of a [reactiveSync] data pipeline.
///
/// This state machine tracks the progression of an asynchronous synchronization
/// process, allowing UI layers to reactively update (e.g., showing loading
/// indicators, progress bars, or error states) based on the current phase.
enum FluentPipelinePhase {
  /// The pipeline is currently inactive or awaiting a trigger.
  idle,

  /// Initializing data retrieval from the local SQLite storage.
  loadingCache,

  /// Local cached data has been successfully hydrated and is ready for use.
  cacheReady,

  /// Initiating a network request to the remote API.
  loadingApi,

  /// Remote data has been successfully fetched and is ready for reconciliation.
  apiReady,

  /// Data is being committed to the database (merging, upserting, or deleting).
  savingToDb,

  /// The entire synchronization process finished successfully.
  completed,

  /// An unrecoverable error occurred during one of the pipeline stages.
  error,
}

/// Defines how incoming API data is reconciled with the local database state.
enum FluentMergeStrategy {
  /// **Smart Update**
  /// New records are inserted, and existing records (matched by Primary Key)
  /// are updated. Local records missing from the API response are left untouched.
  ///
  /// *Use case:* Standard synchronization where the server sends partial updates.
  upsert,

  /// **Complete Wipe & Replace**
  /// Clears all existing records (constrained by [localWhere]) before inserting
  /// the fresh dataset from the API.
  ///
  /// *Use case:* When the server provides the absolute definitive state and
  /// local-only records must not persist. Faster than [syncDeletions] for large datasets.
  replace,

  /// **Exact Mirror (Upsert + Purge)**
  /// Performs an upsert, and then actively deletes any local records (matching
  /// [localWhere]) that were NOT present in the incoming API response.
  ///
  /// *Use case:* Syncing lists where items might have been deleted on another
  /// device, ensuring the local DB is an exact mirror of the server's list.
  syncDeletions,

  /// **Read-Only (Bypass DB)**
  /// The incoming API data is streamed directly to the UI without touching
  /// the local database at all.
  ///
  /// *Use case:* Search results, temporary filtering, or one-off data fetching
  /// where caching is unnecessary or undesirable.
  none,
}

/// Defines the synchronization orchestration flow between local cache and
/// remote API data sources.
///
/// Strategies dictate the sequence of data delivery to the UI layer and the
/// timing of persistence operations, allowing developers to optimize for
/// perceived performance versus strict data consistency.
enum FluentExecutionStrategy {
  /// **Offline-First (High Consistency)**
  /// The pipeline delivers cached data first, fetches the API response,
  /// commits it to the database, and ONLY THEN emits the fresh dataset to the UI.
  ///
  /// *Use case:* When you want to prevent the UI from showing data that hasn't
  /// been successfully saved to the local disk yet (avoids "flickering" state).
  cacheThenApiThenSave,

  /// **Offline-First (High Performance - Default)**
  /// Delivers cached data immediately, then emits the fresh API response to the
  /// UI *as soon as it arrives*. Persistence to the database happens in the
  /// background.
  ///
  /// *Use case:* Standard screens where you want the UI to update instantly
  /// without waiting for slow disk I/O (database writes).
  cacheThenApiYieldThenSave,

  /// **Network-Only**
  /// Bypasses local storage reading entirely. Forces a fresh network request,
  /// saves it (depending on MergeStrategy), and delivers the data.
  ///
  /// *Use case:* Financial transactions, live charts, or data where stale
  /// cached information is strictly unacceptable.
  apiOnly,

  /// **Local-Only**
  /// Reads data exclusively from the local SQLite cache and terminates the pipeline.
  /// No network requests are made.
  ///
  /// *Use case:* Airplane mode, heavy static dictionaries that are updated via
  /// separate background jobs, or user-forced "offline mode".
  cacheOnly,
}

/// Defines how the synchronization pipeline handles cases where the API
/// returns an empty collection for a given request.
///
/// This behavior is critical when the server-side state is considered the
/// primary source of truth, as it allows the local database to automatically
/// prune stale data when it no longer exists on the backend.
enum FluentEmptyApiBehavior {
  /// Preserves the existing local cache when the API response is empty.
  ///
  /// Use this strategy when the local database should retain previously
  /// fetched data even if the server returns no results (e.g., due to
  /// filtering, temporary connectivity issues, or paginated endpoints
  /// that only return partial data).
  preserveCache,

  /// Clears the local storage when the API response is empty.
  ///
  /// Use this strategy when an empty API response signifies that the
  /// corresponding dataset has been removed from the server. This ensures
  /// the local database stays perfectly synchronized with the server's state
  /// by automatically purging obsolete records.
  clearCache,
}

/// Defines the reconciliation strategy for nested relational associations during
/// synchronization.
///
/// This strategy dictates how the engine should handle differences between
/// the existing local relational graph and incoming entity payloads.
enum FluentRelationSyncMode {
  /// Preserves existing local associations when the incoming payload provides
  /// incomplete or partial relational data.
  ///
  /// Use this strategy when the local database should retain previously
  /// associated records even if they are missing from the current update.
  /// This is ideal for partial state updates or additive synchronization.
  preserveLocal,

  /// Performs a full reconciliation of the relational graph.
  ///
  /// The engine treats the incoming payload as the authoritative state for all
  /// child associations. Any existing local associations not present in the
  /// new dataset are identified as stale and removed (or unlinked) to ensure
  /// strict alignment with the provided entity structure.
  replace,
}

/// Defines the behavior of the synchronization pipeline when a request
/// encounters a terminal failure or exceeds its retry quota.
///
/// This strategy allows for fine-grained control over local data persistence
/// versus state invalidation during network or server-side errors, enabling
/// robust error recovery patterns.
enum FluentApiErrorBehavior {
  /// Terminates the pipeline and emits an [FluentPipelinePhase.error] event.
  ///
  /// The local cache remains untouched. Use this strategy for transient server
  /// errors (e.g., 500-level codes) where the data may be available again
  /// during subsequent attempts.
  yieldError,

  /// Invalidates the local cache before emitting an [FluentPipelinePhase.error] event.
  ///
  /// This strategy clears records matching [localWhere] (or the entire table).
  /// Use this for critical auth/access errors (e.g., 401 Unauthorized,
  /// 403 Forbidden, 404 Not Found) where the current local dataset is
  /// considered compromised or no longer authorized.
  clearCacheAndYieldError,

  /// Suppresses the error and concludes the pipeline with [FluentPipelinePhase.completed].
  ///
  /// The local cache is preserved, and the UI receives the successful state,
  /// allowing users to continue working with cached data. Any error details
  /// are still propagated via the [FluentDataEvent.error] field for telemetry
  /// and user-facing notifications.
  preserveCacheAndComplete,
}

/// Represents the provenance (origin) of the data payload within a [FluentDataEvent].
///
/// This metadata is critical for downstream UI consumers to distinguish between
/// "offline-ready" cached data and "fresh" network-synchronized data. It allows
/// developers to implement features like "offline mode" indicators, stale data
/// warnings, or perform granular data reconciliation without needing complex
/// external state management.
enum FluentDataSource {
  /// Represents an uninitialized or transient state where no data payload is available.
  ///
  /// Use this for pipeline event phases that act as control signals (e.g., initial
  /// loading status, stream subscriptions, or empty-state transitions) where
  /// no actual model data is attached.
  none,

  /// Signifies that the data was retrieved from the local SQLite database.
  ///
  /// Data from this source is immediately available for UI rendering, providing
  /// low-latency performance. However, depending on the sync strategy, this
  /// data may be temporally stale relative to the server-side state.
  cache,

  /// Indicates that the data was successfully fetched from the remote backend.
  ///
  /// This represents the "Source of Truth" for the current entity state.
  /// UI components receiving this source can typically assume the data is
  /// up-to-date and reflects the most recent network transaction.
  api,
}
