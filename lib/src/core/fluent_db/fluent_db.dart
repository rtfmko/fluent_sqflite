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

  /// Defines the retention interval for soft-deleted records before they become
  /// eligible for permanent removal.
  ///
  /// Defaults to [defaultSoftDeleteRetentionPeriod] to balance storage efficiency
  /// with data recovery capabilities.
  static Duration _softDeleteRetentionPeriod = defaultSoftDeleteRetentionPeriod;

  /// Retrieves the current retention period configured for the soft-delete maintenance cycle.
  static Duration get softDeleteRetentionPeriod => _softDeleteRetentionPeriod;

  /// Tracks the initialization status of the registry.
  bool _isInitialized = false;

  /// Flag indicating if the registry is running in Development mode (enables destructive operations like `deleteDatabase` on failure).
  bool _isDevMod = false;

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
  @internal
  static List<({FluentProvider parentProvider, FluentDbRelation relation})> getIncomingRelationsFor(Type targetModelType) {
    final List<({FluentProvider parentProvider, FluentDbRelation relation})> incoming = [];

    for (final FluentProvider<FluentStorable> parentProvider in _instance._providers.values) {
      if (parentProvider is FluentRelationsMixin) {
        final Map<Type, FluentDbRelation> relationsMap = parentProvider.resolvedRelations;

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

    return stream.map((event) => FluentChangeEvent<T>(modelType: event.modelType, action: event.action, items: event.items.cast<T>(), customTag: event.customTag));
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
  static Future<void> saveItem<T extends FluentStorable>(T item, {bool updateIfExist = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().saveItem(item, updateIfExist: updateIfExist, policy: policy.withTag(tag));

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
  /// final List<Session> activeSessions = await FluentDb.findValidItems<Session>(limit: 5, sortDirection: SortDirection.asc);
  /// ```
  static Future<List<T>> findValidItems<T extends FluentStorable>({
    int? limit,
    SortDirection? sortDirection,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().findValidItems(limit: limit, sortDirection: sortDirection, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

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
  static Future<int> update<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().update(item, policy: policy.withTag(tag));

  /// Updates a record represented by [item] along with its related entities.
  ///
  /// Use this method when your model has dependencies (Foreign Keys) that also need
  /// to be synchronized or updated in a single transaction.
  ///
  /// **Example:**
  /// ```dart
  /// final UserProfile updatedProfile = userProfile.copyWith(bio: "New Bio");
  /// // This will update the Profile table and sync any related Settings or Roles
  /// await FluentDb.updateWithRelations<UserProfile>(updatedProfile);
  /// ```
  static Future<int> updateWithRelations<T extends FluentStorable>(
    T item, {
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().updateWithRelations(item, syncMode: syncMode, policy: policy.withTag(tag));

  /// Performs a transactional batch update of multiple entities along with their
  /// full relational graphs.
  ///
  /// This method is the high-performance counterpart to [updateWithRelations]. It
  /// processes the entire collection of [items] in a single atomic database
  /// transaction, making it the preferred choice for bulk state reconciliation
  /// and syncing large datasets from remote APIs.
  ///
  /// ### Relational Integrity
  /// The [syncMode] parameter governs how the relational graph is merged:
  /// * [FluentRelationSyncMode.preserveLocal]: Retains existing child records that
  ///   are not present in the update payload.
  /// * [FluentRelationSyncMode.replace]: Clears orphaned relations and fully
  ///   replaces the child associations with the incoming data.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> updatedUsers = [user1, user2];
  /// // Updates the User table and cascades changes to linked Posts,
  /// // Comments, or Profiles in a single transactional batch.
  /// await FluentDb.updateAllWithRelations<User>(
  ///   updatedUsers,
  ///   syncMode: FluentRelationSyncMode.replace,
  /// );
  /// ```
  ///
  /// Returns a [Future<int>] representing the total number of root entities
  /// successfully updated.
  static Future<int> updateAllWithRelations<T extends FluentStorable>(
    Iterable<T> items, {
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _executeMixedBatch(items, (provider, typedItems) => provider.updateAllWithRelations(typedItems, syncMode: syncMode, policy: policy.withTag(tag)));

  /// Updates an entity instance and returns its fully synchronized state from the database.
  ///
  /// This method performs an atomic update of the provided [item] and immediately
  /// triggers a follow-up fetch to ensure the object in memory reflects the latest
  /// state stored in the database. This is critical for entities containing
  /// database-generated fields, triggers, or updated timestamps.
  ///
  /// **Example:**
  /// ```dart
  /// // Update an entity and get the refreshed version with database-managed fields
  /// final User? refreshedUser = await FluentDb.updateAndFetch(userInstance);
  ///
  /// if (refreshedUser != null) {
  ///   print('Entity updated and synchronized: ${refreshedUser.updatedAt}');
  /// }
  /// ```
  static Future<T?> updateAndFetch<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateAndFetch(item, policy: policy.withTag(tag));

  /// Performs a targeted, partial update on a single field of a record identified by ID.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateByKey<User>(1, 'last_login', DateTime.now().toString());
  /// ```
  static Future<int> updateByKey<T extends FluentStorable>(dynamic id, String updateKey, dynamic updateValue, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateByKey(id, updateKey, updateValue, policy: policy.withTag(tag));

  /// Performs a partial update on multiple fields for a specific record.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateFieldsMultiple<User>(1, {'status': 'active', 'last_seen': '2026-05-25'});
  /// ```
  static Future<int> updateFieldsMultiple<T extends FluentStorable>(dynamic id, Map<String, dynamic> fields, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateFieldsMultiple(id, fields, policy: policy.withTag(tag));

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// This method iterates through the provided [items], synchronizes their
  /// fields with the database schema, and commits the updates as an atomic
  /// transaction. It is the most efficient way to perform bulk state updates
  /// across your data layer.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> usersToUpdate = [user1, user2, user3];
  /// // Perform bulk update on all provided instances
  /// final int affectedRows = await FluentDb.updateAll(usersToUpdate);
  /// print('Successfully updated $affectedRows records.');
  /// ```
  static Future<int> updateAll<T extends FluentStorable>(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _executeMixedBatch<T>(items, (provider, typedItems) => provider.updateAll(typedItems, policy: policy.withTag(tag)));

  /// Performs a transactional batch update of specific fields for a set of identified entities.
  ///
  /// This method is designed for high-performance bulk state changes. It takes a set
  /// of primary keys and a map of fields, updates all matching records in the
  /// database to the new values, and ensures schema integrity by filtering
  /// out non-existent columns.
  ///
  /// **Example:**
  /// ```dart
  /// // Mass-update the 'status' and 'updated_at' fields for a set of users
  /// final int updatedCount = await FluentDb.updateMultipleFieldsByIds<User>(
  ///   {1, 2, 3, 4, 5},
  ///   {'status': 'active', 'updated_at': DateTime.now().toIso8601String()},
  /// );
  /// print('Successfully updated $updatedCount records.');
  /// ```
  static Future<int> updateMultipleFieldsByIds<T extends FluentStorable>(Set<dynamic> ids, Map<String, dynamic> fields, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().updateFieldsMultipleByIds(ids, fields, policy: policy.withTag(tag));

  /// Deletes a specific record instance.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.delete<User>(userInstance);
  /// ```
  static Future<int> delete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().delete(item, policy: policy.withTag(tag));

  /// Deletes records matching a specific field value.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteBy<User>('inactive', key: 'status');
  /// ```
  static Future<int> deleteBy<T extends FluentStorable>(dynamic value, {Object? tag, String? key, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().deleteBy(value, key: key, policy: policy.withTag(tag));

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// This method iterates through the provided collection of [items], extracts
  /// their primary keys, and executes a bulk removal operation. Depending on
  /// the model configuration, this will either perform a soft-delete (marking
  /// the record as inactive) or a hard-delete (permanent erasure).
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> usersToDelete = [user1, user2, user3];
  /// // Perform bulk deletion of the provided instances
  /// final int deletedCount = await FluentDb.deleteAll(usersToDelete);
  /// print('Successfully processed $deletedCount deletions.');
  /// ```
  static Future<int> deleteAll<T extends FluentStorable>(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _executeMixedBatch<T>(items, (provider, typedItems) => provider.deleteAll(typedItems, policy: policy.withTag(tag)));

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// Unlike standard deletion methods that may utilize soft-delete markers, this
  /// routine executes a permanent removal of the specified [items] from the
  /// database storage.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> expiredUsers = [user1, user2, user3];
  /// // Permanently remove entities from the database
  /// final int deletedCount = await FluentDb.hardDeleteAll(expiredUsers);
  /// print('Permanently removed $deletedCount records.');
  /// ```
  static Future<int> hardDeleteAll<T extends FluentStorable>(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _executeMixedBatch<T>(items, (provider, typedItems) => provider.hardDeleteAll(typedItems, policy: policy.withTag(tag)));

  /// Deletes a batch of records identified by their primary keys.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteItemsByIds<User>({1, 2, 3});
  /// ```
  static Future<int> deleteItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().deleteItemsByIds(ids, policy: policy.withTag(tag));

  /// Clears items that have exceeded their TTL (Time To Live).
  /// Typically used by maintenance routines.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearExpiredItems<Cache>();
  /// ```
  static Future<int> clearExpiredItems<T extends FluentStorable>({Object? tag, DatabaseExecutor? executor, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().clearExpiredItems(executor: executor, policy: policy.withTag(tag));

  /// Removes all records from the table associated with type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearTable<Cache>();
  /// ```
  static Future<int> clearTable<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().clearTable(policy: policy.withTag(tag));

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

  /// Executes a custom SQL statement against the database for the specified entity type [T].
  ///
  /// Use this method for complex database operations that are not covered
  /// by standard CRUD methods. Returns the number of affected rows.
  ///
  /// **Example:**
  /// ```dart
  /// // Update status for all inactive users and get the affected count
  /// final int updatedCount = await FluentDb.execute<User>(
  ///   "UPDATE users SET status = ? WHERE last_login < ?",
  ///   arguments: [1, cutoffDate],
  /// );
  /// ```
  static Future<int> execute<T extends FluentStorable>(String sql, {List<dynamic>? arguments, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().execute(sql, arguments: arguments, policy: policy);

  /// Restores a soft-deleted record by its unique primary key.
  ///
  /// **Example:**
  /// ```dart
  /// final int count = await FluentDb.restoreById<User>(101);
  /// ```
  static Future<int> restoreById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().restoreById(id, policy: policy.withTag(tag));

  /// Restores a soft-deleted record by its unique primary key and immediately
  /// retrieves the fully refreshed entity.
  ///
  /// This method combines [restoreById] and [findById] into a single atomic-like
  /// operation. It is the preferred way to restore a record when you need to
  /// reflect the restored state (e.g., reset timestamps or updated metadata)
  /// directly in the UI without a secondary fetch call.
  ///
  /// **Example:**
  /// ```dart
  /// // Restore a user and get the refreshed object instance
  /// final User? restoredUser = await FluentDb.restoreAndFetchById<User>(101);
  ///
  /// if (restoredUser != null) {
  ///   print('User restored successfully: ${restoredUser.name}');
  /// }
  /// ```
  static Future<T?> restoreAndFetchById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().restoreAndFetchById(id, policy: policy.withTag(tag));

  /// Restores a previously soft-deleted object instance.
  ///
  /// **Example:**
  /// ```dart
  /// final int restoredCount = await FluentDb.restore<User>(userInstance);
  /// ```
  static Future<int> restore<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().restore(item, policy: policy.withTag(tag));

  /// Restores a soft-deleted entity instance and returns its refreshed state from the database.
  ///
  /// This method is the instance-based counterpart to [restoreAndFetchById]. It is
  /// designed for scenarios where you already hold the entity object in memory (e.g.,
  /// after selecting it from a "trash" list) and need to immediately return it to
  /// an "active" state with updated database-managed fields.
  ///
  /// **Example:**
  /// ```dart
  /// // Restore an entity instance held in memory and get its refreshed state
  /// final User? activeUser = await FluentDb.restoreAndFetch(deletedUserInstance);
  ///
  /// if (activeUser != null) {
  ///   print('Entity restored and synced: ${activeUser.id}');
  /// }
  /// ```
  static Future<T?> restoreAndFetch<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().restoreAndFetch(item, policy: policy.withTag(tag));

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// This method iterates through the provided collection of [items], extracts their
  /// primary keys, and initiates a bulk restoration sequence. It is the most
  /// efficient way to restore multiple records while ensuring relational and
  /// transactional integrity.
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> deletedUsers = [user1, user2, user3];
  /// // Restore multiple entities in a single atomic operation
  /// final int restoredCount = await FluentDb.restoreAll(deletedUsers);
  /// print('Successfully restored $restoredCount records.');
  /// ```
  static Future<int> restoreAll<T extends FluentStorable>(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _executeMixedBatch<T>(items, (provider, typedItems) => provider.restoreAll(typedItems, policy: policy.withTag(tag)));

  /// Performs a transactional batch restoration of multiple soft-deleted entities
  /// identified by their primary keys.
  ///
  /// This method is the primary entry point for bulk recovery operations. It
  /// coordinates the restoration process by resetting deletion markers across
  /// all provided identifiers in a single atomic database transaction.
  ///
  /// **Example:**
  /// ```dart
  /// // Restore a specific set of users by their IDs
  /// final int restoredCount = await FluentDb.restoreItemsByIds<User>({101, 102, 103});
  /// print('Restored $restoredCount records.');
  /// ```
  static Future<int> restoreItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().restoreItemsByIds(ids, policy: policy.withTag(tag));

  /// Permanently removes an object instance from the database, bypassing any soft-delete mechanisms.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.hardDelete<User>(userInstance);
  /// ```
  static Future<int> hardDelete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().hardDelete(item, policy: policy.withTag(tag));

  /// Permanently removes a record from the database by its primary key, bypassing any soft-delete mechanisms.
  ///
  /// **Example:**
  /// ```dart
  /// final int deletedCount = await FluentDb.hardDeleteById<User>(101);
  /// ```
  static Future<int> hardDeleteById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().hardDeleteById(id, policy: policy.withTag(tag));

  /// Permanently removes records matching a specific field value, bypassing any soft-delete mechanisms.
  ///
  /// **Example:**
  /// ```dart
  /// // Permanently delete all users with a specific status
  /// await FluentDb.hardDeleteBy<User>( 'inactive', key: 'status');
  /// ```
  static Future<int> hardDeleteBy<T extends FluentStorable>(dynamic value, {Object? tag, String? key, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().hardDeleteBy(value, key: key, policy: policy.withTag(tag));

  /// Permanently removes a collection of records from the database by their primary keys.
  ///
  /// **Example:**
  /// ```dart
  /// // Permanently delete multiple products by their IDs
  /// await FluentDb.hardDeleteItemsByIds<Product>({10, 25, 42});
  /// ```
  static Future<int> hardDeleteItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().hardDeleteItemsByIds(ids, policy: policy.withTag(tag));

  /// Retrieves all records of type [T] that have been marked as soft-deleted.
  ///
  /// **Example:**
  /// ```dart
  /// // Fetch the last 20 deleted items for potential recovery
  /// final List<User> deletedUsers = await FluentDb.findDeletedItems<User>(limit: 20);
  /// ```
  static Future<List<T>> findDeletedItems<T extends FluentStorable>({int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().findDeletedItems(limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy);

  /// Permanently deletes all soft-deleted records of type [T] that have exceeded their retention period.
  ///
  /// **Example:**
  /// ```dart
  /// // Run a cleanup task to permanently remove expired deleted records
  /// await FluentDb.purgeSoftDeleted<User>();
  /// ```
  static Future<int> purgeSoftDeleted<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => providerByType<T>().purgeSoftDeleted(policy: policy.withTag(tag));

  /// Permanently and immediately removes all soft-deleted records of type [T].
  ///
  /// Unlike [purgeSoftDeleted], which respects the retention period, this method
  /// acts as an "Empty Trash" function, forcefully deleting all records currently
  /// marked as soft-deleted regardless of when they were deleted.
  ///
  /// **Example:**
  /// ```dart
  /// // Manual "forcePurgeSoftDeleted" functionality initiated by the user
  /// final int clearedItems = await FluentDb.forcePurgeSoftDeleted<User>();
  /// ```
  static Future<int> forcePurgeSoftDeleted<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      providerByType<T>().forcePurgeSoftDeleted(policy: policy.withTag(tag));

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// Saves a list of items of type [T] atomically.
  ///
  /// **Example Usage:**
  /// ```dart
  /// await FluentDb.saveItems([user1, user2, user3]);
  /// ```
  /// Persists a heterogeneous collection of [FluentStorable] items.
  static Future<void> saveItems<T extends FluentStorable>(List<T> itemsToSave, {bool updateIfExists = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      await _executeMixedBatch<T>(itemsToSave, (provider, typedItems) async {
        await provider.saveItems(typedItems, updateIfExist: updateIfExists, policy: policy.withTag(tag));
        return 0;
      });

  /// Orchestrates a data synchronization cycle between the local database and a remote backend.
  ///
  /// This method provides a centralized way to execute synchronization strategies,
  /// handling data discovery, asynchronous network transport, and post-sync database
  /// cleanup or state updates.
  ///
  /// **Example:**
  /// ```dart
  /// // Push pending local tasks to the server and mark them as synced
  /// final FluentSyncResult<Task> result = await FluentDb.syncWithServer<Task>(
  ///   strategy: FluentSyncStrategy.pushActive,
  ///   onPush: (items) async => await myApiClient.uploadTasks(items),
  ///   additionalWhere: 'is_synced = 0',
  ///   markAsSyncedFields: {'is_synced': 1},
  ///   tag: 'TaskSync',
  /// );
  /// ```
  static Future<FluentSyncResult<T>> syncWithServer<T extends FluentStorable>({
    required FluentSyncStrategy strategy,
    Future<bool> Function(List<T> items)? onPush,
    Future<List<T>> Function()? onPull,
    String? additionalWhere,
    List<Object?>? additionalWhereArgs,
    Map<String, dynamic>? markAsSyncedFields,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().syncWithServer(
    strategy: strategy,
    onPush: onPush,
    onPull: onPull,
    additionalWhere: additionalWhere,
    additionalWhereArgs: additionalWhereArgs,
    markAsSyncedFields: markAsSyncedFields,
    tag: tag,
    policy: policy,
  );

  /// Initiates a reactive synchronization pipeline for the entity type [T].
  ///
  /// This method orchestrates the full lifecycle: fetching data from the API,
  /// managing retries, reconciling with local storage, and streaming state
  /// updates (loading, saving, completed) to the UI.
  ///
  /// ### Examples
  ///
  /// **1. Syncing a collection (List):**
  /// Use [FluentApiResponse.list] when the endpoint returns multiple items.
  /// ```dart
  /// FluentDb.reactiveSync<User>(
  ///   fetchFromApi: () async {
  ///     final http.Response response = await http.get(Uri.parse('[https://api.example.com/users](https://api.example.com/users)'));
  ///     final List<User> users = (jsonDecode(response.body) as List)
  ///         .map((e) => User.fromJson(e)).toList();
  ///     return FluentApiResponse.list(data: users, statusCode: response.statusCode);
  ///   },
  /// ).listen((event) {
  ///   if (event.phase == FluentPipelinePhase.apiReady) {
  ///     print('Loaded ${event.data.length} users');
  ///   }
  /// });
  /// ```
  ///
  ///
  /// **2. Syncing a single entity:**
  /// Use [FluentApiResponse.single] to keep the pipeline unified.
  /// Use `options: FluentSyncOptions(limit: 1)` to optimize local cache lookups.
  /// ```dart
  /// FluentDb.reactiveSync<User>(
  ///   fetchFromApi: () async {
  ///     final http.Response response = await http.get(Uri.parse('[https://api.example.com/users/123](https://api.example.com/users/123)'));
  ///     final User user = User.fromJson(jsonDecode(response.body));
  ///     return FluentApiResponse.single(data: user, statusCode: response.statusCode);
  ///   },
  ///   options: const FluentSyncOptions(limit: 1),
  /// ).listen((event) {
  ///   final user = event.data.firstOrNull;
  ///   if (user != null) {
  ///     print('User synchronized: ${user.name}');
  ///   }
  /// });
  /// ```
  ///
  ///
  /// **3. Advanced usage with filtering and custom reconciliation:**
  /// Demonstrates using custom merge strategies, error behaviors, and data transformation.
  /// ```dart
  /// await FluentDb.reactiveSync<Post>(
  ///   fetchFromApi: () async {
  ///     final Response res = await dio.get('/posts', queryParameters: {'userId': 123});
  ///     return FluentApiResponse.list(
  ///       data: (res.data as List).map((e) => Post.fromJson(e)).toList(),
  ///       statusCode: res.statusCode ?? 200,
  ///     );
  ///   },
  ///   localWhere: 'user_id = ?',
  ///   localWhereArgs: [123],
  ///   options: FluentSyncOptions<Post>(
  ///     executionStrategy: FluentExecutionStrategy.cacheThenApiYieldThenSave,
  ///     mergeStrategy: FluentMergeStrategy.syncDeletions,
  ///     retryCount: 3,
  ///     beforeSave: (items) async => items.map((p) => p.copyWith(syncedAt: DateTime.now())).toList(),
  ///     statusBehaviors: {
  ///       401: FluentApiErrorBehavior.clearCacheAndYieldError,
  ///     },
  ///   ),
  /// ).listen((event) {
  ///   if (event.phase == FluentPipelinePhase.completed) {
  ///     // event.data is always a List<Post>, ensuring consistent UI updates
  ///     updateUI(event.data);
  ///   }
  /// });
  /// ```
  ///
  ///
  /// ### Integration with BLoC
  ///
  /// The `reactiveSync` method is designed to work seamlessly with [Bloc].
  /// By using `emit.forEach`, you can transform the sync stream into UI states
  /// safely, without causing memory leaks or state errors.
  ///
  /// ```dart
  /// on<FetchUsersEvent>((event, emit) async {
  ///   await emit.forEach<FluentDataEvent<User>>(
  ///     FluentDb.reactiveSync<User>(
  ///       fetchFromApi: () async => FluentApiResponse.single(
  ///         data: await api.getUsers(),
  ///        ),
  ///     ),
  ///     onData: (syncEvent) => syncEvent.when(
  ///       onLoading: (e) => const UserState.loading(),
  ///       onEmpty: (e) => const UserState.empty(),
  ///       onError: (e) => UserState.error(e.error.toString()),
  ///       onData: (e) => UserState.success(
  ///         user: e.singleData!,
  ///         isOffline: e.isFromCache,
  ///       ),
  ///     ),
  ///   );
  /// });
  /// ```
  /// *Note: This method is non-blocking and provides a [Stream] of [FluentDataEvent].*
  static Stream<FluentDataEvent<T>> reactiveSync<T extends FluentStorable>({
    required Future<FluentApiResponse<T>> Function() fetchFromApi,
    FluentSyncOptions<T> options = const FluentSyncOptions(),
    String? localWhere,
    List<Object?>? localWhereArgs,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>().reactiveSync(fetchFromApi: fetchFromApi, options: options, localWhere: localWhere, localWhereArgs: localWhereArgs, policy: policy);

  /// Dispatches a database task to the background `FluentEngine` for execution.
  ///
  /// This is the core engine of the registry. It handles:
  /// 1. **Context Resolution:** Automatically mapping a [FluentTask] to the correct table/provider.
  /// 2. **Policy Flattening:** Merging operation-specific, provider-level, and global execution policies.
  /// 3. **Result Hydration:** Converting raw SQL results (from the worker isolate) back into domain models using the appropriate [FluentMapper].
  ///
  /// **Example Usage:**
  /// ```dart
  /// final FluentTask task = FluentTask(action: DbAction.findAll);
  /// final user = await FluentDb.executeTask<User, User?>(task: task);
  /// ```
  @internal
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

        final FluentStorable model = FluentMapper(provider).mapToModelSync(result.first);
        return model as R;
      }

      if (task.action == FluentDbAction.find || task.action == FluentDbAction.findAll || task.action == FluentDbAction.findValidItems || task.action == FluentDbAction.findItemsBy) {
        if (result.isEmpty) return <T>[] as R;

        final List<T> models = result.map<T>((row) => FluentMapper(provider!).mapToModelSync(row) as T).toList(growable: false);
        return models as R;
      }
    }

    return result as R;
  }

  /// An internal batch orchestrator that executes database operations across
  /// heterogeneous collections.
  ///
  /// This method is the engine behind all batch operations (saveAll, deleteAll, etc.).
  /// It performs the following steps:
  /// 1. **Classification:** Groups items by their exact [runtimeType] to ensure
  ///    each entity is routed to the correct [FluentProvider].
  /// 2. **Parallel Dispatch:** Executes the provided [action] for each group
  ///    concurrently across available providers.
  /// 3. **Aggregation:** Waits for all batch operations to complete and aggregates
  ///    the total number of affected rows.
  ///
  /// Using this orchestrator allows the library to handle mixed-type lists
  /// (e.g., [User, Post, Comment]) within a single transaction-like flow while
  /// maintaining strict provider-level isolation.
  ///
  /// [items] The collection of models to process.
  /// [action] The operation to perform (e.g., provider.deleteAll).
  /// Returns the sum of affected rows across all executed batches.
  static Future<int> _executeMixedBatch<T extends FluentStorable>(Iterable<T> items, Future<int> Function(FluentProvider provider, List<FluentStorable> typedItems) action) async {
    if (items.isEmpty) return 0;

    final Map<Type, List<FluentStorable>> groupedItems = {};
    for (final T item in items) {
      groupedItems.putIfAbsent(item.runtimeType, () => []).add(item);
    }

    final List<Future<int>> tasks = groupedItems.entries.map((entry) {
      final Type targetType = entry.key;
      final List<FluentStorable> typedItems = entry.value;

      final FluentProvider provider = providerForType(targetType);

      return action(provider, typedItems);
    }).toList();

    final List<int> results = await Future.wait(tasks);
    return results.fold<int>(0, (sum, rowsAffected) => sum + rowsAffected);
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

  /// Returns `true` if the database logging system is currently active.
  ///
  /// This property provides a read-only view into the global logging state.
  /// It is useful for conditional logic in performance-critical code paths
  /// where you may want to skip expensive string building or diagnostic
  /// processing if logging is currently disabled.
  static bool get isLoggingEnable => FluentLog.isEnabled;

  /// Configures the global database telemetry and logging system.
  ///
  /// This method acts as a public facade for the internal [FluentLog] system,
  /// allowing configuration of both application-level and engine-level telemetry.
  ///
  /// * [userLogger]: Handles surface-level application events, SQL execution
  ///   reports, and developer-defined logging.
  /// * [internalLogger]: Handles low-level framework telemetry, performance
  ///   profiling, and deep diagnostic traces.
  /// * [enable]: A global toggle for the logging system. If false, short-circuits
  ///   all logging operations.
  ///
  /// **Example:**
  /// ```dart
  /// FluentDb.setupLogging(
  ///   userLogger: FluentLogger(
  ///     isDebug: true,
  ///     useColors: true,
  ///     onError: (message, e, s) {
  ///       // Send to Crashlytics or Sentry
  ///     },
  ///   ),
  ///   internalLogger: MyCustomCrashlyticsLogger(),
  /// );
  /// ```
  static void setupLogging({FluentTelemetry? userLogger, FluentTelemetry? internalLogger, bool? enable}) => FluentLog.setup(userLogger: userLogger, internalLogger: internalLogger, enable: enable);

  /// Initializes the database logging system with a default configuration.
  ///
  /// This is a convenience method designed for development environments. It
  /// automatically configures user loggers to output
  /// diagnostic information directly to the console with formatting.
  static void setupDefault({bool useColors = true}) => FluentLog.initDefault(useColors: useColors);

  /// Initializes the database logging system with a default debug configuration.
  ///
  /// This is a convenience method designed for development environments. It
  /// automatically configures user loggers to output
  /// diagnostic information (including SQL traces and performance metrics)
  /// directly to the console with formatting.
  static void setupDefaultDebug({bool useColors = true}) => FluentLog.initDefaultDebug(useColors: useColors);

  /// Dynamically toggles the global database logging state at runtime.
  ///
  /// Useful for silencing logs during heavy, non-critical background tasks,
  /// and resuming them afterward.
  ///
  /// **Example:**
  /// ```dart
  /// FluentDb.toggleLogging(false); // Silence logs
  /// await performMassiveDataMigration();
  /// FluentDb.toggleLogging(true); // Resume logs
  /// ```
  static void toggleLogging(bool enable) => FluentLog.isGloballyEnabled(enable);
}
