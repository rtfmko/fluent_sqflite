// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../../core/fluent_sqlite_internal.dart';

/// Represents a structured command message sent from the Main Isolate
/// to the background execution worker ([_FluentWorker]).
class IsolateRequest {
  /// The specific operation token directing the isolate worker's control flow.
  final IsolateCmd cmd;

  /// The concrete database task payload containing parameters for physical storage execution.
  final FluentTask? task;

  /// Volatile data register used to pass dynamic arguments (e.g., configurations, metrics payloads).
  final dynamic data;

  /// The communication port where response payloads from diagnostics operations should be directed.
  final SendPort? replyPort;

  /// Creates a immutable request capsule to transmit across isolate borders.
  const IsolateRequest({required this.cmd, this.task, this.data, this.replyPort});

  /// Serializes the request envelope into a standard map contract for pipeline transmission.
  ///
  /// Enums are reduced to integer indexes, and [SendPort] references are preserved nakedly.
  Map<String, dynamic> toMap() => {'cmd': cmd.index, 'task': task?.toMap(), 'data': data, 'replyPort': replyPort};

  /// Constructs a structured [IsolateRequest] from a serialized data frame.
  factory IsolateRequest.fromMap(Map<String, dynamic> map) {
    FluentTask? parsedTask;
    if (map['task'] != null && map['task'] is Map) {
      parsedTask = FluentTask.fromMap(Map<String, dynamic>.from(map['task'] as Map));
    }

    return IsolateRequest(
      cmd: IsolateCmd.values[map['cmd'] is int ? map['cmd'] as int : 0],
      task: parsedTask,
      data: map['data'],
      replyPort: map['replyPort'] is SendPort ? map['replyPort'] as SendPort : null,
    );
  }

  /// Creates a mutated clone of the current request configuration snapshot.
  ///
  /// Simplifies task transformations and enables predictable state modifications
  /// without mutating underlying memory contexts.
  IsolateRequest copyWith({IsolateCmd? cmd, FluentTask? task, dynamic data, SendPort? replyPort}) =>
      IsolateRequest(cmd: cmd ?? this.cmd, task: task ?? this.task, data: data ?? this.data, replyPort: replyPort ?? this.replyPort);
}
