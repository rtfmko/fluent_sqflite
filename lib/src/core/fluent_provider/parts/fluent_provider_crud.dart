// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, type-safe CRUD operations for [FluentStorable] entities.
///
/// The [FluentProviderCrud] extension establishes a structured, standardized interface over [FluentProvider],
/// abstracting low-level storage engine mechanics, transaction isolation layers, and multi-threaded
/// task orchestration.
///
/// ### Core Architecture & Execution Paradigms
/// Operations exposed by this extension follow a strict hierarchical routing pipeline designed to minimize
/// main-thread blocking, preserve relational integrity, and guarantee atomic consistency:
///
/// * **Early Fast-Path Evaluation:** Methods analyze input arguments immediately (e.g., verifying if unique
///   identity collections are empty or null) to return accelerated, cached futures. This short-circuits execution
///   before invoking pipeline generators or allocating task entities on the heap.
/// * **Contextual Transaction Routing:** The execution layer dynamically interrogates the active connection state.
///   If operations run within a pre-established transaction scope (via localized executors or shared batch contexts),
///   queries hook directly into the active connection pool to enforce atomic isolation and prevent deadlocks.
/// * **Asynchronous Task Orchestration:** Out-of-transaction maintenance operations (such as broad record purges,
///   expiration sweeps, or large-scale aggregation counts) are encapsulated into standardized [FluentTask] units.
///   These tasks are dispatched to the global [FluentDb], where an isolation scheduling coordinator allocates
///   concurrency frameworks and background isolates based on the configured [ExecutionPolicy].
/// * **Relational Integrity Cascading:** Mutative operations automatically track database relational states.
///   Upon successful row mutations or data clearance executions, cascading sweeps are safely forwarded to
///   internal relationship mixins to purge detached data structures and eliminate orphan records.
/// * **High-Fidelity Telemetry Separation:** Structural diagnostics leverage a centralized global facade pattern.
///   By passing runtime state variables inside structured tracking maps rather than compiling dynamic strings,
///   the layer guarantees zero temporary string allocations on the heap when runtime logging is disabled globally.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [FluentTask], the uniform framework task encapsulation unit.
/// * [ExecutionPolicy], which defines chunk boundaries, prioritizations, and thread allocation overrides.
extension FluentProviderCrud<T extends FluentStorable> on FluentProvider<T> {
  /// Saves or updates a single object [item] in the table [$tableName].
  ///
  /// If a record with the same primary key already exists in the database,
  /// the behavior is determined by the [updateIfExist] flag:
  /// * `true` — The existing record will be updated with new field values (UPSERT).
  /// * `false` — SQLite will throw a uniqueness constraint violation exception.
  ///
  /// The [policy] parameter allows overriding the default task execution settings
  /// (e.g., forcing execution inside the background isolate or bypassing request collapsing).
  ///
  /// ### Usage Example:
  /// ```dart
  /// final User user = User(id: 42, name: 'Alex', role: 'admin');
  ///
  /// await userRepository.saveItem(
  ///   user,
  ///   updateIfExist: true,
  ///   policy: const ExecutionPolicy(useIsolate: false), // Force Main-thread execution
  /// );
  /// ```
  @internal
  Future<void> saveItem(T item, {bool updateIfExist = false, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    FluentLog.debug(
      'Request to add single item into data layer pipeline',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'updateIfExist': updateIfExist, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    await saveItems([item], updateIfExist: updateIfExist, policy: policy);
  }

  /// Saves or updates a collection of objects [items] in the table [$tableName].
  ///
  /// This batch operation is highly optimized for performance and memory consumption.
  /// It pre-compiles internal JSON structures before evaluating thread allocation strategies.
  ///
  /// [updateIfExist] controls the SQLite resolution behavior on constraint conflicts (UPSERT).
  /// [sharedBatch] allows chaining this operation into an existing cascading transaction.
  /// [cachedJsons] bypasses the serialization loop if payload maps were computed beforehand.
  /// [policy] defines customized scheduler constraints for the underlying [FluentTask].
  ///
  /// ### Usage Example:
  /// ```dart
  /// final List<Order> newOrders = [
  ///   Order(id: 101, total: 55.0),
  ///   Order(id: 102, total: 120.5),
  /// ];
  ///
  /// await orderRepository.saveItems(
  ///   newOrders,
  ///   updateIfExist: true,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true,
  ///     useIsolate: true, // Offload heavy batch parsing to background worker
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> saveItems(List<T> items, {bool updateIfExist = false, Batch? sharedBatch, List<Map<String, dynamic>>? cachedJsons, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final int itemsLength = items.length;
    if (itemsLength == 0) return Future.value();

    List<Map<String, dynamic>> effectiveJsons;

    if (cachedJsons != null) {
      effectiveJsons = cachedJsons;
    } else {
      effectiveJsons = List<Map<String, dynamic>>.filled(itemsLength, const {}, growable: false);
      for (int i = 0; i < itemsLength; i++) {
        effectiveJsons[i] = _prepareSqlJson(items[i]);
      }
    }

    final FluentTask task = FluentTask(
      action: FluentDbAction.save,
      table: tableName,
      dbName: dbName,
      ignoreLazy: true,
      maxDepth: 0,
      data: items,
      relations: effectiveJsons,
      helper: TableHelper(updateIfExist: updateIfExist),
      policy: policy,
    );

    FluentLog.debug(
      'Request to add batch of items into data layer pipeline',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'batchSize': itemsLength, 'updateIfExist': updateIfExist, 'hasSharedBatch': sharedBatch != null, 'hasCachedJsons': cachedJsons != null, 'taskId': task.id},
    );

    if (sharedBatch != null) {
      return _executeAdd(null, items, task, sharedBatch: sharedBatch, parentJsons: effectiveJsons);
    }

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  /// Analyzes catch block errors, evaluates constraint flags, and formats exceptions.
  ///
  /// Intercepts incoming low-level [DatabaseException] anomalies, performs routing
  /// based on SQLite error signatures, generates diagnostic telemetry logs via [FluentLog.error],
  /// and wraps underlying failures into specialized package exception modules.
  void _handleDatabaseException(DatabaseException e, StackTrace stackTrace) {
    final String errorString = e.toString();
    if (e.isUniqueConstraintError() || errorString.contains('UNIQUE')) {
      FluentLog.error(
        'Database write aborted due to uniqueness constraint violation',
        e,
        stackTrace,
        tag: '$tableName:exception',
        hint: 'Verify data records match table indexing schema parameters and unique identifiers.',
        context: {'tableName': tableName, 'isConstraintViolation': true},
      );
      throw FluentConstraintException('Unique constraint violation in table "$tableName"', originalError: e);
    }
    FluentLog.error(
      'Database pipeline caught unhandled low-level engine exception during write routing',
      e,
      stackTrace,
      tag: '$tableName:exception',
      hint: 'Inspect internal SQLite connection status, schema state, or execution query parameters.',
      context: {'tableName': tableName, 'isConstraintViolation': false},
    );
    throw FluentBaseException('Database error while writing to "$tableName": $e', stackTrace, e);
  }

  /// Standard pipeline router executing incoming write [task] commands directly on the Main thread.
  ///
  /// This internal mechanism extracts payload variants safely into unified generic arrays,
  /// checks whether an outer transaction wrapper is currently controlling the call stack:
  /// * Intercepts existing contexts to merge queries into an inherited cascade write sequence.
  /// * Spawns an isolated local transaction when executing a standalone task entry point.
  ///
  /// Dispatches structured execution tracing via [FluentLog.debug] and maps internal errors
  /// through custom low-level database exception handlers.
  Future<void> _executeSaveTaskOnMain(FluentTask task) async {
    final List<T> items;

    if (task.data is List<T>) {
      items = task.data as List<T>;
    } else if (task.data is List) {
      items = (task.data as List).cast<T>();
    } else {
      items = <T>[task.data as T];
    }

    final currentTxn = _transactionExecutor;

    // SCENARIO A: An active external transaction context already exists on this thread
    if (currentTxn is Transaction) {
      try {
        FluentLog.debug(
          'Executing Main-thread save routine within an inherited active transaction',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'batchSize': items.length, 'transactionMode': 'inherited'},
        );

        await _executeAdd(currentTxn, items, task, parentJsons: null);
        return;
      } on DatabaseException catch (e, stackTrace) {
        _handleDatabaseException(e, stackTrace);
        rethrow;
      }
    }

    // SCENARIO B: No inherited context — open a new isolated local database transaction block
    try {
      FluentLog.debug(
        'Opening an exclusive standalone transaction block for Main-thread execution',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'batchSize': items.length, 'transactionMode': 'standalone'},
      );
      await db.transaction((txn) async {
        setTransactionExecutor(txn);

        try {
          await _executeAdd(txn, items, task, parentJsons: null);
        } finally {
          restoreOriginalExecutor();
        }
      });
    } on DatabaseException catch (e, stackTrace) {
      _handleDatabaseException(e, stackTrace);
      rethrow;
    }
  }

  /// Fetches a single object mapping from the database table [$tableName] matching execution criteria.
  ///
  /// This operational bridge utilizes the batch selection pipeline [findAll] under the hood,
  /// specifying a strict constraint of a single item via the `limit: 1` optimization parameter.
  ///
  /// [maxDepth] determines the cascading relation traversal threshold for database sub-tables.
  /// [ignoreLazy] overrides proxy model configurations to execute synchronous joins where applicable.
  /// [policy] configures low-level isolation and worker routing parameters for the underlying task.
  ///
  /// Returns the typed instance [T] if an entity satisfies constraints; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeSession = await sessionRepository.findOne(
  ///   maxDepth: 2,
  ///   ignoreLazy: true,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Prevents dual-fetching on parallel view allocations
  ///   ),
  /// );
  /// ```
  @internal
  Future<T?> findOne({int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    FluentLog.debug(
      'Evaluating operational pipeline constraints for single-row entity lookup',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final List<T> results = await findAll(maxDepth: maxDepth, ignoreLazy: ignoreLazy, limit: 1, policy: policy);

    return results.isNotEmpty ? results.first : null;
  }

  /// Fetches a batch collection of typed objects [T] from the database table [$tableName].
  ///
  /// This high-performance selection pipeline encapsulates runtime parameters into a unified [FluentTask]
  /// and pipes it into the asynchronous worker scheduler architecture for stream or thread routing.
  ///
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [maxDepth] determines the operational traversal deep-linking threshold for relational nested child models.
  /// [ignoreLazy] overrides default structural configurations to immediately evaluate proxies or nested sub-tables.
  /// [policy] defines prioritization, synchronization, and query collapsing rules managed by the coordinator.
  ///
  /// Returns a typed [List<T>] containing matched relational structures materialized from the data layer.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final standardOrders = await orderRepository.findAll(
  ///   limit: 50,
  ///   maxDepth: 3,
  ///   ignoreLazy: false,
  ///   policy: const ExecutionPolicy(useIsolate: true), // Offload heavy hydration task to background thread
  /// );
  /// ```
  @internal
  Future<List<T>> findAll({int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for batch row selection',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'limit': limit ?? 'unlimited', 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findAll,
      table: tableName,
      dbName: dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs data selection queries on the Main thread thread-pool.
  ///
  /// This pipeline retrieves a collection of raw row configurations from SQLite matching criteria.
  /// It branches dynamically based on table topology configuration states:
  /// * Evaluates a zero-allocation flat array mapper loop if the target model has no relations.
  /// * Triggers chunked multi-tier data structure worker routines if sub-relation tables must be resolved.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<List<T>> _executeFindAllTaskOnMain(FluentTask task) async {
    final int? limit = task.helper?.limit;

    FluentLog.debug('Executing Main-thread batch selection routine', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id, 'limit': limit ?? 'unlimited'});

    try {
      // Execute the low-level raw query constraint directly against the database driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, limit: limit);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer selection', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Raw database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'rawRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence finalized safely',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.chunkSize!);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence finalized safely',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'chunkSize': task.policy.chunkSize, 'optimizationApplied': 'batched_cascade_enrichment'},
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine data transformation models, custom row enrichment callbacks, or database mapping layouts.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Processing worker executing relational data structure resolution for a single row model.
  ///
  /// This micro-task runs sequentially or concurrently within chunked stream pipelines:
  /// * Evaluates [_processRow] to link cascading sub-tables and compute virtual data fields.
  /// * Triggers [_assembleModel] to handle type-casting and constructor hydration mappings.
  ///
  /// Intercepts relational mapping failures and pipes detailed breakdown metrics into [FluentLog.error]
  /// to pinpoint corrupt or unaligned foreign records.
  Future<T> _rowEnrichmentAndAssembleWorker(Map<String, dynamic> row, FluentTask task) async {
    try {
      // Execute cascading foreign-key resolution and child object tree hydration
      final Map<String, dynamic> enriched = await _processRow(row, task);

      // Materialize the final strongly-typed data model from the fully hydrated map
      return _assembleModel(enriched);
    } catch (e, s) {
      FluentLog.error(
        'Hydration layer failed during singular row enrichment processing',
        e,
        s,
        tag: '$tableName:pipeline',
        hint: 'Verify nested model serializers match relational schema schemas and check for missing foreign keys.',
        context: {'tableName': tableName, 'taskId': task.id, 'rawRowKeys': row.keys.toList()},
      );
      rethrow;
    }
  }

  /// Safely formats and stages a database insertion or modification inside an active batch transaction.
  ///
  /// This transactional micro-task processes raw record maps before executing write steps:
  /// * Evaluates payload properties against [tableColumns] to detect invalid attributes.
  /// * Sanitizes extraneous keys to prevent underlying SQLite syntax errors.
  /// * Fires warning telemetry via [FluentLog.warning] if any model attributes were stripped.
  /// * Configures structural [ConflictAlgorithm] states according to the [updateIfExist] modifier.
  void _upsertItemInTxn(Batch batch, Map<String, dynamic> map, bool updateIfExist) {
    final Set<String> allowedColumns = tableColumns;

    // Evaluate input map structure against the verified schema constraints
    bool needsSanitization = false;
    for (final String key in map.keys) {
      if (!allowedColumns.contains(key)) {
        needsSanitization = true;
        break;
      }
    }

    final Map<String, dynamic> sqlData;

    // SCENARIO A: CLEAN PAYLOAD — Map structure maps perfectly to column rules
    if (!needsSanitization) {
      sqlData = map;
    } else {
      // SCENARIO B: CORRUPT/EXTRANEOUS PAYLOAD — Extract unaligned schema fields
      sqlData = {};
      final List<String> strippedFields = [];

      for (final entry in map.entries) {
        if (allowedColumns.contains(entry.key)) {
          sqlData[entry.key] = entry.value;
        } else {
          strippedFields.add(entry.key);
        }
      }

      FluentLog.warning(
        'Database payload sanitization triggered due to unaligned model attributes',
        tag: '$tableName:schema',
        hint: 'Ensure your data models are fully synchronized with the physical table definitions. Outdated migrations or missing column mappings can leave dead properties in serialization payloads.',
        context: {'tableName': tableName, 'strippedFields': strippedFields, 'expectedColumns': allowedColumns.toList()},
      );
    }

    final ConflictAlgorithm conflictAlgorithm = updateIfExist ? ConflictAlgorithm.replace : ConflictAlgorithm.abort;

    batch.insert(tableName, sqlData, conflictAlgorithm: conflictAlgorithm);
  }

  /// Fetches a filtered batch collection of typed objects [T] containing non-expired valid records from [$tableName].
  ///
  /// This specialized selection routine wraps localized expiration checking filters and
  /// relational parameters into a unified [FluentTask] before passing it to the thread-pool router.
  ///
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [sortByExpireDate] flags the underlying query builder to inject explicit chronological order constraints.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a filtered [List<T>] containing materialized active data layers.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeVouchers = await voucherRepository.findValidItems(
  ///   limit: 10,
  ///   sortByExpireDate: true,
  ///   maxDepth: 1,
  ///   policy: const ExecutionPolicy(cancelIfDuplicate: true), // Enable query collapsing protection
  /// );
  /// ```
  @internal
  Future<List<T>> findValidItems({int? limit, bool sortByExpireDate = false, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) {
    FluentLog.debug(
      'Initiating localized query pipeline for unexpired validation row selection',
      tag: '$tableName:operation',
      context: {
        'tableName': tableName,
        'limit': limit ?? 'unlimited',
        'sortByExpireDate': sortByExpireDate,
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findValidItems,
      table: tableName,
      dbName: dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, multiple: true, sortByExpireDate: sortByExpireDate),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs data verification and filtering on the Main thread.
  ///
  /// This pipeline queries a specific subset of active, unexpired database records by cross-checking
  /// the inferred timestamp metadata columns against the active runtime system epoch.
  /// It branches dynamically based on table topology configuration states:
  /// * Evaluates a zero-allocation flat array mapper loop if the target model has no relations.
  /// * Triggers chunked multi-tier data structure worker routines if sub-relation tables must be resolved.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<List<T>> _executeFindValidItemsTaskOnMain(FluentTask task, {bool sortByExpireDate = false}) async {
    final int? limit = task.helper?.limit;
    final int now = DateTime.now().millisecondsSinceEpoch;

    // Resolve target column mapping for validation tracking parameters
    final String expiryCol = _cachedPrimaryKey?.name == 'id' ? 'expiry_date' : modelSample.expiryColumn;

    FluentLog.debug(
      'Executing Main-thread unexpired validation selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'limit': limit ?? 'unlimited', 'expiryColumn': expiryCol, 'timestampThreshold': now, 'sortByExpireDate': sortByExpireDate},
    );

    try {
      final String? orderBy = sortByExpireDate ? '$expiryCol ASC' : null;

      // Execute the low-level raw query constraints directly against the database driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, where: '$expiryCol IS NULL OR $expiryCol > ?', whereArgs: [now], limit: limit, orderBy: orderBy);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer valid row selection', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Valid database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'validRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for valid records finalized safely',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.chunkSize!);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for valid records finalized safely',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'chunkSize': task.policy.chunkSize, 'optimizationApplied': 'batched_cascade_enrichment'},
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread validation query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine expiry mapping parameters, active database connections, or data model constructors.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Fetches a batch collection of typed objects [T] from [$tableName] matching a specific column attribute value.
  ///
  /// This conditional selection routine automatically infers your table's primary key structure
  /// if the [key] parameter is omitted, passing parameterized mapping constraints into a uniform [FluentTask].
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [key] specifies the targeted column field name to filter against. Defaults to the table's primary key.
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a matched [List<T>] containing materialized data layers.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final activeUsers = await userRepository.findItemsBy(
  ///   'active',
  ///   key: 'status',
  ///   limit: 100,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Merges parallel identical selection calls
  ///   ),
  /// );
  /// ```
  @internal
  Future<List<T>> findItemsBy(dynamic value, {String? key, int? limit, int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) {
    // Fall back to the inferred primary key identifier if no custom attribute key is passed
    final String searchKey = key ?? (_cachedPrimaryKey?.name ?? 'id');

    FluentLog.debug(
      'Initiating localized query pipeline for conditional attribute row selection',
      tag: '$tableName:operation',
      context: {
        'tableName': tableName,
        'searchColumnKey': searchKey,
        'searchConditionValue': value.toString(),
        'limit': limit ?? 'unlimited',
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findItemsBy,
      table: tableName,
      dbName: dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(limit: limit, key: searchKey, value: value, where: '$searchKey = ?', whereArgs: [value], multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  Future<List<T>> _executeFindItemsByTaskOnMain(FluentTask task) async {
    final int? limit = task.helper?.limit;
    final String whereClause = task.helper?.where ?? 'id = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [];
    final String searchKey = task.helper?.key ?? 'id';
    final dynamic value = task.helper?.value;

    FluentLog.debug(
      'Executing Main-thread conditional attribute query selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'searchKey': searchKey, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit ?? 'unlimited'},
    );

    try {
      // Execute the parameterized conditional query directly against the underlying driver
      final List<Map<String, dynamic>> result = await executor.query(tableName, where: whereClause, whereArgs: whereArgs, limit: limit);

      final int resultLength = result.length;
      if (resultLength == 0) {
        FluentLog.debug(
          'Empty result set returned from data layer conditional attribute selection',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'searchKey': searchKey, 'searchValue': value.toString()},
        );
        return <T>[];
      }

      FluentLog.debug(
        'Conditional database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'matchedRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(result[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for conditional query finalized safely',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs via the unified row worker
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(result, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.chunkSize!);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for conditional query finalized safely',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'chunkSize': task.policy.chunkSize, 'optimizationApplied': 'batched_cascade_enrichment'},
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread conditional query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Verify where clause structure parameters, evaluate model constructors, or audit relational join constraints.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedSearchKey': searchKey, 'failedSearchValue': value.toString()},
      );
      rethrow;
    }
  }

  /// Fetches a single typed object [T] from the database table [$tableName] by its primary key [id].
  ///
  /// This unique identification selection routine encapsulates the lookup constraints into a uniform [FluentTask]
  /// and pipes it into the asynchronous worker scheduler architecture for stream or thread routing.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns the materialized typed instance [T] if found; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final userProfile = await userRepository.findById(
  ///   'usr_892x04',
  ///   maxDepth: 2,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: true, // Enables query collapsing to prevent parallel double-fetching
  ///   ),
  /// );
  /// ```
  @internal
  Future<T?> findById(dynamic id, {int maxDepth = 1, bool ignoreLazy = false, ExecutionPolicy policy = const ExecutionPolicy()}) {
    FluentLog.debug(
      'Initiating localized query pipeline for primary key row selection',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'targetId': id.toString(), 'maxDepth': maxDepth, 'ignoreLazy': ignoreLazy, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.findById,
      table: tableName,
      dbName: dbName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(id: id, limit: 1, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, T?>(provider: this, task: task);
  }

  Future<T?> _executeFindByIdTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    // Resolve the primary key name property configuration dynamically
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread single-row primary key query selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetId': id.toString()},
    );

    // Execute a strict singular-row search query directly against the underlying driver
    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: '$pkName = ?', whereArgs: [id], limit: 1);

    if (maps.isEmpty) {
      FluentLog.debug(
        'Empty result set returned from data layer unique primary key selection',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'targetId': id.toString()},
      );
      return null;
    }

    final Map<String, dynamic> rawRow = maps.first;

    // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
    if (!_hasRelations) {
      FluentLog.debug(
        'Fast-path matching sequence for direct identity lookup finalized safely',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'optimizationApplied': 'flat_map_fast_path'},
      );
      return _assembleModel(rawRow);
    }

    // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
    // Execute synchronous relational matching constraints and append nested models via the supervisor task context
    final Map<String, dynamic> enriched = await _processRow(rawRow, task);

    FluentLog.debug(
      'Relational hydration mapping sequence for identity lookup finalized safely',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'optimizationApplied': 'cascade_enrichment'},
    );
    return _assembleModel(enriched);
  }

  /// Fetches a batch collection of typed objects [T] from [$tableName] satisfying custom query constraints.
  ///
  /// This flexible selection routine encapsulates low-level SQLite query modifiers (including raw filters,
  /// sorting definitions, and explicit pagination indexes) into a standardized [FluentTask] payload architecture.
  ///
  /// [where] defines the parameterized filter query constraint string (e.g., 'status = ? AND age > ?').
  /// [whereArgs] contains the typed runtime evaluation variables mapped directly to placeholders in the where clause.
  /// [orderBy] defines explicit sorting priorities and directions (e.g., 'created_at DESC, total_price ASC').
  /// [limit] defines the maximum upper bounds constraint for returned database entries. Pass `null` for unlimited rows.
  /// [offset] specifies the row index constraint from which database record extraction starts.
  /// [maxDepth] determines the deep-linking threshold when traversing nested relational child models.
  /// [ignoreLazy] overrides proxy patterns to immediately evaluate related sub-tables where applicable.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a matching [List<T>] containing materialized data layers.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final premiumInvoices = await invoiceRepository.find(
  ///   where: 'status = ? AND total_amount > ?',
  ///   whereArgs: ['PAID', 500.0],
  ///   orderBy: 'settled_at DESC',
  ///   limit: 20,
  ///   offset: 40, // Useful for multi-tier pagination screens
  ///   policy: const ExecutionPolicy(useIsolate: true), // Offload heavy cascading mapping to background thread
  /// );
  /// ```
  @internal
  Future<List<T>> find({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
    int maxDepth = 1,
    bool ignoreLazy = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) {
    FluentLog.debug(
      'Initiating global operational query pipeline for structured condition row selection',
      tag: '$tableName:operation',
      context: {
        'tableName': tableName,
        'hasWhereClause': where != null,
        'whereArgsCount': whereArgs?.length ?? 0,
        'hasOrderBy': orderBy != null,
        'limit': limit ?? 'unlimited',
        'offset': offset ?? 0,
        'maxDepth': maxDepth,
        'ignoreLazy': ignoreLazy,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.find,
      dbName: dbName,
      table: tableName,
      maxDepth: maxDepth,
      ignoreLazy: ignoreLazy,
      helper: TableHelper(where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit, offset: offset, multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<T>>(provider: this, task: task);
  }

  Future<List<T>> _executeFindTaskOnMain(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<Object?>? whereArgs = task.helper?.whereArgs;
    final String? orderBy = task.helper?.orderBy;
    final int? limit = task.helper?.limit;
    final int? offset = task.helper?.offset;

    FluentLog.debug(
      'Executing Main-thread customized structured query selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'hasWhereClause': where != null, 'hasOrderBy': orderBy != null, 'limit': limit ?? 'unlimited', 'offset': offset ?? 0},
    );

    try {
      // Execute the fully dynamic structured query directly against the underlying driver
      final List<Map<String, dynamic>> maps = await executor.query(tableName, where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit, offset: offset);

      final int resultLength = maps.length;
      if (resultLength == 0) {
        FluentLog.debug('Empty result set returned from data layer customized selection query', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});
        return <T>[];
      }

      FluentLog.debug(
        'Custom structured database records retrieved successfully. Initiating deserialization flow',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'retrievedRowsCount': resultLength, 'hasRelations': _hasRelations},
      );

      // SCENARIO A: FAST-PATH — Table has no nested relational schemas or foreign keys configured
      if (!_hasRelations) {
        final List<dynamic> rawFixedList = List<dynamic>.filled(resultLength, modelSample, growable: false);
        for (int i = 0; i < resultLength; i++) {
          rawFixedList[i] = _assembleModel(maps[i]);
        }

        final List<T> typedItems = _createTypedList(rawFixedList);
        FluentLog.debug(
          'Fast-path mapping sequence for customized query finalized safely',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'optimizationApplied': 'flat_array_fast_path'},
        );
        return typedItems;
      }

      // SCENARIO B: RELATIONAL CASCADE — Table has complex child structures requiring hydration loops
      // Execute batched concurrent/chunked computation layers to safely process model graphs via the unified row worker
      final List<T> items = await _computeBatched<Map<String, dynamic>, T>(maps, (row) => _rowEnrichmentAndAssembleWorker(row, task), batchSize: task.policy.chunkSize!);

      final List<T> typedItems = _createTypedList(items);

      FluentLog.debug(
        'Relational hydration mapping sequence for customized query finalized safely',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'materializedInstances': typedItems.length, 'chunkSize': task.policy.chunkSize, 'optimizationApplied': 'batched_cascade_enrichment'},
      );
      return typedItems;
    } catch (e, s) {
      FluentLog.error(
        'Main-thread customized query pipeline aborted due to unexpected hydration layer failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine raw query variables, inspect column syntax constraints, or audit model mapping transformations.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Fetches a single un-materialized raw data map from [$tableName] matching a specific column condition.
  ///
  /// This low-level extraction routine bypasses model constructors, fast-paths, and relation
  /// enrichment steps completely, returning the raw database row format mapped directly by the engine.
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [column] specifies the targeted column field name to filter against. Defaults to the table's primary key name.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a JSON-compatible [Map<String, dynamic>] if a record satisfies constraints; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final rawDataMap = await userRepository.rawGetItemBy(
  ///   'usr_0192a3',
  ///   column: 'uuid',
  ///   policy: const ExecutionPolicy(useIsolate: false), // Run instantly on the Main thread thread-pool
  /// );
  ///
  /// if (rawDataMap != null) {
  ///   print(rawDataMap['encrypted_payload']); // Safely read raw fields before model parsing
  /// }
  /// ```
  @internal
  Future<Map<String, dynamic>?> rawGetItemBy(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) {
    // Fall back to the configured table primary key name if no explicit column is specified
    final String searchCol = column ?? primaryKeyColumn.name;

    FluentLog.debug(
      'Initiating global operational query pipeline for single raw map record extraction',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'searchColumn': searchCol, 'searchValue': value.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.rawGetItem,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(column: searchCol, value: value, where: '$searchCol = ?', whereArgs: [value], limit: 1, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, Map<String, dynamic>?>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs specific un-materialized raw column selections on the Main thread.
  ///
  /// This pipeline unpacks execution boundaries to perform atomic single-row column filters directly
  /// on the SQLite engine layer, completely bypassing hydration steps, fast-paths, and relation sub-workers.
  /// It enforces isolated dictionary parsing by returning a decoupled snapshot copy of the query result.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug].
  Future<Map<String, dynamic>?> _executeRawGetItemByTaskOnMain(FluentTask task) async {
    final String searchCol = task.helper?.column ?? 'id';
    final dynamic value = task.helper?.value;
    final String whereClause = task.helper?.where ?? '$searchCol = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [value];
    final int limit = task.helper?.limit ?? 1;

    FluentLog.debug(
      'Executing Main-thread single raw-map record search query selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit},
    );

    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: whereClause, whereArgs: whereArgs, limit: limit);

    if (maps.isEmpty) {
      FluentLog.debug(
        'Empty result set returned from data layer raw record lookups',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString()},
      );
      return null;
    }

    return Map<String, dynamic>.from(maps.first);
  }

  /// Fetches a batch collection of un-materialized raw data maps from [$tableName] matching a specific column criteria.
  ///
  /// This performance-focused routine extracts multiple matching row documents from SQLite while completely
  /// bypassing data-layer model hydration, model assembly constructors, and relational sub-worker loops.
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [column] specifies the targeted column field name to filter against. Defaults to the table's primary key name.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [List<Map<String, dynamic>>] containing raw, row-index mapping structures.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final rawLogsBatch = await auditRepository.rawGetItemsBy(
  ///   'ERROR',
  ///   column: 'log_level',
  ///   policy: const ExecutionPolicy(useIsolate: true), // Offload parsing overhead of large sets from Main
  /// );
  /// ```
  @internal
  Future<List<Map<String, dynamic>>> rawGetItemsBy(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) {
    // Fall back to the configured table primary key name if no explicit column is specified
    final String searchCol = column ?? primaryKeyColumn.name;

    FluentLog.debug(
      'Initiating global operational query pipeline for raw collection record batch extraction',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'searchColumn': searchCol, 'searchValue': value.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.rawGetItems,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(column: searchCol, value: value, where: '$searchCol = ?', whereArgs: [value], multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<Map<String, dynamic>>>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs specific multi-row un-materialized collection selections on the Main thread.
  ///
  /// This pipeline unpacks database execution parameters to perform batch column filters directly on
  /// the SQLite engine layer, completely bypassing hydration steps, fast-paths, and relational sub-workers.
  /// It returns a memory-optimized, non-growable fixed list containing deep-copied snapshots of individual rows.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug].
  Future<List<Map<String, dynamic>>> _executeRawGetItemsByTaskOnMain(FluentTask task) async {
    final String searchCol = task.helper?.column ?? 'id';
    final dynamic value = task.helper?.value;
    final String whereClause = task.helper?.where ?? '$searchCol = ?';
    final List<dynamic> whereArgs = task.helper?.whereArgs ?? [value];
    final int? limit = task.helper?.limit;

    FluentLog.debug(
      'Executing Main-thread batch raw-map collection search query selection routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString(), 'whereClause': whereClause, 'limit': limit ?? 'unlimited'},
    );

    final List<Map<String, dynamic>> maps = await executor.query(tableName, where: whereClause, whereArgs: whereArgs, limit: limit);

    final int resultLength = maps.length;

    if (resultLength == 0) {
      FluentLog.debug(
        'Empty result set returned from data layer batch raw record selections',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'searchColumn': searchCol, 'searchValue': value.toString()},
      );
      return <Map<String, dynamic>>[];
    }

    FluentLog.debug(
      'Batch raw records retrieved successfully. Projecting isolated dictionary maps',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'matchedRowsCount': resultLength},
    );

    return List<Map<String, dynamic>>.generate(resultLength, (i) => Map<String, dynamic>.from(maps[i]), growable: false);
  }

  /// Commits internal structural modifications of a typed object [item] back into the [$tableName] storage engine.
  ///
  /// This operational modification pipeline first serializes the target object into a primitive database map,
  /// extracts its corresponding primary identity key properties, and evaluates structural validation bounds:
  /// * Aborts instantly with an explicitly raised [ArgumentError] and fires [FluentLog.error] if identity keys are missing.
  /// * Encapsulates valid state modifications into a unified [FluentTask] for secure thread routing.
  ///
  /// [item] represents the modified data model entity carrying the updated state values.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when changes are securely written into the data layer.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final updatedUser = activeUser.copyWith(email: 'new.email@domain.com');
  ///
  /// await userRepository.update(
  ///   updatedUser,
  ///   policy: const ExecutionPolicy(
  ///     cancelIfDuplicate: false, // Modifications must always execute atomically without deduplication
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> update(T item, {ExecutionPolicy policy = const ExecutionPolicy()}) {
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    final Map<String, dynamic> preparedData = _prepareSqlJson(item);
    final dynamic id = preparedData[pkName];

    if (id == null) {
      final FluentArgumentException exception = FluentArgumentException(tableName, 'Target update identifier evaluated to null"', StackTrace.current);

      FluentLog.error(
        'Database update operations rejected due to unassigned identity bounds',
        exception,
        StackTrace.current,
        tag: '$tableName:exception',
        hint:
            'Verify your model attributes possess valid database entity assignments before committing modifications. Unassigned or auto-incrementing identity values must be inserted before they can be updated.',
        context: {'tableName': tableName, 'expectedPrimaryKeyColumn': pkName},
      );

      return Future<void>.error(exception);
    }
    FluentLog.debug(
      'Initiating localized query pipeline for single-row structural table update modification',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.update,
      table: tableName,
      dbName: dbName,
      data: item,
      helper: TableHelper(id: id, dataMap: preparedData, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  Future<void> _executeUpdateTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final Map<String, dynamic>? preparedData = task.helper?.dataMap;

    if (id == null || preparedData == null) {
      FluentLog.warning(
        'Database update sequence aborted on Main due to incomplete task parameters',
        tag: '$tableName:pipeline',
        hint: 'Verify that the task object initiates with valid data structures and primary keys initialized.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isPreparedDataNull': preparedData == null},
      );
      return;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread direct-row state mutation sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString()},
    );

    try {
      final Set<String> allowedKeys = tableColumns;

      final Map<String, dynamic> dataToSet = <String, dynamic>{};

      for (final MapEntry<String, dynamic> entry in preparedData.entries) {
        final String key = entry.key;

        if (key != pkName && allowedKeys.contains(key)) {
          dataToSet[key] = entry.value;
        }
      }

      if (dataToSet.isEmpty) {
        FluentLog.debug(
          'Data modification bypassed: no updatable or altered schema properties found',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'reason': 'Only primary identifier was provided or zero matching table schema attributes discovered.'},
        );
        return;
      }

      final int count = await executor.update(tableName, dataToSet, where: '$pkName = ?', whereArgs: [id]);

      FluentLog.debug(
        'Database operational modification successfully finalized inside storage layer',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
      );
    } catch (e, s) {
      FluentLog.error(
        'Main-thread table modification query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Verify raw property value mappings match active SQL field definitions, constraint triggers, or active table keys.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Modifies a singular specific column cell property on a record inside [$tableName] matching [id].
  ///
  /// This targeted field modification pipeline performs early defensive validation checking:
  /// * Evaluates [updateKey] against [tableColumns] to catch schema compatibility mismatches early.
  /// * Aborts gracefully and registers a [FluentLog.warning] if the target column does not exist in the schema.
  /// * Encapsulates the verified individual field change criteria into a secure [FluentTask] framework wrapper.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [updateKey] specifies the exact physical string column name to modify inside the record database table.
  /// [updateValue] represents the updated primitive data state payload to insert into the targeted cell.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes safely when the target column write sequence completes.
  ///
  /// ### Usage Example:
  /// ```dart
  /// await userRepository.updateByKey(
  ///   'usr_772x11',
  ///   'is_verified',
  ///   true,
  ///   policy: const ExecutionPolicy(useIsolate: false), // Run instantly on Main thread thread-pool
  /// );
  /// ```
  @internal
  Future<void> updateByKey(dynamic id, String updateKey, dynamic updateValue, {ExecutionPolicy policy = const ExecutionPolicy()}) {
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    if (!tableColumns.contains(updateKey)) {
      FluentLog.warning(
        'Database structural mutation rejected due to non-existent schema column property',
        tag: '$tableName:schema',
        hint: 'Verify your lookup or update key mappings. Triggering alterations against invalid columns will cause structural SQLite syntax runtime exceptions.',
        context: {'tableName': tableName, 'attemptedColumnKey': updateKey, 'targetRecordId': id.toString(), 'availableColumns': tableColumns.toList()},
      );
      return Future<void>.value();
    }

    FluentLog.debug(
      'Initiating localized query pipeline for single-field target cell mutation',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetColumnField': updateKey, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateSingleField,

      table: tableName,
      dbName: dbName,
      helper: TableHelper(id: id, key: updateKey, value: updateValue, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  Future<void> _executeUpdateByKeyTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final String? updateKey = task.helper?.key;
    final dynamic updateValue = task.helper?.value;

    if (id == null || updateKey == null) {
      FluentLog.warning(
        'Database targeted mutation sequence aborted on Main due to missing parameters',
        tag: '$tableName:pipeline',
        hint: 'Verify that both the record identity tracking field and the targeted update column key are non-null values.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isUpdateKeyNull': updateKey == null},
      );
      return;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread localized singular cell property state mutation pipeline',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetFieldKey': updateKey},
    );

    try {
      final ({String? metaType, dynamic value}) result = _sanitizeValue(updateValue);
      final Map<String, dynamic> updateData = <String, dynamic>{updateKey: result.value};

      // Process and merge field-level metadata mapping descriptions if explicit schemas exist
      final String? resultMetaType = result.metaType;
      final Map<String, String>? metaParam = resultMetaType != null ? <String, String>{updateKey: resultMetaType} : null;
      final String? mergedMeta = await _getMergedMetadata(id, metaParam);

      if (mergedMeta != null) {
        updateData[FluentDbColumn.systemMetadata().name] = mergedMeta;
      }

      final int count = await executor.update(tableName, updateData, where: '$pkName = ?', whereArgs: [id]);

      if (count > 0) {
        FluentLog.debug(
          'Targeted column cell property modified and finalized safely in storage layer',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'modifiedFieldKey': updateKey, 'affectedRowsCount': count},
        );
      } else {
        FluentLog.warning(
          'Single-field update completed with zero affected records',
          tag: '$tableName:pipeline',
          hint: 'The identity key may not match any active row documents, or the physical storage driver rejected the cell state override.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'unmodifiedFieldKey': updateKey},
        );
      }
    } catch (e, s) {
      FluentLog.error(
        'Main-thread targeted cell mutation query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine field metadata configurations, analyze typing constraints, or check active entity row states.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString(), 'failedFieldKey': updateKey},
      );
      rethrow;
    }
  }

  /// Modifies a discrete, targeted subset collection of column properties on a record inside [$tableName] matching [id].
  ///
  /// This performance-tuned, multi-field partial modification pipeline performs early defensive checks:
  /// * Evaluates if the incoming [fields] payload map is empty, immediately returning an accelerated [Future.value] fast-path.
  /// * Encapsulates the partial update payload elements into a uniform [FluentTask] for secure thread-routing.
  /// * Leaves unspecified columns untouched, preserving original states inside unmapped record cells.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [fields] represents a dictionary structure containing the specific property keys and corresponding values to overwrite.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the targeted batch mutations are securely written.
  ///
  /// ### Usage Example:
  /// ```dart
  /// await userRepository.updateFieldsMultiple(
  ///   'usr_901a23',
  ///   {
  ///     'failed_login_attempts': 0,
  ///     'last_authenticated_at': DateTime.now().millisecondsSinceEpoch,
  ///     'account_status': 'ACTIVE',
  ///   },
  ///   policy: const ExecutionPolicy(useIsolate: true), // Offload tracking schema merge logic to thread worker
  /// );
  /// ```
  @internal
  Future<void> updateFieldsMultiple(dynamic id, Map<String, dynamic> fields, {ExecutionPolicy policy = const ExecutionPolicy()}) {
    if (fields.isEmpty) {
      return Future<void>.value();
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Initiating localized query pipeline for targeted subset row properties mutation',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'targetFieldsKeys': fields.keys.toList(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.updateMultipleFields,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(id: id, dataMap: fields, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs subset column modifications on the Main thread.
  ///
  /// This multi-field partial modification pipeline processes task dictionaries before executing modifications:
  /// * Evaluates data existence constraints to guard against uninitialized or empty map inputs.
  /// * Splits and separates raw runtime entries into storage values and typed system tracking metadata.
  /// * Filters keys dynamically against the table schema, omitting the primary key to maintain entity identity.
  /// * Extracts, constructs, and flushes complementary system metadata schemas dynamically into the row layout.
  /// * Evaluates state updates directly against the physical storage driver using fully parameterized syntax.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<void> _executeUpdateFieldsMultipleTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;
    final Map<String, dynamic>? fields = task.helper?.dataMap;

    if (id == null || fields == null || fields.isEmpty) {
      FluentLog.warning(
        'Database dynamic subset mutation sequence aborted on Main due to missing parameters',
        tag: '$tableName:pipeline',
        hint: 'Verify that both the record identity tracking field and the targeted update properties dictionary are non-empty structures.',
        context: {'tableName': tableName, 'taskId': task.id, 'isIdNull': id == null, 'isFieldsMapNullOrEmpty': fields == null || fields.isEmpty},
      );
      return;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread localized multi-field subset state mutation pipeline',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'incomingFieldsCount': fields.length},
    );

    try {
      // Split raw dictionary entries into primitive storage fields and typing metadata maps
      final ({Map<String, dynamic> data, Map<String, String> meta}) parts = _prepareMapAndMeta(fields);

      final Set<String> allowedKeys = tableColumns;
      final Map<String, dynamic> dataToSet = <String, dynamic>{};

      // Sanitize and align payload properties against physical table boundaries
      for (final MapEntry<String, dynamic> entry in parts.data.entries) {
        final String key = entry.key;

        // Skip the primary identity key to maintain model alignment constraints
        if (key != pkName && allowedKeys.contains(key)) {
          dataToSet[key] = entry.value;
        }
      }

      // Process and merge partial field typing schemas into centralized physical records
      final String? mergedMeta = await _getMergedMetadata(id, parts.meta);
      if (mergedMeta != null) {
        dataToSet[FluentDbColumn.systemMetadata().name] = mergedMeta;
      }

      // SCENARIO A: COMPATIBILITY COLLAPSE — Filtering operations yielded zero valid database column properties
      if (dataToSet.isEmpty) {
        FluentLog.debug(
          'Multi-field data modification bypassed: no updatable or altered schema properties found',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'reason': 'All fields were filtered out due to database schema incompatibility constraints.'},
        );
        return;
      }

      // SCENARIO B: MUTATION WRITE — Commit aligned property subsets using fully parameterized syntax
      final int count = await executor.update(tableName, dataToSet, where: '$pkName = ?', whereArgs: [id]);

      if (count == 0) {
        FluentLog.warning(
          'Multi-field partial update completed with zero affected records',
          tag: '$tableName:pipeline',
          hint: 'The identity key may not match any active row documents, or the physical storage driver rejected the subset map state change.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
        );
      } else {
        FluentLog.debug(
          'Targeted subset property batch modified and finalized safely in storage layer',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
        );
      }
    } catch (e, s) {
      FluentLog.error(
        'Main-thread targeted subset mutation query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine field dictionary variables, verify metadata parsing rules, or audit schema column typing constraints.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Splits an un-sanitized, generic runtime input map into a strongly decoupled, structure-aligned record tuple.
  ///
  /// This serialization and categorization pre-processing loop inspects input entries sequentially:
  /// * Skips blank identifiers and explicitly drops [FluentDbColumn.systemMetadata] properties to protect system storage keys.
  /// * Bypasses type serialization processing for entries recognized as active foreign relational keys.
  /// * Runs standard fields through low-level type sanitization to isolate underlying storage values.
  /// * Collects complex typing metadata tags into an separate sub-map to assist future deserialization.
  ///
  /// [rawData] represents the source dictionary of key-value pairs targeted for ingestion or processing.
  ///
  /// Returns a record tuple containing:
  /// * `data`: A structured [Map<String, dynamic>] holding normalized database primitive values.
  /// * `meta`: A specialized [Map<String, String>] mapping physical column keys to structural type descriptions.
  ({Map<String, dynamic> data, Map<String, String> meta}) _prepareMapAndMeta(Map<String, dynamic> rawData) {
    final Map<String, dynamic> sqlData = <String, dynamic>{};
    final Map<String, String> metaData = <String, String>{};

    // Cache the active table relationship structures locally to maximize iteration throughput
    final Set<String> relationKeys = _hasRelations ? (_cachedRelationKeys ?? const <String>{}) : const <String>{};
    final String systemMetaName = FluentDbColumn.systemMetadata().name;

    FluentLog.debug(
      'Executing data and typing-metadata segmentation mapping routine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'rawFieldsCount': rawData.length, 'hasRelations': _hasRelations, 'trackedRelationFields': relationKeys.toList()},
    );

    for (final MapEntry<String, dynamic> entry in rawData.entries) {
      final String key = entry.key;

      if (key.isEmpty || key == systemMetaName) continue;

      final dynamic value = entry.value;

      if (relationKeys.contains(key)) {
        sqlData[key] = value;
        continue;
      }

      final ({String? metaType, dynamic value}) result = _sanitizeValue(value);
      sqlData[key] = result.value;

      final String? metaType = result.metaType;
      if (metaType != null) {
        metaData[key] = metaType;
      }
    }

    FluentLog.debug(
      'Data segmentation and typing extraction successfully finalized',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'segmentedSqlFieldsCount': sqlData.length, 'extractedMetaFieldsCount': metaData.length},
    );

    return (data: sqlData, meta: metaData);
  }

  /// Combines new structural type definitions with the historical system metadata document stored in [$tableName].
  ///
  /// This read-modify-write internal sub-routine fetches the column snapshot isolated by the entity's [id]:
  /// * Evaluates input boundaries to skip database selection queries if [newTypes] is null or empty.
  /// * Safely handles un-serialized JSON errors via [FluentLog.error], allowing execution to proceed with a clean map structure.
  ///
  /// [id] defines the unique primitive or object identifier matching the table's primary key mapping constraint.
  /// [newTypes] represents an optional map linking newly modified column property keys to their structural string meta types.
  ///
  /// Returns a JSON-serialized [String] holding the unified map payload ready for cell flush operations,
  /// or evaluates to `null` if the final combined map contains zero entries.
  Future<String?> _getMergedMetadata(dynamic id, Map<String, String>? newTypes) async {
    if (newTypes == null || newTypes.isEmpty) return null;

    final String pkName = _cachedPrimaryKey?.name ?? 'id';
    final String metaColName = FluentDbColumn.systemMetadata().name;

    // Fetch the existing system metadata column snapshot from the target row document
    final List<Map<String, dynamic>> result = await executor.query(tableName, columns: [metaColName], where: '$pkName = ?', whereArgs: [id], limit: 1);

    final Map<String, String> merged = <String, String>{};

    if (result.isNotEmpty) {
      final dynamic rawMeta = result.first[metaColName];
      if (rawMeta is String && rawMeta.isNotEmpty) {
        try {
          // Deserialize the database string into an un-typed structured dictionary map
          final dynamic oldMeta = jsonDecode(rawMeta);
          if (oldMeta is Map<String, dynamic>) {
            for (final entry in oldMeta.entries) {
              merged[entry.key] = entry.value.toString();
            }
          }
        } catch (e, s) {
          FluentLog.error(
            'Failed to deserialize existing record system metadata document payload',
            e,
            s,
            tag: '$tableName:exception',
            hint: 'The metadata column data may have been corrupted, manually modified, or formatted using an incompatible schema encoding protocol.',
            context: {'tableName': tableName, 'targetRecordId': id.toString(), 'metadataColumnName': metaColName, 'rawMetadataContent': rawMeta},
          );
        }
      }
    }

    // Append and overwrite historical properties with the freshly extracted type metadata descriptors
    merged.addAll(newTypes);

    return merged.isEmpty ? null : jsonEncode(merged);
  }

  /// Permanently purges a specific physical record matching [item] from the [$tableName] storage engine.
  ///
  /// This operational destruction pipeline extracts the entry's primary identity key and validates boundaries:
  /// * Evaluates the primary key field early; if null, it registers a [FluentLog.warning] and short-circuits via [Future.value].
  /// * Encapsulates the target deletion parameters into a standardized [FluentTask] payload for thread coordination.
  ///
  /// [item] represents the target data model entity whose matching physical database row should be removed.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the row record is permanently purged.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final obsoleteInvoice = fetchedInvoices.first;
  ///
  /// await invoiceRepository.delete(
  ///   obsoleteInvoice,
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.critical, // Prioritize record purges over active cache fetches
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> delete(T item, {ExecutionPolicy policy = const ExecutionPolicy()}) {
    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    final Map<String, dynamic> preparedData = _prepareSqlJson(item);
    final dynamic id = preparedData[pkName];

    if (id == null) {
      FluentLog.warning(
        'Database delete operations rejected due to unassigned identity bounds',
        tag: '$tableName:pipeline',
        hint: 'Verify your model attributes possess valid database entity assignments before committing deletions. Bypassing execution preventing unnecessary database connection locking.',
        context: {'tableName': tableName, 'expectedPrimaryKeyColumn': pkName},
      );
      return Future<void>.value();
    }

    FluentLog.debug(
      'Initiating localized query pipeline for single-row physical record purge deletion',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.delete,
      table: tableName,
      dbName: dbName,
      data: item,
      helper: TableHelper(id: id, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  Future<void> _executeDeleteTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    if (id == null) {
      FluentLog.warning(
        'Database purge sequence aborted on Main due to missing parameter references',
        tag: '$tableName:pipeline',
        hint: 'Verify that the task wrapper passes a non-null primary identity key value.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread direct physical row destruction sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordId': id.toString()},
    );

    try {
      final int count = await deleteBy(id);

      if (count > 0) {
        FluentLog.debug(
          'Targeted database entity row permanently purged from storage layer',
          tag: '$tableName:pipeline',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString(), 'affectedRowsCount': count},
        );
      } else {
        FluentLog.warning(
          'Physical row destruction completed with zero affected records',
          tag: '$tableName:pipeline',
          hint: 'The identity key may not match any active row documents, or the record was already removed by a concurrent execution transaction.',
          context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
        );
      }
    } catch (e, s) {
      FluentLog.error(
        'Main-thread row destruction query pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Verify active storage constraint locks, inspect cascading foreign key rules, or audit table index maps.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedRecordId': id.toString()},
      );
      rethrow;
    }
  }

  /// Purges record entries from [$tableName] satisfying a conditional key evaluation constraint.
  ///
  /// This targeted, multi-tier data destruction pipeline evaluates runtime execution boundaries sequentially:
  /// * Intercepts [batch] objects to register query commands, returning an accelerated [Future.value] fast-path.
  /// * Evaluates active [_transactionExecutor] states to process selections inside local locked loops.
  /// * Packages multi-row deletion bounds into a standardized [FluentTask] for secure thread routing.
  ///
  /// [value] defines the target parameter matched against the column condition to determine row deletion.
  /// [key] specifies the physical table column field name to filter against. Defaults to the primary key name.
  /// [batch] represents an optional atomic database batch context used to stack multiple database mutation commands.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<int>] yielding the total count of physical table records successfully removed.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Perform an immediate bulk cascade delete of deactivated sessions
  /// final deactivatedCount = await sessionRepository.deleteBy(
  ///   'DEACTIVATED',
  ///   key: 'session_status',
  ///   policy: const ExecutionPolicy(priority: TaskPriority.high),
  /// );
  /// ```
  @internal
  Future<int> deleteBy(dynamic value, {String? key, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final String searchKey = key ?? (_cachedPrimaryKey?.name ?? 'id');

    FluentLog.debug(
      'Initiating localized query pipeline for conditional storage layer record purges',
      tag: '$tableName:operation',
      context: {
        'tableName': tableName,
        'searchColumnField': searchKey,
        'searchValue': value.toString(),
        'isBatchOperation': batch != null,
        'hasActiveTransaction': _transactionExecutor != null,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    // SCENARIO A: BATCH OPERATION — Stage the deletion query into the provided transaction batch array
    if (batch != null) {
      batch.delete(tableName, where: '$searchKey = ?', whereArgs: [value]);
      // Returns an assumed singular modification confirmation since actual execution delays until batch commit
      return Future<int>.value(1);
    }

    // SCENARIO B: TRANSACTION ENVELOPE — Execute directly on the local locked transaction connection pool
    if (_transactionExecutor != null) {
      return _rawDeleteByExecution(searchKey, value, _transactionExecutor!);
    }

    // SCENARIO C: STANDARD TASK PIPELINE — Encapsulate deletion parameters into a uniform framework task
    // TableHelper maps criteria into where clauses and sets multiple: true to handle bulk sweeps.
    final FluentTask task = FluentTask(
      action: FluentDbAction.deleteBy,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(key: searchKey, value: value, where: '$searchKey = ?', whereArgs: [value], multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs transactional multi-row conditional purges on the Main thread.
  ///
  /// This pipeline unpacks task payload fields to execute isolated batch destructions safely:
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Overrides active query routes using [setTransactionExecutor] to hook operations to the current transaction frame.
  /// * Utilizes a strict `finally` structural block to guarantee connection pool restoration via [restoreOriginalExecutor].
  /// * Traps query issues, logging comprehensive data context diagnostics before propagation.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.error].
  Future<int> _executeDeleteByTaskOnMain(FluentTask task) async {
    final String searchKey = task.helper?.key ?? 'id';
    final dynamic value = task.helper?.value;

    FluentLog.debug(
      'Executing Main-thread transactional conditional record purge sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'searchColumnField': searchKey, 'searchValue': value.toString()},
    );

    try {
      // Wrap the multi-row deletion routine inside a localized database transaction scope
      return await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          return await _rawDeleteByExecution(searchKey, value, txn);
        } finally {
          restoreOriginalExecutor();
        }
      });
    } catch (e, s) {
      FluentLog.error(
        'Main-thread conditional purge transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine database indexing boundaries, active primary constraints, or evaluate concurrent connection pool configurations.',
        context: {'tableName': tableName, 'taskId': task.id, 'failedColumnField': searchKey},
      );
      rethrow;
    }
  }

  /// Low-level atomic driver execution routine that carries out row deletions and relational cleanup cycles.
  ///
  /// This routine acts as a direct interface to the underlying database driver:
  /// * Fires a parameterized raw SQL delete query directly against the provided [activeExecutor] context.
  /// * Evaluates the resulting row mutation count to determine if follow-up processing is required.
  /// * Spawns an orphan records sweeping routine via [_relationsMixin] to process foreign constraints.
  /// * Forwards the original transactional executor reference to child workers to maintain transaction scopes.
  ///
  /// [searchKey] specifies the targeted column field name to filter against.
  /// [value] defines the target evaluation parameter bound to the deletion query constraint argument.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  ///
  /// Returns a [Future<int>] containing the total number of physical table rows deleted during this process block.
  Future<int> _rawDeleteByExecution(String searchKey, dynamic value, DatabaseExecutor activeExecutor) async {
    // Execute the low-level physical row deletion directly against the assigned driver context
    final int count = await activeExecutor.delete(tableName, where: '$searchKey = ?', whereArgs: [value]);

    if (count > 0) {
      FluentLog.debug(
        'Physical data layer entries removed successfully from the storage engine',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'searchColumnField': searchKey, 'purgedRowsCount': count},
      );

      // SCENARIO A: RELATIONAL INTEGRITY CLEANUP — Cascade cascade checks to wipe detached data structures
      if (_hasRelations && _relationsMixin != null) {
        // Pass the identical executing connection handle downstream to preserve atomic transaction boundaries
        await _relationsMixin!.cleanupOrphans(activeExecutor);
      }
    } else {
      // SCENARIO B: NO TARGET RECORDS FOUND — The execution criteria matched zero active row models
      FluentLog.debug(
        'Physical row destruction completed with zero affected records',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'searchColumnField': searchKey, 'searchValue': value.toString()},
      );
    }

    return count;
  }

  /// Deletes a mass collection of individual database row items from [$tableName] matching a set of unique [ids].
  ///
  /// This high-throughput batch destruction routine evaluates runtime routing contexts sequentially:
  /// * Evaluates input collection lengths early, immediately returning an accelerated [Future.value] fast-path if empty.
  /// * Forwards tracking arrays to [_executeDeleteChunks] if a [sharedBatch] context is explicitly supplied.
  /// * Intercepts active [_transactionExecutor] connections to process primary updates inside local locked loops.
  /// * Packs remaining criteria sets into a standard [FluentTask] for thread allocation and scheduler queuing.
  ///
  /// [ids] represents a unique [Set] of primitive or object identity keys matching the target table primary key field.
  /// [sharedBatch] provides an optional external atomic batch reference to stack database mutation statements.
  /// [policy] defines chunk constraints, thread allocation overrides, and scheduling prioritizations.
  ///
  /// Returns a [Future<void>] that completes when all rows match the deleted constraint layout.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final obsoleteSessionIds = {'sess_101', 'sess_102', 'sess_159'};
  ///
  /// await sessionRepository.deleteItemsByIds(
  ///   obsoleteSessionIds,
  ///   policy: const ExecutionPolicy(
  ///     chunkSize: 500, // Segment parameters to avoid exceeding SQLite max variable limits
  ///     useIsolate: true, // Offload array parsing and parameter formatting down to an isolate worker
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> deleteItemsByIds(Set<dynamic> ids, {Batch? sharedBatch, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final int idsLength = ids.length;
    if (idsLength == 0) {
      FluentLog.debug('Batch primary identity multi-purge operation short-circuited due to empty parameters', tag: '$tableName:pipeline', context: {'tableName': tableName});
      return Future<void>.value();
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Initiating global operational query pipeline for batch primary identity multi-purge record destruction',
      tag: '$tableName:operation',
      context: {
        'tableName': tableName,
        'primaryKeyColumn': pkName,
        'targetRecordsCount': idsLength,
        'isSharedBatch': sharedBatch != null,
        'hasActiveTransaction': _transactionExecutor != null,
        'hasCustomPolicy': policy != const ExecutionPolicy(),
      },
    );

    // SCENARIO A: SHARED BATCH CONTEXT — Direct slice chunks onto an existing external atomic batch array
    if (sharedBatch != null) {
      _executeDeleteChunks(sharedBatch, ids.toList(), policy.effectiveChunkSize, pkName);
      return Future<void>.value();
    }

    // SCENARIO B: ACTIVE TRANSACTION CONNECTION — Run sequential sweeps inside local locked loops
    if (_transactionExecutor != null) {
      return _rawBatchDeleteExecution(ids.toList(), pkName, _transactionExecutor!, policy);
    }

    // SCENARIO C: STANDARD TASK SCHEDULER — Package primary array arguments into a uniform framework task.
    // TableHelper maps arguments to array indices and configures multiple: true to handle broad purges.
    final FluentTask task = FluentTask(
      action: FluentDbAction.deleteItemsByIds,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(where: '$pkName IN (...)', arguments: ids.toList(), multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs transactional multi-row primary identity purges on the Main thread.
  ///
  /// This pipeline unpacks target argument lists to execute safe, chunked batch destructions inside atomic loops:
  /// * Evaluates input collection states to guard against uninitialized or empty identity parameter references.
  /// * Establishes an atomic database transaction context block to ensure structural rolled-back parity on failures.
  /// * Redirects operational engine queries to the transaction handle via [setTransactionExecutor].
  /// * Protects connection pools with a strict `finally` scope block that resets context paths via [restoreOriginalExecutor].
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<void> _executeDeleteItemsByIdsTaskOnMain(FluentTask task) async {
    final List<dynamic> idList = task.helper?.arguments ?? [];

    if (idList.isEmpty) {
      FluentLog.warning(
        'Database batch identity purge sequence aborted on Main due to empty criteria lists',
        tag: '$tableName:pipeline',
        hint: 'Verify that the task wrapper passes a non-empty identity collection array argument.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return;
    }

    final String pkName = _cachedPrimaryKey?.name ?? 'id';

    FluentLog.debug(
      'Executing Main-thread transactional batch identity record destruction sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'primaryKeyColumn': pkName, 'targetRecordsCount': idList.length},
    );

    try {
      // Wrap the mass multi-row deletion routine inside a localized database transaction scope
      await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          await _rawBatchDeleteExecution(idList, pkName, txn, task.policy);
        } finally {
          restoreOriginalExecutor();
        }
      });

      FluentLog.debug(
        'Database operational batch multi-purge successfully finalized inside storage layer',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'taskId': task.id, 'processedRecordsCount': idList.length},
      );
    } catch (e, s) {
      FluentLog.error(
        'Main-thread batch identity purge transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Analyze the total parameter length boundaries against SQLite engine constraints, check active table locks, or inspect index maps.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Low-level multi-row batch execution routine that handles chunked deletions and relational cleanup cycles.
  ///
  /// This high-throughput structural routine processes batch identity sets directly against the active connection:
  /// * Allocates an un-committed [Batch] structure linked directly to the passed [activeExecutor] reference context.
  /// * Segments mass tracking identifier collections into safe operational slices via [_executeDeleteChunks].
  /// * Flushes the piled queries into the storage layers using `noResult: true` to eliminate unnecessary memory overhead.
  /// * Spawns an orphan records sweeping routine via [_relationsMixin] to process foreign constraints.
  /// * Forwards the original transactional executor reference to child workers to maintain transaction scopes.
  ///
  /// [idList] defines the list of primitive or object identity keys targeted for deletion.
  /// [pkName] specifies the string column name assigned as the table's primary key identifier.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  /// [policy] carries configuration rules containing maximum variable boundary limits and chunk size modifiers.
  Future<void> _rawBatchDeleteExecution(List<dynamic> idList, String pkName, DatabaseExecutor activeExecutor, ExecutionPolicy policy) async {
    // Initialize an atomic batch compilation pipeline bounded to the current executor transaction pool
    final Batch batch = activeExecutor.batch();

    // Delegate identity arrays into parameterized raw chunks to conform to SQLite variable limits
    _executeDeleteChunks(batch, idList, policy.chunkSize!, pkName);

    await batch.commit(noResult: true);

    FluentLog.debug(
      'Physical batch identity deletion query successfully committed to the database storage engine',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'totalPurgedIdsCount': idList.length, 'configuredChunkSize': policy.chunkSize},
    );

    // SCENARIO A: RELATIONAL INTEGRITY CLEANUP — Cascade cascade checks to wipe detached data structures
    if (_hasRelations && _relationsMixin != null) {
      // Pass the identical executing connection handle downstream to preserve atomic transaction boundaries
      await _relationsMixin!.cleanupOrphans(activeExecutor);
    }
  }

  /// Segments large collection parameters into fixed, parameterized query blocks to avoid database variable limits.
  ///
  /// This performance-critical calculation routine shards tracking lists directly into individual batch operations:
  /// * Evaluates array boundaries to slice the data set safely without creating index overflow errors.
  /// * Leverages dynamic placeholder strings to generate parameterized target arrays for each chunk execution.
  /// * Piles row criteria commands into [batch] arrays using an `IN (...)` match clause for maximum efficiency.
  /// * Prevents thread blockages by computing slices using localized value parameters rather than heavy map objects.
  ///
  /// [batch] represents the ongoing database batch sequence used to group and execute multi-row mutations.
  /// [idList] defines the source list of unique record identifiers targeted for deletion.
  /// [chunkSize] specifies the maximum allowed variables allowed in a single database parameter block (e.g., SQLite limits).
  /// [pkName] defines the exact physical column string key assigned as the target table primary identifier.
  void _executeDeleteChunks(Batch batch, List<dynamic> idList, int chunkSize, String pkName) {
    final int totalLength = idList.length;

    // Iterate through the target collection using stepped boundaries to extract safe database parameter subsets
    for (int i = 0; i < totalLength; i += chunkSize) {
      final int end = (i + chunkSize > totalLength) ? totalLength : i + chunkSize;

      // Extract a localized parameter segment slicing from the historical identifier set
      final List<dynamic> chunk = idList.sublist(i, end);

      // Construct parameterized index placeholder strings matching the size of the current slice
      final String placeholders = _generatePlaceholders(chunk.length);

      batch.delete(tableName, where: '$pkName IN ($placeholders)', whereArgs: chunk);

      FluentLog.debug(
        'Segmented identification collection subset registered successfully into batch context',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'primaryKeyColumn': pkName, 'currentChunkStartIndex': i, 'currentChunkSliceLength': chunk.length, 'remainingIdentifiersCount': totalLength - end},
      );
    }
  }

  /// Generates an efficient comma-separated sequence of parameterized SQL bind tokens `(?, ?, ...)`.
  ///
  /// This performance-critical memory calculation utility builds selection array bindings:
  /// * Evaluates numerical boundaries early to return accelerated static shortcuts for common `count <= 1` use cases.
  /// * Leverages a lightweight [StringBuffer] array stream instead of standard string interpolation loops.
  /// * Reduces garbage collection overhead by eliminating transient intermediate string heap instantiations.
  ///
  /// [count] specifies the total number of individual parameter arguments requiring query binding placeholders.
  ///
  /// Returns a formatted [String] containing the bound tokens, or an empty string if [count] is less than or equal to zero.
  String _generatePlaceholders(int count) {
    // Fast-path evaluation: Return an empty string if zero or negative parameters are requested
    if (count <= 0) {
      return '';
    }
    // Performance shortcut: Bypass dynamic buffers entirely for single-parameter lookups
    if (count == 1) {
      return '?';
    }

    final StringBuffer sb = StringBuffer('?');
    for (int i = 1; i < count; i++) {
      sb.write(', ?');
    }

    FluentLog.debug(
      'Dynamic sql parameter index placeholders successfully generated',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'requestedCount': count, 'allocatedBufferLength': sb.length},
    );
    return sb.toString();
  }

  /// Sweeps through [$tableName] and permanently removes records whose timestamps have exceeded expiration limits.
  ///
  /// This automated maintenance utility evaluates execution layers sequentially to process stale records:
  /// * Evaluates active [batch] contexts to immediately chain raw delete statements without checking counts.
  /// * Checks explicit or transaction-bound [executor] states to process selections inside local locked loops.
  /// * Packages query variables into a standard [FluentTask] frame for structural scheduling across worker threads.
  ///
  /// [executor] provides an optional active transaction context to execute the extraction on an isolated runner.
  /// [batch] represents an optional atomic database batch context used to stack multiple database mutation commands.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the data layer sweeps are finalized.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Trigger a background automated cache maintenance sweep
  /// await sessionRepository.clearExpiredItems(
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.low, // Run as background task to ensure main interactions are prioritized
  ///     useIsolate: false,          // Execute locally on main if internal payload size remains light
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> clearExpiredItems({DatabaseExecutor? executor, Batch? batch, ExecutionPolicy policy = const ExecutionPolicy()}) {
    final String colName = modelSample.expiryColumn;
    final int now = DateTime.now().millisecondsSinceEpoch;

    final String whereClause = '$colName IS NOT NULL AND $colName <= ?';
    final List<Object?> whereArgs = <Object?>[now];

    // SCENARIO A: SHARED BATCH CONTEXT — Stage the deletion query into the provided atomic batch array
    if (batch != null) {
      FluentLog.debug(
        'Staging expired records removal query into external batch sequence',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'expiryColumnField': colName, 'referenceTimestamp': now},
      );
      batch.delete(tableName, where: whereClause, whereArgs: whereArgs);
      return Future<void>.value();
    }

    // SCENARIO B: EXPLICIT OR CACHED TRANSACTION — Execute directly on the assigned connection runner
    final DatabaseExecutor? activeTxn = executor ?? _transactionExecutor;
    if (activeTxn != null) {
      return _rawClearExpiredExecution(whereClause, whereArgs, activeTxn);
    }

    // SCENARIO C: STANDARD TASK SCHEDULER — Package cleanup criteria into a uniform framework task.
    // Dispatch a structured informational log via the centralized global facade pattern.
    FluentLog.debug(
      'Initiating global operational query pipeline for database cache expiration auto-cleanup sweeps',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'expiryColumnField': colName, 'referenceTimestamp': now, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.clearExpired,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(where: whereClause, whereArgs: whereArgs, multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs transactional expiration maintenance sweeps on the Main thread.
  ///
  /// This pipeline unpacks criteria boundaries to execute background cleanups safely within an atomic isolation lock:
  /// * Evaluates data existence constraints to guard against uninitialized or missing helper parameters.
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Redirects operational engine queries to the transaction handle via [setTransactionExecutor].
  /// * Strongly enforces strict generic casting on arguments via [List.from] to ensure compatibility with underlying bindings.
  /// * Protects connection pools with a strict `finally` scope block that resets context paths via [restoreOriginalExecutor].
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], [FluentLog.warning], or [FluentLog.error].
  Future<void> _executeClearExpiredItemsTaskOnMain(FluentTask task) async {
    final String? whereClause = task.helper?.where;
    final List<dynamic>? whereArgs = task.helper?.whereArgs;

    if (whereClause == null || whereArgs == null) {
      FluentLog.warning(
        'Database cache expiration sweep aborted on Main due to missing query parameters',
        tag: '$tableName:pipeline',
        hint: 'Verify that the task helper payload supplies both the conditional where-clause and its corresponding evaluation arguments.',
        context: {'tableName': tableName, 'taskId': task.id, 'isWhereClauseNull': whereClause == null, 'isWhereArgsNull': whereArgs == null},
      );
      return;
    }

    FluentLog.debug(
      'Executing Main-thread transactional database cache expiration maintenance sweep',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'conditionalWhereClause': whereClause, 'queryArgumentsCount': whereArgs.length},
    );

    try {
      // Wrap the record expiration sweep routine inside an atomic database transaction scope
      await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          final List<Object?> castedArgs = List<Object?>.from(whereArgs);
          await _rawClearExpiredExecution(whereClause, castedArgs, txn);
        } finally {
          restoreOriginalExecutor();
        }
      });

      FluentLog.debug('Database operational cache expiration sweep successfully finalized inside storage layer', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});
    } catch (e, s) {
      FluentLog.error(
        'Main-thread cache expiration transaction pipeline aborted due to execution driver failure',
        e,
        s,
        tag: '$tableName:exception',
        hint: 'Examine table indexing on columns evaluated by the expiration query, or look into active record transactional concurrency thresholds.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
    }
  }

  /// Low-level atomic driver execution routine that processes automated cache expiration and relational sweeps.
  ///
  /// This operational routine executes a direct deletion query against the storage engine:
  /// * Fires a parameterized raw SQL delete execution directly using the provided [activeExecutor] context.
  /// * Evaluates resulting row impact metrics to determine if deep relational integrity cycles are required.
  /// * Spawns an orphan record cleaning routine via [_relationsMixin] to process foreign constraints.
  /// * Preserves atomic transaction boundaries by passing down the active transaction context reference.
  ///
  /// [where] specifies the conditional filter query clause used to extract expired record documents.
  /// [whereArgs] contains the precise tracking timestamps or variables bound to the conditional arguments.
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  Future<void> _rawClearExpiredExecution(String where, List<Object?> whereArgs, DatabaseExecutor activeExecutor) async {
    final int count = await activeExecutor.delete(tableName, where: where, whereArgs: whereArgs);

    if (count > 0) {
      // SCENARIO A: STALE DATA PURGED — The cleanup sweep successfully located and removed expired entries
      FluentLog.debug('Physical data layer entries removed successfully during automated maintenance sweep', tag: '$tableName:pipeline', context: {'tableName': tableName, 'purgedRowsCount': count});

      // Evaluate cascading constraints to ensure data layer isolation consistency
      if (_hasRelations && _relationsMixin != null) {
        // Pass the identical executing connection handle downstream to preserve atomic transaction boundaries
        await _relationsMixin!.cleanupOrphans(activeExecutor);
      }
    } else {
      // SCENARIO B: DATA LAYER CLEAN — No active storage documents matched the expiration criteria bounds
      FluentLog.debug('Automated record maintenance sweep finalized with zero affected targets', tag: '$tableName:pipeline', context: {'tableName': tableName});
    }
  }

  /// Completely truncates and evacuates all rows permanently from the [$tableName] storage engine.
  ///
  /// This heavy operational maintenance pipeline evaluates runtime driver contexts sequentially:
  /// * Intercepts ongoing [_transactionExecutor] connections to process table clears inside local transaction locks.
  /// * Packages global truncation rules into a uniform [FluentTask] for thread allocation and supervisor queuing.
  /// * Triggers cascade constraint audits downstream if relational mixing structures are active.
  ///
  /// [policy] defines prioritization, query collapsing, and concurrency thresholds managed by the coordinator.
  ///
  /// Returns a [Future<void>] that completes successfully when the physical storage table is completely empty.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Wipe log cache table completely under a background operational priority
  /// await analyticsRepository.clearTable(
  ///   policy: const ExecutionPolicy(
  ///     priority: TaskPriority.low,
  ///     flushImmediate: true,
  ///   ),
  /// );
  /// ```
  @internal
  Future<void> clearTable({ExecutionPolicy policy = const ExecutionPolicy()}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for full storage table evacuation purges',
      tag: '$tableName:operation',
      context: {'tableName': tableName, 'hasActiveTransaction': _transactionExecutor != null, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    // SCENARIO A: TRANSACTION ENVELOPE — Execute directly on the local locked transaction connection pool
    if (_transactionExecutor != null) {
      return _rawClearTableExecution(_transactionExecutor!);
    }

    // SCENARIO B: STANDARD TASK PIPELINE — Encapsulate table truncation parameters into a uniform framework task.
    // TableHelper configures multiple: true to signal a comprehensive dataset evacuation.
    final FluentTask task = FluentTask(action: FluentDbAction.clearTable, table: tableName, dbName: dbName, helper: TableHelper(multiple: true), policy: policy);

    return FluentDb.executeTask<T, void>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs transactional whole-table evacuations on the Main thread.
  ///
  /// This pipeline handles full structural truncations safely within an atomic isolation lock:
  /// * Establishes an atomic database transaction callback to ensure consistency during multi-row wipes.
  /// * Overrides active query routes using [setTransactionExecutor] to hook operations to the current transaction frame.
  /// * Utilizes a strict `finally` structural block to guarantee connection pool restoration via [restoreOriginalExecutor].
  /// * Traps query issues, logging comprehensive data context diagnostics before propagation.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug], [FluentLog.debug], or [FluentLog.error].
  Future<void> _executeClearTableTaskOnMain(FluentTask task) async {
    FluentLog.debug('Executing Main-thread transactional table evacuation destruction sequence', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});

    try {
      // Wrap the complete table evacuation routine inside a localized database transaction scope
      await db.transaction((txn) async {
        // Divert the provider driver context to use the active transaction runner
        setTransactionExecutor(txn);

        try {
          await _rawClearTableExecution(txn);
        } finally {
          restoreOriginalExecutor();
        }
      });

      FluentLog.debug('Database operational table evacuation successfully finalized inside storage layer', tag: '$tableName:pipeline', context: {'tableName': tableName, 'taskId': task.id});
    } catch (e, st) {
      FluentLog.error(
        'Main-thread table evacuation transaction pipeline aborted due to execution driver failure',
        e,
        st,
        tag: '$tableName:exception',
        hint: 'Examine database indexing boundaries, active primary constraints, or evaluate concurrent connection pool configurations.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      rethrow;
    }
  }

  /// Low-level atomic driver execution routine that handles whole-table truncation and relational cleanup cycles.
  ///
  /// This routine interacts directly with the underlying database driver layer:
  /// * Fires an un-parameterized raw SQL delete operation across the target table via [activeExecutor].
  /// * Tracks total impacted rows before logging the finalized operation context.
  /// * Evaluates active [_relationsMixin] targets to cascade cleanup routines across orphan rows.
  /// * Maintains isolated transaction boundaries by forwarding the current connection handle downstream.
  ///
  /// [activeExecutor] represents the specific database engine connection scope executing this transaction.
  Future<void> _rawClearTableExecution(DatabaseExecutor activeExecutor) async {
    final int count = await activeExecutor.delete(tableName);

    FluentLog.debug('Storage table completely evacuated and cleared of physical row records', tag: '$tableName:pipeline', context: {'tableName': tableName, 'purgedRowsCount': count});

    if (_hasRelations && _relationsMixin != null) {
      await _relationsMixin!.cleanupOrphans(activeExecutor);
    }
  }

  /// Validates whether a specific database record entry exists within [$tableName] matching the given unique [id].
  ///
  /// This lightweight validation utility handles input verification and schedules row lookups sequentially:
  /// * Evaluates input boundaries early, immediately returning an accelerated [Future.value] fast-path if null.
  /// * Packages unique identifier matching rules into a highly optimized [FluentTask] payload configuration.
  /// * Constraints matching parameters to an internal `LIMIT 1` check via [TableHelper] to prevent full table scans.
  ///
  /// [id] represents the unique identity primary key value targeted for table validation checks.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<bool>] yielding `true` if a matching row is located in storage, otherwise `false`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final recordExists = await sessionRepository.exists(
  ///   'sess_9921',
  ///   policy: const ExecutionPolicy(priority: TaskPriority.critical),
  /// );
  /// ```
  @internal
  Future<bool> exists(dynamic id, {ExecutionPolicy policy = const ExecutionPolicy()}) {
    if (id == null) {
      return Future<bool>.value(false);
    }

    FluentLog.debug(
      'Initiating localized query pipeline for storage layer primary record existence validation',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'targetRecordId': id.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.exists,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(id: id, limit: 1, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, bool>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs highly optimized record existence lookups on the Main thread.
  ///
  /// This pipeline unpacks target identifier keys to execute low-level index probes safely:
  /// * Evaluates data existence constraints to guard against uninitialized or missing helper parameters.
  /// * Fires an optimized, lightweight raw SQL statement (`SELECT 1 ... LIMIT 1`) directly against the active executor connection.
  /// * Prevents unnecessary data hydration overhead by fetching constant markers rather than structural columns or mass row arrays.
  /// * Transforms collection state metrics directly into deterministic operational booleans.
  ///
  /// Dispatches structured operational logging maps via [FluentLog.debug] or [FluentLog.warning].
  Future<bool> _executeExistsTaskOnMain(FluentTask task) async {
    final dynamic id = task.helper?.id;

    if (id == null) {
      FluentLog.warning(
        'Database primary record existence check aborted on Main due to unassigned target identifier',
        tag: '$tableName:pipeline',
        hint: 'Verify that the task wrapper passes a valid non-null primary identity key inside the helper context.',
        context: {'tableName': tableName, 'taskId': task.id},
      );
      return false;
    }

    FluentLog.debug(
      'Executing Main-thread transactional database record existence validation sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'targetRecordId': id.toString()},
    );

    final List<Map<String, dynamic>> res = await executor.rawQuery('SELECT 1 FROM $tableName WHERE ${primaryKeyColumn.name} = ? LIMIT 1', <dynamic>[id]);

    final bool isExists = res.isNotEmpty;
    FluentLog.debug(
      'Database operational existence lookup finalized successfully',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'isMatchingRecordLocated': isExists},
    );

    return isExists;
  }

  /// Computes the total number of physical row record entries stored within [$tableName].
  ///
  /// This aggregation utility handles selective row scans or whole-dataset calculations sequentially:
  /// * Evaluates active filter flags to dynamically adjust structural task matching configurations.
  /// * Packages conditional strings and matching arguments into a standard [FluentTask] payload configuration.
  /// * Maps constraints via [TableHelper], setting up optimal compilation indices for target filters.
  ///
  /// [where] defines an optional conditional selection SQL filter clause used to constrain counting bounds.
  /// [whereArgs] contains the precise tracking parameters or variables bound to the conditional arguments.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [Future<int>] yielding the total count of rows matching the evaluated criteria parameters.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Calculate active rows matching an identity constraint using a background isolation priority
  /// final activeItemsCount = await sessionRepository.count(
  ///   where: 'status = ? AND is_stale = ?',
  ///   whereArgs: ['active', 0],
  ///   policy: const ExecutionPolicy(priority: TaskPriority.normal),
  /// );
  /// ```
  @internal
  Future<int> count({String? where, List<Object?>? whereArgs, ExecutionPolicy policy = const ExecutionPolicy()}) {
    FluentLog.debug(
      'Initiating global operational query pipeline for storage layer record aggregation counting',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'hasConditionalWhereFilter': where != null, 'queryArgumentsCount': whereArgs?.length ?? 0, 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.count,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(where: where, whereArgs: whereArgs, multiple: where == null),
      policy: policy,
    );

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }

  /// Direct data layer coordinator that runs highly optimized record aggregation counts on the Main thread.
  ///
  /// This pipeline unpacks selection parameters to execute low-level row counting operations safely:
  /// * Evaluates active filter flags to dynamically construct target parameterized SQL statements.
  /// * Strongly enforces strict generic casting on arguments via [List.from] to ensure compatibility with underlying bindings.
  /// * Fires a low-level optimized `COUNT(*)` query directly against the active executor engine runner.
  ///
  /// [task] represents the specific framework operational unit containing query boundaries, filters, and tracking keys.
  ///
  /// Returns a [Future<int>] yielding the total integer row accumulation result extracted from the storage engine.
  Future<int> _executeCountTaskOnMain(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<dynamic>? whereArgs = task.helper?.whereArgs;

    FluentLog.debug(
      'Executing Main-thread transactional database record aggregation counting sequence',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'conditionalWhereClause': where ?? 'NONE (FULL TABLE COUNT)', 'queryArgumentsCount': whereArgs?.length ?? 0},
    );

    // Cast generic runtime dynamic variables to the strict nullable object types required by sqflite
    final List<Object?>? castedArgs = whereArgs != null ? List<Object?>.from(whereArgs) : null;

    final List<Map<String, dynamic>> result = await executor.rawQuery('SELECT COUNT(*) as total FROM $tableName ${where != null ? 'WHERE $where' : ''}', castedArgs);

    final int totalCount = Sqflite.firstIntValue(result) ?? 0;

    FluentLog.debug(
      'Database operational aggregation counting finalized successfully',
      tag: '$tableName:pipeline',
      context: {'tableName': tableName, 'taskId': task.id, 'aggregatedRowsResult': totalCount},
    );

    return totalCount;
  }
}
