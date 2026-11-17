// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// Parameters per statement chunk: below SQLite's default limit of 999 bound variables.
const int _maxParamsPerChunk = 900;

/// The last soft-delete stamp handed out (epoch milliseconds), see `_softDeleteStamp`.
int _lastSoftDeleteStamp = 0;

/// A saved row: what happened and its key.
typedef _WrittenRow = (FluentRowOutcome outcome, Object? id);

/// Building blocks shared by the CRUD API: visibility, row writing, soft delete / restore, field updates, errors.
extension _FluentCrudHelper<T extends FluentStorable> on FluentProvider<T> {
  // ---------------------------------------------------------------------------
  // Tasks and filters
  // ---------------------------------------------------------------------------

  /// Dispatches a CRUD task of this table through [FluentDbInternals.executeTask].
  ///
  /// [relations] / [maxDepth] say which relations reads load (`FluentLoad.none` travels as depth 0); [tag] marks the
  /// change events.
  Future<R> _run<R>(
    FluentDbAction action, {
    TableHelper? helper,
    Object? data,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    Object? tag,
  }) =>
      // Future.sync: an error while the task is built (a provider that is not registered) fails the Future, it never
      // throws at the call. The task is still queued synchronously, so the call order is kept.
      Future.sync(
        () => FluentDbInternals.executeTask<T, R>(
          provider: this,
          task: FluentTask(
            action: action,
            table: tableName,
            dbName: dbName,
            data: data,
            helper: helper,
            policy: policy,
            tag: tag,
            maxDepth: relations == FluentLoad.none ? 0 : maxDepth.clamp(1, _FluentRelationReader.maxDepthLimit),
            ignoreLazy: relations == FluentLoad.all,
          ),
        ),
      );


  /// SQL expression of the current time in epoch milliseconds: SQLite's clock, or the replaced test clock.
  static String get _sqlNow => FluentClock.isReplaced ? '${FluentClock.millis}' : _sqlNowMs;

  /// SQLite's current time in epoch milliseconds.
  static const String _sqlNowMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  /// The version columns of a `FluentSyncable` provider, or `null`.
  ({String version, String synced})? get _syncColumns {
    final FluentProvider<T> self = this;
    if (self is! FluentSyncable) return null;
    final FluentSyncable sync = self as FluentSyncable;
    return (version: sync.syncVersionColumn, synced: sync.syncedVersionColumn);
  }

  /// SQL assignments keeping the sync versions: a local change raises `sync_version`; a change received from the
  /// server ([synced]) marks the row synced. Empty for providers without sync.
  List<String> _versionSet({required bool synced}) {
    final ({String version, String synced})? c = _syncColumns;
    if (c == null) return const [];
    final String v = c.version.quotedIdentifier;
    return synced ? ['${c.synced.quotedIdentifier} = $v'] : ['$v = $v + 1'];
  }

  /// `UPDATE` of [set] (+ [extra] SQL assignments, e.g. [FluentUpdate]s) on the rows matching [where].
  (String, List<Object?>) _updateSql(Map<String, Object?> set, FluentFilter where, List<String> extra) {
    final List<String> parts = [for (final String k in set.keys) '${k.quotedIdentifier} = ?', ...extra];
    final String condition = where.whereClause.isEmpty ? '' : ' WHERE ${where.whereClause}';
    return ('UPDATE ${tableName.quotedIdentifier} SET ${parts.join(', ')}$condition', [...set.values, ...?_sqlArgs(where.whereArgs)]);
  }

  /// Updates [set] (and the [computed] SQL assignments) on the rows matching [where], keeping the sync versions (see
  /// [_versionSet]).
  Future<int> _setRows(DatabaseExecutor ex, Map<String, Object?> set, FluentFilter where, {bool synced = false, List<String> computed = const []}) {
    final List<String> extra = [...computed, ..._versionSet(synced: synced)];
    if (extra.isEmpty) return ex.update(tableName.quotedIdentifier, set.quotedKeys, where: _clause(where), whereArgs: _args(where));
    final (String sql, List<Object?> args) = _updateSql(set, where, extra);
    return ex.rawUpdate(sql, args);
  }

  /// The current time as stored in timestamp columns (epoch milliseconds).
  static int _now() => FluentClock.now().millisecondsSinceEpoch;


  /// The rows reads see: not soft-deleted (any with [includeDeleted], only soft-deleted with [deletedOnly]) and
  /// not expired (unless [includeExpired]).
  FluentFilter _visibility({bool includeExpired = false, bool? deletedOnly, bool? includeDeleted}) {
    final _TrashScope scope = _TrashScope.current;
    deletedOnly ??= scope == _TrashScope.only;
    includeDeleted ??= scope == _TrashScope.all;
    if (deletedOnly) includeExpired = true; // the trash shows everything that was deleted
    FluentFilter filter = FluentFilter.empty;
    final String? deleted = _softDeleteColumn;
    if (deleted != null && !includeDeleted) filter = deletedOnly ? FluentFilter.isNotNull(deleted.quotedIdentifier) : FluentFilter.isNull(deleted.quotedIdentifier);
    if (!includeExpired) {
      // "Now" is evaluated by SQLite when the query runs (not when it is queued), and identical reads keep identical
      // SQL, so the engine can still answer them with one query.
      final String expiry = _expiryColumn.quotedIdentifier;
      filter = filter.and(FluentFilter('$expiry IS NULL OR $expiry > $_sqlNow'));
    }
    return filter;
  }

  /// One term of `orderBy`: a column (plain, quoted — `""` escapes a quote inside — or `table.column`) or a function of one, optionally with
  /// `COLLATE`, `ASC` / `DESC` and `NULLS FIRST` / `LAST`.
  static final RegExp _orderTerm = RegExp(
    r'^\s*(?:[A-Za-z_]\w*\(\s*(?:(?:"(?:[^"]|"")+"|[A-Za-z_]\w*)(?:\.(?:"(?:[^"]|"")+"|[A-Za-z_]\w*))?)?\s*\)|(?:"(?:[^"]|"")+"|[A-Za-z_]\w*)(?:\.(?:"(?:[^"]|"")+"|[A-Za-z_]\w*))?)'
    r'(?:\s+COLLATE\s+\w+)?(?:\s+(?:ASC|DESC))?(?:\s+NULLS\s+(?:FIRST|LAST))?\s*$',
    caseSensitive: false,
  );

  /// [orderBy] when it only orders by columns; anything else (sub-queries, comments, `;`) is refused, so a sort
  /// order taken from user input can never run SQL of its own.
  String? _checkedOrderBy(String? orderBy) {
    if (orderBy == null || orderBy.trim().isEmpty) return orderBy;
    if (_splitOrderTerms(orderBy).every(_orderTerm.hasMatch)) return orderBy;
    throw FluentLog.raise(
      FluentArgumentException(
        'orderBy',
        'orderBy of "$tableName" may only name columns (with ASC / DESC, COLLATE, NULLS FIRST / LAST).',
        hint: "Order by columns, e.g. orderBy: 'created_at DESC, id'. Never pass user input as SQL: map the choice to a "
            "column name (switch (sort) { 'new' => 'created_at DESC', ... }). For anything else use rawQuery."
            "${_unquotedNameHint(orderBy, 'orderBy')}",
      ),
      tag: '$tableName:orderBy',
    );
  }

  /// A hint line when a term of [orderBy] looks like a column name with a space or dash that is not quoted.
  static String _unquotedNameHint(String orderBy, String argument) {
    for (final String term in _splitOrderTerms(orderBy)) {
      final String t = term.trim();
      if (!t.startsWith('"') && RegExp(r'^[\p{L}_][\p{L}\p{N}_]*[ -][\p{L}\p{N}_ -]*$', unicode: true).hasMatch(t.replaceFirst(RegExp(r'\s+(ASC|DESC)$', caseSensitive: false), ''))) {
        return " A column name with a space or dash must be quoted: $argument: '\"${t.replaceFirst(RegExp(r'\s+(ASC|DESC)$', caseSensitive: false), '')}\"'.";
      }
    }
    return '';
  }

  /// Splits [orderBy] at the commas outside quoted names.
  static List<String> _splitOrderTerms(String orderBy) {
    final List<String> terms = [];
    final StringBuffer term = StringBuffer();
    bool quoted = false;
    for (final int unit in orderBy.codeUnits) {
      final String c = String.fromCharCode(unit);
      if (c == '"') quoted = !quoted;
      if (c == ',' && !quoted) {
        terms.add(term.toString());
        term.clear();
      } else {
        term.write(c);
      }
    }
    terms.add(term.toString());
    return terms;
  }

  /// [where] narrowed by [scope] (both optional).
  FluentFilter _scoped(FluentFilter? where, FluentFilter scope) => (where ?? FluentFilter.empty).and(scope);

