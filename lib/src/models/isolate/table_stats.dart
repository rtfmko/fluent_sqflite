// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../core/fluent_sqlite_internal.dart';

/// Represents an aggregated telemetry snapshot of a database table's performance.
class TableStats extends FluentStorable {
  /// The identifier of the database containing the table.
  final String dbName;

  /// The name of the table being tracked.
  final String tableName;

  /// Current number of rows in the table.
  int rowCount;

  /// Total count of established relations mapped to this table.
  int relationsCount;

  /// Moving average of time taken for read operations (in milliseconds).
  double avgReadTimeMs;

  /// Moving average of time taken for write operations (in milliseconds).
  double avgWriteTimeMs;

  /// The average execution weight calculated from [FluentTask.executionWeight].
  double avgExecutionWeight;

  /// The longest execution time recorded for a single operation on this table (ms).
  int maxTimeMs;

  /// The shortest execution time recorded for a single operation on this table (ms).
  int? minTimeMs;

  /// Cumulative count of all read operations since tracking began.
  int totalReads;

  /// Cumulative count of all write operations since tracking began.
  int totalWrites;

  /// Count of operations that resulted in an SQLite exception or transaction failure.
  int failedQueries;

  /// Count of read operations performed during the current application session.
  ///
  /// This value is transient, resets upon application restart, and is not
  /// persisted to the database. Used for real-time performance monitoring.
  int _readsSession = 0;

  /// Count of write operations performed during the current application session.
  ///
  /// This value is transient, resets upon application restart, and is not
  /// persisted to the database. Used for real-time performance monitoring.
  int _writesSession = 0;

  /// Count of read operations performed during the current application session.
  ///
  /// This value is transient, resets upon application restart, and is not
  /// persisted to the database. Used for real-time performance monitoring.
  int get readsSession => _readsSession;

  /// Count of write operations performed during the current application session.
  ///
  /// This value is transient, resets upon application restart, and is not
  /// persisted to the database. Used for real-time performance monitoring.
  int get writesSession => _writesSession;

  /// A synthetic unique identifier for this record in the telemetry database.
  ///
  /// Combines [dbName] and [tableName] to ensure database-level uniqueness,
  /// enabling the use of [ConflictAlgorithm.replace] during batch persistence.
  String get _statKey => '$dbName:$tableName';

  /// Creates a [TableStats] instance, optionally initialized from an active [FluentTask].
  ///
  /// This factory-like constructor pattern allows for easy creation of stats
  /// objects either from explicit parameters or as a result of monitoring an
  /// ongoing task execution.
  ///
  /// The initializer list handles the fallback logic for [dbName] and [tableName],
  /// prioritizing explicit values over [FluentTask] metadata, which is useful when
  /// tracking aggregate stats across multiple tasks for the same table.
  TableStats({
    FluentTask? task,
    String? dbName,
    String? tableName,
    this.rowCount = 0,
    this.relationsCount = 0,
    this.avgReadTimeMs = 0.0,
    this.avgWriteTimeMs = 0.0,
    this.avgExecutionWeight = 10.0,
    this.maxTimeMs = 0,
    this.minTimeMs,
    this.totalReads = 0,
    this.totalWrites = 0,
    this.failedQueries = 0,
  }) : dbName = dbName ?? task?.dbName ?? '',
       tableName = tableName ?? task?.table ?? '';

  /// Dynamically calculates the [TableComplexity] based on the observed
  /// performance latency (Read/Write times).
  ///
  /// This getter acts as a "performance heuristic." By comparing the worst-case
  /// average latency (`maxAvg`) against predefined thresholds, it automatically
  /// classifies the table's current operational load.
  ///
  /// **Thresholds (ms):**
  /// * `<= 5.0`: [TableComplexity.low] - High efficiency, minimal overhead.
  /// * `<= 20.0`: [TableComplexity.medium] - Standard operation.
  /// * `<= 50.0`: [TableComplexity.high] - Noticed latency; query optimization recommended.
  /// * `> 50.0`: [TableComplexity.extreme] - Significant bottlenecks detected; high priority for refactoring.
  TableComplexity get complexity {
    final double maxAvg = avgReadTimeMs > avgWriteTimeMs ? avgReadTimeMs : avgWriteTimeMs;

    if (maxAvg <= 5.0) return TableComplexity.low;
    if (maxAvg <= 20.0) return TableComplexity.medium;
    if (maxAvg <= 50.0) return TableComplexity.high;
    return TableComplexity.extreme;
  }

