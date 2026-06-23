// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_provider.dart';

/// Enterprise data-layer extension providing relational traversal, integrity maintenance, and lazy-loading hydration for [FluentProvider].
///
/// The [FluentProviderRelations] extension acts as the primary orchestration engine for cross-table
/// relational workflows. It encapsulates the complexity of relational persistence,
/// ensuring that complex entity graphs remain consistent during transactional mutations.
///
/// ### Core Responsibilities & Functional Domains
///
/// * **Transactional Relational Hydration:** Manages the propagation of relational state through deep-update
///   pipelines. It handles recursive batch processing of associated entities, ensuring that
///   parent-child relationships are atomically committed within the same database transaction.
/// * **Referential Integrity Auditing:** Provides automated orphan cleanup routines that scan for and
///   purge relational fragments (child rows) that no longer have valid parent references. This
///   maintenance routine utilizes high-performance SQL `NOT EXISTS` patterns to enforce database
///   normalization without loading massive datasets into memory.
/// * **Lazy-Loading Hydration ([ensureLoaded]):** Implements "just-in-time" data resolution. It selectively
///   hydrates deferred associations from the persistent storage layer only when requested,
///   drastically reducing memory footprint and initial query latency for large object graphs.
/// * **Relational Mapping & Resolution:** Bridges the gap between flat SQL result sets and structured
///   object graphs. It handles polymorphic resolution, foreign key injection, and pivot-table
///   linkage (many-to-many), abstracting the underlying schema implementation from the business domain.
/// * **High-Fidelity Observability:** Integrates with the [FluentLog] facade to provide structured diagnostic
///   tracing. This includes SQL audit logs, relational hydration performance metrics, and integrity
///   audit results, facilitating rapid debugging of complex transactional cascades.
///
/// ### Architectural Contract
/// This extension requires the underlying [FluentProvider] to support the [FluentRelationsMixin],
/// which provides the necessary metadata definitions for [resolvedRelations], foreign keys, and
/// relational configuration.
///
/// See also:
/// * [FluentRelationsMixin], the structural foundation for relational-aware providers.
/// * [FluentTask], the container for transactional operations and relational dependency metadata.
extension FluentRelations<T extends FluentStorable> on FluentProvider<T> {
  /// Executes a relational integrity audit to purge orphaned child records from the storage layer.
  ///
  /// This maintenance routine ensures that child entities lacking a valid parent reference
  /// are permanently removed, maintaining strict database normalization:
  /// * Performs selective scans across associated tables flagged with [onDeleteCascade].
  /// * Utilizes `NOT EXISTS` query patterns to identify rows in child tables that no longer correspond
  ///   to valid primary keys in the parent storage container.
  /// * Supports standard, polymorphic, and one-to-many cardinality integrity checks.
  /// * Propagates the [executor] handle to ensure this maintenance runs inside the existing atomic transaction.
  ///
  /// [executor] represents the active database connection context used to perform the deletion.
  Future<void> cleanupOrphans(DatabaseExecutor executor) async {
    // Early Exit: Terminate if the provider lacks relational metadata or is unconfigured
    if (!_hasRelations || _relationsMixin == null) return;

    final FluentRelationsMixin<T> mixin = _relationsMixin!;
    final Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> syncRels = mixin.resolvedRelations;
    if (syncRels.isEmpty) return;

    final String parentPk = _cachedPrimaryKey?.name ?? 'id';
    final String currentTable = tableName;

    final Set<String> localColumns = tableColumns;

    // Iterate over active relations to perform reference integrity audits
    for (final MapEntry<Type, FluentDbRelation<FluentStorable, FluentStorable>> entry in syncRels.entries) {
      final FluentDbRelation rel = entry.value;

      // Filter: Skip relations without cascade requirements or unsupported complex associations
      if (!rel.onDeleteCascade || rel.relationType == FluentDbRelationType.manyToMany) {
        continue;
      }

      final FluentProvider childProvider = FluentDb.providerForType(entry.key);

      final String childTable = childProvider.tableName;

      String sql = '';
      List<Object?> args = const [];

      final String? effectiveRemoteKey = rel.remoteKey ?? resolveRemoteKey(childProvider);

      // Branch: Apply specific deletion logic based on the cardinality of the relation
      if (rel.relationType == FluentDbRelationType.oneToMany || rel.relationType == FluentDbRelationType.auto) {
        if (effectiveRemoteKey == null) continue;

        if (rel.isPolymorphic) {
          final String typeCol = rel.polyTypeColumn ?? 'parent_type';

          sql =
              '''
          DELETE FROM $childTable 
          WHERE $typeCol = ? 
            AND NOT EXISTS (
              SELECT 1 FROM $currentTable 
              WHERE $currentTable.$parentPk = $childTable.$effectiveRemoteKey
            )
        ''';
          args = [currentTable];
        } else {
          sql =
              '''
          DELETE FROM $childTable 
          WHERE $effectiveRemoteKey IS NOT NULL 
            AND NOT EXISTS (
              SELECT 1 FROM $currentTable 
              WHERE $currentTable.$parentPk = $childTable.$effectiveRemoteKey
            )
        ''';
        }
      } else {
        final String? lKey = rel.localKey;
        if (lKey == null || lKey.isEmpty) continue;

        if (!localColumns.contains(lKey)) {
          continue;
        }

        final String childPk = childProvider._cachedPrimaryKey?.name ?? 'id';

        sql =
            '''
        DELETE FROM $childTable 
        WHERE NOT EXISTS (
          SELECT 1 FROM $currentTable 
          WHERE $currentTable.$lKey = $childTable.$childPk
        )
      ''';
      }

      if (sql.isNotEmpty) {
        try {
          FluentLog.sql(sql, arguments: args, tag: '$tableName:cleanupOrphans:sql');

          final int count = await executor.rawDelete(sql, args);

          if (count > 0) {
            FluentLog.debug(
              'Relational integrity audit finalized: Orphaned records purged from child storage',
              tag: '$tableName:cleanupOrphans',
              context: {'parentTable': currentTable, 'childTable': childTable, 'orphanedRowsRemoved': count},
            );
          }
        } catch (e, st) {
          FluentLog.error(
            'Relational orphan cleanup sequence aborted due to execution driver failure',
            e,
            st,
            tag: '$tableName:cleanupOrphans',
            hint: 'Verify foreign key indexing on the child table and check for referential locking constraints.',
            context: {'childTable': childTable},
          );
        }
      }
    }
  }

