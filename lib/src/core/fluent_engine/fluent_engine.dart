// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The central orchestrator for the FluentSQFLite database layer.
///
/// **Role:**
/// The [FluentEngine] acts as the primary synchronization hub for database operations.
/// It manages the execution lifecycle of tasks, ensuring thread-safe interaction
/// with SQLite and optimizing I/O throughput by intelligently scheduling operations.
///
/// **Key Responsibilities:**
/// * **Adaptive Concurrency:** Dynamically manages execution strategies to maintain
///   high performance and eliminate `SQLITE_BUSY` contention under heavy load.
/// * **Intelligent Batching:** Automatically merges identical or adjacent tasks
///   into optimized chunks, respecting [ExecutionPolicy] limits to maximize
///   database I/O efficiency.
/// * **Task Prioritization:** Implements an aging-aware scheduling queue that
///   prevents starvation of low-priority tasks while keeping UI-critical
///   operations responsive via high-priority lanes.
/// * **Observability:** Integrates with [FluentTableStatsTracker] for real-time
///   performance telemetry, including mutation tracking and schema-level diagnostics.
///
/// **Usage:**
/// The engine should be initialized with [FluentEngineConfig] and used as a singleton.
/// It serves as the primary gateway for executing `FluentTask` operations,
/// coordinating background processing, and managing persistence.
class FluentEngine {
  /// The singleton instance of the [FluentEngine].
  static final FluentEngine _instance = FluentEngine._internal();

  /// Accesses the global [FluentEngine] instance.
  factory FluentEngine() => _instance;

  /// Private constructor for the singleton pattern.
  FluentEngine._internal();

  /// Registry for outstanding async tasks, allowing completion when the worker reports back.
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  /// Performance tuning configurations per table or database group.
  final Map<String, SQLitePerformanceConfig> _configs = {};

  /// Prioritized queue of [FluentTask] operations; sorted by weight and policy rules to
  /// prioritize critical UI-blocking reads over background synchronization.
  final List<FluentTask> _queue = [];

  /// Deduplication layer: stores active Futures for identical queries to prevent
  /// redundant IO work when multiple components request the same data simultaneously.
  final Map<String, Future<dynamic>> _activeCollapses = {};

  /// Atomic counter for generating unique sequence IDs for tracking communication.
  int _idCounter = 0;

  /// Tracks the number of active read operations currently executing for each database.
  /// Used by the scheduler to respect [maxConcurrentReads] limits.
  final Map<String, int> _activeReadsPerDb = {};

  /// Tracks the number of active write operations.
  /// Since SQLite allows only one writer at a time, this acts as a global
  /// semaphore for write-level synchronization.
  final Map<String, int> _activeWritesPerDb = {};

  /// A global flag indicating if the entire engine is paused.
  /// When true, all incoming tasks are queued until [resumeAll] is called.
  bool _isGlobalPaused = false;

  /// Completer used to suspend task execution when the engine is globally paused.
  /// Tasks await this future until the pause state is lifted.
  Completer<void>? _globalPauseCompleter;

  /// A set of database identifiers that are currently paused.
  /// Allows the engine to throttle or stop activity on a per-database basis.
  final Set<String> _pausedDbs = {};

  /// Map of completers for specific database pause states.
  /// Enables fine-grained control, allowing the engine to resume operations
  /// for one database while others remain paused.
  final Map<String, Completer<void>> _dbPauseCompleters = {};

  /// Periodic timer for triggering maintenance tasks or telemetry flush cycles.
  Timer? _saveTimer;

  /// Periodic timer for triggering analyze task for telemetry.
  Timer? _analyzeTimer;

  /// Increments and returns the next unique operation ID.
  int get _nextId => ++_idCounter;

  /// A cache mapping database identifiers to the list of tables they contain.
  /// Used to validate table existence and optimize query routing before execution.
  final Map<String, List<String>> _dbTables = {};

  /// Stores metadata about the number of relations (e.g., foreign keys or indices)
  /// for tables within each database. Used to analyze schema complexity
  /// and estimate performance impact of heavy mutations.
  final Map<String, Map<String, int>> _dbRelationsCount = {};

  /// A registry of active [Database] instances.
  /// Serves as the primary connection pool, allowing the engine to access
  /// specific database handles by their unique identifier.
  final Map<String, Database> _databases = {};

  final Map<String, Timer> _dbPauseTimers = {};
  Timer? _globalPauseTimer;

  /// Global broadcast bus for all database modification events.
  ///
  /// This controller acts as the central hub for dispatching change notifications
  /// across the application. It is defined as a broadcast stream to allow
  /// multiple independent listeners (e.g., UI widgets, BLoCs, background services)
  /// to subscribe to database updates simultaneously.
  final StreamController<FluentChangeEvent<dynamic>> _changeEventBus = StreamController.broadcast();

  /// The public reactive stream that exposes all database mutations.
  ///
  /// Use [FluentDb.onEvent] to subscribe to this stream with type-safe filtering,
  /// rather than listening to this stream directly. This ensures that your
  /// listeners only receive events relevant to their specific model types or tags.
  Stream<FluentChangeEvent<dynamic>> get changeStream => _changeEventBus.stream;

  /// The broadcast event bus for system-level notifications and critical alerts.
  ///
  /// Consumers can listen to this stream to receive [FluentSystemAlert] events,
  /// such as watchdog timeouts, persistence failures, or execution errors.
  final StreamController<FluentSystemAlert> _alertEventBus = StreamController.broadcast();

  /// Exposes the system alert stream for monitoring and observability.
  Stream<FluentSystemAlert> get alertStream => _alertEventBus.stream;

  /// The engine configuration parameters (timers, limits, and safety thresholds).
  FluentEngineConfig _engineConfigs = const FluentEngineConfig();

  /// Internal handler for system-level database operations (telemetry, stats).
  final _FluentSystemDb _systemDb = _FluentSystemDb();

  /// Calculates the sum of all currently active read operations across all databases.
  int get _globalActiveReads => _activeReadsPerDb.values.fold(0, (a, b) => a + b);

  /// Calculates the sum of all currently active write operations across all databases.
  int get _globalActiveWrites => _activeWritesPerDb.values.fold(0, (a, b) => a + b);

  /// Initializes the multi-database environment, setting up performance manifests,
  /// schema metadata, and background maintenance services.
  ///
  /// **Workflow:**
  /// 1. **State Reset:** Clears previous configurations and registries to ensure a clean state.
  /// 2. **Metadata Registration:** Loads performance configs, table structures, and
  ///    relation metadata for all registered databases.
  /// 3. **APM Bootstrapping:** Loads historical statistics from the system database
  ///    into [FluentTableStatsTracker] for real-time diagnostics.
  /// 4. **Service Activation:** Triggers background analysis and starts maintenance
  ///    timers (AutoSave, Analyze, Watchdog) to ensure optimal I/O health.
  ///
  /// **Parameters:**
  /// * [configs]: Mapping of database keys to their respective [SQLitePerformanceConfig].
  /// * [dbTables]: Schema map for structural validation and query optimization.
  /// * [dbRelationsCount]: Complexity map used by the scheduler to adjust batching intensity.
  /// * [dbNameWithDb]: Active database connection handles for runtime access.
  /// * [engineConfig]: Global configuration for timers and safety watchdog thresholds.
  Future<void> initMultiple({
    required Map<String, SQLitePerformanceConfig> configs,
    required Map<String, List<String>> dbTables,
    required Map<String, Map<String, int>> dbRelationsCount,
    required Map<String, Database> dbNameWithDb,
    required FluentEngineConfig engineConfig,
  }) async {
    _configs.clear();
    _dbTables.clear();
    _dbRelationsCount.clear();
    _databases.clear();

    _configs.addAll(configs);
    _dbTables.addAll(dbTables);
    _dbRelationsCount.addAll(dbRelationsCount);
    _databases.addAll(dbNameWithDb);

    _engineConfigs = engineConfig;

    await _systemDb.init();

    final List<TableStats> historicalStats = await _systemDb.loadAllHistoricalStats();
    FluentTableStatsTracker().importFromDisk(historicalStats);

    FluentLog.info('FluentEngine: Initialized with full APM and performance manifest', tag: 'FluentEngine:initMultiple');

    _scheduleBackgroundAnalysis();
    _startTimers();
  }

