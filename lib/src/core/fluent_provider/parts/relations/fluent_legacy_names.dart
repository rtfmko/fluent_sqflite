// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// The names a 1.x database used for what a provider stores, where the 1.x rule of [FluentUtils.toSnakeCase]
/// ([FluentUtils.legacySnakeCase]) named them differently (`Item2` → `item_2`, `HTTPLog` → `h_t_t_p_log`). Found by
/// building the relation graph once with the 1.x rule ([buildFluentRelationGraph]); the start renames what it finds
/// under these names ([fluentAdoptLegacyNames]).
class _FluentLegacyNames {
  /// The 1.x name of the provider's table (only for the default `tableName`).
  String? table;

  /// Library columns of this table: current name → 1.x name.
  final Map<String, String> columns = {};

  /// Link tables of this provider's many-to-many relations: current name → 1.x name.
  final Map<String, String> linkTables = {};

  /// Columns of those link tables (by the current link table name): current name → 1.x name.
  final Map<String, Map<String, String>> linkColumns = {};

  /// Type columns of polymorphic references stored in this table (current column name): current value → 1.x value.
  final Map<String, Map<String, String>> typeValues = {};

  bool get isEmpty => table == null && columns.isEmpty && linkTables.isEmpty && linkColumns.isEmpty && typeValues.isEmpty;
}

/// The [_FluentLegacyNames] of each provider of the last graph build (`null`: nothing differs).
final Expando<_FluentLegacyNames> _legacyNames = Expando('fluentLegacyNames');

/// Table name and relation links of one provider after a graph build.
typedef _FluentGraphShape = ({String table, List<FluentRelationLink> links});

/// Runs [build] with the 1.x naming rule and its issues dropped (the real build reports them), and returns the
/// table name and links each provider got; `null` when that build fails (then no 1.x names are looked for).
Map<FluentProvider, _FluentGraphShape>? _legacyGraph(List<FluentProvider> all, void Function() build) {
  try {
    return FluentLog.captureIssuesSync(<FluentIssue>[], () => FluentUtils.withLegacyNames(() {
      build();
      return {for (final FluentProvider p in all) p: (table: p.tableName, links: p._links)};
    }));
  } catch (_) {
    return null;
  }
}

/// Compares the current graph of [all] with the 1.x one ([old]) and keeps the names that differ ([_legacyNames]).
void _recordLegacyNames(List<FluentProvider> all, Map<FluentProvider, _FluentGraphShape>? old) {
  final Map<FluentProvider, _FluentLegacyNames> names = {for (final FluentProvider p in all) p: _FluentLegacyNames()};
  void pair(Map<String, String> into, List<String> now, List<String> was) {
    if (now.length != was.length) return;
    for (int i = 0; i < now.length; i++) {
      if (now[i] != was[i]) into[now[i]] = was[i];
    }
  }

  for (final FluentProvider p in all) {
    final _FluentGraphShape? shape = old?[p];
    if (shape == null) continue;
    if (shape.table != p.tableName) names[p]!.table = shape.table;
    for (final FluentRelationLink link in p._links) {
      final FluentRelationLink? was = shape.links.where((l) => l.name == link.name).firstOrNull;
      if (was == null || was.type != link.type || was.isThrough != link.isThrough || link.isThrough) continue;
      if (link.isManyToMany) {
        final String? table = link.linkTable;
        if (table == null || was.linkTable == null) continue;
        if (table != was.linkTable) names[p]!.linkTables[table] = was.linkTable!;
        final Map<String, String> columns = {};
        pair(columns, link.linkOwnerColumns, was.linkOwnerColumns);
        pair(columns, link.linkTargetColumns, was.linkTargetColumns);
        if (columns.isNotEmpty) names[p]!.linkColumns[table] = columns;
        continue;
      }
      // References and oneOf live in the owner's table, owned children (also polymorphic ones) in the target's.
      final FluentProvider? holder = link.isReference || link.type == FluentRelationType.oneOf ? p : (names.containsKey(link.target) ? link.target : null);
      if (holder == null) continue;
      final _FluentLegacyNames n = names[holder]!;
      pair(n.columns, link.foreignKeys, was.foreignKeys);
      final String? typeColumn = link.typeColumn;
      if (typeColumn == null || was.typeColumn == null) continue;
      if (typeColumn != was.typeColumn) n.columns[typeColumn] = was.typeColumn!;
      final Map<String, String> values = {
        if (link.typeValue != null && was.typeValue != null && link.typeValue != was.typeValue) link.typeValue!: was.typeValue!,
        for (final MapEntry<String, FluentProvider> t in link.targets.entries)
          if (was.targets.entries.where((MapEntry<String, FluentProvider> o) => identical(o.value, t.value)).firstOrNull?.key case final String before when before != t.key) t.key: before,
      };
      if (values.isNotEmpty) n.typeValues.putIfAbsent(typeColumn, () => {}).addAll(values);
    }
  }
  for (final FluentProvider p in all) {
    _legacyNames[p] = names[p]!.isEmpty ? null : names[p];
  }
}

