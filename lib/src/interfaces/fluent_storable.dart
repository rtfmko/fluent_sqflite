// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../fluent_sqflite.dart';
import '../core/fluent_sqlite_internal.dart';

/// The base abstract class for all database-persistable entities.
///
/// [FluentStorable] defines the contract for models that can be stored in the
/// database, providing mechanisms for schema inference, dynamic field storage,
/// relationship management, and data lifecycle tracking (expiry).
abstract class FluentStorable {
  /// The column name used to track record expiration, default is "expiry_date".
  ///
  /// This field enables the engine to automatically identify and prune
  /// expired records based on your defined business logic (e.g., cache TTL,
  /// temporary sessions, or expiring feature flags).
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Override to specify a custom column for TTL tracking
  /// @override
  /// String get expiryColumn => "session_expires_at";
  /// ```
  String get expiryColumn => "expiry_date";

  /// Internal cache mapping model [Type]s to their resolved [FluentDbColumn] schema.
  static final Map<Type, List<FluentDbColumn>> _schemaCache = {};

  /// Defines the primary key column configuration for the model.
  ///
  /// This method allows full control over the primary key's identity, including
  /// its name, data type, and auto-increment behavior.
  ///
  /// Defaults to an integer 'id' column with [isAutoIncrement] enabled.
  /// Override this in your [FluentStorable] model to customize the primary key
  /// (e.g., for tables with external IDs or non-integer keys).
  ///
  /// ### Usage Examples:
  ///
  /// **Using a custom ID name:**
  /// ```dart
  /// @override
  /// FluentDbColumn get primaryKey => FluentDbColumn(
  ///   name: 'user_uuid',
  ///   type: FluentDbDataType.text,
  ///   isPrimaryKey: true,
  /// );
  /// ```
  ///
  /// **Disabling Auto-Increment (for backend-generated IDs):**
  /// ```dart
  /// @override
  /// FluentDbColumn get primaryKey => FluentDbColumn(
  ///   name: 'id',
  ///   type: FluentDbDataType.integer,
  ///   isPrimaryKey: true,
  ///   isAutoIncrement: false,
  /// );
  /// ```
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true, isAutoIncrement: true);

  /// Retrieves the physical value of the primary key for this instance.
  ///
  /// **Automatic Fallback:** By default, this dynamically extracts the value
  /// using `buildJson()[primaryKey.name]`. This provides maximum convenience
  /// without requiring manual boilerplate in every model.
  ///
  /// **Performance Tip:** For high-frequency operations (like bulk deletes or
  /// mass updates), override this getter in your model to return the ID directly
  /// (e.g., `=> id;`). This bypasses JSON serialization and achieves O(1) zero-allocation performance.
  dynamic get primaryKeyValue {
    final Map<String, dynamic> json = buildJson();
    return json[primaryKey.name];
  }

  /// Provides a mapping for Enum fields to ensure proper database serialization.
  ///
  /// This map tells the [FluentProvider] which [Enum] type corresponds to each
  /// database column, enabling automatic conversion between database values
  /// (int or string) and Dart [Enum] instances.
  ///
  /// ### Usage Example:
  /// ```dart
  /// enum UserStatus { active, inactive, banned }
  /// enum UserRole { admin, editor, guest }
  ///
  /// class User extends FluentStorable {
  ///   @override
  ///   Map<String, List<Enum>> get enumValues => {
  ///     'status': UserStatus.values,
  ///     'role': UserRole.values,
  ///   };
  /// }
  /// ```
  ///
  /// **Note:** Ensure that `tableConfig.storeEnumsAsNames` matches your
  /// database schema strategy. If `true`, the engine expects and stores
  /// string representations (e.g., 'active'). If `false` (default), it
  /// uses the enum index (e.g., `0`).
  Map<String, List<Enum>> get enumValues => {};

  /// Defines columns that should be manually included in the schema, overriding
  /// automatic inference or adding fields not present in `buildJson()`.
  ///
  /// This is useful for columns managed exclusively by database triggers,
  /// default value constraints, or legacy fields that you do not want to map
  /// to your Dart entity class.
  ///
  /// ### Usage Example:
  /// ```dart
  /// @override
  /// List<FluentDbColumn> get missingColumns => [
  ///   // Include a column that is populated by a SQLite trigger
  ///   FluentDbColumn(
  ///     name: 'last_modified_timestamp',
  ///     type: FluentDbDataType.integer,
  ///     isNullable: false,
  ///     defaultValue: 'CURRENT_TIMESTAMP',
  ///   ),
  ///   // Include a hidden indexing column
  ///   FluentDbColumn.text('search_vector_idx'),
  /// ];
  /// ```
  List<FluentDbColumn> get missingColumns => [];

  /// Stores internal file-system or synchronization metadata.
  @internal
  final Map<String, dynamic> fsMetadataInternal = {};

  /// Tracks relationship keys that have not yet been fetched from the database.
  @internal
  final Set<String> unloadedRelations = {};

  /// Checks if a field has been loaded into memory.
  bool isFieldLoaded(String key) => !unloadedRelations.contains(key);

  /// Internal storage for fields not explicitly defined in the model structure.
  final Map<String, dynamic> _dynamicStore = {};

  /// Retrieves a dynamic/runtime-only field by key, with type casting.
  R? getDynamicValue<R>(String key) => _dynamicStore[key] as R?;

  /// List of [FluentDbMigration] objects associated with this model's schema evolution.
  ///
  /// Override this getter to define incremental structural changes to your database table.
  /// The [FluentDb] orchestrator will automatically iterate through these definitions,
  /// applying new columns and executing custom SQL commands to keep the schema in sync.
  ///
  /// ### Usage Example:
  /// ```dart
  /// @override
  /// List<FluentDbMigration> get migrations => [
  ///   // Migration step for version 2: Adding new metadata columns
  ///   FluentDbMigration(
  ///     columns: [
  ///       FluentDbColumn(name: 'age', type: FluentDbDataType.integer, isNotNull: false),
  ///       FluentDbColumn(name: 'bio', type: FluentDbDataType.text, isNotNull: true),
  ///     ],
  ///   ),
  /// ];
  /// ```
  List<FluentDbMigration> get migrations => const [];

  /// The timestamp when this record expires.
  ///
  /// If set, the [FluentEngine] will automatically filter or prune this
  /// record once the current time exceeds this value.
  DateTime? expiryDate;

  /// The duration after which this record should be considered expired.
  ///
  /// Override this getter to define a default Time-To-Live (TTL) for instances
  /// of this model. When initializing a new record, the engine can use this
  /// to automatically calculate the [expiryDate].
  Duration? expiryDuration;

  /// Internal storage for loaded relational data.
  final Map<String, dynamic> _extras = {};

  /// Retrieves a related entity by its key.
  dynamic getRelation(String key) => _extras[key];

  /// Initializes the base database-storable entity.
  ///
  /// This constructor allows for immediate definition of TTL (Time-To-Live)
  /// properties, which are used by the persistence layer to automatically
  /// expire or invalidate records.
  ///
  /// [expiryDate] A specific point in time after which this record is considered stale.
  /// [expiryDuration] A relative time span used to calculate the expiration
  /// starting from the moment of record creation or last update.
  FluentStorable({this.expiryDate, this.expiryDuration});

  /// Stores a temporary, runtime-only field that is not persisted in the database.
  ///
  /// This is useful for UI state, calculated properties, or transient data
  /// that should exist on the model instance but not in the schema.
  @internal
  void setDynamicField(String key, dynamic value) {
    _dynamicStore[key] = value;
    FluentLog.debug('Dynamic field updated', tag: 'FluentStorable:setDynamic', context: {'key': key});
  }

  /// Marks a collection of relationship keys as "unloaded" (lazy-loading).
  ///
  /// The [FluentProvider] will use this to track which relationships need to be
  /// fetched on-demand when accessed by the application.
  @internal
  void setUnloaded(List<String> keys) {
    unloadedRelations.addAll(keys);
    FluentLog.debug('Relations marked as unloaded', tag: 'FluentStorable:setUnloaded', context: {'keys': keys.join(', ')});
  }

  /// Injects a resolved entity into the internal storage.
  ///
  /// This is typically called by the [FluentProvider] after a lazy-load operation
  /// successfully fetches the related model from the database.
  @internal
  void setRelation(String key, dynamic data) {
    _extras[key] = data;
    FluentLog.debug('Relation injected', tag: 'FluentStorable:setRelation', context: {'key': key});
  }

  /// Injects a raw identifier or foreign key into the internal metadata storage.
  ///
  /// Useful for tracking internal synchronization state or foreign key references
  /// that are not part of the primary model's data payload.
  @internal
  void injectRelationId(String key, dynamic value) {
    fsMetadataInternal[key] = value;
    FluentLog.debug('Internal relation ID injected', tag: 'FluentStorable:injectRelation', context: {'key': key, 'value': value});
  }

  /// Generates the full database schema for the current model.
  ///
  /// This method performs a multi-step resolution process:
  /// 1. **Cache Lookup:** Returns cached schema if available for the type.
  /// 2. **Inference:** Iterates through `buildJson()` to infer types for standard fields.
  /// 3. **Validation:** Identifies ambiguous fields and triggers a schema report if fields cannot be typed.
  /// 4. **Merge:** Combines inferred columns with explicit `missingColumns` definitions,
  ///    ensuring `missingColumns` take precedence to allow for schema overrides.
  /// 5. **Persistence:** Caches the final schema for subsequent calls.
  List<FluentDbColumn> get tableSchema {
    final Type currentType = runtimeType;
    if (_schemaCache.containsKey(currentType)) {
      return _schemaCache[currentType]!;
    }

    final Map<String, dynamic> json = buildJson();
    final FluentDbColumn pkColumn = primaryKey;
    final String pkName = pkColumn.name;
    final List<FluentDbColumn> detected = [pkColumn];
    final List<Map<String, String>> unknownFields = [];

    // Infer column types based on the structure returned by buildJson()
    json.forEach((key, value) {
      if (key == pkName) return;

      try {
        detected.add(_inferColumnType(key, value));
      } catch (e) {
        unknownFields.add({'field': key, 'type': value.runtimeType.toString()});
      }
    });

    // Validate fields that could not be inferred
    if (unknownFields.isNotEmpty) {
      final Set<String> missingKeys = missingColumns.map((e) => e.name).toSet();
      final List<Map<String, String>> actuallyUnknown = unknownFields.where((f) => !missingKeys.contains(f['field'])).toList();

      if (actuallyUnknown.isNotEmpty) {
        FluentLog.info('  🔎 ${actuallyUnknown.length} ambiguous field(s) found. Generating Schema Report...', tag: 'FluentStorable:tableSchema');
        _throwSchemaReport(actuallyUnknown);
      }
    }

    // Merge inferred columns with explicit definitions, handling duplicates
    final Map<String, FluentDbColumn> uniqueColumns = {};

    for (final FluentDbColumn column in detected) {
      uniqueColumns[column.name] = column;
    }

    for (final FluentDbColumn column in missingColumns) {
      if (uniqueColumns.containsKey(column.name)) {
        FluentLog.warning(
          'Duplicate column "${column.name}" detected in model "$currentType".',
          tag: 'FluentStorable:tableSchema',
          hint:
              'This field exists in buildJson() AND missingColumns. '
              'If you wanted to override the type, keep it in missingColumns only.',
        );
      }
      uniqueColumns[column.name] = column;
    }

    final List<FluentDbColumn> finallySchema = uniqueColumns.values.toList();

    FluentLog.debug(
      'Schema CREATED for $currentType.',
      tag: 'FluentStorable:tableSchema',
      context: {'model': currentType.toString(), 'columns': finallySchema.map((c) => "${c.name}(${c.type.name})").join(', ')},
    );

    _schemaCache[currentType] = finallySchema;
    return finallySchema;
  }

  /// Clears the global schema cache for all [FluentStorable] models.
  ///
  /// This method is intended for use in test suites to ensure a clean state
  /// between individual test runs, preventing cross-test interference
  /// caused by cached schema definitions.
  @visibleForTesting
  static void clearSchemaCache() {
    _schemaCache.clear();
  }

  /// Infers the database column definition based on the runtime type of a value.
  ///
  /// This method serves as the core type-mapper for the schema builder. It
  /// maps common Dart primitives to their corresponding SQLite [FluentDbDataType]
  /// counterparts.
  ///
  /// ### Logic:
  /// - **Primary Keys:** Specifically handled to enforce auto-incrementing integers or text IDs.
  /// - **Primitives:** Maps Dart types (`int`, `double`, `bool`, `DateTime`, `String`) to standard SQL types.
  /// - **Collections & Complex:** Maps `List`, `Map`, `Enum`, `Uri`, etc., to `TEXT`.
  ///
  /// @throws [FluentSchemaException] if the type is unrecognized, prompting the
  /// user to define it explicitly in `missingColumns`.
  FluentDbColumn _inferColumnType(String key, dynamic value) {
    // --- Direct type-to-SQL mapping (Primitives) ---
    if (value is int) return FluentDbColumn.integer(key);
    if (value is double) return FluentDbColumn.real(key);
    if (value is bool) return FluentDbColumn.boolean(key);
    if (value is DateTime) return FluentDbColumn.timestamp(key);
    if (value is String) return FluentDbColumn.text(key);
    if (value is Uint8List) return FluentDbColumn.blob(key);

    // --- Dart Core Types ---
    if (value is Duration) return FluentDbColumn.integer(key);
    if (value is BigInt) return FluentDbColumn.text(key);
    if (value is RegExp) return FluentDbColumn.text(key);
    if (value is Uri) return FluentDbColumn.text(key);

    // --- Flutter Specific Types ---
    if (value is Color) return FluentDbColumn.integer(key);
    if (value is Locale) return FluentDbColumn.text(key);
    if (value is TimeOfDay) return FluentDbColumn.text(key);

    // --- Collections & Enums ---
    // Serialized as TEXT (JSON or String representation)
    if (value is List || value is Map || value is Enum) {
      return FluentDbColumn.text(key);
    }

    throw FluentSchemaException(
      modelName: runtimeType.toString(),
      columnName: key,
      details:
          'Unknown SQL type for field "$key" (${value.runtimeType}). '
          'Please define this column explicitly in missingColumns.',
      stackTrace: StackTrace.current,
    );
  }

  /// Generates a comprehensive, human-readable schema diagnostic report and
  /// throws a [FluentSchemaException] to halt execution.
  ///
  /// This method is triggered when the schema inference engine encounters
  /// fields with unknown types, ensuring that the developer is alerted
  /// immediately with actionable "Quick Fix" code snippets.
  ///
  /// ### Report Contents:
  /// - **Table Summary:** Visual list of problematic fields.
  /// - **Action Suggestions:** Clear instructions on how to resolve the ambiguity.
  /// - **Code Generation:** Provides a ready-to-copy-paste `missingColumns`
  ///   override block for the specific model.
  void _throwSchemaReport(List<Map<String, String>> unknowns) {
    final StringBuffer buffer = StringBuffer();
    final String modelName = runtimeType.toString();

    const int lineWidth = 66;
    const String title = '🛡️ [FLUENT SQFLITE] DATABASE SCHEMA DIAGNOSTICS 🛡️';

    const int paddingCount = (lineWidth - title.length - 2) ~/ 2;
    final String sidePadding = ' ' * paddingCount;

    const String extraSpace = (lineWidth - title.length - 2) % 2 == 0 ? '' : ' ';

    buffer.writeln('\n╔${'═' * (lineWidth - 2)}╗');
    buffer.writeln('║$sidePadding$title$sidePadding$extraSpace ║');
    buffer.writeln('╚${'═' * (lineWidth - 2)}╝');

    buffer.writeln('\n ⛔ HALT! SCHEMA INCOMPLETE');
    buffer.writeln(' 📦 Model:  $modelName');
    buffer.writeln(' 🔎 Status: Found ${unknowns.length} field(s) with ambiguous types.');

    buffer.writeln('\n 📋 MISSING FIELDS TABLE:');
    buffer.writeln(' ┌${'─' * 18}┬${'─' * 15}┬${'─' * 27}┐');
    buffer.writeln(' │ FIELD            │ DART TYPE     │ ACTION SUGGESTION         │');
    buffer.writeln(' ├${'─' * 18}┼${'─' * 15}┼${'─' * 27}┤');

    for (final Map<String, String> f in unknowns) {
      final rawKey = f['field'] ?? '';
      final displayName = rawKey.trim().isEmpty ? '[ EMPTY KEY ]' : rawKey;
      final name = displayName.padRight(16);
      final type = f['type']?.padRight(13);
      buffer.writeln(' │ $name │ $type │ Define in missingColumns  │');
    }
    buffer.writeln(' └${'─' * 18}┴${'─' * 15}┴${'─' * 27}┘');

    buffer.writeln('\n 💡 QUICK FIX (Copy & Paste to $modelName):');
    buffer.writeln(' ${'━' * (lineWidth - 2)}');
    buffer.writeln('  @override');
    buffer.writeln('  List<FluentDbColumn> get missingColumns => [');

    for (final Map<String, String> f in unknowns) {
      final rawKey = f['field'] ?? '';
      final fixName = rawKey.trim().isEmpty ? 'ENTER_NAME' : rawKey;
      final fixType = f['type'] == 'Null' ? 'text' : _mapDartTypeToMethod(f['type']);
      buffer.writeln("    FluentDbColumn.$fixType('$fixName'), // ⬅️ Replace $fixName with actual name!");
    }

    buffer.writeln('  ];');
    buffer.writeln(' ${'━' * (lineWidth - 2)}');

    buffer.writeln('\n ℹ️  Hint: Use FluentDbColumn.integer(), .real(), or .blob() if needed.');
    buffer.writeln('═' * lineWidth + '\n');

    throw FluentSchemaException(modelName: runtimeType.toString(), details: buffer.toString(), stackTrace: StackTrace.current);
  }

  /// Maps a Dart runtime type string to its corresponding [FluentDbColumn] factory method.
  ///
  /// This helper method is used by the diagnostic generator to suggest appropriate
  /// column definitions when the schema builder encounters unknown field types.
  ///
  /// ### Mapping Logic:
  /// - **Numbers/Complex (Int based):** `int`, `Color`, and `Duration` -> `integer`; `double` -> `real`.
  /// - **Booleans/Dates:** Map to `boolean` and `timestamp` respectively.
  /// - **Binary:** `Uint8List` maps to `blob` for efficient binary storage.
  /// - **Complex/Default:** `List`, `Map`, `String`, `Locale`, `Uri`, `TimeOfDay`,
  ///   and unknown types default to `text` (typically handled as serialized strings).
  String _mapDartTypeToMethod(String? dartType) {
    switch (dartType) {
      case 'int':
      case 'Color':
      case 'Duration':
        return 'integer';
      case 'double':
        return 'real';
      case 'bool':
        return 'boolean';
      case 'DateTime':
        return 'timestamp';
      case 'Uint8List':
        return 'blob';
      case 'List':
      case 'Map':
      case 'Null':
      case 'String':
      case 'Locale':
      case 'Uri':
      case 'TimeOfDay':
      default:
        return 'text';
    }
  }

  /// Converts the model instance into a map suitable for SQLite operations.
  ///
  /// This method should include fields defined in your table schema.
  /// The library automatically handles type conversion for:
  /// * **bool**: Converted to `1` or `0`.
  /// * **DateTime**: Converted to an ISO8601 string.
  /// * **List/Map**: Automatically encoded into a JSON string.
  ///
  /// **Note:** Do not include related models directly in this map.
  /// Complex objects will trigger an [InvalidSqlTypeException].
  ///
  /// **Example:**
  /// ```dart
  /// @override
  /// Map<String, dynamic> buildJson() => {
  ///   'id': id,
  ///   'title': title,
  ///   'is_completed': isCompleted, // Automatically handled as 1/0
  ///   'created_at': createdAt,     // Automatically handled as String
  ///   'tags': tags,                // Automatically JSON encoded
  /// };
  /// ```
  Map<String, dynamic> buildJson();

  /// A helper to restore a model from a database [json] while preserving metadata.
  ///
  /// 1. Uses the [creator] to build the model instance.
  /// 2. Automatically extracts and assigns the [expiryDate] from the map.
  static R fromJsonWithExpiry<R extends FluentStorable>(Map<String, dynamic> json, R Function(Map<String, dynamic>) creator) {
    final R model = creator(json);
    model.expiryDate = json.tryGetDateTime(model.expiryColumn);
    return model;
  }

  /// Helper to format the object's state in a clean, consistent way.
  /// Skips null values to keep logs readable.
  @protected
  String formatToString(Map<String, Object?> fields) {
    final StringBuffer sb = StringBuffer('$runtimeType{');
    final List<String> parts = [];

    fields.forEach((key, value) {
      if (value != null) {
        if (value is Iterable && value.isEmpty) return;
        if (value is Map && value.isEmpty) return;

        parts.add('$key: $value');
      }
    });

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }

  @override
  String toString() => formatToString({
    'expiryDate': expiryDate,
    'expiryDuration': expiryDuration,
    'unloadedRelations': unloadedRelations.isNotEmpty ? unloadedRelations : null,
    'dynamicFields': _dynamicStore.isNotEmpty ? _dynamicStore : null,
    'primaryKey': primaryKey,
  });
}
