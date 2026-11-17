// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:typed_data';

/// A raw SQL expression, used where a plain value would otherwise be escaped.
///
/// Column defaults are written as ordinary Dart values and escaped automatically:
/// ```dart
/// FluentDbColumn.text('status', defaultValue: 'active'); // DEFAULT 'active'
/// ```
/// Use [FluentSqlExpression] when the default must be computed by SQLite:
/// ```dart
/// FluentDbColumn(name: 'created', type: FluentDbDataType.text, defaultValue: FluentSqlExpression.currentTimestamp);
/// ```
///
/// Note: SQLite only allows constant defaults when a column is added to an existing table,
/// so expressions like `CURRENT_TIMESTAMP` work for new tables only.
class FluentSqlExpression {
  /// Creates an expression from raw SQL. The text is inserted into the statement as is.
  const FluentSqlExpression(this.sql);

  /// The raw SQL text.
  final String sql;

  /// `CURRENT_TIMESTAMP` — UTC date and time as text (`YYYY-MM-DD HH:MM:SS`).
  static const FluentSqlExpression currentTimestamp = FluentSqlExpression('CURRENT_TIMESTAMP');

  /// `CURRENT_DATE` — UTC date as text (`YYYY-MM-DD`).
  static const FluentSqlExpression currentDate = FluentSqlExpression('CURRENT_DATE');

  @override
  bool operator ==(Object other) => other is FluentSqlExpression && other.sql == sql;

  @override
  int get hashCode => sql.hashCode;

  @override
  String toString() => 'FluentSqlExpression($sql)';
}

/// Renders a Dart value as an SQL literal for DDL (column defaults).
///
/// * `null` → `NULL`, `bool` → `1`/`0`, numbers as is (`Infinity` as `9e999`, `NaN` as `NULL`: SQLite has no `NaN`),
/// * [Uint8List] → a blob literal (`X'0aff'`),
/// * [String] → single-quoted with quotes escaped,
/// * [DateTime] → milliseconds since epoch (the same storage the library uses for dates),
/// * [Enum] → its name, [FluentSqlExpression] → `(expression)`.
String fluentSqlLiteral(Object? value) {
  if (value == null) return 'NULL';
  if (value is FluentSqlExpression) return '(${value.sql})';
  if (value is bool) return value ? '1' : '0';
  if (value is double && !value.isFinite) return value.isNaN ? 'NULL' : (value.isNegative ? '-9e999' : '9e999');
  if (value is num) return value.toString();
  if (value is Uint8List) return "X'${[for (final int b in value) b.toRadixString(16).padLeft(2, '0')].join()}'";
  if (value is DateTime) return value.millisecondsSinceEpoch.toString();
  if (value is Enum) return _quoteText(value.name);
  return _quoteText(value.toString());
}

/// [value] as ISO-8601 text with a fixed fraction of six digits (`2026-01-01T12:00:00.123000Z`): text compares and
/// sorts like time only when every value has the same length (`toIso8601String` prints three digits, or six when
/// there are microseconds, so `.123Z` sorted after `.123456Z`).
String fluentIsoText(DateTime value) {
  final String text = value.toIso8601String();
  final int dot = text.indexOf('.');
  if (dot < 0) return text;
  int end = dot + 1;
  while (end < text.length && text.codeUnitAt(end) >= 0x30 && text.codeUnitAt(end) <= 0x39) {
    end++;
  }
  final int digits = end - dot - 1;
  return digits >= 6 ? text : '${text.substring(0, end)}${'0' * (6 - digits)}${text.substring(end)}';
}

String _quoteText(String text) => "'${text.replaceAll("'", "''")}'";
