// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// The function of a [FluentAggregate].
enum FluentAggregateFunction {
  /// Number of rows (or of non-null values of a column).
  count,

  /// Number of distinct non-null values of a column.
  countDistinct,

  /// Sum of a numeric column (`0` for no rows).
  sum,

  /// Average of a numeric column (`null` for no rows).
  avg,

  /// Smallest value of a column, as its Dart value (`null` for no rows).
  min,

  /// Largest value of a column, as its Dart value (`null` for no rows).
  max,
}

/// One computed value of `FluentProvider.aggregate`: a function over a column, by its stored column name.
///
/// ```dart
/// final List<Map<String, dynamic>> rows = await orders.aggregate(
///   groupBy: ['status'],
///   values: {'orders': const FluentAggregate.count(), 'revenue': const FluentAggregate.sum('total')},
///   orderBy: 'revenue DESC',
/// );
/// rows.first['status']; // OrderStatus.paid (the enum, as in the model)
/// ```
class FluentAggregate {
  const FluentAggregate._(this.function, this.column);

  /// Number of rows; with [column], number of rows where it is not null.
  const FluentAggregate.count([String? column]) : this._(FluentAggregateFunction.count, column);

  /// Number of distinct non-null values of [column].
  const FluentAggregate.countDistinct(String column) : this._(FluentAggregateFunction.countDistinct, column);

  /// Sum of the numeric [column] (`0` for no rows).
  const FluentAggregate.sum(String column) : this._(FluentAggregateFunction.sum, column);

  /// Average of the numeric [column] (`null` for no rows).
  const FluentAggregate.avg(String column) : this._(FluentAggregateFunction.avg, column);

  /// Smallest value of [column] (`null` for no rows).
  const FluentAggregate.min(String column) : this._(FluentAggregateFunction.min, column);

  /// Largest value of [column] (`null` for no rows).
  const FluentAggregate.max(String column) : this._(FluentAggregateFunction.max, column);

  /// The function.
  final FluentAggregateFunction function;

  /// The column, by its stored name (`null`: all rows, for [FluentAggregateFunction.count]).
  final String? column;

  @override
  String toString() => '${function.name}(${column ?? '*'})';
}
