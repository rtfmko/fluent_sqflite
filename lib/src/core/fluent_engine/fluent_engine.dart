// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The central orchestrator for the FluentSQFLite database layer.
///
/// **Role:**
/// The [FluentEngine] acts as the bridge between the UI-facing Main Isolate
/// and the background Isolate responsible for heavy database I/O. It implements a
/// sophisticated task-scheduling and execution pipeline that ensures thread
/// safety and maximizes performance.
///
/// **Key Responsibilities:**
/// * **Concurrency Management:** Routes database tasks between the Main thread
///   (for immediate consistency) and the Worker Isolate (for heavy lifting),
///   using a priority-based queue and a "busy" worker flag.
/// * **Telemetry & APM:** Integrates with [FluentTableStatsTracker] to provide
///   real-time performance monitoring, schema analysis, and heavy-mutation
///   detection (log-driven diagnostics).
/// * **Task Lifecycle:** Manages complex request states (Futures, Streams, and
///   Chunk accumulators), providing a unified API for async operations.
/// * **Resilience:** Implements automatic re-analysis triggers, hard-reset
///   recovery for unresponsive isolates, and intelligent task weighting based
///   on row count, memory payload, and historical latency.
///
/// **Usage:**
/// This class should be instantiated as a singleton and serves as the primary
/// access point for executing `FluentTask` operations, managing database warmups,
/// and coordinating persistence cascades.
class FluentEngine {
  /// The singleton instance of the [FluentEngine].
  static final FluentEngine _instance = FluentEngine._internal();

  /// Accesses the global [FluentEngine] instance.
  factory FluentEngine() => _instance;

  /// Private constructor for the singleton pattern.
  FluentEngine._internal();

  /// Registry for outstanding async tasks, allowing completion when the worker reports back.
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  /// Controllers for streaming large result sets that are fetched in chunks to avoid OOM errors.
  final Map<int, StreamController<List<Map<String, dynamic>>>> _streamRequests = {};

  /// Buffers for accumulating partial data chunks before flushing to the request initiator.
  final Map<int, List<Map<String, dynamic>>> _chunkAccumulators = {};

  /// Performance tuning configurations per table or database group.
  final Map<String, SQLitePerformanceConfig> _configs = {};

  /// Prioritized queue of [FluentTask] operations; sorted by weight and policy rules to
  /// prioritize critical UI-blocking reads over background synchronization.
  final List<FluentTask> _queue = [];

  /// Deduplication layer: stores active Futures for identical queries to prevent
  /// redundant IO work when multiple components request the same data simultaneously.
  final Map<String, Future<dynamic>> _activeCollapses = {};

  /// Atomic counter for generating unique sequence IDs for tracking cross-isolate communication.
  int _idCounter = 0;

  /// Concurrency guards: flags tracking if the background isolate or the main thread
  /// executor are currently occupied, preventing race conditions.
  bool _isIsolateWorkerBusy = false;
  bool _isMainWorkerBusy = false;

  /// Coordination locks for native transaction support; when true, the queue
  /// stops dispatching new tasks to allow the main thread exclusive database access.
  Completer<void>? _pauseCompleter;
  bool _isPaused = false;

  /// Communication pipe to the background isolate, used to ship serialized tasks for processing.
  SendPort? _toWorker;

  /// Handle to the underlying background isolate thread.
  Isolate? _isolateInstance;

  /// Periodic timer for triggering maintenance tasks or telemetry flush cycles.
  Timer? _saveTimer;

  /// Dirty-state flag indicating if there are telemetry metrics awaiting persistence.
  bool _hasUnsavedChanges = false;

  /// Increments and returns the next unique operation ID.
  int get _nextId => ++_idCounter;

  /// Safely pauses the task dispatching queue and suspends execution until the
  /// currently in-flight operations (on both Main thread and Background Isolate)
  /// are fully completed.
  ///
  /// This method is crucial for maintaining data consistency during heavy
  /// administrative operations like:
  /// 1. **Native SQLite Transactions:** Ensures no background task conflicts
  ///    with a transaction running on the main thread.
  /// 2. **Hard Resets/Migrations:** Prevents data race conditions by draining
  ///    the pipeline before modifying schema or tearing down the isolate.
  ///
  /// **Workflow:**
  /// - Sets [_isPaused] to true to stop `_processNext()` from picking up new tasks.
  /// - If workers are busy, blocks the caller using [_pauseCompleter] until the
  ///   workers trigger `_checkPauseState()` upon completing their last task.
  Future<void> pauseQueue() async {
    _isPaused = true;

    // If both workers are already idle, return immediately.
    if (!_isIsolateWorkerBusy && !_isMainWorkerBusy) {
      FluentLog.debug('Queue paused instantly. Workers are idle.', tag: 'FluentEngine:pauseQueue');
      return;
    }

    FluentLog.debug('Queue paused. Waiting for in-flight tasks to finish...', tag: 'FluentEngine:pauseQueue');

    // Initialize completer and wait for workers to report completion
    _pauseCompleter ??= Completer<void>();
    await _pauseCompleter!.future;

    FluentLog.debug('All in-flight tasks finished. Safe to proceed.', tag: 'FluentEngine:pauseQueue');
  }

  /// Resumes task dispatching and triggers the immediate processing of the
  /// internal task queue.
  ///
  /// This method is called after an atomic transaction or administrative
  /// routine completes, effectively unlocking the [FluentEngine] to
  /// resume traffic between the main thread and background isolate.
  ///
  /// **Workflow:**
  /// - Resets the [_isPaused] flag to allow `_processNext()` to dispatch tasks.
  /// - Initiates the processing loop to clear the backlog of tasks accumulated
  ///   while the queue was suspended.
  void resumeQueue() {
    _isPaused = false;
    FluentLog.debug('Queue resumed. Processing pending tasks...', tag: 'FluentEngine:queue');
    _processNext();
  }

  /// Monitors worker state to determine if the pipeline has successfully "drained."
  ///
  /// This internal helper is triggered whenever a worker finishes a task
  /// ([_isIsolateWorkerBusy] or [_isMainWorkerBusy] becomes false). If a
  /// transaction pause is in progress (`_isPaused`) and no tasks remain in
  /// execution, it resolves the [_pauseCompleter] to notify the waiting thread
  /// that exclusive database access is now safe.
  void _checkPauseState() {
    if (_isPaused && !_isIsolateWorkerBusy && !_isMainWorkerBusy) {
      if (_pauseCompleter != null && !_pauseCompleter!.isCompleted) {
        FluentLog.debug('Pipeline drained. Resolving pause request.', tag: 'FluentEngine:pause');
        _pauseCompleter!.complete();
      }
      _pauseCompleter = null;
    }
  }

