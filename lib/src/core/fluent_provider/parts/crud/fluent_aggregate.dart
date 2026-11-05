// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Aggregates computed by SQLite (no rows are loaded): sums, averages, extremes, distinct counts and grouped reports.
///
/// Like every read they skip soft-deleted and expired rows (`withTrash` / `includeExpired` to count them).
/// Columns are stored column names; `min` / `max` and group columns come back as Dart values (`DateTime`, enums, ...).
/// An unknown column fails with a [FluentArgumentException]; so do `sum` / `avg` of a column that does not hold plain
/// numbers (dates, enums, converted values).
extension FluentAggregates<T extends FluentStorable> on FluentProvider<T> {
  /// Sum of the numeric (`int` / `double`) [column] over the rows matching [where]; `0` when no row matches.
  ///
  /// ```dart
  /// final num revenue = await orders.sum('total', where: FluentFilter.eq('status', OrderStatus.paid));
  /// ```
  Future<num> sum(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      (await _single(FluentAggregate.sum(column), where, includeExpired, policy) as num?) ?? 0;

  /// Average of the numeric (`int` / `double`) [column] over the rows matching [where]; `null` when no row matches.
  Future<double?> avg(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      (await _single(FluentAggregate.avg(column), where, includeExpired, policy) as num?)?.toDouble();

  /// Smallest value of [column] as its Dart value ([V]: `DateTime`, `int`, an enum, ...); `null` when no row matches.
  /// A value that is not a [V] fails with a [FluentArgumentException].
  ///
  /// ```dart
  /// final DateTime? first = await orders.min<DateTime>('created_at');
  /// ```
  Future<V?> min<V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _typed<V>(column, 'min', await _single(FluentAggregate.min(column), where, includeExpired, policy));

  /// Largest value of [column] as its Dart value ([V], see [min]); `null` when no row matches.
  Future<V?> max<V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _typed<V>(column, 'max', await _single(FluentAggregate.max(column), where, includeExpired, policy));

  /// Number of distinct non-null values of [column] in the rows matching [where].
  Future<int> countDistinct(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      (await _single(FluentAggregate.countDistinct(column), where, includeExpired, policy) as int?) ?? 0;

  /// A grouped report: one map per group of [groupBy] values (one map for all rows without [groupBy]) holding the
  /// group columns and the [values] under their names.
  ///
  /// [having] and [orderBy] refer to the result names (group columns and [values] keys), [where] to the table's
  /// columns; [orderBy] may only name result names (with `ASC` / `DESC`, ...). Values in [having] are stored like the
  /// group column, or like the column of a `min` / `max` value, they compare with. Group columns, `min` and `max`
  /// come back as Dart values (with a single `min` / `max` in [values], the type tags of its row are kept, so a UTC
  /// `DateTime` stays UTC); `sum` is `0` and `avg` / `min` / `max` are `null` for an empty group.
  ///
  /// Empty [values], a value name that is empty or also a group column, or an unknown column fail with a
  /// [FluentArgumentException].
  ///
  /// ```dart
  /// final List<Map<String, dynamic>> byStatus = await orders.aggregate(
  ///   groupBy: ['status'],
  ///   values: {'orders': const FluentAggregate.count(), 'revenue': const FluentAggregate.sum('total')},
  ///   having: FluentFilter.gt('revenue', 1000),
  ///   orderBy: 'revenue DESC',
  /// );
  /// ```
  Future<List<Map<String, dynamic>>> aggregate({
    required Map<String, FluentAggregate> values,
    List<String> groupBy = const [],
    FluentFilter? where,
    FluentFilter? having,
    String? orderBy,
    int? limit,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final Object? invalid = _pagingError('aggregate', limit, null);
    if (invalid != null) throw invalid;
    if (values.isEmpty) {
      throw FluentLog.raise(
        FluentArgumentException('values', 'aggregate on "$tableName" got no values to compute.', hint: "Pass at least one value: values: {'count': const FluentAggregate.count()}."),
        tag: '$tableName:aggregate',
      );
    }
    if (having != null && having.deferred.isNotEmpty) {
      throw FluentLog.raise(
        FluentArgumentException('having', 'aggregate on "$tableName": having filters the results, related / search / ids conditions only work in where.', hint: 'Move the condition to where: aggregate(values: ..., where: FluentFilter.related(...)).'),
        tag: '$tableName:aggregate',
      );
    }
    if (groupBy.isNotEmpty) _checkColumns(groupBy, 'aggregate');
    for (final String name in values.keys) {
      if (name.isEmpty || groupBy.contains(name)) {
        throw FluentLog.raise(
          FluentArgumentException('values', 'aggregate on "$tableName": the result name "$name" is empty or is also a group column.', hint: "Give every value its own name, e.g. {'revenue': FluentAggregate.sum('total')}."),
          tag: '$tableName:aggregate',
        );
      }
    }
    final Map<String, String> selects = {for (final MapEntry<String, FluentAggregate> e in values.entries) e.key: _aggregateSql(e.value)};
    if (orderBy != null) _checkAggregateOrder(orderBy, [...groupBy, ...values.keys]);
    // With exactly one min / max, SQLite takes the other (bare) columns from the row holding that value: its type
    // tags tell how the value was stored (a UTC DateTime stays UTC).
    final List<String> extremes = [
      for (final MapEntry<String, FluentAggregate> e in values.entries)
        if (e.value.function == FluentAggregateFunction.min || e.value.function == FluentAggregateFunction.max) e.key,
    ];
    final String? tagged = extremes.length == 1 && tableColumns.contains(FluentDbColumn.systemMetadata().name) ? extremes.single : null;
    final FluentFilter scoped = _resolveRelated(_scoped(where, _visibility(includeExpired: includeExpired)));
    final String group = groupBy.map((c) => c.quotedIdentifier).join(', ');
    String sql =
        'SELECT ${[
          if (group.isNotEmpty) group,
          for (final MapEntry<String, String> s in selects.entries) '${s.value} AS ${s.key.quotedIdentifier}',
          if (tagged != null) '${FluentDbColumn.systemMetadata().name.quotedIdentifier} AS ${_aggregateMeta.quotedIdentifier}',
        ].join(', ')} '
        'FROM ${tableName.quotedIdentifier}${scoped.whereClause.isEmpty ? '' : ' WHERE ${scoped.whereClause}'}${group.isEmpty ? '' : ' GROUP BY $group'}';
    final List<Object?> args = [...?_sqlArgs(scoped.whereArgs)];
    // The outer query sees only the result names, so `having` / `orderBy` never pick a table column by mistake.
    if (having != null && having.whereClause.isNotEmpty || orderBy != null || limit != null) {
      sql = 'SELECT * FROM ($sql)';
      if (having != null && having.whereClause.isNotEmpty) {
        sql += ' WHERE ${having.whereClause}';
        args.addAll(_sqlArgs(_havingArgs(having, groupBy, values)) ?? const []);
      }
      if (orderBy != null) sql += ' ORDER BY $orderBy';
      if (limit != null) sql += ' LIMIT $limit';
    }
    final String shape = [
      _shape(where, includeExpired: includeExpired),
      'aggregate ${values.values.join(',')}',
      if (groupBy.isNotEmpty) 'by ${groupBy.join(',')}',
      if (having != null) 'having ${having.whereClause}',
    ].where((p) => p.isNotEmpty).join(' ');
    final List<Map<String, dynamic>> rows = await _run<List<Map<String, dynamic>>>(
      FluentDbAction.aggregate,
      helper: TableHelper(sql: sql, whereArgs: args, shape: shape, orderBy: orderBy, limit: limit),
      policy: policy,
    );
    final List<_MappingWarning> warnings = [];
    final List<Map<String, dynamic>> result = [
      for (final Map<String, dynamic> row in rows)
        {
          for (final String c in groupBy) c: _plan.decodeValue(c, row[c], warnings),
          for (final MapEntry<String, FluentAggregate> e in values.entries)
            e.key: _aggregateValue(e.value, row[e.key], warnings, metadata: e.key == tagged ? row[_aggregateMeta] : null),
        },
    ];
    _logWarnings(warnings);
    return result;
  }

  /// The result name of the type tags of the row holding a min / max value (dropped from the result).
  static const String _aggregateMeta = '__fluent_meta';

  /// [orderBy] of an aggregate: columns only (see `_checkedOrderBy`), and each one a result [names] (group column or
  /// value name), because the outer query sees nothing else.
  void _checkAggregateOrder(String orderBy, List<String> names) {
    _checkedOrderBy(orderBy);
    for (final String term in _FluentCrudHelper._splitOrderTerms(orderBy)) {
      final RegExpMatch? m = _orderName.firstMatch(term);
      final String? name = m == null ? null : (m[1]?.replaceAll('""', '"') ?? m[2]);
      if (name != null && names.contains(name)) continue;
      throw FluentLog.raise(
        FluentArgumentException(
          'orderBy',
          'aggregate on "$tableName": orderBy may only name result names (${names.join(', ')}), got "${term.trim()}".',
          hint: "Order by a group column or a value name, e.g. orderBy: '${names.last} DESC'.",
        ),
        tag: '$tableName:aggregate',
      );
    }
  }

  /// The name an order term starts with (quoted or plain), followed only by COLLATE / ASC / DESC / NULLS.
  static final RegExp _orderName = RegExp(r'^\s*(?:"((?:[^"]|"")+)"|([A-Za-z_]\w*))(?:\s+(?:COLLATE|ASC|DESC|NULLS)\b.*)?\s*$', caseSensitive: false);

  /// The arguments of [having] with the columns their result names stand for: a group column itself, the column of a
  /// `min` / `max` value (it holds that column's stored values); other values are plain numbers.
  List<Object?> _havingArgs(FluentFilter having, List<String> groupBy, Map<String, FluentAggregate> values) {
    final List<Object?> args = having.whereArgs;
    if (args is! FluentFilterArgs || args.columns.isEmpty) return args;
    String? source(String? name) {
      if (name == null || groupBy.contains(name)) return name;
      final FluentAggregate? value = values[name];
      return value != null && (value.function == FluentAggregateFunction.min || value.function == FluentAggregateFunction.max) ? value.column : null;
    }

    return FluentFilterArgs(args.raw, [for (int i = 0; i < args.raw.length; i++) source(args.columnAt(i))]);
  }

  Future<Object?> _single(FluentAggregate value, FluentFilter? where, bool includeExpired, ExecutionPolicy policy) async {
    final List<Map<String, dynamic>> rows = await aggregate(values: {'value': value}, where: where, includeExpired: includeExpired, policy: policy);
    return rows.isEmpty ? null : rows.first['value'];
  }

  V? _typed<V>(String column, String call, Object? value) {
    if (value == null || value is V) return value as V?;
    throw FluentLog.raise(
      FluentArgumentException('V', '$call<$V>("$column") got a ${value.runtimeType} value from "$tableName".', hint: 'Use the Dart type of the column: $call<${value.runtimeType}>("$column").'),
      tag: '$tableName:$call',
    );
  }

  /// The SQL of [value] (its column checked; `sum` / `avg` only on plain numeric columns).
  String _aggregateSql(FluentAggregate value) {
    final String? column = value.column;
    if (column == null) return 'COUNT(*)'; // only count can be built without a column
    _checkColumns([column], 'aggregate');
    final String c = column.quotedIdentifier;
    if (value.function == FluentAggregateFunction.sum || value.function == FluentAggregateFunction.avg) {
      final FluentDbColumn definition = getFullSchema.firstWhere((d) => d.name == column);
      final bool numeric = (definition.type == FluentDbDataType.integer || definition.type == FluentDbDataType.real) && definition.valueKind == null && !_plan.converters.containsKey(column);
      if (!numeric) {
        throw FluentLog.raise(
          FluentArgumentException(
            'column',
            '${value.function.name}("$column") on "$tableName": the column does not hold plain numbers (${definition.valueKind?.name ?? (_plan.converters.containsKey(column) ? 'a converted value' : definition.type.name)}).',
            hint: 'sum / avg work on int / double columns. For dates, enums and other values use min / max / countDistinct, or count per group with aggregate(groupBy: ...).',
          ),
          tag: '$tableName:aggregate',
        );
      }
    }
    return switch (value.function) {
      FluentAggregateFunction.count => 'COUNT($c)',
      FluentAggregateFunction.countDistinct => 'COUNT(DISTINCT $c)',
      FluentAggregateFunction.sum => 'SUM($c)',
      FluentAggregateFunction.avg => 'AVG($c)',
      FluentAggregateFunction.min => 'MIN($c)',
      FluentAggregateFunction.max => 'MAX($c)',
    };
  }

  Object? _aggregateValue(FluentAggregate value, Object? stored, List<_MappingWarning> warnings, {Object? metadata}) => switch (value.function) {
    FluentAggregateFunction.count || FluentAggregateFunction.countDistinct => stored ?? 0,
    FluentAggregateFunction.sum => stored ?? 0,
    FluentAggregateFunction.avg => (stored as num?)?.toDouble(),
    FluentAggregateFunction.min || FluentAggregateFunction.max => _plan.decodeValue(value.column!, stored, warnings, metadata: metadata),
  };
}
