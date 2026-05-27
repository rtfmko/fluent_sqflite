// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../core/core.dart';
import '../exceptions/exceptions.dart';
import '../utils/utils.dart';

/// Represents a structural definition of a database column.
///
/// [FluentDbColumn] serves as the metadata container that instructs the provider
/// how to map a Dart class field to a physical SQLite table column, including
/// constraints, indexes, and default values.
class FluentDbColumn {
  /// The physical column name in the database.
  final String name;

  /// The SQLite data type (e.g., TEXT, INTEGER, REAL, BLOB).
  FluentDbDataType type;

  /// The previous name of the column, used for automated migration handling
  /// (renaming columns) without data loss.
  final String? oldName;

  /// Custom SQL snippet for specialized column definitions.
  ///
  /// If provided, this string is appended to the column definition during
  /// schema creation.
  String? customSql;

  /// Whether this column acts as the primary key for the table.
  bool isPrimaryKey;

  /// Whether the database should automatically increment this column's value.
  ///
  /// Only applicable to [FluentDbDataType.integer] types.
  final bool isAutoIncrement;

  /// Whether the column constraint `NOT NULL` should be applied.
  final bool isNotNull;

  /// Whether the column constraint `UNIQUE` should be applied.
  final bool isUnique;

  /// The default value expression (e.g., "CURRENT_TIMESTAMP" or "'active'").
  final String? defaultValue;

  /// An optional `CHECK` constraint (e.g., "age > 0").
  final String? checkConstraint;

  /// Whether to create a secondary index on this column for faster lookups.
  bool indexed;

  /// Indicates if the framework is permitted to attempt type or name corrections
  /// during automated migration sequences.
  final bool autoCorrectAllowed;

  /// Cached DDL definition to optimize runtime performance during schema initialization.
  String? _cachedSqlDefinition;