  /// Initializes the background database worker isolate with database configurations,
  /// performance manifests, and relation metadata.
  ///
  /// **Workflow:**
  /// 1. **Isolation:** Spawns a dedicated background isolate (`_fluentWorkerEntryPoint`).
  /// 2. **Handshake:** Establishes a communication pipe ([SendPort]) for cross-thread messaging.
  /// 3. **Manifest Compilation:** Maps [SQLitePerformanceConfig] and schema metadata
  ///    into a serializable format (`isolateDbConfigs`) for the worker.
  /// 4. **Registration:** Sends the complete configuration package to the isolate
  ///    to enable localized I/O processing.
  Future<void> initMultiple({
    required Map<String, String> dbPaths,
    required Map<String, List<Map<String, dynamic>>> relationMap,
    required Map<String, SQLitePerformanceConfig> configs,
    required Map<String, List<String>> dbTables,
    required Map<String, Map<String, int>> dbRelationsCount,
  }) async {
    if (_toWorker != null) return;

    _configs.clear();
    _configs.addAll(configs);

    final ReceivePort initReceivePort = ReceivePort();
    try {
      _isolateInstance = await Isolate.spawn(_fluentWorkerEntryPoint, initReceivePort.sendPort);
      final Object? firstMsg = await initReceivePort.first;
      if (firstMsg is! SendPort) {
        throw Exception("Failed to get SendPort from Isolate");
      }
      _toWorker = firstMsg;
    } finally {
      initReceivePort.close();
    }

    final ReceivePort responsePort = ReceivePort();
    responsePort.listen(_handleWorkerMessage);

    final Map<String, Map<String, dynamic>> isolateDbConfigs = {};

    for (final MapEntry<String, SQLitePerformanceConfig> entry in configs.entries) {
      final String dbName = entry.key;
      final SQLitePerformanceConfig cfg = entry.value;

      isolateDbConfigs[dbName] = {
        'cacheSize': cfg.cacheSize.rawValue,
        'tempStoreInMemory': cfg.tempStoreInMemory,
        'tables': dbTables[dbName] ?? <String>[],
        'relationsManifest': dbRelationsCount[dbName] ?? <String, int>{},
      };
    }

    _sendMessageToIsolate(
      IsolateRequest(
        cmd: IsolateCmd.init,
        data: IsolateHelper(dbPaths: dbPaths, relationMap: relationMap, dbConfigs: isolateDbConfigs).toMap(),
        replyPort: responsePort.sendPort,
      ),
    );

    FluentLog.info('FluentEngine: Isolate spawned with full APM and performance manifest', tag: 'FluentEngine:initMultiple', context: {'totalDatabases': dbPaths.length});
  }

  /// Dispatches a database task to the processing pipeline, applying "Request Collapsing"
  /// for read-only operations to eliminate redundant I/O.
  ///
  /// **Workflow:**
  /// 1. **Collapsing Check:** Identifies read-heavy actions eligible for deduplication.
  /// 2. **Registry Lookup:** Returns an existing Future if the operation is already in-flight.
  /// 3. **Execution & Cleanup:** Executes the task in the pipeline and ensures the
  ///    future is evicted from the `_activeCollapses` map once resolved.
  Future<dynamic> dispatch(FluentTask task) async {
    final bool canCollapse =
        task.policy.cancelIfDuplicate! &&
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

  /// Prepares and submits a database task into the execution pipeline.
  ///
  /// **Workflow:**
  /// 1. **Identity & Weighting:** Assigns a unique tracking ID and calculates
  ///    the execution weight based on task complexity (to inform priority ordering).
  /// 2. **Completer Registration:** Creates a `Completer` for the operation
  ///    so the caller can `await` the result once the worker completes the task.
  /// 3. **Queueing:** Moves the task into the prioritized queue via `_enqueue`.
  /// 4. **Accumulation:** Initializes a resul
  Future<dynamic> _executeTaskInPipeline(FluentTask task) async {
    final int id = _nextId;
    task.id = id;

    // Calculate weight for priority ordering in the queue
    final int weight = _calculateFinalWeight(task);
    task.executionWeight = weight;

    final Completer<dynamic> completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    // Initialize buffer for chunked results (e.g., large result sets)
    _chunkAccumulators[id] = List<Map<String, dynamic>>.empty(growable: true);

    FluentLog.debug('Enqueuing task to pipeline', tag: 'FluentEngine:pipeline', context: {'taskId': id, 'action': task.action.toString(), 'table': task.table, 'weight': weight});

    _enqueue(task);

    return completer.future;
  }

  /// Dispatches a database task that returns data via a continuous [Stream]. //todo in next release
  Stream<List<Map<String, dynamic>>> _dispatchStream(FluentTask task) {
    final int id = _nextId;
    task.id = id;

    final StreamController<List<Map<String, dynamic>>> controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onCancel: () {
        FluentLog.debug('Stream cancelled by subscriber', tag: 'FluentEngine:stream', context: {'taskId': id});
        cancelTask(id);
        _streamRequests.remove(id);
      },
    );

    _streamRequests[id] = controller;
    _enqueue(task);

    return controller.stream;
  }

