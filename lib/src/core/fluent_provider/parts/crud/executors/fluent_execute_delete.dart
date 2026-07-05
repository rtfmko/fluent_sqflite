// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe deletion primitives for [FluentStorable] entities.
///
/// The [FluentExecuteDelete] extension serves as the foundational executor for record removal. It
/// intelligently switches between soft-deletion (preserving data for recovery) and hard-deletion
/// (permanent erasure) based on model configuration and execution policy.
///
/// ### Core Architecture & Deletion Paradigms
/// This extension enforces strict data-integrity safeguards during the deletion lifecycle:
///
/// * **Identity Validation:** Every deletion request is guarded by identity validation. The system
///   explicitly requires a resolved primary key before executing, effectively neutralizing
///   the risk of accidental "table-wide" wipes caused by malformed queries.
/// * **Dual-Mode Orchestration:**
///   * **Soft-Delete:** If the model implements [FluentSoftDeletable], the engine performs a
///     state-reversion update. This masks the record from active queries while retaining it
///     for future recovery.
///   * **Hard-Delete:** When [isHardDelete] is requested or the model lacks [FluentSoftDeletable]
///     capabilities, the engine performs a physical `DELETE` operation, reclaiming storage
///     and ensuring compliance with data-retention policies.
/// * **Relational Cascading:** The executor integrates with the [RelationsMixin] to manage
///   dependency cleanup. During physical removal, it coordinates the invalidation of orphaned
///   associations, preventing database inconsistencies or referential integrity violations.
/// * **Fault-Tolerant Execution:** The layer captures race conditions (e.g., attempting to
///   delete a record already purged by a concurrent transaction) and logs them through the
///   centralized diagnostic facade, providing clear insights into execution outcomes.
///
/// ### Execution Flow
/// Deletion tasks are dispatched as structured [FluentTask] units. This ensures that
/// operations respect the defined [ExecutionPolicy], allowing for prioritized task handling
/// and ensuring that heavy-duty cleanup operations (like hard-purges) do not block
/// critical UI execution threads.
///
/// See also:
/// * [FluentSoftDeletable], for models supporting record recovery.
/// * [FluentRestore], for methods to reverse soft-deletion operations.
/// * [FluentDb], the engine responsible for transaction management and task scheduling.
extension FluentExecuteDelete<T extends FluentStorable> on FluentProvider<T> {
  /// Executes a deletion operation on a specific database record, supporting both
  /// soft-delete and hard-delete execution modes.
  ///
  /// This method serves as the low-level executor for record removal:
  /// * **Identity Validation:** Ensures the primary key is present before initiating
  ///   the operation to prevent accidental table-wide data loss.
  /// * **Dual-Mode Execution:**
  ///   * If [isHardDelete] is `true` or the model does not implement [FluentSoftDeletable],
  ///     it performs a physical `DELETE` query to permanently erase the record.
  ///   * Otherwise, it performs a soft-delete (update) by setting the `deleted_at`
  ///     timestamp, preserving the record for potential restoration.
  /// * **Execution Integrity:** Captures state, logs potential race conditions (e.g.,
  ///   record already removed by concurrent transaction), and handles storage
  ///   constraint failures.
  ///
  /// [task] must contain a valid identity key in the helper unit.
  ///
  /// Returns a [Future<int>] representing the number of rows physically removed or updated
  /// (0 if the identity key does not match existing records).
  Future<int> _executeDeleteTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    if (id == null) {
      FluentLog.warning(
        'Database purge sequence aborted on Main due to missing parameter references',
        tag: '$tableName:deleteExecutor',
        hint: 'Verify that the task wrapper passes a non-null primary identity key value.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final bool isHardDelete = task.helper?.isHardDelete ?? false;

    FluentLog.debug(
      'Executing Main-thread direct physical row destruction sequence',
      tag: '$tableName:deleteExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'isHardDelete': isHardDelete},
    );

    try {
      final int count = await _rawDeleteByExecution(pkName, id, executor, isHardDelete: isHardDelete);

      if (count > 0) {
        FluentLog.debug(
          'Targeted database entity row permanently purged from storage layer',
          tag: '$tableName:deleteExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
        );
      } else {
        FluentLog.warning(
          'Physical row destruction completed with zero affected records',
          tag: '$tableName:deleteExecutor',
          hint: 'The identity key may not match any active row documents, or the record was already removed by a concurrent execution transaction.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
        );
      }

      return count;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread row destruction query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:deleteExecutor',
        hint: 'Verify active storage constraint locks, inspect cascading foreign key rules, or audit table index maps.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs transactional multi-row conditional purges on the Main thread.
  ///
  /// This pipeline unpacks task payload fields to execute isolated batch destructions safely:
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Overrides active query routes using [setTransactionExecutor] to hook operations to the current transaction frame.
  /// * Utilizes a strict `finally` structural block to guarantee connection pool restoration via [restoreOriginalExecutor].
  /// * Traps query issues, logging comprehensive data context diagnostics before propagation.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<int> _executeDeleteByTaskOnMain(FluentTask task) async {
    final String searchKey = task.helper?.key ?? 'id';
    final dynamic value = task.helper?.value;
    final bool isHardDelete = task.helper?.isHardDelete ?? false;

    FluentLog.debug(
      'Executing Main-thread transactional conditional record purge sequence',
      tag: '$tableName:rawDeleteExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumnField': searchKey, 'searchValue': value.toString(), 'isHardDelete': isHardDelete},
    );

    try {
      // Wrap the multi-row deletion routine inside a localized database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          return await _rawDeleteByExecution(searchKey, value, txn, isHardDelete: isHardDelete);
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, s) {
      FluentLog.error(
        'Main-thread conditional purge transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:rawDeleteExecutor',
        hint: 'Examine database indexing boundaries, active primary constraints, or evaluate concurrent connection pool configurations.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedColumnField': searchKey},
      );
      rethrow;
    }
  }

