// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/utils.dart';

/// Represents an event emitted by the [reactiveSync] pipeline during its
/// execution lifecycle.
///
/// Use this class to observe the synchronization state in your UI layer.
/// It encapsulates the current [phase], the processed [data] (if available),
/// and any potential [error] encountered.
class FluentDataEvent<T> {
  /// The current state of the synchronization process.
  final FluentPipelinePhase phase;

  /// The dataset associated with the current phase.
  ///
  /// Usually populated when [phase] is [FluentPipelinePhase.cacheReady]
  /// or [FluentPipelinePhase.apiReady].
  final List<T> data;

  /// An error object if the pipeline entered the [FluentPipelinePhase.error] state.
  final Object? error;

  /// The time elapsed since the synchronization pipeline started, in milliseconds.
  ///
  /// This provides a precise metric for performance tracking and profiling
  /// of the synchronization process at each phase.
  final int? executionMs;

  /// The provenance (origin) of the data payload.
  ///
  /// This indicates whether the [data] was retrieved from the local database
  /// ([FluentDataSource.cache]) or fetched directly from the remote backend
  /// ([FluentDataSource.api]).
  ///
  /// Use this to implement data freshness indicators in the UI or to
  /// conditionally execute business logic based on the authority of the data source.
  final FluentDataSource source;

  /// Returns `true` if the pipeline has finished its execution (successfully or not).
  bool get isTerminal => phase == FluentPipelinePhase.completed || phase == FluentPipelinePhase.error;

  /// Creates a [FluentDataEvent].
  const FluentDataEvent({required this.phase, this.data = const [], this.error, this.executionMs, this.source = FluentDataSource.none});

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentDataEvent{');
    final List<String> parts = [];

    parts.add('phase: ${phase.name}');
    parts.add('source: ${source.name}');
    parts.add('items: ${data.length}');

    if (executionMs != null) {
      parts.add('ms: $executionMs');
    }

    if (error != null) {
      parts.add('error: $error');
    }

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}