  /// A [TableHelper] carrying [filter] as `where` / `whereArgs` (none for an empty filter).
  TableHelper _helperFor(
    FluentFilter filter, {
    String? orderBy,
    int? limit,
    int? offset,
    Map<String, dynamic>? dataMap,
    Object? value,
    String? shape,
    List<String>? columns,
    bool distinct = false,
  }) => TableHelper(
    where: filter.whereClause.isEmpty ? null : filter.whereClause,
    whereArgs: filter.whereClause.isEmpty ? null : _sqlArgs(filter.whereArgs),
    orderBy: orderBy,
    limit: limit,
    offset: offset,
    dataMap: dataMap,
    value: value,
    shape: shape,
    columns: columns,
    distinct: distinct,
    deferred: filter.deferred.isEmpty ? null : filter.deferred,
  );

  /// The cost-model shape of a read: the caller's [where] plus the visibility flags.
  String _shape(FluentFilter? where, {bool includeExpired = false}) {
    final _TrashScope scope = _TrashScope.current;
    return [where?.description ?? '', if (scope == _TrashScope.only) '[trash]', if (scope == _TrashScope.all) '[+deleted]', if (includeExpired) '[+expired]'].where((p) => p.isNotEmpty).join(' ');
  }

  /// [columns] checked against the table (user columns only); an unknown one fails with the list of valid ones.
  List<String> _checkColumns(List<String> columns, String call) {
    final Set<String> known = {for (final FluentDbColumn c in getFullSchema) if (!FluentProvider._isInternalColumn(c.name)) c.name};
    if (columns.isEmpty) {
      throw FluentLog.raise(FluentArgumentException('columns', '$call on "$tableName" got an empty column list.', hint: 'Pass the columns to read, or leave columns out to read all of them.'), tag: '$tableName:$call');
    }
    for (final String column in columns) {
      if (!known.contains(column)) {
        throw FluentLog.raise(
          FluentArgumentException('columns', '$call: "$tableName" has no column "$column".', hint: 'Columns of "$tableName": ${known.join(', ')}. Use stored column names (as in buildJson), not Dart field names.'),
          tag: '$tableName:$call',
        );
      }
    }
    return columns;
  }

  /// Stored [rows] as maps of Dart values, without internal columns (see `findMaps`).
  List<Map<String, dynamic>> _decodeMaps(List<Map<String, dynamic>> rows) {
    final List<_MappingWarning> warnings = [];
    final List<Map<String, dynamic>> maps = [for (final Map<String, dynamic> row in rows) _plan.decodeRow(row, warnings)];
    _logWarnings(warnings);
    return maps;
  }

  /// The task's filter (`helper.where` / `helper.whereArgs`).
  FluentFilter _taskFilter(FluentTask task) {
    final String? where = task.helper?.where;
    return where == null || where.isEmpty ? FluentFilter.empty : FluentFilter(where, [...?task.helper?.whereArgs]);
  }

  /// Converts Dart values in query arguments (bool, DateTime, enum, ...) to SQLite values: arguments of a
  /// [FluentFilter] ([FluentFilterArgs]) like their column on save (see [_filterValue]), others with the table settings.
  List<Object?>? _sqlArgs(List<Object?>? args) {
    if (args == null || args.isEmpty) return args;
    if (args is FluentFilterArgs) return [for (int i = 0; i < args.raw.length; i++) _filterValue(args.raw[i], args.columnAt(i))];
    if (args.every((a) => a == null || a is String || a is num || a is Uint8List)) return args;
    return [for (final Object? a in args) FluentSqlSanitizer.sanitizeValueOnly(a, _tableConfig)];
  }

  /// Runs [action] for [ids] in chunks that stay below the bound-variable limit. [stored]: [ids] are SQLite values (read
  /// from rows) and are used as they are; otherwise they are Dart values that the key columns convert like on save.
  Future<int> _forKeyChunks(List<Object> ids, Future<int> Function(FluentFilter keys) action, {bool stored = false}) async {
    final int step = keysPerChunk(_maxParamsPerChunk);
    int total = 0;
    for (int i = 0; i < ids.length; i += step) {
      total += await action(_keysFilterOf(ids.sublist(i, math.min(i + step, ids.length)), stored: stored));
    }
    return total;
  }

