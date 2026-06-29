// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing robust execution primitives for
/// [FluentStorable] entity mutations and state reconciliation.
///
/// The [FluentExecuteUpdate] extension serves as the mutation orchestrator. It
/// encapsulates the complex logic of mapping domain entity properties to
/// strict SQL table columns, ensuring that updates are applied safely,
/// predictably, and with minimal overhead.
///
/// ### Core Architecture & Mutation Paradigms
/// This extension enforces strict data-integrity safeguards during every update lifecycle:
///
/// * **Schema-Compliant Filtering:** The engine automatically filters out
///   properties that do not map to valid [tableColumns]. It strictly prohibits
///   modification of the primary key field, preventing inadvertent integrity
///   violations or relational drift.
/// * **Selective Persistence:** By evaluating the diff between the provided
///   [dataMap] and the model's schema, the extension skips redundant database
///   round-trips when no valid, mutable fields are detected.
/// * **Atomic Transactional Grouping:** For batch operations, the extension
///   leverages database transactions, ensuring that complex multi-row updates
///   are treated as a single atomic operation—guaranteeing consistency across
///   the entity state graph.
/// * **Diagnostic Transparency:** Every update operation is instrumented via
///   the [FluentLog] facade. This includes tracking affected row counts and
///   capturing execution context, which is vital for debugging concurrent write
///   collisions or schema-level constraint failures.
///
/// ### Execution Flow
/// Mutation tasks are dispatched through the [FluentTask] pipeline, allowing
/// for prioritized handling based on [ExecutionPolicy]. This approach ensures
/// that high-frequency write operations do not saturate the main execution
/// thread while maintaining complete transactional isolation.
///
/// See also:
/// * [FluentProvider], the central orchestrator for storage drivers.
/// * [FluentExecuteSave], for high-level transactional entity persistence.
/// * [FluentDb], for managing transactional isolation and atomicity.
extension FluentExecuteUpdate<T extends FluentStorable> on FluentProvider<T> {
  /// Executes a full-row state mutation by updating specified properties of an existing record.
  ///
  /// This internal executor performs a controlled `UPDATE` operation, ensuring that
  /// only schema-compliant fields are modified:
  /// * **Parameter Validation:** Ensures the record's identity ([id]) and the data map
  ///   ([preparedData]) are provided.
  /// * **Schema Filtering:** Iterates through the provided properties, automatically
  ///   ignoring the primary key and any fields not present in the defined [tableColumns].
  /// * **Optimized Execution:** If the filtered data map is empty (e.g., no valid fields
  ///   to update), the operation is bypassed to prevent unnecessary database interaction.
  /// * **Persistence:** Dispatches a precision `UPDATE` statement using the primary
  ///   key constraint to target exactly one row.
  ///
  /// [task] must contain the target [id] and the [dataMap] containing new property values.
  ///
  /// Returns a [Future<int>] yielding the number of rows updated (typically 1 on
  /// success, or 0 if the record was not found or no valid changes were detected).
  Future<int> _executeUpdateTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final Map<String, dynamic>? preparedData = task.helper?.dataMap;

