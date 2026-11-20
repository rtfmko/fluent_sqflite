// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// A sliding count of events (calls of one kind on one table) within [FluentAnalyzer.window].
class _Burst {
  _Burst(this.start);

  int start;
  int count = 0;
  int last = 0;

  /// The last time the event was seen, counted or not (the polling gap is measured from it).
  int seen = 0;
}

/// The analyzer: watches the engine's calls and turns what it sees into hints ([FluentIssue] of type hint) with code
/// to copy. The one place of the hint thresholds (the constants below; reads are judged by their average over
/// [FluentTableStatsTracker.minSamples] runs, never by one spike).
///
/// It never changes how calls run; it only observes them. The one exception: with the index tuning lever on
/// (`FluentTuning.indexes`) it proposes indexes to the tuner, which acts through the queue (the analyzer itself
/// changes nothing). Runs while the database's [FluentDiagnostics] collect hints
/// (debug / profile builds, or release with `hintsInRelease`, then without `EXPLAIN QUERY PLAN`). Sources:
/// * **slow reads** — `EXPLAIN QUERY PLAN` (debug / profile) shows whether SQLite reads every row or sorts in a temp
///   B-tree; the hint is the index that serves the filter and the order. In release, or when the plan cannot be read,
///   the filtered columns no index starts with are suggested instead;
/// * **measurements** — big unpaged reads, deep offsets, `LIKE '%…'`, heavy relation loading, very slow writes;
/// * **call patterns** — loops of awaited single `save` / `findById` calls, a flooded queue, the same query polled
///   while the data did not change, calls waiting long in the queue;
/// * **the schema** (at `init`, [onSchema]) — enum fields without `enumValues`, indexes another index already covers,
///   auto-increment keys on synced tables.
class FluentAnalyzer {
  static final FluentAnalyzer _instance = FluentAnalyzer._internal();

  /// The shared analyzer.
  factory FluentAnalyzer() => _instance;

  FluentAnalyzer._internal();

  /// Window of the call-pattern counters.
  static const Duration window = Duration(seconds: 2);

  /// Awaited single saves of one table within [window] that make a "save loop".
  static const int saveLoopCalls = 50;

  /// Awaited single `findById` calls of one table within [window] that make a lookup loop (N+1).
  static const int lookupLoopCalls = 30;

  /// Queued calls of one database that count as a flood.
  static const int floodQueue = 1000;

  /// Rows of an unpaged read that make it "big".
  static const int bigReadRows = 1000;

  /// An offset from which keyset paging (`findPage`) is suggested.
  static const int deepOffset = 1000;

  /// A `LIKE '%…'` read at least this slow (ms, on average over several runs) gets a hint.
  static const int slowLikeMs = 30;

  /// A read loading nested relations at least this slow (ms, on average) gets a hint.
  static const int slowRelationsMs = 100;

  /// A read shape at least this slow (ms, on average over several runs) is explained and gets a hint.
  static const int slowReadMs = 100;

  /// A single write at least this slow (ms) gets a hint.
  static const int slowWriteMs = 500;

  /// A call that waited at least this long (ms) in the queue gets a hint.
  static const int queueWaitMs = 1000;

  /// Identical reads (same data) needed for a polling hint, spread over at most [pollingSpan].
  static const int pollingRuns = 10;

  /// Identical reads closer than this (ms) are rebuilds, not polling, and are not counted.
  static const int pollingGapMs = 200;

  /// Longest span (ms) of the identical reads of a polling hint.
  static const int pollingSpan = 60000;

  /// Treats the build as a release build (tests).
  @visibleForTesting
  static bool releaseMode = kReleaseMode;

  /// Replaces the clock (epoch-free milliseconds) used by the call-pattern counters (tests).
  @visibleForTesting
  static int Function()? clock;

  final Stopwatch _stopwatch = Stopwatch()..start();
  final Map<String, _Burst> _bursts = {};

  /// The most counters [_bursts] keeps; above it old ones are dropped (at most once per second, [_prunedAt]). Pruning
  /// on every call once the map was full made each call scan thousands of counters (reads of distinct keys).
  static const int _maxBursts = 2000;
  int _prunedAt = -1 << 62;
  final Set<String> _explained = {};

  /// The slowest recent call per database (what may have held the queue).
  final Map<String, ({String what, int ms, int at})> _holders = {};

  int get _now => clock?.call() ?? _stopwatch.elapsedMilliseconds;

