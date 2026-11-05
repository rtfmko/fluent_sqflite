// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Loading related models: one batched query per relation and level for all rows at once (no N+1), split into chunks
/// below the SQL argument limit.
extension _FluentRelationReader<T extends FluentStorable> on FluentProvider<T> {
  /// The deepest relation level a read follows (`maxDepth` is clamped to it).
  static const int maxDepthLimit = 8;

  /// Builds models from raw [rows], loading their relations.
  Future<List<T>> _assembleRows(List<Map<String, dynamic>> rows, FluentTask task) async {
    if (rows.isEmpty) return <T>[];
    return _mapRows(_links.isEmpty ? rows : await _processRowsBatch(rows, task));
  }

  /// Returns mutable copies of [rows] with the related models stored under each relation name.
  ///
  /// * Relations marked `lazy` are skipped unless the task ignores lazy (`FluentLoad.all`) or the name is in [force];
  ///   skipped relations are recorded as unloaded on the model.
  /// * Depth: level 1 are the direct relations; depth 0 (`FluentLoad.none`) loads none.
  /// * A failing relation is logged with a hint and left unloaded; the rows are still returned.
  Future<List<Map<String, dynamic>>> _processRowsBatch(List<Map<String, dynamic>> rows, FluentTask task, {int currentDepth = 0, Set<String> force = const {}}) async {
    final List<Map<String, dynamic>> result = [for (final Map<String, dynamic> row in rows) Map<String, dynamic>.from(row)];
    if (result.isEmpty || _links.isEmpty) return result;

    final int maxDepth = task.maxDepth;
    final int level = currentDepth + 1;

    for (final FluentRelationLink link in _links) {
      final bool wanted = force.contains(link.name) || task.ignoreLazy || !link.relation.lazy;
      if (!wanted || level > maxDepth) {
        _markUnloaded(result, link.name);
        continue;
      }
      try {
        await _loadLink(link, result, task, level);
      } catch (e, st) {
        FluentLog.issue(
          FluentIssueKind.relationLoadFailed,
          'Loading relation "${link.name}" of "$tableName" failed; it is left unloaded.',
          error: e,
          stackTrace: st,
          table: tableName,
          tag: '$tableName:relations',
          hint: 'Check that table "${link.target.tableName}" has the reference column (restart applies pending schema changes) '
              'and that orderBy / where of "${link.name}" are valid SQL.',
        );
        _markUnloaded(result, link.name);
      }
    }
    return result;
  }

  void _markUnloaded(List<Map<String, dynamic>> rows, String name) {
    for (final Map<String, dynamic> row in rows) {
      if (row[name] != null) continue;
      final List<String> unloaded = (row['_unloaded_relations'] as List<String>?) ?? <String>[];
      if (!unloaded.contains(name)) unloaded.add(name);
      row['_unloaded_relations'] = unloaded;
    }
  }

