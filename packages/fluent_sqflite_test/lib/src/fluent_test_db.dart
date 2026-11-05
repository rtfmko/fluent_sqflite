// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// Resetting the registry, the engine's idle state and the issue memory are internals of the library; this package is
// their only user outside it and always ships with the same version.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fluent_test_clock.dart';

/// A database for tests, opened the way an app opens it (`FluentDb.init` with one group), plus what tests need:
/// a [clock] to move, [settle] to wait for streams, the [issues] the library raised, and [restart] for migrations.
///
/// One test database is open at a time (the library has one registry): [open] closes the previous one.
///
/// ```dart
/// late FluentTestDb db;
/// setUp(() async {
///   db = FluentTestDb();
///   await db.open([TodoProvider()]);
/// });
/// tearDown(() => db.close());
/// ```
class FluentTestDb {
  /// A test database named [name] (unique by default).
  ///
  /// * [persistent]: a file in the temporary directory of `setUpFluentTests` instead of memory; needed for
  ///   [restart] (memory is gone after a close) and for read connections (`FluentDbConfig.readConnections`).
  /// * [failOnWarnings]: [close] fails the test when the library raised a warning or an error issue.
  FluentTestDb({String? name, this.persistent = false, this.failOnWarnings = false}) : name = name ?? 'test_${_counter++}';

  static int _counter = 0;
  static FluentTestDb? _current;

  /// The database name (the file `<name>.db` when [persistent]).
  final String name;

  /// Whether the database is a file (see [FluentTestDb.new]).
  final bool persistent;

  /// Whether [close] fails the test on warning or error issues.
  final bool failOnWarnings;

  /// The time the library sees; moved only when the test asks, back to the real time on [close].
  final FluentTestClock clock = FluentTestClock();

  final List<FluentIssue> _issues = [];
  StreamSubscription<FluentIssue>? _issueListener;

  /// The key of this database, for calls that take `dbKey`.
  FluentDbKey get key => FluentDbKey(name);

  /// Every issue the library raised since [open]: hints (when diagnostics collect them), automatic changes, warnings
  /// and errors. "Once per run" issues are reported again for every test database.
  List<FluentIssue> get issues => List.unmodifiable(_issues);

  /// The warning and error issues among [issues].
  List<FluentIssue> get warnings => [for (final FluentIssue i in _issues) if (i.type == FluentIssueType.warning || i.type == FluentIssueType.error) i];

  /// Whether the database is open.
  bool get isOpen => identical(_current, this);

  /// Opens the database with [providers]; the other parameters are those of `FluentGroup` and `FluentDb.init`.
  /// Another test database still open is closed first; opening this one again starts its [issues] afresh but keeps
  /// its file (like [restart]).
  Future<void> open(
    List<FluentProvider> providers, {
    FluentDbConfig config = const FluentDbConfig(),
    FluentConfig fluentConfig = const FluentConfig(),
    FluentColumnRemoval removedColumns = FluentColumnRemoval.archive,
    Duration? archiveRetention = const Duration(days: 30),
    int historyLimit = 100,
    bool resetOnSchemaError = false,
    MigrationPlanCallback? onMigrationPlan,
  }) async {
    if (isOpen) {
      await _shut();
    } else {
      await closeCurrent();
    }
    await _issueListener?.cancel();
    _issues.clear();
    FluentLog.forgetIssues();
    _issueListener = FluentDb.onIssue().listen(_issues.add);
    await _init(providers, config, fluentConfig, removedColumns, archiveRetention, historyLimit, resetOnSchemaError, onMigrationPlan);
  }

  /// Simulates an app restart: closes the database and opens the same file again with [providers] (they may describe
  /// a newer schema, to test migrations). Needs [persistent]; [issues] and [clock] carry on.
  Future<void> restart(
    List<FluentProvider> providers, {
    FluentDbConfig config = const FluentDbConfig(),
    FluentConfig fluentConfig = const FluentConfig(),
    FluentColumnRemoval removedColumns = FluentColumnRemoval.archive,
    Duration? archiveRetention = const Duration(days: 30),
    int historyLimit = 100,
    bool resetOnSchemaError = false,
    MigrationPlanCallback? onMigrationPlan,
  }) async {
    if (!persistent) fail('FluentTestDb.restart needs FluentTestDb(persistent: true): a database in memory is gone after the close.');
    await _shut();
    await _init(providers, config, fluentConfig, removedColumns, archiveRetention, historyLimit, resetOnSchemaError, onMigrationPlan);
  }

