// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Executes CRUD tasks (called by the engine, or directly inside `FluentDb.transaction`).
///
/// Tasks arrive prepared by the public API: `helper.where` / `helper.whereArgs` hold the final filter with stored
/// values (visibility included; deferred conditions are written out before the task runs), `helper.id` the key of a
/// `findById`, `helper.arguments` the keys of key-based deletes. Every multi-statement operation runs in one
/// transaction.
extension _FluentExecuteCrud<T extends FluentStorable> on FluentProvider<T> {
  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _queryTask(FluentTask task, {int? limit}) {
    final TableHelper? h = task.helper;
    if (h?.sql != null) return executor.rawQuery(h!.sql!, h.whereArgs); // a read written by the provider (search)
    final int? offset = h?.offset;
    final List<String>? columns = h?.columns?.map((c) => c.quotedIdentifier).toList();
    // A distinct projection groups by its columns instead (the same rows), so each row can carry the type tags of
    // one of its stored rows (a UTC DateTime stays UTC); `DISTINCT` with `_fs_metadata` would repeat rows.
    final bool grouped = (h?.distinct ?? false) && columns != null;
    return executor.query(
      tableName.quotedIdentifier,
      distinct: grouped ? null : h?.distinct,
      columns: grouped ? [...columns, 'MIN(${FluentDbColumn.systemMetadata().name.quotedIdentifier}) AS ${FluentDbColumn.systemMetadata().name.quotedIdentifier}'] : columns,
      groupBy: grouped ? columns.join(', ') : null,
      where: h?.where,
      whereArgs: h?.whereArgs,
      orderBy: _checkedOrderBy(h?.orderBy), // checked when the task runs: the caller's Future fails, nothing throws early
      // SQLite needs a LIMIT for an OFFSET.
      limit: limit ?? h?.limit ?? (offset != null ? -1 : null),
      offset: offset,
    );
  }

  Future<List<T>> _executeFind(FluentTask task) async => _assembleRows(await _queryTask(task), task);

