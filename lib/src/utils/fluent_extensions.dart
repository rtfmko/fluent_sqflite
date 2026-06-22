// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../models/models.dart';
import 'utils.dart';

/// Utility extensions for [Map] to simplify database-to-model conversions.
///
/// These methods provide safe ways to extract and cast data from raw JSON maps
/// returned by the database.
extension FluentJsonExtension on Map<String, dynamic> {
  /// Attempts to extract a [DateTime] from the map by the given [key].
  ///
  /// This method is flexible and supports:
  /// * **int**: Interpreted as milliseconds since epoch.
  /// * **String**: Interpreted as an ISO 8601 formatted date.
  ///
  /// Returns `null` if the key is missing, the value is `null`, or the
  /// format is unrecognized.
  ///
  /// Example:
  /// ```dart
  /// final dynamic json = {'created_at': 1777755600000};
  /// final DateTime date = json.tryGetDateTime('created_at'); // 2026-05-03...
  ///
  /// final dynamic stringJson = {'updated_at': '2026-05-03T12:00:00Z'};
  /// final DateTime date2 = stringJson.tryGetDateTime('updated_at'); // 2026-05-03...
  /// ```
  DateTime? tryGetDateTime(String key) {
    final dynamic value = this[key];
    if (value == null) return null;

    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }
}

/// A utility extension for applying ANSI escape codes to strings.
///
/// These sequences allow colorizing terminal output, making logs
/// significantly easier to scan visually.
extension FluentColorStrings on String {
  // ANSI Escape Sequences for terminal colors
  static const _reset = '\x1B[0m'; // Resets the color to default
  static const _red = '\x1B[31m'; // Errors and critical failures
  static const _green = '\x1B[32m'; // Success and completed operations
  static const _yellow = '\x1B[33m'; // Warnings and non-critical alerts
  static const _cyan = '\x1B[36m'; // Info, tags, and system messages
  static const _magenta = '\x1B[35m'; // SQL executor
  static const _gold = '\x1B[93m'; // Hints color

  /// Wraps the string in ANSI red color.
  String get red => '$_red$this$_reset';

  /// Wraps the string in ANSI green color.
  String get green => '$_green$this$_reset';

  /// Wraps the string in ANSI yellow color.
  String get yellow => '$_yellow$this$_reset';

  /// Wraps the string in ANSI cyan color.
  String get cyan => '$_cyan$this$_reset';

  /// Wraps the string in ANSI magenta color.
  String get magenta => '$_magenta$this$_reset';

  /// Wraps the string in ANSI gold color.
  String get gold => '$_gold$this$_reset';
}

/// Adds helper methods to [DateTime] specifically for log formatting
/// and diagnostic output within the `fluent_sqflite` library.
extension FluentDateTimeX on DateTime {
  /// Returns a compact, fixed-width timestamp string in the format "HH:mm:ss.mmm".
  ///
  /// This format is used throughout the library for telemetry and logging
  /// to ensure consistent and parseable timestamps, avoiding the variability
  /// of [DateTime.toIso8601String()] when microsecond precision varies.
  ///
  /// Example: "05:46:24.123"
  String get toFluentTimestamp =>
      "${hour.toString().padLeft(2, '0')}:"
      "${minute.toString().padLeft(2, '0')}:"
      "${second.toString().padLeft(2, '0')}."
      "${millisecond.toString().padLeft(3, '0')}";
}

/// Adds ergonomic utility methods to [ExecutionPolicy] to simplify
/// database task configuration within the `fluent_sqflite` library.
extension ExecutionPolicyUtils on ExecutionPolicy {
  /// Returns a new [ExecutionPolicy] with the [tag] applied if provided,
  /// otherwise returns the original policy.
  ///
  /// This method is primarily used in the [FluentDb] static API to conditionally
  /// attach custom metadata tags to tasks, which are later used for event filtering
  /// and logging within the engine's reactive stream.
  ///
  /// **Example:**
  /// ```dart
  /// // Only applies the tag 'cleanup_task' if it is not null
  /// final ExecutionPolicy policy = const ExecutionPolicy().withTag(tag);
  /// await FluentDb.clearTable<User>(policy: policy);
  /// ```
  ExecutionPolicy withTag(Object? tag) {
    if (tag == null) return this;
    return copyWith(customTag: tag);
  }
}

/// Adds functional classification utilities to [FluentDbAction] to streamline
/// database task routing and reactive stream management.
extension FluentDbActionX on FluentDbAction {
  /// Defines the subset of operations that perform data mutations within the database.
  ///
  /// This set is used by the [FluentEngine] to determine if a task requires
  /// transactional integrity and post-execution persistence verification.
  static const Set<FluentDbAction> _writeActions = {
    FluentDbAction.save,
    FluentDbAction.update,
    FluentDbAction.updateSingleField,
    FluentDbAction.updateMultipleFields,
    FluentDbAction.updateWithRelations,
    FluentDbAction.updateAll,
    FluentDbAction.updateMultipleFieldsByIds,
    FluentDbAction.delete,
    FluentDbAction.deleteBy,
    FluentDbAction.deleteItemsByIds,
    FluentDbAction.restore,
    FluentDbAction.restoreItemsByIds,
    FluentDbAction.hardDelete,
    FluentDbAction.hardDeleteBy,
    FluentDbAction.hardDeleteItemsByIds,
    FluentDbAction.purgeSoftDeleted,
    FluentDbAction.forcePurgeSoftDeleted,
  };

  /// Defines the set of operations that trigger database stream notifications.
  ///
  /// This includes all mutation operations as well as administrative tasks
  /// that affect the overall state of the table (e.g., clearing expired items),
  /// ensuring that observers receive timely updates regarding the data layer.
  static const Set<FluentDbAction> _streamActions = {..._writeActions, FluentDbAction.clearExpired, FluentDbAction.clearTable};

  /// Returns `true` if the current operation modifies the underlying database state.
  bool get isWriteOp => _writeActions.contains(this);

  /// Returns `true` if the current operation necessitates an update to reactive
  /// stream controllers.
  bool get isStreamOp => _streamActions.contains(this);
}
