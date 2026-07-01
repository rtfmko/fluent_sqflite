class FluentDbHealthReport {
  final List<String> extremeLoadTables;
  final List<String> highLoadTables;
  final List<String> moderateLoadTables;
  final List<String> healthyTables;
  final int totalReadsSession;
  final int totalWritesSession;

  FluentDbHealthReport({
    required this.extremeLoadTables,
    required this.highLoadTables,
    required this.moderateLoadTables,
    required this.healthyTables,
    required this.totalReadsSession,
    required this.totalWritesSession,
  });

  /// Converts the health report into a JSON-compatible map for external telemetry.
  Map<String, dynamic> toJson() => {
    'extremeLoadTables': extremeLoadTables,
    'highLoadTables': highLoadTables,
    'moderateLoadTables': moderateLoadTables,
    'healthyTables': healthyTables,
    'totalReadsSession': totalReadsSession,
    'totalWritesSession': totalWritesSession,
  };
}