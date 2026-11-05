// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// One row per table with a full-text index: its definition and the schema revision it was built for.
const String _ftsMetaTable = '__fluent_fts';

/// The FTS module each database (and [FluentFullText] mode) can use, probed once per run.
final Map<String, String?> _ftsSupport = {};

/// [FluentFullTextSchema.fullTextColumns] per provider, for the schema it was computed from (recomputed, and its
/// issues reported, only when the schema changes).
final Expando<(List<FluentDbColumn>, List<String>)> _fullTextColumnsCache = Expando('fullTextColumns');

/// Full-text indexes (`FluentIndex.fullText`): an external-content FTS table (`__fluent_fts_<table>`) next to the
/// table, kept in step by triggers, so every write (models, `execute`, sync) updates it inside its own transaction.
///
/// It is rebuilt from the table when its definition or the table's schema revision changes (so it never points at
/// rows of an earlier table version), and dropped when the model no longer declares it. FTS5 is used where the device's SQLite has
/// it, FTS4 otherwise ([FluentFullText]); without either, searches compare words with `LIKE`.
extension FluentFullTextSchema<T extends FluentStorable> on FluentProvider<T> {
  String get _ftsTable => '__fluent_fts_$tableName';

  /// Test hook: when set, tells whether the SQLite module (`'fts5'` / `'fts4'`) counts as available, instead of probing
  /// the real one (nothing is cached then). Lets tests run the "device without FTS" path.
  @visibleForTesting
  static bool Function(String module)? moduleAvailableOverride;

  /// The columns of the full-text index (every `FluentIndex.fullText` of the model, merged); unknown or non-text
  /// columns are skipped with a warning.
  List<String> get fullTextColumns {
    final List<FluentDbColumn> schema = getFullSchema;
    final (List<FluentDbColumn>, List<String>)? cached = _fullTextColumnsCache[this];
    if (cached != null && identical(cached.$1, schema)) return cached.$2;
    final List<String> columns = _computeFullTextColumns(schema);
    _fullTextColumnsCache[this] = (schema, columns);
    return columns;
  }

  List<String> _computeFullTextColumns(List<FluentDbColumn> schema) {
    final Map<String, FluentDbColumn> known = {for (final FluentDbColumn c in schema) c.name: c};
    final List<String> columns = [];
    for (final FluentIndex index in modelSample.indexes.where((i) => i.fullText)) {
      for (final String column in index.columns) {
        final FluentDbColumn? c = known[column];
        if (c == null || c.type != FluentDbDataType.text) {
          FluentLog.issue(
            FluentIssueKind.fullTextSkipped,
            'Full-text index of "$tableName": column "$column" skipped (${c == null ? 'no such column' : 'not a text column'}).',
            table: tableName,
            tag: '$tableName:fullText',
            subject: column,
            hint: 'List text columns of "$tableName" in FluentIndex.fullText: ${known.values.where((k) => k.type == FluentDbDataType.text && !FluentProvider._isInternalColumn(k.name)).map((k) => k.name).join(', ')}.',
          );
          continue;
        }
        if (!columns.contains(column)) columns.add(column);
      }
    }
    return List.unmodifiable(columns);
  }

