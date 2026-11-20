// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../core/fluent_sqlite_internal.dart';

/// The options of one [FluentTask]: condition, order, paging, projection, raw SQL and write settings. The action
/// (`FluentDbAction`) says what to do, the helper with what.
class TableHelper {
  /// Whether the text of a SQLite error says the file is damaged or not a database (`SQLITE_NOTADB` / `SQLITE_CORRUPT`).
  static bool isCorrupt(Object? error) {
    if (error == null) return false;
    return RegExp(r'file is not a database|database disk image is malformed|SQLITE_NOTADB|SQLITE_CORRUPT|\(code (26|11)', caseSensitive: false).hasMatch('$error');
  }

  /// The most rows a read returns (`LIMIT`).
  final int? limit;

  /// The rows a read skips first (`OFFSET`).
  final int? offset;

  /// The final `WHERE` clause (from `FluentFilter`, with the visibility conditions); deferred conditions appear as
  /// markers until the task runs ([deferred]).
  final String? where;

  /// The values of the `?` placeholders of [where] (Dart values, converted per column when the SQL is built), or of
  /// the raw [sql].
  final List<dynamic>? whereArgs;

  /// The order of a read (e.g. `created_at DESC`); checked when the task runs: columns only, never raw SQL.
  final String? orderBy;

  /// The key of a `findById` lookup (a value or a `FluentKey`).
  final dynamic id;

  /// A value an action needs (the retention period of `purgeDeleted`).
  final dynamic value;

  /// The column values of an `updateFields` call.
  final Map<String, dynamic>? dataMap;

  /// The SQL of a raw call (`rawQuery`, `execute`).
  final String? sql;

  /// The keys of a key-based `delete` / `hardDelete` / `restore` (chunked when sent).
  final List<Object?>? arguments;

  /// How a save treats the stored related rows its models no longer list (`FluentRelationSyncMode`); `null` uses the
  /// default.
  final FluentRelationSyncMode? syncMode;

  /// How a save writes rows that already exist (`FluentSaveStrategy`).
  final FluentSaveStrategy saveStrategy;

  /// Columns that identify existing rows on save instead of the key (`saveAll(conflictOn: ...)`).
  final List<String>? conflictOn;

  /// The query shape for the cost model: the caller's condition without values and the visibility flags (the
  /// library's own soft-delete / expiry conditions are left out: they are the same for every read of a table).
  final String? shape;

  /// The write comes from the server (sync pull): rows are stored as synced, versions are not raised.
  final bool syncWrite;

  /// Columns a read returns (projections); `null` returns every column.
  final List<String>? columns;

  /// Whether a read returns each distinct row once (`SELECT DISTINCT`).
  final bool distinct;

  /// Conditions resolved by the provider when it runs the task (related models, full-text search); [where] holds
  /// their markers.
  final List<FluentDeferredCondition>? deferred;

  /// Creates the options of a task; [saveStrategy] defaults to [FluentSaveStrategy.upsert].
  TableHelper({
    this.limit,
    this.offset,
    this.where,
    this.whereArgs,
    this.orderBy,
    this.id,
    this.value,
    this.dataMap,
    this.sql,
    this.arguments,
    this.syncMode,
    this.saveStrategy = FluentSaveStrategy.upsert,
    this.conflictOn,
    this.shape,
    this.syncWrite = false,
    this.columns,
    this.distinct = false,
    this.deferred,
  });

  /// Creates a copy of this [TableHelper] with the specified fields replaced.
  TableHelper copyWith({
    int? limit,
    int? offset,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    dynamic id,
    dynamic value,
    Map<String, dynamic>? dataMap,
    String? sql,
    List<Object?>? arguments,
    FluentRelationSyncMode? syncMode,
    FluentSaveStrategy? saveStrategy,
    List<String>? conflictOn,
    String? shape,
    bool? syncWrite,
    List<String>? columns,
    bool? distinct,
    List<FluentDeferredCondition>? deferred,
  }) => TableHelper(
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
    where: where ?? this.where,
    whereArgs: whereArgs ?? this.whereArgs,
    orderBy: orderBy ?? this.orderBy,
    id: id ?? this.id,
    value: value ?? this.value,
    dataMap: dataMap ?? this.dataMap,
    sql: sql ?? this.sql,
    arguments: arguments ?? this.arguments,
    syncMode: syncMode ?? this.syncMode,
    saveStrategy: saveStrategy ?? this.saveStrategy,
    conflictOn: conflictOn ?? this.conflictOn,
    shape: shape ?? this.shape,
    syncWrite: syncWrite ?? this.syncWrite,
    columns: columns ?? this.columns,
    distinct: distinct ?? this.distinct,
    deferred: deferred ?? this.deferred,
  );

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('TableHelper{');
    final List<String> parts = [];

    if (limit != null) parts.add('limit: $limit');
    if (offset != null) parts.add('offset: $offset');
    if (where != null) parts.add('where: "$where"');
    // Values are user data: shown only with FluentLog.showSqlArguments (like SQL arguments in every message).
    final bool values = FluentLog.showSqlArguments;
    if (whereArgs != null) parts.add(values ? 'args: $whereArgs' : 'args: ${whereArgs!.length} hidden');
    if (orderBy != null) parts.add('orderBy: $orderBy');
    if (id != null) parts.add(values ? 'id: $id' : 'id: hidden');
    if (value != null) parts.add(values ? 'value: $value' : 'value: hidden');
    if (dataMap != null) parts.add('dataKeys: ${dataMap!.keys.toList()}');
    if (sql != null) parts.add('sql: ${values ? sql : FluentLog.redact(sql!)}');
    if (syncMode != null) parts.add('syncMode: ${syncMode!.name}');
    if (saveStrategy != FluentSaveStrategy.upsert) parts.add('strategy: ${saveStrategy.name}');

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}
