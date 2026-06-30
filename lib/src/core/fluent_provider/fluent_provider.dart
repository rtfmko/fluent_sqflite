// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../exceptions/exceptions.dart';
import '../../interfaces/interfaces.dart';
import '../../models/models.dart';
import '../../relations/relations.dart';
import '../../soft_delete/soft_delete.dart';
import '../../utils/utils.dart';
import '../core.dart';
import '../fluent_sqlite_internal.dart';
import '../utils/utils.dart';

part 'parts/crud/executors/fluent_execute_delete.dart';

part 'parts/crud/executors/fluent_execute_find.dart';

part 'parts/crud/executors/fluent_execute_maintenance.dart';

part 'parts/crud/executors/fluent_execute_query.dart';

part 'parts/crud/executors/fluent_execute_raw.dart';

part 'parts/crud/executors/fluent_execute_restore.dart';

part 'parts/crud/executors/fluent_execute_save.dart';

part 'parts/crud/executors/fluent_execute_update.dart';

part 'parts/crud/fluent_delete.dart';

part 'parts/crud/fluent_find.dart';

part 'parts/crud/fluent_maintenance.dart';

part 'parts/crud/fluent_query.dart';

part 'parts/crud/fluent_raw.dart';

part 'parts/crud/fluent_restore.dart';

part 'parts/crud/fluent_save.dart';

part 'parts/crud/fluent_update.dart';

part 'parts/fluent_crud_helper.dart';

part 'parts/fluent_mapper.dart';

part 'parts/fluent_provider_sync.dart';

part 'parts/fluent_relation_loader.dart';

part 'parts/fluent_relations.dart';

part 'parts/fluent_schema.dart';

/// The foundational abstract base class for all database provider implementations.
///
/// [FluentProvider] acts as the primary Data Access Object (DAO) and ORM bridge
/// within the application. It orchestrates the lifecycle of domain entities
/// ([T]) by providing a standardized interface for CRUD operations,
/// relational mapping, and transactional integrity.
///
/// ### Architectural Responsibilities
///
/// * **Entity Lifecycle Management:** Manages the full pipeline from raw SQL
///   execution to fully hydrated, type-safe Dart objects.
/// * **Schema Reconciliation:** Maintains an internal state manifest (`_isSchemaInitialized`)
///   to map Dart class structures to SQLite schema definitions automatically.
/// * **Relational Orchestration:** Handles foreign key resolution, lazy-loading
///   of nested associations, and relational graph stitching via [FluentRelationsMixin].
/// * **Transactional Atomicity:** Provides a flexible executor pattern, allowing
///   operations to be transparently wrapped in multi-provider transactions via
///   `_transactionExecutor`.
/// * **Serialization Layer:** Bridges the gap between SQLite's primitive type
///   system and Dart’s rich object model, employing metadata-driven type
///   resurrection to ensure data consistency.
///
/// ### Implementation Requirements
/// Concrete subclasses must define the model's structure via `modelSample` and
/// typically rely on the [FluentDb] for lifecycle management and
/// dependency injection of the [Database] instance.
///
/// See also:
/// * [FluentStorable], for the serialization requirements of the managed entity.
/// * [FluentDb], for managing provider registration and cross-provider linking.
abstract class FluentProvider<T extends FluentStorable> {
  /// The global configuration profile for this table.
  FluentTableConfig get tableConfig => const FluentTableConfig();

  /// The defined execution policy.
  ExecutionPolicy get policy => const ExecutionPolicy();

  /// The unique identifier for the database instance this provider belongs to.
  String? _dbName;

  /// The underlying SQLite [Database] connection.
  Database? _db;

  /// A sample instance of the model [T], used for runtime type reflection and schema mapping.
  T get modelSample;

  /// The [Type] of the model entity managed by this provider.
  Type get modelType => modelSample.runtimeType;

  /// The default foreign key naming convention used for relational lookups.
  ///
  /// Derives the key by sanitizing the class name (removing 'Model'/'Provider' suffixes)
  /// and converting it to snake_case followed by '_id'.
  late final String defaultForeignKey = "${FluentUtils.toSnakeCase(tableName.replaceAll('Model', '').replaceAll('Provider', ''))}_id";

  /// The physical table name in the database, derived from the class name of [T].
  String get tableName => FluentUtils.toSnakeCase(T.toString());

