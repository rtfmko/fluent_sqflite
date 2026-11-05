// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// The library's clock is internal; this package is its only user outside the library.
// ignore_for_file: implementation_imports

import 'package:fluent_sqflite/src/internal.dart';

/// The time fluent_sqflite sees in a test: timestamps, soft-delete stamps, expiry (`timeToLive`), trash retention,
/// sync times and `maxAge`. It is the real time until you move it; `FluentTestDb.close` puts it back.
///
/// ```dart
/// db.clock.advance(const Duration(days: 31)); // the trash retention has passed
/// db.clock.set(DateTime(2026, 1, 1));         // a fixed moment from now on
/// ```
class FluentTestClock {
  /// Creates a clock (by `FluentTestDb`); it changes nothing until [set] or [advance].
  FluentTestClock();

  DateTime? _fixed;
  Duration _offset = Duration.zero;
  bool _installed = false;

  /// The time the library sees now.
  DateTime get now => FluentClock.now();

  /// Whether the clock was moved ([set] or [advance]) since it was created or [reset].
  bool get isMoved => _installed;

  /// Stops the clock at [time]: every later read of the time gives [time] until the next [set] or [advance].
  void set(DateTime time) {
    _fixed = time;
    _install();
  }

  /// Moves the clock forward by [by] (back with a negative duration). A running clock keeps running from there; a
  /// clock stopped by [set] stays stopped at the new time.
  void advance(Duration by) {
    final DateTime? fixed = _fixed;
    if (fixed != null) {
      _fixed = fixed.add(by);
    } else {
      _offset += by;
    }
    _install();
  }

  /// Back to the real time.
  void reset() {
    _fixed = null;
    _offset = Duration.zero;
    if (!_installed) return;
    _installed = false;
    FluentClock.testNow = null;
  }

  void _install() {
    if (_installed) return;
    _installed = true;
    FluentClock.testNow = () => _fixed ?? DateTime.now().add(_offset);
  }
}