  /// Coordinates a batched, recursive persistence pipeline for domain entities and their relational graphs.
  ///
  /// This orchestration engine manages deep-object structural writes using batched transaction blocks:
  /// * Recursive Depth Control: Enforces [maxDepth] constraints to prevent stack overflow or circular reference hangs during graph hydration.
  /// * Schema Flattening: Extracts primitive database values from complex objects while stripping relational pointers via [relationKeys].
  /// * Atomic Transaction Management: Dispatches operations into a [Batch] container to minimize I/O overhead on the storage engine.
  /// * ID Back-Propagation: Automatically maps auto-increment primary keys from committed database records back into the [sqlJsonCache] for use by child entities in subsequent recursive calls.
  ///
  /// [txn] The active transaction executor handle, used to propagate unit-of-work state.
  /// [items] The collection of model entities to be persisted to storage.
  /// [task] The global task configuration containing policy and depth metadata.
  Future<void> _executeAdd(
    Transaction? txn,
    List<dynamic> items,
    FluentTask task, {
    Batch? sharedBatch,
    List<Map<String, dynamic>>? parentJsons,
    int currentDepth = 0,
    Set<String>? visitedTables,
  }) async {
    if (items.isEmpty) return;

    // Depth-Limit Enforcement: Prevent infinite recursive loops in complex object graphs
    final int nextDepth = currentDepth + 1;
    final int maxAllowedDepth = (task.action != FluentDbAction.save) ? (task.maxDepth != 0 ? task.maxDepth : 99) : 99;
    if (nextDepth > maxAllowedDepth) {
      FluentLog.warning('Relational depth-limit exceeded; aborting sub-graph hydration', tag: '$tableName:executeAddExecutor', context: {'currentDepth': currentDepth, 'maxDepth': maxAllowedDepth});
      return;
    }

    final int itemsLength = items.length;
    final bool isRootBatch = sharedBatch == null;
    final Batch batch = sharedBatch ?? txn!.batch();

    final bool effectiveUpdateIfExist = task.helper?.updateIfExist ?? false;
    final bool hasRels = _hasRelations && _relationsMixin != null;
    final Set<String> relKeys = relationKeys;

    final List<T>? modelItems = hasRels ? List<T>.filled(itemsLength, modelSample, growable: false) : null;

    List<Map<String, dynamic>>? sqlJsonCache = parentJsons;
    if (sqlJsonCache == null && hasRels) {
      sqlJsonCache = List<Map<String, dynamic>>.filled(itemsLength, const {}, growable: false);
    }

    final Set<String> currentVisited = visitedTables ?? <String>{};
    currentVisited.add(tableName);

    // Iterative Batch Processing: Flatten domain models into SQL-safe maps
    for (int i = 0; i < itemsLength; i++) {
      final dynamic item = items[i];
      if (item is T) {
        if (modelItems != null) {
          modelItems[i] = item;
        }

        final bool useCache = parentJsons != null && i < parentJsons.length && parentJsons[i].isNotEmpty;
        final Map<String, dynamic> rawJson = useCache ? Map<String, dynamic>.from(parentJsons[i]) : _prepareSqlJson(item);

        if (parentJsons == null && sqlJsonCache != null) {
          sqlJsonCache[i] = rawJson;
        }

        // SQL Sanitization: Strip relational keys before table insertion
        final Map<String, dynamic> flatSqlJson = {};
        for (final MapEntry<String, dynamic> entry in rawJson.entries) {
          if (!relKeys.contains(entry.key)) {
            flatSqlJson[entry.key] = entry.value;
          }
        }

        _upsertItemInTxn(batch, flatSqlJson, effectiveUpdateIfExist);
      }
    }

    // Atomic Commit: Finalize root batch and map auto-increment IDs back to cache
    if (isRootBatch) {
      FluentLog.sql('Executing batched upsert operations', tag: '$tableName:sql:executeAddExecutor');

      final List<Object?> results = await batch.commit(noResult: false);
      _checkBatchResults(results);

      if (sqlJsonCache != null) {
        final String pkName = primaryKeyColumn.name;

        for (int i = 0; i < itemsLength; i++) {
          if (i < results.length) {
            final res = results[i];
            if (res is int) {
              if (sqlJsonCache[i].isNotEmpty) {
                sqlJsonCache[i][pkName] = res;
              }
            } else {}
          }
        }
      }
    }

    // Recursive Relational Hydration: Cascade process to child providers
    if (hasRels && modelItems != null) {
      await _relationsMixin!._processBatchRelations(txn, modelItems, task, batch: isRootBatch ? null : batch, parentJsons: sqlJsonCache, currentDepth: nextDepth, visitedTables: currentVisited);
    }

    currentVisited.remove(tableName);
  }