  /// Creates, rebuilds or drops the full-text index of this table to match the model (inside the schema transaction).
  /// The mode is the table's `fullText`, else [databaseMode] (the database's), else the global one.
  @internal
  Future<void> syncFullText(Transaction txn, FluentFullText? databaseMode, {List<FluentSchemaChange>? changes}) async {
    final FluentFullText mode = _tableConfig.fullText ?? databaseMode ?? FluentEngine().config.fullText;
    _ftsModule = null;
    await txn.execute('CREATE TABLE IF NOT EXISTS ${_ftsMetaTable.quotedIdentifier} (tbl TEXT PRIMARY KEY, definition TEXT NOT NULL, revision INTEGER NOT NULL)');
    final List<Map<String, Object?>> rows = await txn.query(_ftsMetaTable, where: 'tbl = ?', whereArgs: [tableName]);
    final Map<String, Object?>? meta = rows.isEmpty ? null : rows.first;
    final List<String> columns = fullTextColumns;

    if (columns.isNotEmpty && modelSample.withoutRowId) {
      FluentLog.issue(
        FluentIssueKind.fullTextSkipped,
        'Full-text index of "$tableName" skipped: the table has no rowid (withoutRowId).',
        table: tableName,
        tag: '$tableName:fullText',
        hint: 'Full-text search needs a rowid table: remove withoutRowId from $modelType, or search with FluentFilter.contains.',
      );
    }
    if (columns.isEmpty || mode == FluentFullText.off || modelSample.withoutRowId) {
      if (meta != null) {
        await _dropFullText(txn);
        await txn.delete(_ftsMetaTable, where: 'tbl = ?', whereArgs: [tableName]);
        FluentLog.info('Full-text index of "$tableName" removed', tag: '$tableName:fullText');
        changes?.add(FluentSchemaChange(kind: FluentSchemaChangeKind.fullText, table: tableName, description: 'removed full-text index'));
      }
      return;
    }

    final String? module = await _ftsModuleFor(txn, mode);
    if (module == null) {
      // No module on this device: an index (and its triggers) from an earlier run would fail every write with
      // "no such module", so it is dropped; searches use LIKE. A device with FTS builds it again later.
      final List<String> names = [_ftsTable, for (final String suffix in const ['ai', 'ad', 'au', 'bd', 'bu']) '${_ftsTable}_$suffix'];
      final bool leftovers = meta != null || (await txn.rawQuery('SELECT 1 FROM sqlite_master WHERE name IN (${List.filled(names.length, '?').join(', ')})', names)).isNotEmpty;
      if (leftovers) {
        await _dropFullText(txn);
        await txn.delete(_ftsMetaTable, where: 'tbl = ?', whereArgs: [tableName]);
        FluentLog.issue(
          FluentIssueKind.fullTextFallback,
          'The full-text index of "$tableName" was removed: the SQLite of this device has no ${mode == FluentFullText.fts4 ? 'FTS4' : 'FTS5 / FTS4'}, and its triggers would fail every write.',
          database: dbName,
          table: tableName,
          tag: '$tableName:fullText',
          hint: 'Searches use LIKE now. The index is created again on a device whose SQLite has FTS (bundle one, e.g. sqlite3_flutter_libs).',
        );
        changes?.add(FluentSchemaChange(kind: FluentSchemaChangeKind.fullText, table: tableName, description: 'removed full-text index (no FTS module on this device)'));
      }
      return;
    }
    final int revision = Sqflite.firstIntValue(await txn.rawQuery('SELECT revision FROM ${fluentSchemaTable.quotedIdentifier} WHERE table_name = ?', [tableName])) ?? 0;
    final String definition = '$module:${columns.join(',')}';
    final bool exists = (await txn.rawQuery('SELECT 1 FROM sqlite_master WHERE name = ?', [_ftsTable])).isNotEmpty;
    if (exists && meta != null && meta['definition'] == definition && meta['revision'] == revision) {
      _ftsModule = module;
      return;
    }

    await _dropFullText(txn);
    await _createFullText(txn, module, columns);
    await txn.execute('INSERT INTO ${_ftsTable.quotedIdentifier}(${_ftsTable.quotedIdentifier}) VALUES (\'rebuild\')');
    await txn.insert(_ftsMetaTable, {'tbl': tableName, 'definition': definition, 'revision': revision}, conflictAlgorithm: ConflictAlgorithm.replace);
    FluentLog.info('Full-text index of "$tableName" ${meta == null ? 'created' : 'rebuilt'} ($module: ${columns.join(', ')})', tag: '$tableName:fullText');
    changes?.add(FluentSchemaChange(kind: FluentSchemaChangeKind.fullText, table: tableName, description: '${meta == null ? 'created' : 'rebuilt'} full-text index ($module: ${columns.join(', ')})'));
    _ftsModule = module;
  }

