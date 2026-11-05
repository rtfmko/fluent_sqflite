// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

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
/// * `null` → `NULL`, `bool` → `1`/`0`, numbers as is,
/// * [String] → single-quoted with quotes escaped,
/// * [DateTime] → milliseconds since epoch (the same storage the library uses for dates),
/// * [Enum] → its name, [FluentSqlExpression] → `(expression)`.
String fluentSqlLiteral(Object? value) {
  if (value == null) return 'NULL';
  if (value is FluentSqlExpression) return '(${value.sql})';
  if (value is bool) return value ? '1' : '0';
  if (value is num) return value.toString();
  if (value is DateTime) return value.millisecondsSinceEpoch.toString();
  if (value is Enum) return _quoteText(value.name);
  return _quoteText(value.toString());
}

String _quoteText(String text) => "'${text.replaceAll("'", "''")}'";