  /// Low-level atomic driver execution routine that carries out row deletions and relational cleanup cycles.
  ///
  /// This routine acts as a direct interface to the underlying database driver:
  /// * Fires a parameterized raw SQL delete query directly against the provided [activeExecutor] context.
  /// * Evaluates the resulting row mutation count to determine if follow-up processing is required.
  /// * Spawns an orphan records sweeping routine via [_relationsMixin] to process foreign constraints.
  /// * Forwards the original transactional executor reference to child workers to maintain transaction scopes.
  ///
  /// [searchKey] specifies the targeted column field name to filter against.
  /// [value] defines the target evaluation parameter bound to the deletion query constraint argument.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  ///
  /// Returns a [Future<int>] containing the total number of physical table rows deleted during this process block.
  Future<int> _rawDeleteByExecution(String searchKey, dynamic value, DatabaseExecutor activeExecutor, {bool isHardDelete = false}) async {
    // Execute the low-level physical row deletion directly against the assigned driver context
    int count = 0;

    if (!isHardDelete && modelSample is FluentSoftDeletable) {
      final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;
      final DateTime now = DateTime.now();
      final dynamic formattedDate = tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? now.millisecondsSinceEpoch : now.toIso8601String();

      count = await activeExecutor.update(tableName, {sample.softDeleteColumn: formattedDate}, where: '$searchKey = ?', whereArgs: [value]);

      FluentLog.debug('Records softly deleted (moved to trash)', tag: '$tableName:rawDeleteExecutor', context: {'count': count});
    } else {
      count = await activeExecutor.delete(tableName, where: '$searchKey = ?', whereArgs: [value]);
      FluentLog.debug('Records permanently purged', tag: '$tableName:rawDeleteExecutor', context: {'count': count});
    }

    if (count > 0) {
      FluentLog.debug(
        'Physical data layer entries removed successfully from the storage engine',
        tag: '$tableName:rawDeleteExecutor',
        context: {'tableName': tableName, 'searchColumnField': searchKey, 'purgedRowsCount': count},
      );

      // SCENARIO A: RELATIONAL INTEGRITY CLEANUP — Cascade cascade checks to wipe detached data structures
      if (_hasRelations && _relationsMixin != null) {
        // Pass the identical executing connection handle downstream to preserve atomic transaction boundaries
        await _relationsMixin!.cleanupOrphans(activeExecutor);
      }
    } else {
      // SCENARIO B: NO TARGET RECORDS FOUND — The execution criteria matched zero active row models
      FluentLog.debug(
        'Physical row destruction completed with zero affected records',
        tag: '$tableName:rawDeleteExecutor',
        context: {'tableName': tableName, 'searchColumnField': searchKey, 'searchValue': value.toString()},
      );
    }

    return count;
  }

