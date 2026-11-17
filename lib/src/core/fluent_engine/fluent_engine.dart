// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// A table changed by a task besides its own (a related table, a cascade): provider, kind of change, known items.
@internal
typedef FluentTouchedTable = (FluentProvider provider, FluentDbAction action, List<Object?> items);

/// The task scheduler behind every provider call (a singleton, set up by `FluentDb.init`).
///
/// * **Queues per database, in call order.** A write is a barrier: it starts after every earlier task of its database,
///   runs alone, and nothing later overtakes it. Only the reads between two writes are reordered (aged priority, then
///   aged weight, then arrival), one per connection (more with a read pool).
/// * **Merging never changes the order of operations:** identical reads in flight are collapsed (fingerprint + write
///   epoch), adjacent saves of one table become one call, queued `findById` calls become one `IN (...)` query; a merged
///   batch that fails runs again call by call.
/// * **No timeouts:** a started task is never abandoned; [shutdown] fails only calls that did not start.
/// * **Telemetry:** task costs go to [FluentTableStatsTracker] (written to `__fluent_stats`), usage hints to
///   [FluentAnalyzer], and idle / write signals to [FluentTuner].
/// * **Change events:** every finished write publishes on [changeStream], also for tables it touched ([touch]).
class FluentEngine {
  /// The singleton instance of the [FluentEngine].
  static final FluentEngine _instance = FluentEngine._internal();

  /// Accesses the global [FluentEngine] instance.
  factory FluentEngine() => _instance;

  /// Private constructor for the singleton pattern.
  FluentEngine._internal();

  /// The completer of every queued or running call, by task id (one per call of a merged batch).
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  /// The settings of each database (`FluentGroup.config`), by database name.
  final Map<String, FluentDbConfig> _configs = {};

  /// Waiting tasks per database, in call order (the scheduler only looks at the head of each queue).
  final Map<String, List<FluentTask>> _queues = {};

  /// Number of writes queued per database so far: reads may share a result only within one epoch, so a read called
  /// after a write never gets the result of a read that ran before it.
  final Map<String, int> _writeEpochs = {};

  int get _queuedCount => _queues.values.fold(0, (sum, q) => sum + q.length);

  /// Whether new tasks are accepted (false between [shutdown] and the next [initMultiple]).
  bool _accepting = true;

  /// Incremented by [shutdown]: tasks of an older generation finishing later do not touch the new counters.
  int _generation = 0;

  /// Completed when the engine has nothing queued or running (see [_waitIdle]).
  Completer<void>? _idle;

  /// Zone key of the list collecting the tables a running task changes besides its own (see [touch]).
  static final Object _touchedKey = Object();

  /// Records that the running task changed [provider]'s table ([action], with [items] when known). The engine
  /// publishes one change event per touched table after the task — after the commit inside a transaction —
  /// so watchers of related tables (children, link targets, cascades) see the change too.
  @internal
  static void touch(FluentProvider provider, FluentDbAction action, [List<Object?> items = const []]) {
    (Zone.current[_touchedKey] as List<FluentTouchedTable>?)?.add((provider, action, items));
  }

  /// Runs [body] collecting the tables it touches into [into].
  @internal
  static Future<R> collectingTouched<R>(List<FluentTouchedTable> into, Future<R> Function() body) => runZoned(body, zoneValues: {_touchedKey: into});

  /// Zone key marking code that runs inside an engine task (also transaction bodies); its value is the task's
  /// [_RunningTask], which ends with the task (timers and listeners created inside keep the zone, not the mark).
  static final Object _runningTaskKey = Object();

  /// Whether the current code runs inside a running engine task or an open transaction.
  bool get _insideTask => isInsideTask;

  /// Whether the current code runs inside a running engine task or an open transaction (lifecycle calls refuse to wait for it).
  @internal
  bool get isInsideTask => ((Zone.current[_runningTaskKey] as _RunningTask?)?.running ?? false) || FluentTransactionScope.current != null;

  /// Whether the current code runs inside a running task of [dbName] (or one started from it) without that
  /// database's open transaction: a queued write of [dbName] would start only after that task, which waits for it.
  @internal
  bool holdsDatabase(String dbName) => (Zone.current[_runningTaskKey] as _RunningTask?)?.holds(dbName) ?? false;

  /// The zone each queued task was called from, by task id: the task runs in a copy of it without the library's own
  /// scopes (see [_taskZone]), never in the zone of whatever code happened to start it.
  final Map<int, Zone> _callerZones = {};

  /// Priorities raised by collapsed reads (task id -> priority), see [dispatch].
  final Map<int, int> _raisedPriority = {};

  /// The queued task answering each collapse key (to raise its priority).
  final Map<String, FluentTask> _collapseHeads = {};

  /// The result of each read in flight, by collapse key (fingerprint + write epoch): an identical read called meanwhile
  /// awaits it instead of running again (see [dispatch]).
  final Map<String, Future<dynamic>> _activeCollapses = {};

  /// The last task id handed out.
  int _idCounter = 0;

  /// Running reads per database (at most one per connection, see [readConnectionCount]).
  final Map<String, int> _activeReadsPerDb = {};

  /// Running writes per database (0 or 1: a write runs alone).
  final Map<String, int> _activeWritesPerDb = {};

  /// Whether the whole engine is paused: nothing starts until [resumeQueue] is called without a database.
  bool _isGlobalPaused = false;

  /// Completed when a global [pauseQueue] has drained the running tasks (its caller awaits it).
  Completer<void>? _globalPauseCompleter;

  /// Databases whose queue is paused: their tasks stay queued until [resumeQueue].
  final Set<String> _pausedDbs = {};

  /// Per database: completed when its [pauseQueue] has drained the running tasks (its caller awaits it).
  final Map<String, Completer<void>> _dbPauseCompleters = {};

  /// Timer of the next stats write (see [_maybeFlushStats]).
  Timer? _saveTimer;

  /// The stats flush that is running, if any (see [_flushStats]).
  Future<void>? _flushing;
  int _lastStatsFlush = -1 << 31;

  /// Shortest gap between two writes of the measured query costs (they are written only when changed, when the
  /// database is idle, and always on close). Tests shorten it.
  @visibleForTesting
  static Duration statsFlushInterval = const Duration(minutes: 5);

  /// Awaited by a stats write after it took the changes of a database and before it writes them (tests hold a flush
  /// open with it, to change the stats meanwhile).
  @visibleForTesting
  static Future<void> Function(String db)? statsWriteGate;

  /// Databases whose measured query costs are written to their own `__fluent_stats` table (not in-memory or read-only).
  final Set<String> _persistStats = {};

  /// How fast a waiting read gains on cheaper reads queued after it: its weight drops by this many points per second
  /// of waiting, so heavy reads never wait forever behind a stream of light ones.
  static const int _readAgingPerSecond = 200;

  /// Waiting time (ms) that raises the priority of a queued read by one point (see [_agedPriority]).
  static const int _priorityAgingMs = 1000;

  /// Increments and returns the next unique operation ID.
  int get _nextId => ++_idCounter;

  /// Monotonic clock for queue waiting times and aging.
  final Stopwatch _clock = Stopwatch()..start();

  /// Replaces the monotonic clock (milliseconds) of queue waiting times and aging (tests).
  @visibleForTesting
  static int Function()? clock;

  int get _nowMs => clock?.call() ?? _clock.elapsedMilliseconds;

  // Scheduler counters (see [stats]).
  int _startedTasks = 0;
  int _completedTasks = 0;
  int _collapsedReads = 0;
  int _mergedSaves = 0;
  int _batchedLookups = 0;
  int _splitBatches = 0;
  int _adoptedReads = 0;
  int _totalWaitMs = 0;
  int _maxWaitMs = 0;

  /// Number of relations per table, per database: adds to the weight of reads that load relations.
  final Map<String, Map<String, int>> _dbRelationsCount = {};

  /// The main (writable) connection of each database, by name.
  final Map<String, Database> _databases = {};

  /// Read-only connections per database (`FluentDbConfig.readConnections`) and the ones not lent right now.
  final Map<String, List<Database>> _readers = {};
  final Map<String, List<Database>> _freeReaders = {};

  /// Hands the read pool of [dbName] to the engine; reads then run on these connections, one read per connection.
  @internal
  void attachReaders(String dbName, List<Database> readers) {
    if (readers.isEmpty) return;
    _readers[dbName] = List.of(readers);
    _freeReaders[dbName] = List.of(readers);
    FluentLog.debug('Read pool attached', tag: 'FluentEngine:readers', context: {'db': dbName, 'connections': readers.length});
  }