  Future<void> _loadLink(FluentRelationLink link, List<Map<String, dynamic>> rows, FluentTask task, int level) async {
    final FluentProvider target = link.target;
    final String name = link.name;

    switch (link.type) {
      case FluentRelationType.one:
        final Map<String, Object> distinct = {};
        for (final Map<String, dynamic> r in rows) {
          final Object? ref = _rowTuple(r, link.foreignKeys, link.referencedColumns);
          if (ref != null) distinct[_tupleKey(ref)] = ref;
        }
        if (distinct.isEmpty) {
          for (final Map<String, dynamic> r in rows) {
            r[name] = null;
          }
          return;
        }
        final List<Map<String, dynamic>> childRows = await _inChunks(
          distinct.values.toList(),
          target.keysPerChunk(_maxParamsPerChunk),
          (refs) => target._fetchRelated(link, target._keysFilterOf(refs, stored: true), task, applyListOptions: false),
        );
        final List<FluentStorable> models = await target._assembleRelated(childRows, task, level);
        final Map<String, FluentStorable> byId = {for (int i = 0; i < childRows.length; i++) _tupleKey(target.idFromRow(childRows[i])): models[i]};
        for (final Map<String, dynamic> r in rows) {
          final Object? ref = _rowTuple(r, link.foreignKeys, link.referencedColumns);
          r[name] = ref == null ? null : byId[_tupleKey(ref)];
        }

      case FluentRelationType.oneOwned:
      case FluentRelationType.many:
        final List<Object> ids = _ownerIds(rows);
        final Map<String, List<FluentStorable>> grouped = {};
        if (ids.isNotEmpty) {
          // Owners in the trash (findDeleted) show the children that were deleted together with them (same stamp).
          final String? ownerDeleted = _softDeleteColumn;
          final String? childDeleted = target._softDeleteColumn;
          final Map<String, Object> rawStampOf = {};
          if (ownerDeleted != null && childDeleted != null && !link.relation.includeDeleted) {
            for (final Map<String, dynamic> r in rows) {
              if (r[ownerDeleted] != null) rawStampOf[_tupleKey(idFromRow(r))] = r[ownerDeleted] as Object;
            }
          }
          final Map<String, String> stampOf = {for (final MapEntry<String, Object> e in rawStampOf.entries) e.key: '${e.value}'};
          // Chunked by owner, so every owner's children (and their order) come from one statement; a deleted owner's
          // stamp takes one more argument.
          final List<Map<String, dynamic>> childRows = await _inChunks(ids, math.max(1, _maxParamsPerChunk ~/ (link.foreignKeys.length + (rawStampOf.isEmpty ? 0 : 1))), (owners) {
            FluentFilter filter = _tupleFilter(link.foreignKeys, link.referencedColumns, owners, stored: true).and(link.typeFilter);
            final List<Object> stamps = {for (final Object id in owners) ?rawStampOf[_tupleKey(id)]}.toList();
            if (stamps.isNotEmpty) {
              final String c = childDeleted!.quotedIdentifier;
              filter = filter.and(FluentFilter('$c IS NULL OR $c IN (${List.filled(stamps.length, '?').join(', ')})', stamps));
            }
            return target._fetchRelated(link, filter, task, includeDeleted: stamps.isNotEmpty, perOwner: link.foreignKeys);
          });
          final List<FluentStorable> models = await target._assembleRelated(childRows, task, level);
          for (int i = 0; i < childRows.length; i++) {
            final String owner = _tupleKey(_rowTuple(childRows[i], link.foreignKeys, link.referencedColumns));
            final Object? stamp = childDeleted == null || link.relation.includeDeleted ? null : childRows[i][childDeleted]; // includeDeleted keeps trashed children
            if (stamp != null && stampOf[owner] != '$stamp') continue; // deleted on its own, or owner is live
            grouped.putIfAbsent(owner, () => []).add(models[i]);
          }
        }
        _assignGrouped(link, rows, grouped);

      case FluentRelationType.manyToMany:
        final List<Object> ids = _ownerIds(rows);
        final Map<String, List<FluentStorable>> grouped = {};
        if (ids.isNotEmpty) {
          final List<Map<String, dynamic>> joined = await _inChunks(ids, math.max(1, _maxParamsPerChunk ~/ link.linkOwnerColumns.length), (owners) => target._fetchLinked(link, owners, task));
          final List<String> owners = [
            for (final Map<String, dynamic> r in joined)
              [for (int k = 0; k < link.linkOwnerColumns.length; k++) '${r.remove('$_linkOwnerAlias$k')}'].join('\u0001'),
          ];
          final List<FluentStorable> models = await target._assembleRelated(joined, task, level);
          for (int i = 0; i < joined.length; i++) {
            grouped.putIfAbsent(owners[i], () => []).add(models[i]);
          }
        }
        _assignGrouped(link, rows, grouped);

      case FluentRelationType.oneOf:
        // One query (chunked) per referenced table.
        final String typeColumn = link.typeColumn!;
        // The key a row points to, in the columns of its type (a FluentKey for a composite key).
        Object? refOf(Map<String, dynamic> r) {
          final Object? type = r[typeColumn];
          final FluentProvider? p = type is String ? link.targets[type] : null;
          return p == null ? null : _rowTuple(r, link.columnsFor(type! as String), p.keyColumnNames.toList());
        }

        final Map<String, Map<String, Object>> wanted = {};
        for (final Map<String, dynamic> r in rows) {
          final Object? id = refOf(r);
          if (id != null) (wanted[r[typeColumn] as String] ??= {})[_tupleKey(id)] = id;
        }
        final Map<String, FluentStorable> byRef = {};
        for (final MapEntry<String, Map<String, Object>> w in wanted.entries) {
          final FluentProvider p = link.targets[w.key]!;
          final List<Map<String, dynamic>> found = await _inChunks(
            w.value.values.toList(),
            p.keysPerChunk(_maxParamsPerChunk),
            (refs) => p._fetchRelated(link, p._keysFilterOf(refs, stored: true), task, applyListOptions: false),
          );
          final List<FluentStorable> models = await p._assembleRelated(found, task, level);
          for (int i = 0; i < found.length; i++) {
            byRef['${w.key}\u0001${_tupleKey(p.idFromRow(found[i]))}'] = models[i];
          }
        }
        for (final Map<String, dynamic> r in rows) {
          final Object? id = refOf(r);
          r[name] = id == null ? null : byRef['${r[typeColumn]}\u0001${_tupleKey(id)}'];
        }

      case FluentRelationType.auto:
        // Never stored in a link: auto relations are resolved at init.
        return;
    }
  }

