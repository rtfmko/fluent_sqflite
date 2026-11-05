// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../interfaces/fluent_exception.dart';
import '../fluent_issue.dart';

/// What a [FluentSchemaChange] does.
enum FluentSchemaChangeKind {
  /// A table is created.
  createTable,

  /// A column is added.
  addColumn,

  /// A column is renamed (`oldName`, or a 1.x name of a library column), its data kept.
  renameColumn,

  /// A table stored under its 1.x name (a name derived from a type name) is renamed to the current one, its data
  /// kept; also the polymorphic type values naming it.
  renameTable,

  /// The definition of a column changes (type, constraint, default, NOT NULL enforced).
  changeColumn,

  /// A column removed from the model is kept with its data as `__fluent_removed_<name>_r<rev>`.
  archiveColumn,

  /// A column is deleted with its data (`dropColumns`, `FluentColumnRemoval.drop`).
  dropColumn,

  /// An archived column older than the retention is deleted with its data.
  purgeArchive,

  /// Archived data is copied back into a column (`restoreColumns`).
  restoreColumn,

  /// The table is rebuilt (copied into a new table) with its data, rowids, `AUTOINCREMENT` counter, triggers, views
  /// and the app's own indexes.
  rebuildTable,

  /// The primary key changes.
  primaryKey,

  /// Table constraints (`CHECK`) or `WITHOUT ROWID` change.
  constraints,

  /// An index is created or recreated.
  createIndex,

  /// An index of the library is dropped.
  dropIndex,

  /// Rows a new constraint rejects are moved to a quarantine table (kept, not deleted).
  quarantineRows,

  /// A one-time migration step runs (`rawSql`, `onMigrate`).
  runStep,

  /// A link table of a many-to-many relation is created or rebuilt.
  linkTable,

  /// Relation data is copied to a new place (a relation changed its kind).
  moveRelationData,

  /// A full-text index is created, rebuilt or removed.
  fullText,

  /// A view or trigger that used the table could not be recreated after a rebuild (it used a removed or renamed
  /// column): it is gone and must be recreated by the app; counted as data loss.
  viewOrTriggerLost,
}

/// One change the schema sync applies (or would apply, see `FluentDb.planMigrations`).
class FluentSchemaChange {
  /// Creates a change.
  const FluentSchemaChange({required this.kind, required this.table, required this.description, this.subject});

  /// What the change does.
  final FluentSchemaChangeKind kind;

  /// The table it changes.
  final String table;

  /// The column, index or step it is about, when there is one.
  final String? subject;

  /// Readable description, as written to the schema history (`added column "title"`).
  final String description;

  /// Whether data is deleted for good ([FluentSchemaChangeKind.dropColumn], [FluentSchemaChangeKind.purgeArchive]) or
  /// a view / trigger of the app is lost ([FluentSchemaChangeKind.viewOrTriggerLost]).
  bool get losesData => kind == FluentSchemaChangeKind.dropColumn || kind == FluentSchemaChangeKind.purgeArchive || kind == FluentSchemaChangeKind.viewOrTriggerLost;

  @override
  String toString() => '$table: $description';
}

/// What the schema sync of one database would do, computed without changing it (`FluentDb.planMigrations`), and what
/// `FluentGroup.onMigrationPlan` decides on before a start applies it.
class FluentMigrationPlan {
  /// Creates a plan.
  const FluentMigrationPlan({
    required this.database,
    required this.changes,
    required this.issues,
    this.isNewDatabase = false,
    this.skippedCode = const [],
    this.failure,
  });

  /// Database name.
  final String database;

  /// Every change, in the order it is applied.
  final List<FluentSchemaChange> changes;

  /// What the sync would report: archived columns, possible renames, type changes, quarantined rows, ...
  final List<FluentIssue> issues;

  /// Whether the database file does not exist yet (every table is created).
  final bool isNewDatabase;

  /// Labels of steps whose `onMigrate` code was not run for the plan (`runCode: false`); what that code changes is
  /// not part of [changes].
  final List<String> skippedCode;

  /// Why the start would fail (a migration step that throws, a schema SQLite refuses); [changes] then holds what
  /// ran before it. A start with this schema fails the same way and changes nothing.
  final FluentException? failure;

  /// Whether nothing would change (and nothing would fail).
  bool get isEmpty => changes.isEmpty && failure == null;

  /// Whether any change deletes data for good or loses a view / trigger of the app (see
  /// [FluentSchemaChange.losesData]).
  bool get losesData => changes.any((c) => c.losesData);

  /// Whether a table would be rebuilt (slower on big tables).
  bool get rebuilds => changes.any((c) => c.kind == FluentSchemaChangeKind.rebuildTable);

  /// The warnings and errors among [issues].
  List<FluentIssue> get warnings => [for (final FluentIssue i in issues) if (i.type == FluentIssueType.warning || i.type == FluentIssueType.error) i];

  /// The changes of [table].
  List<FluentSchemaChange> changesOf(String table) => [for (final FluentSchemaChange c in changes) if (c.table == table) c];

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('=== Migration plan of "$database"${isNewDatabase ? ' (new database)' : ''} ===\n');
    if (changes.isEmpty) sb.writeln('  nothing to change');
    String? table;
    for (final FluentSchemaChange c in changes) {
      if (c.table != table) sb.writeln('  ${table = c.table}:');
      sb.writeln('    ${c.losesData ? '⚠ ' : '- '}${c.description}');
    }
    if (skippedCode.isNotEmpty) sb.writeln('  onMigrate not run for the plan: ${skippedCode.join(', ')}');
    if (failure != null) sb.writeln('  ✖ the start would fail: ${failure!.message}');
    for (final FluentIssue i in issues) {
      sb.writeln('  [${i.type.name}] ${i.title}');
    }
    return sb.toString();
  }
}
