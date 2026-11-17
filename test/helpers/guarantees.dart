// Checks shared by every guarantee test (TEST_PLAN.md). Cheap enough to run after every scenario.

import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// G19: the file is intact — `integrity_check` is ok and no foreign key points nowhere.
Future<void> expectIntegrity(Database db, {String? reason}) async {
  final List<Map<String, Object?>> integrity = await db.rawQuery('PRAGMA integrity_check');
  expect(integrity.map((r) => r.values.first).toList(), ['ok'], reason: 'G19 integrity_check ${reason ?? ''}');
  final List<Map<String, Object?>> fk = await db.rawQuery('PRAGMA foreign_key_check');
  expect(fk, isEmpty, reason: 'G19 foreign_key_check ${reason ?? ''}');
}

/// The settled outcome of one call: its value or its error.
class Settled {
  Settled.value(this.value) : error = null;
  Settled.error(this.error) : value = null;

  final Object? value;
  final Object? error;

  bool get failed => error != null;
}

/// G12: every one of [calls] completes (value or error) within [timeout]; else the test fails naming the calls that
/// hang ([names], same order). Errors must be typed (G13): a [FluentException] with a hint.
Future<List<Settled>> waitAllSettled(List<Future<Object?>> calls, {List<String>? names, Duration timeout = const Duration(seconds: 10), bool typedErrors = true}) async {
  final List<Settled?> out = List.filled(calls.length, null);
  await Future.wait([
    for (int i = 0; i < calls.length; i++)
      calls[i].then((v) => out[i] = Settled.value(v), onError: (Object e) => out[i] = Settled.error(e)),
  ]).timeout(timeout, onTimeout: () => const []);
  final List<int> hanging = [for (int i = 0; i < out.length; i++) if (out[i] == null) i];
  if (hanging.isNotEmpty) fail('G12: ${hanging.length} call(s) never completed: ${hanging.map((i) => names?[i] ?? '#$i').join(', ')}');
  final List<Settled> settled = out.cast<Settled>();
  if (typedErrors) {
    for (int i = 0; i < settled.length; i++) {
      if (settled[i].failed) expectTypedError(settled[i].error!, reason: names?[i]);
    }
  }
  return settled;
}

/// G13 / G26: [error] is a [FluentException] with a non-empty hint (what → why → how to fix).
void expectTypedError(Object error, {String? reason}) {
  expect(error, isA<FluentException>(), reason: 'G13: errors reach the app typed ${reason ?? ''} (got ${error.runtimeType}: $error)');
  final FluentException e = error as FluentException;
  expect(e.hint, isNotNull, reason: 'G26: ${e.code.name} has a hint ${reason ?? ''}');
  expect(e.hint!.trim(), isNotEmpty, reason: 'G26: ${e.code.name} has a hint ${reason ?? ''}');
}

/// G26: every issue says how to fix it.
void expectIssuesHaveFixes(Iterable<FluentIssue> issues) {
  for (final FluentIssue i in issues) {
    expect(i.fix?.trim() ?? '', isNotEmpty, reason: 'G26: issue ${i.kind.name} "${i.title}" has a fix');
  }
}

/// G15 / G25: collects every log record while installed; checks that no secret value or path leaked.
class LogWatch {
  LogWatch._();

  /// Every record since [install].
  final List<FluentLogRecord> records = [];

  /// Starts collecting (enables logging at debug level, no console). Call [uninstall] in tearDown.
  static LogWatch install() {
    final LogWatch w = LogWatch._();
    FluentDb.setupLogging(enabled: true, level: FluentLogLevel.debug, console: false, onRecord: w.records.add);
    return w;
  }

  /// Stops collecting.
  void uninstall() => FluentDb.setupLogging(removeOnRecord: true, enabled: false);

  /// The text a reader of the log sees for [r] (message, hint, context, error).
  static String textOf(FluentLogRecord r) => '${r.message} ${r.hint ?? ''} ${r.context ?? ''} ${r.error ?? ''}';

  /// G15: none of [secrets] (values the test saved / queried) and no absolute path appear in any record.
  void expectNoLeaks(Iterable<String> secrets) {
    final RegExp path = RegExp(r'[A-Za-z]:\\[^\s<]+|(?<![\w<])/(?:[\w.-]+/){2,}[\w.-]+');
    for (final FluentLogRecord r in records) {
      final String text = textOf(r);
      for (final String s in secrets) {
        if (s.length >= 4) expect(text.contains(s), isFalse, reason: 'G15: value "$s" leaked into: $text');
      }
      expect(path.hasMatch(text), isFalse, reason: 'G15: a path leaked into: $text');
    }
  }

  /// G25: a record of at least [level] mentions [part].
  void expectLogged(Pattern part, {FluentLogLevel level = FluentLogLevel.warning}) {
    expect(records.any((r) => r.level.index >= level.index && textOf(r).contains(part)), isTrue, reason: 'G25: "$part" was logged');
  }
}

/// Compares two row lists order-insensitively by [key], with a readable diff of missing / extra / changed rows.
void expectSameRows(List<Map<String, Object?>> actual, List<Map<String, Object?>> expected, {required String Function(Map<String, Object?> row) key, String? reason}) {
  final Map<String, Map<String, Object?>> a = {for (final r in actual) key(r): r};
  final Map<String, Map<String, Object?>> e = {for (final r in expected) key(r): r};
  final List<String> problems = [
    for (final String k in e.keys) if (!a.containsKey(k)) 'missing $k: ${e[k]}',
    for (final String k in a.keys) if (!e.containsKey(k)) 'extra $k: ${a[k]}',
    for (final String k in e.keys)
      if (a.containsKey(k) && !_sameRow(a[k]!, e[k]!)) 'changed $k: expected ${e[k]}, got ${a[k]}',
  ];
  if (actual.length != a.length) problems.add('duplicate keys in the result (${actual.length} rows, ${a.length} keys)');
  if (problems.isNotEmpty) fail('${reason ?? 'rows differ'}:\n  ${problems.join('\n  ')}');
}

bool _sameRow(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, Object?> e in b.entries) {
    if (!a.containsKey(e.key)) return false;
    final Object? x = a[e.key];
    final Object? y = e.value;
    if (x is DateTime && y is DateTime) {
      if (x != y) return false; // same instant and same UTC flag
    } else if (x is List && y is List || x is Map && y is Map) {
      if (x.toString() != y.toString()) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}
