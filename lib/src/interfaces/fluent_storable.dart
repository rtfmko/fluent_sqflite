// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:ui' show Color, Locale;

import 'package:flutter/foundation.dart';
// Only TimeOfDay comes from material; Color / Locale are dart:ui.
import 'package:flutter/material.dart' show TimeOfDay;

import '../internal.dart';

/// The base class of every stored model.
///
/// A model describes its table: the columns come from [buildJson] (types inferred from the values, see
/// [tableSchema]), keys from [primaryKey] / [primaryKeys], plus [indexes], [checks], [enumValues], [migrations] and
/// [tableConfig]. Mixins add soft delete (`FluentSoftDeletable`), timestamps (`FluentTimestamps`), relations
/// (`FluentRelations`) and sync (`FluentSyncable`). A `FluentProvider` reads and writes it.
///
/// ```dart
/// class Note extends FluentStorable {
///   Note({this.id, required this.title});
///
///   int? id;
///   String title;
///
///   @override
///   Map<String, dynamic> buildJson() => {'id': id, 'title': title};
/// }
/// ```
abstract class FluentStorable {
  /// The column that holds when a row expires (epoch milliseconds, set from [timeToLive]), default `expiry_date`.
  /// Every table has it; override the name when it collides with a field:
  /// `@override String get expiryColumn => 'session_expires_at';`.
  String get expiryColumn => "expiry_date";

  /// Internal cache mapping model [Type]s to their resolved [FluentDbColumn] schema.
  static final Map<Type, List<FluentDbColumn>> _schemaCache = {};

  /// The primary key column. Defaults to an auto-incremented INTEGER `id`; override it for another name, a text key
  /// or ids given by a server. For a composite key override [primaryKeys] instead.
  ///
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

  /// The primary key value of this instance (a [FluentKey] for composite keys).
  ///
  /// Taken from [buildJson]; when the field is still `null` because the database generated the id on insert,
  /// the generated id is returned — so a freshly saved model can be used for `loadRelations`, `attach`, deletes, ...
  ///
  /// **Performance:** the key columns are resolved once per instance, but [buildJson] runs on every call.
  /// In hot paths override it to return the field directly: `@override Object? get primaryKeyValue => id;`
  /// (keep a fallback to the generated id if your model is saved with `id: null`).
  dynamic get primaryKeyValue {
    final List<String> names = _keyColumnNames;
    if (names.length > 1) return key;
    final String name = names.first;
    return _keyValue(name, buildJson()[name]);
  }

  /// The value of key column [name]: [given] (from [buildJson]) wins, the kept value fills a `null`. A key the
  /// library replaced (a `conflictOn` save matched another row) wins while [buildJson] still returns the value it
  /// replaced; once the model's own key changes, the model wins again.
  Object? _keyValue(String name, Object? given) {
    final ({Object? replaced, Object? value})? forced = _forcedKeys[name];
    if (forced != null && given != null && fluentSameKeyValue(given, forced.replaced)) return forced.value;
    return given ?? _metadata[name];
  }

  static final Expando<List<String>> _keyNamesCache = Expando<List<String>>('fluentKeyColumnNames');

  /// Key column names, resolved once per instance ([primaryKeys] builds new column objects on every call).
  /// An empty [primaryKeys] falls back to `id`, like the provider does.
  List<String> get _keyColumnNames => _keyNamesCache[this] ??= switch (primaryKeys) {
    final List<FluentDbColumn> keys when keys.isNotEmpty => [for (final FluentDbColumn c in keys) c.name],
    _ => const ['id'],
  };


  /// The primary key columns of the table.
  ///
  /// Defaults to the single [primaryKey]. Override it to declare a **composite key**:
  /// ```dart
  /// @override
  /// List<FluentDbColumn> get primaryKeys => [
  ///   FluentDbColumn.integer('user_id'),
  ///   FluentDbColumn.text('day'),
  /// ];
  /// ```
  /// The columns are created as `PRIMARY KEY (user_id, day)`; they do not need to be marked with
  /// `isPrimaryKey`. A row is then addressed with a [FluentKey]:
  /// `FluentDb.findById<DailyStats>(FluentKey({'user_id': 7, 'day': '2026-10-20'}))`.
  List<FluentDbColumn> get primaryKeys => [primaryKey];

  /// The key of this instance, built from the values of [primaryKeys] in [buildJson].
  ///
  /// Override it to compute the key yourself (e.g. `FluentKey({'user_id': userId, 'day': day})`),
  /// which also avoids serializing the whole model.
  FluentKey get key {
    final Map<String, dynamic> json = buildJson();
    return FluentKey({for (final String name in _keyColumnNames) name: _keyValue(name, json[name])});
  }

