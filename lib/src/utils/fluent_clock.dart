// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../core/fluent_sqlite_internal.dart';

/// The wall clock of the library: timestamps, soft delete stamps, expiry, trash retention, sync freshness and the
/// stats. One place, so tests can move time ([testNow]; for apps: `FluentTestClock` of the `fluent_sqflite_test`
/// package) instead of waiting.
// ignore: avoid_classes_with_only_static_members
abstract final class FluentClock {
  static DateTime Function() _now = DateTime.now;
  static bool _replaced = false;

  /// Whether a test replaced the clock ([testNow]); SQL then uses this time instead of SQLite's own "now".
  /// (A flag, not a comparison with `DateTime.now`: constructor tear-offs need not be identical.)
  static bool get isReplaced => _replaced;

  /// The current time.
  static DateTime now() => _now();

  /// The current time in milliseconds since epoch.
  static int get millis => _now().millisecondsSinceEpoch;

  /// Replaces the clock (tests); `null` restores [DateTime.now].
  static set testNow(DateTime Function()? now) {
    _now = now ?? DateTime.now;
    _replaced = now != null;
  }
}
