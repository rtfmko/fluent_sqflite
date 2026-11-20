// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Bookkeeping tables `syncWithServer` keeps per database: deletions waiting to be pushed, and the last pull.
const String _tombstoneTable = '__fluent_tombstones';
const String _syncStateTable = '__fluent_sync_state';

/// What applying a pull did.
typedef FluentPullStats = ({int pulled, int conflicts, int remoteDeleted});

/// The sync engine of `FluentSyncable` providers: change tracking, push batches, pull with conflicts, tombstones.
///
/// * Every local write raises `sync_version`; a push records the version it sent in `synced_version`, only if the row
///   did not change meanwhile — an edit made during a push stays pending and goes with the next one.
/// * Writes received from the server are stored as synced (no echo), and never overwrite a row with a local change
///   that was not pushed yet (the local change wins, unless the conflict policy says otherwise).
/// * Server rows and deletions are matched by the server key (`FluentTableConfig.serverKey`, else the primary key);
///   permanent deletes of rows the server knows leave a tombstone with that key, which the next push reports.
extension FluentSyncCore<T extends FluentStorable> on FluentProvider<T> {
  FluentFilter get _unsynced {
    final ({String version, String synced}) c = _syncColumns!;
    return FluentFilter('${c.version.quotedIdentifier} > ${c.synced.quotedIdentifier}');
  }

  /// Creates the sync bookkeeping tables at init (schema sync), so reads never have to (they may run on a read-only
  /// pooled connection).
  @internal
  Future<void> prepareSyncTables(DatabaseExecutor ex) async {
    if (_syncColumns != null) await _ensureSyncTables(ex);
  }

  /// Reads on the main connection still create the tables when missing (databases opened before they existed).
  Future<void> _ensureSyncTablesForRead() async {
    if (FluentReadScope.of(dbName) == null) await _ensureSyncTables(executor);
  }

  static Future<void> _ensureSyncTables(DatabaseExecutor ex) async {
    await ex.execute('CREATE TABLE IF NOT EXISTS $_tombstoneTable (tbl TEXT NOT NULL, key TEXT NOT NULL, deleted_at INTEGER NOT NULL, PRIMARY KEY (tbl, key))');
    await ex.execute('CREATE TABLE IF NOT EXISTS $_syncStateTable (tbl TEXT PRIMARY KEY, last_pull INTEGER)');
  }

  static String _encodeKey(Object id) => jsonEncode(id is FluentKey ? id.values : id);

  Object _decodeKey(String raw) {
    final Object? value = jsonDecode(raw);
    return value is Map ? FluentKey(Map<String, Object?>.from(value)) : value!;
  }

  /// The server key of the stored [row] (a plain value, or a [FluentKey] of the server key columns) as Dart values, like
  /// the server knows it (a column converter is applied backwards); `null` while one is empty.
  Object? _serverKeyOf(Map<String, Object?> row) {
    final List<String> columns = _serverKey;
    final Object? metadata = row['_fs_metadata'];
    Object? value(String c) => _plan.decodeValue(c, row[c], [], metadata: metadata);
    if (columns.length == 1) return value(columns.first);
    final Map<String, Object?> values = {for (final String c in columns) c: value(c)};
    return values.values.contains(null) ? null : FluentKey(values);
  }

  /// Runs [action] for [keys] (server keys) in chunks that stay below the bound-variable limit.
  Future<void> _forServerKeyChunks(List<Object> keys, Future<void> Function(FluentFilter where) action) async {
    final int step = math.max(1, _maxParamsPerChunk ~/ _serverKey.length);
    for (int i = 0; i < keys.length; i += step) {
      await action(_tupleFilter(_serverKey, _serverKey, keys.sublist(i, math.min(i + step, keys.length))));
    }
  }

