// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe update operations for [FluentStorable] entities.
///
/// The [FluentUpdate] extension establishes a robust pipeline for mutating records within the
/// storage engine. It abstracts the complexities of differential state reconciliation,
/// relational graph synchronization, and transactional isolation, ensuring that every modification
/// is applied atomically, consistently, and with high performance.
///
/// ### Core Architecture & Mutation Paradigms
/// Update operations in this extension follow a rigorous lifecycle designed to maintain
/// data integrity and optimize system throughput:
///
/// * **Differential State Reconciliation:** The extension intelligently identifies modifications,
///   minimizing I/O overhead by targeting only changed attributes where the engine permits.
///   This preserves index integrity and reduces fragmentation.
/// * **Relational Graph Integrity:** Beyond simple attribute mutation, [FluentUpdate] propagates
///   changes across dependent associations. It manages foreign key re-mapping and dependency
///   invalidation, preventing orphaned pointers or relational drift.
/// * **Transactional Atomicity:** All mutations are dispatched through the [FluentDb] orchestrator
///   with strict isolation guarantees. This ensures that concurrent updates are handled safely,
///   preventing race conditions and protecting the system from partial write states.
/// * **Policy-Driven Concurrency:** To maintain optimal UI responsiveness, high-impact update
///   tasks (such as bulk modifications or deep relational sync) are offloaded to background
///   isolates. The [ExecutionPolicy] allows precise control over priority, batching strategies,
///   and concurrency limits.
/// * **Observability & Diagnostics:** Every mutation event is integrated into the central
///   diagnostic facade. By tracking identity-based performance metrics and operation duration,
///   the system provides granular visibility into write-behavior without the overhead of
///   manual string-based logging.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [ExecutionPolicy], which manages concurrency levels and transaction-time limits.
/// * [FluentStorable], the base entity contract required for persistence.
extension FluentUpdate<T extends FluentStorable> on FluentProvider<T> {
  /// Commits internal structural modifications of a typed object [item] back into the [$tableName] storage engine.
  ///
  /// This operational modification pipeline first serializes the target object into a primitive database map,
  /// extracts its corresponding primary identity key properties, and evaluates structural validation bounds:
  /// * Aborts instantly with an explicitly raised [ArgumentError] and fires [FluentLog.error] if identity keys are missing.
  /// * Encapsulates valid state modifications into a unified [FluentTask] for secure thread routing.
  ///
  /// [item] represents the modified data model entity carrying the updated state values.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when changes are securely written into the data layer.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final updatedUser = activeUser.copyWith(email: 'new.email@domain.com');
  ///
  /// await userRepository.update(
  ///   updatedUser,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: false, // Modifications must always execute atomically without deduplication
  ///   ),
  /// );
  /// ```
  @internal
  Future<int> update(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    final Map<String, dynamic> preparedData = _prepareSqlJson(item);
    final dynamic id = preparedData[pkName];

    if (id == null) {
      final FluentArgumentException exception = FluentArgumentException(tableName, 'Target update identifier evaluated to null"', StackTrace.current);

      FluentLog.error(
        'Database update operations rejected due to unassigned identity bounds',
        exception,
        StackTrace.current,
        tag: '$tableName:exception:update',
        hint:
            'Verify your model attributes possess valid database entity assignments before committing modifications. Unassigned or auto-incrementing identity values must be inserted before they can be updated.',
        context: {'tableName': tableName, 'expectedPrimaryKeyColumn': pkName},
      );

      return Future<int>.error(exception);
    }
    FluentLog.debug(
      'Initiating localized query pipeline for single-row structural table update modification',
      tag: '$tableName:update',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.update,
      table: tableName,
      dbName: dbName ?? this.dbName,
      data: item,
      helper: TableHelper(id: id, dataMap: preparedData, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Modifies a singular specific column cell property on a record inside [$tableName] matching [id].
  ///
  /// This targeted field modification pipeline performs early defensive validation checking:
  /// * Evaluates [updateKey] against [tableColumns] to catch schema compatibility mismatches early.
  /// * Aborts gracefully and registers a [FluentLog.warning] if the target column does not exist in the schema.
  /// * Encapsulates the verified individual field change criteria into a secure [FluentTask] framework wrapper.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [updateKey] specifies the exact physical string column name to modify inside the record database table.
  /// [updateValue] represents the updated primitive data state payload to insert into the targeted cell.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes safely when the target column write sequence completes.
  ///
  /// ### Usage Example:
  /// ```dart
  /// await userRepository.updateByKey(
  ///   'usr_772x11',
  ///   'is_verified',
  ///   true
  /// );
  /// ```
  @internal
  Future<int> updateByKey(dynamic id, String updateKey, dynamic updateValue, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    if (!tableColumns.contains(updateKey)) {
      FluentLog.warning(
        'Database structural mutation rejected due to non-existent schema column property',
        tag: '$tableName:schema:updateByKey',
        hint: 'Verify your lookup or update key mappings. Triggering alterations against invalid columns will cause structural SQLite syntax runtime exceptions.',
        context: {'tableName': tableName, 'attemptedColumnKey': updateKey, 'targetRecordId': id.toString(), 'availableColumns': tableColumns.toList()},
      );
      return Future<int>.value(0);
    }

    FluentLog.debug(
      'Initiating localized query pipeline for single-field target cell mutation',
      tag: '$tableName:updateByKey',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetColumnField': updateKey, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateSingleField,

      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(id: id, key: updateKey, value: updateValue, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Modifies a discrete, targeted subset collection of column properties on a record inside [$tableName] matching [id].
  ///
  /// This performance-tuned, multi-field partial modification pipeline performs early defensive checks:
  /// * Evaluates if the incoming [fields] payload map is empty, immediately returning an accelerated [Future.value] fast-path.
  /// * Encapsulates the partial update payload elements into a uniform [FluentTask] for secure thread-routing.
  /// * Leaves unspecified columns untouched, preserving original states inside unmapped record cells.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [fields] represents a dictionary structure containing the specific property keys and corresponding values to overwrite.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the targeted batch mutations are securely written.
  ///
  /// ### Usage Example:
  /// ```dart
  /// await userRepository.updateFieldsMultiple(
  ///   'usr_901a23',
  ///   {
  ///     'failed_login_attempts': 0,
  ///     'last_authenticated_at': DateTime.now().millisecondsSinceEpoch,
  ///     'account_status': 'ACTIVE',
  ///   },
  /// );
  /// ```
  @internal
  Future<int> updateFieldsMultiple(dynamic id, Map<String, dynamic> fields, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (fields.isEmpty) {
      return Future<int>.value(0);
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Initiating localized query pipeline for targeted subset row properties mutation',
      tag: '$tableName:updateFieldsMultiple',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetFieldsKeys': fields.keys.toList(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateMultipleFields,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(id: id, dataMap: fields, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Performs a deep update of an entity and its associated relational graph.
  ///
  /// Unlike standard [update] operations that may target only the root entity, this
  /// method triggers a synchronization sequence that flattens the entity into a
  /// SQL-compatible structure and attempts to persist the current state of
  /// the entire relational dependency graph.
  ///
  /// This method is intended for complex domain models where updating an entity
  /// requires keeping its nested relations (e.g., linked profiles, settings, or
  /// secondary associations) in strict database synchronization.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Update a user profile including all linked relational data (e.g., settings)
  /// try {
  ///   final rowsAffected = await userRepository.updateWithRelations(
  ///     updatedUser,
  ///     policy: const ExecutionPolicy(priority: TaskPriority.high),
  ///   );
  ///   print('Successfully synchronized $rowsAffected records.');
  /// } on FluentSchemaException catch (e) {
  ///   print('Failed to update: ${e.details}');
  /// }
  /// ```
  ///
  /// [item] The entity instance to update.
  /// [policy] The [ExecutionPolicy] managing concurrency and execution constraints.
  ///
  /// Returns a [Future<int>] representing the number of rows affected by the update.
  /// Throws a [FluentSchemaException] if the entity lacks a valid primary key.
  Future<int> updateWithRelations(T item, {FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    // Transform model entity into a flattened SQL-compatible map structure
    final Map<String, dynamic> preparedData = _prepareSqlJson(item);

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final dynamic id = preparedData[pkName];

    if (id == null) {
      final FluentSchemaException exception = FluentSchemaException(
        modelName: tableName,
        columnName: pkName,
        details: 'Database transactional update aborted due to missing primary key constraint',
        stackTrace: StackTrace.current,
      );
      FluentLog.error(
        exception.message,
        exception,
        exception.stackTrace,
        tag: '$tableName:exception:updateWithRelations',
        hint: 'Ensure that the model entity possesses a valid and initialized primary key value before attempting persistence.',
        context: {'tableName': tableName, 'primaryKeyColumn': pkName},
      );
      throw exception;
    }

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateWithRelations,
      table: tableName,
      dbName: dbName ?? this.dbName,
      data: item,
      relations: [preparedData],
      helper: TableHelper(id: id, dataMap: preparedData, syncMode: syncMode),
      policy: policy,
    );

    FluentLog.debug(
      'Initiating deep model update synchronization sequence with relational dependency resolution',
      tag: '$tableName:updateWithRelations',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Performs a transactional batch update of multiple entities along with their relational graphs.
  ///
  /// This method is highly optimized for bulk state reconciliation of complex domain models.
  /// It segregates core table fields from relational dependencies, updating the root entities
  /// via a fast SQL [Batch], and subsequently passes the entire collection to the relational
  /// engine for batched graph synchronization.
  ///
  /// [items] The collection of entities to update.
  /// [syncMode] Determines how nested relations are merged (e.g., preserving local children or replacing them).
  /// [policy] The [ExecutionPolicy] defining task priority and concurrency constraints.
  @internal
  Future<int> updateAllWithRelations(Iterable<T> items, {FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (items.isEmpty) {
      FluentLog.warning('Batch relational update aborted: input collection is empty', tag: '$tableName:updateAllWithRelations', context: {'tableName': tableName});
      return Future.value(0);
    }

    final List<T> itemList = items.toList(growable: false);

    final List<Map<String, dynamic>> preparedJsons = List.generate(itemList.length, (i) => _prepareSqlJson(itemList[i]), growable: false);

    FluentLog.debug('Initiating batch deep-model update synchronization sequence', tag: '$tableName:updateAllWithRelations', context: {'tableName': tableName, 'itemsCount': itemList.length});

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateAllWithRelations,
      table: tableName,
      dbName: dbName ?? this.dbName,
      data: itemList,
      relations: preparedJsons,
      helper: TableHelper(multiple: true, syncMode: syncMode),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Updates an entity and immediately retrieves its refreshed state from the database.
  ///
  /// This method provides a "write-then-read" orchestration, which is particularly
  /// useful for entities containing fields managed by the database (e.g., auto-generated
  /// timestamps, version numbers, or computed defaults). It first executes an
  /// [update] on the provided [item] and, if the operation is successful, performs
  /// a follow-up [findById] to return the exact database-persisted state.
  ///
  /// If the entity lacks a valid primary key, or if the update affects zero rows
  /// (e.g., the record was deleted or already synchronized), this method returns `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Update a product and retrieve the newly updated state with refreshed metadata
  /// final Product? updatedProduct = await productRepository.updateAndFetch(
  ///   product,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// if (updatedProduct != null) {
  ///   print('Product updated successfully. New version: ${updatedProduct.version}');
  /// } else {
  ///   print('Failed to update product: record not found or no changes applied.');
  /// }
  /// ```
  ///
  /// [item] The entity instance to update.
  /// [policy] The [ExecutionPolicy] defining task priority and concurrency controls.
  ///
  /// Returns a [Future<T?>] resolving to the fresh entity instance or `null` if the
  /// operation could not be completed.
  @internal
  Future<T?> updateAndFetch(T item, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) async {
    final dynamic id = item.primaryKeyValue;

    if (id == null) {
      FluentLog.warning(
        'Update-and-fetch operation rejected: unassigned identity bounds',
        tag: '$tableName:updateAndFetch',
        hint: 'Cannot perform update-and-fetch on an entity without a valid primary key.',
        context: {'tableName': tableName},
      );
      return null;
    }

    FluentLog.debug('Initiating update-and-fetch sequence', tag: '$tableName:updateAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    final int rowsAffected = await update(item, policy: policy, dbName: dbName);

    if (rowsAffected > 0) {
      FluentLog.debug('Update successful, fetching refreshed entity state', tag: '$tableName:updateAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});
      return await findById(id, policy: policy, dbName: dbName);
    }

    FluentLog.debug('Update-and-fetch aborted: no rows were affected by update', tag: '$tableName:updateAndFetch', context: {'tableName': tableName, 'targetRecordId': id.toString()});

    return null;
  }

  /// Updates a collection of entities in a single batch operation.
  ///
  /// This method provides an efficient way to synchronize multiple entities with
  /// the database. Instead of executing individual update statements, it packages
  /// all provided [items] into a single [FluentTask], which the storage engine
  /// processes as a unified batch operation.
  ///
  /// This is significantly faster for mass updates and ensures that the operation
  /// can be managed under a specific [ExecutionPolicy] (e.g., to control batch size,
  /// priority, or transactional grouping). If the input collection is empty, the
  /// method returns `0` without triggering any database activity.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Perform a bulk update on a list of modified products
  /// final int rowsAffected = await productRepository.updateAll(
  ///   modifiedProducts,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// print('Successfully synchronized $rowsAffected records with the database.');
  /// ```
  ///
  /// [items] The collection of entities to update.
  /// [policy] The [ExecutionPolicy] defining task priority, chunk sizes, and concurrency constraints.
  ///
  /// Returns a [Future<int>] representing the total count of rows affected by the batch operation.
  @internal
  Future<int> updateAll(Iterable<T> items, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (items.isEmpty) {
      FluentLog.warning(
        'Batch update aborted: input collection is empty',
        tag: '$tableName:updateAll',
        hint: 'Ensure that the provided iterable contains at least one entity to update.',
        context: {'tableName': tableName},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating batch update sequence',
      tag: '$tableName:updateAll',
      context: {'tableName': tableName, 'itemsCount': items.length, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateAll,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(arguments: items.toList(), multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Performs a bulk update on a specific set of fields for multiple entities identified by [ids].
  ///
  /// This method is an optimized alternative to updating entities individually. It dispatches
  /// a single [FluentTask] that executes a filtered `UPDATE` statement, modifying only
  /// the key-value pairs specified in [fields] for all records matching the provided [ids].
  ///
  /// This approach minimizes database round-trips and transaction overhead, making it ideal
  /// for bulk status changes (e.g., "mark all as read," "archive items," or "bulk update flags").
  /// If either the [ids] set or the [fields] map is empty, the operation aborts to prevent
  /// invalid or accidental bulk updates.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Bulk update the status and timestamp for a group of orders
  /// final int rowsAffected = await orderRepository.updateFieldsMultipleByIds(
  ///   {101, 102, 105},
  ///   {'status': 'processed', 'updated_at': DateTime.now().toIso8601String()},
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  ///
  /// print('Successfully updated $rowsAffected orders.');
  /// ```
  ///
  /// [ids] A set of unique primary keys to be updated.
  /// [fields] A map representing the fields to update and their new values.
  /// [policy] The [ExecutionPolicy] managing batch size, priority, and concurrency controls.
  ///
  /// Returns a [Future<int>] representing the number of records affected by the update.
  @internal
  Future<int> updateFieldsMultipleByIds(Set<dynamic> ids, Map<String, dynamic> fields, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (ids.isEmpty || fields.isEmpty) {
      FluentLog.warning(
        'Batch field update aborted: empty identifiers or fields map',
        tag: '$tableName:updateFieldsMultipleByIds',
        hint: 'Ensure that both the set of IDs and the fields map contain data.',
        context: {'tableName': tableName, 'idsCount': ids.length, 'fieldsCount': fields.length},
      );
      return Future.value(0);
    }

    FluentLog.debug(
      'Initiating batch field update sequence',
      tag: '$tableName:updateFieldsMultipleByIds',
      context: {'tableName': tableName, 'targetIdsCount': ids.length, 'fieldsUpdated': fields.keys.toList(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateMultipleFieldsByIds,
      table: tableName,
      dbName: dbName ?? this.dbName,
      helper: TableHelper(dataMap: fields, where: '$pkName IN (...)', arguments: ids.toList(), multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
