// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values, unreachable_switch_default

part of '../fluent_provider.dart';

/// Provides advanced synchronization capabilities for [FluentProvider].
///
/// This extension enables seamless data reconciliation between the local SQLite
/// database and remote server APIs. It orchestrates the entire synchronization
/// pipeline, including data discovery, asynchronous network transport, and
/// automated database state cleanup.
///
/// **Key benefits:**
/// * **Non-blocking:** Performs network operations outside the database engine
///   pipeline to maintain UI responsiveness.
/// * **Atomic consistency:** Post-sync database operations (like purging or
///   updating sync status) are executed only after a successful network transport.
/// * **Observability:** Integrates with [FluentLog] and [FluentTableStatsTracker]
///   to provide deep insights into sync performance and failure points.
///
/// Use [syncWithServer] to implement common patterns such as "Pull and Save,"
/// "Push Active," or "Purge Deleted."
extension FluentProviderSyncExtension<T extends FluentStorable> on FluentProvider<T> {
  /// Orchestrates a comprehensive synchronization cycle between the local database
  /// and a remote backend.
  ///
  /// This utility manages the entire lifecycle of a synchronization task:
  /// 1. **Discovery:** Identifies relevant records based on the [strategy]
  ///    (e.g., active items, soft-deleted items) and [additionalWhere] filters.
  /// 2. **Transport:** Executes the provided [onPush] or [onPull] callbacks
  ///    asynchronously. This is handled outside the database lock to keep the
  ///    application UI responsive.
  /// 3. **Post-Sync Lifecycle:** Automates cleanup (e.g., [purgeDeleted]) or
  ///    state updates (e.g., [markAsSyncedFields]) only after the transport
  ///    succeeds.
  ///
  /// ### Example: Syncing "Task" items
  /// ```dart
  /// final TaskProvider taskProvider = FluentDb.providerByType<Task>();
  ///
  /// final FluentSyncResult<Task> result = await taskProvider.syncWithServer<Task>(
  ///   strategy: FluentSyncStrategy.pushActive,
  ///
  ///   // Send unsynced local items to the remote API
  ///   onPush: (List<Task> items) async {
  ///     try {
  ///       return await myApiClient.uploadTasks(items);
  ///     } catch (e) {
  ///       return false; // Sync stops if transport fails
  ///     }
  ///   },
  ///
  ///   // Only process items not yet on the server
  ///   additionalWhere: 'is_synced = 0',
  ///
  ///   // Mark as synced automatically if onPush returns true
  ///   markAsSyncedFields: {'is_synced': 1},
  ///
  ///   tag: 'TaskSyncService',
  /// );
  ///
  /// if (result.isSuccess) {
  ///   print('Synced ${result.itemsProcessed} items');
  /// }
  /// ```
  ///
  /// Returns a [FluentSyncResult] containing the status and metrics.
  /// Throws [FluentSyncException] if critical callbacks are missing.
  Future<FluentSyncResult<T>> syncWithServer({
    required FluentSyncStrategy strategy,
    Future<bool> Function(List<T> items)? onPush,
    Future<List<T>> Function()? onPull,
    String? additionalWhere,
    List<Object?>? additionalWhereArgs,
    Map<String, dynamic>? markAsSyncedFields,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final bool isSoftDeletable = modelSample is FluentSoftDeletable;

    FluentLog.debug('Sync process initiated', tag: 'sync_$tableName', context: {'strategy': strategy.name});

    try {
      // 1. PULL AND SAVE
      if (strategy == FluentSyncStrategy.pullAndSave) {
        if (onPull == null) {
          final FluentSyncException exception = FluentSyncException('onPull callback is missing', stackTrace: StackTrace.current);
          FluentLog.error(exception.message, exception, exception.stackTrace, tag: 'sync_$tableName', hint: 'The "pullAndSave" strategy requires an onPull function to fetch data from the server.');
          throw exception;
        }

        FluentLog.debug('Fetching data from server...', tag: 'sync_$tableName');
        final List<T> serverItems = await onPull();

        if (serverItems.isEmpty) {
          FluentLog.debug('Server returned empty data, sync finished', tag: 'sync_$tableName');
          return FluentSyncResult(strategy: strategy, isSuccess: true);
        }

        FluentLog.debug('Saving ${serverItems.length} items to database', tag: 'sync_$tableName');
        await saveItems(serverItems, updateIfExist: true, policy: policy.withTag('${'sync_$tableName'}_pull'));

        FluentLog.debug('Successfully pulled and saved ${serverItems.length} items', tag: 'sync_$tableName');
        return FluentSyncResult(strategy: strategy, isSuccess: true, itemsProcessed: serverItems.length);
      }

      // 2. PUSH ACTIVE & PURGE DELETED (READ PHASE)
      if (onPush == null) {
        final FluentSyncException exception = FluentSyncException('onPush callback is missing');
        FluentLog.error(exception.message, exception, exception.stackTrace, tag: 'sync_$tableName', hint: 'The push/purge strategy requires an onPush function to transmit data to the server.');
        throw exception;
      }

      if (strategy == FluentSyncStrategy.purgeDeleted && !isSoftDeletable) {
        FluentLog.warning(
          'Purge strategy ignored for table "$tableName"',
          tag: 'sync_$tableName',
          hint: 'Ensure that the model class for this provider implements FluentSoftDeletable to use purgeDeleted.',
        );
        return FluentSyncResult(strategy: strategy, isSuccess: false, errorMessage: 'Model not soft-deletable');
      }

      // Logic to construct query
      String? syncWhere = additionalWhere;
      if (isSoftDeletable) {
        final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;
        final String condition = strategy == FluentSyncStrategy.purgeDeleted ? '$col IS NOT NULL' : '$col IS NULL';
        syncWhere = syncWhere == null || syncWhere.trim().isEmpty ? condition : '(${syncWhere.trim()}) AND $condition';
      }

      FluentLog.debug('Reading local items with condition: $syncWhere', tag: 'sync_$tableName');
      final List<T> localItems = await find(where: syncWhere, whereArgs: additionalWhereArgs, policy: policy.withTag('${'sync_$tableName'}_read'));

      if (localItems.isEmpty) {
        FluentLog.debug('No local items found to process', tag: 'sync_$tableName');
        return FluentSyncResult(strategy: strategy, isSuccess: true);
      }

      // 3. EXTERNAL TRANSPORT
      FluentLog.debug('Pushing ${localItems.length} items to server...', tag: 'sync_$tableName');
      final bool isPushSuccessful = await onPush(localItems);

      if (!isPushSuccessful) {
        FluentLog.warning('Network transport rejected data', tag: 'sync_$tableName', hint: 'Check API response status or endpoint availability.');
        return FluentSyncResult(strategy: strategy, isSuccess: false, errorMessage: 'Network transport returned false');
      }

      // 4. POST-SYNC CLEANUP
      if (strategy == FluentSyncStrategy.purgeDeleted) {
        FluentLog.debug('Purging ${localItems.length} items from database', tag: 'sync_$tableName');
        await hardDeleteAll(localItems, policy: policy.withTag('${'sync_$tableName'}_purge'));
      } else if (strategy == FluentSyncStrategy.pushActive && markAsSyncedFields != null) {
        final Set<dynamic> ids = localItems.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();
        if (ids.isNotEmpty) {
          FluentLog.debug('Marking ${ids.length} items as synced', tag: 'sync_$tableName');
          await updateFieldsMultipleByIds(ids, markAsSyncedFields, policy: policy.withTag('${'sync_$tableName'}_mark_synced'));
        }
      }

      FluentLog.debug('Sync finished successfully', tag: 'sync_$tableName');
      return FluentSyncResult(strategy: strategy, isSuccess: true, itemsProcessed: localItems.length);
    } catch (e, st) {
      FluentLog.error(
        'Critical sync failure',
        e,
        st,
        tag: 'sync_$tableName',
        hint: 'Investigate the network layer or constraint violations during batch processing.',
        context: {'strategy': strategy.name, 'table': tableName},
      );
      return FluentSyncResult(strategy: strategy, isSuccess: false, error: e, errorMessage: e.toString());
    }
  }

  /// Performs a reactive synchronization of data between local storage and a remote API.
  ///
  /// The pipeline lifecycle emits [FluentDataEvent] objects, allowing the UI to
  /// track phases from [FluentPipelinePhase.loadingCache] to [FluentPipelinePhase.completed].
  ///
  /// ### Synchronization Flow:
  /// 1. **Cache Phase**: Retrieves local records (optionally limited by `options.limit`).
  /// 2. **API Phase**: Fetches remote data using [FluentApiResponse] factories.
  /// 3. **Persistence**: Performs [FluentMergeStrategy] reconciliation against the local store.
  ///
  /// ### Example: Syncing a single entity
  /// Use [FluentApiResponse.single] when the API returns a specific object.
  /// ```dart
  /// userProvider.reactiveSync<User>(
  ///   fetchFromApi: () async => FluentApiResponse.single(
  ///     data: await api.getUser(123),
  ///     statusCode: 200,
  ///   ),
  ///   options: FluentSyncOptions(limit: 1), // Limits local cache query to 1
  /// );
  /// ```
  ///
  /// ### Example: Syncing a collection
  /// Use [FluentApiResponse.list] for multi-record endpoints.
  /// ```dart
  /// userProvider.reactiveSync<User>(
  ///   fetchFromApi: () async => FluentApiResponse.list(
  ///     data: await api.getUsers(),
  ///     statusCode: 200,
  ///   ),
  ///   options: FluentSyncOptions(mergeStrategy: FluentMergeStrategy.syncDeletions),
  /// );
  /// ```
  ///
  /// ### Example: Advanced transformation and error handling
  /// ```dart
  /// await userProvider.reactiveSync<User>(
  ///   fetchFromApi: () => api.fetchUserPosts(userId: 123),
  ///   localWhere: 'user_id = ?',
  ///   localWhereArgs: [123],
  ///   options: FluentSyncOptions<User>(
  ///     mergeStrategy: FluentMergeStrategy.syncDeletions,
  ///     beforeSave: (items) async => items.map((e) => e.copyWith(syncedAt: DateTime.now())).toList(),
  ///     statusBehaviors: { 404: FluentApiErrorBehavior.preserveCacheAndComplete },
  ///   ),
  /// ).listen((event) {
  ///   // event.data is always a List<T>, providing consistent UI handling
  ///   final items = event.data;
  ///   print('Sync phase: ${event.phase}, items count: ${items.length}');
  /// });
  /// ```
  Stream<FluentDataEvent<T>> reactiveSync({
    required Future<FluentApiResponse<T>> Function() fetchFromApi,
    FluentSyncOptions<T> options = const FluentSyncOptions(),
    String? localWhere,
    List<Object?>? localWhereArgs,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async* {
    FluentLog.info('Initiating sync pipeline', tag: 'sync:pipeline', context: {'model': T.toString()});

    yield FluentDataEvent(phase: FluentPipelinePhase.idle);

    List<T> localData = [];

    if (options.executionStrategy != FluentExecutionStrategy.apiOnly) {
      yield FluentDataEvent(phase: FluentPipelinePhase.loadingCache);

      if (options.loadOnlyValidCache) {
        localData = await findValidItems(
          where: localWhere,
          whereArgs: localWhereArgs,
          limit: options.limit,
          maxDepth: options.maxDepth,
          sortDirection: options.sortDirection,
          policy: policy,
          ignoreLazy: options.ignoreLazy,
        );
      } else {
        localData = await find(where: localWhere, whereArgs: localWhereArgs, limit: options.limit, maxDepth: options.maxDepth, policy: policy, ignoreLazy: options.ignoreLazy);
      }
      FluentLog.debug('Cache loaded', tag: 'sync:cache', context: {'count': localData.length, 'model': T.toString()});
      yield FluentDataEvent(phase: FluentPipelinePhase.cacheReady, data: localData);

      if (options.executionStrategy == FluentExecutionStrategy.cacheOnly) {
        FluentLog.info('Execution strategy is cacheOnly. Terminating pipeline.', tag: 'sync:pipeline');
        yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: localData);
        return;
      }
    }

    yield FluentDataEvent(phase: FluentPipelinePhase.loadingApi);

    FluentApiResponse<T>? response;
    int attempts = 0;
    Object? lastError;

    while (attempts <= options.retryCount) {
      try {
        response = await fetchFromApi();
        if (options.validStatusCodes.contains(response.statusCode)) {
          FluentLog.debug('API fetch success', tag: 'sync:api', context: {'status': response.statusCode});
          lastError = null;
          break;
        } else {
          throw FluentApiException(response.statusCode, message: 'Received unexpected status code', originalError: response.error);
        }
      } catch (e) {
        lastError = e;
        attempts++;
        FluentLog.warning('API fetch attempt $attempts failed', tag: 'sync:api:retry', hint: 'Check connectivity or server availability', context: {'attempt': attempts, 'error': e.toString()});
        if (attempts > options.retryCount) {
          break;
        }
        await Future<void>.delayed(options.baseRetryBackoff * attempts);
      }
    }

    if (lastError != null) {
      FluentLog.error(lastError is FluentException ? lastError.message : 'Pipeline terminated with error', lastError, StackTrace.current, tag: 'sync:error', context: {'model': T.toString()});
      if (options.onError != null) {
        options.onError?.call(lastError, StackTrace.current);
      }

      FluentApiErrorBehavior behaviorToUse = options.defaultErrorBehavior;
      if (lastError is FluentApiException && options.statusBehaviors != null) {
        behaviorToUse = options.statusBehaviors?[lastError.statusCode] ?? options.defaultErrorBehavior;
      }

      switch (behaviorToUse) {
        case FluentApiErrorBehavior.clearCacheAndYieldError:
          FluentLog.info('Clearing cache due to error', tag: 'sync:error');
          yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb);
          await _handleClearCache(localWhere, localWhereArgs, policy);
          yield FluentDataEvent(phase: FluentPipelinePhase.error, error: lastError);
          break;

        case FluentApiErrorBehavior.preserveCacheAndComplete:
          yield FluentDataEvent(phase: FluentPipelinePhase.completed, error: lastError);
          break;

        case FluentApiErrorBehavior.yieldError:
        default:
          yield FluentDataEvent(phase: FluentPipelinePhase.error, error: lastError);
          break;
      }
      return;
    }

    List<T> apiData = response?.data ?? [];

    if (apiData.isEmpty) {
      FluentLog.info('Empty API response', tag: 'sync:api');
      if (options.emptyApiBehavior == FluentEmptyApiBehavior.clearCache) {
        yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb);
        await _handleClearCache(localWhere, localWhereArgs, policy);
      }
      yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: []);
      return;
    }

