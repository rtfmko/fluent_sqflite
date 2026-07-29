import '../core/fluent_sqlite_internal.dart';
import '../core/utils/utils.dart';

/// A powerful query builder helper for constructing safe and type-safe SQL `WHERE` clauses
/// and parameter arguments for [FluentProvider] and database operations.
///
/// **Features:**
/// * Automatic type sanitization (handles [DateTime], [bool], [Enum], and custom types via [FluentTableConfig]).
/// * Protection against common SQL errors (e.g., handling empty lists in `IN` clauses).
/// * Seamless composition using [and] and [or] operators.
///
/// **Example:**
/// ```dart
/// final FluentFilter filter = FluentFilter.eq('status', 'active')
///     .and(FluentFilter.between('created_at', startDate, endDate, config: tableConfig))
///     .or(FluentFilter.contains('title', 'urgent'));
///
/// final TaskProvider results = await TaskProvider.find(filter: filter);
/// ```
class FluentFilter {
  /// The generated SQL `WHERE` clause string containing `?` placeholders.
  final String whereClause;

  /// The list of sanitized arguments corresponding to the placeholders in [whereClause].
  final List<Object?> whereArgs;

  /// Creates a new [FluentFilter] instance with the specified SQL [whereClause]
  /// and its corresponding [whereArgs].
  const FluentFilter(this.whereClause, [this.whereArgs = const []]);

  /// An empty filter representing no conditions or filtering criteria.
  ///
  /// Useful as a fallback or a starting point for dynamic filter building.
  ///
  /// **Example:**
  /// ```dart
  /// FluentFilter filter = FluentFilter.empty;
  /// if (isFiltered) {
  ///   filter = FluentFilter.eq('status', 'active');
  /// }
  /// ```
  static const FluentFilter empty = FluentFilter('');

  /// Combines this filter with [other] using the logical `AND` operator.
  ///
  /// Safely handles empty clauses, returning whichever filter is populated.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('status', 'active')
  ///     .and(FluentFilter.gt('age', 18));
  /// // Generates WHERE clause: (status = ?) AND (age > ?)
  /// ```
  FluentFilter and(FluentFilter other) {
    if (whereClause.isEmpty) return other;
    if (other.whereClause.isEmpty) return this;
    return FluentFilter('($whereClause) AND (${other.whereClause})', [...whereArgs, ...other.whereArgs]);
  }

  /// Combines this filter with [other] using the logical `OR` operator.
  ///
  /// Safely handles empty clauses, returning whichever filter is populated.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('role', 'admin')
  ///     .or(FluentFilter.eq('role', 'moderator'));
  /// // Generates WHERE clause: (role = ?) OR (role = ?)
  /// ```
  FluentFilter or(FluentFilter other) {
    if (whereClause.isEmpty) return other;
    if (other.whereClause.isEmpty) return this;
    return FluentFilter('($whereClause) OR (${other.whereClause})', [...whereArgs, ...other.whereArgs]);
  }

  /// Creates a condition where [column] equals [value] (` = `).
  ///
  /// *Note: If [value] is `null`, automatically falls back to [isNull].*
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('status', 'active');
  /// // Generates WHERE clause: status = ?
  /// ```
  static FluentFilter eq(String column, Object? value, {FluentTableConfig? config}) {
    if (value == null) return isNull(column);
    return FluentFilter('$column = ?', [_sanitize(value, config)]);
  }

  /// Creates a condition where [column] does not equal [value] (` != `).
  ///
  /// *Note: If [value] is `null`, automatically falls back to [isNotNull].*
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.notEq('role', 'guest');
  /// // Generates WHERE clause: role != ?
  /// ```
  static FluentFilter notEq(String column, Object? value, {FluentTableConfig? config}) {
    if (value == null) return isNotNull(column);
    return FluentFilter('$column != ?', [_sanitize(value, config)]);
  }

  /// Creates a condition where [column] is strictly greater than [value] (` > `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.gt('age', 18);
  /// // Generates WHERE clause: age > ?
  /// ```
  static FluentFilter gt(String column, Object value, {FluentTableConfig? config}) => FluentFilter('$column > ?', [_sanitize(value, config)]);

  /// Creates a condition where [column] is greater than or equal to [value] (` >= `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.gte('score', 50);
  /// // Generates WHERE clause: score >= ?
  /// ```
  static FluentFilter gte(String column, Object value, {FluentTableConfig? config}) => FluentFilter('$column >= ?', [_sanitize(value, config)]);

