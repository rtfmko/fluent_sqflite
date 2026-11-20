import 'dart:collection';

import '../core/fluent_sqlite_internal.dart';
import '../interfaces/fluent_storable.dart';
import '../models/configs/fluent_table_config.dart';
import '../models/db/fluent_key.dart';
import 'fluent_identifier.dart';

/// A `WHERE` condition for reads, writes, deletes and watches of a [FluentProvider] (and the `FluentDb` statics).
///
/// * Column names are quoted (`"order"` works); a string that is not a plain name (`lower(name)`, `t.id`) is used as
///   an SQL expression.
/// * Values stay Dart values (`DateTime`, `bool`, enums, ...) until the query runs: the provider stores each one like
///   its column on save (the column's converter, the enum converter of `enumValues`, the table's
///   [FluentTableConfig] `dateTimeFormat` / `storeEnumsAsNames`, epoch milliseconds for timestamp, soft-delete and
///   expiry columns). `config:` stores the values right away with that config instead. Values of a hand-written
///   `FluentFilter(sql, args)` and of expressions use the table's settings.
/// * Empty lists are safe (`inList` with no values matches nothing), and filters compose with [and] / [or].
///
/// **Example:**
/// ```dart
/// final FluentFilter filter = FluentFilter.eq('status', TaskStatus.open)
///     .and(FluentFilter.between('due', startDate, endDate))
///     .or(FluentFilter.contains('title', 'urgent'));
///
/// final List<Task> results = await tasks.find(where: filter, orderBy: 'due');
/// ```
class FluentFilter {
  /// The marker of a deferred condition in [whereClause] (its index in the deferred conditions).
  static final RegExp _relatedMarker = RegExp('\u0001(\\d+)\u0001');

  /// The generated SQL `WHERE` clause string containing `?` placeholders.
  final String whereClause;

  /// The arguments as given (Dart values), or a [FluentFilterArgs] that also knows their columns.
  final List<Object?> _args;

  /// Conditions resolved by the provider that runs the query ([FluentFilter.related], [FluentFilter.search], ...);
  /// the [whereClause] holds a marker for each one. Empty for plain filters.
  final List<FluentDeferredCondition> _deferred;

  /// A raw condition: [whereClause] is SQL with `?` placeholders, [whereArgs] their values (Dart values are stored
  /// with the table's settings; no column conversion applies). Quote identifiers yourself.
  ///
  /// ```dart
  /// FluentFilter('"price" * "qty" > ?', [100]);
  /// ```
  const FluentFilter(this.whereClause, [List<Object?> whereArgs = const []]) : _args = whereArgs, _deferred = const [];

  FluentFilter._withDeferred(this.whereClause, this._args, this._deferred);

  /// The arguments of the placeholders in [whereClause], read as SQLite values with the default table settings.
  ///
  /// Queries of a provider do not use these values: the provider stores each Dart value like its column does on
  /// save (see the class doc and [FluentFilterArgs]).
  List<Object?> get whereArgs {
    final List<Object?> args = _args;
    if (args is FluentFilterArgs) return args;
    return args.isEmpty ? const [] : FluentFilterArgs(args);
  }

  /// [whereClause] with the deferred conditions written out (for logs and the cost model; search text is hidden).
  String get description => _deferred.isEmpty ? whereClause : whereClause.replaceAllMapped(_relatedMarker, (m) => '${_deferred[int.parse(m[1]!)]}');

  /// Models whose relation [relation] has at least one related model matching [where] (any related model without
  /// [where]). [relation] is the name declared in `relations`; a path (`'author.company'`) follows several relations.
  ///
  /// Soft-deleted and expired related rows do not count, and the relation's own `where` applies, as when it is loaded.
  ///
  /// ```dart
  /// await articles.find(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann')));
  /// await articles.find(where: FluentFilter.related('comments'));                       // with at least one comment
  /// await articles.find(where: FluentFilter.related('author.company', FluentFilter.eq('country', 'UA')));
  /// ```
  ///
  /// For a reference to one of several types (`FluentRelation.oneOf`), [R] picks the type the related model must
  /// have; without it any of the types counts and [where] applies to each of them:
  /// ```dart
  /// await likes.find(where: FluentFilter.related<Post>('target', FluentFilter.eq('title', 'x')));
  /// ```
  static FluentFilter related<R extends FluentStorable>(String relation, [FluentFilter? where]) =>
      _single(FluentRelatedCondition(relation, where, FluentRelatedMode.exists, type: R));

