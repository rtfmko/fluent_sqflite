part of '../fluent_sqlite_internal.dart';

/// The [ _FluentSystemDb ] acts as a dedicated repository for FluentSQFLite's internal state.
///
/// It encapsulates the lifecycle and persistence of the telemetry database, ensuring
/// that performance metrics, row counts, and table metadata are physically isolated
/// from the user's operational data.
class _FluentSystemDb {
  /// Provides the SQL abstraction layer for telemetry-specific operations.
  ///
  /// This separates the concerns of data manipulation (DML) from the
  /// orchestrator's state management logic.
  final SystemStatsProvider _systemStatsProvider = SystemStatsProvider();

  /// A private, dedicated database instance for storing performance snapshots.
  ///
  /// This handle is managed exclusively by the [FluentEngine] to ensure
  /// consistent APM (Application Performance Monitoring) metrics across sessions.
  ///
  /// **Lifecycle:**
  /// * Initialized: On [FluentEngine] startup.
  /// * Destroyed: Upon [FluentDb] shutdown or registry reset.
  Database? _systemDb;

  /// Retrieves all historical performance statistics from the persistent system storage.
  ///
  /// This method performs a safe hydration of the in-memory tracker by reading
  /// existing metrics from the telemetry database.
  ///
  /// **Failure Handling:**
  /// * If the database is closed or uninitialized, returns an empty list and logs a warning.
  /// * If a query error occurs, logs the error with diagnostic hints and returns an empty list.
  Future<List<TableStats>> loadAllHistoricalStats() async {
    await _ensureSystemDbOpen();
    if (_systemDb == null || !_systemDb!.isOpen) {
      FluentLog.warning('System database is not available for reading stats.', tag: 'FluentSystemDb:load', hint: 'Ensure that FluentEngine has been properly initialized before accessing stats.');
      return [];
    }
    try {
      final List<TableStats> stats = await _systemStatsProvider.readAllStats(_systemDb!);
      FluentLog.debug('Loaded ${stats.length} stats records.', tag: 'FluentSystemDb:load');
      return stats;
    } catch (e, st) {
      FluentLog.error('Failed to load historical statistics.', e, st, tag: 'FluentSystemDb:load', hint: 'Check if the telemetry database file is locked or corrupted.');
      return [];
    }
  }

  /// Persists a batch of table statistics to the system telemetry database.
  ///
  /// This method is typically invoked by the [FluentEngine] during the
  /// periodic auto-save cycle or upon system shutdown.
  ///
  /// **Exceptions:**
  /// * Throws [FluentBaseException] if the disk write fails, allowing the caller
  ///   to decide whether to retry the batch or clear the operation.
  Future<void> saveStats(List<TableStats> statsList) async {
    if (statsList.isEmpty) return;

    await _ensureSystemDbOpen();
    if (_systemDb == null || !_systemDb!.isOpen) {
      FluentLog.error(
        'System database unavailable for saving stats.',
        FluentBaseException('System database unavailable for saving stats.'),
        StackTrace.current,
        tag: 'FluentSystemDb:save',
        hint: 'Telemetry data loss imminent. Check if FluentEngine was destroyed before saving operations.',
      );
      return;
    }

    try {
      await _systemStatsProvider.saveStatsBatch(_systemDb!, statsList);
    } catch (e, st) {
      final FluentBaseException exception = FluentBaseException('Critical failure while persisting telemetry batch.', st, e);
      FluentLog.error(exception.message, exception, exception.stackTrace, tag: 'FluentSystemDb:save', hint: 'Ensure disk space is available and database permissions are granted.');
      rethrow;
    }
  }

  /// Initializes the system telemetry database connection.
  ///
  /// This method ensures that the dedicated system database is mounted and ready for
  /// recording internal performance metrics. It is a safe, idempotent operation
  /// that can be called multiple times without side effects.
  ///
  /// **Internal Logic:**
  /// * Triggers [_ensureSystemDbOpen] to lazily mount the storage file.
  /// * Validates connection integrity before allowing further telemetry operations.
  Future<void> init() async => await _ensureSystemDbOpen();

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

    try {
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
          await db.rawQuery('PRAGMA journal_mode = WAL;');
        },
      );
    } catch (e, st) {
      _systemDb = null;

      FluentLog.error(
        'Critical failure while mounting telemetry database.',
        e,
        st,
        tag: 'FluentSystemDb:open',
        hint:
            'Verify disk space and application permissions for the database path: $systemDbPath. '
            'If the file is corrupted, it may require manual deletion.',
        context: {'path': systemDbPath},
      );
    }

    FluentLog.info('Permanent telemetry session connection to "$_systemDbName" successfully established.', tag: 'FluentSystemDb:open');
  }
}
