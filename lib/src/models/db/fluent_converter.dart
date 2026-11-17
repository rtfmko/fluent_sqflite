// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:convert';

import '../../utils/fluent_enum.dart';
import 'fluent_sql_expression.dart';

/// Converts a Dart value of type [D] to an SQLite value of type [S] and back.
///
/// Attach a converter to a column to control exactly how a field is stored:
/// ```dart
/// FluentDbColumn.converted('status', FluentEnumConverter(OrderStatus.values));
/// ```
/// The model keeps working with its Dart type in `buildJson()` / `fromCacheJson()`; the library applies [toSql]
/// when writing (also to `FluentFilter` values on the column) and [fromSql] when reading. A filter value that is
/// not a [D] (already the stored form) is used as it is; a [D] that [toSql] fails on is a `FluentArgumentException`.
abstract class FluentConverter<D, S> {
  /// Const constructor for subclasses.
  const FluentConverter();

  /// The column type used to store the converted value.
  FluentDbDataType get sqlType;

  /// Dart value → stored value.
  S toSql(D value);

  /// Stored value → Dart value.
  D fromSql(S value);

  /// Untyped [toSql] used by the library; `null` stays `null`.
  Object? encode(Object? value) => value == null ? null : toSql(value as D);

  /// Whether [value] is of the Dart type [D] this converter takes. Filter values that are not (already in their
  /// stored form) are used as they are.
  bool acceptsValue(Object? value) => value is D;

  /// Untyped [fromSql] used by the library; `null` stays `null`.
  Object? decode(Object? value) => value == null ? null : fromSql(value as S);
}

/// Stores an enum by its `name` (default: readable, survives reordering of enum values) or by its `index`.
///
/// Reading accepts both forms, so switching [byName] (or `FluentTableConfig.storeEnumsAsNames`) keeps old rows
/// readable. `FluentStorable.enumValues` creates this converter for its columns.
class FluentEnumConverter<E extends Enum> extends FluentConverter<E, Object> {
  /// Creates a converter for the given enum [values], e.g. `OrderStatus.values`.
  const FluentEnumConverter(this.values, {this.byName = true, this.nullIfUnknown = false});

  /// Whether a stored value that matches no enum value reads as `null` (the row mapping publishes a warning with a
  /// hint to migrate the value) instead of failing the read. `FluentStorable.enumValues` sets it for columns that
  /// allow `NULL`.
  final bool nullIfUnknown;

  /// All values of the enum.
  final List<E> values;

  /// Store the name (`true`) or the index (`false`).
  final bool byName;

  @override
  FluentDbDataType get sqlType => byName ? FluentDbDataType.text : FluentDbDataType.integer;

  @override
  Object toSql(E value) => byName ? value.name : value.index;

  /// A name or index given instead of the enum (e.g. from raw maps) is stored as it is.
  @override
  Object? encode(Object? value) => value is String || value is int ? value : super.encode(value);

  /// Throws [ArgumentError] when [value] matches no enum value (the library turns it into a schema error with a hint).
  @override
  E fromSql(Object value) =>
      lookup(values, value) as E? ?? (throw ArgumentError.value(value, 'value', 'Unknown enum value. Known names: ${values.map((e) => e.name).join(', ')}'));

  /// The value of [values] stored as [stored] (an enum, its name, its index or the index as text), or `null`.
  static Enum? lookup(List<Enum> values, Object stored) {
    if (stored is Enum) return stored;
    final String text = stored.toString();
    for (final Enum e in values) {
      if (e.name == text) return e;
    }
    final int? index = stored is int ? stored : int.tryParse(text);
    return index != null && index >= 0 && index < values.length ? values[index] : null;
  }
}

/// Stores a `DateTime` as ISO-8601 text (readable in any SQLite browser, sorts correctly in UTC) with a fixed
/// six-digit fraction (`.123000Z`). Text written by earlier versions has three digits (`.123Z`) when there are no
/// microseconds; it still reads back, but sorts and compares wrongly next to the new form within one millisecond.
class FluentIsoDateTimeConverter extends FluentConverter<DateTime, String> {
  /// Creates the converter. With [toUtc] (default) values are normalized to UTC before storing.
  const FluentIsoDateTimeConverter({this.toUtc = true});

  /// Whether to convert to UTC before storing.
  final bool toUtc;

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(DateTime value) => fluentIsoText(toUtc ? value.toUtc() : value);

  @override
  DateTime fromSql(String value) => DateTime.parse(value);
}

/// Stores a `DateTime` as milliseconds since epoch (compact, fast to compare).
///
/// The stored number has no time zone: values are read back as local times, or as UTC with [utc] `true`. `DateTime`
/// equality includes the zone, so a model that keeps UTC times should use `FluentEpochDateTimeConverter(utc: true)`
/// to read back values equal to the ones it saved. Microseconds are cut off (milliseconds are stored).
class FluentEpochDateTimeConverter extends FluentConverter<DateTime, int> {
  /// Creates the converter; [utc] reads values back as UTC times.
  const FluentEpochDateTimeConverter({this.utc = false});

  /// Whether stored values are read back as UTC (`DateTime.isUtc`) instead of local times.
  final bool utc;

  @override
  FluentDbDataType get sqlType => FluentDbDataType.integer;

  @override
  int toSql(DateTime value) => value.millisecondsSinceEpoch;

  @override
  DateTime fromSql(int value) => DateTime.fromMillisecondsSinceEpoch(value, isUtc: utc);
}

/// Stores a JSON-encodable value (`Map`, `List`, ...) as JSON text.
class FluentJsonConverter<D> extends FluentConverter<D, String> {
  /// Creates the converter. [fromJson] turns the decoded JSON back into [D];
  /// by default the decoded value is cast to [D].
  const FluentJsonConverter({this.fromJson});

  /// Optional factory for typed objects (e.g. `Address.fromJson`).
  final D Function(Object? json)? fromJson;

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(D value) => jsonEncode(value);

  @override
  D fromSql(String value) {
    final Object? decoded = jsonDecode(value);
    return fromJson != null ? fromJson!(decoded) : decoded as D;
  }
}
