// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_provider.dart';

/// Internal infrastructure engine providing low-level execution primitives for [FluentProvider].
///
/// The [FluentCrudHelper] extension serves as the structural backbone for all database operations.
/// It encapsulates the "heavy lifting" required to bridge domain-specific [FluentStorable] entities
/// with the raw storage engine, ensuring type safety, relational integrity, and memory efficiency
/// during data ingestion and retrieval.
///
/// ### Core Infrastructure Paradigms
/// This extension orchestrates the internal lifecycle of database operations, handling
/// cross-cutting concerns that occur behind the scenes:
///
/// * **Schema & Payload Sanitization:** Performs automated verification of input maps against
///   defined [tableColumns], ensuring that extraneous or corrupted data properties never
///   reach the storage engine.
/// * **Transactional Integrity & Error Routing:** Acts as a specialized diagnostic layer that
///   intercepts low-level database anomalies, maps them to package-specific exceptions, and
///   provides rich telemetry context for debugging.
/// * **Relational Hydration & Orphan Cleanup:** Manages the orchestration of cascading foreign-key
///   resolutions and orphan record purging, ensuring that relational state transitions are
///   atomic and consistent with entity mixins.
/// * **High-Performance Serialization:** Implements memory-optimized utilities for metadata
///   extraction and parameter binding, minimizing garbage collection pressure during
///   large-scale batch operations or stream processing.
/// * **Conditional Query Injection:** Transparently manages record visibility protocols, such as
///   the mandatory injection of [FluentSoftDeletable] filters into SQL clauses to maintain
///   data-set isolation without requiring manual developer input.
///
/// See also:
/// * [FluentProvider], the primary driver contract.
/// * [FluentStorable], the domain entity definition.
/// * [FluentSoftDeletable], the protocol for managed data lifecycle states.
extension FluentCrudHelper<T extends FluentStorable> on FluentProvider<T> {
  /// Analyzes catch block errors, evaluates constraint flags, and formats exceptions.
  ///
  /// Intercepts incoming low-level [DatabaseException] anomalies, performs routing
  /// based on SQLite error signatures, generates diagnostic telemetry logs via [FluentLog.error],
  /// and wraps underlying failures into specialized package exception modules.
  void _handleDatabaseException(DatabaseException e, StackTrace stackTrace) {
    final String errorString = e.toString();
    if (e.isUniqueConstraintError() || errorString.contains('UNIQUE')) {
      FluentLog.error(
        'Database write aborted due to uniqueness constraint violation',
        e,
        stackTrace,
        tag: '$tableName:exception:database',
        hint: 'Verify data records match table indexing schema parameters and unique identifiers.',
        context: {'tableName': tableName, 'isConstraintViolation': true},
      );
      throw FluentConstraintException('Unique constraint violation in table "$tableName"', originalError: e);
    }
    FluentLog.error(
      'Database pipeline caught unhandled low-level engine exception during write routing',
      e,
      stackTrace,
      tag: '$tableName:exception:database',
      hint: 'Inspect internal SQLite connection status, schema state, or execution query parameters.',
      context: {'tableName': tableName, 'isConstraintViolation': false},
    );
    throw FluentBaseException('Database error while writing to "$tableName": $e', stackTrace, e);
  }

  /// Processing worker executing relational data structure resolution for a single row model.
  ///
  /// This micro-task runs sequentially or concurrently within chunked stream pipelines:
  /// * Evaluates [_processRow] to link cascading sub-tables and compute virtual data fields.
  /// * Triggers [_assembleModel] to handle type-casting and constructor hydration mappings.
  ///
  /// Intercepts relational mapping failures and pipes detailed breakdown metrics into [FluentLog.error]
  /// to pinpoint corrupt or unaligned foreign records.
  Future<T> _rowEnrichmentAndAssembleWorker(Map<String, dynamic> row, FluentTask task) async {
    try {
      // Execute cascading foreign-key resolution and child object tree hydration
      final List<Map<String, dynamic>> enrichedList = await _processRowsBatch([row], task);

      // Materialize the final strongly-typed data model from the fully hydrated map
      return _assembleModel(enrichedList.first);
    } catch (e, s) {
      FluentLog.error(
        'Hydration layer failed during singular row enrichment processing',
        e,
        s,
        tag: '$tableName:enrichmentAndAssembleExecutor',
        hint: 'Verify nested model serializers match relational schema schemas and check for missing foreign keys.',
        context: {'tableName': tableName, 'taskId': task.id, 'rawRowKeys': row.keys.toList()},
      );
      rethrow;
    }
  }

