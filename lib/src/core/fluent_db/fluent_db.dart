// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../fluent_sqflite.dart';
import '../fluent_sqlite_internal.dart';

part 'parts/fluent_db_lifecycle.dart';

part 'parts/fluent_db_locator.dart';

part 'parts/fluent_db_maintenance.dart';

part 'parts/fluent_db_schema.dart';

/// The central orchestration hub for the database persistence layer.
///
/// `FluentDb` acts as a **Singleton Service Locator** that governs the lifecycle,
/// schema configuration, and task execution for the entire application database.
/// It bridges the gap between high-level business models and low-level storage
/// providers by managing:
///
/// * **Provider Lifecycle:** Maintains a registry of [FluentProvider] instances,
///   allowing for type-safe lookups and relational data mapping.
/// * **Isolate Coordination:** Serves as the primary entry point for offloading
///   database I/O to background isolates via the [FluentEngine], ensuring
///   a jank-free UI.
/// * **Schema Integrity:** Centralizes the schema discovery and migration
///   logic to ensure data consistency across multiple database groups.
/// * **Execution Policy:** Enforces consistent transaction behavior, retry
///   logic, and concurrency constraints (via `globalPolicy`) for every
///   database operation.
///
/// Use `FluentDb` as the single source of truth for all database operations,
/// preventing state fragmentation and ensuring atomic consistency across
/// related data providers.
class FluentDb {
  /// Singleton instance of the registry.
  static final FluentDb _instance = FluentDb._internal();

  /// Default execution policy for database operations.
  static ExecutionPolicy globalPolicy = ExecutionPolicy.rootDefault();

  /// O(1) lookup index mapping table names to their respective `FluentProvider`.
  /// Critical for high-performance cross-reference operations and isolate-based messaging.
  final Map<String, FluentProvider<FluentStorable>> _tableToProviderIndex = {};

  /// Stores the most recent configuration applied to the registry for restarts/re-init.
  static List<FluentGroup>? _lastConfig;

  /// Internal storage mapping `Type` (model or provider class) to the corresponding `FluentProvider` instance.
  final Map<Type, FluentProvider> _providers = {};

  /// Tracks the initialization status of the registry.
  bool _isInitialized = false;

  /// Flag indicating if the registry is running in Development mode (enables destructive operations like `deleteDatabase` on failure).
  bool isDevMod = false;

  /// Private internal constructor for the singleton.
  FluentDb._internal();

  /// Factory constructor providing global access to the [FluentDb] instance.
  factory FluentDb() => _instance;

  /// Returns true if the registry has been successfully initialized.
  bool get isInitialized => _isInitialized;

  /// Resolves a `FluentProvider` instance using the target database table name.
  ///
  /// This lookup utilizes the internal O(1) table-to-provider index, making it the
  /// most efficient way to map raw SQL table references back to their corresponding
  /// `FluentProvider` logic.
  ///
  /// **Example Usage:**
  /// ```dart
  /// final provider = FluentDb.getProviderByTable('users_table');
  /// if (provider != null) {
  ///   // Perform operations on the resolved provider
  /// }
  /// ```
  static FluentProvider getProviderByTable(String tableName) {
    final FluentProvider? provider = _instance._tableToProviderIndex[tableName];

    if (provider == null) {
      final ProviderNotFoundException exception = ProviderNotFoundException(Null, stackTrace: StackTrace.current);
      FluentLog.error(
        'Provider for table "$tableName" is not registered',
        exception,
        exception.stackTrace,
        tag: 'FluentDb:providerByTable',
        hint: 'Ensure that the provider for this table has been registered during the init() phase.',
        context: {'tableName': tableName},
      );
      throw exception;
    }

    return provider;
  }

  /// Retrieves a provider instance using a specific [model] instance.
  ///
  /// This is particularly useful in generic logic where you have a [FluentStorable]
  /// object and need to perform database operations on it.
  ///
  /// Throws [ProviderNotFoundException] if the model's type is not registered.
  ///
  /// **Example:**
  /// ```dart
  /// final UserModel user = UserModel(id: 1, name: 'John');
  /// final FluentProvider<FluentStorable> provider = FluentDb.providerByModel(user);
  /// await provider.update(user);
  /// ```
  static FluentProvider providerByModel(FluentStorable model) {
    final Type type = model.runtimeType;
    final FluentProvider? provider = _instance._providers[type];

    if (provider != null) {
      return provider;
    }

    final ProviderNotFoundException exception = ProviderNotFoundException(type, stackTrace: StackTrace.current);
    FluentLog.error(
      'Provider for model "$type" is not registered',
      exception,
      exception.stackTrace,
      tag: 'FluentDb:providerByModel',
      hint: 'Ensure that the provider for this model type has been registered during the init() phase.',
      context: {'modelType': type.toString()},
    );
    throw exception;
  }