  /// Adds a [FluentTask] to the execution queue, using a binary search algorithm
  /// to maintain strict ordering based on priority, 'force' status, and weight.
  ///
  /// **Performance Optimization:**
  /// The method employs a binary search ($O(\log N)$) to locate the insertion index.
  /// This prevents UI-thread stutters when thousands of tasks are enqueued
  /// simultaneously (e.g., during bulk synchronization or initialization).
  ///
  /// **Sorting Logic:**
  /// 1. [force] tasks are always prioritized ahead of non-force tasks.
  /// 2. If flags match, tasks are sorted by [priority].
  /// 3. If priorities match, tasks are sorted by [executionWeight].
  /// 4. If all parameters are equal, FIFO order is preserved by placing the
  ///    new task after existing ones.
  void _enqueue(FluentTask task) {
    _hasUnsavedChanges = true;

    // Calculate execution weight if not already assigned
    if (task.executionWeight == 0) {
      task.executionWeight = _calculateFinalWeight(task);
    }

    if (_queue.isEmpty) {
      _queue.add(task);
      _processNext();
      return;
    }

    // Binary search for the insertion index
    int low = 0;
    int high = _queue.length;

    while (low < high) {
      // Bitwise shift for fast division by 2
      final int mid = (low + high) >> 1;
      final current = _queue[mid];

      bool insertBefore = false;

      // Priority determination logic
      if (task.force && !current.force) {
        insertBefore = true;
      } else if (!task.force && current.force) {
        insertBefore = false;
      } else if (task.force && current.force) {
        // Preserve FIFO for force tasks
        insertBefore = false;
      } else {
        final int taskPriority = task.policy.priority!;
        final int currentPriority = current.policy.priority!;

        if (taskPriority > currentPriority) {
          insertBefore = true;
        } else if (taskPriority < currentPriority) {
          insertBefore = false;
        } else {
          // If priorities match, compare execution weight
          if (task.executionWeight > current.executionWeight) {
            insertBefore = true;
          } else {
            // Preserve FIFO for equal-weight tasks
            insertBefore = false;
          }
        }
      }

      if (insertBefore) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }

    _queue.insert(low, task);

    FluentLog.debug(
      'Task enqueued at position $low',
      tag: 'FluentEngine:queue',
      context: {'taskId': task.id, 'action': task.action.toString(), 'priority': task.policy.priority, 'weight': task.executionWeight, 'isForce': task.force},
    );

    _processNext();
  }

  /// The core FluentEngine loop that inspects the queue and dispatches tasks to
  /// the appropriate thread based on performance strategy and load availability.
  ///
  /// **Workflow:**
  /// 1. **Guard Clauses:** Stops if the queue is paused or no workers are available.
  /// 2. **Strategy Routing:** Evaluates [FluentDbExecutionStrategy] (Sequential vs WAL).
  /// 3. **Load Balancing:** Checks thread availability (_isMainWorkerBusy / _isIsolateWorkerBusy).
  /// 4. **Execution:** Delegates task to the Main thread or the background isolate.
  void _processNext() {
    // If a transaction is in progress, we halt all new task dispatching
    if (_isPaused) return;

    // Flush telemetry statistics if idle
    if (_queue.isEmpty) {
      if (!_isIsolateWorkerBusy && !_isMainWorkerBusy) {
        _checkAndFlushStats();
      }
      return;
    }

    if (_toWorker == null) return;

    FluentTask? taskToExecute;
    bool isWriteAction = false;
    int targetIndex = -1;

    SQLitePerformanceConfig? selectedConfig;

    for (int i = 0; i < _queue.length; i++) {
      final FluentTask currentTask = _queue[i];
      final SQLitePerformanceConfig? config = _configs[currentTask.dbName];
      final FluentDbExecutionStrategy strategy = config?.executionStrategy ?? FluentDbExecutionStrategy.concurrentWAL;

      final bool currentIsWrite =
          currentTask.action == FluentDbAction.save ||
          currentTask.action == FluentDbAction.update ||
          currentTask.action == FluentDbAction.delete ||
          currentTask.action == FluentDbAction.updateMultipleFields ||
          currentTask.action == FluentDbAction.updateSingleField;

      // --- STRATEGY A: strictSequential ---
      // Exclusive lock: ensures zero concurrent I/O. Safe for destructive operations.
      if (strategy == FluentDbExecutionStrategy.strictSequential) {
        if (_isMainWorkerBusy || _isIsolateWorkerBusy) {
          continue;
        }

        taskToExecute = currentTask;
        isWriteAction = currentIsWrite;
        targetIndex = i;
        selectedConfig = config;
        break;
      }

      // --- STRATEGY B: sequentialWAL ---
      // Single-thread-like order in a WAL environment.
      if (strategy == FluentDbExecutionStrategy.sequentialWAL) {
        if (_isMainWorkerBusy || _isIsolateWorkerBusy) {
          continue;
        }

        taskToExecute = currentTask;
        targetIndex = i;
        selectedConfig = config;

        if (currentIsWrite) {
          isWriteAction = true;
        } else {
          final bool shouldGoToIsolate = currentTask.policy.useIsolate ?? (currentTask.executionWeight >= 25);
          isWriteAction = !shouldGoToIsolate;
        }
        break;
      }

      // --- STRATEGY C: concurrentWAL ---
      // Maximum throughput mode: allows parallel Reads and Writes.
      if (strategy == FluentDbExecutionStrategy.concurrentWAL) {
        if (currentIsWrite) {
          if (!_isMainWorkerBusy) {
            taskToExecute = currentTask;
            isWriteAction = true;
            targetIndex = i;
            selectedConfig = config;
            break;
          }
        } else {
          final bool shouldGoToIsolate = currentTask.policy.useIsolate ?? (currentTask.executionWeight >= 25);

          if (shouldGoToIsolate || currentTask.force) {
            if (!_isIsolateWorkerBusy) {
              taskToExecute = currentTask;
              isWriteAction = false;
              targetIndex = i;
              selectedConfig = config;
              break;
            }
          } else {
            if (!_isMainWorkerBusy) {
              taskToExecute = currentTask;
              isWriteAction = true;
              targetIndex = i;
              selectedConfig = config;
              break;
            } else if (!_isIsolateWorkerBusy) {
              taskToExecute = currentTask;
              isWriteAction = false;
              targetIndex = i;
              selectedConfig = config;
              break;
            }
          }
        }
      }
    }

    if (taskToExecute == null || targetIndex == -1) return;

    FluentLog.debug(
      'Starting task processing',
      tag: 'FluentEngine:queue',
      context: {
        'dbName': taskToExecute.dbName,
        'action': taskToExecute.action.name,
        'staticWeight': taskToExecute.staticWeight,
        'executionWeight': taskToExecute.executionWeight,
        'strategy': selectedConfig?.executionStrategy.name ?? FluentDbExecutionStrategy.concurrentWAL.name,
      },
    );

    _queue.removeAt(targetIndex);

    if (isWriteAction) {
      _isMainWorkerBusy = true;

      _executeInMain(taskToExecute)
          .then((result) {
            _isMainWorkerBusy = false;
            _checkPauseState();
            _processNext();
          })
          .catchError((error) {
            _isMainWorkerBusy = false;
            _checkPauseState();
            _processNext();
          });

      _processNext();
    } else {
      _isIsolateWorkerBusy = true;
      _sendMessageToIsolate(IsolateRequest(cmd: IsolateCmd.execute, task: taskToExecute));
    }
  }

