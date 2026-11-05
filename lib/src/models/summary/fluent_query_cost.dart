// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// The measured cost of one query shape (see `FluentDb.queryStats()`).
///
/// A shape is the table, the operation and the SQL condition without its values (`"status" = ?`), so every
/// `find(where: FluentFilter.eq('status', ...))` shares one entry whatever the status is.
class FluentQueryCost {
  /// Creates a cost entry.
  const FluentQueryCost({
    required this.database,
    required this.table,
    required this.action,
    required this.shape,
    required this.averageMs,
    required this.samples,
    required this.failures,
    this.averageRows,
  });

  /// Database group of the table.
  final String database;

  /// Table name.
  final String table;

  /// Operation (`find`, `count`, `findById`, `save`, ...).
  final String action;

  /// Condition, order and options of the query, without values.
  final String shape;

  /// Moving average duration (ms; per row for writes of several rows); recent runs weigh most, so old measurements
  /// fade out.
  final double averageMs;

  /// Moving average of the rows a read returned (`null` for writes and for reads that return no list).
  final double? averageRows;

  /// Number of measured runs.
  final int samples;

  /// Number of failed runs.
  final int failures;

  @override
  String toString() =>
      '$table.$action ${shape.isEmpty ? '(all rows)' : shape}: ${averageMs.toStringAsFixed(1)} ms × $samples'
      '${averageRows == null ? '' : ', ~${averageRows!.round()} rows'}${failures > 0 ? ' ($failures failed)' : ''}';
}

/// The measured query costs returned by `FluentDb.queryStats()`, slowest first; [toString] prints them as a table.
class FluentQueryStats {
  /// Wraps [queries] (slowest first).
  const FluentQueryStats(this.queries);

  /// The measured query shapes, slowest first.
  final List<FluentQueryCost> queries;

  @override
  String toString() {
    if (queries.isEmpty) return 'No queries measured yet.';
    final StringBuffer out = StringBuffer('Measured queries (avg ms × runs):\n');
    for (final FluentQueryCost c in queries) {
      out.writeln(
        '  ${c.averageMs.toStringAsFixed(1).padLeft(8)} ms × ${c.samples.toString().padRight(6)} ${c.database}/${c.table} ${c.action} '
        '${c.shape}${c.averageRows == null ? '' : '  (~${c.averageRows!.round()} rows)'}${c.failures > 0 ? '  (${c.failures} failed)' : ''}',
      );
    }
    return out.toString();
  }
}