  /// Retrieves a provider instance by its model [type].
  ///
  /// Use this when you have a [Type] variable and need to get the
  /// corresponding DAO.
  ///
  /// Throws [ProviderNotFoundException] if the [type] is not registered.
  ///
  /// **Example:**
  /// ```dart
  /// Type dynamicType = UserModel;
  /// final FluentProvider<FluentStorable> provider = FluentDb.providerForType(dynamicType);
  /// ```
  static FluentProvider providerForType(Type type) {
    final FluentProvider? provider = _instance._providers[type];

    if (provider != null) {
      return provider;
    }

    final ProviderNotFoundException exception = ProviderNotFoundException(type, stackTrace: StackTrace.current);
    FluentLog.error(
      'Provider for type "$type" is not registered',
      exception,
      exception.stackTrace,
      tag: 'FluentDb:providerForType',
      hint: 'Verify that the class type is registered in your FluentGroup configuration before accessing it.',
      context: {'type': type.toString()},
    );
    throw exception;
  }

  /// The primary and most type-safe way to access a Data Access Object (DAO).
  ///
  /// It retrieves the [FluentProvider] associated with the model type [T].
  /// Use this for all standard CRUD operations.
  ///
  /// Throws [ProviderNotFoundException] if the model [T] has no registered provider.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentProvider<UserModel> userDAO = FluentDb.dao<UserModel>();
  /// final List<UserModel>? users = await userDAO.getItems();
  /// ```
  static FluentProvider<T> providerByType<T extends FluentStorable>() {
    final FluentProvider? provider = _instance._providers[T];

    if (provider != null) {
      return provider as FluentProvider<T>;
    }

    final ProviderNotFoundException exception = ProviderNotFoundException(T, stackTrace: StackTrace.current);
    FluentLog.error(
      'Provider for model "$T" is not registered',
      exception,
      exception.stackTrace,
      tag: 'FluentDb:providerByType',
      hint: 'Check your FluentDb.init configuration to ensure this model type is included in a FluentGroup.',
      context: {'modelType': T.toString()},
    );
    throw exception;
  }

  /// Finds a registered [FluentProvider] by its own implementation type [T].
  ///
  /// Use this when you need to access custom methods or properties defined
  /// specifically in your provider class, rather than the base [FluentProvider] interface.
  ///
  /// Throws [ProviderNotFoundException] if the model [T] has no registered provider.
  ///
  /// **Example:**
  /// ```dart
  /// // Accessing a custom method like 'syncWithServer()' defined in UserProvider
  /// final UserDAO userDao = FluentDb.provider<UserDAO>();
  /// await userDao.syncWithServer();
  /// ```
  static T provider<T extends FluentProvider>() {
    final FluentProvider<FluentStorable>? provider = _instance._providers[T];

    if (provider != null) {
      return provider as T;
    }

    final ProviderNotFoundException exception = ProviderNotFoundException(T, stackTrace: StackTrace.current);
    FluentLog.error(
      'Provider type "$T" not found in registry',
      exception,
      exception.stackTrace,
      tag: 'FluentDb:provider',
      hint: 'Ensure that the specific provider class is registered in the FluentDb during initialization.',
      context: {'requestedType': T.toString()},
    );
    throw exception;
  }

  /// Searches for all defined relations that point to the [targetModelType].
  ///
  /// This method iterates through all registered providers that implement [FluentRelationsMixin]
  /// and inspects their `syncRelations` maps to identify any that have a dependency
  /// on the specified model.
  ///
  /// **Example Usage:**
  /// ```dart
  /// // Find all tables that have a foreign key or relationship to 'Profile'
  /// final relations = FluentDb.getIncomingRelationsFor(Profile);
  /// for (final entry in relations) {
  ///   print('Relationship found in: ${entry.parentProvider.tableName}');
  /// }
  /// ```
  ///
  /// Returns a list of records containing the [parentProvider] and the specific [FluentDbRelation].
  static List<({FluentProvider parentProvider, FluentDbRelation relation})> getIncomingRelationsFor(Type targetModelType) {
    final List<({FluentProvider parentProvider, FluentDbRelation relation})> incoming = [];

    for (final FluentProvider<FluentStorable> parentProvider in _instance._providers.values) {
      if (parentProvider is FluentRelationsMixin) {
        final Map<Type, FluentDbRelation> relationsMap = parentProvider.syncRelations;

        if (relationsMap.containsKey(targetModelType)) {
          final FluentDbRelation rel = relationsMap[targetModelType]!;

          incoming.add((parentProvider: parentProvider, relation: rel));

          FluentLog.debug(
            'Found incoming relation',
            tag: 'FluentDb:getIncomingRelationsFor',
            context: {'sourceTable': parentProvider.tableName, 'targetModel': targetModelType.toString(), 'relationType': rel.runtimeType.toString()},
          );
        }
      }
    }

    return incoming;
  }