    if (options.beforeSave != null) {
      apiData = await options.beforeSave?.call(apiData) ?? [];
    }

    if (options.executionStrategy == FluentExecutionStrategy.cacheThenApiYieldThenSave) {
      yield FluentDataEvent(phase: FluentPipelinePhase.apiReady, data: apiData);
    }

    if (options.mergeStrategy == FluentMergeStrategy.none) {
      FluentLog.info('Merge strategy is none. Skipping database persistence.', tag: 'sync:persistence');
    } else {
      FluentLog.info('Saving ${apiData.length} records to DB', tag: 'sync:persistence');
      yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb, data: apiData);

      await _executeMergeStrategy(
        strategy: options.mergeStrategy,
        relationSyncMode: options.relationSyncMode,
        apiData: apiData,
        localWhere: localWhere,
        localWhereArgs: localWhereArgs,
        policy: policy,
      );
    }

    if (options.executionStrategy != FluentExecutionStrategy.cacheThenApiYieldThenSave) {
      yield FluentDataEvent(phase: FluentPipelinePhase.apiReady, data: apiData);
    }

    if (options.onSuccess != null) {
      options.onSuccess?.call(apiData);
    }

    FluentLog.info('Sync completed successfully', tag: 'sync:pipeline');
    yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: apiData);
  }

  /// Executes a cleanup operation on the local database for the entity type [T].
  ///
  /// If [localWhere] is provided, this method performs a scoped deletion of
  /// records matching the condition. Otherwise, it executes a full table
  /// truncation using [clearTable].
  ///
  /// * [localWhere]: The SQL WHERE clause condition.
  /// * [localWhereArgs]: The arguments for the WHERE clause.
  /// * [policy]: The [ExecutionPolicy] governing the database transaction.
  Future<void> _handleClearCache(String? localWhere, List<Object?>? localWhereArgs, ExecutionPolicy policy) async {
    if (localWhere != null && localWhere.trim().isNotEmpty) {
      FluentLog.debug('Performing scoped cache cleanup', tag: 'sync:cache:clear', context: {'model': T.toString(), 'where': localWhere, 'args': localWhereArgs});
      await deleteWhere(where: localWhere, whereArgs: localWhereArgs, isHardDelete: false, policy: policy);
    } else {
      FluentLog.warning('Performing full table truncation', tag: 'sync:cache:clear', hint: 'All local records for ${T.toString()} have been purged.', context: {'model': T.toString()});
      await clearTable(policy: policy);
    }
  }

  /// Orchestrates the reconciliation between local storage and incoming API data
  /// based on the selected [FluentMergeStrategy].
  ///
  /// This method performs the following reconciliation steps:
  /// 1. **Classification**: Separates [apiData] into items to be inserted or updated
  ///    based on their existence in the local cache.
  /// 2. **Persistence**:
  ///    - For `upsert` or `syncDeletions`, performs batch inserts and relational updates.
  ///    - For `syncDeletions`, identifies and removes stale local records not
  ///      present in the current API payload.
  ///    - For `replace`, clears existing records (matching [localWhere]) and
  ///      performs a bulk insertion of all [apiData].
  ///
  /// * [strategy]: The reconciliation mode (e.g., [FluentMergeStrategy.upsert]).
  /// * [relationSyncMode]: Strategy for handling child/nested entities.
  /// * [localWhere]: Optional filter to limit the reconciliation scope.
  /// * [policy]: The [ExecutionPolicy] applied to database transactions.
  Future<void> _executeMergeStrategy({
    required FluentMergeStrategy strategy,
    required FluentRelationSyncMode relationSyncMode,
    required List<T> apiData,
    String? localWhere,
    List<Object?>? localWhereArgs,
    required ExecutionPolicy policy,
  }) async {
    if (strategy == FluentMergeStrategy.none) return;

    final List<T> localData = await find(where: localWhere, whereArgs: localWhereArgs, policy: policy);
    final Set<dynamic> localIds = localData.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();

    final List<T> itemsToInsert = [];
    final List<T> itemsToUpdate = [];

    for (final T item in apiData) {
      if (localIds.contains(item.primaryKeyValue)) {
        itemsToUpdate.add(item);
      } else {
        itemsToInsert.add(item);
      }
    }

    FluentLog.debug('Reconciliation breakdown', tag: 'sync:merge', context: {'model': T.toString(), 'insert': itemsToInsert.length, 'update': itemsToUpdate.length});

    switch (strategy) {
      case FluentMergeStrategy.upsert:
      case FluentMergeStrategy.syncDeletions:
        if (itemsToInsert.isNotEmpty) {
          await saveItems(itemsToInsert, updateIfExist: false, policy: policy);
        }

        if (itemsToUpdate.isNotEmpty) {
          await updateAllWithRelations(itemsToUpdate, syncMode: relationSyncMode, policy: policy);
        }

        if (strategy == FluentMergeStrategy.syncDeletions) {
          final Set<dynamic> apiIds = apiData.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();

          final List<T> itemsToDelete = localData.where((local) => !apiIds.contains(local.primaryKeyValue)).toList();

          if (itemsToDelete.isNotEmpty) {
            final bool isSoftDeletable = modelSample is FluentSoftDeletable;

            FluentLog.info(
              '${isSoftDeletable ? "Soft" : "Hard"}-deleting ${itemsToDelete.length} obsolete items',
              tag: 'sync:merge:cleanup',
              context: {'model': T.toString(), 'count': itemsToDelete.length},
            );

            if (isSoftDeletable) {
              FluentLog.debug('Soft-deleting ${itemsToDelete.length} obsolete items', tag: 'PipelineSync');
              await deleteAll(itemsToDelete, policy: policy);
            } else {
              FluentLog.debug('Hard-deleting ${itemsToDelete.length} obsolete items', tag: 'PipelineSync');
              await hardDeleteAll(itemsToDelete, policy: policy);
            }
          }
        }
        break;
      case FluentMergeStrategy.replace:
        FluentLog.info('Executing replace strategy for ${T.toString()}', tag: 'sync:merge');
        await _handleClearCache(localWhere, localWhereArgs, policy);
        await saveItems(apiData, updateIfExist: false, policy: policy);
        break;
      case FluentMergeStrategy.none:
        return;
    }
  }
}