  /// What opening the file with [providers] would change (see `FluentDb.planMigrations`), without changing it: test
  /// that a new version of the models keeps the data (`expect(plan.losesData, isFalse)`). The database is closed first
  /// when it is open (its file is kept); [open] or [restart] it afterwards.
  ///
  /// Another test database that is open stays open and usable: the plan runs beside it (the registry is only reset
  /// when no test database is open).
  Future<FluentMigrationPlan> plan(
    List<FluentProvider> providers, {
    FluentDbConfig config = const FluentDbConfig(),
    FluentConfig fluentConfig = const FluentConfig(),
    FluentColumnRemoval removedColumns = FluentColumnRemoval.archive,
    Duration? archiveRetention = const Duration(days: 30),
    bool runCode = false,
  }) async {
    if (isOpen) await _shut();
    final FluentTestDb? other = _current;
    if (other == null || !other.isOpen) FluentDbInternals.reset();
    final List<FluentMigrationPlan> plans = await FluentDb.planMigrations([
      FluentGroup(dbKey: key, providerList: providers, config: config, removedColumns: removedColumns, archiveRetention: archiveRetention, inMemory: !persistent),
    ], config: fluentConfig, runCode: runCode);
    return plans.single;
  }

  Future<void> _init(
    List<FluentProvider> providers,
    FluentDbConfig config,
    FluentConfig fluentConfig,
    FluentColumnRemoval removedColumns,
    Duration? archiveRetention,
    int historyLimit,
    bool resetOnSchemaError,
    MigrationPlanCallback? onMigrationPlan,
  ) async {
    FluentDbInternals.reset();
    _current = this;
    await FluentDb.init([
      FluentGroup(
        dbKey: key,
        providerList: providers,
        config: config,
        removedColumns: removedColumns,
        archiveRetention: archiveRetention,
        historyLimit: historyLimit,
        resetOnSchemaError: resetOnSchemaError,
        inMemory: !persistent,
        onMigrationPlan: onMigrationPlan,
      ),
    ], config: fluentConfig);
  }

  /// Waits until the library is quiet: no call queued or running, and no change for one [frame] (watch streams
  /// refresh after a change within a frame). Use it instead of `Future.delayed` after writes a stream should show.
  /// Fails the test when it is still busy after [timeout] (a stuck call or a transaction that never ends).
  Future<void> settle({Duration frame = const Duration(milliseconds: 20), Duration timeout = const Duration(seconds: 30)}) async {
    final FluentEngine engine = FluentEngine();
    final Stopwatch waited = Stopwatch()..start();
    while (true) {
      final Duration left = timeout - waited.elapsed;
      if (left <= Duration.zero || !await engine.whenIdle(left)) {
        fail('FluentTestDb.settle: the library is still busy after $timeout (a stuck call or a transaction that never ends).');
      }
      bool changed = false;
      final StreamSubscription<Object?> changes = engine.changeStream.listen((_) => changed = true);
      await Future<void>.delayed(frame);
      await changes.cancel();
      if (!changed && engine.isIdle) return;
    }
  }

  /// Closes the database, removes its file (unless [keepFile], e.g. to inspect it), puts the [clock] back, and — with
  /// [failOnWarnings] — fails the test when warnings were raised. Safe to call twice.
  Future<void> close({bool keepFile = false}) async {
    if (isOpen) await _shut();
    await _issueListener?.cancel();
    _issueListener = null;
    clock.reset();
    if (persistent && !keepFile) await databaseFactory.deleteDatabase('${await getDatabasesPath()}/$name.db');
    final List<FluentIssue> raised = warnings;
    if (failOnWarnings && raised.isNotEmpty) {
      _issues.clear();
      fail('The library raised ${raised.length} warning(s):\n${raised.map((i) => '* ${i.kind.name}: ${i.title}${i.fix == null ? '' : ' — ${i.fix}'}').join('\n')}');
    }
  }

  /// Closes the test database that is open, if any (see [close]).
  static Future<void> closeCurrent() async => _current?.close();

  Future<void> _shut() async {
    _current = null;
    await FluentDb.close();
    FluentDbInternals.reset();
  }
}
