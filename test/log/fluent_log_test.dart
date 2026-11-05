// FluentLog: levels, sinks, mute patterns, once-per-run vs repeats, capture, redaction, record formatting.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  final List<FluentLogRecord> records = [];

  setUp(() {
    FluentLog.reset();
    records.clear();
    FluentLog.configure(enabled: true, console: false, level: FluentLogLevel.sql, onRecord: records.add);
  });

  tearDown(() {
    FluentLog.reset();
    FluentLog.configure(enabled: false);
  });

  const FluentIssue warning = FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: 'W 3 rows', fix: 'fix it');
  const FluentIssue change = FluentIssue(kind: FluentIssueKind.tuned, database: 'd', title: 'C', fix: 'f');

  group('levels', () {
    test('records below the level are dropped, isOn follows level and enabled', () {
      FluentLog.configure(level: FluentLogLevel.warning);
      FluentLog.info('i');
      FluentLog.debug('d');
      FluentLog.sql('s');
      expect(records, isEmpty);
      expect(FluentLog.isOn(FluentLogLevel.info), isFalse);
      expect(FluentLog.isOn(FluentLogLevel.error), isTrue);
      FluentLog.report(FluentConfigException('bad', hint: 'h'));
      expect(records.single.level, FluentLogLevel.warning);
      FluentLog.configure(enabled: false);
      expect(FluentLog.isEnabled, isFalse);
      expect(FluentLog.isOn(FluentLogLevel.error), isFalse);
      FluentLog.report(FluentConfigException('bad2', hint: 'h'));
      expect(records, hasLength(1));
    });

    test('reset restores the defaults', () {
      FluentLog.configure(showSqlArguments: true, mute: {'a:*'});
      FluentLog.reset();
      expect(FluentLog.isEnabled, isTrue);
      expect(FluentLog.showSqlArguments, isFalse);
      expect(FluentLog.mute, isEmpty);
      expect(FluentLog.level, FluentLogLevel.info);
    });

    test('sql shows only the number of arguments unless showSqlArguments', () {
      FluentLog.sql('SELECT 1', arguments: const ['secret', 2], tag: 'x');
      expect(records.single.message, 'SELECT 1 | Args: 2 hidden');
      FluentLog.configure(showSqlArguments: true);
      FluentLog.sql('SELECT 2', arguments: const ['secret']);
      expect(records.last.message, contains('[secret]'));
      FluentLog.sql('SELECT 3');
      expect(records.last.message, 'SELECT 3');
      FluentLog.sql('SELECT 4', arguments: const []);
      expect(records.last.message, 'SELECT 4');
    });
  });

  group('sink', () {
    test('a throwing sink never breaks the caller', () {
      FluentLog.configure(onRecord: (FluentLogRecord r) => throw StateError('sink broke'));
      expect(() => FluentLog.info('hello'), returnsNormally);
      final List<String?> lines = [];
      final DebugPrintCallback old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m);
      try {
        FluentLog.configure(console: true);
        FluentLog.info('hello');
      } finally {
        debugPrint = old;
      }
      expect(lines.any((String? l) => l!.contains('onRecord callback')), isTrue);
    });

    test('console output goes through debugPrint, with colors when asked', () {
      final List<String?> lines = [];
      final DebugPrintCallback old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => lines.add(m);
      try {
        FluentLog.configure(console: true, colors: true);
        FluentLog.info('colored');
        FluentLog.configure(colors: false);
        FluentLog.info('plain');
      } finally {
        debugPrint = old;
      }
      expect(lines.first, contains('\u001b['));
      expect(lines.last, isNot(contains('\u001b[')));
      expect(lines.last, contains('plain'));
    });
  });

  group('issues', () {
    test('mute: exact keys and prefix patterns; muted issues vanish from seen and the bus', () async {
      final List<FluentIssue> bus = [];
      final StreamSubscription<FluentIssue> sub = FluentLog.issues.listen(bus.add);
      FluentLog.configure(mute: {'schemaFallback:*'});
      expect(FluentLog.isMuted(warning.key), isTrue);
      expect(FluentLog.isMuted(change.key), isFalse);
      FluentLog.publish(warning);
      FluentLog.publish(change);
      await Future<void>.delayed(Duration.zero);
      expect(bus.map((FluentIssue i) => i.kind), [FluentIssueKind.tuned]);
      expect(FluentLog.seen.map((FluentIssue i) => i.kind), [FluentIssueKind.tuned]);
      FluentLog.configure(mute: {change.key});
      expect(FluentLog.isMuted(change.key), isTrue);
      expect(FluentLog.seen, isEmpty);
      expect(FluentLog.mute, {change.key});
      await sub.cancel();
    });

    test('warnings once per key and title without numbers, automatic changes every time', () {
      FluentLog.publish(warning);
      FluentLog.publish(warning);
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: 'W 99 rows', fix: 'fix it'));
      expect(FluentLog.seen.where((FluentIssue i) => i.kind == FluentIssueKind.schemaFallback), hasLength(1));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: 'Other thing', fix: 'f'));
      expect(FluentLog.seen, hasLength(2));
      FluentLog.publish(change);
      FluentLog.publish(change);
      expect(FluentLog.seen.where((FluentIssue i) => i.kind == FluentIssueKind.tuned), hasLength(2));
      expect(FluentLog.reported(warning.key), isTrue);
      expect(FluentLog.reported(change.key), isTrue);
      expect(FluentLog.reported('nothing:here'), isFalse);
      FluentLog.forgetIssues();
      expect(FluentLog.seen, isEmpty);
      expect(FluentLog.reported(warning.key), isFalse);
      FluentLog.publish(warning);
      expect(FluentLog.seen, hasLength(1));
    });

    test('repeating issues keep only the latest 200', () {
      for (int i = 0; i < 230; i++) {
        FluentLog.publish(FluentIssue(kind: FluentIssueKind.tuned, database: 'd', title: 'C$i', fix: 'f'));
      }
      expect(FluentLog.seen, hasLength(200));
      expect(FluentLog.seen.first.title, 'C30');
      expect(FluentLog.seen.last.title, 'C229');
    });

    test('hints are published while diagnostics collect them (default), logged at hint level', () {
      const FluentIssue hint = FluentIssue(kind: FluentIssueKind.missingIndex, database: 'nodb', table: 't', title: 'H', fix: 'f');
      expect(hint.type, FluentIssueType.hint);
      FluentLog.publish(hint);
      expect(FluentLog.shownHints, hasLength(1));
      expect(records.single.level, FluentLogLevel.hint);
    });

    test('issues are logged at the level of their type, with a tag from table or kind', () {
      FluentLog.publish(warning);
      FluentLog.publish(change);
      expect(records[0].level, FluentLogLevel.warning);
      expect(records[0].tag, 't:schemaFallback');
      expect(records[0].hint, 'fix it');
      expect(records[1].level, FluentLogLevel.autoFix);
      expect(records[1].tag, 'FluentDb:tuned');
      FluentLog.publish(change, tag: 'custom', context: const {'a': 1});
      expect(records.last.tag, 'custom');
      expect(records.last.context, {'a': 1});
      const FluentIssue errorIssue = FluentIssue(kind: FluentIssueKind.maintenanceFailed, title: 'E', fix: 'f');
      expect(errorIssue.type, FluentIssueType.error);
      FluentLog.publish(errorIssue);
      expect(records.last.level, FluentLogLevel.error);
    });

    test('the bus gets issues even below the log level', () async {
      FluentLog.configure(level: FluentLogLevel.error);
      final List<FluentIssue> bus = [];
      final StreamSubscription<FluentIssue> sub = FluentLog.issues.listen(bus.add);
      FluentLog.publish(warning);
      await Future<void>.delayed(Duration.zero);
      expect(bus, hasLength(1));
      expect(records, isEmpty);
      await sub.cancel();
    });

    test('issue() marks the FluentException as reported and formats details and code', () {
      final FluentConfigException e = FluentConfigException('boom', hint: 'h');
      FluentLog.issue(FluentIssueKind.tuned, 'T', hint: 'hh', database: 'db', subject: 's', details: 'det', code: 'code()', error: e);
      expect(e.reported, isTrue);
      final FluentIssue i = FluentLog.seen.single;
      expect(i.key, 'tuned:db::s');
      expect(i.details, 'det');
      expect(i.code, 'code()');
      FluentLog.report(e);
      expect(records.where((FluentLogRecord r) => r.message == 'boom'), isEmpty);
      final String text = records.single.format();
      expect(text, contains('det'));
      expect(text, contains('code()'));
      expect(text, contains("mute: FluentDb.setupLogging(mute: {'tuned:*'})"));
    });

    test('captureIssues collects instead of reporting (async and sync)', () async {
      final List<FluentIssue> into = [];
      await FluentLog.captureIssues(into, () async {
        await Future<void>.delayed(Duration.zero);
        FluentLog.publish(warning);
      });
      final int syncResult = FluentLog.captureIssuesSync(into, () {
        FluentLog.publish(change);
        return 7;
      });
      expect(syncResult, 7);
      expect(into.map((FluentIssue i) => i.kind), [FluentIssueKind.schemaFallback, FluentIssueKind.tuned]);
      expect(FluentLog.seen, isEmpty);
      expect(records, isEmpty);
      FluentLog.publish(warning);
      expect(FluentLog.seen, hasLength(1));
    });
  });

  group('raise / report', () {
    test('report logs a FluentException once as warning, with its hint', () {
      final FluentConfigException e = FluentConfigException('bad arg', hint: 'use x');
      FluentLog.report(e, tag: 'tag');
      FluentLog.report(e, tag: 'tag');
      expect(records, hasLength(1));
      expect(records.single.level, FluentLogLevel.warning);
      expect(records.single.hint, 'use x');
      expect(records.single.code, e.code);
      expect(records.single.format(), contains('HINT: use x'));
    });

    test('raise logs and returns, but defers inside a provider call', () {
      final FluentConfigException a = FluentLog.raise(FluentConfigException('a', hint: 'h'));
      expect(records, hasLength(1));
      expect(a.message, 'a');
      runZoned(() {
        final FluentConfigException b = FluentLog.raise(FluentConfigException('b', hint: 'h'));
        expect(b.reported, isFalse);
      }, zoneValues: {FluentLog.deferKey: true});
      expect(records, hasLength(1));
    });

    test('foreign errors become "Unexpected error" warnings and arrive redacted', () {
      FluentLog.report(StateError('failed args [secret, 1] more'), tag: 't');
      final FluentLogRecord r = records.single;
      expect(r.message, startsWith('Unexpected error'));
      expect(r.error, isA<FluentRedactedError>());
      final FluentRedactedError redacted = r.error! as FluentRedactedError;
      expect(redacted.type, contains('StateError'));
      expect(redacted.message, isNot(contains('secret')));
      expect(redacted.toString(), startsWith(redacted.type));
      expect(r.code, isNull);
      expect(r.message, isNot(contains('secret')));
    });

    test('showSqlArguments delivers the original error and text', () {
      FluentLog.configure(showSqlArguments: true);
      final StateError error = StateError('args [secret]');
      FluentLog.report(error);
      expect(records.single.error, same(error));
      expect(records.single.message, contains('secret'));
      expect(FluentLog.redact('args [secret]'), 'args [secret]');
    });

    test('an issue with a foreign error is redacted; a FluentException stays', () {
      FluentLog.issue(FluentIssueKind.tuned, 'T', hint: 'h', database: 'd', error: StateError('args [secret]'), table: 'tb', stackTrace: StackTrace.current);
      final FluentIssue i = FluentLog.seen.single;
      expect(i.error, isA<FluentRedactedError>());
      expect(i.table, 'tb');
      expect(i.stackTrace, isNotNull);
      final FluentConfigException e = FluentConfigException('x', hint: 'h');
      FluentLog.issue(FluentIssueKind.tuned, 'T2', hint: 'h', database: 'd', error: e);
      expect(FluentLog.seen.last.error, same(e));
      FluentLog.issue(FluentIssueKind.tuned, 'T3', hint: 'h', database: 'd', error: const FluentRedactedError(type: 'X', message: 'm'));
      expect(FluentLog.seen.last.error, isA<FluentRedactedError>());
    });

    test('redact hides sqflite args, details and ffi parameters', () {
      expect(FluentLog.redact('Error sql INSERT args [a, b] {details: path}'), isNot(contains('a, b')));
      expect(FluentLog.redact('x parameters: a, b) sql foo'), contains('parameters: hidden'));
      expect(FluentLog.redact('no secrets'), 'no secrets');
    });

    test('context strings are redacted in the record, other values kept', () {
      FluentLog.configure(level: FluentLogLevel.info);
      FluentLog.info('m', context: const {'s': 'args [secret]', 'n': 3});
      expect(records.single.context!['s'], 'args [hidden]');
      expect(records.single.context!['n'], 3);
    });
  });

  group('FluentLogRecord.format', () {
    final DateTime time = DateTime(2026, 1, 2, 3, 4, 5);

    test('every level has an icon and colors only when asked', () {
      for (final FluentLogLevel level in FluentLogLevel.values) {
        final FluentLogRecord r = FluentLogRecord(level: level, message: 'm', time: time, tag: 'a:b');
        final String plain = r.format();
        final String colored = r.format(colors: true);
        expect(plain, contains('[a] [b]'));
        expect(plain, isNot(contains('\u001b[')));
        expect(colored, contains('\u001b['));
        expect(r.toString(), plain);
      }
    });

    test('hint, context, cause and stack lines', () {
      final StackTrace stack = StackTrace.fromString(List.generate(12, (int i) => '#$i frame').join('\n'));
      final FluentLogRecord r = FluentLogRecord(
        level: FluentLogLevel.error,
        message: 'm',
        time: time,
        hint: 'a\nb',
        context: const {'k': 'v'},
        error: StateError('cause text'),
        stackTrace: stack,
      );
      final String text = r.format(colors: true);
      expect(text, contains('HINT: a\n   b'));
      expect(text, contains('CAUSE'));
      expect(text, contains('cause text'));
      expect(text, contains('{k: v}'));
      expect(text, contains('... 4 more'));
      expect(r.format(stackLines: 0), isNot(contains('#0 frame')));
      expect(r.format(stackLines: 12), isNot(contains('more')));
    });

    test('a FluentException with a cause shows the cause and its own hint', () {
      final FluentQueryException e = FluentQueryException('q failed', hint: 'try y', cause: StateError('inner'));
      final String text = FluentLogRecord(level: FluentLogLevel.warning, message: e.message, time: time, error: e).format();
      expect(text, contains('HINT: try y'));
      expect(text, contains('inner'));
      expect(text, contains('${e.code.name}: q failed'));
    });

    test('a custom redact is applied to message, hint, context and cause', () {
      final FluentLogRecord r = FluentLogRecord(level: FluentLogLevel.warning, message: 'SECRET', time: time, hint: 'SECRET', context: const {'a': 'SECRET'}, error: StateError('SECRET'));
      expect(r.format(redact: (String t) => t.replaceAll('SECRET', '***')), isNot(contains('SECRET')));
    });
  });
}