  /// The active transaction executor, if currently inside a transaction scope.
  DatabaseExecutor? _transactionExecutor;

  /// The primary [DatabaseExecutor] used for operations.
  ///
  /// Returns the current [_transactionExecutor] if active, otherwise falls back
  /// to the persistent [_db] connection. Throws if neither is initialized.
  DatabaseExecutor get executor => _transactionExecutor ?? _db ?? (throw FluentNotInitializedException(tableName));

  /// Tracks whether the provider has performed the initial schema discovery.
  bool _isSchemaInitialized = false;

  /// Full structural definition of the table (columns, types, constraints).
  List<FluentDbColumn>? _cachedFullSchema;

  /// A lookup set for quick validation of existing table columns.
  Set<String>? _cachedTableColumns;

  /// A lookup set for relational keys that link to foreign entities.
  Set<String>? _cachedRelationKeys;

  /// The primary identity column for this table.
  FluentDbColumn? _cachedPrimaryKey;

  /// Optimization flag indicating if the model has associated relational dependencies.
  bool _hasRelations = false;

  /// The mixin providing configuration for child relationships.
  FluentRelationsMixin<T>? _relationsMixin;

  /// A localized cache to map relational types to their respective foreign key
  /// column names, minimizing redundant lookup logic.
  final Map<Type, String?> _remoteKeyCache = <Type, String?>{};

  /// The set of all physical database columns defined for this table.
  Set<String> get tableColumns {
    if (!_isSchemaInitialized) getFullSchema;
    return _cachedTableColumns!;
  }

  /// The set of keys representing relational associations (JOINs/Foreign Keys).
  Set<String> get relationKeys {
    if (!_isSchemaInitialized) getFullSchema;
    return _cachedRelationKeys!;
  }

  /// The definitive primary key column definition for this table.
  ///
  /// Throws a [MissingPrimaryKeyException] if the schema was initialized
  /// without defining a valid primary key.
  FluentDbColumn get primaryKeyColumn {
    if (!_isSchemaInitialized) getFullSchema;
    if (_cachedPrimaryKey == null) {
      final FluentSchemaException exception = FluentSchemaException(
        modelName: tableName,
        details: 'Primary key is missing. Every table must define a primary key column.',
        stackTrace: StackTrace.current,
      );
      FluentLog.error(exception.message, exception, exception.stackTrace, tag: '$runtimeType:init');
      throw exception;
    }
    return _cachedPrimaryKey!;
  }

  /// Returns true if this provider supports relational object-graph mapping.
  bool get hasRelations {
    if (!_isSchemaInitialized) getFullSchema;
    return _hasRelations;
  }

  /// Accessor for the relational mixin providing configuration for child associations.
  FluentRelationsMixin<T>? get relationsMixin {
    if (!_isSchemaInitialized) getFullSchema;
    return _relationsMixin;
  }

  /// Injects a specific [DatabaseExecutor] (e.g., [Transaction] or [Batch]) to be
  /// used for all subsequent database operations performed by this provider.
  ///
  /// This mechanism facilitates transactional atomicity, allowing multiple
  /// operations across different providers to be wrapped in a single ACID-compliant
  /// transaction block.
  ///
  /// [txn] The active transaction executor to delegate operations to.
  @internal
  void setTransactionExecutor(DatabaseExecutor txn) {
    _transactionExecutor = txn;
  }

  /// Clears the active [DatabaseExecutor], reverting the provider back to the
  /// default database connection.
  ///
  /// This should be called immediately upon the completion of a transaction block
  /// to ensure that subsequent standard operations do not accidentally execute
  /// within the scope of a closed or stale transaction.
  @internal
  void restoreOriginalExecutor() {
    _transactionExecutor = null;
  }

