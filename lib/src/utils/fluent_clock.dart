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

  /// Replaces the clock (tests); `null` restores [DateTime.now]. Every assignment counts as a move of the clock: the
  /// timers of the library that follow it ([FluentClockTimer]) check at once whether they are due.
  static set testNow(DateTime Function()? now) {
    _now = now ?? DateTime.now;
    _replaced = now != null;
    for (final void Function() listener in List.of(_moveListeners)) {
      listener();
    }
  }

  static final List<void Function()> _moveListeners = [];
}

/// A periodic timer that follows [FluentClock]: [job] runs every [interval] of library time, so a test that moves the
/// clock (`db.clock.advance`) runs it without waiting. Between moves a real timer waits for the next due time.
///
/// [job] never throws out of the timer: an error is reported ([FluentLog.report]) and the next run is scheduled as
/// usual. A run never starts while the previous one is still running (a due run waits for it). [cancel] stops it for
/// good (also a run that would follow a clock move). A zero or negative [interval] cannot work (the job would run
/// without waiting): the timer does not start and a `configFallback` warning is reported.
final class FluentClockTimer {
  /// Starts the timer; the first run is one [interval] from now.
  FluentClockTimer(this.interval, this.job, {this.tag = 'FluentClockTimer'}) : _due = FluentClock.millis + interval.inMilliseconds {
    if (interval <= Duration.zero) {
      _cancelled = true;
      FluentLog.issue(
        FluentIssueKind.configFallback,
        'The timer "$tag" has an interval of ${interval.inMilliseconds} ms, so it was not started (it would run without waiting).',
        subject: tag,
        tag: tag,
        hint: 'Use a positive Duration for the interval, or null to switch the job off.',
      );
      return;
    }
    FluentClock._moveListeners.add(_check);
    _arm();
  }

  /// The time between two runs.
  final Duration interval;

  /// The work of one run.
  final Future<void> Function() job;

  /// The log tag of a failed run.
  final String tag;

  int _due;
  Timer? _timer;
  bool _cancelled = false;
  bool _running = false;

  /// Whether [cancel] was called (or the timer never started: bad interval).
  bool get isCancelled => _cancelled;

  /// Stops the timer.
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    FluentClock._moveListeners.remove(_check);
  }

  void _arm() {
    _timer?.cancel();
    final int wait = _due - FluentClock.millis;
    _timer = Timer(Duration(milliseconds: wait < 1 ? 1 : wait), _check);
  }

  void _check() {
    if (_cancelled) return;
    final int now = FluentClock.millis;
    // A clock moved back never stalls the timer: the next run is at most one interval away.
    if (_due - now > interval.inMilliseconds) _due = now + interval.inMilliseconds;
    if (now >= _due) {
      // Due while the previous run is still going: it starts when that run ends (no overlap, no spinning timer).
      if (_running) return;
      _due = now + interval.inMilliseconds;
      _running = true;
      unawaited(
        Future<void>.sync(job)
            .catchError((Object e, StackTrace st) {
              FluentLog.report(e, stackTrace: st, tag: tag);
            })
            .whenComplete(() {
              _running = false;
              // A run that became due meanwhile starts now (once); otherwise the timer waits for its due time.
              _check();
            }),
      );
    }
    if (!_cancelled) _arm();
  }
}

/// A one-shot timer that follows [FluentClock]: [job] runs once when the library time reaches [due] (epoch
/// milliseconds), so a test that moves the clock past it (`db.clock.advance`) runs it without waiting. Between moves
/// a real timer waits for the due time. A [due] in the past runs [job] on the next event-loop turn.
///
/// [job] never throws out of the timer (an error is reported with [FluentLog.report]). [cancel] stops it for good.
final class FluentClockAlarm {
  /// Arms the alarm for [due] (epoch milliseconds of library time).
  FluentClockAlarm(this.due, this.job, {this.tag = 'FluentClockAlarm'}) {
    FluentClock._moveListeners.add(_check);
    _arm();
  }

  /// When [job] runs (epoch milliseconds of library time).
  final int due;

  /// The work, run once.
  final void Function() job;

  /// The log tag of a failed run.
  final String tag;

  Timer? _timer;
  bool _done = false;

  /// Whether the alarm ran or was cancelled.
  bool get isDone => _done;

  /// Stops the alarm; [job] does not run any more.
  void cancel() {
    _done = true;
    _timer?.cancel();
    _timer = null;
    FluentClock._moveListeners.remove(_check);
  }

  void _arm() {
    _timer?.cancel();
    final int wait = due - FluentClock.millis;
    // A real timer for the time left; a clock that stands still (a test clock set to a fixed time) is checked again
    // after the same wait, so the alarm never spins.
    _timer = Timer(Duration(milliseconds: wait < 1 ? 1 : wait), _check);
  }

  void _check() {
    if (_done) return;
    if (FluentClock.millis < due) {
      _arm();
      return;
    }
    cancel();
    try {
      job();
    } catch (e, st) {
      FluentLog.report(e, stackTrace: st, tag: tag);
    }
  }
}