/// Adopts tables, link tables and link columns a 1.x database stored under its own names ([_FluentLegacyNames]),
/// before the tables of [providers] are synchronized in [txn]: renamed when the 1.x name exists and the current one
/// does not (never over existing data), with the library's bookkeeping (schema snapshot, sync state, tombstones,
/// statistics; a full-text index is rebuilt). [existing] (the tables on disk) is updated. Columns of the provider
/// tables are renamed by the schema sync (`oldName` of the reference columns), polymorphic type values by
/// [fluentAdoptLegacyTypeValues]. Each rename is reported (`legacyNameAdopted`) and recorded in [changes].
Future<void> fluentAdoptLegacyNames(Transaction txn, Iterable<FluentProvider> providers, Set<String> existing, List<FluentSchemaChange> changes) async {
  final List<FluentProvider> all = providers.toList(growable: false);
  final Set<String> claimed = {for (final FluentProvider p in all) p.tableName};
  // Old → new: rewrites the relation storage kept in the snapshots, so a renamed relation is not taken as changed.
  final Map<String, String> renamed = {};

  Future<bool> renameTable(FluentProvider p, String from, String to) async {
    if (!existing.contains(from) || claimed.contains(from)) return false;
    if (existing.contains(to)) {
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'Table "$from" (the 1.x name of "$to") was not renamed: "$to" exists too; the rows of "$from" are not used.',
        table: to,
        database: p.dbName,
        subject: from,
        tag: '$to:schema',
        hint: 'Copy the rows you still need from "$from" into "$to" with a migration step, then drop "$from".',
        code: "FluentDbMigration(id: 'adopt_$from', rawSql: ['INSERT OR IGNORE INTO \"$to\" SELECT * FROM \"$from\"', 'DROP TABLE \"$from\"']),",
      );
      return false;
    }
    await txn.execute('ALTER TABLE ${from.quotedIdentifier} RENAME TO ${to.quotedIdentifier}');
    existing
      ..remove(from)
      ..add(to);
    renamed[from] = to;
    changes.add(FluentSchemaChange(kind: FluentSchemaChangeKind.renameTable, table: to, subject: from, description: 'renamed table "$from" (1.x name) to "$to"'));
    FluentLog.issue(
      FluentIssueKind.legacyNameAdopted,
      'Table "$from" was renamed to "$to": 2.0 names tables and columns derived from type names differently.',
      table: to,
      database: p.dbName,
      subject: from,
      tag: '$to:schema',
      hint: 'Nothing to do; set tableName / foreignKey explicitly to choose the names yourself.',
    );
    return true;
  }

  Future<bool> tableExists(String table) async => (await txn.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).isNotEmpty;

  for (final FluentProvider p in all) {
    final _FluentLegacyNames? names = _legacyNames[p];
    if (names == null) continue;
    final String? old = names.table;
    if (old != null && await renameTable(p, old, p.tableName)) {
      final String now = p.tableName;
      if (await tableExists(fluentSchemaTable)) {
        await txn.rawUpdate('UPDATE ${fluentSchemaTable.quotedIdentifier} SET "table_name" = ? WHERE "table_name" = ?', [now, old]);
      }
      for (final String table in const ['__fluent_tombstones', '__fluent_sync_state']) {
        if (await tableExists(table)) await txn.rawUpdate('UPDATE ${table.quotedIdentifier} SET tbl = ? WHERE tbl = ?', [now, old]);
      }
      if (await tableExists('__fluent_stats')) await txn.rawDelete('DELETE FROM "__fluent_stats" WHERE tbl = ?', [old]);
      // The full-text index is derived data: dropped under the old name, the sync builds it again for the new one.
      if (await tableExists('__fluent_fts')) {
        final String fts = '__fluent_fts_$old';
        for (final String suffix in const ['ai', 'ad', 'au', 'bd', 'bu']) {
          await txn.execute('DROP TRIGGER IF EXISTS ${'${fts}_$suffix'.quotedIdentifier}');
        }
        await txn.execute('DROP TABLE IF EXISTS ${fts.quotedIdentifier}');
        await txn.rawDelete('DELETE FROM "__fluent_fts" WHERE tbl = ?', [old]);
      }
    }
    for (final MapEntry<String, String> link in names.linkTables.entries) {
      if (await renameTable(p, link.value, link.key)) {
        // The library's indexes of the link table carry its name: the sync creates them under the new one.
        for (final Map<String, Object?> r in await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [link.key])) {
          final String index = r['name']! as String;
          if (index.startsWith('idx_${link.value}_')) await txn.execute('DROP INDEX IF EXISTS ${index.quotedIdentifier}');
        }
      }
    }
    for (final MapEntry<String, Map<String, String>> link in names.linkColumns.entries) {
      if (!existing.contains(link.key)) continue;
      final Set<String> columns = await _columnsOnDisk(txn, link.key);
      for (final MapEntry<String, String> c in link.value.entries) {
        if (!columns.contains(c.value) || columns.contains(c.key)) continue;
        await txn.execute('ALTER TABLE ${link.key.quotedIdentifier} RENAME COLUMN ${c.value.quotedIdentifier} TO ${c.key.quotedIdentifier}');
        renamed[c.value] = c.key;
        changes.add(FluentSchemaChange(kind: FluentSchemaChangeKind.renameColumn, table: link.key, subject: c.key, description: 'renamed link column "${c.value}" (1.x name) to "${c.key}"'));
      }
    }
    for (final MapEntry<String, String> c in names.columns.entries) {
      renamed[c.value] = c.key; // renamed by the schema sync (oldName)
    }
  }
  if (renamed.isEmpty || !await tableExists(fluentSchemaTable)) return;
  // The relation storage of the snapshots names tables and columns: written with the new names.
  for (final Map<String, Object?> row in await txn.rawQuery('SELECT "table_name", "snapshot" FROM ${fluentSchemaTable.quotedIdentifier}')) {
    final Map<String, dynamic> json = jsonDecode(row['snapshot']! as String) as Map<String, dynamic>;
    final Map<String, dynamic>? relations = json['relations'] as Map<String, dynamic>?;
    if (relations == null || relations.isEmpty) continue;
    final Map<String, String> rewritten = {for (final MapEntry<String, dynamic> e in relations.entries) e.key: _renamedStorage(e.value as String, renamed)};
    if (mapEquals(rewritten, relations.cast<String, String>())) continue;
    json['relations'] = rewritten;
    await txn.rawUpdate('UPDATE ${fluentSchemaTable.quotedIdentifier} SET "snapshot" = ? WHERE "table_name" = ?', [jsonEncode(json), row['table_name']]);
  }
}

