part of '../fluent_sqlite_internal.dart';

class _FluentSystemDb {
  /// Low-level raw SQL queries provider for managing table metadata and counts.
  final SystemStatsProvider _systemStatsProvider = SystemStatsProvider();

  /// Dedicated database handle used exclusively for storing and reading internal metrics and table telemetry.
  Database? _systemDb;

  /// Dynamic hardware/software configuration overrides for each registered database.
  Map<String, Map<String, dynamic>> _dbConfigs = {};

  /// Cache of active SQLite database instances, mapped by their unique database name.
  Map<String, Database> _databases = {};

  Future<List<Map<String, dynamic>>?> analyzeStats() async => await _handleAnalyzeStatsCommand();

  Future<void> saveStats(List<dynamic>? stats) async => await _handleSaveStatsCommand(stats);

  Future<void> init({required Map<String, Map<String, dynamic>> dbConfigs, required Map<String, Database> databases}) async {
    _dbConfigs = dbConfigs;
    _databases = databases;
    await _ensureSystemDbOpen();
  }

  /// Gracefully closes the system telemetry connection and permanently deletes
  /// its physical file from the disk.
  Future<void> destroySystemDb() async {
    if (_systemDb == null) return;

    final String path = _systemDb!.path;

    try {
      if (_systemDb!.isOpen) {
        FluentLog.debug('Closing system telemetry database...', tag: 'FluentSystemDb:destroy');
        await _systemDb!.close();
      }

      FluentLog.debug('Deleting physical system database file', tag: 'FluentSystemDb:destroy', context: {'path': path});
      await databaseFactory.deleteDatabase(path);

      _systemDb = null;
      _dbConfigs.clear();
      _databases.clear();

      FluentLog.info('System telemetry database successfully deleted.', tag: 'FluentSystemDb:destroy');
    } catch (e, st) {
      FluentLog.error('Failed to destroy system telemetry database', e, st, tag: 'FluentSystemDb:destroy', context: {'path': path});
    }
  }

  /// Ensures that the dedicated telemetry system database connection is active.
  ///
  /// If the system handle is uninitialized, it mounts the [_systemDbName] file,
  /// builds internal tracking schemas via [_systemStatsProvider], and applies
  /// specialized light performance PRAGMA constraints.
  Future<void> _ensureSystemDbOpen() async {
    // Return early if the connection lifecycle is already active
    if (_systemDb != null) return;

    final String systemDbPath = join(await getDatabasesPath(), _systemDbName);

    FluentLog.info('Mounting permanent telemetry storage database connection...', tag: 'FluentSystemDb:open');

    _systemDb = await openDatabase(
      systemDbPath,
      version: 1,
      onCreate: (db, _) async {
        FluentLog.warning('Telemetry system tables missing. Triggering schema initialization...', tag: 'FluentSystemDb:open');
        await _systemStatsProvider.createTable(db);
      },
      onConfigure: (db) async {
        // Apply high-performance WAL and light caching rules for background indexing
        await db.execute('PRAGMA synchronous = FULL;');
        await db.execute('PRAGMA cache_size = -2000;');
        await db.execute('PRAGMA temp_store = MEMORY;');
        // await db.rawQuery('PRAGMA journal_mode = WAL;');
      },
    );

    FluentLog.info('Permanent telemetry session connection to "$_systemDbName" successfully established.', tag: 'FluentSystemDb:open');
  }

  /// Flushes live runtime weight telemetry from Main isolate to the system database.
  Future<void> _handleSaveStatsCommand(List<dynamic>? data) async {
    try {
      await _ensureSystemDbOpen();
      final List<dynamic> rawStats = data ?? const [];

      if (rawStats.isNotEmpty) {
        final List<TableStats> statsToSave = rawStats.map((rawRow) {
          final Map<String, dynamic> rowMap = rawRow is Map ? rawRow.cast<String, dynamic>() : const <String, dynamic>{};
          return TableStats.fromMap(rowMap);
        }).toList();

        await _systemStatsProvider.saveStatsBatch(_systemDb!, statsToSave);
        FluentLog.debug('Synchronized ${statsToSave.length} table telemetry matrix profiles to system disk.', tag: 'FluentSystemDb:saveStats');
      }
    } catch (e, st) {
      FluentLog.error('ERROR: Synchronization of statistics to disk failed.', e, st);
    }
  }

  /// Triggers internal structural diagnostics across all database registers.
  ///
  /// Computes rows metrics via physical SELECT COUNT calls if metadata cache is missed.
  Future<List<Map<String, dynamic>>?> _handleAnalyzeStatsCommand() async {
    FluentLog.debug('Running lazy database metrics analysis cascade...', tag: 'FluentSystemDb:analyzeStats');
    try {
      await _ensureSystemDbOpen();

      final List<TableStats> cachedRows = await _systemStatsProvider.readAllStats(_systemDb!);
      final List<Map<String, dynamic>> finalStatsPayload = [];

      final Map<String, TableStats> statsCacheMap = {for (var s in cachedRows) '${s.dbName}:${s.tableName}': s};

      FluentLog.debug('Executing live physical row scanning across active database configurations...', tag: 'FluentSystemDb:analyzeStats');
      final List<TableStats> updatedStatsToCache = [];

      for (final MapEntry<String, Database> dbEntry in _databases.entries) {
        final String dbName = dbEntry.key;
        final Database db = dbEntry.value;

        if (dbName == _systemDbName) continue;

        final Map<String, dynamic> currentCfg = _dbConfigs[dbName] ?? const {};
        final List<dynamic> tableNames = currentCfg['tables'] as List<dynamic>? ?? [];
        final Map<String, dynamic> relationsManifest = currentCfg['relationsManifest'] is Map ? (currentCfg['relationsManifest'] as Map).cast<String, dynamic>() : const {};

        for (final dynamic tableName in tableNames) {
          if (tableName is! String) continue;

          try {
            final int? count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $tableName').timeout(const Duration(milliseconds: 300)));
            FluentLog.debug('Counted structural row limit for table "$tableName" -> $count', tag: 'FluentSystemDb:analyzeStats');

            final String key = '$dbName:$tableName';
            final int relationsCount = relationsManifest[tableName] as int? ?? 0;

            final TableStats existingStats = statsCacheMap[key] ?? TableStats(dbName: dbName, tableName: tableName, relationsCount: relationsCount);

            final int newCount = count ?? 0;

            if (existingStats.rowCount != newCount) {
              existingStats.rowCount = newCount;
              updatedStatsToCache.add(existingStats);
            }

            if (!statsCacheMap.containsKey(key)) {
              statsCacheMap[key] = existingStats;
            }

            updatedStatsToCache.add(existingStats);
          } catch (e, st) {
            FluentLog.error('WARNING: Diagnostics failure on table "$tableName" inside database "$dbName"', e, st, tag: 'FluentSystemDb:analyzeStats');
          }
        }
      }

      if (updatedStatsToCache.isNotEmpty) {
        await _systemStatsProvider.saveStatsBatch(_systemDb!, updatedStatsToCache);
        FluentLog.info('Telemetry profiles successfully refreshed and synchronized to system storage.', tag: 'FluentSystemDb:analyzeStats');
      }

      for (final TableStats stats in statsCacheMap.values) {
        finalStatsPayload.add(stats.buildJson());
      }

      return finalStatsPayload;
    } catch (e, st) {
      FluentLog.error('Database Analysis failed', e, st, tag: 'FluentSystemDb:analyzeStats');
      return null;
    }
  }
}
