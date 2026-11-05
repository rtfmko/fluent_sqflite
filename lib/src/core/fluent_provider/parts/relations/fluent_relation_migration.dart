// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// How [link] stores its data, kept in the owner's schema snapshot ([FluentTableSnapshot.relations]) to notice when a
/// relation changes its kind between app versions: `link|<table>|<owner columns>|<target columns>`,
/// `owned|<child table>|<reference columns>`, `ref|<reference columns>`, `poly|<type column>|<reference columns>`
/// (a `oneOf` or an owned list through one) or `through|<link model table>`.
String _storageOf(FluentRelationLink link) => link.isThrough
    ? 'through|${link.linkTable}'
    : link.isPolymorphic
    ? 'poly|${link.typeColumn}|${link.foreignKeys.join(',')}'
    : switch (link.type) {
  FluentRelationType.manyToMany => 'link|${link.linkTable}|${link.linkOwnerColumns.join(',')}|${link.linkTargetColumns.join(',')}',
  FluentRelationType.many || FluentRelationType.oneOwned => 'owned|${link.target.tableName}|${link.foreignKeys.join(',')}',
  _ => 'ref|${link.foreignKeys.join(',')}',
};

/// Keeps relation data when a relation changes how it is stored (e.g. `auto` decided `manyToMany` before and `many`
/// now, because the other side got a back-reference). Runs in the schema transaction, [before] holds the snapshots
/// of the last start:
///
/// * `beforeTables: true` (before the tables are synchronized, while the old reference column still exists):
///   a list owned through a reference column became many-to-many → the references are copied into the link table.
/// * `beforeTables: false` (after, when the new reference column exists): many-to-many became an owned list →
///   the links are copied into the reference column, unless a child is linked to several owners (then nothing moves
///   and a warning says why). A reference (`one`) and an owned child (`oneOwned` / `many`) swapped the table that
///   stores the key → the keys are copied to the other table (from the old column, or its archive), unless a row is
///   referenced several times (both sides of a one-to-one pair describe one move, made once). Link tables no
///   relation uses any more are reported (`unusedLinkTable`, kept with their data).
///
/// Every move is reported (`relationDataMoved`) and recorded in [changes]. Only single-column keys are moved;
/// composite keys are reported. Any other change of storage leaves the data where it was and is reported
/// (`relationChanged`).
Future<void> fluentMigrateRelations(
  Transaction txn,
  Iterable<FluentProvider> providers,
  Map<String, FluentTableSnapshot> before, {
  required bool beforeTables,
  List<FluentSchemaChange>? changes,
}) async {
  // `<table>.<column>` written in this pass: the two sides of a one-to-one pair describe the same move.
  final Set<String> movedInto = {};
  for (final FluentProvider p in providers) {
    final Map<String, String> previous = before[p.tableName]?.relations ?? const {};
    if (previous.isEmpty) continue;
    for (final FluentRelationLink link in p._links) {
      if (link.isThrough) continue; // the link model's own table
      final String? stored = previous[link.name];
      if (stored == null || stored == _storageOf(link)) continue;
      final List<String> old = stored.split('|');
      final String was = old.first;
      final int? moved;
      if (link.isManyToMany && was == 'owned') {
        if (!beforeTables) continue;
        moved = await p._ownedToLinks(txn, link, childTable: old[1], references: old[2].split(','));
      } else if (link.isOwned && was == 'link') {
        if (beforeTables) continue;
        moved = await p._linksToOwned(txn, link, linkTable: old[1], ownerColumns: old[2].split(','), targetColumns: old[3].split(','));
      } else if (link.isOwned && !link.isPolymorphic && was == 'ref') {
        if (beforeTables || !movedInto.add('${link.target.tableName}.${link.foreignKeys.join(',')}')) continue;
        moved = await p._referenceToOwned(txn, link, references: old[1].split(','));
      } else if (link.isReference && was == 'owned') {
        if (beforeTables || !movedInto.add('${p.tableName}.${link.foreignKeys.join(',')}')) continue;
        moved = await p._ownedToReference(txn, link, childTable: old[1], references: old[2].split(','));
      } else {
        // Same link table (synchronized in place) or the same polymorphic columns: the data stays usable.
        final bool kept = (was == 'link' && link.isManyToMany && old[1] == link.linkTable) || (was == 'poly' && link.isPolymorphic && old[1] == link.typeColumn);
        if (!beforeTables && !kept) p._notMoved(link, 'it was stored as "$stored" and is "${_storageOf(link)}" now');
        continue;
      }
      if (moved != null) {
        changes?.add(
          FluentSchemaChange(kind: FluentSchemaChangeKind.moveRelationData, table: p.tableName, subject: link.name, description: 'copied $moved link(s) of "${link.name}" to its new storage (${link.type.name})'),
        );
      }
    }
  }
  if (beforeTables) return;

  final Set<String> used = {
    for (final FluentProvider p in providers)
      for (final FluentRelationLink l in p._links) if (l.isManyToMany) l.linkTable!,
  };
  final Set<String> reported = {};
  for (final FluentProvider p in providers) {
    for (final MapEntry<String, String> r in (before[p.tableName]?.relations ?? const <String, String>{}).entries) {
      final List<String> old = r.value.split('|');
      if (old.first != 'link' || used.contains(old[1]) || !reported.add(old[1])) continue;
      if (!await _tableExists(txn, old[1])) continue;
      final int rows = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM ${old[1].quotedIdentifier}')) ?? 0;
      FluentLog.issue(
        FluentIssueKind.unusedLinkTable,
        'The link table "${old[1]}" of "${p.tableName}.${r.key}" is no longer used by any relation; it is kept with its $rows link(s).',
        table: p.tableName,
        database: p.dbName,
        subject: old[1],
        tag: '${p.tableName}:relations',
        hint: 'Drop it with a migration step once you no longer need the links.',
        code: "FluentDbMigration(id: 'drop_${old[1]}', rawSql: ['DROP TABLE IF EXISTS ${old[1]}']),",
      );
    }
  }
}

