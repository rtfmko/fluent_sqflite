// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// An index the tuner created and still checks: the shape it serves and its average before.
class _AutoIndex {
  _AutoIndex(this.name, this.db, this.table, this.columns, this.shapeKey, this.beforeMs) : since = FluentClock.now();

  /// When the index was proposed: a shape that is not measured again within [FluentTuner.checkFor] stops waiting.
  final DateTime since;

  final String name;
  final String db;
  final String table;
  final List<String> columns;
  final String shapeKey;
  final double beforeMs;
}

/// The tuner: the "act" part of the diagnostics ([FluentTuning], per database). It improves what is safe to improve
/// while the app runs, reports every change of a setting as [FluentIssueKind.tuned], checks the effect and takes a
/// change back ([FluentIssueKind.tuningReverted]) when it does not help or fails — the app keeps working either way.
///
/// Levers: automatic indexes for slow reads (created through the queue, so never inside a transaction; checked after
/// new measurements and dropped when they do not help), the read pool size, freeing SQLite memory on memory pressure,
/// maintenance when the app goes to the background, write-ahead log checkpoints, and the frame budget of sliced
/// mapping. Nothing is changed that only works for a new database file.
class FluentTuner with WidgetsBindingObserver {
  static final FluentTuner _instance = FluentTuner._internal();

  /// The shared tuner.
  factory FluentTuner() => _instance;

  FluentTuner._internal();

  /// Prefix of the indexes the tuner creates (`fluent_auto_<table>_<columns>`); schema sync leaves them alone.
  static const String autoIndexPrefix = 'fluent_auto_';

  /// A created index must make its read at least this much faster (fraction of the time before), or it is dropped.
  static const double indexGain = 0.2;

  /// Page cache (KiB) while the system reports memory pressure.
  static const int lowMemoryCacheKib = 512;

  /// How long the small page cache stays after memory pressure, unless the app comes back earlier.
  static const Duration lowMemoryFor = Duration(minutes: 2);

  /// Writes of a database after which an idle checkpoint merges the write-ahead log.
  static const int checkpointEveryWrites = 500;

  /// How long an automatic index waits for its read to be measured again; after that it is kept without a verdict
  /// (the read became rare), so the check list never grows without end.
  static const Duration checkFor = Duration(hours: 1);

  final Map<String, _AutoIndex> _checking = {};
  final Set<String> _failedShapes = {};

  /// Read shapes an automatic index (by name) serves, and the ones it was measured to help: one index may serve
  /// several shapes, so it is dropped only when it helps none of them.
  final Map<String, Set<String>> _servedShapes = {};
  final Map<String, Set<String>> _helpedShapes = {};
  final Map<String, int> _autoIndexCount = {};
  final Map<String, int> _writes = {};
  final Set<String> _lowMemory = {};

  /// Databases whose page cache restore waits until they are idle (see [onIdle]).
  final Set<String> _restoreWhenIdle = {};
  final Set<String> _disabled = {};
  Timer? _memoryTimer;
  bool _observing = false;
  bool _inBackground = false;
  Duration? _reportedBudget;

  /// The tuning of database [db].
  FluentTuning _tuning(String? db) => FluentEngine().diagnosticsOf(db).tuning;

  /// Whether lever [lever] is on for [db] and did not fail in this run.
  bool _on(String db, String lever, bool Function(FluentTuning t) pick) => pick(_tuning(db)) && !_disabled.contains('$db|$lever');

  /// Turns lever [lever] off for [db] for the rest of the run after a failure, and reports the fallback.
  void _giveUp(String db, String lever, String what, Object error) {
    _disabled.add('$db|$lever');
    FluentLog.issue(
      FluentIssueKind.tuningReverted,
      '$what failed for "$db"; the tuner leaves "$lever" alone for this run.',
      database: db,
      subject: lever,
      error: error,
      hint: 'Nothing else changes. If it keeps failing on this device, turn it off: FluentTuning.full.copyWith($lever: false).',
    );
  }

  // ---------------------------------------------------------------------------
  // Start / stop
  // ---------------------------------------------------------------------------

