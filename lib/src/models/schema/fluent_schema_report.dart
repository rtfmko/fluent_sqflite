// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:convert';

import '../../core/fluent_sqlite_internal.dart';

/// What happens to a column that disappeared from the model.
enum FluentColumnRemoval {
  /// Keep the data: the column is renamed to `__fluent_removed_<name>_r<revision>`, loses its constraints and is
  /// never read or written again. It can be restored with `FluentDbMigration(restoreColumns: ...)` and is purged
  /// automatically after `FluentGroup.archiveRetention`.
  archive,

  /// Delete the column together with its data.
  drop,
}

/// A column that was removed from the model and kept with its data.
class FluentArchivedColumn {
  /// Creates an archive record.
  const FluentArchivedColumn({required this.original, required this.archivedAs, required this.type, required this.revision, required this.removedAt});

  /// Restores a record from [FluentArchivedColumn.toJson].
  factory FluentArchivedColumn.fromJson(Map<String, dynamic> json) => FluentArchivedColumn(
    original: json['original'] as String,
    archivedAs: json['archivedAs'] as String,
    type: json['type'] as String? ?? '',
    revision: json['revision'] as int? ?? 0,
    // Without a stored time the retention starts now (epoch 0 would purge the data at the next start).
    removedAt: json['removedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(json['removedAt'] as int) : FluentClock.now(),
  );

  /// The column name in the model before it was removed.
  final String original;

  /// The physical column that holds the data now.
  final String archivedAs;

  /// Declared SQLite type of the data.
  final String type;

  /// Table revision in which the column was archived.
  final int revision;

  /// When the column was archived.
  final DateTime removedAt;

  /// JSON form stored in the schema snapshot.
  Map<String, dynamic> toJson() => {'original': original, 'archivedAs': archivedAs, 'type': type, 'revision': revision, 'removedAt': removedAt.millisecondsSinceEpoch};

  @override
  String toString() => '$original → $archivedAs ($type, r$revision, ${removedAt.toIso8601String()})';
}

/// The schema state the library last applied to one table (stored in `__fluent_schema`).
class FluentTableSnapshot {
  /// Creates a snapshot.
  FluentTableSnapshot({
    required this.table,
    this.revision = 0,
    Map<String, String>? columns,
    List<String>? key,
    List<String>? checks,
    this.withoutRowId = false,
    Map<String, String>? indexes,
    List<FluentArchivedColumn>? archived,
    Set<String>? pendingNotNull,
    Map<String, String>? steps,
    Map<String, String>? relations,
    Map<String, String>? swaps,
    this.fingerprint,
    this.tableSql,
  }) : columns = columns ?? {},
       relations = relations ?? {},
       swaps = swaps ?? {},
       key = key ?? [],
       checks = checks ?? [],
       indexes = indexes ?? {},
       archived = archived ?? [],
       pendingNotNull = pendingNotNull ?? {},
       steps = steps ?? {};