/// Before the schema of a database is compared: `auto` one-to-one pairs keep the table that stored their key on the
/// last start (see [FluentRelationLink.oneToOne]). When the graph built at init chose the other side (e.g. because an
/// unrelated relation was added), it is built again with the stored relation storage, so no key moves and no
/// reference is lost. Called through [FluentRelationSchema.keepOneToOneSides].
Future<void> _keepOneToOneSides(DatabaseExecutor db, Iterable<FluentProvider> providers) async {
  final List<FluentRelationLink> pairs = [
    for (final FluentProvider p in providers)
      for (final FluentRelationLink l in p._links) if (l.oneToOne) l,
  ];
  if (pairs.isEmpty || !await _tableExists(db, fluentSchemaTable)) return;
  final Map<String, Map<String, String>> stored = {
    for (final FluentTableSnapshot s in await readFluentSchemaSnapshots(db)) if (s.relations.isNotEmpty) s.table: Map<String, String>.of(s.relations),
  };
  // A 1.x database keeps them under the 1.x table name until the start renames it.
  for (final FluentProvider p in providers) {
    final String? old = _legacyNames[p]?.table;
    if (old != null && !stored.containsKey(p.tableName) && stored[old] != null) stored[p.tableName] = stored[old]!;
  }
  final bool switched = pairs.any((l) {
    final String? was = stored[l.owner.tableName]?[l.name];
    return was != null && was.split('|').first != _storageOf(l).split('|').first && !(l.decidedBy?.endsWith(_keptAsStored) ?? false);
  });
  final void Function(Map<String, Map<String, String>>)? rebuild = _graphRebuild[pairs.first.owner];
  if (!switched || rebuild == null) return;
  rebuild(stored);
  for (final FluentProvider p in providers) {
    p.refreshSchema();
  }
}

Future<bool> _tableExists(DatabaseExecutor executor, String table) async =>
    (await executor.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).isNotEmpty;

Future<Set<String>> _columnsOnDisk(DatabaseExecutor executor, String table) async => {
  for (final Map<String, Object?> r in await executor.rawQuery('PRAGMA table_info(${table.quotedIdentifier})')) r['name']! as String,
};

/// The column holding the data of [column] of [table]: the column itself, or its newest archive
/// (`__fluent_removed_<column>_r<revision>`) once the model no longer has it; `null` when neither exists.
Future<String?> _sourceColumn(DatabaseExecutor executor, String table, String column) async {
  final Set<String> columns = await _columnsOnDisk(executor, table);
  if (columns.contains(column)) return column;
  String? newest;
  int revision = -1;
  for (final String c in columns) {
    final RegExpMatch? m = _archiveName.firstMatch(c);
    if (m == null || m.group(1) != column || int.parse(m.group(2)!) <= revision) continue;
    revision = int.parse(m.group(2)!);
    newest = c;
  }
  return newest;
}

/// Moving relation data between the ways it is stored (see [fluentMigrateRelations]).
extension _FluentRelationMigration<T extends FluentStorable> on FluentProvider<T> {
  /// Reports (`relationChanged`) that [link] changed its storage but its data stayed where it was ([why]).
  void _notMoved(FluentRelationLink link, String why) {
    FluentLog.issue(
      FluentIssueKind.relationChanged,
      '"$tableName.${link.name}" changed how it is stored ($why); the existing data was not moved.',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Move the data with a migration step, or keep the earlier storage by declaring the relation as it was '
          '(kind, foreignKey, linkTable). Removed reference columns are archived, so the old values are still there.',
    );
  }

