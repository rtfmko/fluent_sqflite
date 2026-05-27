// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../../core/fluent_sqlite_internal.dart';

/// Represents a structured response payload sent from the background
/// isolate worker back to the [FluentEngine] in the Main Isolate.
class IsolateResponse {
  /// The unique identifier.
  final int taskId;

  /// The current state status of the task execution (e.g., ok, progress, error).
  final IsolateStatus status;

  /// A snapshot configuration of the task that triggered this specific transaction response.
  final FluentTask? task;

  /// The core raw data payload (typically a collection of hydrated database record rows).
  final dynamic data;

  /// The physical query duration metrics measured inside the background isolate thread (in milliseconds).
  final int executionTime;

  /// The total volume of dataset elements processed during the lifetime of this operation.
  final int totalRows;

  /// Hexadecimal unique application error code (e.g., '0x01'), populated on [IsolateStatus.error].
  final String? errorCode;

  /// A precise, diagnostic log snapshot slice collected during execution up to milliseconds accuracy.
  final List<String> logs;

  /// Matrix mapping listing processed row impact capacities across all underlying cascade tables.
  final Map<String, int> affectedTables;

  /// Creates an immutable response tracking envelope to transition state metrics across isolates.
  const IsolateResponse({
    required this.taskId,
    this.status = IsolateStatus.ok,
    this.task,
    this.data,
    this.executionTime = 0,
    this.totalRows = 0,
    this.errorCode,
    this.logs = const [],
    this.affectedTables = const {},
  });

  /// Creates a mutated clone of the current response snapshot configuration.
  ///
  /// Essential for injecting data slices, altering state statuses, or flushing
  /// background micro-logs without destroying the underlying thread data structures.
  IsolateResponse copyWith({
    int? taskId,
    IsolateStatus? status,
    FluentTask? task,
    dynamic data,
    int? executionTime,
    int? totalRows,
    String? errorCode,
    List<String>? logs,
    Map<String, int>? affectedTables,
  }) => IsolateResponse(
    taskId: taskId ?? this.taskId,
    status: status ?? this.status,
    task: task ?? this.task,
    data: data ?? this.data,
    executionTime: executionTime ?? this.executionTime,
    totalRows: totalRows ?? this.totalRows,
    errorCode: errorCode ?? this.errorCode,
    logs: logs ?? this.logs,
    affectedTables: affectedTables ?? this.affectedTables,
  );

  /// Serializes the tracking metrics into a standard map layer contract for cross-port streaming.
  Map<String, dynamic> toMap() => {
    'taskId': taskId,
    'status': status.index,
    'task': task?.toMap(),
    'data': data,
    'executionTime': executionTime,
    'totalRows': totalRows,
    'errorCode': errorCode,
    'logs': logs,
    'affectedTables': affectedTables,
  };

  /// Constructs a structured [IsolateResponse] from a serialized data map frame.
  factory IsolateResponse.fromMap(Map<String, dynamic> map) {
    final List<String> parsedLogs = map['logs'] is List ? List<dynamic>.from(map['logs'] as List).cast<String>() : const [];

    final Map<String, int> parsedAffected = map['affectedTables'] is Map ? (map['affectedTables'] as Map).cast<String, int>() : const {};

    return IsolateResponse(
      taskId: map['taskId'] is int ? map['taskId'] as int : 1,
      status: IsolateStatus.values[map['status'] is int ? map['status'] as int : 0],
      task: map['task'] is Map ? FluentTask.fromMap(Map<String, dynamic>.from(map['task'] as Map)) : null,
      data: map['data'],
      executionTime: map['executionTime'] is int ? map['executionTime'] as int : 0,
      totalRows: map['totalRows'] is int ? map['totalRows'] as int : 0,
      errorCode: map['errorCode'] is String ? map['errorCode'] as String : null,
      logs: parsedLogs,
      affectedTables: parsedAffected,
    );
  }
}
