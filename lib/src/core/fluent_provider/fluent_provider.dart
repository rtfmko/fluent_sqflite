// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../exceptions/exceptions.dart';
import '../../interfaces/interfaces.dart';
import '../../models/models.dart';
import '../../relations/relations.dart';
import '../../soft_delete/soft_delete.dart';
import '../../sync/sync.dart';
import '../../timestamps/timestamps.dart';
import '../../utils/utils.dart';
import '../core.dart';
import '../fluent_sqlite_internal.dart';
import '../utils/utils.dart';

part 'parts/crud/fluent_aggregate.dart';
part 'parts/crud/fluent_execute_crud.dart';
part 'parts/crud/fluent_read.dart';
part 'parts/crud/fluent_remove.dart';
part 'parts/crud/fluent_trash.dart';
part 'parts/crud/fluent_watch.dart';
part 'parts/crud/fluent_write.dart';
part 'parts/fluent_crud_helper.dart';
part 'parts/fluent_mapper.dart';
part 'parts/fluent_row_mapping.dart';
part 'parts/fluent_schema.dart';
part 'parts/relations/fluent_relation_filter.dart';
part 'parts/relations/fluent_legacy_names.dart';
part 'parts/relations/fluent_relation_graph.dart';
part 'parts/relations/fluent_relation_migration.dart';
part 'parts/schema/fluent_full_text.dart';
part 'parts/schema/fluent_schema_sync.dart';
part 'parts/relations/fluent_relation_reader.dart';
part 'parts/relations/fluent_relation_ops.dart';
part 'parts/relations/fluent_relation_writer.dart';
part 'parts/fluent_watch_remote.dart';
part 'parts/sync/fluent_sync_core.dart';

/// The data access object of one table: every read, write, delete, watch and sync call for the models [T].
///
/// A subclass names the model's table ([tableName]), gives a [modelSample] (the schema is read from its
/// `tableSchema` / `buildJson`) and builds models from rows ([fromCacheJson]). Register it in a `FluentGroup` and
/// `await FluentDb.init(...)` before the first call; the table is created and migrated from the model.
///
/// Calls run on the engine queue of the database (writes in call order, reads may be reordered by priority) and join
/// the open transaction of `FluentDb.transaction` when there is one. Reads hide soft-deleted and expired rows; models
/// with [FluentRelations] load and save their relations. The same calls exist as `FluentDb.*<T>` statics.
///
/// **Example:**
/// ```dart
/// class NoteProvider extends FluentProvider<Note> {
///   @override
///   String get tableName => 'notes';
///
///   @override
///   Note get modelSample => Note(title: '');
///
///   @override
///   Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, title: json['title'] as String);
/// }
///
/// final NoteProvider notes = NoteProvider();
/// await FluentDb.init([FluentGroup(dbKey: FluentDbKey('app'), providerList: [notes])]);
/// final List<Note> recent = await notes.find(orderBy: 'id DESC', limit: 20);
/// ```
///
/// See also:
/// * [FluentStorable], for the model side (schema, migrations, table settings).
/// * [FluentDb], for initialization, transactions and the static call variants.
abstract class FluentProvider<T extends FluentStorable> {
  /// The table settings of the model (`FluentStorable.tableConfig`), read once.
  late final FluentTableConfig _tableConfig = modelSample.tableConfig;

  /// Columns that identify a row on the server (`FluentTableConfig.serverKey`, else the primary key).
  late final List<String> _serverKey = _checkedServerKey();

  List<String> _checkedServerKey() {
    final List<String>? wanted = _tableConfig.serverKey;
    if (wanted == null || wanted.isEmpty) return keyColumnNames.toList();
    final List<String> unknown = [for (final String c in wanted) if (!tableColumns.contains(c)) c];
    if (unknown.isEmpty) return List.unmodifiable(wanted);
    FluentLog.issue(
      FluentIssueKind.serverKeyIgnored,
      'serverKey of "$tableName" names unknown column(s) ${unknown.join(', ')}; rows are matched with the server by the primary key.',
      table: tableName,
      tag: '$tableName:sync',
      hint: 'List columns of $modelType.tableSchema in FluentTableConfig(serverKey: [...]), e.g. a unique "server_id".',
    );
    return keyColumnNames.toList();
  }

