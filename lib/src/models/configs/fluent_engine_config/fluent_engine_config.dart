// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Configuration settings for the [FluentEngine] lifecycle and maintenance routines.
///
/// This class defines the temporal parameters that govern background tasks,
/// resource management, and error reporting thresholds within the engine.
class FluentEngineConfig {
  /// Defines the interval between automatic telemetry synchronization attempts.
  ///
  /// During this cycle, accumulated statistics are flushed to persistent storage.
  final Duration saveInterval;

  /// The frequency at which the [FluentEngine] triggers background maintenance
  /// to refresh SQLite query planner statistics.
  ///
  /// Frequent analysis ensures optimal query execution plans, while infrequent
  /// updates minimize background I/O overhead.
  final Duration analyzeInterval;

  /// The maximum allowed duration for a manual database pause before the
  /// [Watchdog] triggers an emergency resumption or alert.
  ///
  /// If null, the engine will hold the pause indefinitely until [resumeQueue]
  /// is explicitly invoked.
  final Duration? maxPauseDuration;

  /// The timeout threshold for system-level alerts monitored by the [alertStream].
  ///
  /// This defines the grace period for reactive monitoring before an alert is
  /// considered critical or stale.
  final Duration alertPauseDuration;

  /// Creates a configuration for the [FluentEngine].
  ///
  /// * [saveInterval]: How often telemetry data is flushed to persistent storage.
  /// * [analyzeInterval]: The period between SQLite index and query planner maintenance.
  /// * [maxPauseDuration]: Optional threshold for how long a database can stay paused.
  /// * [alertPauseDuration]: Threshold for silent periods in the [alertStream] before
  ///   reporting state changes or monitoring gaps.
  const FluentEngineConfig({
    this.saveInterval = const Duration(seconds: 30),
    this.analyzeInterval = const Duration(minutes: 5),
    this.maxPauseDuration,
    this.alertPauseDuration = const Duration(seconds: 60),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FluentEngineConfig && runtimeType == other.runtimeType && saveInterval == other.saveInterval && analyzeInterval == other.analyzeInterval && maxPauseDuration == other.maxPauseDuration;

  @override
  int get hashCode => Object.hash(saveInterval, analyzeInterval, maxPauseDuration);
}
