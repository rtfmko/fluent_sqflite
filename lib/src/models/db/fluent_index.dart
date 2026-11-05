// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/fluent_identifier.dart';

/// An index on one or more columns, declared on the model through [FluentStorable.indexes].
///
/// Indexes are created on new tables and added to existing databases on the next start; a changed index is
/// recreated, a removed one dropped (only indexes the model declares; other indexes of the app are never touched).
/// An index that cannot be created (e.g. duplicates for a unique one) is skipped with a warning.
///
/// ```dart
/// @override
/// List<FluentIndex> get indexes => [
///   FluentIndex(['last_name', 'first_name']),          // speeds up search/sort by full name
///   FluentIndex.unique(['email']),                      // no two users with the same email
///   FluentIndex(['created_at'], where: 'deleted_at IS NULL'), // partial index
///   FluentIndex.fullText(['title', 'body']),            // full-text search: FluentFilter.search / provider.search
/// ];
/// ```
class FluentIndex {
  /// Creates an index on [columns].
  const FluentIndex(this.columns, {this.unique = false, this.name, this.where}) : fullText = false;

  /// Creates a unique index: the combination of [columns] must be unique across rows.
  const FluentIndex.unique(this.columns, {this.name, this.where}) : unique = true, fullText = false;

  /// Creates the full-text index of the table over the text [columns] (one per table; several are merged).
  ///
  /// The library keeps a SQLite FTS table (`__fluent_fts_<table>`, FTS5, or FTS4 where FTS5 is missing) in step
  /// with every write through triggers and fills it once from existing rows. Words are matched case-insensitively,
  /// diacritics removed, in any language (no stemming: "cats" does not find "cat"). Needs a table with a rowid
  /// (not `withoutRowId`). See `FluentFilter.search` and `FluentProvider.search`.
  const FluentIndex.fullText(this.columns, {this.name}) : unique = false, where = null, fullText = true;

  /// Indexed columns, in order (order matters for multi-column indexes).
  final List<String> columns;

  /// Whether duplicate value combinations are rejected.
  final bool unique;

  /// Custom index name. Defaults to `idx_<table>_<columns>` (`uidx_` for unique indexes).
  final String? name;

  /// Optional raw SQL condition for a partial index (`WHERE` clause without the keyword).
  final String? where;

  /// Whether this is the full-text index ([FluentIndex.fullText]), kept in an FTS table instead of a SQLite index.
  final bool fullText;

  /// The index name used for [table].
  String nameFor(String table) => name ?? '${unique ? 'uidx' : 'idx'}_${table}_${columns.join('_')}';

  /// The `CREATE INDEX` statement for [table].
  String createSql(String table) {
    final String cols = columns.map((c) => c.quotedIdentifier).join(', ');
    final String partial = where == null || where!.trim().isEmpty ? '' : ' WHERE ${where!.trim()}';
    return 'CREATE ${unique ? 'UNIQUE ' : ''}INDEX IF NOT EXISTS ${nameFor(table).quotedIdentifier} ON ${table.quotedIdentifier} ($cols)$partial;';
  }

  @override
  bool operator ==(Object other) =>
      other is FluentIndex && other.unique == unique && other.fullText == fullText && other.name == name && other.where == where && _listEquals(other.columns, columns);

  @override
  int get hashCode => Object.hash(unique, fullText, name, where, Object.hashAll(columns));

  @override
  String toString() => 'FluentIndex${fullText ? '.fullText' : ''}(${columns.join(', ')}${unique ? ', unique' : ''}${where != null ? ', where: $where' : ''})';
}

/// A table-level `CHECK` constraint, declared on the model through [FluentStorable.checks].
///
/// ```dart
/// @override
/// List<FluentCheck> get checks => [FluentCheck('end_date >= start_date', name: 'valid_period')];
/// ```
///
/// Checks are part of `CREATE TABLE`: a new or changed check rebuilds an existing table on the next start; rows it
/// rejects are moved to a quarantine table (`__fluent_rejected_<table>_r<revision>`), never deleted.
class FluentCheck {
  /// Creates a check from a raw SQL boolean [expression].
  const FluentCheck(this.expression, {this.name});

  /// Raw SQL boolean expression.
  final String expression;

  /// Optional constraint name (shown by SQLite when the check fails).
  final String? name;

  /// The constraint clause for `CREATE TABLE`.
  String get sql => '${name == null ? '' : 'CONSTRAINT ${name!.quotedIdentifier} '}CHECK ($expression)';

  @override
  bool operator ==(Object other) => other is FluentCheck && other.expression == expression && other.name == name;

  @override
  int get hashCode => Object.hash(expression, name);

  @override
  String toString() => 'FluentCheck($expression)';
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