  /// Safely formats and stages a database insertion or modification inside an active batch transaction.
  ///
  /// This transactional micro-task processes raw record maps before executing write steps:
  /// * Evaluates payload properties against [tableColumns] to detect invalid attributes.
  /// * Sanitizes extraneous keys to prevent underlying SQLite syntax errors.
  /// * Fires warning telemetry via [FluentLog.warning] if any model attributes were stripped.
  /// * Configures structural [FluentSaveStrategy] states according to the [strategy] modifier.
  void _upsertItemInTxn(Batch batch, Map<String, dynamic> map, FluentSaveStrategy strategy) {
    final Set<String> allowedColumns = tableColumns;

    // Evaluate input map structure against the verified schema constraints
    bool needsSanitization = false;
    for (final String key in map.keys) {
      if (!allowedColumns.contains(key)) {
        needsSanitization = true;
        break;
      }
    }

    final Map<String, dynamic> sqlData;

    // SCENARIO A: CLEAN PAYLOAD — Map structure maps perfectly to column rules
    if (!needsSanitization) {
      sqlData = map;
    } else {
      // SCENARIO B: CORRUPT/EXTRANEOUS PAYLOAD — Extract unaligned schema fields
      sqlData = {};
      final List<String> strippedFields = [];

      for (final entry in map.entries) {
        if (allowedColumns.contains(entry.key)) {
          sqlData[entry.key] = entry.value;
        } else {
          strippedFields.add(entry.key);
        }
      }

      FluentLog.warning(
        'Database payload sanitization triggered due to unaligned model attributes',
        tag: '$tableName:schema:upsertItemExecutor',
        hint: 'Ensure your data models are fully synchronized with the physical table definitions. Outdated migrations or missing column mappings can leave dead properties in serialization payloads.',
        context: {'tableName': tableName, 'strippedFields': strippedFields, 'expectedColumns': allowedColumns.toList()},
      );
    }

    switch (strategy) {
      case FluentSaveStrategy.upsert:
        batch.insert(tableName, sqlData, conflictAlgorithm: ConflictAlgorithm.replace);
        break;

      case FluentSaveStrategy.insertOnly:
        batch.insert(tableName, sqlData, conflictAlgorithm: ConflictAlgorithm.ignore);
        break;

      case FluentSaveStrategy.patch:
      case FluentSaveStrategy.updateOnly:
        final String pkName = _cachedPrimaryKey?.name ?? 'id';
        final dynamic pkValue = sqlData[pkName];

        if (pkValue != null) {
          batch.update(tableName, sqlData, where: '$pkName = ?', whereArgs: [pkValue]);
        } else {
          FluentLog.warning('Update strategy used but no primary key found in payload. Skipping record.', tag: '$tableName:schema:upsertItemExecutor');
        }
        break;
    }
  }

