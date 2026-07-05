// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe permanent (hard) deletion operations
/// for [FluentStorable] entities.
///
/// The [FluentDelete] extension provides specialized, irreversible removal primitives.
/// Unlike standard operations or soft-delete mechanisms that mask records, methods in
/// this extension bypass [FluentSoftDeletable] state modifiers to perform direct
/// SQL `DELETE` operations and full relational cleanup.
///
/// ### Execution Paradigms & Safety Constraints
/// Methods within this extension enforce strict data lifecycle management protocols designed
/// to ensure relational consistency during destructive operations:
///
/// * **Physical Deletion:** Directly interacts with the storage engine to execute permanent
///   data reclamation. This operation is non-recoverable.
/// * **Batch Processing:** Supports high-performance bulk removal of entity sets, leveraging
///   chunked execution to maintain database stability and avoid variable limit constraints.
/// * **Relational Integrity Cascading:** Mutative deletion operations trigger internal cascading
///   sweeps, forwarding requests to relationship mixins to invalidate foreign keys and purge
///   orphaned records.
/// * **Atomic Consistency:** All operations are routed through the [FluentProvider] connection
///   pipeline, ensuring transactional integrity.
/// * **Execution Policy Enforcement:** Hard-delete operations respect [ExecutionPolicy]
///   configurations, enabling efficient offloading of large-scale purges to background
///   task processing without blocking the event loop.
///
/// See also:
/// * [FluentSoftDeletable], which these operations bypass.
/// * [FluentProvider], the core storage driver contract.
/// * [ExecutionPolicy], which defines concurrency and task management constraints.
extension FluentDelete<T extends FluentStorable> on FluentProvider<T> {
  /// Permanently purges a specific physical record matching [item] from the [$tableName] storage engine.
  ///
  /// This operational destruction pipeline extracts the entry's primary identity key and validates boundaries:
  /// * Evaluates the primary key field early; if null, it registers a [FluentLog.warning] and short-circuits via [Future.value].
  /// * Encapsulates the target deletion parameters into a standardized [FluentTask] payload for thread coordination.
  ///
  /// [item] represents the target data model entity whose matching physical database row should be removed.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the row record is permanently purged.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final obsoleteInvoice = fetchedInvoices.first;
  ///
  /// await invoiceRepository.delete(
  ///   obsoleteInvoice,
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.critical, // Prioritize record purges over active cache fetches
  ///   ),
  /// );
  /// ```
  @internal
  Future<int> delete(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is FluentSoftDeletable) {
      final FluentSoftDeletable sample = item as FluentSoftDeletable;
      sample.deletedAt = DateTime.now();
      return update(item, policy: policy, dbName: dbName);
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    final dynamic id = item.primaryKeyValue;

    if (id == null) {
      FluentLog.warning(
        'Database delete operations rejected due to unassigned identity bounds',
        tag: '$tableName:delete',
        hint: 'Verify your model attributes possess valid database entity assignments before committing deletions. Bypassing execution preventing unnecessary database connection locking.',
        context: {'tableName': tableName, 'expectedPrimaryKeyColumn': pkName},
      );
      return Future<int>.value(0);
    }

    FluentLog.debug(
      'Initiating localized query pipeline for single-row physical record purge deletion',
      tag: '$tableName:delete',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.delete,
      table: tableName,
      dbName: dbName ?? this.dbName,
      data: item,
      helper: TableHelper(id: id, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Purges record entries from [$tableName] satisfying a conditional key evaluation constraint.
  ///
  /// This targeted, multi-tier data destruction pipeline evaluates runtime execution boundaries sequentially:
  /// * Intercepts [batch] objects to register query commands, returning an accelerated [Future.value] fast-path.
  /// * Evaluates active [_transactionExecutor] states to process selections inside local locked loops.
  /// * Packages multi-row deletion bounds into a standardized [FluentTask] for secure thread routing.
  ///
  /// [value] defines the target parameter matched against the column condition to determine row deletion.
  /// [key] specifies the physical table column field name to filter against. Defaults to the primary key name.
  /// [batch] represents an optional atomic database batch context used to stack multiple database mutation commands.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<int>] yielding the total count of physical table records successfully removed.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Perform an immediate bulk cascade delete of deactivated sessions
  /// final deactivatedCount = await sessionRepository.deleteBy(
  ///   'DEACTIVATED',
  ///   key: 'session_status',
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  /// ```
  @internal
  Future<int> deleteBy(dynamic value, {String? key, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final String searchKey = key ?? (_cachedPrimaryKey?.name ?? 'id');

    FluentLog.debug(
      'Initiating localized query pipeline for conditional storage layer record purges',
      tag: '$tableName:deleteBy',
      context: {
        'tableName': tableName,
        'searchColumnField': searchKey,
        'searchValue': value.toString(),
        'isBatchOperation': batch != null,
        'hasActiveTransaction': _transactionExecutor != null,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    // SCENARIO A: BATCH OPERATION — Stage the deletion query into the provided transaction batch array
    if (batch != null) {
      batch.delete(tableName, where: '$searchKey = ?', whereArgs: [value]);
      // Returns an assumed singular modification confirmation since actual execution delays until batch commit
      return Future<int>.value(1);
    }

    // SCENARIO B: TRANSACTION ENVELOPE — Execute directly on the local locked transaction connection pool
    if (_transactionExecutor != null) {
      return _rawDeleteByExecution(searchKey, value, _transactionExecutor!);
    }

    // SCENARIO C: STANDARD TASK PIPELINE — Encapsulate deletion parameters into a uniform framework task
    // TableHelper maps criteria into where clauses and sets multiple: true to handle bulk sweeps.
    final FluentTask task = FluentTask(
      action: FluentDbAction.deleteBy,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(key: searchKey, value: value, where: '$searchKey = ?', whereArgs: [value], multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Deletes a mass collection of individual database row items from [$tableName] matching a set of unique [ids].
  ///
  /// This high-throughput batch destruction routine evaluates runtime routing contexts sequentially:
  /// * Evaluates input collection lengths early, immediately returning an accelerated [Future.value] fast-path if empty.
  /// * Forwards tracking arrays to [_executeDeleteChunks] if a [sharedBatch] context is explicitly supplied.
  /// * Intercepts active [_transactionExecutor] connections to process primary updates inside local locked loops.
  /// * Packs remaining criteria sets into a standard [FluentTask] for thread allocation and scheduler queuing.
  ///
  /// [ids] represents a unique [Set] of primitive or object identity keys matching the target table primary key field.
  /// [sharedBatch] provides an optional external atomic batch reference to stack database mutation statements.
  /// [policy] defines chunk constraints, thread allocation overrides, and scheduling prioritizations.
  ///
  /// Returns a [Future<void>] that completes when all rows match the deleted constraint layout.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final obsoleteSessionIds = {'sess_101', 'sess_102', 'sess_159'};
  ///
  /// await sessionRepository.deleteItemsByIds(
  ///   obsoleteSessionIds,
  ///   policy: const ExecutionPolicy(
  ///     chunkSize: 500, // Segment parameters to avoid exceeding SQLite max variable limits
  ///   ),
  /// );
  /// ```
  @internal
  Future<int> deleteItemsByIds(Set<dynamic> ids, {Batch? sharedBatch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final int idsLength = ids.length;
    if (idsLength == 0) {
      FluentLog.debug('Batch primary identity multi-purge operation short-circuited due to empty parameters', tag: '$tableName:deleteItemsByIds', context: {'tableName': tableName});
      return Future<int>.value(0);
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Initiating global operational query pipeline for batch primary identity multi-purge record destruction',
      tag: '$tableName:deleteItemsByIds',
      context: {
        'tableName': tableName,
        'primaryKeyColumn': pkName,
        'targetRecordsCount': idsLength,
        'isSharedBatch': sharedBatch != null,
        'hasActiveTransaction': _transactionExecutor != null,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    // SCENARIO A: SHARED BATCH CONTEXT — Direct slice chunks onto an existing external atomic batch array
    if (sharedBatch != null) {
      _executeDeleteChunks(sharedBatch, ids.toList(), policy.effectiveChunkSize, pkName);
      return Future<int>.value(1);
    }

    // SCENARIO B: ACTIVE TRANSACTION CONNECTION — Run sequential sweeps inside local locked loops
    if (_transactionExecutor != null) {
      return _rawBatchDeleteExecution(ids.toList(), pkName, _transactionExecutor!, policy);
    }

    // SCENARIO C: STANDARD TASK SCHEDULER — Package primary array arguments into a uniform framework task.
    // TableHelper maps arguments to array indices and configures multiple: true to handle broad purges.
    final FluentTask task = FluentTask(
      action: FluentDbAction.deleteItemsByIds,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: '$pkName IN (...)', arguments: ids.toList(), multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Deletes records from [$tableName] matching a custom SQL [where] clause.
  ///
  /// This method provides maximum flexibility for multi-condition pruning.
  /// Unlike [deleteBy], which filters by a single column, this allows complex
  /// logic (e.g., 'status = ? AND created_at < ?').
  ///
  /// [where] The SQL WHERE clause (excluding the 'WHERE' keyword).
  /// [whereArgs] The arguments to bind to the placeholders in the [where] clause.
  /// [isHardDelete] If true, bypasses soft-delete mechanics and physically removes rows.
  @internal
  Future<int> deleteWhere({required String where, List<Object?>? whereArgs, bool isHardDelete = false, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (where.trim().isEmpty) {
      FluentLog.warning('Aborted deleteWhere: empty condition', tag: '$tableName:deleteWhere');
      return Future.value(0);
    }

    // SCENARIO A: BATCH
    if (batch != null) {
      if (!isHardDelete && modelSample is FluentSoftDeletable) {
        final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;
        final Object formattedDate = tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? DateTime.now().millisecondsSinceEpoch : DateTime.now().toIso8601String();
        batch.update(tableName, {sample.softDeleteColumn: formattedDate}, where: where, whereArgs: whereArgs);
      } else {
        batch.delete(tableName, where: where, whereArgs: whereArgs);
      }
      return Future<int>.value(1);
    }

    // SCENARIO B: TRANSACTION
    if (_transactionExecutor != null) {
      return _rawDeleteWhereExecution(where, whereArgs, _transactionExecutor!, isHardDelete: isHardDelete);
    }

    // SCENARIO C: TASK QUEUE
    final FluentTask task = FluentTask(
      action: FluentDbAction.deleteWhere,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: where, arguments: whereArgs, multiple: true, isHardDelete: isHardDelete),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently removes all records from [$tableName] that have been marked as soft-deleted.
  ///
  /// This maintenance utility executes a destructive cleanup operation to reclaim storage space
  /// and enforce data retention policies. It is intended for automated background maintenance cycles.
  ///
  /// * Validates that the entity supports soft-deletion via the [FluentSoftDeletable] mixin.
  /// * Triggers a global system-level task to bypass standard user-facing operation queues.
  /// * Performs a physical row deletion, rendering affected records irrecoverable.
  ///
  /// [policy] defines prioritization, concurrency controls, and task tagging for the engine.
  ///
  /// Returns a [Future<int>] yielding the total number of physical rows permanently removed
  /// from the database during this purge operation.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Execute a background purge of the 'User' table to clean up expired/deleted entries
  /// final int rowsPurged = await userRepository.purgeSoftDeleted(
  ///   policy: const ExecutionPolicy(priority: TaskPriority.background),
  /// );
  /// ```
  @internal
  Future<int> purgeSoftDeleted({ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Database soft-delete purge rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:purgeSoftDeleted',
        hint: 'Only models with soft-delete capabilities can be purged. Ensure your model implements the FluentSoftDeletable interface.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating soft-deleted record retention purge sequence',
      tag: '$tableName:purgeSoftDeleted',
      context: {'tableName': tableName, 'policy': policy.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(action: FluentDbAction.purgeSoftDeleted, table: tableName, dbName: dbName ?? this.dbName, isSystem: true, helper: TableHelper(multiple: true), policy: policy);

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently and forcefully removes all soft-deleted records from [$tableName], ignoring any retention period.
  ///
  /// This utility executes an immediate, destructive cleanup operation acting as an "Empty Trash" function.
  /// Unlike [purgeSoftDeleted], which respects configured time constraints, this method physically deletes
  /// all records currently residing in the soft-delete state.
  ///
  /// * Validates that the entity supports soft-deletion via the [FluentSoftDeletable] mixin.
  /// * Triggers a global system-level task to bypass standard user-facing operation queues.
  /// * Performs a physical row deletion, rendering affected records entirely irrecoverable.
  ///
  /// [policy] defines prioritization, concurrency controls, and task tagging for the engine.
  ///
  /// Returns a [Future<int>] yielding the total number of physical rows permanently removed
  /// from the database during this forced purge operation.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Forcefully clear all soft-deleted users immediately
  /// final int clearedItems = await userRepository.forcePurgeSoftDeleted(
  ///   policy: const ExecutionPolicy(priority: TaskPriority.background),
  /// );
  /// ```
  @internal
  Future<int> forcePurgeSoftDeleted({ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Database force-purge rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:forcePurgeSoftDeleted',
        hint: 'The force-purge operation is only applicable to models supporting soft-delete.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating forced physical purge of all soft-deleted records',
      tag: '$tableName:forcePurgeSoftDeleted',
      context: {'tableName': tableName, 'policy': policy.toString(), 'bypassRetention': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.forcePurgeSoftDeleted,
      table: tableName,
      dbName: dbName ?? this.dbName,
      isSystem: true,
      helper: TableHelper(multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Safely and concurrently removes a collection of domain entities.
  ///
  /// This batch operation extracts the primary keys from the provided [items]
  /// and routes them to the optimized [deleteItemsByIds] engine worker. It
  /// leverages efficient set-based lookups and chunked execution to ensure
  /// transactional integrity and performance during mass deletions.
  ///
  /// * **Efficiency:** Automatically transforms the iterable into a unique [Set]
  ///   of identifiers to prevent redundant database I/O.
  /// * **Safety:** If the collection is empty, the operation returns `0`
  ///   immediately, bypassing the task scheduler.
  /// * **Execution:** Dispatches a single unified [FluentTask] for the entire
  ///   collection, allowing the [FluentEngine] to optimize the deletion order.
  ///
  /// [items] The collection of domain entities to be removed.
  /// [policy] Defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] representing the total number of records successfully
  /// processed (soft-deleted) by the operation.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Safely remove a batch of stale cache entries
  /// final List<CacheEntry> staleEntries = await cacheRepository.findItemsBy({'status': 'expired'});
  /// final int count = await cacheRepository.deleteAll(
  ///   staleEntries,
  /// );
  ///
  /// print('Successfully deleted $count entries.');
  /// ```
  @internal
  Future<int> deleteAll(Iterable<T> items, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (items.isEmpty) {
      FluentLog.warning(
        'Batch delete aborted: input collection is empty',
        tag: '$tableName:deleteAll',
        hint: 'Ensure that the provided iterable contains at least one entity.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    final Set<dynamic> ids = items.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();

    if (ids.isEmpty) {
      FluentLog.warning(
        'Batch delete aborted: no valid primary keys resolved',
        tag: '$tableName:deleteAll',
        hint: 'Verify that the provided entities are properly initialized with primary keys.',
        context: {'tableName': tableName, 'totalItemsProvided': items.length},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating batch deletion pipeline',
      tag: '$tableName:deleteAll',
      context: {'tableName': tableName, 'uniqueIdsCount': ids.length, 'totalItemsProvided': items.length, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    return deleteItemsByIds(ids, policy: policy, dbName: dbName);
  }

  /// Permanently and completely removes a collection of domain entities from storage.
  ///
  /// This batch operation extracts the primary keys from the provided [items]
  /// and routes them through the physical [hardDeleteItemsByIds] destruction pipeline.
  /// Unlike [deleteAll], this bypasses the soft-delete layer, rendering the records
  /// irrecoverable.
  ///
  /// * **Irreversible:** Records are physically purged from the database table.
  ///   This is ideal for GDPR compliance or immediate cleanup of sensitive/stale data.
  /// * **Efficiency:** Maps input items into a unique [Set] of primary keys, minimizing
  ///   the number of SQL `DELETE` commands issued to the storage engine.
  /// * **Relational Cleanup:** Triggers the underlying relational cascade, ensuring
  ///   that orphaned records in dependent tables are also cleaned up.
  ///
  /// [items] The collection of domain entities to be permanently purged.
  /// [policy] Defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] representing the total number of physical rows
  /// successfully removed from the database.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Permanently wipe all data related to a user's deleted account
  /// final List<SensitiveLog> logs = await logRepository.findItemsBy({'user_id': userId});
  /// final int purgedCount = await logRepository.hardDeleteAll(
  ///   logs,
  ///   policy: const ExecutionPolicy.background,
  /// );
  ///
  /// print('Permanently erased $purgedCount sensitive records.');
  /// ```
  @internal
  Future<int> hardDeleteAll(Iterable<T> items, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (items.isEmpty) {
      FluentLog.warning(
        'Hard-delete batch aborted: input collection is empty',
        tag: '$tableName:hardDeleteAll',
        hint: 'Ensure that the provided iterable contains at least one entity.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    final Set<dynamic> ids = items.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();

    if (ids.isEmpty) {
      FluentLog.warning(
        'Hard-delete batch aborted: no valid primary keys resolved',
        tag: '$tableName:hardDeleteAll',
        hint: 'Verify that the provided entities are properly initialized with primary keys.',
        context: {'tableName': tableName, 'totalItemsProvided': items.length},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating batch physical destruction pipeline',
      tag: '$tableName:hardDeleteAll',
      context: {'tableName': tableName, 'uniqueIdsCount': ids.length, 'totalItemsProvided': items.length, 'bypassSoftDelete': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    return hardDeleteItemsByIds(ids, policy: policy, dbName: dbName);
  }

  /// Permanently removes the provided [item] from the database.
  ///
  /// This operation bypasses the soft-delete layer and executes a physical `DELETE`
  /// statement based on the entity's primary key. It is the definitive way to remove
  /// an object instance from storage, rendering it irrecoverable.
  ///
  /// * **Preparation:** Automatically extracts the primary key from the item using
  ///   the internal schema mapping.
  /// * **Safety:** If the primary key is missing, the operation is aborted, and 0
  ///   is returned to prevent accidental null-reference deletions.
  /// * **Execution:** Dispatches a destructive [FluentTask] to the engine coordinator
  ///   for immediate physical removal.
  ///
  /// [item] the model instance to be physically purged from the table.
  /// [policy] defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] yielding 1 if the record was purged, or 0 if the
  /// identity key could not be resolved.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Permanently remove a specific user object from the database
  /// final User user = await userRepository.findFirst(where: 'username = ?', whereArgs: ['john_doe']);
  /// if (user != null) {
  ///   await userRepository.hardDelete(user);
  ///   print('User record permanently removed.');
  /// }
  /// ```
  @internal
  Future<int> hardDelete(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final dynamic id = item.primaryKeyValue;

    if (id == null) {
      FluentLog.warning(
        'Hard-delete operation rejected: unassigned identity bounds',
        tag: '$tableName:hardDelete',
        hint: 'The provided entity does not have a primary key. Hard-delete requires a valid identity to target the specific row.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating physical row destruction',
      tag: '$tableName:hardDelete',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'bypassSoftDelete': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.hardDelete,
      table: tableName,
      dbName: dbName ?? this.dbName,
      data: item,
      helper: TableHelper(id: id, multiple: false, isHardDelete: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently removes a single record from the database identified by its primary key.
  ///
  /// This operation is destructive and bypasses the soft-delete layer, effectively
  /// erasing the record from storage. It is the primary method for sensitive data
  /// cleanup or fulfilling data deletion requests (e.g., GDPR "Right to be Forgotten").
  ///
  /// * The operation is dispatched as a standalone [FluentTask] to the engine coordinator.
  /// * It ignores any `deleted_at` status and executes a physical `DELETE` SQL statement.
  ///
  /// [id] specifies the unique primary key of the record to be removed.
  /// [policy] defines prioritization, concurrency, and execution controls.
  ///
  /// Returns a [Future<int>] yielding 1 if the record was successfully purged,
  /// or 0 if no record with the specified ID was found.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Permanently delete a specific user profile
  /// final int result = await userRepository.hardDeleteById(
  ///   user.id,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// if (result > 0) {
  ///   print('User record permanently erased.');
  /// }
  /// ```
  @internal
  Future<int> hardDeleteById(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (id == null) {
      FluentLog.warning(
        'Hard-delete-by-id operation rejected: invalid identity',
        tag: '$tableName:hardDeleteById',
        hint: 'The provided primary key is null. A valid identity is  for physical removal.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating physical row destruction by primary key',
      tag: '$tableName:hardDeleteById',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'bypassSoftDelete': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.hardDelete,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(id: id, multiple: false, isHardDelete: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently removes records from [$tableName] matching a custom SQL [where] clause.
  ///
  /// This method provides maximum flexibility for multi-condition pruning, bypassing
  /// any soft-delete mechanics to physically remove the rows from the storage engine.
  ///
  /// [where] The SQL WHERE clause (excluding the 'WHERE' keyword).
  /// [whereArgs] The arguments to bind to the placeholders in the [where] clause.
  /// [batch] Optional transaction batch to defer execution.
  /// [policy] Defines prioritization, concurrency, and task management configurations.
  @internal
  Future<int> hardDeleteWhere({required String where, List<Object?>? whereArgs, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (where.trim().isEmpty) {
      FluentLog.warning('Aborted hardDeleteWhere: empty condition', tag: '$tableName:hardDeleteWhere');
      return Future.value(0);
    }

    // SCENARIO A: BATCH
    if (batch != null) {
      batch.delete(tableName, where: where, whereArgs: whereArgs);
      return Future<int>.value(1);
    }

    // SCENARIO B: TRANSACTION
    if (_transactionExecutor != null) {
      return _rawDeleteWhereExecution(where, whereArgs, _transactionExecutor!, isHardDelete: true);
    }

    // SCENARIO C: TASK QUEUE
    final FluentTask task = FluentTask(
      action: FluentDbAction.hardDeleteWhere,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: where, arguments: whereArgs, multiple: true, isHardDelete: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently removes records from the database that match the specified criteria.
  ///
  /// This bulk operation performs a physical `DELETE` query based on a provided key-value pair,
  /// bypassing all soft-delete mechanisms. It is the most efficient way to prune data
  /// by a specific attribute (e.g., status, user_id, or type).
  ///
  /// The method optimizes execution based on the availability of an execution context:
  /// * **Batch Processing:** If a [batch] is provided, the operation is queued for
  ///   deferred execution within the batch context.
  /// * **Transaction Context:** If an active [_transactionExecutor] is detected,
  ///   the deletion is performed atomically within the transaction.
  /// * **Standalone Task:** If no context is provided, it dispatches an asynchronous
  ///   [FluentTask] to the engine coordinator for background execution.
  ///
  /// [value] defines the target value to match against the [key].
  /// [key] specifies the column to filter by (defaults to the primary key).
  /// [policy] defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] yielding the number of rows physically purged from storage.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Permanently remove all archived messages for a specific conversation
  /// final int purgedCount = await messageRepository.hardDeleteBy(
  ///   'conversation_123',
  ///   key: 'conversation_id',
  ///   policy: const ExecutionPolicy(priority: TaskPriority.normal),
  /// );
  /// ```
  @internal
  Future<int> hardDeleteBy(dynamic value, {String? key, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final String searchKey = key ?? (_cachedPrimaryKey?.name ?? 'id');

    if (batch != null) {
      FluentLog.debug('Queueing hard-delete-by operation into active batch', tag: '$tableName:hardDeleteBy', context: {'tableName': tableName, 'column': searchKey, 'value': value.toString()});
      batch.delete(tableName, where: '$searchKey = ?', whereArgs: [value]);
      return Future<int>.value(1);
    }

    if (_transactionExecutor != null) {
      FluentLog.debug('Executing transactional hard-delete-by', tag: '$tableName:hardDeleteBy', context: {'tableName': tableName, 'column': searchKey, 'value': value.toString()});
      return _rawDeleteByExecution(searchKey, value, _transactionExecutor!, isHardDelete: true);
    }

    FluentLog.debug(
      'Initiating hard-delete-by pipeline',
      tag: '$tableName:hardDeleteBy',
      context: {'tableName': tableName, 'column': searchKey, 'value': value.toString(), 'bypassSoftDelete': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.hardDeleteBy,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(key: searchKey, value: value, where: '$searchKey = ?', whereArgs: [value], multiple: true, isHardDelete: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Permanently removes a set of records from the database identified by their primary keys.
  ///
  /// This bulk operation performs a physical `DELETE` query, bypassing any soft-delete
  /// status or `deleted_at` filters. It is designed for high-performance cleanup
  /// and bulk removal of data.
  ///
  /// The method handles execution based on the current context:
  /// * **Shared Batch:** If a [sharedBatch] is provided, operations are queued
  ///   for batch processing within an existing transaction.
  /// * **Transaction Context:** If an active [_transactionExecutor] is detected,
  ///   the deletion is executed atomically within that transaction.
  /// * **Standalone Task:** If no transaction is active, it dispatches an
  ///   asynchronous [FluentTask] to the coordinator for execution.
  ///
  /// [ids] defines the unique identifiers of the records to be purged.
  /// [policy] defines prioritization, concurrency, and chunking controls.
  ///
  /// Returns a [Future<int>] yielding the number of rows successfully purged.
  /// Returns 0 if the provided set of IDs is empty.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Physically remove a list of sensitive or expired records
  /// final int deletedCount = await userRepository.hardDeleteItemsByIds(
  ///   {101, 102, 105},
  ///   policy: const ExecutionPolicy(chunkSize: 50),
  /// );
  /// ```
  @internal
  Future<int> hardDeleteItemsByIds(Set<dynamic> ids, {Batch? sharedBatch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (ids.isEmpty) {
      FluentLog.warning(
        'Hard-delete-by-ids aborted: identity set is empty',
        tag: '$tableName:hardDeleteItemsByIds',
        hint: 'Ensure that the provided Set of primary keys is populated.',
        context: {'tableName': tableName},
      );
      return Future<int>.value(0);
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    if (sharedBatch != null) {
      FluentLog.debug('Queueing hard-delete-by-ids into shared batch', tag: '$tableName:hardDeleteItemsByIds', context: {'tableName': tableName, 'count': ids.length, 'column': pkName});
      _executeDeleteChunks(sharedBatch, ids.toList(), policy.effectiveChunkSize, pkName, isHardDelete: true);
      return Future<int>.value(1);
    }

    if (_transactionExecutor != null) {
      FluentLog.debug('Executing transactional hard-delete-by-ids', tag: '$tableName:hardDeleteItemsByIds', context: {'tableName': tableName, 'count': ids.length, 'column': pkName});
      return _rawBatchDeleteExecution(ids.toList(), pkName, _transactionExecutor!, policy, isHardDelete: true);
    }

    FluentLog.debug(
      'Initiating batch physical destruction pipeline',
      tag: '$tableName:hardDeleteItemsByIds',
      context: {'tableName': tableName, 'count': ids.length, 'bypassSoftDelete': true, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.hardDeleteItemsByIds,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(where: '$pkName IN (...)', arguments: ids.toList(), multiple: true, isHardDelete: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
