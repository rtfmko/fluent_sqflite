// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../core/fluent_sqlite_internal.dart';
import '../../exceptions/exceptions.dart';
import '../../utils/utils.dart';
import '../fluent_issue.dart';
import 'fluent_converter.dart';
import 'fluent_sql_expression.dart';

/// Text comparison rule of a column (`COLLATE`).
enum FluentCollation {
  /// Byte-by-byte comparison (SQLite default): `"a" != "A"`.
  binary('BINARY'),

  /// Case-insensitive for ASCII letters: `"a" == "A"`. Handy for emails, usernames, tags.
  noCase('NOCASE'),

  /// Like [binary], but trailing spaces are ignored.
  rTrim('RTRIM');

  /// The SQL keyword.
  final String sql;

  const FluentCollation(this.sql);
}

/// The Dart type a column holds when SQLite stores it as a simpler value.
///
/// Set automatically for columns inferred from `buildJson()` and by the column factories
/// (`boolean`, `timestamp`). It lets the library restore the Dart value even for rows that were written
/// without type metadata (raw SQL, older versions), and saves writing that metadata on every row.
enum FluentValueKind {
  /// `bool` stored as INTEGER 0 / 1.
  boolean('bool'),

  /// `DateTime` stored as milliseconds since epoch (or ISO text, see `FluentTableConfig`).
  dateTime('datetime'),

  /// `Duration` stored as microseconds.
  duration('duration'),

  /// Flutter `Color` stored as ARGB INTEGER.
  color('color'),

  /// Flutter `Locale` stored as a language tag.
  locale('locale'),

  /// Flutter `TimeOfDay` stored as `HH:mm`.
  timeOfDay('timeofday'),

  /// `BigInt` stored as TEXT.
  bigInt('bigint'),

  /// `Uri` stored as TEXT.
  uri('uri'),

  /// `List` / `Map` stored as JSON TEXT.
  json('json'),

  /// `Enum` stored by name (or index); needs `FluentStorable.enumValues` to be restored.
  enumValue('enum');

  /// The type tag used in `_fs_metadata`.
  final String tag;

  const FluentValueKind(this.tag);
}

/// The definition of one table column: name, type, constraints, index, default value and how the value is stored.
///
/// Columns are inferred from `buildJson()`; declare one yourself (`FluentStorable.missingColumns`, `primaryKeys`)
/// to set constraints or a converter. Instances are immutable; use [copyWith] to derive a changed column.
///
/// ```dart
/// @override
/// List<FluentDbColumn> get missingColumns => [
///   FluentDbColumn.text('email', isUnique: true, collation: FluentCollation.noCase),
///   FluentDbColumn.integer('stock', isNotNull: true, defaultValue: 0),
///   FluentDbColumn.converted('status', FluentEnumConverter(OrderStatus.values), indexed: true),
/// ];
/// ```
class FluentDbColumn {
  /// The physical column name in the database.
  final String name;

  /// The SQLite data type (TEXT, INTEGER, REAL, BLOB, or `custom` with [customSql]).
  final FluentDbDataType type;

  /// The previous name of the column: the schema sync renames that column instead of adding a new empty one.
  final String? oldName;

  /// Raw SQL of the column definition, written after the name (and after the type unless it starts with one).
  /// Constraints it already contains (`NOT NULL`, `DEFAULT`, ...) are not added again.
  final String? customSql;

  /// Whether this column acts as the primary key for the table.
  final bool isPrimaryKey;

  /// Whether the database should automatically increment this column's value.
  ///
  /// Only applicable to single [FluentDbDataType.integer] primary keys.
  final bool isAutoIncrement;

  /// Whether the column constraint `NOT NULL` should be applied.
  final bool isNotNull;

  /// Whether the column constraint `UNIQUE` should be applied.
  final bool isUnique;

