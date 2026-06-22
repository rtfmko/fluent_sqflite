// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing core maintenance and lifecycle management
/// primitives for [FluentStorable] entity tables.
///
/// The [FluentExecuteMaintenance] extension serves as the administrative backbone of
/// the storage layer. It orchestrates complex, transactional "housekeeping" tasks
/// such as bulk expiration, table evacuation (clearing), and index optimization.
/// These operations are designed to be atomic and thread-safe, ensuring that the
/// database state remains consistent even during heavy maintenance cycles.
///
/// ### Core Architecture & Maintenance Paradigms
/// This extension enforces strict isolation and resource management protocols:
///
/// * **Atomic Transactional Evacuation:** Maintenance operations, such as clearing a
///   table, are wrapped in explicit database transaction blocks. This guarantees that
///   if an evacuation sequence is interrupted, the database reverts to its prior state
///   without partial data loss or corrupted schemas.
/// * **Transactional Driver Redirection:** To maintain operational integrity, the
///   extension dynamically redirects the provider's execution context to an active
///   transaction handle using [setTransactionExecutor]. This ensures that all
///   sub-operations within a sweep remain scoped to the same atomic unit.
/// * **Safety-First Resource Management:** Every maintenance routine utilizes
///   a strict `finally` block to invoke [restoreOriginalExecutor], ensuring that
///   connection pools are never left in a hijacked or invalid state, regardless
///   of success or failure.
/// * **Fault-Tolerant Diagnostics:** Maintenance tasks are instrumented with granular
///   logging that captures indexing boundaries, constraint violations, and connection
///   pool contention, allowing for rapid debugging of database-level bottlenecks.
///
/// ### Execution Flow
/// Maintenance tasks are dispatched as structured [FluentTask] units to the internal
/// execution pipeline. This architecture decouples high-latency background maintenance
/// from the primary application logic, ensuring that expensive cleanup operations
/// do not induce frame drops or latency in the UI thread.
///
/// See also:
/// * [FluentProvider], the central orchestrator for storage drivers.
/// * [FluentTask], the unit of work governing maintenance constraints.
/// * [FluentDb], for transactional isolation and atomic commit guarantees.
extension FluentExecuteMaintenance<T extends FluentStorable> on FluentProvider<T> {
  /// Direct data layer coordinator that runs transactional expiration maintenance sweeps on the Main thread.
  ///
  /// This pipeline unpacks criteria boundaries to execute background cleanups safely within an atomic isolation lock:
  /// * Evaluates data existence constraints to guard against uninitialized or missing helper parameters.
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Redirects operational engine queries to the transaction handle via [setTransactionExecutor].
  /// * Strongly enforces strict generic casting on arguments via [List.from] to ensure compatibility with underlying bindings.
  /// * Protects connection pools with a strict `finally` scope block that resets context paths via [restoreOriginalExecutor].
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<int> _executeClearExpiredItemsTaskOnMain(FluentTask task) async {
    final String? whereClause = task.helper?.where;
    final List<dynamic>? whereArgs = task.helper?.whereArgs;

    if (whereClause == null || whereArgs == null) {
      FluentLog.warning(
        'Database cache expiration sweep aborted on Main due to missing query parameters',
        tag: '$tableName:clearExpireItemsExecutor',
        hint: 'Verify that the task helper payload supplies both the conditional where-clause and its corresponding evaluation arguments.',
        context: {'tableName': tableName, 'taskId': task.id, 'isWhereClauseNull': whereClause == null, 'isWhereArgsNull': whereArgs == null},
      );
      return 0;
    }

    FluentLog.debug(
      'Executing Main-thread transactional database cache expiration maintenance sweep',
      tag: '$tableName:clearExpireItemsExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'conditionalWhereClause': whereClause, 'queryArgumentsCount': whereArgs.length},
    );

    try {
      // Wrap the record expiration sweep routine inside an atomic database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);
        try {
          final List<Object?> castedArgs = List<Object?>.from(whereArgs);
          final int count = await _rawClearExpiredExecution(whereClause, castedArgs, txn);
          FluentLog.debug(
            'Database operational cache expiration sweep successfully finalized inside storage layer',
            tag: '$tableName:clearExpireItemsExecutor',
            context: {'tableName': tableName, 'taskId': task.id},
          );
          return count;
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, s) {
      FluentLog.error(
        'Main-thread cache expiration transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:clearExpireItemsExecutor',
        hint: 'Examine table indexing on columns evaluated by the expiration query, or look into active record transactional concurrency thresholds.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs transactional whole-table evacuations on the Main thread.
  ///
  /// This pipeline handles full structural truncations safely within an atomic isolation lock:
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Overrides active query routes using [setTransactionExecutor] to hook operations to the current transaction frame.
  /// * Utilizes a strict `finally` structural block to guarantee connection pool restoration via [restoreOriginalExecutor].
  /// * Traps query issues, logging comprehensive data context diagnostics before propagation.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], or [FluentLog.error].
  Future<int> _executeClearTableTaskOnMain(FluentTask task) async {
    FluentLog.debug('Executing Main-thread transactional table evacuation destruction sequence', tag: '$tableName:clearTableExecutor', context: {'tableName': tableName, 'taskId': task.id});

    try {
      // Wrap the complete table evacuation routine inside a localized database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          final int count = await _rawClearTableExecution(txn);
          FluentLog.debug(
            'Database operational table evacuation successfully finalized inside storage layer',
            tag: '$tableName:clearTableExecutor',
            context: {'tableName': tableName, 'taskId': task.id},
          );
          return count;
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, st) {
      FluentLog.error(
        'Main-thread table evacuation transaction pipeline aborted due to execution driver failure',
        e,
        st,
        tag: '$tableName:exception:clearTableExecutor',
        hint: 'Examine database indexing boundaries, active primary constraints, or evaluate concurrent connection pool configurations.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }
}