  /// Subscribes to database modification events (Save, Update, Delete) for a specific model type.
  ///
  /// This method provides a reactive interface to track changes in the database.
  /// It filters the global event stream based on the provided [T] model type,
  /// optional [tag] for targeted filtering, and specific [actions].
  ///
  /// **Example Usage:**
  /// ```dart
  /// // Listen for 'save' and 'delete' events on 'Profile' models
  /// // triggered specifically by the background sync worker.
  /// FluentDb.onEvent<Profile>(
  ///   tag: SyncSource.api,
  ///   actions: [FluentDbAction.save, FluentDbAction.delete]
  /// ).listen((event) {
  ///   print('Profile changed via API! Action: ${event.action}');
  /// });
  /// ```
  ///
  /// Returns a filtered [Stream] of [FluentChangeEvent] objects.
  static Stream<FluentChangeEvent<T>> onEvent<T extends FluentStorable>({Object? tag, List<FluentDbAction>? actions}) {
    Stream<FluentChangeEvent<dynamic>> stream = FluentEngine().changeStream;

    if (T != FluentStorable) {
      stream = stream.where((event) => event.modelType == T);
    }

    if (tag != null) {
      stream = stream.where((event) => event.customTag == tag);
    }

    if (actions != null && actions.isNotEmpty) {
      stream = stream.where((event) => actions.contains(event.action));
    }

    return stream.cast<FluentChangeEvent<T>>();
  }

  /// These static convenience methods provide a type-safe interface for performing
  /// CRUD operations through the appropriate `FluentProvider` resolved via the registry.
  ///
  /// Each method leverages the `providerByType<T>()` lookup to delegate execution
  /// to the registered DAO, ensuring consistent policy application and lazy-loading
  /// behavior.

