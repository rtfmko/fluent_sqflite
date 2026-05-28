// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_sqlite_internal.dart';

/// The entry point for the background Isolate worker.
///
/// Spawns the internal synchronous worker engine and sets up the primary
/// communication channel back to the Main Isolate via [mainSendPort].
void _fluentWorkerEntryPoint(SendPort mainSendPort) {
  _FluentWorker(mainSendPort)._start();
}

/// An internal engine running inside the background Isolate to handle heavy
/// database transactions, cascade relations parsing, and internal telemetry.
class _FluentWorker {
  /// Communication channel to send responses/streams back to the [FluentEngine] in Main Isolate.
  final SendPort _mainSendPort;

  /// Inbound communication channel for receiving requests from Main Isolate.
  SendPort? _replyPort;

  /// Cache of active SQLite database instances, mapped by their unique database name.
  final Map<String, Database> _databases = {};

  /// Global relational schema dictionary used to map and resolve nested entities during batch selections.
  Map<String, List<Map<String, dynamic>>> _relations = {};

  /// Dynamic hardware/software configuration overrides for each registered database.
  Map<String, Map<String, dynamic>> _dbConfigs = {};

  /// Thread-safe lookup buffer containing task IDs that were cancelled by the client while pending.
  final Set<int> _cancelledTasks = {};

  /// Volatile log buffer that aggregates runtime execution logs for the current task.
  ///
  /// Automatically flushed and cleared upon sending the final [IsolateStatus] payload.
  final List<String> _logBuffer = [];

  /// Dedicated database handle used exclusively for storing and reading internal metrics and table telemetry.
  Database? _systemDb;

  /// Low-level raw SQL queries provider for managing table metadata and counts.
  final SystemStatsProvider _systemStatsProvider = SystemStatsProvider();

  /// Creates a new background database worker isolate instance.
  _FluentWorker(this._mainSendPort);

  /// Starts the main event loop of the background isolate.
  ///
  /// Initializes the FFI database factory for desktop platforms, establishes
  /// the primary communication handshake with the Main Isolate, and listens
  /// continuously for incoming streaming requests.
  void _start() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // Set up communication channel: send the worker's inbound port back to Main Isolate
    final ReceivePort receivePort = ReceivePort();
    _mainSendPort.send(receivePort.sendPort);

