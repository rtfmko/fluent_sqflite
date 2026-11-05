// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

final RegExp _plainIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// SQL identifier helpers used by every statement the library generates.
///
/// All table, column and index names are quoted, so names that collide with SQL keywords
/// (`order`, `group`, `index`, ...) work without any extra effort from the user.
///
/// ```dart
/// 'order'.quotedIdentifier; // "order"
/// ```
extension FluentIdentifier on String {
  /// The identifier wrapped in double quotes, with embedded quotes escaped.
  String get quotedIdentifier => '"${replaceAll('"', '""')}"';

  /// Whether this string is a plain identifier (letters, digits, underscore; not starting with a digit).
  ///
  /// Expressions such as `lower(name)` or `t.id` are not plain identifiers and are left untouched
  /// by [quotedIfPlain].
  bool get isPlainIdentifier => _plainIdentifier.hasMatch(this);

  /// Quotes the string only if it is a plain identifier; expressions are returned as is.
  String get quotedIfPlain => isPlainIdentifier ? quotedIdentifier : this;
}

/// Quoted names for sqflite's `insert` / `update` / `query` / `delete` helpers: sqflite quotes only SQL keywords, so a
/// name with a quote, a space or a dash breaks its statements. A quoted name passes through unchanged, and SQLite
/// reports result columns without the quotes.
///
/// ```dart
/// ex.insert(tableName.quotedIdentifier, row.quotedKeys);
/// ```
extension FluentQuotedRow on Map<String, Object?> {
  /// This row with every column name quoted.
  Map<String, Object?> get quotedKeys => {for (final MapEntry<String, Object?> e in entries) e.key.quotedIdentifier: e.value};
}

/// Quoted column lists for sqflite's `query(columns:)` (see [FluentQuotedRow]).
extension FluentQuotedColumns on Iterable<String> {
  /// Every name of this list quoted.
  List<String> get quotedAll => [for (final String c in this) c.quotedIdentifier];
}
