// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// A singleton tracker responsible for aggregating and caching database
/// performance metrics and schema metadata in-memory.
///
/// This tracker serves as the central hub for the `SystemStatsProvider`,
/// collecting telemetry from the worker isolate and maintaining a
/// synchronized view of table performance across the entire database group.
class FluentTableStatsTracker {
  /// Internal singleton instance.
  static final FluentTableStatsTracker _instance = FluentTableStatsTracker._internal();

  /// Returns the singleton instance of the tracker.
  factory FluentTableStatsTracker() => _instance;

  FluentTableStatsTracker._internal();

  /// Local cache of table schema definitions to avoid repeated disk introspection.
  final Map<String, List<Map<String, Object?>>> _schemaCache = {};

  /// In-memory store of performance snapshots, keyed by database and table name.
  final Map<String, TableStats> _statsMap = {};

  /// Exposes the current performance snapshots for all tracked tables.
  List<TableStats> get getAllStats => _statsMap.values.toList();

  /// Flag indicating if the in-memory stats have changed and require a disk flush.
  bool _isDirty = false;

  /// Returns true if there are pending stats updates that haven't been persisted yet.
  bool get isDirty => _isDirty;

  /// Creates a unique composite key for indexing [TableStats] or schema data.
  String _makeKey(String dbName, String tableName) => '$dbName:$tableName';

  /// Helper to generate a key directly from a [FluentTask] for streamlined lookups.
  String _makeKeyFromTask(FluentTask task) => '${task.dbName}:${task.table}';

  /// Records the performance metrics and success state of a database operation,
  /// updating the internal statistics registry and flagging the tracker as 'dirty'.
  ///
  /// This method implements a **moving average** calculation for read and write
  /// performance, ensuring that recent latency trends are prioritized over
  /// historical data without requiring the storage of every single execution time.
  void registerCascadeSuccess({required String dbName, required String tableName, required int elapsedMs, required bool isWrite, required int affectedRows, bool wasExecuted = false}) {
    final String key = _makeKey(dbName, tableName);
    final TableStats stats = _statsMap.putIfAbsent(key, () => TableStats(dbName: dbName, tableName: tableName));

    // Update session/total counters if the operation actually performed work
    if (wasExecuted) {
      if (isWrite) {
        stats.totalWrites++;
        stats.writesSession++;
        if (affectedRows > 0) {
          stats.rowCount = math.max(stats.rowCount, affectedRows);
        }
      } else {
        stats.totalReads++;
        stats.readsSession++;

        if (affectedRows > 0) {
          stats.sessionPayload += affectedRows;
        }
      }
      _isDirty = true;
    }

    // Performance metrics update (skipping if elapsedMs is invalid/zero)
    if (elapsedMs <= 0) return;

    if (elapsedMs > stats.maxTimeMs) stats.maxTimeMs = elapsedMs;
    if (stats.minTimeMs == 0 || elapsedMs < stats.minTimeMs) {
      stats.minTimeMs = elapsedMs;
    }

    // Exponential moving average: 70% historical, 30% current.
    // This allows the stats to adapt to evolving performance characteristics.
    if (isWrite) {
      stats.avgWriteTimeMs = stats.avgWriteTimeMs == 0.0 ? elapsedMs.toDouble() : (stats.avgWriteTimeMs * 0.7) + (elapsedMs * 0.3);
    } else {
      stats.avgReadTimeMs = stats.avgReadTimeMs == 0.0 ? elapsedMs.toDouble() : (stats.avgReadTimeMs * 0.7) + (elapsedMs * 0.3);
    }

    _isDirty = true;

    FluentLog.debug(
      'Stats updated for $tableName: ${isWrite ? 'Write' : 'Read'} | Time: ${elapsedMs}ms | Avg: ${isWrite ? stats.avgWriteTimeMs.toStringAsFixed(2) : stats.avgReadTimeMs.toStringAsFixed(2)}ms',
      tag: 'FluentTableStats',
      context: {'db': dbName, 'table': tableName, 'totalWrites': stats.totalWrites, 'totalReads': stats.totalReads},
    );
  }

