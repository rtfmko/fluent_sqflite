// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../../exceptions/fluent_exceptions.dart';
import '../../utils/fluent_filter.dart';
import '../../utils/fluent_identifier.dart';

/// The value of a primary key: one or more `column → value` pairs.
///
/// Tables with a single primary key keep using plain values (`findById(5)`).
/// Tables with a composite key use [FluentKey]:
///
/// ```dart
/// final stats = await FluentDb.findById<DailyStats>(FluentKey({'user_id': 7, 'day': '2026-10-20'}));
/// ```
///
/// A model returns its own key through [FluentStorable.key], so the key can always be taken
/// from an instance: `FluentDb.deleteById<DailyStats>(stats.key)`.
@immutable
class FluentKey {
  /// Creates a key from `column → value` pairs. The map must not be empty (`FluentArgumentException`).
  FluentKey(Map<String, Object?> values) : values = Map.unmodifiable(values) {
    if (values.isEmpty) {
      throw FluentArgumentException('values', 'a FluentKey needs at least one column.', hint: 'Pass e.g. FluentKey({"id": 1}).');
    }
  }

  /// Creates a key for a single primary key column.
  FluentKey.single(String column, Object? value) : this({column: value});

  /// The key columns and their values, in the order given (lookups do not depend on it).
  final Map<String, Object?> values;

  /// The key column names, in the order given.
  List<String> get columns => values.keys.toList(growable: false);

  /// Whether the key consists of more than one column.
  bool get isComposite => values.length > 1;

  /// Whether every key column has a non-null value (required to address an existing row).
  bool get isComplete => values.values.every((v) => v != null);

  /// The value of one key column.
  Object? operator [](String column) => values[column];

  /// A filter matching exactly the row with this key: `("a" = ?) AND ("b" = ?)` (`IS NULL` for a `null` value).
  FluentFilter get filter => values.entries.map((e) => FluentFilter.eq(e.key.quotedIdentifier, e.value)).reduce((a, b) => a.and(b));

  @override
  bool operator ==(Object other) => identical(this, other) || other is FluentKey && mapEquals(values, other.values);

  @override
  int get hashCode => Object.hashAllUnordered(values.entries.map((e) => Object.hash(e.key, e.value))); // like ==, order-free

  @override
  String toString() => 'FluentKey(${values.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}
