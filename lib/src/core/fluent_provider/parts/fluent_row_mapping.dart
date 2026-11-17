// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// A warning found while building a model (logged on the UI isolate, also when the work ran in a background one).
typedef _MappingWarning = ({String message, String hint});

/// Everything needed to turn stored rows of one table into models — without the provider, so it can be sent to a
/// background isolate. The UI isolate uses the same plan, so both paths behave exactly alike.
class _FluentRowPlan<T extends FluentStorable> {
  _FluentRowPlan({
    required this.table,
    required this.modelName,
    required this.kinds,
    required this.converters,
    required this.enumValues,
    required this.linkNames,
    required this.factory,
    Map<String, String>? seenTags,
  }) : _seenTags = seenTags ?? {};

  final String table;
  final String modelName;

  /// Column → codec tag of its value kind (`FluentValueKind.tag`); columns with a converter are not listed.
  final Map<String, String> kinds;
  final Map<String, FluentConverter<Object?, Object?>> converters;
  final Map<String, List<Enum>> enumValues;
  final List<String> linkNames;
  final T Function(Map<String, dynamic> json) factory;

  /// Column → the tag the last intact `_fs_metadata` gave it (that is where a `DateTime`'s UTC flag lives): a row
  /// whose metadata is damaged takes the tags of its columns from here before falling back to the column kinds.
  final Map<String, String> _seenTags;

  _FluentRowPlan<T> withFactory(T Function(Map<String, dynamic> json) other) => _FluentRowPlan<T>(
    table: table,
    modelName: modelName,
    kinds: kinds,
    converters: converters,
    enumValues: enumValues,
    linkNames: linkNames,
    factory: other,
    seenTags: _seenTags,
  );

  /// Columns already reported for short ISO text (once per plan).
  final Set<String> _shortIsoReported = {};

  /// ISO text with a three-digit fraction was written by earlier versions (the library writes six digits now): next to
  /// new values it sorts and compares wrongly within one millisecond. Reported once per column, with the statement
  /// that rewrites the values.
  void _checkShortIso(String column, String value, List<_MappingWarning> warnings) {
    if (!FluentTypeCodecs.isShortIso(value) || !_shortIsoReported.add(column)) return;
    final String c = column.quotedIdentifier;
    final String dot = "instr($c, '.')";
    warnings.add((
      message: 'The ISO-8601 text of "$table.$column" has a three-digit fraction (written by an earlier version, e.g. "$value"); the library writes six digits now, so old and new values compare and sort wrongly within one millisecond.',
      hint: 'Rewrite the old values once (a FluentDbMigration rawSql step): UPDATE ${table.quotedIdentifier} SET $c = substr($c, 1, $dot + 3) || \'000\' || substr($c, $dot + 4) '
          "WHERE $c GLOB '*.[0-9][0-9][0-9]' OR $c GLOB '*.[0-9][0-9][0-9]Z'.",
    ));
  }

  /// `"column":"tag"` pairs that are still readable in damaged metadata (e.g. text cut off in the middle).
  static final RegExp _tagPair = RegExp(r'"((?:[^"\\]|\\.)*)"\s*:\s*"([a-z_]+)"');

