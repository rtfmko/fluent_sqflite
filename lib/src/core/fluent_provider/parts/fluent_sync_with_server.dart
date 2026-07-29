// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values, unreachable_switch_default

part of '../fluent_provider.dart';

/// Provides reactive synchronization and live-data streaming capabilities
/// for any [FluentProvider].
///
/// This extension bridges local database storage with remote API fetching,
/// enabling an "offline-first" reactive data flow where the UI instantly receives
/// cached local data and seamlessly updates as fresh data arrives from the network.
extension FluentSyncWithServer<T extends FluentStorable> on FluentProvider<T> {
  /// Performs a reactive synchronization of data between local storage and a remote API.
  ///
  /// The pipeline lifecycle emits [FluentDataEvent] objects, allowing the UI to
  /// track phases from [FluentPipelinePhase.loadingCache] to [FluentPipelinePhase.completed].
  ///
  /// ### Synchronization Flow:
  /// 1. **Cache Phase**: Retrieves local records (optionally filtered by [localFilter] or [localWhere], and limited by `options.limit`).
  /// 2. **API Phase**: Fetches remote data using [FluentApiResponse] factories.
  /// 3. **Persistence**: Performs [FluentMergeStrategy] reconciliation against the local store.
  ///
  /// *Note: You can use either [localFilter] or [localWhere] / [localWhereArgs] to scope*
  /// *the local cache query, but providing both simultaneously will trigger an assertion error.*
  ///
  /// ### Example: Syncing a single entity
  /// Use [FluentApiResponse.single] when the API returns a specific object.
  /// ```dart
  /// userProvider.reactiveSync(
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
  /// userProvider.reactiveSync(
  ///   fetchFromApi: () async => FluentApiResponse.list(
  ///     data: await api.getUsers(),
  ///     statusCode: 200,
  ///   ),
  ///   options: FluentSyncOptions(mergeStrategy: FluentMergeStrategy.syncDeletions),
  /// );
  /// ```
  ///
  /// ### Example: Advanced transformation with type-safe [localFilter]
  /// ```dart
  /// userProvider.reactiveSync(
  ///   fetchFromApi: () => api.fetchUserPosts(userId: 123),
  ///   localFilter: FluentFilter.eq('user_id', 123)
  ///       .and(FluentFilter.gt('created_at', startDate, config: tableConfig)),
  ///   options: FluentSyncOptions(
  ///     mergeStrategy: FluentMergeStrategy.syncDeletions,
  ///     beforeSave: (items) async => items.map((e) => e.copyWith(syncedAt: DateTime.now())).toList(),
  ///     statusBehaviors: { 404: FluentApiErrorBehavior.preserveCacheAndComplete },
  ///   ),
  /// ).listen((event) {
  ///   // event.data is always a List<T>, providing consistent UI handling
  ///   final items = event.data;
  ///   print('Sync phase: ${event.phase}, items count:${items.length}');
  /// });
  /// ```
  Stream<FluentDataEvent<T>> reactiveSync({
    required Future<FluentApiResponse<T?>> Function() fetchFromApi,
    FluentSyncOptions<T> options = const FluentSyncOptions(),
    String? localWhere,
    List<Object?>? localWhereArgs,
    FluentFilter? localFilter,
    String? localOrderBy,
    String? dbName,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async* {
    assert(!(localFilter != null && localWhere != null), 'Provide either [localFilter] or [localWhere], not both.');

    if (localFilter != null && localWhere != null) {
      FluentLog.warning(
        'Mutually exclusive cache query parameters provided.',
        tag: 'sync:pipeline',
        hint: 'Both [localFilter] and [localWhere] were passed. The raw [localWhere] will be ignored.',
        context: {'ignoredWhere': localWhere, 'appliedFilter': localFilter.whereClause},
      );
    }

    final String? actualWhere = localFilter?.whereClause ?? localWhere;
    final List<Object?>? actualWhereArgs = localFilter?.whereArgs ?? localWhereArgs;

    final Stopwatch pipelineTimer = Stopwatch()..start();
    FluentLog.info('Initiating sync pipeline', tag: 'sync:pipeline', context: {'model': T.toString()});

    yield FluentDataEvent(phase: FluentPipelinePhase.idle, executionMs: pipelineTimer.elapsedMilliseconds);

    List<T> localData = [];

    if (options.executionStrategy != FluentExecutionStrategy.apiOnly) {
      yield FluentDataEvent(phase: FluentPipelinePhase.loadingCache, executionMs: pipelineTimer.elapsedMilliseconds);

      if (options.loadOnlyValidCache) {
        localData = await findValidItems(
          where: actualWhere,
          whereArgs: actualWhereArgs,
          limit: options.limit,
          maxDepth: options.maxDepth,
          sortDirection: options.sortDirection,
          policy: policy,
          ignoreLazy: options.ignoreLazy,
          dbName: dbName,
          orderBy: localOrderBy,
        );
      } else {
        localData = await find(
          where: actualWhere,
          whereArgs: actualWhereArgs,
          orderBy: localOrderBy,
          limit: options.limit,
          maxDepth: options.maxDepth,
          policy: policy,
          ignoreLazy: options.ignoreLazy,
          dbName: dbName,
        );
      }
      FluentLog.debug('Cache loaded', tag: 'sync:cache', context: {'count': localData.length, 'model': T.toString(), 'ms': pipelineTimer.elapsedMilliseconds});
      yield FluentDataEvent(phase: FluentPipelinePhase.cacheReady, data: localData, source: FluentDataSource.cache, executionMs: pipelineTimer.elapsedMilliseconds);

      if (options.executionStrategy == FluentExecutionStrategy.cacheOnly) {
        FluentLog.info('Execution strategy is cacheOnly. Terminating pipeline.', tag: 'sync:pipeline');
        yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: localData, source: FluentDataSource.cache, executionMs: pipelineTimer.elapsedMilliseconds);
        return;
      }
    }

    yield FluentDataEvent(phase: FluentPipelinePhase.loadingApi, executionMs: pipelineTimer.elapsedMilliseconds);

    FluentApiResponse<T?>? response;
    int attempts = 0;
    Object? lastError;

    while (attempts <= options.retryCount) {
      try {
        response = await fetchFromApi();
        if (options.validStatusCodes.contains(response.statusCode)) {
          FluentLog.debug('API fetch success', tag: 'sync:api', context: {'status': response.statusCode, 'ms': pipelineTimer.elapsedMilliseconds});
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
          yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb, executionMs: pipelineTimer.elapsedMilliseconds);
          await _handleClearCache(actualWhere, actualWhereArgs, policy, dbName);
          yield FluentDataEvent(phase: FluentPipelinePhase.error, error: lastError, executionMs: pipelineTimer.elapsedMilliseconds);
          break;

        case FluentApiErrorBehavior.preserveCacheAndComplete:
          yield FluentDataEvent(phase: FluentPipelinePhase.completed, error: lastError, executionMs: pipelineTimer.elapsedMilliseconds);
          break;

        case FluentApiErrorBehavior.yieldError:
        default:
          yield FluentDataEvent(phase: FluentPipelinePhase.error, error: lastError, executionMs: pipelineTimer.elapsedMilliseconds);
          break;
      }
      return;
    }

    List<T> apiData = response?.data?.whereType<T>().toList() ?? [];

    if (apiData.isEmpty) {
      FluentLog.info('Empty API response', tag: 'sync:api');
      if (options.emptyApiBehavior == FluentEmptyApiBehavior.clearCache) {
        yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb, executionMs: pipelineTimer.elapsedMilliseconds);
        await _handleClearCache(actualWhere, actualWhereArgs, policy, dbName);
      }
      yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: [], executionMs: pipelineTimer.elapsedMilliseconds);
      return;
    }