  /// Additional indexes of the table: multi-column, unique or partial.
  ///
  /// ```dart
  /// @override
  /// List<FluentIndex> get indexes => [FluentIndex.unique(['email']), FluentIndex(['last_name', 'first_name'])];
  /// ```
  /// For a simple index on one column, `indexed: true` on the column is enough.
  List<FluentIndex> get indexes => const [];

  /// Settings of the table: how dates and enums are stored, and overrides of the database (`FluentGroup.config`) and
  /// global (`FluentDb.init(config:)`) settings — trash retention, reference indexes, full-text mode, background
  /// mapping. A value set here wins over the database's, which wins over the global one.
  ///
  /// ```dart
  /// @override
  /// FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 90));
  /// ```
  FluentTableConfig get tableConfig => const FluentTableConfig();

  /// Table-level `CHECK` constraints (applied when the table is created).
  List<FluentCheck> get checks => const [];

  /// Creates the table `WITHOUT ROWID` — smaller and faster for tables with a composite or text
  /// primary key that are looked up by key. Not compatible with `AUTOINCREMENT`.
  bool get withoutRowId => false;

  /// The enum type of each enum column (column -> `MyEnum.values`): such columns store and read their values through
  /// a `FluentEnumConverter`, so models and maps get enum values back. Without an entry, an enum field is read back
  /// as its stored name / index (a `schemaFallback` issue says so).
  ///
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
  /// Values are stored by name (`'active'`); with `FluentTableConfig(storeEnumsAsNames: false)` by index. Reading
  /// accepts both, so switching keeps old rows readable. Filters take the enum itself:
  /// `FluentFilter.eq('status', UserStatus.active)`.
  Map<String, List<Enum>> get enumValues => {};

  /// Columns declared explicitly: they replace the inferred column of the same `buildJson()` field (constraints,
  /// converters, or a type inference cannot tell, e.g. a field that is `null` in the provider's `modelSample`) or
  /// add columns the model has no field for (filled by defaults, triggers or raw SQL).
  ///
  /// ```dart
  /// @override
  /// List<FluentDbColumn> get missingColumns => [
  ///   FluentDbColumn.text('email', isUnique: true), // replaces the inferred 'email'
  ///   FluentDbColumn.text('nickname'),               // null in the sample: the type cannot be inferred
  ///   FluentDbColumn(name: 'created', type: FluentDbDataType.text, defaultValue: FluentSqlExpression.currentTimestamp),
  /// ];
  /// ```
  List<FluentDbColumn> get missingColumns => [];

  /// One-time migration steps of this table, run once per database in declaration order.
  ///
  /// Structural changes need no step: the schema is synchronized from the model on every start. Steps are for data
  /// changes and explicit drops; each needs a unique `version` or `id`, and an applied step must never be edited.
  ///
  /// ```dart
  /// @override
  /// List<FluentDbMigration> get migrations => [
  ///   FluentDbMigration(id: 'fill_status', rawSql: ["UPDATE posts SET status = 'draft' WHERE status IS NULL"]),
  ///   FluentDbMigration(version: 3, dropColumns: ['legacy_flag']),
  /// ];
  /// ```
  List<FluentDbMigration> get migrations => const [];

  /// How long the row lives after it is saved: once the time has passed, every read hides it and `clearExpired`
  /// (also run at start) deletes it. `null` (default): the save leaves the expiry alone — a new row never expires,
  /// an existing row keeps the expiry it has (a model read back has no `timeToLive`, so saving it again does not make
  /// it permanent). To make an existing row permanent, clear its expiry column:
  /// `provider.updateById(id, {'expiry_date': null})`.
  ///
  /// Set it per instance (`Session(token: t)..timeToLive = const Duration(hours: 1)`) or for the whole table:
  /// `@override Duration? get timeToLive => const Duration(days: 30);` (then every save extends the life).
  Duration? timeToLive;

  /// Values the library keeps for this instance (the key generated on insert, ...), never written as columns.
  final Map<String, dynamic> _metadata = {};

  /// Key values the library replaced, with the value of the model they replace (see [_keyValue]).
  final Map<String, ({Object? replaced, Object? value})> _forcedKeys = {};

  /// Relations that were not loaded when this instance was read (lazy ones, or reads with `relations: none`).
  final Set<String> _unloaded = {};

  /// Whether relation [name] was loaded when this instance was read (`false` for lazy relations and reads with
  /// `relations: FluentLoad.none`; load them with `loadRelations`).
  bool isRelationLoaded(String name) => !_unloaded.contains(name);