  /// Models with no related model through [relation] matching [where] (none at all without [where]).
  ///
  /// ```dart
  /// await articles.find(where: FluentFilter.notRelated('comments'));
  /// ```
  static FluentFilter notRelated<R extends FluentStorable>(String relation, [FluentFilter? where]) =>
      _single(FluentRelatedCondition(relation, where, FluentRelatedMode.none, type: R));

  /// Models with at least [min] and at most [max] related models through [relation] (matching [where]).
  ///
  /// ```dart
  /// await articles.find(where: FluentFilter.relatedCount('comments', min: 5));
  /// ```
  static FluentFilter relatedCount<R extends FluentStorable>(String relation, {FluentFilter? where, int? min, int? max}) =>
      _single(FluentRelatedCondition(relation, where, FluentRelatedMode.count, min: min, max: max, type: R));

  /// Models whose full-text indexed columns (`FluentIndex.fullText`) contain every word of [text]; the last word also
  /// matches longer words while [prefix] (search as you type). Quotes and operators in [text] are plain text.
  /// An empty [text] matches every row.
  ///
  /// Combine it with other conditions; `FluentProvider.search` also orders by relevance.
  ///
  /// ```dart
  /// await notes.find(where: FluentFilter.search(query).and(FluentFilter.eq('archived', false)));
  /// ```
  static FluentFilter search(String text, {bool prefix = true}) => _single(FluentSearchCondition(text, prefix: prefix));

  /// Rows whose key is one of [ids]: plain values for a simple key, [FluentKey]s for a composite key. The table's key
  /// columns are filled in by the provider that runs the query. No ids match no rows; an id that does not fit the
  /// key fails with a [FluentArgumentException] when the query runs.
  ///
  /// ```dart
  /// await posts.deleteWhere(FluentFilter.ids([1, 2, 3]), hard: true);
  /// await FluentDb.updateWhere<Post>(FluentFilter.ids(selected), {'archived': true});
  /// ```
  /// Any number of ids: beyond 900 (fewer for composite keys) the provider moves them into a temporary table of the
  /// connection, so old SQLite versions (at most 999 arguments per statement) take them too.
  static FluentFilter ids(Iterable<Object?> ids) => _single(FluentKeyCondition(List.unmodifiable(ids)));

  static FluentFilter _single(FluentDeferredCondition condition) => FluentFilter._withDeferred('\u00010\u0001', const [], [condition]);

  /// [other]'s clause with its markers moved behind this filter's ones.
  String _shifted(FluentFilter other) => _deferred.isEmpty || other._deferred.isEmpty
      ? other.whereClause
      : other.whereClause.replaceAllMapped(_relatedMarker, (m) => '\u0001${int.parse(m[1]!) + _deferred.length}\u0001');

  FluentFilter _join(String op, FluentFilter other) {
    final String clause = '($whereClause) $op (${_shifted(other)})';
    final List<Object?> args = FluentFilterArgs.concat(_args, other._args);
    if (_deferred.isEmpty && other._deferred.isEmpty) return FluentFilter(clause, args);
    return FluentFilter._withDeferred(clause, args, [..._deferred, ...other._deferred]);
  }

  /// A value-complete text of this filter (clause, typed argument values, deferred conditions) for read collapsing;
  /// unlike [description] it holds every value.
  String get _fingerprint {
    final StringBuffer sb = StringBuffer('${whereClause.length}:$whereClause|');
    for (final Object? v in FluentFilterArgs.rawOf(_args)) {
      sb.write('${fluentValueKey(v)},');
    }
    for (final FluentDeferredCondition c in _deferred) {
      sb.write('${c.fingerprint};');
    }
    return sb.toString();
  }

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
  /// An empty filter on either side is left out (the other one is returned).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('status', 'active')
  ///     .and(FluentFilter.gt('age', 18));
  /// // WHERE ("status" = ?) AND ("age" > ?)
  /// ```
  FluentFilter and(FluentFilter other) {
    if (whereClause.isEmpty) return other;
    if (other.whereClause.isEmpty) return this;
    return _join('AND', other);
  }

