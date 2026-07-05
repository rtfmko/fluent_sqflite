// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_db.dart';

/// Provides lifecycle management capabilities for the [FluentDb].
///
/// This extension encapsulates the orchestration logic required to manage the
/// database engine's operational state. It handles:
///
/// * **Initialization & Restart:** Orchestrating the setup, validation, and hot-reloading
///   of database configurations.
/// * **Connection Teardown:** Graceful shutdown of database handles and registry state resets.
/// * **Diagnostic Control:** Facilitating database maintenance operations, including
///   the purging of specific databases or total system resets for testing environments.
/// * **Dynamic Tuning:** Allowing real-time performance adjustments via hot-swapping
///   SQLite configurations without interrupting active sessions.
///
/// Use this extension to control the high-level lifecycle of the persistence
/// layer across your application's start-up, backgrounding, and testing phases.
extension FluentDbLifecycle on FluentDb {
  /// Checks if a database file by [dbName] is currently open.
  bool isDatabaseOpen(String dbName) {
    final Map<Type, FluentProvider<FluentStorable>>? group = _groupedRegistry[dbName];
    if (group == null) return false;

    return group.values.any((p) => p.db.isOpen);
  }

  /// Initializes the database registry by processing [groups] of [FluentProvider] entities.
  ///
  /// This process performs a multi-stage orchestration:
  /// 1. **De-duplication:** Ensures each database group is registered exactly once.
  /// 2. **Linkage:** Automatically resolves relational paths and bidirectional backlinks.
  /// 3. **Validation:** Checks schema integrity and performs topological sorting for dependency-safe creation.
  /// 4. **Persistence:** Initializes SQLite instances and synchronizes schema evolution.
  /// 5. **Coordination:** Spawns the [FluentEngine] for background processing.
  /// 6. **Maintenance:** Triggers an initial global purge of soft-deleted records.
  ///
  /// [isRetry] acts as a safety guard to prevent infinite loops during recovery in dev mode.
  ///
  /// ### Usage:
  /// ```dart
  /// await FluentDb.init([
  ///   FluentGroup(
  ///     dbKey: AppDatabases.cache,
  ///     providerList: [GoodsProvider(), PriceProvider()],
  ///   ),
  ///   FluentGroup(
  ///     dbKey: AppDatabases.user,
  ///     providerList: [UserProvider(), ProfileProvider()],
  ///   ),
  /// ]);
  /// ```
  Future<void> init(Iterable<FluentGroup> groups, {Duration? purgeDuration, bool isDev = false, bool isRetry = false, FluentEngineConfig engineConfig = const FluentEngineConfig()}) async {
    if (_isInitialized) return;

    final Stopwatch stopwatch = Stopwatch()..start();
    final Map<String, FluentGroup> uniqueGroupsMap = {};

    for (final FluentGroup g in groups) {
      if (g.providerList.isEmpty) continue;

      final String dbName = g.dbKey.dbName;

      if (!_isSafeDbName(g.dbKey)) {
        final FluentDatabaseNameException exception = FluentDatabaseNameException(
          'Invalid database name: "$dbName". '
          'Database names must contain only alphanumeric characters and underscores (a-z, A-Z, 0-9, _).',
          stackTrace: StackTrace.current,
        );
        FluentLog.error(
          'Configuration error: Illegal database name detected.',
          exception,
          exception.stackTrace,
          tag: 'FluentDb:init',
          hint:
              'Database names are used as file names for SQLite. '
              'To ensure cross-platform compatibility and prevent path traversal, '
              'only use letters (a-z), digits (0-9), and underscores (_). '
              'Avoid spaces, hyphens, dots, or special characters.',
          context: {'dbName': dbName},
        );
        throw exception;
      }

      if (uniqueGroupsMap.containsKey(dbName)) {
        FluentLog.warning(
          'Found duplicate FluentGroup for database "$dbName". Only the first will be used.',
          tag: 'FluentDb:init',
          hint:
              'Each database name must be unique within the initialization registry. '
              'Multiple FluentGroup instances targeting the same database name are ignored. '
              'Verify your "init" call parameters to ensure each database is defined exactly once.',
          context: {'dbName': dbName},
        );
      } else {
        uniqueGroupsMap[dbName] = g;
      }
    }

    if (uniqueGroupsMap.isEmpty) {
      FluentLog.warning(
        'No active groups with DAOs provided.',
        tag: 'FluentDb:init',
        hint:
            'The initialization registry is empty. Ensure that you are passing a non-empty iterable of FluentGroup instances to FluentDb.init(). '
            'If you intended to start with no databases, ignore this warning; otherwise, check your dependency injection or group provider setup.',
      );
      return;
    }

    FluentDb._lastConfig = uniqueGroupsMap.values.toList();
    _isDevMod = isDev;

    if (purgeDuration != null) {
      FluentDb._softDeleteRetentionPeriod = purgeDuration;
    }

    final Map<String, SQLitePerformanceConfig> performanceConfigs = {};
    final Map<String, List<String>> dbTables = {};
    final Map<String, Database> dbNameWithDb = {};
    final Map<String, Map<String, int>> dbRelationsCount = {};

    final String databasesPath = await getDatabasesPath();

    for (final FluentGroup group in uniqueGroupsMap.values) {
      final String currentDbName = group.dbKey.dbName;

      try {
        FluentLog.info('Initializing database group: $currentDbName', tag: 'FluentDb:init');

        for (final FluentProvider dao in group.providerList) {
          dao.setDbName(currentDbName);
          dao.registerSelf(_register);
        }

        final List<String> tableNames = [];
        final Map<String, int> relationsManifest = {};

        for (final FluentProvider dao in group.providerList) {
          if (dao case final FluentRelationsMixin relDao) {
            relDao.resolvedRelations.forEach((targetType, relation) {
              final Type oldType = relation.modelType;
              relation.bindType(targetType);
              if (oldType != relation.modelType) {
                FluentLog.debug('Fixed model binding', tag: 'FluentDb:init', context: {'table': dao.tableName, 'from': oldType.toString(), 'to': relation.modelType.toString()});
              }
            });
            relDao.linkRelations(group.providerList);
          }

          dao.refreshSchema();

          _verifyAndFixIntegrity(dao, currentDbName);

          tableNames.add(dao.tableName);

          relationsManifest[dao.tableName] = (dao is FluentRelationsMixin) ? dao.resolvedRelations.length : 0;
        }

        final List<FluentProvider> sortedDaos = _getSortedProviders(group.providerList);
        FluentLog.debug('Group "$currentDbName": Relations established and sorted.', tag: 'FluentDb:init');

        final String path = '$databasesPath/$currentDbName.db';
        performanceConfigs[currentDbName] = group.performanceConfig;
        dbTables[currentDbName] = tableNames;
        dbRelationsCount[currentDbName] = relationsManifest;

        final Database db = await openDatabase(
          path,
          version: 1,
          onConfigure: (db) => _applyPerformanceConfig(db, group.performanceConfig, isFullConfig: true),
          onCreate: (db, version) async {
            FluentLog.info('First run for $currentDbName. Building initial schema...', tag: 'FluentDb:init');
            for (final FluentProvider dao in sortedDaos) {
              await dao.createTable(db);
            }
          },
        );

        dbNameWithDb[currentDbName] = db;

        for (final FluentProvider dao in group.providerList) {
          dao.setDb(db);
        }

        FluentLog.info('Syncing schema and maintenance for $currentDbName', tag: 'FluentDb:init');
        await _syncSchema(db, group, sortedProviders: sortedDaos);
        await _runInitialMaintenance(group);
      } catch (e, st) {
        FluentLog.error(
          'Critical error while initializing group "$currentDbName"',
          e,
          st,
          tag: 'FluentDb:init',
          hint:
              'The initialization of database "$currentDbName" failed. '
              'Check if the database file is corrupted, if there are pending migrations, '
              'or if a schema mismatch occurred between your DAO models and the physical disk. '
              'If this is a development environment, consider deleting the database file to trigger a clean recreation.',
          context: {'isRetry': isRetry, 'dbName': currentDbName, 'path': '$databasesPath/$currentDbName.db'},
        );

        if (_isDevMod && !isRetry) {
          FluentLog.warning(
            'DevMode: Recreating database "$currentDbName" due to initialization failure.',
            tag: 'FluentDb:init',
            hint:
                'This is an automatic recovery mechanism triggered because "isDevMod" is true. '
                'The engine detected a corrupted or incompatible database state and is performing a hard reset '
                'by deleting the file. This ensures a clean schema environment for development.',
            context: {'dbName': currentDbName},
          );
          await databaseFactory.deleteDatabase('$databasesPath/$currentDbName.db');

          uniqueGroupsMap.clear();
          reset();

          return await init(groups, isDev: isDev, isRetry: true);
        } else {
          stopwatch.stop();
          rethrow;
        }
      }
    }

    FluentLog.info('Registry: Spawning FluentDb...', tag: 'FluentDb:init');

    await FluentEngine().initMultiple(configs: performanceConfigs, dbTables: dbTables, dbRelationsCount: dbRelationsCount, dbNameWithDb: dbNameWithDb, engineConfig: engineConfig);

    _isInitialized = true;
    stopwatch.stop();
    FluentLog.info('Registry: Initialization complete in ${stopwatch.elapsedMilliseconds}ms', tag: 'FluentDb:init', context: {'totalGroups': uniqueGroupsMap.length});

    unawaited(_purgeSoftDeletedGlobal());
  }

