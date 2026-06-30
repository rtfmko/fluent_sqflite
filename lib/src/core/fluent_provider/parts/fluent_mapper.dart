// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_provider.dart';

/// Enterprise-grade data mapping and serialization engine for [FluentProvider].
///
/// The [FluentMapper] extension facilitates the high-performance translation
/// between raw relational database records (Maps) and typed domain models ([T]).
/// It serves as the bidirectional "Codec" layer for the persistence system.
///
/// ### Core Responsibilities & Functional Domains
///
/// * **Hydration Pipeline ([mapToModelSync], [mapToModelsSync]):** Orchestrates
///   the transformation of raw SQL `Map` results into fully realized domain entities.
///   It handles deep object-graph assembly, including the recursive resolution of
///   nested relationships defined via [FluentRelationsMixin].
/// * **Asynchronous Batch Processing ([mapToModelsAsync]):** Manages heavy
///   transformation loads by offloading object instantiation to isolated compute
///   batches, preventing main-thread blocking and frame drops.
/// * **Serialization ([_prepareSqlJson]):** Performs strict structural validation
///   and sanitization before data is committed to SQLite. It ensures only schema-defined
///   columns are persisted while injecting system-level metadata.
/// * **Dynamic Type Resurrection ([_sanitizeValue]):** Bridges the gap between
///   SQLite's limited primitive types and Dart's rich type system (e.g., `DateTime`,
///   `Color`, `Enum`, `JSON`) by encoding type-hints into the database row metadata.
///
/// ### Architectural Contract
/// This extension is the primary consumer of the schema definition provided by
/// `FluentProviderSchema`. It relies on the provider's `tableColumns`, `relationKeys`,
/// and `tableConfig` to enforce data integrity during both storage and retrieval.
///
/// See also:
/// * [FluentLog], for structured audit tracing of serialization/hydration events.
/// * [FluentTask], for policy-driven execution of asynchronous hydration.
extension FluentMapper<T extends FluentStorable> on FluentProvider<T> {
  /// Transforms a raw database result map into a fully hydrated domain model instance,
  /// including the resolution of nested relational objects.
  ///
  /// This mapping engine performs two-pass hydration:
  /// 1. Primary Assembly: Translates base columns into the model instance.
  /// 2. Relational Hydration: Detects `FluentRelationsMixin` definitions to inject nested
  ///    models (one-to-many or many-to-one) into the hydrated instance.
  ///
  /// [enrichedRow] The raw map returned from a `JOIN` or `SELECT` query.
  ///
  /// Returns a hydrated model [T] populated with its relational graph.
  T mapToModelSync(Map<String, dynamic> enrichedRow) {
    if (!_hasRelations || _relationsMixin == null) {
      return _assembleModel(enrichedRow);
    }

    final T model = _assembleModel(enrichedRow);
    final Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> syncRels = _relationsMixin!.resolvedRelations;

    FluentLog.debug('Hydrating relational graph for model', tag: '$tableName:hydration', context: {'modelId': model.primaryKey.name, 'relationalKeys': syncRels.keys.toString()});

    for (final FluentDbRelation<FluentStorable, FluentStorable> rel in syncRels.values) {
      final String key = rel.mapToKey;
      final dynamic data = enrichedRow[key];

      if (data == null) continue;
      try {
        final FluentProvider childDao = FluentDb.providerForType(rel.modelType);

        if (data is List && rel.castType == FluentModelCast.modelList) {
          if (data.isEmpty) {
            model.setRelation(key, childDao._createTypedList(<FluentStorable>[]));
            continue;
          }

          if (data[0] is! FluentStorable) {
            final int len = data.length;
            final List<FluentStorable> childModels = List<FluentStorable>.filled(len, childDao.modelSample, growable: false);

            for (int i = 0; i < len; i++) {
              final item = data[i];
              final Map<String, dynamic> childRow = item is Map<String, dynamic> ? item : (item as Map).cast<String, dynamic>();
              childModels[i] = childDao._assembleModel(childRow);
            }

            model.setRelation(key, childDao._createTypedList(childModels));
          }
        } else if (data is Map && rel.castType == FluentModelCast.model) {
          if (data is! FluentStorable) {
            model.setRelation(key, childDao._assembleModel(data.cast<String, dynamic>()));
          }
        }
      } catch (e, s) {
        FluentLog.error('Failed to hydrate relation key "$key" during mapping', e, s, tag: '$tableName:hydration', context: {'key': key, 'relType': rel.relationType.toString()});
        rethrow;
      }
    }

    return model;
  }

