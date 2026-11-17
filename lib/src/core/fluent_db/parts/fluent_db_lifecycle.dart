// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_db.dart';

/// Hooks of the lifecycle for tests (hidden from the public API).
extension FluentLifecycleHooks on FluentDb {
  /// Deletes the database file at the path (what `deleteDatabases` and `resetOnSchemaError` call). Tests replace it
  /// to simulate a file that cannot be deleted (a lock): the caller then checks that the file is really gone.
  static Future<void> Function(String path) deleteFile = (String path) => databaseFactory.deleteDatabase(path);
}

/// The lifecycle of [FluentDb]: [FluentDb.planMigrations], [FluentDb.init], [FluentDb.restart], [FluentDb.close] and
/// [FluentDb.deleteDatabases] (the public statics serialize them), plus the maintenance timers, the read pool and the
/// SQLite pragmas of each connection.
extension _FluentDbLifecycle on FluentDb {
  /// [FluentDb.planMigrations]: plans every group on its own connection (an open database gets an empty plan).
  Future<List<FluentMigrationPlan>> _planMigrations(Iterable<FluentGroup> groups, FluentConfig config, {required bool runCode}) async {
    if (_isInitialized) return _planGroups(groups, config, runCode: runCode);
    // The settings are the plan's own: the ones of the library stay as they were (nothing is initialized).
    final FluentConfig before = FluentEngine().config;
    FluentEngine().applyConfig(config);
    try {
      return await _planGroups(groups, config, runCode: runCode);
    } finally {
      if (identical(FluentEngine().config, config)) FluentEngine().applyConfig(before);
    }
  }

  Future<List<FluentMigrationPlan>> _planGroups(Iterable<FluentGroup> groups, FluentConfig config, {required bool runCode}) async {
    final List<FluentGroup> groupList = groups.toList(growable: false);
    _refuseSharedProviders([for (final FluentGroup g in groupList) if (g.providerList.isNotEmpty) g], tag: 'FluentDb:planMigrations');
    final List<FluentMigrationPlan> plans = [];
    for (final FluentGroup group in groupList) {
      if (group.providerList.isEmpty) continue;
      final String name = group.dbKey.dbName;
      if (_groupedRegistry.containsKey(name)) {
        FluentLog.issue(
          FluentIssueKind.ignoredCall,
          'planMigrations: database "$name" is already open, so its schema is already applied; the plan is empty.',
          database: name,
          tag: 'FluentDb:planMigrations',
          hint: 'Plan before FluentDb.init (or after FluentDb.close).',
        );
        plans.add(FluentMigrationPlan(database: name, changes: const [], issues: const []));
        continue;
      }
      if (group.readOnly && !group.inMemory) {
        // A read-only file is never synced (init skips the schema), so there is nothing to plan: it is not even opened,
        // which keeps the file and its journal untouched.
        plans.add(FluentMigrationPlan(database: name, changes: const [], issues: const []));
        continue;
      }
      for (final FluentProvider dao in group.providerList) {
        dao.setDbName(name);
      }
      buildFluentRelationGraph(
        group.providerList,
        foreignKeysEnabled: group.config.enableForeignKeys,
        autoFallback: group.autoRelationFallback,
        indexReferences: group.config.indexReferences ?? config.indexReferences,
        autoRelations: group.config.autoRelations ?? config.autoRelations,
      );
      for (final FluentProvider dao in group.providerList) {
        dao.refreshSchema();
      }
      final String path = await group.resolvePath();
      // A file that does not exist is planned in memory: planning never creates it.
      final bool isNew = group.inMemory || !await databaseFactory.databaseExists(path);
      final Database db = await openDatabase(isNew ? inMemoryDatabasePath : path, singleInstance: false);
      try {
        await db.execute('PRAGMA foreign_keys = ${group.config.enableForeignKeys ? 'ON' : 'OFF'}');
        plans.add(await _planSchema(db, group, _getSortedProviders(group.providerList), runCode: runCode, isNewDatabase: isNew));
      } finally {
        await db.close();
      }
    }
    return plans;
  }

