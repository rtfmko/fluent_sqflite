// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'fluent_query_cost.dart';

/// A snapshot of the task engine (see `FluentDb.engineStats`): queue state and what the scheduler saved.
class FluentEngineStats {
  /// Creates a snapshot.
  const FluentEngineStats({
    required this.queued,
    required this.activeReads,
    required this.activeWrites,
    required this.completed,
    required this.collapsedReads,
    required this.mergedSaves,
    required this.batchedLookups,
    required this.splitBatches,
    required this.adoptedReads,
    required this.averageWaitMs,
    required this.maxWaitMs,
    this.slowestQueries = const [],
  });

  /// Tasks waiting in the queue.
  final int queued;

  /// Reads running now (all databases).
  final int activeReads;

  /// Writes running now (all databases).
  final int activeWrites;

  /// Tasks finished (completed or failed) since the engine was initialized.
  final int completed;

  /// Reads answered by an identical read already in flight (no query of their own).
  final int collapsedReads;

  /// Saves that ran merged with an adjacent save of the same table.
  final int mergedSaves;

  /// `findById` calls answered by one shared `IN (...)` query.
  final int batchedLookups;

  /// Merged batches that failed and were re-run call by call, so only the faulty call failed.
  final int splitBatches;

  /// Reads that waited behind a long transaction and were run inside it by the transaction watchdog.
  final int adoptedReads;

  /// Average time a task waited in the queue before it started (ms).
  final double averageWaitMs;

  /// Longest time a task waited in the queue (ms).
  final int maxWaitMs;

  /// The slowest measured read shapes (see `FluentDb.report()` for what to do about them).
  final List<FluentQueryCost> slowestQueries;

  @override
  String toString() =>
      'FluentEngineStats(queued: $queued, active: $activeReads reads / $activeWrites writes, completed: $completed, '
      'collapsed: $collapsedReads, mergedSaves: $mergedSaves, batchedLookups: $batchedLookups, splitBatches: $splitBatches, adoptedReads: $adoptedReads, '
      'wait: ${averageWaitMs.toStringAsFixed(1)} ms avg / $maxWaitMs ms max)';
}