  /// Performs a topological sort of [providers] to ensure parent-child dependencies
  /// are respected during table creation and migration.
  ///
  /// Uses a Depth-First Search (DFS) algorithm to order entities such that
  /// any entity is created only after its dependencies (related tables) are
  /// initialized. Circular dependencies are detected and handled to prevent
  /// infinite recursion.
  List<FluentProvider> _getSortedProviders(Set<FluentProvider> providers) {
    final List<FluentProvider> sorted = [];
    final Set<Type> visited = {};
    final Set<Type> visiting = {};

    final Map<Type, FluentProvider> typeToProvider = {for (final FluentProvider p in providers) p.modelType: p};

    void visit(FluentProvider provider) {
      final type = provider.modelType;
      if (visited.contains(type)) return;

      if (visiting.contains(type)) {
        FluentLog.warning(
          'Circular dependency detected for table "${provider.tableName}"',
          tag: 'FluentDb:getSorted',
          hint: 'The model graph contains a cycle. Ensure that foreign key constraints are not mutually dependent.',
          context: {'table': provider.tableName},
        );
        return;
      }

      visiting.add(type);
      FluentLog.debug('Visiting provider', tag: 'FluentDb:getSorted', context: {'table': provider.tableName});

      if (provider is FluentRelationsMixin) {
        final Map<Type, FluentDbRelation> relations = provider.resolvedRelations;
        for (final Type targetType in relations.keys) {
          final targetProvider = typeToProvider[targetType];
          if (targetProvider != null) visit(targetProvider);
        }
      }

      visiting.remove(type);
      visited.add(type);
      sorted.add(provider);

      FluentLog.debug('Sorted provider appended', tag: 'FluentDb:getSorted', context: {'table': provider.tableName});
    }

    FluentLog.debug('Starting topological sort of providers', tag: 'FluentDb:getSorted', context: {'count': providers.length});
    providers.forEach(visit);
    FluentLog.info('Topological sort completed', tag: 'FluentDb:getSorted');
    return sorted;
  }