  /// How long rows of this table stay in the trash: table → database → global setting.
  Duration get _trashRetention => _tableConfig.trashRetention ?? FluentEngine().dbConfig(dbName)?.trashRetention ?? FluentEngine().config.trashRetention;

  /// The default execution policy of this table's calls: what a call's `policy:` leaves unset is taken from here, then
  /// from `FluentConfig.defaultPolicy` (call → provider → global).
  ///
  /// ```dart
  /// @override
  /// ExecutionPolicy get policy => ExecutionPolicy.fresh; // every read of this table runs its own query
  /// ```
  ExecutionPolicy get policy => const ExecutionPolicy();

  /// The unique identifier for the database instance this provider belongs to.
  String? _dbName;

  /// The underlying SQLite [Database] connection.
  Database? _db;

  /// How rows of this table become models (built from the schema, reset when it changes).
  _FluentRowPlan<T>? _rowPlan;

  /// Batches still to be mapped on the UI isolate before background mapping is tried again (set after the isolate
  /// itself failed); 0 while background mapping is on.
  int _isolateSkipBatches = 0;

  /// The length of the last such pause in batches: doubles with every failure up to a cap, back to 0 after a success.
  int _isolateBackoff = 0;

  /// A static (or top-level) function that builds [T] from a row — the same as [fromCacheJson], but without access
  /// to the provider, so big lists can be turned into models in a background isolate and the UI stays smooth
  /// (see `FluentConfig.isolateMapping`, `FluentTableConfig.isolateMapping`). `null` (default): always on the UI
  /// isolate (big lists are sliced).
  ///
  /// ```dart
  /// @override
  /// Note Function(Map<String, dynamic> json)? get isolateFactory => Note.fromJson;
  /// ```
  T Function(Map<String, dynamic> json)? get isolateFactory => null;

  // Built here (not in an extension): the plan needs the provider's real model type, extensions only see the static one.
  _FluentRowPlan<T> get _plan => _rowPlan ??= _FluentRowPlan<T>(
    table: tableName,
    modelName: modelType.toString(),
    kinds: {for (final MapEntry<String, FluentValueKind> e in _valueKinds.entries) e.key: e.value.tag},
    converters: _converters,
    enumValues: modelSample.enumValues,
    linkNames: [for (final FluentRelationLink link in _links) link.name],
    factory: fromCacheJson,
  );

  /// The plan with [isolateFactory], for a background isolate (call only when it is set).
  _FluentRowPlan<T> get _isolatePlan => _plan.withFactory(isolateFactory!);

  /// A sample instance of the model [T]: its schema, settings, relations and mixins describe the table. Read once
  /// per fact (it may build a new instance on every access); the values of its fields do not matter.
  T get modelSample;

  /// The model type (cached: [modelSample] builds a new instance on every access).
  late final Type _modelType = modelSample.runtimeType;

  /// For relations found in `buildJson`: whether [value] is one model of this provider ([list]: a list of them).
  /// A generic type test, so it works with obfuscated builds.
  bool _stores(Object? value, {required bool list}) => list ? value is Iterable<T> : value is T;

  /// The relation for the `buildJson` field [name] that holds models of this provider; its kind is decided by the graph.
  FluentRelation<FluentStorable, T> _foundRelation(String name) =>
      FluentRelation<FluentStorable, T>(name: name, type: FluentRelationType.auto, select: (parent) => parent.buildJson()[name]);

  // Facts of the model the hot paths need, read once ([modelSample] builds a new model on every access).

  /// The column of the row's expiry (`FluentStorable.expiryColumn`).
  late final String _expiryColumn = modelSample.expiryColumn;

  /// The soft-delete column, or `null` when the model does not support soft delete.
  late final String? _softDeleteColumn = switch (modelSample) {
    final FluentSoftDeletable s => s.softDeleteColumn,
    _ => null,
  };