  /// Number of read-only connections of [dbName] (0: reads use the main connection).
  @internal
  int readConnectionCount(String dbName) => _readers[dbName]?.length ?? 0;

  /// Closes the read pools. A connection a running read still borrows (a shutdown from inside a task does not wait)
  /// is closed by that read when it gives the connection back.
  Future<void> _closeReaders() async {
    final Set<Database> free = {for (final List<Database> list in _freeReaders.values) ...list};
    final List<Database> all = [for (final List<Database> list in _readers.values) ...list];
    _readers.clear();
    _freeReaders.clear();
    for (final Database db in all) {
      if (free.contains(db)) {
        await _closeReader(db);
      } else {
        _orphanReaders.add(db);
      }
    }
  }

  /// Borrowed read connections whose pool was closed: closed when their read ends.
  final Set<Database> _orphanReaders = Set.identity();

  Future<void> _closeReader(Database db) async {
    try {
      if (db.isOpen) await db.close();
    } catch (e) {
      FluentLog.issue(FluentIssueKind.closeFailed, 'A read connection could not be closed', tag: 'FluentEngine:readers', hint: 'Harmless: it is released with the app process.', error: e);
    }
  }

  final Map<String, Timer> _dbPauseTimers = {};
  Timer? _globalPauseTimer;

  /// Broadcast bus of the change events of every database.
  final StreamController<FluentChangeEvent<dynamic>> _changeEventBus = StreamController.broadcast();

  /// Every change event of every database (keyed by `dbName` + `table`); users subscribe through [FluentDb.onEvent]
  /// and the watch calls, which filter it.
  Stream<FluentChangeEvent<dynamic>> get changeStream => _changeEventBus.stream;

  /// The global settings (`FluentDb.init(config:)` / `FluentDb.configure`).
  FluentConfig _config = const FluentConfig();

  /// The global settings in use.
  @internal
  FluentConfig get config => _config;

  /// The settings of database [dbName] (`FluentGroup.config`), `null` before it was initialized.
  @internal
  FluentDbConfig? dbConfig(String dbName) => _configs[dbName];

  /// The diagnostics settings of database [dbName] (its `FluentDbConfig.diagnostics`, else the global ones).
  @internal
  FluentDiagnostics diagnosticsOf(String? dbName) => (dbName == null ? null : _configs[dbName]?.diagnostics) ?? _config.diagnostics;

  /// Calculates the sum of all currently active read operations across all databases.
  int get _globalActiveReads => _activeReadsPerDb.values.fold(0, (a, b) => a + b);

  /// Calculates the sum of all currently active write operations across all databases.
  int get _globalActiveWrites => _activeWritesPerDb.values.fold(0, (a, b) => a + b);

  /// Starts accepting tasks for the databases of [dbNameWithDb] (their main connections), replacing the previous
  /// settings, connections and read pools.
  ///
  /// * [configs]: the settings of each database.
  /// * [dbRelationsCount]: relations per table, added to the weight of reads that load relations.
  /// * [stats]: the measured query costs of each database (rows of its `__fluent_stats` table), loaded into
  ///   [FluentTableStatsTracker]; those of [persistStats] databases are written back when they change.
  Future<void> initMultiple({
    required Map<String, FluentDbConfig> configs,
    required Map<String, Map<String, int>> dbRelationsCount,
    required Map<String, Database> dbNameWithDb,
    Map<String, List<Map<String, Object?>>> stats = const {},
    Set<String> persistStats = const {},
  }) async {
    _accepting = true;
    _configs.clear();
    _dbRelationsCount.clear();
    _databases.clear();
    await _closeReaders();

    _configs.addAll(configs);
    _dbRelationsCount.addAll(dbRelationsCount);
    _databases.addAll(dbNameWithDb);

    _persistStats
      ..clear()
      ..addAll(persistStats);
    for (final String db in dbNameWithDb.keys) {
      FluentTableStatsTracker().discard(db);
      FluentTableStatsTracker().load(db, stats[db] ?? const []);
    }

    FluentLog.debug('FluentEngine: initialized', tag: 'FluentEngine:initMultiple', context: {'databases': dbNameWithDb.keys.toList()});

  }

  /// Starts the watchdog of a paused queue ([dbName], or all databases): after `FluentConfig.pauseWatchdog` the queue
  /// is resumed with a warning, so a forgotten `resumeQueue` never blocks the app; `null` keeps it paused.
  void _startPauseWatchdog({String? dbName}) {
    final Duration? timeout = _config.pauseWatchdog;
    if (timeout == null) return;

    final Timer timer = Timer(timeout, () {
      FluentLog.issue(
        FluentIssueKind.queueResumed,
        'The queue of ${dbName ?? 'all databases'} was paused longer than ${timeout.inSeconds} s and was resumed automatically',
        tag: 'FluentEngine:watchdog',
        hint: 'Call FluentDb.resumeQueue() when the paused work is done (in a finally block), or raise FluentConfig(pauseWatchdog: ...).',
      );
      resumeQueue(dbName: dbName);
    });

    if (dbName != null) {
      _dbPauseTimers[dbName]?.cancel();
      _dbPauseTimers[dbName] = timer;
    } else {
      _globalPauseTimer?.cancel();
      _globalPauseTimer = timer;
    }
  }

  /// Cancels the pause watchdog of [dbName] (or the global one).
  void _cancelPauseWatchdog({String? dbName}) {
    if (dbName != null) {
      _dbPauseTimers.remove(dbName)?.cancel();
    } else {
      _globalPauseTimer?.cancel();
      _globalPauseTimer = null;
    }
  }

  /// Makes the settings of the databases known before their schema sync (`init`), so hints raised while the schema is
  /// applied follow each database's own diagnostics; [initMultiple] replaces them. An empty map forgets them (a failed
  /// init).
  @internal
  void preloadDbConfigs(Map<String, FluentDbConfig> configs) {
    _configs
      ..clear()
      ..addAll(configs);
  }

  /// Applies the global settings (at `init` and on `FluentDb.configure`).
  void applyConfig(FluentConfig config) => _config = config;