  /// Low-level atomic driver execution routine for custom WHERE clauses.
  Future<int> _rawDeleteWhereExecution(String whereClause, List<Object?>? whereArgs, DatabaseExecutor activeExecutor, {bool isHardDelete = false}) async {
    int count = 0;

    if (!isHardDelete && modelSample is FluentSoftDeletable) {
      final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;
      final DateTime now = DateTime.now();
      final dynamic formattedDate = tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? now.millisecondsSinceEpoch : now.toIso8601String();

      count = await activeExecutor.update(tableName, {sample.softDeleteColumn: formattedDate}, where: whereClause, whereArgs: whereArgs);
      FluentLog.debug('Records softly deleted via custom condition', tag: '$tableName:rawDeleteWhere');
    } else {
      count = await activeExecutor.delete(tableName, where: whereClause, whereArgs: whereArgs);
      FluentLog.debug('Records permanently purged via custom condition', tag: '$tableName:rawDeleteWhere');
    }

    if (count > 0 && _hasRelations && _relationsMixin != null) {
      await _relationsMixin!.cleanupOrphans(activeExecutor);
    }

    return count;
  }

  /// Direct data layer coordinator that runs transactional multi-row custom WHERE purges on the Main thread.
  ///
  /// Handles both soft and hard deletions based on the [isHardDelete] flag injected into the task helper.
  Future<int> _executeDeleteWhereTaskOnMain(FluentTask task) async {
    final String? whereClause = task.helper?.where;
    final List<Object?>? whereArgs = task.helper?.arguments;
    final bool isHardDelete = task.helper?.isHardDelete ?? false;

    if (whereClause == null || whereClause.isEmpty) {
      FluentLog.warning(
        'Database custom purge sequence aborted on Main due to empty WHERE clause',
        tag: '$tableName:deleteWhereExecutor',
        hint: 'Verify that the task wrapper passes a valid SQL condition.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return 0;
    }

    FluentLog.debug(
      'Executing Main-thread transactional custom WHERE record destruction sequence',
      tag: '$tableName:deleteWhereExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'isHardDelete': isHardDelete},
    );

    try {
      // Wrap the multi-row deletion routine inside a localized database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          final int count = await _rawDeleteWhereExecution(whereClause, whereArgs, txn, isHardDelete: isHardDelete);

          FluentLog.debug(
            'Custom condition purge successfully finalized inside storage layer',
            tag: '$tableName:deleteWhereExecutor',
            context: {'tableName': tableName, 'taskId': task.id, 'affectedRows': count},
          );

          return count;
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, s) {
      FluentLog.error(
        'Main-thread custom WHERE purge transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:deleteWhereExecutor',
        hint: 'Analyze the syntax of your WHERE clause or inspect active table constraint locks.',
        context: {'tableName': tableName, 'taskId': task.id, 'whereClause': whereClause},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs transactional multi-row primary identity purges on the Main thread.
  ///
  /// This pipeline unpacks target argument lists to execute safe, chunked batch destructions inside atomic loops:
  /// * Evaluates input collection states to guard against uninitialized or empty identity parameter references.
  /// * Establishes an atomic database transaction context block to ensure structural rolled-back parity on failures.
  /// * Redirects operational engine queries to the transaction handle via [setTransactionExecutor].
  /// * Protects connection pools with a strict `finally` scope block that resets context paths via [restoreOriginalExecutor].
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<int> _executeDeleteItemsByIdsTaskOnMain(FluentTask task) async {
    final List<dynamic> idList = task.helper?.arguments ?? [];
    final bool isHardDelete = task.helper?.isHardDelete ?? false;

    if (idList.isEmpty) {
      FluentLog.warning(
        'Database batch identity purge sequence aborted on Main due to empty criteria lists',
        tag: '$tableName:deleteItemsByIdsExecutor',
        hint: 'Verify that the task wrapper passes a non-empty identity collection array argument.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread transactional batch identity record destruction sequence',
      tag: '$tableName:deleteItemsByIdsExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordsCount': idList.length, 'isHardDelete': isHardDelete},
    );

    try {
      // Wrap the mass multi-row deletion routine inside a localized database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          final int count = await _rawBatchDeleteExecution(idList, pkName, txn, task.policy, isHardDelete: isHardDelete);
          FluentLog.debug(
            'Database operational batch multi-purge successfully finalized inside storage layer',
            tag: '$tableName:deleteItemsByIdsExecutor',
            context: {'tableName': tableName, 'taskId': task.id, 'processedRecordsCount': idList.length},
          );
          return count;
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, s) {
      FluentLog.error(
        'Main-thread batch identity purge transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:deleteItemsByIdsExecutor',
        hint: 'Analyze the total parameter length boundaries against SQLite engine constraints, check active table locks, or inspect index maps.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Low-level multi-row batch execution routine that handles chunked deletions and relational cleanup cycles.
  ///
  /// This high-throughput structural routine processes batch identity sets directly against the active connection:
  /// * Allocates an un-committed [Batch] structure linked directly to the passed [activeExecutor] reference context.
  /// * Segments mass tracking identifier collections into safe operational slices via [_executeDeleteChunks].
  /// * Flushes the piled queries into the storage layers using `noResult: true` to eliminate unnecessary memory overhead.
  /// * Spawns an orphan records sweeping routine via [_relationsMixin] to process foreign constraints.
  /// * Forwards the original transactional executor reference to child workers to maintain transaction scopes.
  ///
  /// [idList] defines the list of primitive or object identity keys targeted for deletion.
  /// [pkName] specifies the string column name assigned as the table's primary key identifier.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  /// [policy] carries configuration rules containing maximum variable boundary limits and chunk size modifiers.
  Future<int> _rawBatchDeleteExecution(List<dynamic> idList, String pkName, DatabaseExecutor activeExecutor, ExecutionPolicy policy, {bool isHardDelete = false}) async {
    // Initialize an atomic batch compilation pipeline bounded to the current executor transaction pool
    final Batch batch = activeExecutor.batch();

    // Delegate identity arrays into parameterized raw chunks to conform to SQLite variable limits
    _executeDeleteChunks(batch, idList, policy.effectiveChunkSize, pkName, isHardDelete: isHardDelete);

    final List<dynamic> results = await batch.commit();

    int totalDeleted = 0;
    for (final dynamic r in results) {
      if (r is int) totalDeleted += r;
    }

    FluentLog.debug(
      'Physical batch identity deletion query successfully committed to the database storage engine',
      tag: '$tableName:batchDeleteExecutor',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'totalPurgedIdsCount': idList.length, 'configuredChunkSize': policy.effectiveChunkSize},
    );

    if (totalDeleted > 0 && _hasRelations && _relationsMixin != null) {
      await _relationsMixin!.cleanupOrphans(activeExecutor);
    }
    return totalDeleted;
  }

  /// Segments large collection parameters into fixed, parameterized query blocks to avoid database variable limits.
  ///
  /// This performance-critical calculation routine shards tracking lists directly into individual batch operations:
  /// * Evaluates array boundaries to slice the data set safely without creating index overflow errors.
  /// * Leverages dynamic placeholder strings to generate parameterized target arrays for each chunk execution.
  /// * Piles row criteria commands into [batch] arrays using an `IN (...)` match clause for maximum efficiency.
  /// * Prevents thread blockages by computing slices using localized value parameters rather than heavy map objects.
  ///
  /// [batch] represents the ongoing database batch sequence used to group and execute multi-row mutations.
  /// [idList] defines the source list of unique record identifiers targeted for deletion.
  /// [chunkSize] specifies the maximum allowed variables allowed in a single database parameter block (e.g., SQLite limits).
  /// [pkName] defines the exact physical column string key assigned as the target table primary identifier.
  void _executeDeleteChunks(Batch batch, List<dynamic> idList, int chunkSize, String pkName, {bool isHardDelete = false}) {
    final int totalLength = idList.length;
    final bool useSoftDelete = !isHardDelete && modelSample is FluentSoftDeletable;

    final String? softDeleteColumn = useSoftDelete ? (modelSample as FluentSoftDeletable).softDeleteColumn : null;
    final dynamic formattedDate = useSoftDelete ? (tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? DateTime.now().millisecondsSinceEpoch : DateTime.now().toIso8601String()) : null;

    for (int i = 0; i < totalLength; i += chunkSize) {
      final int end = (i + chunkSize > totalLength) ? totalLength : i + chunkSize;
      final List<dynamic> chunk = idList.sublist(i, end);

      final String placeholders = _generatePlaceholders(chunk.length);

      if (useSoftDelete) {
        batch.update(tableName, {softDeleteColumn!: formattedDate}, where: '$pkName IN ($placeholders)', whereArgs: chunk);
      } else {
        batch.delete(tableName, where: '$pkName IN ($placeholders)', whereArgs: chunk);
      }

      FluentLog.debug(
        'Segmented identification collection subset registered successfully into batch context',
        tag: '$tableName:deleteChunkExecutor',
        context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'currentChunkStartIndex': i, 'currentChunkSliceLength': chunk.length, 'isSoft': useSoftDelete},
      );
    }
  }

  /// Executes the physical deletion of records that have exceeded the soft-delete retention period.
  ///
  /// This internal engine worker performs a hard-delete SQL operation on the database layer:
  /// * **Time-based filtering:** Calculates the cutoff timestamp based on [FluentDb.softDeleteRetentionPeriod].
  /// * **Format alignment:** Dynamically adapts the cutoff value to match the table's configured
  ///   `dateTimeFormat` (timestamp vs ISO8601 string) to ensure consistent SQL comparisons.
  /// * **Targeted deletion:** Removes records where the soft-delete column is set and the
  ///   stored date is strictly older than the calculated threshold.
  ///
  /// This method is invoked by the background maintenance pipeline to prevent the accumulation
  /// of stale data and optimize database performance.
  ///
  /// Returns a [Future<int>] representing the total number of rows permanently purged
  /// from the database during this execution.
  Future<int> _executePurgeSoftDeletedTaskOnMain(FluentTask task) async {
    if (modelSample is! FluentSoftDeletable) return 0;
    final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;

    FluentLog.debug('Executing Main-thread soft delete purge sequence', tag: '$tableName:purgeSoftDeleted');

    try {
      final Duration retention = FluentDb.softDeleteRetentionPeriod;
      final DateTime now = DateTime.now().subtract(retention);

      final dynamic formattedDate = tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? now.millisecondsSinceEpoch : now.toIso8601String();

      final int count = await executor.delete(tableName, where: '${sample.softDeleteColumn} IS NOT NULL AND ${sample.softDeleteColumn} < ?', whereArgs: [formattedDate]);

      FluentLog.debug('Auto-purge completed', tag: '$tableName:purgeSoftDeleted', context: {'count': count});
      return count;
    } catch (e, s) {
      FluentLog.error('Purge sequence failed', e, s, tag: '$tableName:purgeSoftDeleted');
      rethrow;
    }
  }

  /// Executes a hard-purge operation to permanently remove soft-deleted records
  /// from the storage engine.
  ///
  /// This method performs an irreversible data deletion for all records where the
  /// [FluentSoftDeletable.softDeleteColumn] is not null. Following the purge,
  /// it triggers an optional orphan cleanup process if the model maintains
  /// relational dependencies.
  ///
  /// * **Irreversibility:** Data purged by this operation cannot be restored.
  /// * **Relational Integrity:** If the model supports relations, it invokes
  ///   [cleanupOrphans] to ensure that purged records do not leave dangling
  ///   references in linked tables.
  /// * **Execution Context:** This method is optimized for direct, synchronous-style
  ///   execution within the current pipeline, suitable for immediate maintenance
  ///   tasks where the overhead of scheduling is unnecessary.
  ///
  /// Returns the number of records permanently removed from the database.
  /// Throws an exception if the underlying database deletion fails.
  Future<int> _executeForcePurgeSoftDeletedTaskOnMain(FluentTask task) async {
    if (modelSample is! FluentSoftDeletable) return 0;

    final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;

    FluentLog.debug('Executing Main-thread empty trash sequence', tag: '$tableName:emptyTrash');

    try {
      final int count = await executor.delete(tableName, where: '${sample.softDeleteColumn} IS NOT NULL');

      FluentLog.debug('Empty trash sequence completed', tag: '$tableName:emptyTrash', context: {'purgedCount': count});

      if (_hasRelations && _relationsMixin != null) {
        await _relationsMixin!.cleanupOrphans(executor);
      }

      return count;
    } catch (e, s) {
      FluentLog.error('Empty trash sequence failed', e, s, tag: '$tableName:emptyTrash');
      rethrow;
    }
  }
}