  /// Validates the outcome of a batched transaction, identifying constraint violations or structural execution failures.
  ///
  /// This error-resolution engine scans transactional result arrays for [DatabaseException] signals:
  /// * Error Categorization: Differentiates between standard structural database failures and [DbConstraintException] triggers.
  /// * Diagnostic Capture: Leverages lazy stack-trace initialization to minimize memory overhead unless a failure is identified.
  /// * Exception Propagation: Transforms low-level engine exceptions into domain-specific [DbBatchException] or [DbConstraintException] variants.
  void _checkBatchResults(List<Object?> results) {
    if (results.isEmpty) return;
    StackTrace? lazyStack;

    final int len = results.length;
    for (int i = 0; i < len; i++) {
      final res = results[i];

      // Pass over successful operations (which may return row IDs or void)
      if (res is! DatabaseException) continue;

      // Initialize diagnostic trace only upon detecting an error condition
      final String msg = res.toString();
      lazyStack ??= StackTrace.current;

      // Check for common referential integrity or uniqueness failures
      final bool isConstraint = msg.contains('constraint failed') || msg.contains('UNIQUE') || msg.contains('1555');

      if (isConstraint) {
        FluentLog.error(
          'Batch execution halted due to relational constraint violation',
          res,
          lazyStack,
          tag: '$tableName:crud',
          hint:
              'The data attempted for insertion violates unique identity or foreign key constraints. '
              'Review provided arguments against existing table indices.',
          context: {'failedBatchIndex': i, 'errorMessage': msg},
        );

        throw FluentConstraintException('Batch execution halted due to relational constraint violation (failedBatchIndex: [$i]})', originalError: res, stackTrace: lazyStack);
      }

      FluentLog.error(
        'Batch execution aborted due to unexpected database driver error',
        res,
        lazyStack,
        tag: '$tableName:crud',
        hint:
            'A low-level driver failure occurred. Check for disk space exhaustion, table locks, '
            'or schema mismatches between the model definition and the underlying database.',
        context: {'failedBatchIndex': i, 'errorMessage': msg},
      );

      throw FluentBatchException(tableName, results, originalError: res, stackTrace: lazyStack);
    }
  }

