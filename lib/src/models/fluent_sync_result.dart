import '../utils/utils.dart';

/// Represents the outcome of a [FluentSyncStrategy] execution.
///
/// This object encapsulates the result of a synchronization process, providing
/// both status indicators and metadata about the processed items. It is returned
/// by [FluentProviderSyncExtension.syncWithServer] to allow the UI or business
/// logic to react to the sync status.
class FluentSyncResult<T> {
  /// The [FluentSyncStrategy] that was attempted.
  final FluentSyncStrategy strategy;

  /// Whether the synchronization process was completed successfully.
  final bool isSuccess;

  /// The number of items that were successfully pushed, pulled, or purged.
  final int itemsProcessed;

  /// A descriptive message detailing the cause of a failure, if [isSuccess] is false.
  final String? errorMessage;

  /// The original error object or exception thrown during the process, if any.
  final Object? error;

  /// Creates a [FluentSyncResult] instance.
  const FluentSyncResult({required this.strategy, required this.isSuccess, this.itemsProcessed = 0, this.errorMessage, this.error});
}
