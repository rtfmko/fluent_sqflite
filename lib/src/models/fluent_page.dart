// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  /// Restores a cursor from [encode]d text.
  factory FluentCursor.decode(String text) {
    final Map<String, dynamic> json = jsonDecode(utf8.decode(base64Url.decode(text))) as Map<String, dynamic>;
    return FluentCursor(orderBy: json['o'] as String, descending: json['d'] as bool, value: json['v'], key: Map<String, Object?>.from(json['k'] as Map));
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
  String encode() => base64Url.encode(utf8.encode(jsonEncode({'o': orderBy, 'd': descending, 'v': value, 'k': key})));

  @override
  bool operator ==(Object other) => other is FluentCursor && other.orderBy == orderBy && other.descending == descending && other.value == value && mapEquals(other.key, key);

  @override
  int get hashCode => Object.hash(orderBy, descending, value, Object.hashAllUnordered(key.entries.map((e) => Object.hash(e.key, e.value))));

  @override
  String toString() => 'FluentCursor($orderBy ${descending ? 'DESC' : 'ASC'} after $value / $key)';
}