  /// Recursive orchestrator for batch-processing relational dependencies in entity graphs.
  ///
  /// This engine performs complex multi-table coordination during batch operations:
  /// * Graph Traversal: Iterates through defined [resolvedRelations], executing lookups via [FluentDb].
  /// * Identity Conflict Resolution: Detects duplicate object references across the batch and enforces
  ///   idempotent state updates for entities marked with auto-increment keys.
  /// * Cardinality Routing: Automatically dispatches processing to [manyToMany] or [oneOrMany] handlers
  ///   based on the relational schema metadata.
  /// * Telemetry Integration: Emits high-fidelity structure data to [FluentLog] tracking the depth and scale
  ///   of the relational cascade.
  ///
  /// [txn] The active transaction handle for atomic relational binding.
  /// [items] The collection of parent entities being hydrated or persisted.
  /// [task] The current global task operational context.
  Future<void> _processBatchRelations(
    Transaction? txn,
    List<T> items,
    FluentTask task, {
    Batch? batch,
    List<Map<String, dynamic>>? parentJsons,
    int currentDepth = 0,
    Set<String>? visitedTables,
  }) async {
    if (!_hasRelations || _relationsMixin == null) return;

    final Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> relations = _relationsMixin!.resolvedRelations;
    if (relations.isEmpty) return;

    final int nextDepth = currentDepth;
    if (task.maxDepth != 0 && nextDepth > task.maxDepth) {
      return;
    }

    final int itemsLength = items.length;
    final List<Map<String, dynamic>>? localParentJsons = parentJsons;

    for (final MapEntry<Type, FluentDbRelation<FluentStorable, FluentStorable>> entry in relations.entries) {
      final Type childType = entry.key;
      final FluentDbRelation rel = entry.value;

      final FluentProvider childDao = FluentDb.providerForType(childType);

      if (task.action != FluentDbAction.save && rel.isLazy && !task.ignoreLazy) continue;
      if (visitedTables != null && visitedTables.contains(childDao.tableName)) continue;

      final Map<int, List<FluentStorable>> parentIndexToChildren = {};
      final List<FluentStorable> allChildren = [];

      final Set<FluentStorable> globalIdentitySet = {};
      bool hasIdentityConflict = false;

      final FluentDbColumn childPkColumn = childDao.primaryKeyColumn;
      final String childPkName = childPkColumn.name;
      final bool isChildAutoIncrement = childPkColumn.isAutoIncrement;

      for (int i = 0; i < itemsLength; i++) {
        final T parent = items[i];
        final dynamic childrenData = rel.select(parent);

        if (childrenData == null) continue;

        final List<FluentStorable> childrenList;
        if (childrenData is List) {
          if (childrenData.isEmpty) continue;
          childrenList = childrenData.cast<FluentStorable>();
        } else if (childrenData is FluentStorable) {
          childrenList = List<FluentStorable>.filled(1, childrenData, growable: false);
        } else {
          continue;
        }

        final List<FluentStorable> sanitizedChildren = [];

        for (final FluentStorable child in childrenList) {
          FluentStorable effectiveChild = child;

          // IDENTITY RESOLUTION: Prevent duplicate persistence of the same object graph instance
          if (rel.relationType != FluentDbRelationType.manyToMany) {
            if (!globalIdentitySet.add(effectiveChild)) {
              hasIdentityConflict = true;

              final Map<String, dynamic> childJson = effectiveChild.buildJson();
              effectiveChild = (childDao).mapToModelSync(childJson);

              if (isChildAutoIncrement) {
                effectiveChild.injectRelationId(childPkName, null);
              }
            }
          } else {
            globalIdentitySet.add(effectiveChild);
          }

          sanitizedChildren.add(effectiveChild);
          allChildren.add(effectiveChild);
        }

        if (sanitizedChildren.isNotEmpty) {
          parentIndexToChildren[i] = sanitizedChildren;
        }
      }

      if (allChildren.isEmpty) continue;

      FluentLog.debug(
        'Processing nested relational graph associations',
        tag: '$tableName:relations',
        context: {'childType': childType.toString(), 'relationType': rel.relationType.toString(), 'totalChildrenInBatch': allChildren.length},
      );

      FluentTask taskToUse = task;
      if (hasIdentityConflict && !isChildAutoIncrement) {
        taskToUse = task.copyWith(helper: TableHelper(updateIfExist: true));
      }

      if (rel.relationType == FluentDbRelationType.manyToMany) {
        await _processManyToMany(txn, items, parentIndexToChildren, childDao, rel, taskToUse, batch: batch, parentJsons: localParentJsons, currentDepth: nextDepth, visitedTables: visitedTables);
      } else {
        await _processOneOrMany(txn, items, parentIndexToChildren, childDao, rel, taskToUse, batch: batch, parentJsons: localParentJsons, currentDepth: nextDepth, visitedTables: visitedTables);
      }
    }
  }

