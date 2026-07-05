// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing the core transactional pipeline for
/// persisting [FluentStorable] entity collections.
///
/// The [FluentExecuteSave] extension acts as the primary traffic controller for
/// write operations. It handles the critical transition between high-level business
/// domain objects and low-level SQL execution, ensuring that all data persistence
/// tasks are executed with full transactional atomicity and thread safety.
///
/// ### Core Architecture & Transactional Paradigms
/// The extension employs a dynamic execution strategy that adapts to the current
/// database state, ensuring robust write performance:
///
/// * **Context-Aware Transaction Routing:** The extension intelligently detects
///   existing database transaction contexts. If an inherited transaction is found
///   (e.g., within a nested service call), it transparently merges the operation
///   into the active cascade, maintaining unit-of-work integrity.
/// * **Exclusive Standalone Isolation:** In the absence of an inherited context,
///   the extension spawns an isolated database transaction block. This guarantees
///   that multi-item saves are applied as a single atomic unit—if any insertion
///   or update fails, the system safely rolls back to the initial state.
/// * **Resource Lifecycle Management:** To prevent connection hijacking, the
///   extension strictly manages executor handles via [setTransactionExecutor] and
///   [restoreOriginalExecutor]. The use of `finally` blocks ensures that
///   even in the event of severe database failures, the provider’s executor state
///   is cleanly reset.
/// * **Diagnostic Tracing & Error Handling:** Every save routine is instrumented
///   with granular logging that tracks batch sizes, transaction modes, and
///   task IDs. Database exceptions are caught and passed through custom handlers,
///   providing actionable feedback on constraint violations or driver-level issues.
///
/// ### Execution Flow
/// Incoming [FluentTask] commands are normalized into typed entity collections
/// before being passed to the low-level execution engine. By decoupling the
/// request routing from the actual SQL write routines, the extension ensures
/// that business logic remains clean while persistence remains highly performant
/// and reliable.
///
/// See also:
/// * [FluentProvider], the central registry and orchestrator for data access.
/// * [FluentDb], for transactional isolation guarantees and commit logic.
/// * [FluentExecuteDelete], for symmetrical deletion and lifecycle management.
extension FluentExecuteSave<T extends FluentStorable> on FluentProvider<T> {
  /// Standard pipeline router executing incoming write [task] commands directly on the Main thread.
  ///
  /// This internal mechanism extracts payload variants safely into unified generic arrays,
  /// checks whether an outer transaction wrapper is currently controlling the call stack:
  /// * Intercepts existing contexts to merge queries into an inherited cascade write sequence.
  /// * Spawns an isolated local transaction when executing a standalone task entry point.
  ///
  /// Dispatches structured execution tracing via [FluentLog.debug] and maps internal errors
  /// through custom low-level database exception handlers.
  Future<void> _executeSaveTaskOnMain(FluentTask task) async {
    final List<T> items;

    if (task.data is List<T>) {
      items = task.data as List<T>;
    } else if (task.data is List) {
      items = (task.data as List).whereType<T>().toList();
    } else {
      items = <T>[task.data as T];
    }

    if (_transactionExecutor != null && _transactionExecutor is Transaction) {
      try {
        FluentLog.debug(
          'Executing Main-thread save routine within an inherited active transaction',
          tag: '$tableName:saveExecutor',
          context: {'batchSize': items.length, 'transactionMode': 'inherited'},
        );
        await _executeAdd(_transactionExecutor as Transaction, items, task, parentJsons: null);
        return;
      } on DatabaseException catch (e, stackTrace) {
        _handleDatabaseException(e, stackTrace);
        rethrow;
      }
    }

    try {
      FluentLog.debug('Opening an exclusive standalone transaction block', tag: '$tableName:saveExecutor', context: {'batchSize': items.length, 'transactionMode': 'standalone'});

      await db.transaction((txn) async {
        await _executeAdd(txn, items, task, parentJsons: null);
      });
    } on DatabaseException catch (e, stackTrace) {
      _handleDatabaseException(e, stackTrace);
      rethrow;
    }
  }
}