  /// Combines this filter with [other] using the logical `OR` operator.
  ///
  /// An empty filter on either side is left out (the other one is returned), so `FluentFilter.empty.or(x)` is `x`.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('role', 'admin')
  ///     .or(FluentFilter.eq('role', 'moderator'));
  /// // WHERE ("role" = ?) OR ("role" = ?)
  /// ```
  FluentFilter or(FluentFilter other) {
    if (whereClause.isEmpty) return other;
    if (other.whereClause.isEmpty) return this;
    return _join('OR', other);
  }

  /// Creates a condition where [column] equals [value] (` = `).
  ///
  /// A `null` [value] gives [isNull]. [value] is stored like [column] stores it (see the class doc); [config] stores it
  /// right away with those settings instead (rarely needed). The same holds for the other comparisons.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.eq('status', OrderStatus.paid);
  /// // WHERE "status" = ?   (argument: 'paid', or the converter's / enum's stored form)
  /// ```
  static FluentFilter eq(String column, Object? value, {FluentTableConfig? config}) {
    if (value == null) return isNull(column);
    return FluentFilter('${column.quotedIfPlain} = ?', _values(column, [value], config));
  }

  /// Creates a condition where [column] does not equal [value] (` != `).
  ///
  /// A `null` [value] gives [isNotNull]. Like SQL `!=`, rows where [column] is `NULL` do not match.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.notEq('role', 'guest');
  /// // WHERE "role" != ?
  /// ```
  static FluentFilter notEq(String column, Object? value, {FluentTableConfig? config}) {
    if (value == null) return isNotNull(column);
    return FluentFilter('${column.quotedIfPlain} != ?', _values(column, [value], config));
  }

  /// Creates a condition where [column] is strictly greater than [value] (` > `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.gt('age', 18);
  /// // WHERE "age" > ?
  /// ```
  static FluentFilter gt(String column, Object value, {FluentTableConfig? config}) => FluentFilter('${column.quotedIfPlain} > ?', _values(column, [value], config));

  /// Creates a condition where [column] is greater than or equal to [value] (` >= `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.gte('created_at', DateTime(2026)); // stored like the column
  /// // WHERE "created_at" >= ?
  /// ```
  static FluentFilter gte(String column, Object value, {FluentTableConfig? config}) => FluentFilter('${column.quotedIfPlain} >= ?', _values(column, [value], config));

  /// Creates a condition where [column] is strictly less than [value] (` < `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.lt('price', 100);
  /// // WHERE "price" < ?
  /// ```
  static FluentFilter lt(String column, Object value, {FluentTableConfig? config}) => FluentFilter('${column.quotedIfPlain} < ?', _values(column, [value], config));

  /// Creates a condition where [column] is less than or equal to [value] (` <= `).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.lte('stock', 5);
  /// // WHERE "stock" <= ?
  /// ```
  static FluentFilter lte(String column, Object value, {FluentTableConfig? config}) => FluentFilter('${column.quotedIfPlain} <= ?', _values(column, [value], config));

  /// Creates a condition where [column] is `NULL`.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.isNull('email');
  /// // WHERE "email" IS NULL
  /// ```
  static FluentFilter isNull(String column) => FluentFilter('${column.quotedIfPlain} IS NULL');

  /// Creates a condition where [column] is not `NULL`.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.isNotNull('email');
  /// // WHERE "email" IS NOT NULL
  /// ```
  static FluentFilter isNotNull(String column) => FluentFilter('${column.quotedIfPlain} IS NOT NULL');

  /// Creates a condition where [column] falls between [start] and [end] inclusively (`BETWEEN ... AND ...`).
  ///
  /// [start] and [end] are stored like the column stores them (see the class doc).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.between('created_at', startDate, endDate);
  /// // WHERE "created_at" BETWEEN ? AND ?
  /// ```
  static FluentFilter between(String column, Object start, Object end, {FluentTableConfig? config}) =>
      FluentFilter('${column.quotedIfPlain} BETWEEN ? AND ?', _values(column, [start, end], config));

