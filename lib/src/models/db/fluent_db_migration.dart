// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:sqflite/sqflite.dart';

/// A one-time data step of a table, declared on the model through `FluentStorable.migrations`.
///
/// Schema changes need **no migration at all**: the library compares the model with the schema it applied
/// last time and adds columns, archives removed ones, rebuilds tables and indexes by itself. A renamed column
/// says `oldName` on its own column in the model.
///
/// **Steps (need a [version] or an [id]):** run once per database, in the order they are declared,
/// after the table structure is synchronized, inside the schema transaction:
/// * [rawSql] — statements for data fixes or anything the model cannot express,
/// * [dropColumns] — remove columns for good: the live column and its archived copies, with their data,
/// * [restoreColumns] — bring archived data back: `{'old name': 'column in the model'}`,
/// * [onMigrate] — custom Dart code, e.g. to transform existing rows.
///
/// When a table is created from scratch, all steps are only marked as applied (there is no old data); a step that
/// inserts rows (seed data) therefore never runs on a new install — create such rows in code instead.
///
/// ```dart
/// @override
/// List<FluentDbMigration> get migrations => [
///   FluentDbMigration(version: 2, rawSql: ["UPDATE users SET full_name = trim(full_name)"]),
///   FluentDbMigration(id: 'drop_legacy_flags', dropColumns: ['legacy_flags']),
///   FluentDbMigration(version: 4, restoreColumns: {'nickname': 'display_name'}),
/// ];
/// ```
class FluentDbMigration {
  /// Creates a migration.
  const FluentDbMigration({
    this.version,
    this.id,
    this.rawSql = const [],
    this.dropColumns = const [],
    this.restoreColumns = const {},
    this.onMigrate,
  });

  /// Numeric label of the one-time steps. A step needs a [version] or an [id].
  final int? version;

  /// Text label of the one-time steps, e.g. `'fix_names_2026_10'`.
  final String? id;

  /// Raw SQL statements executed once.
  final List<String> rawSql;

  /// Columns removed once together with their data (live column and archived copies).
  final List<String> dropColumns;

  /// Archived columns restored once: name the column had in the model → target column of the model (its newest
  /// archive is copied where it holds a value).
  final Map<String, String> restoreColumns;

  /// Custom code executed once, inside the schema transaction.
  ///
  /// Use [txn] for SQL. Provider calls (`save`, `findAll`, ...) also work here: they join the schema transaction,
  /// but see the tables of this database only as far as they were synchronized before this table.
  final Future<void> Function(Transaction txn)? onMigrate;

  /// Whether this migration has one-time steps.
  bool get hasSteps => rawSql.isNotEmpty || dropColumns.isNotEmpty || restoreColumns.isNotEmpty || onMigrate != null;

  /// The label that marks the steps as applied (`id`, or `v<version>`), or `null` when none is set.
  String? get label => id ?? (version == null ? null : 'v$version');

  /// Fingerprint of the steps' content, used to warn when an applied step is edited afterwards.
  ///
  /// It covers [rawSql], [dropColumns], [restoreColumns] and whether [onMigrate] is set, not the body of [onMigrate]:
  /// a running app cannot read its own code. Changed code needs a new step (new `id` / `version`), never an edit.
  String get contentHash {
    final String content = [
      ...rawSql,
      '#drop',
      ...dropColumns,
      '#restore',
      for (final MapEntry<String, String> e in restoreColumns.entries) '${e.key}>${e.value}',
      '#code:${onMigrate != null}',
    ].join('\u0001');
    // FNV-1a 32-bit: stable across runs and Dart versions (String.hashCode is not guaranteed to be).
    int hash = 0x811c9dc5;
    for (final int unit in content.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  String toString() {
    final List<String> parts = [
      if (label != null) 'label: $label',
      if (rawSql.isNotEmpty) 'rawSql: ${rawSql.length}',
      if (dropColumns.isNotEmpty) 'dropColumns: $dropColumns',
      if (restoreColumns.isNotEmpty) 'restoreColumns: $restoreColumns',
      if (onMigrate != null) 'onMigrate: yes',
    ];
    return 'FluentDbMigration{${parts.join(', ')}}';
  }
}