  /// Whether hints of database [db] are collected: its diagnostics have `hints` on, and this is a debug / profile
  /// build or `hintsInRelease` is on.
  bool collects(String? db) {
    final FluentDiagnostics d = FluentEngine().diagnosticsOf(db);
    return d.hints && (!releaseMode || d.hintsInRelease);
  }

  /// Whether query plans may be read (debug / profile only: one extra statement per slow query shape).
  bool get canExplain => !releaseMode;

  /// Forgets the counters (engine reset, tests); hints already shown stay shown.
  void reset() {
    _bursts.clear();
    _explained.clear();
    _holders.clear();
  }

  int _bump(String key, {int span = 0}) {
    final int now = _now;
    final _Burst b = _bursts[key] ??= _Burst(now);
    if (now - b.start > (span == 0 ? window.inMilliseconds : span)) {
      b
        ..start = now
        ..count = 0;
    }
    b
      ..count += 1
      ..last = now;
    if (_bursts.length > _maxBursts && now - _prunedAt >= 1000) {
      _prunedAt = now;
      _bursts.removeWhere((_, v) => now - v.last > pollingSpan);
      // Still full (many distinct reads within the polling span): drop the oldest half (insertion order).
      if (_bursts.length > _maxBursts) _bursts.keys.take(_bursts.length - _maxBursts ~/ 2).toList().forEach(_bursts.remove);
    }
    return b.count;
  }

  static String _model(String db, String table) => FluentDbInternals.lookupByTable(table, db)?.modelType.toString() ?? table;

  // ---------------------------------------------------------------------------
  // Engine hooks
  // ---------------------------------------------------------------------------

