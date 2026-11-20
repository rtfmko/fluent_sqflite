// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The stats table of every writable database file: one row per measured query shape (and per mapped table).
const String _statsTable = '__fluent_stats';

/// The `action` of the rows holding the cost of turning one row into a model (`avg_ms` = microseconds per row).
const String _mappingAction = 'map';

/// One measured query shape.
class _QueryCost {
  _QueryCost(this.db, this.table, this.action, this.shape, {this.averageMs = 0, this.averageRows, this.samples = 0, this.failures = 0, this.lastUsed = 0});

  final String db;
  final String table;
  final String action;
  final String shape;
  double averageMs;
  double? averageRows;
  int samples;
  int failures;

  /// Epoch milliseconds of the last run.
  int lastUsed;

  String get key => '$db|$rowKey';

  /// The key inside the database's own stats table.
  String get rowKey => '$table|$action|$shape';

  bool get isMapping => action == _mappingAction;

  FluentQueryCost get public => FluentQueryCost(database: db, table: table, action: action, shape: shape, averageMs: averageMs, averageRows: averageRows, samples: samples, failures: failures);

  Map<String, Object?> get row => {'key': rowKey, 'tbl': table, 'action': action, 'shape': shape, 'avg_ms': averageMs, 'avg_rows': averageRows, 'samples': samples, 'failures': failures, 'last_used': lastUsed};
}

/// The cost model of the engine: how long each query shape takes, learned from real runs.
///
/// * A shape is table + operation + condition without values (+ order, limit, relation depth), so measurements of
///   the same query with different values add up, and different queries of one table do not mix.
/// * Also kept: the rows a read returned (moving average) and, per table, the cost of turning one row into a model
///   (`isolateMapping: smart` decides with it right after a restart).
/// * Forgetting: a moving average (a new run weighs 20 %, 30 % for mapping costs) follows changes of the data; shapes unused for [retention]
///   are dropped; at most [capacity] shapes are kept (least recently used go).
/// * Persisted in each database's own `__fluent_stats` table: only changed shapes, when that database is idle, at
///   most every few minutes, and on close. So weights are accurate right after a restart, and the numbers go away
///   with the database. In-memory and read-only databases keep them in memory only. Nothing scans user tables.
/// * Feeds read weights (after [minSamples] runs), the analyzer (slow shapes), the optimization report
///   ([measuredHints]) and `FluentDb.queryStats()`.
class FluentTableStatsTracker {
  static final FluentTableStatsTracker _instance = FluentTableStatsTracker._internal();

  /// The shared tracker.
  factory FluentTableStatsTracker() => _instance;

  FluentTableStatsTracker._internal();

  /// Maximum number of shapes kept.
  static const int capacity = 500;

  /// Runs needed before a shape's average is trusted for weights and hints.
  static const int minSamples = 3;

  /// A read shape slower than this (ms, on average) is handed to the analyzer, once per run (again after [forgetKey]).
  static const double slowReadMs = FluentAnalyzer.slowReadMs + 0.0;

  /// Shapes not run for this long are forgotten (dropped when a database is opened).
  static const Duration retention = Duration(days: 30);

  /// SQL creating the stats table of a database (run at init, before any read task).
  static const String createTableSql =
      'CREATE TABLE IF NOT EXISTS "$_statsTable" (key TEXT PRIMARY KEY, tbl TEXT NOT NULL, action TEXT NOT NULL, shape TEXT NOT NULL, '
      'avg_ms REAL NOT NULL, avg_rows REAL, samples INTEGER NOT NULL, failures INTEGER NOT NULL, last_used INTEGER NOT NULL)';

  /// Name of the stats table.
  static const String table = _statsTable;

  final Map<String, _QueryCost> _costs = {};

  /// Keys ([_QueryCost.key]) of shapes changed since they were last written.
  final Set<String> _changed = {};

  /// Row keys to delete, per database.
  final Map<String, Set<String>> _removed = {};
  final Set<String> _hinted = {};

  /// Whether any measurement was not written yet (cheap: no allocation; see [dirtyDatabases]).
  bool get hasChanges => _changed.isNotEmpty || _removed.isNotEmpty;

  /// Databases with measurements not written yet.
  Set<String> get dirtyDatabases => {for (final String key in _changed) key.substring(0, key.indexOf('|')), ..._removed.keys};

  void _remove(_QueryCost cost) {
    _costs.remove(cost.key);
    _changed.remove(cost.key);
    (_removed[cost.db] ??= {}).add(cost.rowKey);
  }

