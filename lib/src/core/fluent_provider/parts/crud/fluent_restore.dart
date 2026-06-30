// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe restoration primitives for
/// [FluentStorable] entities.
///
/// The [FluentRestore] extension provides specialized recovery mechanisms for entities that
/// implement the [FluentSoftDeletable] mixin. It abstracts the logic of toggling the
/// soft-delete state, allowing for the seamless reversal of deletion actions without
/// permanent data loss or relational fragmentation.
///
/// ### Core Architecture & Restoration Paradigms
/// Operations within this extension are designed to restore data to its prior active state
/// while ensuring that business logic constraints and relational links remain consistent:
///
/// * **State Reversion Logic:** Methods like [restore] and [restoreById] perform a surgical
///   update, resetting the [FluentSoftDeletable.softDeleteColumn] to null. This effectively
///   moves the record from the "trash" back into the active dataset, making it immediately
///   available for standard queries.
/// * **Transactional Integrity:** All restoration tasks are routed through the [FluentDb]
///   orchestration layer. Whether performed as an individual entity update or a bulk
///   transactional batch, the operation respects transactional boundaries and consistency
///   guarantees.
/// * **Type-Safe Contract Enforcement:** This extension acts as a gateway for reversible
///   operations. By requiring entities to mixin [FluentSoftDeletable], the architecture
///   guarantees that only data structures equipped with the necessary tracking metadata
///   can participate in these workflows.
///
/// ### Execution Routing
/// Every restoration method creates a [FluentTask], which is dispatched to the centralized
/// [FluentDb] engine. This ensures that restoration routines respect [ExecutionPolicy]
/// constraints, allowing you to prioritize critical data recovery without inducing
/// performance bottlenecks in the UI thread.
///
/// See also:
/// * [FluentSoftDeletable], the mandatory contract for reversible entities.
/// * [FluentEngine], which orchestrates the transactional safety of these tasks.
/// * [ExecutionPolicy], which defines concurrency and priority controls for restoration tasks.
extension FluentRestore<T extends FluentStorable> on FluentProvider<T> {
  /// Restores a previously soft-deleted record, making it active again.
  ///
  /// This operation performs an atomic update on the database to reset the
  /// [FluentSoftDeletable.softDeleteColumn] to `null`. It is the standard way to
  /// "undo" a soft-delete and bring an entity back into the active dataset.
  ///
  /// * **Persistence:** The method dynamically extracts the primary key from the
  ///   [item] and delegates the restoration to the engine coordinator.
  /// * **Safety:** If the entity is not a soft-deletable type or the primary key
  ///   cannot be resolved, the operation safely aborts.
  ///
  /// [item] the model instance to be restored.
  /// [policy] defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] yielding 1 if the record was successfully restored,
  /// or 0 if no record was updated (e.g., entity already active or not found).
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Restore an archived product record
  /// final int count = await productRepository.restore(archivedProduct);
  ///
  /// if (count > 0) {
  ///   print('Product restored successfully.');
  /// }
  /// ```
  @internal
  Future<int> restore(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Restore operation rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:restore',
        hint: 'Only models supporting soft-deletion can be restored.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    final dynamic id = item.primaryKeyValue;

    if (id == null) {
      FluentLog.warning(
        'Restore operation rejected: unassigned identity bounds',
        tag: '$tableName:restore',
        hint: 'The provided entity lacks a primary key. Cannot restore an object without a valid database identity.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug('Redirecting restore request to internal identity-based pipeline', tag: '$tableName:restore', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    return restoreById(id, policy: policy, dbName: dbName);
  }

  /// Restores a soft-deleted record identified by its primary key.
  ///
  /// This operation performs an atomic update on the database to reset the
  /// [FluentSoftDeletable.softDeleteColumn] to `null`, effectively moving the
  /// record from the "trash" back into the active dataset.
  ///
  /// * **Type Guard:** Ensures the model implements the [FluentSoftDeletable] mixin;
  ///   if not, the operation is ignored and returns 0.
  /// * **Persistence:** Dispatches an update task to the engine coordinator to
  ///   nullify the deletion timestamp/flag.
  ///
  /// [id] specifies the unique primary key of the record to be restored.
  /// [policy] defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<int>] yielding 1 if the record was successfully restored,
  /// or 0 if no record was found or the model does not support soft-deletion.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Restore a specific archived product by its ID
  /// final int restored = await productRepository.restoreById(
  ///   123,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.normal),
  /// );
  ///
  /// if (restored > 0) {
  ///   print('Record 123 is now active.');
  /// }
  /// ```
  @internal
  Future<int> restoreById(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Restore operation rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:restoreById',
        hint: 'Only models supporting soft-deletion can be restored.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    if (id == null) {
      FluentLog.warning('Restore operation rejected: invalid identity', tag: '$tableName:restoreById', hint: 'A valid primary key is required to restore a record.', context: {'tableName': tableName});
      return Future.value(0);
    }

    final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;

    FluentLog.debug(
      'Initiating soft-delete restoration sequence',
      tag: '$tableName:restoreById',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'softDeleteColumn': col, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.restore,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(id: id, key: col, value: null, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Restores a soft-deleted entity by its [id] and returns the updated instance.
  ///
  /// This method performs an atomic-like sequence: it first flips the soft-delete flag
  /// for the specified record, and if successful, immediately fetches the restored
  /// entity from the storage engine.
  ///
  /// If the entity does not support [FluentSoftDeletable] or the record does not
  /// exist/cannot be restored, this method returns `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Attempt to restore a user and receive the refreshed entity instance
  /// final User? restoredUser = await userRepository.restoreAndFetchById(
  ///   userId,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// if (restoredUser != null) {
  ///   print('Successfully restored user: ${restoredUser.username}');
  /// } else {
  ///   print('Failed to restore user: record not found or already active.');
  /// }
  /// ```
  ///
  /// [id] The primary key of the record to restore.
  /// [policy] The [ExecutionPolicy] to control concurrency and priority of the operations.
  ///
  /// Returns a [Future<T?>] resolving to the restored entity or `null` on failure.
  @internal
  Future<T?> restoreAndFetchById(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) async {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Restore-and-fetch operation rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:restoreAndFetchById',
        hint: 'Only models supporting soft-deletion can be restored.',
        context: {'tableName': tableName},
      );
      return null;
    }

    if (id == null) {
      FluentLog.warning(
        'Restore-and-fetch operation rejected: invalid identity',
        tag: '$tableName:restoreAndFetchById',
        hint: 'A valid primary key is required to perform restoration and retrieval.',
        context: {'tableName': tableName},
      );
      return null;
    }

    FluentLog.debug('Initiating restore-and-fetch sequence', tag: '$tableName:restoreAndFetchById', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    final int rowsAffected = await restoreById(id, policy: policy, dbName: dbName);

    if (rowsAffected > 0) {
      FluentLog.debug('Restoration successful, fetching recovered entity', tag: '$tableName:restoreAndFetchById', context: {'tableName': tableName, 'targetRecordId': id.toString()});
      return await findById(id, policy: policy, dbName: dbName);
    }

    FluentLog.debug('Restore-and-fetch aborted: no records were restored', tag: '$tableName:restoreAndFetchById', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    return null;
  }

  /// Restores a soft-deleted entity and returns its refreshed, up-to-date instance
  /// from the database.
  ///
  /// This method simplifies the recovery workflow by combining two operations:
  /// 1. Executes a [restore] command to flip the soft-delete flag.
  /// 2. If the restoration was successful (at least one row affected), it immediately
  ///    performs a [findById] lookup to retrieve the entity with the current database state.
  ///
  /// If the entity does not implement [FluentSoftDeletable], the item lacks a primary
  /// key, or the record cannot be restored, this method returns `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Recover an archived entity and immediately work with the restored state
  /// final User? user = await userRepository.restoreAndFetch(
  ///   archivedUser,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// if (user != null) {
  ///   print('Successfully restored: ${user.username} (ID: ${user.id})');
  /// } else {
  ///   print('Restoration failed: entity might be already active or non-existent.');
  /// }
  /// ```
  ///
  /// [item] The entity instance to restore.
  /// [policy] The [ExecutionPolicy] defining task priority and concurrency controls.
  ///
  /// Returns a [Future<T?>] resolving to the fresh entity instance or `null` if the
  /// operation could not be completed.
  @internal
  Future<T?> restoreAndFetch(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) async {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Restore-and-fetch operation rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:restoreAndFetch',
        hint: 'Only models supporting soft-deletion can be restored.',
        context: {'tableName': tableName},
      );
      return null;
    }

    final dynamic id = item.primaryKeyValue;
    if (id == null) {
      FluentLog.warning(
        'Restore-and-fetch operation rejected: unassigned identity bounds',
        tag: '$tableName:restoreAndFetch',
        hint: 'Cannot perform restore-and-fetch on an entity without a valid primary key.',
        context: {'tableName': tableName},
      );
      return null;
    }

    FluentLog.debug('Initiating restore-and-fetch sequence for entity', tag: '$tableName:restoreAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    final int rowsAffected = await restore(item, policy: policy, dbName: dbName);

    if (rowsAffected > 0) {
      FluentLog.debug('Restoration successful, fetching refreshed entity state', tag: '$tableName:restoreAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});
      return await findById(id, policy: policy, dbName: dbName);
    }

    FluentLog.debug('Restore-and-fetch aborted: no rows were affected by restoration', tag: '$tableName:restoreAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    return null;
  }

  /// Restores a batch of soft-deleted entities from the provided collection.
  ///
  /// This method performs a bulk recovery operation. It extracts the primary keys
  /// from the provided [items], filters out invalid or null identifiers, and
  /// dispatches a single batch restoration task to the storage engine.
  ///
  /// The operation is idempotent—duplicate IDs are automatically deduplicated
  /// before processing. If the model does not implement [FluentSoftDeletable]
  /// or no valid primary keys can be resolved, the method aborts and returns `0`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Recover a set of archived items and update their status in the database
  /// final int restoredCount = await productRepository.restoreAll(
  ///   archivedProducts,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// print('Successfully restored $restoredCount items from the archive.');
  /// ```
  ///
  /// [items] The collection of entities to be restored.
  /// [policy] The [ExecutionPolicy] defining concurrency controls and task priority.
  ///
  /// Returns a [Future<int>] representing the number of batch operations performed
  /// (typically `1` for a successful batch dispatch, or `0` if aborted).
  @internal
  Future<int> restoreAll(Iterable<T> items, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Batch restore rejected: model does not implement FluentSoftDeletable',
        tag: '$tableName:restoreAll',
        hint: 'Only models supporting soft-deletion can be restored in batch.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    if (items.isEmpty) {
      FluentLog.warning(
        'Batch restore aborted: input collection is empty',
        tag: '$tableName:restoreAll',
        hint: 'Ensure that the provided iterable contains at least one entity to restore.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    final Set<dynamic> ids = items.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();

    if (ids.isEmpty) {
      FluentLog.warning(
        'Batch restore aborted: no valid primary keys resolved',
        tag: '$tableName:restoreAll',
        hint: 'Verify that the provided entities are properly initialized with primary keys.',
        context: {'tableName': tableName, 'totalItemsProvided': items.length},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating batch restoration sequence',
      tag: '$tableName:restoreAll',
      context: {'tableName': tableName, 'uniqueIdsCount': ids.length, 'totalItemsProvided': items.length, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    return restoreItemsByIds(ids, policy: policy, dbName: dbName);
  }

  /// Performs a batch restoration of soft-deleted entities identified by the provided set of [ids].
  ///
  /// This method serves as the low-level engine for bulk recovery operations. It intelligently
  /// routes the restoration request based on the current execution context:
  /// * **Shared Batch:** Queues restoration commands into an existing [Batch] for atomic submission.
  /// * **Transactional:** Executes the restoration within an isolated transaction.
  /// * **Standard Pipeline:** Dispatches a [FluentTask] to the engine for prioritized,
  ///   policy-compliant execution.
  ///
  /// The operation is only valid for models implementing [FluentSoftDeletable]. If the model
  /// does not support soft-deletion, or if no valid IDs are provided, the method silently aborts.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Recover a specific set of entities by their primary keys
  /// final Set<dynamic> idsToRestore = {101, 102, 105};
  /// final int result = await userRepository.restoreItemsByIds(
  ///   idsToRestore,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// if (result > 0) {
  ///   print('Successfully dispatched restoration for $result batches/items.');
  /// }
  /// ```
  ///
  /// [ids] A set of unique primary keys of the entities to restore.
  /// [sharedBatch] An optional [Batch] instance to participate in a shared transactional commit.
  /// [policy] The [ExecutionPolicy] managing concurrency and execution constraints.
  ///
  /// Returns a [Future<int>] representing the success status or the count of affected operations.
  @internal
  Future<int> restoreItemsByIds(Set<dynamic> ids, {Batch? sharedBatch, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning('Batch restore rejected: model does not implement FluentSoftDeletable', tag: '$tableName:restoreItemsByIds', context: {'tableName': tableName});
      return Future.value(0);
    }

    if (ids.isEmpty) return Future.value(0);

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;

    // SCENARIO A: SHARED BATCH CONTEXT
    if (sharedBatch != null) {
      FluentLog.debug('Queueing batch restoration into shared batch', tag: '$tableName:restoreItemsByIds', context: {'tableName': tableName, 'count': ids.length, 'column': col});
      _executeRestoreChunks(sharedBatch, ids.toList(), policy.effectiveChunkSize, pkName, col);
      return Future.value(1);
    }

    // SCENARIO B: ACTIVE TRANSACTION CONNECTION
    if (_transactionExecutor != null) {
      FluentLog.debug('Executing transactional batch restoration', tag: '$tableName:restoreItemsByIds', context: {'tableName': tableName, 'count': ids.length, 'column': col});
      final Batch batch = _transactionExecutor!.batch();
      _executeRestoreChunks(batch, ids.toList(), policy.effectiveChunkSize, pkName, col);
      return batch.commit().then((results) => results.whereType<int>().fold<int>(0, (a, b) => a + b));
    }

    // SCENARIO C: STANDARD TASK SCHEDULER
    FluentLog.debug(
      'Initiating batch restoration pipeline',
      tag: '$tableName:restoreItemsByIds',
      context: {'tableName': tableName, 'count': ids.length, 'column': col, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.restoreItemsByIds,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(key: col, where: '$pkName IN (...)', arguments: ids.toList(), multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
