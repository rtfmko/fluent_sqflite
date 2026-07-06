// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../../fluent_provider.dart';

/// Enterprise data-layer extension providing the low-level execution pipeline for
/// data retrieval queries.
///
/// The [FluentExecuteFind] extension acts as the primary coordinator for dispatching
/// and resolving data queries on the main execution thread. It bridges the gap
/// between raw SQL result sets and fully hydrated, type-safe [FluentStorable] entity
/// collections, implementing performance-critical strategies based on model topology.
///
/// ### Core Architecture & Hydration Paradigms
/// The extension utilizes a dynamic branching strategy to optimize the retrieval
/// lifecycle based on the complexity of the requested data:
///
/// * **Zero-Allocation Flat Mapper:** For models without relational dependencies,
///   the engine employs an optimized loop-based assembly path, ensuring minimal
///   GC pressure and maximum throughput for large flat datasets.
/// * **Batched Relational Cascade:** For complex models with sub-relations, it
///   triggers a chunked hydration sequence via [_computeBatched]. This avoids
///   blocking the main thread for extended periods by processing relational
///   enrichment in manageable segments.
/// * **Diagnostic Transparency:** Every execution sequence is instrumented with
///   context-aware logging. This allows developers to audit query performance,
///   hydration latency, and the specific optimization path applied (e.g.,
///   `flat_array_fast_path` vs `batched_cascade_enrichment`).
/// * **Fault-Tolerant Hydration:** The pipeline features robust error handling,
///   capturing failures during row-to-model assembly and providing structured
///   diagnostic hints that point to potential schema mismatches or mapping logic
///   errors.
///
/// ### Execution Flow
/// The flow begins with the [FluentTask], which carries the necessary SQL constraints,
/// and culminates in the delivery of a fully materialized [List<T>]. By offloading
/// enrichment logic to dedicated worker routines, the extension maintains
/// responsiveness even when resolving complex entity trees.
///
/// See also:
/// * [FluentProvider], the orchestrator of storage driver access.
/// * [FluentTask], the unit of work definition for database operations.
/// * [RelationsMixin], for logic regarding the hydration of nested sub-models.
extension FluentExecuteFind<T extends FluentStorable> on FluentProvider<T> {
  /// Direct data layer coordinator that runs data selection queries on the Main thread thread-pool.
  ///
  /// This pipeline retrieves a collection of raw row configurations from SQLite matching criteria.
  /// It branches dynamically based on table topology configuration states:
  /// * Evaluates a zero-allocation flat array mapper loop if the target model has no relations.
  /// * Triggers chunked multi-tier data structure worker routines if sub-relation tables must be resolved.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<List<T>> _executeFindAllTaskOnMain(FluentTask task) async {
    final int? limit = task.helper?.limit;
    final String? orderBy = task.helper?.orderBy;

    FluentLog.debug('Executing Main-thread batch selection routine', tag: '$tableName:findAllExecutor', context: {'tableName': tableName, 'taskId': task.id, 'limit': limit ?? 'unlimited'});

