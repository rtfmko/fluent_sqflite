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

  /// The list of items affected by this database operation.
  ///
  /// Always returns a [List], even if only a single item was saved/deleted.
  final List<T> items;

  /// An optional custom identifier or tag used to filter events.
  ///
  /// This is useful for distinguishing between different sources of updates,
  /// such as 'api_sync', 'background_worker', or UI-triggered events.
  final Object? customTag;

  /// Creates a [FluentChangeEvent] instance.
  FluentChangeEvent({required this.modelType, required this.action, this.items = const [], this.customTag});

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentChangeEvent{');
    sb.write('model: ${modelType.toString()}');
    sb.write(', action: ${action.name}');
    sb.write(', itemsCount: ${items.length}');

    if (customTag != null) {
      sb.write(', tag: $customTag');
    }

    sb.write('}');
    return sb.toString();
  }
}