  /// A read was submitted; [epoch] is the write epoch of its database (changes with every write).
  void onDispatch(FluentTask task, int epoch) {
    if (task.table.isEmpty || !collects(task.dbName)) return;
    final String key = 'poll|${task.fingerprint}#$epoch';
    final int now = _now;
    final _Burst? b = _bursts[key];
    // Gap from the last read seen (counted or not): a rebuild storm or several widgets keep it short, a timer does not.
    final bool storm = b != null && now - b.seen < pollingGapMs;
    if (b != null) b.seen = now;
    if (storm) return;
    final int runs = _bump(key, span: pollingSpan);
    _bursts[key]!.seen = now;
    if (runs < pollingRuns) return;
    final String model = _model(task.dbName, task.table);
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.polling,
        database: task.dbName,
        table: task.table,
        title: 'Watch "${task.table}" instead of reading it again and again',
        details: 'The same ${task.action.name} ran $pollingRuns times while the data did not change (a timer or a refresh loop). '
            'watch() reads once and emits again only after a write that changes the table.',
        fix: 'Replace the timer or refresh loop with FluentDb.watch<$model>(...): it reads once and emits again only after a write to the table.',
        code: 'StreamBuilder<List<$model>>(\n'
            '  stream: FluentDb.watch<$model>(where: ...),\n'
            '  builder: (context, snapshot) => ...,\n'
            ');',
      ),
    );
  }

  /// [task] entered the queue of its database, which now holds [queued] calls.
  void onEnqueue(FluentTask task, int queued) {
    if (!collects(task.dbName)) return;
    final int? offset = task.helper?.offset;
    if (offset != null && offset >= deepOffset) _hintDeepOffset(task, offset);
    if (queued >= floodQueue) {
      FluentLog.publish(
        FluentIssue(
          kind: FluentIssueKind.flood,
          database: task.dbName,
          title: 'Batch the calls of "${task.dbName}" instead of queueing thousands',
          details: '$queued calls of "${task.dbName}" were queued at once (the last one: ${task.action.name} on "${task.table}"). '
              'Each waits for the ones before it; one batched call does the same work in one transaction.',
          fix: 'Save many rows with one saveAll call, or await each call so the queue stays short.',
          code: 'await FluentDb.saveAll<${_model(task.dbName, task.table)}>(items); // instead of items.forEach(FluentDb.save)\n'
              '// or await each call, so the app sees errors and the queue stays short',
        ),
      );
    }
  }

  /// [task] starts after waiting [waitedMs] in the queue.
  void onStart(FluentTask task, int waitedMs) {
    if (waitedMs < queueWaitMs || !collects(task.dbName)) return;
    final ({String what, int ms, int at})? holder = _holders[task.dbName];
    final String heldBy = holder == null || _now - holder.at > waitedMs + 1000 ? '' : ' The slowest call before it: ${holder.what} (${holder.ms} ms).';
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.queueWait,
        database: task.dbName,
        title: 'Calls of "${task.dbName}" wait long in the queue',
        details: '${task.action.name} on "${task.table}" waited $waitedMs ms before it could start.$heldBy '
            'A write runs alone and every call queued after it waits; long transactions and big writes hold everything.',
        fix: 'Keep transactions short (no network or UI waits inside) and split big writes into chunks, so queued calls can start.',
        code: '// keep FluentDb.transaction short (no network / UI waits inside)\n'
            '// split big imports: for (final chunk in items.slices(500)) await FluentDb.saveAll<Model>(chunk);\n'
            "debugPrint('\${FluentDb.engineStats()}'); // queue and wait times",
      ),
    );
  }

  /// [task] ended after [elapsedMs] (any outcome); remembered as a possible queue holder.
  void onDone(FluentTask task, int elapsedMs) {
    if (elapsedMs < 200 || !collects(task.dbName)) return;
    final ({String what, int ms, int at})? old = _holders[task.dbName];
    if (old == null || _now - old.at > window.inMilliseconds || elapsedMs >= old.ms) {
      _holders[task.dbName] = (what: task.action == FluentDbAction.transaction ? 'a transaction' : '${task.action.name} on "${task.table}"', ms: elapsedMs, at: _now);
    }
  }

  /// [task] of [provider] succeeded after [elapsedMs] with [result].
  void onFinish(FluentTask task, FluentProvider provider, int elapsedMs, Object? result) {
    if (!collects(task.dbName)) return;
    final String db = task.dbName;
    final String table = task.table;
    final bool single = !task.isBatched && (task.data is! List || (task.data as List).length == 1);
    if (task.action == FluentDbAction.save && single && _bump('save|$db|$table') == saveLoopCalls) _hintSaveLoop(task);
    if (task.action == FluentDbAction.findById && !task.isBatched && _bump('find|$db|$table') == lookupLoopCalls) _hintLookupLoop(task, provider);
    if (task.isWriteOp) {
      if (elapsedMs >= slowWriteMs) _hintSlowWrite(task, elapsedMs);
      return;
    }
    if ((task.action == FluentDbAction.find || task.action == FluentDbAction.findMaps) && task.helper?.limit == null && result is List && result.length >= bigReadRows) {
      _hintBigRead(task, result.length, elapsedMs);
    }
    // Judged by the trusted average of the shape (like the other read hints), never by one run; the current run is
    // recorded by the engine right after this hook, so the average lags by one run.
    final double? average = FluentTableStatsTracker().averageMs(task);
    if (average != null && average >= slowLikeMs) _hintLeadingLike(task);
  }

  /// The trusted average of [task]'s shape is slow ([FluentTableStatsTracker.slowReadMs]): relation hint and query plan;
  /// also runs without hints when the index tuner is on (`FluentTuning.indexes`), which takes its index proposals.
  void onSlowShape(FluentTask task, double averageMs, int samples) {
    if (!collects(task.dbName) && !FluentEngine().diagnosticsOf(task.dbName).tuning.indexes) return;
    final FluentProvider? provider = FluentDbInternals.lookupByTable(task.table, task.dbName);
    if (provider == null) return;
    if ((task.maxDepth > 1 || task.ignoreLazy) && averageMs >= slowRelationsMs) _hintRelations(task.dbName, task.table, averageMs);
    unawaited(explain(task, provider, '~${averageMs.round()} ms on average ($samples runs)'));
  }

  /// Reviews the compiled schema of [provider] (at `init`, after the relation graph).
  void onSchema(FluentProvider provider) {
    if (!collects(provider.dbName)) return;
    final String db = provider.dbName;
    final String table = provider.tableName;
    final String model = provider.modelType.toString();

    // Enum fields without enumValues come back as String.
    final Map<String, List<Enum>> enums = provider.modelSample.enumValues;
    for (final FluentDbColumn c in provider.getFullSchema) {
      if (c.valueKind != FluentValueKind.enumValue || c.converter != null || enums.containsKey(c.name)) continue;
      FluentLog.publish(
        FluentIssue(
          kind: FluentIssueKind.enumValues,
          database: db,
          subject: c.name,
          table: table,
          title: 'Declare the values of the enum field "$table.${c.name}"',
          details: '$model stores an enum in "${c.name}" but enumValues does not list its values, so reads return the stored String '
              '(fromCacheJson casting it to the enum fails) and filters compare names by hand.',
          fix: 'Add the enum to enumValues of $model: {"column": EnumType.values}.',
          code: 'class $model extends FluentStorable {\n'
              '  @override\n'
              "  Map<String, List<Enum>> get enumValues => {'${c.name}': YourEnum.values};\n"
              '}',
        ),
      );
    }

    // Indexes whose columns are the leading columns of another index (or of the key) cost writes and space for nothing.
    final List<List<String>> covering = [
      provider.keyColumnNames.toList(),
      for (final FluentIndex i in provider.tableIndexes)
        if (i.where == null) i.columns,
    ];
    for (final FluentIndex index in provider.modelSample.indexes) {
      if (index.fullText || index.unique || index.where != null) continue;
      final List<String>? by = covering.where((c) => c.length >= index.columns.length && !listEquals(c, index.columns) && listEquals(c.sublist(0, index.columns.length), index.columns)).firstOrNull;
      final bool isKey = listEquals(provider.keyColumnNames.toList(), index.columns);
      if (by == null && !isKey) continue;
      FluentLog.publish(
        FluentIssue(
          kind: FluentIssueKind.redundantIndex,
          database: db,
          subject: index.columns.join(','),
          table: table,
          title: 'Remove the index on $table(${index.columns.join(', ')})',
          details: isKey
              ? 'It repeats the primary key, which SQLite already indexes. Every write updates it for nothing.'
              : 'The index on ($table(${by!.join(', ')})) starts with the same columns and serves the same queries. Every write updates both.',
          fix: 'Remove this FluentIndex from the indexes of $model; the other index (or the key) serves the same queries.',
          code: "// in $model.indexes, remove: FluentIndex([${index.columns.map((c) => "'$c'").join(', ')}])",
        ),
      );
    }

    // Synced tables with local auto-increment keys: two devices create the same id.
    if (provider is FluentSyncable && provider.modelSample.tableConfig.serverKey == null && provider.primaryKeyColumns.length == 1 && provider.primaryKeyColumns.first.isAutoIncrement) {
      final String key = provider.primaryKeyColumns.first.name;
      FluentLog.publish(
        FluentIssue(
          kind: FluentIssueKind.syncKey,
          database: db,
          table: table,
          title: 'Give synced "$table" rows keys made on the device',
          fix: 'Use a key made on the device (a text UUID) instead of the auto-increment "$key", or keep the local id and match server rows by their own id with FluentTableConfig(serverKey: [...]).',
          details: '"$table" syncs with a server but its key "$key" is an auto-increment number: two devices (or a device and the '
              'server) create the same id for different rows, and a pull overwrites one with the other.',
          code: '// a text key created on the device (e.g. a UUID), in $model:\n'
              '@override\n'
              "List<FluentDbColumn> get primaryKeys => [FluentDbColumn(name: '$key', type: FluentDbDataType.text, isPrimaryKey: true)];\n"
              '// or keep the local id and match server rows by their own id:\n'
              "FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);",
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Slow reads: the query plan
  // ---------------------------------------------------------------------------

  static const Set<FluentDbAction> _plannable = {FluentDbAction.find, FluentDbAction.findMaps, FluentDbAction.count};

  /// Reads the query plan of [task] once per shape (debug / profile) and suggests the index it lacks; in release, or
  /// when the plan cannot be read, falls back to the filtered columns no index starts with.
  @visibleForTesting
  Future<void> explain(FluentTask task, FluentProvider provider, String measured) async {
    if (!_plannable.contains(task.action) || (task.helper?.deferred?.isNotEmpty ?? false) || !_explained.add('${task.dbName}|${task.table}|${FluentTableStatsTracker.shapeOf(task)}')) return;
    final _Wanted wanted = _Wanted.of(task, provider);
    if (wanted.isEmpty) return;
    if (!canExplain) return _hintIndex(task, provider, wanted.unindexed(provider), measured, null);
    final TableHelper? h = task.helper;
    final StringBuffer sql = StringBuffer('EXPLAIN QUERY PLAN SELECT ${task.action == FluentDbAction.count ? 'COUNT(*)' : '*'} FROM ${task.table.quotedIdentifier}');
    if (h?.where != null) sql.write(' WHERE ${h!.where}');
    if (h?.orderBy != null) sql.write(' ORDER BY ${h!.orderBy}');
    if (h?.limit != null) sql.write(' LIMIT ${h!.limit}');
    final List<String> plan;
    try {
      // A background-priority read through the queue (never a barrier, so it runs where a read may run, on a pooled read
      // connection, and never waits for a user transaction on the main connection). Started in a copy of the current
      // zone without the transaction and the running task: it must not join the transaction or the task whose finish
      // started the hint. (Not `Zone.root`: a failing call started there never completes its caller and leaks an
      // unhandled error.)
      final List<Map<String, dynamic>> rows = await Zone.current.fork(zoneValues: {FluentTransactionScope._zoneKey: null, FluentEngine._runningTaskKey: null}).run(
        () => FluentDbInternals.executeTask<FluentStorable, List<Map<String, dynamic>>>(
          provider: provider,
          task: FluentTask(
            action: FluentDbAction.rawQuery,
            table: task.table,
            dbName: task.dbName,
            helper: TableHelper(sql: sql.toString(), whereArgs: h?.whereArgs),
            policy: ExecutionPolicy.background,
            maxDepth: 0,
          ),
        ),
      );
      plan = [for (final Map<String, dynamic> row in rows) '${row['detail']}'];
    } on FluentCancelledException {
      return; // the engine closed meanwhile: there is nothing left to hint
    } catch (e) {
      FluentLog.debug('Query plan not available: $e', tag: '${task.table}:analyzer');
      return _hintIndex(task, provider, wanted.unindexed(provider), measured, null);
    }
    _hintIndex(task, provider, wanted.fromPlan(plan, task.table), measured, plan);
  }

  void _hintIndex(FluentTask task, FluentProvider provider, List<String> columns, String measured, List<String>? plan) {
    if (columns.isEmpty) return;
    FluentTuner().proposeIndex(task, provider, columns);
    final String model = provider.modelType.toString();
    final String planText = plan == null ? '' : ' Query plan: ${plan.join('; ')}.';
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.missingIndex,
        database: task.dbName,
        subject: columns.join(','),
        table: task.table,
        title: 'Add an index on ${task.table}(${columns.join(', ')})',
        details: '${task.action.name} with ${FluentTableStatsTracker.shapeOf(task)} takes $measured.$planText '
            'An index on these columns (equality filters first, then the range or the order) lets SQLite jump to the rows; '
            'it is created on the next start.',
        fix: 'Add a FluentIndex on these columns to the indexes of the model (equality columns first, then range or order); it is created on the next start.',
        code: indexExample(model, columns),
      ),
    );
  }

  /// The code adding an index on [columns] to [model].
  static String indexExample(String model, List<String> columns) =>
      'class $model extends FluentStorable {\n'
      '  @override\n'
      '  List<FluentIndex> get indexes => [FluentIndex([${columns.map((c) => "'$c'").join(', ')}])];\n'
      '}';

  // ---------------------------------------------------------------------------
  // Hints
  // ---------------------------------------------------------------------------

  void _hintSaveLoop(FluentTask task) {
    final String model = _model(task.dbName, task.table);
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.saveLoop,
        database: task.dbName,
        table: task.table,
        title: 'Save "${task.table}" rows with saveAll instead of one by one',
        details: '$saveLoopCalls single saves of "${task.table}" ran one after another within ${window.inSeconds} s (each awaited, so they '
            'could not be merged). Every save is its own transaction; saveAll writes all rows in one.',
        fix: 'Collect the rows and save them with one saveAll call, or wrap the loop in FluentDb.transaction.',
        code: 'await FluentDb.saveAll<$model>(items);\n'
            '// instead of: for (final item in items) await FluentDb.save<$model>(item);',
      ),
    );
  }

  void _hintLookupLoop(FluentTask task, FluentProvider provider) {
    final String model = provider.modelType.toString();
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.lookupLoop,
        database: task.dbName,
        table: task.table,
        title: 'Read "${task.table}" rows by a list of keys instead of one by one',
        details: '$lookupLoopCalls findById calls of "${task.table}" ran one after another within ${window.inSeconds} s (N+1 reads). '
            'One query with all keys is much faster; if the rows belong to other models, a relation loads them in batches.',
        fix: 'Read all keys with one findByIds call, or declare a relation so the rows are loaded in batches.',
        code: 'final List<$model> rows = await FluentDb.findByIds<$model>(ids);\n'
            '// instead of: for (final id in ids) await FluentDb.findById<$model>(id);',
      ),
    );
  }

  void _hintBigRead(FluentTask task, int rows, int elapsedMs) {
    final String model = _model(task.dbName, task.table);
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.bigRead,
        database: task.dbName,
        table: task.table,
        title: 'Read "${task.table}" in pages',
        details: 'One read returned $rows rows without a limit ($elapsedMs ms, all of them in memory as models). '
            'Lists usually show a page at a time; findPage loads the next page when the user scrolls.',
        fix: 'Read a page at a time with findPage (orderBy + limit) or pass a limit.',
        code: "FluentPage<$model> page = await FluentDb.findPage<$model>(orderBy: 'id', limit: 50);\n"
            "page = await FluentDb.findPage<$model>(orderBy: 'id', limit: 50, after: page.next); // next page",
      ),
    );
  }

  void _hintDeepOffset(FluentTask task, int offset) {
    final String model = _model(task.dbName, task.table);
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.deepOffset,
        database: task.dbName,
        table: task.table,
        title: 'Page "${task.table}" with findPage instead of a big offset',
        details: 'A read of "${task.table}" skips $offset rows: SQLite still reads every skipped row, so each page is slower than the last. '
            'findPage continues after the last row of the previous page, so every page costs the same.',
        fix: 'Page with findPage (after: previous page next) instead of a big offset.',
        code: "FluentPage<$model> page = await FluentDb.findPage<$model>(orderBy: 'id', limit: 50, after: previous?.next);",
      ),
    );
  }

  static final RegExp _like = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s+LIKE\s+\?');

  void _hintLeadingLike(FluentTask task) {
    final String? where = task.helper?.where;
    final List<dynamic>? args = task.helper?.whereArgs;
    if (where == null || args == null || !where.contains('LIKE')) return;
    for (final RegExpMatch m in _like.allMatches(where)) {
      final int index = '?'.allMatches(where.substring(0, m.end)).length - 1;
      final Object? arg = index < args.length ? args[index] : null;
      if (arg is! String || !arg.startsWith('%')) continue;
      final String column = m.group(1)!;
      FluentLog.publish(
        FluentIssue(
          kind: FluentIssueKind.like,
          database: task.dbName,
          subject: column,
          table: task.table,
          title: 'Search "${task.table}.$column" by prefix if you can',
          details: 'A LIKE pattern that starts with % (contains / endsWith) cannot use an index: SQLite reads every row. '
              'A prefix search (startsWith) can, with an index on a NOCASE column.',
          fix: 'Use FluentFilter.startsWith with an index on a NOCASE column, or a full-text index (FluentFilter.search) for words inside text.',
          code: "FluentFilter.startsWith('$column', text) // instead of FluentFilter.contains('$column', text)\n"
              '// in the model:\n'
              "FluentDbColumn.text('$column', collation: FluentCollation.noCase) // in missingColumns\n"
              "FluentIndex(['$column']) // in indexes",
        ),
      );
    }
  }

  void _hintRelations(String db, String table, double averageMs) {
    final String model = _model(db, table);
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.relations,
        database: db,
        table: table,
        title: 'Load fewer relation levels of "$table"',
        details: 'Reads of "$table" load relations several levels deep and take ~${averageMs.round()} ms on average.',
        fix: 'Load fewer levels (maxDepth: 1 or FluentLoad.none) and mark big relations lazy, loading them only when needed.',
        code: 'await FluentDb.find<$model>(maxDepth: 1); // or relations: FluentLoad.none for lists\n'
            "// and load big relations only when needed: FluentRelation.many(..., lazy: true) + model.loadRelations(names: ['...'])",
      ),
    );
  }

  void _hintSlowWrite(FluentTask task, int elapsedMs) {
    final String model = _model(task.dbName, task.table);
    final int items = task.data is List ? (task.data as List).length : 1;
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.slowWrite,
        database: task.dbName,
        table: task.table,
        title: 'Split big writes of "${task.table}"',
        details: '${task.action.name} of $items row(s) on "${task.table}" took $elapsedMs ms. A write runs alone: every other call of '
            'the database waits for it. Smaller chunks let reads in between.',
        fix: 'Save in chunks (for example 500 rows per call) so reads can run between the writes.',
        code: 'for (final chunk in items.slices(500)) {\n'
            '  await FluentDb.saveAll<$model>(chunk);\n'
            '}',
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // The report
  // ---------------------------------------------------------------------------

  /// Every issue of this run plus the hints derived from the measured query costs (also measured in earlier runs);
  /// muted ones excepted. Hints come first, by impact.
  FluentReport report() {
    final List<FluentIssue> seen = FluentLog.seen;
    final Set<String> keys = {for (final FluentIssue i in seen) i.key};
    final List<FluentIssue> all = [
      ...seen,
      for (final FluentIssue h in FluentTableStatsTracker().measuredHints())
        if (!FluentLog.isMuted(h.key) && keys.add(h.key) && collects(h.database)) h,
    ];
    int rank(FluentIssue i) => i.type == FluentIssueType.hint ? i.priority.index : FluentIssueImpact.values.length + i.type.index;
    final List<int> order = List<int>.generate(all.length, (i) => i)..sort((a, b) => rank(all[a]) != rank(all[b]) ? rank(all[a]).compareTo(rank(all[b])) : a.compareTo(b));
    return FluentReport([for (final int i in order) all[i]]);
  }
}