  /// The rows [fetch] returns for [keys], [perStatement] keys at a time (SQLite limits the arguments of one statement:
  /// 999 on older Android versions), in order. Lists are chunked by owner, so the `orderBy` of a relation still holds
  /// within each owner.
  Future<List<Map<String, dynamic>>> _inChunks(List<Object> keys, int perStatement, Future<List<Map<String, dynamic>>> Function(List<Object> keys) fetch) async {
    if (keys.length <= perStatement) return fetch(keys);
    final List<Map<String, dynamic>> rows = [];
    for (int i = 0; i < keys.length; i += perStatement) {
      rows.addAll(await fetch(keys.sublist(i, math.min(i + perStatement, keys.length))));
    }
    return rows;
  }

  /// Distinct keys of [rows] (plain values or [FluentKey]s).
  List<Object> _ownerIds(List<Map<String, dynamic>> rows) {
    final Map<String, Object> distinct = {};
    for (final Map<String, dynamic> r in rows) {
      final Object? id = idFromRow(r);
      if (id != null) distinct[_tupleKey(id)] = id;
    }
    return distinct.values.toList();
  }

  void _assignGrouped(FluentRelationLink link, List<Map<String, dynamic>> rows, Map<String, List<FluentStorable>> grouped) {
    final int? limit = link.relation.limit;
    for (final Map<String, dynamic> r in rows) {
      List<FluentStorable> items = grouped[_tupleKey(idFromRow(r))] ?? const [];
      if (limit != null && limit >= 0 && items.length > limit) items = items.sublist(0, limit);
      r[link.name] = link.type == FluentRelationType.oneOwned ? (items.isEmpty ? null : items.first) : link.target._createTypedList(items);
    }
  }

  /// What related rows of this table are visible: expired rows never, soft-deleted rows unless `includeDeleted`. The
  /// trash scope of the caller (`trash.find`, `withTrash`) does not apply: a relation shows what it declares.
  FluentFilter _relationVisibility(FluentRelationLink link) => _visibility(deletedOnly: false, includeDeleted: link.relation.includeDeleted);

