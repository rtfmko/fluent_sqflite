// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// The table layout of a provider: the full column list (model + migrations + relation columns + system columns),
/// the indexes, and the schema caches. Changes are applied by `FluentSchemaSync.syncTable`.
extension FluentSchema<T extends FluentStorable> on FluentProvider<T> {
  /// Whether the table is created `WITHOUT ROWID` (requested by the model and valid for its key).
  bool get _useWithoutRowId {
    if (!modelSample.withoutRowId) return false;
    final List<FluentDbColumn> keyColumns = primaryKeyColumns;
    if (keyColumns.length == 1 && keyColumns.first.isAutoIncrement) {
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'WITHOUT ROWID ignored for "$tableName": the primary key uses AUTOINCREMENT.',
        table: tableName,
        tag: '$tableName:schema',
        hint: 'Set isAutoIncrement: false on the primary key (and supply ids yourself), or remove withoutRowId.',
      );
      return false;
    }
    return true;
  }

  /// All indexes the library keeps on the table: single-column `indexed: true` columns, the expiry and trash indexes,
  /// partial unique indexes of a soft-deletable table, relation indexes and [FluentStorable.indexes] (full-text ones
  /// live in their FTS table).
  ///
  /// Indexes that reference unknown columns are skipped with a warning.
  List<FluentIndex> get tableIndexes {
    final List<FluentDbColumn> columns = getFullSchema;
    final Set<String> keyNames = {for (final FluentDbColumn c in primaryKeyColumns) c.name};
    final Set<String> columnNames = {for (final FluentDbColumn c in columns) c.name};

    final List<FluentIndex> result = [
      for (final FluentDbColumn col in columns)
        if (col.indexed && !(keyNames.length == 1 && keyNames.contains(col.name))) FluentIndex([col.name], name: 'idx_${tableName}_${col.name}'),
    ];

    // Partial index for TTL clean-up: tiny when the table does not use expiry dates.
    final String expiry = _expiryColumn;
    if (columnNames.contains(expiry)) {
      result.add(FluentIndex([expiry], name: 'idx_${tableName}_$expiry', where: '${expiry.quotedIdentifier} IS NOT NULL'));
    }

    // Soft delete: unique values count only among rows that are not in the trash; a small index serves the trash.
    final String? deleted = _softDeleteColumn;
    final String? alive = deleted == null ? null : '${deleted.quotedIdentifier} IS NULL';
    if (deleted != null) {
      for (final String column in _softUniqueColumns) {
        result.add(FluentIndex([column], unique: true, name: 'uidx_${tableName}_$column', where: alive));
      }
      result.add(FluentIndex([deleted], name: 'idx_${tableName}_$deleted', where: '${deleted.quotedIdentifier} IS NOT NULL'));
    }

    for (final FluentIndex declared in [..._relationIndexes, ...modelSample.indexes]) {
      if (declared.fullText) continue; // kept in an FTS table (fluent_full_text.dart)
      final FluentIndex index = alive != null && declared.unique && declared.where == null ? FluentIndex(declared.columns, unique: true, name: declared.name, where: alive) : declared;
      final List<String> unknown = index.columns.where((c) => !columnNames.contains(c)).toList();
      if (index.columns.isEmpty || unknown.isNotEmpty) {
        FluentLog.issue(
          FluentIssueKind.indexSkipped,
          'Index "${index.nameFor(tableName)}" skipped: unknown columns $unknown',
          table: tableName,
          subject: index.nameFor(tableName),
          tag: '$tableName:schema',
          hint: 'Index columns must exist in the table. Known columns: ${columnNames.join(', ')}. Check the spelling in $T.indexes.',
        );
        continue;
      }
      if (!result.any((r) => r.nameFor(tableName) == index.nameFor(tableName))) result.add(index);
    }
    return result;
  }

  /// Creates one index; a failure is reported with a hint but never stops initialization.
  Future<bool> _createIndexSafely(DatabaseExecutor executor, FluentIndex index) async {
    final String sql = index.createSql(tableName);
    try {
      FluentLog.sql(sql, tag: '$tableName:schema');
      await executor.execute(sql);
      return true;
    } catch (e, s) {
      FluentLog.issue(
        FluentIssueKind.indexSkipped,
        'Index "${index.nameFor(tableName)}" could not be created; the table works without it',
        table: tableName,
        subject: index.nameFor(tableName),
        error: e,
        stackTrace: s,
        tag: '$tableName:schema',
        hint: index.unique
            ? 'The table already contains rows with duplicate values in (${index.columns.join(', ')}). '
                  'Remove the duplicates, then restart: the unique index will be created automatically.'
            : 'Check that the index columns and the "where" condition are valid SQL for table "$tableName".',
        context: {'indexName': index.nameFor(tableName), 'sql': sql},
      );
      return false;
    }
  }

  /// Every column of the table, in table order (cached until [refreshSchema]):
  ///
  /// 1. the model's `tableSchema`;
  /// 2. the library's system columns (expiry, metadata; they replace model columns of the same name);
  /// 3. reference columns of relations ([FluentRelations]);
  /// 4. the trash column ([FluentSoftDeletable], unless the model declares it; its UNIQUE columns become partial
  ///    unique indexes), timestamps (`FluentTimestamps`) and sync columns ([FluentSyncable]).
  ///
  /// It also resolves the primary key (default `id`), checks defaults and fills the column caches and the value
  /// converters of the provider.
  List<FluentDbColumn> get getFullSchema {
    if (_cachedFullSchema != null && _isSchemaInitialized) {
      return _cachedFullSchema!;
    }

    _cachedFullSchema = const <FluentDbColumn>[];

    FluentLog.debug('Initiating schema compilation sequence', tag: '$tableName:schema', context: {'table': tableName});

    final Map<String, FluentDbColumn> finalMap = <String, FluentDbColumn>{};
    final List<FluentDbColumn> systemColumns = FluentDbColumn.systemColumns(_expiryColumn);
    // One sample for the whole compilation: modelSample builds a new model on every access.
    final T model = modelSample;

    for (final FluentDbColumn col in model.tableSchema) {
      if (finalMap.containsKey(col.name)) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Column "${col.name}" is declared twice in the tableSchema of "$tableName"; the last declaration is used.',
          table: tableName,
          subject: col.name,
          tag: '$tableName:schema',
          hint: 'Declare each column once in ${modelSample.runtimeType}.tableSchema.',
        );
      }
      finalMap[col.name] = col;
    }

    for (final FluentDbColumn sysCol in systemColumns) {
      finalMap[sysCol.name] = sysCol;
    }

    // Reference columns of relations (one → this table, owned children of others → this table)
    _addRelationColumns(finalMap);

    if (model is FluentSoftDeletable) {
      final FluentSoftDeletable sample = model as FluentSoftDeletable;
      finalMap.putIfAbsent(sample.softDeleteColumn, () => FluentDbColumn.systemSoftDelete(sample.softDeleteColumn));
      // Rows in the trash must not keep their unique values: UNIQUE becomes a partial index (see tableIndexes).
      _softUniqueColumns = [for (final FluentDbColumn c in finalMap.values) if (c.isUnique && !c.isPrimaryKey) c.name];
      for (final String name in _softUniqueColumns) {
        finalMap[name] = finalMap[name]!.copyWith(isUnique: false);
      }
    }

    // Library-managed times (FluentTimestamps): always epoch-millisecond INTEGER columns read back as DateTime.
    final ({String created, String updated})? times = _timestampColumns;
    if (times != null) {
      finalMap[times.created] = FluentDbColumn.timestamp(times.created);
      finalMap[times.updated] = FluentDbColumn.timestamp(times.updated);
    }

    // Sync bookkeeping (FluentSyncable): a local change raises sync_version, a push records synced_version.
    final ({String version, String synced})? sync = _syncColumns;
    if (sync != null) {
      finalMap[sync.version] = FluentDbColumn.integer(sync.version, isNotNull: true, defaultValue: 1);
      finalMap[sync.synced] = FluentDbColumn.integer(sync.synced, isNotNull: true, defaultValue: 0);
    }

    final List<FluentDbColumn> keyColumns = _resolvePrimaryKeys(finalMap, model);
    _validateSchema(finalMap);

    final List<FluentDbColumn> declaredSchema = finalMap.values.toList(growable: false);

    _cachedTableColumns = finalMap.keys.toSet();

    _cachedPrimaryKeys = keyColumns;
    _cachedPrimaryKey = keyColumns.first;
    // One conversion path per column: an explicit converter, an enum converter from `enumValues`, or the built-in
    // codec of its value kind (FluentTypeCodecs).
    final Map<String, List<Enum>> enums = model.enumValues;
    _converters = {
      for (final FluentDbColumn c in declaredSchema)
        if (c.converter != null)
          c.name: c.converter!
        else if (c.valueKind == FluentValueKind.enumValue && enums[c.name] != null)
          c.name: FluentEnumConverter<Enum>(enums[c.name]!, byName: _tableConfig.storeEnumsAsNames, nullIfUnknown: !c.isNotNull),
    };
    _valueKinds = {
      for (final FluentDbColumn c in declaredSchema)
        if (c.valueKind != null && !_converters.containsKey(c.name)) c.name: c.valueKind!,
    };

    // A value-kind column (a DateTime as ISO text, a BigInt) says by its kind what it stores: no numeric check.
    _numericColumns = {
      for (final FluentDbColumn c in declaredSchema)
        if (_converters.containsKey(c.name) || c.valueKind == null)
          if ((_converters[c.name]?.sqlType ?? c.type) case final FluentDbDataType t when t == FluentDbDataType.integer || t == FluentDbDataType.real) c.name: t,
    };

    // A default is stored the way the row writer stores that value (converter, codec with this table's settings).
    final List<FluentDbColumn> finalizedSchema = [for (final FluentDbColumn c in declaredSchema) _withStoredDefault(c)];

    _cachedFullSchema = finalizedSchema;
    _rowPlan = null;
    _isSchemaInitialized = true;

    FluentLog.debug('Schema compilation finalized', tag: '$tableName:schema', context: {'finalColumnCount': finalizedSchema.length});
    return _cachedFullSchema!;
  }

  /// [column] with its Dart `defaultValue` replaced by the stored form of that value: the column's converter, else the
  /// built-in codec with this table's settings (a `DateTime` on an ISO column becomes its ISO text, an enum its name or
  /// index). The DEFAULT text of the column definition, so also the schema fingerprint, follows. A default that is
  /// already a stored value (`String`, `num`, `bool`, expression) stays as it is.
  FluentDbColumn _withStoredDefault(FluentDbColumn column) {
    final Object? value = column.defaultValue;
    if (value == null || value is FluentSqlExpression || value is String || value is num || value is bool || value is Uint8List) return column;
    try {
      final FluentConverter<Object?, Object?>? converter = _converters[column.name];
      final Object? stored = converter != null && converter.acceptsValue(value) ? converter.encode(value) : value;
      final Object? plain = stored is String || stored is num || stored is bool || stored is Uint8List || stored == null ? stored : FluentSqlSanitizer.sanitizeValueOnly(stored, _tableConfig);
      return identical(plain, value) ? column : column.copyWith(defaultValue: plain);
    } catch (e) {
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'The default value ${value.runtimeType} of "$tableName.${column.name}" cannot be stored: ${FluentLog.redact('$e')}',
        table: tableName,
        tag: '$tableName:schema',
        hint: 'Use a default the column stores as it is (String, int, double, bool), or the value its converter takes.',
      );
      return column;
    }
  }

  /// Resolves the primary key columns from the model and makes sure they exist in [finalMap]
  /// and are flagged as primary key there.
  ///
  /// * Single key: a key not marked `isPrimaryKey` is promoted when `autoCorrectAllowed` is true.
  /// * Composite key: every key column is added to the table if missing; `AUTOINCREMENT` is ignored.
  List<FluentDbColumn> _resolvePrimaryKeys(Map<String, FluentDbColumn> finalMap, T model) {
    List<FluentDbColumn> declared = model.primaryKeys;

    if (declared.isEmpty) {
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'Model $T declares no primary key columns. Falling back to the default "id" key.',
        tag: '$tableName:schema',
        hint: 'Return at least one column from primaryKeys, or remove the override to use the default "id".',
      );
      // Like a declared `id` key: an `id` column of tableSchema becomes the key instead of staying a plain column.
      declared = [FluentDbColumn.primary()];
    }

    if (declared.length == 1) {
      FluentDbColumn primaryKey = declared.first;
      if (!primaryKey.isPrimaryKey && primaryKey.autoCorrectAllowed) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Primary key column "${primaryKey.name}" of "$tableName" is not marked as primary key. Treating it as primary key.',
          table: tableName,
          tag: '$tableName:schema',
          hint: 'Set "isPrimaryKey: true" in the primaryKey getter of $T, or "autoCorrectAllowed: false" to keep it as a regular column.',
        );
        primaryKey = primaryKey.copyWith(isPrimaryKey: true);
      }
      // The key column may also be listed in tableSchema (e.g. a plain `integer('id')`): the key definition
      // decides that it is the key, otherwise the table would be created without a PRIMARY KEY.
      final FluentDbColumn? existing = finalMap[primaryKey.name];
      if (existing != null && primaryKey.isPrimaryKey && !existing.isPrimaryKey) {
        FluentLog.debug('Key column "${primaryKey.name}" is also declared in tableSchema; it is used as the primary key', tag: '$tableName:schema');
        finalMap[primaryKey.name] = existing.copyWith(isPrimaryKey: true, isAutoIncrement: primaryKey.isAutoIncrement && existing.type == FluentDbDataType.integer);
      }
      return [finalMap.putIfAbsent(primaryKey.name, () => primaryKey)];
    }

    final List<FluentDbColumn> resolved = [];
    final Set<String> seen = {};
    for (final FluentDbColumn column in declared) {
      if (!seen.add(column.name)) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Duplicate primary key column "${column.name}" in $T.primaryKeys ignored.',
          tag: '$tableName:schema',
          hint: 'List each key column once in primaryKeys.',
        );
        continue;
      }
      if (column.isAutoIncrement) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'AUTOINCREMENT on composite key column "${column.name}" of "$tableName" is ignored.',
          table: tableName,
          tag: '$tableName:schema',
          hint: 'SQLite supports AUTOINCREMENT only for a single INTEGER primary key. Supply the values of composite key columns yourself.',
        );
      }
      final FluentDbColumn base = finalMap[column.name] ?? column;
      // Keep everything that decides how values are stored and filtered (valueKind, converter, indexes).
      final FluentDbColumn keyColumn = base.copyWith(isPrimaryKey: true, isNotNull: true, isAutoIncrement: false);
      finalMap[column.name] = keyColumn;
      resolved.add(keyColumn);
    }
    return resolved;
  }

  /// Registration checks that produce warnings with hints instead of failing.
  void _validateSchema(Map<String, FluentDbColumn> finalMap) {
    for (final FluentDbColumn column in finalMap.values) {
      final Object? defaultValue = column.defaultValue;
      if (defaultValue == null || defaultValue is FluentSqlExpression) continue;

      final bool mismatch = switch (column.type) {
        FluentDbDataType.integer => !(defaultValue is int || defaultValue is bool || defaultValue is DateTime || (defaultValue is String && int.tryParse(defaultValue) != null)),
        FluentDbDataType.real => !(defaultValue is num || (defaultValue is String && num.tryParse(defaultValue) != null)),
        _ => false,
      };

      if (mismatch) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Default value $defaultValue (${defaultValue.runtimeType}) does not match the ${column.type.sql} type of "$tableName.${column.name}".',
          table: tableName,
          tag: '$tableName:schema',
          hint: 'Use a ${column.type == FluentDbDataType.integer ? 'int or bool' : 'number'} default, or change the column type. '
              'SQLite will store the value as is, which may break filters and sorting on this column.',
        );
      }
    }
  }

  /// Forgets the cached column list: [getFullSchema] builds it again on the next access (after the relation graph
  /// or the settings changed, e.g. at init and in schema planning).
  void refreshSchema() {
    FluentLog.debug('Invalidating schema cache', tag: '$tableName:schema', context: {'tableName': tableName});
    _cachedFullSchema = null;
    _isSchemaInitialized = false;
  }
}
