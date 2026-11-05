// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../core/fluent_sqlite_internal.dart';
import '../exceptions/exceptions.dart';
import '../interfaces/interfaces.dart';
import '../utils/utils.dart';
import 'fluent_issue.dart';

/// Stands in for a foreign error (a raw SQLite error, say) in [FluentLogRecord.error] and [FluentIssue.error] while
/// `showSqlArguments` is off: the original text can carry SQL arguments, so only its [type] and its redacted [message]
/// travel on. With `showSqlArguments` on the original error is delivered as it is.
@immutable
class FluentRedactedError implements Exception {
  /// Creates the stand-in for an error of runtime type [type] whose text, with SQL arguments and paths hidden, is
  /// [message].
  const FluentRedactedError({required this.type, required this.message});

  /// The runtime type of the original error, e.g. `SqfliteFfiException`.
  final String type;

  /// The text of the original error with SQL arguments and database paths hidden.
  final String message;

  @override
  String toString() => '$type: $message';
}

/// One log entry of fluent_sqflite, as delivered to `FluentDb.setupLogging(onRecord: ...)`.
///
/// [error] is the original error object only when `showSqlArguments` is on (a [FluentException] is always delivered as
/// it is: its texts are redacted); otherwise a foreign error arrives as a [FluentRedactedError], so crash reporters
/// never receive SQL arguments.
///
/// ```dart
/// FluentDb.setupLogging(onRecord: (r) {
///   if (r.level == FluentLogLevel.error) Crashlytics.instance.recordError(r.error ?? r.message, r.stackTrace);
/// });
/// ```
@immutable
class FluentLogRecord {
  /// Creates a log entry.
  const FluentLogRecord({required this.level, required this.message, required this.time, this.tag, this.hint, this.context, this.error, this.stackTrace, this.issue});

  /// Severity.
  final FluentLogLevel level;

  /// What happened.
  final String message;

  /// When it was logged.
  final DateTime time;

  /// Where it happened, e.g. `users:write` or `FluentEngine:dispatch`.
  final String? tag;

  /// How to fix it.
  final String? hint;

  /// Extra values (table, action, counts ...).
  final Map<String, dynamic>? context;

  /// The error, for warnings and errors caused by one.
  final Object? error;

  /// The stack trace of [error].
  final StackTrace? stackTrace;

  /// The issue this record reports (hints, automatic changes, warnings and errors of the library), if one.
  final FluentIssue? issue;

  /// The error code, when the record is about a [FluentException].
  FluentErrorCode? get code => switch (error) {
    final FluentException e => e.code,
    _ => null,
  };

  /// Formats the record as console text: time, tags, message, context, hint and cause.
  ///
  /// [colors] adds ANSI colors; [redact] is applied to the message, context, hint and error texts (default: hides
  /// SQL arguments and paths unless `showSqlArguments` is on); [stackLines] limits the printed stack trace of errors
  /// (0: none).
  String format({bool colors = false, String Function(String text)? redact, int stackLines = 8}) {
    final String Function(String) clean = redact ?? FluentLog.redact;
    final String? hint = this.hint ?? switch (error) {
      final FluentException e => e.hint,
      _ => null,
    };
    final StringBuffer sb = StringBuffer(time.toFluentTimestamp);
    if (tag != null) sb.write(' ${tag!.split(':').map((t) => '[$t]').join(' ')}');
    final FluentErrorCode? errorCode = code;
    final String text = '${_icon(level)} ${errorCode == null ? '' : '${errorCode.name}: '}${clean(message)}';
    sb.write(' ${colors ? _color(level, text) : text}');
    if (context != null && context!.isNotEmpty) sb.write(' 📦 ${clean('$context')}');
    final FluentIssue? i = issue;
    if (i?.details != null) sb.write('\n   ${i!.details!.replaceAll('\n', '\n   ')}');
    if (hint != null) {
      final String row = '   💡 HINT: ${clean(hint).replaceAll('\n', '\n   ')}';
      sb.write('\n${colors ? row.gold : row}');
    }
    if (i?.code != null) sb.write('\n${i!.code!.split('\n').map((l) => '     $l').join('\n')}');
    if (i != null) sb.write("\n   (${i.type.name} ${i.key}; mute: FluentDb.setupLogging(mute: {'${i.kind.name}:*'}))");
    final Object? e = error;
    if (e != null && e is! FluentException) {
      sb.write('\n   ⛔ CAUSE: ${clean('$e')}');
    } else if (e is FluentException && e.cause != null) {
      sb.write('\n   ⛔ CAUSE: ${clean('${e.cause}')}');
    }
    if (level == FluentLogLevel.error && stackTrace != null && stackLines > 0) {
      final List<String> lines = stackTrace.toString().trimRight().split('\n');
      sb.write('\n${lines.take(stackLines).map((l) => '   $l').join('\n')}');
      if (lines.length > stackLines) sb.write('\n   ... ${lines.length - stackLines} more');
    }
    return sb.toString();
  }

  @override
  String toString() => format();

  static String _icon(FluentLogLevel level) => switch (level) {
    FluentLogLevel.sql => '🔨',
    FluentLogLevel.debug => '🔍',
    FluentLogLevel.info => 'ℹ️',
    FluentLogLevel.hint => '💡',
    FluentLogLevel.autoFix => '🔧',
    FluentLogLevel.warning => '⚠️',
    FluentLogLevel.error => '❌',
  };

  static String _color(FluentLogLevel level, String text) => switch (level) {
    FluentLogLevel.sql => text.magenta,
    FluentLogLevel.debug => text.cyan,
    FluentLogLevel.info => text.green,
    FluentLogLevel.hint => text.gold,
    FluentLogLevel.autoFix => text.cyan,
    FluentLogLevel.warning => text.yellow,
    FluentLogLevel.error => text.red,
  };
}
