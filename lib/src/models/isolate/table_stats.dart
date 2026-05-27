// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../core/fluent_sqlite_internal.dart';

/// Represents a telemetry snapshot of a database table's performance and usage statistics.
///
/// This class stores metrics collected during the application lifecycle, allowing
/// the system to analyze query efficiency, workload balance, and error rates per table.
class TableStats extends FluentStorable {
  /// The identifier of the database containing the table.
  final String dbName;

  /// The name of the table being tracked.
  final String tableName;

  /// Current number of rows in the table.
  int rowCount;

  /// Aggregate size of data payloads processed in the current session.
  int sessionPayload;

  /// Total count of established relations mapped to this table.
  int relationsCount;

  /// Moving average of time taken for read operations (in milliseconds).
  double avgReadTimeMs;

  /// Moving average of time taken for write operations (in milliseconds).
  double avgWriteTimeMs;

  /// The longest execution time recorded for a single operation on this table (ms).
  int maxTimeMs;

  /// The shortest execution time recorded for a single operation on this table (ms).
  int minTimeMs;

  /// Cumulative count of all read operations since tracking began.
  int totalReads;

  /// Cumulative count of all write operations since tracking began.
  int totalWrites;

  /// Number of read operations performed in the current runtime session.
  int readsSession;

  /// Number of write operations performed in the current runtime session.
  int writesSession;

  /// Count of operations that resulted in an SQLite exception or transaction failure.
  int failedQueries;

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
    this.sessionPayload = 0,
    this.relationsCount = 0,
    this.avgReadTimeMs = 0.0,
    this.avgWriteTimeMs = 0.0,
    this.maxTimeMs = 0,
    this.minTimeMs = 999999,
    this.totalReads = 0,
    this.totalWrites = 0,
    this.readsSession = 0,
    this.writesSession = 0,
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
  Map<String, dynamic> buildJson() => {
    'dbName': dbName,
    'tableName': tableName,
    'rowCount': rowCount,
    'sessionPayload': sessionPayload,
    'relationsCount': relationsCount,
    'avgReadTime': avgReadTimeMs,
    'avgWriteTimeMs': avgWriteTimeMs,
    'maxTimeMs': maxTimeMs,
    'minTimeMs': minTimeMs,
    'totalReads': totalReads,
    'totalWrites': totalWrites,
    'readsSession': readsSession,
    'writesSession': writesSession,
    'failedQueries': failedQueries,
  };

  /// Deserializes a [Map] back into a [TableStats] instance.
  factory TableStats.fromMap(Map<String, dynamic> map) => TableStats(
    dbName: map['dbName'] is String ? map['dbName'] as String : '',
    tableName: map['tableName'] is String ? map['tableName'] as String : '',
    rowCount: map['rowCount'] is int ? map['rowCount'] as int : 0,
    sessionPayload: map['sessionPayload'] is int ? map['sessionPayload'] as int : 0,
    relationsCount: map['relationsCount'] is int ? map['relationsCount'] as int : 0,
    avgReadTimeMs: (map['avgReadTime'] is num ? map['avgReadTime'] as num : 0).toDouble(),
    avgWriteTimeMs: (map['avgWriteTimeMs'] is num ? map['avgWriteTimeMs'] as num : 0).toDouble(),
    maxTimeMs: map['maxTimeMs'] is int ? map['maxTimeMs'] as int : 0,
    minTimeMs: map['minTimeMs'] is int ? map['minTimeMs'] as int : 0,
    totalReads: map['totalReads'] is int ? map['totalReads'] as int : 0,
    totalWrites: map['totalWrites'] is int ? map['totalWrites'] as int : 0,
    readsSession: map['readsSession'] is int ? map['readsSession'] as int : 0,
    writesSession: map['writesSession'] is int ? map['writesSession'] as int : 0,
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

      FluentLog.info('Successfully persisted ${statsList.length} telemetry entries to disk.', tag: 'TableStats:persist');
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