  /// Default value written as a plain Dart value; it is escaped automatically
  /// (`'active'` → `DEFAULT 'active'`, `true` → `DEFAULT 1`).
  ///
  /// Use [FluentSqlExpression] for values computed by SQLite, e.g.
  /// [FluentSqlExpression.currentTimestamp].
  final Object? defaultValue;

  /// An optional `CHECK` constraint as raw SQL (e.g., "age > 0").
  final String? checkConstraint;

  /// Whether to create a secondary index on this column for faster lookups.
  ///
  /// For indexes over several columns or unique indexes use [FluentStorable.indexes].
  final bool indexed;

  /// Whether the library may correct this column's definition by itself (a `primaryKey` column not marked
  /// [isPrimaryKey] is promoted to the key). System columns set it to `false`.
  final bool autoCorrectAllowed;

  /// How text values of this column are compared and sorted (`COLLATE`).
  final FluentCollation? collation;

  /// Optional converter that controls how the field value is stored and read back.
  final FluentConverter<Object?, Object?>? converter;

  /// The Dart type behind the stored value, if it is not a plain SQLite value (see [FluentValueKind]).
  final FluentValueKind? valueKind;

  /// Cached DDL definition (columns are immutable, so the cache never goes stale).
  String? _cachedSqlDefinition;

  /// Creates a column definition.
  ///
  /// `AUTOINCREMENT` on a non-INTEGER column is ignored (a `schemaFallback` issue says so). With
  /// [FluentDbDataType.custom], [customSql] must start with a SQLite type or contain a `REFERENCES` clause;
  /// otherwise a [FluentSchemaException] is thrown.
  FluentDbColumn({
    required this.name,
    required this.type,
    this.oldName,
    this.customSql,
    this.isPrimaryKey = false,
    this.isAutoIncrement = false,
    this.isNotNull = false,
    this.isUnique = false,
    this.defaultValue,
    this.checkConstraint,
    this.indexed = false,
    this.autoCorrectAllowed = true,
    this.collation,
    this.converter,
    this.valueKind,
  }) {
    if (isAutoIncrement && type != FluentDbDataType.integer) {
      FluentLog.issue(
        FluentIssueKind.schemaFallback,
        'AUTOINCREMENT on non-INTEGER column "$name" is ignored.',
        tag: 'FluentDbColumn',
        hint: 'AUTOINCREMENT is only valid for INTEGER primary keys in SQLite. Use FluentDbDataType.integer or set isAutoIncrement: false.',
      );
    }

    if (type == FluentDbDataType.custom && customSql != null) {
      final String upperSql = customSql!.toUpperCase().trim();
      const List<String> allowedTypes = ['INTEGER', 'TEXT', 'REAL', 'BLOB', 'NUMERIC', 'BOOLEAN', 'TIMESTAMP'];

      final bool isValid = allowedTypes.any((t) => upperSql.startsWith(t)) || upperSql.contains('REFERENCES');

      if (!isValid) {
        throw FluentLog.raise(
          FluentSchemaException(
            "customSql of column \"$name\" must start with a SQLite type (TEXT, INTEGER, REAL, BLOB, NUMERIC): '$customSql'.",
            columnName: name,
            hint: 'Start customSql with a type, e.g. customSql: "TEXT NOT NULL", or use a regular type instead of FluentDbDataType.custom.',
          ),
          tag: 'FluentDbColumn',
        );
      }
    }
  }