  /// Starts observing the app (lifecycle, memory) when a database of [dbs] uses those levers; lists the indexes it
  /// created in earlier runs.
  Future<void> start(Map<String, Database> dbs) async {
    for (final MapEntry<String, Database> e in dbs.entries) {
      if (!_tuning(e.key).indexes || !e.value.isOpen) continue;
      try {
        final List<Map<String, Object?>> rows = await e.value.rawQuery(r"SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' AND name LIKE 'fluent\_auto\_%' ESCAPE '\'");
        _autoIndexCount[e.key] = rows.length;
        for (final Map<String, Object?> r in rows) {
          FluentLog.debug('Automatic index "${r['name']}" on "${r['tbl_name']}" (created in an earlier run)', tag: 'FluentTuner:index');
        }
      } catch (_) {
        // Only the count of the cap is unknown; it starts at 0.
      }
    }
    final bool observe = dbs.keys.any((db) {
      final FluentTuning t = _tuning(db);
      return t.memory || t.background || t.checkpoints;
    });
    if (observe && !_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {
        FluentLog.debug('No Flutter binding: app lifecycle and memory pressure are not observed', tag: 'FluentTuner');
      }
    }
  }

  /// Stops observing and forgets this run's state (databases closed).
  void stop() {
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    _observing = false;
    _memoryTimer?.cancel();
    _memoryTimer = null;
    _checking.clear();
    _failedShapes.clear();
    _servedShapes.clear();
    _helpedShapes.clear();
    _autoIndexCount.clear();
    _writes.clear();
    _lowMemory.clear();
    _restoreWhenIdle.clear();
    _disabled.clear();
    _inBackground = false;
    _reportedBudget = null;
  }

  // ---------------------------------------------------------------------------
  // Read pool and frame budget (decided, not stored)
  // ---------------------------------------------------------------------------

  /// The read pool size of [group] when neither the group nor the global settings set one: 2, or with
  /// `FluentTuning.readConnections` half the device's cores (1–4).
  static int readConnections(FluentGroup group, FluentConfig config) {
    final FluentTuning tuning = (group.config.diagnostics ?? config.diagnostics).tuning;
    if (!tuning.readConnections) return 2;
    final int cores = Platform.numberOfProcessors;
    final int n = (cores ~/ 2).clamp(1, 4);
    if (n != 2) {
      FluentLog.issue(
        FluentIssueKind.tuned,
        'Read pool of "${group.dbKey.dbName}": $n connections for $cores cores (default 2).',
        database: group.dbKey.dbName,
        subject: 'readConnections',
        hint: 'To fix the size yourself set FluentDbConfig(readConnections: n); FluentTuning(readConnections: false) turns this off.',
      );
    }
    return n;
  }

  /// Replaces the display's refresh rate (Hz) read by [frameBudget] (tests: the test binding has no way to change the
  /// platform dispatcher this code reads).
  @visibleForTesting
  static double? Function()? refreshRateProbe;

  /// The frame budget of sliced mapping: [config]'s, scaled to the display's refresh rate with
  /// `FluentTuning.frameBudget` (4 ms at 60 Hz → 2 ms at 120 Hz).
  Duration frameBudget(FluentConfig config) {
    if (!config.diagnostics.tuning.frameBudget) return config.frameBudget;
    double rate = 60;
    try {
      final double? probed = refreshRateProbe?.call();
      final Iterable<ui.Display> displays = ui.PlatformDispatcher.instance.displays;
      if (probed != null) {
        rate = probed;
      } else if (displays.isNotEmpty && displays.first.refreshRate > 0) {
        rate = displays.first.refreshRate;
      }
    } catch (_) {}
    final Duration budget = Duration(microseconds: math.max(1000, (config.frameBudget.inMicroseconds * 60 / rate).round()));
    if (budget != config.frameBudget && budget != _reportedBudget) {
      _reportedBudget = budget;
      FluentLog.issue(
        FluentIssueKind.tuned,
        'Big lists are mapped in slices of ${budget.inMicroseconds / 1000} ms for a ${rate.round()} Hz display.',
        subject: 'frameBudget',
        hint: 'Set FluentConfig(frameBudget: ...) and FluentTuning(frameBudget: false) to choose it yourself.',
      );
    }
    return budget;
  }

