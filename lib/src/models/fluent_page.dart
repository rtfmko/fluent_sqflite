// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../exceptions/fluent_exceptions.dart';
import '../interfaces/fluent_exception.dart';

/// One page of a `findPage` read: the models and the cursor of the next page.
///
/// ```dart
/// FluentPage<Message> page = await messages.findPage(orderBy: 'sent_at', descending: true, limit: 30);
/// while (page.hasMore) {
///   page = await messages.findPage(orderBy: 'sent_at', descending: true, limit: 30, after: page.next);
/// }
/// ```
@immutable
class FluentPage<T> {
  /// Creates a page.
  const FluentPage(this.items, this.next);

  /// The models of this page, in the requested order.
  final List<T> items;

  /// Where the next page starts; `null` on the last page.
  final FluentCursor? next;

  /// Whether there is a next page.
  bool get hasMore => next != null;
}

/// The position after the last row of a page (keyset pagination): the next page starts right after it, so rows
/// inserted or deleted meanwhile never make pages repeat or skip rows (unlike `offset`).
///
/// It can be kept between app runs or sent to a server as text ([encode] / [decode]).
@immutable
class FluentCursor {
  /// Creates a cursor; normally built by `findPage`.
  const FluentCursor({required this.orderBy, required this.descending, required this.value, required this.key});

  /// Restores a cursor from [encode]d text (also text of earlier 2.0 versions). Text that is not a cursor throws a
  /// [FluentArgumentException].
  factory FluentCursor.decode(String text) {
    try {
      final Map<String, dynamic> json = jsonDecode(utf8.decode(base64Url.decode(text))) as Map<String, dynamic>;
      return FluentCursor(
        orderBy: json['o'] as String,
        descending: json['d'] as bool,
        value: _decodeValue(json['v']),
        key: {for (final MapEntry<String, dynamic> e in (json['k'] as Map<String, dynamic>).entries) e.key: _decodeValue(e.value)},
      );
    } on FluentException {
      rethrow;
    } catch (e, s) {
      throw FluentArgumentException(
        'cursor',
        'The text is not a cursor produced by FluentCursor.encode: $e',
        hint: 'Pass the unchanged text of FluentPage.next.encode() (a damaged or cut-off text cannot be read).',
        cause: e,
        stackTrace: s,
      );
    }
  }

  /// The column the pages are ordered by.
  final String orderBy;

  /// Whether the order is descending.
  final bool descending;

  /// The stored value of [orderBy] in the last row.
  final Object? value;

  /// The key of the last row (column → stored value); makes the order unique when [value] repeats.
  final Map<String, Object?> key;

  /// The cursor as URL-safe text.
  ///
  /// Bytes (`Uint8List`) and non-finite doubles travel as tagged objects (`{"$b": base64}`, `{"$d": "inf"}`), so
  /// [decode] gives back exactly the value that was encoded; plain values are written as JSON like before.
  String encode() => base64Url.encode(utf8.encode(jsonEncode({'o': orderBy, 'd': descending, 'v': _encodeValue(value), 'k': {for (final MapEntry<String, Object?> e in key.entries) e.key: _encodeValue(e.value)}})));

  static Object? _encodeValue(Object? v) {
    if (v is Uint8List) return {r'$b': base64.encode(v)};
    if (v is double && !v.isFinite) return {r'$d': v.isNaN ? 'nan' : (v.isNegative ? '-inf' : 'inf')};
    if (v == null || v is String || v is num || v is bool) {
      return v;
    }
    throw FluentArgumentException(
      'cursor',
      'a cursor cannot hold a ${v.runtimeType} value.',
      hint: 'Cursors hold stored SQLite values (text, numbers, bytes); order by a column that stores one of them.',
    );
  }

  static Object? _decodeValue(Object? v) {
    if (v is Map<String, dynamic> && v.length == 1) {
      final Object? bytes = v[r'$b'];
      if (bytes is String) return base64.decode(bytes);
      final Object? special = v[r'$d'];
      if (special is String) {
        return switch (special) {
          'nan' => double.nan,
          '-inf' => double.negativeInfinity,
          _ => double.infinity,
        };
      }
    }
    return v;
  }

  static bool _same(Object? a, Object? b) => a is Uint8List && b is Uint8List ? listEquals(a, b) : (a is double && b is double && a.isNaN && b.isNaN) || a == b;

  static int _hash(Object? v) => v is Uint8List ? Object.hashAll(v) : v.hashCode;

  @override
  bool operator ==(Object other) => other is FluentCursor && other.orderBy == orderBy && other.descending == descending && _same(other.value, value) && other.key.length == key.length && key.entries.every((e) => other.key.containsKey(e.key) && _same(other.key[e.key], e.value));

  @override
  int get hashCode => Object.hash(orderBy, descending, _hash(value), Object.hashAllUnordered(key.entries.map((e) => Object.hash(e.key, _hash(e.value)))));

  @override
  String toString() => 'FluentCursor($orderBy ${descending ? 'DESC' : 'ASC'} after $value / $key)';
}