  /// Creates a copy of this [FluentDbColumn] with the specified fields replaced. An argument left out keeps the
  /// current value; the nullable fields ([oldName], [customSql], [defaultValue], [checkConstraint], [collation],
  /// [converter], [valueKind]) are cleared by passing `null`: `column.copyWith(defaultValue: null)`.
  FluentDbColumn copyWith({
    String? name,
    FluentDbDataType? type,
    Object? oldName = _keep,
    Object? customSql = _keep,
    bool? isPrimaryKey,
    bool? isAutoIncrement,
    bool? isNotNull,
    bool? isUnique,
    Object? defaultValue = _keep,
    Object? checkConstraint = _keep,
    bool? indexed,
    bool? autoCorrectAllowed,
    Object? collation = _keep,
    Object? converter = _keep,
    Object? valueKind = _keep,
  }) {
    T? pick<T>(Object? given, T? current) => identical(given, _keep) ? current : given as T?;
    return FluentDbColumn(
      name: name ?? this.name,
      type: type ?? this.type,
      oldName: pick(oldName, this.oldName),
      customSql: pick(customSql, this.customSql),
      isPrimaryKey: isPrimaryKey ?? this.isPrimaryKey,
      isAutoIncrement: isAutoIncrement ?? this.isAutoIncrement,
      isNotNull: isNotNull ?? this.isNotNull,
      isUnique: isUnique ?? this.isUnique,
      defaultValue: pick(defaultValue, this.defaultValue),
      checkConstraint: pick(checkConstraint, this.checkConstraint),
      indexed: indexed ?? this.indexed,
      autoCorrectAllowed: autoCorrectAllowed ?? this.autoCorrectAllowed,
      collation: pick(collation, this.collation),
      converter: pick(converter, this.converter),
      valueKind: pick(valueKind, this.valueKind),
    );
  }

  /// "Keep the current value" in [copyWith] (so `null` can clear a field).
  static const Object _keep = Object();

  /// An INTEGER primary key column, named `id` by default, auto-incremented unless [isAutoIncrement] is `false`.
  static FluentDbColumn primary({String? name, bool isAutoIncrement = true}) =>
      FluentDbColumn(name: name ?? 'id', type: FluentDbDataType.integer, isPrimaryKey: true, isAutoIncrement: isAutoIncrement);

  /// A TEXT column.
  static FluentDbColumn text(String name, {bool isNotNull = false, bool isUnique = false, bool indexed = false, String? defaultValue, FluentCollation? collation}) =>
      FluentDbColumn(name: name, type: FluentDbDataType.text, isNotNull: isNotNull, isUnique: isUnique, indexed: indexed, defaultValue: defaultValue, collation: collation);

  /// An INTEGER column.
  static FluentDbColumn integer(String name, {bool isNotNull = false, bool isUnique = false, bool indexed = false, int? defaultValue}) =>
      FluentDbColumn(name: name, type: FluentDbDataType.integer, isNotNull: isNotNull, isUnique: isUnique, indexed: indexed, defaultValue: defaultValue);

  /// A REAL (floating-point) column.
  static FluentDbColumn real(String name, {bool isNotNull = false, bool indexed = false, double? defaultValue}) =>
      FluentDbColumn(name: name, type: FluentDbDataType.real, isNotNull: isNotNull, indexed: indexed, defaultValue: defaultValue);

  /// Creates a boolean column (stored as INTEGER `0`/`1`, guarded by a `CHECK` constraint).
  static FluentDbColumn boolean(String name, {bool isNotNull = false, bool indexed = false, bool? defaultValue}) => FluentDbColumn(
    name: name,
    type: FluentDbDataType.integer,
    isNotNull: isNotNull,
    indexed: indexed,
    defaultValue: defaultValue,
    checkConstraint: '${name.quotedIdentifier} IN (0, 1)',
    valueKind: FluentValueKind.boolean,
  );

  /// A `DateTime` column of type INTEGER: values are stored as milliseconds since epoch with the default
  /// `FluentTableConfig.dateTimeFormat` (ISO text with `FluentDateTimeFormat.iso8601`).
  static FluentDbColumn timestamp(String name, {bool isNotNull = false, bool indexed = false}) =>
      FluentDbColumn(name: name, type: FluentDbDataType.integer, isNotNull: isNotNull, indexed: indexed, valueKind: FluentValueKind.dateTime);

  /// A BLOB column (`Uint8List` values).
  static FluentDbColumn blob(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.blob, isNotNull: isNotNull);