  @override
  List<FluentDbColumn> get tableSchema => [
    primaryKey,
    FluentDbColumn(name: 'statKey', type: FluentDbDataType.text, isUnique: true),
    FluentDbColumn(name: 'dbName', type: FluentDbDataType.text),
    FluentDbColumn(name: 'tableName', type: FluentDbDataType.text),
    FluentDbColumn(name: 'rowCount', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'relationsCount', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'avgReadTimeMs', type: FluentDbDataType.real),
    FluentDbColumn(name: 'avgWriteTimeMs', type: FluentDbDataType.real),
    FluentDbColumn(name: 'avgExecutionWeight', type: FluentDbDataType.real),
    FluentDbColumn(name: 'maxTimeMs', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'minTimeMs', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'totalReads', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'totalWrites', type: FluentDbDataType.integer),
    FluentDbColumn(name: 'failedQueries', type: FluentDbDataType.integer),
  ];

  /// Fully resets the table's statistics to their initial state.
  /// Used during operations like [clearTable] or [wipeAll] when accumulated
  /// row counts and performance metrics are no longer relevant.
  void resetAllStats() {
    rowCount = 0;
    relationsCount = 0;
    avgReadTimeMs = 0.0;
    avgWriteTimeMs = 0.0;
    avgExecutionWeight = 10.0;
    maxTimeMs = 0;
    minTimeMs = null;
    totalReads = 0;
    totalWrites = 0;
    failedQueries = 0;
  }

  /// Resets only the performance metrics (latencies, execution weight).
  /// Structural data (rowCount, relationsCount, failedQueries) remains intact.
  /// Useful for periodic recalibration or when clearing cumulative averages
  /// without invalidating the actual data row counts.
  void resetPerformanceStats() {
    avgReadTimeMs = 0.0;
    avgWriteTimeMs = 0.0;
    avgExecutionWeight = 10.0;
    minTimeMs = null;
    maxTimeMs = 0;
    totalReads = 0;
    totalWrites = 0;
  }

  /// Increments in-memory session counters (call this from Tracker)
  void incrementSessionStats({required bool isWrite}) {
    if (isWrite) {
      _writesSession++;
    } else {
      _readsSession++;
    }
  }

  /// Records performance metrics for the table, updating latency bounds,
  /// average read/write times, and the adaptive execution weight.
  ///
  /// Uses an Adaptive Exponential Moving Average (AEMA) to calculate metrics:
  /// - [sensitivity] is derived from the deviation of the current weight from
  ///   the historical average, providing a "trigger" for rapid adaptation.
  /// - [alpha] (smoothing factor) dynamically scales between 0.07 and 0.3:
  ///     - 0.07 ensures baseline stability during normal operation.
  ///     - 0.3 allows the system to react quickly to performance bottlenecks
  ///       or "storm" conditions.
  /// - Metrics are clamped to prevent outliers from distorting the engine's
  ///   decision-making process (20ms - 300ms for weights).
  void recordMetrics({required int currentWeight, required int elapsedMs, required bool isWrite}) {
    // 1. Latency bounds
    if (elapsedMs > maxTimeMs) maxTimeMs = elapsedMs;
    if (minTimeMs == null || elapsedMs < minTimeMs!) minTimeMs = elapsedMs;

    // 2. Adaptive Alpha Calculation
    final double weightDouble = currentWeight.toDouble();
    final double diff = (weightDouble - avgExecutionWeight).abs();
    final double sensitivity = diff / (avgExecutionWeight + 20.0);
    final double alpha = sensitivity.clamp(0.07, 0.3);

    // 3. Update Adaptive Execution Weight
    double newWeight = ((avgExecutionWeight * (1 - alpha)) + (weightDouble * alpha));

    if (currentWeight < avgExecutionWeight) {
      final double coolingFactor = (avgExecutionWeight / 400.0) * 0.03;
      newWeight -= (avgExecutionWeight - currentWeight) * coolingFactor;
    }

    avgExecutionWeight = newWeight.clamp(10.0, 400.0);

    // 4. Update Latency Averages
    final double targetTime = (elapsedMs <= 0) ? 0.1 : elapsedMs.toDouble();
    if (isWrite) {
      totalWrites++;
      avgWriteTimeMs = (totalWrites == 1) ? targetTime : (avgWriteTimeMs * (1 - alpha)) + (targetTime * alpha);
    } else {
      totalReads++;
      avgReadTimeMs = (totalReads == 1) ? targetTime : (avgReadTimeMs * (1 - alpha)) + (targetTime * alpha);
    }
  }