  /// Monitors and synchronizes database telemetry and performance statistics.
  ///
  /// **Workflow:**
  /// 1. **State Check:** Consults the [FluentTableStatsTracker] to determine if
  ///    performance metrics (rows, latency, index hits) have changed.
  /// 2. **Serialization:** Exports the 'dirty' (unsaved) data snapshots.
  /// 3. **Offloading:** Dispatches the statistics payload to the background
  ///    isolate for persistent storage without blocking the main execution thread.
  /// 4. **Cleanup:** Resets the dirty flag to prevent redundant IO operations.
  void _checkAndFlushStats() {
    final FluentTableStatsTracker tracker = FluentTableStatsTracker();
    if (tracker.isDirty) {
      final List<Map<String, dynamic>> dirtyData = tracker.exportDirtyData();
      if (dirtyData.isNotEmpty) {
        FluentLog.debug('Flushing accumulated telemetry stats', tag: 'FluentEngine:stats', context: {'statsCount': dirtyData.length});

        _sendMessageToIsolate(
          IsolateRequest(
            cmd: IsolateCmd.saveStats,
            task: FluentTask(id: _systemId, action: FluentDbAction.none),
            data: dirtyData,
          ),
        );
        tracker.clearDirtyFlag();
      }
    }
  }

  /// Safely routes a serialized request to the background database isolate.
  ///
  /// **Workflow:**
  /// 1. **Sanity Check:** Validates that the background isolate communication
  ///    channel (`_toWorker`) is active.
  /// 2. **Serialization:** Converts the [IsolateRequest] object into a
  ///    cross-thread-safe primitive map for transport.
  /// 3. **Dispatch:** Posts the serialized message to the Isolate's message loop.
  void _sendMessageToIsolate(IsolateRequest message) {
    if (_toWorker == null) {
      FluentLog.warning('Attempted to send message to uninitialized Isolate', tag: 'FluentEngine:transport', hint: 'Ensure that initMultiple() has been called and the Isolate is running.');
      return;
    }

    _toWorker?.send(message.toMap());
  }

  /// The central message dispatcher for the Isolate-to-Main thread communication pipe.
  ///
  /// This method acts as the "Traffic Control" for all responses coming from the
  /// background database worker. It deserializes raw incoming data into
  /// [IsolateResponse] objects and routes them to dedicated handler methods
  /// based on their specific status.
  ///
  /// **Workflow:**
  /// 1. **Validation:** Ensures the message structure is a compatible `Map`.
  /// 2. **Deserialization:** Converts the map to a typed [IsolateResponse].
  /// 3. **Routing:** Uses a pattern-matched switch to trigger lifecycle events,
  ///    error recovery, or data chunk completion callbacks.
  void _handleWorkerMessage(dynamic message) {
    if (message is! Map) return;
    final Map<String, dynamic> rawMessage = message.cast<String, dynamic>();
    final IsolateResponse response = IsolateResponse.fromMap(rawMessage);

    // Decoupled log and system event processing
    unawaited(_interceptLogs(response));

    // Route the response to the corresponding specialized handler
    switch (response.status) {
      case IsolateStatus.none:
        break;

      case IsolateStatus.ok:
        _handleOkStatus(response);
        break;

      case IsolateStatus.progress:
        _handleProgress(response);
        break;

      case IsolateStatus.warmupDone:
        _handleWarmupDone();
        break;

      case IsolateStatus.analyzeDone:
        _handleAnalyzeDone(response);
        break;

      case IsolateStatus.error:
        _handleError(response);
        break;

      case IsolateStatus.saveDone:
        _handleSaveDone(response);
        break;

      case IsolateStatus.terminated:
        FluentLog.info('Worker confirmed termination.', tag: 'FluentEngine:lifecycle');
        break;
    }
  }

  /// Asynchronously intercepts and processes telemetry data from a background worker isolate.
  ///
  /// This method runs in a non-blocking fashion, ensuring that diagnostic logging
  /// and error reporting do not introduce latency into the main task processing pipeline.
  ///
  /// **Responsibility Breakdown:**
  /// * **Log Aggregation:** Flushes buffered logs from the isolate into the main
  ///   application's [FluentLog] sink, tagged by their originating [taskId].
  /// * **System Telemetry:** Monitors system-level commands (e.g., `_systemId`)
  ///   to track the health of the background engine.
  /// * **Unified Error Handling:** Captures `errorCode` signals to populate
  ///   error reporting tools with necessary context, including stack traces
  ///   and metadata for post-mortem debugging.
  Future<void> _interceptLogs(IsolateResponse response) async {
    // 1. Log Aggregation
    if (response.logs.isNotEmpty) {
      for (final logEntry in response.logs) {
        FluentLog.debug(logEntry, tag: 'FluentWorker:${response.task?.table ?? response.taskId}');
      }
    }

    // 2. System Monitoring
    if (response.taskId == _systemId) {
      FluentLog.info('System Task Processed: ${response.status}', tag: 'FluentWorker:System');
    }

    // 3. Error Telemetry (Unified)
    if (response.errorCode != null) {
      FluentLog.error(
        'Worker reported error: ${response.errorCode}',
        FluentEngineException('Worker reported error: ${response.errorCode}', component: 'FluentWorker', task: response.task),
        StackTrace.current,
        tag: 'FluentWorker:Error',
        context: {'taskId': response.taskId, 'data': response.data},
      );
    }
  }