  /// Creates a column whose value is stored through [converter] (the column type is taken from the converter).
  ///
  /// ```dart
  /// FluentDbColumn.converted('status', FluentEnumConverter(OrderStatus.values));
  /// FluentDbColumn.converted('settings', const FluentJsonConverter<Map<String, dynamic>>());
  /// ```
  static FluentDbColumn converted<D, S>(String name, FluentConverter<D, S> converter, {bool isNotNull = false, bool indexed = false, Object? defaultValue}) => FluentDbColumn(
    name: name,
    type: converter.sqlType,
    isNotNull: isNotNull,
    indexed: indexed,
    defaultValue: defaultValue,
    converter: converter as FluentConverter<Object?, Object?>,
  );

  /// The columns every table gets: [systemMetadata] and the expiry column [expiryColumnName].
  static List<FluentDbColumn> systemColumns(String expiryColumnName) => [systemMetadata(), systemExpiryDate(expiryColumnName)];

  /// The `_fs_metadata` column: per-row type tags of values the column kind does not describe (never part of models
  /// or maps).
  static FluentDbColumn systemMetadata() => FluentDbColumn(name: '_fs_metadata', type: FluentDbDataType.text, autoCorrectAllowed: false);

  /// The expiry column (epoch milliseconds, see `FluentStorable.timeToLive`).
  static FluentDbColumn systemExpiryDate(String name) => FluentDbColumn(name: name, type: FluentDbDataType.integer, autoCorrectAllowed: false);

  /// The soft-delete column (`deletedAt` as epoch milliseconds).
  static FluentDbColumn systemSoftDelete(String name) => FluentDbColumn(name: name, type: FluentDbDataType.integer, autoCorrectAllowed: false, valueKind: FluentValueKind.dateTime);

  /// The column definition for `CREATE TABLE` / `ADD COLUMN` (cached): quoted name, type (or [customSql]) and the
  /// constraints [customSql] does not already contain. SQL keywords work as column names.
  String get sqlDefinition => _cachedSqlDefinition ??= sqlDefinitionWith();

  bool _customHas(RegExp rule) => customSql != null && rule.hasMatch(customSql!);

  static final RegExp _notNullRule = RegExp(r'\bNOT\s+NULL\b', caseSensitive: false);
  static final RegExp _uniqueRule = RegExp(r'\bUNIQUE\b', caseSensitive: false);
  static final RegExp _primaryKeyRule = RegExp(r'\bPRIMARY\s+KEY\b', caseSensitive: false);
  static final RegExp _defaultRule = RegExp(r'\bDEFAULT\b', caseSensitive: false);
  static final RegExp _expressionDefaultRule = RegExp(r'\bDEFAULT\s*(\(|CURRENT_)', caseSensitive: false);

