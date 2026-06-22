// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing transactional restoration primitives
/// for soft-deleted [FluentStorable] entities.
///
/// The [FluentExecuteRestore] extension serves as the restoration orchestrator,
/// enabling the recovery of records that have been marked as deleted (e.g., via
/// `deleted_at` timestamps). By centralizing restoration logic, the extension
/// guarantees that recovered data retains its integrity and relational validity.
///
/// ### Core Architecture & Restoration Paradigms
/// This extension is engineered for high-throughput recovery and atomic safety:
///
/// * **Atomic Transactional Recovery:** Restoration tasks are executed within a
///   single database transaction. This ensures an "all-or-nothing" consistency
///   guarantee—if the batch recovery is interrupted, the database state remains
///   unmodified, preventing data corruption.
/// * **Chunked Batch Processing:** To bypass SQLite variable binding limits, the
///   extension utilizes [_executeRestoreChunks], segmenting large identifier lists
///   into manageable batches according to [ExecutionPolicy].
/// * **Relational Re-validation:** Upon restoration, the framework ensures that
///   recovered records are correctly re-integrated into the system, automatically
///   clearing the deletion markers and ensuring compatibility with active query filters.
/// * **Fault-Tolerant Diagnostics:** The pipeline includes structured logging that
///   tracks restoration progress, affected row counts, and potential driver-level
///   exceptions, providing full transparency during recovery operations.
///
/// ### Execution Flow
/// Operations are dispatched as structured [FluentTask] units. This architecture
/// ensures that restoration tasks respect current concurrency constraints and
/// transactional locks, effectively offloading heavy-duty bulk updates from the
/// UI-critical threads.
///
/// See also:
/// * [FluentSoftDeletable], the contract for models supporting soft-deletion.
/// * [FluentExecuteDelete], for methods that perform the initial deletion.
/// * [FluentDb], for transactional isolation guarantees.
extension FluentExecuteRestore<T extends FluentStorable> on FluentProvider<T> {
  /// Performs a transactional batch restoration of soft-deleted entities by their primary keys.
  ///
  /// This method restores records by resetting the `deleted_at` (or equivalent)
  /// column to `null` for all entities matching the provided [ids]. To ensure
  /// maximum performance and reliability, the restoration is executed:
  ///
  /// * **Transactionally:** All updates are wrapped in a database transaction,
  ///   ensuring that either all records are restored or none (preventing partial state).
  /// * **In Chunks:** To avoid exceeding SQL parameter limits (e.g., `SQLITE_LIMIT_VARIABLE_NUMBER`),
  ///   the operation is processed in segments determined by [ExecutionPolicy].
  /// * **Atomically:** Uses a [Batch] object to minimize I/O overhead by committing
  ///   multiple `UPDATE` statements as a single atomic unit.
  ///
  /// Returns the total count of successfully restored records.
  Future<int> _executeRestoreItemsByIdsTaskOnMain(FluentTask task) async {
    final List<dynamic> ids = task.helper?.arguments ?? [];

    if (ids.isEmpty || modelSample is! FluentSoftDeletable) {
      if (ids.isEmpty) {
        FluentLog.warning('Batch restore aborted: empty ID list', tag: '$tableName:restoreItemsByIdsExecutor');
      }
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final String colName = (modelSample as FluentSoftDeletable).softDeleteColumn;

    FluentLog.debug(
      'Initiating batch restoration sequence',
      tag: '$tableName:restoreItemsByIdsExecutor',
      context: {'tableName': tableName, 'targetIdsCount': ids.length, 'chunkSize': task.policy.effectiveChunkSize},
    );

    try {
      return await db.transaction((txn) async {
        final Batch batch = txn.batch();
        _executeRestoreChunks(batch, ids, task.policy.effectiveChunkSize, pkName, colName);

        final List<dynamic> results = await batch.commit();
        final int restoredCount = results.whereType<int>().fold<int>(0, (a, b) => a + b);

        FluentLog.debug('Batch restoration successfully finalized', tag: '$tableName:restoreItemsByIdsExecutor', context: {'restoredCount': restoredCount});

        return restoredCount;
      });
    } catch (e, s) {
      FluentLog.error('Batch restoration failed during transaction', e, s, tag: '$tableName:restoreItemsByIdsExecutor', context: {'targetIdsCount': ids.length});
      rethrow;
    }
  }
}
