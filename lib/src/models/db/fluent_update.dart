// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// What a [FluentUpdate] does to its column.
enum FluentUpdateOperation {
  /// Adds a number ([FluentUpdate.increment] / [FluentUpdate.decrement]).
  add,

  /// Sets the current time ([FluentUpdate.now]).
  now,

  /// Flips a boolean ([FluentUpdate.toggle]).
  toggle,
}

/// A value of `updateById` / `updateWhere` that SQLite computes from the stored row, in the same statement — so
/// concurrent calls never lose an update (unlike reading the model, changing it and saving it back).
///
/// `increment` / `decrement` need an `int` / `double` column without a converter, `toggle` a `bool` column; other
/// columns throw `FluentArgumentException` when the update runs.
///
/// ```dart
/// await posts.updateById(id, {'views': FluentUpdate.increment(1), 'seen_at': FluentUpdate.now});
/// await carts.updateWhere(FluentFilter.eq('user_id', u), {'items': FluentUpdate.decrement(1)});
/// await todos.updateById(id, {'done': FluentUpdate.toggle});
/// ```
@immutable
class FluentUpdate {
  const FluentUpdate._(this.operation, [this.amount = 0]);

  /// Adds [by] to a number column (`NULL` counts as 0).
  factory FluentUpdate.increment([num by = 1]) => FluentUpdate._(FluentUpdateOperation.add, by);

  /// Subtracts [by] from a number column (`NULL` counts as 0).
  factory FluentUpdate.decrement([num by = 1]) => FluentUpdate._(FluentUpdateOperation.add, -by);

  /// The current time, stored like every `DateTime` of the column.
  static const FluentUpdate now = FluentUpdate._(FluentUpdateOperation.now);

  /// Flips a `bool` column (`NULL` becomes `true`).
  static const FluentUpdate toggle = FluentUpdate._(FluentUpdateOperation.toggle);

  /// What it does.
  final FluentUpdateOperation operation;

  /// The number added ([FluentUpdateOperation.add]).
  final num amount;

  @override
  bool operator ==(Object other) => other is FluentUpdate && other.operation == operation && other.amount == amount;

  @override
  int get hashCode => Object.hash(operation, amount);

  @override
  String toString() => switch (operation) {
    FluentUpdateOperation.add => amount < 0 ? 'FluentUpdate.decrement(${-amount})' : 'FluentUpdate.increment($amount)',
    FluentUpdateOperation.now => 'FluentUpdate.now',
    FluentUpdateOperation.toggle => 'FluentUpdate.toggle',
  };
}