  /// Builds the model of [row] (relation values already typed); problems that do not stop it go to [warnings].
  T build(Map<String, dynamic> row, List<_MappingWarning> warnings) {
    // The reader's bookkeeping of unloaded relations is applied after the factory: fromCacheJson never sees it.
    final Object? unloaded = row['_unloaded_relations'];
    final Map<String, dynamic> json = decodeRow(unloaded == null ? row : (Map<String, dynamic>.of(row)..remove('_unloaded_relations')), warnings);
    final T model;
    try {
      model = factory(json);
    } on FluentException {
      rethrow;
    } catch (e, st) {
      // Any failure of the app's factory (a cast, a FormatException, a StateError, ...) arrives typed, with the
      // received value types.
      final String types = json.entries.map((e) => '${e.key}: ${e.value.runtimeType}').join(', ');
      throw FluentSchemaException(
        'Building $modelName from "$table" failed: ${FluentLog.redact('$e')}\nReceived: {$types}',
        modelName: modelName,
        hint: e is TypeError
            ? 'Read values with the types listed above. JSON lists/maps arrive as List<dynamic> / Map<String, dynamic>: use '
                  '(json["tags"] as List?)?.cast<String>(). Enums without enumValues arrive as their stored value (String, or int with storeEnumsAsNames: false). Nullable columns need `as T?`.'
            : 'fromCacheJson of the provider (or its isolateFactory) threw for this row; the values it received are listed above.',
        cause: e,
        stackTrace: st,
      );
    }

    // The soft-delete stamp and the timestamps are library state: models get them without reading them themselves.
    if (model is FluentSoftDeletable) {
      final Object? stamp = json[(model as FluentSoftDeletable).softDeleteColumn];
      (model as FluentSoftDeletable).deletedAt = stamp is DateTime ? stamp : null;
    }
    if (model is FluentTimestamps) {
      final FluentTimestamps timed = model as FluentTimestamps;
      final Object? created = json[timed.createdAtColumn];
      final Object? updated = json[timed.updatedAtColumn];
      timed
        ..createdAt = created is DateTime ? created : null
        ..updatedAt = updated is DateTime ? updated : null;
    }
    if (unloaded is Iterable) model.unloadedRelations.addAll(unloaded.cast<String>());
    return model;
  }

  /// [row] with Dart values (type tags, enums, converters) and without internal columns (type metadata, archived
  /// columns). Used for models and for maps (`findMaps`, `pluck`, aggregates).
  Map<String, dynamic> decodeRow(Map<String, dynamic> row, List<_MappingWarning> warnings) {
    Map<String, dynamic> json = _restoreTypes(row, warnings);

    // Column converters (stored value → Dart value).
    if (converters.isNotEmpty) {
      bool copied = false;
      for (final MapEntry<String, FluentConverter<Object?, Object?>> entry in converters.entries) {
        if (!json.containsKey(entry.key)) continue;
        if (!copied) {
          json = Map<String, dynamic>.from(json);
          copied = true;
        }
        json[entry.key] = _decodeConverted(entry.key, entry.value, json[entry.key], warnings);
      }
    }

    // Internal columns never reach the caller: type metadata and archived (removed) columns.
    if (json.keys.any(FluentProvider._isInternalColumn)) {
      json = {for (final MapEntry<String, dynamic> e in json.entries) if (!FluentProvider._isInternalColumn(e.key)) e.key: e.value};
    }
    return json;
  }

  /// One stored [value] of [column] as a Dart value (by its converter, the type tags of its row's [metadata]
  /// (`_fs_metadata`), enum values or value kind).
  Object? decodeValue(String column, Object? value, List<_MappingWarning> warnings, {Object? metadata}) {
    if (value == null) return null;
    final FluentConverter<Object?, Object?>? converter = converters[column];
    if (converter != null) return _decodeConverted(column, converter, value, warnings);
    final bool tagged = metadata is String && metadata.isNotEmpty;
    if (kinds[column] == null && !tagged) return value;
    return _restoreTypes({column: value, if (tagged) '_fs_metadata': metadata}, warnings)[column];
  }