  /// Coordinates the linkage and batched persistence of one-to-many and many-to-one relational graphs.
  ///
  /// This relational binder ensures structural integrity between parent and child storage containers:
  /// * Foreign Key Injection: Dynamically discovers the parent's primary key and injects it into the
  ///   corresponding child model's relational field via `injectRelationId`.
  /// * Polymorphic Metadata: Automatically tags child entities with parent-table identifiers when
  ///   configured for polymorphic association, enabling proper runtime lookup discrimination.
  /// * Batch Aggregation: Collects all bound child entities into a singular flat list, executing a
  ///   highly optimized batched write via the child provider's `_executeAdd` pipeline.
  ///
  /// [parentIndexToChildren] Maps the index of the parent entity to its associated list of children.
  /// [rel] The relational configuration metadata used to determine mapping keys and polymorphism.
  Future<void> _processOneOrMany(
    Transaction? txn,
    List<T> parents,
    Map<int, List<FluentStorable>> parentIndexToChildren,
    FluentProvider childDao,
    FluentDbRelation rel,
    FluentTask task, {
    Batch? batch,
    List<Map<String, dynamic>>? parentJsons,
    int currentDepth = 0,
    Set<String>? visitedTables,
  }) async {
    final String parentPkName = _cachedPrimaryKey?.name ?? 'id';
    final String? effectiveRemoteKey = rel.remoteKey ?? resolveRemoteKey(childDao);

    if (effectiveRemoteKey == null) {
      FluentLog.warning('Relational binding aborted: Remote key resolution failed', tag: '$tableName:relations', context: {'childTable': childDao.tableName});
      return;
    }

    int totalChildrenCount = 0;
    for (final List<FluentStorable> children in parentIndexToChildren.values) {
      totalChildrenCount += children.length;
    }
    if (totalChildrenCount == 0) return;

    final List<dynamic> fixedRawList = List<dynamic>.filled(totalChildrenCount, childDao.modelSample, growable: false);

    final bool isPolymorphic = rel.isPolymorphic;
    final String polyTypeCol = isPolymorphic ? (rel.polyTypeColumn ?? 'parent_type') : '';
    final String currentTableName = tableName;

    int globalChildIdx = 0;

    // Relational Binding: Inject parent primary keys into child models before persistence
    for (final MapEntry<int, List<FluentStorable>> entry in parentIndexToChildren.entries) {
      final int parentIdx = entry.key;
      final List<FluentStorable> children = entry.value;
      final int currentChildrenLen = children.length;

      dynamic parentId;

      if (parentJsons != null && parentIdx < parentJsons.length && parentJsons[parentIdx].isNotEmpty) {
        parentId = parentJsons[parentIdx][parentPkName];
      } else {
        final T parent = parents[parentIdx];
        parentId = _prepareSqlJson(parent)[parentPkName];
      }

      if (parentId == null) continue;

      for (int i = 0; i < currentChildrenLen; i++) {
        final FluentStorable child = children[i];
        // Link child to parent via foreign key
        child.injectRelationId(effectiveRemoteKey, parentId);

        // Inject polymorphic metadata if the relation architecture demands type-discrimination
        if (isPolymorphic) {
          child.injectRelationId(polyTypeCol, currentTableName);
        }

        fixedRawList[globalChildIdx++] = child;
      }
    }

    // Hydration Pipeline: Finalize typed entity list and delegate to child provider for batch persistence
    final List<FluentStorable> flatChildrenList = childDao._createTypedList(fixedRawList);

    if (flatChildrenList.isNotEmpty) {
      FluentLog.debug(
        'Hydrating relational child batch into storage layer',
        tag: '$tableName:relations',
        context: {'childTable': childDao.tableName, 'count': flatChildrenList.length, 'depth': currentDepth},
      );
      await childDao._executeAdd(txn, flatChildrenList, task, sharedBatch: batch, currentDepth: currentDepth, visitedTables: visitedTables);
    }
  }

