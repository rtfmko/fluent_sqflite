// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../core/fluent_sqlite_internal.dart';

/// Represents a discrete, self-contained unit of work for the database engine.
///
/// This class serves as the primary command object within the [FluentEngine],[FluentProvider],
/// encapsulating both the data to be processed and the metadata (policy, constraints,
/// and identity) required to execute the operation safely across isolate boundaries.
class FluentTask {
  /// Unique identifier for the task; used for tracking, status updates, and cancellation.
  int id;

  /// The target table name for this operation.
  final String table;

  /// The specific database instance identifier (e.g., 'primary', 'cache').
  final String dbName;

  /// The type of action to perform (e.g., `find`, `save`, `delete`).
  final FluentDbAction action;

  /// The primary payload or raw data required for the operation.
  final dynamic data;

  /// The maximum depth for recursive relationship resolution (e.g., fetching nested entities).
  final int maxDepth;

  /// If true, skips loading relationships marked as "lazy" to optimize performance.
  final bool ignoreLazy;

  /// If true, bypasses standard validation or deduplication checks.
  final bool force;

  /// Pre-resolved or injected relational mapping data for batch operations.
  final List<Map<String, dynamic>>? relations;

  /// The [TableHelper] configuration specifying query constraints (where, limit, etc.).
  final TableHelper? helper;

  /// The [ExecutionPolicy] defining isolate usage, priority, and timeouts.
  final ExecutionPolicy policy;

  /// Flags whether this task is a internal maintenance/system task (e.g., cleanup).
  final bool isSystem;

  /// The base priority weight calculated at instantiation; used for queue sorting.
  late final int staticWeight;

  /// The dynamic weight adjusted by the coordinator during runtime (e.g., task aging).
  int executionWeight;

  /// A unique hash representing the task's parameters, used for task deduplication.
  late final String fingerprint;

  /// Constructs a [FluentTask] and automatically computes its scheduling metadata.
  ///
  /// The constructor immediately processes the [action], [helper], and [policy]
  /// to generate a [staticWeight] and [fingerprint]. This ensures that the
  /// task is "ready for dispatch" the moment it is instantiated, allowing
  /// the [FluentEngine] to place it into the correct priority queue
  /// without further computation.
  FluentTask({
    this.id = 0,
    this.table = '',
    this.dbName = '',
    required this.action,
    this.data,
    this.maxDepth = 1,
    this.ignoreLazy = false,
    this.force = false,
    this.relations,
    this.helper,
    this.policy = const ExecutionPolicy(),
    this.isSystem = false,
    this.executionWeight = 0,
  }) {
    // Determine the baseline computational cost of this task.
    staticWeight = _calculateStaticWeight();

    // Create a unique identifier to support automatic task deduplication.
    fingerprint = _calculateFingerprint();
  }

  /// Creates a copy of this [FluentTask] with the specified fields replaced.
  FluentTask copyWith({
    int? id,
    String? table,
    String? dbName,
    FluentDbAction? action,
    dynamic data,
    int? maxDepth,
    bool? ignoreLazy,
    bool? force,
    List<Map<String, dynamic>>? relations,
    TableHelper? helper,
    int? executionWeight,
    bool? isSystem,
    ExecutionPolicy? policy,
  }) => FluentTask(
    id: id ?? this.id,
    table: table ?? this.table,
    dbName: dbName ?? this.dbName,
    action: action ?? this.action,
    data: data ?? this.data,
    maxDepth: maxDepth ?? this.maxDepth,
    ignoreLazy: ignoreLazy ?? this.ignoreLazy,
    force: force ?? this.force,
    relations: relations ?? this.relations,
    helper: helper ?? this.helper,
    executionWeight: executionWeight ?? this.executionWeight,
    isSystem: isSystem ?? this.isSystem,
    policy: policy ?? this.policy,
  );

  /// Serializes the [FluentTask] instance into a JSON-compatible map.
  Map<String, dynamic> toMap() => {
    'id': id,
    'table': table,
    'dbName': dbName,
    'action': action.index,
    'data': data,
    'maxDepth': maxDepth,
    'ignoreLazy': ignoreLazy,
    'relationsSchema': relations,
    'helper': helper?.toMap(),
    'isSystem': isSystem,
    'policy': policy.toMap(),
  };

  /// Deserializes a [Map] back into a [FluentTask] instance.
  factory FluentTask.fromMap(Map<String, dynamic> map) => FluentTask(
    id: map['id'] is int ? map['id'] as int : 0,
    table: map['table'] is String ? map['table'] as String : '',
    dbName: map['dbName'] is String ? map['dbName'] as String : '',
    action: FluentDbAction.values[map['action'] is int ? map['action'] as int : 0],
    data: map['data'],
    maxDepth: map['maxDepth'] is int ? map['maxDepth'] as int : 1,
    ignoreLazy: map['ignoreLazy'] is bool ? map['ignoreLazy'] as bool : false,
    relations: map['relationsSchema'] is List ? map['relationsSchema'] as List<Map<String, dynamic>> : null,
    helper: map['helper'] is Map<String, dynamic> ? TableHelper.fromMap(map['helper'] as Map<String, dynamic>) : null,
    isSystem: map['isSystem'] is bool ? map['isSystem'] as bool : false,
    policy: map['policy'] is Map<String, dynamic> ? ExecutionPolicy.fromMap(map['policy'] as Map<String, dynamic>) : const ExecutionPolicy(),
  );