  /// The columns of [FluentTimestamps], or `null` when the model does not use it.
  late final ({String created, String updated})? _timestampColumns = switch (modelSample) {
    final FluentTimestamps t => (created: t.createdAtColumn, updated: t.updatedAtColumn),
    _ => null,
  };

  /// The keys `buildJson` of the model sample writes (what a cursor can read from a model), or `null` when the sample
  /// cannot build its json (callers then keep their own checks).
  late final Set<String>? _modelFields = () {
    try {
      return modelSample.buildJson().keys.toSet();
    } catch (_) {
      return null;
    }
  }();

  /// The table name in the database; by default the class name of [T] in snake case (`TodoItem` → `todo_item`,
  /// `HTTPLog` → `http_log`, `Item2` → `item2`, `Box<Note>` → `box_note`). A table a 1.x database stored under the 1.x
  /// name (`h_t_t_p_log`, `item_2`) is renamed at start. Override it to keep the name stable (obfuscated or renamed
  /// classes would change the default).
  String get tableName => FluentUtils.toSnakeCase(T.toString());

  /// Runs [action] in the open transaction of this database, or in a new one.
  Future<R> _runInTransaction<R>(Future<R> Function(Transaction txn) action) => FluentTransactionScope.inTransaction(db, dbName, action);

  /// Tracks whether the provider has performed the initial schema discovery.
  bool _isSchemaInitialized = false;

  /// Full structural definition of the table (columns, types, constraints).
  List<FluentDbColumn>? _cachedFullSchema;

  /// A lookup set for quick validation of existing table columns.
  Set<String>? _cachedTableColumns;

  /// The primary identity column for this table (the first key column for composite keys).
  FluentDbColumn? _cachedPrimaryKey;

  /// All primary key columns, in declaration order.
  List<FluentDbColumn>? _cachedPrimaryKeys;

  /// Column converters by column name.
  Map<String, FluentConverter<Object?, Object?>> _converters = const {};

  /// Dart value kinds of columns by name (see [FluentValueKind]).
  Map<String, FluentValueKind> _valueKinds = const {};

  /// UNIQUE columns of a soft-deletable table: enforced by partial indexes over the rows that are not in the trash.
  List<String> _softUniqueColumns = const [];

  /// Table-level `FOREIGN KEY` clauses of composite-key relations (see [FluentRelationSchema._addRelationColumns]).
  List<String> _relationConstraints = const [];

  /// Indexes on composite reference columns.
  List<FluentIndex> _relationIndexes = const [];

  /// Relations declared by this provider, resolved at init (see [buildFluentRelationGraph]).
  List<FluentRelationLink> _links = const [];

  /// Owned-children relations of other providers whose reference column lives in this table.
  List<FluentRelationLink> _incomingLinks = const [];

  /// Whether SQLite enforces foreign keys for this database (deletes cascade by themselves).
  bool _foreignKeysEnforced = true;

  /// Whether reference columns of relations get an index (`indexReferences` of the group / engine).
  bool _indexReferences = true;

  /// The FTS module of this table's full-text index (`fts5` / `fts4`), `null` without one (searches use `LIKE`).
  String? _ftsModule;

  /// Whether the rowid is the table's key (a single INTEGER primary key on a rowid table): `VACUUM` keeps it then.
  bool get _rowidIsKey => !modelSample.withoutRowId && primaryKeyColumns.length == 1 && primaryKeyColumns.single.type == FluentDbDataType.integer;

  /// Providers of the same database that take part in relations (used for orphan clean-up).
  List<FluentProvider> _relationPeers = const [];