  static final RegExp _paramList = RegExp(r'\?(\s*,\s*\?)+');

  /// The shape of [task] (condition without values, order, limit, relation depth).
  static String shapeOf(FluentTask task) {
    final TableHelper? h = task.helper;
    final StringBuffer shape = StringBuffer((h?.shape ?? h?.where ?? '').replaceAll(_paramList, '?…'));
    if (h?.orderBy != null) shape.write(' ORDER BY ${h!.orderBy}');
    if (h?.limit != null) shape.write(' LIMIT');
    if (!task.isWriteOp && (task.maxDepth != 1 || task.ignoreLazy)) shape.write(' depth=${task.maxDepth}${task.ignoreLazy ? '+lazy' : ''}');
    return shape.toString().trim();
  }

  /// Whether the cost model runs for database [db] (`FluentDiagnostics.costModel`).
  static bool _measures(String db) => FluentEngine().diagnosticsOf(db).costModel;

  /// The key of [task]'s shape (database, table, action, shape).
  static String keyOf(FluentTask task) => '${task.dbName}|${task.table}|${task.action.name}|${shapeOf(task)}';

  /// Forgets the measurements of one shape [key] (an index changed it: measure it again).
  void forgetKey(String key) {
    final _QueryCost? cost = _costs.remove(key);
    if (cost == null) return;
    _changed.remove('${cost.db}|${cost.rowKey}');
    (_removed[cost.db] ??= {}).add(cost.rowKey);
    _hinted.remove(key);
  }

  _QueryCost _entry(FluentTask task) => _costs[task.costKey] ??= _QueryCost(task.dbName, task.table, task.action.name, shapeOf(task));

  /// Records a successful run of [task] that took [elapsedMs] (per item for writes of several items); [rows] is the
  /// number of rows a read returned, when it returned a list.
  void record(FluentTask task, int elapsedMs, {int? rows}) {
    if (task.action == FluentDbAction.transaction || task.table.isEmpty || !_measures(task.dbName)) return;
    final int items = task.isWriteOp && task.data is List ? math.max(1, (task.data as List).length) : 1;
    final double ms = elapsedMs / items;
    final _QueryCost cost = _entry(task);
    cost.averageMs = cost.samples == 0 ? ms : cost.averageMs * 0.8 + ms * 0.2;
    if (rows != null && !task.isWriteOp) cost.averageRows = cost.averageRows == null ? rows.toDouble() : cost.averageRows! * 0.8 + rows * 0.2;
    cost.samples++;
    cost.lastUsed = FluentClock.millis;
    _changed.add(cost.key);
    _evictOverflow();
    if (!task.isWriteOp && cost.samples >= minSamples) FluentTuner().onMeasured(cost.key, cost.averageMs);
    if (!task.isWriteOp && cost.samples >= minSamples && cost.averageMs >= slowReadMs && _hinted.add(cost.key)) {
      FluentAnalyzer().onSlowShape(task, cost.averageMs, cost.samples);
    }
  }

  /// Records a failed run of [task].
  void recordFailure(FluentTask task) {
    if (task.table.isEmpty || !_measures(task.dbName)) return;
    final _QueryCost cost = _entry(task)..failures += 1;
    cost.lastUsed = FluentClock.millis;
    _changed.add(cost.key);
  }

  /// Records that turning one row of [table] into a model took [microsPerRow] on the UI isolate (moving average).
  void recordMapping(String db, String table, double microsPerRow) {
    if (!_measures(db)) return;
    final _QueryCost cost = _costs['$db|$table|$_mappingAction|'] ??= _QueryCost(db, table, _mappingAction, '');
    cost.averageMs = cost.samples == 0 ? microsPerRow : cost.averageMs * 0.7 + microsPerRow * 0.3;
    cost.samples++;
    cost.lastUsed = FluentClock.millis;
    _changed.add(cost.key);
  }

  /// The measured cost (microseconds) of turning one row of [table] into a model, `null` before it was measured.
  double? mappingMicros(String db, String table) => _costs['$db|$table|$_mappingAction|']?.averageMs;

  /// The trusted average duration (ms) of [task]'s shape, or `null` before [minSamples] runs.
  double? averageMs(FluentTask task) {
    final _QueryCost? cost = _costs[task.costKey];
    return cost == null || cost.samples < minSamples ? null : cost.averageMs;
  }

