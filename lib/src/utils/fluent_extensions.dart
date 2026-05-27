// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

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
  String get toFluentTimestamp {
    return "${hour.toString().padLeft(2, '0')}:"
        "${minute.toString().padLeft(2, '0')}:"
        "${second.toString().padLeft(2, '0')}."
        "${millisecond.toString().padLeft(3, '0')}";
  }
}