  FluentKey _normalizeKey(Object? id) {
    final List<FluentDbColumn> keyColumns = primaryKeyColumns;
    final FluentKey key;

    if (id is FluentKey) {
      key = id;
    } else if (id is Map) {
      key = FluentKey({for (final MapEntry<dynamic, dynamic> e in id.entries) e.key.toString(): e.value});
    } else if (keyColumns.length == 1) {
      key = FluentKey.single(keyColumns.first.name, id);
    } else {
      throw _keyError(id, 'Table "$tableName" has a composite key, a single value cannot identify a row.');
    }

    final Set<String> expected = {for (final FluentDbColumn c in keyColumns) c.name};
    final Set<String> given = key.values.keys.toSet();
    if (given.length != expected.length || !given.containsAll(expected)) {
      throw _keyError(id, 'Key columns ${given.toList()} do not match the key of "$tableName": ${expected.toList()}.');
    }
    return key;
  }

  /// A comparable text of the key [id] with its values in the order of the key columns (a `FluentKey` may list its
  /// columns in any order).
  String _keyTuple(Object? id) {
    final FluentKey key = _normalizeKey(id);
    return [for (final FluentDbColumn c in primaryKeyColumns) '${key[c.name]}'].join('\u0001');
  }

  FluentArgumentException _keyError(Object? id, String reason) {
    final String example = primaryKeyColumns.map((c) => "'${c.name}': ...").join(', ');
    return FluentLog.raise(
      FluentArgumentException('key $id', reason, code: FluentErrorCode.invalidKey, hint: 'Build the key from the model (item.key) or pass FluentKey({$example}).'),
      tag: '$tableName:key',
    );
  }

  FluentConfigException _notInitialized() => FluentLog.raise(
    FluentConfigException(
      '$runtimeType is used before its database was opened.',
      code: FluentErrorCode.notInitialized,
      hint: 'Register it in a group and await init first: await FluentDb.init([FluentGroup(dbKey: ..., providerList: [$runtimeType()])]).',
    ),
    tag: '$runtimeType:init',
  );

  /// [elements] as a `List<T>` (the elements must be [T]s).
  List<T> _createTypedList(Iterable<dynamic> elements) => elements.cast<T>().toList();

  /// The name of the provider's database.
  ///
  /// Throws a [FluentConfigException] ([FluentErrorCode.notInitialized]) before `FluentDb.init` registered it.
  String get dbName => _dbName ?? (throw _notInitialized());

  /// Creates the provider; it is bound to its database by `FluentDb.init`.
  ///
  /// [mockDb] binds a [Database] right away (tests); `FluentDb.init` replaces it with the group's connection.
  FluentProvider({Database? mockDb}) : _db = mockDb;

  /// Builds a model from [json]: one stored row with its values already restored to Dart values (`DateTime`, `bool`,
  /// enums with `enumValues`, converted values, as `buildJson` returned them) and the loaded relations under their names. Internal
  /// columns are left out. `deletedAt` and the timestamps are set by the library after it returns. Runs on the UI
  /// isolate; see [isolateFactory] for big lists. A `TypeError` here becomes a [FluentSchemaException] listing the
  /// received types.
  @protected
  T fromCacheJson(Map<String, dynamic> json);

  /// Builds one model from a stored row [enriched] (with its loaded relations) on the UI isolate: relation values
  /// typed by [_castReadyRelations], stored values restored by the row plan, then [fromCacheJson].
  T _assembleModel(Map<String, dynamic> enriched) {
    final List<_MappingWarning> warnings = [];
    try {
      return _plan.build(_castReadyRelations(enriched), warnings);
    } on FluentException catch (e) {
      throw FluentLog.raise(e, tag: '$tableName:hydration');
    } finally {
      _logWarnings(warnings);
    }
  }

  /// Whether [column] is internal bookkeeping that must not reach models or raw maps.
  static bool _isInternalColumn(String column) => column == '_fs_metadata' || column.startsWith('__fluent_removed_');

  /// Runs a column converter and turns a failure into a [FluentSchemaException] with a hint.
  Object? _convert(String column, Object? value, FluentConverter<Object?, Object?> converter, {required bool toSql}) {
    try {
      return toSql ? converter.encode(value) : converter.decode(value);
    } catch (e, s) {
      throw FluentLog.raise(
        FluentSchemaException(
          'Converter ${converter.runtimeType} failed to ${toSql ? 'store' : 'read'} a ${value.runtimeType} value of "$tableName.$column": ${FluentLog.redact('$e')}',
          modelName: modelType.toString(),
          columnName: column,
          hint: toSql
              ? 'buildJson() must return the Dart type the converter expects for "$column".'
              : 'The stored value does not match the converter. If the column held data before the converter was added, migrate it (e.g. with a migration rawSql step).',
          cause: e,
          stackTrace: s,
        ),
        tag: '$tableName:converter',
      );
    }
  }