  /// Creates a condition where [column] value is present in the given [values] list (`IN (...)`).
  ///
  /// An empty [values] matches no rows (`1 = 0`). Each value is stored like [column] stores it. For key lookups prefer
  /// [ids] (composite keys too). Any number of values: beyond 900 they go through a temporary table of the connection
  /// (a filter with them works only in a provider call, which writes it as SQL).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.inList('status', [OrderStatus.open, OrderStatus.paid]);
  /// // WHERE "status" IN (?, ?)
  /// ```
  static FluentFilter inList(String column, List<Object> values, {FluentTableConfig? config}) {
    if (values.isEmpty) return const FluentFilter('1 = 0');
    if (values.length > FluentFilterInternals.maxListArguments) return _single(FluentListCondition(column, _values(column, values, config)));
    final String placeholders = List.filled(values.length, '?').join(', ');
    return FluentFilter('${column.quotedIfPlain} IN ($placeholders)', _values(column, values, config));
  }

  /// Creates a condition where [column] value is NOT present in the given [values] list (`NOT IN (...)`).
  ///
  /// An empty [values] matches every row (`1 = 1`). Rows where [column] is `NULL` do not match (SQL `NOT IN`).
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.notInList('id', [1, 2, 3]);
  /// // WHERE "id" NOT IN (?, ?, ?)
  /// ```
  static FluentFilter notInList(String column, List<Object> values, {FluentTableConfig? config}) {
    if (values.isEmpty) return const FluentFilter('1 = 1');
    if (values.length > FluentFilterInternals.maxListArguments) return _single(FluentListCondition(column, _values(column, values, config), negated: true));
    final String placeholders = List.filled(values.length, '?').join(', ');
    return FluentFilter('${column.quotedIfPlain} NOT IN ($placeholders)', _values(column, values, config));
  }

  /// A `LIKE` pattern: `%` and `_` in [value] are wildcards (for plain text use [contains], [startsWith] or
  /// [endsWith]). SQLite's `LIKE` ignores the case of ASCII letters.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.like('name', 'J%n');
  /// // WHERE "name" LIKE ?
  /// ```
  static FluentFilter like(String column, String value) => FluentFilter('${column.quotedIfPlain} LIKE ?', [value]);

  /// Creates a condition where [column] contains the text [value] (case-insensitive for ASCII, like `LIKE`); `%`, `_`
  /// and `\` in [value] are plain text.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.contains('title', '100%');
  /// // WHERE "title" LIKE ? ESCAPE '\'   (argument: '%100\%%')
  /// ```
  static FluentFilter contains(String column, String value) => _likeText(column, '%${_escapeLike(value)}%');

  /// Creates a condition where [column] starts with [value] (case-insensitive for ASCII); wildcards in [value] are
  /// plain text.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.startsWith('email', 'admin');
  /// // WHERE "email" LIKE ? ESCAPE '\'   (argument: 'admin%')
  /// ```
  static FluentFilter startsWith(String column, String value) => _likeText(column, '${_escapeLike(value)}%');

  /// Creates a condition where [column] ends with [value] (case-insensitive for ASCII); wildcards in [value] are
  /// plain text.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentFilter filter = FluentFilter.endsWith('file_name', '_v2.png');
  /// // WHERE "file_name" LIKE ? ESCAPE '\'   (argument: '%\_v2.png')
  /// ```
  static FluentFilter endsWith(String column, String value) => _likeText(column, '%${_escapeLike(value)}');

  /// A `LIKE` with an escaped pattern; the pattern is not a column value, so no column conversion applies to it.
  static FluentFilter _likeText(String column, String pattern) => FluentFilter("${column.quotedIfPlain} LIKE ? ESCAPE '\\'", [pattern]);

  /// [value] with the `LIKE` wildcards (and the escape character itself) escaped by `\`.
  static String _escapeLike(String value) => value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// The arguments of a condition on [column]: Dart values that the provider stores like [column] (when [column] names
  /// a column), or values stored right away with [config] when it is given.
  static List<Object?> _values(String column, List<Object?> values, FluentTableConfig? config) {
    if (config != null) return [for (final Object? v in values) FluentSqlSanitizer.sanitizeValueOnly(v, config)];
    final String? name = _columnName(column);
    return FluentFilterArgs(values, name == null ? const [] : List<String?>.filled(values.length, name));
  }

  static final RegExp _quotedName = RegExp(r'^"((?:[^"]|"")+)"$');

  /// The column [column] names (plain or quoted), `null` for an expression (`lower(name)`, `t.id`).
  static String? _columnName(String column) {
    if (column.isPlainIdentifier) return column;
    return _quotedName.firstMatch(column)?.group(1)!.replaceAll('""', '"');
  }
}

/// How a [FluentRelatedCondition] counts the related models.
enum FluentRelatedMode {
  /// At least one ([FluentFilter.related]).
  exists,

