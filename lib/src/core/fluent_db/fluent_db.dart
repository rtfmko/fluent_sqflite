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

  /// Stores the most recent configuration applied to the registry for restarts/re-init.
  static List<FluentGroup>? _lastConfig;

  /// Internal storage mapping database group names (dbName) to their respective
  /// provider registries.
  ///
  /// This multi-level registry ensures strict isolation between different
  /// database contexts and enables both strict-context resolution and system-wide "smart" lookups.
  final Map<String, Map<Type, FluentProvider>> _groupedRegistry = {};

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
  /// This lookup utilizes the internal index to map raw SQL table references back
  /// to their corresponding `FluentProvider` logic.
  ///
  /// If [dbName] is provided, it resolves the provider within that specific database group.
  /// If omitted, it performs a system-wide lookup and resolves automatically
  /// if the table is registered uniquely.
  ///
  /// Throws [ProviderNotFoundException] if the table is not registered.
  /// Throws [AmbiguousProviderException] if the table exists in multiple database groups.
  ///
  /// **Example Usage:**
  /// ```dart
  /// // Automatically resolves based on table uniqueness
  /// final provider = FluentDb.getProviderByTable('users_table');
  ///
  /// // Context-specific resolution
  /// final provider = FluentDb.getProviderByTable('users_table', dbName: 'core_app');
  /// ```
  static FluentProvider getProviderByTable(String tableName, {String? dbName}) => _resolveProvider(tableName: tableName, dbName: dbName);

  /// Retrieves a provider instance using a specific [model] instance.
  ///
  /// This is particularly useful in generic logic where you have a [FluentStorable]
  /// object and need to perform database operations on it.
  ///
  /// If [dbName] is provided, it resolves the provider within that specific database group.
  /// If omitted, it performs a system-wide lookup and resolves automatically
  /// if the model type is registered uniquely.
  ///
  /// Throws [ProviderNotFoundException] if the model's type is not registered.
  /// Throws [AmbiguousProviderException] if the model's type is registered in multiple database groups.
  ///
  /// **Example:**
  /// ```dart
  /// final UserModel user = UserModel(id: 1, name: 'John');
  /// // Resolves automatically based on registry
  /// final FluentProvider<FluentStorable> provider = FluentDb.providerByModel(user);
  /// await provider.update(user);
  /// ```
  static FluentProvider providerByModel(FluentStorable model, {String? dbName}) => _resolveProvider(modelType: model.runtimeType, dbName: dbName);

  /// Retrieves a provider instance by its model [type].
  ///
  /// Use this when you have a [Type] variable and need to get the
  /// corresponding DAO dynamically.
  ///
  /// If [dbName] is provided, it resolves the provider within that specific database group.
  /// If omitted, it performs a system-wide lookup and resolves automatically
  /// if the model is registered uniquely.
  ///
  /// Throws [ProviderNotFoundException] if the [type] is not registered.
  /// Throws [AmbiguousProviderException] if the [type] is registered in multiple database groups.
  ///
  /// **Example:**
  /// ```dart
  /// Type dynamicType = UserModel;
  /// // Resolves automatically based on registry
  /// final FluentProvider<FluentStorable> provider = FluentDb.providerForType(dynamicType);
  /// ```
  static FluentProvider providerForType(Type type, {String? dbName}) => _resolveProvider(modelType: type, dbName: dbName);

  /// The primary and most type-safe way to access a Data Access Object (DAO).
  ///
  /// It retrieves the [FluentProvider] associated with the model type [T].
  /// If [dbName] is provided, it resolves the provider within that specific database group.
  /// If omitted, it performs a system-wide lookup and resolves automatically
  /// if the model is registered uniquely.
  ///
  /// Throws [ProviderNotFoundException] if the model [T] has no registered provider.
  /// Throws [AmbiguousProviderException] if the model [T] is registered in multiple database groups.
  ///
  /// **Example:**
  /// ```dart
  /// // Standard access
  /// final FluentProvider<UserModel> userDAO = FluentDb.providerByType<UserModel>();
  /// final List<UserModel>? users = await userDAO.getItems();
  ///
  /// // Context-specific access
  /// final FluentProvider<Goods> cardProvider = FluentDb.providerByType<Goods>(dbName: 'history');
  /// ```
  static FluentProvider<T> providerByType<T extends FluentStorable>({String? dbName}) => _resolveProvider(modelType: T, dbName: dbName) as FluentProvider<T>;

  /// Finds a registered [FluentProvider] by its implementation type [T].
  ///
  /// Use this when you need to access custom methods or properties defined
  /// specifically in your provider class, rather than the base [FluentProvider] interface.
  ///
  /// If [dbName] is provided, it searches only within that database group.
  /// If [dbName] is omitted, it performs a system-wide search.
  ///
  /// Throws [ProviderNotFoundException] if no provider of type [T] is found.
  /// Throws [AmbiguousProviderException] if the provider type [T] exists in multiple database groups.
  ///
  /// **Example:**
  /// ```dart
  /// // Accessing a custom method defined in UserDAO
  /// final UserDAO userDao = FluentDb.provider<UserDAO>();
  /// await userDao.syncWithServer();
  /// ```
  static T provider<T extends FluentProvider>({String? dbName}) => _resolveProvider(providerType: T, dbName: dbName) as T;

  /// Resolves the appropriate [FluentProvider] based on the provided criteria.
  ///
  /// This is the central resolution engine for multi-database architecture.
  /// It performs the following steps:
  /// 1. Validates the search criteria (model type, provider type, or table name).
  /// 2. Performs a strict lookup if [dbName] is provided.
  /// 3. Performs a system-wide "smart" lookup if [dbName] is omitted.
  /// 4. Handles collisions and missing provider cases with specific exceptions.
  ///
  /// Throws [FluentConfigurationException] if criteria are missing.
  /// Throws [ProviderNotFoundException] if the provider cannot be resolved.
  /// Throws [AmbiguousProviderException] if the model exists in multiple databases.
  static FluentProvider _resolveProvider({Type? modelType, Type? providerType, String? tableName, String? dbName}) {
    if (modelType == null && providerType == null && tableName == null) {
      final FluentConfigurationException exception = FluentConfigurationException(
        'Invalid resolution criteria: Must provide at least one search criterion '
        '(modelType, providerType, or tableName).',
        stackTrace: StackTrace.current,
      );
      FluentLog.error('Invalid resolution criteria provided', exception, exception.stackTrace, tag: 'FluentDb:resolve');
      throw exception;
    }
    final String target = modelType?.toString() ?? providerType?.toString() ?? tableName!;

    // Helper to match criteria against provider metadata.
    bool isMatch(FluentProvider p) {
      if (modelType != null) return p.modelType == modelType;
      if (providerType != null) return p.runtimeType == providerType;
      if (tableName != null) return p.tableName == tableName;
      return false;
    }

    // Strict Search: Search only within the specified database group.
    if (dbName != null) {
      final Map<Type, FluentProvider<FluentStorable>>? group = _instance._groupedRegistry[dbName];
      if (group != null) {
        for (final FluentProvider<FluentStorable> p in group.values) {
          if (isMatch(p)) return p;
        }
      }
      final ProviderNotFoundException exception = ProviderNotFoundException('$target (in group: $dbName)', stackTrace: StackTrace.current);

      FluentLog.error(
        'Provider resolution failed: target not found in specified database',
        exception,
        exception.stackTrace,
        tag: 'FluentDb:resolve',
        hint: 'Verify that the model or DAO is correctly registered within the "$dbName" group during the initialization phase.',
        context: {'target': target, 'requestedGroup': dbName},
      );
      throw exception;
    }

    // Smart Search: Scan all registered database groups.
    final Map<String, FluentProvider> matches = {};
    for (final MapEntry<String, Map<Type, FluentProvider<FluentStorable>>> entry in _instance._groupedRegistry.entries) {
      for (final FluentProvider<FluentStorable> p in entry.value.values) {
        if (isMatch(p)) {
          matches[entry.key] = p;
          break;
        }
      }
    }

    if (matches.isEmpty) {
      final ProviderNotFoundException exception = ProviderNotFoundException(target, stackTrace: StackTrace.current);

      FluentLog.warning(
        'Provider resolution failed: No match found across all registered databases',
        tag: 'FluentDb:resolve',
        hint: 'The requested entity is not registered in any database group. Check your init() setup.',
        context: {'target': target},
      );
      throw exception;
    }

    // Handle Success: Single match found (the ideal scenario).
    if (matches.length == 1) {
      final String resolvedDbName = matches.keys.first;
      FluentLog.debug('Successfully resolved "$target" to database "$resolvedDbName"', tag: 'fluentdb:resolve', context: {'target': target, 'dbName': resolvedDbName});
      return matches.values.first;
    }

    // Handle Collision: Same model found in multiple databases (Ambiguity).
    final AmbiguousProviderException exception = AmbiguousProviderException(target, matches.keys.toList(), stackTrace: StackTrace.current);

    FluentLog.error(
      'Collision detected during provider resolution',
      exception,
      exception.stackTrace,
      tag: 'FluentDb:resolve',
      hint: 'Model "$target" is registered in multiple database groups. Please specify "dbName" in your repository call or task configuration.',
      context: {'target': target, 'detectedInGroups': matches.keys.toList()},
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
  static List<({FluentProvider parentProvider, FluentDbRelation relation})> getIncomingRelationsFor(Type targetModelType, {String? dbName}) {
    final List<({FluentProvider parentProvider, FluentDbRelation relation})> incoming = [];

    final groups = dbName != null ? [_instance._groupedRegistry[dbName]].whereType<Map<Type, FluentProvider>>() : _instance._groupedRegistry.values;

    for (final Map<Type, FluentProvider> group in groups) {
      for (final FluentProvider<FluentStorable> parentProvider in group.values) {
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

  /// Saves a single [item] of type [T] into its corresponding database table.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// The [saveStrategy] parameter defines how to handle records:
  /// * [FluentSaveStrategy.upsert] (default) — Overwrites or creates the record.
  /// * [FluentSaveStrategy.insertOnly] — Adds the record only if it doesn't exist.
  /// * [FluentSaveStrategy.patch] / [FluentSaveStrategy.updateOnly] — Modifies existing data.
  ///
  /// **Example:**
  /// ```dart
  /// // Updates the user if they exist, or creates a new one
  /// await FluentDb.saveItem(User(id: 1, name: 'John Doe'), saveStrategy: FluentSaveStrategy.upsert);
  /// ```
  static Future<void> saveItem<T extends FluentStorable>(
    T item, {
    FluentSaveStrategy saveStrategy = FluentSaveStrategy.upsert,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:saveItem');
    }
    return providerByType<T>(dbName: dbName).saveItem(item, saveStrategy: saveStrategy, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Retrieves a single record of type [T].
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final User user = await FluentDb.findOne<User>(maxDepth: 2);
  /// ```
  static Future<T?> findOne<T extends FluentStorable>({int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findOne');
    }
    return providerByType<T>(dbName: dbName).findOne(maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Retrieves a list of records of type [T] with optional constraints.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> recentUsers = await FluentDb.findAll<User>(limit: 10, maxDepth: 0);
  /// ```
  static Future<List<T>> findAll<T extends FluentStorable>({int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findAll');
    }
    return providerByType<T>(dbName: dbName).findAll(limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Fetches items that have not yet expired based on their TTL configuration.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findValidItems');
    }
    return providerByType<T>(dbName: dbName).findValidItems(limit: limit, sortDirection: sortDirection, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Performs a lookup based on a specific property key and value.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final List<User> users = await FluentDb.findItemsBy<User>('admin', key: 'role');
  /// ```
  static Future<List<T>> findItemsBy<T extends FluentStorable>(
    dynamic value, {
    String? key,
    int? limit,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findItemsBy');
    }
    return providerByType<T>(dbName: dbName).findItemsBy(value, key: key, limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Retrieves a single record by its primary key identifier.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final Order order = await FluentDb.findById<Order>(101, maxDepth: 2);
  /// ```
  static Future<T?> findById<T extends FluentStorable>(dynamic id, {int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findById');
    }
    return providerByType<T>(dbName: dbName).findById(id, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Executes a custom SQL-based query with support for `WHERE` clauses,
  /// ordering, and pagination.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:find');
    }
    return providerByType<T>(
      dbName: dbName,
    ).find(where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit, offset: offset, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Retrieves a single raw record map by a specific column value.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final Map<String, dynamic>? rawUser = await FluentDb.rawGetItemBy<User>('admin@example.com', column: 'email');
  /// ```
  static Future<Map<String, dynamic>?> rawGetItemBy<T extends FluentStorable>(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:rawGetItemBy');
    }
    return providerByType<T>(dbName: dbName).rawGetItemBy(value, column: column, policy: policy, dbName: dbName);
  }

  /// Retrieves a list of raw record maps matching the specified column value.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final List<Map<String, dynamic>> activeOrders = await FluentDb.rawGetItemsBy<Order>('pending', column: 'status');
  /// ```
  static Future<List<Map<String, dynamic>>> rawGetItemsBy<T extends FluentStorable>(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:rawGetItemsBy');
    }
    return providerByType<T>(dbName: dbName).rawGetItemsBy(value, column: column, policy: policy, dbName: dbName);
  }

  /// Updates an entire record represented by [item].
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.update<User>(updatedUserInstance);
  /// ```
  static Future<int> update<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:update');
    }
    return providerByType<T>(dbName: dbName).update(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Updates a record represented by [item] along with its related entities.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateWithRelations');
    }
    return providerByType<T>(dbName: dbName).updateWithRelations(item, syncMode: syncMode, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a transactional batch update of multiple entities along with their
  /// full relational graphs.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
    Iterable<T>? items, {
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateAllWithRelations');
    }
    return _executeMixedBatch(
      items,
      (provider, typedItems) => provider.updateAllWithRelations(typedItems, syncMode: syncMode, policy: policy.withTag(tag), dbName: dbName),
      dbName: dbName,
    );
  }

  /// Updates an entity instance and returns its fully synchronized state from the database.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<T?> updateAndFetch<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateAndFetch');
    }
    return providerByType<T>(dbName: dbName).updateAndFetch(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a targeted, partial update on a single field of a record identified by ID.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateByKey<User>(1, 'last_login', DateTime.now().toString());
  /// ```
  static Future<int> updateByKey<T extends FluentStorable>(dynamic id, String updateKey, dynamic updateValue, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateByKey');
    }
    return providerByType<T>(dbName: dbName).updateByKey(id, updateKey, updateValue, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a partial update on multiple fields for a specific record.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.updateFieldsMultiple<User>(1, {'status': 'active', 'last_seen': '2026-05-25'});
  /// ```
  static Future<int> updateFieldsMultiple<T extends FluentStorable>(dynamic id, Map<String, dynamic> fields, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateFieldsMultiple');
    }
    return providerByType<T>(dbName: dbName).updateFieldsMultiple(id, fields, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> updateAll<T extends FluentStorable>(Iterable<T>? items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateAll');
    }
    return _executeMixedBatch<T>(
      items,
      (provider, typedItems) => provider.updateAll(typedItems, policy: policy.withTag(tag), dbName: dbName),
      dbName: dbName,
    );
  }

  /// Performs a transactional batch update of specific fields for a set of identified entities.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> updateMultipleFieldsByIds<T extends FluentStorable>(
    Set<dynamic> ids,
    Map<String, dynamic> fields, {
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:updateMultipleFieldsByIds');
    }
    return providerByType<T>(dbName: dbName).updateFieldsMultipleByIds(ids, fields, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Deletes a specific record instance.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.delete<User>(userInstance);
  /// ```
  static Future<int> delete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:delete');
    }
    return providerByType<T>(dbName: dbName).delete(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Deletes records matching a specific field value.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteBy<User>('inactive', key: 'status');
  /// ```
  static Future<int> deleteBy<T extends FluentStorable>(dynamic value, {Object? tag, String? key, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:delete');
    }
    return providerByType<T>(dbName: dbName).deleteBy(value, key: key, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> deleteAll<T extends FluentStorable>(Iterable<T>? items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:deleteAll');
    }
    return _executeMixedBatch<T>(
      items,
      (provider, typedItems) => provider.deleteAll(typedItems, policy: policy.withTag(tag), dbName: dbName),
      dbName: dbName,
    );
  }

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> hardDeleteAll<T extends FluentStorable>(Iterable<T>? items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:hardDeleteAll');
    }
    return _executeMixedBatch<T>(
      items,
      (provider, typedItems) => provider.hardDeleteAll(typedItems, policy: policy.withTag(tag), dbName: dbName),
      dbName: dbName,
    );
  }

  /// Deletes a batch of records identified by their primary keys.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.deleteItemsByIds<User>({1, 2, 3});
  /// ```
  static Future<int> deleteItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:deleteItemsByIds');
    }
    return providerByType<T>(dbName: dbName).deleteItemsByIds(ids, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Clears items that have exceeded their TTL (Time To Live).
  /// Typically used by maintenance routines.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearExpiredItems<Cache>();
  /// ```
  static Future<int> clearExpiredItems<T extends FluentStorable>({Object? tag, DatabaseExecutor? executor, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:clearExpiredItems');
    }
    return providerByType<T>(dbName: dbName).clearExpiredItems(executor: executor, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Removes all records from the table associated with type [T].
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.clearTable<Cache>();
  /// ```
  static Future<int> clearTable<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:clearTable');
    }
    return providerByType<T>(dbName: dbName).clearTable(policy: policy.withTag(tag), dbName: dbName);
  }

  /// Checks if a record with the given [id] exists in the table.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final bool isExisting = await FluentDb.exists<User>(101);
  /// ```
  static Future<bool> exists<T extends FluentStorable>(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:exists');
    }
    return providerByType<T>(dbName: dbName).exists(id, policy: policy, dbName: dbName);
  }

  /// Returns the count of records matching the optional [where] clause.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final int activeCount = await FluentDb.count<User>(where: 'status = ?', whereArgs: ['active']);
  /// ```
  static Future<int> count<T extends FluentStorable>({String? where, List<Object?>? whereArgs, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:count');
    }
    return providerByType<T>(dbName: dbName).count(where: where, whereArgs: whereArgs, policy: policy, dbName: dbName);
  }

  /// Executes a custom SQL statement against the database for the specified entity type [T].
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> execute<T extends FluentStorable>(String sql, {List<dynamic>? arguments, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:execute');
    }
    return providerByType<T>(dbName: dbName).execute(sql, arguments: arguments, policy: policy, dbName: dbName);
  }

  /// Restores a soft-deleted record by its unique primary key.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final int count = await FluentDb.restoreById<User>(101);
  /// ```
  static Future<int> restoreById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restoreById');
    }
    return providerByType<T>(dbName: dbName).restoreById(id, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Restores a soft-deleted record by its unique primary key and immediately
  /// retrieves the fully refreshed entity.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<T?> restoreAndFetchById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restoreAndFetchById');
    }
    return providerByType<T>(dbName: dbName).restoreAndFetchById(id, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Restores a previously soft-deleted object instance.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final int restoredCount = await FluentDb.restore<User>(userInstance);
  /// ```
  static Future<int> restore<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restore');
    }
    return providerByType<T>(dbName: dbName).restore(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Restores a soft-deleted entity instance and returns its refreshed state from the database.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<T?> restoreAndFetch<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restoreAndFetch');
    }
    return providerByType<T>(dbName: dbName).restoreAndFetch(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> restoreAll<T extends FluentStorable>(Iterable<T>? items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restoreAll');
    }
    return _executeMixedBatch<T>(
      items,
      (provider, typedItems) => provider.restoreAll(typedItems, policy: policy.withTag(tag), dbName: dbName),
      dbName: dbName,
    );
  }

  /// Performs a transactional batch restoration of multiple soft-deleted entities
  /// identified by their primary keys.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> restoreItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:restoreItemsByIds');
    }
    return providerByType<T>(dbName: dbName).restoreItemsByIds(ids, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Permanently removes an object instance from the database, bypassing any soft-delete mechanisms.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.hardDelete<User>(userInstance);
  /// ```
  static Future<int> hardDelete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:hardDelete');
    }
    return providerByType<T>(dbName: dbName).hardDelete(item, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Permanently removes a record from the database by its primary key, bypassing any soft-delete mechanisms.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// final int deletedCount = await FluentDb.hardDeleteById<User>(101);
  /// ```
  static Future<int> hardDeleteById<T extends FluentStorable>(dynamic id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:hardDeleteById');
    }
    return providerByType<T>(dbName: dbName).hardDeleteById(id, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Permanently removes records matching a specific field value, bypassing any soft-delete mechanisms.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// // Permanently delete all users with a specific status
  /// await FluentDb.hardDeleteBy<User>( 'inactive', key: 'status');
  /// ```
  static Future<int> hardDeleteBy<T extends FluentStorable>(dynamic value, {Object? tag, String? key, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:hardDeleteBy');
    }
    return providerByType<T>(dbName: dbName).hardDeleteBy(value, key: key, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Permanently removes a collection of records from the database by their primary keys.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// // Permanently delete multiple products by their IDs
  /// await FluentDb.hardDeleteItemsByIds<Product>({10, 25, 42});
  /// ```
  static Future<int> hardDeleteItemsByIds<T extends FluentStorable>(Set<dynamic> ids, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:hardDeleteItemsByIds');
    }
    return providerByType<T>(dbName: dbName).hardDeleteItemsByIds(ids, policy: policy.withTag(tag), dbName: dbName);
  }

  /// Retrieves all records of type [T] that have been marked as soft-deleted.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// // Fetch the last 20 deleted items for potential recovery
  /// final List<User> deletedUsers = await FluentDb.findDeletedItems<User>(limit: 20);
  /// ```
  static Future<List<T>> findDeletedItems<T extends FluentStorable>({int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:findDeletedItems');
    }
    return providerByType<T>(dbName: dbName).findDeletedItems(limit: limit, maxDepth: maxDepth, ignoreLazy: ignoreLazy, policy: policy, dbName: dbName);
  }

  /// Permanently deletes all soft-deleted records of type [T] that have exceeded their retention period.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// **Example:**
  /// ```dart
  /// // Run a cleanup task to permanently remove expired deleted records
  /// await FluentDb.purgeSoftDeleted<User>();
  /// ```
  static Future<int> purgeSoftDeleted<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:purgeSoftDeleted');
    }
    return providerByType<T>(dbName: dbName).purgeSoftDeleted(policy: policy.withTag(tag), dbName: dbName);
  }

  /// Permanently and immediately removes all soft-deleted records of type [T].
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
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
  static Future<int> forcePurgeSoftDeleted<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), String? dbName}) {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:forcePurgeSoftDeleted');
    }
    return providerByType<T>(dbName: dbName).forcePurgeSoftDeleted(policy: policy.withTag(tag), dbName: dbName);
  }

  /// Performs a transactional batch restoration, safely handling mixed-type collections.
  ///
  /// If [dbName] is provided, the operation is scoped to that specific database.
  /// If omitted, the system will attempt to auto-resolve the database via
  /// the model type [T].
  ///
  /// Saves a list of items of type [T] atomically.
  ///
  /// **Example Usage:**
  /// ```dart
  /// await FluentDb.saveItems([user1, user2, user3]);
  /// ```
  /// Persists a heterogeneous collection of [FluentStorable] items.
  static Future<void> saveItems<T extends FluentStorable>(
    Iterable<T>? itemsToSave, {
    FluentSaveStrategy saveStrategy = FluentSaveStrategy.upsert,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    String? dbName,
  }) async => await _executeMixedBatch<T>(itemsToSave, (provider, typedItems) async {
    if (dbName == null) {
      FluentLog.debug('Performing auto-resolved CRUD operation for $T', tag: 'FluentDb:saveItems');
    }
    await provider.saveItems(typedItems, saveStrategy: saveStrategy, policy: policy.withTag(tag), dbName: dbName);
    return 0;
  }, dbName: dbName);

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
    String? dbName,
  }) => providerByType<T>(dbName: dbName).syncWithServer(
    strategy: strategy,
    onPush: onPush,
    onPull: onPull,
    additionalWhere: additionalWhere,
    additionalWhereArgs: additionalWhereArgs,
    markAsSyncedFields: markAsSyncedFields,
    tag: tag,
    policy: policy,
    dbName: dbName,
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
    String? dbName,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => providerByType<T>(dbName: dbName).reactiveSync(fetchFromApi: fetchFromApi, options: options, localWhere: localWhere, localWhereArgs: localWhereArgs, policy: policy, dbName: dbName);

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

      provider ??= providerForType(T, dbName: task.dbName);
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
  static Future<int> _executeMixedBatch<T extends FluentStorable>(
    Iterable<T>? items,
    Future<int> Function(FluentProvider provider, List<FluentStorable> typedItems) action, {
    required String? dbName,
  }) async {
    if (items == null || items.isEmpty) return 0;

    final Map<Type, List<FluentStorable>> groupedItems = {};
    for (final T item in items) {
      groupedItems.putIfAbsent(item.runtimeType, () => []).add(item);
    }

    final List<Future<int>> tasks = groupedItems.entries.map((entry) {
      final Type targetType = entry.key;
      final List<FluentStorable> typedItems = entry.value;

      final FluentProvider provider = providerForType(targetType, dbName: dbName);

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