    try {
      // Execute the low-level raw query constraint directly against the database driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, limit: limit, orderBy: orderBy);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer selection', tag: '$tableName:findAllExecutor', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Raw database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:findAllExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'rawRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence finalized safely',
          tag: '$tableName:findAllExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.effectiveChunkSize);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence finalized safely',
        tag: '$tableName:findAllExecutor',
        context: {
          'tableName': tableName,
          'taskId': task.id,
          'materializedInstances': typedItems.length,
          'chunkSize': task.policy.effectiveChunkSize,
          'optimizationApplied': 'batched_cascade_enrichment',
        },
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception:findAllExecutor',
        hint: 'Examine data transformation models, custom row enrichment callbacks, or database mapping layouts.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Direct data layer coordinator that runs data verification and filtering on the Main thread.
  ///
  /// This pipeline queries a specific subset of active, unexpired database records by cross-checking
  /// the inferred timestamp metadata columns against the active runtime system epoch.
  /// It branches dynamically based on table topology configuration states:
  /// * Evaluates a zero-allocation flat array mapper loop if the target model has no relations.
  /// * Triggers chunked multi-tier data structure worker routines if sub-relation tables must be resolved.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<List<T>> _executeFindValidItemsTaskOnMain(FluentTask task) async {
    final SortDirection? sortDirection = task.helper?.sortDirection;
    final String? customOrderBy = task.helper?.orderBy;
    final int? limit = task.helper?.limit;

    final String? customWhere = task.helper?.where;
    final List<dynamic>? customWhereArgs = task.helper?.whereArgs;

    final int now = DateTime.now().millisecondsSinceEpoch;

    // Resolve target column mapping for validation tracking parameters
    final String expiryCol = modelSample.expiryColumn;

    String finalWhere;
    List<dynamic> finalWhereArgs;

    if (customWhere != null && customWhere.trim().isNotEmpty) {
      finalWhere = '($customWhere) AND ($expiryCol IS NULL OR $expiryCol > ?)';
      finalWhereArgs = [...(customWhereArgs ?? []), now];
    } else {
      finalWhere = '$expiryCol IS NULL OR $expiryCol > ?';
      finalWhereArgs = [now];
    }

    FluentLog.debug(
      'Executing Main-thread unexpired validation selection routine',
      tag: '$tableName:findValidItemsExecutor',
      context: {
        'tableName': tableName,
        'taskId': task.id,
        'limit': limit ?? 'unlimited',
        'expiryColumn': expiryCol,
        'timestampThreshold': now,
        'sortDirection': sortDirection,
        'hasCustomWhere': customWhere != null,
      },
    );

    try {
      String? finalOrderBy;
      if (customOrderBy != null && customOrderBy.trim().isNotEmpty) {
        if (sortDirection != null) {
          finalOrderBy = '$customOrderBy, $expiryCol ${sortDirection.name.toUpperCase()}';
        } else {
          finalOrderBy = customOrderBy;
        }
      } else {
        finalOrderBy = sortDirection != null ? '$expiryCol ${sortDirection.name.toUpperCase()}' : null;
      }

      // Execute the low-level raw query constraints directly against the database driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, where: finalWhere, whereArgs: finalWhereArgs, limit: limit, orderBy: finalOrderBy);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer valid row selection', tag: '$tableName:findValidItemsExecutor', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Valid database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:findValidItemsExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'validRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for valid records finalized safely',
          tag: '$tableName:findValidItemsExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.effectiveChunkSize);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for valid records finalized safely',
        tag: '$tableName:findValidItemsExecutor',
        context: {
          'tableName': tableName,
          'taskId': task.id,
          'materializedInstances': typedItems.length,
          'chunkSize': task.policy.effectiveChunkSize,
          'optimizationApplied': 'batched_cascade_enrichment',
        },
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread validation query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception:findValidItemsExecutor',
        hint: 'Examine expiry mapping parameters, active database connections, or data model constructors.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Executes a parameterized conditional query to retrieve multiple records based on arbitrary criteria.
  ///
  /// This internal engine worker provides a flexible interface for attribute-based lookups,
  /// bridging the gap between dynamic SQL constraints and typed model instances:
  /// * **Dynamic Clause Resolution:** Uses the provided [task.helper] to determine the
  ///   `WHERE` clause and arguments, defaulting to a standard primary key lookup if none specified.
  /// * **Two-Tier Hydration:**
  ///   * **Fast-Path:** Direct assembly for flat models (no relations), bypassing
  ///     overhead for simple data models.
  ///   * **Relational Cascade:** Utilizes [_computeBatched] for complex entities,
  ///     ensuring efficient processing of object graphs through chunked concurrent workers.
  /// * **Operational Logging:** Captures rich diagnostic context (search keys, clause structure)
  ///   to facilitate troubleshooting of dynamic query pipelines.
  ///
  /// This method is the engine's primary way of resolving `findItemsBy` or custom `where` filters.
  ///
  /// Returns a [Future<List<T>>] containing the list of materialized instances
  /// matching the specified criteria.
  Future<List<T>> _executeFindItemsByTaskOnMain(FluentTask task) async {
    final int? limit = task.helper?.limit;
    final String? orderBy = task.helper?.orderBy;
    final String whereClause = task.helper?.where ?? 'id = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [];
    final String searchKey = task.helper?.key ?? 'id';
    final dynamic value = task.helper?.value;

    FluentLog.debug(
      'Executing Main-thread conditional attribute query selection routine',
      tag: '$tableName:findItemsByExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'orderBy': orderBy, 'searchKey': searchKey, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit ?? 'unlimited'},
    );

    try {
      // Execute the parameterized conditional query directly against the underlying driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, where: whereClause, whereArgs: whereArgs, limit: limit, orderBy: orderBy);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug(
          'Empty result set returned from data layer conditional attribute selection',
          tag: '$tableName:findItemsByExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'searchKey': searchKey, 'searchValue': value.toString()},
        );
        return <T>[];
      }

      FluentLog.debug(
        'Conditional database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:findItemsByExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'matchedRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for conditional query finalized safely',
          tag: '$tableName:findItemsByExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs via the unified row worker
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.effectiveChunkSize);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for conditional query finalized safely',
        tag: '$tableName:findItemsByExecutor',
        context: {
          'tableName': tableName,
          'taskId': task.id,
          'materializedInstances': typedItems.length,
          'chunkSize': task.policy.effectiveChunkSize,
          'optimizationApplied': 'batched_cascade_enrichment',
        },
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread conditional query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception:findItemsByExecutor',
        hint: 'Verify where clause structure parameters, evaluate model constructors, or audit relational join constraints.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedSearchKey': searchKey, 'failedSearchValue': value.toString()},
      );
      rethrow;
    }
  }

  /// Executes a direct lookup for a single database record by its primary key.
  ///
  /// This method serves as the optimized "getter" for the storage layer, handling
  /// both flat data retrieval and complex relational hydration:
  /// * **Targeted Query:** Performs a high-performance `SELECT` limited to a single row,
  ///   using the dynamically resolved primary key column.
  /// * **Fast-Path:** If the entity model has no relations, it bypasses heavy
  ///   computational loops for direct assembly.
  /// * **Relational Cascade:** If relations are present, it triggers the batch
  ///   enrichment pipeline to ensure the returned model is fully hydrated with its
  ///   dependencies (e.g., nested objects, related lists).
  /// * **Safe Nullability:** Gracefully handles missing records by returning `null`,
  ///   ensuring the upper application layer can react appropriately.
  ///
  /// [task] must contain the target identifier in the helper unit.
  ///
  /// Returns a [Future<T?>] containing the hydrated model instance if found,
  /// otherwise returns `null`.
  Future<T?> _executeFindByIdTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    // Resolve the primary key name property configuration dynamically
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread single-row primary key query selection routine',
      tag: '$tableName:findByIdExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetId': id.toString()},
    );

    // Execute a strict singular-row search query directly against the underlying driver
    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: '$pkName = ?', whereArgs: [id], limit: 1);

    if (maps.isEmpty) {
      FluentLog.debug(
        'Empty result set returned from data layer unique primary key selection',
        tag: '$tableName:findByIdExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'targetId': id.toString()},
      );
      return null;
    }

    final Map<String, dynamic> rawRow = maps.first;

    // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
    if (!_hasRelations) {
      FluentLog.debug(
        'Fast-path matching sequence for direct identity lookup finalized safely',
        tag: '$tableName:findByIdExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'optimizationApplied': 'flat_map_fast_path'},
      );
      return _assembleModel(rawRow);
    }

    // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
    final List<Map<String, dynamic>> enrichedList = await _processRowsBatch([rawRow], task);

    FluentLog.debug(
      'Relational hydration mapping sequence for identity lookup finalized safely',
      tag: '$tableName:findByIdExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'optimizationApplied': 'cascade_enrichment'},
    );

    return _assembleModel(enrichedList.first);
  }

  /// Executes a customized database query and orchestrates the model hydration flow.
  ///
  /// This method serves as the core engine for data retrieval, dynamically branching
  /// based on schema complexity to ensure optimal performance:
  /// * **Query Execution:** Dispatches a structured SQL query to the storage driver
  ///   using the criteria defined in [task.helper].
  /// * **Fast-Path (Flat Models):** If the entity lacks relational dependencies, it
  ///   performs a direct, optimized mapping from the raw map result to model instances.
  /// * **Relational Cascade (Hydration):** For complex entities, it offloads model graph
  ///   assembly to a batched concurrent computation worker, minimizing main-thread blocking
  ///   via [task.policy.chunkSize].
  /// * **Error Handling:** Implements comprehensive logging and context-aware error
  ///   reporting to simplify debugging of complex mapping transformations.
  ///
  /// This method is intended for internal engine use when processing standard
  /// `find` or `findDeletedItems` operations.
  ///
  /// Returns a [Future<List<T>>] containing the fully hydrated and typed model instances.
  Future<List<T>> _executeFindTaskOnMain(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<Object?>? whereArgs = task.helper?.whereArgs;
    final String? orderBy = task.helper?.orderBy;
    final int? limit = task.helper?.limit;
    final int? offset = task.helper?.offset;

    FluentLog.debug(
      'Executing Main-thread customized structured query selection routine',
      tag: '$tableName:findExecutor',
      context: {'tableName': tableName, 'taskId': task.id, 'hasWhereClause': where != null, 'hasOrderBy': orderBy != null, 'limit': limit ?? 'unlimited', 'offset': offset ?? 0},
    );

    try {
      // Execute the fully dynamic structured query directly against the underlying driver
      final List<Map<String, dynamic>> maps = await executor.query(tableName, where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit, offset: offset);

      final int resultLength = maps.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer customized selection query', tag: '$tableName:findExecutor', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Custom structured database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:findExecutor',
        context: {'tableName': tableName, 'taskId': task.id, 'retrievedRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(maps[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for customized query finalized safely',
          tag: '$tableName:findExecutor',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs via the unified row worker
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(maps, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.effectiveChunkSize);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for customized query finalized safely',
        tag: '$tableName:findExecutor',
        context: {
          'tableName': tableName,
          'taskId': task.id,
          'materializedInstances': typedItems.length,
          'chunkSize': task.policy.effectiveChunkSize,
          'optimizationApplied': 'batched_cascade_enrichment',
        },
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread customized query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception:findExecutor',
        hint: 'Examine raw query variables, inspect column syntax constraints, or audit model mapping transformations.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }
}