  Object? _decodeConverted(String column, FluentConverter<Object?, Object?> converter, Object? value, [List<_MappingWarning>? warnings]) {
    try {
      if (value != null && converter is FluentEnumConverter && FluentEnumConverter.lookup(converter.values, value) == null) {
        final String known = converter.values.map((e) => "'${e.name}'").join(', ');
        if (converter.nullIfUnknown && warnings != null) {
          final String sample = value is num ? '$value' : "'${value.toString().replaceAll("'", "''")}'";
          warnings.add((
            message: 'The stored value $sample of "$table.$column" matches no ${converter.values.first.runtimeType} value; the field reads as null.',
            hint: 'The enum value was probably renamed or removed (known: $known). Migrate the stored values, e.g. '
                '`UPDATE "$table" SET "$column" = <new name> WHERE "$column" = $sample`, or keep the old name in the enum.',
          ));
          return null;
        }
        throw FormatException('unknown enum value ${value.runtimeType == String ? "'$value'" : value}; known values: $known');
      }
      if (converter is FluentIsoDateTimeConverter && value is String && warnings != null) _checkShortIso(column, value, warnings);
      return converter.decode(value);
    } catch (e, s) {
      throw FluentSchemaException(
        'Converter ${converter.runtimeType} failed to read a ${value.runtimeType} value of "$table.$column": ${FluentLog.redact('$e')}',
        modelName: modelName,
        columnName: column,
        hint: converter is FluentEnumConverter
            ? 'The enum value was probably renamed or removed. Migrate the stored values (a migration rawSql step), keep the old name in the enum, or make the column nullable so such values read as null.'
            : 'The stored value does not match the converter. If the column held data before the converter was added, migrate it (e.g. with a migration rawSql step).',
        cause: e,
        stackTrace: s,
      );
    }
  }

  /// Stored SQLite values back to Dart values: by the row's `_fs_metadata` tags, else by the column kinds.
  Map<String, dynamic> _restoreTypes(Map<String, dynamic> row, List<_MappingWarning> warnings) {
    final Object? metaRaw = row['_fs_metadata'];
    // The column kinds as they are; a copy only for a row with its own type tags (rare), not for every row.
    Map<String, String> hints = kinds;
    if (metaRaw is String && metaRaw.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(metaRaw) as Map<String, dynamic>;
        hints = Map.of(kinds);
        for (final MapEntry<String, dynamic> e in decoded.entries) {
          // Columns with a converter are read by it (rows written before the converter may still carry a tag).
          if (converters.containsKey(e.key)) continue;
          final String tag = e.value.toString();
          hints[e.key] = tag;
          if (_seenTags[e.key] != tag) _seenTags[e.key] = tag;
        }
      } catch (_) {
        // Damaged: the pairs still readable, else the tag intact rows gave the column, else the column kind.
        hints = Map.of(kinds);
        for (final MapEntry<String, String> seen in _seenTags.entries) {
          hints[seen.key] = seen.value;
        }
        for (final RegExpMatch m in _tagPair.allMatches(metaRaw)) {
          final String column = m.group(1)!;
          final String tag = m.group(2)!;
          if (!converters.containsKey(column) && FluentTypeCodecs.knows(tag)) hints[column] = tag;
        }
        // Every tag decodes leniently, so a guessed tag never loses a value; at worst a DateTime gets the other flag.
        warnings.add((message: 'Corrupted type metadata in "$table"; readable tags, tags of intact rows and column kinds are used instead', hint: 'Re-save the affected rows to rewrite their metadata.'));
      }
    }
    if (hints.isEmpty) return row;

    Map<String, dynamic> result = row;
    for (final MapEntry<String, String> entry in hints.entries) {
      final Object? value = result[entry.key];
      if (value == null) continue;
      final List<Enum>? values = entry.value == 'enum' ? enumValues[entry.key] : null;
      final Object? restored;
      try {
        restored = FluentTypeCodecs.decode(entry.value, value, enumValues: values);
      } catch (e, s) {
        throw FluentSchemaException(
          'The stored value of "$table.${entry.key}" cannot be read as ${entry.value}: ${FluentLog.redact('$e')}',
          modelName: modelName,
          columnName: entry.key,
          hint: 'The value was damaged or written outside the library. Fix or delete it (e.g. `UPDATE "$table" SET "${entry.key}" = NULL WHERE ...`), '
              'or save the row again with a valid value.',
          cause: e,
          stackTrace: s,
        );
      }
      if (identical(restored, value)) {
        if (entry.value == 'json' && value is String) {
          warnings.add((
            message: 'The stored JSON of "$table.${entry.key}" cannot be decoded; the model receives the raw text.',
            hint: 'The value was damaged or written outside the library. Save the row again with a valid value.',
          ));
        }
        continue;
      }
      if (value is String && (entry.value == 'datetime' || entry.value == 'datetime_utc')) _checkShortIso(entry.key, value, warnings);
      if (identical(result, row)) result = Map<String, dynamic>.from(row);
      result[entry.key] = restored;
    }
    return result;
  }
}

