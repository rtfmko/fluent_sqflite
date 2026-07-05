// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing robust maintenance, storage reclamation, and
/// lifecycle management for [FluentStorable] entities.
///
/// The [FluentMaintenance] extension manages the health, integrity, and storage footprint
/// of the database persistence layer. It encapsulates high-level administrative primitives
/// designed to maintain schema efficiency, reclaim orphaned storage space, and ensure
/// consistent performance over the application lifecycle.
///
/// ### Core Maintenance Paradigms
/// Operations exposed by this extension follow a specialized, high-priority execution
/// pipeline focused on storage health and automated cleanup:
///
/// * **Storage Reclamation Protocols:** Methods are designed for batch-oriented storage
///   reclamation, safely truncating or sanitizing datasets while respecting transactional
///   integrity and foreign key constraints.
/// * **Deterministic Lifecycle Management:** Maintenance tasks are treated as critical
///   background processes. By decoupling these operations from primary business
///   transactions, the extension ensures that maintenance routines—such as purging expired
///   logs or clearing caches—do not induce UI jank or database contention.
/// * **Integrity Safeguards:** Every maintenance operation is routed through the central
///   coordination layer, ensuring that table locks, schema versioning, and policy-based
///   execution constraints are strictly enforced.
///
/// See also:
/// * [FluentProvider], the primary storage driver contract.
/// * [ExecutionPolicy], which allows throttling maintenance tasks to prioritize
///   user-facing operations.
/// * [FluentEngine], which orchestrates the background execution of these administrative tasks.
extension FluentMaintenance<T extends FluentStorable> on FluentProvider<T> {
  /// Sweeps through [$tableName] and permanently removes records whose timestamps have exceeded expiration limits.
  ///
  /// This automated maintenance utility evaluates execution layers sequentially to process stale records:
  /// * Evaluates active [batch] contexts to immediately chain raw delete statements without checking counts.
  /// * Checks explicit or transaction-bound [executor] states to process selections inside local locked loops.
  /// * Packages query variables into a standard [FluentTask] frame for structural scheduling across worker threads.
  ///
  /// [executor] provides an optional active transaction context to execute the extraction on an isolated runner.
  /// [batch] represents an optional atomic database batch context used to stack multiple database mutation commands.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the data layer sweeps are finalized.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Trigger a background automated cache maintenance sweep
  /// await sessionRepository.clearExpiredItems(
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.low, // Run as background task to ensure main interactions are prioritized
  ///   ),
  /// );
  /// ```
  @internal
  Future<int> clearExpiredItems({DatabaseExecutor? executor, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final String colName = modelSample.expiryColumn;
    final int now = DateTime.now().millisecondsSinceEpoch;

    final String whereClause = '$colName IS NOT NULL AND $colName <= ?';
    final List<Object?> whereArgs = <Object?>[now];

    // SCENARIO A: SHARED BATCH CONTEXT — Stage the deletion query into the provided atomic batch array
    if (batch != null) {
      FluentLog.debug(
        'Staging expired records removal query into external batch sequence',
        tag: '$tableName:clearExpiredItems',
        context: {'tableName': tableName, 'expiryColumnField': colName, 'referenceTimestamp': now},
      );
      batch.delete(tableName, where: whereClause, whereArgs: whereArgs);
      return Future<int>.value(1);
    }

    // SCENARIO B: EXPLICIT OR CACHED TRANSACTION — Execute directly on the assigned connection runner
    final DatabaseExecutor? activeTxn = executor ?? _transactionExecutor;
    if (activeTxn != null) {
      return _rawClearExpiredExecution(whereClause, whereArgs, activeTxn);
    }

    // SCENARIO C: STANDARD TASK SCHEDULER — Package cleanup criteria into a uniform framework task.
    // Dispatch a structured informational log via the centralized global facade pattern.
    FluentLog.debug(
      'Initiating global operational query pipeline for database cache expiration auto-cleanup sweeps',
      tag: '$tableName:clearExpiredItems',
      context: {'tableName': tableName, 'expiryColumnField': colName, 'referenceTimestamp': now, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.clearExpired,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: whereClause, whereArgs: whereArgs, multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Completely truncates and evacuates all rows permanently from the [$tableName] storage engine.
  ///
  /// This heavy operational maintenance pipeline evaluates runtime driver contexts sequentially:
  /// * Intercepts ongoing [_transactionExecutor] connections to process table clears inside local transaction locks.
  /// * Packages global truncation rules into a uniform [FluentTask] for thread allocation and supervisor queuing.
  /// * Triggers cascade constraint audits downstream if relational mixing structures are active.
  ///
  /// [policy] defines prioritization, query collapsing, and concurrency thresholds managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the physical storage table is completely empty.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Wipe log cache table completely under a background operational priority
  /// await analyticsRepository.clearTable(
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.low,
  ///     flushImmediate: true,
  ///   ),
  /// );
  /// ```
  @internal
  Future<int> clearTable({ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for full storage table evacuation purges',
      tag: '$tableName:clearTable',
      context: {'tableName': tableName, 'hasActiveTransaction': _transactionExecutor != null, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    // SCENARIO A: TRANSACTION ENVELOPE — Execute directly on the local locked transaction connection pool
    if (_transactionExecutor != null) {
      return _rawClearTableExecution(_transactionExecutor!);
    }

    // SCENARIO B: STANDARD TASK PIPELINE — Encapsulate table truncation parameters into a uniform framework task.
    // TableHelper configures multiple: true to signal a comprehensive dataset evacuation.
    final FluentTask task = FluentTask(action: FluentDbAction.clearTable, table: tableName, dbName: dbName ?? this.dbName, helper: TableHelper(multiple: true), policy: policy, force: true);

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