  /// Creates a condition where [column] is strictly less than [value] (` < `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.lt('price', 100);
  /// // Generates WHERE clause: price < ?
  /// ```
  static FluentFilter lt(String column, Object value, {FluentTableConfig? config}) => FluentFilter('$column < ?', [_sanitize(value, config)]);

  /// Creates a condition where [column] is less than or equal to [value] (` <= `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.lte('stock', 5);
  /// // Generates WHERE clause: stock <= ?
  /// ```
  static FluentFilter lte(String column, Object value, {FluentTableConfig? config}) => FluentFilter('$column <= ?', [_sanitize(value, config)]);

  /// Creates a condition where [column] is `NULL`.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.isNull('deleted_at');
  /// // Generates WHERE clause: deleted_at IS NULL
  /// ```
  static FluentFilter isNull(String column) => FluentFilter('$column IS NULL');

  /// Creates a condition where [column] is not `NULL`.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.isNotNull('email');
  /// // Generates WHERE clause: email IS NOT NULL
  /// ```
  static FluentFilter isNotNull(String column) => FluentFilter('$column IS NOT NULL');

  /// Creates a condition where [column] falls between [start] and [end] inclusively (`BETWEEN ... AND ...`).
  ///
  /// Automatically respects the [FluentTableConfig] formatting for [DateTime] and other complex types.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.between('created_at', startDate, endDate, config: tableConfig);
  /// // Generates WHERE clause: created_at BETWEEN ? AND ?
  /// ```
  static FluentFilter between(String column, Object start, Object end, {FluentTableConfig? config}) => FluentFilter('$column BETWEEN ? AND ?', [_sanitize(start, config), _sanitize(end, config)]);

  /// Creates a condition where [column] value is present in the given [values] list (`IN (...)`).
  ///
  /// *Note: If [values] is empty, safely returns a condition that evaluates to false (`1 = 0`),*
  /// *preventing invalid SQL syntax.*
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.inList('status', ['active', 'pending']);
  /// // Generates WHERE clause: status IN (?, ?)
  /// ```
  static FluentFilter inList(String column, List<Object> values, {FluentTableConfig? config}) {
    if (values.isEmpty) return const FluentFilter('1 = 0');
    final String placeholders = List.filled(values.length, '?').join(', ');
    final List<Object?> args = values.map((v) => _sanitize(v, config)).toList();
    return FluentFilter('$column IN ($placeholders)', args);
  }

  /// Creates a condition where [column] value is NOT present in the given [values] list (`NOT IN (...)`).
  ///
  /// *Note: If [values] is empty, safely returns a condition that evaluates to true (`1 = 1`),*
  /// *preventing invalid SQL syntax.*
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.notInList('id', [1, 2, 3]);
  /// // Generates WHERE clause: id NOT IN (?, ?, ?)
  /// ```
  static FluentFilter notInList(String column, List<Object> values, {FluentTableConfig? config}) {
    if (values.isEmpty) return const FluentFilter('1 = 1');
    final String placeholders = List.filled(values.length, '?').join(', ');
    final List<Object?> args = values.map((v) => _sanitize(v, config)).toList();
    return FluentFilter('$column NOT IN ($placeholders)', args);
  }

  /// Creates a raw SQL `LIKE` condition.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.like('name', 'J%');
  /// // Generates WHERE clause: name LIKE ?
  /// ```
  static FluentFilter like(String column, String value) => FluentFilter('$column LIKE ?', [value]);

  /// Creates a condition where [column] contains the substring [value] (`%value%`).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.contains('title', 'urgent');
  /// // Generates WHERE clause: title LIKE ? (arg: '%urgent%')
  /// ```
  static FluentFilter contains(String column, String value) => FluentFilter('$column LIKE ?', ['%$value%']);

  /// Creates a condition where [column] starts with the given [value] (`value%`).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.startsWith('email', 'admin');
  /// // Generates WHERE clause: email LIKE ? (arg: 'admin%')
  /// ```
  static FluentFilter startsWith(String column, String value) => FluentFilter('$column LIKE ?', ['$value%']);

  /// Creates a condition where [column] ends with the given [value] (`%value`).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.endsWith('file_path', '.png');
  /// // Generates WHERE clause: file_path LIKE ? (arg: '%.png')
  /// ```
  static FluentFilter endsWith(String column, String value) => FluentFilter('$column LIKE ?', ['%$value']);

  /// Internal helper that sanitizes raw query values using the [FluentSqlSanitizer],
  /// falling back to a default [FluentTableConfig] if none is provided.
  static Object? _sanitize(Object? value, FluentTableConfig? config) => FluentSqlSanitizer.sanitizeValueOnly(value, config ?? const FluentTableConfig());
}