  /// A database opened read-only (no schema sync): uses the full-text index the file already has when it fits the
  /// model ([syncFullText] wrote it); searches fall back to `LIKE` otherwise.
  @internal
  Future<void> adoptFullText(DatabaseExecutor executor, FluentFullText? databaseMode) async {
    _ftsModule = null;
    final FluentFullText mode = _tableConfig.fullText ?? databaseMode ?? FluentEngine().config.fullText;
    if (mode == FluentFullText.off || modelSample.withoutRowId) return;
    try {
      final Set<String> present = {
        for (final Map<String, Object?> r in await executor.rawQuery('SELECT name FROM sqlite_master WHERE name IN (?, ?)', [_ftsMetaTable, _ftsTable])) r['name']! as String,
      };
      if (!present.contains(_ftsMetaTable) || !present.contains(_ftsTable)) return;
      final List<Map<String, Object?>> rows = await executor.query(_ftsMetaTable, columns: ['definition'], where: 'tbl = ?', whereArgs: [tableName]);
      final String? definition = rows.firstOrNull?['definition'] as String?;
      if (definition != null && mode == FluentFullText.fts4 && !definition.startsWith('fts4:')) return;
      _adoptFullText(definition);
    } catch (e) {
      FluentLog.debug('Full-text index of "$tableName" not adopted (searches use LIKE): $e', tag: '$tableName:fullText');
    }
  }

  /// Fast start (the schema is unchanged): takes the module from the stored [definition] instead of checking it.
  void _adoptFullText(String? definition) {
    final List<String> columns = fullTextColumns;
    _ftsModule = definition != null && columns.isNotEmpty && definition.endsWith(':${columns.join(',')}') ? definition.split(':').first : null;
  }

  Future<String?> _ftsModuleFor(Transaction txn, FluentFullText mode) async {
    final String key = '$dbName|${mode.name}';
    final bool Function(String module)? override = moduleAvailableOverride;
    if (override == null && _ftsSupport.containsKey(key)) return _ftsSupport[key];
    String? found;
    for (final String module in mode == FluentFullText.fts4 ? const ['fts4'] : const ['fts5', 'fts4']) {
      if (override != null) {
        if (!override(module)) continue;
        found = module;
        break;
      }
      try {
        await txn.execute('CREATE VIRTUAL TABLE temp."__fluent_fts_probe" USING $module(x)');
        await txn.execute('DROP TABLE temp."__fluent_fts_probe"');
        found = module;
        break;
      } catch (_) {
        // Not compiled into this SQLite: try the next one.
      }
    }
    if (found == 'fts4' && mode == FluentFullText.auto) {
      FluentLog.info(
        'The SQLite of this device has no FTS5: full-text indexes of "$dbName" use FTS4 (search results are not ranked by relevance).',
        tag: 'FluentDb:fullText',
        context: {'hint': 'Bundle a newer SQLite (e.g. sqlite3_flutter_libs) for FTS5, or set FluentDbConfig(fullText: FluentFullText.fts4) for the same behaviour on every device.'},
      );
    } else if (found == null) {
      FluentLog.issue(
        FluentIssueKind.fullTextFallback,
        'The SQLite of this device has no ${mode == FluentFullText.fts4 ? 'FTS4' : 'full-text search (FTS5 / FTS4)'}: searches in "$dbName" compare words with LIKE.',
        database: dbName,
        tag: 'FluentDb:fullText',
        hint: mode == FluentFullText.fts4
            ? 'Use FluentDbConfig(fullText: FluentFullText.auto) to take FTS5 where FTS4 is missing.'
            : 'Searches work but read every row. Bundle a SQLite with FTS (e.g. sqlite3_flutter_libs) for fast search.',
      );
    }
    if (override != null) return found;
    return _ftsSupport[key] = found;
  }