  /// Saves a single [item] of type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.saveItem(User(id: 1, name: 'John Doe'), updateIfExist: true);
  /// ```
  static Future<void> saveItem<T extends FluentStorable>(T item, {bool updateIfExist = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final ExecutionPolicy effectivePolicy = tag != null ? policy.copyWith(customTag: tag) : policy;
    return providerByType<T>().saveItem(item, updateIfExist: updateIfExist, policy: effectivePolicy);
  }

  /// Saves a list of items of type [T] atomically.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.saveItems([user1, user2, user3]);
  /// ```
  static Future<void> saveItems<T extends FluentStorable>(List<T> items, {bool updateIfExist = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final ExecutionPolicy effectivePolicy = tag != null ? policy.copyWith(customTag: tag) : policy;
    return providerByType<T>().saveItems(items, updateIfExist: updateIfExist, policy: effectivePolicy);
  }

  /// Retrieves a single record of type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final User user = await FluentDb.findOne<User>(maxDepth: 2);
  /// ```
  static Future<T?> findOne<T extends FluentStorable>({int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().findOne(maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Retrieves a list of records of type [T] with optional constraints.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> recentUsers = await FluentDb.findAll<User>(limit: 10, maxDepth: 0);
  /// ```
  static Future<List<T>> findAll<T extends FluentStorable>({int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().findAll(limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Fetches items that have not yet expired based on their TTL configuration.
  ///
  /// **Example:**
  /// ```dart
  /// final List<Session> activeSessions = await FluentDb.findValidItems<Session>(limit: 5, sortByExpireDate: true);
  /// ```
  static Future<List<T>> findValidItems<T extends FluentStorable>({
    int? limit,
    bool sortByExpireDate = false,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().findValidItems(limit: limit, sortByExpireDate: sortByExpireDate, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Performs a lookup based on a specific property key and value.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> users = await FluentDb.findItemsBy<User>('admin', key: 'role');
  /// ```
  static Future<List<T>> findItemsBy<T extends FluentStorable>(dynamic value, {String? key, int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().findItemsBy(value, key: key, limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Retrieves a single record by its primary key identifier.
  ///
  /// **Example:**
  /// ```dart
  /// final Order order = await FluentDb.findById<Order>(101, maxDepth: 2);
  /// ```
  static Future<T?> findById<T extends FluentStorable>(dynamic id, {int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().findById(id, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Executes a custom SQL-based query with support for `WHERE` clauses,
  /// ordering, and pagination.
  ///
  /// **Example:**
  /// ```dart
  /// final List<Order> highValueOrders = await FluentDb.find<Order>(
  ///   where: 'amount > ?',
  ///   whereArgs: [1000],
  ///   orderBy: 'date DESC'
  /// );
  /// ```
  static Future<List<T>> find<T extends FluentStorable>({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().find(where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit, offset: offset, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Retrieves a single raw record map by a specific column value.
  ///
  /// **Example:**
  /// ```dart
  /// final Map<String, dynamic>? rawUser = await FluentDb.rawGetItemBy<User>('admin@example.com', column: 'email');
  /// ```
  static Future<Map<String, dynamic>?> rawGetItemBy<T extends FluentStorable>(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().rawGetItemBy(value, column: column, policy: policy);

  /// Retrieves a list of raw record maps matching the specified column value.
  ///
  /// **Example:**
  /// ```dart
  /// final List<Map<String, dynamic>> activeOrders = await FluentDb.rawGetItemsBy<Order>('pending', column: 'status');
  /// ```
  static Future<List<Map<String, dynamic>>> rawGetItemsBy<T extends FluentStorable>(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().rawGetItemsBy(value, column: column, policy: policy);

  /// Updates an entire record represented by [item].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.update<User>(updatedUserInstance);
  /// ```
  static Future<void> update<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final ExecutionPolicy effectivePolicy = tag != null ? policy.copyWith(customTag: tag) : policy;
    return providerByType<T>().update(item, policy: effectivePolicy);
  }

  /// Performs a targeted, partial update on a single field of a record identified by ID.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateByKey<User>(1, 'last_login', DateTime.now().toString());
  /// ```
  static Future<void> updateByKey<T extends FluentStorable>(dynamic id, String updateKey, dynamic updateValue, {ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateByKey(id, updateKey, updateValue, policy: policy);

  /// Performs a partial update on multiple fields for a specific record.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateFieldsMultiple<User>(1, {'status': 'active', 'last_seen': '2026-05-25'});
  /// ```
  static Future<void> updateFieldsMultiple<T extends FluentStorable>(dynamic id, Map<String, dynamic> fields, {ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateFieldsMultiple(id, fields, policy: policy);

  /// Deletes a specific record instance.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.delete<User>(userInstance);
  /// ```
  static Future<void> delete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final ExecutionPolicy effectivePolicy = tag != null ? policy.copyWith(customTag: tag) : policy;
    return providerByType<T>().delete(item, policy: effectivePolicy);
  }

  /// Deletes records matching a specific field value.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteBy<User>('inactive', key: 'status');
  /// ```
  static Future<void> deleteBy<T extends FluentStorable>(dynamic value, {String? key, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().deleteBy(value, key: key, policy: policy);

  /// Deletes a batch of records identified by their primary keys.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteItemsByIds<User>({1, 2, 3});
  /// ```
  static Future<void> deleteItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().deleteItemsByIds(ids, policy: policy);

  /// Clears items that have exceeded their TTL (Time To Live).
  /// Typically used by maintenance routines.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearExpiredItems<Cache>();
  /// ```
  static Future<void> clearExpiredItems<T extends FluentStorable>({DatabaseExecutor? executor, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().clearExpiredItems(executor: executor, policy: policy);

  /// Removes all records from the table associated with type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearTable<Cache>();
  /// ```
  static Future<void> clearTable<T extends FluentStorable>({ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().clearTable(policy: policy);

  /// Checks if a record with the given [id] exists in the table.
  ///
  /// **Example:**
  /// ```dart
  /// final bool isExisting = await FluentDb.exists<User>(101);
  /// ```
  static Future<bool> exists<T extends FluentStorable>(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().exists(id, policy: policy);

  /// Returns the count of records matching the optional [where] clause.
  ///
  /// **Example:**
  /// ```dart
  /// final int activeCount = await FluentDb.count<User>(where: 'status = ?', whereArgs: ['active']);
  /// ```
  static Future<int> count<T extends FluentStorable>({String? where, List<Object?>? whereArgs, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().count(where: where, whereArgs: whereArgs, policy: policy);

  /// Persists a heterogeneous collection of [FluentStorable] items using the background
  /// execution queue.
  ///
  /// Unlike the type-specific `saveAll<T>`, this method accepts a list of various
  /// models, allowing for a bulk "sync" operation where different entities (e.g.,
  /// User, Product, Order) are persisted in a single batch process.
  ///
  /// **Example Usage:**
  /// ```dart
  /// final List<FluentStorable> mixedItems = [
  ///   User(id: 1, name: 'Alice'),
  ///   Product(id: 50, title: 'Laptop')
  /// ];
  ///
  /// await FluentDb.saveAllMixed(mixedItems, updateIfExists: true);
  /// ```
  /// Persists a heterogeneous collection of [FluentStorable] items.
  static Future<void> saveAll<T extends FluentStorable>(List<T> itemsToSave, {bool updateIfExists = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (itemsToSave.isEmpty) return;

    final ExecutionPolicy effectivePolicy = tag != null ? policy.copyWith(customTag: tag) : policy;

    final Map<Type, List<FluentStorable>> groupedItems = {};
    for (final T item in itemsToSave) {
      groupedItems.putIfAbsent(item.runtimeType, () => []).add(item);
    }

    final List<Future<void>> batchTasks = [];

    for (final MapEntry<Type, List<FluentStorable>> entry in groupedItems.entries) {
      final Type targetType = entry.key;
      final List<FluentStorable> typedItems = entry.value;

      final FluentProvider provider = providerForType(targetType);

      batchTasks.add(provider.saveItems(typedItems, updateIfExist: updateIfExists, policy: effectivePolicy));
    }

    await Future.wait(batchTasks);
  }

  /// Dispatches a database task to the background `FluentEngine` for execution.
  ///
  /// This is the core engine of the registry. It handles:
  /// 1. **Context Resolution:** Automatically mapping a [FluentTask] to the correct table/provider.
  /// 2. **Policy Flattening:** Merging operation-specific, provider-level, and global execution policies.
  /// 3. **Result Hydration:** Converting raw SQL results (from the worker isolate) back into domain models using the appropriate [FluentProviderMapper].
  ///
  /// **Example Usage:**
  /// ```dart
  /// final FluentTask task = FluentTask(action: DbAction.findAll);
  /// final user = await FluentDb.executeTask<User, User?>(task: task);
  /// ```
  static Future<R> executeTask<T, R>({required FluentTask task, FluentProvider? provider}) async {
    FluentTask effectiveData = task;

    // Resolve Provider and ensure task is tagged with target table/DB name
    if (provider == null || task.table.isEmpty) {
      if (task.data is FluentStorable) {
        provider = providerByModel(task.data as FluentStorable);
      }

      provider ??= providerForType(T);
      effectiveData = task.copyWith(table: provider.tableName, dbName: provider.dbName);
    }

    // Policy resolution hierarchy: Task -> Provider -> Global Default
    final ExecutionPolicy effectivePolicy = effectiveData.policy.merge(provider.policy).merge(globalPolicy).flatten();

    effectiveData = effectiveData.copyWith(policy: effectivePolicy);

    FluentLog.debug(
      'Dispatching task to background worker',
      tag: 'FluentDb:executor',
      context: {'action': effectiveData.action.toString(), 'table': effectiveData.table, 'policy': effectivePolicy.toString()},
    );

    // Dispatch to isolate coordinator
    final dynamic result = await FluentEngine().dispatch(effectiveData);

    // Handle Model Hydration for Read operations
    if (result is List<Map<String, dynamic>>) {
      if (task.action == FluentDbAction.findById || task.action == FluentDbAction.rawGetItem) {
        if (result.isEmpty) return null as R;

        final FluentStorable model = FluentProviderMapper(provider).mapToModelSync(result.first);
        return model as R;
      }

      if (task.action == FluentDbAction.find || task.action == FluentDbAction.findAll || task.action == FluentDbAction.findValidItems || task.action == FluentDbAction.findItemsBy) {
        if (result.isEmpty) return <T>[] as R;

        final List<T> models = result.map<T>((row) => FluentProviderMapper(provider!).mapToModelSync(row) as T).toList(growable: false);
        return models as R;
      }
    }

    return result as R;
  }

  /// Prints a formatted summary table of all tracked database table statistics
  /// to the console.
  ///
  /// Useful during development to monitor query frequency, execution time,
  /// and cache hit ratios across your database models.
  static void report() => FluentTableStatsTracker().printStatsTable();

  /// Generates a detailed diagnostic report for a specific table in the
  /// given database and returns it as a [String].
  ///
  /// This is intended for advanced debugging or for exporting telemetry
  /// data to log files/external monitoring services.
  ///
  /// * [dbName]: The target database name.
  /// * [tableName]: The specific table to generate the dump for.
  static Future<String> dumpReport(String dbName, String tableName) async => FluentTableStatsTracker().dumpReport(dbName, tableName);
}