  /// Creates a model; [timeToLive] makes the row expire that long after it is saved.
  FluentStorable({this.timeToLive});

  /// The columns of the model (cached per model type): the [primaryKeys], a column per `buildJson()` field with its
  /// type inferred from the value (stored models are relations, not columns), and [missingColumns], which win over
  /// inferred columns of the same name. A field whose type cannot be inferred (e.g. `null`) and that is not in
  /// [missingColumns] throws a [FluentSchemaException] with a report and copy-paste `missingColumns` code.
  List<FluentDbColumn> get tableSchema {
    final Type currentType = runtimeType;
    if (_schemaCache.containsKey(currentType)) {
      return _schemaCache[currentType]!;
    }

    final Map<String, dynamic> json = buildJson();
    final List<FluentDbColumn> keyColumns = primaryKeys;
    final Set<String> keyNames = {for (final FluentDbColumn c in keyColumns) c.name};
    final List<FluentDbColumn> detected = [...keyColumns];
    final List<Map<String, String>> unknownFields = [];

    // Infer column types based on the structure returned by buildJson()
    json.forEach((key, value) {
      if (keyNames.contains(key)) return;
      // Other stored models are relations (declared, or found by the provider), never columns.
      if (value is FluentStorable || value is Iterable<FluentStorable>) return;

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
        FluentLog.debug('  🔎 ${actuallyUnknown.length} ambiguous field(s) found. Generating Schema Report...', tag: 'FluentStorable:tableSchema');
        _throwSchemaReport(actuallyUnknown);
      }
    }

    // Merge inferred columns with explicit definitions, handling duplicates
    final Map<String, FluentDbColumn> uniqueColumns = {};

    for (final FluentDbColumn column in detected) {
      uniqueColumns[column.name] = column;
    }

    // A column of missingColumns may replace the inferred definition of a buildJson field (the way to attach a
    // converter or a type): no warning. Only a name declared twice in missingColumns is a true duplicate.
    final Set<String> declared = {};
    for (final FluentDbColumn column in missingColumns) {
      if (!declared.add(column.name)) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Duplicate column "${column.name}" detected in model "$currentType".',
          tag: 'FluentStorable:tableSchema',
          hint:
              'The column "${column.name}" is declared twice in missingColumns(); the last declaration wins. '
              'Keep one definition.',
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

  /// The column of field [key] inferred from the runtime type of [value] (with its [FluentValueKind]); throws a
  /// [FluentSchemaException] for a type SQLite cannot store (and for `null`).
  FluentDbColumn _inferColumnType(String key, dynamic value) {
    // --- Direct type-to-SQL mapping (Primitives) ---
    if (value is int) return FluentDbColumn.integer(key);
    if (value is double) return FluentDbColumn.real(key);
    if (value is bool) return FluentDbColumn.boolean(key);
    if (value is DateTime) return FluentDbColumn.timestamp(key);
    if (value is String) return FluentDbColumn.text(key);
    if (value is Uint8List) return FluentDbColumn.blob(key);

    // --- Dart Core Types ---
    if (value is Duration) return FluentDbColumn.integer(key).copyWith(valueKind: FluentValueKind.duration);
    if (value is BigInt) return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.bigInt);
    if (value is RegExp) return FluentDbColumn.text(key);
    if (value is Uri) return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.uri);

    // --- Flutter Specific Types ---
    if (value is Color) return FluentDbColumn.integer(key).copyWith(valueKind: FluentValueKind.color);
    if (value is Locale) return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.locale);
    if (value is TimeOfDay) return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.timeOfDay);

    // --- Collections & Enums ---
    // Serialized as TEXT (JSON or String representation)
    if (value is List || value is Map) {
      return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.json);
    }
    if (value is Enum) {
      if (!enumValues.containsKey(key) && !missingColumns.any((FluentDbColumn c) => c.name == key)) {
        FluentLog.issue(
          FluentIssueKind.schemaFallback,
          'Enum field "$key" of $runtimeType is stored (by ${tableConfig.storeEnumsAsNames ? 'name' : 'index'}) but cannot be read back as ${value.runtimeType}: enumValues has no entry for it.',
          tag: 'FluentStorable:tableSchema',
          hint: 'Add it to enumValues (`{"$key": ${value.runtimeType}.values}`) or declare the column with '
              'FluentDbColumn.converted("$key", FluentEnumConverter(${value.runtimeType}.values)) in missingColumns.',
        );
      }
      return FluentDbColumn.text(key).copyWith(valueKind: FluentValueKind.enumValue);
    }

    throw FluentSchemaException(
      'Field "$key" of $runtimeType has a type SQLite cannot store: ${value.runtimeType}.',
      modelName: runtimeType.toString(),
      columnName: key,
      hint: "Declare the column in missingColumns, e.g. FluentDbColumn.text('$key'), or store it with a converter: "
          "FluentDbColumn.converted('$key', MyConverter()).",
    );
  }

  /// Throws a [FluentSchemaException] for the fields of [unknowns] whose type cannot be inferred; its hint is a
  /// report with a copy-paste `missingColumns` override.
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
    buffer.writeln(' ℹ️  A field that holds another stored model is a relation: give it a value in modelSample');
    buffer.writeln('    (e.g. posts: const [], author: Person(name: \'\')) or declare it in relations.');
    buffer.writeln('═' * lineWidth + '\n');

    throw FluentSchemaException(
      'The column types of ${unknowns.length} field(s) of $modelName cannot be inferred: ${unknowns.map((f) => f['field']).join(', ')}.',
      modelName: modelName,
      hint: buffer.toString(),
    );
  }

  /// The [FluentDbColumn] factory the schema report suggests for the Dart type name [dartType] (`text` by default).
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

  /// The fields of the model by column name, as Dart values; the table's columns are inferred from it.
  ///
  /// The library stores Dart values itself: `bool` as `1` / `0`, `DateTime` as epoch milliseconds (ISO text with
  /// `FluentTableConfig.dateTimeFormat`), enums by name, `List` / `Map` as JSON, and `Duration`, `BigInt`, `Uri`,
  /// `Color`, `Locale`, `TimeOfDay`; columns with a converter go through it. Fields holding other stored models (one
  /// or a list) are relations (declared in `FluentRelations.relations`, or found automatically), never columns.
  /// Values of other types fail on save with a [FluentArgumentException] ([FluentErrorCode.unsupportedValue]).
  /// Library columns (soft-delete stamp, timestamps, sync versions) are written by the library, not from here.
  ///
  /// **Example:**
  /// ```dart
  /// @override
  /// Map<String, dynamic> buildJson() => {
  ///   'id': id,
  ///   'title': title,
  ///   'is_completed': isCompleted, // stored as 1 / 0
  ///   'due': due,                  // DateTime, stored as epoch milliseconds
  ///   'tags': tags,                // List<String>, stored as JSON
  /// };
  /// ```
  Map<String, dynamic> buildJson();

  /// `Type{key: value, ...}` of [fields] for `toString`, without `null` and empty values.
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
    'timeToLive': timeToLive,
    'unloadedRelations': _unloaded.isNotEmpty ? _unloaded : null,
    'key': primaryKeyValue,
  });
}

