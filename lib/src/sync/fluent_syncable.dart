// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values, unreachable_switch_default

import '../core/core.dart';
import '../core/fluent_sqlite_internal.dart';
import '../exceptions/fluent_exceptions.dart';
import '../interfaces/interfaces.dart';
import '../models/models.dart';
import '../soft_delete/soft_delete.dart';
import '../utils/utils.dart';

/// Adds automated synchronization capabilities and tracking schema columns
/// to a [FluentProvider].
///
/// Providers mixed with [FluentSyncable] automatically inject synchronization
/// tracking fields (such as `is_synced`) into the table schema during compilation
/// and provide a default state mutation dictionary for post-sync lifecycle updates.
mixin FluentSyncable<T extends FluentStorable> on FluentProvider<T> {
  /// The specific database column name used to track synchronization state.
  /// Override this if your legacy database uses a different column name.
  String get syncStateColumn => 'is_synced';

  /// Defines the structural database columns required for tracking synchronization state.
  List<FluentDbColumn> get syncColumns => [FluentDbColumn(name: syncStateColumn, type: FluentDbDataType.integer, defaultValue: '0')];

  /// Defines the default field-value mapping applied to local records
  /// upon a successful remote synchronization push.
  Map<String, dynamic> get syncCompleteState => {syncStateColumn: 1};

  /// The SQL WHERE condition used to identify records that have not yet
  /// been successfully synchronized with the remote server.
  String get unsyncedWhereClause => '$syncStateColumn = 0';

  /// Orchestrates a comprehensive synchronization cycle between the local database
  /// and a remote backend.
  ///
  /// This utility manages the entire lifecycle of a synchronization task:
  /// 1. **Discovery:** Identifies relevant records based on the [strategy]
  ///    (e.g., active items, soft-deleted items) and [additionalFilter] / [additionalWhere] filters.
  /// 2. **Transport:** Executes the provided [onPush] or [onPull] callbacks
  ///    asynchronously. This is handled outside the database lock to keep the
  ///    application UI responsive.
  /// 3. **Post-Sync Lifecycle:** Automates cleanup (e.g., [purgeDeleted]) or
  ///    state updates using [markAsSyncedFields] (or falls back to the provider's
  ///    default [syncCompleteState]) only after the transport succeeds.
  ///
  /// *Note: You can use either [additionalFilter] or [additionalWhere] / [additionalWhereArgs] to scope*
  /// *the query, but providing both simultaneously will trigger an assertion error.*
  ///
  /// ### Example: Syncing "Task" items with type-safe [additionalFilter]
  /// ```dart
  /// final TaskProvider taskProvider = FluentDb.providerByType<Task>();
  ///
  /// final FluentSyncResult<Task> result = await taskProvider.syncWithServer(
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
  ///   // Only process items not yet on the server using type-safe filter
  ///   additionalFilter: FluentFilter.eq('is_synced', 0),
  ///
  ///   // markAsSyncedFields is omitted here because the provider automatically
  ///   // applies syncCompleteState (e.g., {'is_synced': 1}) upon success.
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
    FluentFilter? additionalFilter,
    Map<String, dynamic>? markAsSyncedFields,
    bool pushOnlyUnsynced = true,
    Object? tag,
    String? dbName,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    assert(!(additionalFilter != null && additionalWhere != null), 'Provide either [additionalFilter] or [additionalWhere], not both.');

    if (additionalFilter != null && additionalWhere != null) {
      FluentLog.warning(
        'Mutually exclusive sync parameters provided.',
        tag: 'sync_$tableName',
        hint: 'Both [additionalFilter] and [additionalWhere] were passed. The raw [additionalWhere] will be ignored.',
        context: {'strategy': strategy.toString(), 'ignoredWhere': additionalWhere, 'appliedFilter': additionalFilter.whereClause},
      );
    }

    final String? actualWhere = additionalFilter?.whereClause ?? additionalWhere;
    final List<Object?>? actualWhereArgs = additionalFilter?.whereArgs ?? additionalWhereArgs;

    final bool isSoftDeletable = modelSample is FluentSoftDeletable;

    final Map<String, dynamic> actualMarkAsSyncedFields = markAsSyncedFields ?? syncCompleteState;

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
        await saveItems(serverItems, saveStrategy: FluentSaveStrategy.upsert, policy: policy.withTag('${'sync_$tableName'}_pull'), dbName: dbName);

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
      String? syncWhere = actualWhere;
      if (strategy == FluentSyncStrategy.pushActive && pushOnlyUnsynced) {
        final String unsyncedCondition = unsyncedWhereClause;
        syncWhere = syncWhere == null || syncWhere.trim().isEmpty ? unsyncedCondition : '(${syncWhere.trim()}) AND $unsyncedCondition';
      }

      if (isSoftDeletable) {
        final String col = (modelSample as FluentSoftDeletable).softDeleteColumn;
        final String condition = strategy == FluentSyncStrategy.purgeDeleted ? '$col IS NOT NULL' : '$col IS NULL';
        syncWhere = syncWhere == null || syncWhere.trim().isEmpty ? condition : '(${syncWhere.trim()}) AND $condition';
      }

      FluentLog.debug('Reading local items with condition: $syncWhere', tag: 'sync_$tableName');
      final List<T> localItems = await find(where: syncWhere, whereArgs: actualWhereArgs, policy: policy.withTag('${'sync_$tableName'}_read'), dbName: dbName);

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
        await hardDeleteAll(localItems, policy: policy.withTag('${'sync_$tableName'}_purge'), dbName: dbName);
      } else if (strategy == FluentSyncStrategy.pushActive && actualMarkAsSyncedFields.isNotEmpty) {
        final Set<dynamic> ids = localItems.map((e) => e.primaryKeyValue).where((id) => id != null).toSet();
        if (ids.isNotEmpty) {
          FluentLog.debug('Marking ${ids.length} items as synced', tag: 'sync_$tableName');
          await updateFieldsMultipleByIds(ids, actualMarkAsSyncedFields, policy: policy.withTag('${'sync_$tableName'}_mark_synced'), dbName: dbName);
        } else {
          FluentLog.warning(
            'Failed to mark items as synced: primaryKeyValue is null for all processed items',
            tag: 'sync_$tableName',
            hint: 'Ensure that ${T.toString()} correctly implements primaryKeyValue getter.',
          );
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
}