/// Turning query results into models without blocking the UI: big lists are sliced across frames on the UI isolate,
/// or mapped in a background isolate (see `FluentConfig.isolateMapping` and [FluentProvider.isolateFactory]).
extension _FluentRowMapping<T extends FluentStorable> on FluentProvider<T> {
  /// Pads ISO-8601 text written by earlier versions (three-digit fraction, `...:00.123Z`) to the six digits the library
  /// writes now, in every column that holds library ISO text (columns of a `FluentIsoDateTimeConverter`; date columns
  /// of an `iso8601` table), so equality filters and the order inside one millisecond see one form. The instant stays
  /// the same (only zeros are added). Runs in the schema sync of the table, which the fingerprint marker `#iso:6` makes
  /// happen once per database; a quick UPDATE that matches nothing costs one scan. Reported as an autoFix issue.
  /// Read-only groups never run it: the row mapping warns there (`_checkShortIso`).
  Future<void> _adoptIsoFraction(DatabaseExecutor ex) async {
    final bool isoTable = _tableConfig.dateTimeFormat == FluentDateTimeFormat.iso8601;
    final Map<String, int> fixed = {};
    for (final FluentDbColumn column in getFullSchema) {
      final bool isoConverter = _converters[column.name] is FluentIsoDateTimeConverter;
      final bool isoKind = isoTable && column.valueKind == FluentValueKind.dateTime && !_converters.containsKey(column.name);
      if (!isoConverter && !isoKind) continue;
      final String c = column.name.quotedIdentifier;
      final String dot = "instr($c, '.')";
      final int count = await ex.rawUpdate(
        'UPDATE ${tableName.quotedIdentifier} SET $c = substr($c, 1, $dot + 3) || \'000\' || substr($c, $dot + 4) '
        "WHERE typeof($c) = 'text' AND $c GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]' "
        "OR typeof($c) = 'text' AND $c GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9]Z'",
      );
      if (count > 0) fixed[column.name] = count;
    }
    if (fixed.isEmpty) return;
    FluentLog.issue(
      FluentIssueKind.storedFormatAdopted,
      'ISO-8601 dates of "$tableName" written with a three-digit fraction were padded to six digits: ${fixed.entries.map((e) => '${e.key}: ${e.value} row(s)').join(', ')}.',
      table: tableName,
      subject: fixed.keys.first,
      tag: '$tableName:schema',
      hint: 'Nothing to do: the instants are unchanged. Equality filters and ordering on these columns see one text form now.',
      context: {'rows': fixed.values.fold<int>(0, (a, b) => a + b)},
    );
  }

  /// Below this many rows a background isolate never pays off (spawning and copying cost more than mapping).
  static const int _isolateMinRows = 100;

  /// Mapping longer than this on the UI isolate (half a 60 Hz frame) moves to a background isolate in `smart` mode.
  static const int _isolateAboveMicros = 8000;

  /// Batches mapped on the UI isolate after the first failure of the isolate (doubled by every further failure).
  static const int _isolateRetryFirst = 2;

  /// The longest pause in batches.
  static const int _isolateRetryMax = 64;

