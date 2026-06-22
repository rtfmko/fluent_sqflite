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
  bool isDatabaseOpen(String dbName) => _providers.values.any((p) => p.db.path.endsWith(dbName) && p.db.isOpen);

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
  Future<void> init(Iterable<FluentGroup> groups, {Duration? purgeDuration, bool isDev = false, bool isRetry = false}) async {
    if (_isInitialized) return;

    final Map<String, FluentGroup> uniqueGroupsMap = {};
    for (final FluentGroup g in groups) {
      if (g.daos.isEmpty) continue;
      if (uniqueGroupsMap.containsKey(g.dbName)) {
        FluentLog.warning(
          'Found duplicate FluentGroup for database "${g.dbName}".',
          tag: 'FluentDb:init',
          hint:
              'You are trying to register two different FluentGroup objects with the same dbName. '
              'Only the first one will be used. Consider merging all DAOs into a single FluentGroup for this database.',
        );
      } else {
        uniqueGroupsMap[g.dbName] = g;
      }
    }

    final List<FluentGroup> activeGroups = uniqueGroupsMap.values.toList();
    if (activeGroups.isEmpty) {
      FluentLog.warning('No active groups with DAOs provided.', tag: 'FluentDb:init');
      return;
    }

    FluentDb._lastConfig = activeGroups;
    _isDevMod = isDev;

    if (purgeDuration != null) {
      FluentDb._softDeleteRetentionPeriod = purgeDuration;
    }

    final Map<String, String> dbPaths = {};
    final Map<String, SQLitePerformanceConfig> performanceConfigs = {};
    final Map<String, List<String>> dbTables = {};
    final Map<String, Database> dbNameWithDb = {};
    final Map<String, Map<String, int>> dbRelationsCount = {};

    final String databasesPath = await getDatabasesPath();

    for (final FluentGroup group in activeGroups) {
      try {
        FluentLog.info('Initializing database group: ${group.dbName}', tag: 'FluentDb:init');

        // Registration & Relational Linkage
        for (final FluentProvider dao in group.daos) {
          dao.registerSelf(_register);
        }

        for (final FluentProvider dao in group.daos) {
          if (dao case final FluentRelationsMixin relDao) {
            FluentLog.debug('Linking relations for ${dao.tableName}', tag: 'FluentDb:init');

            relDao.resolvedRelations.forEach((targetType, relation) {
              final Type oldType = relation.modelType;
              relation.bindType(targetType);
              if (oldType != relation.modelType) {
                FluentLog.debug('Fixed model binding', tag: 'FluentDb:init', context: {'table': dao.tableName, 'from': oldType.toString(), 'to': relation.modelType.toString()});
              }
            });
            relDao.linkRelations(group.daos);
          }
        }

        final List<String> tableNames = [];
        final Map<String, int> relationsManifest = {};

        for (final FluentProvider dao in group.daos) {
          dao.refreshSchema();
          _verifyAndFixIntegrity(dao);

          tableNames.add(dao.tableName);

          if (dao case final FluentRelationsMixin relDao) {
            FluentLog.debug('Provider finalized', tag: 'FluentDb:init', context: {'table': dao.tableName, 'incomingRelations': relDao.incomingRelations.length});
            relationsManifest[dao.tableName] = relDao.resolvedRelations.length;
          } else {
            relationsManifest[dao.tableName] = 0;
          }
        }

        final List<FluentProvider> sortedDaos = _getSortedProviders(group.daos);
        FluentLog.debug('Group "${group.dbName}": Relations established and sorted.', tag: 'FluentDb:init');

        final String path = '$databasesPath/${group.dbName}';
        dbPaths[group.dbName] = path;
        performanceConfigs[group.dbName] = group.performanceConfig;
        dbTables[group.dbName] = tableNames;
        dbRelationsCount[group.dbName] = relationsManifest;

        FluentLog.debug('Opening database: ${group.dbName}', tag: 'FluentDb:init', context: {'path': path});

        final Database db = await openDatabase(
          path,
          version: 1,
          onConfigure: (db) => _applyPerformanceConfig(db, group.performanceConfig, isFullConfig: true),
          onCreate: (db, version) async {
            FluentLog.info('First run for ${group.dbName}. Building initial schema...', tag: 'FluentDb:init');
            for (final FluentProvider dao in sortedDaos) {
              await dao.createTable(db);
            }
          },
        );

        dbNameWithDb[group.dbName] = db;

        for (final FluentProvider dao in group.daos) {
          dao.setDb(db);
          dao.setDbName(group.dbName);
        }

        FluentLog.info('Syncing schema and running maintenance for ${group.dbName}', tag: 'FluentDb:init');
        await _syncSchema(db, group, sortedProviders: sortedDaos);
        await _runInitialMaintenance(group);
      } catch (e, st) {
        FluentLog.error(
          'Critical error while initializing group "${group.dbName}"',
          e,
          st,
          tag: 'FluentDb:init',
          hint: 'Check the database schema definitions or migration scripts for potential syntax errors or constraint violations.',
          context: {'dbName': group.dbName, 'isRetry': isRetry},
        );

        if (_isDevMod && !isRetry) {
          FluentLog.warning(
            'DevMode: Recreating database "${group.dbName}"...',
            tag: 'FluentDb:init',
            hint: 'The initialization failure triggered an automatic wipe of the local database file to restore schema integrity.',
          );
          await databaseFactory.deleteDatabase('$databasesPath/${group.dbName}');
          reset();
          return await init(groups, isDev: isDev, isRetry: true);
        } else {
          rethrow;
        }
      }
    }

    final Map<String, List<Map<String, dynamic>>> globalRelationMap = {};

    for (final FluentRelationsMixin relDao in _providers.values.whereType<FluentRelationsMixin>()) {
      final Map<Type, FluentDbRelation> syncRels = relDao.resolvedRelations;
      if (syncRels.isEmpty) continue;

      final List<Map<String, dynamic>> tableRelationsList = [];

      for (final entry in syncRels.entries) {
        final childProvider = _providers[entry.key];
        if (childProvider == null) continue;

        tableRelationsList.add({
          'targetTable': childProvider.tableName,
          'localKey': entry.value.localKey ?? '',
          'remoteKey': entry.value.remoteKey ?? '',
          'mapKey': entry.value.mapToKey,
          'isList': entry.value.castType.isList,
        });
      }

      if (tableRelationsList.isNotEmpty) {
        globalRelationMap[relDao.tableName] = tableRelationsList;
      }
    }

    FluentLog.info('Registry: Spawning FluentDb...', tag: 'FluentDb:init');

    await FluentEngine().initMultiple(
      dbPaths: dbPaths,
      relationMap: globalRelationMap,
      configs: performanceConfigs,
      dbTables: dbTables,
      dbRelationsCount: dbRelationsCount,
      dbNameWithDb: dbNameWithDb,
    );

    _isInitialized = true;
    FluentLog.info('Registry: Initialization complete.', tag: 'FluentDb:init');

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
  void _verifyAndFixIntegrity(FluentProvider dao) {
    if (dao is! FluentRelationsMixin) return;

    final Map<Type, FluentDbRelation> relations = dao.resolvedRelations;

    FluentLog.debug('Checking integrity for DAO', tag: 'FluentDb:verifyAndFix', context: {'table': dao.tableName});

    relations.forEach((targetType, relation) {
      try {
        final FluentProvider<FluentStorable> targetProvider = FluentDb.providerForType(targetType);
        final FluentDbColumn targetCol = targetProvider.primaryKeyColumn;

        FluentLog.debug('Verifying relation target', tag: 'FluentDb:verifyAndFix', context: {'source': dao.tableName, 'target': targetProvider.tableName, 'targetCol': targetCol.name});

        if (!targetCol.isPrimaryKey) {
          if (targetCol.autoCorrectAllowed) {
            targetCol.isPrimaryKey = true;
            targetProvider.refreshSchema();

            FluentLog.info('AUTO-FIX: Forced PRIMARY KEY on "${targetProvider.tableName}.${targetCol.name}"', tag: 'FluentDb:verifyAndFix');
          } else {
            relation.disable('Target column is not a PK and auto-correct is disabled');
            FluentLog.error(
              'Integrity violation: Target column is not a PK',
              FluentConstraintException('Constraint violation in ${dao.tableName}', originalError: 'SQLITE_CONSTRAINT', stackTrace: StackTrace.current),
              null,
              tag: 'FluentDb:verifyAndFix',
              hint: 'Enable autoCorrectAllowed on the target column or explicitly define it as a Primary Key.',
              context: {'table': dao.tableName, 'targetTable': targetProvider.tableName},
            );
          }
        } else {
          targetProvider.refreshSchema();
        }
      } catch (e, s) {
        relation.disable('Target column is not a PK and auto-correct is disabled');
        FluentLog.error(
          'Broken relation in "${dao.tableName}": Model "$targetType" is not registered.',
          e,
          s,
          tag: 'FluentDb:verifyAndFix',
          hint: 'Ensure that the model class is registered in the FluentDb before linkRelations runs.',
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
  Future<void> changeCurrentPerformanceConfig<T extends FluentProvider>(SQLitePerformanceConfig newConfig) async {
    final Database db = FluentDb.provider<T>().db;

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

    final Set<Database> uniqueDbs = dbs ?? _providers.values.map((p) => p.db).where((db) => db.isOpen).toSet();

    for (final Database db in uniqueDbs) {
      try {
        final String dbPath = db.path;
        await db.close();
        FluentLog.debug('Database closed successfully', tag: 'FluentDb:close', context: {'path': dbPath});
      } catch (e, st) {
        FluentLog.error('Error closing database', e, st, tag: 'FluentDb:close', hint: 'The database connection may have already been closed or became unresponsive during teardown.');
      }
    }
    _providers.clear();
    _tableToProviderIndex.clear();
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

    final Set<Database> uniqueDbs = _providers.values.map((p) => p.db).where((db) => db.isOpen).toSet();
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

  /// Permanently removes a specific database file from the file system.
  ///
  /// This method locates the database by name within the application's
  /// default database directory and performs an irreversible deletion.
  ///
  /// [dbName] The identifier of the database to be dropped.
  @visibleForTesting
  Future<void> dropDatabase(String dbName) async {
    FluentLog.warning(
      'Dropping database: "$dbName". All data will be permanently deleted.',
      tag: 'FluentDb:drop',
      hint: 'This operation is destructive and cannot be undone.',
      context: {'dbName': dbName},
    );

    try {
      final String databasesPath = await getDatabasesPath();
      final String path = '$databasesPath/$dbName';

      await FluentEngine().hardReset();

      FluentLog.debug('Deleting database file', tag: 'FluentDb:drop', context: {'path': path});
      await databaseFactory.deleteDatabase(path);

      FluentLog.info('Database file successfully removed', tag: 'FluentDb:drop', context: {'dbName': dbName});
    } catch (e, st) {
      FluentLog.error(
        'Failed to drop database: "$dbName"',
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
    FluentLog.warning(
      'Executing hard reset: Dropping all databases.',
      tag: 'FluentDb:dropAll',
      hint: 'This will irreversibly delete all local data. Ensure this is intentional.',
      context: {'providerCount': _providers.length},
    );
    await FluentEngine().hardReset();
    for (FluentProvider dao in _providers.values) {
      try {
        final String path = dao.db.path;
        FluentLog.debug('Deleting database file', tag: 'FluentDb:dropAll', context: {'path': path});
        await databaseFactory.deleteDatabase(path);
      } catch (e, st) {
        FluentLog.error('Failed to drop database file for ${dao.tableName}', e, st, tag: 'FluentDb:dropAll');
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
}
