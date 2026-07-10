// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../core/fluent_sqlite_internal.dart';

/// A specification object that encapsulates query constraints, operational flags,
/// and raw execution parameters for database operations.
///
/// This class acts as the "Query Descriptor" for the [FluentTask], separating the
/// business intent (the `FluentDbAction`) from the implementation details required by
/// the SQLite engine to filter, sort, and modify data.
class TableHelper {
  /// Limits the number of rows returned in a result set (e.g., `LIMIT 10`).
  final int? limit;

  /// Specifies the number of rows to skip before starting to return results (e.g., `OFFSET 5`).
  final int? offset;

  /// The raw SQL `WHERE` clause string to filter the result set.
  final String? where;

  /// The collection of arguments corresponding to the placeholders in the `where` clause (prevents SQL injection).
  final List<dynamic>? whereArgs;

  /// The sorting criteria for the returned rows (e.g., `created_at DESC`).
  final String? orderBy;

  /// The primary key identifier, often used for single-item lookups or updates.
  final dynamic id;

  /// A secondary unique key used for map-based lookups or key-value stores.
  final String? key;

  /// The data value associated with a specific [key].
  final dynamic value;

  /// A map representing the key-value pairs of the record to be inserted or updated.
  final Map<String, dynamic>? dataMap;

  /// If true, automatically appends a validity constraint (e.g., `is_deleted = 0`) to the query.
  final bool onlyValid;

  /// Defines the sorting order by expiration date.
  /// If null, no specific expiration-based ordering is applied.
  final SortDirection? sortDirection;

  /// Custom raw SQL query string to be executed; bypasses standard builder logic.
  final String? sql;

  /// Positional arguments for the raw [sql] query placeholders.
  final List<Object?>? arguments;

  /// If true, allows operations to affect multiple rows rather than just one.
  final bool multiple;

  /// The specific database column name targeted by the operation.
  final String? column;

  /// Indicates whether this operation is a permanent (hard) delete.
  ///
  /// Note: This flag only applies to entities that implement the [FluentSoftDeletable].
  /// If the entity does not support soft-delete, this flag is ignored.
  final bool isHardDelete;

  /// Defines the synchronization strategy for relational entities (e.g., child objects).
  ///
  /// This mode determines whether the system should overwrite, ignore,
  /// or merge nested entities when a parent record is synchronized.
  final FluentRelationSyncMode syncMode;

  /// Defines how the database should handle incoming data during save operations.
  ///
  /// This strategy dictates the SQL conflict resolution and update logic,
  /// ensuring data integrity during synchronization from APIs or local mutations.
  final FluentSaveStrategy saveStrategy;

  /// The [TableHelper] constructor initializes query constraints and operational flags.
  ///
  /// Note that [saveStrategy] defaults to [FluentSaveStrategy.upsert] to prioritize
  /// developer productivity for bulk sync operations, automatically handling
  /// both new records (insertion) and existing ones (updates).
  TableHelper({
    this.limit,
    this.offset,
    this.where,
    this.whereArgs,
    this.orderBy,
    this.id,
    this.key,
    this.value,
    this.dataMap,
    this.sql,
    this.arguments,
    this.column,
    this.onlyValid = false,
    this.sortDirection,
    this.multiple = true,
    this.isHardDelete = false,
    this.syncMode = FluentRelationSyncMode.preserveLocal,
    this.saveStrategy = FluentSaveStrategy.upsert,
  });