  Future<void> _createFullText(Transaction txn, String module, List<String> columns) async {
    final String fts = _ftsTable.quotedIdentifier;
    final String table = tableName.quotedIdentifier;
    final String cols = columns.map((c) => c.quotedIdentifier).join(', ');
    final String newValues = columns.map((c) => 'new.${c.quotedIdentifier}').join(', ');
    final String oldValues = columns.map((c) => 'old.${c.quotedIdentifier}').join(', ');
    String trigger(String suffix) => '${_ftsTable}_$suffix'.quotedIdentifier;

    if (module == 'fts5') {
      await txn.execute("CREATE VIRTUAL TABLE $fts USING fts5($cols, content=$table, content_rowid='rowid', tokenize='unicode61 remove_diacritics 1')");
      final String remove = "INSERT INTO $fts($fts, rowid, $cols) VALUES ('delete', old.rowid, $oldValues);";
      final String add = 'INSERT INTO $fts(rowid, $cols) VALUES (new.rowid, $newValues);';
      await txn.execute('CREATE TRIGGER ${trigger('ai')} AFTER INSERT ON $table BEGIN $add END');
      await txn.execute('CREATE TRIGGER ${trigger('ad')} AFTER DELETE ON $table BEGIN $remove END');
      await txn.execute('CREATE TRIGGER ${trigger('au')} AFTER UPDATE OF $cols ON $table BEGIN $remove $add END');
      return;
    }
    try {
      await txn.execute('CREATE VIRTUAL TABLE $fts USING fts4(content=$table, $cols, tokenize=unicode61)');
    } catch (_) {
      await txn.execute('CREATE VIRTUAL TABLE $fts USING fts4(content=$table, $cols)'); // very old SQLite: no unicode61
    }
    final String remove = 'DELETE FROM $fts WHERE docid = old.rowid;';
    final String add = 'INSERT INTO $fts(docid, $cols) VALUES (new.rowid, $newValues);';
    await txn.execute('CREATE TRIGGER ${trigger('ai')} AFTER INSERT ON $table BEGIN $add END');
    await txn.execute('CREATE TRIGGER ${trigger('bd')} BEFORE DELETE ON $table BEGIN $remove END');
    await txn.execute('CREATE TRIGGER ${trigger('bu')} BEFORE UPDATE OF $cols ON $table BEGIN $remove END');
    await txn.execute('CREATE TRIGGER ${trigger('au')} AFTER UPDATE OF $cols ON $table BEGIN $add END');
  }

  Future<void> _dropFullText(Transaction txn) async {
    for (final String suffix in const ['ai', 'ad', 'au', 'bd', 'bu']) {
      await txn.execute('DROP TRIGGER IF EXISTS ${'${_ftsTable}_$suffix'.quotedIdentifier}');
    }
    await txn.execute('DROP TABLE IF EXISTS ${_ftsTable.quotedIdentifier}');
  }

  /// The SQL of a [FluentFilter.search] condition on this table, named [outer] in the statement.
  FluentFilter _searchSql(FluentSearchCondition search, String outer) {
    final List<String> words = search.words;
    if (words.isEmpty) return const FluentFilter('1 = 1');
    final String? module = _ftsModule;
    if (module != null) {
      final String fts = _ftsTable.quotedIdentifier;
      return FluentFilter('$outer."rowid" IN (SELECT rowid FROM $fts WHERE $fts MATCH ?)', [_matchQuery(search, module)]);
    }
    final List<String> columns = fullTextColumns;
    if (columns.isEmpty) {
      throw FluentLog.raise(
        FluentArgumentException('where', 'FluentFilter.search on "$tableName": $modelType declares no full-text index.', hint: "Add one: List<FluentIndex> get indexes => [FluentIndex.fullText(['title', 'body'])];"),
        tag: '$tableName:search',
      );
    }
    _hintNoFullText();
    final List<String> parts = [];
    final List<Object?> args = [];
    for (final String word in words) {
      final String pattern = '%${word.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      parts.add('(${columns.map((c) => "$outer.${c.quotedIdentifier} LIKE ? ESCAPE '\\'").join(' OR ')})');
      args.addAll(List.filled(columns.length, pattern));
    }
    return FluentFilter(parts.join(' AND '), args);
  }

  /// The MATCH expression of [search]: every word quoted (user input is never FTS syntax), the last as a prefix.
  static String _matchQuery(FluentSearchCondition search, String module) {
    final List<String> words = search.words;
    return [
      for (int i = 0; i < words.length; i++)
        if (search.prefix && i == words.length - 1) (module == 'fts5' ? '"${words[i]}"*' : '"${words[i]}*"') else '"${words[i]}"',
    ].join(' ');
  }

  void _hintNoFullText() {
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.fullTextOff,
        database: dbName,
        table: tableName,
        title: 'Searches of "$tableName" read every row',
        details: 'The full-text index of "$tableName" is not available (FluentDbConfig.fullText is off, or the SQLite of this '
            'device has no FTS), so FluentFilter.search compares words with LIKE: every row is read, words match anywhere inside '
            'other words, and only ASCII letters ignore case.',
        code: 'FluentGroup(..., config: const FluentDbConfig(fullText: FluentFullText.auto))',
      ),
    );
  }
}