  Future<dynamic> _route(FluentTask task) {
    return switch (task.action) {
      FluentDbAction.find => _executeFind(task),
      FluentDbAction.findById => _executeFindById(task),
      FluentDbAction.count => _executeCount(task),
      FluentDbAction.exists => _executeExists(task),
      FluentDbAction.findMaps => _executeFindMaps(task),
      FluentDbAction.rawQuery || FluentDbAction.aggregate => _executeRawQuery(task),
      FluentDbAction.execute => _executeSql(task),
      FluentDbAction.save || FluentDbAction.update => _executeSave(task),
      FluentDbAction.updateFields => _executeUpdateFields(task),
      FluentDbAction.delete || FluentDbAction.hardDelete || FluentDbAction.restore => _executeRemove(task),
      FluentDbAction.purgeDeleted => _executePurgeDeleted(task),
      FluentDbAction.clearExpired => _executeClearExpired(task),
      FluentDbAction.clearTable => _executeClearTable(task),
      FluentDbAction.relationRead || FluentDbAction.relationWrite => (task.data! as Future<Object?> Function())(),
      _ => Future<dynamic>.error(FluentEngineException('Action ${task.action.name} cannot run on a table.', hint: 'This is a bug of fluent_sqflite; please report it.')),
    };
  }
}

/// Members the library itself uses (database binding, keys, task execution); not part of the public API.
extension FluentProviderInternals<T extends FluentStorable> on FluentProvider<T> {
  /// The model type of this provider.
  Type get modelType => _modelType;

  /// Empties the trash past its retention (no-op for tables without soft delete); run by the library's maintenance.
  Future<int> purgeTrash() => _purgeTrash(policy: ExecutionPolicy.background);

  /// The primary [DatabaseExecutor] used for operations.
  ///
  /// Returns the open transaction of this database in the current zone (see [FluentDb.transaction]),
  /// otherwise the persistent [_db] connection. Throws if the provider is not initialized.
  /// Inside a pooled read task it is that task's read-only connection (`FluentDbConfig.readConnections`).
  DatabaseExecutor get executor => FluentTransactionScope.of(dbName)?.txn ?? FluentReadScope.of(dbName) ?? _db ?? (throw _notInitialized());

  /// Names of the declared relations; their values are never written as columns.
  Set<String> get relationKeys => _relationNames;

  /// The resolved relations of this provider.
  List<FluentRelationLink> get relationLinks => List.unmodifiable(_links);

  /// The set of all physical database columns defined for this table.
  Set<String> get tableColumns {
    if (!_isSchemaInitialized) getFullSchema;
    return _cachedTableColumns!;
  }

  /// The definitive primary key column definition for this table (the schema always has one: without a declared key
  /// it falls back to `id` and reports it).
  FluentDbColumn get primaryKeyColumn {
    if (!_isSchemaInitialized) getFullSchema;
    return _cachedPrimaryKey!;
  }

  /// All primary key columns of the table (one for a simple key, several for a composite key).
  List<FluentDbColumn> get primaryKeyColumns {
    if (!_isSchemaInitialized) getFullSchema;
    return _cachedPrimaryKeys ?? [primaryKeyColumn];
  }

  /// Whether the table has a composite primary key.
  bool get hasCompositeKey => primaryKeyColumns.length > 1;

  /// Builds a filter matching the row identified by [id].
  ///
  /// [id] is a plain value for simple keys, or a [FluentKey] / `Map<String, Object?>` for
  /// composite keys. A [FluentKey] is also accepted for simple keys.
  ///
  /// Throws a [FluentArgumentException] with a hint when [id] does not fit the table key, or is `null` for a simple
  /// key (like [keysFilter]: a missing key identifies no row).
  FluentFilter keyFilter(Object? id) => _keyFilterOf(id);