  /// Splits an un-sanitized, generic runtime input map into a strongly decoupled, structure-aligned record tuple.
  ///
  /// This serialization and categorization pre-processing loop inspects input entries sequentially:
  /// * Skips blank identifiers and explicitly drops [FluentDbColumn.systemMetadata] properties to protect system storage keys.
  /// * Bypasses type serialization processing for entries recognized as active foreign relational keys.
  /// * Runs standard fields through low-level type sanitization to isolate underlying storage values.
  /// * Collects complex typing metadata tags into an separate sub-map to assist future deserialization.
  ///
  /// [rawData] represents the source dictionary of key-value pairs targeted for ingestion or processing.
  ///
  /// Returns a record tuple containing:
  /// * `data`: A structured [Map<String, dynamic>] holding normalized database primitive values.
  /// * `meta`: A specialized [Map<String, String>] mapping physical column keys to structural type descriptions.
  ({Map<String, dynamic> data, Map<String, String> meta}) _prepareMapAndMeta(Map<String, dynamic> rawData) {
    final Map<String, dynamic> sqlData = <String, dynamic>{};
    final Map<String, String> metaData = <String, String>{};

    // Cache the active table relationship structures locally to maximize iteration throughput
    final Set<String> relationKeys = _hasRelations ? (_cachedRelationKeys ?? const <String>{}) : const <String>{};
    final String systemMetaName = FluentDbColumn.systemMetadata().name;

    FluentLog.debug(
      'Executing data and typing-metadata segmentation mapping routine',
      tag: '$tableName:prepareMapAndMeta',
      context: {'tableName': tableName, 'rawFieldsCount': rawData.length, 'hasRelations': _hasRelations, 'trackedRelationFields': relationKeys.toList()},
    );

    for (final MapEntry<String, dynamic> entry in rawData.entries) {
      final String key = entry.key;

      if (key.isEmpty || key == systemMetaName) continue;

      final dynamic value = entry.value;

      if (relationKeys.contains(key)) {
        sqlData[key] = value;
        continue;
      }

      final ({String? metaType, dynamic value}) result = _sanitizeValue(value);
      sqlData[key] = result.value;

      final String? metaType = result.metaType;
      if (metaType != null) {
        metaData[key] = metaType;
      }
    }

    FluentLog.debug(
      'Data segmentation and typing extraction successfully finalized',
      tag: '$tableName:prepareMapAndMeta',
      context: {'tableName': tableName, 'segmentedSqlFieldsCount': sqlData.length, 'extractedMetaFieldsCount': metaData.length},
    );

    return (data: sqlData, meta: metaData);
  }

  /// Combines new structural type definitions with the historical system metadata document stored in [$tableName].
  ///
  /// This read-modify-write internal sub-routine fetches the column snapshot isolated by the entity's [id]:
  /// * Evaluates input boundaries to skip database selection queries if [newTypes] is null or empty.
  /// * Safely handles un-serialized JSON errors via [FluentLog.error], allowing execution to proceed with a clean map structure.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [newTypes] represents an optional map linking newly modified column property keys to their structural string meta types.
  ///
  /// Returns a JSON-serialized [String] holding the unified map payload ready for cell flush operations,
  /// or evaluates to `null` if the final combined map contains zero entries.
  Future<String?> _getMergedMetadata(dynamic id, Map<String, String>? newTypes) async {
    if (newTypes == null || newTypes.isEmpty) return null;

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final String metaColName = FluentDbColumn.systemMetadata().name;

    // Fetch the existing system metadata column snapshot from the target row document
    final List<Map<String, dynamic>> result = await executor.query(tableName, columns: [metaColName], where: '$pkName = ?', whereArgs: [id], limit: 1);

    final Map<String, String> merged = <String, String>{};

    if (result.isNotEmpty) {
      final dynamic rawMeta = result.first[metaColName];
      if (rawMeta is String && rawMeta.isNotEmpty) {
        try {
          // Deserialize the database string into an un-typed structured dictionary map
          final dynamic oldMeta = jsonDecode(rawMeta);
          if (oldMeta is Map<String, dynamic>) {
            for (final entry in oldMeta.entries) {
              merged[entry.key] = entry.value.toString();
            }
          }
        } catch (e, s) {
          FluentLog.error(
            'Failed to deserialize existing record system metadata document payload',
            e,
            s,
            tag: '$tableName:exception:mergedMetadata',
            hint: 'The metadata column data may have been corrupted, manually modified, or formatted using an incompatible schema encoding protocol.',
            context: {'tableName': tableName, 'targetRecordId': id.toString(), 'metadataColumnName': metaColName, 'rawMetadataContent': rawMeta},
          );
        }
      }
    }

    // Append and overwrite historical properties with the freshly extracted type metadata descriptors
    merged.addAll(newTypes);

    return merged.isEmpty ? null : jsonEncode(merged);
  }