  /// A reference of this table (`<this>.<column>` → target key) became an owned child (`<target>.<fk>` → this key):
  /// the number of keys copied, `null` when nothing could be moved.
  Future<int?> _referenceToOwned(Transaction txn, FluentRelationLink link, {required List<String> references}) async {
    if (!_movable(link, references)) return null;
    final String? source = await _sourceColumn(txn, tableName, references.single);
    if (source == null) {
      _notMoved(link, 'the old column "$tableName.${references.single}" is gone');
      return null;
    }
    final String me = tableName.quotedIdentifier;
    final String from = source.quotedIdentifier;
    final int shared = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM (SELECT 1 FROM $me WHERE $from IS NOT NULL GROUP BY $from HAVING COUNT(*) > 1)')) ?? 0;
    if (shared > 0) {
      _notMoved(link, '$shared ${link.target.modelType} row(s) are referenced by several $modelType rows, but a child has one owner');
      return null;
    }
    final String child = link.target.tableName.quotedIdentifier;
    final String childKey = link.target.keyColumnNames.single.quotedIdentifier;
    final String reference = link.foreignKeys.single.quotedIdentifier;
    await txn.execute(
      'UPDATE $child SET $reference = (SELECT o.${keyColumnNames.single.quotedIdentifier} FROM $me o WHERE o.$from = $child.$childKey) '
      'WHERE $reference IS NULL AND $childKey IN (SELECT $from FROM $me WHERE $from IS NOT NULL)',
    );
    final int moved = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) ?? 0;
    FluentLog.issue(
      FluentIssueKind.relationDataMoved,
      '"$tableName.${link.name}" is stored in "${link.target.tableName}.${link.foreignKeys.single}" now; $moved key(s) were copied from '
          '"$tableName.$source".',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Nothing was lost. If $modelType should keep the key, declare the relation as one.',
      code: "FluentRelation.one<$modelType, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}, foreignKey: '${references.single}'),",
    );
    return moved;
  }

  /// An owned child (`<child>.<column>` → this key) became a reference of this table (`<this>.<fk>` → child key):
  /// the number of keys copied, `null` when nothing could be moved.
  Future<int?> _ownedToReference(Transaction txn, FluentRelationLink link, {required String childTable, required List<String> references}) async {
    if (!_movable(link, references)) return null;
    final String? source = childTable == link.target.tableName ? await _sourceColumn(txn, childTable, references.single) : null;
    if (source == null) {
      _notMoved(link, childTable == link.target.tableName ? 'the old column "$childTable.${references.single}" is gone' : 'it was stored in "$childTable"');
      return null;
    }
    final String child = childTable.quotedIdentifier;
    final String from = source.quotedIdentifier;
    final int shared = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM (SELECT 1 FROM $child WHERE $from IS NOT NULL GROUP BY $from HAVING COUNT(*) > 1)')) ?? 0;
    if (shared > 0) {
      _notMoved(link, '$shared $modelType row(s) own several ${link.target.modelType} rows, but a reference holds one');
      return null;
    }
    final String me = tableName.quotedIdentifier;
    final String key = keyColumnNames.single.quotedIdentifier;
    final String reference = link.foreignKeys.single.quotedIdentifier;
    await txn.execute(
      'UPDATE $me SET $reference = (SELECT c.${link.target.keyColumnNames.single.quotedIdentifier} FROM $child c WHERE c.$from = $me.$key) '
      'WHERE $reference IS NULL AND $key IN (SELECT $from FROM $child WHERE $from IS NOT NULL)',
    );
    final int moved = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) ?? 0;
    FluentLog.issue(
      FluentIssueKind.relationDataMoved,
      '"$tableName.${link.name}" is stored in "$tableName.${link.foreignKeys.single}" now; $moved key(s) were copied from "$childTable.$source".',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Nothing was lost. If ${link.target.modelType} should keep the key, declare the relation as oneOwned.',
      code: "FluentRelation.oneOwned<$modelType, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}, foreignKey: '${references.single}'),",
    );
    return moved;
  }

  bool _movable(FluentRelationLink link, List<String> columns) {
    if (columns.length == 1 && keyColumnNames.length == 1 && link.target.keyColumnNames.length == 1) return true;
    FluentLog.issue(
      FluentIssueKind.relationChanged,
      '"$tableName.${link.name}" changed how it is stored, but its keys have several columns; the existing data was not moved.',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Move the data with a migration step, or keep the earlier kind of relation by declaring it.',
    );
    return false;
  }

  /// The number of links copied, `null` when nothing could be moved.
  Future<int?> _ownedToLinks(Transaction txn, FluentRelationLink link, {required String childTable, required List<String> references}) async {
    if (childTable != link.target.tableName) {
      _notMoved(link, 'it was stored in "$childTable"');
      return null;
    }
    if (!_movable(link, references)) return null;
    final String reference = references.single;
    if (!(await _columnsOnDisk(txn, childTable)).contains(reference)) {
      _notMoved(link, 'the old column "$childTable.$reference" is gone');
      return null;
    }
    await _executeLogged(txn, _linkTableSql(link, link.linkTable!));
    final String child = childTable.quotedIdentifier;
    final String key = link.target.keyColumnNames.single.quotedIdentifier;
    await txn.execute(
      'INSERT OR IGNORE INTO ${link.linkTable!.quotedIdentifier} (${link.linkOwnerColumns.single.quotedIdentifier}, ${link.linkTargetColumns.single.quotedIdentifier}) '
      'SELECT ${reference.quotedIdentifier}, $key FROM $child WHERE ${reference.quotedIdentifier} IS NOT NULL',
    );
    final int moved = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) ?? 0;
    FluentLog.issue(
      FluentIssueKind.relationDataMoved,
      '"$tableName.${link.name}" is many-to-many now; $moved link(s) were copied from "$childTable.$reference" into "${link.linkTable}".',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Nothing was lost. If the relation should stay a list owned by $modelType, declare it as many.',
      code: "FluentRelation.many<$modelType, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}),",
    );
    return moved;
  }

  /// The number of links copied, `null` when nothing could be moved.
  Future<int?> _linksToOwned(Transaction txn, FluentRelationLink link, {required String linkTable, required List<String> ownerColumns, required List<String> targetColumns}) async {
    if (!_movable(link, [...ownerColumns, ...targetColumns.skip(1)])) return null;
    if (!await _tableExists(txn, linkTable)) {
      _notMoved(link, 'the old link table "$linkTable" is gone');
      return null;
    }
    final String links = linkTable.quotedIdentifier;
    final String ownerColumn = ownerColumns.single.quotedIdentifier;
    final String targetColumn = targetColumns.single.quotedIdentifier;
    final int shared = Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM (SELECT 1 FROM $links GROUP BY $targetColumn HAVING COUNT(*) > 1)')) ?? 0;
    if (shared > 0) {
      FluentLog.issue(
        FluentIssueKind.relationChanged,
        '"$tableName.${link.name}" is a list owned by $modelType now, but $shared ${link.target.modelType} row(s) are linked to several owners; '
            'nothing was moved, the links stay in "$linkTable".',
        table: tableName,
        database: dbName,
        subject: link.name,
        tag: '$tableName:relations',
        hint: 'Keep the relation many-to-many by declaring it, or move the links yourself with a migration step.',
        code: "FluentRelation.manyToMany<$modelType, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}, linkTable: '$linkTable'),",
      );
      return null;
    }
    final String child = link.target.tableName.quotedIdentifier;
    final String key = link.target.keyColumnNames.single.quotedIdentifier;
    final String reference = link.foreignKeys.single.quotedIdentifier;
    // A child may already hold a reference that disagrees with the link table. Moving it would silently move the child
    // between owners, so the existing reference is kept (the fill below only touches NULL references) and the
    // conflicts are reported; the link table keeps the other owner, as nothing is deleted.
    final int conflicts = Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT COUNT(*) FROM $child WHERE $reference IS NOT NULL AND $key IN (SELECT $targetColumn FROM $links) '
            'AND $reference <> (SELECT l.$ownerColumn FROM $links l WHERE l.$targetColumn = $child.$key)',
          ),
        ) ??
        0;
    if (conflicts > 0) {
      FluentLog.issue(
        FluentIssueKind.relationChanged,
        '"$tableName.${link.name}" is a list owned by $modelType now, but $conflicts ${link.target.modelType} row(s) already point to another owner in '
            '"${link.target.tableName}.${link.foreignKeys.single}" than "$linkTable" says; their reference was kept.',
        table: tableName,
        database: dbName,
        subject: link.name,
        tag: '$tableName:relations',
        hint: 'Check these rows: "$linkTable" is kept with the other owner. Set "${link.target.tableName}.${link.foreignKeys.single}" yourself in a migration step to choose.',
      );
    }
    await txn.execute(
      'UPDATE $child SET $reference = (SELECT l.$ownerColumn FROM $links l WHERE l.$targetColumn = $child.$key) '
      'WHERE $reference IS NULL AND $key IN (SELECT $targetColumn FROM $links)',
    );
    final int moved = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) ?? 0;
    FluentLog.issue(
      FluentIssueKind.relationDataMoved,
      '"$tableName.${link.name}" is a list owned by $modelType now; $moved link(s) were copied from "$linkTable" into '
          '"${link.target.tableName}.${link.foreignKeys.single}".',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Nothing was lost: "$linkTable" is kept. If the relation should stay many-to-many, declare it.',
      code: "FluentRelation.manyToMany<$modelType, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}),",
    );
    return moved;
  }
}