/// Members the library itself uses; not part of the public API.
extension FluentStorableInternals on FluentStorable {
  /// Values the library keeps for this instance (e.g. the key generated on insert).
  Map<String, dynamic> get metadata => _metadata;

  /// Relations that were not loaded when this instance was read.
  Set<String> get unloadedRelations => _unloaded;

  /// Remembers [value] of column [key] that the model has no field for (the generated id, a reference column).
  void injectRelationId(String key, Object? value) => _metadata[key] = value;

  /// The stored row of this instance has key [value] in column [key] although the model carries [replaced] (a
  /// `conflictOn` save matched another row): reads of the key and later saves use [value] while the model still
  /// carries [replaced].
  void forceKey(String key, Object? value, {required Object? replaced}) {
    _metadata[key] = value;
    _forcedKeys[key] = (replaced: replaced, value: value);
  }

  /// The key value of column [name] given the [buildJson] value [given] (forced and generated keys applied).
  Object? keyValueOf(String name, Object? given) => _keyValue(name, given);

  /// A function that puts the kept value of key column [key] (generated / forced key) back as it is now: undoes a
  /// later [injectRelationId] / [forceKey] of a write that is rolled back.
  void Function() keyRestorer(String key) {
    final bool had = _metadata.containsKey(key);
    final Object? value = _metadata[key];
    final ({Object? replaced, Object? value})? forced = _forcedKeys[key];
    return () {
      had ? _metadata[key] = value : _metadata.remove(key);
      forced == null ? _forcedKeys.remove(key) : _forcedKeys[key] = forced;
    };
  }
}

/// Whether two key values are the same key (`1` and `'1'` too: SQLite affinity stores them alike).
bool fluentSameKeyValue(Object? a, Object? b) => a == b || '$a' == '$b';