  /// Builds the column definition. With [inlinePrimaryKey] set to `false` the `PRIMARY KEY`
  /// clause is left out — used for composite keys, which are declared at table level.
  String sqlDefinitionWith({bool inlinePrimaryKey = true}) {
    final List<String> parts = [name.quotedIdentifier];
    final String? trimmedCustom = customSql?.trim();
    final String upperCustom = trimmedCustom?.toUpperCase() ?? '';
    final bool hasCustom = trimmedCustom != null && trimmedCustom.isNotEmpty;

    // Reconcile custom SQL with standard type definitions
    if (hasCustom) {
      final bool hasTypeInCustom = upperCustom.startsWith('TEXT') || upperCustom.startsWith('INTEGER') || upperCustom.startsWith('REAL') || upperCustom.startsWith('BLOB');

      if (!hasTypeInCustom && type != FluentDbDataType.custom) {
        parts.add(type.sql);
      }
      parts.add(trimmedCustom);
    } else {
      parts.add(type.sql);
    }

    // Constraint validation to prevent SQL syntax errors from redundant keywords
    final bool hasCustomPk = upperCustom.contains('PRIMARY KEY');
    final bool hasCustomAi = upperCustom.contains('AUTOINCREMENT');
    final bool hasCustomNotNull = upperCustom.contains('NOT NULL');
    final bool hasCustomUnique = upperCustom.contains('UNIQUE');
    final bool hasCustomDefault = upperCustom.contains('DEFAULT');
    final bool hasCustomCheck = upperCustom.contains('CHECK');
    final bool hasCustomCollate = upperCustom.contains('COLLATE');

    final bool renderPk = isPrimaryKey && inlinePrimaryKey;

    if (renderPk && !hasCustomPk) {
      parts.add('PRIMARY KEY');
      if (isAutoIncrement && type == FluentDbDataType.integer && !hasCustomAi) {
        parts.add('AUTOINCREMENT');
      }
    }

    if (isNotNull && !renderPk && !hasCustomNotNull) parts.add('NOT NULL');
    if (isUnique && !renderPk && !hasCustomUnique) parts.add('UNIQUE');

    if (defaultValue != null && !hasCustomDefault) {
      parts.add('DEFAULT ${fluentSqlLiteral(defaultValue)}');
    }

    if (checkConstraint != null && !hasCustomCheck) {
      parts.add('CHECK ($checkConstraint)');
    }

    if (collation != null && !hasCustomCollate) {
      parts.add('COLLATE ${collation!.sql}');
    }

    final String sql = parts.join(' ');
    FluentLog.debug('Generated SQL definition for column "$name"', tag: 'FluentDbColumn', context: {'sql': sql});
    return sql;
  }

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentDbColumn{');
    final List<String> parts = [];

    parts.add('name: "$name"');
    parts.add('type: ${type.name}');

    if (isPrimaryKey) parts.add('isPK: true');
    if (isAutoIncrement) parts.add('isAutoIncrement: true');
    if (isNotNull) parts.add('isNotNull: true');
    if (isUnique) parts.add('isUnique: true');
    if (indexed) parts.add('indexed: true');
    if (autoCorrectAllowed) parts.add('autoCorrect: true');

    if (oldName != null) parts.add('oldName: "$oldName"');
    if (defaultValue != null) parts.add('defaultValue: $defaultValue');
    if (checkConstraint != null) parts.add('check: "$checkConstraint"');
    if (collation != null) parts.add('collate: ${collation!.name}');
    if (converter != null) parts.add('converter: ${converter.runtimeType}');
    if (customSql != null) parts.add('customSql: "$customSql"');

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}

/// Effective column rules the schema sync decides by (flags and `customSql` clauses). Internal: hidden from the
/// public API.
extension FluentDbColumnRules on FluentDbColumn {
  /// Whether the column is `NOT NULL`, by flag or by a clause in `customSql`.
  bool get effectiveNotNull => isNotNull || _customHas(FluentDbColumn._notNullRule);

  /// Whether the column is `UNIQUE`, by flag or by a clause in `customSql`.
  bool get effectiveUnique => isUnique || _customHas(FluentDbColumn._uniqueRule);

  /// Whether the column is a primary key, by flag or by a clause in `customSql`.
  bool get effectivePrimaryKey => isPrimaryKey || _customHas(FluentDbColumn._primaryKeyRule);

  /// Whether the column has a default value, by `defaultValue` or by a `DEFAULT` clause in `customSql`.
  bool get effectiveDefault => defaultValue != null || _customHas(FluentDbColumn._defaultRule);

  /// Whether the default is not a constant (an expression or `CURRENT_*`), so `ADD COLUMN` cannot use it.
  bool get hasExpressionDefault => defaultValue is FluentSqlExpression || _customHas(FluentDbColumn._expressionDefaultRule);

  /// The column without its `NOT NULL` rule (flag and `customSql` clause), as used by a pending NOT NULL column.
  FluentDbColumn get withoutNotNull {
    final String? custom = customSql;
    if (custom == null || !FluentDbColumn._notNullRule.hasMatch(custom)) return copyWith(isNotNull: false);
    return copyWith(isNotNull: false, customSql: custom.replaceAll(FluentDbColumn._notNullRule, ' ').replaceAll(RegExp(r'\s+'), ' ').trim());
  }
}