  /// Handles the successful completion of an Isolate database task.
  ///
  /// **Workflow:**
  /// 1. **Concurrency Release:** Marks the isolate as idle and checks if the queue
  ///    is pending a pause (for transaction atomicity).
  /// 2. **Data Assembly:** Reconstructs the complete result set from chunk buffers
  ///    and resolves the associated [Completer] or [StreamController].
  /// 3. **Telemetry Integration:** Updates [FluentTableStatsTracker] with execution metrics,
  ///    cascading table impacts, and row-count performance data.
  /// 4. **Pipeline Resumption:** Triggers the next task in the queue.
  void _handleOkStatus(IsolateResponse response) {
    final int id = response.taskId;
    _isIsolateWorkerBusy = false;
    _checkPauseState();

    final List<Map<String, dynamic>> lastData = _parseData(response.data);
    final Completer<dynamic>? completer = _pendingRequests.remove(id);
    final List<Map<String, dynamic>>? accumulatedData = _chunkAccumulators.remove(id);

    // Finalize standard async requests
    if (completer != null && !completer.isCompleted) {
      final finalResult = accumulatedData != null ? [...accumulatedData, ...lastData] : lastData;
      completer.complete(finalResult);
    }

    // Finalize stream-based requests
    final StreamController<List<Map<String, dynamic>>>? controller = _streamRequests.remove(id);
    if (controller != null && !controller.isClosed) {
      if (lastData.isNotEmpty) controller.add(lastData);
      controller.close();
    }

    // Process system tasks without updating performance telemetry
    if (response.task != null && (response.task?.isSystem ?? false)) {
      _processNext();
      return;
    }

    // Update performance metrics for standard user operations
    if (response.task != null) {
      final tracker = FluentTableStatsTracker();
      final bool isWriteAction = response.task!.action == FluentDbAction.save || response.task!.action == FluentDbAction.update || response.task!.action == FluentDbAction.delete;

      FluentLog.debug('Task executed successfully', tag: 'FluentEngine:okStatus', context: {'taskId': id, 'duration': '${response.executionTime}ms', 'isWrite': isWriteAction});

      if (response.affectedTables.isNotEmpty) {
        final String rootTable = response.task!.table;
        bool isRootProcessedInCascade = false;

        response.affectedTables.forEach((tableName, encodedValue) {
          if (tableName == rootTable) isRootProcessedInCascade = true;

          // Unpack performance metrics from high-order bits
          final int pureElapsedMs = encodedValue >> 32;
          final int affectedRows = encodedValue & 0xFFFFFFFF;

          tracker.registerCascadeSuccess(dbName: response.task!.dbName, tableName: tableName, elapsedMs: pureElapsedMs, isWrite: isWriteAction, affectedRows: affectedRows, wasExecuted: true);
        });

        if (!isRootProcessedInCascade) {
          final int rootTime = response.affectedTables[rootTable] ?? response.executionTime;
          tracker.registerCascadeSuccess(
            dbName: response.task!.dbName,
            tableName: rootTable,
            elapsedMs: rootTime <= 0 ? 1 : rootTime,
            isWrite: isWriteAction,
            affectedRows: response.totalRows,
            wasExecuted: true,
          );
        }
      } else {
        tracker.registerSuccess(task: response.task!, elapsedMs: response.executionTime, isWrite: isWriteAction, rows: response.totalRows);
      }

      _hasUnsavedChanges = true;
    }

    _processNext();
  }

  /// Handles intermediate data chunks streaming from the background isolate.
  ///
  /// **Workflow:**
  /// 1. **Chunk Parsing:** Converts the raw isolate message into a list of maps.
  /// 2. **Stream Routing:** If a `Stream` subscription exists (e.g., UI observer),
  ///    it pushes the new chunk to the listeners immediately.
  /// 3. **Memory Accumulation:** Appends the chunk to the internal `_chunkAccumulators`
  ///    buffer, ensuring the full result set is ready once the final `IsolateStatus.ok`
  ///    message arrives.
  void _handleProgress(IsolateResponse response) {
    final int id = response.taskId;
    final List<Map<String, dynamic>> chunk = _parseData(response.data);

    FluentLog.debug('Received data chunk', tag: 'FluentEngine:progress', context: {'taskId': id, 'chunkSize': chunk.length});

    // If the request was opened via dispatchStream(), forward data to the stream
    final StreamController<List<Map<String, dynamic>>>? controller = _streamRequests[id];
    if (controller != null && !controller.isClosed) {
      controller.add(chunk);
    }

    // Accumulate the chunk in case the task expects the full result at the end
    final List<Map<String, dynamic>>? accumulator = _chunkAccumulators[id];
    if (accumulator != null) {
      accumulator.addAll(chunk);
    }
  }

  /// Finalizes the database worker initialization sequence.
  ///
  /// **Workflow:**
  /// 1. **Warmup Completion:** Acknowledges that the worker has finished
  ///    initial indexing and statistics pre-loading.
  /// 2. **Analysis Trigger:** Initiates database health/schema analysis
  ///    asynchronously to avoid blocking the main startup sequence.
  /// 3. **Persistence:** Starts the auto-save timer for telemetry and performance stats.
  void _handleWarmupDone() {
    FluentLog.info('Warmup & Stats pre-load complete.', tag: 'FluentEngine:warmupDone');
    // Trigger analysis in the background without waiting for it to finish,
    // ensuring the application reaches an "interactive" state faster.
    unawaited(_triggerDatabaseAnalysis());

    // Start the periodic flush cycle for performance metrics
    _startAutoSaveTimer();
  }

