import '../utils/utils.dart';

/// One change of one table, published after a write that changed rows (after the commit inside a transaction; a
/// rolled-back write publishes nothing). Tables a write changes besides its own (relations, cascades) get an event
/// too. Subscribe with `FluentDb.onEvent`, or use the watch calls, which re-read on these events.
class FluentChangeEvent<T> {
  /// The [Type] of the model affected by the operation (e.g., `User`).
  final Type modelType;

  /// What happened: saved, updated, deleted, restored or cleared.
  final FluentChangeKind kind;

  /// The models the call wrote, as far as known; empty when the rows are not known (deletes by key or filter, clears,
  /// cascades, raw SQL).
  final List<T> items;

  /// The `tag:` of the call that made the change (e.g. `'api_sync'`), to tell sources of changes apart.
  final Object? tag;

  /// The table that changed (one model type may be stored in several tables).
  final String table;

  /// The database of [table].
  final String dbName;

  /// Creates a [FluentChangeEvent] instance.
  FluentChangeEvent({required this.modelType, required this.table, required this.dbName, required this.kind, this.items = const [], this.tag});

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentChangeEvent{');
    sb.write('model: ${modelType.toString()}, table: $dbName/$table');
    sb.write(', kind: ${kind.name}');
    sb.write(', itemsCount: ${items.length}');

    if (tag != null) {
      sb.write(', tag: $tag');
    }

    sb.write('}');
    return sb.toString();
  }
}