  // ---------------------------------------------------------------------------
  // Automatic indexes
  // ---------------------------------------------------------------------------

  /// The analyzer found that an index on [columns] would serve the slow read [task] of [provider].
  void proposeIndex(FluentTask task, FluentProvider provider, List<String> columns) {
    final String db = task.dbName;
    if (columns.isEmpty || !_on(db, 'indexes', (t) => t.indexes)) return;
    final String shapeKey = task.costKey;
    final DateTime now = FluentClock.now();
    _checking.removeWhere((_, i) => now.difference(i.since) > checkFor);
    if (_failedShapes.contains(shapeKey) || _checking.containsKey(shapeKey)) return;
    final String name = '$autoIndexPrefix${task.table}_${columns.join('_')}';
    final Set<String>? served = _servedShapes['$db|$name'];
    if (served != null) {
      // The index exists for another read of the same columns: this read is served too, nothing is created or counted.
      served.add(shapeKey);
      return;
    }
    if ((_autoIndexCount[db] ?? 0) >= _tuning(db).maxIndexes) {
      FluentLog.debug('No automatic index for "${task.table}": the cap of ${_tuning(db).maxIndexes} is reached', tag: 'FluentTuner:index');
      return;
    }
    final double before = FluentTableStatsTracker().averageMs(task) ?? FluentAnalyzer.slowReadMs.toDouble();
    final _AutoIndex index = _AutoIndex(name, db, task.table, columns, shapeKey, before);
    _checking[shapeKey] = index;
    _servedShapes['$db|$name'] = {shapeKey};
    _autoIndexCount[db] = (_autoIndexCount[db] ?? 0) + 1;
    unawaited(_create(index, provider));
  }

  Future<void> _create(_AutoIndex index, FluentProvider provider) async {
    final String sql = 'CREATE INDEX IF NOT EXISTS ${index.name.quotedIdentifier} ON ${index.table.quotedIdentifier} (${index.columns.map((c) => c.quotedIdentifier).join(', ')})';
    try {
      // Through the queue: after the writes before it, never inside a transaction.
      await provider.execute(sql, policy: ExecutionPolicy.background);
      FluentTableStatsTracker().forgetKey(index.shapeKey); // measure again with the index
      FluentLog.issue(
        FluentIssueKind.tuned,
        'Created index ${index.table}(${index.columns.join(', ')}) for a read that took ~${index.beforeMs.round()} ms; it is dropped again if it does not help.',
        database: index.db,
        table: index.table,
        subject: index.columns.join(','),
        hint: 'Declare it in the model to keep it for good (then the tuner leaves it alone), or turn automatic indexes off: '
            'FluentTuning.full.copyWith(indexes: false).',
        code: FluentAnalyzer.indexExample(provider.modelType.toString(), index.columns),
      );
    } catch (e) {
      _checking.remove(index.shapeKey);
      _servedShapes.remove('${index.db}|${index.name}');
      _failedShapes.add(index.shapeKey);
      _autoIndexCount[index.db] = math.max(0, (_autoIndexCount[index.db] ?? 1) - 1);
      FluentLog.issue(
        FluentIssueKind.tuningReverted,
        'The automatic index ${index.table}(${index.columns.join(', ')}) could not be created; the table works as before.',
        database: index.db,
        table: index.table,
        subject: index.columns.join(','),
        error: e,
        hint: 'Usually a locked or read-only database. The tuner does not retry it in this run.',
      );
    }
  }