  /// Merges analysis results from the background worker into the main thread's
  /// performance tracking registry.
  ///
  /// **Workflow:**
  /// 1. **Data Normalization:** Processes the list of `TableStats` returned by the
  ///    database worker after an analysis cycle.
  /// 2. **Intelligent Patching:** Updates the `FluentStatsTracker` by performing a
  ///    "max-value" merge. It ensures that statistics only ever grow or stay the
  ///    same, preventing stale isolate data from overwriting fresher main-thread stats.
  /// 3. **Registry Resolution:** Completes the `_pendingRequests` future associated
  ///    with the analysis task, allowing the system to proceed.
  void _handleAnalyzeDone(IsolateResponse response) {
    final int id = response.taskId;

    if (response.data is List) {
      final List<dynamic> rawList = response.data as List;
      final FluentTableStatsTracker tracker = FluentTableStatsTracker();

      for (final dynamic item in rawList) {
        if (item is Map) {
          final Map<String, dynamic> statRow = item.cast<String, dynamic>();
          final TableStats incomingStats = TableStats.fromMap(statRow);
          final String key = '${incomingStats.dbName}:${incomingStats.tableName}';

          // Perform an intelligent merge to maintain the most accurate performance profile
          final TableStats? existingStats = tracker._statsMap[key];
          if (existingStats != null) {
            existingStats.rowCount = math.max(existingStats.rowCount, incomingStats.rowCount);

            if (incomingStats.totalReads > existingStats.totalReads) {
              existingStats.totalReads = incomingStats.totalReads;
            }
            if (incomingStats.totalWrites > existingStats.totalWrites) {
              existingStats.totalWrites = incomingStats.totalWrites;
            }
          } else {
            tracker._statsMap[key] = incomingStats;
          }
        }
      }
      FluentLog.info('Table Stats Tracker intelligently patched', tag: 'FluentEngine:analyzeDone', context: {'metricsProcessed': rawList.length});
    }

    final Completer<dynamic>? completer = _pendingRequests.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  /// Handles errors reported by the background database isolate.
  ///
  /// **Workflow:**
  /// 1. **Concurrency Recovery:** Clears the isolate busy flag to ensure the
  ///    FluentEngine doesn't hang.
  /// 2. **Telemetry Updates:** Reports the failure to [FluentTableStatsTracker] for
  ///    error rate monitoring.
  /// 3. **Future/Stream Resolution:** Propagates the error to the awaiting
  ///    [Completer] or [StreamController] so the calling code can handle the
  ///    exception gracefully.
  /// 4. **Cleanup:** Purges internal buffers (accumulators) and moves to the
  ///    next task in the queue to maintain system availability.
  void _handleError(IsolateResponse response) {
    final int id = response.taskId;

    _isIsolateWorkerBusy = false;
    final String errorMessage = response.data?.toString() ?? 'Unknown Isolate Error';
    FluentLog.error(
      'Database worker operation failed',
      FluentBaseException(errorMessage),
      StackTrace.current,
      tag: 'FluentEngine:error',
      context: {'taskId': id, 'error': errorMessage, 'taskAction': response.task?.action.toString() ?? 'unknown'},
    );

    if (response.task != null) {
      FluentTableStatsTracker().registerFailure(response.task!);
    }

    _pendingRequests.remove(id)?.completeError(errorMessage);

    // Notify stream subscribers of the failure and close the stream
    final StreamController<List<Map<String, dynamic>>>? failedController = _streamRequests.remove(id);
    if (failedController != null && !failedController.isClosed) {
      failedController.addError(errorMessage);
      failedController.close();
    }

    _chunkAccumulators.remove(id);
    _processNext();
  }

  /// Handles the acknowledgment from the background isolate that a persistence
  /// (e.g., stats flush or batch write) operation has completed successfully.
  ///
  /// **Workflow:**
  /// 1. **Registry Cleanup:** Removes the task from the pending requests registry.
  /// 2. **Completer Resolution:** Resolves the Future, signaling that the
  ///    persistence cascade is finished and data is safely written to disk.
  void _handleSaveDone(IsolateResponse response) {
    FluentLog.debug('Persistence cascade confirmed by worker', tag: 'FluentEngine:persistence', context: {'taskId': response.taskId});

    final Completer<dynamic>? completer = _pendingRequests.remove(response.taskId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  /// Initializes or resets the background synchronization timer for telemetry data.
  ///
  /// **Workflow:**
  /// 1. **De-duplication:** Cancels any existing timers to prevent overlapping
  ///    flush cycles.
  /// 2. **Periodic Maintenance:** Schedules a recurring check at a defined
  ///    [_saveInterval].
  /// 3. **Change Tracking:** Only triggers a database write (`triggerSaveStats`)
  ///    if the `_hasUnsavedChanges` flag is true, minimizing I/O overhead.
  void _startAutoSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(_saveInterval, (timer) async {
      if (_hasUnsavedChanges) {
        FluentLog.debug('Auto-save interval reached: Flushing pending stats', tag: 'FluentEngine:persistence');

        await _triggerSaveStats();
      }
    });
  }

  /// Triggers a persistence cascade to write accumulated telemetry statistics to the disk.
  ///
  /// **Workflow:**
  /// 1. **Data Gathering:** Exports the current state of [FluentTableStatsTracker].
  /// 2. **State Reset:** Updates the dirty flag (`_hasUnsavedChanges = false`)
  ///    before the operation, allowing the tracker to begin accumulating fresh
  ///    metrics immediately without blocking.
  /// 3. **Isolation Transmission:** Sends the stat payload to the background
  ///    worker via a system-reserved task ID ([_systemId]).
  /// 4. **Resilience:** If the save operation fails, the dirty flag is restored,
  ///    ensuring the next auto-save cycle will attempt to re-persist the data.
  Future<void> _triggerSaveStats() async {
    if (_toWorker == null) return;

    final List<TableStats> currentStats = FluentTableStatsTracker().getAllStats;
    if (currentStats.isEmpty) return;

    // Set dirty flag to false immediately to prevent redundant overlapping calls
    _hasUnsavedChanges = false;

    final Completer<dynamic> completer = Completer<dynamic>();
    _pendingRequests[_systemId] = completer;

    final List<Map<String, dynamic>> payload = currentStats.map((s) => s.buildJson()).toList();

    FluentLog.debug('Synchronizing telemetry to disk', tag: 'FluentEngine:persistence', context: {'statCount': payload.length});

    _sendMessageToIsolate(
      IsolateRequest(
        cmd: IsolateCmd.saveStats,
        task: FluentTask(id: _systemId, action: FluentDbAction.none),
        data: payload,
      ),
    );

    try {
      await completer.future;
      FluentLog.info('Telemetry successfully synchronized with disk', tag: 'FluentEngine:persistence');
    } catch (e, s) {
      _hasUnsavedChanges = true;
      FluentLog.error('Failed to persist statistics', e, s, tag: 'FluentEngine:persistence', context: {'error': e.toString()});
    }
  }

  /// Triggers a non-blocking background analysis of the database schema and
  /// performance metrics to optimize future query execution.
  ///
  /// **Workflow:**
  /// 1. **Request Dispatch:** Issues an `analyzeStats` command to the worker isolate.
  /// 2. **Async Wait:** Uses a [Completer] to suspend execution until the
  ///    background isolate returns the finalized performance profile.
  /// 3. **Memory Sync:** Once resolved, the FluentEngine updates the
  ///    [FluentTableStatsTracker] in-memory state with fresh data.
  Future<void> _triggerDatabaseAnalysis() async {
    if (_toWorker == null) return;

    FluentLog.info('Triggering background database analysis cascade', tag: 'FluentEngine:analysis');

    final Completer<dynamic> completer = Completer<dynamic>();
    _pendingRequests[_systemId] = completer;

    _sendMessageToIsolate(
      IsolateRequest(
        cmd: IsolateCmd.analyzeStats,
        task: FluentTask(id: _systemId, action: FluentDbAction.none),
      ),
    );

    try {
      await completer.future;
      FluentLog.info('Live analysis completed and applied to RAM memory', tag: 'FluentEngine:analysis');
    } catch (e, s) {
      FluentLog.error('Live analytics session failed', e, s, tag: 'FluentEngine:analysis', context: {'error': e.toString()});
    }
  }

  /// Safely deserializes raw isolate data into the typed structure expected by the FluentEngine.
  ///
  /// **Workflow:**
  /// 1. **Type Verification:** Confirms that the incoming [data] is a `List` before casting.
  /// 2. **Efficient Casting:** Uses `.cast<Map<String, dynamic>>()` to interpret the
  ///    collection of maps, which is optimized for performance in Dart's runtime.
  /// 3. **Null/Type Safety:** Returns an empty list if the input is null or incorrectly typed,
  ///    preventing runtime casting exceptions and ensuring downstream logic remains robust.
  List<Map<String, dynamic>> _parseData(dynamic data) {
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Executes a database operation directly on the Main thread.
  ///
  /// **Workflow:**
  /// 1. **Provider Resolution:** Locates the correct database provider for the
  ///    target table.
  /// 2. **Execution & Guarding:** Performs the operation with a strict [TimeoutException]
  ///    to prevent long-running queries from blocking the UI thread indefinitely.
  /// 3. **Performance Monitoring:** Captures execution metrics. If a write
  ///    operation exceeds a 100ms threshold (a "heavy mutation"), it triggers
  ///    automatic re-analysis and telemetry persistence.
  /// 4. **State Synchronization:** Updates the `FluentStatsTracker` to reflect
  ///    successful data changes or failures, ensuring statistics remain accurate.
  Future<dynamic> _executeInMain(FluentTask task) async {
    final Stopwatch sw = Stopwatch()..start();
    final String tableName = task.table;

    try {
      final FluentProvider provider = FluentDb.getProviderByTable(tableName);

      final dynamic result = await provider
          .internalExecute(task)
          .timeout(
            task.policy.timeout!,
            onTimeout: () {
              throw TimeoutException(
                '🎯 [Main Isolate Timeout] Database operation "${task.action.name}" on table "$tableName" '
                'exceeded its allowed limit of ${task.policy.timeout!.inSeconds}s!',
              );
            },
          );

      sw.stop();
      final int elapsedMs = sw.elapsedMilliseconds;

      final bool isWriteOp =
          task.action == FluentDbAction.save ||
          task.action == FluentDbAction.update ||
          task.action == FluentDbAction.delete ||
          task.action == FluentDbAction.updateMultipleFields ||
          task.action == FluentDbAction.updateSingleField;

      // Performance Telemetry: Flag heavy operations
      if (isWriteOp) {
        if (elapsedMs > 100) {
          FluentLog.warning(
            'Heavy mutation detected in Main thread',
            tag: 'FluentEngine:main_track',
            hint: 'Consider offloading this write operation to the isolate worker or optimizing the transaction batch size to keep main-thread execution below 100ms.',
            context: {'tableName': tableName, 'duration': '${elapsedMs}ms'},
          );

          FluentTableStatsTracker().registerCascadeSuccess(dbName: task.dbName, tableName: tableName, elapsedMs: elapsedMs, isWrite: true, affectedRows: 1);

          unawaited(_triggerSaveStats());
        } else {
          int finalDelta = 0;
          if (task.action == FluentDbAction.save) finalDelta = 1;
          if (task.action == FluentDbAction.delete) finalDelta = -1;

          FluentTableStatsTracker().registerSuccess(task: task, elapsedMs: elapsedMs, isWrite: true, delta: finalDelta);
        }
      } else {
        int finalRows = 0;
        if (result is List) {
          finalRows = result.length;
        }

        FluentTableStatsTracker().registerCascadeSuccess(dbName: task.dbName, tableName: tableName, elapsedMs: elapsedMs, isWrite: false, affectedRows: finalRows);
      }

      _hasUnsavedChanges = true;

      _pendingRequests.remove(task.id)?.complete(result);

      return result;
    } on TimeoutException catch (e, s) {
      FluentLog.error(
        'Main thread operation timed out',
        e,
        s,
        tag: 'FluentEngine:main_track',
        hint: 'Verify if the transaction duration exceeds the policy timeout or if the SQLite file is locked by a long-running background migration.',
        context: {'table': tableName, 'error': e.toString()},
      );
      FluentTableStatsTracker().registerFailure(task);
      _pendingRequests.remove(task.id)?.completeError(e);
      rethrow;
    } catch (e, s) {
      FluentLog.error('Critical execution error in Main thread', e, s, tag: 'FluentEngine:main_track', context: {'table': tableName, 'error': e.toString()});
      FluentTableStatsTracker().registerFailure(task);
      _pendingRequests.remove(task.id)?.completeError(e);
      rethrow;
    }
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

    // Physical table size multiplier
    final int safeRowCount = stats.rowCount < 0 ? 0 : stats.rowCount;
    final double rowMultiplier = 1.0 + (safeRowCount / 5000);

    // Session Payload: Accounts for RAM serialization overhead
    final int safePayload = stats.sessionPayload < 0 ? 0 : stats.sessionPayload;
    final double payloadMultiplier = 1.0 + (safePayload / 2500);

    // Complexity Multiplier: Adjusts priority for heavy schema operations
    final double complexityMultiplier = switch (stats.complexity) {
      TableComplexity.low => 0.8,
      TableComplexity.medium => 1.2,
      TableComplexity.high => 2.5,
      TableComplexity.extreme => 6.0,
    };

    // Relational Multiplier: Accounts for schema cascade depth
    final double relationsMultiplier = 1.0 + (stats.relationsCount * 0.25);

    // Performance degradation factor: Adjusts weight for high-latency operations
    final bool isWrite = task.action == FluentDbAction.update || task.action == FluentDbAction.delete || task.action == FluentDbAction.save;

    final double avgTimeMs = isWrite ? stats.avgWriteTimeMs : stats.avgReadTimeMs;

    // Gradual weight increase if avg time exceeds 50ms to prevent FluentEngine flooding
    final double timeMultiplier = 1.0 + (avgTimeMs > 50.0 ? (avgTimeMs / 100.0) : 0.0);

    // Calculate final product of all factors
    final double finalCalculated = staticWeight * rowMultiplier * payloadMultiplier * complexityMultiplier * relationsMultiplier * timeMultiplier;

    final int finalWeight = finalCalculated.round().clamp(0, 100000);

    FluentLog.debug(
      'Calculated task weight',
      tag: 'FluentEngine:weight',
      context: {'taskId': task.id, 'static': staticWeight, 'final': finalWeight, 'complexity': stats.complexity.name, 'avgTime': '${avgTimeMs.round()}ms'},
    );

    return finalWeight;
  }

  /// Attempts to cancel a pending or currently running database task.
  ///
  /// **Workflow:**
  /// 1. **Queue Purge:** Removes the task from the internal processing queue.
  /// 2. **Signal Resolution:** Immediately completes the associated [Future] or
  ///    [Stream] with a cancellation error to unblock the UI layer.
  /// 3. **Memory Cleanup:** Discards associated data accumulators.
  /// 4. **Worker Synchronization:** If the task was currently active in the
  ///    Isolate, resets the worker status and triggers the next queued item.
  /// 5. **Isolate Notification:** Sends a hard-cancel command to the background
  ///    worker to stop any ongoing database I/O.
  void cancelTask(int id) {
    FluentLog.warning('Requesting cancellation for task', tag: 'FluentEngine:cancel', context: {'taskId': id});

    final int initialQueueLength = _queue.length;
    _queue.removeWhere((t) => t.id == id);
    final bool wasInQueue = _queue.length < initialQueueLength;

    // Resolve pending future if it exists
    _pendingRequests.remove(id)?.completeError('Cancelled by user');

    // Notify stream listeners of cancellation
    final StreamController<List<Map<String, dynamic>>>? controller = _streamRequests.remove(id);
    if (controller != null && !controller.isClosed) {
      controller.addError('Cancelled by user');
      controller.close();
    }

    // Purge result buffers
    _chunkAccumulators.remove(id);

    // If the task was active (not in queue), reset the worker state to allow next task
    if (!wasInQueue && _isIsolateWorkerBusy) {
      _isIsolateWorkerBusy = false;
      Future.microtask(() => _processNext());
    }

    _sendMessageToIsolate(
      IsolateRequest(
        cmd: IsolateCmd.cancel,
        task: FluentTask(id: id, action: FluentDbAction.none),
      ),
    );
  }

  /// Performs a catastrophic recovery of the database isolate.
  ///
  /// **Workflow:**
  /// 1. **Resource Termination:** Forcefully kills the existing isolate to
  ///    break out of deadlocks or unrecoverable worker states.
  /// 2. **State Reset:** Purges all communication channels and concurrency flags.
  /// 3. **Request Purging:** Rejects all active `Completer` and `Stream` objects
  ///    with an Exception to notify callers that their pending tasks were aborted.
  /// 4. **Cleanup:** Clears internal queues and accumulators to ensure a clean
  ///    re-initialization state for the next session.
  Future<void> hardReset() async {
    FluentLog.warning('Initiating emergency hard reset', tag: 'FluentEngine:lifecycle', hint: 'This operation should only be used as a last resort when the worker isolate is unresponsive.');

    // Immediate termination
    if (_isolateInstance != null) {
      _isolateInstance!.kill(priority: Isolate.immediate);
      _isolateInstance = null;
    }

    await _performCleanup(wasEmergency: true);
    FluentLog.warning('Hard reset completed successfully', tag: 'FluentEngine:lifecycle');
  }

  /// Performs a coordinated, graceful shutdown of the database worker engine.
  ///
  /// This method is designed for planned lifecycle events, such as application
  /// backgrounding or engine restarts, ensuring that the worker isolate has a
  /// chance to finalize current transactions and release file system locks
  /// before termination.
  ///
  /// **Workflow:**
  /// 1. **Signal Dispatch:** Sends a [IsolateCmd.terminate] command to the background
  ///    isolate to initiate internal cleanup of SQLite connections.
  /// 2. **Local State Purge:** Synchronously clears internal request queues,
  ///    stream controllers, and task trackers to prevent memory leaks.
  /// 3. **Teardown Confirmation:** Logs the completion of the shutdown, providing
  ///    a clear audit trail for telemetry.
  Future<void> shutdown() async {
    FluentLog.info('Initiating shutdown', tag: 'FluentEngine:lifecycle');

    _sendMessageToIsolate(
      IsolateRequest(
        cmd: IsolateCmd.terminate,
        task: FluentTask(id: _systemId, action: FluentDbAction.none),
      ),
    );

    await _performCleanup(wasEmergency: false);
    FluentLog.info('Graceful shutdown completed successfully', tag: 'FluentEngine:lifecycle', context: {'isolateTerminated': true});
  }

  /// Centralized cleanup logic ensuring state consistency and log reporting.
  Future<void> _performCleanup({required bool wasEmergency}) async {
    _toWorker = null;
    _isIsolateWorkerBusy = false;
    _isMainWorkerBusy = false;

    // Reject pending requests
    if (_pendingRequests.isNotEmpty) {
      final String msg = wasEmergency ? 'Database isolate was forcefully restarted.' : 'Database engine is shutting down.';
      FluentLog.warning('Rejecting pending completers', tag: 'FluentEngine:lifecycle', context: {'count': _pendingRequests.length});

      for (final completer in _pendingRequests.values) {
        if (!completer.isCompleted) completer.completeError(Exception(msg));
      }
      _pendingRequests.clear();
    }

    // Close streams
    for (final StreamController<List<Map<String, dynamic>>> controller in _streamRequests.values) {
      if (!controller.isClosed) await controller.close();
    }
    _streamRequests.clear();

    // Clear buffers and queues
    _chunkAccumulators.clear();

    if (_queue.isNotEmpty) {
      FluentLog.warning('Dropping pending tasks from queue', tag: 'FluentEngine:lifecycle', context: {'count': _queue.length});
      _queue.clear();
    }
  }

  /// Dispatches a system-level administrative task (e.g., stats flush,
  /// schema maintenance) into the primary execution pipeline.
  ///
  /// **Workflow:**
  /// 1. **Pipeline Routing:** Redirects the system task to [_executeTaskInPipeline],
  ///    ensuring it undergoes the same scheduling, priority calculation,
  ///    and concurrency management as standard user tasks.
  /// 2. **System Integrity:** By sharing the pipeline, system tasks respect
  ///    the current database state and locking mechanisms, preventing
  ///    race conditions during background maintenance cycles.
  Future<dynamic> _executeSystemTask(FluentTask task) async => _executeTaskInPipeline(task);
}
