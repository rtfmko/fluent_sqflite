// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe "upsert" (save)
/// operations for [FluentStorable] entities.
///
/// The [FluentSave] extension serves as a high-level orchestration interface that
/// abstracts the decision logic between [FluentInsert] and [FluentUpdate]. It
/// intelligently identifies whether an entity requires creation or mutation based
/// on its primary key state, simplifying the consumer API.
///
/// ### Core Architecture & Persistence Paradigms
/// The save operation is designed to provide a declarative persistence model,
/// ensuring that the database state aligns with the application's domain state
/// without the need for explicit action-routing:
///
/// * **Deterministic Conflict Resolution:** The layer analyzes the entity's
///   identity signature. If the primary key is null or missing, it triggers an
///   insertion pipeline; otherwise, it performs an update. This prevents
///   duplicate key errors and ensures atomicity in synchronized environments.
/// * **Atomic "Upsert" Logic:** Save operations are dispatched as unified
///   transactional units. By treating the record as a single state-sync event,
///   the extension prevents intermediate corrupted states and ensures consistency
///   across complex entity graphs.
/// * **Lazy Loading Optimization:** During save operations, the engine automatically
///   handles lazy-loaded relations, ensuring that associated entity graphs are
///   persisted or linked according to the configured [ExecutionPolicy].
///
/// ### Execution Routing
/// Every save method creates a [FluentTask] dispatched to the [FluentDb]
/// orchestrator. This decoupling allows the [FluentEngine] to perform batching,
/// conflict detection, and cache invalidation as background tasks, keeping the
/// primary execution thread performant.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [FluentEngine], which orchestrates transactional safety and task planning.
/// * [ExecutionPolicy], which defines constraints for batch saving and concurrency.
extension FluentSave<T extends FluentStorable> on FluentProvider<T> {
  /// Saves a single object [item] into the table [$tableName].
  ///
  /// The [saveStrategy] parameter determines how the database handles the insertion:
  /// * [FluentSaveStrategy.upsert] (default) — Overwrites existing records or creates a new one.
  /// * [FluentSaveStrategy.insertOnly] — Ignores duplicate primary keys.
  /// * [FluentSaveStrategy.patch] — Updates only the provided fields (requires record to exist).
  /// * [FluentSaveStrategy.updateOnly] — Updates only existing records; skips new ones.
  ///
  /// The [policy] parameter allows overriding default execution settings, such as
  /// forcing background isolate execution or bypassing request collapsing.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final User user = User(id: 42, name: 'Alex', role: 'admin');
  ///
  /// await userRepository.saveItem(
  ///   user,
  ///   saveStrategy: FluentSaveStrategy.upsert,
  ///   policy: const ExecutionPolicy(useIsolate: false), // Force Main-thread execution
  /// );
  /// ```
  @internal
  Future<void> saveItem(T item, {FluentSaveStrategy saveStrategy = FluentSaveStrategy.upsert, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) async {
    FluentLog.debug(
      'Request to add single item into data layer pipeline',
      tag: '$tableName:saveItem',
      context: {'tableName': tableName, 'saveStrategy': saveStrategy.name, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    await saveItems([item], saveStrategy: saveStrategy, policy: policy, dbName: dbName);
  }

  /// Saves a collection of objects [items] into the table [$tableName].
  ///
  /// This operation is highly optimized for batch processing. It supports various
  /// strategies for handling data collisions via the [saveStrategy] parameter:
  /// * [FluentSaveStrategy.upsert] (default) — Overwrites or creates records.
  /// * [FluentSaveStrategy.insertOnly] — Skips records that already exist.
  /// * [FluentSaveStrategy.patch] / [FluentSaveStrategy.updateOnly] — Partial or strict updates.
  ///
  /// [sharedBatch] allows chaining this operation into an existing cascading transaction.
  /// [cachedJsons] bypasses the serialization loop if payload maps were computed beforehand.
  /// [policy] defines customized scheduler constraints for the underlying [FluentTask].
  ///
  /// ### Usage Example:
  /// ```dart
  /// final List<Order> newOrders = [
  ///   Order(id: 101, total: 55.0),
  ///   Order(id: 102, total: 120.5),
  /// ];
  ///
  /// await orderRepository.saveItems(
  ///   newOrders,
  ///   saveStrategy: FluentSaveStrategy.upsert,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true,
  ///     useIsolate: true, // Offload heavy batch parsing to background worker
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> saveItems(
    List<T> items, {
    FluentSaveStrategy saveStrategy = FluentSaveStrategy.upsert,
    Batch? sharedBatch,
    List<Map<String, dynamic>>? cachedJsons,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    final int itemsLength = items.length;
    if (itemsLength == 0) return Future.value();

    List<Map<String, dynamic>> effectiveJsons;

    if (cachedJsons != null) {
      effectiveJsons = cachedJsons;
    } else {
      effectiveJsons = List<Map<String, dynamic>>.filled(itemsLength, const {}, growable: false);
      for (int i = 0; i < itemsLength; i++) {
        effectiveJsons[i] = _prepareSqlJson(items[i]);
      }
    }

    final FluentTask task = FluentTask(
      action: FluentDbAction.save,
      table: tableName,
      dbName: dbName ?? this.dbName,
      ignoreLazy: true,
      maxDepth: 0,
      data: items,
      relations: effectiveJsons,
      helper: TableHelper(saveStrategy: saveStrategy),
      policy: policy,
    );

    FluentLog.debug(
      'Request to add batch of items into data layer pipeline',
      tag: '$tableName:saveItems',
      context: {'tableName': tableName, 'batchSize': itemsLength, 'saveStrategy': saveStrategy.name, 'hasSharedBatch': sharedBatch != null, 'hasCachedJsons': cachedJsons != null, 'taskId': task.id},
    );

    if (sharedBatch != null) {
      return _executeAdd(null, items, task, sharedBatch: sharedBatch, parentJsons: effectiveJsons);
    }

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }
}