  /// Orchestrates the persistence and cross-reference mapping for many-to-many relational associations.
  ///
  /// This specialized routine handles the two-stage lifecycle of many-to-many joins:
  /// * Entity Deduplication: Scans incoming child collections and extracts unique entities to ensure
  ///   idempotent insertions into the child storage layer.
  /// * Batched Pivot Persistence: Maps parent primary keys to child primary keys within the
  ///   intermediate [pivotTable], ensuring atomic referential integrity within the transaction.
  /// * Conflict Resolution: Utilizes [ConflictAlgorithm] to either overwrite or ignore pre-existing
  ///   linkage entries depending on the [FluentTask] configuration.
  ///
  /// [parentIndexToChildren] Maps parent entities to their collection of associated children.
  /// [rel] Metadata containing pivot table naming conventions and foreign key definitions.
  Future<void> _processManyToMany(
    Transaction? txn,
    List<T> parents,
    Map<int, List<FluentStorable>> parentIndexToChildren,
    FluentProvider childDao,
    FluentDbRelation rel,
    FluentTask task, {
    Batch? batch,
    List<Map<String, dynamic>>? parentJsons,
    int currentDepth = 0,
    Set<String>? visitedTables,
  }) async {
    final String parentPkName = _cachedPrimaryKey?.name ?? 'id';
    final String childPkName = childDao._cachedPrimaryKey?.name ?? 'id';

    final String pivotTable = rel.pivotTable ?? '${tableName}_${childDao.tableName}';
    final String pivotParentKey = rel.localKey ?? '${tableName}_id';
    final String pivotChildKey = rel.remoteKey ?? '${childDao.tableName}_id';

    int totalChildrenCount = 0;
    for (final List<FluentStorable> children in parentIndexToChildren.values) {
      totalChildrenCount += children.length;
    }
    if (totalChildrenCount == 0) return;

    final Set<FluentStorable> uniqueChildren = <FluentStorable>{};
    final Map<FluentStorable, FluentStorable> childToRepresentative = Map.identity();

    for (final List<FluentStorable> children in parentIndexToChildren.values) {
      for (final FluentStorable child in children) {
        if (uniqueChildren.add(child)) {
          childToRepresentative[child] = child;
        } else {
          childToRepresentative[child] = uniqueChildren.lookup(child) ?? child;
        }
      }
    }

    final List<FluentStorable> flatChildrenList = uniqueChildren.toList(growable: false);

    final List<FluentStorable> newChildrenToSave = [];
    final List<Map<String, dynamic>> newChildrenJsons = [];

    final List<FluentStorable> existingChildrenToUpsert = [];
    final Map<FluentStorable, Map<String, dynamic>> childToSqlJson = Map.identity();

    for (final FluentStorable child in flatChildrenList) {
      final json = childDao._prepareSqlJson(child);
      childToSqlJson[child] = json;

      if (json[childPkName] == null) {
        newChildrenToSave.add(child);
        newChildrenJsons.add(json);
      } else {
        existingChildrenToUpsert.add(child);
      }
    }

    final bool isLocalBatch = batch == null;
    final Batch effectiveBatch = batch ?? txn!.batch();

    if (newChildrenToSave.isNotEmpty) {
      FluentLog.debug('Hydrating NEW unique child entities for M2M', tag: '$tableName:relations', context: {'count': newChildrenToSave.length});
      await childDao._executeAdd(
        txn,
        childDao._createTypedList(newChildrenToSave),
        task,
        sharedBatch: effectiveBatch,
        currentDepth: currentDepth,
        visitedTables: visitedTables,
        parentJsons: newChildrenJsons,
      );
    }

    if (existingChildrenToUpsert.isNotEmpty) {
      FluentLog.debug('Upserting EXISTING child entities for M2M safely', tag: '$tableName:relations', context: {'count': existingChildrenToUpsert.length});

      final List<Map<String, dynamic>> existingJsons = [];

      for (final FluentStorable child in existingChildrenToUpsert) {
        final Map<String, dynamic> json = childToSqlJson[child]!;
        existingJsons.add(json);
        final dynamic id = json[childPkName];

        effectiveBatch.insert(childDao.tableName, json, conflictAlgorithm: ConflictAlgorithm.ignore);

        if (task.helper?.updateIfExist == true) {
          final Map<String, dynamic> updateData = <String, dynamic>{};
          final Set<String> relKeys = childDao.relationKeys;
          for (final MapEntry<String, dynamic> entry in json.entries) {
            if (!relKeys.contains(entry.key)) {
              updateData[entry.key] = entry.value;
            }
          }
          effectiveBatch.update(childDao.tableName, updateData, where: '$childPkName = ?', whereArgs: [id]);
        }
      }

      if (childDao._hasRelations && childDao._relationsMixin != null) {
        await childDao._relationsMixin!._processBatchRelations(
          txn,
          childDao._createTypedList(existingChildrenToUpsert),
          task,
          batch: effectiveBatch,
          parentJsons: existingJsons,
          currentDepth: currentDepth + 1,
          visitedTables: visitedTables,
        );
      }
    }

    final Set<String> uniquePairs = <String>{};

    for (final MapEntry<int, List<FluentStorable>> entry in parentIndexToChildren.entries) {
      final int parentIdx = entry.key;
      final List<FluentStorable> children = entry.value;

      dynamic parentId;
      if (parentJsons != null && parentIdx < parentJsons.length && parentJsons[parentIdx].isNotEmpty) {
        parentId = parentJsons[parentIdx][parentPkName];
      } else {
        final T parent = parents[parentIdx];
        parentId = _prepareSqlJson(parent)[parentPkName];
      }

      if (parentId == null) continue;

      for (int i = 0; i < children.length; i++) {
        final FluentStorable child = children[i];
        final FluentStorable representative = childToRepresentative[child] ?? child;

        final dynamic childId = childToSqlJson[representative]?[childPkName];

        if (childId == null) {
          FluentLog.warning('Pivot association skipped: Child record ID unresolved', tag: '$tableName:relations');
          continue;
        }

        final String pairKey = '$parentId:$childId';
        if (uniquePairs.add(pairKey)) {
          final Map<String, dynamic> pivotRecord = {pivotParentKey: parentId, pivotChildKey: childId};

          effectiveBatch.insert(pivotTable, pivotRecord, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }

    if (isLocalBatch) {
      await effectiveBatch.commit(noResult: true);
    }

    FluentLog.debug('Many-to-many pivot association records staged successfully', tag: '$tableName:relations', context: {'pivotTable': pivotTable});
  }

  /// Explicitly hydrates lazy-loaded relational associations for a specific model instance.
  ///
  /// This operational utility provides targeted runtime hydration for entities requiring
  /// deferred dependency resolution:
  /// * Relation Filtering: Processes only those associations marked as currently unloaded or
  ///   explicitly requested via type [R].
  /// * Dynamic Hydration: Dispatches targeted queries to the [FluentDb], automatically resolving
  ///   foreign key constraints and polymorphic mapping keys.
  /// * Schema Normalization: Supports polymorphic and singular/collection casts, mapping raw
  ///   database results back into the entity's dynamic field structure.
  ///
  /// [model] The storable entity requiring dependency hydration.
  /// [maxDepth] Defines the recursion limit for child-graph loading (default is 1).
  Future<void> ensureLoaded<R extends FluentStorable>(T model, {int maxDepth = 1}) async {
    if (!_hasRelations || _relationsMixin == null) return;

    final relations = _relationsMixin!.resolvedRelations;
    if (relations.isEmpty) return;

    final String parentPkName = _cachedPrimaryKey?.name ?? 'id';

    final dynamic id = _prepareSqlJson(model)[parentPkName];
    if (id == null) {
      FluentLog.warning('EnsureLoaded operation aborted: Entity primary key is unassigned', tag: '$tableName:relations');
      return;
    }

    final String fallbackRemoteKey = '${FluentUtils.toSnakeCase(tableName.replaceAll('Model', '').replaceAll('Dao', ''))}_id';

    final bool loadAllUnloaded = R == FluentStorable;
    final Set<String> unloadedRels = model.unloadedRelations;

    for (final MapEntry<Type, FluentDbRelation<FluentStorable, FluentStorable>> entry in relations.entries) {
      final Type childType = entry.key;
      final FluentDbRelation rel = entry.value;
      final String mapKey = rel.mapToKey;

      if (loadAllUnloaded) {
        if (!unloadedRels.contains(mapKey)) continue;
      } else {
        if (childType != R) continue;
      }

      final FluentProvider childDao = FluentDb.providerForType(childType);
      final String whereKey = rel.remoteKey ?? resolveRemoteKey(childDao) ?? fallbackRemoteKey;

      FluentLog.debug('Hydrating lazy relational association', tag: '$tableName:relations', context: {'mapKey': mapKey, 'childTable': childDao.tableName, 'parentId': id.toString()});

      final List<dynamic> children = await childDao.find(where: '$whereKey = ?', whereArgs: [id], maxDepth: maxDepth, ignoreLazy: true);

      dynamic finalResult;
      final castType = rel.castType;

      if (castType == FluentModelCast.model || castType == FluentModelCast.map) {
        finalResult = children.isNotEmpty ? children.first : null;
      } else {
        finalResult = childDao._createTypedList(children);
      }

      model.setDynamicField(mapKey, finalResult);
      unloadedRels.remove(mapKey);

      FluentLog.info('Relational association successfully hydrated', tag: '$tableName:relations', context: {'mapKey': mapKey, 'injectedType': finalResult.runtimeType.toString()});
    }
  }
}