  /// Generates an efficient comma-separated sequence of parameterized SQL bind tokens `(?, ?, ...)`.
  ///
  /// This performance-critical memory calculation utility builds selection array bindings:
  /// * Evaluates numerical boundaries early to return accelerated static shortcuts for common `count <= 1` use cases.
  /// * Leverages a lightweight [StringBuffer] array stream instead of standard string interpolation loops.
  /// * Reduces garbage collection overhead by eliminating transient intermediate string heap instantiations.
  ///
  /// [count] specifies the total number of individual parameter arguments requiring query binding placeholders.
  ///
  /// Returns a formatted [String] containing the bound tokens, or an empty string if [count] is less than or equal to zero.
  String _generatePlaceholders(int count) {
    // Fast-path evaluation: Return an empty string if zero or negative parameters are requested
    if (count <= 0) {
      return '';
    }
    // Performance shortcut: Bypass dynamic buffers entirely for single-parameter lookups
    if (count == 1) {
      return '?';
    }

    final StringBuffer sb = StringBuffer('?');
    for (int i = 1; i < count; i++) {
      sb.write(', ?');
    }

    FluentLog.debug(
      'Dynamic sql parameter index placeholders successfully generated',
      tag: '$tableName:generatePlaceholders',
      context: {'tableName': tableName, 'requestedCount': count, 'allocatedBufferLength': sb.length},
    );
    return sb.toString();
  }

  /// Low-level atomic driver execution routine that processes automated cache expiration and relational sweeps.
  ///
  /// This operational routine executes a direct deletion query against the storage engine:
  /// * Fires a parameterized raw SQL delete execution directly using the provided [activeExecutor] context.
  /// * Evaluates resulting row impact metrics to determine if deep relational integrity cycles are required.
  /// * Spawns an orphan record cleaning routine via [_relationsMixin] to process foreign constraints.
  /// * Preserves atomic transaction boundaries by passing down the active transaction context reference.
  ///
  /// [where] specifies the conditional filter query clause used to extract expired record documents.
  /// [whereArgs] contains the precise tracking timestamps or variables bound to the conditional arguments.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  Future<int> _rawClearExpiredExecution(String where, List<Object?> whereArgs, DatabaseExecutor activeExecutor) async {
    final int count = await activeExecutor.delete(tableName, where: where, whereArgs: whereArgs);

