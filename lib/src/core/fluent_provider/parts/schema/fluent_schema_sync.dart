// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Table that stores the applied schema snapshot of every table.
const String fluentSchemaTable = '__fluent_schema';

/// Table that stores the schema migration history.
const String fluentSchemaHistoryTable = '__fluent_schema_history';

const String _archivePrefix = '__fluent_removed_';
final RegExp _archiveName = RegExp(r'^__fluent_removed_(.+)_r(\d+)$');

/// Settings and collected results of one schema synchronization run (one database).
class FluentSchemaSyncContext {
  /// Creates a context.
  FluentSchemaSyncContext({
    required this.removal,
    required this.archiveRetention,
    required this.supportsRenameColumn,
    this.supportsDropColumn = false,
    this.fullText,
    this.runCode = true,
    this.foreignKeys = true,
  });

  /// What happens to columns removed from a model.
  final FluentColumnRemoval removal;

  /// Archived columns older than this are purged; `null` keeps them.
  final Duration? archiveRetention;

  /// Whether SQLite supports `ALTER TABLE RENAME COLUMN` (3.25+).
  final bool supportsRenameColumn;

  /// Whether SQLite supports `ALTER TABLE DROP COLUMN` (3.35+).
  final bool supportsDropColumn;

  /// Full-text mode of the database (`FluentDbConfig.fullText`).
  final FluentFullText? fullText;

  /// Whether `onMigrate` code runs; `false` for a migration plan that leaves it out (`FluentDb.planMigrations`).
  final bool runCode;

  /// Whether foreign keys are enforced (`FluentDbConfig.enableForeignKeys`). Part of every table's fingerprint: a switch
  /// from off to on takes the full sync, which then checks the rows for dangling references.
  final bool foreignKeys;

  /// Every change of this run, in order (tables, link tables, relation data, full-text indexes).
  final List<FluentSchemaChange> changes = [];

  /// Steps whose `onMigrate` did not run because of [runCode] (`<table>.<label>`).
  final List<String> skippedCode = [];

  /// Reference time of this run.
  final DateTime now = FluentClock.now();

  /// History entries produced by this run.
  final List<FluentSchemaHistoryEntry> history = [];

  /// Table being synchronized (to attribute a failure).
  String? currentTable;
}

/// Creates the schema bookkeeping tables if needed.
Future<void> ensureFluentSchemaTables(DatabaseExecutor executor) async {
  await executor.execute(
    'CREATE TABLE IF NOT EXISTS ${fluentSchemaTable.quotedIdentifier} ('
    '"table_name" TEXT PRIMARY KEY, "revision" INTEGER NOT NULL, "snapshot" TEXT NOT NULL, "updated_at" INTEGER NOT NULL)',
  );
  await executor.execute(
    'CREATE TABLE IF NOT EXISTS ${fluentSchemaHistoryTable.quotedIdentifier} ('
    '"id" INTEGER PRIMARY KEY AUTOINCREMENT, "table_name" TEXT NOT NULL, "from_revision" INTEGER NOT NULL, '
    '"to_revision" INTEGER NOT NULL, "changes" TEXT NOT NULL, "success" INTEGER NOT NULL, "error" TEXT, '
    '"duration_ms" INTEGER NOT NULL, "applied_at" INTEGER NOT NULL)',
  );
}

/// Stores [entries] and keeps at most [limit] entries per table.
Future<void> writeFluentSchemaHistory(DatabaseExecutor executor, List<FluentSchemaHistoryEntry> entries, int limit) async {
  if (entries.isEmpty) return;
  for (final FluentSchemaHistoryEntry e in entries) {
    await executor.insert(fluentSchemaHistoryTable, {
      'table_name': e.table,
      'from_revision': e.fromRevision,
      'to_revision': e.toRevision,
      'changes': jsonEncode(e.changes),
      'success': e.success ? 1 : 0,
      'error': e.error,
      'duration_ms': e.durationMs,
      'applied_at': e.appliedAt.millisecondsSinceEpoch,
    });
  }
  for (final String table in {for (final FluentSchemaHistoryEntry e in entries) e.table}) {
    await executor.rawDelete(
      'DELETE FROM ${fluentSchemaHistoryTable.quotedIdentifier} WHERE "table_name" = ? AND "id" NOT IN '
      '(SELECT "id" FROM ${fluentSchemaHistoryTable.quotedIdentifier} WHERE "table_name" = ? ORDER BY "id" DESC LIMIT ?)',
      [table, table, limit < 1 ? 1 : limit],
    );
  }
}

/// Reads the history of a database, newest first.
Future<List<FluentSchemaHistoryEntry>> readFluentSchemaHistory(DatabaseExecutor executor) async {
  final List<Map<String, Object?>> rows = await executor.query(fluentSchemaHistoryTable, orderBy: '"id" DESC');
  return [
    for (final Map<String, Object?> r in rows)
      FluentSchemaHistoryEntry(
        table: r['table_name']! as String,
        fromRevision: r['from_revision']! as int,
        toRevision: r['to_revision']! as int,
        changes: (jsonDecode(r['changes']! as String) as List<dynamic>).cast<String>(),
        success: r['success'] == 1,
        error: r['error'] as String?,
        durationMs: r['duration_ms']! as int,
        appliedAt: DateTime.fromMillisecondsSinceEpoch(r['applied_at']! as int),
      ),
  ];
}

/// Reads the applied snapshots of a database.
Future<List<FluentTableSnapshot>> readFluentSchemaSnapshots(DatabaseExecutor executor) async {
  final List<Map<String, Object?>> rows = await executor.query(fluentSchemaTable, orderBy: '"table_name"');
  final List<FluentTableSnapshot> snapshots = [];
  for (final Map<String, Object?> r in rows) {
    try {
      snapshots.add(FluentTableSnapshot.fromJson(r['table_name']! as String, r['revision']! as int, r['snapshot']! as String));
    } catch (_) {
      // Damaged: left out here; the next schema sync of the table reports it and stores a new one.
    }
  }
  return snapshots;
}

/// What a damaged snapshot still told (its revision, and the labels of applied steps when they could be read), so the
/// snapshot read back from the table keeps them: archive names stay unique and applied steps never run twice.
final Expando<({int revision, Map<String, String> steps})> _damagedSnapshots = Expando('damagedSnapshot');

/// Version of the schema sync rules: raising it makes every database take the full sync once.
const int _schemaSyncVersion = 1;