  @override
  Map<String, dynamic> buildJson() => {
    'statKey': _statKey,
    'dbName': dbName,
    'tableName': tableName,
    'rowCount': rowCount,
    'relationsCount': relationsCount,
    'avgReadTimeMs': avgReadTimeMs,
    'avgWriteTimeMs': avgWriteTimeMs,
    'avgExecutionWeight': avgExecutionWeight,
    'maxTimeMs': maxTimeMs,
    'minTimeMs': minTimeMs,
    'totalReads': totalReads,
    'totalWrites': totalWrites,
    'failedQueries': failedQueries,
  };

  /// Deserializes a [Map] back into a [TableStats] instance.
  factory TableStats.fromMap(Map<String, dynamic> map) => TableStats(
    dbName: map['dbName'] is String ? map['dbName'] as String? : '',
    tableName: map['tableName'] is String ? map['tableName'] as String : '',
    rowCount: map['rowCount'] is int ? map['rowCount'] as int : 0,
    relationsCount: map['relationsCount'] is int ? map['relationsCount'] as int : 0,
    avgReadTimeMs: (map['avgReadTimeMs'] is num ? map['avgReadTimeMs'] as num : 0).toDouble(),
    avgWriteTimeMs: (map['avgWriteTimeMs'] is num ? map['avgWriteTimeMs'] as num : 0).toDouble(),
    avgExecutionWeight: (map['avgExecutionWeight'] is num ? map['avgExecutionWeight'] as num : 10).toDouble(),
    maxTimeMs: map['maxTimeMs'] is int ? map['maxTimeMs'] as int : 0,
    minTimeMs: map['minTimeMs'] is int ? map['minTimeMs'] as int : null,
    totalReads: map['totalReads'] is int ? map['totalReads'] as int : 0,
    totalWrites: map['totalWrites'] is int ? map['totalWrites'] as int : 0,
    failedQueries: map['failedQueries'] is int ? map['failedQueries'] as int : 0,
  );
}

/// A specialized Data Access Object (DAO) for persisting and retrieving
/// internal database performance metrics.
///
/// This provider uses the `__fluent_table_stats` internal table to store
/// [TableStats] snapshots. By integrating with the database itself, it allows
/// the system to maintain a persistent history of performance telemetry across
/// application restarts.
class SystemStatsProvider extends FluentProvider<TableStats> {
  @override
  String get tableName => '__fluent_table_stats';

  @override
  TableStats get modelSample => TableStats();

  @override
  TableStats fromCacheJson(Map<String, dynamic> json) => TableStats.fromMap(json);

  /// Performs a high-performance batch insertion to update performance snapshots.
  ///
  /// Using a [Batch] is critical here: when the system performs a periodic
  /// flush of statistics, it minimizes the number of disk I/O operations by
  /// grouping multiple `INSERT` statements into a single transaction commit.
  Future<void> saveStatsBatch(Database db, List<TableStats> statsList) async {
    final Batch batch = db.batch();
    for (final TableStats stats in statsList) {
      batch.insert(tableName, stats.buildJson(), conflictAlgorithm: ConflictAlgorithm.replace);
    }

    try {
      await batch.commit(noResult: true);

      FluentLog.debug('Successfully persisted ${statsList.length} telemetry entries to disk.', tag: 'TableStats:persist');
    } catch (e, s) {
      FluentLog.error('Failed to persist telemetry batch.', e, s, tag: 'TableStats:persist', hint: 'Check database connectivity or disk write permissions.');
      rethrow;
    }
  }

  /// Retrieves the entire performance history for all tables.
  ///
  /// This is typically called during the initialization phase to hydrate the
  /// [FluentTableStatsTracker] with existing data from the disk.
  Future<List<TableStats>> readAllStats(Database db) async {
    try {
      final List<Map<String, dynamic>> maps = await db.query(tableName);

      final List<TableStats> stats = maps.map((m) => TableStats.fromMap(m)).toList();

      FluentLog.debug('Successfully loaded ${stats.length} telemetry records from $tableName.', tag: 'TableStats:read');

      return stats;
    } catch (e, s) {
      FluentLog.error('Failed to read telemetry records from $tableName.', e, s, tag: 'TableStats:read', hint: 'Verify the existence of the $tableName table or check for schema inconsistencies.');
      return [];
    }
  }
}
