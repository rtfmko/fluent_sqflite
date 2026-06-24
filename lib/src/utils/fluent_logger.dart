// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_print

import '../interfaces/interfaces.dart';
import 'utils.dart';

/// A concrete implementation of [FluentTelemetry] that provides a fluent,
/// chainable interface for database diagnostic reporting.
///
/// This class orchestrates the delegation of log events to the defined
/// callback hooks, providing a centralized point for filtering,
/// formatting, and routing all database engine telemetry.
class FluentLogger extends FluentTelemetry {
  @override
  final bool isLogOn;

  @override
  final bool isDebug;

  @override
  final void Function(String msg, FluentLogLevel level, {String? tag})? onAll;
  @override
  final void Function(String msg)? onInfo;
  @override
  final void Function(String query, [List<Object?>? arguments])? onSql;
  @override
  final void Function(String msg)? onDebug;
  @override
  final void Function(String msg)? onWarning;
  @override
  final void Function(String message, Object e, StackTrace? s)? onError;

  /// Whether to use ANSI escape codes for colored output.
  final bool useColors;

  /// A prefix for all log messages to distinguish them in the console (e.g., 'FluentSQFLite').
  final String tag;

  /// Creates a [FluentLogger] instance with customizable diagnostic behaviors.
  ///
  /// This constructor allows for granular control over the logging pipeline.
  /// By injecting specific callbacks, you can redirect database logs to any
  /// platform-specific logging service (e.g., Firebase, Sentry, or console output).
  ///
  /// [isLogOn]: Master switch to enable or disable all database logging.
  /// [isDebug]: Toggles the visibility of verbose debug and SQL-level logs.
  /// [useColors]: Enables ANSI color-coding for console output (if supported).
  /// [tag]: The default identifier attached to log entries for filtering.
  /// [onAll]: A global interception hook for every log entry.
  /// [onInfo], [onDebug], [onWarning], [onError], [onSql]: Specific handlers
  /// for different severity levels and diagnostic contexts.
  FluentLogger({this.isLogOn = true, this.isDebug = false, this.useColors = true, this.tag = 'FluentSQFLite', this.onAll, this.onInfo, this.onDebug, this.onWarning, this.onError, this.onSql});

  @override
  void all(String message, FluentLogLevel level, {String? customTag, String? hint, Map<String, dynamic>? context}) {
    if (!isLogOn) return;

    final StringBuffer buffer = StringBuffer();

    if (useColors) {
      buffer.write(_applyColor(message, level));
    } else {
      buffer.write(_applyEmoji(level) + message);
    }

    if (context != null && context.isNotEmpty) {
      buffer.write(' 📦 $context');
    }

    if (hint != null) {
      buffer.writeln();
      final String hintRow = '   💡 HINT: $hint';
      buffer.write(useColors ? hintRow.gold : hintRow);
    }

    final String finalMessage = buffer.toString();
    final String timestamp = DateTime.now().toFluentTimestamp;

    final String activeTag = customTag ?? tag;
    final String formattedTags = activeTag.split(':').map((t) => '[$t]').join(' ');

    final String finalOutput = '$timestamp $formattedTags $finalMessage';

    if (onAll != null) {
      onAll!(finalOutput, level, tag: activeTag);
    } else {
      print(finalOutput);
    }
  }

  /// Maps [FluentLogLevel] to specific colors.
  String _applyColor(String msg, FluentLogLevel level) => switch (level) {
    FluentLogLevel.info => '💡 $msg'.green,
    FluentLogLevel.debug => '🔍 $msg'.cyan,
    FluentLogLevel.sql => '🔨 $msg'.magenta,
    FluentLogLevel.warning => '⚠️ $msg'.yellow,
    FluentLogLevel.error => '❌ $msg'.red,
  };

  /// Fallback emojis if colors are disabled.
  String _applyEmoji(FluentLogLevel level) => switch (level) {
    FluentLogLevel.info => '💡 ',
    FluentLogLevel.debug => '🔍 ',
    FluentLogLevel.sql => '🔨 ',
    FluentLogLevel.warning => '⚠️ ',
    FluentLogLevel.error => '❌ ',
  };
}