  /// Resolves the foreign key column name on a [childProvider] that references
  /// this parent table.
  ///
  /// This resolution strategy prioritizes in order:
  /// 1. Cached result: Returns previously resolved keys to minimize reflection/calculation overhead.
  /// 2. Explicit configuration: Checks [FluentRelationsMixin] for a manually defined [FluentDbRelation.remoteKey].
  /// 3. Heuristic inference: If no explicit key is defined, it guesses based on the
  ///    naming convention `[parent_table]_[parent_pk]` (snake_case).
  ///
  /// Returns the column name as a [String] if a valid reference exists, otherwise `null`.
  @internal
  String? resolveRemoteKey(FluentProvider childProvider) {
    final Type childType = childProvider.runtimeType;

    if (_remoteKeyCache.containsKey(childType)) {
      return _remoteKeyCache[childType];
    }

    if (_hasRelations && _relationsMixin != null) {
      final FluentDbRelation<FluentStorable, FluentStorable>? rel = _relationsMixin!.resolvedRelations[childProvider.modelType];
      if (rel?.remoteKey != null) {
        final String explicitKey = (rel as FluentDbRelation).remoteKey!;
        _remoteKeyCache[childType] = explicitKey;
        FluentLog.debug('Resolved explicit remote key', tag: '$tableName:relations', context: {'child': childProvider.tableName, 'key': explicitKey});
        return explicitKey;
      }
    }

    final String parentPk = _cachedPrimaryKey?.name ?? 'id';
    final String cleanTableName = tableName.endsWith('Model') ? tableName.substring(0, tableName.length - 5) : tableName;
    final String inferredFkName = "${FluentUtils.toSnakeCase(cleanTableName)}_$parentPk";

    final Set<String> childColumns = childProvider.tableColumns;
    String? result;

    if (childColumns.contains(inferredFkName)) {
      result = inferredFkName;
    } else if (childColumns.contains(parentPk)) {
      final String childPk = childProvider._cachedPrimaryKey?.name ?? 'id';
      if (parentPk != childPk) {
        result = parentPk;
      }
    }

    if (result != null) {
      FluentLog.debug('Inferred remote key via heuristic', tag: '$tableName:relations', context: {'child': childProvider.tableName, 'inferredKey': result});
    } else {
      FluentLog.warning('Could not resolve remote key for relationship', tag: '$tableName:relations', context: {'parent': tableName, 'child': childProvider.tableName});
    }

    _remoteKeyCache[childType] = result;
    return result;
  }

  /// Safely coerces an iterable into a strongly-typed list of [T].
  ///
  /// This utility is used primarily during relational hydration to ensure that
  /// deserialized child objects strictly adhere to the expected generic type [T].
  List<T> _createTypedList(Iterable<dynamic> elements) => elements.cast<T>().toList();

  /// Returns the underlying [Database] instance.
  ///
  /// Throws a [FluentNotInitializedException] if the provider has not been
  /// assigned a database instance via [setDb].
  Database get db {
    if (_db == null) {
      final String msg =
          'Database not initialized for $runtimeType. '
          'HINT: Ensure you have called setDb(database) or registered this provider '
          'in the FluentDb before performing any CRUD operations.';

      FluentLog.error(msg, FluentNotInitializedException(msg, StackTrace.current), StackTrace.current, tag: '$runtimeType:init');
      throw FluentNotInitializedException(msg, StackTrace.current);
    }
    return _db!;
  }

  /// Returns the assigned database name/identifier.
  ///
  /// Throws a [FluentNotInitializedException] if the provider configuration
  /// is incomplete.
  String get dbName {
    if (_dbName == null) {
      final String msg = 'Database name not initialized for $runtimeType. ';

      FluentLog.error(
        msg,
        FluentNotInitializedException(msg, StackTrace.current),
        hint: 'The provider was instantiated but not fully configured. Verify that initialization (e.g., via FluentDb) was completed successfully.',
        StackTrace.current,
        tag: '$runtimeType:init',
      );
      throw FluentNotInitializedException(msg, StackTrace.current);
    }
    return _dbName!;
  }

  /// Links model relationships by resolving foreign keys, pivot tables, and
  /// cardinalities across the global set of [FluentProvider]s.
  ///
  /// This method performs "Auto-Discovery" of database relationships:
  /// 1. **Table Resolution:** Identifies target tables from provider instances.
  /// 2. **Constraint Inference:** Uses naming conventions (e.g., `model_id`) to
  ///    assign keys if not explicitly defined.
  /// 3. **Backlink Propagation:** Automatically injects inverse relationships
  ///    (Many-to-One) into target providers to ensure two-way data integrity.
  @internal
  void linkRelations(Iterable<FluentProvider> allProviders) {}

  /// Initializes a new instance of the provider.
  ///
  /// [mockDb] Optional database injection used for unit testing or
  /// transactional overrides, allowing for isolated data operations.
  FluentProvider({Database? mockDb}) : _db = mockDb;