  /// Verifies the relational integrity between a source DAO and its target models.
  ///
  /// This method acts as a self-healing schema validator:
  /// 1. **PK Verification:** Ensures the target of a relationship is actually a Primary Key.
  /// 2. **Auto-Correction:** If the target isn't a PK but allows auto-correction,
  ///    it forces the property and refreshes the schema.
  /// 3. **Fault Isolation:** If correction is impossible or the model is missing,
  ///    it disables the relation to prevent runtime SQL failures.
  void _verifyAndFixIntegrity(FluentProvider dao, String dbName) {
    if (dao is! FluentRelationsMixin) return;

    final Map<Type, FluentDbRelation> relations = dao.resolvedRelations;

    relations.forEach((targetType, relation) {
      try {
        final FluentProvider<FluentStorable> targetProvider = FluentDb.providerForType(targetType, dbName: dbName);
        final FluentDbColumn targetCol = targetProvider.primaryKeyColumn;

        if (!targetCol.isPrimaryKey) {
          if (targetCol.autoCorrectAllowed) {
            targetCol.isPrimaryKey = true;
            targetProvider.refreshSchema();
            FluentLog.info('AUTO-FIX: Forced PRIMARY KEY on "${targetProvider.tableName}.${targetCol.name}"', tag: 'FluentDb:verifyAndFix');
          } else {
            relation.disable('Target column is not a PK and auto-correct is disabled');
            FluentLog.error(
              'Integrity violation: Target column is not a PK',
              FluentConstraintException('Constraint violation in ${dao.tableName}', originalError: 'SQLITE_CONSTRAINT'),
              StackTrace.current,
              tag: 'FluentDb:verifyAndFix',
              hint:
                  'The relation setup requires the referenced column to be a Primary Key. '
                  '1) Ensure the target column has @PrimaryKey annotation. '
                  '2) If you cannot change the schema, enable "autoCorrectAllowed" on the column definition to force the fix. '
                  '3) Verify if you are referencing the correct model type.',
              context: {'table': dao.tableName, 'targetTable': targetProvider.tableName, 'dbName': dbName},
            );
          }
        }
      } catch (e, s) {
        relation.disable('Target column is not a PK and auto-correct is disabled');
        FluentLog.error(
          'Broken relation in "${dao.tableName}": Model "$targetType" is not registered.',
          e,
          s,
          tag: 'FluentDb:verifyAndFix',
          hint:
              'The relation cannot be resolved because the target model "$targetType" is not found in the current registry. '
              '1) Ensure the model "$targetType" is included in your FluentGroup definition. '
              '2) Verify that the model belongs to the same database group ("$dbName"). '
              '3) Check for typos in the relation type definition.',
          context: {'table': dao.tableName, 'targetModel': targetType.toString(), 'dbName': dbName},
        );
      }
    });
  }