  /// [keyFilter]; with [stored] the key values are SQLite values (read from rows) used as they are, without the
  /// converters of the key columns.
  FluentFilter _keyFilterOf(Object? id, {bool stored = false}) {
    final FluentKey key = _normalizeKey(id);
    if (!hasCompositeKey && key[primaryKeyColumns.first.name] == null) throw _keyError(id, 'The key value is null.');
    if (!stored) return key.filter;
    return key.values.entries.map((e) => _storedEq(e.key, e.value)).reduce((a, b) => a.and(b));
  }

  /// The key [id] (Dart values: a plain value or a [FluentKey]) as it is stored: each value converted like its column
  /// converts it on save (converter, codec); a value that is stored already stays as it is. Same shape as [id].
  Object? _storedId(Object? id) {
    if (id == null) return null;
    final FluentKey key = _normalizeKey(id);
    final Map<String, Object?> values = {for (final FluentDbColumn c in primaryKeyColumns) c.name: _filterValue(key[c.name], c.name)};
    return hasCompositeKey ? FluentKey(values) : values[primaryKeyColumns.first.name];
  }

  /// Builds a filter matching all rows identified by [ids] (`pk IN (...)` for simple keys,
  /// `(a = ? AND b = ?) OR ...` for composite keys).
  ///
  /// ```dart
  /// final FluentFilter selected = keysFilter([1, 2, 3]); // users: FluentFilter.ids([1, 2, 3])
  /// ```
  /// For very long lists, split them (SQLite limits the number of arguments of one statement).
  FluentFilter keysFilter(Iterable<Object?> ids) => _keysFilterOf(ids);

  /// [keysFilter]; with [stored] the key values are SQLite values (read from rows) used as they are.
  FluentFilter _keysFilterOf(Iterable<Object?> ids, {bool stored = false}) {
    if (ids.isEmpty) return const FluentFilter('1 = 0');
    if (!hasCompositeKey) {
      final String column = primaryKeyColumns.first.name;
      final List<Object> values = [for (final Object? id in ids) (_normalizeKey(id)[column]) ?? (throw _keyError(id, 'The key value is null.'))];
      return stored ? _storedIn(column, values) : FluentFilter.inList(column.quotedIdentifier, values);
    }
    // One flat `(a = ? AND b = ?) OR ...`: nesting `or` would deepen the parentheses with every key, and old SQLite
    // parsers overflow their stack on a few hundred levels.
    final List<String> columns = [for (final FluentDbColumn c in primaryKeyColumns) c.name];
    final List<String> parts = [];
    final List<Object?> values = [];
    final List<String?> valueColumns = [];
    for (final Object? id in ids) {
      final FluentKey key = _normalizeKey(id);
      final List<String> terms = [];
      for (final String c in columns) {
        final Object? value = key[c];
        if (value == null) {
          terms.add('${c.quotedIdentifier} IS NULL');
        } else {
          terms.add('${c.quotedIdentifier} = ?');
          values.add(value);
          valueColumns.add(stored ? null : c);
        }
      }
      parts.add('(${terms.join(' AND ')})');
    }
    return FluentFilter(parts.join(' OR '), FluentFilterArgs(values, valueColumns));
  }

  /// The names of all primary key columns.
  Set<String> get keyColumnNames => {for (final FluentDbColumn c in primaryKeyColumns) c.name};

  /// How many keys fit into one statement of [chunkSize] SQL variables.
  int keysPerChunk(int chunkSize) => (chunkSize ~/ primaryKeyColumns.length).clamp(1, chunkSize);

  /// Extracts the key of a raw row / payload map, or `null` if a key column is missing.
  FluentKey? keyFromRow(Map<String, dynamic> row) {
    final Map<String, Object?> values = {};
    for (final FluentDbColumn column in primaryKeyColumns) {
      final Object? value = row[column.name];
      if (value == null) return null;
      values[column.name] = value;
    }
    return FluentKey(values);
  }

