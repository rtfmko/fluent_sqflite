// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing low-level execution primitives for
/// optimized data aggregation and existence verification.
///
/// The [FluentExecuteQuery] extension serves as the high-speed query executor
/// for operations that do not require full entity hydration (e.g., existence
/// checks or count aggregations). By bypassing the overhead of object
/// instantiation and mapping, this layer ensures maximum performance for
/// metadata-centric database operations.
///
/// ### Core Architecture & Query Paradigms
/// This extension is engineered for minimal I/O impact and strict type-safety
/// during SQL execution:
///
/// * **Optimized Index Probing:** For [exists] operations, the engine fires a
///   lightweight `SELECT 1 ... LIMIT 1` statement. This avoids structural column
///   fetching and mass data array allocation, providing near-instantaneous
///   verification of entity presence.
/// * **Deterministic Aggregation:** For [count] and aggregation tasks, the layer
///   uses precise raw SQL query orchestration. It ensures that runtime arguments
///   are correctly sanitized and transformed into SQLite-compatible types,
///   protecting the system from malformed query errors.
/// * **Diagnostic Instrumentation:** Every execution sequence is logged with
///   contextual detail, including the specific `WHERE` clause syntax and
///   argument count. This diagnostic transparency is critical for auditing
///   complex filtering logic and identifying performance bottlenecks in the
///   query layer.
/// * **Fault-Tolerant Execution:** The pipeline includes robust error boundaries
///   to capture driver failures, providing structured feedback regarding
///   syntax errors or schema mismatches in the query arguments.
///
/// ### Execution Flow
/// Operations are dispatched as structured [FluentTask] units. This ensures that
/// existence probes and aggregations run within the same transactional context
/// as other database operations, maintaining consistent snapshots of the
/// table state.
///
/// See also:
/// * [FluentProvider], the central registry and orchestrator for data access.
/// * [FluentTask], the operational unit definition for query constraints.
/// * [FluentDb], for transactional isolation guarantees during heavy aggregation.
extension FluentExecuteQuery<T extends FluentStorable> on FluentProvider<T> {
  /// Direct data layer coordinator that runs highly optimized record existence lookups on the Main thread.
  ///
  /// This pipeline unpacks target identifier keys to execute low-level index probes safely:
  /// * Evaluates data existence constraints to guard against uninitialized or missing helper parameters.
  /// * Fires an optimized, lightweight raw SQL statement (`SELECT 1 ... LIMIT 1`) directly against the active executor connection.
  /// * Prevents unnecessary data hydration overhead by fetching constant markers rather than structural columns or mass row arrays.
  /// * Transforms collection state metrics directly into deterministic operational booleans.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.warning].
  Future<bool> _executeExistsTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    if (id == null) {
      FluentLog.warning(
        'Database primary record existence check aborted on Main due to unassigned target identifier',
        tag: '$tableName:existsExecutor',
        hint: 'Verify that the task wrapper passes a valid non-null primary identity key inside the helper context.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return false;
    }

    FluentLog.debug(
      'Executing Main-thread transactional database record existence validation sequence',
      tag: '$tableName:existsExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
    );

    try {
      final String rawSql = 'SELECT 1 FROM $tableName WHERE ${primaryKeyColumn.name} = ? LIMIT 1';

      FluentLog.sql(rawSql, arguments: <dynamic>[id], tag: '$tableName:sql:existsExecutor');

      final List<Map<String, dynamic>> res = await executor.rawQuery(rawSql, <dynamic>[id]);

      final bool isExists = res.isNotEmpty;

      FluentLog.debug(
        'Database operational existence lookup finalized successfully',
        tag: '$tableName:existsExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'isMatchingRecordLocated': isExists},
      );

      return isExists;
    } catch (e, st) {
      FluentLog.error(
        'Database existence lookup failed due to driver execution error',
        e,
        st,
        tag: '$tableName:exception:existsExecutor',
        hint: 'The database driver encountered a critical error during the existence lookup. Check if the table schema has been altered or if the connection to the executor is still active.',
        context: {'tableName': tableName, 'taskId': task.id, 'targetId': id.toString()},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs highly optimized record aggregation counts on the Main thread.
  ///
  /// This pipeline unpacks selection parameters to execute low-level row counting operations safely:
  /// * Evaluates active filter flags to dynamically construct target parameterized SQL statements.
  /// * Strongly enforces strict generic casting on arguments via [List.from] to ensure compatibility with underlying bindings.
  /// * Fires a low-level optimized `COUNT(*)` query directly against the active executor engine runner.
  ///
  /// [task] represents the specific framework operational unit containing query boundaries, filters, and tracking keys.
  ///
  /// Returns a [Future<int>] yielding the total integer row accumulation result extracted from the storage engine.
  Future<int> _executeCountTaskOnMain(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<dynamic>? whereArgs = task.helper?.whereArgs;

    FluentLog.debug(
      'Executing Main-thread transactional database record aggregation counting sequence',
      tag: '$tableName:countExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'conditionalWhereClause': where ?? 'NONE (FULL TABLE COUNT)', 'queryArgumentsCount': whereArgs?.length ?? 0},
    );

    try {
      // Cast generic runtime dynamic variables to the strict nullable object types required by sqflite
      final List<Object?>? castedArgs = whereArgs != null ? List<Object?>.from(whereArgs) : null;

      final List<Map<String, dynamic>> result = await executor.rawQuery('SELECT COUNT(*) as total FROM $tableName ${where != null ? 'WHERE $where' : ''}', castedArgs);

      final int totalCount = Sqflite.firstIntValue(result) ?? 0;

      FluentLog.debug(
        'Database operational aggregation counting finalized successfully',
        tag: '$tableName:countExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'aggregatedRowsResult': totalCount},
      );

      return totalCount;
    } catch (e, st) {
      FluentLog.error(
        'Database aggregation counting aborted due to execution driver failure',
        e,
        st,
        tag: '$tableName:exception:countExecutor',
        hint: 'Verify the integrity of your WHERE clause syntax and the compatibility of the provided filter arguments with the table schema.',
        context: {'tableName': tableName, 'taskId': task.id, 'whereClause': where},
      );
      rethrow;
    }
  }
}