  /// Performs a soft-restart of the database engine by tearing down existing
  /// connections and re-initializing with the current (or updated) configuration.
  ///
  /// This is particularly useful for hot-reloading schema changes in development,
  /// switching between database modes, or applying runtime migration updates
  /// without restarting the entire application process.
  ///
  /// [updateConfig] An optional callback to modify the [FluentGroup] configuration
  /// before re-initialization (e.g., adding a new DAO or changing connection flags).
  Future<void> restart({List<FluentGroup> Function(List<FluentGroup> currentConfig)? updateConfig}) async {
    if ((FluentDb._lastConfig?.isEmpty ?? true)) {
      FluentLog.warning(
        'Restart failed: No previous configuration found.',
        tag: 'FluentDb:restart',
        hint: 'Ensure that init() has been called successfully at least once before requesting a restart.',
      );
      return;
    }
    FluentLog.info('Restarting database engine...', tag: 'db:registry', linesBefore: 2);

    await FluentEngine().shutdown();

    final List<FluentGroup> configToUse = updateConfig != null ? updateConfig(List.from(FluentDb._lastConfig ?? [])) : FluentDb._lastConfig ?? [];
    await closeAll();
    await init(configToUse, isDev: _isDevMod);
  }

  /// Hot-swaps the performance configuration for the database associated with the provided provider type.
  ///
  /// This method allows for dynamic adjustment of SQLite pragmas (such as cache size or
  /// synchronization modes) at runtime without requiring a full engine restart.
  ///
  /// Note: Only dynamic settings are applied. Structural settings that require a
  /// fresh connection are ignored in this hot-swap.
  Future<void> changeCurrentPerformanceConfig<T extends FluentProvider>(SQLitePerformanceConfig newConfig, {FluentDbKey? dbKey}) async {
    final Database db = FluentDb.provider<T>(dbName: dbKey?.dbName).db;

    FluentLog.debug('Attempting hot-swap of performance config', tag: 'FluentDb:changePerformance', context: {'provider': T.toString()});
    await _applyPerformanceConfig(db, newConfig, isFullConfig: false);

    FluentLog.info('Performance settings hot-swapped successfully', tag: 'FluentDb:changePerformance', context: {'provider': T.toString()});
  }

