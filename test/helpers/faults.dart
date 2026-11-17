// Statement-level fault injection and crash simulation for the guarantee tests (TEST_PLAN.md, techniques 5-7).
//
// The library opens every database through sqflite's global `databaseFactory`, so a wrapping factory sees every
// SQL call (reads, writes, BEGIN / COMMIT / SAVEPOINT, batches, open / close) without any change to the library.
// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:sqflite_common/src/exception.dart' show SqfliteDatabaseException;
import 'package:sqflite_common/src/mixin/import_mixin.dart' show SqfliteInvokeHandler, buildDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The SQLite error an injected failure looks like.
enum FaultKind {
  /// `SQLITE_IOERR` (10): the disk failed.
  ioError(10, 'disk I/O error'),

  /// `SQLITE_FULL` (13): the disk is full.
  full(13, 'database or disk is full'),

  /// `SQLITE_BUSY` (5): another connection holds the lock.
  busy(5, 'database is locked'),

  /// `SQLITE_READONLY` (8): the file cannot be written.
  readOnly(8, 'attempt to write a readonly database');

  const FaultKind(this.code, this.text);

  /// The SQLite result code.
  final int code;

  /// The SQLite message.
  final String text;
}

/// One call that reached SQLite.
class SqlCall {
  SqlCall(this.index, this.method, this.sql, this.inTransaction, this.batchSql);

  /// Position among all calls since [FaultyDatabaseFactory.install] (0-based).
  final int index;

  /// sqflite method: execute, insert, update, query, batch, openDatabase, closeDatabase, queryCursorNext, ...
  final String method;

  /// The SQL (`null` for open / close / cursor calls; for a batch the first statement).
  final String? sql;

  /// Whether sqflite marked it as part of a transaction.
  final bool inTransaction;

  /// Every statement of a batch (empty otherwise).
  final List<String> batchSql;

  String get _head => (sql ?? '').trimLeft().toUpperCase();

  /// A read (SELECT, read-only PRAGMA, cursor).
  bool get isRead => method == 'query' || method == 'queryCursorNext';

  /// A write (INSERT / UPDATE / DELETE / DDL / batch), not transaction control.
  bool get isWrite => (method == 'insert' || method == 'update' || method == 'batch' || method == 'execute') && !isControl;

  /// BEGIN / COMMIT / END / ROLLBACK / SAVEPOINT / RELEASE.
  bool get isControl => method == 'execute' && RegExp(r'^(BEGIN|COMMIT|END|ROLLBACK|SAVEPOINT|RELEASE)\b').hasMatch(_head);

  /// COMMIT / END / RELEASE (a commit point).
  bool get isCommit => method == 'execute' && RegExp(r'^(COMMIT|END|RELEASE)\b').hasMatch(_head);

  /// ROLLBACK (also ROLLBACK TO): recovery, never failed unless asked.
  bool get isRollback => method == 'execute' && _head.startsWith('ROLLBACK');

  /// Whether [pattern] matches the SQL (or any statement of a batch).
  bool matches(Pattern pattern) => [?sql, ...batchSql].any((s) => s.contains(pattern));

  @override
  String toString() => '#$index $method${inTransaction ? ' (txn)' : ''}: ${sql ?? ''}${batchSql.length > 1 ? ' (+${batchSql.length - 1} in batch)' : ''}';
}

class _Rule {
  _Rule(this.where, this.kind, {this.skip = 0, this.times, this.random, this.probability = 1});

  final bool Function(SqlCall call) where;
  final FaultKind kind;
  int skip;
  int? times;
  final Random? random;
  final double probability;

  bool fires(SqlCall call) {
    if (!where(call)) return false;
    if (skip > 0) {
      skip--;
      return false;
    }
    if (times != null && times! <= 0) return false;
    if (random != null && random!.nextDouble() >= probability) return false;
    if (times != null) times = times! - 1;
    return true;
  }
}

/// A global [databaseFactory] that passes every call to the FFI factory and fails the ones the test asks for.
///
/// ```dart
/// final faults = await FaultyDatabaseFactory.install();   // before db.open
/// faults.failWhere((c) => c.isWrite && c.matches('INSERT'), times: 1);
/// await expectLater(notes.save(n), throwsA(isA<FluentException>()));
/// faults.heal();
/// ...
/// faults.uninstall();                                      // in tearDown, after db.close
/// ```
///
/// By default ROLLBACK and closeDatabase never fail (recovery must stay possible), unless `includeRecovery: true`.
class FaultyDatabaseFactory {
  FaultyDatabaseFactory._(this._previous);

  final DatabaseFactory _previous;
  final List<_Rule> _rules = [];
  final Set<String> _paths = {};
  bool _dead = false;
  int _next = 0;

  /// Every call since install (also the failed ones), oldest first.
  final List<SqlCall> calls = [];

  /// The calls that were failed on purpose.
  final List<SqlCall> injected = [];

  /// Runs before each call reaches SQLite (after the failure decision). May be async, e.g. to copy the files.
  FutureOr<void> Function(SqlCall call)? beforeEach;

  /// The database files opened through this factory.
  Set<String> get paths => Set.unmodifiable(_paths);

  /// Whether [die] was called (and not [heal]ed).
  bool get isDead => _dead;