  /// Performs a high-speed deserialization of a cached JSON map into the
  /// domain model [T].
  ///
  /// Unlike standard hydration, this method is optimized for retrieving
  /// pre-serialized objects from cache (e.g., local storage or memory)
  /// bypassing the full relational SQL-assembly pipeline.
  ///
  /// [json] The cached map representation of the entity.
  /// Returns a fully hydrated instance of [T].
  @protected
  T fromCacheJson(Map<String, dynamic> json);

  /// Assembles a raw SQL record into a fully hydrated domain model [T].
  ///
  /// This assembly pipeline performs three critical phases of object construction:
  /// * Type Restoration: Reconstructs complex types (e.g., `bool` from `int`) by
  ///   consulting the system metadata column.
  /// * Relational Stitching: Invokes [_castReadyRelations] to resolve and
  ///   instantiate nested model dependencies.
  /// * Model Instantiation: Finalizes the conversion into the domain model [T]
  ///   via [FluentStorable.fromJsonWithExpiry].
  ///
  /// [enriched] The raw map result, potentially populated with relational child data.
  /// Returns a fully hydrated model [T].
  T _assembleModel(Map<String, dynamic> enriched) {
    final String metaColName = FluentDbColumn.systemMetadata().name;
    final dynamic rawMeta = enriched[metaColName];

    Map<String, dynamic> workingMap = enriched;

    // Stage 1: Restore dynamic types using stored metadata
    if (rawMeta is String && rawMeta.isNotEmpty) {
      try {
        final dynamic metaMap = jsonDecode(rawMeta);
        if (metaMap is Map<String, dynamic> && metaMap.isNotEmpty) {
          for (final MapEntry<String, dynamic> entry in metaMap.entries) {
            final String key = entry.key;

            if (entry.value == 'bool' && enriched.containsKey(key)) {
              final dynamic val = enriched[key];
              if (val is int) {
                if (identical(workingMap, enriched)) {
                  workingMap = Map<String, dynamic>.from(enriched);
                }
                workingMap[key] = val == 1;
              }
            }
          }
        }
      } catch (e, s) {
        FluentLog.error('Failed to restore dynamic types from metadata', e, s, tag: '$tableName:assembly');
      }
    }

    // Stage 2: Relational casting and final model creation
    workingMap = _castReadyRelations(workingMap);

    final T model = FluentStorable.fromJsonWithExpiry(workingMap, (json) => fromCacheJson(json));

    // Stage 3: Flag unloaded relations for lazy-load tracking
    if (workingMap.containsKey('_unloaded_relations')) {
      final keys = List<String>.from(workingMap['_unloaded_relations'] as Iterable);
      model.setUnloaded(keys);
      FluentLog.debug('Model assembled with lazy-loaded relations', tag: '$tableName:assembly', context: {'unloadedCount': keys.length});
    }

    return model;
  }

