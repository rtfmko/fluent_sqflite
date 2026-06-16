import '../utils/utils.dart';

/// Represents a database change event dispatched by the [FluentEngine].
///
/// This event is emitted whenever a write operation (Save, Update, Delete)
/// successfully completes. It carries the metadata about the operation,
/// the affected model type, and the modified data payload.
class FluentChangeEvent<T> {
  /// The [Type] of the model affected by the operation (e.g., `User`).
  final Type modelType;

  /// The type of operation performed on the database (e.g., [FluentDbAction.save]).
  final FluentDbAction action;

  /// The data payload associated with the event.
  ///
  /// For single-item operations, this contains the affected [T] object.
  /// For bulk operations, this typically contains the `List<T>` of affected items.
  final T? data;

  /// An optional custom identifier or tag used to filter events.
  ///
  /// This is useful for distinguishing between different sources of updates,
  /// such as 'api_sync', 'background_worker', or UI-triggered events.
  final Object? customTag;

  /// Creates a [FluentChangeEvent] instance.
  FluentChangeEvent({
    required this.modelType,
    required this.action,
    this.data,
    this.customTag,
  });

  @override
  String toString() => 'ChangeEvent(type: $modelType, action: ${action.name}, tag: $customTag)';
}