  void _evictOverflow() {
    if (_costs.length <= capacity) return;
    final List<_QueryCost> byAge = _costs.values.toList()..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    byAge.take(_costs.length - capacity).forEach(_remove);
  }

  /// Loads the persisted shapes of [db] (rows of its stats table); those unused for longer than [retention] are
  /// dropped (and deleted on the next write).
  void load(String db, List<Map<String, Object?>> rows) {
    final int cutoff = FluentClock.now().subtract(retention).millisecondsSinceEpoch;
    for (final Map<String, Object?> r in rows) {
      final _QueryCost cost = _QueryCost(
        db,
        '${r['tbl']}',
        '${r['action']}',
        '${r['shape']}',
        averageMs: (r['avg_ms'] as num?)?.toDouble() ?? 0,
        averageRows: (r['avg_rows'] as num?)?.toDouble(),
        samples: (r['samples'] as int?) ?? 0,
        failures: (r['failures'] as int?) ?? 0,
        lastUsed: (r['last_used'] as int?) ?? 0,
      );
      if (cost.lastUsed < cutoff) {
        (_removed[db] ??= {}).add(cost.rowKey);
      } else {
        _costs[cost.key] = cost;
      }
    }
    _evictOverflow();
  }

  /// The changed shapes of [db] (rows to write) and its removed ones (keys to delete) since the last call.
  ({List<Map<String, Object?>> upserts, List<String> deletes}) takeChanges(String db) {
    final String prefix = '$db|';
    final List<String> keys = [for (final String key in _changed) if (key.startsWith(prefix)) key];
    _changed.removeAll(keys);
    return (upserts: [for (final String key in keys) ?_costs[key]?.row], deletes: (_removed.remove(db) ?? const <String>{}).toList());
  }

  /// Puts changes of [db] back after a failed write, so the next flush retries them.
  void restoreChanges(String db, ({List<Map<String, Object?>> upserts, List<String> deletes}) changes) {
    _changed.addAll([for (final Map<String, Object?> r in changes.upserts) '$db|${r['key']}']);
    (_removed[db] ??= {}).addAll(changes.deletes);
  }

  /// Forgets measurements of [table] of [db], of all tables of [db], or of everything (deleted on the next write).
  void forget({String? db, String? table}) {
    _costs.values.where((c) => (db == null || c.db == db) && (table == null || c.table == table)).toList().forEach(_remove);
  }

  /// Drops everything of [db] from memory without writing anything (its file is gone or is not written).
  void discard(String db) {
    _costs.removeWhere((_, c) => c.db == db);
    _changed.removeWhere((key) => key.startsWith('$db|'));
    _removed.remove(db);
  }

  /// The measured query shapes of [db] and / or [table] (all when `null`), slowest first.
  List<FluentQueryCost> costs({String? db, String? table}) {
    final List<_QueryCost> picked = _costs.values.where((c) => !c.isMapping && (db == null || c.db == db) && (table == null || c.table == table)).toList()
      ..sort((a, b) => b.averageMs.compareTo(a.averageMs));
    return [for (final _QueryCost c in picked) c.public];
  }

  /// The [count] slowest read shapes (trusted averages only).
  List<FluentQueryCost> slowest([int count = 5]) {
    final List<_QueryCost> reads = _costs.values.where((c) => c.samples >= minSamples && !c.isMapping && !_isWrite(c.action)).toList()
      ..sort((a, b) => b.averageMs.compareTo(a.averageMs));
    return [for (final _QueryCost c in reads.take(count)) c.public];
  }

  static bool _isWrite(String action) => _writeActionNames.contains(action);

  /// Names of the write actions (looked up per cost entry by [slowest] and the hints).
  static final Set<String> _writeActionNames = {for (final FluentDbAction a in FluentDbAction.values) if (a.isWriteOp) a.name};

  // ---------------------------------------------------------------------------
  // Hints and the optimization report
  // ---------------------------------------------------------------------------

  static final RegExp _filteredColumn = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*(=|<|>|<=|>=|IN\b|BETWEEN\b|IS\b)', caseSensitive: false); // no LIKE: a leading % cannot use an index