  /// Gracefully shuts down all active database connections and resets the registry state.
  ///
  /// [dbs] An optional set of specific databases to close. If not provided,
  /// all currently open databases in the registry will be shut down.
  /// This method performs the following steps:
  /// 1. **De-duplication:** Identifies unique open database connections from all providers.
  /// 2. **Teardown:** Safely closes each connection to prevent file corruption or handle leaks.
  /// 3. **Reset:** Clears all registered providers and sets the initialization flag to false.
  Future<void> closeAll({Set<Database>? dbs}) async {
    FluentLog.debug('Closing all database connections...', tag: 'FluentDb:close');

    final Set<Database> uniqueDbs = dbs ?? _groupedRegistry.values.expand((group) => group.values).map((p) => p.db).where((db) => db.isOpen).toSet();

    for (final Database db in uniqueDbs) {
      try {
        final String dbPath = db.path;
        await db.close();
        FluentLog.debug('Database closed successfully', tag: 'FluentDb:close', context: {'path': dbPath});
      } catch (e, st) {
        FluentLog.error('Error closing database', e, st, tag: 'FluentDb:close', hint: 'The database connection may have already been closed or became unresponsive during teardown.');
      }
    }
    _groupedRegistry.clear();
    _isInitialized = false;
    await FluentEngine().shutdown();
    FluentLog.info('Registry reset: All connections closed and providers cleared.', tag: 'FluentDb:close');
  }

  /// Safely shuts down all database operations, closes connections, and permanently
  /// deletes all database files from the file system.
  ///
  /// This method is intended for use cases like user logout or complete app reset.
  /// It ensures that no file locks remain before attempting deletion.
  Future<void> destroyAllDatabases() async {
    FluentLog.warning('Initiating total data wipe. All databases will be destroyed.', tag: 'FluentDb:destroyAll');

    await FluentEngine().pauseQueue();

    for (final Map<Type, FluentProvider<FluentStorable>> group in _groupedRegistry.values) {
      for (final FluentProvider<FluentStorable> provider in group.values) {
        FluentEngine().broadcastSystemAction(FluentDbAction.wipeAll, modelType: provider.runtimeType);
      }
    }

    // Added delay for UI to render new states
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final Set<Database> uniqueDbs = _groupedRegistry.values.expand((group) => group.values).map((p) => p.db).where((db) => db.isOpen).toSet();
    final List<String> pathsToDelete = uniqueDbs.map((db) => db.path).toList();

    await closeAll(dbs: uniqueDbs);

    for (final String path in pathsToDelete) {
      try {
        FluentLog.debug('Deleting physical database file', tag: 'FluentDb:destroyAll', context: {'path': path});
        await databaseFactory.deleteDatabase(path);
      } catch (e, st) {
        FluentLog.error('Failed to delete database file', e, st, tag: 'FluentDb:destroyAll', context: {'path': path});
      }
    }

    await FluentEngine().destroy();

    FluentLog.info('Total data wipe completed successfully. Engine is reset.', tag: 'FluentDb:destroyAll');
  }

  /// Performs a complete wipe of all data, notifies the UI to clear its state,
  /// and then immediately re-initializes the database engine using the last known configuration.
  ///
  /// This is the recommended method for handling "User Logout" scenarios, ensuring
  /// that no previous user's data remains in memory or on disk, while leaving
  /// the app ready for a new user to log in.
  Future<void> destroyAllDatabasesAndRestart({List<FluentGroup> Function(List<FluentGroup> currentConfig)? updateConfig}) async {
    FluentLog.info('Executing Wipe & Restart sequence...', tag: 'FluentDb:wipeAndRestart');

    await destroyAllDatabases();

    FluentLog.debug('Re-initializing engine with clean state', tag: 'FluentDb:wipeAndRestart');
    await restart(updateConfig: updateConfig);

    FluentLog.info('Wipe & Restart sequence completed successfully.', tag: 'FluentDb:wipeAndRestart');
  }