  /// Routes a [FluentTask] to its corresponding implementation method based on the [FluentDbAction].
  ///
  /// This method acts as the central traffic controller for the database engine.
  /// It utilizes Dart's exhaustive `switch` expression to guarantee that every
  /// defined [FluentDbAction] is mapped to a specific execution handler.
  @internal
  Future<dynamic> internalExecute(FluentTask task) async {
    FluentLog.debug('Routing task execution', tag: '$tableName:execute', context: {'action': task.action.toString(), 'task': task.toString()});

    return switch (task.action) {
      FluentDbAction.find => _executeFindTaskOnMain(task),
      FluentDbAction.findAll => _executeFindAllTaskOnMain(task),
      FluentDbAction.findValidItems => _executeFindValidItemsTaskOnMain(task),
      FluentDbAction.findItemsBy => _executeFindItemsByTaskOnMain(task),
      FluentDbAction.findById => _executeFindByIdTaskOnMain(task),
      FluentDbAction.save => _executeSaveTaskOnMain(task),
      FluentDbAction.update => _executeUpdateTaskOnMain(task),
      FluentDbAction.updateSingleField => _executeUpdateByKeyTaskOnMain(task),
      FluentDbAction.updateMultipleFields => _executeUpdateFieldsMultipleTaskOnMain(task),
      FluentDbAction.updateWithRelations => _executeUpdateWithRelationsTaskOnMain(task),
      FluentDbAction.updateAllWithRelations => _executeUpdateAllWithRelationsTaskOnMain(task),
      FluentDbAction.updateAll => _executeUpdateAllTaskOnMain(task),
      FluentDbAction.updateMultipleFieldsByIds => _executeUpdateMultipleFieldsByIdsTaskOnMain(task),
      FluentDbAction.clearExpired => _executeClearExpiredItemsTaskOnMain(task),
      FluentDbAction.clearTable => _executeClearTableTaskOnMain(task),
      FluentDbAction.delete => _executeDeleteTaskOnMain(task),
      FluentDbAction.deleteBy => _executeDeleteByTaskOnMain(task),
      FluentDbAction.deleteItemsByIds => _executeDeleteItemsByIdsTaskOnMain(task),
      FluentDbAction.deleteWhere => _executeDeleteWhereTaskOnMain(task),
      FluentDbAction.hardDeleteWhere => _executeDeleteWhereTaskOnMain(task),
      FluentDbAction.exists => _executeExistsTaskOnMain(task),
      FluentDbAction.count => _executeCountTaskOnMain(task),
      FluentDbAction.rawGetItem => _executeRawGetItemByTaskOnMain(task),
      FluentDbAction.rawGetItems => _executeRawGetItemsByTaskOnMain(task),
      FluentDbAction.execute => _executeRawSqlTaskOnMain(task),
      FluentDbAction.findDeletedItems => _executeFindTaskOnMain(task),
      FluentDbAction.restore => _executeUpdateByKeyTaskOnMain(task),
      FluentDbAction.restoreItemsByIds => _executeRestoreItemsByIdsTaskOnMain(task),
      FluentDbAction.hardDelete => _executeDeleteTaskOnMain(task),
      FluentDbAction.hardDeleteBy => _executeDeleteByTaskOnMain(task),
      FluentDbAction.hardDeleteItemsByIds => _executeDeleteItemsByIdsTaskOnMain(task),
      FluentDbAction.purgeSoftDeleted => _executePurgeSoftDeletedTaskOnMain(task),
      FluentDbAction.forcePurgeSoftDeleted => _executeForcePurgeSoftDeletedTaskOnMain(task),
      _ => () {
        FluentLog.error(
          'Unsupported task action attempted',
          UnimplementedError('Action ${task.action} not supported in Main Thread'),
          StackTrace.current,
          tag: '$tableName:execute',
          context: {'action': task.action.toString()},
        );
        throw UnimplementedError('Action ${task.action} not supported in Main Thread');
      }(),
    };
  }

  /// Injects the underlying SQLite [Database] instance into this provider.
  ///
  /// Used during the initialization phase to establish the connection
  /// before the provider begins processing any CRUD tasks.
  @internal
  void setDb(Database db) {
    _db = db;
    FluentLog.debug('Database instance assigned', tag: '$runtimeType:init');
  }

  /// Sets the database name identifier, used for multi-database configurations.
  @internal
  void setDbName(String dbName) {
    _dbName = dbName;
    FluentLog.debug('Database name set to "$dbName"', tag: '$runtimeType:init', context: {'hashCode': hashCode, 'modelType': modelType});
  }

  /// Self-registers this provider instance with the central system registry.
  ///
  /// This allows the [FluentDb] to discover this provider dynamically
  /// without requiring manual instantiation throughout the application.
  ///
  /// [registerFn] The callback provided by the registry to handle
  /// type-safe registration of the [FluentProvider].
  @internal
  void registerSelf(void Function<M extends FluentStorable>(FluentProvider<M>) registerFn) {
    FluentLog.debug('Registering provider instance', tag: '$runtimeType:init');
    registerFn<T>(this);
  }

  /// Overrides the table name for testing purposes.
  ///
  /// This method is marked `@visibleForTesting` to expose the table name
  /// property to unit and integration test suites, allowing for isolated
  /// schema testing or the use of temporary "shadow" tables during test execution.
  ///
  /// NOTE: This will only update the value if it has been previously initialized.
  @visibleForTesting
  void setTableName(String dbName) {
    if (_dbName != null) {
      _dbName = dbName;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FluentProvider && runtimeType == other.runtimeType && _dbName == other._dbName && _db == other._db && tableName == other.tableName;

  @override
  int get hashCode => Object.hash(_dbName, _db, tableName);
}