  /// Registers a successful [FluentTask] execution, updating the table's telemetry
  /// metrics such as latency averages, throughput counts, and row-count state.
  ///
  /// This method serves as the primary hook for the [FluentEngine] to
  /// report task completion, facilitating real-time performance monitoring.
  void registerSuccess({required FluentTask task, required int elapsedMs, required bool isWrite, int? rows, int? delta}) {
    if (task.isSystem) return;
    final String key = _makeKeyFromTask(task);
    final TableStats stats = _statsMap.putIfAbsent(key, () => TableStats(task: task));

    // Track latency bounds
    if (elapsedMs > stats.maxTimeMs) stats.maxTimeMs = elapsedMs;
    if (stats.minTimeMs == 0 || elapsedMs < stats.minTimeMs) stats.minTimeMs = elapsedMs;

    // Update throughput and calculate Exponential Moving Average (EMA)
    // Smoothing factor of 0.3 allows the system to adapt to new performance baselines
    final double targetTime = elapsedMs == 0 ? 0.1 : elapsedMs.toDouble();

    if (isWrite) {
      stats.totalWrites++;
      stats.writesSession++;
      stats.avgWriteTimeMs = stats.totalWrites == 1 ? targetTime : (stats.avgWriteTimeMs * 0.7) + (targetTime * 0.3);
    } else {
      stats.totalReads++;
      stats.readsSession++;
      stats.avgReadTimeMs = stats.totalReads == 1 ? targetTime : (stats.avgReadTimeMs * 0.7) + (targetTime * 0.3);
    }

    // Maintain row count state via absolute sets (rows) or relative changes (delta)
    if (rows != null && rows > 0) {
      stats.rowCount = math.max(stats.rowCount, rows);
    } else if (delta != null) {
      stats.rowCount = (stats.rowCount + delta).clamp(0, double.maxFinite.toInt());
    }

    _isDirty = true;

    FluentLog.debug(
      'Task ${task.action} completed on ${task.table}',
      tag: 'FluentTableStats:register',
      context: {'elapsed': '${elapsedMs}ms', 'isWrite': isWrite, 'new_avg': isWrite ? stats.avgWriteTimeMs : stats.avgReadTimeMs, 'current_row_count': stats.rowCount},
    );
  }

  /// Records a failed [FluentTask] execution, incrementing the error counter
  /// for the associated table and marking the tracker as 'dirty'.
  ///
  /// Tracking failures is critical for identifying unstable database operations,
  /// such as schema mismatches, transaction rollbacks, or constraint violations.
  void registerFailure(FluentTask task) {
    final String key = _makeKeyFromTask(task);
    final TableStats stats = _statsMap.putIfAbsent(key, () => TableStats(task: task));

    stats.failedQueries++;
    _isDirty = true;

    FluentLog.warning(
      'Task failed on table: ${task.table}',
      tag: 'FluentTableStats:failure',
      context: {'db': task.dbName, 'action': task.action.toString(), 'total_failures': stats.failedQueries},
      hint:
          'Check if this task is causing frequent constraint violations or if '
          'the schema is out of sync with the data model.',
    );
  }

  /// Hydrates the in-memory statistics registry with previously saved data from disk.
  ///
  /// This method is intended to be called during application startup (e.g., in
  /// [FluentEngine.init]) to restore telemetry state across app sessions.
  void importFromDisk(List<TableStats> loadedStats) {
    for (final TableStats stats in loadedStats) {
      _statsMap[_makeKey(stats.dbName, stats.tableName)] = stats;
    }
    _isDirty = false;
    FluentLog.info('Stats tracker hydrated with ${loadedStats.length} entries.', tag: 'FluentTableStats:import');
  }

  /// Exports only the pending (dirty) statistics to a serializable JSON format.
  ///
  /// Used primarily by the background worker when flushing data to the
  /// `__fluent_table_stats` internal table. If the tracker is clean, this
  /// returns an empty list to prevent unnecessary database write cycles.
  List<Map<String, dynamic>> exportDirtyData() {
    if (!_isDirty) {
      FluentLog.debug('Export skipped: no dirty data to persist.', tag: 'FluentTableStats:export');
      return [];
    }
    FluentLog.debug('Exporting ${_statsMap.length} entries for persistence.', tag: 'FluentTableStats:export');
    return _statsMap.values.map((s) => s.buildJson()).toList();
  }