  /// Asynchronously transforms a raw database row into a fully hydrated domain model [T],
  /// with support for deep relational graph resolution and concurrency-aware execution.
  ///
  /// This method serves as the high-level gateway for asynchronous data hydration:
  /// * Task Encapsulation: Packages the transformation requirements (depth, laziness,
  ///   and policies) into a [FluentTask] for unified pipeline processing.
  /// * Data Enrichment: Invokes [_processRow] to resolve missing relational fields
  ///   or deferred data points through the asynchronous microtask worker pool.
  /// * Synchronous Completion: Once the row is enriched with full relational data,
  ///   it delegates to [mapToModelSync] to perform the final object graph assembly.
  ///
  /// [row] The raw database record (map) to be hydrated.
  /// [maxDepth] Defines the recursion limit for resolving nested relational models.
  /// [ignoreLazy] If true, forces the resolution of all lazy-loaded associations.
  /// [policy] Determines execution constraints, such as threading priority or timeout limits.
  ///
  /// Returns a Future that resolves to the fully hydrated domain model [T].
  Future<T> mapToModelAsync(Map<String, dynamic> row, {int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final FluentTask task = FluentTask(
      action: FluentDbAction.rawGetItem,
      table: tableName,
      dbName: dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(multiple: false, dataMap: row),
      policy: policy,
    );

    final List<Map<String, dynamic>> enrichedList = await _processRowsBatch([row], task);

    return mapToModelSync(enrichedList.first);
  }

  /// Transforms a list of raw database result maps into a list of hydrated domain models,
  /// including the resolution of nested relational objects for all instances.
  ///
  /// This batch processor provides optimized bulk hydration:
  /// * Pre-allocated Collection: Uses `List.filled` to avoid excessive memory re-allocation.
  /// * Relational Pipeline: Reuses existing relational resolution logic to ensure consistency
  ///   between single-item and bulk data hydration.
  /// * Performance Telemetry: Provides visibility into the complexity of the batch transformation.
  ///
  /// [rows] The raw list of database rows to be hydrated.
  ///
  /// Returns a list of fully hydrated domain models [T].
  List<T> mapToModelsSync(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return <T>[];

    final int rowsLength = rows.length;

    if (!_hasRelations || _relationsMixin == null) {
      final List<T> models = List<T>.filled(rowsLength, modelSample, growable: false);
      for (int i = 0; i < rowsLength; i++) {
        models[i] = _assembleModel(rows[i]);
      }
      return models;
    }

    FluentLog.debug('Initiating bulk relational hydration', tag: '$tableName:hydration', context: {'rowCount': rowsLength});

    final Map<Type, FluentDbRelation> syncRels = _relationsMixin!.resolvedRelations;
    final List<T> models = List<T>.filled(rowsLength, modelSample, growable: false);

    for (int index = 0; index < rowsLength; index++) {
      final Map<String, dynamic> enrichedRow = rows[index];

      final T model = _assembleModel(enrichedRow);

      for (final FluentDbRelation<FluentStorable, FluentStorable> rel in syncRels.values) {
        final String key = rel.mapToKey;
        final dynamic data = enrichedRow[key];

        if (data == null) continue;

        try {
          final FluentProvider childDao = FluentDb.providerForType(rel.modelType);
          if (data is List && rel.castType == FluentModelCast.modelList) {
            if (data.isEmpty) {
              model.setRelation(key, childDao._createTypedList(<FluentStorable>[]));
              continue;
            }

            if (data[0] is! FluentStorable) {
              final int len = data.length;
              final List<FluentStorable> childModels = List<FluentStorable>.filled(len, childDao.modelSample, growable: false);

              for (int i = 0; i < len; i++) {
                final item = data[i];
                final Map<String, dynamic> childRow = item is Map<String, dynamic> ? item : (item as Map).cast<String, dynamic>();
                childModels[i] = childDao._assembleModel(childRow);
              }

              model.setRelation(key, childDao._createTypedList(childModels));
            }
          } else if (data is Map && rel.castType == FluentModelCast.model) {
            if (data is! FluentStorable) {
              model.setRelation(key, childDao._assembleModel(data.cast<String, dynamic>()));
            }
          }
        } catch (e, s) {
          FluentLog.error('Failed to hydrate relation in batch index $index', e, s, tag: '$tableName:hydration', context: {'key': key, 'modelId': model.primaryKey.name});
          rethrow;
        }
      }

      models[index] = model;
    }

    FluentLog.debug('Bulk hydration complete', tag: '$tableName:hydration');
    return models;
  }

  /// Asynchronously transforms a list of raw database rows into a list of hydrated
  /// domain models [T], delegating processing to a batched compute isolate.
  ///
  /// This method enables high-performance bulk data retrieval:
  /// * Compute Isolation: Offloads the transformation and relational hydration logic
  ///   to a background computation pool, preventing main-thread blocking during
  ///   heavy object-graph assembly.
  /// * Batch Execution: Uses the internal `_computeBatched` utility to manage
  ///   concurrency and resource limits during large data set processing.
  ///
  /// [rows] The raw list of database records (maps) to be transformed.
  ///
  /// Returns a Future that resolves to a list of fully hydrated domain models [T].
  Future<List<T>> mapToModelsAsync(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return <T>[];

    return await _computeBatched<Map<String, dynamic>, T>(rows, (row) => mapToModelAsync(row));
  }

  /// Dispatches raw database responses through the appropriate hydration pipeline
  /// based on the performed database action.
  ///
  /// This transformation gateway serves two primary purposes:
  /// * Schema Hydration: Detects result sets (lists or individual maps) and triggers
  ///   asynchronous model assembly, ensuring heavy object-graph building is non-blocking.
  /// * Pipeline Orchestration: Acts as a middleware filter, passing non-transformation
  ///   actions (like `DELETE` or `INSERT` returns) through to the application layer.
  ///
  /// [data] The raw response payload from the database engine.
  /// [action] The [FluentDbAction] context used to determine the transformation strategy.
  ///
  /// Returns a Future that resolves to the hydrated model(s) or the original data.
  Future<dynamic> transformResponseAsync(dynamic data, FluentDbAction action) async {
    if (data == null) return null;

    // Route for hydration-eligible actions
    if (action == FluentDbAction.find || action == FluentDbAction.findById || action == FluentDbAction.findItemsBy) {
      // Handle List responses (Collections)
      if (data is List) {
        if (data.isEmpty) return <T>[];

        final List<Map<String, dynamic>> rows;

        if (data is List<Map<String, dynamic>>) {
          rows = data;
        } else {
          final int len = data.length;
          rows = List<Map<String, dynamic>>.filled(len, const <String, dynamic>{}, growable: false);

          for (int i = 0; i < len; i++) {
            final item = data[i];
            rows[i] = item is Map<String, dynamic> ? item : Map<String, dynamic>.from(item as Map);
          }
        }

        final List<T> models = await mapToModelsAsync(rows);
        FluentLog.debug('Hydration complete for list', tag: '$tableName:transform', context: {'count': models.length});

        return _createTypedList(models);
      }

      // Handle Map responses (Single entities)
      if (data is Map) {
        final Map<String, dynamic> row = data is Map<String, dynamic> ? data : Map<String, dynamic>.from(data);

        return await mapToModelAsync(row);
      }
    }

    return data;
  }

  /// Prepares a domain model [T] for SQL persistence by sanitizing values,
  /// filtering non-column properties, and injecting system-level metadata.
  ///
  /// This routine executes the serialization bridge:
  /// * Data Sanitization: Validates types and converts complex Dart objects to
  ///   SQL-compatible primitives (e.g., ISO strings, numeric timestamps).
  /// * Metadata Injection: Automatically serializes type-specific metadata (e.g.,
  ///   JSON-encoded specialized types) into the reserved `_metadata` column.
  /// * Column Filtering: Strips out transient properties (relational keys) that
  ///   should not be written directly into the main table row.
  ///
  /// [item] The domain model instance to serialize.
  /// Returns a sanitized map ready for insertion or update into the SQL driver.
  Map<String, dynamic> _prepareSqlJson(T item) {
    final Map<String, dynamic> rawJson = item.buildJson();

    // Inject internal filesystem/system metadata if present
    final Map<String, dynamic> metadata = item.fsMetadataInternal;
    if (metadata.isNotEmpty) {
      rawJson.addAll(metadata);
    }

    final Set<String> relKeys = relationKeys;
    final Set<String> validColumns = tableColumns;
    final Map<String, dynamic> finalSqlJson = {};
    Map<String, String>? typeMetadata;

    FluentLog.debug('Serializing model for SQL persistence', tag: '$tableName:serialization', context: {'modelId': item.primaryKey.name, 'columnCount': rawJson.length});

    for (final MapEntry<String, dynamic> entry in rawJson.entries) {
      final String key = entry.key;
      final dynamic value = entry.value;

      if (relKeys.contains(key)) {
        finalSqlJson[key] = value;
        continue;
      }

      if (!validColumns.contains(key)) {
        continue;
      }

      final ({dynamic value, String? metaType}) result = _sanitizeValue(value);
      finalSqlJson[key] = result.value;

      if (result.metaType != null) {
        typeMetadata ??= {};
        typeMetadata[key] = result.metaType!;
      }
    }

    if (typeMetadata != null && typeMetadata.isNotEmpty) {
      finalSqlJson[FluentDbColumn.systemMetadata().name] = jsonEncode(typeMetadata);
    }

    if (item is FluentSoftDeletable) {
      finalSqlJson[(item as FluentSoftDeletable).softDeleteColumn] = item.deletedAt?.toIso8601String();
    }

    final DateTime? effectiveExpiryDate = item.expiryDate ?? (item.expiryDuration != null ? DateTime.now().add(item.expiryDuration!) : null);

    final int? expiry = effectiveExpiryDate?.millisecondsSinceEpoch;
    if (expiry != null) {
      finalSqlJson[modelSample.expiryColumn] = expiry;
    }

    FluentLog.debug('Serialization complete', tag: '$tableName:serialization', context: {'finalColumnCount': finalSqlJson.length});
    return finalSqlJson;
  }

  /// Recursively hydrates a database row by resolving relational dependencies
  /// and performing type-sanitization for complex column types.
  ///
  /// This routine orchestrates the asynchronous "Graph Enrichment" process:
  /// * Depth Management: Prevents cyclic dependency overflows with a recursive limit.
  /// * Type Sanitization: Decodes complex types (Enum, DateTime, JSON) from metadata.
  /// * Relational Graph Hydration: Recursively fetches and stitches related records
  ///   based on the [FluentDbRelation] definitions and execution [FluentTask] policy.
  Future<List<Map<String, dynamic>>> _processRowsBatch(List<Map<String, dynamic>> rows, FluentTask task, {Set<String>? visitedTables, int currentDepth = 0}) async {
    if (rows.isEmpty) return rows;

    if (currentDepth >= 30) {
      FluentLog.warning('Safety recursion limit reached', tag: '$tableName:hydration', hint: 'Possible circular dependency detected in relational model mapping.');
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }

    final List<Map<String, dynamic>> processedRows = rows.map((r) => Map<String, dynamic>.from(r)).toList();

    final Set<String> currentVisited = visitedTables ?? <String>{};
    currentVisited.add(tableName);

    // Stage 1: Type Sanitization
    if (tableConfig.sanitizeTypes) {
      processedRows.forEach(_sanitizeRowInPlace);
    }

    // Stage 2: Relational Hydration
    if (!_hasRelations || _relationsMixin == null) {
      currentVisited.remove(tableName);
      return processedRows;
    }

    // Local cast
    for (int i = 0; i < processedRows.length; i++) {
      processedRows[i] = _castReadyRelations(processedRows[i]);
    }

    final Map<Type, FluentDbRelation> relations = _relationsMixin!.resolvedRelations;
    if (relations.isEmpty) {
      currentVisited.remove(tableName);
      return processedRows;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    // Take all parents ID
    final List<dynamic> parentIds = processedRows.map((r) => r[pkName]).where((id) => id != null).toSet().toList();

    if (parentIds.isEmpty) {
      currentVisited.remove(tableName);
      return processedRows;
    }

    final int nextDepth = currentDepth + 1;
    final int maxDepth = task.maxDepth;
    final bool ignoreLazy = task.ignoreLazy;
    final int chunkSize = task.policy.chunkSize ?? 950;

    for (final MapEntry<Type, FluentDbRelation<FluentStorable, FluentStorable>> entry in relations.entries) {
      final FluentDbRelation rel = entry.value;
      final String key = rel.mapToKey;
      final FluentProvider childDao = FluentDb.providerForType(entry.key);

      FluentLog.warning(
        'Debugging case',
        tag: 'debug',
        hint: 'Debug',
        context: {
          'task.dbName': task.dbName,
          'task': task.toString(),
          'childDao.dbName': childDao.dbName,
          'childDao.tableName': childDao.tableName,
          'childDao.hashCode': childDao.hashCode,
          'entryType': entry.key,
          'entry.value.modelType': entry.value.modelType,
          'entry.value.pivotTable': entry.value.pivotTable,
          'tableName': tableName,
        },
      );

      // Depth & Lazy Load Control
      if ((rel.isLazy && !ignoreLazy) || (maxDepth != 0 && nextDepth > maxDepth)) {
        for (final Map<String, dynamic> row in processedRows) {
          if (row[key] == null) {
            row['_unloaded_relations'] ??= <String>[];
            final List<String> unloaded = row['_unloaded_relations'] as List<String>;

            if (!unloaded.contains(key)) {
              unloaded.add(key);
            }
          }
        }
        continue;
      }

      if (currentVisited.contains(childDao.tableName)) continue;

      try {
        final String remoteKey = rel.remoteKey ?? childDao.defaultForeignKey;
        final List<Map<String, dynamic>> allRawChildren = [];

        for (int i = 0; i < parentIds.length; i += chunkSize) {
          final int end = (i + chunkSize > parentIds.length) ? parentIds.length : i + chunkSize;
          final List<dynamic> chunk = parentIds.sublist(i, end);
          final String placeholders = List.filled(chunk.length, '?').join(',');

          List<Map<String, dynamic>> results;

          if (rel.relationType == FluentDbRelationType.manyToMany) {
            final String pivot = rel.pivotTable!;
            final String localKey = rel.localKey ?? defaultForeignKey;
            final String childTable = childDao.tableName;
            final String childPk = childDao.primaryKeyColumn.name;

            final String sql =
                '''
              SELECT t.*, p.$localKey AS _fluent_pivot_parent_id
              FROM $childTable t
              INNER JOIN $pivot p ON t.$childPk = p.$remoteKey
              WHERE p.$localKey IN ($placeholders)
            ''';

            FluentLog.sql(sql, arguments: chunk, tag: '$tableName:hydration:m2m');
            results = await childDao.db.rawQuery(sql, chunk);
          } else {
            results = await childDao.db.query(childDao.tableName, where: '$remoteKey IN ($placeholders)', whereArgs: chunk);
          }

          allRawChildren.addAll(results);
        }

        FluentLog.debug('Enriching relation (Batch)', tag: '$tableName:hydration', context: {'key': key, 'childCount': allRawChildren.length, 'parents': parentIds.length});

        List<Map<String, dynamic>> enrichedChildren = [];

        // Рекурсивно обрабатываем детей ТОЖЕ пачкой!
        if (allRawChildren.isNotEmpty) {
          enrichedChildren = await childDao._processRowsBatch(allRawChildren, task, visitedTables: {...currentVisited}, currentDepth: nextDepth);
        }

        // Memory Join: Группируем детей по ключу родителя
        final Map<dynamic, List<Map<String, dynamic>>> groupedChildren = {};
        for (var child in enrichedChildren) {
          final pId = child['_fluent_pivot_parent_id'] ?? child[remoteKey];
          groupedChildren.putIfAbsent(pId, () => []).add(child);
        }

        for (final Map<String, dynamic> row in processedRows) {
          if (row[key] is List<FluentStorable> || row[key] is FluentStorable) {
            continue;
          }

          final dynamic pId = row[pkName];
          final List<Map<String, dynamic>> matches = groupedChildren[pId] ?? [];

          // Final Mapping Logic
          if (rel.castType == FluentModelCast.modelList) {
            if (matches.isEmpty && rel.nullable) {
              row[key] = null;
            } else {
              final List<FluentStorable> childModels = matches.map((m) => childDao._assembleModel(m)).toList(growable: false);
              row[key] = childDao._createTypedList(childModels);
            }
          } else if (rel.castType == FluentModelCast.model) {
            row[key] = matches.isNotEmpty ? childDao._assembleModel(matches.first) : null;
          } else {
            row[key] = rel.castType == FluentModelCast.mapList ? matches : (matches.isNotEmpty ? matches.first : null);
          }
        }
      } catch (e, st) {
        FluentLog.error('Relational batch enrichment failed for key: ${rel.mapToKey}', e, st, tag: '$tableName:hydration');
      }
    }

    currentVisited.remove(tableName);
    return processedRows;
  }

  void _sanitizeRowInPlace(Map<String, dynamic> processedRow) {
    final String metaKey = FluentDbColumn.systemMetadata().name;
    final Object? metaRaw = processedRow[metaKey];

    if (metaRaw is String && metaRaw.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(metaRaw) as Map<String, dynamic>;

        for (final String key in decoded.keys) {
          final dynamic value = processedRow[key];
          if (value == null) continue;

          final String typeHint = decoded[key].toString();
          switch (typeHint) {
            case 'bool':
              processedRow[key] = value == 1;
              break;
            case 'datetime':
              processedRow[key] = value is int ? DateTime.fromMillisecondsSinceEpoch(value) : DateTime.tryParse(value.toString());
              break;
            case 'json':
              if (value is String) processedRow[key] = jsonDecode(value);
              break;
            case 'enum':
              final List<Enum>? values = modelSample.enumValues[key];
              if (values != null) {
                processedRow[key] = tableConfig.storeEnumsAsNames ? values.byName(value.toString()) : values[value as int];
              }
              break;
          }
        }
      } catch (e, s) {
        FluentLog.error('Failed to sanitize row metadata', e, s, tag: '$tableName:hydration');
      }
      processedRow.remove(metaKey);
    }
  }

  Map<String, dynamic> _castReadyRelations(Map<String, dynamic> processedRow) {
    if (!_hasRelations || _relationsMixin == null) return processedRow;

    final Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> relations = _relationsMixin!.resolvedRelations;
    if (relations.isEmpty) return processedRow;

    Map<String, dynamic> result = processedRow;

    for (final MapEntry<Type, FluentDbRelation<FluentStorable, FluentStorable>> entry in relations.entries) {
      final FluentDbRelation rel = entry.value;
      final String key = rel.mapToKey;

      if (result.containsKey(key)) {
        final dynamic rawData = result[key];
        final FluentProvider childDao = FluentDb.providerForType(entry.key);

        if (rawData == null) {
          if (!rel.nullable && rel.castType == FluentModelCast.modelList) {
            if (identical(result, processedRow)) {
              result = Map<String, dynamic>.from(processedRow);
            }
            result[key] = childDao._createTypedList([]);
          }
          continue;
        }

        if (rawData is List<FluentStorable> || rawData is FluentStorable) {
          continue;
        }

        try {
          // Transformation logic
          if (rel.castType == FluentModelCast.modelList && rawData is List) {
            final int len = rawData.length;

            if (len == 0 && rel.nullable) {
              if (identical(result, processedRow)) {
                result = Map<String, dynamic>.from(processedRow);
              }
              result[key] = null;
              continue;
            }

            if (len == 0) {
              if (identical(result, processedRow)) {
                result = Map<String, dynamic>.from(processedRow);
              }
              result[key] = childDao._createTypedList([]);
              continue;
            }

            final List<FluentStorable> childModels = List<FluentStorable>.filled(len, childDao.modelSample, growable: false);

            for (int i = 0; i < len; i++) {
              final dynamic item = rawData[i];
              final Map<String, dynamic> childMap = item is Map<String, dynamic> ? item : (item as Map).cast<String, dynamic>();

              childModels[i] = childDao._assembleModel(childMap);
            }

            if (identical(result, processedRow)) {
              result = Map<String, dynamic>.from(processedRow);
            }
            result[key] = childDao._createTypedList(childModels);
          } else if (rel.castType == FluentModelCast.model && rawData is Map) {
            final Map<String, dynamic> childMap = rawData is Map<String, dynamic> ? rawData : rawData.cast<String, dynamic>();

            if (identical(result, processedRow)) {
              result = Map<String, dynamic>.from(processedRow);
            }
            result[key] = childDao._assembleModel(childMap);
          }
        } catch (e, st) {
          FluentLog.error('Failed to cast relational field', e, st, tag: '$tableName:hydration', context: {'key': key});
        }
      }
    }

    return result;
  }

  /// Executes a computationally expensive task on a large list of items in
  /// manageable chunks to prevent main-thread starvation and memory spikes.
  ///
  /// * Batching: Breaks down large lists into smaller sub-lists to manage memory pressure.
  /// * Non-Blocking: Utilizes `Future.delayed(Duration.zero)` between chunks to
  ///   allow the event loop to process pending UI frames, keeping the application responsive.
  /// * Parallelization: Executes items within a single batch concurrently using `Future.wait`.
  ///
  /// [items] The source list of objects.
  /// [processor] The async transformation function applied to each item.
  /// [batchSize] The number of items to process in a single concurrent chunk.
  Future<List<R>> _computeBatched<TRaw, R>(List<TRaw> items, Future<R> Function(TRaw) processor, {int batchSize = 50}) async {
    if (items.isEmpty) return <R>[];

    final int totalItems = items.length;

    if (totalItems <= batchSize) {
      final List<Future<R>> futures = List<Future<R>>.generate(totalItems, (index) => processor(items[index]), growable: false);
      return await Future.wait(futures);
    }

    FluentLog.debug('Initiating batched processing', tag: '$tableName:batch', context: {'totalItems': totalItems, 'batchSize': batchSize});

    final List<R> results = List<R>.filled(totalItems, null as R);

    for (int i = 0; i < totalItems; i += batchSize) {
      final int end = (i + batchSize < totalItems) ? i + batchSize : totalItems;
      final int currentChunkLength = end - i;

      FluentLog.debug('Processing chunk', tag: '$tableName:batch', context: {'range': '${i + 1} to $end', 'total': totalItems});

      final List<Future<R>> chunkFutures = List<Future<R>>.generate(currentChunkLength, (index) => processor(items[i + index]), growable: false);

      final List<R> processedChunk = await Future.wait(chunkFutures);

      for (int j = 0; j < currentChunkLength; j++) {
        results[i + j] = processedChunk[j];
      }

      if (end < totalItems) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    FluentLog.info('Batched processing completed', tag: '$tableName:batch', context: {'totalProcessed': totalItems});

    return results;
  }

  /// Sanitizes Dart domain types into SQLite-compatible primitives while tracking
  /// structural metadata for accurate reconstruction.
  ///
  /// This method acts as the serialization gateway:
  /// * Primitive Passthrough: Allows `String`, `num`, and `Uint8List` to persist without overhead.
  /// * Type Coercion: Maps high-level types (e.g., `DateTime`, `Enum`, `Color`) into
  ///   SQL-compliant formats (timestamps, indices, or hex/integer equivalents).
  /// * Metadata Tracking: Returns an optional [metaType] hint which is stored in the
  ///   system metadata column, enabling strict type-resurrection during hydration.
  ///
  /// [value] The raw field value from the domain model.
  /// Returns a record containing the sanitized value and its associated type identifier.
  ({dynamic value, String? metaType}) _sanitizeValue(dynamic value) {
    if (value == null) return (value: null, metaType: null);

    if (value is String || value is num || value is Uint8List) {
      return (value: value, metaType: null);
    }

    if (value is bool) return (value: value ? 1 : 0, metaType: 'bool');

    if (value is DateTime) {
      final dynamic formattedDate = tableConfig.dateTimeFormat == FluentDateTimeFormat.timestamp ? value.millisecondsSinceEpoch : value.toIso8601String();
      return (value: formattedDate, metaType: 'datetime');
    }

    if (value is Map || value is List) {
      try {
        return (value: jsonEncode(value), metaType: 'json');
      } catch (_) {
        throw InvalidSqlTypeException(tableName, value);
      }
    }

    if (value is Enum) {
      final dynamic formattedEnum = tableConfig.storeEnumsAsNames ? value.name : value.index;
      return (value: formattedEnum, metaType: 'enum');
    }

    if (value is Color) return (value: value.toARGB32(), metaType: 'color');

    if (value is Uri) return (value: value.toString(), metaType: 'uri');

    throw InvalidSqlTypeException(tableName, value);
  }
}