    if (count > 0) {
      // SCENARIO A: STALE DATA PURGED — The cleanup sweep successfully located and removed expired entries
      FluentLog.debug(
        'Physical data layer entries removed successfully during automated maintenance sweep',
        tag: '$tableName:clearExpireExecutor',
        context: {'tableName': tableName, 'purgedRowsCount': count},
      );

      // Evaluate cascading constraints to ensure data layer isolation consistency
      if (_hasRelations && _relationsMixin != null) {
        // Pass the identical executing connection handle downstream to preserve atomic transaction boundaries
        await _relationsMixin!.cleanupOrphans(activeExecutor);
      }
    } else {
      // SCENARIO B: DATA LAYER CLEAN — No active storage documents matched the expiration criteria bounds
      FluentLog.debug('Automated record maintenance sweep finalized with zero affected targets', tag: '$tableName:clearExpireExecutor', context: {'tableName': tableName});
    }
    return count;
  }

  /// Low-level atomic driver execution routine that handles whole-table truncation and relational cleanup cycles.
  ///
  /// This routine interacts directly with the underlying database driver layer:
  /// * Fires an un-parameterized raw SQL delete operation across the target table via [activeExecutor].
  /// * Tracks total impacted rows before logging the finalized operation context.
  /// * Evaluates active [_relationsMixin] targets to cascade cleanup routines across orphan rows.
  /// * Maintains isolated transaction boundaries by forwarding the current connection handle downstream.
  ///
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  Future<int> _rawClearTableExecution(DatabaseExecutor activeExecutor) async {
    final int count = await activeExecutor.delete(tableName);

    FluentLog.debug('Storage table completely evacuated and cleared of physical row records', tag: '$tableName:clearExecutor', context: {'tableName': tableName, 'purgedRowsCount': count});

    if (_hasRelations && _relationsMixin != null) {
      await _relationsMixin!.cleanupOrphans(activeExecutor);
    }
    return count;
  }

  /// Injects a mandatory soft-delete filtering condition into a SQL `WHERE` clause.
  ///
  /// This method serves as the primary security layer for entity retrieval,
  /// ensuring that soft-deleted records are automatically handled according to
  /// the operational context.
  ///
  /// * **Soft-Delete Enforcement:** If the model implements [FluentSoftDeletable],
  ///   appends either `IS NULL` (active) or `IS NOT NULL` (trash) logic.
  /// * **Nullable Response:** Returns `null` if no filtering condition is required,
  ///   allowing higher-level query builders to omit the `WHERE` block entirely
  ///   for optimized performance.
  /// * **Constraint Integrity:** Wraps existing [baseWhere] clauses in parentheses
  ///   before appending the soft-delete filter with an `AND` operator, preventing
  ///   logical conflicts with complex `OR` queries.
  ///
  /// @param baseWhere The initial SQL condition string.
  /// @param requestDeletedOnly If `true`, filters for soft-deleted items;
  ///        defaults to `false` (active items only).
  /// @return A sanitized SQL string for the `WHERE` clause, or `null` if no
  ///         filtering is applicable.
  String? _injectSoftDelete(String? baseWhere, {bool requestDeletedOnly = false}) {
    if (modelSample is! FluentSoftDeletable) {
      return (baseWhere?.trim().isEmpty ?? true) ? null : baseWhere;
    }

    final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;
    final String condition = requestDeletedOnly ? '$col IS NOT NULL' : '$col IS NULL';

    if (baseWhere == null || baseWhere.trim().isEmpty) {
      return condition;
    }

    return '(${baseWhere.trim()}) AND $condition';
  }

  /// Executes the restoration of a large set of records by processing them in
  /// manageable [chunkSize] segments.
  ///
  /// This method iterates through the provided [idList], slices them into chunks,
  /// and queues an `UPDATE` operation for each chunk into the provided [batch].
  /// Using placeholders for the `IN` clause, it efficiently resets the
  /// [colName] to `null` (restoring the record) without overwhelming the
  /// database connection or hitting SQL parameter limits.
  ///
  /// * **Efficiency:** By batching updates, it significantly reduces the number of
  ///   transaction commits required for mass restoration.
  /// * **Constraint Safety:** It dynamically generates the required number of
  ///   SQL placeholders based on the current chunk size, ensuring syntactical
  ///   correctness.
  ///
  /// [batch] The database [Batch] object used to queue the operations.
  /// [idList] The list of primary keys for the records to be restored.
  /// [chunkSize] The maximum number of IDs to process in a single SQL query.
  /// [pkName] The column name of the primary key used in the `WHERE` clause.
  /// [colName] The soft-delete column name to be set to `null`.
  void _executeRestoreChunks(Batch batch, List<dynamic> idList, int chunkSize, String pkName, String colName) {
    final int totalLength = idList.length;
    for (int i = 0; i < totalLength; i += chunkSize) {
      final int end = (i + chunkSize > totalLength) ? totalLength : i + chunkSize;
      final List<dynamic> chunk = idList.sublist(i, end);
      final String placeholders = _generatePlaceholders(chunk.length);

      batch.update(tableName, {colName: null}, where: '$pkName IN ($placeholders)', whereArgs: chunk);
    }
  }
}
