// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

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
  /// final taskProvider = FluentDb.providerByType<Task>();
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
    final String baseTag = tag?.toString() ?? 'sync_$tableName';
    final bool isSoftDeletable = modelSample is FluentSoftDeletable;

    FluentLog.debug('Sync process initiated', tag: baseTag, context: {'strategy': strategy.name});

    try {
      // 1. PULL AND SAVE
      if (strategy == FluentSyncStrategy.pullAndSave) {
        if (onPull == null) {
          final FluentSyncException exception = FluentSyncException('onPull callback is missing', stackTrace: StackTrace.current);
          FluentLog.error(exception.message, exception, exception.stackTrace, tag: baseTag, hint: 'The "pullAndSave" strategy requires an onPull function to fetch data from the server.');
          throw exception;
        }

        FluentLog.debug('Fetching data from server...', tag: baseTag);
        final List<T> serverItems = await onPull();

        if (serverItems.isEmpty) {
          FluentLog.debug('Server returned empty data, sync finished', tag: baseTag);
          return FluentSyncResult(strategy: strategy, isSuccess: true);
        }

        FluentLog.debug('Saving ${serverItems.length} items to database', tag: baseTag);
        await saveItems(serverItems, updateIfExist: true, policy: policy.withTag('${baseTag}_pull'));

        FluentLog.debug('Successfully pulled and saved ${serverItems.length} items', tag: baseTag);
        return FluentSyncResult(strategy: strategy, isSuccess: true, itemsProcessed: serverItems.length);
      }

      // 2. PUSH ACTIVE & PURGE DELETED (READ PHASE)
      if (onPush == null) {
        final FluentSyncException exception = FluentSyncException('onPush callback is missing');
        FluentLog.error(exception.message, exception, exception.stackTrace, tag: baseTag, hint: 'The push/purge strategy requires an onPush function to transmit data to the server.');
        throw exception;
      }

      if (strategy == FluentSyncStrategy.purgeDeleted && !isSoftDeletable) {
        FluentLog.warning('Purge strategy ignored for table "$tableName"', tag: baseTag, hint: 'Ensure that the model class for this provider implements FluentSoftDeletable to use purgeDeleted.');
        return FluentSyncResult(strategy: strategy, isSuccess: false, errorMessage: 'Model not soft-deletable');
      }

      // Logic to construct query
      String? syncWhere = additionalWhere;
      if (isSoftDeletable) {
        final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;
        final String condition = strategy == FluentSyncStrategy.purgeDeleted ? '$col IS NOT NULL' : '$col IS NULL';
        syncWhere = syncWhere == null || syncWhere.trim().isEmpty ? condition : '(${syncWhere.trim()}) AND $condition';
      }

      FluentLog.debug('Reading local items with condition: $syncWhere', tag: baseTag);
      final List<T> localItems = await find(where: syncWhere, whereArgs: additionalWhereArgs, policy: policy.withTag('${baseTag}_read'));

      if (localItems.isEmpty) {
        FluentLog.debug('No local items found to process', tag: baseTag);
        return FluentSyncResult(strategy: strategy, isSuccess: true);
      }

      // 3. EXTERNAL TRANSPORT
      FluentLog.debug('Pushing ${localItems.length} items to server...', tag: baseTag);
      final bool isPushSuccessful = await onPush(localItems);

      if (!isPushSuccessful) {
        FluentLog.warning('Network transport rejected data', tag: baseTag, hint: 'Check API response status or endpoint availability.');
        return FluentSyncResult(strategy: strategy, isSuccess: false, errorMessage: 'Network transport returned false');
      }

      // 4. POST-SYNC CLEANUP
      if (strategy == FluentSyncStrategy.purgeDeleted) {
        FluentLog.debug('Purging ${localItems.length} items from database', tag: baseTag);
        await hardDeleteAll(localItems, policy: policy.withTag('${baseTag}_purge'));
      } else if (strategy == FluentSyncStrategy.pushActive && markAsSyncedFields != null) {
        final Set<dynamic> ids = localItems.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();
        if (ids.isNotEmpty) {
          FluentLog.debug('Marking ${ids.length} items as synced', tag: baseTag);
          await updateFieldsMultipleByIds(ids, markAsSyncedFields, policy: policy.withTag('${baseTag}_mark_synced'));
        }
      }

      FluentLog.debug('Sync finished successfully', tag: baseTag);
      return FluentSyncResult(strategy: strategy, isSuccess: true, itemsProcessed: localItems.length);
    } catch (e, st) {
      FluentLog.error(
        'Critical sync failure',
        e,
        st,
        tag: baseTag,
        hint: 'Investigate the network layer or constraint violations during batch processing.',
        context: {'strategy': strategy.name, 'table': tableName},
      );
      return FluentSyncResult(strategy: strategy, isSuccess: false, error: e, errorMessage: e.toString());
    }
  }
}