  /// Before a permanent delete of [where] (not one received from the server): remember the server keys of rows the
  /// server already knows, so the next push can report the deletion.
  Future<void> _writeTombstones(DatabaseExecutor ex, FluentFilter where) async {
    final ({String version, String synced})? c = _syncColumns;
    if (c == null) return;
    final String? deleted = _softDeleteColumn;
    final String synced = c.synced.quotedIdentifier;
    final String version = c.version.quotedIdentifier;
    // Known to the server (-1: a new row over a key whose deletion was never sent, see _dropTombstonesOfWritten), and
    // not a deletion that was already pushed (trash purge).
    FluentFilter known = where.and(FluentFilter('$synced <> 0'));
    if (deleted != null) known = known.and(FluentFilter('${deleted.quotedIdentifier} IS NULL OR $version > $synced'));
    final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: _serverKey.quotedAll, where: known.whereClause, whereArgs: _sqlArgs(known.whereArgs));
    if (rows.isEmpty) return;
    final List<Object> keys = [for (final Map<String, Object?> r in rows) ?_serverKeyOf(r)];
    if (keys.length < rows.length) {
      FluentLog.issue(
        FluentIssueKind.tombstoneWithoutKey,
        '${rows.length - keys.length} deleted row(s) of "$tableName" have no server key (${_serverKey.join(', ')}); the server is not told about their deletion.',
        table: tableName,
        tag: '$tableName:sync',
        hint: 'Store the key the server gives a pushed row: return it in FluentPushResult.accepted(updated: [...]).',
      );
    }
    await _insertTombstones(ex, keys);
  }

  /// Stores tombstones for the server [keys]: the next push reports their deletion.
  Future<void> _insertTombstones(DatabaseExecutor ex, List<Object> keys) async {
    if (keys.isEmpty) return;
    await _ensureSyncTables(ex);
    final Batch batch = ex.batch();
    final int now = FluentClock.now().millisecondsSinceEpoch;
    for (final Object key in keys) {
      batch.insert(_tombstoneTable, {'tbl': tableName, 'key': _encodeKey(key), 'deleted_at': now}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// After a local write: the rows with the stored keys [ids] exist again, so a tombstone with their server key is
  /// obsolete (their `sync_version` sends an upsert; a push must not also report the deletion). The server key is read
  /// from the stored rows: it may be set by the server only, or be composite.
  Future<void> _dropTombstonesOfWritten(DatabaseExecutor ex, List<Object> ids) async {
    if (ids.isEmpty || await _countTombstones(ex) == 0) return;
    final List<Object> keys = [];
    final List<Object> rowIds = []; // stored keys, aligned with keys
    final List<String> columns = {..._serverKey, ...keyColumnNames}.toList();
    await _forKeyChunks(ids, (filter) async {
      for (final Map<String, Object?> r in await ex.query(tableName.quotedIdentifier, columns: columns.quotedAll, where: filter.whereClause, whereArgs: _sqlArgs(filter.whereArgs))) {
        final Object? key = _serverKeyOf(r);
        if (key != null) {
          keys.add(key);
          rowIds.add(idFromRow(r)!);
        }
      }
      return 0;
    }, stored: true);
    if (keys.isEmpty) return;
    final Batch batch = ex.batch();
    for (final Object key in keys) {
      batch.delete(_tombstoneTable, where: 'tbl = ? AND key = ?', whereArgs: [tableName, _encodeKey(key)]);
    }
    final List<Object?> dropped = await batch.commit();
    // The server still has these keys (their deletion was never sent): a new row written over one counts as known
    // (`synced_version` -1, still pending), so deleting it again before a push writes the tombstone again.
    final List<Object> known = [for (int i = 0; i < rowIds.length; i++) if ((dropped[i] as int? ?? 0) > 0) rowIds[i]];
    if (known.isEmpty) return;
    final String synced = _syncColumns!.synced.quotedIdentifier;
    await _forKeyChunks(known, (filter) {
      final FluentFilter where = filter.and(FluentFilter('$synced = 0'));
      return ex.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET $synced = -1 WHERE ${where.whereClause}', _sqlArgs(where.whereArgs));
    }, stored: true);
  }

  /// Number of tombstones (deletions not pushed yet) of this table.
  Future<int> _countTombstones(DatabaseExecutor ex) async {
    await _ensureSyncTables(ex);
    return Sqflite.firstIntValue(await ex.rawQuery('SELECT COUNT(*) FROM $_tombstoneTable WHERE tbl = ?', [tableName])) ?? 0;
  }

  /// Drops every tombstone of this table (a local reset: the deletions are not reported any more).
  Future<void> _dropAllTombstones(DatabaseExecutor ex) async {
    await _ensureSyncTables(ex);
    await ex.delete(_tombstoneTable, where: 'tbl = ?', whereArgs: [tableName]);
  }

  /// Indexes of the prepared [rows] whose local row (matched by [match]) has a change not pushed yet.
  Future<Set<int>> _busyRows(DatabaseExecutor ex, List<String> match, List<Map<String, dynamic>> rows) async {
    bool keyed(Map<String, dynamic> r) => match.every((c) => r[c] != null);
    final Map<String, Object?> busy = await _existingByMatch(ex, match, [for (final Map<String, dynamic> r in rows) if (keyed(r)) r], scope: _unsynced);
    if (busy.isEmpty) return const <int>{};
    return {
      for (int i = 0; i < rows.length; i++)
        if (keyed(rows[i]) && busy.containsKey(_valuesKey(match, [for (final String c in match) rows[i][c]]))) i,
    };
  }

  /// Indexes of the prepared [rows] whose server key has a tombstone: the row was deleted locally and the deletion is
  /// not pushed yet. Bringing the server's row back would undo that newer local change.
  Future<Set<int>> _tombstonedRows(DatabaseExecutor ex, List<Map<String, dynamic>> rows) async {
    if (_syncColumns == null || rows.isEmpty) return const <int>{};
    final Map<String, List<int>> byKey = {};
    for (int i = 0; i < rows.length; i++) {
      final Object? key = _serverKeyOf(rows[i]);
      if (key != null) (byKey[_encodeKey(key)] ??= []).add(i);
    }
    if (byKey.isEmpty) return const <int>{};
    await _ensureSyncTables(ex);
    final List<String> encoded = byKey.keys.toList();
    final Set<int> found = {};
    final int step = math.max(1, _maxParamsPerChunk - 1);
    for (int i = 0; i < encoded.length; i += step) {
      final List<String> chunk = encoded.sublist(i, math.min(i + step, encoded.length));
      final List<Map<String, Object?>> hits = await ex.query(
        _tombstoneTable,
        columns: ['key'],
        where: 'tbl = ? AND key IN (${List.filled(chunk.length, '?').join(', ')})',
        whereArgs: [tableName, ...chunk],
      );
      for (final Map<String, Object?> hit in hits) {
        found.addAll(byKey[hit['key']! as String] ?? const <int>[]);
      }
    }
    return found;
  }

  /// Drops the tombstones of the prepared [rows] at [indexes] (the server's row won over the local deletion).
  Future<void> _dropTombstones(DatabaseExecutor ex, List<Map<String, dynamic>> rows, Iterable<int> indexes) async {
    final Batch batch = ex.batch();
    for (final int i in indexes) {
      final Object? key = _serverKeyOf(rows[i]);
      if (key != null) batch.delete(_tombstoneTable, where: 'tbl = ? AND key = ?', whereArgs: [tableName, _encodeKey(key)]);
    }
    await batch.commit(noResult: true);
  }

  /// Keeps the creation / modification times the server sent: the row writer stamps stored rows with the local time,
  /// so after a synced write the times a received model carries (`createdAt` / `updatedAt` of `FluentTimestamps`)
  /// are written over them. Models without a time keep the local one. The rows stay synced.
  Future<void> _keepServerTimes(DatabaseExecutor ex, List<T> items) async {
    final ({String created, String updated})? times = _timestampColumns;
    if (times == null) return;
    // One batch for the whole page (a pull page can hold hundreds of rows).
    final Batch batch = ex.batch();
    bool any = false;
    for (final T item in items) {
      if (item is! FluentTimestamps) continue;
      final Object? id = item.primaryKeyValue;
      final DateTime? created = item.createdAt;
      final DateTime? updated = item.updatedAt;
      if (id == null || (created == null && updated == null)) continue;
      final Map<String, Object?> set = {if (created != null) times.created: created.millisecondsSinceEpoch, if (updated != null) times.updated: updated.millisecondsSinceEpoch};
      final (String sql, List<Object?> args) = _updateSql(set, keyFilter(id), _versionSet(synced: true));
      batch.rawUpdate(sql, args);
      any = true;
    }
    if (any) await batch.commit(noResult: true);
  }

  /// Local changes not pushed yet (matching [where], except the rows with a key in [skip]), at most [limit] of them,
  /// in key order.
  ///
  /// Committed data only: the transaction watchdog never lets this read into a transaction it was not called in (a
  /// batch with changes that roll back later would leave the server with them, and the committed rows marked synced).
  @internal
  Future<FluentSyncBatch<T>> pendingSyncBatch({FluentFilter? where, int? limit, List<Object> skip = const []}) => _run<FluentSyncBatch<T>>(
    FluentDbAction.relationRead,
    committedOnly: true,
    data: () async {
      final ({String version, String synced}) c = _syncColumns!;
      final FluentFilter pending = _resolveRelated(_scoped(where, _unsynced));
      await _flushValueLists();
      // Skipped keys are dropped here, not in SQL (one NOT IN of every refused key passes the variable limit): at
      // most skip.length of the first limit + skip.length rows are skipped, so a full batch remains.
      final Set<String> skipped = {for (final Object id in skip) _keyText(_storedId(id)!)}; // keyed like the stored rows
      final List<Map<String, Object?>> found = await executor.query(
        tableName.quotedIdentifier,
        columns: [...keyColumnNames, c.version].quotedAll,
        where: pending.whereClause,
        whereArgs: _sqlArgs(pending.whereArgs),
        orderBy: keyColumnNames.map((k) => k.quotedIdentifier).join(', '),
        limit: limit == null ? null : limit + skipped.length,
      );
      final List<Map<String, Object?>> rows = [for (final Map<String, Object?> r in found) if (!skipped.contains(_keyText(idFromRow(r)!))) r].take(limit ?? found.length).toList();
      // The keys of the batch are Dart values (what the models carry); filters convert them like on save.
      final List<(Object, int)> versions = [for (final Map<String, Object?> r in rows) (_dartIdOf(r)!, r[c.version]! as int)];
      final List<T> models = [];
      final int step = keysPerChunk(_maxParamsPerChunk);
      for (int i = 0; i < versions.length; i += step) {
        final FluentFilter keys = keysFilter([for (final (Object id, int _) in versions.sublist(i, math.min(i + step, versions.length))) id]);
        final List<Map<String, dynamic>> found = await executor.query(tableName.quotedIdentifier, where: keys.whereClause, whereArgs: _sqlArgs(keys.whereArgs));
        models.addAll(await _assembleRows(found, FluentTask(action: FluentDbAction.find, table: tableName, dbName: dbName)));
      }
      final bool soft = _softDeleteColumn != null;
      final int left = limit == null ? -1 : limit - rows.length;
      List<Map<String, Object?>> tombstones = const [];
      if (left != 0) {
        await _ensureSyncTablesForRead();
        tombstones = await executor.query(_tombstoneTable, columns: ['key'], where: 'tbl = ?', whereArgs: [tableName], orderBy: 'deleted_at, key', limit: left < 0 ? null : left);
      }
      return FluentSyncBatch<T>(
        changed: [for (final T m in models) if (!soft || (m as FluentSoftDeletable).deletedAt == null) m],
        deleted: [for (final T m in models) if (soft && (m as FluentSoftDeletable).deletedAt != null) m],
        deletedKeys: [for (final Map<String, Object?> t in tombstones) _decodeKey(t['key']! as String)],
        versions: versions,
        tombstones: [for (final Map<String, Object?> t in tombstones) t['key']! as String],
      );
    },
  );

  /// Before [batch] is sent: its rows the server did not know (`synced_version` 0) count as known from now on
  /// (`synced_version` -1, still pending), since the server may store them even when its answer is lost, fails or is
  /// cancelled: a later permanent delete then leaves a tombstone (a deletion of a key the server lacks is harmless).
  @internal
  Future<void> markSent(FluentSyncBatch<T> batch) {
    final List<Object> ids = [for (final (Object id, int _) in batch.versions) id];
    if (ids.isEmpty) return Future<void>.value();
    return _run<void>(
      FluentDbAction.relationWrite,
      data: () => _write('Sync', (txn) async {
        final String synced = _syncColumns!.synced.quotedIdentifier;
        await _forKeyChunks(ids, (keys) {
          final FluentFilter where = keys.and(FluentFilter('$synced = 0'));
          return txn.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET $synced = -1 WHERE ${where.whereClause}', _sqlArgs(where.whereArgs));
        });
      }),
    );
  }

  /// After a successful push: marks the sent versions synced (rows changed meanwhile, and the [rejected] keys, stay
  /// pending) and drops the sent tombstones. Rows deleted for good while the push ran get a tombstone with the server
  /// key of [updated] (the server's answer) or of the pushed model, so the next push deletes them on the server too.
  /// Returns the number of rows marked.
  @internal
  Future<int> markPushed(FluentSyncBatch<T> batch, {List<Object> rejected = const [], List<T> updated = const []}) => _run<int>(
    FluentDbAction.relationWrite,
    data: () => _write('Sync', (txn) async {
      final ({String version, String synced}) c = _syncColumns!;
      final Set<String> refused = {for (final Object id in rejected) _keyText(id)};
      final Batch writes = txn.batch();
      final List<Object> sent = [];
      for (final (Object id, int version) in batch.versions) {
        if (refused.contains(_keyText(id))) continue;
        final FluentFilter where = keyFilter(id).and(FluentFilter('${c.version.quotedIdentifier} = ?', [version]));
        writes.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET ${c.synced.quotedIdentifier} = ? WHERE ${where.whereClause}', [version, ...?_sqlArgs(where.whereArgs)]);
        sent.add(id);
      }
      for (final String key in batch.tombstones) {
        writes.delete(_tombstoneTable, where: 'tbl = ? AND key = ?', whereArgs: [tableName, key]);
      }
      final List<Object?> results = await writes.commit();
      int marked = 0;
      final List<Object> unmarked = [];
      for (int i = 0; i < sent.length; i++) {
        final int n = results[i] as int? ?? 0;
        marked += n;
        if (n == 0) unmarked.add(sent[i]);
      }
      if (unmarked.isNotEmpty) await _tombstonesOfGone(txn, unmarked, [...updated, ...batch.changed, ...batch.deleted]);
      return marked;
    }),
  );

  /// Tombstones for the pushed rows [ids] that were deleted for good while the push ran (that delete wrote none: the
  /// server did not know them yet). The server key comes from [known] (the server's answer first).
  Future<void> _tombstonesOfGone(DatabaseExecutor ex, List<Object> ids, List<T> known) async {
    final Set<String> alive = {};
    await _forKeyChunks(ids, (keys) async {
      for (final Object id in await _keysWhere(ex, keys, dart: true)) {
        alive.add(_keyText(id));
      }
      return 0;
    });
    final List<Object> gone = [for (final Object id in ids) if (!alive.contains(_keyText(id))) id];
    if (gone.isEmpty) return;
    final Map<String, Object> serverKeys = {};
    for (final T model in known) {
      final Map<String, dynamic> row = _prepareSqlJson(model);
      final Object? id = _dartIdOf(row);
      final Object? key = _serverKeyOf(row);
      if (id != null && key != null) serverKeys.putIfAbsent(_keyText(id), () => key);
    }
    final List<Object> keys = [for (final Object id in gone) ?serverKeys[_keyText(id)]];
    if (keys.length < gone.length) {
      FluentLog.issue(
        FluentIssueKind.tombstoneWithoutKey,
        '${gone.length - keys.length} row(s) of "$tableName" were deleted while their first push ran, and the server gave no key (${_serverKey.join(', ')}); the server is not told about their deletion.',
        table: tableName,
        tag: '$tableName:sync',
        hint: 'Store the key the server gives a pushed row: return it in FluentPushResult.accepted(updated: [...]).',
      );
    }
    await _insertTombstones(ex, keys);
  }

  /// Number of local changes waiting to be pushed (changed / trashed rows and tombstones).
  @internal
  Future<int> pendingSyncCount({FluentFilter? where}) => _run<int>(
    FluentDbAction.relationRead,
    data: () async {
      final FluentFilter pending = _resolveRelated(_scoped(where, _unsynced));
      await _flushValueLists();
      final int rows = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM ${tableName.quotedIdentifier} WHERE ${pending.whereClause}', _sqlArgs(pending.whereArgs))) ?? 0;
      await _ensureSyncTablesForRead();
      final int tombstones = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM $_tombstoneTable WHERE tbl = ?', [tableName])) ?? 0;
      return rows + tombstones;
    },
  );

  /// The time of the last successful pull (the `since` of the next one), or `null`.
  @internal
  Future<DateTime?> lastPull() => _run<DateTime?>(
    FluentDbAction.relationRead,
    committedOnly: true,
    data: () async {
      await _ensureSyncTablesForRead();
      final List<Map<String, Object?>> rows = await executor.query(_syncStateTable, where: 'tbl = ?', whereArgs: [tableName]);
      final int? at = rows.isEmpty ? null : rows.first['last_pull'] as int?;
      return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
    },
  );

  /// Local models of [items] that have changes not pushed yet (matched by the server key), by item index, with their
  /// key and the `sync_version` that was read (a merge of them is written only while the row still has it).
  @internal
  Future<Map<int, ({T model, Object id, int version})>> unpushedCounterparts(List<T> items) => _run<Map<int, ({T model, Object id, int version})>>(
    FluentDbAction.relationRead,
    committedOnly: true, // a merge of a local row that rolls back later would be written as a local change
    data: () async {
      final List<String> match = _serverKey;
      final String versionColumn = _syncColumns!.version;
      final List<Map<String, dynamic>> rows = [for (final T item in items) _prepareSqlJson(item)];
      // Rows in the trash whose deletion is not pushed yet are not merged: like a permanent delete, the local deletion
      // wins over a server row (applyPull skips them as busy), unless the server wins.
      final String? deleted = _softDeleteColumn;
      final FluentFilter scope = deleted == null ? _unsynced : _unsynced.and(FluentFilter.isNull(deleted.quotedIdentifier));
      final Map<String, Object?> found = await _existingByMatch(executor, match, [for (final Map<String, dynamic> r in rows) if (match.every((c) => r[c] != null)) r], scope: scope);
      if (found.isEmpty) return <int, ({T model, Object id, int version})>{};
      // The local rows in a few queries (not one per item).
      final List<Object> ids = found.values.whereType<Object>().toList();
      final Map<String, T> local = {};
      final Map<String, int> versions = {};
      final Map<String, Object> dartIds = {};
      final int step = keysPerChunk(_maxParamsPerChunk);
      for (int i = 0; i < ids.length; i += step) {
        final FluentFilter keys = _keysFilterOf(ids.sublist(i, math.min(i + step, ids.length)), stored: true); // found holds stored keys
        final List<Map<String, dynamic>> hits = await executor.query(tableName.quotedIdentifier, where: keys.whereClause, whereArgs: _sqlArgs(keys.whereArgs));
        for (final Map<String, dynamic> hit in hits) {
          versions[_keyText(idFromRow(hit)!)] = hit[versionColumn] as int;
          dartIds[_keyText(idFromRow(hit)!)] = _dartIdOf(hit)!;
        }
        final List<T> hitModels = await _assembleRows(hits, FluentTask(action: FluentDbAction.find, table: tableName, dbName: dbName));
        for (int k = 0; k < hitModels.length; k++) {
          local[_keyText(idFromRow(hits[k])!)] = hitModels[k]; // models and rows are aligned
        }
      }
      final Map<int, ({T model, Object id, int version})> result = {};
      for (int i = 0; i < rows.length; i++) {
        if (!match.every((c) => rows[i][c] != null)) continue;
        final Object? id = found[_valuesKey(match, [for (final String c in match) rows[i][c]])];
        if (id == null) continue;
        final T? model = local[_keyText(id)];
        final int? version = versions[_keyText(id)];
        if (model != null && version != null) result[i] = (model: model, id: dartIds[_keyText(id)] ?? id, version: version);
      }
      return result;
    },
  );

  /// Applies a pull in one transaction: server rows are stored as synced, except rows with a local change made
  /// meanwhile (the local change wins, unless [serverWins]); [resolved] (merged by the conflict policy) are saved as
  /// local changes to push, unless their local row changed again (or went away) while the merge ran — then the
  /// newer local row wins; remote deletions (server keys) follow [remoteDeletes].
  ///
  /// Rows are matched by the server key, or by the primary key with [byKey] (the server's answer to a push). The
  /// answer to a push only updates rows that still exist; a row with a local change made meanwhile, or in the trash,
  /// only takes the server key columns (the change stays pending, the next push carries the key).
  /// With [rememberAs], that time becomes the `since` of the next pull.
  @internal
  Future<FluentPullStats> applyPull(
    FluentPullResult<T> pull, {
    required List<T> remote,
    List<({T model, Object id, int version})> resolved = const [],
    bool byKey = false,
    bool serverWins = false,
    FluentRemoteDeleteBehavior remoteDeletes = FluentRemoteDeleteBehavior.auto,
    FluentRelationSyncMode? relationSync,
    DateTime? rememberAs,
    List<Object> serverHas = const [],
  }) => _run<FluentPullStats>(
    FluentDbAction.relationWrite,
    data: () => _write('Pull', (txn) async {
      final List<String> match = byKey ? keyColumnNames.toList() : _serverKey;
      final List<String>? conflictOn = setEquals(match.toSet(), keyColumnNames.toSet()) ? null : match;
      // Rows that got a local change since the conflicts were checked: the local change wins.
      final List<Map<String, dynamic>> rows = [for (final T item in remote) _prepareSqlJson(item)];
      final Set<int> busy = serverWins ? const <int>{} : await _busyRows(txn, match, rows);
      // The server has the rows whose local change wins ([serverHas]: Dart keys; busy rows: by match): known from now
      // on, so deleting one later tells the server (it would keep its row otherwise, and never send it again).
      final String syncedColumn = _syncColumns!.synced.quotedIdentifier;
      final FluentFilter unknown = FluentFilter('$syncedColumn = 0');
      Future<int> markKnown(FluentFilter keys) {
        final FluentFilter where = keys.and(unknown);
        return txn.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET $syncedColumn = -1 WHERE ${where.whereClause}', _sqlArgs(where.whereArgs));
      }

      if (serverHas.isNotEmpty) await _forKeyChunks(serverHas, markKnown);
      if (busy.isNotEmpty) {
        final List<Object> busyIds = (await _existingByMatch(txn, match, [for (final int i in busy) rows[i]], scope: unknown)).values.whereType<Object>().toList();
        if (busyIds.isNotEmpty) await _forKeyChunks(busyIds, markKnown, stored: true);
      }
      // Rows deleted locally whose deletion is not pushed yet (a pull only; the answer to a push never inserts): the
      // local deletion is the newer change and wins, unless the server wins (then the tombstone is dropped).
      final Set<int> tombstoned = byKey ? const <int>{} : await _tombstonedRows(txn, rows);
      final Set<int> deletedLocally = serverWins ? const <int>{} : tombstoned;
      // The answer to a push for rows in the trash: writing it would bring them back.
      final Set<int> trashed = {};
      if (byKey && _softDeleteColumn != null) {
        final List<int> keyed = [for (int i = 0; i < rows.length; i++) if (!busy.contains(i) && idFromRow(rows[i]) != null) i];
        final Set<String> inTrash = keyed.isEmpty ? const {} : await _trashedKeys(txn, [for (final int i in keyed) idFromRow(rows[i])!]);
        trashed.addAll([for (final int i in keyed) if (inTrash.contains(_valuesKey(keyColumnNames.toList(), [for (final String c in keyColumnNames) rows[i][c]]))) i]);
      }
      final List<T> incoming = [for (int i = 0; i < remote.length; i++) if (!busy.contains(i) && !trashed.contains(i) && !deletedLocally.contains(i)) remote[i]];
      if (byKey) await _storeServerKeys(txn, rows, busy, trashed);
      // A server row stored over a row in the local trash (its deletion was pushed already, or the server wins over a
      // deletion not pushed yet) brings it back, synced: the row writer alone would update it inside the trash.
      if (!byKey && _softDeleteColumn != null && incoming.isNotEmpty) {
        final List<Map<String, dynamic>> keyed = [
          for (int i = 0; i < remote.length; i++)
            if (!busy.contains(i) && !deletedLocally.contains(i) && match.every((c) => rows[i][c] != null)) rows[i],
        ];
        final Map<String, Object> inTrash = keyed.isEmpty ? const {} : await _trashedMatches(txn, match, keyed, live: conflictOn != null);
        if (inTrash.isNotEmpty) await _forKeyChunks(inTrash.values.toList(), (keys) => _restoreWhere(txn, keys, synced: true), stored: true);
      }

      Future<void> store(List<T> items, {required bool synced}) async {
        if (items.isEmpty) return;
        // The answer to a push never inserts: a row deleted while the push ran stays deleted.
        final FluentSaveStrategy strategy = byKey ? FluentSaveStrategy.updateOnly : FluentSaveStrategy.upsert;
        final FluentTask task = FluentTask(action: FluentDbAction.save, table: tableName, dbName: dbName, helper: TableHelper(syncWrite: synced, syncMode: relationSync));
        if (_links.isNotEmpty) {
          await _saveGraph(txn, items, task, FluentRelationSaveContext(keepMissingOverride: _keepMissingOverride(task)), strategy: strategy, conflictOn: synced ? conflictOn : null);
          if (synced) await _keepServerTimes(txn, items);
        } else {
          final List<_WrittenRow> written = await _writeRows(txn, [for (final T item in items) _prepareSqlJson(item)], strategy, conflictOn: synced ? conflictOn : null, synced: synced);
          _injectKeys(items, written);
          if (synced) await _keepServerTimes(txn, items);
          FluentEngine.touch(this, FluentDbAction.save, items);
        }
      }

      await store(incoming, synced: true);
      if (serverWins && tombstoned.isNotEmpty) await _dropTombstones(txn, rows, tombstoned);
      await store(await _unchangedMerges(txn, resolved), synced: false);

      int deleted = 0;
      if (pull.deletedKeys.isNotEmpty && remoteDeletes != FluentRemoteDeleteBehavior.keep) {
        final List<Object> safe = []; // stored keys
        await _forServerKeyChunks(pull.deletedKeys, (keys) async {
          // A local change not pushed yet wins, unless the server wins.
          safe.addAll(await _keysWhere(txn, serverWins ? keys : keys.and(_negate(_unsynced))));
        });
        final bool soft = _softDeleteColumn != null;
        if (remoteDeletes == FluentRemoteDeleteBehavior.soft && !soft) {
          FluentLog.issue(
            FluentIssueKind.remoteDeleteKept,
            'The server deleted ${safe.length} row(s) of "$tableName", but $modelType has no soft delete; they are kept.',
            table: tableName,
            tag: '$tableName:sync',
            hint: 'Add `with FluentSoftDeletable` to the model, or pull with remoteDeletes: FluentRemoteDeleteBehavior.auto / hard.',
          );
        } else if (safe.isNotEmpty) {
          final bool useSoft = soft && remoteDeletes != FluentRemoteDeleteBehavior.hard;
          final Object stamp = _softDeleteStamp();
          deleted = await _forKeyChunks(safe, (keys) => useSoft ? _softDeleteWhere(txn, keys, stamp, synced: true) : _hardDeleteWhere(txn, keys, synced: true), stored: true);
          if (useSoft && serverWins) {
            // Rows already in the trash whose deletion was not pushed yet: the server deleted them too, nothing to send.
            final FluentFilter trashedUnsent = FluentFilter.isNotNull(_softDeleteColumn.quotedIdentifier).and(_unsynced);
            await _forKeyChunks(safe, (keys) => _setRows(txn, const {}, keys.and(trashedUnsent), synced: true), stored: true);
          }
        }
      }

      if (rememberAs != null) {
        await _ensureSyncTables(txn);
        await txn.insert(_syncStateTable, {'tbl': tableName, 'last_pull': rememberAs.millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (deletedLocally.isNotEmpty) {
        FluentLog.debug('${deletedLocally.length} server row(s) of "$tableName" were not stored: deleted locally, the deletion is not pushed yet', tag: 'sync:$tableName');
      }
      return (pulled: incoming.length, conflicts: busy.length + deletedLocally.length, remoteDeleted: deleted);
    }),
  );

  /// The answer to a push for rows that must not take all of it ([busy]: edited while the push ran; [trashed]):
  /// only the server key columns are written, so the next push (or the tombstone of a later delete) carries the key.
  /// Busy rows stay pending, trashed rows stay synced. Nothing to do when the server key is the primary key.
  Future<void> _storeServerKeys(DatabaseExecutor ex, List<Map<String, dynamic>> rows, Set<int> busy, Set<int> trashed) async {
    final List<String> columns = [for (final String c in _serverKey) if (!keyColumnNames.contains(c)) c];
    if (columns.isEmpty) return;
    int changed = 0;
    for (final int i in {...busy, ...trashed}) {
      final Object? id = idFromRow(rows[i]);
      final Map<String, Object?> set = {for (final String c in columns) c: rows[i][c]};
      if (id == null || set.values.contains(null)) continue;
      final FluentFilter differs = FluentFilter(columns.map((c) => '${c.quotedIdentifier} IS NOT ?').join(' OR '), set.values.toList());
      changed += await _setRows(ex, set, _keyFilterOf(id, stored: true).and(differs), synced: !busy.contains(i)); // id and set come from a prepared row
    }
    _touched(FluentDbAction.update, changed);
  }

  /// The merged rows of [resolved] whose local row still has the version the merge was made from; the others
  /// changed (or went away) while the merge callback ran: the newer local row wins and stays pending.
  Future<List<T>> _unchangedMerges(DatabaseExecutor ex, List<({T model, Object id, int version})> resolved) async {
    if (resolved.isEmpty) return const [];
    final String version = _syncColumns!.version;
    final Map<String, int> current = {};
    await _forKeyChunks([for (final ({T model, Object id, int version}) r in resolved) r.id], (keys) async {
      for (final Map<String, Object?> row in await ex.query(tableName.quotedIdentifier, columns: [...keyColumnNames, version].quotedAll, where: keys.whereClause, whereArgs: _sqlArgs(keys.whereArgs))) {
        current[_keyText(_dartIdOf(row)!)] = row[version]! as int;
      }
      return 0;
    });
    final List<T> fresh = [for (final ({T model, Object id, int version}) r in resolved) if (current[_keyText(r.id)] == r.version) r.model];
    if (fresh.length < resolved.length) {
      FluentLog.debug('${resolved.length - fresh.length} merged row(s) of "$tableName" were not written: the local row changed while the merge ran (it stays pending)', tag: 'sync:$tableName');
    }
    return fresh;
  }

  /// Removes rows of [where] locally only (a cache reset): no tombstones, and rows with local changes not pushed yet
  /// are kept. Returns the number of removed rows.
  @internal
  Future<int> clearLocally(FluentFilter where) => _run<int>(
    FluentDbAction.relationWrite,
    data: () => _write('Clear cache', (txn) async {
      final FluentFilter scope = _resolveRelated(_keepBusyRows(where));
      await _flushValueLists(txn);
      return _hardDeleteWhere(txn, scope, synced: true);
    }),
  );

  /// Replaces the rows of [where] with [items] in one transaction (a cache refresh): rows with local changes not
  /// sent yet stay (and keep them: fetched rows for them are skipped, like in a pull), no tombstones are written, the
  /// new rows are stored as synced. Rows are matched by the server key.
  @internal
  Future<void> replaceLocally(FluentFilter where, List<T> items, {FluentRelationSyncMode? relationSync}) => _run<void>(
    FluentDbAction.relationWrite,
    data: () => _write('Replace cache', (txn) async {
      final FluentFilter scope = _resolveRelated(_keepBusyRows(where));
      await _flushValueLists(txn);
      await _hardDeleteWhere(txn, scope, synced: true);
      if (items.isEmpty) return;
      final List<String>? conflictOn = setEquals(_serverKey.toSet(), keyColumnNames.toSet()) ? null : _serverKey;
      List<T> fresh = items;
      if (_syncColumns != null) {
        final List<Map<String, dynamic>> prepared = [for (final T item in items) _prepareSqlJson(item)];
        // Also rows deleted locally whose deletion is not pushed yet: they must not come back.
        final Set<int> changed = await _busyRows(txn, _serverKey, prepared);
        final Set<int> busy = {...changed, ...await _tombstonedRows(txn, prepared)};
        if (changed.isNotEmpty) {
          // The server has these rows: known from now on, so deleting one later tells the server.
          final String synced = _syncColumns!.synced.quotedIdentifier;
          final FluentFilter unknown = FluentFilter('$synced = 0');
          final List<Object> ids = (await _existingByMatch(txn, _serverKey, [for (final int i in changed) prepared[i]], scope: unknown)).values.whereType<Object>().toList();
          await _forKeyChunks(ids, (keys) {
            final FluentFilter where = keys.and(unknown);
            return txn.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET $synced = -1 WHERE ${where.whereClause}', _sqlArgs(where.whereArgs));
          }, stored: true);
        }
        if (busy.isNotEmpty) {
          fresh = [for (int i = 0; i < items.length; i++) if (!busy.contains(i)) items[i]];
          FluentLog.debug('${busy.length} fetched row(s) of "$tableName" kept their local version (changes not sent yet)', tag: 'sync:$tableName');
        }
        if (fresh.isEmpty) return;
      }
      final FluentTask task = FluentTask(action: FluentDbAction.save, table: tableName, dbName: dbName, helper: TableHelper(syncWrite: true, syncMode: relationSync));
      if (_links.isNotEmpty) {
        await _saveGraph(txn, fresh, task, FluentRelationSaveContext(keepMissingOverride: _keepMissingOverride(task)), conflictOn: conflictOn);
        await _keepServerTimes(txn, fresh);
      } else {
        _injectKeys(fresh, await _writeRows(txn, [for (final T item in fresh) _prepareSqlJson(item)], FluentSaveStrategy.upsert, conflictOn: conflictOn, synced: true));
        await _keepServerTimes(txn, fresh);
        FluentEngine.touch(this, FluentDbAction.save, fresh);
      }
    }),
  );

  /// [where] without the rows a local-only removal must keep: rows with local changes not pushed yet, and rows
  /// whose cascade (`ON DELETE CASCADE` or a polymorphic `oneOf` list / reference, at any depth) would remove such rows of another table.
  FluentFilter _keepBusyRows(FluentFilter where) {
    final FluentFilter own = _syncColumns == null ? where : where.and(_negate(_unsynced));
    final String? busy = _busyBelow(tableName.quotedIdentifier, {this}, [0]);
    return busy == null ? own : own.and(FluentFilter('NOT ($busy)'));
  }

  /// SQL: the row of [outer] (a table name or alias) has a cascade descendant with local changes not pushed yet;
  /// `null` when no syncable table is reachable.
  String? _busyBelow(String outer, Set<FluentProvider> path, List<int> counter) {
    final List<String> parts = [];
    for (final (FluentProvider child, List<String> references, List<String> referenced) in _cascadeEdges) {
      if (path.contains(child)) continue; // a cycle: the rows of this branch are checked at its first visit
      final String alias = '"__c${counter[0]++}"';
      final String? below = child._busyBelow(alias, {...path, child}, counter);
      final String? own = child._syncColumns == null ? null : child._unsynced.whereClause;
      final String? busy = own == null ? below : below == null ? own : '($own) OR ($below)';
      if (busy == null) continue;
      final String link = [for (int i = 0; i < references.length; i++) '$alias.${references[i].quotedIdentifier} = $outer.${referenced[i].quotedIdentifier}'].join(' AND ');
      parts.add('EXISTS (SELECT 1 FROM ${child.tableName.quotedIdentifier} AS $alias WHERE $link AND ($busy))');
    }
    // Polymorphic (oneOf) references: deleted or cleared by `_polymorphicCascade`, either way the unsynced row is lost.
    final List<String> keys = keyColumnNames.toList();
    for (final (FluentProvider child, FluentRelationLink ref) in _oneOfPointing) {
      if (path.contains(child)) continue;
      final List<String> references = ref.columnsFor(tableName);
      if (references.length != keys.length) continue;
      final String alias = '"__c${counter[0]++}"';
      final String? below = child._busyBelow(alias, {...path, child}, counter);
      final String? own = child._syncColumns == null ? null : child._unsynced.whereClause;
      final String? busy = own == null ? below : below == null ? own : '($own) OR ($below)';
      if (busy == null) continue;
      final String link = [for (int i = 0; i < references.length; i++) '$alias.${references[i].quotedIdentifier} = $outer.${keys[i].quotedIdentifier}'].join(' AND ');
      final String type = "'${tableName.replaceAll("'", "''")}'";
      parts.add('EXISTS (SELECT 1 FROM ${child.tableName.quotedIdentifier} AS $alias WHERE $alias.${ref.typeColumn!.quotedIdentifier} = $type AND $link AND ($busy))');
    }
    return parts.isEmpty ? null : parts.join(' OR ');
  }

  static FluentFilter _negate(FluentFilter f) => FluentFilter('NOT (${f.whereClause})', f.whereArgs);
}
