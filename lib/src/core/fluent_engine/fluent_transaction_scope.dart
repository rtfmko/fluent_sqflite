// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The open transaction of one database, bound to the current [Zone].
///
/// Everything that runs inside [run] — provider executors, nested `FluentDb` calls, relation writers — finds the
/// transaction through [of] instead of a shared mutable field, so code outside the transaction never sees it.
/// Calls made inside the scope bypass the engine queue (the transaction itself holds the database's write slot),
/// and their change events are published only after the commit.
@internal
class FluentTransactionScope {
  /// Creates a scope for [txn] of the database group [dbName].
  FluentTransactionScope(this.dbName, this.txn);

  /// The database group the transaction belongs to.
  final String dbName;

  /// The open transaction.
  final Transaction txn;

  /// Writes made inside the scope, published as change events after the commit.
  final List<(FluentTask, FluentProvider, Object?)> pendingEvents = [];

  /// Other tables changed by those writes (relations, cascades), published after the commit too.
  final List<(FluentTask, FluentProvider, List<FluentTouchedTable>)> pendingTouched = [];

  /// Changes to the app's models that only hold once the writes are committed (see [whenCommitted]).
  final List<void Function()> _afterCommit = [];

  /// Runs [change] once the open transaction of [dbName] commits (dropped when it or the savepoint it was registered
  /// in rolls back); at once when no transaction is open.
  static void whenCommitted(String dbName, void Function() change) {
    final FluentTransactionScope? scope = of(dbName);
    if (scope == null) {
      change();
    } else {
      scope._afterCommit.add(change);
    }
  }

  /// Runs the [whenCommitted] changes; called once the transaction of this scope committed.
  void committed() {
    final List<void Function()> changes = List.of(_afterCommit);
    _afterCommit.clear();
    for (final void Function() change in changes) {
      try {
        change();
      } catch (e, s) {
        FluentLog.report(e, stackTrace: s, tag: 'FluentTransactionScope');
      }
    }
  }

  static final Object _zoneKey = Object();

  /// Whether the transaction body ended (committed or rolled back). Code created inside the body (timers, listeners,
  /// unawaited futures) keeps the zone, but no longer sees the scope: its calls run on their own.
  bool get closed => _closed;
  bool _closed = false;

  /// Whether the body has started: the first [run] of a scope is its transaction body; later ones (reads adopted by the
  /// transaction watchdog) only join it.
  bool _started = false;

  /// Savepoints opened so far (unique names for nested joins).
  int _savepoints = 0;

  /// The innermost open scope of the current zone, if any.
  static FluentTransactionScope? get current {
    final FluentTransactionScope? scope = Zone.current[_zoneKey] as FluentTransactionScope?;
    return scope == null || scope._closed ? null : scope;
  }

  /// The open transaction of [dbName] in the current zone, if any.
  static FluentTransactionScope? of(String dbName) {
    final FluentTransactionScope? scope = current;
    return scope != null && scope.dbName == dbName ? scope : null;
  }

  /// Runs [body] with this scope visible to everything it calls. The first call is the transaction body: the scope
  /// is [closed] when it ends.
  Future<R> run<R>(Future<R> Function() body) {
    if (_started) return runZoned(body, zoneValues: {_zoneKey: this});
    _started = true;
    return runZoned(() => Future<R>.sync(body), zoneValues: {_zoneKey: this}).whenComplete(() async {
      // Reads the watchdog moved into the transaction finish before it ends: no statement may reach a closed one.
      await _drainAdopted();
      _closed = true;
    });
  }

  /// Reads adopted by the transaction watchdog that still run.
  final Set<Future<void>> _adopted = {};

  /// Registers a read the watchdog runs inside this transaction (awaited before the transaction ends).
  void adopt(Future<void> read) {
    _adopted.add(read);
    unawaited(read.whenComplete(() => _adopted.remove(read)));
  }

  Future<void> _drainAdopted() async {
    while (_adopted.isNotEmpty) {
      await Future.wait(_adopted.toList());
    }
  }

  /// Runs [action] in a `SAVEPOINT` of this transaction (a nested `FluentDb.transaction`): when it throws, only its
  /// writes, pending events and [whenCommitted] changes are rolled back and the error is rethrown.
  Future<R> savepoint<R>(Future<R> Function() action) => _inSavepoint((_) => action());

  /// Runs [action] in the open transaction of [db] / [dbName], or opens one (and a scope for it) when there is none.
  ///
  /// Joining an open transaction runs [action] inside a `SAVEPOINT`: when it fails, its writes are rolled back even
  /// if the caller catches the error and the transaction commits (a half-written `saveAll` never stays).
  static Future<R> inTransaction<R>(Database db, String dbName, Future<R> Function(Transaction txn) action) {
    final FluentTransactionScope? open = of(dbName);
    if (open != null) return open._inSavepoint(action);
    FluentTransactionScope? scope;
    return db.transaction((txn) => (scope = FluentTransactionScope(dbName, txn)).run(() => action(txn))).then((result) {
      scope?.committed();
      return result;
    });
  }

  Future<R> _inSavepoint<R>(Future<R> Function(Transaction txn) action) async {
    final String name = 'fluent_sp_${++_savepoints}'.quotedIdentifier;
    await txn.execute('SAVEPOINT $name');
    // What the savepoint's writes registered is dropped with them when it rolls back.
    final int events = pendingEvents.length;
    final int touched = pendingTouched.length;
    final int changes = _afterCommit.length;
    final R result;
    try {
      result = await action(txn);
    } catch (_) {
      if (pendingEvents.length > events) pendingEvents.removeRange(events, pendingEvents.length);
      if (pendingTouched.length > touched) pendingTouched.removeRange(touched, pendingTouched.length);
      if (_afterCommit.length > changes) _afterCommit.removeRange(changes, _afterCommit.length);
      try {
        await txn.execute('ROLLBACK TO $name');
        await txn.execute('RELEASE $name');
      } catch (e) {
        FluentLog.debug('Savepoint not rolled back: $e', tag: 'FluentTransactionScope');
      }
      rethrow;
    }
    await txn.execute('RELEASE $name');
    return result;
  }
}

/// A read-only connection of the read pool, lent by the engine to one running read task (see
/// `FluentDbConfig.readConnections`). Provider reads find it through [of] (`FluentProvider.executor`);
/// writes always use the main connection.
@internal
class FluentReadScope {
  FluentReadScope._(this.dbName, this.db);

  /// The database group of the connection.
  final String dbName;

  /// The read-only connection.
  final Database db;

  static final Object _zoneKey = Object();

  /// The pooled read connection of [dbName] in the current zone, if any.
  static Database? of(String dbName) {
    final FluentReadScope? scope = Zone.current[_zoneKey] as FluentReadScope?;
    return scope != null && scope.dbName == dbName ? scope.db : null;
  }

  /// Runs [body] with [db] as the read connection of [dbName].
  static Future<R> run<R>(String dbName, Database db, Future<R> Function() body) => runZoned(body, zoneValues: {_zoneKey: FluentReadScope._(dbName, db)});
}