  /// Explicitly resets the dirty flag after a successful disk commit.
  ///
  /// This should be called immediately after the [SystemStatsProvider] finishes
  /// its batch save operation to prevent redundant writes.
  void clearDirtyFlag() {
    _isDirty = false;
    FluentLog.debug('Dirty flag cleared.', tag: 'FluentTableStats:cleanup');
  }

  /// Generates a formatted ASCII diagnostic report for a database table.
  ///
  /// This method performs an on-demand reconciliation of current [TableStats]
  /// and live schema metadata. It leverages the internal schema cache
  /// where possible, falling back to a system task request if the schema
  /// is not already held in memory.
  ///
  /// The report is ideal for console debugging or for attaching to
  /// remote crash logs to provide immediate context on table health.
  Future<String> dumpReport(String dbName, String tableName) async {
    FluentLog.info('Generating diagnostic dump for $tableName...', tag: 'FluentTableStats:report');

    final StringBuffer buffer = StringBuffer();
    const int lineWidth = 70;
    final String cacheKey = '$dbName:$tableName';
    final TableStats? stats = _statsMap[cacheKey];

    buffer.writeln('\n┌${'─' * (lineWidth - 2)}┐');
    buffer.writeln('│ 📊 TELEMETRY & DIAGNOSTICS REPORT: ${tableName.toUpperCase().padRight(31)} │');
    buffer.writeln('├${'─' * (lineWidth - 2)}┤');

    buffer.writeln('│ 📈 LIVE PERFORMANCE METRICS:');
    if (stats != null) {
      buffer.writeln('│   • Rows count (Disk):   ${stats.rowCount.toString().padRight(42)} │');
      buffer.writeln('│   • Session Payload:     ${stats.sessionPayload.toString().padRight(42)} │');
      buffer.writeln('│   • Table Complexity:    ${stats.complexity.toString().split('.').last.toUpperCase().padRight(42)} │');
      buffer.writeln('│   • Active Relations:    ${stats.relationsCount.toString().padRight(42)} │');
      buffer.writeln('│   • Avg Read Speed:      ${'${stats.avgReadTimeMs.toStringAsFixed(2)} ms'.padRight(42)} │');
      buffer.writeln('│   • Avg Write Speed:     ${'${stats.avgWriteTimeMs.toStringAsFixed(2)} ms'.padRight(42)} │');
    } else {
      buffer.writeln('│   [No active performance telemetry recorded for this session]      │');
    }

    buffer.writeln('├${'─' * (lineWidth - 2)}┤');

    buffer.writeln('│ 📋 PHYSICAL TABLE STRUCTURE (PRAGMA):');

    List<Map<String, Object?>>? columns = _schemaCache[cacheKey];
    bool isFromCache = true;

    if (columns == null) {
      isFromCache = false;
      try {
        FluentLog.debug('Fetching schema for $tableName via system task...', tag: 'FluentTableStats:report');
        final dynamic result = await FluentEngine()._executeSystemTask(FluentTask(dbName: dbName, table: tableName, isSystem: true, action: FluentDbAction.readSchema));

        if (result is List) {
          columns = result.cast<Map<String, Object?>>();
          if (columns.isNotEmpty) {
            _schemaCache[cacheKey] = columns;
          }
        }
      } catch (e, s) {
        FluentLog.error('Failed to retrieve schema for $tableName', e, s, tag: 'FluentTableStats:report');
        buffer.writeln('│   ❌ Failed to query database schema: ${e.toString().padRight(31)} │');
      }
    }

    if (columns != null && columns.isNotEmpty) {
      final String sourceInfo = isFromCache ? '[CACHE_HIT]' : '[QUEUE_FETCH]';
      buffer.writeln('│   Source: ${sourceInfo.padRight(57)} │');
      buffer.writeln('│   ┌─────┬────────────────┬────────────┬─────┬──────────┐           │');
      buffer.writeln('│   │ CID │ NAME           │ TYPE       │ PK  │ NOT NULL │           │');
      buffer.writeln('│   ├─────┼────────────────┼────────────┼─────┼──────────┤           │');

      for (final Map<String, Object?> col in columns) {
        final String cid = col['cid'].toString().padRight(3);
        final String name = col['name'].toString().padRight(14);
        final String type = col['type'].toString().padRight(10);
        final String pk = col['pk'] == 1 ? '[X]' : '[ ]';
        final String nn = col['notnull'] == 1 ? '[X]' : '[ ]';
        buffer.writeln('│   │ $cid │ $name │ $type │ $pk │   $nn    │           │');
      }
      buffer.writeln('│   └─────┴────────────────┴────────────┴─────┴──────────┘           │');
    } else if (columns?.isEmpty ?? true) {
      buffer.writeln('│   ⚠️ Table does not exist or schema could not be resolved.        │');
    }

    buffer.writeln('└${'─' * (lineWidth - 2)}┘\n');
    FluentLog.debug('Diagnostic report generated for $tableName.', tag: 'FluentTableStats:report');
    return buffer.toString();
  }

