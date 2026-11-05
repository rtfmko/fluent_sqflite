// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// What the library observes, suggests and changes by itself: one place for the analyzer, the cost model and the
/// tuner. Set it globally (`FluentConfig.diagnostics`) or per database (`FluentDbConfig.diagnostics`, wins).
///
/// ```dart
/// const FluentConfig(diagnostics: FluentDiagnostics.auto);                 // suggest and tune
/// FluentConfig(diagnostics: FluentDiagnostics(tuning: FluentTuning.full.copyWith(indexes: false)));
/// const FluentDbConfig(diagnostics: FluentDiagnostics.none);               // fully predictable database
/// ```
///
/// Warnings, errors and automatic changes are always reported (mute them by key with `setupLogging(mute:)`).
@immutable
class FluentDiagnostics {
  /// Creates diagnostics settings; the defaults are [recommend].
  const FluentDiagnostics({this.hints = true, this.hintsInRelease = false, this.costModel = true, this.tuning = FluentTuning.off});

  /// Hints with code to copy (indexes, loops, paging, ...): from the analyzer and the measured costs.
  final bool hints;

  /// Also collect hints in release builds (without reading query plans): e.g. to send them from real devices.
  final bool hintsInRelease;

  /// Measure what every query shape costs (rows, time) and keep it in the database (`__fluent_stats`). The scheduler
  /// runs cheap reads first with it, the hints and the tuner rely on it. Off: reads run in call order (by priority),
  /// nothing is measured or stored, no measured hints, no tuning.
  final bool costModel;

  /// What the library changes by itself while the app runs ([FluentTuning.off]: nothing).
  final FluentTuning tuning;

  /// Nothing measured, suggested or changed: the most predictable behaviour.
  static const FluentDiagnostics none = FluentDiagnostics(hints: false, costModel: false);

  /// Measure and schedule, but no hints and no tuning.
  static const FluentDiagnostics quiet = FluentDiagnostics(hints: false);

  /// Measure, schedule and suggest (debug / profile builds); nothing is changed automatically. The default.
  static const FluentDiagnostics recommend = FluentDiagnostics();

  /// [recommend] plus every safe automatic improvement ([FluentTuning.full]).
  static const FluentDiagnostics auto = FluentDiagnostics(tuning: FluentTuning.full);

  /// A copy with the given values replaced.
  FluentDiagnostics copyWith({bool? hints, bool? hintsInRelease, bool? costModel, FluentTuning? tuning}) => FluentDiagnostics(
    hints: hints ?? this.hints,
    hintsInRelease: hintsInRelease ?? this.hintsInRelease,
    costModel: costModel ?? this.costModel,
    tuning: tuning ?? this.tuning,
  );

  @override
  bool operator ==(Object other) =>
      other is FluentDiagnostics && other.hints == hints && other.hintsInRelease == hintsInRelease && other.costModel == costModel && other.tuning == tuning;

  @override
  int get hashCode => Object.hash(hints, hintsInRelease, costModel, tuning);

  @override
  String toString() => 'FluentDiagnostics(hints: $hints, hintsInRelease: $hintsInRelease, costModel: $costModel, tuning: $tuning)';
}

/// The automatic improvements of the tuner, each one switchable. Every change is reported
/// ([FluentIssueKind.tuned]), checked afterwards and taken back when it does not help or fails
/// ([FluentIssueKind.tuningReverted]); work goes on unchanged. Nothing is changed inside a transaction, and nothing
/// that only works for a new database file.
///
/// New improvements get their own switch here (on in [full], off in [off]).
@immutable
class FluentTuning {
  /// Creates tuner settings; every improvement is off unless switched on (see [full]).
  const FluentTuning({
    this.indexes = false,
    this.maxIndexes = 5,
    this.readConnections = false,
    this.memory = false,
    this.background = false,
    this.checkpoints = false,
    this.frameBudget = false,
  });

  /// Creates indexes for slow filtered / ordered reads (found in the query plan, after several slow runs, while the
  /// database is idle), checks that they help and drops them otherwise. The report shows the code to declare them
  /// in the model. Up to [maxIndexes] per database.
  final bool indexes;

  /// The most indexes the tuner creates in one database.
  final int maxIndexes;

  /// Sizes the read pool by the device's cores when no `readConnections` is set.
  final bool readConnections;

  /// On memory pressure: frees SQLite's caches (`PRAGMA shrink_memory`, smaller page cache), restored afterwards.
  final bool memory;

  /// When the app goes to the background: runs maintenance then (`PRAGMA optimize`, stats, trash) and pauses the
  /// periodic maintenance until it comes back.
  final bool background;

  /// After many writes, and when the app goes to the background: merges the write-ahead log into the database file
  /// (`wal_checkpoint`), keeping the log small and reads fast.
  final bool checkpoints;

  /// Fits the slices of big lists turned into models to the display's refresh rate (`FluentConfig.frameBudget` on
  /// 60 Hz, less on 90 / 120 Hz).
  final bool frameBudget;

  /// No automatic changes.
  static const FluentTuning off = FluentTuning();

  /// Every improvement.
  static const FluentTuning full = FluentTuning(indexes: true, readConnections: true, memory: true, background: true, checkpoints: true, frameBudget: true);

  /// Every improvement except automatic indexes (the schema stays exactly as declared).
  static const FluentTuning noIndexes = FluentTuning(readConnections: true, memory: true, background: true, checkpoints: true, frameBudget: true);

  /// Whether nothing is switched on.
  bool get isOff => !indexes && !readConnections && !memory && !background && !checkpoints && !frameBudget;

  /// A copy with the given switches replaced.
  FluentTuning copyWith({bool? indexes, int? maxIndexes, bool? readConnections, bool? memory, bool? background, bool? checkpoints, bool? frameBudget}) => FluentTuning(
    indexes: indexes ?? this.indexes,
    maxIndexes: maxIndexes ?? this.maxIndexes,
    readConnections: readConnections ?? this.readConnections,
    memory: memory ?? this.memory,
    background: background ?? this.background,
    checkpoints: checkpoints ?? this.checkpoints,
    frameBudget: frameBudget ?? this.frameBudget,
  );

  @override
  bool operator ==(Object other) =>
      other is FluentTuning &&
      other.indexes == indexes &&
      other.maxIndexes == maxIndexes &&
      other.readConnections == readConnections &&
      other.memory == memory &&
      other.background == background &&
      other.checkpoints == checkpoints &&
      other.frameBudget == frameBudget;

  @override
  int get hashCode => Object.hash(indexes, maxIndexes, readConnections, memory, background, checkpoints, frameBudget);

  @override
  String toString() => isOff
      ? 'FluentTuning.off'
      : 'FluentTuning(${[if (indexes) 'indexes (max $maxIndexes)', if (readConnections) 'readConnections', if (memory) 'memory', if (background) 'background', if (checkpoints) 'checkpoints', if (frameBudget) 'frameBudget'].join(', ')})';
}