  /// Constructs a [FluentDbColumn] and performs strict schema validation.
  ///
  /// The constructor enforces database integrity rules at the model-definition
  /// stage, ensuring that constraints and SQL types are logically compatible.
  ///
  /// ### Validation Rules:
  /// * **Name Integrity:** Ensures the column name is non-empty.
  /// * **Type Constraints:** Prevents `AUTOINCREMENT` on non-INTEGER columns.
  /// * **Custom SQL Validation:** Ensures that if [FluentDbDataType.custom] is used,
  ///   the provided SQL snippet either starts with a valid SQLite type or includes
  ///   a `REFERENCES` clause for foreign key definitions.
  ///
  /// @throws [FluentSchemaException] if the [customSql] provided does not adhere to
  /// expected SQLite type/reference syntax.
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
  }) {
    assert(name.isNotEmpty, "Column name cannot be empty. Check your model's missingColumns or buildJson.");

    if (isAutoIncrement && type != FluentDbDataType.integer) {
      FluentLog.warning('Invalid constraint: AUTOINCREMENT set on non-INTEGER column "$name".', tag: 'FluentDbColumn', hint: 'AUTOINCREMENT is only valid for INTEGER primary keys in SQLite.');
      assert(!isAutoIncrement, "AUTOINCREMENT can only be used with INTEGER type");
    }

    if (type == FluentDbDataType.custom && customSql != null) {
      final upperSql = customSql!.toUpperCase().trim();
      final allowedTypes = ['INTEGER', 'TEXT', 'REAL', 'BLOB', 'NUMERIC', 'BOOLEAN', 'TIMESTAMP'];

      final bool isValid = allowedTypes.any((t) => upperSql.startsWith(t)) || upperSql.contains('REFERENCES');

      if (!isValid) {
        final String errorMsg = "Invalid customSql: '$customSql'. Must start with a valid SQLite type (TEXT, INTEGER, etc.)";

        FluentLog.error(
          'Schema validation failed for column "$name"',
          FluentSchemaException(modelName: "Unknown", columnName: name, details: errorMsg),
          StackTrace.current,
          tag: 'FluentDbColumn',
        );
        throw FluentSchemaException(modelName: "Unknown", columnName: name, details: errorMsg);
      }
    }
  }

  /// Creates a standard auto-incrementing Primary Key column.
  /// Defaults to column name 'id' if not specified.
  static FluentDbColumn primary({String? name}) => FluentDbColumn(name: name ?? 'id', type: FluentDbDataType.integer, isPrimaryKey: true, isAutoIncrement: true);

  /// Creates a text-based column.
  static FluentDbColumn text(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.text, isNotNull: isNotNull);

  /// Creates an integer-based column.
  static FluentDbColumn integer(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.integer, isNotNull: isNotNull);

  /// Creates a floating-point/real number column.
  static FluentDbColumn real(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.real, isNotNull: isNotNull);

  /// Creates a boolean column (stored as INTEGER for SQLite compatibility).
  static FluentDbColumn boolean(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.integer, isNotNull: isNotNull);

  /// Creates a timestamp column (stored as BLOB for high-precision or custom formats)
  static FluentDbColumn timestamp(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.blob, isNotNull: isNotNull);

  /// Creates a BLOB (Binary Large Object) column.
  static FluentDbColumn blob(String name, {bool isNotNull = false}) => FluentDbColumn(name: name, type: FluentDbDataType.blob, isNotNull: isNotNull);

  /// Returns the mandatory system-level columns for every managed table.
  /// Used for internal lifecycle management and record expiration tracking.
  static List<FluentDbColumn> systemColumns(String expiryColumnName) => [systemMetadata(), systemExpiryDate(expiryColumnName)];

  /// System column for internal state tracking.
  /// Marked as [autoCorrectAllowed: false] to prevent schema drift.
  static FluentDbColumn systemMetadata() => FluentDbColumn(name: '_fs_metadata', type: FluentDbDataType.text, autoCorrectAllowed: false);

  /// System column for automated data expiration.
  static FluentDbColumn systemExpiryDate(String name) => FluentDbColumn(name: name, type: FluentDbDataType.integer, autoCorrectAllowed: false);

  /// Generates the SQL column definition string used for table creation (DDL).
  ///
  /// This method constructs a valid SQLite column definition by evaluating
  /// property attributes ([isPrimaryKey], [isAutoIncrement], etc.) and
  /// reconciling them against any [customSql] provided. It implements a
  /// caching mechanism to prevent expensive string reconstructions.
  ///
  /// ### Logic Flow:
  /// 1. Priority is given to [customSql] if defined.
  /// 2. If no [customSql] exists or type info is missing, it injects the appropriate `DbDataType`.
  /// 3. It checks for existing constraints (PK, AI, NOT NULL, UNIQUE) within the custom
  ///    string to prevent redundant/conflicting SQL keywords.
  /// 4. Falls back to default constraints if not already handled by [customSql].
  String get sqlDefinition {
    if (_cachedSqlDefinition != null) {
      return _cachedSqlDefinition!;
    }

    final List<String> parts = [name];
    final String? trimmedCustom = customSql?.trim();

    // Reconcile custom SQL with standard type definitions
    if (trimmedCustom != null && trimmedCustom.isNotEmpty) {
      final String upperCustom = trimmedCustom.toUpperCase();
      final bool hasTypeInCustom = upperCustom.startsWith('TEXT') || upperCustom.startsWith('INTEGER') || upperCustom.startsWith('REAL') || upperCustom.startsWith('BLOB');

      if (!hasTypeInCustom && type != FluentDbDataType.custom) {
        parts.add(type.sql);
      }
      parts.add(trimmedCustom);
    } else {
      parts.add(type.sql);
    }

    // Constraint validation to prevent SQL syntax errors from redundant keywords
    final bool hasCustomPk = trimmedCustom != null && trimmedCustom.toUpperCase().contains('PRIMARY KEY');
    final bool hasCustomAi = trimmedCustom != null && trimmedCustom.toUpperCase().contains('AUTOINCREMENT');
    final bool hasCustomNotNull = trimmedCustom != null && trimmedCustom.toUpperCase().contains('NOT NULL');
    final bool hasCustomUnique = trimmedCustom != null && trimmedCustom.toUpperCase().contains('UNIQUE');

    if (isPrimaryKey && !hasCustomPk) {
      parts.add('PRIMARY KEY');
      if (isAutoIncrement && type == FluentDbDataType.integer && !hasCustomAi) {
        parts.add('AUTOINCREMENT');
      }
    }

    if (isNotNull && !isPrimaryKey && !hasCustomNotNull) parts.add('NOT NULL');
    if (isUnique && !isPrimaryKey && !hasCustomUnique) parts.add('UNIQUE');

    _cachedSqlDefinition = parts.join(' ');
    FluentLog.debug('Generated SQL definition for column "$name"', tag: 'FluentDbColumn', context: {'sql': _cachedSqlDefinition});
    return _cachedSqlDefinition!;
  }

  @override
  String toString() {
    return 'FluentDbColumn{name: $name, type: $type, oldName: $oldName, customSql: $customSql, isPrimaryKey: $isPrimaryKey, isAutoIncrement: $isAutoIncrement, isNotNull: $isNotNull, isUnique: $isUnique, defaultValue: $defaultValue, checkConstraint: $checkConstraint}';
  }
}
