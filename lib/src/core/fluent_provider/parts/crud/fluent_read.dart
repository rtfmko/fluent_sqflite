// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Reading: models, maps and raw SQL.
///
/// Every read sees the same rows: soft-deleted rows are hidden (`withTrash` shows them, only [FluentTrash.find]
/// reads the trash alone) and rows whose expiry date has passed are hidden unless `includeExpired: true`.
/// Filters are [FluentFilter]s; Dart values in them (bool, DateTime, enum, Duration, ...) are stored like their column
/// stores them on save when the query runs. `orderBy` names columns only (`'name'`, `'created_at DESC, id'`, with
/// `COLLATE` / `NULLS FIRST|LAST`); anything else fails with a [FluentArgumentException] when the read runs.
/// [FluentLoad] `relations` says which relations load (default: the eager ones), `maxDepth` how many levels deep.
///
/// An identical read already in flight answers a call too (unless `policy: ExecutionPolicy.fresh`): the callers get
/// their own lists, but the models in them are the same instances.
extension FluentRead<T extends FluentStorable> on FluentProvider<T> {
  /// The model with key [id] (a plain value, or a [FluentKey] for composite keys), or `null` (also for a `null` [id]).
  /// An [id] that does not fit the key fails with a [FluentArgumentException]. Lookups of one table queued together
  /// run as one `IN (...)` query.
  ///
  /// ```dart
  /// final User? user = await users.findById(42);
  /// final Member? member = await members.findById(FluentKey({'team_id': 1, 'user_id': 7}));
  /// ```
  Future<T?> findById(Object? id, {bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (id == null) return null;
    keyFilter(id); // fails early (with a hint) when the id does not fit the key
    // The key travels separately from the visibility filter, so the engine can answer several queued lookups of
    // this table with one IN (...) query.
    final TableHelper helper = _helperFor(
      _visibility(includeExpired: includeExpired),
      shape: _shape(null, includeExpired: includeExpired),
    ).copyWith(id: id);
    return _run<T?>(FluentDbAction.findById, helper: helper, policy: policy, relations: relations, maxDepth: maxDepth);
  }

  /// The models with the keys [ids], in the order of [ids]; `null` keys and keys without a (visible) row are left
  /// out. Long lists are read in chunks (SQLite limits the arguments of one statement).
  ///
  /// ```dart
  /// final List<User> selected = await users.findByIds([3, 1, 2]);
  /// ```
  Future<List<T>> findByIds(
    Iterable<Object?> ids, {
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final List<Object?> wanted = [for (final Object? id in ids) ?id];
    if (wanted.isEmpty) return <T>[];
    final Map<String, T> byKey = {};
    final int step = keysPerChunk(_maxParamsPerChunk);
    for (int i = 0; i < wanted.length; i += step) {
      final List<Object?> chunk = wanted.sublist(i, math.min(i + step, wanted.length));
      for (final T model in await find(where: FluentFilter.ids(chunk), includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy)) {
        byKey[_keyTuple(model.primaryKeyValue)] = model;
      }
    }
    return [for (final Object? id in wanted) ?byKey[_keyTuple(id)]];
  }

  /// Models matching [where] (all without it), ordered by the columns [orderBy] (e.g. `'name DESC, id'`; see the
  /// extension doc), paged with [limit] / [offset]. Paging without [orderBy] publishes an `unordered` hint: SQLite
  /// has no defined row order. For "next page" lists see [findPage].
  ///
  /// ```dart
  /// final List<User> admins = await users.find(where: FluentFilter.eq('role', 'admin'), orderBy: 'name', limit: 20);
  /// ```
  Future<List<T>> find({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final Object? invalid = _pagingError('find', limit, offset);
    if (invalid != null) throw invalid;
    _hintUnordered('find', orderBy, limit, offset);
    return _run<List<T>>(
    FluentDbAction.find,
    helper: _helperFor(
      _scoped(where, _visibility(includeExpired: includeExpired)),
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      shape: _shape(where, includeExpired: includeExpired),
    ),
    policy: policy,
    relations: relations,
    maxDepth: maxDepth,
  );
  }

  /// The first model matching [where] in [orderBy] order, or `null`.
  ///
  /// ```dart
  /// final Message? latest = await messages.findFirst(where: FluentFilter.eq('chat_id', chatId), orderBy: 'sent_at DESC');
  /// ```
  Future<T?> findFirst({FluentFilter? where, String? orderBy, bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final List<T> found = await find(where: where, orderBy: orderBy, limit: 1, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy);
    return found.isEmpty ? null : found.first;
  }

  /// All models, ordered by [orderBy], at most [limit].
  Future<List<T>> findAll({String? orderBy, int? limit, bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      find(orderBy: orderBy, limit: limit, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy);

  /// Number of (visible) rows matching [where] (all without it).
  Future<int> count({FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _run<int>(
        FluentDbAction.count,
        helper: _helperFor(_scoped(where, _visibility(includeExpired: includeExpired)), shape: _shape(where, includeExpired: includeExpired)),
        policy: policy,
      );

  /// Whether a (visible) row with key [id] (a plain value or a [FluentKey]) exists; `false` for a `null` [id].
  Future<bool> exists(Object? id, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (id == null) return false;
    return _run<bool>(FluentDbAction.exists, helper: _helperFor(keyFilter(id).and(_visibility(includeExpired: includeExpired))), policy: policy);
  }

  /// Whether a (visible) row matching [where] exists. Stops at the first one: cheaper than `count(...) > 0`.
  ///
  /// ```dart
  /// if (await users.existsWhere(FluentFilter.eq('email', email))) showError('This e-mail is taken');
  /// ```
  Future<bool> existsWhere(FluentFilter where, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async => _run<bool>(
    FluentDbAction.exists,
    helper: _helperFor(where.and(_visibility(includeExpired: includeExpired)), shape: _shape(where, includeExpired: includeExpired)),
    policy: policy,
  );

  /// Rows matching [where] as maps of Dart values (`DateTime`, enums, lists, converted values — as the model gets
  /// them), without models, relations or internal columns. [columns] limits the columns read (a light list);
  /// [distinct] returns each distinct row once. An unknown or empty [columns] fails with a [FluentArgumentException].
  ///
  /// Projections are maps, not models: a model built from some columns would carry defaults in the others, and
  /// saving it would overwrite them.
  ///
  /// ```dart
  /// final List<Map<String, dynamic>> rows = await posts.findMaps(columns: ['id', 'title', 'created_at'], orderBy: 'id');
  /// ```
  Future<List<Map<String, dynamic>>> findMaps({
    FluentFilter? where,
    List<String>? columns,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _findMapsAs('findMaps', where: where, columns: columns, distinct: distinct, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, policy: policy);

  /// [findMaps] for a call named [call] (the name hints and errors use: `pluck` reads through it).
  Future<List<Map<String, dynamic>>> _findMapsAs(
    String call, {
    FluentFilter? where,
    List<String>? columns,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final Object? invalid = _pagingError(call, limit, offset);
    if (invalid != null) throw invalid;
    _hintUnordered(call, orderBy, limit, offset);
    final List<String>? selected = columns == null ? null : _checkColumns(columns, call);
    return _run<List<Map<String, dynamic>>>(
        FluentDbAction.findMaps,
        helper: _helperFor(
          _scoped(where, _visibility(includeExpired: includeExpired)),
          orderBy: orderBy,
          limit: limit,
          offset: offset,
          columns: selected == null ? null : [...selected, if (!distinct) FluentDbColumn.systemMetadata().name],
          distinct: distinct,
          shape: [_shape(where, includeExpired: includeExpired), if (selected != null) 'columns=${selected.join(',')}', if (distinct) 'distinct'].where((p) => p.isNotEmpty).join(' '),
        ),
        policy: policy,
      );
  }

  /// Models whose full-text indexed columns (`FluentIndex.fullText`) contain every word of [text], best matches first
  /// (FTS5; with FTS4 in index order, or by [orderBy] when given). The last word also matches longer words while
  /// [prefix] (search as you type); quotes and operators in [text] are plain text. Other parameters are those of
  /// [find]; an empty [text] lists every row (by [orderBy]).
  ///
  /// ```dart
  /// final List<Note> found = await notes.search(query, where: FluentFilter.eq('archived', false), limit: 30);
  /// ```
  Future<List<T>> search(
    String text, {
    FluentFilter? where,
    bool prefix = true,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final Object? invalid = _pagingError('search', limit, offset);
    if (invalid != null) throw invalid;
    final FluentSearchCondition condition = FluentSearchCondition(text, prefix: prefix);
    final String? module = _ftsModule;
    final FluentFilter matching = FluentFilter.search(text, prefix: prefix).and(where ?? FluentFilter.empty);
    if (module == null || condition.words.isEmpty || orderBy != null) {
      return find(where: matching, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy);
    }
    // Ranked: join the hits of the FTS table (their columns are renamed, so the caller's columns stay unambiguous).
    final FluentFilter scoped = _resolveRelated(_scoped(where, _visibility(includeExpired: includeExpired)));
    final String t = tableName.quotedIdentifier;
    final String fts = _ftsTable.quotedIdentifier;
    final bool ranked = module == 'fts5';
    final StringBuffer sql = StringBuffer(
      'SELECT $t.* FROM $t JOIN (SELECT rowid AS "__fluent_rowid"${ranked ? ', rank AS "__fluent_rank"' : ''} FROM $fts WHERE $fts MATCH ?) AS "__fluent_hits" '
      'ON "__fluent_hits"."__fluent_rowid" = $t."rowid"',
    );
    if (scoped.whereClause.isNotEmpty) sql.write(' WHERE ${scoped.whereClause}');
    if (ranked) sql.write(' ORDER BY "__fluent_hits"."__fluent_rank"');
    if (limit != null || offset != null) sql.write(' LIMIT ${limit ?? -1}${offset == null ? '' : ' OFFSET $offset'}');
    return _run<List<T>>(
      FluentDbAction.find,
      helper: TableHelper(
        sql: sql.toString(),
        whereArgs: [FluentFullTextSchema._matchQuery(condition, module), ...?_sqlArgs(scoped.whereArgs)],
        limit: limit,
        offset: offset,
        shape: ['search', _shape(where, includeExpired: includeExpired), if (limit != null) 'LIMIT'].where((p) => p.isNotEmpty).join(' '),
      ),
      policy: policy,
      relations: relations,
      maxDepth: maxDepth,
    );
  }

  /// The values of [column] of the rows matching [where], as Dart values ([distinct]: each value once). A value that
  /// is not a [V] fails with a [FluentArgumentException] (use a nullable [V] for a nullable column).
  ///
  /// ```dart
  /// final List<String> emails = await users.pluck<String>('email', orderBy: 'email');
  /// final List<Status> used = await posts.pluck<Status>('status', distinct: true);
  /// ```
  Future<List<V>> pluck<V>(
    String column, {
    FluentFilter? where,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final List<Map<String, dynamic>> rows = await _findMapsAs(
      'pluck',
      where: where,
      columns: [column],
      distinct: distinct,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      policy: policy,
    );
    final List<V> values = [];
    for (final Map<String, dynamic> row in rows) {
      final Object? value = row[column];
      if (value is! V) {
        throw FluentLog.raise(
          FluentArgumentException('V', 'pluck<$V>("$column") got a ${value.runtimeType} value from "$tableName".', hint: 'Use the Dart type of the column (pluck<${value.runtimeType}>), or a nullable one (pluck<$V?>) for a nullable column.'),
          tag: '$tableName:pluck',
        );
      }
      values.add(value);
    }
    return values;
  }

  /// One page of models ordered by the column [orderBy] (default: the key), starting [after] the previous page.
  ///
  /// Keyset pagination: unlike `offset`, pages never repeat or skip rows when rows are added or deleted meanwhile,
  /// and a deep page costs as much as the first one. The key is added to the order, so rows with equal [orderBy]
  /// values have a fixed order. An index on [orderBy] makes it fast for big tables. [FluentPage.next] is `null` on the
  /// last page. An unknown [orderBy] column, a [limit] below 1 or a cursor of another order fail with a
  /// [FluentArgumentException].
  ///
  /// ```dart
  /// final FluentPage<Message> first = await messages.findPage(orderBy: 'sent_at', descending: true, limit: 30);
  /// final FluentPage<Message> second = await messages.findPage(orderBy: 'sent_at', descending: true, limit: 30, after: first.next);
  /// ```
  Future<FluentPage<T>> findPage({
    FluentFilter? where,
    String? orderBy,
    bool descending = false,
    int limit = 50,
    FluentCursor? after,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final List<String> keys = keyColumnNames.toList();
    final String column = orderBy ?? keys.first;
    // Columns the model does not carry (type metadata, archives, the expiry computed on save, sync versions) cannot
    // give the cursor its value: refused before reading, not after the first page.
    final ({String version, String synced})? sync = _syncColumns;
    final bool notInModel = FluentProvider._isInternalColumn(column) || column == _expiryColumn || column == sync?.version || column == sync?.synced;
    // A sample that does not even write the key (a generic or empty sample) says nothing about the fields: no check.
    final Set<String>? sample = _modelFields;
    final Set<String>? fields = sample != null && sample.containsAll(keys) ? sample : null;
    final ({String created, String updated})? times = _timestampColumns;
    final bool managed = (times != null && (column == times.created || column == times.updated)) || column == _softDeleteColumn;
    final bool notCarried = fields != null && !fields.contains(column) && !managed;
    if (!tableColumns.contains(column) || notInModel || notCarried) {
      throw FluentLog.raise(
        FluentArgumentException('orderBy', '"$column" is not a column of "$tableName" that findPage can sort by', hint: "Name one column, e.g. orderBy: 'created_at'; findPage adds the key itself."),
        tag: '$tableName:findPage',
      );
    }
    if (limit < 1) throw FluentLog.raise(FluentArgumentException('limit', 'must be at least 1, got $limit', hint: 'findPage(limit: 50) reads 50 rows per page.'), tag: '$tableName:findPage');
    if (after != null && (after.orderBy != column || after.descending != descending)) {
      throw FluentLog.raise(
        FluentArgumentException(
          'after',
          'the cursor belongs to orderBy "${after.orderBy}"${after.descending ? ' descending' : ''}, not "$column"${descending ? ' descending' : ''}',
          hint: 'Pass the same orderBy / descending as for the page the cursor came from.',
        ),
        tag: '$tableName:findPage',
      );
    }

    final String dir = descending ? 'DESC' : 'ASC';
    final List<String> orderColumns = [column, ...keys.where((k) => k != column)];
    final FluentFilter? position = after == null ? null : _afterCursor(after, column, keys, descending);
    final List<T> rows = await find(
      where: position == null ? where : _scoped(where, position),
      orderBy: orderColumns.map((c) => '${c.quotedIdentifier} $dir').join(', '),
      limit: limit + 1,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    );
    if (rows.length <= limit) return FluentPage<T>(rows, null);
    final List<T> items = rows.sublist(0, limit);
    final T last = items.last;
    final Map<String, Object?> stored = _prepareSqlJson(last);
    return FluentPage<T>(items, FluentCursor(orderBy: column, descending: descending, value: _storedValue(last, column, stored), key: {for (final String k in keys) k: _storedValue(last, k, stored)}));
  }

  /// The stored value of [column] in [model] (library-managed columns included: timestamps, soft-delete stamp).
  Object? _storedValue(T model, String column, Map<String, Object?> stored) {
    if (stored.containsKey(column)) return stored[column];
    if (model is FluentTimestamps) {
      final FluentTimestamps t = model as FluentTimestamps;
      if (column == t.createdAtColumn) return t.createdAt?.millisecondsSinceEpoch;
      if (column == t.updatedAtColumn) return t.updatedAt?.millisecondsSinceEpoch;
    }
    if (model is FluentSoftDeletable && column == (model as FluentSoftDeletable).softDeleteColumn) return (model as FluentSoftDeletable).deletedAt?.millisecondsSinceEpoch;
    throw FluentLog.raise(
      FluentArgumentException('orderBy', '"$column" of "$tableName" is not a field of the model, so a cursor cannot be built', hint: 'Order by a column that buildJson writes.'),
      tag: '$tableName:findPage',
    );
  }

  /// Rows after [cursor] in the order (`column`, key...) [descending]; SQLite sorts NULL first, so NULL values come
  /// first ascending and last descending.
  FluentFilter _afterCursor(FluentCursor cursor, String column, List<String> keys, bool descending) {
    final String op = descending ? '<' : '>';
    final List<String> tieKeys = keys.where((k) => k != column).toList();
    // Lexicographic "after" over the key columns: (k1 > v1) OR (k1 = v1 AND k2 > v2) ...
    FluentFilter tie(List<String> cols) {
      final List<String> parts = [];
      final List<Object?> args = [];
      for (int i = 0; i < cols.length; i++) {
        final List<String> equal = [for (int j = 0; j < i; j++) '${cols[j].quotedIdentifier} = ?'];
        parts.add([...equal, '${cols[i].quotedIdentifier} $op ?'].join(' AND '));
        args
          ..addAll([for (int j = 0; j < i; j++) cursor.key[cols[j]]])
          ..add(cursor.key[cols[i]]);
      }
      return FluentFilter(parts.map((p) => '($p)').join(' OR '), args);
    }

    if (tieKeys.isEmpty) return tie(keys); // ordered by the (single) key itself
    final String c = column.quotedIdentifier;
    final FluentFilter rest = tie(tieKeys);
    if (cursor.value == null) {
      final FluentFilter sameNull = FluentFilter('$c IS NULL AND (${rest.whereClause})', rest.whereArgs);
      return descending ? sameNull : FluentFilter('(${sameNull.whereClause}) OR $c IS NOT NULL', sameNull.whereArgs);
    }
    final FluentFilter beyond = FluentFilter('$c $op ? OR ($c = ? AND (${rest.whereClause}))', [cursor.value, cursor.value, ...rest.whereArgs]);
    return descending ? FluentFilter('${beyond.whereClause} OR $c IS NULL', beyond.whereArgs) : beyond;
  }

  /// A [FluentArgumentException] when [limit] or [offset] is negative (SQLite reads `LIMIT -1` as "all rows"), else
  /// `null`. Returned, not thrown, so the caller can fail its Future.
  Object? _pagingError(String call, int? limit, int? offset) {
    final String? name = limit != null && limit < 0 ? 'limit' : (offset != null && offset < 0 ? 'offset' : null);
    if (name == null) return null;
    return FluentLog.raise(
      FluentArgumentException(name, '$call on "$tableName" got a negative $name (${name == 'limit' ? limit : offset}).', hint: 'Use $name: 0 or more; leave $name out to read without a ${name == 'limit' ? 'limit' : 'skip'}.'),
      tag: '$tableName:$call',
    );
  }

  /// Without `orderBy`, SQLite returns rows in no defined order: pages may repeat or skip rows. A hint, once per table.
  void _hintUnordered(String call, String? orderBy, int? limit, int? offset) {
    if (orderBy != null || (offset == null && (limit == null || limit <= 1))) return;
    final String key = keyColumnNames.first;
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.unordered,
        database: dbName,
        table: tableName,
        title: 'Give paged reads of "$tableName" an orderBy',
        details: '$call(${offset != null ? 'offset' : 'limit'}: ...) without orderBy: SQLite returns rows in no defined order, so pages can '
            'repeat or skip rows (after writes, VACUUM or an index change). For "next page" lists findPage is stable even while rows are added.',
        code: "await provider.$call(orderBy: '$key', limit: 20, offset: page * 20);\n"
            '// or, stable while rows change:\n'
            "final FluentPage<$modelType> page = await provider.findPage(orderBy: '$key', limit: 20, after: previous?.next);",
      ),
    );
  }

  /// Runs a read-only SQL query and returns its rows as maps: one `SELECT`, `VALUES`, `WITH ... SELECT` or reading
  /// `PRAGMA` (`PRAGMA user_version`, `PRAGMA table_info(t)`).
  ///
  /// The raw escape hatch: the query is run as written, without soft-delete or expiry filtering. Statements that
  /// write (`WITH ... DELETE`, `PRAGMA x = 1`, `PRAGMA journal_mode(WAL)`, `PRAGMA optimize`, several statements)
  /// fail with a [FluentArgumentException]: run them with [execute], which also publishes their change events.
  /// Dart values in [arguments] are converted with the table settings; internal columns are left out of the rows.
  ///
  /// ```dart
  /// final List<Map<String, dynamic>> rows = await posts.rawQuery(
  ///   'SELECT "author_id", COUNT(*) AS "n" FROM "posts" WHERE "created_at" > ? GROUP BY "author_id"',
  ///   arguments: [since],
  /// );
  /// ```
  Future<List<Map<String, dynamic>>> rawQuery(String sql, {List<Object?>? arguments, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final String? refused = _FluentReadOnlySql.whyNotReadOnly(sql);
    if (refused != null) {
      throw FluentLog.raise(
        FluentArgumentException('sql', 'rawQuery only runs read-only statements: $refused.', hint: 'Use execute() for statements that change data or settings (INSERT / UPDATE / DELETE, writing PRAGMAs).'),
        tag: '$tableName:rawQuery',
      );
    }
    return _run<List<Map<String, dynamic>>>(FluentDbAction.rawQuery, helper: TableHelper(sql: sql, whereArgs: _sqlArgs(arguments)), policy: policy);
  }

  /// Runs a SQL statement that changes data (`INSERT` / `UPDATE` / `DELETE` / DDL) as a write and returns the number
  /// of changed rows (as reported by SQLite). `INSERT` / `UPDATE` / `DELETE` / `REPLACE` publish a change event of
  /// this table (marked with [tag]), so watchers of it re-run; DDL and PRAGMAs do not. Dart values in [arguments]
  /// are converted with the table settings. Prefer the model calls (`save`, `updateWhere`, `deleteWhere`): raw SQL
  /// skips timestamps, soft delete and sync bookkeeping.
  ///
  /// ```dart
  /// await posts.execute('UPDATE "posts" SET "views" = "views" + 1 WHERE "id" = ?', arguments: [post.id]);
  /// ```
  Future<int> execute(String sql, {List<Object?>? arguments, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _run<int>(FluentDbAction.execute, helper: TableHelper(sql: sql, whereArgs: _sqlArgs(arguments)), policy: policy, tag: tag);
}

/// Tells read-only SQL from SQL that writes, for [FluentRead.rawQuery] (the driver offers no read-only check). A token
/// scan that skips string literals, quoted identifiers and comments.
// ignore: avoid_classes_with_only_static_members
abstract final class _FluentReadOnlySql {
  /// PRAGMAs that take an argument in parentheses and only read.
  static const Set<String> _readingWithArgument = {
    'TABLE_INFO', 'TABLE_XINFO', 'TABLE_LIST', 'INDEX_INFO', 'INDEX_XINFO', 'INDEX_LIST', 'FOREIGN_KEY_LIST', 'FOREIGN_KEY_CHECK', 'INTEGRITY_CHECK', 'QUICK_CHECK',
  };

  /// PRAGMAs that change the database or the connection without an argument.
  static const Set<String> _writingWithoutArgument = {'OPTIMIZE', 'INCREMENTAL_VACUUM', 'WAL_CHECKPOINT', 'SHRINK_MEMORY'};

  static const Set<String> _writes = {'INSERT', 'UPDATE', 'DELETE', 'REPLACE'};

  /// Why [sql] is not one read-only statement, or `null` when it is.
  static String? whyNotReadOnly(String sql) {
    final List<String> tokens = _tokens(sql);
    while (tokens.isNotEmpty && tokens.last == ';') {
      tokens.removeLast();
    }
    if (tokens.isEmpty) return 'the statement is empty';
    if (tokens.contains(';')) return 'it holds several statements';
    final String first = tokens.first;
    if (first == 'SELECT' || first == 'VALUES') return null;
    if (first == 'WITH') {
      // The statement after the common table expressions decides (their bodies are always SELECTs).
      int depth = 0;
      for (final String t in tokens.skip(1)) {
        if (t == '(') depth++;
        if (t == ')') depth--;
        if (depth != 0) continue;
        if (t == 'SELECT' || t == 'VALUES') return null;
        if (_writes.contains(t)) return 'WITH ... $t changes data';
      }
      return null; // incomplete: SQLite reports the syntax error
    }
    if (first == 'PRAGMA') {
      int i = 1;
      if (tokens.length > i + 2 && tokens[i + 1] == '.') i += 2; // schema.name
      final String name = tokens.length > i ? tokens[i] : '';
      final String? next = tokens.length > i + 1 ? tokens[i + 1] : null;
      if (next == '=') return 'PRAGMA $name = ... changes a setting';
      if (next == '(' && !_readingWithArgument.contains(name)) return 'PRAGMA $name(...) changes a setting or the database';
      if (next == null && _writingWithoutArgument.contains(name)) return 'PRAGMA $name changes the database';
      return null;
    }
    return 'it starts with $first';
  }

  /// Upper-case words, single punctuation characters, `'` for a string literal and `"` for a quoted identifier.
  static List<String> _tokens(String sql) {
    final List<String> tokens = [];
    int i = 0;
    bool isWord(int unit) => (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || (unit >= 48 && unit <= 57) || unit == 95 || unit == 36 || unit > 127;
    while (i < sql.length) {
      final String c = sql[i];
      final int unit = sql.codeUnitAt(i);
      if (c.trim().isEmpty) {
        i++;
      } else if (c == "'" || c == '"' || c == '`' || c == '[') {
        final int end = sql.indexOf(c == '[' ? ']' : c, i + 1);
        tokens.add(c == "'" ? "'" : '"');
        i = end < 0 ? sql.length : end + 1;
      } else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
        final int end = sql.indexOf('\n', i);
        i = end < 0 ? sql.length : end + 1;
      } else if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
        final int end = sql.indexOf('*/', i + 2);
        i = end < 0 ? sql.length : end + 2;
      } else if (isWord(unit)) {
        final int start = i;
        while (i < sql.length && isWord(sql.codeUnitAt(i))) {
          i++;
        }
        tokens.add(sql.substring(start, i).toUpperCase());
      } else {
        tokens.add(c);
        i++;
      }
    }
    return tokens;
  }
}
