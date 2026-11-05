// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: implementation_imports
import 'package:sqflite_common/sqflite.dart' as sqflite;
import 'package:sqflite_common/src/mixin/import_mixin.dart' show SqfliteInvokeHandler, buildDatabaseFactory;

/// Counts the SQL statements that reach SQLite while it is installed (reads and writes).
///
/// Install it before the databases are opened; `FluentBenchmark.runScenarios` does that itself.
class FluentStatementCounter {
  FluentStatementCounter._(this._previous);

  final sqflite.DatabaseFactory _previous;

  /// Statements counted since the last [reset].
  int count = 0;

  /// Routes the global database factory through a counter, or returns `null` when the factory cannot be wrapped.
  static Future<FluentStatementCounter?> tryInstall() async {
    try {
      final sqflite.DatabaseFactory inner = sqflite.databaseFactory;
      if (inner is! SqfliteInvokeHandler) return null;
      final SqfliteInvokeHandler handler = inner as SqfliteInvokeHandler; // ignore: unnecessary_cast
      final FluentStatementCounter counter = FluentStatementCounter._(inner);
      final sqflite.DatabaseFactory counting = buildDatabaseFactory(
        tag: 'fluent_benchmark_counting',
        invokeMethod: (String method, [Object? arguments]) {
          if (arguments is Map) {
            if (arguments['sql'] != null) {
              counter.count++;
            } else if (arguments['operations'] is List) {
              counter.count += (arguments['operations'] as List<dynamic>).length;
            }
          }
          return handler.invokeMethod<Object?>(method, arguments);
        },
      );
      await counting.setDatabasesPath(await inner.getDatabasesPath());
      sqflite.databaseFactoryOrNull = counting;
      return counter;
    } on Object {
      return null;
    }
  }

  /// Starts counting from zero.
  void reset() => count = 0;

  /// Restores the previous factory.
  void uninstall() => sqflite.databaseFactoryOrNull = _previous;
}