  /// Prints a comprehensive, human-readable summary of all accumulated
  /// database table statistics to the console.
  ///
  /// This method iterates over the `_statsMap` and generates a formatted
  /// ASCII table, complete with color-coded complexity badges for quick
  /// assessment of performance health across the entire database schema.
  void printStatsTable() {
    FluentLog.debug('Rendering console dashboard for ${_statsMap.length} tables.', tag: 'FluentTableStats:ui', linesBefore: 1);

    if (_statsMap.isEmpty) {
      final StringBuffer buffer = StringBuffer()
        ..writeln('┌──────────────────────────────────────────────────────────────┐')
        ..writeln('│            No database stats accumulated yet.                │')
        ..writeln('└──────────────────────────────────────────────────────────────┘');
      FluentLog.info(buffer.toString(), tag: 'FluentTableStats:ui', linesBefore: 1);
      return;
    }

    final buffer = StringBuffer()
      ..writeln('┌─────────────────┬─────────────┬─────────────┬─────────────┬─────────────┬─────────────────┬──────────────────────┐')
      ..writeln('│ Table (DB)      │ Row Count   │ Payload (S) │ Active (S)  │ Avg Read    │ Avg Write       │ Weight (Complexity)  │')
      ..writeln('├─────────────────┼─────────────┼─────────────┼─────────────┼─────────────┼─────────────────┼──────────────────────┤');

    _statsMap.forEach((_, s) {
      final String displayTitle = '${s.tableName} (${s.dbName})';
      final String tableInfo = displayTitle.length > 15 ? '${displayTitle.substring(0, 12)}...' : displayTitle.padRight(15);

      final String rows = s.rowCount.toString().padLeft(11);
      final String payload = s.sessionPayload.toString().padLeft(11);
      final String active = 'R:${s.readsSession}/W:${s.writesSession}'.padLeft(11);
      final String avgRead = '${s.avgReadTimeMs.toStringAsFixed(1)} ms'.padLeft(11);
      final String avgWrite = '${s.avgWriteTimeMs.toStringAsFixed(1)} ms'.padLeft(15);

      final String complexityName = s.complexity.name.toUpperCase();
      final String levelBadge = switch (s.complexity) {
        TableComplexity.low => '🟢 $complexityName',
        TableComplexity.medium => '🟡 $complexityName',
        TableComplexity.high => '🟠 $complexityName',
        TableComplexity.extreme => '🔴 $complexityName 🔥',
      }.padRight(20);

      buffer.writeln('│ $tableInfo │ $rows │ $payload │ $active │ $avgRead │ $avgWrite │ $levelBadge │');
    });

    buffer.write('└─────────────────┴─────────────┴─────────────┴─────────────┴─────────────┴─────────────────┴──────────────────────┘');

    FluentLog.info(buffer.toString(), tag: 'FluentTableStats:ui', linesBefore: 1);
  }
}