  /// One lookup, or a merged group of lookups (`task.mergedTasks`, answered in their order with one query per chunk).
  Future<Object?> _executeFindById(FluentTask task) async {
    final FluentFilter visible = _taskFilter(task);
    if (!task.isBatched) {
      final FluentFilter where = keyFilter(task.helper!.id).and(visible);
      final List<Map<String, dynamic>> rows = await executor.query(tableName.quotedIdentifier, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs), limit: 1);
      return rows.isEmpty ? null : (await _assembleRows(rows, task)).first;
    }
    final List<Object> ids = [for (final FluentTask part in task.mergedTasks!) part.helper!.id as Object];
    final Map<String, T> found = {};
    final bool fromRows = _batchKeys == FluentBatchKeys.fromRows;
    final Set<String> wanted = {for (final Object id in ids) _keyTuple(id)};
    bool mismatch = false;
    final int step = keysPerChunk(_maxParamsPerChunk);
    for (int i = 0; i < ids.length; i += step) {
      final FluentFilter where = keysFilter(ids.sublist(i, math.min(i + step, ids.length))).and(visible);
      final List<Map<String, dynamic>> rows = await executor.query(tableName.quotedIdentifier, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs));
      final List<T> models = await _assembleRows(rows, task);
      for (int r = 0; r < models.length; r++) {
        // fromRows: the key of the stored row, decoded like the mapping does (no buildJson per model). fromModels: the
        // key the model reports.
        final String? key = fromRows ? _rowKeyTuple(rows[r]) : _keyTuple(models[r].primaryKeyValue);
        if (key != null && wanted.contains(key)) {
          found[key] = models[r];
        } else {
          mismatch = true; // a row for none of the requested keys (SQLite matched it in another form, e.g. NOCASE)
          if (fromRows) found.putIfAbsent(_keyTuple(models[r].primaryKeyValue), () => models[r]);
        }
      }
    }
    if (mismatch) {
      if (fromRows) _hintBatchKeys();
      // Call by call for the keys the batch could not assign: SQLite alone knows which row each key matches.
      for (final Object id in ids) {
        final String key = _keyTuple(id);
        if (found.containsKey(key)) continue;
        final FluentFilter one = keyFilter(id).and(visible);
        final List<Map<String, dynamic>> rows = await executor.query(tableName.quotedIdentifier, where: one.whereClause, whereArgs: _sqlArgs(one.whereArgs), limit: 1);
        if (rows.isNotEmpty) found[key] = (await _assembleRows(rows, task)).first;
      }
    }
    // Keys in the order of the key columns: a FluentKey may list its columns in any order.
    return [for (final Object id in ids) found[_keyTuple(id)]];
  }

  /// Where batched lookups take the keys of their rows from: table → database → global setting.
  FluentBatchKeys get _batchKeys => _tableConfig.batchKeys ?? FluentEngine().dbConfig(dbName)?.batchKeys ?? FluentEngine().config.batchKeys;

  /// The comparable key text (see [_keyTuple]) of a stored [row]: its key columns decoded to Dart values (converter or
  /// codec, as the mapping does); `null` when a key column is missing or null.
  String? _rowKeyTuple(Map<String, dynamic> row) {
    final List<_MappingWarning> warnings = [];
    final Object? metadata = row['_fs_metadata'];
    final StringBuffer key = StringBuffer();
    bool first = true;
    for (final FluentDbColumn column in primaryKeyColumns) {
      final Object? stored = row[column.name];
      if (stored == null) return null;
      if (!first) key.write('\u0001');
      first = false;
      key.write(_plan.decodeValue(column.name, stored, warnings, metadata: metadata));
    }
    return key.toString();
  }

  void _hintBatchKeys() {
    FluentLog.issue(
      FluentIssueKind.batchKeysMismatch,
      'Batched lookups on "$tableName" found a row whose stored key matches none of the requested keys; the key of its model was used.',
      table: tableName,
      tag: '$tableName:findById',
      hint: 'The model built from the row has another key than the row (its fromCacheJson or a numeric/text form of the key). '
          'Read keys from the models for this table to be exact: FluentTableConfig get tableConfig => const FluentTableConfig(batchKeys: FluentBatchKeys.fromModels);',
      code: '@override\nFluentTableConfig get tableConfig => const FluentTableConfig(batchKeys: FluentBatchKeys.fromModels);',
    );
  }

  Future<int> _executeCount(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<Map<String, Object?>> result = await executor.rawQuery(
      'SELECT COUNT(*) FROM ${tableName.quotedIdentifier}${where == null ? '' : ' WHERE $where'}',
      task.helper?.whereArgs,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<bool> _executeExists(FluentTask task) async {
    final String? where = task.helper?.where;
    final List<Map<String, Object?>> rows = await executor.rawQuery(
      'SELECT 1 FROM ${tableName.quotedIdentifier}${where == null || where.isEmpty ? '' : ' WHERE $where'} LIMIT 1',
      task.helper?.whereArgs,
    );
    return rows.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> _executeFindMaps(FluentTask task) async => _decodeMaps(await _queryTask(task));

  Future<List<Map<String, dynamic>>> _executeRawQuery(FluentTask task) async => [
    for (final Map<String, dynamic> row in await executor.rawQuery(task.helper!.sql!, task.helper?.whereArgs)) withoutInternalColumns(row),
  ];

  Future<int> _executeSql(FluentTask task) async {
    final String sql = task.helper!.sql!;
    final int result = await executor.rawUpdate(sql, task.helper?.whereArgs);
    if (_vacuum.hasMatch(sql)) await _rebuildFullTextAfterVacuum();
    return result;
  }

  /// `VACUUM` after any leading whitespace and comments.
  static final RegExp _vacuum = RegExp(r'^(?:\s+|--[^\n]*(?:\n|$)|/\*.*?\*/)*VACUUM\b', caseSensitive: false, dotAll: true);

  /// `VACUUM` may renumber the rowids of tables without an INTEGER PRIMARY KEY; their full-text indexes point at rows
  /// by rowid, so they are rebuilt from the table.
  Future<void> _rebuildFullTextAfterVacuum() async {
    for (final FluentProvider p in FluentDbInternals.providersOf(dbName)) {
      if (p._ftsModule == null || p._rowidIsKey) continue;
      final String fts = '__fluent_fts_${p.tableName}'.quotedIdentifier;
      await executor.execute("INSERT INTO $fts($fts) VALUES ('rebuild')");
      FluentLog.debug('Full-text index rebuilt after VACUUM (rowids may change)', tag: '${p.tableName}:fullText');
    }
  }


  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// `save` / `update`: writes the models (with their relations when the table has any and the call asks for them)
  /// and returns one outcome per model.
  Future<List<FluentRowOutcome>> _executeSave(FluentTask task) {
    final List<T> items = _createTypedList(task.data! as List);
    final FluentSaveStrategy strategy = task.helper?.saveStrategy ?? FluentSaveStrategy.upsert;
    final List<String>? conflictOn = task.helper?.conflictOn;
    final bool withRelations = _links.isNotEmpty && (task.action == FluentDbAction.save || task.helper?.syncMode != null);

    return _write(task.action == FluentDbAction.save ? 'Save' : 'Update', (txn) async {
      final List<FluentRowOutcome> outcomes;
      if (withRelations) {
        final FluentRelationSaveContext ctx = FluentRelationSaveContext(keepMissingOverride: _keepMissingOverride(task));
        await _saveGraph(txn, items, task, ctx, strategy: strategy, conflictOn: conflictOn);
        outcomes = [for (final T item in items) ctx.outcomes[item] ?? FluentRowOutcome.skipped];
      } else {
        final List<_WrittenRow> written = await _writeRows(txn, [for (final T item in items) _prepareSqlJson(item)], strategy, conflictOn: conflictOn, synced: task.helper?.syncWrite ?? false);
        _injectKeys(items, written);
        outcomes = [for (final _WrittenRow w in written) w.$1];
      }
      // Server writes may update a row in the trash in place (it stays there): their models are not touched. Only
      // after the commit: a rollback leaves the models as they were.
      if (task.helper?.syncWrite != true) FluentTransactionScope.whenCommitted(dbName, () => _syncDeletedAt(items, outcomes));
      return outcomes;
    });
  }

  /// After a save: written rows are live, so their models drop `deletedAt`; a `deletedAt` set by hand on a live row
  /// was ignored (only delete / restore change the trash) and is reported once.
  void _syncDeletedAt(List<T> items, List<FluentRowOutcome> outcomes) {
    if (_softDeleteColumn == null) return;
    int ignored = 0;
    for (int i = 0; i < items.length; i++) {
      final FluentSoftDeletable item = items[i] as FluentSoftDeletable;
      if (item.deletedAt == null || outcomes[i] == FluentRowOutcome.skipped) continue;
      if (outcomes[i] != FluentRowOutcome.restored) ignored++;
      item.deletedAt = null;
    }
    if (ignored > 0) {
      FluentLog.issue(
        FluentIssueKind.deletedAtIgnored,
        'Save on "$tableName" ignored deletedAt of $ignored model(s): the rows are live.',
        table: tableName,
        tag: '$tableName:save',
        hint: 'deletedAt is set by the library. Use delete() to move a row to the trash and restore() to bring it back.',
      );
    }
  }

  Future<int> _executeUpdateFields(FluentTask task) => _write('Update', (txn) => _updateFields(txn, _taskFilter(task), task.helper!.dataMap!));

  // ---------------------------------------------------------------------------
  // Deletes
  // ---------------------------------------------------------------------------

  /// `delete` / `hardDelete` / `restore`: by keys (`helper.arguments`, chunked) or by filter (`helper.where`).
  Future<int> _executeRemove(FluentTask task) {
    final List<Object?>? ids = task.helper?.arguments;
    Future<int> each(Transaction txn, Future<int> Function(FluentFilter where) action) =>
        ids == null ? action(_taskFilter(task)) : _forKeyChunks([...ids.whereType<Object>()], (keys) => action(FluentFilter(keys.whereClause, _sqlArgs(keys.whereArgs)!)));

    // The models passed in (`delete(item)`, `deleteAll`, `trash.restore(item)`); a `List<FluentStorable>` when the call
    // came through a base type (`FluentDb.deleteAll`, `Iterable.deleteAll()`), so not tested as `List<T>`.
    final List<FluentStorable>? items = task.data is List ? (task.data! as List).whereType<FluentStorable>().toList(growable: false) : null;

    /// Gives [items] the stamps stored now, once the transaction commits (a rollback leaves them as they were).
    Future<void> stampModels(Transaction txn) async {
      if (ids == null || items == null || items.isEmpty) return;
      final Map<String, DateTime?> stamps = await _storedDeleteStamps(txn, [...ids.whereType<Object>()]);
      FluentTransactionScope.whenCommitted(dbName, () => _applyDeleteStamps(items, stamps));
    }

    return switch (task.action) {
      FluentDbAction.delete => _write('Delete', (txn) async {
        final int stamp = _softDeleteStamp();
        final int n = await each(txn, (where) => _softDeleteWhere(txn, where, stamp));
        // Models passed in get the stamp stored in this transaction (rows in the trash already keep their first one).
        await stampModels(txn);
        return n;
      }),
      FluentDbAction.restore => _write('Restore', (txn) async {
        final int n = await each(txn, (where) => _restoreWhere(txn, where));
        // Restored rows have no stamp any more; rows that stay in the trash (owner deleted) keep theirs.
        await stampModels(txn);
        return n;
      }),
      _ => _write('Delete', (txn) => each(txn, (where) => _hardDeleteWhere(txn, where))),
    };
  }

  /// The purged rows' own deletions were pushed already (see `_deletedBefore`), so they leave no tombstone; the
  /// children the cascade removes with them do (a local delete).
  Future<int> _executePurgeDeleted(FluentTask task) => _write('Purge', (txn) => _hardDeleteWhere(txn, _deletedBefore(task.helper!.value as Duration)));

  Future<int> _executeClearExpired(FluentTask task) {
    final String expiry = _expiryColumn.quotedIdentifier;
    // Local maintenance: expired cache rows leave no tombstones.
    return _write('Clear expired', (txn) => _hardDeleteWhere(txn, FluentFilter('$expiry IS NOT NULL AND $expiry <= ?', [FluentClock.now().millisecondsSinceEpoch]), synced: true));
  }

  /// Clears the table locally (e.g. on logout): no tombstones, the server keeps its data.
  Future<int> _executeClearTable(FluentTask task) => _write('Clear table', (txn) async {
    final int unsent = _syncColumns == null ? 0 : await _countUnsent(txn) + await _countTombstones(txn);
    final int count = await _hardDeleteWhere(txn, FluentFilter.empty, synced: true);
    await _forgetFetchState(txn);
    if (_syncColumns != null) await _dropAllTombstones(txn);
    if (unsent > 0) {
      FluentLog.issue(
        FluentIssueKind.unsentChangesDiscarded,
        'clearTable on "$tableName" discarded $unsent local change(s) (rows and deletions) the server never received.',
        table: tableName,
        tag: '$tableName:clearTable',
        hint: 'Call syncWithServer() before clearTable to push them first. clearTable is a full local reset: it also drops unsent changes.',
        context: {'rows': unsent},
      );
    }
    return count;
  });

  /// Rows with local changes not pushed yet (a syncable table).
  Future<int> _countUnsent(DatabaseExecutor ex) async {
    final FluentFilter unsent = _unsynced;
    final List<Map<String, Object?>> rows = await ex.rawQuery('SELECT COUNT(*) FROM ${tableName.quotedIdentifier} WHERE ${unsent.whereClause}');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// After the table was emptied: the next pull asks for everything again (no `since`), and `watchRemote` fetches
  /// again instead of trusting `maxAge`.
  Future<void> _forgetFetchState(DatabaseExecutor ex) async {
    Future<bool> exists(String table) async => (await ex.rawQuery("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).isNotEmpty;
    if (_syncColumns != null && await exists(_syncStateTable)) await ex.delete(_syncStateTable, where: 'tbl = ?', whereArgs: [tableName]);
    if (await exists(_fetchStateTable)) {
      final String prefix = '${jsonEncode([tableName]).substring(0, jsonEncode([tableName]).length - 1)},'; // see _fetchKey
      await ex.delete(_fetchStateTable, where: 'substr(query, 1, ?) = ?', whereArgs: [prefix.length, prefix]);
    }
  }
}
