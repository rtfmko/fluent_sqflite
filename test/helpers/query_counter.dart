// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'package:sqflite_common/src/mixin/import_mixin.dart' show SqfliteInvokeHandler, buildDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Counts the SQL statements that reach SQLite (reads and writes), for tests that guard against N+1 patterns.
///
/// ```dart
/// final counter = await QueryCounter.install();
/// ...
/// counter.reset(); await provider.findAll(); expect(counter.reads, 4);
/// await counter.uninstall();
/// ```
class QueryCounter {
  QueryCounter._(this._previous);

  final DatabaseFactory _previous;
  int reads = 0;
  int writes = 0;
  final List<String> statements = [];

  /// Routes the global [databaseFactory] through a counter (call before opening the databases).
  static Future<QueryCounter> install() async {
    final DatabaseFactory inner = databaseFactory;
    final QueryCounter counter = QueryCounter._(inner);
    final DatabaseFactory counting = buildDatabaseFactory(
      tag: 'counting',
      invokeMethod: (String method, [Object? arguments]) {
        final Object? sql = arguments is Map ? arguments['sql'] : null;
        if (method == 'query') counter.reads++;
        if (method == 'execute' || method == 'insert' || method == 'update' || method == 'batch') counter.writes++;
        if (sql != null) counter.statements.add('$method: $sql');
        return (inner as SqfliteInvokeHandler).invokeMethod<Object?>(method, arguments);
      },
    );
    await counting.setDatabasesPath(await inner.getDatabasesPath());
    databaseFactoryOrNull = counting; // the setter without the "changing default factory" console warning
    return counter;
  }

  /// Starts counting from zero.
  void reset() {
    reads = 0;
    writes = 0;
    statements.clear();
  }

  /// Restores the previous factory.
  void uninstall() => databaseFactoryOrNull = _previous;
}