  /// Restores a snapshot from its stored JSON.
  factory FluentTableSnapshot.fromJson(String table, int revision, String raw) {
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    return FluentTableSnapshot(
      table: table,
      revision: revision,
      columns: (json['columns'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      key: (json['key'] as List<dynamic>? ?? const []).cast<String>(),
      checks: (json['checks'] as List<dynamic>? ?? const []).cast<String>(),
      withoutRowId: json['withoutRowId'] as bool? ?? false,
      indexes: (json['indexes'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      archived: [for (final dynamic a in json['archived'] as List<dynamic>? ?? const []) FluentArchivedColumn.fromJson(a as Map<String, dynamic>)],
      pendingNotNull: (json['pendingNotNull'] as List<dynamic>? ?? const []).cast<String>().toSet(),
      steps: (json['steps'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      relations: (json['relations'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      swaps: (json['swaps'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v as String)),
      fingerprint: json['fingerprint'] as String?,
      tableSql: json['tableSql'] as String?,
    );
  }

  /// Table name.
  final String table;

  /// Increases with every applied change of the table.
  int revision;

  /// Column name → applied SQL definition, in table order.
  final Map<String, String> columns;

  /// Primary key columns.
  final List<String> key;

  /// Table-level CHECK clauses.
  final List<String> checks;

  /// Whether the table is `WITHOUT ROWID`.
  bool withoutRowId;

  /// Index name → normalized `CREATE INDEX` statement (indexes created by the library only).
  final Map<String, String> indexes;

  /// Columns removed from the model and kept with their data.
  final List<FluentArchivedColumn> archived;

  /// NOT NULL columns that are temporarily nullable because existing rows have no value yet.
  final Set<String> pendingNotNull;

  /// Applied one-time migration steps: label (`v3` / id) → content hash.
  final Map<String, String> steps;

  /// How each relation of the table stored its data (relation name → storage), to keep the data when a relation
  /// changes its kind between versions.
  final Map<String, String> relations;

  /// Renames that exchange names between columns of the model (new name → `oldName`) already applied: both names are
  /// live columns afterwards, so only this record tells a second start that the swap ran (a swap must not run twice).
  final Map<String, String> swaps;

  /// Fingerprint of everything the last full sync of this table was based on (model, steps, relations, settings);
  /// while it matches, a start skips the schema sync.
  String? fingerprint;

  /// Fingerprint of the table's `CREATE TABLE` statement after the last full sync: a table changed outside the library
  /// is synchronized again on the next start.
  String? tableSql;

  /// JSON form stored in `__fluent_schema`.
  String toJson() => jsonEncode({
    'columns': columns,
    'key': key,
    'checks': checks,
    'withoutRowId': withoutRowId,
    'indexes': indexes,
    'archived': [for (final FluentArchivedColumn a in archived) a.toJson()],
    'pendingNotNull': pendingNotNull.toList(),
    'steps': steps,
    if (relations.isNotEmpty) 'relations': relations,
    if (swaps.isNotEmpty) 'swaps': swaps,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (tableSql != null) 'tableSql': tableSql,
  });

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('$table (revision $revision)\n');
    sb.writeln('  columns: ${columns.keys.join(', ')}');
    sb.writeln('  key: ${key.join(', ')}${withoutRowId ? ' (WITHOUT ROWID)' : ''}');
    if (indexes.isNotEmpty) sb.writeln('  indexes: ${indexes.keys.join(', ')}');
    if (archived.isNotEmpty) sb.writeln('  archived: ${archived.join('; ')}');
    if (pendingNotNull.isNotEmpty) sb.writeln('  pending NOT NULL: ${pendingNotNull.join(', ')}');
    if (steps.isNotEmpty) sb.writeln('  applied steps: ${steps.keys.join(', ')}');
    return sb.toString();
  }
}

/// One entry of `__fluent_schema_history`: a schema change applied to a table, or a failed attempt.
class FluentSchemaHistoryEntry {
  /// Creates an entry.
  const FluentSchemaHistoryEntry({
    required this.table,
    required this.fromRevision,
    required this.toRevision,
    required this.changes,
    required this.success,
    required this.appliedAt,
    this.error,
    this.durationMs = 0,
  });

  /// Table name (`*` when the failure could not be attributed to one table).
  final String table;

  /// Revision before the change.
  final int fromRevision;

  /// Revision after the change (equal to [fromRevision] for a failure).
  final int toRevision;

  /// Human-readable list of what was done, e.g. `added column "title"`.
  final List<String> changes;

  /// Whether the change was applied.
  final bool success;

  /// The error of a failed attempt.
  final String? error;

  /// Duration of the table sync in milliseconds.
  final int durationMs;

  /// When it happened.
  final DateTime appliedAt;

  @override
  String toString() =>
      '${appliedAt.toIso8601String()} $table r$fromRevision→r$toRevision ${success ? 'OK' : 'FAILED'} (${durationMs}ms)'
      '${changes.isEmpty ? '' : '\n    - ${changes.join('\n    - ')}'}'
      '${error == null ? '' : '\n    error: $error'}';
}

/// Schema state and migration history of one database (`FluentDb.schemaReport()`).
class FluentSchemaReport {
  /// Creates a report.
  const FluentSchemaReport({required this.database, required this.tables, required this.history});

  /// Database name.
  final String database;

  /// Applied state of every table.
  final List<FluentTableSnapshot> tables;

  /// Migration history, newest first.
  final List<FluentSchemaHistoryEntry> history;

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('=== Schema of "$database" ===\n');
    tables.forEach(sb.write);
    sb.writeln('--- history (newest first) ---');
    history.forEach(sb.writeln);
    return sb.toString();
  }
}
