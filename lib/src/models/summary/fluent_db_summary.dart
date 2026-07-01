import '../models.dart';

class FluentDbSummary {
  final int totalTrackedTables;
  final int totalRowsAcrossAllTables;
  final double globalAvgReadMs;
  final double globalAvgWriteMs;
  final FluentDbHealthReport health;

  /// Contains the raw JSON output of each table's individual [TableStats].
  final Map<String, dynamic> tableStatsJson;

  FluentDbSummary({
    required this.totalTrackedTables,
    required this.totalRowsAcrossAllTables,
    required this.globalAvgReadMs,
    required this.globalAvgWriteMs,
    required this.health,
    required this.tableStatsJson,
  });

  /// Converts the entire database telemetry snapshot into a JSON map.
  Map<String, dynamic> toJson() => {
    'totalTrackedTables': totalTrackedTables,
    'totalRowsAcrossAllTables': totalRowsAcrossAllTables,
    'globalAvgReadMs': double.parse(globalAvgReadMs.toStringAsFixed(2)),
    'globalAvgWriteMs': double.parse(globalAvgWriteMs.toStringAsFixed(2)),
    'health': health.toJson(),
    'tables': tableStatsJson,
  };
}