  /// Permanently removes a specific database file from the file system.
  ///
  /// This method locates the database by name within the application's
  /// default database directory and performs an irreversible deletion.
  ///
  /// [dbName] The identifier of the database to be dropped.
  @visibleForTesting
  Future<void> dropDatabase(FluentDbKey dbKey) async {
    FluentLog.warning(
      'Dropping database: "${dbKey.dbName}". All data will be permanently deleted.',
      tag: 'FluentDb:drop',
      hint: 'This operation is destructive and cannot be undone.',
      context: {'dbName': dbKey.dbName},
    );

    try {
      final String databasesPath = await getDatabasesPath();
      final String path = '$databasesPath/${dbKey.dbName}';

      await FluentEngine().hardReset();

      FluentLog.debug('Deleting database file', tag: 'FluentDb:drop', context: {'path': path});
      await databaseFactory.deleteDatabase(path);

      FluentLog.info('Database file successfully removed', tag: 'FluentDb:drop', context: {'dbName': dbKey.dbName});
    } catch (e, st) {
      FluentLog.error(
        'Failed to drop database: "${dbKey.dbName}"',
        e,
        st,
        tag: 'FluentDb:drop',
        hint: 'Verify that the database file is not currently locked by an active connection or operating system process.',
      );
    }
  }

  /// Wipes all registered databases from the file system and resets the background worker coordinator.
  ///
  /// This method is intended for test environments and emergency recovery. It iterates
  /// through all registered providers, deletes their corresponding database files,
  /// and performs a hard reset on the coordinator to clear stale tasks and connection states.
  @visibleForTesting
  Future<void> dropAll() async {
    FluentLog.warning('Executing hard reset: Dropping all databases.', tag: 'FluentDb:dropAll', hint: 'This will irreversibly delete all local data. Ensure this is intentional.');
    await FluentEngine().hardReset();

    final Set<String> pathsToDelete = _groupedRegistry.values.expand((group) => group.values).map((p) => p.db.path).toSet();

    for (final String path in pathsToDelete) {
      try {
        FluentLog.debug('Deleting database file', tag: 'FluentDb:dropAll', context: {'path': path});
        await databaseFactory.deleteDatabase(path);
      } catch (e, st) {
        FluentLog.error('Failed to drop database file for $path', e, st, tag: 'FluentDb:dropAll');
      }
    }
    FluentLog.info('Resetting FluentDb...', tag: 'FluentDb:dropAll');
    await FluentEngine().hardReset();

    FluentLog.info('DropAll procedure completed successfully.', tag: 'FluentDb:dropAll');
  }

  /// Configures SQLite runtime parameters to optimize I/O, concurrency, and data integrity.
  ///
  /// [db] The database instance to configure.
  /// [cfg] The performance settings defining cache size, journaling, and synchronization.
  /// [isFullConfig] If true, applies structural settings (e.g., `journal_mode`, `foreign_keys`)
  /// that require a fresh connection or re-opening of the database.
  Future<void> _applyPerformanceConfig(Database db, SQLitePerformanceConfig cfg, {bool isFullConfig = false}) async {
    FluentLog.debug('Applying SQLite performance pragmas', tag: 'FluentDb:cfg', context: {'synchronous': cfg.synchronous.value, 'cacheSize': cfg.cacheSize.rawValue, 'isFullConfig': isFullConfig});

    await db.execute('PRAGMA synchronous = ${cfg.synchronous.value};');
    await db.execute('PRAGMA cache_size = ${cfg.cacheSize.rawValue};');

    if (cfg.tempStoreInMemory) {
      await db.execute('PRAGMA temp_store = MEMORY;');
    }

    if (isFullConfig) {
      await db.execute('PRAGMA foreign_keys = ${cfg.enableForeignKeys ? "ON" : "OFF"};');
      await db.rawQuery('PRAGMA journal_mode = ${cfg.journalMode.value};');

      FluentLog.debug('Applied structural PRAGMAs (FKs and Journal Mode)', tag: 'FluentDb:cfg');
    }
  }

  /// Validates that the provided database name is safe for file system operations.
  ///
  /// Database names must be restricted to alphanumeric characters and underscores
  /// to prevent:
  /// * Path traversal vulnerabilities (e.g., using '/' or '..').
  /// * Conflicts with reserved file system characters across different platforms (Android/iOS).
  /// * Encoding issues in database file paths.
  ///
  /// **Constraints:**
  /// * Allowed: `a-z`, `A-Z`, `0-9`, and `_`.
  /// * Disallowed: Spaces, hyphens, dots, path separators, or any special characters.
  bool _isSafeDbName(FluentDbKey dbKey) {
    final RegExp safeNameRegex = RegExp(r'^[a-zA-Z0-9_]+$');
    return safeNameRegex.hasMatch(dbKey.dbName);
  }
}