/// FNV-1a 32-bit: stable across runs and Dart versions (String.hashCode is not guaranteed to be).
String _fnv1a(String content) {
  int hash = 0x811c9dc5;
  for (final int unit in content.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Fast start: `true` when every table of [providers] is exactly as the last full schema sync left it (same
/// fingerprint, tables present, nothing pending or expired), so the sync and its write transaction can be skipped.
///
/// Costs three reads instead of several statements per table. Anything unusual returns `false` (the full sync).
Future<bool> fluentSchemaUpToDate(DatabaseExecutor db, Iterable<FluentProvider> providers, FluentSchemaSyncContext ctx) async {
  final Map<String, String?> sqlOf = {
    for (final Map<String, Object?> r in await db.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'table'")) r['name']! as String: r['sql'] as String?,
  };
  final Set<String> tables = sqlOf.keys.toSet();
  if (!tables.contains(fluentSchemaTable) || !tables.contains(_ftsMetaTable)) return false;
  final Map<String, FluentTableSnapshot> snapshots = {for (final FluentTableSnapshot s in await readFluentSchemaSnapshots(db)) s.table: s};
  final Map<String, String> fullText = {};
  final Map<String, int?> fullTextRevision = {};
  for (final Map<String, Object?> r in await db.query(_ftsMetaTable, columns: ['tbl', 'definition', 'revision'])) {
    fullText[r['tbl']! as String] = r['definition']! as String;
    fullTextRevision[r['tbl']! as String] = r['revision'] as int?;
  }
  for (final FluentProvider p in providers) {
    final FluentTableSnapshot? snapshot = snapshots[p.tableName];
    // DDL run outside the library (or another tool) changed the table: the full sync looks at it again.
    if (snapshot?.tableSql == null || snapshot!.tableSql != _tableSqlHash(sqlOf[p.tableName])) return false;
    if (!p._unchangedSince(snapshot, ctx, tables: tables, fullText: fullText[p.tableName])) return false;
    // A full-text index built for another revision of the table may point at the wrong rows: the full sync rebuilds it.
    if (fullText.containsKey(p.tableName) && fullTextRevision[p.tableName] != snapshot.revision) return false;
  }
  for (final FluentProvider p in providers) {
    p._adoptFullText(fullText[p.tableName]);
  }
  return true;
}

/// Fingerprint of a table's `CREATE TABLE` statement as SQLite keeps it (`sqlite_master.sql`).
String? _tableSqlHash(String? sql) => sql == null ? null : _fnv1a(_normalizeSql(sql));

/// SQLite type affinity of a declared column type (https://sqlite.org/datatype3.html#affinity).
String _affinity(String declared) {
  final String t = declared.toUpperCase();
  if (t.contains('INT')) return 'INTEGER';
  if (t.contains('CHAR') || t.contains('CLOB') || t.contains('TEXT')) return 'TEXT';
  if (t.isEmpty || t.contains('BLOB')) return 'BLOB';
  if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) return 'REAL';
  return 'NUMERIC';
}

/// Declared type of a stored column definition (`"x" INTEGER NOT NULL` → `INTEGER`).
String _declaredType(String definition) => _definitionBody(definition).trim().split(' ').first;

/// `CREATE INDEX IF NOT EXISTS "x" ON ...;` and `CREATE INDEX "x" ON ...` compare equal.
String _normalizeSql(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').replaceAll('IF NOT EXISTS ', '').replaceAll(RegExp(r';\s*$'), '').trim();

/// Column definition without its leading quoted name (renames keep the same body).
String _definitionBody(String definition) {
  final int end = definition.startsWith('"') ? definition.indexOf('" ', 1) : -1;
  return end < 0 ? definition : definition.substring(end + 2);
}

class _DiskColumn {
  _DiskColumn(this.name, this.type, this.pk, {this.notNull = false, this.defaultValue});

  final String name;
  final String type;
  final int pk;

  /// `PRAGMA table_info.notnull`.
  final bool notNull;

  /// `PRAGMA table_info.dflt_value` (the SQL text of the default), `null` without one.
  final String? defaultValue;
}

/// A `CREATE TABLE` statement split into its column definitions (name → definition with the quoted name) and its
/// table constraints, as SQLite keeps it in `sqlite_master.sql`.
class _DiskTable {
  _DiskTable(this.columns, this.constraints, {required this.withoutRowId});

  /// Parses [sql]; an empty result when it cannot be read (the caller then falls back to `PRAGMA table_info`).
  factory _DiskTable.parse(String? sql) {
    final Map<String, String> columns = {};
    final List<String> constraints = [];
    if (sql == null) return _DiskTable(columns, constraints, withoutRowId: false);
    final int open = sql.indexOf('(');
    final int close = sql.lastIndexOf(')');
    if (open < 0 || close <= open) return _DiskTable(columns, constraints, withoutRowId: false);
    final bool withoutRowId = RegExp(r'WITHOUT\s+ROWID\s*;?\s*$', caseSensitive: false).hasMatch(sql.substring(close + 1));
    for (final String part in _splitTopLevel(sql.substring(open + 1, close))) {
      final String text = part.trim();
      if (text.isEmpty) continue;
      final (String name, String rest, bool quoted) = _leadingName(text);
      if (!quoted && const {'CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN'}.contains(name.toUpperCase())) {
        constraints.add(text.replaceAll(RegExp(r'\s+'), ' '));
        continue;
      }
      columns[name] = rest.isEmpty ? name.quotedIdentifier : '${name.quotedIdentifier} ${rest.replaceAll(RegExp(r'\s+'), ' ')}';
    }
    return _DiskTable(columns, constraints, withoutRowId: withoutRowId);
  }

  final Map<String, String> columns;
  final List<String> constraints;
  final bool withoutRowId;

  /// Splits at the commas outside parentheses and quotes.
  static List<String> _splitTopLevel(String body) {
    final List<String> parts = [];
    final StringBuffer current = StringBuffer();
    int depth = 0;
    String? quote;
    for (int i = 0; i < body.length; i++) {
      final String ch = body[i];
      if (quote != null) {
        current.write(ch);
        if (ch == quote) quote = null; // a doubled quote reopens on the next character
        continue;
      }
      if (ch == "'" || ch == '"' || ch == '`') {
        quote = ch;
      } else if (ch == '[') {
        quote = ']';
      } else if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
      } else if (ch == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
        continue;
      }
      current.write(ch);
    }
    parts.add(current.toString());
    return parts;
  }

  /// The leading identifier of a definition (unquoted), the rest, and whether it was quoted.
  static (String, String, bool) _leadingName(String text) {
    final String first = text[0];
    final String? end = switch (first) {
      '"' => '"',
      '`' => '`',
      '[' => ']',
      _ => null,
    };
    if (end != null) {
      final StringBuffer name = StringBuffer();
      int i = 1;
      while (i < text.length) {
        if (text[i] == end) {
          if (end != ']' && i + 1 < text.length && text[i + 1] == end) {
            name.write(end);
            i += 2;
            continue;
          }
          break;
        }
        name.write(text[i]);
        i++;
      }
      return (name.toString(), text.substring(i + 1 < text.length ? i + 1 : text.length).trim(), true);
    }
    final int space = text.indexOf(RegExp(r'\s'));
    return space < 0 ? (text, '', false) : (text.substring(0, space), text.substring(space + 1).trim(), false);
  }
}

/// Compares column definitions / constraints as SQLite reads them: case and spacing do not matter outside literals.
String _canonicalSql(String sql) {
  final StringBuffer out = StringBuffer();
  bool inText = false;
  for (final String part in sql.split("'")) {
    out.write(inText ? "'$part'" : part.toUpperCase().replaceAll('"', '').replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'\s*([(),])\s*'), r'$1'));
    inText = !inText;
  }
  return out.toString().trim();
}

/// A column definition without its `DEFAULT` clause (to compare a pending NOT NULL column that got a default).
String _withoutDefault(String definition) =>
    definition.replaceAll(RegExp(r"\s+DEFAULT\s+('(?:[^']|'')*'|\((?:[^()]|\([^()]*\))*\)|[^\s]+)", caseSensitive: false), '');

class _DesiredSchema {
  _DesiredSchema(this.columns, this.definitions, this.key, this.checks, this.withoutRowId, this.indexes);

  final List<FluentDbColumn> columns;
  final Map<String, String> definitions;
  final List<String> key;
  final List<String> checks;
  final bool withoutRowId;
  final Map<String, FluentIndex> indexes;
}

/// Schema synchronization of one table: compares the model with the applied snapshot and applies the difference.
extension FluentSchemaSync<T extends FluentStorable> on FluentProvider<T> {
  /// Brings the table in line with the model, runs pending one-time migration steps and records the result.
  ///
  /// * Unchanged model → no DDL at all.
  /// * New column → `ADD COLUMN`; rename → `RENAME COLUMN` (or rebuild on old SQLite).
  /// * Removed column → archived or dropped (see [FluentColumnRemoval]) with one `ALTER TABLE` when possible.
  /// * Type / key / constraint change → safe rebuild (data, rowids, `AUTOINCREMENT` counter, triggers, views and the
  ///   app's own indexes are kept; rejected rows go to a quarantine table).
  /// * NOT NULL columns without default on a non-empty table are added nullable and enforced later.
  /// * A table without snapshot (adopted) is compared with its real definition on disk and rebuilt once if its
  ///   rules differ from the model.
  Future<void> syncTable(Transaction txn, FluentSchemaSyncContext ctx, {required bool existsOnDisk}) async {
    ctx.currentTable = tableName;
    final Stopwatch watch = Stopwatch()..start();
    _checkStepLabels();
    refreshSchema();

    final _DesiredSchema desired = _desiredSchema();
    final String fingerprint = _fingerprint(desired, ctx);
    final List<FluentSchemaChange> changes = [];
    FluentTableSnapshot? snapshot = existsOnDisk ? await _readSnapshot(txn) : null;
    final bool bootstrapped = existsOnDisk && snapshot == null;
    int fromRevision = snapshot?.revision ?? 0;

    if (!existsOnDisk) {
      snapshot = await _createFresh(txn, desired, changes);
    } else {
      final List<_DiskColumn> disk = await _diskColumns(txn);
      if (snapshot == null) {
        snapshot = await _bootstrapSnapshot(txn, desired, disk);
        final ({int revision, Map<String, String> steps})? damaged = _damagedSnapshots[this];
        if (damaged != null) {
          _damagedSnapshots[this] = null;
          snapshot.steps.addAll(damaged.steps);
          if (damaged.revision > snapshot.revision) snapshot.revision = damaged.revision;
        }
        fromRevision = snapshot.revision;
      }
      await _applyStructure(txn, desired, disk, snapshot, ctx, changes, stepDrops: _pendingStepDrops(snapshot));
    }

    await _applySteps(txn, snapshot, desired, ctx, changes, fresh: !existsOnDisk);

    if (changes.isNotEmpty) snapshot.revision = fromRevision + 1;
    snapshot.relations
      ..clear()
      ..addAll({for (final FluentRelationLink l in _links) l.name: _storageOf(l)});
    final String? tableSql = _tableSqlHash(
      (await txn.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [tableName])).firstOrNull?['sql'] as String?,
    );
    if (changes.isNotEmpty || bootstrapped || snapshot.fingerprint != fingerprint || snapshot.tableSql != tableSql) {
      snapshot.fingerprint = fingerprint;
      snapshot.tableSql = tableSql;
      await txn.insert(
        fluentSchemaTable,
        {'table_name': tableName, 'revision': snapshot.revision, 'snapshot': snapshot.toJson(), 'updated_at': ctx.now.millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    watch.stop();

    ctx.changes.addAll(changes);
    if (changes.isEmpty) {
      FluentLog.debug('Schema of "$tableName" is up to date', tag: '$tableName:schema', context: {'revision': snapshot.revision});
      return;
    }
    FluentLog.info('Schema of "$tableName" updated to revision ${snapshot.revision}', tag: '$tableName:schema', context: {'changes': changes});
    ctx.history.add(
      FluentSchemaHistoryEntry(
        table: tableName,
        fromRevision: fromRevision,
        toRevision: snapshot.revision,
        changes: [for (final FluentSchemaChange c in changes) c.description],
        success: true,
        durationMs: watch.elapsedMilliseconds,
        appliedAt: ctx.now,
      ),
    );
  }

  /// Two steps with the same label (`id: 'v2'` and `version: 2`, or equal ids) would share one "applied" mark, so the
  /// second would never run: refused before anything runs.
  void _checkStepLabels() {
    final Map<String, FluentDbMigration> seen = {};
    for (final FluentDbMigration step in modelSample.migrations) {
      final String? label = step.label;
      if (!step.hasSteps || label == null) continue;
      if (seen.containsKey(label)) {
        throw FluentSchemaException(
          'Two migration steps of "$tableName" have the label "$label".',
          modelName: tableName,
          hint: 'A step runs once per label (id, or "v<version>"), so the second one would never run. Give every step of ${modelSample.runtimeType}.migrations its own id / version '
              '(note that version: 2 and id: "v2" are the same label).',
        );
      }
      seen[label] = step;
    }
  }

  /// Fingerprint of everything a full sync of this table depends on (see [FluentTableSnapshot.fingerprint]).
  String _fingerprint(_DesiredSchema desired, FluentSchemaSyncContext ctx) {
    final FluentFullText fullText = _tableConfig.fullText ?? ctx.fullText ?? FluentEngine().config.fullText;
    return _fnv1a(
      [
        'v$_schemaSyncVersion',
        ctx.removal.name,
        for (final MapEntry<String, String> c in desired.definitions.entries) '${c.key}=${c.value}',
        '#key', ...desired.key,
        '#checks', ...desired.checks,
        '#rowid:${desired.withoutRowId}',
        '#indexes',
        for (final MapEntry<String, FluentIndex> i in desired.indexes.entries) '${i.key}=${_normalizeSql(i.value.createSql(tableName))}',
        '#steps',
        for (final FluentDbMigration step in modelSample.migrations) if (step.hasSteps) '${step.label}=${step.contentHash}',
        '#links', ..._linkTableStatements(),
        for (final FluentRelationLink l in _links) '${l.name}=${_storageOf(l)}',
        '#sync:${_syncColumns != null}',
        '#fk:${ctx.foreignKeys}',
        '#fts:${fullText.name}:${fullTextColumns.join(',')}',
      ].join('\u0001'),
    );
  }

  /// See [fluentSchemaUpToDate]: whether this table needs no sync at all.
  bool _unchangedSince(FluentTableSnapshot? snapshot, FluentSchemaSyncContext ctx, {required Set<String> tables, required String? fullText}) {
    if (snapshot == null || snapshot.fingerprint == null || snapshot.pendingNotNull.isNotEmpty) return false;
    final Duration? retention = ctx.archiveRetention;
    if (retention != null && snapshot.archived.any((a) => ctx.now.difference(a.removedAt) > retention)) return false;
    // Unlabeled steps and indexes that could not be created are reported / retried by the full sync on every start.
    if (modelSample.migrations.any((m) => m.hasSteps && m.label == null)) return false;
    refreshSchema();
    final _DesiredSchema desired = _desiredSchema();
    if (!desired.indexes.keys.every(snapshot.indexes.containsKey)) return false;
    final List<String> needed = [
      tableName,
      for (final FluentRelationLink l in _links) if (l.isManyToMany) l.linkTable!,
      if (_syncColumns != null) ...[_tombstoneTable, _syncStateTable],
      if (fullText != null) _ftsTable,
    ];
    return needed.every(tables.contains) && snapshot.fingerprint == _fingerprint(desired, ctx);
  }

  FluentSchemaChange _change(FluentSchemaChangeKind kind, String description, {String? subject}) =>
      FluentSchemaChange(kind: kind, table: tableName, description: description, subject: subject);

  /// Columns that a step not yet applied removes for good: they are dropped right away instead of being archived first.
  Set<String> _pendingStepDrops(FluentTableSnapshot snapshot) => {
    for (final FluentDbMigration step in modelSample.migrations)
      if (step.label != null && !snapshot.steps.containsKey(step.label)) ...step.dropColumns,
  };

  _DesiredSchema _desiredSchema() {
    final List<FluentDbColumn> columns = getFullSchema;
    final List<FluentDbColumn> keyColumns = primaryKeyColumns;
    final bool composite = keyColumns.length > 1;
    return _DesiredSchema(
      columns,
      {for (final FluentDbColumn c in columns) c.name: c.sqlDefinitionWith(inlinePrimaryKey: !composite)},
      [for (final FluentDbColumn c in keyColumns) c.name],
      [for (final FluentCheck c in modelSample.checks) c.sql, ..._relationConstraints],
      _useWithoutRowId,
      {for (final FluentIndex i in tableIndexes) i.nameFor(tableName): i},
    );
  }

  String _tableSql(String name, Iterable<String> definitions, _DesiredSchema desired) {
    final List<String> parts = [...definitions];
    if (desired.key.length > 1) parts.add('PRIMARY KEY (${desired.key.map((c) => c.quotedIdentifier).join(', ')})');
    parts.addAll(desired.checks);
    return 'CREATE TABLE ${name.quotedIdentifier} (\n  ${parts.join(',\n  ')}\n)${desired.withoutRowId ? ' WITHOUT ROWID' : ''}';
  }

  String _nullableDefinition(FluentDbColumn column) => column.withoutNotNull.sqlDefinitionWith(inlinePrimaryKey: !hasCompositeKey);

  Future<FluentTableSnapshot?> _readSnapshot(DatabaseExecutor executor) async {
    final List<Map<String, Object?>> rows = await executor.query(fluentSchemaTable, where: '"table_name" = ?', whereArgs: [tableName], limit: 1);
    if (rows.isEmpty) return null;
    final Object? revision = rows.first['revision'];
    final Object? raw = rows.first['snapshot'];
    try {
      return FluentTableSnapshot.fromJson(tableName, revision! as int, raw! as String);
    } catch (e) {
      // A damaged snapshot must not stop the app: the applied state is read back from the table itself. Applied steps
      // are kept when their labels can be read, else every declared step counts as applied (never run one twice).
      Map<String, String>? steps;
      try {
        steps = ((jsonDecode(raw! as String) as Map<String, dynamic>)['steps'] as Map<String, dynamic>).map((k, v) => MapEntry(k, '$v'));
      } catch (_) {
        steps = null;
      }
      steps ??= {for (final FluentDbMigration m in modelSample.migrations) if (m.hasSteps && m.label != null) m.label!: ''};
      _damagedSnapshots[this] = (revision: revision is int ? revision : 0, steps: steps);
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'The stored schema snapshot of "$tableName" cannot be read; the applied state is read from the table instead.',
        table: tableName,
        database: dbName,
        tag: '$tableName:schema',
        error: e,
        hint: 'Nothing to do: the next sync stores a new snapshot. Data and archived columns are kept; migration steps are not run again.',
      );
      return null;
    }
  }

  Future<List<_DiskColumn>> _diskColumns(DatabaseExecutor executor) async => [
    for (final Map<String, Object?> r in await executor.rawQuery('PRAGMA table_info(${tableName.quotedIdentifier})'))
      _DiskColumn(
        r['name']! as String,
        ((r['type'] as String?) ?? '').toUpperCase(),
        (r['pk'] as int?) ?? 0,
        notNull: r['notnull'] == 1,
        defaultValue: r['dflt_value'] as String?,
      ),
  ];

  /// The table as it is on disk (`sqlite_master.sql`, parsed).
  Future<_DiskTable> _diskTable(DatabaseExecutor executor) async => _DiskTable.parse(
    (await executor.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [tableName])).firstOrNull?['sql'] as String?,
  );

  Future<bool> _hasRows(DatabaseExecutor executor) async =>
      (await executor.rawQuery('SELECT EXISTS(SELECT 1 FROM ${tableName.quotedIdentifier}) AS e')).first['e'] == 1;

  Future<bool> _hasNulls(DatabaseExecutor executor, String column) async =>
      (await executor.rawQuery('SELECT EXISTS(SELECT 1 FROM ${tableName.quotedIdentifier} WHERE ${column.quotedIdentifier} IS NULL) AS e')).first['e'] == 1;

  Future<FluentTableSnapshot> _createFresh(Transaction txn, _DesiredSchema desired, List<FluentSchemaChange> changes) async {
    final String sql = _tableSql(tableName, desired.definitions.values, desired);
    FluentLog.sql(sql, tag: '$tableName:schema');
    await txn.execute(sql);
    final FluentTableSnapshot snapshot = FluentTableSnapshot(
      table: tableName,
      columns: Map.of(desired.definitions),
      key: desired.key,
      checks: desired.checks,
      withoutRowId: desired.withoutRowId,
    );
    changes.add(_change(FluentSchemaChangeKind.createTable, 'created table with ${desired.definitions.length} columns'));
    await _syncIndexes(txn, desired, snapshot, changes, rebuilt: true);
    return snapshot;
  }

  /// First sync of a table without snapshot (created before snapshots existed, or by other code): reconstruct the
  /// applied state from the database.
  ///
  /// The snapshot records what is really on disk (column definitions and table constraints of `sqlite_master.sql`),
  /// so every rule of the model the table lacks (NOT NULL, UNIQUE, REFERENCES, CHECK, ...) is seen as a change and
  /// applied by this first sync (usually one rebuild). A definition that already matches is recorded as the model's.
  Future<FluentTableSnapshot> _bootstrapSnapshot(Transaction txn, _DesiredSchema desired, List<_DiskColumn> disk) async {
    final _DiskTable table = await _diskTable(txn);
    final Map<String, String> columns = {};
    final List<FluentArchivedColumn> archived = [];

    for (final _DiskColumn d in disk) {
      final RegExpMatch? archive = _archiveName.firstMatch(d.name);
      if (archive != null) {
        archived.add(FluentArchivedColumn(original: archive.group(1)!, archivedAs: d.name, type: d.type, revision: int.parse(archive.group(2)!), removedAt: FluentClock.now()));
        continue;
      }
      final String? wanted = desired.definitions[d.name];
      final String? onDisk = table.columns[d.name];
      if (onDisk == null) {
        // The statement could not be read: the declared type only (a difference in rules then takes one rebuild).
        columns[d.name] = '${d.name.quotedIdentifier} ${d.type}${d.notNull ? ' NOT NULL' : ''}${d.defaultValue != null ? ' DEFAULT ${d.defaultValue}' : ''}';
      } else {
        columns[d.name] = wanted != null && _canonicalSql(_definitionBody(onDisk)) == _canonicalSql(_definitionBody(wanted)) ? wanted : onDisk;
      }
    }

    final List<_DiskColumn> pk = disk.where((d) => d.pk > 0).toList()..sort((a, b) => a.pk.compareTo(b.pk));
    // Table constraints as on disk (a composite PRIMARY KEY is the snapshot's key, not a check).
    final Map<String, String> wantedChecks = {for (final String c in desired.checks) _canonicalSql(c): c};
    final List<String> checks = [
      for (final String c in table.constraints)
        if (!RegExp(r'^PRIMARY\s+KEY', caseSensitive: false).hasMatch(c)) wantedChecks[_canonicalSql(c)] ?? c,
    ];

    // Only indexes of the model's names and definitions are the library's; every other index (even one named idx_<table>_...) is the app's.
    final Map<String, String> indexes = {};
    for (final Map<String, Object?> r in await txn.query('sqlite_master', columns: ['name', 'sql'], where: "type = 'index' AND tbl_name = ? AND sql IS NOT NULL", whereArgs: [tableName])) {
      final String name = r['name']! as String;
      final FluentIndex? wanted = desired.indexes[name];
      // Only an identical index is taken over; one of the same name with another definition is the app's (reported by _syncIndexes).
      if (wanted != null && _normalizeSql(r['sql']! as String) == _normalizeSql(wanted.createSql(tableName))) indexes[name] = _normalizeSql(r['sql']! as String);
    }

    final Map<String, String> steps = {};
    final bool legacy = (await txn.query('sqlite_master', where: "type = 'table' AND name = '__fluent_migrations'")).isNotEmpty;
    if (legacy) {
      for (final Map<String, Object?> r in await txn.query('__fluent_migrations', columns: ['version'], where: '"table_name" = ?', whereArgs: [tableName])) {
        steps['v${r['version']}'] = '';
      }
    }

    FluentLog.debug('Schema snapshot of "$tableName" initialized from the database', tag: '$tableName:schema');
    return FluentTableSnapshot(
      table: tableName,
      columns: columns,
      key: [for (final _DiskColumn d in pk) d.name],
      checks: checks,
      withoutRowId: table.withoutRowId,
      indexes: indexes,
      archived: archived,
      steps: steps,
      // Past the archives on disk, so a new archive never takes the name of an old one.
      revision: archived.fold<int>(0, (m, a) => a.revision > m ? a.revision : m),
    );
  }

  Future<void> _applyStructure(
    Transaction txn,
    _DesiredSchema desired,
    List<_DiskColumn> disk,
    FluentTableSnapshot snapshot,
    FluentSchemaSyncContext ctx,
    List<FluentSchemaChange> changes, {
    required Set<String> stepDrops,
  }) async {
    final Map<String, _DiskColumn> live = {for (final _DiskColumn d in disk) if (!d.name.startsWith(_archivePrefix)) d.name: d};
    final Set<String> archivesOnDisk = {for (final _DiskColumn d in disk) if (d.name.startsWith(_archivePrefix)) d.name};
    final int nextRevision = snapshot.revision + 1;
    // Archives on disk the snapshot does not know (lost or older snapshot): adopted, so a rebuild carries them over
    // instead of dropping them; their retention starts now.
    final Set<String> knownArchives = {for (final FluentArchivedColumn a in snapshot.archived) a.archivedAs};
    for (final _DiskColumn d in disk) {
      if (!d.name.startsWith(_archivePrefix) || knownArchives.contains(d.name)) continue;
      final RegExpMatch? m = _archiveName.firstMatch(d.name);
      snapshot.archived.add(
        FluentArchivedColumn(
          original: m?.group(1) ?? d.name.substring(_archivePrefix.length),
          archivedAs: d.name,
          type: d.type,
          revision: int.tryParse(m?.group(2) ?? '') ?? 0,
          removedAt: ctx.now,
        ),
      );
      FluentLog.debug('Archived column "${d.name}" of "$tableName" was not in the snapshot; adopted', tag: '$tableName:schema');
    }

    // Renames (oldName maps live columns only).
    final Map<String, String> renames = {};
    for (final FluentDbColumn c in desired.columns) {
      final String? old = c.oldName;
      if (old == null || live.containsKey(c.name)) continue;
      if (live.containsKey(old)) {
        renames[c.name] = old;
      } else if (snapshot.archived.any((a) => a.original == old)) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Column "${c.name}" of "$tableName" declares oldName "$old", but "$old" is archived; "${c.name}" starts empty.',
          table: tableName,
          tag: '$tableName:schema',
          hint: 'To bring the archived data into "${c.name}", add FluentDbMigration(id: "restore_$old", restoreColumns: {"$old": "${c.name}"}).',
        );
      }
    }

    final List<FluentDbColumn> added = [for (final FluentDbColumn c in desired.columns) if (!live.containsKey(c.name) && !renames.containsKey(c.name)) c];
    final Set<String> renamedFrom = renames.values.toSet();
    final List<String> removed = [for (final String name in live.keys) if (!desired.definitions.containsKey(name) && !renamedFrom.contains(name)) name];
    // A column a pending step drops stays in the table (under its own name) while the step runs, so its rawSql /
    // onMigrate can still read it; the step drops it right after (see _applySteps).
    final List<String> keptForSteps = [for (final String name in removed) if (stepDrops.contains(name)) name];
    removed.removeWhere(keptForSteps.contains);

    // Changed definitions (pending NOT NULL columns stay "unchanged" while they still contain NULLs).
    final List<String> changed = [];
    bool enforcePending = false;
    for (final FluentDbColumn c in desired.columns) {
      final String? source = renames[c.name] ?? (live.containsKey(c.name) ? c.name : null);
      if (source == null) continue;
      final String? applied = snapshot.columns[source];
      final String wanted = desired.definitions[c.name]!;
      if (applied != null && _definitionBody(applied) == _definitionBody(wanted)) continue;
      // A pending column compares without its DEFAULT: one added since is no other change, the rebuild fills the NULLs.
      if (snapshot.pendingNotNull.contains(c.name) && applied != null && _withoutDefault(_definitionBody(applied)) == _withoutDefault(_definitionBody(_nullableDefinition(c)))) {
        if (c.defaultValue == null && await _hasNulls(txn, source)) continue;
        enforcePending = true;
      }
      changed.add(c.name);
    }
    snapshot.pendingNotNull.removeWhere((name) => !desired.definitions.containsKey(name));

    bool? hasRowsCache;
    Future<bool> hasRows() async => hasRowsCache ??= await _hasRows(txn);
    await _reportDataRisks(desired, snapshot, ctx, renames: renames, added: added, removed: removed, changed: changed, stepDrops: stepDrops, hasRows: hasRows);

    final bool keyChanged = !listEquals(snapshot.key, desired.key);
    final bool checksChanged = !listEquals(snapshot.checks, desired.checks);
    final bool rowIdChanged = snapshot.withoutRowId != desired.withoutRowId;
    final Duration? retention = ctx.archiveRetention;
    final List<FluentArchivedColumn> expired = [
      if (retention != null)
        for (final FluentArchivedColumn a in snapshot.archived) if (ctx.now.difference(a.removedAt) > retention) a,
    ];

    bool addNeedsRebuild = false;
    for (final FluentDbColumn c in added) {
      if (c.effectivePrimaryKey || c.effectiveUnique || c.hasExpressionDefault) addNeedsRebuild = true;
      if (c.effectiveNotNull && !c.effectiveDefault && !await hasRows()) addNeedsRebuild = true;
    }

    // Removed columns and expired archives in place (RENAME / DROP COLUMN) when nothing else needs a rebuild.
    final bool otherRebuild = changed.isNotEmpty || keyChanged || checksChanged || rowIdChanged || addNeedsRebuild || (renames.isNotEmpty && !ctx.supportsRenameColumn);
    if (!otherRebuild) {
      final _DiskTable onDisk = removed.isEmpty ? _DiskTable({}, [], withoutRowId: false) : await _diskTable(txn);
      for (final String name in [...removed]) {
        if (await _removeInPlace(txn, name, live[name]!, onDisk, snapshot, ctx, changes, revision: nextRevision, drop: ctx.removal == FluentColumnRemoval.drop)) {
          removed.remove(name);
          // A later column may still need the rebuild: it must carry this archive over.
          archivesOnDisk.addAll([for (final FluentArchivedColumn a in snapshot.archived) a.archivedAs]);
        }
      }
      for (final FluentArchivedColumn a in [...expired]) {
        if (!archivesOnDisk.contains(a.archivedAs)) continue;
        if (ctx.supportsDropColumn && await _alterInPlace(txn, 'ALTER TABLE ${tableName.quotedIdentifier} DROP COLUMN ${a.archivedAs.quotedIdentifier}')) {
          expired.remove(a);
          snapshot.archived.remove(a);
          archivesOnDisk.remove(a.archivedAs);
          changes.add(_change(FluentSchemaChangeKind.purgeArchive, 'purged archived column "${a.archivedAs}" (older than ${retention!.inDays} days)', subject: a.archivedAs));
        }
      }
    }

    final bool rebuild = otherRebuild || removed.isNotEmpty || expired.isNotEmpty;

    if (!rebuild) {
      for (final MapEntry<String, String> r in renames.entries) {
        await txn.execute('ALTER TABLE ${tableName.quotedIdentifier} RENAME COLUMN ${r.value.quotedIdentifier} TO ${r.key.quotedIdentifier}');
        snapshot.columns.remove(r.value);
        snapshot.columns[r.key] = desired.definitions[r.key]!;
        changes.add(_change(FluentSchemaChangeKind.renameColumn, 'renamed column "${r.value}" to "${r.key}"', subject: r.key));
      }
      for (final FluentDbColumn c in added) {
        final bool pending = c.effectiveNotNull && !c.effectiveDefault;
        final String definition = pending ? _nullableDefinition(c) : desired.definitions[c.name]!;
        await txn.execute('ALTER TABLE ${tableName.quotedIdentifier} ADD COLUMN $definition');
        snapshot.columns[c.name] = definition;
        if (pending) {
          snapshot.pendingNotNull.add(c.name);
          _warnPendingNotNull(c);
          changes.add(_change(FluentSchemaChangeKind.addColumn, 'added column "${c.name}" (NOT NULL pending: existing rows have no value)', subject: c.name));
        } else {
          changes.add(_change(FluentSchemaChangeKind.addColumn, 'added column "${c.name}"', subject: c.name));
        }
      }
      await _syncIndexes(txn, desired, snapshot, changes, rebuilt: false);
      return;
    }

    // Rebuild: target columns + where their data comes from.
    final Map<String, String> target = {};
    final Map<String, String> copyFrom = {};
    final Set<String> pending = {};
    for (final FluentDbColumn c in desired.columns) {
      final String? source = renames[c.name] ?? (live.containsKey(c.name) ? c.name : null);
      String definition = desired.definitions[c.name]!;
      if (c.effectiveNotNull && !c.effectiveDefault && !c.effectivePrimaryKey) {
        final bool missingValues = source == null ? await hasRows() : await _hasNulls(txn, source);
        if (missingValues) {
          definition = _nullableDefinition(c);
          pending.add(c.name);
          _warnPendingNotNull(c);
        }
      }
      target[c.name] = definition;
      if (source != null) copyFrom[c.name] = source;
    }

    final Set<String> expiredNames = {for (final FluentArchivedColumn a in expired) a.archivedAs};
    final List<FluentArchivedColumn> archives = [
      for (final FluentArchivedColumn a in snapshot.archived)
        if (!expiredNames.contains(a.archivedAs) && archivesOnDisk.contains(a.archivedAs)) a,
    ];
    for (final FluentArchivedColumn a in archives) {
      target[a.archivedAs] = '${a.archivedAs.quotedIdentifier} ${a.type}';
      copyFrom[a.archivedAs] = a.archivedAs;
    }
    for (final String name in keptForSteps) {
      target[name] = snapshot.columns[name] ?? '${name.quotedIdentifier} ${live[name]!.type}';
      copyFrom[name] = name;
    }
    for (final String name in removed) {
      if (ctx.removal == FluentColumnRemoval.drop) {
        changes.add(_change(FluentSchemaChangeKind.dropColumn, 'dropped column "$name" with its data', subject: name));
        continue;
      }
      final String archivedAs = '$_archivePrefix${name}_r$nextRevision';
      target[archivedAs] = '${archivedAs.quotedIdentifier} ${live[name]!.type}';
      copyFrom[archivedAs] = name;
      archives.add(FluentArchivedColumn(original: name, archivedAs: archivedAs, type: live[name]!.type, revision: nextRevision, removedAt: ctx.now));
      changes.add(_change(FluentSchemaChangeKind.archiveColumn, 'archived column "$name" as "$archivedAs"', subject: name));
      _reportArchived(name, archivedAs);
    }
    for (final FluentArchivedColumn a in expired) {
      changes.add(_change(FluentSchemaChangeKind.purgeArchive, 'purged archived column "${a.archivedAs}" (older than ${ctx.archiveRetention!.inDays} days)', subject: a.archivedAs));
    }
    for (final MapEntry<String, String> r in renames.entries) {
      changes.add(_change(FluentSchemaChangeKind.renameColumn, 'renamed column "${r.value}" to "${r.key}"', subject: r.key));
    }
    for (final FluentDbColumn c in added) {
      changes.add(_change(FluentSchemaChangeKind.addColumn, 'added column "${c.name}"${pending.contains(c.name) ? ' (NOT NULL pending)' : ''}', subject: c.name));
    }
    for (final String name in changed) {
      changes.add(_change(FluentSchemaChangeKind.changeColumn, enforcePending && snapshot.pendingNotNull.contains(name) ? 'enforced NOT NULL on "$name"' : 'changed definition of "$name"', subject: name));
    }
    if (keyChanged) changes.add(_change(FluentSchemaChangeKind.primaryKey, 'primary key ${snapshot.key} → ${desired.key}'));
    if (checksChanged) changes.add(_change(FluentSchemaChangeKind.constraints, 'table CHECK constraints changed'));
    if (rowIdChanged) changes.add(_change(FluentSchemaChangeKind.constraints, desired.withoutRowId ? 'converted to WITHOUT ROWID' : 'converted to a rowid table'));

    await _rebuild(txn, target, copyFrom, desired, managedIndexes: snapshot.indexes.keys.toSet(), revision: nextRevision, changes: changes);
    changes.add(_change(FluentSchemaChangeKind.rebuildTable, 'rebuilt table'));

    snapshot.columns
      ..clear()
      ..addAll({for (final FluentDbColumn c in desired.columns) c.name: target[c.name]!, for (final String name in keptForSteps) name: target[name]!});
    snapshot.key
      ..clear()
      ..addAll(desired.key);
    snapshot.checks
      ..clear()
      ..addAll(desired.checks);
    snapshot.withoutRowId = desired.withoutRowId;
    snapshot.archived
      ..clear()
      ..addAll(archives);
    snapshot.pendingNotNull
      ..clear()
      ..addAll(pending);

    await _syncIndexes(txn, desired, snapshot, changes, rebuilt: true);
  }

  /// Warns about changes that keep the data but probably not as meant: a changed column type, a column that looks
  /// renamed without `oldName`, and a column back in the model whose old values are archived.
  Future<void> _reportDataRisks(
    _DesiredSchema desired,
    FluentTableSnapshot snapshot,
    FluentSchemaSyncContext ctx, {
    required Map<String, String> renames,
    required List<FluentDbColumn> added,
    required List<String> removed,
    required List<String> changed,
    required Set<String> stepDrops,
    required Future<bool> Function() hasRows,
  }) async {
    final Set<String> restoring = {
      for (final FluentDbMigration step in modelSample.migrations)
        if (step.label != null && !snapshot.steps.containsKey(step.label)) ...step.restoreColumns.values,
    };

    for (final String name in changed) {
      final String? applied = snapshot.columns[renames[name] ?? name];
      if (applied == null) continue;
      final String from = _declaredType(applied);
      final String to = _declaredType(desired.definitions[name]!);
      if (_affinity(from) == _affinity(to) || !await hasRows()) continue;
      FluentLog.issue(
        FluentIssueKind.columnTypeChanged,
        'Column "$name" of "$tableName" changes from $from to $to; the existing values are copied as they are.',
        details: 'SQLite converts the values that fit the new type (e.g. the text "12" to the number 12); the others stay as they were, '
            'and the model may not be able to read them.',
        table: tableName,
        database: dbName,
        subject: name,
        tag: '$tableName:schema',
        hint: 'Convert the values with a step, or revert the type if the change was a mistake.',
        code: "FluentDbMigration(id: '${name}_to_${to.toLowerCase()}', rawSql: ['UPDATE $tableName SET $name = CAST($name AS $to)']),",
      );
    }

    final List<String> lost = [for (final String r in removed) if (!stepDrops.contains(r)) r];
    // Keys and the library's own columns (expiry, trash, times, metadata) are never the new name of a user column.
    final Set<String> library = {
      _expiryColumn,
      '_fs_metadata',
      ?_softDeleteColumn,
      if (_timestampColumns case (:final String created, :final String updated)) ...[created, updated],
    };
    final List<FluentDbColumn> candidates = [for (final FluentDbColumn c in added) if (!c.isPrimaryKey && !desired.key.contains(c.name) && !library.contains(c.name)) c];
    if (lost.isNotEmpty && candidates.isNotEmpty && await hasRows()) {
      for (final String old in lost) {
        final String? oldType = snapshot.columns[old];
        if (oldType == null) continue;
        final List<FluentDbColumn> sameType = [for (final FluentDbColumn c in candidates) if (_affinity(_declaredType(desired.definitions[c.name]!)) == _affinity(_declaredType(oldType))) c];
        if (sameType.length != 1 || restoring.contains(sameType.single.name)) continue;
        final String now = sameType.single.name;
        final bool dropped = ctx.removal == FluentColumnRemoval.drop;
        FluentLog.issue(
          FluentIssueKind.possibleRename,
          'Column "$old" of "$tableName" was removed and "$now" of the same type added; if it is a rename, the values of "$old" '
              '${dropped ? 'were dropped' : 'were archived'} and "$now" starts empty.',
          table: tableName,
          database: dbName,
          subject: now,
          tag: '$tableName:schema',
          hint: dropped
              ? 'Rename columns with oldName on the new column; the values of "$old" are gone (removedColumns: drop).'
              : 'Bring the values back once with restoreColumns, and rename with oldName next time.',
          code: dropped ? "FluentDbColumn(name: '$now', oldName: '$old', ...)" : "FluentDbMigration(id: 'restore_$old', restoreColumns: {'$old': '$now'}),",
        );
      }
    }

    for (final FluentDbColumn c in added) {
      if (restoring.contains(c.name)) continue;
      final FluentArchivedColumn? archive = snapshot.archived.where((a) => a.original == c.name).fold<FluentArchivedColumn?>(null, (best, a) => best == null || a.revision > best.revision ? a : best);
      if (archive == null || _affinity(archive.type) != _affinity(_declaredType(desired.definitions[c.name]!))) continue;
      FluentLog.issue(
        FluentIssueKind.columnRestorable,
        'Column "${c.name}" of "$tableName" is back in the model and starts empty; its earlier values are archived in "${archive.archivedAs}".',
        details: 'The library does not bring them back by itself: a column with the same name may mean something else now.',
        table: tableName,
        database: dbName,
        subject: c.name,
        tag: '$tableName:schema',
        hint: 'If it is the same data, restore it once with a migration step.',
        code: "FluentDbMigration(id: 'restore_${c.name}', restoreColumns: {'${c.name}': '${c.name}'}),",
      );
    }
  }

  /// Archives or drops the removed column [name] with one `ALTER TABLE` instead of a rebuild; `false` when SQLite
  /// cannot (old version, the column is a key, NOT NULL without default, CHECK, indexed, ...) and a rebuild is needed.
  Future<bool> _removeInPlace(
    Transaction txn,
    String name,
    _DiskColumn disk,
    _DiskTable onDisk,
    FluentTableSnapshot snapshot,
    FluentSchemaSyncContext ctx,
    List<FluentSchemaChange> changes, {
    required int revision,
    required bool drop,
  }) async {
    final String table = tableName.quotedIdentifier;
    if (drop) {
      if (!ctx.supportsDropColumn || !await _alterInPlace(txn, 'ALTER TABLE $table DROP COLUMN ${name.quotedIdentifier}')) return false;
      snapshot.columns.remove(name);
      changes.add(_change(FluentSchemaChangeKind.dropColumn, 'dropped column "$name" with its data', subject: name));
      return true;
    }
    // The renamed column keeps its definition, so only a plain one may stay: rows written without it must still be
    // accepted, and a REFERENCES ... ON DELETE CASCADE / SET NULL would keep deleting rows or clearing the archive.
    // Decided from the table as it is on disk (a snapshot of an adopted table may not know every rule).
    final String body = _definitionBody(onDisk.columns[name] ?? snapshot.columns[name] ?? '').toUpperCase();
    final RegExp mentions = RegExp('(^|[^A-Za-z0-9_])"?${RegExp.escape(name)}"?([^A-Za-z0-9_]|\$)', caseSensitive: false);
    final bool keepsRules =
        disk.pk > 0 ||
        (disk.notNull && disk.defaultValue == null) ||
        body.contains('PRIMARY KEY') ||
        body.contains('CHECK') ||
        body.contains('REFERENCES') ||
        body.contains('UNIQUE') ||
        (body.contains('NOT NULL') && !body.contains('DEFAULT')) ||
        onDisk.constraints.any(mentions.hasMatch);
    if (!ctx.supportsRenameColumn || keepsRules) return false;
    final String archivedAs = '$_archivePrefix${name}_r$revision';
    if (!await _alterInPlace(txn, 'ALTER TABLE $table RENAME COLUMN ${name.quotedIdentifier} TO ${archivedAs.quotedIdentifier}')) return false;
    snapshot.columns.remove(name);
    snapshot.archived.add(FluentArchivedColumn(original: name, archivedAs: archivedAs, type: disk.type, revision: revision, removedAt: ctx.now));
    changes.add(_change(FluentSchemaChangeKind.archiveColumn, 'archived column "$name" as "$archivedAs"', subject: name));
    _reportArchived(name, archivedAs);
    return true;
  }

  /// Runs one `ALTER TABLE`; `false` when SQLite refuses it (the statement changes nothing then).
  Future<bool> _alterInPlace(Transaction txn, String sql) async {
    try {
      FluentLog.sql(sql, tag: '$tableName:schema');
      await txn.execute(sql);
      return true;
    } on DatabaseException catch (e) {
      FluentLog.debug('In-place change of "$tableName" not possible, the table is rebuilt instead: $e', tag: '$tableName:schema');
      return false;
    }
  }

  void _reportArchived(String name, String archivedAs) {
    FluentLog.issue(
      FluentIssueKind.columnArchived,
      'Column "$name" of "$tableName" is no longer in the model; its data is kept in "$archivedAs".',
      table: tableName,
      database: dbName,
      subject: name,
      tag: '$tableName:schema',
      hint: 'It is purged after the archive retention period. To delete it now use FluentDbMigration(id: "drop_$name", dropColumns: ["$name"]); '
          'to bring it back use restoreColumns: {"$name": "<column>"}.',
    );
  }

  void _warnPendingNotNull(FluentDbColumn c) {
    FluentLog.issue(
      FluentIssueKind.columnKeptNullable,
      'Column "${c.name}" of "$tableName" is NOT NULL without a default, but existing rows have no value; it stays nullable for now.',
      table: tableName,
      tag: '$tableName:schema',
      hint: 'Give it a defaultValue, or fill the column (e.g. FluentDbMigration rawSql: UPDATE ... SET ${c.name} = ...). '
          'NOT NULL is enforced automatically on a later start once no row is NULL.',
    );
  }

  /// Copies the rows of the table into the rebuilt [temp] table. [sources] maps every target column to the SQL that
  /// reads its value from the old table (`s`); [rowId] copies the rowid too (FTS content and other references to
  /// rowids stay valid).
  ///
  /// Rows the new schema rejects (a new / stricter CHECK, a new UNIQUE or key) are never dropped: they are moved to
  /// the quarantine table `__fluent_rejected_<table>_r<revision>` with a warning that says how to fix and restore them.
  /// They are found by the copied key, or row by row ([sourceKey]: rowid, or the old key of a WITHOUT ROWID table) when
  /// the key does not tell them apart. When every row would be rejected the schema itself is probably wrong, so the
  /// error is kept (nothing changes).
  Future<void> _copyRows(
    Transaction txn,
    String temp,
    Map<String, String> copyFrom,
    Map<String, String> sources,
    _DesiredSchema desired, {
    required bool rowId,
    required List<String> sourceKey,
    required int revision,
    required List<FluentSchemaChange> changes,
  }) async {
    final String table = tableName.quotedIdentifier;
    final String targets = [if (rowId) '"rowid"', ...copyFrom.keys.map((c) => c.quotedIdentifier)].join(', ');
    final String values = [if (rowId) 's."rowid"', for (final String c in copyFrom.keys) sources[c]!].join(', ');
    try {
      await txn.execute('INSERT INTO $temp ($targets) SELECT $values FROM $table s');
      return;
    } on DatabaseException catch (e) {
      final String text = e.toString();
      if (!_rejectsRow(e)) rethrow;
      final int total = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $table')) ?? 0;
      // A name no table has yet: two rebuilds of one sync (a structure change and a step) must not share a quarantine,
      // and an earlier quarantine table is never overwritten.
      String quarantine = '__fluent_rejected_${tableName}_r$revision';
      for (int n = 2; (await txn.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [quarantine])).isNotEmpty; n++) {
        quarantine = '__fluent_rejected_${tableName}_r${revision}_$n';
      }
      final String q = quarantine.quotedIdentifier;
      final String restoreId = quarantine.substring('__fluent_rejected_${tableName}_r'.length);
      int rejected = 0;

      // Fast path: copy what fits, then find the rejected rows by the copied key.
      final bool keyCopied = desired.key.isNotEmpty && desired.key.every(copyFrom.containsKey);
      if (keyCopied) {
        await txn.execute('DELETE FROM $temp');
        await txn.execute('INSERT OR IGNORE INTO $temp ($targets) SELECT $values FROM $table s');
        final String missing = 'NOT EXISTS (SELECT 1 FROM $temp t WHERE ${desired.key.map((k) => 't.${k.quotedIdentifier} IS ${sources[k]!}').join(' AND ')})';
        final int copied = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $temp')) ?? 0;
        rejected = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $table s WHERE $missing')) ?? 0;
        // Valid only when every row not copied is found by its key (duplicates of a new key are not).
        if (rejected > 0 && rejected < total && copied + rejected == total) {
          await txn.execute('DROP TABLE IF EXISTS $q');
          await txn.execute('CREATE TABLE $q AS SELECT * FROM $table s WHERE $missing');
        } else {
          rejected = 0;
        }
      }

      // Row by row: each row is copied or moved to the quarantine on its own.
      if (rejected == 0 && sourceKey.isNotEmpty) {
        await txn.execute('DELETE FROM $temp');
        await txn.execute('DROP TABLE IF EXISTS $q');
        await txn.execute('CREATE TABLE $q AS SELECT * FROM $table WHERE 0');
        final String match = sourceKey.map((c) => 's.${c.quotedIdentifier} IS ?').join(' AND ');
        // Aliased: SQLite names a selected rowid after its INTEGER PRIMARY KEY column.
        final String ids = [for (int i = 0; i < sourceKey.length; i++) '${sourceKey[i].quotedIdentifier} AS "k$i"'].join(', ');
        final String order = [for (int i = 0; i < sourceKey.length; i++) '"k$i"'].join(', ');
        for (final Map<String, Object?> row in await txn.rawQuery('SELECT $ids FROM $table ORDER BY $order')) {
          final List<Object?> args = [for (int i = 0; i < sourceKey.length; i++) row['k$i']];
          try {
            await txn.execute('INSERT INTO $temp ($targets) SELECT $values FROM $table s WHERE $match', args);
          } on DatabaseException catch (rowError) {
            if (!_rejectsRow(rowError)) rethrow;
            await txn.execute('INSERT INTO $q SELECT * FROM $table s WHERE $match', args);
            rejected++;
          }
        }
      }
      if (rejected == 0 || rejected == total) {
        await txn.execute('DROP TABLE IF EXISTS $q');
        rethrow;
      }

      changes.add(_change(FluentSchemaChangeKind.quarantineRows, 'moved $rejected row(s) the new schema rejects to "$quarantine"'));
      FluentLog.issue(
        FluentIssueKind.rowsQuarantined,
        '$rejected of $total row(s) of "$tableName" violate the new schema (${_constraintName(text)}); they were moved to "$quarantine", nothing was deleted.',
        table: tableName,
        tag: '$tableName:schema',
        hint: 'Look at them: rawQuery(\'SELECT * FROM $quarantine\'). Fix and move them back with a migration step, e.g. '
            'FluentDbMigration(id: "restore_rejected_$restoreId", rawSql: [\'INSERT INTO $tableName (...) SELECT ... FROM $quarantine WHERE <now valid>\', '
            '\'DROP TABLE $quarantine\']). To undo the schema change, revert the model: the rows are still in the quarantine table.',
      );
    }
  }

  /// Whether [e] is a constraint a row breaks (UNIQUE / key / CHECK): such rows go to the quarantine.
  static bool _rejectsRow(DatabaseException e) {
    final String text = e.toString();
    return e.isUniqueConstraintError() || text.contains('CHECK constraint') || text.contains('UNIQUE constraint');
  }

  static String _constraintName(String text) => RegExp(r'(\w+ constraint failed[^,)\n]*)').firstMatch(text)?.group(1) ?? 'constraint failed';

  /// Rebuilds the table as [target] (name → definition), copying data from [copyFrom] (target → source column).
  ///
  /// Foreign keys must be off (FluentDb does this before the schema transaction). Views, triggers and indexes the
  /// app created itself (not in [managedIndexes] or the model) are recreated; one that no longer fits is reported
  /// and recorded as [FluentSchemaChangeKind.viewOrTriggerLost]. Rowids, the AUTOINCREMENT counter and NOT NULL
  /// columns with a default (NULLs get the default) are carried over.
  Future<void> _rebuild(
    Transaction txn,
    Map<String, String> target,
    Map<String, String> copyFrom,
    _DesiredSchema desired, {
    required Set<String> managedIndexes,
    required int revision,
    required List<FluentSchemaChange> changes,
  }) async {
    final String table = tableName.quotedIdentifier;
    final String tempName = '__fluent_tmp_$tableName';
    final String temp = tempName.quotedIdentifier;

    final List<Map<String, Object?>> dependents = [
      for (final Map<String, Object?> d in await txn.rawQuery(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND "
        "((type IN ('trigger', 'index') AND tbl_name = ?) OR (type IN ('view', 'trigger') AND sql LIKE ?))",
        [tableName, '%$tableName%'],
      ))
        if (d['type'] != 'index' || !_libraryIndex(d['name']! as String, desired, managedIndexes)) d,
    ];
    // Views and triggers of other tables that use this table would stop the rename below ("no such table").
    for (final Map<String, Object?> d in dependents) {
      final String name = (d['name']! as String).quotedIdentifier;
      if (d['type'] == 'view') await txn.execute('DROP VIEW IF EXISTS $name');
      if (d['type'] == 'trigger') await txn.execute('DROP TRIGGER IF EXISTS $name');
    }

    final List<_DiskColumn> sourceColumns = await _diskColumns(txn);
    final _DiskTable source = await _diskTable(txn);
    Future<bool> hasSequenceTable() async => (await txn.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")).isNotEmpty;
    final int? sequence = await hasSequenceTable() ? Sqflite.firstIntValue(await txn.rawQuery('SELECT seq FROM sqlite_sequence WHERE name = ?', [tableName])) : null;

    await txn.execute('DROP TABLE IF EXISTS $temp');
    final String createSql = _tableSql(tempName, target.values, desired);
    FluentLog.sql(createSql, tag: '$tableName:schema');
    await txn.execute(createSql);

    if (copyFrom.isNotEmpty) {
      // A NOT NULL column with a default takes the default where the old column has NULL (as an ADD COLUMN would).
      final Map<String, String> sources = {for (final MapEntry<String, String> c in copyFrom.entries) c.key: 's.${c.value.quotedIdentifier}'};
      bool rowIdAlias = false;
      for (final Map<String, Object?> info in await txn.rawQuery('PRAGMA table_info($temp)')) {
        final String name = info['name']! as String;
        final int pk = (info['pk'] as int?) ?? 0;
        if (pk == 1 && desired.key.length == 1 && ((info['type'] as String?) ?? '').toUpperCase() == 'INTEGER') rowIdAlias = true;
        final String? fallback = info['dflt_value'] as String?;
        if (info['notnull'] == 1 && pk == 0 && fallback != null && sources.containsKey(name)) sources[name] = 'COALESCE(${sources[name]}, ($fallback))';
      }
      // Rowids are kept, unless the new table's INTEGER PRIMARY KEY (the rowid itself) is copied.
      final bool rowId = !source.withoutRowId && !desired.withoutRowId && !(rowIdAlias && copyFrom.containsKey(desired.key.single));
      final List<_DiskColumn> oldKey = sourceColumns.where((d) => d.pk > 0).toList()..sort((a, b) => a.pk.compareTo(b.pk));
      final List<String> sourceKey = source.withoutRowId ? [for (final _DiskColumn d in oldKey) d.name] : const ['rowid'];
      await _copyRows(txn, temp, copyFrom, sources, desired, rowId: rowId, sourceKey: sourceKey, revision: revision, changes: changes);
    }
    await txn.execute('DROP TABLE $table');
    await txn.execute('ALTER TABLE $temp RENAME TO $table');

    // AUTOINCREMENT: the copy only knows the highest id left; ids of deleted rows must not come back.
    if (sequence != null && createSql.toUpperCase().contains('AUTOINCREMENT') && await hasSequenceTable()) {
      final int? now = Sqflite.firstIntValue(await txn.rawQuery('SELECT seq FROM sqlite_sequence WHERE name = ?', [tableName]));
      if (now == null) {
        await txn.rawInsert('INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)', [tableName, sequence]);
      } else if (now < sequence) {
        await txn.rawUpdate('UPDATE sqlite_sequence SET seq = ? WHERE name = ?', [sequence, tableName]);
      }
    }

    // Views first (triggers may use them), then triggers and the app's own indexes.
    final List<Map<String, Object?>> ordered = [...dependents.where((d) => d['type'] == 'view'), ...dependents.where((d) => d['type'] != 'view')];
    for (final Map<String, Object?> d in ordered) {
      try {
        await txn.execute(d['sql']! as String);
        // SQLite accepts a view on a missing column and fails only when it is read: try it, and drop it when it is broken
        // (a broken view would also stop every later ALTER TABLE of the database).
        if (d['type'] == 'view') {
          try {
            await txn.rawQuery('SELECT 1 FROM ${(d['name']! as String).quotedIdentifier} LIMIT 0');
          } catch (_) {
            await txn.execute('DROP VIEW IF EXISTS ${(d['name']! as String).quotedIdentifier}');
            rethrow;
          }
        }
      } catch (e) {
        changes.add(_change(FluentSchemaChangeKind.viewOrTriggerLost, 'could not recreate ${d['type']} "${d['name']}" (it is gone)', subject: d['name']! as String));
        FluentLog.issue(
          FluentIssueKind.viewOrTrigger,
          'Could not recreate ${d['type']} "${d['name']}" after rebuilding "$tableName": $e',
          table: tableName,
          tag: '$tableName:schema',
          hint: 'It probably uses a column that was removed or renamed. Recreate it with the updated SQL:\n${d['sql']}',
        );
      }
    }
    await _reportBrokenTriggers(txn, ordered);
  }

  /// Finds recreated triggers that no longer fit their tables. SQLite accepts a trigger on a missing column and fails
  /// only when it fires (and then fails every write that fires it). But it compiles the triggers of a table when a
  /// statement that fires them is prepared, so `EXPLAIN INSERT / UPDATE / DELETE` (nothing is executed) reports a broken
  /// body. The error does not name the trigger, so each one is tried alone: inside a savepoint that is rolled back
  /// afterwards, every other trigger is dropped. The trigger is kept (it is the app's code): the issue names it and has
  /// the SQL to fix it. A table that cannot be prepared even without triggers is not judged.
  Future<void> _reportBrokenTriggers(Transaction txn, List<Map<String, Object?>> recreated) async {
    final Set<String> names = {
      for (final Map<String, Object?> d in recreated)
        if (d['type'] == 'trigger' && !(d['name']! as String).startsWith('__fluent_')) d['name']! as String,
    };
    if (names.isEmpty) return;
    final List<Map<String, Object?>> triggers = [
      for (final Map<String, Object?> r in await txn.rawQuery("SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL")) r,
    ];
    // The dependents were found by a substring search: only triggers on this table or naming it as a word are judged.
    final RegExp mentions = RegExp('(^|[^A-Za-z0-9_])["`]?${RegExp.escape(tableName)}["`]?([^A-Za-z0-9_]|\$)', caseSensitive: false);
    final List<Map<String, Object?>> mine = [
      for (final Map<String, Object?> r in triggers)
        if (names.contains(r['name']) && (r['tbl_name'] == tableName || mentions.hasMatch(_afterTriggerName(r['sql']! as String)))) r,
    ];
    if (mine.isEmpty) return;

    Future<String?> failure(Map<String, Object?> trigger) async {
      final String owner = trigger['tbl_name']! as String;
      final String table = owner.quotedIdentifier;
      final List<String> columns = [for (final Map<String, Object?> c in await txn.rawQuery('PRAGMA table_info($table)')) (c['name']! as String).quotedIdentifier];
      if (columns.isEmpty) return null;
      final String assign = columns.map((c) => '$c = $c').join(', ');
      for (final String sql in ['INSERT INTO $table DEFAULT VALUES', 'UPDATE $table SET $assign', 'DELETE FROM $table']) {
        try {
          await txn.rawQuery('EXPLAIN $sql');
        } on DatabaseException catch (e) {
          return '$e';
        }
      }
      return null;
    }

    final Map<String, String> broken = {};
    const String savepoint = 'fluent_trigger_check';
    await txn.execute('SAVEPOINT $savepoint');
    try {
      for (final Map<String, Object?> t in mine) {
        await txn.execute('ROLLBACK TO $savepoint');
        for (final Map<String, Object?> other in triggers) {
          await txn.execute('DROP TRIGGER IF EXISTS ${(other['name']! as String).quotedIdentifier}');
        }
        // Without any trigger the table must prepare, otherwise the failure is not the trigger's.
        if (await failure(t) != null) continue;
        await txn.execute(t['sql']! as String);
        final String? error = await failure(t);
        if (error != null) broken[t['name']! as String] = error;
      }
    } finally {
      await txn.execute('ROLLBACK TO $savepoint');
      await txn.execute('RELEASE $savepoint');
    }
    for (final MapEntry<String, String> b in broken.entries) {
      final String sql = mine.firstWhere((t) => t['name'] == b.key)['sql']! as String;
      FluentLog.issue(
        FluentIssueKind.brokenTrigger,
        'Trigger "${b.key}" no longer fits the schema after "$tableName" was rebuilt: ${_triggerReason(b.value)}; the writes that fire it will fail.',
        details: FluentLog.redact(b.value),
        table: tableName,
        subject: b.key,
        tag: '$tableName:schema',
        hint: 'It was kept as it is (it is your code). Replace it with SQL that fits the new table:',
        code: 'DROP TRIGGER IF EXISTS ${b.key.quotedIdentifier};\n$sql;',
      );
    }
  }

  /// The part of a `CREATE TRIGGER` statement after its name (the name itself could contain the table's name).
  static String _afterTriggerName(String sql) {
    final RegExpMatch? m = RegExp(r'\b(BEFORE|AFTER|INSTEAD)\b', caseSensitive: false).firstMatch(sql);
    return m == null ? sql : sql.substring(m.start);
  }

  /// The short reason out of a SQLite prepare error (`no such column: nick`).
  static String _triggerReason(String error) => RegExp(r'(no such \w+: [^\s,)]+)').firstMatch(error)?.group(1) ?? 'SQLite rejects it';

  /// Whether index [name] belongs to the library: the ones it recorded as created ([managed], the snapshot). Every
  /// other index is the app's, whatever its name (also one named like an index of the model).
  bool _libraryIndex(String name, _DesiredSchema desired, Set<String> managed) => managed.contains(name);

  /// Creates new / changed indexes and drops removed ones (only indexes the library created).
  Future<void> _syncIndexes(Transaction txn, _DesiredSchema desired, FluentTableSnapshot snapshot, List<FluentSchemaChange> changes, {required bool rebuilt}) async {
    final Map<String, String> previous = rebuilt ? const {} : Map.of(snapshot.indexes);
    final Map<String, String> applied = {};

    for (final MapEntry<String, FluentIndex> entry in desired.indexes.entries) {
      final String wanted = _normalizeSql(entry.value.createSql(tableName));
      if (previous[entry.key] == wanted) {
        applied[entry.key] = wanted;
        continue;
      }
      if (previous.containsKey(entry.key)) {
        await txn.execute('DROP INDEX IF EXISTS ${entry.key.quotedIdentifier}');
      } else {
        // An index of this name the library did not create is the app's: it is neither adopted nor replaced.
        final Map<String, Object?>? existing = (await txn.rawQuery("SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND name = ?", [entry.key])).firstOrNull;
        if (existing != null) {
          final String? existingSql = existing['sql'] as String?;
          if (existing['tbl_name'] == tableName && existingSql != null && _normalizeSql(existingSql) == wanted) {
            applied[entry.key] = wanted;
          } else {
            FluentLog.issue(
              FluentIssueKind.indexSkipped,
              'Index "${entry.key}" of the model for "$tableName" was not created: an index with this name already exists in the database${existing['tbl_name'] == tableName ? ' with another definition' : ' on table "${existing['tbl_name']}"'}.',
              table: tableName,
              subject: entry.key,
              tag: '$tableName:schema',
              hint: 'The existing index was not created by the library, so it is left alone. Give the index in $modelType.indexes another name (FluentIndex(name: "...")), '
                  'or drop the existing one yourself.',
              context: {'indexName': entry.key, 'sql': existingSql},
            );
          }
          continue;
        }
      }
      if (await _createIndexSafely(txn, entry.value)) {
        applied[entry.key] = wanted;
        changes.add(_change(FluentSchemaChangeKind.createIndex, '${previous.containsKey(entry.key) ? 'recreated' : 'created'} index "${entry.key}"', subject: entry.key));
      }
    }
    for (final String name in previous.keys) {
      if (desired.indexes.containsKey(name)) continue;
      await txn.execute('DROP INDEX IF EXISTS ${name.quotedIdentifier}');
      changes.add(_change(FluentSchemaChangeKind.dropIndex, 'dropped index "$name"', subject: name));
    }
    snapshot.indexes
      ..clear()
      ..addAll(applied);
  }

  /// Runs pending one-time steps of [FluentStorable.migrations] in declaration order.
  Future<void> _applySteps(Transaction txn, FluentTableSnapshot snapshot, _DesiredSchema desired, FluentSchemaSyncContext ctx, List<FluentSchemaChange> changes, {required bool fresh}) async {
    for (final FluentDbMigration step in modelSample.migrations) {
      if (!step.hasSteps) continue;
      final String? label = step.label;
      if (label == null) {
        FluentLog.issue(
          FluentIssueKind.migrationSkipped,
          'Migration step of "$tableName" skipped: it has no version or id.',
          table: tableName,
          tag: '$tableName:migration',
          hint: 'One-time steps run once per database, so they need a label: FluentDbMigration(version: 2, ...) or FluentDbMigration(id: "fix_names", ...).',
        );
        continue;
      }
      final String hash = step.contentHash;
      final String? appliedHash = snapshot.steps[label];
      if (appliedHash != null) {
        if (appliedHash.isNotEmpty && appliedHash != hash) {
          FluentLog.issue(
            FluentIssueKind.migrationSkipped,
            'Migration step "$label" of "$tableName" was changed after it had been applied; it will not run again.',
            table: tableName,
            tag: '$tableName:migration',
            hint: 'Give new steps a new version / id instead of editing an applied one.',
          );
        }
        continue;
      }
      if (fresh) {
        snapshot.steps[label] = hash;
        if (step.rawSql.any((sql) => RegExp(r'^\s*(INSERT|REPLACE)\b', caseSensitive: false).hasMatch(sql))) {
          FluentLog.issue(
            FluentIssueKind.stepOnNewTable,
            'Step "$label" of "$tableName" inserts rows, but the table was just created, so the step was only marked as applied.',
            details: 'Steps change data that already exists; on a new install there is none, so they never run there.',
            table: tableName,
            database: dbName,
            subject: label,
            tag: '$tableName:migration',
            hint: 'Create rows every install needs in code after init (e.g. when count() is 0), not in a migration step.',
            code: 'if (await FluentDb.count<$modelType>() == 0) await FluentDb.saveAll<$modelType>([...]);',
          );
        }
        continue;
      }

      try {
        for (final String sql in step.rawSql) {
          FluentLog.sql(sql, tag: '$tableName:migration');
          await txn.execute(sql);
        }
        if (step.rawSql.isNotEmpty) changes.add(_change(FluentSchemaChangeKind.runStep, 'step "$label": ${step.rawSql.length} SQL statement(s)', subject: label));

        final Set<String> dropArchives = {};
        final List<String> dropLive = [];
        for (final String name in step.dropColumns) {
          if (desired.definitions.containsKey(name)) {
            FluentLog.issue(
              FluentIssueKind.migrationSkipped,
              'dropColumns of step "$label": "$name" is still part of the model, so it is kept.',
              tag: '$tableName:migration',
              hint: 'Remove "$name" from the model (buildJson / tableSchema) first; the step only deletes columns the model no longer has.',
            );
            continue;
          }
          dropArchives.addAll([for (final FluentArchivedColumn a in snapshot.archived) if (a.original == name) a.archivedAs]);
          dropLive.add(name);
        }

        for (final MapEntry<String, String> r in step.restoreColumns.entries) {
          final List<FluentArchivedColumn> candidates = [for (final FluentArchivedColumn a in snapshot.archived) if (a.original == r.key) a]..sort((a, b) => b.revision.compareTo(a.revision));
          if (candidates.isEmpty) {
            FluentLog.issue(FluentIssueKind.migrationSkipped, 'restoreColumns of step "$label": no archived column "${r.key}" in "$tableName".', table: tableName, tag: '$tableName:migration', hint: snapshot.archived.isEmpty ? '"$tableName" has no archived columns; remove the step.' : 'Archived columns of "$tableName": ${snapshot.archived.map((a) => a.original).join(', ')}. Use the original column name.');
            continue;
          }
          final FluentArchivedColumn archive = candidates.first;
          final FluentDbColumn? targetColumn = desired.columns.where((c) => c.name == r.value).firstOrNull;
          if (targetColumn == null) {
            throw FluentSchemaException(
              'restoreColumns target "${r.value}" of step "$label" is not a column of "$tableName".',
              modelName: tableName,
              columnName: r.value,
              hint: 'Add "${r.value}" to the model first, then restore "${r.key}" into it.',
            );
          }
          final String targetType = targetColumn.type == FluentDbDataType.custom ? (targetColumn.customSql ?? '').trim().split(' ').first : targetColumn.type.sql;
          if (_affinity(archive.type) != _affinity(targetType)) {
            throw FluentSchemaException(
              'Archived "${r.key}" of "$tableName" holds ${archive.type} data but "${r.value}" is $targetType.',
              modelName: tableName,
              columnName: r.value,
              hint: 'Restore into a column of the same type, or convert the data with rawSql / onMigrate.',
            );
          }
          await txn.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET ${r.value.quotedIdentifier} = ${archive.archivedAs.quotedIdentifier} WHERE ${archive.archivedAs.quotedIdentifier} IS NOT NULL');
          dropArchives.add(archive.archivedAs);
          changes.add(_change(FluentSchemaChangeKind.restoreColumn, 'step "$label": restored "${r.key}" into "${r.value}"', subject: r.value));
        }

        if (dropArchives.isNotEmpty) {
          final List<FluentArchivedColumn> keep = [for (final FluentArchivedColumn a in snapshot.archived) if (!dropArchives.contains(a.archivedAs)) a];
          final Map<String, String> target = Map.of(snapshot.columns);
          for (final FluentArchivedColumn a in keep) {
            target[a.archivedAs] = '${a.archivedAs.quotedIdentifier} ${a.type}';
          }
          await _rebuild(txn, target, {for (final String c in target.keys) c: c}, desired, managedIndexes: snapshot.indexes.keys.toSet(), revision: snapshot.revision + 1, changes: changes);
          await _syncIndexes(txn, desired, snapshot, changes, rebuilt: true);
          snapshot.archived
            ..clear()
            ..addAll(keep);
          for (final String a in dropArchives) {
            changes.add(_change(FluentSchemaChangeKind.dropColumn, 'step "$label": removed archived column "$a"', subject: a));
          }
        }

        if (step.onMigrate != null) {
          if (ctx.runCode) {
            // Provider calls inside join this transaction instead of waiting for it.
            await FluentTransactionScope(dbName, txn).run(() => step.onMigrate!(txn));
            changes.add(_change(FluentSchemaChangeKind.runStep, 'step "$label": onMigrate', subject: label));
          } else {
            ctx.skippedCode.add('$tableName.$label');
            changes.add(_change(FluentSchemaChangeKind.runStep, 'step "$label": onMigrate (not run for the plan)', subject: label));
          }
        }
        await _dropStepColumns(txn, dropLive, snapshot, desired, ctx, changes, label);
        snapshot.steps[label] = hash;
      } catch (e, st) {
        // Reported once by FluentDb.init, which receives it.
        throw FluentSchemaException(
          'Migration step "$label" of "$tableName" failed${e is FluentException ? ': ${e.message}' : ''}. Nothing was changed: all schema changes were rolled back.',
          modelName: modelSample.runtimeType.toString(),
          code: FluentErrorCode.migrationFailed,
          hint: '${e is FluentException && e.hint != null ? '${e.hint} ' : ''}'
              'Fix the step "$label" in ${modelSample.runtimeType}.migrations. The database is unchanged, so the corrected step runs on the next start.',
          cause: e is FluentException ? e.cause ?? e : e,
          stackTrace: st,
        );
      }
    }
  }

  /// Drops the live columns a finished step lists in `dropColumns` (they were kept while its code ran): with one
  /// `ALTER TABLE` when SQLite can, else with a rebuild.
  Future<void> _dropStepColumns(
    Transaction txn,
    List<String> names,
    FluentTableSnapshot snapshot,
    _DesiredSchema desired,
    FluentSchemaSyncContext ctx,
    List<FluentSchemaChange> changes,
    String label,
  ) async {
    if (names.isEmpty) return;
    final Set<String> onDisk = {for (final _DiskColumn d in await _diskColumns(txn)) d.name};
    final List<String> pendingDrops = [];
    for (final String name in names) {
      if (!onDisk.contains(name)) continue;
      if (ctx.supportsDropColumn && await _alterInPlace(txn, 'ALTER TABLE ${tableName.quotedIdentifier} DROP COLUMN ${name.quotedIdentifier}')) {
        snapshot.columns.remove(name);
        changes.add(_change(FluentSchemaChangeKind.dropColumn, 'step "$label": dropped column "$name" with its data', subject: name));
      } else {
        pendingDrops.add(name);
      }
    }
    if (pendingDrops.isEmpty) return;
    final Map<String, String> target = Map.of(snapshot.columns)..removeWhere((name, _) => pendingDrops.contains(name));
    for (final FluentArchivedColumn a in snapshot.archived) {
      target[a.archivedAs] = '${a.archivedAs.quotedIdentifier} ${a.type}';
    }
    await _rebuild(txn, target, {for (final String c in target.keys) c: c}, desired, managedIndexes: snapshot.indexes.keys.toSet(), revision: snapshot.revision + 1, changes: changes);
    await _syncIndexes(txn, desired, snapshot, changes, rebuilt: true);
    snapshot.columns.removeWhere((name, _) => pendingDrops.contains(name));
    for (final String name in pendingDrops) {
      changes.add(_change(FluentSchemaChangeKind.dropColumn, 'step "$label": dropped column "$name" with its data', subject: name));
    }
  }

  /// Removes archived columns older than `ctx.archiveRetention` right away (see `FluentDb.purgeArchivedColumns`), and
  /// brings the full-text index in line with the table again (its triggers and revision follow a rebuild).
  Future<void> purgeArchives(Transaction txn, FluentSchemaSyncContext ctx) async {
    await syncTable(txn, ctx, existsOnDisk: true);
    await syncFullText(txn, ctx.fullText, changes: ctx.changes);
  }
}