  /// The key of a stored [row] as Dart values (its columns decoded like the mapping does: converter, codec): the plain
  /// value, or a [FluentKey] for a composite key. `null` when a key column is `null` or missing. Keys of rows that go
  /// back into a filter stay as they are ([idFromRow]); this one is for comparing with keys of models.
  Object? _dartIdOf(Map<String, dynamic> row) {
    final List<_MappingWarning> warnings = [];
    final Object? metadata = row['_fs_metadata'];
    final Map<String, Object?> values = {};
    for (final FluentDbColumn column in primaryKeyColumns) {
      final Object? stored = row[column.name];
      if (stored == null) return null;
      values[column.name] = _plan.decodeValue(column.name, stored, warnings, metadata: metadata);
    }
    return hasCompositeKey ? FluentKey(values) : values.values.first;
  }

  void _logWarnings(List<_MappingWarning> warnings) {
    for (final _MappingWarning w in warnings) {
      FluentLog.issue(FluentIssueKind.mappingValue, w.message, tag: '$tableName:hydration', hint: w.hint);
    }
  }

  /// Builds models from loaded [rows] (relations already loaded), choosing where the work runs.
  Future<List<T>> _mapRows(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return <T>[];
    final FluentConfig config = FluentEngine().config;
    if (_useIsolate(rows.length, config)) {
      if (_isolateSkipBatches > 0) {
        _isolateSkipBatches--; // paused after a failure of the isolate: this batch is mapped here, a later one tries again
      } else {
        final List<T>? done = await _mapInIsolate(rows);
        if (done != null) return done;
      }
    }
    return _mapOnUiIsolate(rows, config);
  }

  /// Where big lists of this table are mapped: table → global setting.
  FluentIsolateMapping _isolateMapping(FluentConfig config) => _tableConfig.isolateMapping ?? config.isolateMapping;

  bool _useIsolate(int rows, FluentConfig config) {
    final FluentIsolateMapping mode = _isolateMapping(config);
    if (mode == FluentIsolateMapping.never) return false;
    final T Function(Map<String, dynamic> json)? factory = isolateFactory;
    if (mode == FluentIsolateMapping.always) {
      if (factory == null) _suggestIsolateFactory(null, rows);
      return factory != null;
    }
    final double? perRow = FluentTableStatsTracker().mappingMicros(dbName, tableName);
    if (rows < _isolateMinRows || perRow == null || perRow * rows < _isolateAboveMicros) return false;
    if (factory == null) _suggestIsolateFactory(perRow * rows / 1000, rows);
    return factory != null;
  }

  Future<List<T>> _mapOnUiIsolate(List<Map<String, dynamic>> rows, FluentConfig config) async {
    final bool slice = config.sliceAfterRows > 0 && rows.length >= config.sliceAfterRows;
    final int budget = FluentTuner().frameBudget(config).inMicroseconds;
    final List<FluentStorable> models = [];
    final List<_MappingWarning> warnings = [];
    final Stopwatch work = Stopwatch()..start();
    int sliceStart = 0;
    try {
      for (final Map<String, dynamic> row in rows) {
        models.add(_plan.build(_castReadyRelations(row), warnings));
        if (slice && work.elapsedMicroseconds - sliceStart >= budget) {
          work.stop();
          await Future<void>.delayed(Duration.zero); // let the UI render a frame
          work.start();
          sliceStart = work.elapsedMicroseconds;
        }
      }
    } on FluentException catch (e) {
      throw FluentLog.raise(e, tag: '$tableName:hydration');
    } finally {
      _logWarnings(warnings);
    }
    if (rows.length >= 50) {
      FluentTableStatsTracker().recordMapping(dbName, tableName, work.elapsedMicroseconds / rows.length);
      if (_isolateMapping(config) == FluentIsolateMapping.smart && isolateFactory == null && rows.length >= _isolateMinRows && work.elapsedMicroseconds >= _isolateAboveMicros) {
        _suggestIsolateFactory(work.elapsedMicroseconds / 1000, rows.length);
      }
    }
    return _createTypedList(models);
  }