  /// [FluentDb.init]: opens, syncs and registers every group. A failing group closes every database this call opened;
  /// with `resetOnSchemaError` (and not [isRetry]) its file is deleted and the whole init runs once more.
  Future<void> _init(Iterable<FluentGroup> groups, FluentConfig requested, {required bool isRetry}) async {
    if (_isInitialized) return;

    // The caller's Iterable may be single-use: it is read once, the retry (resetOnSchemaError) reuses this list.
    final List<FluentGroup> groupList = groups.toList(growable: false);
    final Stopwatch stopwatch = Stopwatch()..start();
    final Map<String, FluentGroup> uniqueGroupsMap = {};

    for (final FluentGroup g in groupList) {
      if (g.providerList.isEmpty) continue;

      final String dbName = g.dbKey.dbName;

      if (!_isSafeDbName(g.dbKey)) {
        throw FluentLog.raise(
          FluentConfigException(
            'Invalid database name "$dbName": it is used as the file name, so only letters, digits and _ are allowed.',
            code: FluentErrorCode.invalidDatabaseName,
            hint: "Rename it, e.g. FluentDbKey('${dbName.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}').",
          ),
          tag: 'FluentDb:init',
        );
      }

      if (uniqueGroupsMap.containsKey(dbName)) {
        FluentLog.issue(
          FluentIssueKind.duplicateGroup,
          'Found duplicate FluentGroup for database "$dbName". Only the first will be used.',
          database: dbName,
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
      FluentLog.issue(
        FluentIssueKind.noGroups,
        'No active groups with DAOs provided.',
        tag: 'FluentDb:init',
        hint:
            'The initialization registry is empty. Ensure that you are passing a non-empty iterable of FluentGroup instances to FluentDb.init(). '
            'If you intended to start with no databases, ignore this warning; otherwise, check your dependency injection or group provider setup.',
      );
      return;
    }

    _refuseSharedProviders(uniqueGroupsMap.values, tag: 'FluentDb:init');

    final FluentConfig config = FluentDb._checkedConfig(requested);
    FluentDb._lastConfig = uniqueGroupsMap.values.toList();
    FluentDb._lastFluentConfig = config;
    FluentEngine().applyConfig(config);
    // The settings of every database are known to the engine before the first schema sync and relation graph run: the
    // hints they raise follow the diagnostics of their own database.
    FluentEngine().preloadDbConfigs({for (final FluentGroup g in uniqueGroupsMap.values) g.dbKey.dbName: g.config});

    final Map<String, FluentDbConfig> dbConfigs = {};
    final Map<String, Database> dbNameWithDb = {};
    final Map<String, Map<String, int>> dbRelationsCount = {};
    final Map<String, List<Map<String, Object?>>> stats = {};
    final Set<String> persistStats = {};


    for (final FluentGroup group in uniqueGroupsMap.values) {
      final String currentDbName = group.dbKey.dbName;

      try {
        FluentLog.debug('Initializing database group: $currentDbName', tag: 'FluentDb:init');

        for (final FluentProvider dao in group.providerList) {
          dao.setDbName(currentDbName);
          dao.registerSelf(_register);
        }
        _warnSharedModelTypes(group);

        final List<String> tableNames = [];
        final Map<String, int> relationsManifest = {};

        // Resolve relations once for the whole group: columns, link tables, delete rules.
        buildFluentRelationGraph(
          group.providerList,
          foreignKeysEnabled: group.config.enableForeignKeys,
          autoFallback: group.autoRelationFallback,
          indexReferences: group.config.indexReferences ?? config.indexReferences,
          autoRelations: group.config.autoRelations ?? config.autoRelations,
        );

        for (final FluentProvider dao in group.providerList) {
          dao.refreshSchema();
          tableNames.add(dao.tableName);
          relationsManifest[dao.tableName] = dao.relationLinks.length;
        }

        group.providerList.forEach(FluentAnalyzer().onSchema);

        final List<FluentProvider> sortedDaos = _getSortedProviders(group.providerList);
        FluentLog.debug('Group "$currentDbName": Relations established and sorted.', tag: 'FluentDb:init');

        final String path = await group.resolvePath();
        dbConfigs[currentDbName] = group.config;
        dbRelationsCount[currentDbName] = relationsManifest;

        if (group.inMemory && group.readOnly) {
          FluentLog.issue(
            FluentIssueKind.configFallback,
            'Database "$currentDbName" is in memory and read-only; it is opened writable (an empty read-only database is useless).',
            database: currentDbName,
            tag: 'FluentDb:init',
            hint: 'Remove readOnly: true, or drop inMemory: true to open a prebuilt file read-only.',
          );
        }
        final bool readOnly = group.readOnly && !group.inMemory;

        if (readOnly && !await databaseFactory.databaseExists(path)) {
          throw FluentConfigException(
            'Read-only database "$currentDbName" does not exist${FluentLog.showSqlArguments ? ' at $path' : ''}.',
            code: FluentErrorCode.databaseNotFound,
            hint: 'Copy the prebuilt database file to FluentGroup.resolvePath() before init, or set readOnly: false to create it.',
          );
        }

        if (group.directory != null && !group.inMemory) {
          await Directory(group.directory!).create(recursive: true);
        }

        final Database db = readOnly
            ? await openDatabase(path, readOnly: true, onConfigure: (db) => _applyPerformanceConfig(db, group.config))
            : await openDatabase(
          path,
          version: 1,
          // Every in-memory group is its own database (a shared instance would mix the groups).
          singleInstance: !group.inMemory,
          // Tables are created by the schema sync below (no separate onCreate pass).
          onConfigure: (db) => _applyPerformanceConfig(db, group.config, isFullConfig: true),
        );

        dbNameWithDb[currentDbName] = db;

        for (final FluentProvider dao in group.providerList) {
          dao.setDb(db);
        }

        if (readOnly) {
          FluentLog.info('Database "$currentDbName" opened read-only: schema sync, migrations and maintenance skipped.', tag: 'FluentDb:init');
          await FluentRelationSchema.keepOneToOneSides(db, group.providerList);
          // The full-text index the file was built with is used as it is (it cannot be created here).
          for (final FluentProvider dao in group.providerList) {
            await dao.adoptFullText(db, group.config.fullText);
          }
        } else {
          FluentLog.debug('Syncing schema and maintenance for $currentDbName', tag: 'FluentDb:init');
          final bool danglingReferences = await _syncSchema(db, group, sortedProviders: sortedDaos);
          await _runInitialMaintenance(group, cleanOrphans: danglingReferences || !group.config.enableForeignKeys);
          if (!group.inMemory) {
            if ((group.config.diagnostics ?? config.diagnostics).costModel) {
              stats[currentDbName] = await _loadStats(db, currentDbName);
              persistStats.add(currentDbName);
            }
          }
        }
      } catch (e, st) {
        const String keepHint =
            'The database file was left untouched. Fix the cause and start again; for throw-away caches '
            'FluentGroup(resetOnSchemaError: true) recreates the file automatically.';
        final FluentException failure = e is FluentException
            ? e
            : FluentConfigException(
                'Database "$currentDbName" could not be opened: ${FluentLog.redact('$e')}',
                hint: 'Usually a corrupted or locked file, or a constraint the existing data violates. $keepHint',
                cause: e,
                stackTrace: st,
              );
        // Logged once, as the issue: it carries the error, so nothing logs the exception again on its way to the caller.
        FluentLog.issue(
          FluentIssueKind.initFailed,
          'Initialization of database "$currentDbName" failed (${failure.code.name}).',
          database: currentDbName,
          tag: 'FluentDb:init',
          hint: failure.hint ?? keepHint,
          context: {'isRetry': isRetry},
          error: failure,
          stackTrace: st,
        );

        // A refused plan is a decision, a busy / locked file is in use, a read-only file is prebuilt: none of them is a
        // broken file, so none deletes the database.
        if (group.resetOnSchemaError && !isRetry && _recreateFixes(failure, group)) {
          // Every database this call opened is closed (the retry opens them again), then the failing file is deleted.
          await _closeAll(dbs: {for (final Database db in dbNameWithDb.values) if (db.isOpen) db});
          final Object? left = await _deleteDatabaseFile(group);
          if (left != null) {
            // The file is still there: opening it again would fail the same way, and nothing was recreated.
            FluentLog.issue(
              FluentIssueKind.fileDeleteFailed,
              'The file of database "$currentDbName" could not be deleted, so it was not recreated (resetOnSchemaError: true).',
              database: currentDbName,
              tag: 'FluentDb:init',
              hint: 'Another process or connection probably holds the file. Close it, or delete the file by hand, and start again.',
              error: left,
            );
            FluentEngine().preloadDbConfigs(const {}); // nothing is open: no settings to follow
            Error.throwWithStackTrace(failure, st);
          }
          FluentLog.issue(
            FluentIssueKind.databaseRecreated,
            'Recreated database "$currentDbName" after an initialization failure (resetOnSchemaError: true). All its data was deleted.',
            database: currentDbName,
            tag: 'FluentDb:init',
            hint: 'Only use resetOnSchemaError for data that can be downloaded again (caches).',
            context: {'dbName': currentDbName},
          );

          uniqueGroupsMap.clear();
          _reset();

          return await _init(groupList, config, isRetry: true);
        } else {
          stopwatch.stop();
          // Nothing stays half open: the databases this call opened before the failure are closed again.
          await _closeAll(dbs: {for (final Database db in dbNameWithDb.values) if (db.isOpen) db});
          FluentEngine().preloadDbConfigs(const {}); // nothing is open: no settings to follow
          Error.throwWithStackTrace(failure, st);
        }
      }
    }

    FluentLog.debug('Registry: Spawning FluentDb...', tag: 'FluentDb:init');

    try {
      await FluentEngine().initMultiple(
        configs: dbConfigs,
        dbRelationsCount: dbRelationsCount,
        dbNameWithDb: dbNameWithDb,
        stats: stats,
        persistStats: persistStats,
      );
      for (final FluentGroup group in uniqueGroupsMap.values) {
        final Database? main = dbNameWithDb[group.dbKey.dbName];
        if (main == null) continue;
        final List<Database> readers = await _openReadConnections(group, main, config);
        FluentEngine().attachReaders(group.dbKey.dbName, readers);
        FluentLog.debug(
          'Database "${group.dbKey.dbName}" ready',
          tag: 'FluentDb:init',
          context: {'readConnections': readers.length, 'diagnostics': '${group.config.diagnostics ?? config.diagnostics}'},
        );
      }
      await FluentTuner().start(dbNameWithDb);
    } catch (e, st) {
      // Nothing stays half started: the engine stops and the databases this call opened are closed again.
      final FluentException failure = e is FluentException
          ? e
          : FluentEngineException('The databases could not be started: ${FluentLog.redact('$e')}', hint: 'Usually a file another process holds. Fix the cause and call FluentDb.init again.', cause: e, stackTrace: st);
      FluentLog.report(failure, tag: 'FluentDb:init');
      await _closeAll(dbs: {for (final Database db in dbNameWithDb.values) if (db.isOpen) db});
      FluentEngine().preloadDbConfigs(const {}); // nothing is open: no settings to follow
      Error.throwWithStackTrace(failure, st);
    }
    unawaited(_deleteLegacyStatsDb(uniqueGroupsMap.values.toList()));

    _isInitialized = true;
    stopwatch.stop();
    FluentLog.info('Registry: Initialization complete in ${stopwatch.elapsedMilliseconds}ms', tag: 'FluentDb:init', context: {'totalGroups': uniqueGroupsMap.length});

    unawaited(_purgeSoftDeletedGlobal());
    _restartTimers(config);
  }

  /// Whether deleting the file of [group] can fix [failure] (`resetOnSchemaError`): not for a refused plan, a missing
  /// read-only file, a read-only group, or a file another connection holds (busy / locked).
  bool _recreateFixes(FluentException failure, FluentGroup group) {
    if (group.readOnly && !group.inMemory) return false;
    if (group.inMemory) return false; // no file to recreate
    if (failure.code == FluentErrorCode.migrationRefused || failure.code == FluentErrorCode.databaseNotFound) return false;
    final RegExp inUse = RegExp(r'database is locked|database table is locked|SQLITE_BUSY|SQLITE_LOCKED|database is busy', caseSensitive: false);
    return !inUse.hasMatch('${failure.message} ${failure.cause ?? ''}');
  }

  /// (Re)starts the periodic trash purge and `PRAGMA optimize` of [config] (only while initialized).
  void _restartTimers(FluentConfig config) {
    _trashPurgeTimer?.cancel();
    _optimizeTimer?.cancel();
    _trashPurgeTimer = _optimizeTimer = null;
    if (!_isInitialized) return;
    final Duration? purgeEvery = config.trashPurgeInterval;
    // Library time (FluentClock): tests move them with the clock instead of waiting.
    if (purgeEvery != null) _trashPurgeTimer = FluentClockTimer(purgeEvery, _purgeSoftDeletedGlobal, tag: 'FluentDb:purge');
    final Duration? optimizeEvery = config.optimizeInterval;
    if (optimizeEvery != null) _optimizeTimer = FluentClockTimer(optimizeEvery, _optimizeAll, tag: 'FluentDb:optimize');
  }

  /// Opens the read pool of [group] (`readConnections` of the group, else of `FluentConfig`): only for a database
  /// file in WAL mode. Any problem leaves the pool empty (reads use the main connection) with a warning.
  Future<List<Database>> _openReadConnections(FluentGroup group, Database main, FluentConfig config) async {
    final FluentDbConfig cfg = group.config;
    final int count = (cfg.readConnections ?? config.readConnections ?? FluentTuner.readConnections(group, config)).clamp(0, 4);
    if (group.inMemory || count == 0) return const [];
    final List<Database> readers = [];
    try {
      final List<Map<String, Object?>> mode = await main.rawQuery('PRAGMA journal_mode');
      if (mode.isEmpty || mode.first.values.first.toString().toLowerCase() != 'wal') {
        FluentLog.debug('No read pool for "${group.dbKey.dbName}": the database is not in WAL mode', tag: 'FluentDb:readers');
        return const [];
      }
      final String path = await group.resolvePath();
      for (int i = 0; i < count; i++) {
        readers.add(await openDatabase(path, readOnly: true, singleInstance: false, onConfigure: (db) => _applyPerformanceConfig(db, cfg)));
      }
      return readers;
    } catch (e, st) {
      for (final Database r in readers) {
        await r.close();
      }
      FluentLog.issue(
        FluentIssueKind.readPoolFallback,
        'Read connections of "${group.dbKey.dbName}" could not be opened; reads run on the main connection.',
        database: group.dbKey.dbName,
        tag: 'FluentDb:readers',
        hint: 'Everything keeps working, only reads do not run in parallel. Set FluentDbConfig(readConnections: 0) to skip them.',
        error: e,
        stackTrace: st,
      );
      return const [];
    }
  }

  /// The measured query costs kept in [db] (its `__fluent_stats` table, created when missing). A failure only means the
  /// costs are measured again.
  Future<List<Map<String, Object?>>> _loadStats(Database db, String dbName) async {
    try {
      try {
        return await db.query(FluentTableStatsTracker.table);
      } on DatabaseException {
        // First start: no measurements yet.
        await db.execute(FluentTableStatsTracker.createTableSql);
        return const [];
      }
    } catch (e) {
      FluentLog.debug('Query stats of "$dbName" not loaded (measured again): $e', tag: 'FluentDb:stats');
      return const [];
    }
  }

  /// Deletes the telemetry file of earlier versions (`fluent_system.db`); it only held measurements. Earlier versions
  /// only ever wrote it to the default databases folder, so a file of that name in a group's own directory (which
  /// may be shared with other code) is left alone, and so is a file one of [groups] resolves to (a database that is
  /// itself named `fluent_system`).
  Future<void> _deleteLegacyStatsDb(List<FluentGroup> groups) async {
    try {
      final String path = join(await getDatabasesPath(), legacyStatsDbName);
      for (final FluentGroup g in groups) {
        if (!g.inMemory && _samePath(await g.resolvePath(), path)) return;
      }
      if (await databaseFactory.databaseExists(path)) await databaseFactory.deleteDatabase(path);
    } catch (e) {
      FluentLog.debug('Old telemetry file not deleted: ${FluentLog.redact('$e')}', tag: 'FluentDb:stats');
    }
  }

  /// Whether [a] and [b] name the same file (absolute, `.` / `..` resolved).
  bool _samePath(String a, String b) => Directory(a).absolute.uri.normalizePath() == Directory(b).absolute.uri.normalizePath();

  /// Refuses a provider instance listed in two groups (in [groups], or already registered in another open database):
  /// it holds one database name and connection, so the last group would silently win.
  void _refuseSharedProviders(Iterable<FluentGroup> groups, {required String tag}) {
    final Map<FluentProvider, String> owner = Map<FluentProvider, String>.identity();
    for (final MapEntry<String, _FluentProviderIndex> e in _groupedRegistry.entries) {
      for (final FluentProvider p in e.value.all) {
        owner[p] = e.key;
      }
    }
    for (final FluentGroup g in groups) {
      final String name = g.dbKey.dbName;
      for (final FluentProvider p in g.providerList) {
        final String? other = owner[p];
        if (other != null && other != name) {
          throw FluentLog.raise(
            FluentConfigException(
              'The provider ${p.runtimeType} (table "${p.tableName}") is listed in two databases ("$other" and "$name"); one instance can only belong to one.',
              hint: 'Create one provider instance per group, e.g. CacheNotes() and MainNotes(), or two instances of the same class.',
            ),
            tag: tag,
          );
        }
        owner[p] = name;
      }
    }
  }

  /// Deletes the file of [group] and checks that it is really gone (sqflite swallows delete errors). Returns `null`
  /// when it is gone, else the error (or a description) of why it stayed. An in-memory group has no file.
  Future<Object?> _deleteDatabaseFile(FluentGroup group) async {
    if (group.inMemory) return null;
    Object? error;
    String? path;
    try {
      path = await group.resolvePath();
      await FluentLifecycleHooks.deleteFile(path);
    } catch (e) {
      error = e;
    }
    if (path == null) return error;
    try {
      if (await _fileStillThere(path)) return error ?? 'the file is still there after the delete';
    } catch (e) {
      return error ?? e;
    }
    return null;
  }

  /// Whether a file exists at [path] (any content: a damaged file is not a database for sqflite, but it is a file).
  Future<bool> _fileStillThere(String path) async {
    if (await databaseFactory.databaseExists(path)) return true;
    final RegExp separator = RegExp(r'[\\/]');
    final String name = path.split(separator).last;
    final Directory folder = Directory(path).parent;
    if (!folder.existsSync()) return false;
    await for (final entity in folder.list()) {
      if (entity.path.split(separator).last == name) return true;
    }
    return false;
  }

  /// One model type stored by several providers (in different tables) works through the providers themselves, but not
  /// through calls that find the provider by model type (`FluentDb.find<T>()`, relations to `T`): warn once at init.
  void _warnSharedModelTypes(FluentGroup group) {
    final Map<Type, List<FluentProvider>> byType = {};
    for (final FluentProvider p in group.providerList) {
      byType.putIfAbsent(p.modelType, () => []).add(p);
    }
    for (final MapEntry<Type, List<FluentProvider>> e in byType.entries.where((e) => e.value.length > 1)) {
      final String providers = e.value.map((p) => '${p.runtimeType} → ${p.tableName}').join(', ');
      FluentLog.issue(
        FluentIssueKind.sharedModelType,
        '${e.key} is stored in ${e.value.length} tables of "${group.dbKey.dbName}" ($providers).',
        database: group.dbKey.dbName,
        tag: 'FluentDb:init',
        hint: 'This works through each provider (FluentDb.provider<${e.value.first.runtimeType}>().find(...)). Calls by model type '
            '(FluentDb.find<${e.key}>(), model.save(), relations to ${e.key}) cannot choose a table and fail. If that is not intended, '
            'give each table its own model type (class Archived${e.key} extends ${e.key}).',
      );
    }
  }

  /// [providers] ordered so that referenced tables come before the tables referencing them (depth-first). A cycle is
  /// reported (`circularReference`) and broken where it is found.
  List<FluentProvider> _getSortedProviders(Set<FluentProvider> providers) {
    final List<FluentProvider> sorted = [];
    final Set<FluentProvider> visited = {};
    final Set<FluentProvider> visiting = {};

    void visit(FluentProvider provider) {
      if (visited.contains(provider)) return;

      if (visiting.contains(provider)) {
        FluentLog.issue(
          FluentIssueKind.circularReference,
          'Circular dependency detected for table "${provider.tableName}"',
          table: provider.tableName,
          tag: 'FluentDb:getSorted',
          hint: 'The model graph contains a cycle. Ensure that foreign key constraints are not mutually dependent.',
          context: {'table': provider.tableName},
        );
        return;
      }

      visiting.add(provider);
      FluentLog.debug('Visiting provider', tag: 'FluentDb:getSorted', context: {'table': provider.tableName});

      // Referenced tables first (Article.author → people is created before articles).
      for (final FluentRelationLink link in provider.relationLinks) {
        if (!link.isReference || identical(link.target, provider)) continue;
        if (providers.contains(link.target)) visit(link.target);
      }

      visiting.remove(provider);
      visited.add(provider);
      sorted.add(provider);

      FluentLog.debug('Sorted provider appended', tag: 'FluentDb:getSorted', context: {'table': provider.tableName});
    }

    FluentLog.debug('Starting topological sort of providers', tag: 'FluentDb:getSorted', context: {'count': providers.length});
    providers.forEach(visit);
    FluentLog.debug('Topological sort completed', tag: 'FluentDb:getSorted');
    return sorted;
  }

  /// [FluentDb.restart]: closes everything and opens the groups of the last init again (changed by [updateConfig]).
  Future<void> _restart(List<FluentGroup> Function(List<FluentGroup> groups)? updateConfig) async {
    if ((FluentDb._lastConfig?.isEmpty ?? true)) {
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        'Restart failed: No previous configuration found.',
        tag: 'FluentDb:restart',
        hint: 'Ensure that init() has been called successfully at least once before requesting a restart.',
      );
      return;
    }
    FluentLog.info('Restarting database engine...', tag: 'db:registry');

    // The app's callback runs first: when it throws, the databases stay open as they were.
    final List<FluentGroup> configToUse;
    try {
      configToUse = updateConfig != null ? updateConfig(List.of(FluentDb._lastConfig ?? const [])) : List.of(FluentDb._lastConfig ?? const []);
    } catch (e, st) {
      throw FluentLog.raise(
        FluentConfigException('restart: the update callback threw: ${FluentLog.redact('$e')}', hint: 'The databases were left open as they were; fix the callback and call restart again.', cause: e, stackTrace: st),
        tag: 'FluentDb:restart',
      );
    }
    await _closeAll();
    await _init(configToUse, FluentDb._lastFluentConfig, isRetry: false);
  }

  /// [FluentDb.close]: stops the timers and the engine (calls already made finish first), runs `PRAGMA optimize` and
  /// closes [dbs] (every open database of the registry without it), then forgets the registered providers.
  Future<void> _closeAll({Set<Database>? dbs}) async {
    FluentLog.debug('Closing all database connections...', tag: 'FluentDb:close');
    _trashPurgeTimer?.cancel();
    _trashPurgeTimer = null;
    _optimizeTimer?.cancel();
    _optimizeTimer = null;
    // Stop the engine first: calls already made finish, later ones fail clearly; then the files are closed.
    await FluentEngine().shutdown();

    final Set<Database> uniqueDbs = dbs ?? _groupedRegistry.values.expand((group) => group.all).map((p) => p.dbOrNull).whereType<Database>().where((db) => db.isOpen).toSet();

    for (final Database db in uniqueDbs) {
      try {
        final String dbPath = db.path;
        await _optimize(db);
        await db.close();
        // The path only appears when the log may show it (showSqlArguments).
        FluentLog.debug('Database closed successfully', tag: 'FluentDb:close', context: FluentLog.showSqlArguments ? {'path': dbPath} : null);
      } catch (e, st) {
        FluentLog.issue(FluentIssueKind.closeFailed, 'Error closing database', error: e, stackTrace: st, tag: 'FluentDb:close', hint: 'The database connection may have already been closed or became unresponsive during teardown.');
      }
    }
    _groupedRegistry.clear();
    _isInitialized = false;
    FluentLog.info('Registry reset: All connections closed and providers cleared.', tag: 'FluentDb:close');
  }

  /// [FluentDb.deleteDatabases]: tells watchers the tables are empty, closes everything, deletes the files of
  /// [dbName] (all without it) and, with [reopen], opens the groups again.
  Future<void> _deleteDatabases(String? dbName, {required bool reopen}) async {
    // Only open databases: groups of the last init that are closed (or were deleted before) have no files to delete.
    final List<FluentGroup> groups = [for (final FluentGroup g in FluentDb._lastConfig ?? const <FluentGroup>[]) if (_groupedRegistry.containsKey(g.dbKey.dbName)) g];
    final List<FluentGroup> requested = [for (final FluentGroup g in groups) if (dbName == null || g.dbKey.dbName == dbName) g];
    if (requested.isEmpty) {
      throw FluentLog.raise(
        FluentConfigException(
          dbName == null ? 'No database is open, so none can be deleted.' : 'Database "$dbName" is not open, so it cannot be deleted.',
          code: FluentErrorCode.databaseNotFound,
          hint: 'Use the dbKey of a group passed to FluentDb.init([...]).',
        ),
        tag: 'FluentDb:delete',
      );
    }
    // A read-only (prebuilt) file is not the library's data: it is kept, and the group stays open as it is.
    final List<FluentGroup> deleted = [];
    for (final FluentGroup g in requested) {
      if (g.readOnly && !g.inMemory) {
        FluentLog.info('Database "${g.dbKey.dbName}" is read-only (prebuilt), so its file was kept.', tag: 'FluentDb:delete');
      } else {
        deleted.add(g);
      }
    }
    if (deleted.isEmpty) return;
    FluentLog.info('Deleting database files: ${deleted.map((g) => g.dbKey.dbName).join(', ')}', tag: 'FluentDb:delete');

    for (final FluentGroup group in deleted) {
      for (final FluentProvider<FluentStorable> provider in _groupedRegistry[group.dbKey.dbName]?.all ?? const <FluentProvider>[]) {
        FluentEngine().broadcastSystemAction(FluentDbAction.wipeAll, provider);
      }
    }

    await _closeAll();
    // Stats of deleted databases must not be written back to the new files.
    for (final FluentGroup g in deleted) {
      FluentTableStatsTracker().discard(g.dbKey.dbName);
    }
    // The delete is checked: sqflite does not report a file it could not delete (a lock), and the old rows would stay.
    final List<FluentGroup> failed = [];
    Object? firstCause;
    for (final FluentGroup g in deleted) {
      final Object? left = await _deleteDatabaseFile(g);
      if (left == null) continue;
      failed.add(g);
      firstCause ??= left;
      if (!reopen) {
        FluentLog.issue(
          FluentIssueKind.fileDeleteFailed,
          'The file of database "${g.dbKey.dbName}" could not be deleted; it keeps its data.',
          database: g.dbKey.dbName,
          tag: 'FluentDb:delete',
          hint: 'Another process or connection probably holds the file. Close it and call FluentDb.deleteDatabases again.',
          error: left,
        );
      }
    }

    // reopen: every group except the ones whose file stayed (they would show the old rows). Without reopen: the groups
    // that were not deleted, plus the ones whose delete failed (they still hold their data, nothing is lost).
    final List<FluentGroup> reopened = reopen ? [for (final FluentGroup g in groups) if (!failed.contains(g)) g] : [for (final FluentGroup g in groups) if (!deleted.contains(g) || failed.contains(g)) g];
    if (reopened.isNotEmpty) await _init(reopened, FluentDb._lastFluentConfig, isRetry: false);
    // A later restart() opens what stayed open: a deleted database is not created again behind the app's back.
    FluentDb._lastConfig = reopen ? groups : reopened;
    if (reopen && failed.isNotEmpty) {
      throw FluentLog.raise(
        FluentConfigException(
          'The file of database ${failed.map((g) => '"${g.dbKey.dbName}"').join(', ')} could not be deleted, so ${failed.length == 1 ? 'it was' : 'they were'} not opened again (the old data is still there).',
          hint: 'Another process or connection probably holds the file. Close it, then call FluentDb.deleteDatabases() or FluentDb.restart() again.',
          cause: firstCause,
        ),
        tag: 'FluentDb:delete',
      );
    }
    if (failed.isEmpty) FluentLog.info('Database files deleted${reopen ? ' and opened again' : ''}.', tag: 'FluentDb:delete');
  }

  /// Applies the pragmas of [cfg] to [db] when it is opened (`onConfigure`): `synchronous`, `cache_size`,
  /// `busy_timeout`, `temp_store`. [isFullConfig] (the main writable connection only, not read-only ones or the read
  /// pool) also sets `foreign_keys` and `journal_mode`.
  Future<void> _applyPerformanceConfig(Database db, FluentDbConfig cfg, {bool isFullConfig = false}) async {
    FluentLog.debug('Applying SQLite performance pragmas', tag: 'FluentDb:cfg', context: {'synchronous': cfg.synchronous.value, 'cacheSize': cfg.cacheSize.rawValue, 'isFullConfig': isFullConfig});

    await db.execute('PRAGMA synchronous = ${cfg.synchronous.value};');
    await db.execute('PRAGMA cache_size = ${cfg.cacheSize.rawValue};');

    if (cfg.busyTimeout != null) {
      await db.rawQuery('PRAGMA busy_timeout = ${cfg.busyTimeout!.inMilliseconds};');
    }

    if (cfg.tempStoreInMemory) {
      await db.execute('PRAGMA temp_store = MEMORY;');
    }

    if (isFullConfig) {
      await db.execute('PRAGMA foreign_keys = ${cfg.enableForeignKeys ? "ON" : "OFF"};');
      await db.rawQuery('PRAGMA journal_mode = ${cfg.journalMode.value};');

      FluentLog.debug('Applied structural PRAGMAs (FKs and Journal Mode)', tag: 'FluentDb:cfg');
    }
  }

  /// Whether the name of [dbKey] is safe as a file name: only `a-z`, `A-Z`, `0-9` and `_` (no path separators, dots,
  /// spaces or other characters).
  bool _isSafeDbName(FluentDbKey dbKey) {
    final RegExp safeNameRegex = RegExp(r'^[a-zA-Z0-9_]+$');
    return safeNameRegex.hasMatch(dbKey.dbName);
  }

  /// Lets SQLite refresh the statistics of its query planner (cheap; it only analyzes what needs it).
  Future<void> _optimize(Database db) async {
    if (!db.isOpen) return; // already closed; on a read-only database the statement fails and is ignored below
    try {
      await db.execute('PRAGMA optimize');
    } catch (e) {
      FluentLog.debug('PRAGMA optimize skipped: $e', tag: 'FluentDb:optimize');
    }
  }

  /// [_optimize] for every open database, queued like a write so it never overlaps the app's own work.
  Future<void> _optimizeAll() async {
    for (final MapEntry<String, _FluentProviderIndex> entry in List.of(_groupedRegistry.entries)) {
      final _FluentProviderIndex group = entry.value;
      if (group.all.isEmpty || _isReadOnly(entry.key) || FluentTuner().defersMaintenance(entry.key)) continue;
      try {
        await group.all.first.execute('PRAGMA optimize', policy: ExecutionPolicy.background);
      } catch (e) {
        FluentLog.debug('PRAGMA optimize skipped: $e', tag: 'FluentDb:optimize');
      }
    }
  }
}
