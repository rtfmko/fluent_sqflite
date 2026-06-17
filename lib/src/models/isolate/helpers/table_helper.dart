// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../../core/fluent_sqlite_internal.dart';

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

  /// If true, performs an 'UPSERT' operation instead of a standard insert.
  final bool updateIfExist;

  /// If true, automatically appends a validity constraint (e.g., `is_deleted = 0`) to the query.
  final bool onlyValid;

  /// If true, forces the result set to be ordered by expiration date.
  final bool? sortByExpireDate;

  /// Custom raw SQL query string to be executed; bypasses standard builder logic.
  final String? sql;

  /// Positional arguments for the raw [sql] query placeholders.
  final List<Object?>? arguments;

  /// If true, allows operations to affect multiple rows rather than just one.
  final bool multiple;

  /// The specific database column name targeted by the operation.
  final String? column;

  /// The [TableHelper] constructor initializes query constraints and operational flags.
  ///
  /// Note that `updateIfExist` and `multiple` default to `true` to prioritize
  /// developer productivity for bulk/upsert operations, which are the most
  /// common patterns in data-syncing applications.
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
    this.updateIfExist = true,
    this.onlyValid = false,
    this.sortByExpireDate,
    this.multiple = true,
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
    bool? updateIfExist,
    bool? onlyValid,
    bool? sortByExpireDate,
    String? sql,
    List<Object?>? arguments,
    bool? multiple,
    String? column,
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
    updateIfExist: updateIfExist ?? this.updateIfExist,
    onlyValid: onlyValid ?? this.onlyValid,
    sortByExpireDate: sortByExpireDate ?? this.sortByExpireDate,
    multiple: multiple ?? this.multiple,
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
    'updateIfExist': updateIfExist,
    'onlyValid': onlyValid,
    'sortByExpireDate': sortByExpireDate,
    'multiple': multiple,
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
    updateIfExist: map['updateIfExist'] is bool ? map['updateIfExist'] as bool : false,
    onlyValid: map['onlyValid'] is bool ? map['onlyValid'] as bool : false,
    sortByExpireDate: map['sortByExpireDate'] is bool ? map['sortByExpireDate'] as bool : false,
    multiple: map['multiple'] is bool ? map['multiple'] as bool : true,
  );

  @override
  String toString() {
    return 'TableHelper{limit: $limit, offset: $offset, where: $where, whereArgs: $whereArgs, orderBy: $orderBy, id: $id, key: $key, value: $value, dataMap: $dataMap, updateIfExist: $updateIfExist, onlyValid: $onlyValid, sortByExpireDate: $sortByExpireDate, sql: $sql, arguments: $arguments, multiple: $multiple, column: $column}';
  }
}
