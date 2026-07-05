// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// A singleton tracker responsible for aggregating and caching database
/// performance metrics and schema metadata in-memory.
///
/// This tracker serves as the central hub for the `SystemStatsProvider`,
/// collecting telemetry from the worker and maintaining a
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

  /// Registers a successful [FluentTask] execution, updating the table's telemetry
  /// metrics such as latency averages, throughput counts, and row-count state.
  ///
  /// This method serves as the primary hook for the [FluentEngine] to
  /// report task completion, facilitating real-time performance monitoring.
  void registerSuccess({required FluentTask task, required int elapsedMs, required bool isWrite}) {
    if (task.isSystem) return;

    final String key = task.statsKey;
    final TableStats stats = _statsMap.putIfAbsent(key, () => TableStats(task: task));

    stats.recordMetrics(currentWeight: task.staticWeight, elapsedMs: elapsedMs, isWrite: isWrite);
    stats.incrementSessionStats(isWrite: isWrite);

    markAsDirty();

    FluentLog.debug(
      'Task ${task.action} completed on ${task.table}',
      tag: 'FluentTableStats:register',
      context: {
        'elapsed': '${elapsedMs}ms',
        'isWrite': isWrite,
        'new_avg': isWrite ? stats.avgWriteTimeMs.toStringAsFixed(1) : stats.avgReadTimeMs.toStringAsFixed(1),
        'current_row_count': stats.rowCount,
      },
    );
  }

  /// Resets the performance statistics for the specified table to their default
  /// baseline values.
  ///
  /// This method should be called when the table's underlying structure changes
  /// (e.g., adding an index) or when historical metrics become invalid due to
  /// significant data model refactoring. Resetting ensures that the adaptive
  /// metrics (AEMA) do not carry over "toxic" latencies from previous
  /// unoptimized state, allowing the engine to re-learn the table's performance
  /// characteristics from a clean slate.
  void resetPerformanceStats(String dbName, String tableName) {
    final TableStats? stats = _statsMap[_makeKey(dbName, tableName)];
    if (stats != null) {
      stats.resetPerformanceStats();
      markAsDirty();
    }
  }

  /// Resets all performance statistics for every table associated with the
  /// specified database to their default baseline values.
  ///
  /// This operation performs a cascading reset of all metrics (row counts,
  /// latency averages, execution weights) within the given database.
  ///
  /// **When to use:**
  /// - During a full database wipe ([FluentDbAction.clearDatabase]).
  /// - After major schema migrations that invalidate historical performance data.
  /// - When resetting the application state to ensure the engine re-evaluates
  ///   the database's performance characteristics from a fresh, unbiased state.
  ///
  /// If any stats were modified, this method automatically triggers [markAsDirty]
  /// to ensure the changes are persisted to the system telemetry storage.
  void resetDatabaseStats(String dbName) {
    bool hasChanges = false;
    for (final TableStats stats in _statsMap.values) {
      if (stats.dbName == dbName) {
        stats.resetAllStats();
        hasChanges = true;
      }
    }
    if (hasChanges) markAsDirty();
  }

  /// Resets the performance statistics and structural metadata for all tracked
  /// database tables to their default baseline values.
  ///
  /// This is a global "hard reset" operation that should be invoked during
  /// maintenance events such as a full database wipe or schema re-initialization.
  /// By clearing all metrics—including row counts, relational depth, and
  /// accumulated execution latencies—it ensures that the [FluentEngine] starts
  /// with a completely clean slate, preventing stale or inconsistent telemetry
  /// from influencing task scheduling and priority calculations after a
  /// structural data reset.
  void resetAllPerformanceStats() {
    for (final TableStats stats in _statsMap.values) {
      stats.resetAllStats();
    }
    markAsDirty();
  }

  /// Records a failed [FluentTask] execution, incrementing the error counter
  /// for the associated table and marking the tracker as 'dirty'.
  ///
  /// Tracking failures is critical for identifying unstable database operations,
  /// such as schema mismatches, transaction rollbacks, or constraint violations.
  void registerFailure(FluentTask task) {
    final String key = task.statsKey;
    final TableStats stats = _statsMap.putIfAbsent(key, () => TableStats(task: task));

    stats.failedQueries++;
    markAsDirty();

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
    clearDirtyFlag();
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

  /// Marks the stats tracker as 'dirty', indicating that pending changes
  /// need to be persisted to the system storage.
  void markAsDirty() {
    _isDirty = true;
    FluentLog.debug('Stats marked as dirty. Pending changes queued for next sync.', tag: 'FluentTableStats:dirty');
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
      ..writeln('┌─────────────────┬─────────────┬─────────────┬─────────────┬─────────────────┬──────────────────────┐')
      ..writeln('│ Table (DB)      │ Row Count   │ Active (S)  │ Avg Read    │ Avg Write       │ Weight (Complexity)  │')
      ..writeln('├─────────────────┼─────────────┼─────────────┼─────────────┼─────────────────┼──────────────────────┤');

    _statsMap.forEach((_, s) {
      final String displayTitle = '${s.tableName} (${s.dbName})';
      final String tableInfo = displayTitle.length > 15 ? '${displayTitle.substring(0, 12)}...' : displayTitle.padRight(15);

      final String rows = s.rowCount.toString().padLeft(11);
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

      buffer.writeln('│ $tableInfo │ $rows │ $active │ $avgRead │ $avgWrite │ $levelBadge │');
    });

    buffer.write('└────────────────┴─────────────┴─────────────┴─────────────┴─────────────────┴──────────────────────┘');

    FluentLog.info(buffer.toString(), tag: 'FluentTableStats:ui', linesBefore: 1);
  }
}