  /// Creates a copy of this [TableHelper] with the specified fields replaced.
  TableHelper copyWith({
    int? limit,
    int? offset,
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    dynamic id,
    String? key,
    dynamic value,
    Map<String, dynamic>? dataMap,
    bool? onlyValid,
    SortDirection? sortDirection,
    String? sql,
    List<Object?>? arguments,
    bool? multiple,
    String? column,
    bool? isHardDelete,
    FluentRelationSyncMode? syncMode,
    FluentSaveStrategy? saveStrategy,
  }) => TableHelper(
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
    where: where ?? this.where,
    whereArgs: whereArgs ?? this.whereArgs,
    orderBy: orderBy ?? this.orderBy,
    id: id ?? this.id,
    key: key ?? this.key,
    value: value ?? this.value,
    dataMap: dataMap ?? this.dataMap,
    sql: sql ?? this.sql,
    arguments: arguments ?? this.arguments,
    column: column ?? this.column,
    onlyValid: onlyValid ?? this.onlyValid,
    sortDirection: sortDirection ?? this.sortDirection,
    multiple: multiple ?? this.multiple,
    isHardDelete: isHardDelete ?? this.isHardDelete,
    syncMode: syncMode ?? this.syncMode,
    saveStrategy: saveStrategy ?? this.saveStrategy,
  );

  /// Serializes the [TableHelper] instance into a JSON-compatible map.
  Map<String, dynamic> toMap() => {
    'limit': limit,
    'offset': offset,
    'where': where,
    'whereArgs': whereArgs,
    'orderBy': orderBy,
    'id': id,
    'key': key,
    'value': value,
    'dataMap': dataMap,
    'sql': sql,
    'arguments': arguments,
    'column': column,
    'saveStrategy': saveStrategy.index,
    'onlyValid': onlyValid,
    'sortDirection': sortDirection?.index,
    'multiple': multiple,
    'isHardDelete': isHardDelete,
    'syncMode': syncMode.index,
  };

  /// Deserializes a [Map] back into a [TableHelper] instance.
  factory TableHelper.fromMap(Map<String, dynamic> map) => TableHelper(
    limit: map['limit'] is int ? map['limit'] as int : null,
    offset: map['offset'] is int ? map['offset'] as int : null,
    where: map['where'] is String ? map['where'] as String : null,
    whereArgs: map['whereArgs'] is List ? map['whereArgs'] as List : null,
    orderBy: map['orderBy'] is String ? map['orderBy'] as String : null,
    id: map['id'],
    key: map['key'] is String ? map['key'] as String : null,
    value: map['value'],
    dataMap: map['dataMap'] is Map<String, dynamic> ? map['dataMap'] as Map<String, dynamic>? : null,
    sql: map['sql'] is String ? map['sql'] as String : null,
    arguments: map['arguments'] is List ? map['arguments'] as List : null,
    column: map['column'] is String ? map['column'] as String : null,
    onlyValid: map['onlyValid'] is bool ? map['onlyValid'] as bool : false,
    sortDirection: map['sortDirection'] is int ? SortDirection.values.elementAt(map['sortDirection'] as int) : null,
    multiple: map['multiple'] is bool ? map['multiple'] as bool : true,
    isHardDelete: map['isHardDelete'] is bool ? map['isHardDelete'] as bool : false,
    syncMode: map['syncMode'] is int ? FluentRelationSyncMode.values[map['syncMode'] as int] : FluentRelationSyncMode.preserveLocal,
    saveStrategy: map['saveStrategy'] is int ? FluentSaveStrategy.values[map['saveStrategy'] as int] : FluentSaveStrategy.upsert,
  );

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('TableHelper{');
    final List<String> parts = [];

    if (limit != null) parts.add('limit: $limit');
    if (offset != null) parts.add('offset: $offset');
    if (where != null) parts.add('where: "$where"');
    if (whereArgs != null) parts.add('args: $whereArgs');
    if (orderBy != null) parts.add('orderBy: $orderBy');
    if (id != null) parts.add('id: $id');
    if (key != null) parts.add('key: $key, value: $value');
    if (dataMap != null) parts.add('dataKeys: ${dataMap!.keys.toList()}');
    if (sql != null) parts.add('sql: $sql');
    if (onlyValid) parts.add('onlyValid: true');
    if (isHardDelete) parts.add('isHardDelete: true');
    if (sortDirection != null) parts.add('sort: ${sortDirection!.name}');
    if (syncMode != FluentRelationSyncMode.preserveLocal) parts.add('syncMode: ${syncMode.name}');
    if (saveStrategy != FluentSaveStrategy.upsert) parts.add('strategy: ${saveStrategy.name}');

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}