    if (options.beforeSave != null) {
      try {
        apiData = await options.beforeSave?.call(apiData) ?? [];
      } catch (e, st) {
        FluentLog.error('User callback beforeSave failed', e, st, tag: 'sync:callback_error');
        yield FluentDataEvent(
          phase: FluentPipelinePhase.error,
          error: FluentEngineException('User callback beforeSave failed', originalError: e, stackTrace: st, component: 'reactiveSync'),
          executionMs: pipelineTimer.elapsedMilliseconds,
        );
        return;
      }
    }

    Future<void>? persistenceFuture;

    if (options.mergeStrategy == FluentMergeStrategy.none) {
      FluentLog.info('Merge strategy is none. Skipping database persistence.', tag: 'sync:persistence');
    } else {
      FluentLog.info('Initiating database persistence', tag: 'sync:persistence');

      persistenceFuture =
          _executeMergeStrategy(
            strategy: options.mergeStrategy,
            relationSyncMode: options.relationSyncMode,
            apiData: apiData,
            localWhere: actualWhere,
            localWhereArgs: actualWhereArgs,
            currentLocalData: localData,
            executionStrategy: options.executionStrategy,
            policy: policy,
            dbName: dbName,
            ignoreLazy: options.ignoreLazy,
            maxDepth: options.maxDepth,
          ).catchError((Object e, StackTrace st) {
            FluentLog.error('Background DB persistence failed', e, st, tag: 'sync:persistence:error');
          });
    }