  /// None ([FluentFilter.notRelated]).
  none,

  /// Between `min` and `max` ([FluentFilter.relatedCount]).
  count,
}

/// A part of a [FluentFilter] that only the provider running the query can write as SQL (it needs the relation
/// graph or the full-text index of the table).
sealed class FluentDeferredCondition {
  const FluentDeferredCondition();

  /// Every value of the condition as text: the engine answers reads with equal fingerprints with one query.
  /// [toString] is the redacted form for logs.
  String get fingerprint;
}

/// Full-text search of the table's `FluentIndex.fullText` columns ([FluentFilter.search]).
class FluentSearchCondition extends FluentDeferredCondition {
  /// Creates a condition; use [FluentFilter.search].
  const FluentSearchCondition(this.text, {this.prefix = true});

  /// What the user typed: words, all of which must occur (in any indexed column).
  final String text;

  /// Whether the last word also matches longer words (search as you type).
  final bool prefix;

  /// The words of [text]: runs of letters and digits, as the full-text tokenizer splits them (punctuation, quotes and
  /// operators are separators), so user input never breaks the query.
  List<String> get words => [for (final String w in text.split(_separators)) if (w.isNotEmpty) w];

  static final RegExp _separators = RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true);

  @override
  String get fingerprint => 'search(${prefix ? 'prefix' : 'words'}:${fluentValueKey(text)})';

  @override
  String toString() => 'search(?)';
}

/// Rows with one of the given keys ([FluentFilter.ids]); the provider knows the key columns.
class FluentKeyCondition extends FluentDeferredCondition {
  /// Creates a condition; use [FluentFilter.ids].
  const FluentKeyCondition(this.ids);

  /// The keys: plain values or `FluentKey`s.
  final List<Object?> ids;

  @override
  String get fingerprint => 'ids(${ids.map(fluentValueKey).join(',')})';

  @override
  String toString() => 'ids(${ids.length})';
}

/// A long [FluentFilter.inList] / [FluentFilter.notInList] (more values than one statement may bind on old SQLite):
/// the provider running the query moves the values into a temporary table of the connection and compares with it.
class FluentListCondition extends FluentDeferredCondition {
  /// Creates a condition; use [FluentFilter.inList] or [FluentFilter.notInList].
  const FluentListCondition(this.column, this.values, {this.negated = false});

  /// The column (plain or quoted name, or an expression).
  final String column;

  /// The values: Dart values that remember their column ([FluentFilterArgs]) or stored values.
  final List<Object?> values;

  /// `NOT IN` instead of `IN`.
  final bool negated;

  @override
  String get fingerprint => 'list(${negated ? 'not ' : ''}$column:${FluentFilterArgs.rawOf(values).map(fluentValueKey).join(',')})';

  @override
  String toString() => '$column ${negated ? 'NOT IN' : 'IN'} (${values.length} values)';
}

/// A condition on the models of a relation, part of a [FluentFilter] until a provider turns it into SQL.
class FluentRelatedCondition extends FluentDeferredCondition {
  /// Creates a condition; use [FluentFilter.related], [FluentFilter.notRelated] or [FluentFilter.relatedCount].
  const FluentRelatedCondition(this.relation, this.where, this.mode, {this.min, this.max, this.type = FluentStorable});

  /// Relation name, or a path of names separated by dots.
  final String relation;

  /// Condition on the related models (their columns), if any.
  final FluentFilter? where;

  /// How the related models are counted.
  final FluentRelatedMode mode;

  /// Least number of related models ([FluentRelatedMode.count]).
  final int? min;

  /// Largest number of related models ([FluentRelatedMode.count]).
  final int? max;

  /// The model type the related model must have (a `oneOf` reference); [FluentStorable] means any.
  final Type type;

  @override
  String get fingerprint => 'related(${mode.name}:$type:${fluentValueKey(relation)}:$min:$max:${where?._fingerprint ?? '-'})';

  @override
  String toString() {
    final String inner = where == null ? '' : ': ${where!.description}';
    final String of = type == FluentStorable ? '' : '<$type>';
    return switch (mode) {
      FluentRelatedMode.exists => 'related$of($relation$inner)',
      FluentRelatedMode.none => 'notRelated$of($relation$inner)',
      FluentRelatedMode.count => 'relatedCount$of($relation$inner, min: $min, max: $max)',
    };
  }
}