  /// Rows of this table matching [filter] for relation [link]: hidden rows (see [_relationVisibility]) are left out,
  /// and list options (`where`, `orderBy`) are applied when [applyListOptions].
  ///
  /// With [perOwner] (the reference columns of owned children) and a relation `limit`, SQLite returns at most `limit`
  /// rows per owner (`ROW_NUMBER()`, SQLite 3.25+) instead of every child; where that statement fails before it ever
  /// worked (older SQLite), every child is read and the lists are cut afterwards.
  Future<List<Map<String, dynamic>>> _fetchRelated(
    FluentRelationLink link,
    FluentFilter filter,
    FluentTask task, {
    bool applyListOptions = true,
    bool includeDeleted = false,
    List<String>? perOwner,
  }) async {
    link.owner._hintReferenceIndex(link);
    FluentFilter where = filter;
    if (applyListOptions && link.relation.where != null) where = where.and(_resolveRelated(link.relation.where!));
    where = where.and(includeDeleted ? _visibility(deletedOnly: false, includeDeleted: true) : _relationVisibility(link));
    final String? orderBy = applyListOptions ? link.relation.orderBy : null;
    final int? limit = link.relation.limit;
    // Children of owners in the trash are filtered after the read (by stamp): there every child must be read.
    if (applyListOptions && perOwner != null && limit != null && limit >= 0 && !includeDeleted && _windowFunctions[dbName] != false) {
      final String table = tableName.quotedIdentifier;
      final String partition = perOwner.map((c) => c.quotedIdentifier).join(', ');
      // Nothing outside the subquery names a column of the table: the outer query orders by a column the subquery
      // selects itself (`rowid` is not visible through a subquery, and an orderBy may be written `table.column`).
      final bool byRowId = orderBy == null && !modelSample.withoutRowId;
      final String order = orderBy ?? (modelSample.withoutRowId ? keyColumnNames.map((c) => c.quotedIdentifier).join(', ') : 'rowid');
      final String rank = byRowId ? '"__fluent_rid"' : '"__fluent_ro"';
      final String extra = byRowId ? 'rowid AS "__fluent_rid"' : 'ROW_NUMBER() OVER (ORDER BY $order) AS "__fluent_ro"';
      final String sql =
          'SELECT * FROM (SELECT *, $extra, ROW_NUMBER() OVER (PARTITION BY $partition ORDER BY $order) AS "__fluent_rn" '
          'FROM $table${where.whereClause.trim().isEmpty ? '' : ' WHERE ${where.whereClause}'}) WHERE "__fluent_rn" <= ? ORDER BY $rank';
      try {
        final List<Map<String, Object?>> rows = await executor.rawQuery(sql, [...?_sqlArgs(where.whereArgs), limit]);
        _windowFunctions[dbName] = true;
        return [for (final Map<String, Object?> r in rows) Map<String, dynamic>.of(r)..remove('__fluent_rn')..remove('__fluent_ro')..remove('__fluent_rid')];
      } on DatabaseException catch (e) {
        // Only "window functions are not supported" switches the path off for the database; every other error (busy,
        // locked, a bad where / orderBy) is a real error of this read and is handled by the caller.
        if (!_lacksWindowFunctions(e)) rethrow;
        // SQLite before 3.25 has no window functions: read every child and cut the lists afterwards.
        _windowFunctions[dbName] = false;
        FluentLog.debug('No window functions in this SQLite; relation limits are applied after reading: $e', tag: '$tableName:relations');
      }
    }
    return executor.query(tableName.quotedIdentifier, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs), orderBy: orderBy);
  }

  /// Whether [e] says that this SQLite cannot run `ROW_NUMBER() OVER (...)` (before 3.25).
  static bool _lacksWindowFunctions(DatabaseException e) {
    final String text = e.toString().toLowerCase();
    return text.contains('no such function') || text.contains('near "over"') || (text.contains('syntax error') && text.contains('over'));
  }

  static const String _linkOwnerAlias = '__fluent_link_owner';

  /// Whether window functions worked in each database (learned from the first limited relation read).
  static final Map<String, bool> _windowFunctions = {};

  /// Rows of this table linked to [ownerIds] through the link table of [link].
  Future<List<Map<String, dynamic>>> _fetchLinked(FluentRelationLink link, List<Object> ownerIds, FluentTask task) async {
    link.owner._hintReferenceIndex(link);
    final String me = tableName.quotedIdentifier;
    final String linkTable = link.linkSource;
    final List<String> myKeys = keyColumnNames.toList();
    final List<String> ownerKeys = link.owner.keyColumnNames.toList();

    // Owner match on the link table: `l.a IN (...)`, or `(l.a = ? AND l.b = ?) OR ...` for composite keys.
    final List<Object?> args = [];
    final String ownerMatch;
    if (link.linkOwnerColumns.length == 1) {
      ownerMatch = 'l.${link.linkOwnerColumns.first.quotedIdentifier} IN (${List.filled(ownerIds.length, '?').join(', ')})';
      args.addAll([for (final Object id in ownerIds) id is FluentKey ? id[ownerKeys.first] : id]);
    } else {
      ownerMatch = ownerIds
          .map((id) {
            for (final String k in ownerKeys) {
              args.add(id is FluentKey ? id[k] : null);
            }
            return '(${[for (final String c in link.linkOwnerColumns) 'l.${c.quotedIdentifier} = ?'].join(' AND ')})';
          })
          .join(' OR ');
    }
    final List<String> conditions = ['($ownerMatch)'];
    if (link.relation.where != null) {
      // Related / search / key conditions written as SQL on this table (the statement names it by its own name).
      final FluentFilter where = _resolveRelated(link.relation.where!);
      conditions.add('(${where.whereClause})');
      args.addAll(_sqlArgs(where.whereArgs) ?? const []);
    }
    final FluentFilter visible = _relationVisibility(link);
    if (visible.whereClause.isNotEmpty) {
      conditions.add('(${visible.whereClause})');
      args.addAll(_sqlArgs(visible.whereArgs) ?? const []);
    }
    final String orderBy = link.relation.orderBy == null ? '' : ' ORDER BY ${link.relation.orderBy}';
    final String sql =
        'SELECT $me.*, ${[for (int k = 0; k < link.linkOwnerColumns.length; k++) 'l.${link.linkOwnerColumns[k].quotedIdentifier} AS $_linkOwnerAlias$k'].join(', ')} FROM $me '
        'JOIN $linkTable l ON ${[for (int k = 0; k < myKeys.length; k++) 'l.${link.linkTargetColumns[k].quotedIdentifier} = $me.${myKeys[k].quotedIdentifier}'].join(' AND ')} '
        'WHERE ${conditions.join(' AND ')}$orderBy';
    FluentLog.sql(sql, arguments: args, tag: '$tableName:relations');
    final List<Map<String, dynamic>> rows = await executor.rawQuery(sql, args);
    return [for (final Map<String, dynamic> r in rows) Map<String, dynamic>.from(r)];
  }

  /// Loads the next relation level of [rows] and builds models, aligned with [rows].
  Future<List<FluentStorable>> _assembleRelated(List<Map<String, dynamic>> rows, FluentTask task, int level) async {
    if (rows.isEmpty) return const [];
    return _mapRows(await _processRowsBatch(rows, task, currentDepth: level));
  }

  /// Turns relation values of an assembled row into typed models (also accepts raw maps, e.g. API JSON).
  Map<String, dynamic> _castReadyRelations(Map<String, dynamic> row) {
    if (_links.isEmpty) return row;
    Map<String, dynamic> result = row;
    for (final FluentRelationLink link in _links) {
      if (!row.containsKey(link.name)) continue;
      final Object? value = row[link.name];
      final Object? typed = _typedRelationValue(link, value);
      if (!identical(typed, value)) {
        if (identical(result, row)) result = Map<String, dynamic>.from(row);
        result[link.name] = typed;
      }
    }
    return result;
  }

  Object? _typedRelationValue(FluentRelationLink link, Object? value) {
    if (link.type == FluentRelationType.oneOf) return value is FluentStorable ? value : null; // a map cannot tell its type
    final FluentProvider target = link.target;
    FluentStorable? one(Object? v) => v is FluentStorable ? v : null; // relation values are always built models
    if (value == null) return null;
    if (link.isList) {
      if (value is! Iterable) return value;
      return target._createTypedList([for (final Object? v in value) one(v)].whereType<FluentStorable>());
    }
    return one(value);
  }
}