/// [storage] (see `_storageOf`) with every table / column name in [renamed] replaced by its new name.
String _renamedStorage(String storage, Map<String, String> renamed) =>
    storage.split('|').map((part) => part.split(',').map((name) => renamed[name] ?? name).join(',')).join('|');

/// After the tables of [providers] are synchronized in [txn]: polymorphic type columns that hold a 1.x table name
/// get the current one (`<relation>_type` stores the table of the referenced row).
Future<void> fluentAdoptLegacyTypeValues(Transaction txn, Iterable<FluentProvider> providers, List<FluentSchemaChange> changes) async {
  for (final FluentProvider p in providers) {
    final Map<String, Map<String, String>> values = _legacyNames[p]?.typeValues ?? const {};
    if (values.isEmpty) continue;
    final Set<String> columns = await _columnsOnDisk(txn, p.tableName);
    for (final MapEntry<String, Map<String, String>> c in values.entries) {
      if (!columns.contains(c.key)) continue;
      for (final MapEntry<String, String> v in c.value.entries) {
        final int n = await txn.rawUpdate('UPDATE ${p.tableName.quotedIdentifier} SET ${c.key.quotedIdentifier} = ? WHERE ${c.key.quotedIdentifier} = ?', [v.key, v.value]);
        if (n == 0) continue;
        changes.add(FluentSchemaChange(kind: FluentSchemaChangeKind.renameTable, table: p.tableName, subject: c.key, description: 'set $n "${c.key}" value(s) "${v.value}" (1.x table name) to "${v.key}"'));
      }
    }
  }
}