  /// Columns a shape filters on that no index starts with (the shape holds only the caller's condition).
  List<String> _unindexedColumns(_QueryCost cost) {
    final FluentProvider? provider = _providerOf(cost);
    if (provider == null) return const [];
    final Set<String> known = {for (final FluentDbColumn c in provider.getFullSchema) c.name};
    final Set<String> leading = {
      for (final FluentIndex index in provider.tableIndexes) index.columns.first,
      ...provider.keyColumnNames.take(1),
      for (final FluentDbColumn c in provider.getFullSchema)
        if (c.isUnique) c.name,
    };
    final String condition = cost.shape.split(' ORDER BY ').first;
    final List<String> columns = {
      for (final RegExpMatch m in _filteredColumn.allMatches(condition))
        if (known.contains(m.group(1))) m.group(1)!,
    }.toList();
    return columns.any(leading.contains) ? const [] : columns;
  }

  FluentProvider? _providerOf(_QueryCost cost) => FluentDbInternals.lookupByTable(cost.table, cost.db);

  /// Hints from the measured shapes (this run and earlier ones): indexes for slow filters, lighter relation loading,
  /// paging, batched saves. Same keys as the analyzer's live hints, so the report shows each once.
  List<FluentIssue> measuredHints() {
    final List<FluentIssue> hints = [];
    final List<_QueryCost> measured = _costs.values.where((c) => c.samples >= minSamples).toList()..sort((a, b) => (b.averageMs * b.samples).compareTo(a.averageMs * a.samples));
    for (final _QueryCost c in measured) {
      if (c.isMapping || _isWrite(c.action) || c.averageMs < FluentAnalyzer.slowReadMs) continue;
      final String model = _providerOf(c)?.modelType.toString() ?? c.table;
      final List<String> columns = _unindexedColumns(c);
      if (columns.isNotEmpty) {
        hints.add(
          FluentIssue(
            kind: FluentIssueKind.missingIndex,
            database: c.db,
            subject: columns.join(','),
            table: c.table,
            title: 'Add an index on ${c.table}(${columns.join(', ')})',
            details: '${c.action} with ${c.shape} takes ~${c.averageMs.round()} ms on average (${c.samples} runs); no index starts with ${columns.join(', ')}.',
            fix: 'Add a FluentIndex on these columns to the indexes of the model (equality columns first, then range or order); it is created on the next start.',
            code: FluentAnalyzer.indexExample(model, columns),
          ),
        );
      } else if (c.shape.contains('depth=') && !c.shape.contains('depth=1')) {
        hints.add(
          FluentIssue(
            kind: FluentIssueKind.relations,
            database: c.db,
            table: c.table,
            title: 'Load fewer relation levels of "${c.table}"',
            details: '${c.action} loads relations several levels deep (${c.shape}) and takes ~${c.averageMs.round()} ms on average.',
            fix: 'Load fewer levels (maxDepth: 1 or FluentLoad.none) and mark big relations lazy, loading them only when needed.',
            code: 'await FluentDb.find<$model>(maxDepth: 1); // or relations: FluentLoad.none, or mark big relations lazy: FluentRelation.many(..., lazy: true)',
          ),
        );
      } else if (c.action == FluentDbAction.find.name && !c.shape.contains('LIMIT')) {
        hints.add(
          FluentIssue(
            kind: FluentIssueKind.bigRead,
            database: c.db,
            table: c.table,
            title: 'Read "${c.table}" in pages',
            details: 'Reading all matching rows at once takes ~${c.averageMs.round()} ms (${c.samples} runs).',
            fix: 'Read a page at a time with findPage (orderBy + limit) or pass a limit.',
            code: "FluentPage<$model> page = await FluentDb.findPage<$model>(orderBy: 'id', limit: 50, after: previous?.next);",
          ),
        );
      }
    }
    for (final _QueryCost c in measured) {
      if (c.action == FluentDbAction.save.name && c.samples >= 200 && c.averageMs >= 2) {
        final String model = _providerOf(c)?.modelType.toString() ?? c.table;
        hints.add(
          FluentIssue(
            kind: FluentIssueKind.saveLoop,
            database: c.db,
            table: c.table,
            title: 'Save "${c.table}" rows with saveAll instead of one by one',
            details: '${c.samples} single saves were measured (~${c.averageMs.toStringAsFixed(1)} ms per row); saveAll writes many rows in one transaction.',
            fix: 'Collect the rows and save them with one saveAll call, or wrap the loop in FluentDb.transaction.',
            code: 'await FluentDb.saveAll<$model>(items);\n// or: await FluentDb.transaction(() async { for (final i in items) await FluentDb.save<$model>(i); });',
          ),
        );
      }
    }
    return hints;
  }
}