  /// Generates a unique "fingerprint" for this task based on its critical parameters.
  ///
  /// This fingerprint is used for task deduplication within the [FluentEngine].
  /// By creating a hash-like identifier, we can instantly detect if an identical
  /// operation is already queued, preventing redundant database I/O and potential
  /// race conditions.
  ///
  /// **Why include runtime types?**
  /// Including `arg.runtimeType` ensures that an integer `1` and a string `"1"`
  /// are treated as distinct parameters, preventing false-positive deduplication.
  String _calculateFingerprint() {
    final StringBuffer sb = StringBuffer('$dbName:$table:${action.name}:$maxDepth:$ignoreLazy:');

    final TableHelper? h = helper;
    if (h != null) {
      sb.write('${h.id}_${h.where}_${h.orderBy}_${h.limit}_${h.offset}_${h.sql}_');

      if (h.whereArgs != null) {
        for (final arg in h.whereArgs!) {
          sb.write('${arg.runtimeType}:$arg,');
        }
      }
      if (h.arguments != null) {
        for (final arg in h.arguments!) {
          sb.write('${arg.runtimeType}:$arg,');
        }
      }
    }

    final String fingerprint = sb.toString();

    FluentLog.debug('Fingerprint generated for task: $fingerprint', tag: 'FluentTask:fingerprint');

    return fingerprint;
  }

  /// Calculates the static weight of the task based on its computational complexity,
  /// I/O impact, and relational overhead.
  ///
  /// This weight is used by the [FluentEngine] to prioritize tasks in the
  /// execution queue. Higher weights indicate more resource-intensive operations
  /// that may require careful scheduling to prevent UI thread stuttering or
  /// SQLite lock contention.
  int _calculateStaticWeight() {
    int w = 0;
    final TableHelper? h = helper;

    // 1. Complexity Score: Assign base cost to actions based on typical SQLite performance
    switch (action) {
      case FluentDbAction.findById:
      case FluentDbAction.exists:
      case FluentDbAction.updateSingleField:
      case FluentDbAction.rawGetItem:
        w += 15; // O(1) or O(log N) index lookups
        break;

      case FluentDbAction.update:
        w += 25;
        break;

      case FluentDbAction.count:
      case FluentDbAction.updateMultipleFields:
      case FluentDbAction.delete:
      case FluentDbAction.deleteBy:
        w += 35;
        break;

      case FluentDbAction.find:
      case FluentDbAction.findItemsBy:
      case FluentDbAction.findValidItems:
      case FluentDbAction.rawGetItems:
      case FluentDbAction.save:
      case FluentDbAction.saveStats:
        w += 60; // Heavier I/O or multi-step CRUD pipelines
        break;

      case FluentDbAction.findAll:
      case FluentDbAction.analyzeStats:
      case FluentDbAction.updateWithRelations:
        w += 80; // Potential Full Table Scan or cascaded graph updates
        break;

      case FluentDbAction.deleteItemsByIds:
      case FluentDbAction.clearTable:
      case FluentDbAction.clearExpired:
        w += 100; // Bulk modifications, heavy impact
        break;

      case FluentDbAction.execute:
        w += 150; // Unbounded execution complexity
        break;

      default:
        w += 40;
    }
    // 2. Query Refinement: Adjust weight based on query builder constraints
    if (h != null) {
      if (h.limit != null) {
        // Small limits significantly reduce I/O overhead
        w = (w * (h.limit! > 100 ? 1.2 : 0.7)).round();
      } else if (action == FluentDbAction.find || action == FluentDbAction.findItemsBy) {
        w += 80; // Penalty for lacking LIMIT: High risk of large result sets
      }

      if (h.sortByExpireDate || h.orderBy != null) {
        w += 30; // Sort operations require extra memory/CPU (temp tables)
      }

      if (h.key != null && h.value != null) {
        w -= 10; // Indexed lookups are highly efficient
      }
    }

    // 3. Relational Recursion: Penalize deep object graphs (N+1 query risk)
    if (maxDepth == 0) {
      w += 200; // Severe penalty for unbounded recursion
    } else if (maxDepth > 1) {
      w += (maxDepth * 40);
    }

    // 4. Data Fetching Policy: Eager loading (ignoreLazy) increases memory pressure
    if (ignoreLazy) w += 30;

    FluentLog.debug('Weight calculated for task $id: $w (Action: ${action.name})', tag: 'FluentTask:weighting');

    return w;
  }

  @override
  String toString() {
    return 'FluentTask{id: $id, table: $table, dbName: $dbName, action: $action, maxDepth: $maxDepth, ignoreLazy: $ignoreLazy, force: $force, helper: $helper, policy: $policy, isSystem: $isSystem, staticWeight: $staticWeight, executionWeight: $executionWeight, fingerprint: $fingerprint}';
  }
}
