// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing low-level execution primitives for
/// raw SQL command orchestration and un-materialized data retrieval.
///
/// The [FluentExecuteRaw] extension serves as the "escape hatch" of the storage
/// layer. It allows for the execution of arbitrary SQL statements that bypass the
/// standard entity hydration and relation-mapping pipelines. This is ideal for
/// highly optimized database operations, complex analytical queries, or schema
/// maintenance tasks where ORM overhead is either unnecessary or contraindicated.
///
/// ### Core Architecture & Execution Paradigms
/// This extension is designed for developers who require fine-grained control
/// over database interactions while maintaining the safety standards of the
/// Fluent architecture:
///
/// * **Direct Engine Passthrough:** By bypassing model materialization and
///   relational sub-workers, [FluentExecuteRaw] minimizes CPU and memory
///   allocation, delivering results directly as decoupled data snapshots.
/// * **SQL Diagnostic Facade:** Every raw execution is instrumented through the
///   centralized [FluentLog] system. This includes detailed logging of SQL strings
///   and bound arguments, enabling full visibility into database-level operations
///   without sacrificing the ability to audit query behavior.
/// * **Execution Safety:** Despite being "raw," these operations are dispatched
///   as structured [FluentTask] units, ensuring they respect established
///   [ExecutionPolicy] constraints and maintain the transactional integrity
///   required by the broader data-layer infrastructure.
/// * **Fail-Fast Error Handling:** The pipeline includes robust boundaries for
///   capturing execution failures. Structured error context provides immediate
///   feedback on syntax errors, binding mismatches, or schema-level constraint
///   violations, significantly reducing debugging cycles.
///
/// ### Execution Flow
/// Operations are routed through the active database executor, capturing impact
/// metrics (affected row counts) for synchronization with internal stats trackers.
/// This ensures that even raw operations remain "visible" to the framework's
/// monitoring systems.
///
/// See also:
/// * [FluentProvider], the central registry and orchestrator for data access.
/// * [FluentTask], the operational unit definition governing task execution.
/// * [FluentDb], for managing transactional isolation during raw command execution
extension FluentExecuteRaw<T extends FluentStorable> on FluentProvider<T> {
  /// Direct data layer coordinator that runs specific un-materialized raw column selections on the Main thread.
  ///
  /// This pipeline unpacks execution boundaries to perform atomic single-row column filters directly
  /// on the SQLite engine layer, completely bypassing hydration steps, fast-paths, and relation sub-workers.
  /// It enforces isolated dictionary parsing by returning a decoupled snapshot copy of the query result.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug].
  Future<Map<String, dynamic>?> _executeRawGetItemByTaskOnMain(FluentTask task) async {
    final String searchCol = task.helper?.column ?? 'id';
    final dynamic value = task.helper?.value;
    final String whereClause = task.helper?.where ?? '$searchCol = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [value];
    final int limit = task.helper?.limit ?? 1;

    FluentLog.debug(
      'Executing Main-thread single raw-map record search query selection routine',
      tag: '$tableName:getRawItemByExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit},
    );

    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: _injectSoftDelete(whereClause), whereArgs: whereArgs, limit: limit);

    if (maps.isEmpty) {
      FluentLog.debug(
        'Empty result set returned from data layer raw record lookups',
        tag: '$tableName:getRawItemByExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString()},
      );
      return null;
    }

    return Map<String, dynamic>.from(maps.first);
  }

  /// Direct data layer coordinator that runs specific multi-row un-materialized collection selections on the Main thread.
  ///
  /// This pipeline unpacks database execution parameters to perform batch column filters directly on
  /// the SQLite engine layer, completely bypassing hydration steps, fast-paths, and relational sub-workers.
  /// It returns a memory-optimized, non-growable fixed list containing deep-copied snapshots of individual rows.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug].
  Future<List<Map<String, dynamic>>> _executeRawGetItemsByTaskOnMain(FluentTask task) async {
    final String searchCol = task.helper?.column ?? 'id';
    final dynamic value = task.helper?.value;
    final String whereClause = task.helper?.where ?? '$searchCol = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [value];
    final int? limit = task.helper?.limit;

    FluentLog.debug(
      'Executing Main-thread batch raw-map collection search query selection routine',
      tag: '$tableName:getRawItemsByExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit ?? 'unlimited'},
    );

    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: whereClause, whereArgs: whereArgs, limit: limit);

    final int resultLength = maps.length;

    if (resultLength == 0) {
      FluentLog.debug(
        'Empty result set returned from data layer batch raw record selections',
        tag: '$tableName:getRawItemsByExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString()},
      );
      return <Map<String, dynamic>>[];
    }

    FluentLog.debug(
      'Batch raw records retrieved successfully. Projecting isolated dictionary maps',
      tag: '$tableName:getRawItemsByExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'matchedRowsCount': resultLength},
    );

    return List<Map<String, dynamic>>.generate(resultLength, (i) => Map<String, dynamic>.from(maps[i]), growable: false);
  }

  /// Direct data layer coordinator that runs raw DML SQL commands on the Main thread.
  ///
  /// This pipeline facilitates high-performance execution of custom, developer-defined SQL statements
  /// while maintaining strict adherence to framework safety and telemetry standards:
  /// * Performs early-path validation to guard against destructive DDL (Data Definition Language) commands like `DROP` or `ALTER`.
  /// * Reconciles SQL placeholders with provided argument collections to ensure robust parameter binding and prevent injection vectors.
  /// * Automatically routes execution through the active database executor, capturing affected row metrics for synchronization with the [TableStatsTracker].
  ///
  /// [task] represents the framework operational unit containing the raw SQL string, bound arguments, and execution policy configuration.
  ///
  /// Returns a [Future<int>] yielding the number of rows modified by the command (e.g., deleted, updated, or inserted).
  Future<int> _executeRawSqlTaskOnMain(FluentTask task) async {
    final String sql = task.helper?.sql ?? '';
    final List<dynamic>? args = task.helper?.whereArgs;

    FluentLog.debug('Executing raw SQL command on Main thread', tag: '$tableName:executeExecutor', context: {'sql': sql, 'argumentsCount': args?.length ?? 0, 'taskId': task.id});

    try {
      FluentLog.sql(sql, tag: '$tableName:sql:executeExecutor', arguments: args);

      final int affectedRows = await executor.rawUpdate(sql, args);

      FluentLog.debug('Raw SQL execution successful', tag: '$tableName:executeExecutor', context: {'affectedRows': affectedRows, 'taskId': task.id});

      return affectedRows;
    } catch (e, st) {
      FluentLog.error(
        'Raw SQL execution failed',
        e,
        st,
        tag: '$tableName:exception:executeExecutor',
        hint: 'Verify your SQL syntax and parameter binding order. Ensure the statement is a DML command (UPDATE, INSERT, DELETE).',
        context: {'sql': sql, 'taskId': task.id},
      );
      rethrow;
    }
  }
}