    if (id == null || preparedData == null) {
      FluentLog.warning(
        'Database update sequence aborted on Main due to incomplete task parameters',
        tag: '$tableName:updateExecutor',
        hint: 'Verify that the task object initiates with valid data structures and primary keys initialized.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isPreparedDataNull': preparedData == null},
      );
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread direct-row state mutation sequence',
      tag: '$tableName:updateExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString()},
    );

    try {
      final Set<String> allowedKeys = tableColumns;

      final Map<String, dynamic> dataToSet = <String, dynamic>{};

      for (final MapEntry<String, dynamic> entry in preparedData.entries) {
        final String key = entry.key;

        if (key != pkName && allowedKeys.contains(key)) {
          dataToSet[key] = entry.value;
        }
      }

      if (dataToSet.isEmpty) {
        FluentLog.debug(
          'Data modification bypassed: no updatable or altered schema properties found',
          tag: '$tableName:updateExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'reason': 'Only primary identifier was provided or zero matching table schema attributes discovered.'},
        );
        return 0;
      }

      final int count = await executor.update(tableName, dataToSet, where: '$pkName = ?', whereArgs: [id]);

      FluentLog.debug(
        'Database operational modification successfully finalized inside storage layer',
        tag: '$tableName:updateExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
      );

      return count;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread table modification query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:updateExecutor',
        hint: 'Verify raw property value mappings match active SQL field definitions, constraint triggers, or active table keys.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Executes a localized mutation on a single column of a specific database record.
  ///
  /// This internal executor performs targeted cell-level updates, ensuring data integrity
  /// through sanitization and system-level metadata management:
  /// * **Parameter Validation:** Ensures the record's identity ([id]) and the target
  ///   column ([updateKey]) are valid before proceeding.
  /// * **Value Sanitization:** Processes the input value via [_sanitizeValue] to match
  ///   the storage driver's requirements and resolve field-level type metadata.
  /// * **Metadata Sync:** Interacts with [_getMergedMetadata] to ensure that system
  ///   metadata (e.g., entity versioning or field-level attributes) is kept in sync
  ///   with the updated value.
  /// * **Execution:** Performs a precise `UPDATE` operation using the primary key,
  ///   logging success or warning if the record was not found or the state was rejected.
  ///
  /// [task] must contain the target [id], the [key] to be updated, and the [value].
  ///
  /// Returns a [Future<int>] yielding the number of rows affected (typically 1 on
  /// success, 0 if the record identity does not match any existing entry).
  Future<int> _executeUpdateByKeyTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final String? updateKey = task.helper?.key;
    final dynamic updateValue = task.helper?.value;

    if (id == null || updateKey == null) {
      FluentLog.warning(
        'Database targeted mutation sequence aborted on Main due to missing parameters',
        tag: '$tableName:updateByKeyExecutor',
        hint: 'Verify that both the record identity tracking field and the targeted update column key are non-null values.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isUpdateKeyNull': updateKey == null},
      );
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread localized singular cell property state mutation pipeline',
      tag: '$tableName:updateByKeyExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetFieldKey': updateKey},
    );

    try {
      final ({String? metaType, dynamic value}) result = _sanitizeValue(updateValue);
      final Map<String, dynamic> updateData = <String, dynamic>{updateKey: result.value};

      // Process and merge field-level metadata mapping descriptions if explicit schemas exist
      final String? resultMetaType = result.metaType;
      final Map<String, String>? metaParam = resultMetaType != null ? <String, String>{updateKey: resultMetaType} : null;
      final String? mergedMeta = await _getMergedMetadata(id, metaParam);

      if (mergedMeta != null) {
        updateData[FluentDbColumn.systemMetadata().name] = mergedMeta;
      }

      final int count = await executor.update(tableName, updateData, where: '$pkName = ?', whereArgs: [id]);

      if (count > 0) {
        FluentLog.debug(
          'Targeted column cell property modified and finalized safely in storage layer',
          tag: '$tableName:updateByKeyExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'modifiedFieldKey': updateKey, 'affectedRowsCount': count},
        );
      } else {
        FluentLog.warning(
          'Single-field update completed with zero affected records',
          tag: '$tableName:updateByKeyExecutor',
          hint: 'The identity key may not match any active row documents, or the physical storage driver rejected the cell state override.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'unmodifiedFieldKey': updateKey},
        );
      }
      return count;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread targeted cell mutation query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:updateByKeyExecutor',
        hint: 'Examine field metadata configurations, analyze typing constraints, or check active entity row states.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString(), 'failedFieldKey': updateKey},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs subset column modifications on the Main thread.
  ///
  /// This multi-field partial modification pipeline processes task dictionaries before executing modifications:
  /// * Evaluates data existence constraints to guard against uninitialized or empty map inputs.
  /// * Splits and separates raw runtime entries into storage values and typed system tracking metadata.
  /// * Filters keys dynamically against the table schema, omitting the primary key to maintain entity identity.
  /// * Extracts, constructs, and flushes complementary system metadata schemas dynamically into the row layout.
  /// * Evaluates state updates directly against the physical storage driver using fully parameterized syntax.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<int> _executeUpdateFieldsMultipleTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final Map<String, dynamic>? fields = task.helper?.dataMap;

    if (id == null || fields == null || fields.isEmpty) {
      FluentLog.warning(
        'Database dynamic subset mutation sequence aborted on Main due to missing parameters',
        tag: '$tableName:updateFieldsMultiple',
        hint: 'Verify that both the record identity tracking field and the targeted update properties dictionary are non-empty structures.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isFieldsMapNullOrEmpty': fields == null || fields.isEmpty},
      );
      return 0;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread localized multi-field subset state mutation pipeline',
      tag: '$tableName:updateFieldsMultiple',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'incomingFieldsCount': fields.length},
    );

    try {
      // Split raw dictionary entries into primitive storage fields and typing metadata maps
      final ({Map<String, dynamic> data, Map<String, String> meta}) parts = _prepareMapAndMeta(fields);

      final Set<String> allowedKeys = tableColumns;
      final Map<String, dynamic> dataToSet = <String, dynamic>{};

      // Sanitize and align payload properties against physical table boundaries
      for (final MapEntry<String, dynamic> entry in parts.data.entries) {
        final String key = entry.key;

        // Skip the primary identity key to maintain model alignment constraints
        if (key != pkName && allowedKeys.contains(key)) {
          dataToSet[key] = entry.value;
        }
      }

      // Process and merge partial field typing schemas into centralized physical records
      final String? mergedMeta = await _getMergedMetadata(id, parts.meta);
      if (mergedMeta != null) {
        dataToSet[FluentDbColumn.systemMetadata().name] = mergedMeta;
      }

      // SCENARIO A: COMPATIBILITY COLLAPSE — Filtering operations yielded zero valid database column properties
      if (dataToSet.isEmpty) {
        FluentLog.debug(
          'Multi-field data modification bypassed: no updatable or altered schema properties found',
          tag: '$tableName:updateFieldsMultiple',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'reason': 'All fields were filtered out due to database schema incompatibility constraints.'},
        );
        return 0;
      }

      // SCENARIO B: MUTATION WRITE — Commit aligned property subsets using fully parameterized syntax
      final int count = await executor.update(tableName, dataToSet, where: '$pkName = ?', whereArgs: [id]);

      if (count == 0) {
        FluentLog.warning(
          'Multi-field partial update completed with zero affected records',
          tag: '$tableName:updateFieldsMultiple',
          hint: 'The identity key may not match any active row documents, or the physical storage driver rejected the subset map state change.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
        );
      } else {
        FluentLog.debug(
          'Targeted subset property batch modified and finalized safely in storage layer',
          tag: '$tableName:updateFieldsMultiple',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
        );
      }
      return count;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread targeted subset mutation query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception:updateFieldsMultiple',
        hint: 'Examine field dictionary variables, verify metadata parsing rules, or audit schema column typing constraints.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Performs an atomic, transactional update of a domain entity and its entire relational sub-graph.
  ///
  /// This pipeline ensures deep-graph consistency by wrapping mutation operations in a serializable transaction:
  /// * Segregates core model fields from relational join keys to preserve table-specific schema integrity.
  /// * Executes primary record updates via a strict [pkName] constraint, flagging non-existent targets as warnings.
  /// * Delegates child-entity cascades to the [_relationsMixin], propagating the [txn] handle to ensure atomic commit/rollback.
  /// * Maintains strict thread isolation via [finally] blocks, guaranteeing that `restoreOriginalExecutor` occurs
  ///   regardless of intermediate mutation or network failures.
  ///
  /// [task] provides the execution context, holding both the primary model map and the list of associated relational state snapshots.
  Future<int> _executeUpdateWithRelationsTaskOnMain(FluentTask task) async {
    final T item = task.data as T;
    final Map<String, dynamic> preparedData = task.relations!.first;
    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final dynamic id = task.helper?.id;
    final FluentRelationSyncMode syncMode = task.helper?.syncMode ?? FluentRelationSyncMode.preserveLocal;

    FluentLog.debug(
      'Executing Main-thread transactional deep-model update sequence',
      tag: '$tableName:updateWithRelationsExecutor',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'taskId': task.id},
    );

    try {
      return await db.transaction((txn) async {
        final Batch batch = txn.batch();

        // Filter: Separate core table fields from relational keys to prevent SQL injection or schema mismatch errors
        final Map<String, dynamic> sqlFields = {};
        final Set<String> relKeys = relationKeys;

        for (final MapEntry<String, dynamic> entry in preparedData.entries) {
          if (!relKeys.contains(entry.key)) {
            sqlFields[entry.key] = entry.value;
          }
        }

        batch.update(tableName, sqlFields, where: '$pkName = ?', whereArgs: [id]);

        if (_hasRelations && _relationsMixin != null) {
          FluentLog.debug('Processing deep-linked relational entity associations', tag: '$tableName:updateWithRelationsExecutor', context: {'tableName': tableName, 'taskId': task.id});

          final List<T> batchList = List<T>.filled(1, item, growable: false);

          await _relationsMixin!._processBatchRelations(txn, batchList, task, batch: batch, parentJsons: task.relations, currentDepth: 0, visitedTables: <String>{tableName}, syncMode: syncMode);
        }

        final List<Object?> results = await batch.commit();

        final int count = (results.isNotEmpty && results.first is int) ? results.first as int : 0;

        if (count == 0) {
          FluentLog.warning(
            'Target record for update could not be located in storage layer',
            tag: '$tableName:updateWithRelationsExecutor',
            hint: 'Attempted to perform an update on a non-existent identifier. Verify record existence or evaluate if an insert operation is required.',
            context: {'tableName': tableName, 'targetRecordId': id.toString()},
          );
        }

        FluentLog.debug('Deep transactional model update successfully persisted', tag: '$tableName:updateWithRelationsExecutor', context: {'tableName': tableName, 'targetRecordId': id.toString()});
        return count;
      });
    } catch (e, stackTrace) {
      FluentLog.error(
        'Deep model transactional update aborted due to execution driver failure',
        e,
        stackTrace,
        tag: '$tableName:exception:updateWithRelationsExecutor',
        hint: 'Examine primary key constraints, foreign key referential integrity, or transient connection deadlocks.',
        context: {'tableName': tableName, 'targetRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Executes a transactional batch update of multiple entity instances and their relations.
  Future<int> _executeUpdateAllWithRelationsTaskOnMain(FluentTask task) async {
    final List<T> items = (task.data as List).cast<T>();
    final List<Map<String, dynamic>>? preparedJsons = task.relations;

    if (items.isEmpty || preparedJsons == null || preparedJsons.isEmpty) return 0;

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final FluentRelationSyncMode syncMode = task.helper?.syncMode ?? FluentRelationSyncMode.preserveLocal;

    final Set<String> allowedKeys = tableColumns;
    final Set<String> relKeys = relationKeys;

    FluentLog.debug(
      'Executing Main-thread transactional batch deep-model update sequence',
      tag: '$tableName:updateAllWithRelationsExecutor',
      context: {'tableName': tableName, 'batchSize': items.length, 'taskId': task.id},
    );

    try {
      return await db.transaction((txn) async {
        int validItemsCount = 0;

        final Batch batch = txn.batch();

        for (int i = 0; i < items.length; i++) {
          final dynamic id = items[i].primaryKeyValue;
          if (id == null) continue;

          final Map<String, dynamic> rawJson = preparedJsons[i];
          final Map<String, dynamic> sqlFields = {};

          for (final MapEntry<String, dynamic> entry in rawJson.entries) {
            if (entry.key != pkName && allowedKeys.contains(entry.key) && !relKeys.contains(entry.key)) {
              sqlFields[entry.key] = entry.value;
            }
          }

          if (sqlFields.isNotEmpty) {
            batch.update(tableName, sqlFields, where: '$pkName = ?', whereArgs: [id]);
            validItemsCount++;
          }
        }

        await batch.commit(noResult: true);

        if (_hasRelations && _relationsMixin != null) {
          FluentLog.debug('Processing deep-linked relational batch associations', tag: '$tableName:updateAllWithRelationsExecutor');

          await _relationsMixin!._processBatchRelations(txn, items, task, batch: batch, parentJsons: preparedJsons, currentDepth: 0, visitedTables: <String>{tableName}, syncMode: syncMode);
        }

        return validItemsCount;
      });
    } catch (e, stackTrace) {
      FluentLog.error(
        'Batch deep model transactional update aborted due to execution driver failure',
        e,
        stackTrace,
        tag: '$tableName:exception:updateAllWithRelationsExecutor',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Executes a transactional batch update of multiple entity instances on the Main thread.
  ///
  /// This method iterates through a collection of [FluentStorable] entities,
  /// sanitizes their fields against the current table schema, and queues them
  /// for a batch update operation.
  ///
  /// * **Schema Integrity:** Automatically filters out non-existent columns and
  ///   the primary key, ensuring that only mutable fields are transmitted to the storage engine.
  /// * **Atomicity:** All updates are bundled into a single database transaction.
  ///   If the batch commit fails, the entire operation is rolled back, preserving
  ///   database consistency.
  /// * **Performance:** Uses a [Batch] object to minimize I/O overhead, effectively
  ///   reducing the number of disk flushes required for multiple record updates.
  ///
  /// Returns the total count of successfully updated records.
  Future<int> _executeUpdateAllTaskOnMain(FluentTask task) async {
    final List<dynamic> items = task.helper?.arguments ?? [];
    if (items.isEmpty) return 0;

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final Set<String> allowedKeys = tableColumns;

    FluentLog.debug('Initiating batch model update sequence', tag: '$tableName:updateAllExecutor', context: {'totalItemsProvided': items.length});

    try {
      return await db.transaction((txn) async {
        final Batch batch = txn.batch();
        int validItemsCount = 0;

        for (final dynamic item in items) {
          if (item is! FluentStorable) continue;

          final dynamic id = item.primaryKeyValue;
          if (id == null) {
            FluentLog.warning('Batch update skip: missing primary key', tag: '$tableName:updateAllExecutor', context: {'itemType': item.runtimeType.toString()});
            continue;
          }

          final Map<String, dynamic> preparedData = _prepareSqlJson(item as T);
          final Map<String, dynamic> dataToSet = {};

          for (final entry in preparedData.entries) {
            if (entry.key != pkName && allowedKeys.contains(entry.key)) {
              dataToSet[entry.key] = entry.value;
            }
          }

          if (dataToSet.isNotEmpty) {
            batch.update(tableName, dataToSet, where: '$pkName = ?', whereArgs: [id]);
            validItemsCount++;
          }
        }

        final List<dynamic> results = await batch.commit();
        final int affectedRows = results.whereType<int>().fold<int>(0, (a, b) => a + b);

        FluentLog.debug('Batch model update successfully finalized', tag: '$tableName:updateAllExecutor', context: {'itemsProcessed': validItemsCount, 'rowsAffected': affectedRows});

        return affectedRows;
      });
    } catch (e, s) {
      FluentLog.error('Batch model update pipeline failed', e, s, tag: '$tableName:updateAllExecutor', context: {'totalItemsProvided': items.length});
      rethrow;
    }
  }

  /// Executes a transactional batch update of specific fields for a set of identified entities.
  ///
  /// This method performs an atomic partial update across multiple records. It sanitizes
  /// the provided [fields] against the table schema, effectively ignoring invalid keys,
  /// and applies changes to all records matching the provided [ids].
  ///
  /// * **Schema-Aware Filtering:** Automatically validates fields against [tableColumns],
  ///   ensuring that only existing, mutable columns are included in the `UPDATE` statement.
  /// * **Transactionally Batch Processed:** The update is performed in chunks (based on
  ///   [ExecutionPolicy.effectiveChunkSize]) to avoid SQL variable limits, all within
  ///   a single atomic database transaction.
  /// * **Optimized Execution:** Uses a [Batch] object to group multiple `UPDATE ... WHERE IN`
  ///   statements, drastically reducing I/O operations for bulk state changes.
  ///
  /// Returns the total count of rows affected by the batch operation.
  Future<int> _executeUpdateMultipleFieldsByIdsTaskOnMain(FluentTask task) async {
    final List<dynamic> ids = task.helper?.arguments ?? [];
    final Map<String, dynamic>? fields = task.helper?.dataMap;

    if (ids.isEmpty || fields == null || fields.isEmpty) return 0;

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final ({Map<String, dynamic> data, Map<String, String> meta}) parts = _prepareMapAndMeta(fields);
    final Set<String> allowedKeys = tableColumns;
    final Map<String, dynamic> dataToSet = {};

    for (final entry in parts.data.entries) {
      if (entry.key != pkName && allowedKeys.contains(entry.key)) dataToSet[entry.key] = entry.value;
    }

    if (dataToSet.isEmpty) {
      FluentLog.warning('Batch field update skipped: no valid fields to update', tag: '$tableName:updateMultipleFieldsByIdsExecutor');
      return 0;
    }

    FluentLog.debug('Initiating batch partial field update', tag: '$tableName:updateMultipleFieldsByIdsExecutor', context: {'targetIdsCount': ids.length, 'updatedFields': dataToSet.keys.toList()});

    try {
      return await db.transaction((txn) async {
        final Batch batch = txn.batch();
        final int chunkSize = task.policy.effectiveChunkSize;

        for (int i = 0; i < ids.length; i += chunkSize) {
          final int end = (i + chunkSize > ids.length) ? ids.length : i + chunkSize;
          final List<dynamic> chunk = ids.sublist(i, end);
          final String placeholders = _generatePlaceholders(chunk.length);

          batch.update(tableName, dataToSet, where: '$pkName IN ($placeholders)', whereArgs: chunk);
        }

        final List<dynamic> results = await batch.commit();
        final int affectedRows = results.whereType<int>().fold<int>(0, (a, b) => a + b);

        FluentLog.debug('Batch partial field update finalized', tag: '$tableName:updateMultipleFieldsByIdsExecutor', context: {'affectedRows': affectedRows});

        return affectedRows;
      });
    } catch (e, s) {
      FluentLog.error('Batch partial fields update failed', e, s, tag: '$tableName:updateMultipleFieldsByIdsExecutor', context: {'targetIdsCount': ids.length, 'fields': dataToSet.keys.toList()});
      rethrow;
    }
  }
}
