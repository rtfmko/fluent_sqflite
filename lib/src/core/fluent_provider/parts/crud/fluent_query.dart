// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe analytical and existence query operations
/// for [FluentStorable] entities.
///
/// The [FluentQuery] extension serves as a high-performance facade over [FluentProvider], enabling
/// developers to execute complex data-set diagnostics, existence validation, and cardinality
/// assessments without the overhead of full record materialization.
///
/// ### Core Query Architecture & Execution Paradigms
/// Operations exposed by this extension are engineered for minimal memory footprint and maximum
/// efficiency, utilizing specialized database-level primitive optimizations:
///
/// * **Optimized Cardinality Assessment:** Methods like [count] leverage native database aggregation
///   functions, bypassing the retrieval of actual record data. This ensures that even for tables
///   containing millions of entries, the operation remains performant (O(1) or O(log N) depending
///   on index availability).
/// * **Existence Validation Pipelines:** The [exists] method implements a short-circuit lookup
///   strategy. By querying for the presence of a primary key or unique identifier, the driver engine
///   returns a boolean result immediately upon the first match, preventing unnecessary I/O.
/// * **Transactional Consistency:** All diagnostic queries are routed through the orchestration
///   layer, ensuring they reflect the latest database state, even when executed concurrently
///   with high-volume mutation tasks.
///
/// ### Execution Paradigm
/// Like other Fluent operations, these diagnostic queries are dispatched as [FluentTask] instances
/// to the [FluentDb] orchestrator. This allows the [FluentEngine] to intelligently prioritize
/// read-only diagnostics over heavy write mutations, ensuring smooth UI performance.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [FluentEngine], the underlying task orchestration layer.
/// * [ExecutionPolicy], which defines concurrency and priority controls for analytical tasks.
extension FluentQuery<T extends FluentStorable> on FluentProvider<T> {
  /// Validates whether a specific database record entry exists within [$tableName] matching the given unique [id].
  ///
  /// This lightweight validation utility handles input verification and schedules row lookups sequentially:
  /// * Evaluates input boundaries early, immediately returning an accelerated [Future.value] fast-path if null.
  /// * Packages unique identifier matching rules into a highly optimized [FluentTask] payload configuration.
  /// * Constraints matching parameters to an internal `LIMIT 1` check via [TableHelper] to prevent full table scans.
  ///
  /// [id] represents the unique identity primary key value targeted for table validation checks.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<bool>] yielding `true` if a matching row is located in storage, otherwise `false`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final recordExists = await sessionRepository.exists(
  ///   'sess_9921',
  ///   policy: const ExecutionPolicy(priority: TaskPriority.critical),
  /// );
  /// ```
  @internal
  Future<bool> exists(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (id == null) {
      return Future<bool>.value(false);
    }

    FluentLog.debug(
      'Initiating localized query pipeline for storage layer primary record existence validation',
      tag: '$tableName:exists',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.exists,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(id: id, limit: 1, multiple: false, where: _injectSoftDelete(null)),
      policy: policy,
    );

    return FluentDb.executeTask<T, bool>(provider: this, task: task);
  }

  /// Computes the total number of physical row record entries stored within [$tableName].
  ///
  /// This aggregation utility handles selective row scans or whole-dataset calculations sequentially:
  /// * Evaluates active filter flags to dynamically adjust structural task matching configurations.
  /// * Packages conditional strings and matching arguments into a standard [FluentTask] payload configuration.
  /// * Maps constraints via [TableHelper], setting up optimal compilation indices for target filters.
  ///
  /// [where] defines an optional conditional selection SQL filter clause used to constrain counting bounds.
  /// [whereArgs] contains the precise tracking parameters or variables bound to the conditional arguments.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<int>] yielding the total count of rows matching the evaluated criteria parameters.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Calculate active rows matching an identity constraint using a background isolation priority
  /// final activeItemsCount = await sessionRepository.count(
  ///   where: 'status = ? AND is_stale = ?',
  ///   whereArgs: ['active', 0],
  ///   policy: const ExecutionPolicy(priority: TaskPriority.normal),
  /// );
  /// ```
  @internal
  Future<int> count({String? where, List<Object?>? whereArgs, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for storage layer record aggregation counting',
      tag: '$tableName:count',
      context: {'tableName': tableName, 'hasConditionalWhereFilter': where != null, 'queryArgumentsCount': whereArgs?.length ?? 0, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.count,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: _injectSoftDelete(where), whereArgs: whereArgs, multiple: where == null),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