/// A value-complete key of [filter] (clause, typed values, deferred conditions with their values); `''` for none.
/// Unlike `FluentFilter.description`, two filters with different values never share it.
String fluentFilterKey(FluentFilter? filter) => filter == null || filter.whereClause.isEmpty ? '' : filter._fingerprint;

/// A text of [value] that tells values and types apart (`1` / `'1'`, `['a,b']` / `['a', 'b']`); keys and lists by
/// their parts. Used for read fingerprints.
///
/// Values of other types (a converter's own class) add their `hashCode`: two objects that print the same but are not
/// equal (no `toString`, or one that leaves fields out) get different keys; equal values still share one.
String fluentValueKey(Object? value) {
  if (value is FluentKey) return 'key{${([...value.values.keys]..sort()).map((c) => '${fluentValueKey(c)}=${fluentValueKey(value[c])}').join(',')}}'; // order-free, like ==
  if (value is List) return 'list[${value.map(fluentValueKey).join(',')}]';
  final String text = '$value';
  final bool plain = value == null || value is num || value is String || value is bool || value is DateTime || value is Duration || value is Enum || value is BigInt;
  return plain ? '${value.runtimeType}:${text.length}:$text' : '${value.runtimeType}#${value.hashCode}:${text.length}:$text';
}

/// The arguments of a [FluentFilter]: the Dart values as given ([raw]) and, for conditions on one column, the column of
/// each value ([columns]), so the provider running the query stores each value like that column does on save.
///
/// Read through the `List` interface, the values are SQLite values converted with the default table settings.
class FluentFilterArgs extends ListBase<Object?> {
  /// Arguments [raw]; [columns] is empty (no column known) or holds the column (or `null`) of every value.
  FluentFilterArgs(List<Object?> raw, [List<String?> columns = const []])
    : assert(columns.isEmpty || columns.length == raw.length, 'one column per value'),
      raw = List.unmodifiable(raw),
      columns = columns.isEmpty ? const [] : List.unmodifiable(columns);

  /// The values as given (Dart values).
  final List<Object?> raw;

  /// The column of each value of [raw], or empty when none is known.
  final List<String?> columns;

  /// The column of the value at [index], `null` when unknown.
  String? columnAt(int index) => columns.isEmpty ? null : columns[index];

  late final List<Object?> _sql = [for (final Object? v in raw) FluentSqlSanitizer.sanitizeValueOnly(v, const FluentTableConfig())];

  /// The values of [args] as given (unwrapped when it is a [FluentFilterArgs]).
  static List<Object?> rawOf(List<Object?> args) => args is FluentFilterArgs ? args.raw : args;

  /// [a] followed by [b], keeping the columns of both.
  static List<Object?> concat(List<Object?> a, List<Object?> b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final FluentFilterArgs? x = a is FluentFilterArgs ? a : null;
    final FluentFilterArgs? y = b is FluentFilterArgs ? b : null;
    final List<Object?> raw = [...rawOf(a), ...rawOf(b)];
    if ((x == null || x.columns.isEmpty) && (y == null || y.columns.isEmpty)) return FluentFilterArgs(raw);
    return FluentFilterArgs(raw, [for (int i = 0; i < a.length; i++) x?.columnAt(i), for (int i = 0; i < b.length; i++) y?.columnAt(i)]);
  }

  @override
  int get length => raw.length;

  @override
  set length(int newLength) => throw UnsupportedError('FluentFilter arguments cannot be changed.');

  @override
  Object? operator [](int index) => _sql[index];

  @override
  void operator []=(int index, Object? value) => throw UnsupportedError('FluentFilter arguments cannot be changed.');
}

/// Internal access to the deferred conditions of a [FluentFilter] (hidden from the public API).
extension FluentFilterInternals on FluentFilter {
  /// Conditions resolved by the provider that runs the query; the clause holds a marker for each one.
  List<FluentDeferredCondition> get deferred => _deferred;

  /// The marker of a deferred condition in the clause (its index in [deferred]).
  static RegExp get marker => FluentFilter._relatedMarker;

  /// The most values a list condition binds as arguments; longer lists go through a temporary table (SQLite before
  /// 3.32, e.g. Android 11 and older, refuses statements with more than 999 arguments).
  static const int maxListArguments = 900;
}