  /// A read shape got a new trusted average (`FluentTableStatsTracker`): checks an index created for it.
  void onMeasured(String shapeKey, double averageMs) {
    final _AutoIndex? index = _checking.remove(shapeKey);
    if (index == null) return;
    final String id = '${index.db}|${index.name}';
    if (averageMs <= index.beforeMs * (1 - indexGain)) {
      (_helpedShapes[id] ??= {}).add(shapeKey);
      FluentLog.debug('Automatic index "${index.name}" helps: ~${index.beforeMs.round()} → ~${averageMs.round()} ms', tag: 'FluentTuner:index');
      return;
    }
    _failedShapes.add(shapeKey);
    // Another read of the same columns it helps keeps it.
    if (_helpedShapes[id]?.isNotEmpty ?? false) return;
    unawaited(_drop(index, averageMs));
  }

  Future<void> _drop(_AutoIndex index, double afterMs) async {
    final FluentProvider? provider = FluentDbInternals.lookupByTable(index.table, index.db);
    if (provider == null) {
      // The database was closed meanwhile: nothing dropped, the next run decides again.
      FluentLog.debug('Automatic index "${index.name}" not dropped: "${index.db}" is closed', tag: 'FluentTuner:index');
      return;
    }
    try {
      await provider.execute('DROP INDEX IF EXISTS ${index.name.quotedIdentifier}', policy: ExecutionPolicy.background);
      _servedShapes.remove('${index.db}|${index.name}');
      _autoIndexCount[index.db] = math.max(0, (_autoIndexCount[index.db] ?? 1) - 1);
      FluentLog.issue(
        FluentIssueKind.tuningReverted,
        'Dropped the automatic index ${index.table}(${index.columns.join(', ')}): the read still takes ~${afterMs.round()} ms (before ~${index.beforeMs.round()} ms).',
        database: index.db,
        table: index.table,
        subject: index.columns.join(','),
        hint: 'The read is slow for another reason (big results, relations): see FluentDb.report() for other hints.',
      );
    } catch (e) {
      FluentLog.issue(
        FluentIssueKind.tuningReverted,
        'The automatic index "${index.name}" could not be dropped; it stays (it costs a little write time).',
        database: index.db,
        table: index.table,
        error: e,
        hint: 'Drop it yourself with execute(\'DROP INDEX "${index.name}"\') when the database is not busy.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Checkpoints, memory, background
  // ---------------------------------------------------------------------------

  /// A write of [db] finished: after [checkpointEveryWrites] writes, merge the write-ahead log while idle.
  void onWrite(String db) {
    if (!_on(db, 'checkpoints', (t) => t.checkpoints)) return;
    final int n = (_writes[db] ?? 0) + 1;
    _writes[db] = n;
    if (n < checkpointEveryWrites || !FluentEngine()._isIdle(db)) return;
    _writes[db] = 0;
    unawaited(_pragma(db, 'wal_checkpoint(PASSIVE)', 'checkpoints', 'A checkpoint'));
  }

  /// Runs `PRAGMA [pragma]` on the main connection of [db] (and its readers with [readers]) while it is idle.
  ///
  /// Outside the queue on purpose (it only changes settings or checkpoints the log): a call that starts meanwhile is
  /// serialized with it by sqflite on the same connection, and an open transaction makes it wait, never the reverse.
  Future<bool> _pragma(String db, String pragma, String lever, String what, {bool readers = false}) async {
    final FluentEngine engine = FluentEngine();
    final Database? main = engine._databases[db];
    if (main == null || !main.isOpen || !engine._isIdle(db)) return false;
    try {
      await main.rawQuery('PRAGMA $pragma');
      if (readers) {
        for (final Database r in engine._readers[db] ?? const <Database>[]) {
          if (r.isOpen) await r.rawQuery('PRAGMA $pragma');
        }
      }
      FluentLog.debug('PRAGMA $pragma on "$db"', tag: 'FluentTuner:$lever');
      return true;
    } catch (e) {
      _giveUp(db, lever, what, e);
      return false;
    }
  }

  /// Whether periodic maintenance of [db] waits until the app is in the foreground again (`FluentTuning.background`).
  bool defersMaintenance(String db) => _inBackground && _on(db, 'background', (t) => t.background);

  /// Forwards the app's lifecycle to [handleLifecycle].
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => unawaited(handleLifecycle(state));

  /// Forwards memory pressure to [handleMemoryPressure].
  @override
  void didHaveMemoryPressure() => unawaited(handleMemoryPressure());

  /// The app changed its lifecycle [state] (from the binding, or tests).
  @visibleForTesting
  Future<void> handleLifecycle(AppLifecycleState state) async {
    final bool background = state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached;
    final bool changed = background != _inBackground;
    _inBackground = background;
    if (!background) {
      if (state == AppLifecycleState.resumed) await _restoreMemory();
      return;
    }
    if (!changed) return;
    final FluentEngine engine = FluentEngine();
    if (engine._databases.keys.any((db) => _on(db, 'background', (t) => t.background))) await engine._flushStats(onlyIdle: true);
    for (final String db in engine._databases.keys.toList()) {
      if (_on(db, 'background', (t) => t.background)) await _pragma(db, 'optimize', 'background', 'Maintenance in the background');
      if (_on(db, 'checkpoints', (t) => t.checkpoints)) await _pragma(db, 'wal_checkpoint(TRUNCATE)', 'checkpoints', 'A checkpoint');
    }
  }

  /// The system reports memory pressure (from the binding, or tests): free SQLite's memory until it is over.
  @visibleForTesting
  Future<void> handleMemoryPressure() async {
    final FluentEngine engine = FluentEngine();
    for (final String db in engine._databases.keys.toList()) {
      if (!_on(db, 'memory', (t) => t.memory)) continue;
      final bool freed = await _pragma(db, 'shrink_memory', 'memory', 'Freeing memory', readers: true) && await _pragma(db, 'cache_size = -$lowMemoryCacheKib', 'memory', 'Shrinking the page cache', readers: true);
      if (!freed || !_lowMemory.add(db)) continue;
      FluentLog.issue(
        FluentIssueKind.tuned,
        'Memory pressure: freed SQLite memory of "$db"; its page cache is $lowMemoryCacheKib KiB until the app is back or for ${lowMemoryFor.inMinutes} min.',
        database: db,
        subject: 'memory',
        hint: 'Reads may be a little slower meanwhile. FluentTuning(memory: false) turns this off.',
      );
    }
    if (_lowMemory.isNotEmpty) {
      _memoryTimer?.cancel();
      _memoryTimer = Timer(lowMemoryFor, () => unawaited(_restoreMemory()));
    }
  }

  /// Puts the page cache of the databases under memory pressure back. A database busy right now keeps the small
  /// cache until it is idle ([onIdle] tries again), so it is never left at [lowMemoryCacheKib] for good.
  Future<void> _restoreMemory() async {
    _memoryTimer?.cancel();
    _memoryTimer = null;
    for (final String db in _lowMemory.toList()) {
      if (!_on(db, 'memory', (t) => t.memory)) {
        _lowMemory.remove(db); // the lever failed: nothing more to do
        continue;
      }
      if (!FluentEngine()._isIdle(db)) {
        _restoreWhenIdle.add(db);
        continue;
      }
      _restoreWhenIdle.remove(db);
      final SQLiteCacheSize size = FluentEngine().dbConfig(db)?.cacheSize ?? SQLiteCacheSize.defaultSize;
      if (await _pragma(db, 'cache_size = ${size.rawValue}', 'memory', 'Restoring the page cache', readers: true)) {
        _lowMemory.remove(db);
        FluentLog.issue(FluentIssueKind.tuned, 'The page cache of "$db" is back to $size.', database: db, subject: 'memory', hint: 'Nothing to do.');
      } else if (_lowMemory.contains(db) && _on(db, 'memory', (t) => t.memory)) {
        _restoreWhenIdle.add(db); // became busy meanwhile
      }
    }
  }

  /// Database [db] has nothing queued or running (called by the engine after a task): finishes a page cache restore
  /// that had to wait.
  void onIdle(String db) {
    if (_restoreWhenIdle.isEmpty || !_restoreWhenIdle.contains(db)) return;
    _restoreWhenIdle.remove(db);
    unawaited(_restoreMemory());
  }
}
