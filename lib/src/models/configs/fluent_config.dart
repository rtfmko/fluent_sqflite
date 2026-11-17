// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

import '../../utils/fluent_enum.dart';
import '../execution_policy.dart';
import 'fluent_diagnostics.dart';

/// Settings of the whole library: the engine, maintenance, mapping of big lists, and the defaults of the settings a
/// database ([FluentDbConfig]) or a table ([FluentTableConfig]) may override.
///
/// Scope rule: **table → database → global**. A value set on the model's `tableConfig` wins over the database's
/// `FluentGroup.config`, which wins over this one.
///
/// ```dart
/// await FluentDb.init(groups, config: const FluentConfig(trashRetention: Duration(days: 30)));
/// FluentDb.configure(const FluentConfig(optimizeInterval: null)); // change later, e.g. in battery saver
/// ```
class FluentConfig {
  /// How long a `FluentDb.transaction` may run while calls of its database wait behind it, before the engine steps
  /// in (default 2 s, `null` turns it off).
  ///
  /// A transaction that awaits a call made outside it after it started would wait forever: that call is queued
  /// behind the transaction. The watchdog logs a warning with a hint and runs the waiting **reads** inside the
  /// transaction, so such a transaction can finish. Waiting writes are not moved into it (a rollback would undo
  /// writes already reported as successful); they keep waiting for the transaction to end.
  final Duration? transactionWatchdog;

  /// A queue paused with `FluentDb.pauseQueue` longer than this is resumed with a warning (default 60 s, `null`
  /// keeps it paused until `resumeQueue`).
  final Duration? pauseWatchdog;

  /// How often the trash is purged while the app runs (default daily; it is always purged at `init`); `null` purges
  /// only at `init`.
  final Duration? trashPurgeInterval;

  /// How often SQLite refreshes its query planner statistics (`PRAGMA optimize`) while the app runs (default every
  /// 6 hours; it also runs on `FluentDb.close`); `null` runs it only on close.
  final Duration? optimizeInterval;

  /// Whether big lists are turned into models in a background isolate (keeps the UI smooth). Default
  /// [FluentIsolateMapping.smart]: the library measures the mapping cost per table and moves lists that would take
  /// longer than half a frame. Needs `FluentProvider.isolateFactory`; without it the library suggests adding one.
  /// A table may override it (`FluentTableConfig.isolateMapping`).
  final FluentIsolateMapping isolateMapping;

  /// Lists with at least this many rows are turned into models in slices on the UI isolate, giving the UI a frame
  /// after every [frameBudget] of work (default 300; 0 turns slicing off).
  final int sliceAfterRows;

  /// Work done on the UI isolate before a sliced mapping lets a frame render (default 4 ms).
  final Duration frameBudget;

  /// What the library measures, suggests and changes by itself (default [FluentDiagnostics.recommend]: measure and
  /// suggest, change nothing). A database may override it (`FluentDbConfig.diagnostics`).
  final FluentDiagnostics diagnostics;

  /// The policy of calls that set none (and whose provider sets none): priority 0, identical reads in flight shared.
  final ExecutionPolicy defaultPolicy;

  /// How long soft-deleted rows stay in the trash before they are removed for good (default 7 days). A database or
  /// a table may override it.
  final Duration trashRetention;

  /// Whether relation reference columns (`author_id`, composite references, many-to-many link targets) get an index
  /// (default `true`). They make relation loads, relation filters and deletes of referenced rows fast and cost some
  /// space and write time; turned off, the library shows a hint when a relation needs one. A database or a table may
  /// override it.
  final bool indexReferences;

  /// Whether fields of a model that hold other stored models (`List<Post> posts`, `Person? author` in `buildJson`)
  /// become relations without a declaration (default `true`). The library decides the kind from the whole database
  /// and lists what it decided in a hint, with the declarations to copy. A database or a table may override it.
  final bool autoRelations;

  /// How full-text indexes (`FluentIndex.fullText`) are kept (default [FluentFullText.auto]: FTS5, FTS4 as
  /// fallback). A database or a table may override it.
  final FluentFullText fullText;

  /// Extra read-only connections per database (0–4) that run reads at the same time; `null` (default): 2, or sized by
  /// the device's cores with `FluentTuning.readConnections`. A database may
  /// override it (`FluentDbConfig.readConnections`).
  ///
  /// sqflite runs the statements of one connection one after another, so real parallel reads need several
  /// connections. They are opened only for a database file in WAL mode; each costs its own page cache. Reads inside
  /// `FluentDb.transaction` always use the transaction, and a read never starts before an earlier write committed,
  /// so every read sees the writes called before it.
  final int? readConnections;

  /// Where the keys of rows come from when several `findById` / `findByIds` lookups are answered by one query:
  /// [FluentBatchKeys.fromRows] (default, fast: the stored rows) or [FluentBatchKeys.fromModels] (exact even when
  /// `fromCacheJson` changes the key, but `buildJson` runs per returned model, so throughput drops). A database or a
  /// table may override it.
  final FluentBatchKeys batchKeys;

  /// Creates the library settings; every value has a default tuned for apps.
  const FluentConfig({
    this.transactionWatchdog = const Duration(seconds: 2),
    this.pauseWatchdog = const Duration(seconds: 60),
    this.trashPurgeInterval = const Duration(hours: 24),
    this.optimizeInterval = const Duration(hours: 6),
    this.isolateMapping = FluentIsolateMapping.smart,
    this.sliceAfterRows = 300,
    this.frameBudget = const Duration(milliseconds: 4),
    this.diagnostics = FluentDiagnostics.recommend,
    this.defaultPolicy = const ExecutionPolicy(),
    this.trashRetention = const Duration(days: 7),
    this.indexReferences = true,
    this.autoRelations = true,
    this.fullText = FluentFullText.auto,
    this.readConnections,
    this.batchKeys = FluentBatchKeys.fromRows,
  });

  /// This config with every interval that cannot work (zero or negative: a timer that never waits, a watchdog that
  /// fires at once) replaced by its default; [onFixed] hears each replacement (`name`, the bad value, the default).
  @internal
  FluentConfig withSafeIntervals(void Function(String name, Duration bad, Duration fallback) onFixed) {
    const FluentConfig defaults = FluentConfig();
    Duration? check(String name, Duration? value, Duration? fallback) {
      if (value == null || value > Duration.zero) return value;
      onFixed(name, value, fallback!);
      return fallback;
    }

    final Duration? tx = check('transactionWatchdog', transactionWatchdog, defaults.transactionWatchdog);
    final Duration? pause = check('pauseWatchdog', pauseWatchdog, defaults.pauseWatchdog);
    final Duration? purge = check('trashPurgeInterval', trashPurgeInterval, defaults.trashPurgeInterval);
    final Duration? optimize = check('optimizeInterval', optimizeInterval, defaults.optimizeInterval);
    if (identical(tx, transactionWatchdog) && identical(pause, pauseWatchdog) && identical(purge, trashPurgeInterval) && identical(optimize, optimizeInterval)) return this;
    return FluentConfig(
      transactionWatchdog: tx,
      pauseWatchdog: pause,
      trashPurgeInterval: purge,
      optimizeInterval: optimize,
      isolateMapping: isolateMapping,
      sliceAfterRows: sliceAfterRows,
      frameBudget: frameBudget,
      diagnostics: diagnostics,
      defaultPolicy: defaultPolicy,
      trashRetention: trashRetention,
      indexReferences: indexReferences,
      autoRelations: autoRelations,
      fullText: fullText,
      readConnections: readConnections,
      batchKeys: batchKeys,
    );
  }
}