  /// The id value to pass back to callers for [row]: the plain value for simple keys,
  /// a [FluentKey] for composite keys.
  Object? idFromRow(Map<String, dynamic> row) => hasCompositeKey ? keyFromRow(row) : row[primaryKeyColumns.first.name];

  /// The underlying [Database], or `null` if this provider has not been bound to one yet.
  ///
  /// Used by lifecycle code (close/drop) that must not fail for half-initialized registries.
  Database? get dbOrNull => _db;

  /// Returns the underlying [Database] instance.
  ///
  /// Throws a [FluentConfigException] ([FluentErrorCode.notInitialized]) before `FluentDb.init` opened it.
  Database get db => _db ?? (throw _notInitialized());

  /// [row] without internal bookkeeping columns (used for the raw map API).
  Map<String, dynamic> withoutInternalColumns(Map<String, dynamic> row) =>
      row.keys.any(FluentProvider._isInternalColumn) ? {for (final MapEntry<String, dynamic> e in row.entries) if (!FluentProvider._isInternalColumn(e.key)) e.key: e.value} : row;

  /// Runs [task] on this table: the one place where a call's error reaches the caller.
  ///
  /// SQLite errors become typed [FluentException]s with a hint, and the error is logged once (as a warning: the
  /// caller receives it). Errors created inside wait for this point ([FluentLog.raise] defers), so a merged batch
  /// that fails and is re-run call by call logs only the calls that really fail.
  Future<dynamic> internalExecute(FluentTask task) async {
    try {
      return await runZoned(() => _route((task.helper?.deferred?.isEmpty ?? true) ? task : _withDeferredResolved(task)), zoneValues: {FluentLog.deferKey: true});
    } catch (e, s) {
      final Object error = e is DatabaseException ? _sqlError(e, s, task.action.name) : e;
      if (!task.isBatched) FluentLog.report(error, stackTrace: s, tag: '$tableName:${task.action.name}');
      if (identical(error, e)) rethrow;
      Error.throwWithStackTrace(error, s);
    }
  }

  /// Injects the underlying SQLite [Database] instance into this provider.
  ///
  /// Used during the initialization phase to establish the connection
  /// before the provider begins processing any CRUD tasks.
  void setDb(Database db) {
    _db = db;
    FluentLog.debug('Database instance assigned', tag: '$runtimeType:init');
  }

  /// Sets the database name identifier, used for multi-database configurations.
  void setDbName(String dbName) {
    _dbName = dbName;
    FluentLog.debug('Database name set to "$dbName"', tag: '$runtimeType:init', context: {'hashCode': hashCode, 'modelType': modelType});
  }

  /// Retrieves a provider for a related model within the same database context.
  ///
  /// Relations resolve related providers only in the current database (`dbName`).
  ///
  /// By using [relatedProvider], you ensure that relations are never resolved
  /// across different databases (e.g., trying to join a 'core_app' Wishlist
  /// with a 'history' GoodsCard), which prevents "no such table" runtime errors.
  ///
  /// [type] is the model [Type] of the related provider.
  ///
  /// Returns a [FluentProvider] instance scoped to the current [dbName].
  /// Throws [FluentConfigException] ([FluentErrorCode.providerNotFound]) if the provider for the given type
  /// is not registered in this specific database group.
  FluentProvider relatedProvider(Type type) => FluentDbInternals.providerForType(type, dbName: dbName);

  /// Self-registers this provider instance with the central system registry.
  ///
  /// This allows the [FluentDb] to discover this provider dynamically
  /// without requiring manual instantiation throughout the application.
  ///
  /// [registerFn] The callback provided by the registry to handle
  /// type-safe registration of the [FluentProvider].
  void registerSelf(void Function<M extends FluentStorable>(FluentProvider<M>, String dbName) registerFn) {
    FluentLog.debug('Registering provider instance', tag: '$runtimeType:init');
    registerFn<T>(this, dbName);
  }
}