  /// Starts a watchdog timer to monitor the duration of a paused queue state.
  ///
  /// **Behavior:**
  /// * If [FluentEngineConfig.maxPauseDuration] is configured, the engine will
  ///   forcefully resume the queue after the timeout to prevent deadlocks.
  /// * If no auto-resume duration is set, the engine assumes a critical state
  ///   and dispatches a `FluentSystemAlert` to the [alertStream], allowing
  ///   external systems (like Sentry) to react to the potential hang.
  ///
  /// [dbName] - If provided, monitors a specific database instance; otherwise,
  /// monitors the global engine state.
  void _startPauseWatchdog({String? dbName}) {
    final bool autoResume = _engineConfigs.maxPauseDuration != null;
    final Duration timeout = autoResume ? _engineConfigs.maxPauseDuration! : _engineConfigs.alertPauseDuration;

    final Timer timer = Timer(timeout, () {
      if (autoResume) {
        FluentLog.warning('Watchdog forcefully resumed queue (Max pause duration exceeded)', tag: 'FluentEngine:watchdog', context: {'db': dbName ?? 'GLOBAL', 'elapsedSeconds': timeout.inSeconds});
        resumeQueue(dbName: dbName);
      } else {
        final FluentEngineException exception = FluentEngineException('Pause timeout exceeded without auto-resume.', component: 'startPauseWatchdog', stackTrace: StackTrace.current);
        final FluentSystemAlert alert = FluentSystemAlert(
          message: 'CRITICAL: Queue has been paused for too long!',
          tag: 'FluentEngine:watchdog',
          context: {'db': dbName ?? 'GLOBAL', 'elapsedSeconds': timeout.inSeconds},
          exception: exception,
        );
        _alertEventBus.add(alert);
        FluentLog.error(alert.message, exception, exception.stackTrace, tag: alert.tag, context: alert.context);
      }
    });

    if (dbName != null) {
      _dbPauseTimers[dbName]?.cancel();
      _dbPauseTimers[dbName] = timer;
    } else {
      _globalPauseTimer?.cancel();
      _globalPauseTimer = timer;
    }
  }

  /// Cancels the active watchdog timer for the specified database or global scope.
  ///
  /// This should be called whenever the queue is resumed or manually unblocked
  /// to prevent unnecessary trigger firing.
  void _cancelPauseWatchdog({String? dbName}) {
    if (dbName != null) {
      _dbPauseTimers.remove(dbName)?.cancel();
    } else {
      _globalPauseTimer?.cancel();
      _globalPauseTimer = null;
    }
  }

  /// Initializes and starts the background maintenance timers.
  ///
  /// This includes:
  /// * The Auto-Save timer for persistence.
  /// * The Analyze timer for statistical data gathering.
  /// * All timers are bound to the intervals defined in [FluentEngineConfig].
  void _startTimers() {
    _startAutoSaveTimer();
    _startAnalyzeTimer();
  }

  /// Dynamically updates the active engine configuration at runtime.
  ///
  /// **Responsibility:**
  /// 1. **Hot Reloading:** Applies new temporal thresholds (e.g., save or analyze
  ///    intervals) without requiring a full engine restart.
  /// 2. **Timer Reconciliation:** Automatically cancels and restarts the specific
  ///    background maintenance timers only if their respective intervals have changed,
  ///    ensuring efficient resource management.
  void changeFluentEngineConfig({required FluentEngineConfig newConfig}) {
    if (_engineConfigs == newConfig) return;

    final bool isSaveIntervalChanged = _engineConfigs.saveInterval != newConfig.saveInterval;
    final bool isAnalyzeIntervalChanged = _engineConfigs.analyzeInterval != newConfig.analyzeInterval;

    _engineConfigs = newConfig;

    if (isSaveIntervalChanged) {
      FluentLog.info('Runtime config applied: Auto-save interval changed to ${newConfig.saveInterval.inSeconds}s', tag: 'FluentEngine:config');
      _startAutoSaveTimer();
    }

    if (isAnalyzeIntervalChanged) {
      FluentLog.info('Runtime config applied: Analyze interval changed to ${newConfig.analyzeInterval.inMinutes}m', tag: 'FluentEngine:config');
      _startAnalyzeTimer();
    }
  }