    // Main isolate event loop processing streaming messages
    await for (final dynamic message in receivePort) {
      if (message is! Map<String, dynamic>) continue;

      final IsolateRequest request = IsolateRequest.fromMap(message);

      switch (request.cmd) {
        case IsolateCmd.init:
          await _handleInitCommand(request);
          break;

        case IsolateCmd.terminate:
          await _handleTerminateCommand();
          break;

        case IsolateCmd.execute:
          await _handleExecuteCommand(request);
          break;

        case IsolateCmd.cancel:
          final int? taskId = request.task?.id ?? (request.data is int ? request.data as int : null);
          if (taskId != null) {
            _cancelledTasks.add(taskId);
          }
          break;

        case IsolateCmd.none:
          break;

        case IsolateCmd.analyzeStats:
          await _handleAnalyzeStatsCommand(request);
          break;

        case IsolateCmd.saveStats:
          await _handleSaveStatsCommand(request);
          break;
      }
    }
  }

  /// Configures PRAGMA settings and opens multiple user database connections concurrently.
  ///
  /// Invoked strictly during the [IsolateCmd.init] phase.
  Future<void> _handleInitCommand(IsolateRequest request) async {
    _log('Initializing database engines cascade...');
    try {
      _replyPort = request.replyPort;

      final Map<String, dynamic> helperData = request.data is Map ? (request.data as Map).cast<String, dynamic>() : const <String, dynamic>{};
      final IsolateHelper helper = IsolateHelper.fromMap(helperData);

      _relations = helper.relationMap;
      _dbConfigs = helper.dbConfigs.cast<String, Map<String, dynamic>>();

      final List<String> dbNames = helper.dbPaths.keys.toList();
      final List<String> dbPaths = helper.dbPaths.values.toList();
      final Map<String, Map<String, dynamic>> dbConfigs = helper.dbConfigs;

      // Open all registered connections concurrently to reduce startup overhead
      final List<Database> openedDbs = await Future.wait(
        dbPaths.map(
          (path) => openDatabase(
            path,
            onConfigure: (db) async {
              final int index = dbPaths.indexOf(path);
              final String dbName = dbNames[index];

              final Map<String, dynamic>? currentCfg = dbConfigs[dbName];
              final int cacheSize = currentCfg?['cacheSize'] as int? ?? -2000;
              final bool tempStoreInMemory = currentCfg?['tempStoreInMemory'] as bool? ?? true;

              // Tune SQLite connection performance parameters
              await db.execute('PRAGMA cache_size = $cacheSize;');
              if (tempStoreInMemory) {
                await db.execute('PRAGMA temp_store = MEMORY;');
              }
            },
          ),
        ),
      );

      // Cache the opened connections mapping
      for (int i = 0; i < dbNames.length; i++) {
        _databases[dbNames[i]] = openedDbs[i];
      }

      _log('All core user databases successfully mounted.');
      _sendReplyToMain(const IsolateResponse(taskId: _systemId, status: IsolateStatus.warmupDone));
    } catch (e, st) {
      _log('CRITICAL: Database initialization failed: $e');
      _sendReplyToMain(IsolateResponse(taskId: _systemId, status: IsolateStatus.error, data: 'Database Initialization Failed: $e\nStack trace: $st', errorCode: '0x01'));
    }
  }

  /// Executes a clean teardown of the database worker environment.
  ///
  /// **Workflow:**
  /// 1. **Resource Release:** Iterates through all open [Database] instances to ensure
  ///    no file handles are left dangling or locked in a partial-transaction state.
  /// 2. **State Purge:** Clears internal caches, relational mappings, and task tracking
  ///    buffers to prevent memory leaks in the Isolate memory space.
  /// 3. **Telemetry Flush:** Appends the final shutdown status to the [_logBuffer]
  ///    and transmits the state back to the Main Isolate for auditability.
  Future<void> _handleTerminateCommand() async {
    _log('Initiating internal worker shutdown...');

    // Close all user database connections
    for (final Database db in _databases.values) {
      if (db.isOpen) await db.close();
    }
    _databases.clear();

    // Close system telemetry database
    if (_systemDb?.isOpen ?? false) {
      await _systemDb!.close();
    }

    // Purge volatile state
    _relations.clear();
    _dbConfigs.clear();
    _cancelledTasks.clear();

    _log('Worker shutdown complete. Clearing logs and state.');

    _sendReplyToMain(const IsolateResponse(taskId: _systemId, status: IsolateStatus.terminated));
  }

  /// Processes heavy read operations or structured joins within a distinct timeout threshold.
  ///
  /// Executed on [IsolateCmd.execute]. Validates tasks and invokes raw processing handlers.
  Future<void> _handleExecuteCommand(IsolateRequest request) async {
    final FluentTask? task = request.task;

    if (task == null || _getDbForTask(task.dbName) == null) {
      _log('Execution aborted: Target database or task payload is null.');
      _sendReplyToMain(IsolateResponse(taskId: task?.id ?? _systemId, status: IsolateStatus.error, data: 'Database not initialized or Task is null', errorCode: '0x02'));
      return;
    }

    _log('Executing task #${task.id} [${task.action.name}] targeting table "${task.table}"');

    try {
      // Execute the business query wrapped into a strict isolation timeout boundary
      await _processTask(task).timeout(task.policy.timeout!);
    } on TimeoutException catch (_) {
      _log('TIMEOUT: Task #${task.id} exceeded its duration budget of ${task.policy.timeout!.inSeconds}s');
      _sendReplyToMain(IsolateResponse(taskId: task.id, status: IsolateStatus.error, task: task, data: 'Isolate Execution Timeout: Exceeded allowed ${task.policy.timeout!.inSeconds}s'));
    } catch (e, st) {
      _log('ERROR: Processing exception on task #${task.id}: $e');
      _sendReplyToMain(IsolateResponse(taskId: task.id, status: IsolateStatus.error, task: task, data: '$e\n$st'));
    }
  }

  /// Triggers internal structural diagnostics across all database registers.
  ///
  /// Computes rows metrics via physical SELECT COUNT calls if metadata cache is missed.
  Future<void> _handleAnalyzeStatsCommand(IsolateRequest request) async {
    _log('Running lazy database metrics analysis cascade...');
    try {
      await _ensureSystemDbOpen();

      final List<TableStats> cachedRows = await _systemStatsProvider.readAllStats(_systemDb!);
      final List<Map<String, dynamic>> finalStatsPayload = [];

      final Map<String, TableStats> statsCacheMap = {for (var s in cachedRows) '${s.dbName}:${s.tableName}': s};

      _log('Executing live physical row scanning across active database configurations...');
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
            _log('Counted structural row limit for table "$tableName" -> $count');

            final String key = '$dbName:$tableName';
            final int relationsCount = relationsManifest[tableName] as int? ?? 0;

            final TableStats existingStats = statsCacheMap[key] ?? TableStats(dbName: dbName, tableName: tableName, relationsCount: relationsCount);

            existingStats.rowCount = count ?? 0;

            if (!statsCacheMap.containsKey(key)) {
              statsCacheMap[key] = existingStats;
            }

            updatedStatsToCache.add(existingStats);
          } catch (e) {
            _log('WARNING: Diagnostics failure on table "$tableName" inside database "$dbName": $e');
          }
        }
      }

      if (updatedStatsToCache.isNotEmpty) {
        await _systemStatsProvider.saveStatsBatch(_systemDb!, updatedStatsToCache);
        _log('Telemetry profiles successfully refreshed and synchronized to system storage.');
      }

      for (final TableStats stats in statsCacheMap.values) {
        finalStatsPayload.add(stats.buildJson());
      }

      _sendReplyToMain(IsolateResponse(taskId: request.task?.id ?? _systemId, status: IsolateStatus.analyzeDone, data: finalStatsPayload));
    } catch (e, st) {
      _log('CRITICAL: Live diagnostics pipeline crash: $e');
      _sendReplyToMain(IsolateResponse(taskId: request.task?.id ?? _systemId, status: IsolateStatus.error, data: 'Database Analysis failed: $e\n$st'));
    }
  }

  /// Flushes live runtime weight telemetry from Main isolate to the system database.
  Future<void> _handleSaveStatsCommand(IsolateRequest request) async {
    try {
      await _ensureSystemDbOpen();
      final List<dynamic> rawStats = request.data is List ? request.data as List : const [];

      if (rawStats.isNotEmpty) {
        final List<TableStats> statsToSave = rawStats.map((rawRow) {
          final Map<String, dynamic> rowMap = rawRow is Map ? rawRow.cast<String, dynamic>() : const <String, dynamic>{};
          return TableStats.fromMap(rowMap);
        }).toList();

        await _systemStatsProvider.saveStatsBatch(_systemDb!, statsToSave);
        _log('Synchronized ${statsToSave.length} table telemetry matrix profiles to system disk.');
      }

      _sendReplyToMain(IsolateResponse(taskId: request.task?.id ?? _systemId, status: IsolateStatus.saveDone));
    } catch (e, st) {
      _log('ERROR: Synchronization of statistics to disk failed: $e');
      _sendReplyToMain(IsolateResponse(taskId: request.task?.id ?? _systemId, status: IsolateStatus.error, data: 'Database Persist failed: $e\n$st'));
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

    _log('Mounting permanent telemetry storage database connection...');

    _systemDb = await openDatabase(
      systemDbPath,
      version: 1,
      onCreate: (db, _) async {
        _log('Telemetry system tables missing. Triggering schema initialization...');
        await _systemStatsProvider.createTable(db);
      },
      onConfigure: (db) async {
        // Apply high-performance WAL and light caching rules for background indexing
        await db.execute('PRAGMA journal_mode = WAL;');
        await db.execute('PRAGMA synchronous = NORMAL;');
        await db.execute('PRAGMA cache_size = -500;');
        await db.execute('PRAGMA temp_store = MEMORY;');
      },
    );

    _log('Permanent telemetry session connection to "$_systemDbName" successfully established.');
  }

  /// Orchestrates low-level physical query extraction and recursive relations hydration.
  ///
  /// Extracts flat record datasets from SQLite matching the [task] boundaries,
  /// maps them into mutable contexts, mounts deep nested relational dependencies,
  /// and streams the final entities back to Main Isolate using chunked microtask windows.
  Future<void> _processTask(FluentTask task) async {
    final Stopwatch sw = Stopwatch()..start();
    final String tableName = task.table;
    final int taskId = task.id;

    final Map<String, int> cascadeTimings = {};

    try {
      final Stopwatch flatQuerySw = Stopwatch()..start();

      // Execute primary flat database selection query
      final List<Map<String, dynamic>> rawRowsFromDb = await _getDbForTask(task.dbName)!.query(tableName, limit: task.helper?.limit, where: task.helper?.where, whereArgs: task.helper?.whereArgs);

      flatQuerySw.stop();

      // Bit-pack primary query performance metrics: duration (high 32 bits) and fetched row count (low 32 bits)
      cascadeTimings[tableName] = (flatQuerySw.elapsedMilliseconds << 32) | (rawRowsFromDb.length & 0xFFFFFFFF);

      // Early return if data layer holds no matches for the target query parameters
      if (rawRowsFromDb.isEmpty) {
        _log('No matching records found inside database for table "$tableName".');
        _sendReplyToMain(IsolateResponse(taskId: taskId, status: IsolateStatus.ok, task: task, executionTime: sw.elapsedMilliseconds, totalRows: 0));
        return;
      }

      // Check if task lifecycle was aborted before serialization routines
      if (_cancelledTasks.contains(taskId)) {
        _log('Task #$taskId dropped by supervisor before hydration pipeline.');
        _cancelledTasks.remove(taskId);
        return;
      }

      // Convert immutable database maps into explicit mutable collections
      final List<Map<String, dynamic>> writableRows = rawRowsFromDb.map((r) => Map<String, dynamic>.of(r)).toList(growable: false);
      final List<Map<String, dynamic>>? currentSchema = task.relations ?? _relations[tableName];

      // Mount cascade relationship models if the structural manifest definition exists
      if (currentSchema != null && currentSchema.isNotEmpty) {
        _log('Hydrating dependencies for "$tableName" (${writableRows.length} root records) via nested layout engine...');

        await _fillRelationsBatch(task.dbName, writableRows, currentSchema, maxDepth: task.maxDepth, currentDepth: 1, chunkSize: task.policy.chunkSize!, affectedTables: cascadeTimings);
      } else {
        _log('No downstream relation contracts found for table "$tableName" (Streaming flat array mappings).');
      }

      final int totalRows = writableRows.length;
      final int chunkSize = task.policy.chunkSize!;
      List<Map<String, dynamic>> currentChunk = [];

      // Partition unified mutated elements into microtask chunks to preserve frame rates
      for (int i = 0; i < totalRows; i++) {
        if (_cancelledTasks.contains(taskId)) {
          _log('Task #$taskId aborted during streaming loops serialization execution.');
          _cancelledTasks.remove(taskId);
          return;
        }

        currentChunk.add(writableRows[i]);

        // Emit current batch block once capacity matches the user-defined chunk size limit
        if (currentChunk.length >= chunkSize || i == totalRows - 1) {
          final bool isFinal = i == totalRows - 1;

          if (isFinal) {
            sw.stop();
            _log('Task #$taskId committed successfully: Total $totalRows items streamed over ${sw.elapsedMilliseconds}ms. Execution map: $cascadeTimings');
          }

          _sendReplyToMain(
            IsolateResponse(
              taskId: taskId,
              status: isFinal ? IsolateStatus.ok : IsolateStatus.progress,
              task: task,
              data: currentChunk,
              executionTime: isFinal ? sw.elapsedMilliseconds : 0,
              totalRows: totalRows,
              affectedTables: cascadeTimings,
            ),
          );

          currentChunk = [];

          // Yield execution priority back to message loops to prevent background blocking threads
          await Future<void>.delayed(Duration.zero);
        }
      }
    } catch (e, st) {
      _log('CRITICAL: Processing failure inside task loop execution execution: $e');
      _sendReplyToMain(IsolateResponse(taskId: task.id, status: IsolateStatus.error, task: task, data: 'SQLite Error: ${e.toString()}\nStack trace: $st'));
    }
  }

  /// Recursively hydrates child relationships for a collection of parent database rows.
  ///
  /// Extracts corresponding dependent records using optimized batched `IN` query clauses,
  /// maps them into nested structures based on the registered schema, and dynamically
  /// descends further down the relational hierarchy until [maxDepth] constraints are met.
  Future<void> _fillRelationsBatch(
    String? dbName,
    List<Map<String, dynamic>> parentRows,
    List<Map<String, dynamic>> schema, {
    required int maxDepth,
    required int currentDepth,
    required int chunkSize,
    required Map<String, int> affectedTables,
  }) async {
    final db = _getDbForTask(dbName);
    if (db == null || parentRows.isEmpty) return;

    // Stop execution early if the recursion boundary has been surpassed
    if (maxDepth != 0 && currentDepth > maxDepth) return;

    // Collect unique, non-null structural IDs from the parent dataset to filter children
    final List<dynamic> parentIds = parentRows.map((p) => p['id']).where((id) => id != null).toSet().toList(growable: false);

    if (parentIds.isEmpty) return;

    // Iterate through every relational dependency rule defined in the current schema block
    for (int s = 0; s < schema.length; s++) {
      final rel = schema[s];
      final String targetTable = rel['targetTable'] as String;
      final String remoteKey = rel['remoteKey'] as String;
      final String mapToKey = rel['mapKey'] as String;
      final bool isList = rel['isList'] as bool? ?? true;

      final List<Map<String, dynamic>> allChildren = [];

      final Stopwatch sw = Stopwatch()..start();

      // Chunk parent IDs to prevent SQLite parameter limits issues (maximum 999/32766 variables)
      for (int i = 0; i < parentIds.length; i += chunkSize) {
        final int end = (i + chunkSize > parentIds.length) ? parentIds.length : i + chunkSize;
        final List<dynamic> chunk = parentIds.sublist(i, end);

        final String placeholders = List.filled(chunk.length, '?').join(',');
        final List<Map<String, dynamic>> results = await db.query(targetTable, where: '$remoteKey IN ($placeholders)', whereArgs: chunk);

        allChildren.addAll(results);
      }

      // This isolates query parsing metrics from runtime CPU overheads (like map allocation and cascades).
      sw.stop();
      final int pureQueryElapsedMs = sw.elapsedMilliseconds;
      final int encodedCombined = affectedTables[targetTable] ?? 0;

      // Unpack accumulated metrics: duration (high 32 bits) and total processed rows (low 32 bits)
      int accumulatedMs = encodedCombined >> 32;
      int accumulatedRows = encodedCombined & 0xFFFFFFFF;

      // Aggregate performance data from the current cascade execution step
      accumulatedMs += pureQueryElapsedMs;
      accumulatedRows += allChildren.length;

      // Pack updated cumulative metrics back into a single 64-bit integer payload
      affectedTables[targetTable] = (accumulatedMs << 32) | (accumulatedRows & 0xFFFFFFFF);

      if (allChildren.isNotEmpty && (allChildren.length > 100 || pureQueryElapsedMs > 10)) {
        _log('Cascading join: "$targetTable" at depth $currentDepth (Collected ${allChildren.length} records in ${pureQueryElapsedMs}ms)');
      }

      // Handle structural empty states by injecting default empty collections or null references
      if (allChildren.isEmpty) {
        for (int i = 0; i < parentRows.length; i++) {
          parentRows[i][mapToKey] = isList ? <Map<String, dynamic>>[] : null;
        }
        continue;
      }

      // Determine if the child targets contain downstream nested layouts to process
      final List<Map<String, dynamic>>? nestedSchema = _relations[targetTable];
      final bool hasNested = nestedSchema != null && nestedSchema.isNotEmpty && (maxDepth == 0 || (currentDepth + 1) <= maxDepth);

      final Map<dynamic, List<Map<String, dynamic>>> groupedChildren = {};

      // Map children items into partitioned buckets linked by their parent reference key
      for (var i = 0; i < allChildren.length; i++) {
        final Map<String, dynamic> child = allChildren[i];
        final dynamic pId = child[remoteKey];

        // Clone map state to ensure mutability only if deeper down cascading steps are expected
        final Map<String, dynamic> readyChild = hasNested ? Map<String, dynamic>.of(child) : child;

        groupedChildren.putIfAbsent(pId, () => <Map<String, dynamic>>[]).add(readyChild);
      }

      // Recursively descend into deeper hierarchy branches if child schemas exist
      if (hasNested) {
        final List<Map<String, dynamic>> writableChildrenList = groupedChildren.values.expand((list) => list).toList(growable: false);

        // Pass the timings map reference further down the recursive cascade tree execution
        await _fillRelationsBatch(dbName, writableChildrenList, nestedSchema, maxDepth: maxDepth, currentDepth: currentDepth + 1, chunkSize: chunkSize, affectedTables: affectedTables);
      }

      // Inject fully hydrated blocks or atomic elements back into the parent rows reference pointers
      for (int i = 0; i < parentRows.length; i++) {
        final Map<String, dynamic> parent = parentRows[i];
        final dynamic pId = parent['id'];
        final List<Map<String, dynamic>> matches = groupedChildren[pId] ?? const [];

        parent[mapToKey] = isList ? matches : (matches.isNotEmpty ? matches.first : null);
      }
    }
  }

  /// Resolves and returns the active [Database] instance for a specific task.
  ///
  /// If only a single database is mounted in the runtime cluster, it automatically
  /// falls back to it as the default target. Otherwise, it performs a strict key lookup
  /// using the provided [dbName]. Returns `null` if no matching handler is found.
  Database? _getDbForTask(String? dbName) {
    // Optimization: If there is exactly one database available, bypass naming checks
    if (_databases.length == 1) {
      return _databases.values.first;
    }

    if (dbName != null && dbName.isNotEmpty) {
      final db = _databases[dbName];
      if (db != null) return db;
    }
    return null;
  }

  /// Dispatches the calculated [response] payload back to the supervisor engine.
  ///
  /// Automatically flushes and clears the volatile [_logBuffer] to ensure that
  /// transaction telemetry from prior operations does not leak into upcoming tasks.
  void _sendReplyToMain(IsolateResponse response) {
    final IsolateResponse responseWithLogs = response.copyWith(logs: List<String>.from(_logBuffer));
    _replyPort?.send(responseWithLogs.toMap());
    _logBuffer.clear();
  }

  /// Appends a new operational trace entry into the local context log buffer.
  ///
  /// Automatically embeds a highly precise timestamp cropped down to milliseconds
  /// using the `HH:mm:ss.SSS` format standard.
  void _log(String message) {
    // Extracts exact time slice (e.g., "20:25:52.8732") bypassing heavy external formatters
    final String timestamp = DateTime.now().toFluentTimestamp;
    _logBuffer.add('[$timestamp] [FluentWorker] $message');
  }
}
