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
  final List<T>? data;

  /// An error object if the pipeline entered the [FluentPipelinePhase.error] state.
  final Object? error;

  /// Returns `true` if the pipeline has finished its execution (successfully or not).
  bool get isTerminal => phase == FluentPipelinePhase.completed || phase == FluentPipelinePhase.error;

  /// Creates a [FluentDataEvent].
  const FluentDataEvent({required this.phase, this.data, this.error});
}