    final bool yieldBeforeSave = options.executionStrategy == FluentExecutionStrategy.cacheThenApiYieldThenSave || options.executionStrategy == FluentExecutionStrategy.apiOnly;

    if (yieldBeforeSave) {
      yield FluentDataEvent(phase: FluentPipelinePhase.apiReady, data: apiData, executionMs: pipelineTimer.elapsedMilliseconds);
    }

    if (persistenceFuture != null && options.awaitPersistence) {
      yield FluentDataEvent(phase: FluentPipelinePhase.savingToDb, data: apiData, executionMs: pipelineTimer.elapsedMilliseconds);
      await persistenceFuture;
    }

    if (!yieldBeforeSave) {
      yield FluentDataEvent(phase: FluentPipelinePhase.apiReady, data: apiData, executionMs: pipelineTimer.elapsedMilliseconds);
    }

    if (options.onSuccess != null) {
      try {
        options.onSuccess?.call(apiData);
      } catch (e) {
        FluentLog.warning('User callback onSuccess failed, but sync was successful', tag: 'sync:callback_error');
      }
    }

    pipelineTimer.stop();
    FluentLog.info('Sync completed successfully', tag: 'sync:pipeline', context: {'total_ms': pipelineTimer.elapsedMilliseconds});

    yield FluentDataEvent(phase: FluentPipelinePhase.completed, data: apiData, source: FluentDataSource.api, executionMs: pipelineTimer.elapsedMilliseconds);
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
  Future<void> _handleClearCache(String? localWhere, List<Object?>? localWhereArgs, ExecutionPolicy policy, String? dbName) async {
    if (localWhere != null && localWhere.trim().isNotEmpty) {
      FluentLog.debug('Performing scoped cache cleanup', tag: 'sync:cache:clear', context: {'model': T.toString(), 'where': localWhere, 'args': localWhereArgs});
      await deleteWhere(where: localWhere, whereArgs: localWhereArgs, isHardDelete: false, policy: policy, dbName: dbName);
    } else {
      FluentLog.warning('Performing full table truncation', tag: 'sync:cache:clear', hint: 'All local records for ${T.toString()} have been purged.', context: {'model': T.toString()});
      await clearTable(policy: policy, dbName: dbName);
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
    required List<T> currentLocalData,
    required FluentExecutionStrategy executionStrategy,
    String? localWhere,
    List<Object?>? localWhereArgs,
    required ExecutionPolicy policy,
    required String? dbName,
    required bool ignoreLazy,
    required int maxDepth,
  }) async {
    if (strategy == FluentMergeStrategy.none) return;

    final List<T> localData = (executionStrategy == FluentExecutionStrategy.apiOnly)
        ? await find(where: localWhere, whereArgs: localWhereArgs, policy: policy, dbName: dbName, maxDepth: maxDepth, ignoreLazy: ignoreLazy)
        : currentLocalData;
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
          await saveItems(itemsToInsert, saveStrategy: FluentSaveStrategy.insertOnly, policy: policy, dbName: dbName);
        }

        if (itemsToUpdate.isNotEmpty) {
          await updateAllWithRelations(itemsToUpdate, syncMode: relationSyncMode, policy: policy, dbName: dbName, ignoreLazy: ignoreLazy, maxDepth: maxDepth);
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
              await deleteAll(itemsToDelete, policy: policy, dbName: dbName);
            } else {
              FluentLog.debug('Hard-deleting ${itemsToDelete.length} obsolete items', tag: 'PipelineSync');
              await hardDeleteAll(itemsToDelete, policy: policy, dbName: dbName);
            }
          }
        }
        break;
      case FluentMergeStrategy.replace:
        FluentLog.info('Executing replace strategy for ${T.toString()}', tag: 'sync:merge');
        await _handleClearCache(localWhere, localWhereArgs, policy, dbName);
        await saveItems(apiData, saveStrategy: FluentSaveStrategy.insertOnly, policy: policy, dbName: dbName);
        break;
      case FluentMergeStrategy.none:
        return;
    }
  }
}