/// The columns an index for a read should have: equality filters, then one range filter, then the order.
class _Wanted {
  _Wanted(this.equal, this.range, this.order);

  final List<String> equal;
  final List<String> range;
  final String? order;

  bool get isEmpty => equal.isEmpty && range.isEmpty && order == null;

  static final RegExp _filtered = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*(<=|>=|=|<|>|IN\b|IS\b|BETWEEN\b)', caseSensitive: false);
  static final RegExp _orderColumn = RegExp(r'^"?([A-Za-z_][A-Za-z0-9_]*)"?(\s+(ASC|DESC))?$', caseSensitive: false);

  /// From the caller's condition (`helper.shape`, without the library's visibility filters) and order of [task].
  static _Wanted of(FluentTask task, FluentProvider provider) {
    final Set<String> known = {for (final FluentDbColumn c in provider.getFullSchema) c.name};
    final String condition = (task.helper?.shape ?? '').replaceAll(RegExp(r'\[[^\]]*\]'), '');
    final List<String> equal = [];
    final List<String> range = [];
    for (final RegExpMatch m in _filtered.allMatches(condition)) {
      final String column = m.group(1)!;
      if (!known.contains(column) || equal.contains(column) || range.contains(column)) continue;
      final String op = m.group(2)!.toUpperCase();
      (op == '=' || op == 'IN' || op == 'IS' ? equal : range).add(column);
    }
    String? order;
    final String? orderBy = task.helper?.orderBy;
    if (orderBy != null) {
      final RegExpMatch? m = _orderColumn.firstMatch(orderBy.split(',').first.trim());
      if (m != null && known.contains(m.group(1)) && !equal.contains(m.group(1))) order = m.group(1);
    }
    return _Wanted(equal, range, order);
  }