  /// Keys of the rows matching [where]: the stored values (to put back into filters of this table or its references),
  /// or with [dart] the Dart values (to compare with the keys of models).
  Future<List<Object>> _keysWhere(DatabaseExecutor ex, FluentFilter where, {bool dart = false}) async {
    final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: keyColumnNames.toList().quotedAll, where: _clause(where), whereArgs: _args(where));
    return [for (final Map<String, Object?> r in rows) ?(dart ? _dartIdOf(r) : idFromRow(r))];
  }

  static String? _clause(FluentFilter f) => f.whereClause.isEmpty ? null : f.whereClause;

  /// [f]'s arguments as SQLite values (converted per column, see [_sqlArgs]).
  List<Object?>? _args(FluentFilter f) => f.whereClause.isEmpty ? null : _sqlArgs(f.whereArgs);

  // ---------------------------------------------------------------------------
  // Writing rows
  // ---------------------------------------------------------------------------

  /// Writes prepared [rows] with [strategy], matching existing rows by the key or by [conflictOn].
  ///
  /// * `upsert`: `UPDATE` the matching rows, then `INSERT` the ones that did not exist. A conflict on another
  ///   UNIQUE column fails loudly (no `INSERT OR IGNORE`).
  /// * `insertOnly`: existing rows are skipped, the others inserted.
  /// * `updateOnly` / `patch`: only existing rows are updated (`patch` leaves `null` fields untouched).
  ///
  /// Soft delete: a row in the trash (matched by the key or by `conflictOn`) counts as missing. `upsert` /
  /// `insertOnly` bring it back (outcome `restored`, together with the children deleted with it; a row whose owner
  /// is still in the trash stays there, outcome `skipped`) and write the new data; `updateOnly` / `patch` skip it.
  /// A live row wins over a trashed one with the same `conflictOn` values. Writes received from the server
  /// ([synced]) update a trashed row in place and leave it in the trash, its sync versions untouched (a local delete
  /// that was not pushed yet stays pending).
  ///
  /// Expiry: a row whose `timeToLive` passed is invisible to reads. `updateOnly` / `patch` skip it (like `findById`),
  /// `insertOnly` writes over it (outcome `inserted`), `upsert` updates it (outcome `updated`; the model's
  /// `timeToLive` renews it; without one it becomes live, no expiry). Server writes ([synced]) match it like any row.
  ///
  /// Rows repeating the same match values in one call are written once (the last one wins; the first for
  /// `insertOnly`) and share its outcome and key. Writes use one `UPDATE` and one `INSERT` batch at most (no
  /// `RETURNING` / `ON CONFLICT`, so every SQLite version works). Returns the outcome and key of every row.
  Future<List<_WrittenRow>> _writeRows(DatabaseExecutor ex, List<Map<String, dynamic>> rows, FluentSaveStrategy strategy, {List<String>? conflictOn, bool synced = false}) async {
    final Set<String> keys = keyColumnNames;
    final List<String> match = conflictOn ?? keys.toList();
    final int n = rows.length;
    final List<FluentRowOutcome?> outcomes = List<FluentRowOutcome?>.filled(n, null);
    final List<Object?> ids = [for (final Map<String, dynamic> r in rows) idFromRow(r)];

    // Which row is written for each distinct match value.
    final List<String?> matchKeys = List<String?>.filled(n, null);
    final Map<String, int> writer = {};
    for (int i = 0; i < n; i++) {
      final List<Object?> values = [for (final String c in match) rows[i][c]];
      if (values.contains(null)) continue;
      final String key = _valuesKey(match, values);
      matchKeys[i] = key;
      if (strategy == FluentSaveStrategy.insertOnly) {
        writer.putIfAbsent(key, () => i);
      } else {
        writer[key] = i;
      }
    }
    bool writes(int i) => matchKeys[i] == null || writer[matchKeys[i]] == i;
    final ({String created, String updated})? times = _timestampColumns;
    final int now = _now();
    final String? deleted = _softDeleteColumn;
    final FluentFilter? alive = deleted != null && conflictOn != null ? FluentFilter.isNull(deleted.quotedIdentifier) : null;
    // Expired rows (timeToLive passed) are invisible to reads: `updateOnly` / `patch` treat them as missing (like
    // findById), `insertOnly` writes over them, `upsert` updates them (the model's timeToLive renews them). Server
    // writes keep matching every row.
    final String expiry = _expiryColumn.quotedIdentifier;
    final bool onlyFresh = !synced && (strategy == FluentSaveStrategy.updateOnly || strategy == FluentSaveStrategy.patch);
    final FluentFilter? fresh = onlyFresh ? FluentFilter('$expiry IS NULL OR $expiry > $_sqlNow') : null;
    final bool renews = !synced && (strategy == FluentSaveStrategy.upsert || strategy == FluentSaveStrategy.insertOnly);
    // Rows matched in the trash: written by their stored key (there is no live row with the same match values).
    final Map<int, Object> trashedId = {};
    FluentFilter matchOf(int i) {
      final Object? stored = trashedId[i];
      if (stored != null) return _keyFilterOf(stored, stored: true);
      FluentFilter where = _equalsAll({for (final String c in match) c: rows[i][c]}, stored: true); // rows[i] is stored already
      if (alive != null) where = where.and(alive);
      return fresh == null ? where : where.and(fresh);
    }

    // Rows whose match is in the trash.
    final Set<int> revived = {};
    final Set<int> inPlace = {}; // server writes to a trashed row: updated, left in the trash
    if (deleted != null) {
      final Map<String, int> byMatch = {for (int i = 0; i < n; i++) if (writes(i) && matchKeys[i] != null) matchKeys[i]!: i};
      final Map<String, Object> trashed = byMatch.isEmpty ? const {} : await _trashedMatches(ex, match, [for (final int i in byMatch.values) rows[i]], live: conflictOn != null);
      if (trashed.isNotEmpty) {
        final List<int> hit = [for (final String k in trashed.keys) byMatch[k]!];
        for (final MapEntry<String, Object> e in trashed.entries) {
          trashedId[byMatch[e.key]!] = e.value;
        }
        if (strategy == FluentSaveStrategy.updateOnly || strategy == FluentSaveStrategy.patch) {
          for (final int i in hit) {
            outcomes[i] = FluentRowOutcome.skipped;
          }
        } else if (synced) {
          inPlace.addAll(hit);
          FluentLog.debug('Server rows written to rows in the trash; they stay there', tag: '$tableName:save', context: {'rows': hit.length});
        } else {
          final List<Object> hitIds = [for (final int i in hit) trashedId[i]!];
          await _forKeyChunks(hitIds, (k) => _restoreWhere(ex, k, synced: synced), stored: true);
          final Set<String> still = await _trashedKeys(ex, hitIds); // children of an owner that is still deleted
          for (final int i in hit) {
            if (still.contains(_keyText(trashedId[i]!))) {
              outcomes[i] = FluentRowOutcome.skipped;
            } else {
              revived.add(i);
            }
          }
          FluentLog.issue(
            FluentIssueKind.trashRevived,
            'Saving ${hit.length} model(s) of "$tableName" whose rows were in the trash: ${revived.length} restored'
            "${still.isEmpty ? '' : ', ${hit.length - revived.length} stay in the trash with their deleted owner'}.",
            table: tableName,
            tag: '$tableName:save',
            hint: 'Saving a deleted key${conflictOn == null ? '' : ' (or conflictOn values)'} brings the row back (outcome "restored"). Use restore() to do it explicitly, or a new key for a new row.',
            context: {'keys': hitIds},
          );
        }
        for (final int i in [...revived, ...inPlace]) {
          // A row matched by other columns than the key keeps its stored key: the caller's own key is not the row's.
          ids[i] = conflictOn == null ? ids[i] ?? trashedId[i] : trashedId[i];
        }
      }
    }
    final Set<int> fromTrash = {...revived, ...inPlace};

    final List<int> toInsert = [];
    final List<int> toUpdate = [...fromTrash];
    // insertOnly over an expired row: written like a new row (outcome `inserted`, new created-at time).
    final Set<int> overExpired = {};
    if (strategy == FluentSaveStrategy.insertOnly) {
      final List<Map<String, dynamic>> candidates = [for (int i = 0; i < n; i++) if (writes(i) && matchKeys[i] != null && outcomes[i] == null && !fromTrash.contains(i)) rows[i]];
      final Map<String, Object?> existing = await _existingByMatch(ex, match, candidates, scope: alive);
      final FluentFilter expired = FluentFilter('$expiry IS NOT NULL AND $expiry <= $_sqlNow');
      final Map<String, Object?> stale = existing.isEmpty || synced
          ? const {}
          : await _existingByMatch(ex, match, [for (final Map<String, dynamic> r in candidates) if (existing.containsKey(_valuesKey(match, [for (final String c in match) r[c]]))) r], scope: alive == null ? expired : alive.and(expired));
      for (int i = 0; i < n; i++) {
        if (!writes(i) || outcomes[i] != null || fromTrash.contains(i)) continue;
        final String? key = matchKeys[i];
        if (key != null && stale.containsKey(key)) {
          overExpired.add(i);
          toUpdate.add(i);
          ids[i] = conflictOn == null ? ids[i] ?? stale[key] : stale[key] ?? ids[i];
        } else if (key != null && existing.containsKey(key)) {
          outcomes[i] = FluentRowOutcome.skipped;
          ids[i] = conflictOn == null ? ids[i] ?? existing[key] : existing[key] ?? ids[i];
        } else {
          toInsert.add(i);
        }
      }
    } else {
      for (int i = 0; i < n; i++) {
        if (!writes(i) || outcomes[i] != null || fromTrash.contains(i)) continue;
        if (matchKeys[i] == null) {
          if (strategy == FluentSaveStrategy.upsert) {
            toInsert.add(i);
          } else {
            outcomes[i] = FluentRowOutcome.skipped;
          }
        } else {
          toUpdate.add(i);
        }
      }
    }

    if (toUpdate.isNotEmpty) {
      final Batch updates = ex.batch();
      // patch: the type tags of the patched fields are merged into the stored ones afterwards (see _mergePatchTags).
      final String meta = FluentDbColumn.systemMetadata().name;
      final bool patch = strategy == FluentSaveStrategy.patch;
      final Map<int, ({FluentFilter where, Set<String> fields})> patched = {};
      for (final int i in toUpdate) {
        final Map<String, Object?> set = {
          for (final MapEntry<String, dynamic> e in rows[i].entries)
            if (!keys.contains(e.key) && !match.contains(e.key) && !(patch && (e.value == null || e.key == meta))) e.key: e.value,
          if (times != null) times.updated: now,
          if (times != null && overExpired.contains(i)) times.created: now,
        };
        final FluentFilter where = matchOf(i);
        if (patch) patched[i] = (where: where, fields: set.keys.toSet());
        final List<String> extra = [
          // A model without timeToLive keeps the stored expiry of a live row; a row that expired already is made
          // live again (the save renews it: it would stay invisible otherwise).
          if (renews && !rows[i].containsKey(_expiryColumn)) '$expiry = CASE WHEN $expiry <= $_sqlNow THEN NULL ELSE $expiry END',
          if (!inPlace.contains(i)) ..._versionSet(synced: synced),
        ];
        if (set.isEmpty && extra.isEmpty) {
          // Nothing to change: a no-op update still tells whether the row exists.
          final String first = match.first.quotedIdentifier;
          updates.rawUpdate('UPDATE ${tableName.quotedIdentifier} SET $first = $first WHERE ${where.whereClause}', _sqlArgs(where.whereArgs));
        } else if (extra.isEmpty) {
          updates.update(tableName.quotedIdentifier, set.quotedKeys, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs));
        } else {
          final (String sql, List<Object?> args) = _updateSql(set, where, extra);
          updates.rawUpdate(sql, args);
        }
      }
      final List<Object?> results = await updates.commit();
      for (int k = 0; k < toUpdate.length; k++) {
        final int i = toUpdate[k];
        if ((results[k] as int? ?? 0) > 0) {
          outcomes[i] = revived.contains(i) ? FluentRowOutcome.restored : (overExpired.contains(i) ? FluentRowOutcome.inserted : FluentRowOutcome.updated);
        } else if (strategy == FluentSaveStrategy.upsert || strategy == FluentSaveStrategy.insertOnly) {
          toInsert.add(i);
        } else {
          outcomes[i] = FluentRowOutcome.skipped;
        }
      }
      patched.removeWhere((i, _) => outcomes[i] != FluentRowOutcome.updated);
      if (patched.isNotEmpty && tableColumns.contains(meta)) await _mergePatchTags(ex, rows, patched);
    }

    if (toInsert.isNotEmpty) {
      final Batch inserts = ex.batch();
      final ({String version, String synced})? sync = _syncColumns;
      for (final int i in toInsert) {
        inserts.insert(tableName.quotedIdentifier, {
          ...rows[i],
          if (times != null) ...{times.created: now, times.updated: now},
          if (sync != null) ...{sync.version: 1, sync.synced: synced ? 1 : 0},
        }.quotedKeys);
      }
      // Results (row ids) are only read back when a generated key is needed: skipping them saves a lot on big batches.
      final bool rowIdKey = !hasCompositeKey && primaryKeyColumns.first.type == FluentDbDataType.integer;
      final bool needIds = rowIdKey && toInsert.any((i) => ids[i] == null);
      final List<Object?> results = await inserts.commit(noResult: !needIds);
      for (int k = 0; k < toInsert.length; k++) {
        final int i = toInsert[k];
        outcomes[i] = FluentRowOutcome.inserted;
        if (needIds && ids[i] == null && results[k] is int) ids[i] = results[k];
      }
    }

    // Rows updated through conflictOn: the key of the row that was really updated replaces the one the caller carried
    // (a server id, a different local key, none). Rows brought back from the trash have theirs already.
    if (conflictOn != null && !setEquals(match.toSet(), keys)) {
      final List<Map<String, dynamic>> updatedRows = [for (int i = 0; i < n; i++) if (writes(i) && matchKeys[i] != null && outcomes[i] == FluentRowOutcome.updated && !fromTrash.contains(i)) rows[i]];
      if (updatedRows.isNotEmpty) {
        final Map<String, Object?> found = await _existingByMatch(ex, match, updatedRows, scope: alive);
        for (int i = 0; i < n; i++) {
          if (writes(i) && matchKeys[i] != null && outcomes[i] == FluentRowOutcome.updated && !fromTrash.contains(i)) ids[i] = found[matchKeys[i]] ?? ids[i];
        }
      }
    }

    // Repeated rows share the outcome and key of the row that was written.
    for (int i = 0; i < n; i++) {
      if (writes(i)) continue;
      final int w = writer[matchKeys[i]]!;
      outcomes[i] = outcomes[w];
      ids[i] = ids[w];
    }
    if (!synced && _syncColumns != null) {
      await _dropTombstonesOfWritten(ex, [for (int i = 0; i < n; i++) if (writes(i) && ids[i] != null && (outcomes[i] == FluentRowOutcome.inserted || outcomes[i] == FluentRowOutcome.updated || outcomes[i] == FluentRowOutcome.restored)) ids[i]!]);
    }
    return [for (int i = 0; i < n; i++) (outcomes[i]!, ids[i])];
  }

  /// Stored keys of the trashed rows whose [match] columns equal those of [rows], by match value (see
  /// [_valuesKey]); with [live], match values that also have a live row are left out (the live row wins).
  Future<Map<String, Object>> _trashedMatches(DatabaseExecutor ex, List<String> match, List<Map<String, dynamic>> rows, {required bool live}) async {
    final String deleted = _softDeleteColumn!;
    final Map<String, Object> trashed = {
      for (final MapEntry<String, Object?> e in (await _existingByMatch(ex, match, rows, scope: FluentFilter.isNotNull(deleted.quotedIdentifier))).entries)
        if (e.value != null) e.key: e.value!,
    };
    if (!live || trashed.isEmpty) return trashed;
    final List<Map<String, dynamic>> hits = [for (final Map<String, dynamic> r in rows) if (trashed.containsKey(_valuesKey(match, [for (final String c in match) r[c]]))) r];
    final Map<String, Object?> alive = await _existingByMatch(ex, match, hits, scope: FluentFilter.isNull(deleted.quotedIdentifier));
    return trashed..removeWhere((k, _) => alive.containsKey(k));
  }

  /// [id] as a match key over the key columns (see [_valuesKey], [_trashedKeys]).
  String _keyText(Object id) {
    final FluentKey key = _normalizeKey(id);
    return _valuesKey(keyColumnNames.toList(), [for (final String c in keyColumnNames) key[c]]);
  }

  /// Match keys (see [_valuesKey], key column order) of the rows among [ids] that are in the trash.
  Future<Set<String>> _trashedKeys(DatabaseExecutor ex, List<Object> ids) async {
    final String deleted = _softDeleteColumn!;
    final List<String> keys = keyColumnNames.toList();
    final Set<String> found = {};
    await _forKeyChunks(ids, (filter) async {
      final FluentFilter where = filter.and(FluentFilter.isNotNull(deleted.quotedIdentifier));
      for (final Map<String, Object?> r in await ex.query(tableName.quotedIdentifier, columns: keys.quotedAll, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs))) {
        found.add(_valuesKey(keys, [for (final String c in keys) r[c]]));
      }
      return 0;
    }, stored: true);
    return found;
  }

  /// After a `patch`: replaces the stored type tags of the patched fields with their new tags and keeps the tags of
  /// the untouched fields. Two batches: read the stored tags, write the changed ones.
  Future<void> _mergePatchTags(DatabaseExecutor ex, List<Map<String, dynamic>> rows, Map<int, ({FluentFilter where, Set<String> fields})> patched) async {
    final String meta = FluentDbColumn.systemMetadata().name;
    final List<int> order = patched.keys.toList();
    final Batch reads = ex.batch();
    for (final int i in order) {
      reads.query(tableName.quotedIdentifier, columns: [meta].quotedAll, where: patched[i]!.where.whereClause, whereArgs: _sqlArgs(patched[i]!.where.whereArgs), limit: 1);
    }
    final List<Object?> stored = await reads.commit();
    final Batch writes = ex.batch();
    bool changed = false;
    for (int k = 0; k < order.length; k++) {
      final int i = order[k];
      final ({FluentFilter where, Set<String> fields}) p = patched[i]!;
      final List<Object?> found = stored[k]! as List<Object?>;
      final Map<String, Object?> current = found.isEmpty ? {} : _decodeMeta((found.first! as Map<String, Object?>)[meta]);
      final Map<String, Object?> merged = {...current}
        ..removeWhere((key, _) => p.fields.contains(key))
        ..addAll({for (final MapEntry<String, Object?> e in _decodeMeta(rows[i][meta]).entries) if (p.fields.contains(e.key)) e.key: e.value});
      if (mapEquals(merged, current)) continue;
      writes.update(tableName.quotedIdentifier, {meta: merged.isEmpty ? null : jsonEncode(merged)}.quotedKeys, where: p.where.whereClause, whereArgs: _sqlArgs(p.where.whereArgs));
      changed = true;
    }
    if (changed) await writes.commit(noResult: true);
  }

  /// Keys of existing rows whose [match] columns equal those of [rows], by match value.
  Future<Map<String, Object?>> _existingByMatch(DatabaseExecutor ex, List<String> match, List<Map<String, dynamic>> rows, {FluentFilter? scope}) async {
    final Map<String, Object?> found = {};
    if (rows.isEmpty) return found;
    final List<String> columns = {...keyColumnNames, ...match}.toList();
    final int step = math.max(1, _maxParamsPerChunk ~/ match.length);
    for (int i = 0; i < rows.length; i += step) {
      final List<Object> tuples = [
        for (final Map<String, dynamic> r in rows.sublist(i, math.min(i + step, rows.length)))
          match.length == 1 ? r[match.first] as Object : FluentKey({for (final String c in match) c: r[c]}),
      ];
      final FluentFilter where = scope == null ? _tupleFilter(match, match, tuples, stored: true) : _tupleFilter(match, match, tuples, stored: true).and(scope); // rows are stored
      for (final Map<String, Object?> r in await ex.query(tableName.quotedIdentifier, columns: columns.quotedAll, where: where.whereClause, whereArgs: _sqlArgs(where.whereArgs))) {
        found[_valuesKey(match, [for (final String c in match) r[c]])] = idFromRow(r);
      }
    }
    return found;
  }

  /// A lookup key for the [values] of [columns] (same order): every value is normalized the way SQLite stores it in
  /// its column (see [_storedForm]), so the Dart value and the stored value of the same row give the same key, and
  /// different values never do (`1` / `'1'` / `'01'` in a TEXT column are `'1'`, `'1'`, `'01'`; in an INTEGER column
  /// all three are `1`; `null` differs from the text `'null'`).
  String _valuesKey(List<String> columns, List<Object?> values) {
    final Map<String, FluentDbDataType?> types = _columnAffinities;
    final StringBuffer key = StringBuffer();
    for (int i = 0; i < values.length; i++) {
      if (i > 0) key.write('\u0001');
      key.write(_storedForm(i < columns.length ? types[columns[i]] : null, values[i]));
    }
    return key.toString();
  }

  /// The column affinities of this table by column name (`null`: no affinity, the value keeps its type); rebuilt
  /// when the schema was.
  Map<String, FluentDbDataType?> get _columnAffinities {
    final List<FluentDbColumn> schema = getFullSchema;
    final ({List<FluentDbColumn> schema, Map<String, FluentDbDataType?> types})? cached = _affinityCache[this];
    if (cached != null && identical(cached.schema, schema)) return cached.types;
    final Map<String, FluentDbDataType?> types = {for (final FluentDbColumn c in schema) c.name: _affinityOf(c)};
    _affinityCache[this] = (schema: schema, types: types);
    return types;
  }

  static final Expando<({List<FluentDbColumn> schema, Map<String, FluentDbDataType?> types})> _affinityCache = Expando('fluentColumnAffinities');

  /// SQLite's affinity of [column] as one of the types (`integer` also stands for NUMERIC); `null` for BLOB / none.
  static FluentDbDataType? _affinityOf(FluentDbColumn column) {
    if (column.type != FluentDbDataType.custom) return column.type == FluentDbDataType.blob ? null : column.type;
    final String declared = (column.customSql ?? '').trimLeft().toUpperCase();
    final String word = RegExp(r'^[A-Z0-9_]*').stringMatch(declared) ?? '';
    if (word.contains('INT')) return FluentDbDataType.integer;
    if (word.contains('CHAR') || word.contains('CLOB') || word.contains('TEXT')) return FluentDbDataType.text;
    if (word.isEmpty || word.contains('BLOB')) return null;
    if (word.contains('REAL') || word.contains('FLOA') || word.contains('DOUB')) return FluentDbDataType.real;
    return FluentDbDataType.integer; // NUMERIC
  }

  /// [value] as a column of affinity [type] stores it: a tagged text, equal exactly when the stored values are equal.
  /// Tags: `N` null, `S` text, `I` integer, `R` real, `B` bytes (hex).
  static String _storedForm(FluentDbDataType? type, Object? value) {
    if (value == null) return 'N';
    Object v = value;
    if (v is bool) v = v ? 1 : 0;
    if (v is DateTime) v = v.millisecondsSinceEpoch;
    if (v is List<int>) return 'B${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    if (type == FluentDbDataType.text) return 'S$v';
    // Numeric affinities also convert text that looks like a number; no affinity keeps text as text.
    final num? number = v is num ? v : (v is String && type != null ? _parseNumber(v) : null);
    if (number == null) return 'S$v';
    if (type == FluentDbDataType.real) return 'R${number.toDouble()}';
    if (number is double && !(number.isFinite && number == number.truncateToDouble() && number.abs() < 9.2e18)) return 'R$number';
    return 'I${number.toInt()}';
  }

  /// The number [text] stands for (blanks around it allowed), or `null`.
  static num? _parseNumber(String text) {
    final String t = text.trim();
    if (t.isEmpty) return null;
    final int? whole = int.tryParse(t);
    if (whole != null) return whole;
    final double? real = double.tryParse(t);
    return real != null && real.isFinite ? real : null;
  }

  /// Checks `conflictOn` columns before a save: they must exist ([FluentArgumentException]) and should be unique (a
  /// `conflictOn` issue otherwise).
  void _checkConflictOn(List<String>? conflictOn) {
    if (conflictOn == null) return;
    final List<String> unknown = [for (final String c in conflictOn) if (!tableColumns.contains(c)) c];
    if (conflictOn.isEmpty || unknown.isNotEmpty) {
      throw FluentLog.raise(
        FluentArgumentException(
          'conflictOn',
          conflictOn.isEmpty ? 'is empty' : 'unknown column(s) ${unknown.join(', ')} in "$tableName"',
          hint: 'List the columns that identify a row, e.g. conflictOn: ["email"].',
        ),
        tag: '$tableName:save',
      );
    }
    final Set<String> wanted = conflictOn.toSet();
    final String? deleted = _softDeleteColumn;
    final bool unique =
        setEquals(wanted, keyColumnNames) ||
        (conflictOn.length == 1 && getFullSchema.any((c) => c.name == conflictOn.first && c.isUnique)) ||
        tableIndexes.any((i) => i.unique && setEquals(i.columns.toSet(), wanted) && (i.where == null || (deleted != null && i.where == '${deleted.quotedIdentifier} IS NULL')));
    if (!unique) {
      FluentLog.issue(
        FluentIssueKind.conflictOn,
        'conflictOn ${conflictOn.join(', ')} of "$tableName" is not backed by a UNIQUE constraint; one save may update several rows.',
        table: tableName,
        subject: conflictOn.join(','),
        tag: '$tableName:save',
        hint: 'Mark the column isUnique, or add FluentIndex.unique([${conflictOn.map((c) => "'$c'").join(', ')}]) to the model\'s indexes.',
      );
    }
  }

  /// Writes the generated / found keys back into the saved models: a missing key is filled, and a key that differs
  /// from the written row's (`conflictOn` matched another row) is replaced.
  ///
  /// At once (later calls of the same transaction need the keys), and taken back when the transaction or savepoint
  /// of the write rolls back: SQLite reuses a rolled-back rowid, so a kept key would make the next save of the model
  /// overwrite another row.
  void _injectKeys(List<FluentStorable> items, List<_WrittenRow> written) {
    if (hasCompositeKey) return;
    final String key = primaryKeyColumns.first.name;
    for (int i = 0; i < items.length; i++) {
      final Object? stored = written[i].$2;
      if (stored == null) continue;
      // The written key is a stored value; the model carries the Dart value (converter, codec).
      final Object? id = _plan.decodeValue(key, stored, []);
      final Object? given = items[i].buildJson()[key];
      if (given == null) {
        if (fluentSameKeyValue(items[i].metadata[key], id)) continue;
        FluentTransactionScope.whenRolledBack(dbName, items[i].keyRestorer(key));
        items[i].injectRelationId(key, id);
      } else if (!fluentSameKeyValue(given, id)) {
        FluentTransactionScope.whenRolledBack(dbName, items[i].keyRestorer(key));
        items[i].forceKey(key, id, replaced: given); // a conflictOn match: the stored row has another key
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Field updates
  // ---------------------------------------------------------------------------

  /// Sets [fields] on the rows matching [where]; Dart values are converted like on save.
  ///
  /// Type metadata is kept exact: tags of the updated columns are replaced (rows that already carry metadata are
  /// merged one by one, only where the stored tags change; all others get the new tags in one statement). Key columns
  /// and the columns the library keeps (trash, sync versions, expiry, type metadata, archived columns) throw
  /// [FluentArgumentException].
  Future<int> _updateFields(DatabaseExecutor ex, FluentFilter where, Map<String, Object?> fields) async {
    for (final String k in fields.keys) {
      final String? hint = _libraryColumnHint(k);
      if (hint == null) continue;
      throw FluentLog.raise(
        FluentArgumentException('fields', '"$tableName.$k" is kept by the library and cannot be set with updateById / updateWhere', hint: hint),
        tag: '$tableName:update',
      );
    }
    final List<String> unknown = [for (final String k in fields.keys) if (!tableColumns.contains(k) || keyColumnNames.contains(k)) k];
    if (unknown.isNotEmpty) {
      throw FluentLog.raise(
        FluentArgumentException(
          'fields',
          'unknown or key column(s) ${unknown.join(', ')} in "$tableName"',
          hint: 'Use column names of the table (see the model\'s buildJson). Keys are changed by saving the model under a new key.',
        ),
        tag: '$tableName:update',
      );
    }

    final Map<String, Object?> set = {};
    final Map<String, String> tags = {};
    final List<String> computed = [];
    for (MapEntry<String, Object?> e in fields.entries) {
      final Object? value = e.value;
      if (value is FluentUpdate) {
        if (value.operation == FluentUpdateOperation.now) {
          e = MapEntry(e.key, FluentClock.now()); // stored like every DateTime of the column (format, converter)
        } else {
          computed.add(_computedAssignment(e.key, value));
          continue;
        }
      }
      final FluentConverter<Object?, Object?>? converter = _converters[e.key];
      if (converter != null) {
        set[e.key] = _convert(e.key, e.value, converter, toSql: true);
        continue;
      }
      final ({dynamic value, String? metaType}) result = FluentSqlSanitizer.sanitize(value: e.value, config: _tableConfig, tableName: tableName, key: e.key);
      set[e.key] = result.value;
      if (result.metaType != null && result.metaType != _valueKinds[e.key]?.tag) tags[e.key] = result.metaType!;
    }
    if (set.isEmpty && computed.isEmpty) return 0;
    final ({String created, String updated})? times = _timestampColumns;
    if (times != null) set.putIfAbsent(times.updated, _now);

    final String meta = FluentDbColumn.systemMetadata().name;
    if (tableColumns.contains(meta)) {
      // Rows whose stored tags change: with new tags every row carrying metadata, otherwise only rows whose tags name
      // an updated column (a text pre-filter on the JSON keys, checked exactly below).
      final Set<String> updated = {...set.keys, ...fields.keys};
      FluentFilter tagged = where.and(FluentFilter.isNotNull(meta.quotedIdentifier));
      if (tags.isEmpty) {
        tagged = tagged.and(updated.map((k) => FluentFilter('${meta.quotedIdentifier} LIKE ?', ['%${jsonEncode(k)}:%'])).reduce((a, b) => a.or(b)));
      }
      final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: [...keyColumnNames, meta].quotedAll, where: tagged.whereClause, whereArgs: _sqlArgs(tagged.whereArgs));
      final Batch batch = ex.batch();
      bool changed = false;
      for (final Map<String, Object?> r in rows) {
        final Map<String, Object?> current = _decodeMeta(r[meta]);
        final Map<String, Object?> merged = {...current}
          ..removeWhere((k, _) => updated.contains(k))
          ..addAll(tags);
        if (mapEquals(merged, current)) continue;
        final FluentFilter byKey = _keyFilterOf(idFromRow(r), stored: true);
        batch.update(tableName.quotedIdentifier, {meta: merged.isEmpty ? null : jsonEncode(merged)}.quotedKeys, where: byKey.whereClause, whereArgs: _sqlArgs(byKey.whereArgs));
        changed = true;
      }
      if (changed) await batch.commit(noResult: true);
      if (tags.isNotEmpty) {
        final FluentFilter untagged = where.and(FluentFilter.isNull(meta.quotedIdentifier));
        await ex.update(tableName.quotedIdentifier, {meta: jsonEncode(tags)}.quotedKeys, where: untagged.whereClause, whereArgs: _sqlArgs(untagged.whereArgs));
      }
    }
    return _setRows(ex, set, where, computed: computed);
  }

  /// Why [column] cannot be set by a field update (a column the library keeps), or `null` when it can.
  String? _libraryColumnHint(String column) {
    if (column == _softDeleteColumn) return 'Use delete() / deleteWhere() to move rows to the trash and trash.restore() / trash.restoreWhere() to bring them back.';
    final ({String version, String synced})? sync = _syncColumns;
    if (sync != null && (column == sync.version || column == sync.synced)) {
      return 'Sync versions are kept by the library: every local write marks the row changed, syncWithServer marks it pushed.';
    }
    if (column == _expiryColumn) return "The expiry comes from the model's timeToLive: save the model again to renew it; clearExpired() removes expired rows.";
    if (FluentProvider._isInternalColumn(column)) return 'Type metadata and archived columns are written by the library; set the model fields instead.';
    return null;
  }

  /// The SQL assignment of a computed [update] of [column], checked against the column's type.
  String _computedAssignment(String column, FluentUpdate update) {
    final FluentDbColumn c = getFullSchema.firstWhere((c) => c.name == column);
    final String q = column.quotedIdentifier;
    final bool number = (c.type == FluentDbDataType.integer || c.type == FluentDbDataType.real) && c.valueKind == null && !_converters.containsKey(column);
    switch (update.operation) {
      case FluentUpdateOperation.add:
        if (!number || !update.amount.isFinite) {
          throw FluentLog.raise(
            FluentArgumentException('fields', '$update needs a number column; "$tableName.$column" is ${c.valueKind?.name ?? c.type.name}.', hint: 'Use increment / decrement on int or double fields only.'),
            tag: '$tableName:update',
          );
        }
        return '$q = COALESCE($q, 0) + ${update.amount}';
      case FluentUpdateOperation.toggle:
        if (c.valueKind != FluentValueKind.boolean) {
          throw FluentLog.raise(
            FluentArgumentException('fields', 'FluentUpdate.toggle needs a bool column; "$tableName.$column" is ${c.valueKind?.name ?? c.type.name}.', hint: 'Use toggle on bool fields only.'),
            tag: '$tableName:update',
          );
        }
        return '$q = CASE WHEN $q THEN 0 ELSE 1 END';
      case FluentUpdateOperation.now:
        return '$q = $q'; // never reached: _updateFields writes `now` as a DateTime value
    }
  }

  Map<String, Object?> _decodeMeta(Object? raw) {
    if (raw is! String || raw.isEmpty) return {};
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? Map<String, Object?>.from(decoded) : {};
    } catch (e) {
      // Damaged type metadata: the column kinds decide (the row mapping reports it when the row is read).
      FluentLog.debug('Type metadata of a row of "$tableName" cannot be read; column kinds are used: $e', tag: '$tableName:update');
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // Soft delete, restore, hard delete
  // ---------------------------------------------------------------------------

  /// The value written to the soft-delete column: epoch milliseconds in every table, whatever its `dateTimeFormat`
  /// (the column is INTEGER). Filters and cursors on the column pass milliseconds too (`_filterValue`,
  /// `_storedValue`), and the cascade writes the owner's stamp into child tables with other date formats unchanged.
  ///
  /// Stamps are strictly increasing within the process: restore brings back the children deleted *together* with
  /// an owner by matching its stamp, so two deletes in the same millisecond must not share one.
  int _softDeleteStamp() {
    _lastSoftDeleteStamp = math.max(FluentClock.now().millisecondsSinceEpoch, _lastSoftDeleteStamp + 1);
    return _lastSoftDeleteStamp;
  }

  /// Converts soft-delete stamps stored as ISO text (`iso8601` tables before 2.0.0-dev.3, 1.x, or a cascade from
  /// such a table) to epoch milliseconds, so filters, cursors and the order on the column see one form. Runs in the
  /// schema sync of the table (the stamp format is part of its fingerprint, so an older database is converted once).
  ///
  /// The text is read the way Dart wrote it (`DateTime.parse`: local time without an offset), so stamps that were
  /// equal stay equal and restore still finds the children deleted together with their owner. Only the stamp
  /// changes: sync versions are kept (no change for the server). Text that is no date is left as it is (the row
  /// stays in the trash; the purge matches text stamps too). Reported as an autoFix issue.
  Future<void> _adoptMillisStamps(DatabaseExecutor ex) async {
    final String? column = _softDeleteColumn;
    if (column == null) return;
    final String c = column.quotedIdentifier;
    final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: [...keyColumnNames, column].quotedAll, where: "typeof($c) = 'text'");
    if (rows.isEmpty) return;
    final Batch batch = ex.batch();
    int converted = 0;
    for (final Map<String, Object?> r in rows) {
      final Object? id = idFromRow(r);
      final DateTime? at = DateTime.tryParse((r[column]! as String).trim());
      if (id == null || at == null) continue;
      final FluentFilter byKey = _keyFilterOf(id, stored: true);
      batch.update(tableName.quotedIdentifier, {column: at.millisecondsSinceEpoch}.quotedKeys, where: byKey.whereClause, whereArgs: _sqlArgs(byKey.whereArgs));
      converted++;
    }
    if (converted > 0) await batch.commit(noResult: true);
    final int kept = rows.length - converted;
    FluentLog.issue(
      FluentIssueKind.storedFormatAdopted,
      'Soft-delete stamps of "$tableName" stored as ISO text were converted to epoch milliseconds: $converted row(s)'
      "${kept == 0 ? '' : ', $kept stamp(s) that are no date were left as they are'}.",
      table: tableName,
      subject: column,
      tag: '$tableName:schema',
      hint: 'Nothing to do: the trash keeps its rows and dates. The soft-delete column always holds epoch milliseconds now, '
          'so filters and findPage on "$column" work with DateTime values in every table.',
      context: {'converted': converted, 'kept': kept},
    );
  }

  /// Owned relations whose children are soft-deleted / restored together with this table's rows.
  Iterable<FluentRelationLink> get _softCascadeLinks => _links.where((l) => l.isOwned && identical(l.owner, this) && l.target._softDeleteColumn != null);

  /// Soft-deletes the not yet deleted rows matching [where]; owned soft-deletable children get the same [stamp].
  Future<int> _softDeleteWhere(DatabaseExecutor ex, FluentFilter where, Object stamp, {bool synced = false}) async {
    final String column = _softDeleteColumn!;
    final FluentFilter alive = where.and(FluentFilter.isNull(column.quotedIdentifier));
    final List<FluentRelationLink> cascade = _softCascadeLinks.toList();
    if (cascade.isEmpty) return _touched(FluentDbAction.delete, await _setRows(ex, {column: stamp}, alive, synced: synced));

    final List<Object> ids = await _keysWhere(ex, alive);
    if (ids.isEmpty) return 0;
    final int count = _touched(FluentDbAction.delete, await _forKeyChunks(ids, (keys) => _setRows(ex, {column: stamp}, keys, synced: synced), stored: true)); // ids come from rows
    for (final FluentRelationLink link in cascade) {
      await _forOwnerChunks(link, ids, (owners) => link.target._softDeleteWhere(ex, owners, stamp, synced: synced));
    }
    return count;
  }

  /// Restores the soft-deleted rows matching [where] (only those deleted at [stamp], when given) and the owned
  /// children that were deleted together with them.
  Future<int> _restoreWhere(DatabaseExecutor ex, FluentFilter where, {Object? stamp, bool synced = false}) async {
    final String column = _softDeleteColumn!;
    FluentFilter deleted = where.and(stamp == null ? FluentFilter.isNotNull(column.quotedIdentifier) : FluentFilter('${column.quotedIdentifier} = ?', [stamp]));
    // A row whose owner is still in the trash stays there: restoring it alone would make a visible orphan.
    final FluentFilter? ownerDeleted = stamp == null ? _ownerInTrash() : null;
    if (ownerDeleted != null) {
      final FluentFilter orphans = deleted.and(ownerDeleted);
      final int skipped =
          Sqflite.firstIntValue(await ex.rawQuery('SELECT COUNT(*) FROM ${tableName.quotedIdentifier} WHERE ${orphans.whereClause}', _sqlArgs(orphans.whereArgs))) ?? 0;
      if (skipped > 0) {
        FluentLog.issue(
          FluentIssueKind.trashStays,
          '$skipped row(s) of "$tableName" stay in the trash: their owner is deleted.',
          table: tableName,
          tag: '$tableName:restore',
          hint: 'Restore the owner instead: it brings back the children deleted together with it.',
        );
      }
      deleted = deleted.and(FluentFilter('NOT (${ownerDeleted.whereClause})', ownerDeleted.whereArgs));
    }
    final List<FluentRelationLink> cascade = _softCascadeLinks.toList();
    if (cascade.isEmpty) return _touched(FluentDbAction.restore, await _setRows(ex, {column: null}, deleted, synced: synced));

    final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: [...keyColumnNames, column].quotedAll, where: deleted.whereClause, whereArgs: _sqlArgs(deleted.whereArgs));
    if (rows.isEmpty) return 0;
    final Map<Object, List<Object>> ownersByStamp = {};
    for (final Map<String, Object?> r in rows) {
      ownersByStamp.putIfAbsent(r[column]!, () => []).add(idFromRow(r)!);
    }
    final List<Object> ids = [for (final List<Object> owners in ownersByStamp.values) ...owners];
    final int count = _touched(FluentDbAction.restore, await _forKeyChunks(ids, (keys) => _setRows(ex, {column: null}, keys, synced: synced), stored: true));
    for (final FluentRelationLink link in cascade) {
      for (final MapEntry<Object, List<Object>> e in ownersByStamp.entries) {
        await _forOwnerChunks(link, e.value, (owners) => link.target._restoreWhere(ex, owners, stamp: e.key, synced: synced));
      }
    }
    return count;
  }

  /// Rows of this table owned (through an owned relation) by a row that is in the trash, or `null` when no owner of
  /// this table is soft-deletable.
  FluentFilter? _ownerInTrash() {
    final List<String> conditions = [
      for (final FluentRelationLink link in _incomingLinks)
        if (link.owner._softDeleteColumn != null)
          'EXISTS (SELECT 1 FROM ${link.owner.tableName.quotedIdentifier} o WHERE '
              '${[for (int k = 0; k < link.foreignKeys.length; k++) 'o.${link.referencedColumns[k].quotedIdentifier} = ${tableName.quotedIdentifier}.${link.foreignKeys[k].quotedIdentifier}'].join(' AND ')}'
              '${link.typeCondition(tableName.quotedIdentifier)} AND o.${link.owner._softDeleteColumn!.quotedIdentifier} IS NOT NULL)',
    ];
    return conditions.isEmpty ? null : FluentFilter(conditions.join(' OR '));
  }

  /// Runs [action] with filters matching the children of [owners] (their stored keys) through [link], chunked.
  Future<void> _forOwnerChunks(FluentRelationLink link, List<Object> owners, Future<int> Function(FluentFilter children) action) async {
    final int step = math.max(1, _maxParamsPerChunk ~/ link.foreignKeys.length);
    for (int i = 0; i < owners.length; i += step) {
      await action(_tupleFilter(link.foreignKeys, link.referencedColumns, owners.sublist(i, math.min(i + step, owners.length)), stored: true).and(link.typeFilter));
    }
  }

  /// Permanently deletes the rows matching [where]; related rows follow the foreign key rules.
  ///
  /// What SQLite's `ON DELETE CASCADE` removes without passing through a provider is prepared first, for the rows
  /// of [where] and every cascaded descendant: sync tombstones (unless [synced]) and the polymorphic clean-up.
  Future<int> _hardDeleteWhere(DatabaseExecutor ex, FluentFilter where, {bool synced = false}) async {
    // Sync: the server learns about the deletion with the next push — also of owned children the cascade removes.
    if (!synced) await _writeTombstones(ex, where);
    await _polymorphicCascade(ex, where, synced: synced);
    await _prepareCascade(ex, where, synced: synced, visited: {});
    final int count = await ex.delete(tableName.quotedIdentifier, where: _clause(where), whereArgs: _args(where));
    if (count > 0) {
      await _cleanupAfterDelete(ex);
      _touched(FluentDbAction.hardDelete, count);
      for (final (FluentProvider provider, FluentDbAction action) in _hardDeleteRipple) {
        FluentEngine.touch(provider, action);
      }
    }
    return count;
  }

  /// Tables whose rows SQLite deletes together with rows of this one (`ON DELETE CASCADE`): owned children (not the
  /// polymorphic ones, which are deleted through their provider, see [_polymorphicCascade]) and rows whose `one`
  /// reference to this table cascades. Each edge: the child, its reference columns and the columns of this table
  /// they point to.
  List<(FluentProvider, List<String>, List<String>)> get _cascadeEdges => [
    for (final FluentRelationLink l in _links)
      if (l.isOwned && !l.isPolymorphic && identical(l.owner, this) && l.onDelete == FluentOnDelete.cascade) (l.target, l.foreignKeys, l.referencedColumns),
    for (final FluentProvider peer in _relationPeers)
      for (final FluentRelationLink l in peer._links)
        if (l.isReference && identical(l.target, this) && l.onDelete == FluentOnDelete.cascade) (peer, l.foreignKeys, l.referencedColumns),
  ];

  /// `oneOf` references of other tables that can point to this table.
  List<(FluentProvider, FluentRelationLink)> get _oneOfPointing => [
    for (final FluentProvider peer in _relationPeers)
      for (final FluentRelationLink l in peer._links)
        if (l.type == FluentRelationType.oneOf && l.targets.containsKey(tableName) && identical(l.targets[tableName], this)) (peer, l),
  ];

  /// Whether this table or a table the cascade reaches from it satisfies [need].
  bool _cascadeReaches(bool Function(FluentProvider p) need, Set<FluentProvider> visited) {
    if (!visited.add(this)) return false;
    if (need(this)) return true;
    return _cascadeEdges.any((e) => e.$1._cascadeReaches(need, visited));
  }

  /// Before the rows of [where] are deleted: for the descendants the cascade will remove, writes their tombstones
  /// (unless [synced]) and runs their polymorphic clean-up. Descendants are found level by level from the key values
  /// of their owners (chunked, no correlated sub-queries), so any depth, composite keys and filters qualified with the
  /// table name work. [visited] holds the rows already handled per table (self-references, cycles).
  Future<void> _prepareCascade(DatabaseExecutor ex, FluentFilter where, {required bool synced, required Map<FluentProvider, Set<String>> visited}) async {
    bool need(FluentProvider p) => (!synced && p._syncColumns != null) || p._oneOfPointing.isNotEmpty;
    final List<(FluentProvider, List<String>, List<String>)> edges = [for (final e in _cascadeEdges) if (e.$1._cascadeReaches(need, {})) e];
    if (edges.isEmpty) return;
    final List<String> columns = {...keyColumnNames, for (final e in edges) ...e.$3}.toList();
    final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: columns.quotedAll, where: _clause(where), whereArgs: _args(where));
    final Set<String> seen = visited.putIfAbsent(this, () => {});
    final List<Map<String, Object?>> fresh = [for (final Map<String, Object?> r in rows) if (seen.add(_tupleKey(idFromRow(r)))) r];
    if (fresh.isEmpty) return;
    for (final (FluentProvider child, List<String> references, List<String> referenced) in edges) {
      final Map<String, Object> owners = {
        for (final Map<String, Object?> r in fresh)
          if (_rowTuple(r, referenced, referenced) case final Object v) _tupleKey(v): v,
      };
      final List<Object> values = owners.values.toList();
      final int step = math.max(1, _maxParamsPerChunk ~/ references.length);
      for (int i = 0; i < values.length; i += step) {
        final FluentFilter children = _tupleFilter(references, referenced, values.sublist(i, math.min(i + step, values.length)), stored: true);
        if (!synced) await child._writeTombstones(ex, children);
        await child._polymorphicCascade(ex, children, synced: synced);
        await child._prepareCascade(ex, children, synced: synced, visited: visited);
      }
    }
  }

  /// What SQLite cannot do for polymorphic references (`oneOf`), before rows of [where] are deleted for good: rows
  /// pointing to them are deleted (the owner declares the list with `via:`, or `onDelete: cascade`) or cleared.
  Future<void> _polymorphicCascade(DatabaseExecutor ex, FluentFilter where, {required bool synced}) async {
    final List<(FluentProvider, FluentRelationLink)> pointing = _oneOfPointing;
    if (pointing.isEmpty) return;
    final List<String> keys = keyColumnNames.toList();
    List<Object>? ids; // only for composite keys: single keys are matched with a sub-query, nothing is loaded
    for (final (FluentProvider child, FluentRelationLink ref) in pointing) {
      final FluentRelationLink? owned = _links.where((l) => l.isPolymorphic && identical(l.target, child) && l.typeColumn == ref.typeColumn).firstOrNull;
      final bool delete = (owned?.onDelete ?? ref.onDelete) == FluentOnDelete.cascade;
      final List<String> columns = ref.columnsFor(tableName);
      final FluentFilter ofThisTable = FluentFilter.eq(ref.typeColumn!.quotedIdentifier, tableName);

      Future<void> apply(FluentFilter children) async {
        if (delete) {
          await child._removeChildrenForGood(ex, children, synced: synced);
        } else if (await child._setRows(ex, {ref.typeColumn!: null, for (final String c in ref.foreignKeys) c: null}, children, synced: synced) > 0) {
          FluentEngine.touch(child, FluentDbAction.update);
        }
      }

      if (columns.length == 1) {
        final String rows = where.whereClause.trim().isEmpty ? '' : ' WHERE ${where.whereClause}';
        // The sub-query filters this table: its values are stored with this table's settings here, not the child's.
        await apply(FluentFilter('${columns.single.quotedIdentifier} IN (SELECT ${keys.single.quotedIdentifier} FROM ${tableName.quotedIdentifier}$rows)', _sqlArgs(where.whereArgs) ?? const []).and(ofThisTable));
        continue;
      }
      final List<Object> all = ids ??= await _keysWhere(ex, where);
      final int step = math.max(1, (_maxParamsPerChunk - 1) ~/ columns.length);
      for (int i = 0; i < all.length; i += step) {
        await apply(_tupleFilter(columns, keys, all.sublist(i, math.min(i + step, all.length)), stored: true).and(ofThisTable));
      }
    }
  }

  /// Deletes owned children for good together with their owner (even soft-deletable ones: the owner is gone).
  Future<int> _removeChildrenForGood(DatabaseExecutor ex, FluentFilter where, {required bool synced}) => _hardDeleteWhere(ex, where, synced: synced);

  /// Reports a change of this table to the running task (see `FluentEngine.touch`) when [count] rows changed.
  int _touched(FluentDbAction action, int count) {
    if (count > 0) FluentEngine.touch(this, action);
    return count;
  }

  /// Tables a hard delete of this table changes through the foreign key rules: owned children (recursively) are
  /// deleted, references (`one`) are cleared, link rows of many-to-many relations are removed.
  Set<(FluentProvider, FluentDbAction)> get _hardDeleteRipple {
    final Set<(FluentProvider, FluentDbAction)> ripple = {};
    void visit(FluentProvider p) {
      for (final FluentRelationLink link in p._links) {
        if (link.isOwned && identical(link.owner, p) && ripple.add((link.target, FluentDbAction.hardDelete))) visit(link.target);
        if (link.isManyToMany) ripple.add((link.target, FluentDbAction.update));
      }
      for (final FluentProvider peer in p._relationPeers) {
        for (final FluentRelationLink link in peer._links) {
          if (identical(link.target, p) && (link.type == FluentRelationType.one || link.isManyToMany)) ripple.add((peer, FluentDbAction.update));
        }
      }
    }

    visit(this);
    return ripple;
  }

  /// Soft-deleted rows deleted more than [olderThan] ago ([Duration.zero]: all of them).
  ///
  /// Stamps are epoch milliseconds (see `_softDeleteStamp`); ISO text written by older versions is converted at the
  /// start (`_adoptMillisStamps`), so the text branch only serves text a raw statement wrote later (compared with the
  /// library's six-digit ISO form, `fluentIsoText`).
  FluentFilter _deletedBefore(Duration olderThan) {
    final String column = _softDeleteColumn!;
    FluentFilter deleted = FluentFilter.isNotNull(column.quotedIdentifier);
    // Sync: a deletion the server has not received yet stays in the trash until it is pushed.
    final ({String version, String synced})? sync = _syncColumns;
    if (sync != null) deleted = deleted.and(FluentFilter('${sync.version.quotedIdentifier} <= ${sync.synced.quotedIdentifier}'));
    if (olderThan <= Duration.zero) return deleted;
    final DateTime cutoff = FluentClock.now().subtract(olderThan);
    final String c = column.quotedIdentifier;
    return deleted.and(
      FluentFilter("(typeof($c) IN ('integer', 'real') AND $c < ?) OR (typeof($c) = 'text' AND $c < ?)", [cutoff.millisecondsSinceEpoch, fluentIsoText(cutoff)]),
    );
  }

  // ---------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------

  /// Turns a SQLite error into a typed exception with a hint ("what → why → how to fix"); not logged here
  /// ([internalExecute] logs it once on its way to the caller).
  FluentException _sqlError(DatabaseException e, StackTrace stackTrace, String operation) {
    // Match SQLite's messages ("... constraint failed"), never the statement text the error also contains.
    final String text = e.toString();
    if (e.isReadOnlyError() || text.contains('readonly database')) {
      return FluentQueryException(
        '$operation on "$tableName" failed: the database is read-only',
        code: FluentErrorCode.readOnly,
        hint: 'The group was opened with FluentGroup(readOnly: true), or a write ran on a read connection (rawQuery only '
            'reads: use execute() for statements that change data).',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    if (e.isUniqueConstraintError() || text.contains('UNIQUE constraint failed')) {
      return FluentConstraintException(
        '$operation on "$tableName" violates a UNIQUE constraint: ${_constraintDetail(text)}',
        code: FluentErrorCode.uniqueViolation,
        hint: 'Another row already has this value. Load and update that row, or save with conflictOn: [<unique columns>] to update it by those columns.',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    if (text.contains('FOREIGN KEY constraint failed')) {
      return FluentConstraintException(
        '$operation on "$tableName" violates a FOREIGN KEY constraint',
        code: FluentErrorCode.foreignKeyViolation,
        hint: 'The referenced row does not exist. Save the referenced model first (or in the same save through a relation).',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    if (e.isNotNullConstraintError() || text.contains('NOT NULL constraint failed')) {
      return FluentConstraintException(
        '$operation on "$tableName" leaves a NOT NULL column empty: ${_constraintDetail(text)}',
        code: FluentErrorCode.notNullViolation,
        hint: 'Give the field a value in buildJson, or a defaultValue in the column definition.',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    if (text.contains('CHECK constraint failed')) {
      return FluentConstraintException(
        '$operation on "$tableName" violates a CHECK constraint: ${_constraintDetail(text)}',
        code: FluentErrorCode.checkViolation,
        hint: 'The value is outside the range allowed by the model\'s checks.',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    final String? missing = RegExp(r'no such table: ([^\s,)]+)').firstMatch(text)?.group(1);
    if (e.isNoSuchTableError() || missing != null) {
      return FluentQueryException(
        'Table "${missing ?? tableName}" does not exist ($operation on "$tableName")',
        code: FluentErrorCode.noSuchTable,
        hint: missing == null || missing == tableName
            ? 'Register the provider of "$tableName" in FluentDb.init before using it.'
            : 'Check the table name in the SQL; models are stored in the tables of their providers (tableName).',
        cause: e,
        stackTrace: stackTrace,
      );
    }
    final String? column = RegExp(r'no such column: ([^\s,)]+)').firstMatch(text)?.group(1);
    final bool syntax = column == null && text.contains('syntax error');
    return FluentQueryException(
      column != null ? '$operation on "$tableName" failed: no such column "$column"' : '$operation on "$tableName" failed: SQLite rejected the statement',
      hint: column != null
          ? 'Use column names of the table (see the model\'s buildJson); a FluentFilter on a typo\'d field fails the same way.'
          : syntax
              ? 'Check the SQL (raw filters, rawQuery, execute) against the cause below. A column name that is not a plain identifier '
                    "(a space, a dash, a dot) must be quoted in a FluentFilter and in orderBy: FluentFilter.eq('\"first name\"', value), orderBy: '\"first name\"'."
              : 'Check the SQL (raw filters, rawQuery, execute) against the cause below.',
      cause: e,
      stackTrace: stackTrace,
    );
  }

  static String _constraintDetail(String text) {
    final RegExpMatch? m = RegExp(r'constraint failed: ([^,)\n]+)').firstMatch(text);
    return m?.group(1)?.trim() ?? 'see the original error';
  }

  /// Runs a write in the open transaction (or a new one) and maps SQLite errors to typed exceptions.
  Future<R> _write<R>(String operation, Future<R> Function(Transaction txn) action) async {
    try {
      return await _runInTransaction(action);
    } on DatabaseException catch (e, s) {
      throw _sqlError(e, s, operation);
    }
  }

  bool? _keepMissingOverride(FluentTask task) => switch (task.helper?.syncMode) {
    FluentRelationSyncMode.preserveLocal => true,
    FluentRelationSyncMode.replace => false,
    null => null,
  };
}
