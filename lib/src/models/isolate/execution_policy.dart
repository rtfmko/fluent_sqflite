// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Defines the operational strategy for executing a [FluentTask].
///
/// This class governs the "how" and "when" of database operations, controlling
/// resource allocation, concurrency, and task-level behavior within the
/// [FluentEngine] pipeline.
class ExecutionPolicy {
  /// If true, forces the task to run in a background isolate (the standard behavior).
  /// If false, allows the operation to run on the main thread (for simple, latency-sensitive reads).
  final bool? useIsolate;

  /// Determines task importance. Higher values move the task to the front
  /// of the [FluentEngine] queue.
  final int? priority;

  /// Defines the maximum number of records processed in a single batch.
  /// Essential for memory management when dealing with large datasets.
  final int? chunkSize;

  /// If true, the coordinator will drop the current task if an identical
  /// task (based on [FluentTask.fingerprint]) is already awaiting execution.
  final Duration? timeout;

  /// If true, the coordinator will drop the current task if an identical
  /// task (based on [FluentTask.fingerprint]) is already awaiting execution.
  final bool? cancelIfDuplicate;

  /// The [ExecutionPolicy] constructor initializes.
  const ExecutionPolicy({this.useIsolate = false, this.priority, this.chunkSize, this.timeout, this.cancelIfDuplicate});

  /// Calculates the optimized batch size for task execution based on the
  /// defined [chunkSize] policy.
  ///
  /// **Logic:**
  /// * **Defaulting:** Uses a sensible default of 200 records if no policy size is specified.
  /// * **Sanitization:** Imposes an upper bound of 950 records per chunk. This limit
  ///   is critical for SQLite operations to avoid hitting the maximum variable count
  ///   (SQLITE_LIMIT_VARIABLE_NUMBER) allowed in a single prepared statement.
  /// * **Heuristic Adjustment:** If a [chunkSize] of 100 or less is requested, the
  ///   logic automatically scales up to 950. This assumes that if a user wants
  ///   small chunks, they are likely performing complex operations, so we maximize
  ///   throughput within the safe SQL limits.
  int get effectiveChunkSize {
    final int rawSize = chunkSize ?? 200;

    // If the requested size is very small (<= 100), treat as a hint to maximize
    // performance up to the safe SQLite variable limit.
    return rawSize <= 100 ? 950 : rawSize.clamp(1, 950);
  }

  /// Serializes the [ExecutionPolicy] instance into a JSON-compatible map.
  Map<String, dynamic> toMap() => {'useIsolate': useIsolate, 'priority': priority, 'chunkSize': chunkSize, 'timeoutMs': timeout?.inMilliseconds, 'cancelIfDuplicate': cancelIfDuplicate};

  /// Deserializes a [Map] back into a [ExecutionPolicy] instance.
  factory ExecutionPolicy.fromMap(Map<String, dynamic> map) => ExecutionPolicy(
    useIsolate: map['useIsolate'] is bool ? map['useIsolate'] as bool : null,
    priority: map['priority'] is int ? map['priority'] as int : null,
    chunkSize: map['chunkSize'] is int ? map['chunkSize'] as int : null,
    timeout: map['timeoutMs'] is int ? Duration(milliseconds: map['timeoutMs'] as int) : null,
    cancelIfDuplicate: map['cancelIfDuplicate'] is bool ? map['cancelIfDuplicate'] as bool : null,
  );

  /// Defines common pre-configured execution policies for various task patterns.
  ///
  /// Using these named constants ensures consistent resource management across
  /// the application, preventing individual developers from having to manually
  /// tune [chunkSize], [timeout], or [priority] for standard operations.

  /// Standard policy for most CRUD operations.
  /// Uses isolate offloading, a 30s timeout, and prevents duplicate task queuing.
  factory ExecutionPolicy.rootDefault() => const ExecutionPolicy(useIsolate: false, priority: 0, chunkSize: 200, timeout: Duration(seconds: 30), cancelIfDuplicate: true);

  /// Optimized for rapid, lightweight read/writes.
  /// Bypasses the isolate to eliminate message-passing overhead for low-latency needs.
  static const fast = ExecutionPolicy(priority: 10, useIsolate: false);

  /// Designed for non-critical, long-running tasks.
  /// Lowered priority and small chunk sizes minimize impact on the main UI thread.
  static const background = ExecutionPolicy(priority: -10, useIsolate: false, chunkSize: 50);

  /// Optimized for massive data synchronization.
  /// Maximizes [chunkSize] for throughput and grants a generous 5-minute timeout.
  static const bulkUpload = ExecutionPolicy(priority: 5, useIsolate: false, chunkSize: 950, timeout: Duration(minutes: 5));

  /// Targeted at complex relational lookups.
  /// Includes deduplication to prevent slamming the database with repeated heavy queries.
  static const heavyQuery = ExecutionPolicy(priority: 2, useIsolate: false, cancelIfDuplicate: true, timeout: Duration(seconds: 15));

  /// Policy for data that must be processed every time (e.g., force-refresh events).
  /// Disables [cancelIfDuplicate] to guarantee execution.
  static const fresh = ExecutionPolicy(cancelIfDuplicate: false);

  /// Resolves the effective [ExecutionPolicy] by defaulting null values to the
  /// global [ExecutionPolicy.rootDefault()].
  ///
  /// This is used internally by the coordinator to ensure that every task
  /// has a fully populated set of configuration parameters, preventing
  /// runtime null-checks during the execution phase.
  ExecutionPolicy flatten() {
    final ExecutionPolicy def = ExecutionPolicy.rootDefault();
    return ExecutionPolicy(
      useIsolate: useIsolate ?? def.useIsolate,
      priority: priority ?? def.priority,
      chunkSize: effectiveChunkSize,
      timeout: timeout ?? def.timeout,
      cancelIfDuplicate: cancelIfDuplicate ?? def.cancelIfDuplicate,
    );
  }

  /// Merges this policy with a parent or base policy, allowing for hierarchical
  /// configuration overrides.
  ///
  /// **Usage Pattern:**
  /// If a [FluentTask] defines a local override (e.g., a specific timeout), this
  /// method ensures the local value takes precedence over the [parent]
  /// configuration. If the local value is null, the [parent]'s value is inherited.
  ///
  /// [parent]: The inherited policy to fall back on if local fields are null.
  ExecutionPolicy merge(ExecutionPolicy? parent) {
    if (parent == null) return this;
    return ExecutionPolicy(
      useIsolate: useIsolate ?? parent.useIsolate,
      priority: priority ?? parent.priority,
      chunkSize: chunkSize ?? parent.chunkSize,
      timeout: timeout ?? parent.timeout,
      cancelIfDuplicate: cancelIfDuplicate ?? parent.cancelIfDuplicate,
    );
  }

  /// Creates a copy of this [ExecutionPolicy] with the specified fields replaced.
  ExecutionPolicy copyWith({bool? useIsolate, int? priority, int? chunkSize, Duration? timeout, bool? spawnDedicatedIsolate, bool? cancelIfDuplicate, int? memoryLimitMb}) => ExecutionPolicy(
    useIsolate: useIsolate ?? this.useIsolate,
    priority: priority ?? this.priority,
    chunkSize: chunkSize ?? this.chunkSize,
    timeout: timeout ?? this.timeout,
    cancelIfDuplicate: cancelIfDuplicate ?? this.cancelIfDuplicate,
  );

  @override
  String toString() {
    return 'ExecutionPolicy{useIsolate: $useIsolate, priority: $priority, chunkSize: $chunkSize, timeout: $timeout, cancelIfDuplicate: $cancelIfDuplicate}';
  }
}
