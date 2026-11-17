// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_provider.dart';

/// Model → row serialization: stores Dart values, drops relation fields and leaves the library columns (soft delete,
/// timestamps, sync versions) to the row writer.
extension _FluentMapper<T extends FluentStorable> on FluentProvider<T> {
  /// The row of [item]: `buildJson()` plus the values the library keeps for it (generated key, reference columns),
  /// only table columns, relation fields left out, each value stored by its converter or the built-in codec. Type tags
  /// the column kind does not cover go to `_fs_metadata` (cleared otherwise); the expiry is set from `timeToLive`.
  Map<String, dynamic> _prepareSqlJson(T item) {
    // A copy: buildJson may return a const or unmodifiable map. Values the library keeps for the instance (generated
    // key, reference columns without a model field) are added to it.
    // buildJson always wins (the user may change a key after the first save); the library's values only fill what
    // buildJson leaves null or does not return. `primaryKeyValue` and `key` follow the same rule.
    final Map<String, dynamic> rawJson = {...item.buildJson()};
    for (final MapEntry<String, dynamic> kept in item.metadata.entries) {
      if (rawJson[kept.key] == null) rawJson[kept.key] = kept.value;
    }
    for (final String k in keyColumnNames) {
      if (rawJson.containsKey(k)) rawJson[k] = item.keyValueOf(k, rawJson[k]); // a key replaced by a conflictOn match
    }

    final Set<String> relKeys = relationKeys;
    final Set<String> validColumns = tableColumns;
    final Map<String, dynamic> finalSqlJson = {};
    Map<String, String>? typeMetadata;

    for (final MapEntry<String, dynamic> entry in rawJson.entries) {
      final String key = entry.key;
      final dynamic value = entry.value;

      // Relation values are saved through their own tables, never as columns.
      if (relKeys.contains(key)) continue;

      if (!validColumns.contains(key)) {
        continue;
      }

      final FluentConverter<Object?, Object?>? converter = _converters[key];
      if (converter != null) {
        finalSqlJson[key] = _convert(key, value, converter, toSql: true);
        continue;
      }

      final ({dynamic value, String? metaType}) result = FluentSqlSanitizer.sanitize(value: value, config: _tableConfig, tableName: tableName, key: key);
      finalSqlJson[key] = result.value;

      // The column kind already tells how to read the value back: no per-row metadata needed.
      if (result.metaType != null && result.metaType != _valueKinds[key]?.tag) {
        typeMetadata ??= {};
        typeMetadata[key] = result.metaType!;
      }
    }

    final String metaColumn = FluentDbColumn.systemMetadata().name;
    if (typeMetadata != null && typeMetadata.isNotEmpty) {
      finalSqlJson[metaColumn] = jsonEncode(typeMetadata);
    } else if (validColumns.contains(metaColumn)) {
      finalSqlJson[metaColumn] = null; // clear stale metadata of an updated row
    }

    // The soft-delete state is never written by a save: only delete / restore change it.
    if (item is FluentSoftDeletable) finalSqlJson.remove((item as FluentSoftDeletable).softDeleteColumn);
    // Sync versions are kept by the row writer.
    final ({String version, String synced})? sync = _syncColumns;
    if (sync != null) {
      finalSqlJson
        ..remove(sync.version)
        ..remove(sync.synced);
    }
    // Creation / modification times are set by the row writer.
    final ({String created, String updated})? times = _timestampColumns;
    if (times != null) {
      finalSqlJson
        ..remove(times.created)
        ..remove(times.updated);
    }

    final Duration? timeToLive = item.timeToLive;

    final int? expiry = timeToLive == null ? null : FluentClock.now().add(timeToLive).millisecondsSinceEpoch;
    if (expiry != null) {
      finalSqlJson[_expiryColumn] = expiry;
    }

    return finalSqlJson;
  }

  /// A filter [value] stored like [column] stores it on save: the column's converter (also the enum converter of
  /// `enumValues`), epoch milliseconds for the library's time columns (timestamps, soft delete, expiry), else the
  /// built-in codec with this table's settings. A value that is not the converter's Dart type (already in its stored
  /// form, e.g. `'paid'` or `2` for an enum) is used as it is; a value of its Dart type the converter fails on throws
  /// a [FluentArgumentException]. [column] `null` (unknown, an expression): the codec.
  Object? _filterValue(Object? value, String? column) {
    if (value == null) return null;
    if (column != null) {
      final FluentConverter<Object?, Object?>? converter = _converters[column];
      if (converter != null) {
        // A value that is not the converter's Dart type is in its stored form already (`'paid'` for an enum).
        if (!converter.acceptsValue(value)) return FluentSqlSanitizer.sanitizeValueOnly(value, _tableConfig);
        final Object? stored;
        try {
          stored = converter.encode(value);
        } catch (e, s) {
          // Filtering with the unconverted value would silently match the wrong rows.
          throw FluentLog.raise(
            FluentArgumentException(
              'where',
              'the filter value for "$tableName.$column" could not be converted by ${converter.runtimeType}: ${FluentLog.redact('$e')}',
              hint: 'Pass a value the converter takes, or the stored form of the value itself.',
              cause: e,
              stackTrace: s,
            ),
            tag: '$tableName:filter',
          );
        }
        return FluentSqlSanitizer.sanitizeValueOnly(stored, _tableConfig);
      }
      if (value is DateTime && _isTimeColumn(column)) return value.millisecondsSinceEpoch;
    }
    return FluentSqlSanitizer.sanitizeValueOnly(value, _tableConfig);
  }

  /// Whether [column] is written by the library as epoch milliseconds (timestamps, soft-delete stamp, expiry).
  bool _isTimeColumn(String column) {
    final ({String created, String updated})? times = _timestampColumns;
    return column == _expiryColumn || column == _softDeleteColumn || (times != null && (column == times.created || column == times.updated));
  }
}
