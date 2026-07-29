// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe retrieval and query operations
/// for [FluentStorable] entities.
///
/// The [FluentFind] extension establishes a structured, standardized interface over [FluentProvider]
/// for data discovery. It serves as the primary gateway for querying, abstracting low-level
/// storage engine mechanics, index utilization, and result-set serialization.
///
/// ### Core Architecture & Query Paradigms
/// Operations exposed by this extension follow an optimized routing pipeline designed to minimize
/// latency and ensure data consistency:
///
/// * **Unified Discovery:** Provides a consistent API for finding records by ID, criteria,
///   or specialized states (e.g., deleted items).
/// * **Optimized Execution:** All queries are routed through the [FluentEngine] coordinator,
///   ensuring thread-safe I/O and respect for [ExecutionPolicy] constraints.
/// * **Lazy Materialization:** Supports demand-driven loading to prevent unnecessary memory
///   overhead during large-scale retrieval.
/// * **Relational Hydration:** Automatically handles depth-controlled loading of linked models,
///   ensuring that your entity graph is populated efficiently.
///
/// ### Execution Routing
/// Every method in this extension creates a [FluentTask], which is dispatched to the centralized
/// [FluentDb] orchestrator. This decoupling allows the engine to optimize query planning,
/// batching, and caching without changing the high-level business logic.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [FluentEngine], the underlying task orchestration layer.
/// * [ExecutionPolicy], which defines concurrency and priority controls for queries.
extension FluentFind<T extends FluentStorable> on FluentProvider<T> {
  /// Fetches a single object mapping from the database table [$tableName] matching execution criteria.
  ///
  /// This operational bridge utilizes the batch selection pipeline [findAll] under the hood,
  /// specifying a strict constraint of a single item via the `limit: 1` optimization parameter.
  ///
  /// [maxDepth] determines the cascading relation traversal threshold for database sub-tables.
  /// [ignoreLazy] overrides proxy model configurations to execute synchronous joins where applicable.
  /// [policy] configures low-level isolation and worker routing parameters for the underlying task.
  ///
  /// Returns the typed instance [T] if an entity satisfies constraints; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeSession = await sessionRepository.findOne(
  ///   maxDepth: 2,
  ///   ignoreLazy: true,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Prevents dual-fetching on parallel view allocations
  ///   ),
  /// );
  /// ```
  @internal
  Future<T?> findOne({int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) async {
    FluentLog.debug(
      'Evaluating operational pipeline constraints for single-row entity lookup',
      tag: '$tableName:findOne',
      context: {'tableName': tableName, 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final List<T> results = await findAll(maxDepth: maxDepth, ignoreLazy: ignoreLazy, limit: 1, policy: policy, dbName: dbName);

    return results.isNotEmpty ? results.first : null;
  }

  /// Fetches a batch collection of typed objects [T] from the database table [$tableName].
  ///
  /// This high-performance selection pipeline encapsulates runtime parameters into a unified [FluentTask]
  /// and pipes it into the asynchronous worker scheduler architecture for stream or thread routing.
  ///
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [maxDepth] determines the operational traversal deep-linking threshold for relational nested child models.
  /// [ignoreLazy] overrides default structural configurations to immediately evaluate proxies or nested sub-tables.
  /// [policy] defines prioritization, synchronization, and query collapsing rules managed by the coordinator.
  ///
  /// Returns a typed [List<T>] containing matched relational structures materialized from the data layer.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final standardOrders = await orderRepository.findAll(
  ///   limit: 50,
  ///   maxDepth: 3,
  ///   ignoreLazy: false
  /// );
  /// ```
  @internal
  Future<List<T>> findAll({String? orderBy, int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for batch row selection',
      tag: '$tableName:findAll',
      context: {'tableName': tableName, 'limit': limit ?? 'unlimited', 'orderBy': orderBy, 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findAll,
      table: tableName,
      dbName: dbName ?? this.dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, multiple: true, where: _injectSoftDelete(null), orderBy: orderBy),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Fetches a filtered batch collection of typed objects [T] containing non-expired valid records from [$tableName].
  ///
  /// This specialized selection routine wraps localized expiration checking filters and
  /// relational parameters into a unified [FluentTask] before passing it to the thread-pool router.
  ///
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [sortDirection] defines the sorting order by expiration date.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a filtered [List<T>] containing materialized active data layers.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeVouchers = await voucherRepository.findValidItems(
  ///   limit: 10,
  ///   sortDirection: SortDirection.asc,
  ///   maxDepth: 1,
  ///   policy: const ExecutionPolicy(cancelIfDuplicate: true), // Enable query collapsing protection
  /// );
  /// ```
  @internal
  Future<List<T>> findValidItems({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    SortDirection? sortDirection,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    FluentLog.debug(
      'Initiating localized query pipeline for unexpired validation row selection',
      tag: '$tableName:findValidItems',
      context: {
        'tableName': tableName,
        'limit': limit ?? 'unlimited',
        'sortDirection': sortDirection,
        'where': where,
        'whereArgs': whereArgs,
        'orderBy': orderBy,
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findValidItems,
      table: tableName,
      dbName: dbName ?? this.dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, multiple: true, sortDirection: sortDirection, where: _injectSoftDelete(where), whereArgs: whereArgs, orderBy: orderBy),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Fetches a batch collection of typed objects [T] from [$tableName] matching a specific column attribute value.
  ///
  /// This conditional selection routine automatically infers your table's primary key structure
  /// if the [key] parameter is omitted, passing parameterized mapping constraints into a uniform [FluentTask].
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [key] specifies the targeted column field name to filter against. Defaults to the table's primary key.
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a matched [List<T>] containing materialized data layers.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeUsers = await userRepository.findItemsBy(
  ///   'active',
  ///   key: 'status',
  ///   limit: 100,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Merges parallel identical selection calls
  ///   ),
  /// );
  /// ```
  @internal
  Future<List<T>> findItemsBy(dynamic value, {String? orderBy, String? key, int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    // Fall back to the inferred primary key identifier if no custom attribute key is passed
    final String searchKey = key ?? (_cachedPrimaryKey?.name ?? 'id');

    FluentLog.debug(
      'Initiating localized query pipeline for conditional attribute row selection',
      tag: '$tableName:findItemsBy',
      context: {
        'tableName': tableName,
        'orderBy': orderBy,
        'searchColumnKey': searchKey,
        'searchConditionValue': value.toString(),
        'limit': limit ?? 'unlimited',
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findItemsBy,
      table: tableName,
      dbName: dbName ?? this.dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, key: searchKey, value: value, where: _injectSoftDelete('$searchKey = ?'), whereArgs: [value], multiple: true, orderBy: orderBy),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Fetches a single typed object [T] from the database table [$tableName] by its primary key [id].
  ///
  /// This unique identification selection routine encapsulates the lookup constraints into a uniform [FluentTask]
  /// and pipes it into the asynchronous worker scheduler architecture for stream or thread routing.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns the materialized typed instance [T] if found; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final userProfile = await userRepository.findById(
  ///   'usr_892x04',
  ///   maxDepth: 2,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Enables query collapsing to prevent parallel double-fetching
  ///   ),
  /// );
  /// ```
  @internal
  Future<T?> findById(dynamic id, {int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    FluentLog.debug(
      'Initiating localized query pipeline for primary key row selection',
      tag: '$tableName:findById',
      context: {'tableName': tableName, 'targetId': id.toString(), 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findById,
      table: tableName,
      dbName: dbName ?? this.dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(id: id, limit: 1, multiple: false, where: _injectSoftDelete(null)),
      policy: policy,
    );

    return FluentDb.executeTask<T, T?>(provider: this, task: task);
  }

  /// Fetches a batch collection of typed objects [T] from [$tableName] satisfying custom query constraints.
  ///
  /// This flexible selection routine encapsulates low-level SQLite query modifiers (including raw filters,
  /// sorting definitions, and explicit pagination indexes) into a standardized [FluentTask] payload architecture.
  ///
  /// [where] defines the parameterized filter query constraint string (e.g., 'status = ? AND age > ?').
  /// [whereArgs] contains the typed runtime evaluation variables mapped directly to placeholders in the where clause.
  /// [whereFilter] provides a type-safe, composable alternative to raw [where] and [whereArgs] (e.g., using [FluentFilter.eq]).
  /// [orderBy] defines explicit sorting priorities and directions (e.g., 'created_at DESC, total_price ASC').
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [offset] specifies the row index constraint from which database record extraction starts.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// *Note: You can use either [whereFilter] or [where] / [whereArgs] to scope*
  /// *the query, but providing both simultaneously will trigger an assertion error.*
  ///
  /// Returns a matching [List<T>] containing materialized data layers.
  ///
  /// ### Usage Example with type-safe [whereFilter]:
  /// ```dart
  /// final Invoice premiumInvoices = await invoiceRepository.find(
  ///   whereFilter: FluentFilter.eq('status', 'PAID')
  ///       .and(FluentFilter.gt('total_amount', 500.0)),
  ///   orderBy: 'settled_at DESC',
  ///   limit: 20,
  ///   offset: 40, // Useful for multi-tier pagination screens
  /// );
  /// ```
  @internal
  Future<List<T>> find({
    String? where,
    List<Object?>? whereArgs,
    FluentFilter? whereFilter,
    String? orderBy,
    int? limit,
    int? offset,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    assert(!(whereFilter != null && where != null), 'Provide either [whereFilter] or [where], not both.');

    if (whereFilter != null && where != null) {
      FluentLog.warning(
        'Mutually exclusive query parameters provided.',
        tag: '$tableName:find',
        hint: 'Both [whereFilter] and [where] were passed. The raw [where] clause will be ignored. Please leave only one to prevent unexpected behavior.',
        context: {'tableName': tableName, 'ignoredWhere': where, 'appliedFilter': whereFilter.whereClause, 'appliedFilterArgs': whereFilter.whereArgs},
      );
    }

    final String? actualWhere = whereFilter?.whereClause ?? where;
    final List<Object?>? actualWhereArgs = whereFilter?.whereArgs ?? whereArgs;

    FluentLog.debug(
      'Initiating global operational query pipeline for structured condition row selection',
      tag: '$tableName:find',
      context: {
        'tableName': tableName,
        'hasWhereClause': actualWhere != null,
        'whereArgsCount': actualWhereArgs?.length ?? 0,
        'hasOrderBy': orderBy != null,
        'limit': limit ?? 'unlimited',
        'offset': offset ?? 0,
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.find,
      dbName: dbName ?? this.dbName,
      table: tableName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(where: _injectSoftDelete(actualWhere), whereArgs: actualWhereArgs, orderBy: orderBy, limit: limit, offset: offset, multiple: true),
      policy: policy,
    );
    final String? injectedWhere = _injectSoftDelete(actualWhere);
    FluentLog.debug('Generated SQL WHERE clause', tag: 'debug:sql', context: {'injected': injectedWhere, 'original': actualWhere});
    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Retrieves all records from the database that have been marked as soft-deleted.
  ///
  /// This method acts as the primary interface for accessing the "trash" or
  /// archived dataset. It is specifically designed to filter for entries where
  /// the [FluentSoftDeletable.softDeleteColumn] contains a value (is not null).
  ///
  /// * **Type Guard:** Ensures the model implements the [FluentSoftDeletable] mixin;
  ///   returns an empty list if soft-deletion is not supported for the entity.
  /// * **Dynamic Filtering:** Internally leverages [_injectSoftDelete] to apply the
  ///   `IS NOT NULL` constraint while respecting the global query pipeline.
  /// * **Hydration:** Fully supports relational hydration and lazy-loading policies,
  ///   matching the behavior of the standard [find] method.
  ///
  /// [limit] defines an optional cap on the number of returned deleted records.
  /// [maxDepth] controls the recursion depth for relational hydration.
  /// [ignoreLazy] allows skipping lazy-loading constraints during retrieval.
  /// [policy] defines prioritization, concurrency, and task management configurations.
  ///
  /// Returns a [Future<List<T>>] containing the materialized instances found in the trash.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Retrieve all deleted user accounts for review
  /// final List<User> deletedUsers = await userRepository.findDeletedItems(
  ///   limit: 50,
  ///   policy: const ExecutionPolicy(priority: TaskPriority.background),
  /// );
  ///
  /// print('Found ${deletedUsers.length} deleted items.');
  /// ```
  @internal
  Future<List<T>> findDeletedItems({String? orderBy, int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (modelSample is! FluentSoftDeletable) {
      FluentLog.warning(
        'Find-deleted items aborted: model does not support soft-deletion',
        tag: '$tableName:findDeletedItems',
        hint: 'Only models implementing FluentSoftDeletable can perform this query.',
        context: {'tableName': tableName},
      );
      return Future.value(<T>[]);
    }

    FluentLog.debug(
      'Retrieving soft-deleted records',
      tag: '$tableName:findDeletedItems',
      context: {'tableName': tableName, 'orderBy': orderBy, 'limit': limit ?? 'none', 'maxDepth': maxDepth, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findDeletedItems,
      table: tableName,
      dbName: dbName ?? this.dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(where: _injectSoftDelete(null, requestDeletedOnly: true), limit: limit, multiple: true, orderBy: orderBy),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }
}