  /// Pauses the queue of [dbName] (every database when `null`): queued and new tasks wait until [resumeQueue];
  /// completes when the tasks already running have finished (at once when none run).
  ///
  /// The pause watchdog (`FluentConfig.pauseWatchdog`) resumes a queue left paused too long, with a warning.
  /// Called from inside a running task or transaction, the pause would wait for itself: it is ignored and reported
  /// (`FluentIssueKind.ignoredCall`).
  Future<void> pauseQueue({String? dbName}) async {
    if (_insideTask) {
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        'pauseQueue was called from inside a running database task or transaction; the pause is cancelled.',
        tag: 'FluentEngine:pause',
        hint: 'A pause waits for the running tasks, including the one that asked for it, so it could never finish. '
            'Pause the queue before starting the task, or after it completed.',
        context: {'db': dbName ?? 'GLOBAL'},
      );
      return;
    }
    _startPauseWatchdog(dbName: dbName);
    if (dbName != null) {
      _pausedDbs.add(dbName);

      final int active = (_activeReadsPerDb[dbName] ?? 0) + (_activeWritesPerDb[dbName] ?? 0);

      if (active == 0) {
        FluentLog.debug('Queue for "$dbName" paused (Idle).', tag: 'FluentEngine:pause');
        return;
      }

      FluentLog.debug('Queue for "$dbName" pause: draining $active active tasks.', tag: 'FluentEngine:pause', context: {'db': dbName});

      _dbPauseCompleters[dbName] ??= Completer<void>();
      await _dbPauseCompleters[dbName]!.future;
    } else {
      _isGlobalPaused = true;
      final int totalActive = _globalActiveReads + _globalActiveWrites;

      if (totalActive == 0) {
        FluentLog.debug('Global engine paused (Idle).', tag: 'FluentEngine:pause');
        return;
      }

      FluentLog.debug('Global pause initiated: draining $totalActive tasks.', tag: 'FluentEngine:pause');

      _globalPauseCompleter ??= Completer<void>();
      await _globalPauseCompleter!.future;
    }
  }

  /// Ends the pause of [dbName] and starts its queued tasks. Without [dbName] it ends every pause, the global one and
  /// those of single databases (callers still waiting in [pauseQueue] stop waiting); the watchdogs are cancelled.
  void resumeQueue({String? dbName}) {
    if (dbName != null) {
      _cancelPauseWatchdog(dbName: dbName);
      _pausedDbs.remove(dbName);

      if (_dbPauseCompleters[dbName]?.isCompleted == false) {
        _dbPauseCompleters[dbName]!.complete();
      }
      _dbPauseCompleters.remove(dbName);

      FluentLog.debug('Queue for "$dbName" resumed.', tag: 'FluentEngine:queue');
    } else {
      _isGlobalPaused = false;
      _pausedDbs.clear();
      // A global resume ends every pause, also the ones of single databases (their callers stop waiting).
      for (final Completer<void> completer in _dbPauseCompleters.values) {
        if (!completer.isCompleted) completer.complete();
      }
      _dbPauseCompleters.clear();
      for (final Timer timer in _dbPauseTimers.values) {
        timer.cancel();
      }
      _dbPauseTimers.clear();
      _cancelPauseWatchdog();

      if (_globalPauseCompleter?.isCompleted == false) {
        _globalPauseCompleter!.complete();
      }
      _globalPauseCompleter = null;

      FluentLog.debug('Global queue resumed.', tag: 'FluentEngine:queue');
    }
    _processNext();
  }

  /// Called after every finished task: completes the pause of each paused database (and the global pause) that has no
  /// running task left, so its [pauseQueue] caller continues.
  void _checkPauseState() {
    if (_pausedDbs.isEmpty && !_isGlobalPaused) return;
    for (final String db in _pausedDbs.toList()) {
      if ((_activeReadsPerDb[db] ?? 0) == 0 && (_activeWritesPerDb[db] ?? 0) == 0) {
        if (_dbPauseCompleters[db]?.isCompleted == false) {
          _dbPauseCompleters[db]!.complete();
          FluentLog.debug('Queue for "$db" drained. Caller unblocked.', tag: 'FluentEngine:pause');
        }
        _dbPauseCompleters.remove(db);
      }
    }

    if (_isGlobalPaused) {
      if (_globalActiveReads == 0 && _globalActiveWrites == 0) {
        if (_globalPauseCompleter?.isCompleted == false) {
          _globalPauseCompleter!.complete();
          FluentLog.debug('Global engine drained. Caller unblocked.', tag: 'FluentEngine:pause');
        }
        _globalPauseCompleter = null;
      }
    }
  }

  /// Submits [task] and completes with its result.
  ///
  /// An identical read already in flight (same fingerprint) answers this one too, unless the policy sets
  /// `cancelIfDuplicate: false`; every caller gets its own copy of a list result, but the models in it are the same
  /// instances (changing a model changes it for every caller of the collapsed read). When the read is still queued it
  /// runs with the higher priority of the two calls.
  Future<dynamic> dispatch(FluentTask task) async {
    if (!_accepting) {
      throw FluentLog.raise(
        FluentCancelledException(
          'The database engine is closed: "${task.action.name}" on "${task.table}" was not run.',
          hint: 'The call came after FluentDb.close(). Call FluentDb.init(...) again before using the database.',
        ),
        tag: 'FluentEngine:dispatch',
      );
    }
    final bool canCollapse =
        (task.policy.cancelIfDuplicate ?? true) &&
        (task.action == FluentDbAction.find || task.action == FluentDbAction.findById || task.action == FluentDbAction.findMaps || task.action == FluentDbAction.count);
    if (!task.isWriteOp) _observe('onDispatch', () => FluentAnalyzer().onDispatch(task, _writeEpochs[task.dbName] ?? 0));
    if (!canCollapse) return _executeTaskInPipeline(task);

    final String key = '${task.fingerprint}#${_writeEpochs[task.dbName] ?? 0}';
    final Future<dynamic>? inFlight = _activeCollapses[key];
    if (inFlight != null) {
      _collapsedReads++;
      if (FluentLog.isOn(FluentLogLevel.debug)) FluentLog.debug('Answered by an identical read in flight', tag: 'FluentEngine:dispatch', context: {'table': task.table});
      // Still queued: it now runs for this caller too, so it gets the higher priority of both.
      final FluentTask? head = _collapseHeads[key];
      final int priority = task.policy.effectivePriority;
      if (head != null && _callerZones.containsKey(head.id) && priority > _priorityOf(head)) _raisedPriority[head.id] = priority;
      final Object? shared = await inFlight;
      if (shared is! List) return shared;
      // Every caller gets its own list; rows of findMaps are copied too (models are shared by design, see above).
      return task.action == FluentDbAction.findMaps ? <Map<String, dynamic>>[for (final Object? row in shared) Map<String, dynamic>.of((row! as Map).cast<String, dynamic>())] : shared.toList();
    }
    final Future<dynamic> execution = _executeTaskInPipeline(task, collapseKey: key);
    _activeCollapses[key] = execution;
    try {
      return await execution;
    } finally {
      _activeCollapses.remove(key)?.ignore(); // already awaited above
      _collapseHeads.remove(key);
    }
  }

  static FluentChangeEvent<dynamic> _event(FluentProvider provider, FluentDbAction action, List<dynamic> items, [Object? tag]) =>
      FluentChangeEvent<dynamic>(modelType: provider.modelType, table: provider.tableName, dbName: provider.dbName, kind: action.changeKind, items: items, tag: tag);

  /// Publishes an event of [action] on [provider]'s table without items and without running a task (used after a
  /// table or database was emptied outside the queue).
  void broadcastSystemAction(FluentDbAction action, FluentProvider provider) {
    if (!_changeEventBus.isClosed) {
      _changeEventBus.add(_event(provider, action, const <dynamic>[]));
      FluentLog.debug('System event broadcasted', tag: 'FluentEngine:broadcast', context: {'action': action.name, 'table': provider.tableName});
    }
  }

  /// Gives [task] an id and its scheduling weight, remembers the caller's zone (and the task as the head of
  /// [collapseKey]), queues it and completes with its result.
  Future<dynamic> _executeTaskInPipeline(FluentTask task, {String? collapseKey}) {
    final int id = _nextId;
    task = task.copyWith(id: id);
    _callerZones[id] = Zone.current;
    if (collapseKey != null) _collapseHeads[collapseKey] = task;

    // Calculate weight for priority ordering in the queue
    final int weight = _calculateFinalWeight(task);
    task.executionWeight = weight;

    final Completer<dynamic> completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    if (FluentLog.isOn(FluentLogLevel.debug)) FluentLog.debug('Queued ${task.action.name} on "${task.table}"', tag: 'FluentEngine:pipeline', context: {'taskId': id, 'weight': weight});

    _enqueue(task);

    return completer.future;
  }

  /// Appends [task] to the queue (arrival order is the order of the operations) and schedules.
  void _enqueue(FluentTask task) {
    task.enqueuedAt = _nowMs;
    final List<FluentTask> queue = _queues.putIfAbsent(task.dbName, () => [])..add(task);
    if (task.isWriteOp) _writeEpochs[task.dbName] = (_writeEpochs[task.dbName] ?? 0) + 1;
    _observe('onEnqueue', () => FluentAnalyzer().onEnqueue(task, queue.length));
    _processNext();
  }

  /// Starts every task that may run now. Per database:
  ///
  /// * **Writes are barriers.** A write starts only after every earlier task of its database finished, runs alone,
  ///   and no later task starts before it ended. So operations on the same data never change order, and a waiting
  ///   write cannot be starved by a stream of reads.
  /// * **Reads before the next write** may run together, one per connection (several only with a read pool), and
  ///   start in [_readOrder]: aged priority, then weight lowered by their waiting time, then arrival.
  /// * Adjacent saves of one table are merged, and queued `findById` calls of one table are answered by one
  ///   `IN (...)` query.
  void _processNext() {
    if (_isGlobalPaused) return;
    // Re-entered while the tasks of a pass start (an observer hook or a synchronous log sink called the database):
    // the tasks taken by that pass are not counted as running yet, so a pass now could start reads before a taken
    // write. The running pass schedules again once all of its tasks are counted.
    if (_starting) {
      _scheduleAgain = true;
      return;
    }

    final List<FluentTask> toStart = [];
    for (final MapEntry<String, List<FluentTask>> entry in _queues.entries) {
      final String db = entry.key;
      final List<FluentTask> tasks = entry.value;
      if (tasks.isEmpty || _pausedDbs.contains(db) || (_activeWritesPerDb[db] ?? 0) > 0) continue;
      final Set<FluentTask> taken = Set.identity();

      int activeReads = _activeReadsPerDb[db] ?? 0;

      if (tasks.first.isWriteOp) {
        if (activeReads > 0) continue; // the write waits for the running reads
        final List<FluentTask> parts = _adjacentSaves(tasks);
        tasks.removeRange(0, parts.length);
        toStart.add(parts.length == 1 ? parts.first : _mergedSave(parts));
        continue;
      }

      // One read per connection: several only with a read pool (one connection runs its statements in turn).
      // Checked before the queue is scanned: many waiting reads with full slots cost nothing per finished task.
      final int maxReads = math.max(1, readConnectionCount(db));
      if (activeReads >= maxReads) continue;
      final int barrier = tasks.indexWhere((t) => t.isWriteOp);
      final List<FluentTask> reads = tasks.sublist(0, barrier < 0 ? tasks.length : barrier);
      final Map<String, List<FluentTask>> lookups = _lookupGroups(reads);
      for (final FluentTask read in _best(reads, maxReads - activeReads, lookups)) {
        final List<FluentTask> group = read.action == FluentDbAction.findById ? [read, for (final FluentTask t in lookups[_lookupShape(read)]!) if (!identical(t, read)) t] : [read];
        if (group.length > 1) _batchedLookups += group.length;
        taken.addAll(group);
        toStart.add(group.length == 1 ? read : read.copyWith(mergedTasks: group));
        activeReads++;
      }
      tasks.removeWhere(taken.contains);
    }

    if (toStart.isEmpty) return;
    _starting = true;
    try {
      toStart.forEach(_dispatchToMain);
    } finally {
      _starting = false;
    }
    if (_scheduleAgain) {
      _scheduleAgain = false;
      _processNext();
    }
  }

  /// Whether [_processNext] is starting the tasks it took (see there).
  bool _starting = false;

  /// Whether [_processNext] was called while [_starting]: it runs again right after.
  bool _scheduleAgain = false;

  /// Order of reads that may run now: aged priority, then aged weight, then arrival.
  int _readOrder(FluentTask a, FluentTask b) {
    final int priority = _agedPriority(b).compareTo(_agedPriority(a));
    if (priority != 0) return priority;
    final int weight = _agedWeight(a).compareTo(_agedWeight(b));
    return weight != 0 ? weight : a.id.compareTo(b.id);
  }

  /// The priority of [task]: its policy's, or the higher one of an identical read that collapsed onto it.
  int _priorityOf(FluentTask task) => _raisedPriority[task.id] ?? task.policy.effectivePriority;

  /// [_priorityOf] raised by one point per second of waiting ([_priorityAgingMs]): a background read (-10) that
  /// waits behind a steady stream of urgent reads (+10) runs after about 20 s, it never starves.
  int _agedPriority(FluentTask task) => _priorityOf(task) + (_nowMs - task.enqueuedAt) ~/ _priorityAgingMs;

  /// The weight of [task] lowered by the time it has waited ([_readAgingPerSecond]).
  int _agedWeight(FluentTask task) => task.executionWeight - (_nowMs - task.enqueuedAt) * _readAgingPerSecond ~/ 1000;

  /// The save at the head of [tasks] and the saves right behind it with the same table, `saveStrategy`, `syncMode`,
  /// `syncWrite` and `conflictOn`.
  /// Only directly adjacent tasks are merged, so merging never changes the order of operations. A save that writes a
  /// row an earlier call of the batch writes too (same key, or same `conflictOn` value) ends the batch: one call
  /// writes a repeated key once, which would drop an earlier call's patch and give both callers one outcome. So does a
  /// save of a model instance an earlier call saves too (a double tap on a new model without a key yet): one call
  /// would insert it twice, the second save must update the row the first one inserted.
  List<FluentTask> _adjacentSaves(List<FluentTask> tasks) {
    final FluentTask head = tasks.first;
    if (head.action != FluentDbAction.save) return [head];
    final List<FluentTask> parts = [head];
    Set<String>? written; // match values of the rows of [parts], built when a second save is in sight
    final Set<Object?> saved = Set.identity(); // the model instances of [parts]
    List<String>? match;
    for (int i = 1; i < tasks.length; i++) {
      final FluentTask next = tasks[i];
      // Everything that changes how a save writes must be equal: one merged call runs with the head's settings.
      if (next.action != FluentDbAction.save ||
          next.table != head.table ||
          next.helper?.saveStrategy != head.helper?.saveStrategy ||
          next.helper?.syncMode != head.helper?.syncMode ||
          next.helper?.syncWrite != head.helper?.syncWrite ||
          !listEquals(next.helper?.conflictOn, head.helper?.conflictOn)) {
        break;
      }
      match ??= head.helper?.conflictOn ?? FluentDbInternals.lookupByTable(head.table, head.dbName)?.keyColumnNames.toList();
      if (match == null) break;
      written ??= _matchKeys(head, match);
      final Set<String>? own = _matchKeys(next, match);
      if (own == null || written == null || own.any(written.contains)) break;
      if (saved.isEmpty) saved.addAll(_itemsOf(head));
      final List<Object?> items = _itemsOf(next);
      if (items.any(saved.contains)) break;
      saved.addAll(items);
      written.addAll(own);
      parts.add(next);
    }
    return parts;
  }

  /// The items [task] saves.
  static List<Object?> _itemsOf(FluentTask task) => task.data is List ? task.data as List : [task.data];

  /// The values of the [match] columns of every row [task] saves, as the row writer writes them (a key generated by an
  /// earlier insert or replaced by a `conflictOn` match, kept by the library, counts too); rows without them insert
  /// new keys and are left out. `null` when an item is not a model or its `buildJson` throws, so the task is not
  /// merged (it then runs alone and fails through the executor's error handling, never inside the scheduler).
  static Set<String>? _matchKeys(FluentTask task, List<String> match) {
    final Set<String> keys = {};
    for (final Object? item in _itemsOf(task)) {
      if (item is! FluentStorable) return null;
      final Map<String, dynamic> json;
      try {
        json = item.buildJson();
      } catch (_) {
        return null; // user code; the save reports the error when it runs
      }
      final List<Object?> values = [for (final String c in match) item.keyValueOf(c, json[c])];
      if (values.contains(null)) continue;
      keys.add(values.map(fluentValueKey).join('|'));
    }
    return keys;
  }

  /// One task saving the items of all [parts] (the results are split back per part).
  FluentTask _mergedSave(List<FluentTask> parts) {
    _mergedSaves += parts.length;
    final List<dynamic> items = [
      for (final FluentTask part in parts)
        if (part.data is List) ...part.data as List else if (part.data != null) part.data,
    ];
    FluentLog.debug('Merged adjacent saves', tag: 'FluentEngine:batching', context: {'table': parts.first.table, 'calls': parts.length, 'items': items.length});
    return parts.first.copyWith(data: items, mergedTasks: parts);
  }

  /// What `findById` calls must share to be answered by one `IN (...)` query: table, relations and visibility.
  static String _lookupShape(FluentTask t) => '${t.table}|${t.maxDepth}|${t.ignoreLazy}|${t.helper?.where}|${t.helper?.whereArgs}';

  /// The queued `findById` calls of [reads] by [_lookupShape] (one pass).
  static Map<String, List<FluentTask>> _lookupGroups(List<FluentTask> reads) {
    final Map<String, List<FluentTask>> groups = {};
    for (final FluentTask t in reads) {
      if (t.action == FluentDbAction.findById) (groups[_lookupShape(t)] ??= []).add(t);
    }
    return groups;
  }

  /// The next [slots] reads to start, in [_readOrder]; a lookup stands for its whole group, so a group is picked once.
  /// Picks without sorting the whole queue (slots are few, the queue may hold thousands of calls).
  List<FluentTask> _best(List<FluentTask> reads, int slots, Map<String, List<FluentTask>> lookups) {
    final List<FluentTask> picked = [];
    final Set<FluentTask> out = Set.identity();
    while (picked.length < slots) {
      FluentTask? best;
      for (final FluentTask t in reads) {
        if (out.contains(t)) continue;
        if (best == null || _readOrder(t, best) < 0) best = t;
      }
      if (best == null) break;
      picked.add(best);
      out.addAll(best.action == FluentDbAction.findById ? lookups[_lookupShape(best)]! : [best]);
    }
    return picked;
  }

  /// Starts the watchdog of a user transaction (see `FluentConfig.transactionWatchdog`); `null` when it is off.
  @internal
  Timer? watchTransaction(FluentTransactionScope scope) {
    final Duration? after = _config.transactionWatchdog;
    if (after == null) return null;
    bool warned = false;
    return Timer.periodic(after, (timer) {
      final List<FluentTask>? queue = _queues[scope.dbName];
      if (queue == null || queue.isEmpty) return;
      final int barrier = queue.indexWhere((t) => t.isWriteOp);
      final List<FluentTask> reads = queue.sublist(0, barrier < 0 ? queue.length : barrier);
      final int writes = queue.where((t) => t.isWriteOp).length;
      if (!warned) {
        warned = true;
        FluentLog.issue(
          FluentIssueKind.transactionWatchdog,
          'A transaction on "${scope.dbName}" has run for ${after.inMilliseconds * timer.tick} ms while ${queue.length} call(s) wait for it'
          '${reads.isEmpty ? '' : '; ${reads.length} waiting read(s) now run inside the transaction and see its uncommitted changes'}'
          '${writes == 0 ? '' : '; $writes write(s) keep waiting for its end'}.',
          database: scope.dbName,
          tag: 'FluentEngine:transaction',
          hint: 'Keep transactions short (no network or UI waits inside). If the transaction awaits a database call made outside '
              'it (a Future created before or beside it), that call waits behind the transaction: make the call inside '
              'FluentDb.transaction(...), or await it before. Reads are let in after FluentConfig.transactionWatchdog '
              'so they never deadlock; if they roll back, those reads saw data that was never committed.',
          context: {'db': scope.dbName, 'reads': reads.length, 'writes': writes},
        );
      }
      if (scope.closed) return; // the body ended: nothing may start on this transaction any more
      for (final FluentTask read in reads) {
        queue.remove(read);
        _adoptedReads++;
        final Zone caller = _callerZones.remove(read.id) ?? Zone.current;
        _raisedPriority.remove(read.id);
        // Counted as a running read, so whenIdle / settle / shutdown wait for it too.
        _activeReadsPerDb[read.dbName] = (_activeReadsPerDb[read.dbName] ?? 0) + 1;
        final int generation = _generation;
        final Future<void> running = _runInTransaction(read, scope, caller).whenComplete(() {
          _completedTasks++;
          _finalizeTaskCompletion(read.dbName, false, generation);
        });
        // The transaction waits for it before it commits (a read of several statements never hits a closed one).
        scope.adopt(running);
      }
    });
  }

  /// Runs a queued [task] directly in the open transaction of [scope], in the zone of its [caller] (trash scope, ...),
  /// and completes its caller.
  Future<void> _runInTransaction(FluentTask task, FluentTransactionScope scope, Zone caller) async {
    final Stopwatch sw = Stopwatch()..start();
    final _RunningTask mark = _RunningTask(task.dbName, caller[_runningTaskKey] as _RunningTask?);
    try {
      final FluentProvider provider = FluentDbInternals.providerForTable(task.table, dbName: task.dbName);
      final Object? result = await _taskZone(caller, mark, null).run(() => scope.run(() => provider.internalExecute(task)));
      _observe('record', () => FluentTableStatsTracker().record(task, sw.elapsedMilliseconds, rows: _rowsOf(result)));
      _pendingRequests.remove(task.id)?.complete(result);
    } catch (e, s) {
      _failTaskOrBatch(task, e, s);
    } finally {
      mark.running = false;
    }
  }

  bool _observerFailureReported = false;

  /// Called with the name of each observer hook right before it runs (`onDispatch`, `onEnqueue`, `onStart`, `onDone`,
  /// `onFinish`, `record`, `recordFailure`, `forget`, `tunerWrite`, `tunerIdle`, `flushStats`); a test makes it throw to
  /// check that a failing hook never changes what the tasks do.
  @visibleForTesting
  static void Function(String hook)? observerProbe;

  /// Runs an observer hook (analyzer, statistics) on the scheduling path: a failing hook never stops tasks from starting
  /// or leaves callers waiting; the first failure is reported once.
  void _observe(String name, void Function() hook) {
    try {
      observerProbe?.call(name);
      hook();
    } catch (e, s) {
      if (_observerFailureReported) return;
      _observerFailureReported = true;
      FluentLog.report(e, stackTrace: s, tag: 'FluentEngine:observer');
    }
  }

  /// Marks [task] as running and executes it.
  void _dispatchToMain(FluentTask task) {
    final String db = task.dbName;
    if (task.isWriteOp) {
      _activeWritesPerDb[db] = (_activeWritesPerDb[db] ?? 0) + 1;
    } else {
      _activeReadsPerDb[db] = (_activeReadsPerDb[db] ?? 0) + 1;
    }
    final int now = _nowMs;
    Zone? caller;
    for (final FluentTask part in task.isBatched ? task.mergedTasks! : [task]) {
      final Zone? zone = _callerZones.remove(part.id);
      caller ??= zone;
      _raisedPriority.remove(part.id);
      final int waited = now - part.enqueuedAt;
      _startedTasks++;
      _totalWaitMs += waited;
      if (waited > _maxWaitMs) _maxWaitMs = waited;
      _observe('onStart', () => FluentAnalyzer().onStart(part, waited));
    }
    final int generation = _generation;
    // A read borrows a pooled read-only connection (it never starts before an earlier write committed).
    final List<Database>? free = task.isWriteOp ? null : _freeReaders[db];
    final Database? reader = free == null || free.isEmpty ? null : free.removeLast();
    final Zone base = caller ?? Zone.current;
    final _RunningTask mark = _RunningTask(db, base[_runningTaskKey] as _RunningTask?);
    void done() {
      mark.running = false;
      _observe('onDone', () => FluentAnalyzer().onDone(task, _nowMs - now));
      _completedTasks += task.isBatched ? task.mergedTasks!.length : 1;
      if (reader != null && (_readers[db]?.contains(reader) ?? false)) {
        _freeReaders[db]!.add(reader);
      } else if (reader != null && _orphanReaders.remove(reader)) {
        unawaited(_closeReader(reader)); // its pool was closed while this read ran
      }
      _finalizeTaskCompletion(db, task.isWriteOp, generation);
    }

    // Started and finished in the caller's zone without the library's scopes: code continuing from another task
    // (a read's connection, a transaction, a running mark) never leaks into this one or into what `done` starts.
    _taskZone(base, mark, reader == null ? null : FluentReadScope._(db, reader)).run(() {
      _executeInMain(task).then((_) => done(), onError: (Object _) => done());
    });
  }

  /// A copy of [base] for one task: marked as running ([mark]), with the task's read connection ([read], or none),
  /// and without the deferred logging or touched-table collector of the code that called it. Of the caller's open
  /// transactions only the one of the task's own database is removed: a transaction on another database the task was
  /// called from stays visible, so a write to it joins it instead of queueing behind it (which would wait forever).
  static Zone _taskZone(Zone base, _RunningTask mark, FluentReadScope? read) => base.fork(
    zoneValues: {
      _runningTaskKey: mark,
      FluentReadScope._zoneKey: read,
      FluentTransactionScope._zoneKey: FluentTransactionScope._withoutDb(base, mark.dbName),
      FluentLog.deferKey: null,
      _touchedKey: null,
    },
  );

  /// A snapshot of the queue and scheduler counters.
  FluentEngineStats get stats => FluentEngineStats(
    queued: _queuedCount,
    activeReads: _globalActiveReads,
    activeWrites: _globalActiveWrites,
    completed: _completedTasks,
    collapsedReads: _collapsedReads,
    mergedSaves: _mergedSaves,
    batchedLookups: _batchedLookups,
    splitBatches: _splitBatches,
    adoptedReads: _adoptedReads,
    averageWaitMs: _startedTasks == 0 ? 0 : _totalWaitMs / _startedTasks,
    maxWaitMs: _maxWaitMs,
    slowestQueries: FluentTableStatsTracker().slowest(),
  );

  /// Releases the slot of a finished task (unless the engine was reset meanwhile) and schedules the next ones.
  void _finalizeTaskCompletion(String dbName, bool wasWrite, int generation) {
    if (generation != _generation) return;
    if (wasWrite) {
      _activeWritesPerDb[dbName] = math.max(0, (_activeWritesPerDb[dbName] ?? 1) - 1);
    } else {
      _activeReadsPerDb[dbName] = math.max(0, (_activeReadsPerDb[dbName] ?? 1) - 1);
    }
    _checkPauseState();
    _processNext();
    _checkIdle();
    _observe('flushStats', _maybeFlushStats);
    if (wasWrite) _observe('tunerWrite', () => FluentTuner().onWrite(dbName));
    if (_isIdle(dbName)) _observe('tunerIdle', () => FluentTuner().onIdle(dbName));
  }

  /// Completes [_idle] when nothing is queued or running.
  void _checkIdle() {
    if (_idle != null && _queuedCount == 0 && _globalActiveReads == 0 && _globalActiveWrites == 0) {
      _idle!.complete();
      _idle = null;
    }
  }

  /// Whether nothing is queued or running (the test package's `settle`).
  bool get isIdle => _queuedCount == 0 && _globalActiveReads == 0 && _globalActiveWrites == 0;

  /// Waits until every queued and running task has finished, at most [timeout]; returns whether it did (the test
  /// package's `settle`).
  Future<bool> whenIdle(Duration timeout) => _waitIdle(timeout);

  /// Waits until every queued and running task has finished, at most [timeout] (no limit when `null`); returns
  /// whether it did.
  Future<bool> _waitIdle(Duration? timeout) async {
    if (_queuedCount == 0 && _globalActiveReads == 0 && _globalActiveWrites == 0) return true;
    _idle ??= Completer<void>();
    if (timeout == null) {
      await _idle!.future;
      return true;
    }
    try {
      await _idle!.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Writes changed query costs of idle databases to their `__fluent_stats` table, at most once per
  /// [statsFlushInterval]; called after every finished task. Nothing is written while nothing changed.
  void _maybeFlushStats() {
    // Cheap checks first: this runs after every task.
    if (_flushing != null || !_accepting || _saveTimer != null || _persistStats.isEmpty || !FluentTableStatsTracker().hasChanges) return;
    final int wait = _lastStatsFlush + statsFlushInterval.inMilliseconds - _nowMs;
    if (wait > 0) {
      _saveTimer = Timer(Duration(milliseconds: wait), () {
        _saveTimer = null;
        _maybeFlushStats();
      });
      return;
    }
    if (_hasStatsToWrite) unawaited(_flushStats(onlyIdle: true));
  }

  bool get _hasStatsToWrite => FluentTableStatsTracker().dirtyDatabases.any(_persistStats.contains);

  bool _isIdle(String db) => (_queues[db]?.isEmpty ?? true) && (_activeReadsPerDb[db] ?? 0) == 0 && (_activeWritesPerDb[db] ?? 0) == 0;

  /// Writes the changed query costs of every database (only idle ones with [onlyIdle]) in one small transaction each.
  /// Changes of databases that are not written ([_persistStats]) are dropped.
  ///
  /// A flush while another one runs: an idle flush is skipped (the running one writes), a full flush waits for it and
  /// then writes what changed meanwhile, so the close never loses measurements nor races the running flush.
  Future<void> _flushStats({required bool onlyIdle}) async {
    while (_flushing != null) {
      if (onlyIdle) return;
      await _flushing;
    }
    if (onlyIdle && !_accepting) return;
    final Completer<void> flushing = Completer<void>();
    _flushing = flushing.future;
    try {
      await _writeStats(onlyIdle: onlyIdle);
    } finally {
      _flushing = null;
      flushing.complete();
      if (_accepting) _observe('flushStats', _maybeFlushStats); // a timer that fired during this flush was dropped: arm it again
    }
  }

  Future<void> _writeStats({required bool onlyIdle}) async {
    final FluentTableStatsTracker tracker = FluentTableStatsTracker();
    _lastStatsFlush = _nowMs;
    for (final String db in tracker.dirtyDatabases) {
      final Database? database = _databases[db];
      if (!_persistStats.contains(db) || database == null || !database.isOpen) {
        tracker.takeChanges(db); // in-memory / read-only: kept in memory only
        continue;
      }
      if (onlyIdle && !_isIdle(db)) continue; // busy: the next flush
      final ({List<Map<String, Object?>> upserts, List<String> deletes}) changes = tracker.takeChanges(db);
      await statsWriteGate?.call(db);
      try {
        await database.transaction((txn) async {
          final Batch batch = txn.batch();
          // Deletes first: a shape forgotten and measured again since the last flush is in both lists, and its
          // current row must win.
          for (final String key in changes.deletes) {
            batch.delete(FluentTableStatsTracker.table, where: 'key = ?', whereArgs: [key]);
          }
          for (final Map<String, Object?> row in changes.upserts) {
            batch.insert(FluentTableStatsTracker.table, row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await batch.commit(noResult: true);
        });
      } catch (e) {
        tracker.restoreChanges(db, changes);
        FluentLog.debug('Query stats of "$db" not saved, retried later: $e', tag: 'FluentEngine:stats');
      }
    }
  }

  /// Runs a started [task] (no time limit) and completes its caller(s).
  ///
  /// 1. **Telemetry:** times the task for the cost model and the analyzer (which decides about slow-query hints).
  /// 2. **Change Propagation:** publishes change events on [_changeEventBus] (also for touched tables); a listener
  ///    that throws reports to its own zone and never fails the call.
  /// 3. **Errors** go to the caller (logged once by the provider call) and to the cost model.
  ///
  /// A merged batch completes every call with its own share of the result; when it fails, its calls run again one by
  /// one ([_runSeparately]), so only the failing call gets the error.
  Future<dynamic> _executeInMain(FluentTask task) async {
    final String tableName = task.table;

    // A user transaction: its body runs here while the task holds the database's write slot.
    if (task.action == FluentDbAction.transaction) {
      try {
        final Object? result = await (task.data! as Future<Object?> Function())();
        _pendingRequests.remove(task.id)?.complete(result);
        return result;
      } catch (e, s) {
        _pendingRequests.remove(task.id)?.completeError(e, s);
        rethrow;
      }
    }

    final Stopwatch sw = Stopwatch()..start();
    if (task.action == FluentDbAction.clearDatabase) {
      try {
        _observe('forget', () => FluentTableStatsTracker().forget(db: task.dbName));
        final bool cleared = await _clearDatabase(task);
        _pendingRequests.remove(task.id)?.complete(cleared);
        return cleared;
      } catch (e, s) {
        _pendingRequests.remove(task.id)?.completeError(e, s); // the caller must never wait forever
        rethrow;
      }
    }

    final FluentProvider provider;
    try {
      provider = FluentDbInternals.providerForTable(tableName, dbName: task.dbName);
    } catch (e) {
      _failTaskOrBatch(task, e);
      rethrow;
    }

    final List<FluentTouchedTable> touched = [];
    final dynamic result;
    try {
      result = await collectingTouched(touched, () => provider.internalExecute(task));
    } catch (e, s) {
      if (task.isBatched) return _runSeparately(task, provider, e);
      // Logged once with its hint by the provider call (FluentProvider.internalExecute).
      FluentLog.debug('Task failed: ${e.runtimeType}', tag: 'FluentEngine:main_track', context: {'table': tableName, 'action': task.action.name});
      _failTaskOrBatch(task, e, s);
      rethrow;
    }

    // The work is committed: what follows (events, stats, hints) never runs the calls again, and every caller is
    // completed even when it fails.
    try {
      sw.stop();
      final int elapsedMs = sw.elapsedMilliseconds;

      _observe('onFinish', () => FluentAnalyzer().onFinish(task, provider, elapsedMs, result));
      if (elapsedMs >= FluentAnalyzer.slowReadMs) {
        FluentLog.debug('"${task.action.name}" on "$tableName" took $elapsedMs ms', tag: 'FluentEngine:main_track', context: {'batched': task.isBatched, 'depth': task.maxDepth});
      }

      if (task.isBatched) {
        _completeMerged(task, provider, result, elapsedMs);
        // Related tables changed by the whole batch: the tag only when every call shares it.
        final Set<Object?> tags = {for (final FluentTask part in task.mergedTasks!) part.tag};
        publishTouched(task, provider, touched, keepTag: tags.length == 1);
      } else {
        if (task.isStreamOp) publishChange(task, provider, result);
        publishTouched(task, provider, touched);
        if (task.action == FluentDbAction.clearTable) {
          _observe('forget', () => FluentTableStatsTracker().forget(db: task.dbName, table: tableName));
          _observe('record', () => FluentTableStatsTracker().record(task, elapsedMs));
        } else if (task.action == FluentDbAction.wipeAll) {
          _observe('forget', () => FluentTableStatsTracker().forget());
        } else {
          _observe('record', () => FluentTableStatsTracker().record(task, elapsedMs, rows: _rowsOf(result)));
        }
        _pendingRequests.remove(task.id)?.complete(result);
      }
    } catch (e, s) {
      FluentLog.report(
        FluentEngineException(
          'The bookkeeping after "${task.action.name}" on "$tableName" failed; the write itself is done.',
          hint: 'The data was written. This is a bug of fluent_sqflite or of a change listener; please report it with the cause.',
          cause: e,
          stackTrace: s,
        ),
        tag: 'FluentEngine:main_track',
      );
      if (task.isBatched) {
        for (final FluentTask part in task.mergedTasks!) {
          final Completer<dynamic>? c = _pendingRequests.remove(part.id);
          if (c != null && !c.isCompleted) c.completeError(FluentEngineException('The result of this call could not be handed back, but its write is done.', hint: 'Read the rows again to get their current state.', cause: e), s);
        }
      } else {
        final Completer<dynamic>? c = _pendingRequests.remove(task.id);
        if (c != null && !c.isCompleted) c.complete(result);
      }
    }
    return result;
  }

  /// Publishes the change event of a finished write [task] on [provider]'s table.
  ///
  /// Called right after the task for queued writes (once per call of a merged batch, with that call's items and tag),
  /// and after the commit for writes made inside [FluentDb.transaction] (rolled-back writes publish nothing).
  /// A write that changed nothing ([result] `0`, or only skipped rows) publishes nothing either.
  @internal
  void publishChange(FluentTask task, FluentProvider provider, Object? result) {
    if (result == 0 || (result is List<FluentRowOutcome> && result.every((o) => o == FluentRowOutcome.skipped))) return;
    // The bus is never closed and delivers asynchronously: a listener that throws reports to its own zone, never here.
    final List<dynamic> items = task.data is List ? List<dynamic>.from(task.data as List) : [?task.data];
    _changeEventBus.add(_event(provider, task.action, items, task.tag));
  }

  /// Publishes one change event per table in [touched] (grouped by table and action), except the task's own
  /// table and action, which [publishChange] already covers.
  @internal
  void publishTouched(FluentTask task, FluentProvider provider, List<FluentTouchedTable> touched, {bool keepTag = true}) {
    if (touched.isEmpty) return;
    final Map<(FluentProvider, FluentDbAction), List<Object?>> grouped = {};
    for (final (FluentProvider p, FluentDbAction action, List<Object?> items) in touched) {
      if (identical(p, provider) && action == task.action) continue;
      grouped.putIfAbsent((p, action), () => []).addAll(items);
    }
    for (final MapEntry<(FluentProvider, FluentDbAction), List<Object?>> e in grouped.entries) {
      _changeEventBus.add(_event(e.key.$1, e.key.$2, e.value, keepTag ? task.tag : null));
    }
  }

  /// Completes every call of a merged [batch] with its own share of [result] and publishes its own event.
  void _completeMerged(FluentTask batch, FluentProvider provider, Object? result, int elapsedMs) {
    final List<FluentTask> parts = batch.mergedTasks!;
    final bool lookups = batch.action == FluentDbAction.findById;
    final int total = lookups ? parts.length : math.max(1, batch.data is List ? (batch.data as List).length : 1);
    int offset = 0;
    for (int k = 0; k < parts.length; k++) {
      final FluentTask part = parts[k];
      final Object? partResult;
      if (batch.action == FluentDbAction.findById) {
        partResult = (result! as List)[k];
      } else {
        final int count = part.data is List ? (part.data as List).length : (part.data == null ? 0 : 1);
        partResult = (result! as List).sublist(offset, offset + count);
        offset += count;
      }
      if (part.isStreamOp) publishChange(part, provider, partResult);
      // The time is shared by item count (the tracker divides a write's time by its items again), so every row costs
      // the same whatever the size of its call; a lookup batch has one item per call.
      final int items = lookups ? 1 : (part.data is List ? (part.data as List).length : (part.data == null ? 0 : 1));
      _observe('record', () => FluentTableStatsTracker().record(part, (elapsedMs * items / total).round()));
      _pendingRequests.remove(part.id)?.complete(partResult);
    }
  }

  /// The number of rows a read returned (a list or a page), `null` for other results.
  static int? _rowsOf(Object? result) => switch (result) {
    final List<Object?> rows => rows.length,
    final FluentPage<FluentStorable> page => page.items.length,
    _ => null,
  };

  /// A merged [batch] failed: runs its calls one by one, so only the call that causes the error fails.
  Future<void> _runSeparately(FluentTask batch, FluentProvider provider, Object error) async {
    _splitBatches++;
    FluentLog.debug('Merged batch failed; running its calls one by one', tag: 'FluentEngine:batching', context: {'table': batch.table, 'calls': batch.mergedTasks!.length, 'error': error.runtimeType.toString()});
    for (final FluentTask part in batch.mergedTasks!) {
      final Stopwatch sw = Stopwatch()..start();
      try {
        final List<FluentTouchedTable> touched = [];
        final Object? result = await collectingTouched(touched, () => provider.internalExecute(part));
        if (part.isStreamOp) publishChange(part, provider, result);
        publishTouched(part, provider, touched);
        _observe('record', () => FluentTableStatsTracker().record(part, sw.elapsedMilliseconds, rows: _rowsOf(result)));
        _pendingRequests.remove(part.id)?.complete(result);
      } catch (e, s) {
        _observe('recordFailure', () => FluentTableStatsTracker().recordFailure(part));
        _pendingRequests.remove(part.id)?.completeError(e, s);
      }
    }
  }

  /// Completes the caller(s) of [task] with [error].
  void _failTaskOrBatch(FluentTask task, Object error, [StackTrace? stackTrace]) {
    for (final FluentTask part in task.isBatched ? task.mergedTasks! : [task]) {
      _observe('recordFailure', () => FluentTableStatsTracker().recordFailure(part));
      _pendingRequests.remove(part.id)?.completeError(error, stackTrace);
    }
  }

  /// Empties every user table of the task's database in one transaction (rolled back on error).
  ///
  /// The tables come from `sqlite_master`, without SQLite's own and the `__fluent_*` tables. The rows are deleted
  /// directly, not through the providers (no soft delete, no per-row events). The sync bookkeeping
  /// (`__fluent_sync_state`, `__fluent_fetch_state`) is emptied too, so synced tables are pulled in full again.
  ///
  /// Returns `true` when the database was emptied, `false` when its connection is missing or closed.
  Future<bool> _clearDatabase(FluentTask task) async {
    final Database? db = _databases[task.dbName];

    if (db != null && db.isOpen) {
      try {
        await _clearTables(db);
      } on DatabaseException catch (e, s) {
        throw _clearError(task.dbName, e, s);
      }
      return true;
    }
    return false;
  }

  Future<void> _clearTables(Database db) => db.transaction(_emptyTables);

  /// Empties every user table and the sync bookkeeping through [txn] (see [_clearDatabase]).
  Future<void> _emptyTables(DatabaseExecutor txn) async {
      {
        // `_` is a wildcard in LIKE: escape it, or user tables like "myfluent_items" would be skipped.
        final List<Map<String, dynamic>> tables = await txn.rawQuery(
          r"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite\_%' ESCAPE '\' AND name NOT LIKE '\_\_fluent\_%' ESCAPE '\'",
        );

        // Tables are emptied in passes: a parent whose children still exist under an ON DELETE RESTRICT rule waits
        // for the next pass (a failed statement leaves the transaction usable).
        List<String> left = [for (final Map<String, dynamic> t in tables) t['name']! as String];
        Object? lastError;
        while (left.isNotEmpty) {
          final List<String> failed = [];
          for (final String table in left) {
            try {
              await txn.delete(table.quotedIdentifier);
            } on DatabaseException catch (e) {
              failed.add(table);
              lastError = e;
            }
          }
          if (failed.length == left.length) throw lastError!; // no progress: a real error
          left = failed;
        }
        // An emptied synced table is pulled in full again, and watchRemote fetches again.
        for (final String bookkeeping in const ['__fluent_sync_state', '__fluent_fetch_state', '__fluent_tombstones']) {
          if ((await txn.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [bookkeeping])).isNotEmpty) {
            await txn.delete(bookkeeping.quotedIdentifier);
          }
        }
      }
  }

  /// `FluentDb.clear` of [scope]'s database inside its open transaction (queued, the clear would wait for the
  /// transaction, and the transaction for it): empties the tables in a savepoint (rolled back alone on error); the
  /// change events of [providers] and the forgotten query costs follow the commit.
  @internal
  Future<void> clearInTransaction(FluentTransactionScope scope, Iterable<FluentProvider> providers) async {
    try {
      await scope.savepoint(() => _emptyTables(scope.txn));
    } on DatabaseException catch (e, s) {
      throw _clearError(scope.dbName, e, s);
    }
    scope._afterCommit.add(() => _observe('forget', () => FluentTableStatsTracker().forget(db: scope.dbName)));
    for (final FluentProvider provider in providers) {
      scope.pendingEvents.add((FluentTask(action: FluentDbAction.clearTable, table: provider.tableName, dbName: scope.dbName), provider, true));
    }
  }

  /// The typed error of a database that could not be emptied: a constraint (rows still referenced, a trigger that
  /// refuses the delete) or another SQL error, with the original as cause.
  FluentException _clearError(String dbName, DatabaseException e, StackTrace stackTrace) {
    final String text = e.toString();
    final bool foreignKey = text.contains('FOREIGN KEY constraint failed');
    final bool constraint = foreignKey || text.contains('constraint failed');
    final String message = 'Database "$dbName" could not be cleared: ${FluentLog.redact(e.toString())}';
    const String hint = 'A foreign key that restricts the delete, or a trigger on one of the tables, refused it. Remove the '
        'referencing rows first, change the rule to ON DELETE CASCADE, or delete those rows yourself.';
    return constraint
        ? FluentConstraintException(message, code: foreignKey ? FluentErrorCode.foreignKeyViolation : FluentErrorCode.checkViolation, hint: hint, cause: e, stackTrace: stackTrace)
        : FluentQueryException(message, hint: hint, cause: e, stackTrace: stackTrace);
  }

  /// The scheduling weight of [task] (lower runs earlier among the reads that may run): the static cost of its action
  /// and options, plus its measured average duration on its table (per action, so a slow `findAll` does not make
  /// `findById` of the same table look heavy), plus a little per relation loaded.
  int _calculateFinalWeight(FluentTask task) {
    final double averageMs = FluentTableStatsTracker().averageMs(task) ?? 0;
    final int relations = task.isWriteOp || task.maxDepth < 1 ? 0 : (_dbRelationsCount[task.dbName]?[task.table] ?? 0);
    return (task.staticWeight + (averageMs * 2).clamp(0, 1000) + relations * 10).round().clamp(1, 2000);
  }

  /// Graceful stop: no new calls are accepted, the calls already queued run (at most [drainTimeout]), telemetry is
  /// flushed. Call it before closing the databases.
  ///
  /// A started call is never abandoned: running calls are always awaited, however long they take. Only calls that
  /// have not started fail ("nothing of this call was written"): those queued on a paused database or while the
  /// whole engine is paused (they would never start), and those still queued after [drainTimeout].
  Future<void> shutdown({Duration drainTimeout = const Duration(seconds: 5)}) async {
    if (_insideTask) {
      // Shutting down waits for the running tasks, including the one that asked: it could never finish. Nothing changes.
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        'The engine was shut down from inside a running task or transaction; the call is ignored.',
        tag: 'FluentEngine:shutdown',
        hint: 'Close the databases outside FluentDb.transaction and outside provider callbacks.',
      );
      return;
    }
    _accepting = false;
    FluentTuner().stop();
    {
      // Paused queues never start: their calls fail now instead of holding the close.
      final int paused = _cancelQueued(_isGlobalPaused ? null : _pausedDbs, 'The database engine was closed while its queue was paused; this call never started.');
      if (paused > 0) FluentLog.debug('Engine shut down while paused: $paused queued call(s) fail without running', tag: 'FluentEngine:shutdown');
      if (!await _waitIdle(drainTimeout)) {
        final int queued = _cancelQueued(null, 'The database engine was closed before this call ran (it waited too long behind other calls).');
        if (queued > 0) {
          FluentLog.issue(
            FluentIssueKind.shutdownTimeout,
            'The engine stopped before every queued call ran (${drainTimeout.inSeconds}s): $queued call(s) that had not started fail; running calls are awaited.',
            tag: 'FluentEngine:shutdown',
            hint: 'A long transaction or a slow call held the queue. Await your database calls before closing.',
            context: {'queued': queued, 'running': _globalActiveReads + _globalActiveWrites},
          );
        }
        await _waitIdle(null); // never abandon a started operation
      }
    }
    _saveTimer?.cancel();
    _saveTimer = null;
    // Explicit close: write what is left (after a running flush) - not from inside a task, where the write would wait
    // for the very task that is closing.
    if (!_insideTask) await _flushStats(onlyIdle: false);
    _generation++;
    await _performCleanup();
  }

  /// Fails the queued (not started) calls of [dbs] (every database when `null`) with [message]; returns how many.
  int _cancelQueued(Set<String>? dbs, String message) {
    int cancelled = 0;
    for (final MapEntry<String, List<FluentTask>> entry in _queues.entries) {
      if (dbs != null && !dbs.contains(entry.key)) continue;
      for (final FluentTask task in entry.value) {
        _callerZones.remove(task.id);
        _raisedPriority.remove(task.id);
        final Completer<dynamic>? completer = _pendingRequests.remove(task.id);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(_cancelled(message));
          cancelled++;
        }
      }
      entry.value.clear();
    }
    _checkIdle();
    return cancelled;
  }

  /// The error of calls the closing engine did not run.
  static FluentCancelledException _cancelled(String message) =>
      FluentCancelledException(message, hint: 'Nothing of this call was written. Await pending calls before FluentDb.close().');

  /// Rejects what is still pending, stops the timers and resets the state (after [shutdown]).
  Future<void> _performCleanup() async {
    FluentLog.debug('Engine cleanup', tag: 'FluentEngine:lifecycle');
    _observerFailureReported = false;
    await _closeReaders();

    _activeReadsPerDb.clear();
    _activeWritesPerDb.clear();
    FluentAnalyzer().reset();

    _isGlobalPaused = false;
    _pausedDbs.clear();

    if (_globalPauseCompleter != null && !_globalPauseCompleter!.isCompleted) {
      _globalPauseCompleter!.completeError(_cancelled('Engine shutdown aborted the global pause.'));
      _globalPauseCompleter = null;
    }

    for (final completer in _dbPauseCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(_cancelled('Engine shutdown aborted a database pause.'));
      }
    }
    _dbPauseCompleters.clear();

    _databases.clear();
    _dbRelationsCount.clear();

    for (final Timer timer in _dbPauseTimers.values) {
      timer.cancel();
    }
    _dbPauseTimers.clear();
    _globalPauseTimer?.cancel();
    _globalPauseTimer = null;

    _activeCollapses.clear();
    _configs.clear();
    if (_idle != null && !_idle!.isCompleted) _idle!.complete();
    _idle = null;

    // Calls that never started fail. Running ones (only when the engine was shut down from inside a task) keep their
    // completers and finish on their own.
    _cancelQueued(null, 'The database engine was closed before this call ran.');
    _queues.clear();
    _writeEpochs.clear();
    _callerZones.clear();
    _raisedPriority.clear();
    _collapseHeads.clear();

    FluentLog.debug('Cleanup sequence completed', tag: 'FluentEngine:lifecycle');
  }


}

/// The mark of a running engine task in its zone (see `FluentEngine._runningTaskKey`): [running] turns false when the
/// task ends, so code it left behind (timers, listeners) no longer counts as inside the task.
class _RunningTask {
  /// A mark for a task of [dbName] started from code that ran inside [outer] (kept only while it runs).
  _RunningTask(this.dbName, _RunningTask? outer) : outer = outer?._running;

  /// The database of the task.
  final String dbName;

  /// The task the code that started this one ran in, if any (a task started from inside another task waits for it).
  final _RunningTask? outer;

  bool running = true;

  /// This mark or the nearest outer one that still runs.
  _RunningTask? get _running {
    _RunningTask? mark = this;
    while (mark != null && !mark.running) {
      mark = mark.outer;
    }
    return mark;
  }

  /// Whether this task, or a running task it was started from, belongs to [db]: a queued write of [db] would wait
  /// for it, and it for the write.
  bool holds(String db) {
    for (_RunningTask? mark = _running; mark != null; mark = mark.outer?._running) {
      if (mark.dbName == db) return true;
    }
    return false;
  }
}