  /// Maps [rows] in a background isolate; `null` when that is not possible (the caller maps on the UI isolate).
  Future<List<T>?> _mapInIsolate(List<Map<String, dynamic>> rows) async {
    final _FluentRowPlan<FluentStorable> plan = _isolatePlan;
    final List<Map<String, dynamic>> input = [for (final Map<String, dynamic> row in rows) _castReadyRelations(row)];
    try {
      // A row the factory cannot build comes back as text (always sendable): only failures of the isolate itself
      // (a closure or a value that cannot be sent) switch background mapping off.
      final ({List<FluentStorable> models, List<_MappingWarning> warnings, String? failure, String? hint, String? column}) result = await Isolate.run(() {
        final List<_MappingWarning> warnings = [];
        try {
          return (models: [for (final Map<String, dynamic> row in input) plan.build(row, warnings)], warnings: warnings, failure: null, hint: null, column: null);
        } on FluentException catch (e) {
          return (models: const <FluentStorable>[], warnings: warnings, failure: e.message, hint: e.hint, column: e is FluentSchemaException ? e.columnName : null);
        }
      }, debugName: 'fluent_sqflite:$tableName');
      _logWarnings(result.warnings);
      if (result.failure != null) {
        throw FluentLog.raise(FluentSchemaException(result.failure!, modelName: '$modelType', columnName: result.column, hint: result.hint), tag: '$tableName:hydration');
      }
      if (_isolateBackoff > 0) {
        _isolateBackoff = 0;
        FluentLog.issue(
          FluentIssueKind.isolateFallback,
          'Rows of "$tableName" are mapped in a background isolate again.',
          table: tableName,
          tag: '$tableName:isolate',
          hint: 'A background isolate failed earlier; the retry worked, so mapping is back off the UI isolate.',
        );
      }
      return _createTypedList(result.models);
    } on FluentException catch (e) {
      throw FluentLog.raise(e, tag: '$tableName:hydration');
    } catch (e, s) {
      // Not for good: a failure can be temporary (low memory, a closed isolate), so mapping goes back to the UI isolate
      // for a growing number of batches and then tries again.
      _isolateBackoff = _isolateBackoff == 0 ? _isolateRetryFirst : math.min(_isolateBackoff * 2, _isolateRetryMax);
      _isolateSkipBatches = _isolateBackoff;
      FluentLog.issue(
        FluentIssueKind.isolateFallback,
        'Rows of "$tableName" cannot be mapped in a background isolate; the next $_isolateBackoff batch(es) are mapped on the UI isolate, then it is tried again.',
        table: tableName,
        tag: '$tableName:isolate',
        hint: 'isolateFactory must be a static or top-level function (e.g. $modelType.fromJson), not a closure over the provider, and '
            'converters must not hold non-sendable objects (database handles, streams, ports).',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  void _suggestIsolateFactory(double? millis, int rows) {
    final String model = modelType.toString();
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.isolate,
        database: dbName,
        table: tableName,
        title: 'Map big lists of "$tableName" in the background',
        details: millis == null
            ? 'isolateMapping is "always", but $runtimeType has no isolateFactory, so its lists are mapped on the UI isolate.'
            : 'Turning $rows rows into $model takes ~${millis.round()} ms on the UI isolate (sliced across frames). '
                'With an isolateFactory the library maps such lists in a background isolate.',
        code: 'class $runtimeType extends FluentProvider<$model> {\n'
            '  @override\n'
            '  $model Function(Map<String, dynamic> json)? get isolateFactory => $model.fromJson;\n'
            '}\n'
            '// In $model: a static factory with the body of fromCacheJson (no access to the provider):\n'
            '// static $model fromJson(Map<String, dynamic> json) => $model(...);',
      ),
    );
  }
}