  /// Routes the global [databaseFactory] through the faults (call before opening the databases).
  static Future<FaultyDatabaseFactory> install() async {
    final DatabaseFactory inner = databaseFactory;
    final FaultyDatabaseFactory f = FaultyDatabaseFactory._(inner);
    final DatabaseFactory wrapped = buildDatabaseFactory(
      tag: 'faulty',
      invokeMethod: (String method, [Object? arguments]) async {
        final Map<Object?, Object?> args = arguments is Map ? arguments.cast<Object?, Object?>() : const {};
        final List<String> batch = [
          if (method == 'batch')
            for (final Object? op in (args['operations'] as List<Object?>? ?? const [])) if (op is Map && op['sql'] is String) op['sql']! as String,
        ];
        final SqlCall call = SqlCall(f._next++, method, (args['sql'] as String?) ?? batch.firstOrNull, args['inTransaction'] == true, batch);
        f.calls.add(call);
        if (method == 'openDatabase' && args['path'] is String) f._paths.add(args['path']! as String);
        f._check(call);
        await f.beforeEach?.call(call);
        return (inner as SqfliteInvokeHandler).invokeMethod<Object?>(method, arguments);
      },
    );
    await wrapped.setDatabasesPath(await inner.getDatabasesPath());
    databaseFactoryOrNull = wrapped; // the setter without the "changing the default factory" warning
    return f;
  }

  /// Restores the previous factory (after the databases are closed).
  void uninstall() => databaseFactoryOrNull = _previous;

  bool _recovery(SqlCall c) => c.isRollback || c.method == 'closeDatabase';

  void _check(SqlCall call) {
    if (_dead) {
      if (call.method == 'closeDatabase' || call.method == 'deleteDatabase' || call.method == 'databaseExists' || call.method == 'getDatabasesPath') return;
      injected.add(call);
      throw SqfliteDatabaseException('SqliteException(${FaultKind.ioError.code}): ${FaultKind.ioError.text} (the app died)', null, resultCode: FaultKind.ioError.code);
    }
    for (final _Rule r in _rules) {
      if (r.fires(call)) {
        injected.add(call);
        throw SqfliteDatabaseException('SqliteException(${r.kind.code}): ${r.kind.text} (injected)', null, resultCode: r.kind.code);
      }
    }
  }

  bool Function(SqlCall) _guard(bool Function(SqlCall)? where, bool includeRecovery) =>
      (c) => (includeRecovery || !_recovery(c)) && (where == null || where(c));

  /// Fails the [n]-th (0-based) call from now that matches [where].
  void failNth(int n, {bool Function(SqlCall call)? where, FaultKind kind = FaultKind.ioError, bool includeRecovery = false}) =>
      _rules.add(_Rule(_guard(where, includeRecovery), kind, skip: n, times: 1));

  /// Fails the calls matching [where] ([times] of them, or all).
  void failWhere(bool Function(SqlCall call) where, {int? times, FaultKind kind = FaultKind.ioError, bool includeRecovery = false}) =>
      _rules.add(_Rule(_guard(where, includeRecovery), kind, times: times));

  /// Fails calls matching [where] (default: any) at random with [probability], seeded.
  void failRandomly(int seed, double probability, {bool Function(SqlCall call)? where, FaultKind kind = FaultKind.ioError, bool includeRecovery = false}) =>
      _rules.add(_Rule(_guard(where, includeRecovery), kind, random: Random(seed), probability: probability));

  /// "The app died": copies the current files of every open database into [copyTo] (when given) and fails every
  /// further call (close / delete still pass, so tests can clean up). Returns original path → copied path.
  Future<Map<String, String>> die({String? copyTo}) async {
    final Map<String, String> copies = copyTo == null ? const {} : await copyFiles(copyTo);
    _dead = true;
    return copies;
  }

  /// Removes every rule and revives a dead factory.
  void heal() {
    _rules.clear();
    _dead = false;
  }

  /// Copies each open database file with its `-wal` / `-journal` companions into [dir] — the state a
  /// killed process leaves on disk. Returns original path → copied path of the main file.
  Future<Map<String, String>> copyFiles(String dir) async {
    await Directory(dir).create(recursive: true);
    final Map<String, String> out = {};
    for (final String p in _paths) {
      if (!File(p).existsSync()) continue;
      final String name = p.split(RegExp(r'[\\/]')).last;
      final String target = '$dir${Platform.pathSeparator}$name';
      // -shm is rebuilt on open (and locked on Windows).
      for (final String suffix in const ['', '-wal', '-journal']) {
        final File f = File('$p$suffix');
        if (f.existsSync()) await f.copy('$target$suffix');
      }
      out[p] = target;
    }
    return out;
  }
}

/// Runs [write] and copies the database files before each write / commit statement it sends, into
/// `<dir>/crash_<n>/`: every copy is a state a process killed at that moment leaves behind (G14).
Future<List<Map<String, String>>> captureCrashStates(FaultyDatabaseFactory faults, String dir, Future<void> Function() write, {bool Function(SqlCall call)? at}) async {
  final List<Map<String, String>> states = [];
  int n = 0;
  final FutureOr<void> Function(SqlCall)? previous = faults.beforeEach;
  faults.beforeEach = (SqlCall c) async {
    await previous?.call(c);
    if (at != null ? at(c) : (c.isWrite || c.isCommit)) states.add(await faults.copyFiles('$dir${Platform.pathSeparator}crash_${n++}'));
  };
  try {
    await write();
  } finally {
    faults.beforeEach = previous;
  }
  states.add(await faults.copyFiles('$dir${Platform.pathSeparator}crash_${n++}')); // after the commit
  return states;
}