  /// Safely pauses the task dispatching queue and suspends execution until the
  /// currently in-flight operations are drained.
  ///
  /// This method serves as a synchronization barrier, ensuring system stability
  /// during critical maintenance or state changes:
  /// 1. **Data Consistency:** Prevents conflicts during structural changes (migrations)
  ///    or complex native SQLite transactions.
  /// 2. **Pipeline Draining:** Allows the engine to reach a "quiescent" state
  ///    before modifying schemas, clearing registries, or shutting down services.
  /// 3. **Fine-grained Control:** Supports both global pauses (whole engine) and
  ///    per-database suspension, allowing maintenance on one DB while others remain active.
  ///
  /// **Safety:**
  /// Operations are protected by a watchdog timer (defined in [FluentEngineConfig]).
  /// If the drainage process takes longer than the allowed duration, the queue
  /// will be forcefully resumed to prevent system deadlocks.
  ///
  /// **Workflow:**
  /// - Flags the targeted DB (or global engine) as paused to prevent new task dispatching.
  /// - Starts a watchdog timer to monitor the drainage process.
  /// - If the target is currently busy with active operations, the caller is suspended
  ///   via a [Completer] until the worker signals that the queue has been drained.
  ///
  /// If [dbName] is provided, only tasks associated with that specific database are paused.
  Future<void> pauseQueue({String? dbName}) async {
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

  /// Resumes task dispatching and triggers the immediate processing of pending tasks.
  ///
  /// This method serves as the signal to exit the quiescent state, allowing the
  /// [FluentEngine] to resume normal operation. It is typically invoked after the
  /// completion of critical administrative routines, schema migrations, or atomic
  /// transactions.
  ///
  /// **Workflow:**
  /// - Cancels any active watchdog timers associated with the paused state.
  /// - Removes the pause flag for the specified database or the global engine.
  /// - Invokes [_processNext] to immediately begin flushing the accumulated backlog
  ///   and returning the engine to normal operation.
  ///
  /// If [dbName] is provided, only the queue for the specified database is unblocked.
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

      if (_globalPauseCompleter?.isCompleted == false) {
        _globalPauseCompleter!.complete();
      }
      _globalPauseCompleter = null;

      FluentLog.debug('Global queue resumed.', tag: 'FluentEngine:queue');
    }
    _processNext();
  }

  /// Monitors worker activity to determine if the pipeline has successfully "drained."
  ///
  /// This internal helper is invoked upon the completion of every task. It checks
  /// whether the engine has reached a quiescent state, where no active reads or
  /// writes are pending for a specific database or the entire engine.
  ///
  /// **Responsibility:**
  /// When a pause request is active (during migrations or maintenance), this method
  /// continuously polls the operation counters. Once all `_activeReadsPerDb` and
  /// `_activeWritesPerDb` reach zero, it resolves the corresponding [Completer],
  /// signaling to the system that it is now safe to perform exclusive operations.
  ///
  /// **Cleanup:**
  /// Automatically disposes of completed [Completer] instances to prevent
  /// memory leaks and keep the registry clean.
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

  /// Dispatches a database task to the pipeline, applying "Request Collapsing"
  /// for read-only operations to eliminate redundant I/O and optimize throughput.
  ///
  /// **Workflow:**
  /// 1. **Collapsing Check:** Validates if the task is a read-only operation eligible
  ///    for deduplication based on its [ExecutionPolicy].
  /// 2. **Registry Lookup:** If an identical task is already in-flight, returns the
  ///    existing [Future] to avoid re-triggering the same I/O operation.
  /// 3. **Lifecycle Management:** Executes the task in the pipeline and ensures the
  ///    [Future] is evicted from the `_activeCollapses` map immediately upon resolution.
  Future<dynamic> dispatch(FluentTask task) async {
    final bool canCollapse =
        (task.policy.cancelIfDuplicate ?? true) &&
        (task.action == FluentDbAction.find ||
            task.action == FluentDbAction.findById ||
            task.action == FluentDbAction.findAll ||
            task.action == FluentDbAction.findValidItems ||
            task.action == FluentDbAction.findItemsBy ||
            task.action == FluentDbAction.rawGetItem ||
            task.action == FluentDbAction.rawGetItems);

    if (canCollapse) {
      final String key = task.fingerprint;

      if (_activeCollapses.containsKey(key)) {
        FluentLog.debug('Request collapsed: Returning shared future', tag: 'FluentEngine:dispatch', context: {'fingerprint': key});
        return _activeCollapses[key]!;
      }
    }

    final Future<dynamic> executionFuture = _executeTaskInPipeline(task);

    if (canCollapse) {
      final String key = task.fingerprint;
      _activeCollapses[key] = executionFuture;

      await executionFuture.whenComplete(() {
        _activeCollapses.remove(key);
      });
    }

    return executionFuture;
  }

  /// Injects a system-level event directly into the reactive stream without
  /// performing any database I/O. Useful for broadcasting app-wide state resets.
  void broadcastSystemAction(FluentDbAction action, {required Type modelType}) {
    if (!_changeEventBus.isClosed) {
      _changeEventBus.add(FluentChangeEvent(modelType: modelType, action: action, items: []));
      FluentLog.debug('System event broadcasted', tag: 'FluentEngine:broadcast', context: {'action': action.name, 'model': modelType.toString()});
    }
  }

  /// Prepares and submits a database task into the execution pipeline.
  ///
  /// **Workflow:**
  /// 1. **Identity & Weighting:** Assigns a unique tracking ID and calculates
  ///    the execution weight based on task complexity, which informs the engine's
  ///    priority-based scheduling.
  /// 2. **Completer Registration:** Registers a [Completer] to facilitate asynchronous
  ///    communication, allowing the caller to `await` the result once the worker completes.
  /// 3. **Queueing:** Enqueues the task into the prioritization pipeline via [_enqueue],
  ///    where it will be merged or scheduled based on current engine load.
  /// 4. **Tracking:** Initializes request mapping to ensure the execution result
  ///    is correctly routed back to the initiating context.
  Future<dynamic> _executeTaskInPipeline(FluentTask task) async {
    final int id = _nextId;
    task = task.copyWith(id: id);

    // Calculate weight for priority ordering in the queue
    final int weight = _calculateFinalWeight(task);
    task.executionWeight = weight;

    final Completer<dynamic> completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    FluentLog.debug('Enqueuing task to pipeline', tag: 'FluentEngine:pipeline', context: {'taskId': id, 'action': task.action.toString(), 'table': task.table, 'weight': weight});

    _enqueue(task);

    return completer.future;
  }

  /// Adds a [FluentTask] to the execution queue, utilizing a binary search algorithm
  /// to maintain strict priority ordering in $O(\log N)$ time.
  ///
  /// **Performance Optimization:**
  /// By using binary search, we avoid linear $O(N)$ scans. This ensures the engine
  /// remains responsive even when thousands of tasks are queued (e.g., bulk sync).
  ///
  /// **Sorting Hierarchy:**
  /// 1. `force` status (High-priority override).
  /// 2. `priority` (Operational importance).
  /// 3. `executionWeight` (Resource/Complexity cost).
  /// 4. FIFO order: For tasks with identical priority/weight, the new task is
  ///    placed after existing ones (stable insertion).
  void _enqueue(FluentTask task) {
    // Ensure weight is calculated before sorting to prevent scheduling inconsistencies
    if (task.executionWeight == 0) {
      task.executionWeight = _calculateFinalWeight(task);
    }

    if (_queue.isEmpty) {
      _queue.add(task);
      _processNext();
      return;
    }

    final SQLitePerformanceConfig? config = _configs[task.dbName];
    final FluentQueueStrategy strategy = config?.queueStrategy ?? FluentQueueStrategy.smartBatching;

    if (strategy == FluentQueueStrategy.fifo) {
      // Pure FIFO: force tasks jump to front, normal tasks to back
      task.force ? _queue.insert(0, task) : _queue.add(task);
    } else {
      // Priority-based binary search insertion
      int low = 0;
      int high = _queue.length;

      while (low < high) {
        final int mid = (low + high) >> 1;
        final FluentTask current = _queue[mid];

        // Determine if task should precede the current element
        if (_shouldInsertBefore(task, current)) {
          high = mid;
        } else {
          low = mid + 1;
        }
      }
      _queue.insert(low, task);
    }

    FluentLog.debug(
      'Task enqueued successfully',
      tag: 'FluentEngine:queue',
      context: {'taskId': task.id, 'db': task.dbName, 'strategy': strategy.name, 'isForce': task.force, 'weight': task.executionWeight, 'queueSize': _queue.length},
    );

    _processNext();
  }

  /// Comparator helper to maintain strict priority ordering.
  bool _shouldInsertBefore(FluentTask task, FluentTask current) {
    // 1. Force override takes precedence
    if (task.force != current.force) return task.force;

    // 2. Priority check
    if (task.policy.effectivePriority != current.policy.effectivePriority) {
      return task.policy.effectivePriority > current.policy.effectivePriority;
    }

    // 3. Lower executionWeight gets earlier execution
    return task.executionWeight < current.executionWeight;
  }

  /// Monitors the queue and applies an "aging" factor to long-standing tasks
  /// to prevent resource starvation.
  ///
  /// **Logic:**
  /// Iteratively reduces the `executionWeight` of non-force tasks. As weight
  /// decreases, the task's priority increases, ensuring even heavy tasks eventually
  /// move to the front of the queue.
  ///
  /// **Workflow:**
  /// 1. Iterates through pending tasks to calculate updated weights based on
  ///    aging multipliers defined in [SQLitePerformanceConfig].
  /// 2. If any weights change, triggers a global re-sort to maintain the
  ///    "Shortest Job First" (SJF) optimization invariant.
  void _preventQueueStarvation() {
    if (_queue.isEmpty) return;
    bool needsResort = false;

    for (final FluentTask task in _queue) {
      // Only age tasks that are not marked as 'force'
      if (!task.force && task.executionWeight > 10) {
        final SQLitePerformanceConfig? config = _configs[task.dbName];
        final double multiplier = config?.queueAgingMultiplier ?? 0.9;
        final int subtract = config?.queueAgingSubtract ?? 10;

        final int newWeight = (task.executionWeight * multiplier).toInt() - subtract;
        task.executionWeight = math.max(10, newWeight);
        needsResort = true;
      }
    }
    if (needsResort) {
      _queue.sort((a, b) {
        if (a.force && !b.force) return -1;
        if (!a.force && b.force) return 1;

        final priorityDiff = b.policy.effectivePriority.compareTo(a.policy.effectivePriority);
        if (priorityDiff != 0) return priorityDiff;

        return a.executionWeight.compareTo(b.executionWeight);
      });
      FluentLog.debug('Queue starvation prevention: Aging applied and queue re-sorted', tag: 'FluentEngine:scheduler', context: {'queueSize': _queue.length});
    }
  }

  /// The core orchestrator loop that manages the [FluentTask] queue and dispatches
  /// operations to the execution pipeline.
  ///
  /// **Responsibility:**
  /// 1. **Concurrency Control:** Respects [SQLitePerformanceConfig] limits for
  ///    read/write concurrency (WAL vs. Sequential modes).
  /// 2. **Dependency Management:** Ensures write operations do not overlap with
  ///    other active tasks, maintaining database integrity.
  /// 3. **Intelligent Batching:** Invokes [_attemptBatching] to collapse compatible
  ///    operations into high-throughput atomic transactions.
  /// 4. **Backpressure:** Gracefully stalls dispatching for specific databases if
  ///    load limits are reached, preventing `SQLITE_BUSY` contention.
  ///
  /// This method continuously evaluates the queue, applying scheduling strategies
  /// to determine which tasks are safe to start based on the current load and
  /// database state (including pause status and pending writes).
  void _processNext() {
    if (_isGlobalPaused || _queue.isEmpty) return;

    final List<FluentTask> tasksToStart = [];
    final List<int> indicesToRemove = [];

    final Set<String> blockedDbs = {..._pausedDbs};
    final Set<String> pendingWriteTables = {};

    for (int i = 0; i < _queue.length; i++) {
      final FluentTask task = _queue[i];
      final String dbName = task.dbName;
      final String tableKey = '$dbName:${task.table}';

      if (blockedDbs.contains(dbName)) continue;

      final SQLitePerformanceConfig? config = _configs[dbName];
      final FluentDbExecutionStrategy executionStrategy = config?.executionStrategy ?? FluentDbExecutionStrategy.concurrentWAL;
      final FluentQueueStrategy queueStrategy = config?.queueStrategy ?? FluentQueueStrategy.smartBatching;
      final int maxReads = config?.maxConcurrentReads ?? 5;

      final int activeWrites = _activeWritesPerDb[dbName] ?? 0;
      final int activeReads = _activeReadsPerDb[dbName] ?? 0;
      final int startingReads = tasksToStart.where((t) => t.dbName == dbName && !t.isWriteOp).length;
      final int startingWrites = tasksToStart.where((t) => t.dbName == dbName && t.isWriteOp).length;

      final int totalActiveReads = activeReads + startingReads;
      final int totalActiveWrites = activeWrites + startingWrites;

      if (executionStrategy == FluentDbExecutionStrategy.strictSequential || executionStrategy == FluentDbExecutionStrategy.sequentialWAL) {
        if (totalActiveWrites > 0 || totalActiveReads > 0) {
          blockedDbs.add(dbName);
          continue;
        }
        tasksToStart.add(task);
        indicesToRemove.add(i);
        blockedDbs.add(dbName);
        continue;
      }

      if (task.isWriteOp && queueStrategy == FluentQueueStrategy.smartBatching) {
        FluentLog.debug('Processing write task: checking for batch opportunities', tag: 'FluentEngine:scheduler', context: {'taskId': task.id, 'db': dbName});
      }

      if (task.isWriteOp) {
        if (totalActiveReads > 0 || totalActiveWrites > 0) {
          pendingWriteTables.add(tableKey);
          continue;
        }

        if (queueStrategy == FluentQueueStrategy.smartBatching) {
          final List<int> batchIndices = [];
          final FluentTask? batchedTask = _attemptBatching(rootTask: task, rootIndex: i, queue: _queue, outIndicesToRemove: batchIndices);

          if (batchedTask != null) {
            tasksToStart.add(batchedTask);
            indicesToRemove.addAll(batchIndices);
            blockedDbs.add(dbName);
            continue;
          }
        }

        tasksToStart.add(task);
        indicesToRemove.add(i);
        blockedDbs.add(dbName);
      } else {
        if (pendingWriteTables.contains(tableKey)) continue;
        if (totalActiveWrites > 0) continue;

        if (totalActiveReads >= maxReads) {
          blockedDbs.add(dbName);
          continue;
        }

        tasksToStart.add(task);
        indicesToRemove.add(i);
      }
    }

    if (tasksToStart.isEmpty) return;

    FluentLog.debug('Dispatching tasks to pipeline', tag: 'FluentEngine:scheduler', context: {'batchSize': tasksToStart.length});

    indicesToRemove.sort((a, b) => b.compareTo(a));
    indicesToRemove.forEach(_queue.removeAt);

    tasksToStart.forEach(_dispatchToMain);
  }

  /// Dispatches the task to the execution environment and registers its
  /// impact on the database's concurrency state.
  ///
  /// **Workflow:**
  /// 1. **Telemetry:** Logs the dispatch event, providing critical context (weight,
  ///    current load) for performance auditing.
  /// 2. **State Tracking:** Increments the active read/write counters for the
  ///    target database. This acts as a semaphore to restrict concurrent access.
  /// 3. **Execution & Finalization:** Invokes the low-level executor ([_executeInMain]).
  ///    Once complete (or failed), it ensures the concurrency counters are
  ///    decremented via [_finalizeTaskCompletion].
  ///
  /// **Integrity:**
  /// The use of `.then()` and `.catchError()` ensures that concurrency counters are
  /// always cleaned up, preventing "zombie" load counts that could block
  /// future operations indefinitely.
  void _dispatchToMain(FluentTask task) {
    final String db = task.dbName;

    FluentLog.debug(
      'Starting task processing',
      tag: 'FluentEngine:queue',
      context: {'action': task.action.name, 'dbName': db, 'executionWeight': task.executionWeight, 'activeReads': _activeReadsPerDb[db] ?? 0, 'activeWrites': _activeWritesPerDb[db] ?? 0},
    );

    if (task.isWriteOp) {
      _activeWritesPerDb[db] = (_activeWritesPerDb[db] ?? 0) + 1;
    } else {
      _activeReadsPerDb[db] = (_activeReadsPerDb[db] ?? 0) + 1;
    }

    _executeInMain(task).then((_) => _finalizeTaskCompletion(db, task.isWriteOp)).catchError((_) => _finalizeTaskCompletion(db, task.isWriteOp));
  }

  /// Finalizes the execution of a task by releasing its associated concurrency slots
  /// and triggering the next scheduling cycle.
  ///
  /// **Responsibility:**
  /// 1. **Resource Release:** Decrements the active read or write counters for
  ///    the specified database, ensuring accurate load tracking.
  /// 2. **Barrier Check:** Invokes [_checkPauseState] to signal that a worker
  ///    slot has become available, potentially resolving pending pause/migration barriers.
  /// 3. **Queue Progression:** Calls [_processNext] to immediately flush the
  ///    next batch of pending tasks from the queue, maintaining high I/O throughput.
  ///
  /// **Integrity:**
  /// Employs `math.max(0, ...)` to ensure counters never drop below zero,
  /// providing a safety guard against race conditions or double-finalization.
  void _finalizeTaskCompletion(String dbName, bool wasWrite) {
    if (wasWrite) {
      _activeWritesPerDb[dbName] = math.max(0, (_activeWritesPerDb[dbName] ?? 1) - 1);
    } else {
      _activeReadsPerDb[dbName] = math.max(0, (_activeReadsPerDb[dbName] ?? 1) - 1);
    }

    FluentLog.debug(
      'Task finalized',
      tag: 'FluentEngine:scheduler',
      context: {'dbName': dbName, 'type': wasWrite ? 'write' : 'read', 'remainingActiveWrites': _activeWritesPerDb[dbName], 'remainingActiveReads': _activeReadsPerDb[dbName]},
    );

    _checkPauseState();
    _processNext();
  }

  /// Initializes or resets the background maintenance timer for telemetry and stats.
  ///
  /// **Responsibility:**
  /// 1. **Resource Guarding:** Cancels any existing timers to prevent race conditions
  ///    and overlapping flush cycles.
  /// 2. **Anti-Starvation:** Periodically invokes [_preventQueueStarvation] to
  ///    ensure long-standing tasks eventually gain execution priority.
  /// 3. **Smart Persistence:** Monitors the [FluentTableStatsTracker] state and
  ///    performs an I/O-efficient write only if data has been modified (`isDirty`).
  ///
  /// **Workflow:**
  /// - Executes a recurring check at the defined [_saveInterval].
  /// - If `isDirty` is true, triggers an asynchronous persistence operation
  ///   via [_triggerSaveStats], minimizing I/O overhead while ensuring data consistency.
  void _startAutoSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(_engineConfigs.saveInterval, (timer) async {
      _preventQueueStarvation();
      if (FluentTableStatsTracker().isDirty) {
        FluentLog.debug('Auto-save interval reached: Flushing pending stats', tag: 'FluentEngine:persistence');

        await _triggerSaveStats();
      }
    });
  }

  /// Initializes the periodic maintenance timer for database schema and index analysis.
  ///
  /// **Responsibility:**
  /// 1. **Resource Guarding:** Cancels any existing timers to prevent redundant analysis cycles.
  /// 2. **Performance Optimization:** Periodically triggers background analysis
  ///    to refresh SQLite query planner statistics, ensuring efficient execution plans.
  ///
  /// **Workflow:**
  /// - Schedules a recurring check at the defined [_analyzeInterval].
  /// - Invokes [_scheduleBackgroundAnalysis] to offload I/O-intensive index
  ///   optimization tasks to background processing, keeping the UI thread fluid.
  void _startAnalyzeTimer() {
    _analyzeTimer?.cancel();
    _analyzeTimer = Timer.periodic(_engineConfigs.analyzeInterval, (timer) {
      _scheduleBackgroundAnalysis();
    });
  }

  /// Iterates through all registered databases and tables to schedule background
  /// maintenance analysis tasks.
  ///
  /// **Responsibility:**
  /// 1. **Stat Refresh:** Ensures SQLite's internal query planner has up-to-date
  ///    statistics, essential for maintaining efficient query execution plans.
  /// 2. **Idempotency:** Prevents redundant analysis tasks by checking the current
  ///    [_queue] for pending tasks with the same action and scope.
  /// 3. **Prioritization:** Dispatches these tasks as "System" level operations
  ///    with [ExecutionPolicy.background], ensuring they run at low priority
  ///    without blocking critical user-facing transactions.
  void _scheduleBackgroundAnalysis() {
    for (final MapEntry<String, Database> dbEntry in _databases.entries) {
      final String dbName = dbEntry.key;
      final List<String> tableNames = _dbTables[dbName] ?? [];

      for (final String tableName in tableNames) {
        // Idempotency check: skip if an analysis task for this table is already queued
        if (_queue.any((t) => t.action == FluentDbAction.analyzeTable && t.dbName == dbName && t.table == tableName)) {
          continue;
        }

        final FluentTask task = FluentTask(action: FluentDbAction.analyzeTable, dbName: dbName, table: tableName, isSystem: true, policy: ExecutionPolicy.background);

        FluentLog.debug('Scheduling background maintenance', tag: 'FluentEngine:maintenance', context: {'dbName': dbName, 'table': tableName});

        _executeSystemTask(task);
      }
    }
  }

  /// Triggers a persistence cascade to write accumulated telemetry statistics to the disk.
  ///
  /// **Workflow:**
  /// 1. **Data Gathering:** Exports the current state of [FluentTableStatsTracker].
  /// 2. **State Reset:** Updates the dirty flag (`_hasUnsavedChanges = false`)
  ///    before the operation, allowing the tracker to begin accumulating fresh
  ///    metrics immediately without blocking.
  /// 3. **Persistence:** Queues a system-level task to write the payload to the
  ///    system database.
  /// 4. **Resilience:** If the save operation fails, the dirty flag is restored,
  ///    ensuring the next auto-save cycle will re-attempt persistence.
  /// 5. **Observability:** In case of critical failure, dispatches a [FluentSystemAlert]
  ///    to the [alertStream], allowing for real-time monitoring of persistence health.
  Future<void> _triggerSaveStats() async {
    final FluentTableStatsTracker tracker = FluentTableStatsTracker();
    if (!tracker.isDirty) {
      return;
    }
    if (_queue.any((t) => t.action == FluentDbAction.saveStats)) {
      FluentLog.debug('Skipping saveStats: Operation already queued', tag: 'FluentEngine:persistence');
      return;
    }

    tracker.clearDirtyFlag();

    final List<TableStats> currentStats = tracker.getAllStats;
    if (currentStats.isEmpty) return;

    final FluentTask persistTask = FluentTask(action: FluentDbAction.saveStats, data: currentStats, isSystem: true, policy: ExecutionPolicy.background);

    FluentLog.debug('Queueing telemetry synchronization', tag: 'FluentEngine:persistence');

    try {
      await _executeSystemTask(persistTask);
      FluentLog.debug('Telemetry successfully synchronized with disk', tag: 'FluentEngine:persistence');
    } catch (e, s) {
      tracker.markAsDirty();
      FluentLog.error('Failed to persist statistics', e, s, tag: 'FluentEngine:persistence');

      _alertEventBus.add(
        FluentSystemAlert(
          message: 'Background telemetry persistence failed',
          tag: 'FluentEngine:persistence_error',
          exception: FluentEngineException('Background telemetry persistence failed', component: 'triggerSaveStats', originalError: e, stackTrace: s),
        ),
      );
    }
  }

  /// Executes a database operation with rigorous monitoring, error trapping,
  /// and diagnostic reporting.
  ///
  /// **Responsibility:**
  /// 1. **Execution Guarding:** Enforces strict execution [TimeoutException] limits
  ///    to preserve system responsiveness.
  /// 2. **Telemetry & Observability:** Uses [Stopwatch] to track performance.
  ///    Heavy operations (>300ms) are logged, and critical UI-blocking queries
  ///    (>1000ms) trigger an automatic [FluentSystemAlert] via the [alertStream].
  /// 3. **Change Propagation:** Automatically dispatches change events to the
  ///    [_changeEventBus] for observers; errors in dispatching are non-fatal
  ///    but are reported as system alerts to prevent silent UI-sync failures.
  /// 4. **Resilience & Fault Tolerance:** Implements multi-layer catch blocks
  ///    that sanitize exceptions, register failures in [FluentTableStatsTracker],
  ///    and propagate critical system alerts to the [alertStream] for
  ///    external observability (e.g., Sentry/Crashlytics).
  ///
  /// **Batch Support:**
  /// Handles atomic resolution for batched tasks, ensuring that all sub-tasks
  /// receive consistent completion signals or propagation of errors.
  Future<dynamic> _executeInMain(FluentTask task) async {
    final String tableName = task.table;

    if (task.isSystem) {
      try {
        dynamic systemResult;
        switch (task.action) {
          case FluentDbAction.analyzeStats:
            await _analyzeStats(task);
            systemResult = true;
            break;
          case FluentDbAction.saveStats:
            final List<TableStats> payload = task.data as List<TableStats>;
            await _systemDb.saveStats(payload);
            systemResult = true;
            break;
          case FluentDbAction.analyzeTable:
            break;
          default:
            throw FluentEngineException('Unknown system action: ${task.action.toString()}', component: 'executeInMain', task: task, stackTrace: StackTrace.current);
        }
        _pendingRequests.remove(task.id)?.complete(systemResult);
        return systemResult;
      } catch (e, s) {
        final FluentException exception = FluentEngineException('System task failed: ${task.action.name}', component: 'executeInMain', originalError: e, stackTrace: s);

        _alertEventBus.add(
          FluentSystemAlert(message: 'System task failed: ${task.action.name}', tag: 'FluentEngine:system_error', context: {'action': task.action.name, 'db': task.dbName}, exception: exception),
        );
        FluentLog.error('System task execution failed', exception, exception.stackTrace, tag: 'FluentEngine:system');
        _pendingRequests.remove(task.id)?.completeError(e);
        rethrow;
      }
    }

    final Stopwatch sw = Stopwatch()..start();
    if (task.action == FluentDbAction.clearDatabase) {
      _purgePendingTasks(dbName: task.dbName);
      FluentTableStatsTracker().resetDatabaseStats(task.dbName);
      await _clearDatabase(task);
      _pendingRequests.remove(task.id)?.complete(true);
      return true;
    }

    try {
      final FluentProvider provider = FluentDb.getProviderByTable(tableName, dbName: task.dbName);

      dynamic result;
      if (task.policy.timeout != null) {
        result = await provider
            .internalExecute(task)
            .timeout(task.policy.timeout!, onTimeout: () => throw TimeoutException('🎯 [Main Timeout] Database operation "${task.action.name}" on table "$tableName" exceeded limit!'));
      } else {
        result = await provider.internalExecute(task);
      }

      sw.stop();
      final int elapsedMs = sw.elapsedMilliseconds;

      if (task.isStreamOp) {
        try {
          List<dynamic> normalizedItems = [];
          if (task.isBatched) {
            for (final mTask in task.mergedTasks!) {
              if (mTask.data is List) {
                normalizedItems.addAll(mTask.data as List);
              } else if (mTask.data != null) {
                normalizedItems.add(mTask.data);
              }
            }
          } else {
            if (task.data is List) {
              normalizedItems = List.from(task.data as List);
            } else if (task.data != null) {
              normalizedItems = [task.data];
            }
          }

          _changeEventBus.add(FluentChangeEvent(modelType: provider.modelSample.runtimeType, action: task.action, items: normalizedItems, customTag: task.policy.customTag));
        } catch (e, s) {
          FluentLog.warning('Failed to dispatch change event', tag: 'FluentEngine:stream');

          _alertEventBus.add(
            FluentSystemAlert(
              message: 'Failed to dispatch reactive change event (UI state may be out of sync)',
              tag: 'FluentEngine:stream_error',
              context: {'table': task.table, 'action': task.action.name},
              exception: FluentEngineException('Failed to dispatch reactive change event (UI state may be out of sync)', component: 'executeInMain', originalError: e, stackTrace: s, task: task),
            ),
          );
        }
      }

      if (elapsedMs > 300) {
        FluentLog.warning('Heavy operation detected: ${elapsedMs}ms', tag: 'FluentEngine:main_track');
        if (elapsedMs > 1000) {
          final Map<String, dynamic> enrichedContext = {
            'table': tableName,
            'dbName': task.dbName,
            'action': task.action.name,
            'elapsedMs': elapsedMs,
            'isBatched': task.isBatched,
            'weight': task.executionWeight,
            'depth': task.maxDepth,
          };

          if (task.helper != null) {
            if (task.helper!.where != null) enrichedContext['where'] = task.helper!.where;
            if (task.helper!.orderBy != null) enrichedContext['orderBy'] = task.helper!.orderBy;
            if (task.helper!.limit != null) enrichedContext['limit'] = task.helper!.limit;
          }

          if (task.policy.customTag != null) {
            enrichedContext['tag'] = task.policy.customTag;
          }

          _alertEventBus.add(FluentSystemAlert(message: 'Critical UI-blocking operation detected', tag: 'FluentEngine:heavy_query', context: enrichedContext));
        }
      }

      if (task.isBatched) {
        for (final FluentTask mergedTask in task.mergedTasks!) {
          _pendingRequests.remove(mergedTask.id)?.complete(result);
          FluentTableStatsTracker().registerSuccess(task: mergedTask, elapsedMs: elapsedMs, isWrite: true);
        }
      } else {
        if (task.action == FluentDbAction.clearTable) {
          _purgePendingTasks(dbName: task.dbName, tableName: tableName);
          FluentTableStatsTracker().resetPerformanceStats(task.dbName, tableName);
          FluentTableStatsTracker().registerSuccess(task: task, elapsedMs: elapsedMs, isWrite: true);
        } else if (task.action == FluentDbAction.wipeAll) {
          FluentTableStatsTracker().resetAllPerformanceStats();
        } else {
          FluentTableStatsTracker().registerSuccess(task: task, elapsedMs: elapsedMs, isWrite: task.isWriteOp);
        }
        _pendingRequests.remove(task.id)?.complete(result);
      }

      return result;
    } on TimeoutException catch (e, s) {
      final FluentEngineException exception = FluentEngineException('Database operation timed out', component: 'executeInMain', originalError: e, stackTrace: s, task: task);

      FluentLog.error('Execution timeout in Main thread', exception, exception.stackTrace, tag: 'FluentEngine:main_track_timeout', context: {'table': tableName});

      _alertEventBus.add(FluentSystemAlert(message: 'Database operation timed out', tag: 'FluentEngine:timeout', context: {'table': tableName, 'action': task.action.name}, exception: exception));
      _failTaskOrBatch(task, e);
      rethrow;
    } catch (e, s) {
      final FluentEngineException exception = FluentEngineException('Critical execution error in Main thread', component: 'executeInMain', originalError: e, stackTrace: s, task: task);

      FluentLog.error('Critical execution error in Main thread', exception, exception.stackTrace, tag: 'FluentEngine:main_track', context: {'table': tableName, 'error': e.toString()});

      _alertEventBus.add(
        FluentSystemAlert(message: 'Critical database query execution error', tag: 'FluentEngine:query_error', context: {'table': tableName, 'action': task.action.name}, exception: exception),
      );

      _failTaskOrBatch(task, e);
      rethrow;
    }
  }

  /// Handles failure propagation for both individual tasks and batched operations.
  ///
  /// **Responsibility:**
  /// 1. **Telemetry Update:** Informs the [FluentTableStatsTracker] of the failure,
  ///    ensuring that database health metrics and success/failure ratios remain accurate.
  /// 2. **Completer Resolution:** Fulfills the [Completer] for the failed task(s)
  ///    with the provided [error], allowing the caller to catch the exception.
  /// 3. **Atomicity:** Ensures that in batched scenarios, all merged sub-tasks
  ///    receive the failure signal, maintaining consistent state between the
  ///    queue and the execution results.
  void _failTaskOrBatch(FluentTask task, Object error) {
    if (task.isBatched) {
      for (final FluentTask mergedTask in task.mergedTasks!) {
        FluentTableStatsTracker().registerFailure(mergedTask);
        _pendingRequests.remove(mergedTask.id)?.completeError(error);
      }
    } else {
      FluentTableStatsTracker().registerFailure(task);
      _pendingRequests.remove(task.id)?.completeError(error);
    }
  }

  /// Performs an atomic, high-performance wipe of all user-defined tables
  /// within a specific database.
  ///
  /// **Mechanism:**
  /// 1. Uses [sqlite_master] to dynamically discover all user tables,
  ///    automatically excluding SQLite system tables and internal Fluent
  ///    telemetry/metadata tables.
  /// 2. Executes all `DELETE` operations within a single [Batch] inside a
  ///    [Transaction]. This ensures atomicity: if any part fails, the
  ///    database state is automatically rolled back.
  /// 3. Bypasses individual [FluentProvider] triggers to minimize overhead
  ///    during massive structural resets.
  ///
  /// Returns `true` if the database was successfully purged, `false` if the
  /// database handle was unavailable or closed.
  Future<bool> _clearDatabase(FluentTask task) async {
    final Database? db = _databases[task.dbName];

    if (db != null && db.isOpen) {
      await db.transaction((txn) async {
        final List<Map<String, dynamic>> tables = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '__fluent_%'");

        final Batch batch = txn.batch();
        for (final table in tables) {
          batch.delete(table['name'] as String);
        }

        await batch.commit(noResult: true);
      });
      return true;
    }
    return false;
  }

  /// Dynamically calculates the execution priority (weight) of a [FluentTask].
  ///
  /// **Weighting Factors:**
  /// 1. **Data Volume:** Scales linearly based on [rowCount] (5k threshold).
  /// 2. **Memory Load:** Penalizes tasks with high [sessionPayload] to reduce
  ///    memory-intensive serialization overhead.
  /// 3. **Schema Complexity:** Applies a multiplier based on [TableComplexity],
  ///    significantly bumping 'Extreme' join-heavy operations.
  /// 4. **Relational Impact:** Accounts for cascading side effects via [relationsCount].
  /// 5. **Historical Latency:** Implements a feedback loop that increases
  ///    priority for tasks that have historically been slow (>50ms).
  int _calculateFinalWeight(FluentTask task) {
    if (task.force) return 0;

    final int staticWeight = task.staticWeight;
    final String key = '${task.dbName}:${task.table}';

    final TableStats? stats = FluentTableStatsTracker()._statsMap[key];
    if (stats == null) return staticWeight;

    // 1. Fundamental Complexity (Multiplicative)
    final double complexityMultiplier = switch (stats.complexity) {
      TableComplexity.low => 0.8,
      TableComplexity.medium => 1.2,
      TableComplexity.high => 2.0,
      TableComplexity.extreme => 3.0,
    };

    double finalCalculated = staticWeight * complexityMultiplier;

    // 2. Additive Bonuses (Sum of impacts)
    final double rowBonus = (stats.rowCount / 5000).clamp(0.0, 1.0);
    final double relationsBonus = (stats.relationsCount * 0.25).clamp(0.0, 1.0);

    final double historicalBonus = (stats.avgExecutionWeight / 200.0).clamp(0.0, 1.0);

    final double totalBonus = rowBonus + relationsBonus + historicalBonus;

    finalCalculated += (staticWeight * totalBonus);

    // 3. Safety Multiplier (Final Penalties)
    final double totalOps = (stats.totalReads + stats.totalWrites).toDouble();
    final double errorRate = totalOps > 0 ? stats.failedQueries / totalOps : 0.0;
    final double safetyMultiplier = errorRate > 0.05 ? 1.5 : 1.0;

    finalCalculated *= safetyMultiplier;

    // 4. Hard Ceiling
    final int finalWeight = finalCalculated.round().clamp(10, 2000);

    FluentLog.debug(
      'Calculated task weight',
      tag: 'FluentEngine:weight',
      context: {
        'taskId': task.id,
        'static': staticWeight,
        'final': finalWeight,
        'complexity': stats.complexity.name,
        'bonuses': [rowBonus, relationsBonus, historicalBonus].map((e) => e.toStringAsFixed(2)).toList().toString(),
        'safety': safetyMultiplier,
      },
    );

    return finalWeight;
  }

  /// Attempts to abort a pending database operation.
  ///
  /// **Workflow:**
  /// 1. **Queue Purge:** Immediately removes the task from the scheduling queue.
  /// 2. **Signal Resolution:** Completes the associated [Future] with a
  ///    cancellation exception, unblocking the calling context.
  /// 3. **Cleanup:** Evicts the request from `_pendingRequests` to prevent
  ///    future memory leaks or dangling completions.
  ///
  /// **Constraint:** /// This method performs a "soft cancel" for queued tasks. If the task
  /// has already been dispatched to a worker, it will continue to run until
  /// completion (to ensure database consistency), but its result will be ignored.
  void cancelTask(int id) {
    FluentLog.warning('Requesting cancellation for task', tag: 'FluentEngine:cancel', context: {'taskId': id});

    _queue.removeWhere((t) => t.id == id);

    // Resolve pending future if it exists
    final Completer<dynamic>? completer = _pendingRequests.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(FluentEngineException('Task cancelled by user', component: 'cancelTask'));
    }
  }

  /// Executes a catastrophic recovery of the database engine, forcing an
  /// emergency reset of the engine state and pending operations.
  ///
  /// **Responsibility:**
  /// 1. **Deadlock Recovery:** Forcefully clears internal synchronization barriers
  ///    and timers to recover from unrecoverable hang states.
  /// 2. **State Purge:** Resets all concurrency semaphores, internal queues,
  ///    and active communication channels to restore a consistent baseline.
  /// 3. **Request Abort:** Rejects all active [Completer] objects, propagating
  ///    a [FluentEngineException] to all waiting callers to prevent long-term
  ///    asynchronous stalls.
  ///
  /// **Critical Warning:**
  /// This operation is destructive. It should only be used as a final fallback
  /// when the engine becomes unresponsive. Use standard lifecycle methods
  /// (e.g., [pauseQueue] or [resumeQueue]) for routine management.
  Future<void> hardReset() async {
    FluentLog.warning('Initiating emergency hard reset', tag: 'FluentEngine:lifecycle', hint: 'This operation should only be used as a last resort when the engine becomes unresponsive.');

    await _performCleanup(wasEmergency: true);
    FluentLog.warning('Hard reset completed successfully', tag: 'FluentEngine:lifecycle');
  }

  /// Performs a coordinated, graceful shutdown of the database engine and
  /// all associated maintenance services.
  ///
  /// **Responsibility:**
  /// 1. **Lifecycle Management:** Prepares the system for planned events (e.g., app
  ///    backgrounding, engine restarts) by ensuring data integrity.
  /// 2. **Transaction Integrity:** Ensures that all currently executing operations
  ///    have an opportunity to finish, allowing SQLite to finalize pending
  ///    transactions and release file-system locks cleanly.
  /// 3. **Resource Reclamation:** Flushes internal request queues, discards
  ///    active [Completer] objects, and clears telemetry trackers to prevent
  ///    memory leaks during the transition to a non-active state.
  ///
  /// **Integrity:**
  /// Unlike [hardReset], this method ensures a graceful transition, preventing
  /// database corruption caused by sudden termination of file-system operations.
  Future<void> shutdown() async {
    FluentLog.info('Initiating shutdown', tag: 'FluentEngine:lifecycle');

    await _performCleanup(wasEmergency: false);
    FluentLog.info('Graceful shutdown completed successfully', tag: 'FluentEngine:lifecycle');
  }

  /// Performs a complete destruction of the engine's state and permanently
  /// deletes the internal system telemetry database.
  ///
  /// This method is typically called by [FluentDb.destroyAllDatabases] during
  /// a catastrophic reset or user logout to ensure no traces of system metrics remain.
  Future<void> destroy() async {
    FluentLog.warning('Destroying FluentEngine state and telemetry database...', tag: 'FluentEngine:destroy');
    await _performCleanup(wasEmergency: false);

    await _systemDb.destroySystemDb();

    FluentLog.info('Engine destruction complete.', tag: 'FluentEngine:destroy');
  }

  /// Performs a comprehensive teardown of the engine's internal state.
  ///
  /// **Responsibility:**
  /// 1. **State Reset:** Clears concurrency semaphores, pause barriers, and
  ///    database registry maps.
  /// 2. **Pending Resolution:** Rejects all active [Completer] objects, notifying
  ///    callers that the engine is no longer capable of fulfilling their requests.
  /// 3. **Resource Reclamation:** Stops all background timers ([_saveTimer],
  ///    [_analyzeTimer]) and clears the operation queue to prevent memory leaks.
  ///
  /// **Integrity:**
  /// Distinguishes between [wasEmergency] (Hard Reset) and standard shutdown
  /// to provide meaningful error messages for debugging lifecycle transitions.
  Future<void> _performCleanup({required bool wasEmergency}) async {
    FluentLog.info(wasEmergency ? 'Performing emergency engine cleanup' : 'Performing graceful engine cleanup', tag: 'FluentEngine:lifecycle', context: {'wasEmergency': wasEmergency});

    _activeReadsPerDb.clear();
    _activeWritesPerDb.clear();

    _isGlobalPaused = false;
    _pausedDbs.clear();

    if (_globalPauseCompleter != null && !_globalPauseCompleter!.isCompleted) {
      _globalPauseCompleter!.completeError(FluentEngineException(wasEmergency ? 'Emergency reset aborted global pause.' : 'Engine shutdown aborted global pause.', component: 'performCleanup'));
      _globalPauseCompleter = null;
    }

    for (final completer in _dbPauseCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(FluentEngineException(wasEmergency ? 'Emergency reset aborted DB pause.' : 'Engine shutdown aborted DB pause.', component: 'performCleanup'));
      }
    }
    _dbPauseCompleters.clear();

    _databases.clear();
    _dbTables.clear();
    _dbRelationsCount.clear();

    for (final Timer timer in _dbPauseTimers.values) {
      timer.cancel();
    }
    _dbPauseTimers.clear();
    _globalPauseTimer?.cancel();
    _globalPauseTimer = null;

    if (_saveTimer != null && _saveTimer!.isActive) {
      _saveTimer!.cancel();
      _saveTimer = null;
    }

    if (_analyzeTimer != null && _analyzeTimer!.isActive) {
      _analyzeTimer!.cancel();
      _analyzeTimer = null;
    }

    _activeCollapses.clear();
    _configs.clear();

    if (_pendingRequests.isNotEmpty) {
      final String msg = wasEmergency ? 'Database engine forcefully restarted.' : 'Database engine shutting down.';
      for (final Completer<dynamic> completer in _pendingRequests.values) {
        if (!completer.isCompleted) completer.completeError(FluentEngineException(msg, component: 'performCleanup'));
      }
      _pendingRequests.clear();
    }

    _queue.clear();

    FluentLog.info('Cleanup sequence completed', tag: 'FluentEngine:lifecycle');
  }

  /// Dispatches a system-level administrative task (e.g., stats flush,
  /// schema maintenance) into the primary execution pipeline.
  ///
  /// **Responsibility:**
  /// 1. **Pipeline Routing:** Delegates the task to [_executeTaskInPipeline]. This
  ///    ensures that maintenance operations respect the same scheduling,
  ///    priority, and concurrency constraints as standard user transactions.
  /// 2. **Integrity Assurance:** By funneling system tasks through the main
  ///    pipeline, we guarantee that background operations do not cause race
  ///    conditions or deadlock with pending user data operations, as they
  ///    compete for access within a single, unified semaphore system.
  /// 3. **Observability:** Centralizing execution allows us to track system
  ///    maintenance impact on performance metrics using our telemetry trackers.
  Future<dynamic> _executeSystemTask(FluentTask task) async => _executeTaskInPipeline(task);

  /// Atomically purges pending operations from the execution queue for a specific
  /// database or table context.
  ///
  /// **Responsibility:**
  /// 1. **Data Consistency:** Prevents invalid operations (e.g., updates or deletes)
  ///    from executing against data that is being truncated or destroyed.
  /// 2. **Resource Reclamation:** Immediately triggers [cancelTask] for all matched
  ///    items, ensuring that associated [Completer] objects are rejected and memory
  ///    is freed without waiting for the task to reach the front of the queue.
  /// 3. **Concurrency Safety:** Neutralizes pending tasks that could otherwise
  ///    result in `SQLiteException` errors (e.g., attempting to access a table
  ///    that no longer exists).
  ///
  /// **Lifecycle Note:**
  /// This method is strictly non-blocking and operates exclusively on the [_queue].
  /// It does not affect tasks already dispatched to the execution pipeline or the
  /// physical database state; it merely acts as a "flight cancellation" for
  /// tasks that have not yet begun.
  void _purgePendingTasks({required String dbName, String? tableName}) {
    final Set<int> taskIdsToCancel = _queue.where((t) => t.dbName == dbName && (tableName == null || t.table == tableName)).map((t) => t.id).toSet();

    if (taskIdsToCancel.isEmpty) return;

    for (final int id in taskIdsToCancel) {
      final Completer<dynamic>? completer = _pendingRequests.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(FluentTaskCancelledException('Task purged due to structural clear', component: 'purgePendingTasks'));
      }
    }

    _queue.removeWhere((t) => taskIdsToCancel.contains(t.id));

    FluentLog.warning('Purged ${taskIdsToCancel.length} pending tasks due to structural clear', tag: 'FluentEngine:purge');
  }

  /// Performs an in-place analysis of a database table to synchronize
  /// runtime statistics with the actual physical row count.
  ///
  /// **Responsibility:**
  /// 1. **Data Verification:** Executes a `SELECT COUNT(*)` query to fetch
  ///    the ground-truth row count from the database.
  /// 2. **State Reconciliation:** Updates the [FluentTableStatsTracker] map. If the
  ///    rowCount differs, it flags the tracker as `isDirty`, signaling that
  ///    persistence (saveStats) is required.
  /// 3. **Metrics Integration:** Merges current row count with existing
  ///    metadata (like relations count) to provide a full health profile of the table.
  ///
  /// **Lifecycle Note:**
  /// This is a high-cost I/O operation. It is triggered by the [FluentEngine]
  /// maintenance cycles to ensure the query planner and heuristics remain accurate.
  Future<void> _analyzeStats(FluentTask task) async {
    final Database? db = _databases[task.dbName];
    if (db != null && db.isOpen) {
      final int? count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM ${task.table}'));

      FluentLog.debug('Analysis complete', tag: 'FluentEngine:analysis', context: {'db': task.dbName, 'table': task.table, 'rowCount': count});

      final FluentTableStatsTracker tracker = FluentTableStatsTracker();
      final String key = '${task.dbName}:${task.table}';
      final int relCount = _dbRelationsCount[task.dbName]?[task.table] ?? 0;

      final TableStats? stats = tracker._statsMap[key];
      if (stats != null) {
        if (stats.rowCount != (count ?? 0)) {
          stats.rowCount = count ?? 0;
          tracker.markAsDirty();
        }
      } else {
        tracker._statsMap[key] = TableStats(dbName: task.dbName, tableName: task.table, relationsCount: relCount, rowCount: count ?? 0);
        tracker.markAsDirty();
      }
    }
  }

  /// Attempts to collapse multiple sequential [FluentDbAction.save] tasks into a
  /// single batched operation to optimize I/O throughput.
  ///
  /// **Responsibility:**
  /// 1. **Batch Accumulation:** Scans the queue for subsequent tasks targeting the
  ///    same database and table.
  /// 2. **Execution Efficiency:** Reduces filesystem transaction overhead by
  ///    combining data from individual tasks into a single atomic payload.
  /// 3. **Heuristic Capping:** Limits the total execution weight of the merged
  ///    task to avoid overwhelming the database with overly large atomic writes.
  ///
  /// **Workflow:**
  /// - If successful, returns a new "Super-Task" containing the aggregated data
  ///   and a list of all merged task references.
  /// - Returns `null` if no batchable tasks are found or if the action is not a save.
  FluentTask? _attemptBatching({required FluentTask rootTask, required int rootIndex, required List<FluentTask> queue, required List<int> outIndicesToRemove}) {
    if (rootTask.action != FluentDbAction.save) return null;

    final List<FluentTask> merged = [rootTask];
    outIndicesToRemove.add(rootIndex);

    int totalWeight = rootTask.executionWeight;

    for (int i = rootIndex + 1; i < queue.length; i++) {
      final FluentTask candidate = queue[i];

      if (candidate.dbName == rootTask.dbName && candidate.table == rootTask.table && candidate.action != rootTask.action) {
        break;
      }

      if (candidate.dbName == rootTask.dbName && candidate.table == rootTask.table && candidate.action == rootTask.action) {
        merged.add(candidate);
        outIndicesToRemove.add(i);
        totalWeight += candidate.executionWeight;
        continue;
      }
    }

    if (merged.length == 1) {
      outIndicesToRemove.clear();
      return null;
    }

    final List<dynamic> batchedData = merged.expand((t) => t.data is List ? (t.data as List) : [t.data]).where((d) => d != null).toList();

    final int finalWeight = math.min(2000, totalWeight);

    FluentLog.debug('Auto-Batching successful', tag: 'FluentTaskMerger', context: {'table': rootTask.table, 'mergedCount': merged.length, 'newWeight': finalWeight});

    return rootTask.copyWith(data: batchedData, executionWeight: finalWeight, mergedTasks: merged);
  }
}