  /// The index columns: equality columns, then the first range column, or else the order column.
  List<String> get columns => [...equal, if (range.isNotEmpty) range.first else ?order];

  /// [columns] when [plan] shows a full scan of [table] with a filter, or a temp B-tree for the order; otherwise none.
  List<String> fromPlan(List<String> plan, String table) {
    final String name = RegExp.escape(table);
    final RegExp scan = RegExp('^SCAN (TABLE )?"?$name"?(\\s|\$)');
    final bool fullScan = plan.any((l) => scan.hasMatch(l.trim()) && !l.contains('INDEX'));
    final bool scanInOrder = plan.any((l) => scan.hasMatch(l.trim()) && l.contains('INDEX'));
    final bool sorts = plan.any((l) => l.contains('TEMP B-TREE FOR ORDER BY') || l.contains('TEMP B-TREE FOR RIGHT PART OF ORDER BY'));
    final bool filtered = equal.isNotEmpty || range.isNotEmpty;
    if ((fullScan || scanInOrder) && filtered) return columns;
    if (sorts && order != null && range.isEmpty) return columns;
    return const [];
  }

  /// Without a plan: the filtered columns no index (nor the key, nor a unique column) starts with.
  List<String> unindexed(FluentProvider provider) {
    final Set<String> leading = {
      for (final FluentIndex index in provider.tableIndexes) index.columns.first,
      ...provider.keyColumnNames.take(1),
      for (final FluentDbColumn c in provider.getFullSchema)
        if (c.isUnique) c.name,
    };
    final List<String> filtered = [...equal, ...range];
    return filtered.any(leading.contains) || filtered.isEmpty ? const [] : columns;
  }
}
