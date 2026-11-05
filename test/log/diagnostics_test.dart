// Issues (hints, automatic changes, warnings, errors), their routing and report, the diagnostics modes, and the tuner.
import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  final List<FluentIssue> issues = [];
  StreamSubscription<FluentIssue>? sub;

  DynamicProvider usersTable() => DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);

  Future<void> open({FluentConfig config = const FluentConfig(), FluentDbConfig dbConfig = const FluentDbConfig()}) async {
    db = FluentTestDb(name: 'diag_${DateTime.now().microsecondsSinceEpoch}');
    users = usersTable();
    FluentLog.reset();
    FluentDb.setupLogging(console: false);
    await db.open([users], fluentConfig: config, config: dbConfig);
    issues.clear();
    await sub?.cancel();
    sub = FluentDb.onIssue().listen(issues.add);
  }

  tearDown(() async {
    await sub?.cancel();
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  Future<void> until(bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  FluentTask read(String column) => FluentTask(
    table: users.tableName,
    dbName: users.dbName,
    action: FluentDbAction.find,
    helper: TableHelper(where: '"$column" = ?', whereArgs: const ['a'], shape: '"$column" = ?'),
  );

  Future<Set<String>> indexes() async => {for (final r in await users.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']! as String};

  group('Issues', () {
    test('hints and warnings are reported once, automatic changes and errors every time', () async {
      await open();
      const FluentIssue warning = FluentIssue(kind: FluentIssueKind.schemaFallback, table: 't', title: 'W', fix: 'f');
      const FluentIssue change = FluentIssue(kind: FluentIssueKind.tuned, database: 'd', title: 'C', fix: 'f');
      FluentLog.publish(warning);
      FluentLog.publish(warning);
      FluentLog.publish(change);
      FluentLog.publish(change);
      await pumpEventQueue();
      expect(issues.map((i) => i.title), ['W', 'C', 'C']);
      expect(warning.key, 'schemaFallback::t');
      expect(change.key, 'tuned:d');
    });

    test('onIssue filters by type and kind; muting a kind drops it everywhere', () async {
      await open();
      final List<FluentIssue> crashes = [];
      final StreamSubscription<FluentIssue> s = FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error}).listen(crashes.add);
      FluentDb.setupLogging(mute: {'unordered:*'});
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.slowRead, table: 'a', title: 'hint'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.unordered, table: 'a', title: 'muted'));
      FluentLog.issue(FluentIssueKind.maintenanceFailed, 'error', hint: 'h', error: StateError('x'));
      FluentLog.issue(FluentIssueKind.ignoredCall, 'warning', hint: 'h');
      await pumpEventQueue();
      await s.cancel();
      expect(crashes.map((i) => i.title), ['error', 'warning']);
      expect(issues.map((i) => i.title), isNot(contains('muted')));
    });

    test('the report groups hints by impact, then automatic changes, warnings and errors', () async {
      await open();
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.redundantIndex, table: 'a', title: 'small'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.missingIndex, table: 'a', subject: 'x', title: 'big', code: 'code();'));
      FluentLog.issue(FluentIssueKind.tuned, 'changed', hint: 'h');
      FluentLog.issue(FluentIssueKind.configFallback, 'warned', hint: 'h');
      final FluentReport report = FluentDb.report();
      expect(report.issues.map((i) => i.title).take(2), ['big', 'small']);
      final String text = '$report';
      expect(text.indexOf('Important — fix first'), lessThan(text.indexOf('Small wins')));
      expect(text, allOf(contains('Changed automatically'), contains('Warnings'), contains('code();')));
    });

    test('a forgotten pause is resumed and reported as an automatic change', () async {
      await open(config: const FluentConfig(pauseWatchdog: Duration(milliseconds: 50)));
      await FluentDb.pauseQueue();
      expect((await users.save(users.row(const {'id': 1, 'status': 'a'}))).inserted, 1);
      await pumpEventQueue();
      expect(issues.where((i) => i.kind == FluentIssueKind.queueResumed).single.type, FluentIssueType.autoFix);
    });
  });

  group('Diagnostics modes', () {
    test('none: nothing is measured, stored or suggested', () async {
      await open(dbConfig: const FluentDbConfig(diagnostics: FluentDiagnostics.none));
      for (int i = 0; i < 5; i++) {
        await users.find(where: FluentFilter.eq('status', 'a'));
      }
      expect(FluentDb.queryStats(dbKey: FluentDbKey(db.name)).queries, isEmpty);
      final List<Map<String, Object?>> stats = await users.rawQuery("SELECT name FROM sqlite_master WHERE name = '__fluent_stats'");
      expect(stats, isEmpty);
      FluentLog.publish(FluentIssue(kind: FluentIssueKind.slowRead, database: users.dbName, title: 'x'));
      expect(FluentLog.shownHints, isEmpty, reason: 'hints of this database are not collected');
    });

    test('the database setting wins over the global one', () async {
      await open(config: const FluentConfig(diagnostics: FluentDiagnostics.quiet), dbConfig: const FluentDbConfig(diagnostics: FluentDiagnostics.recommend));
      FluentLog.publish(FluentIssue(kind: FluentIssueKind.slowRead, database: users.dbName, title: 'kept'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.slowRead, database: 'other', title: 'dropped'));
      expect(FluentLog.shownHints.map((i) => i.title), ['kept']);
    });
  });

  group('Tuner', () {
    test('creates an index for a slow read, reports it with the code, and drops it when it does not help', () async {
      await open(config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
      final FluentTask task = read('status');
      FluentTuner().proposeIndex(task, users, const ['status']);
      await until(() => issues.any((i) => i.kind == FluentIssueKind.tuned));
      expect(await indexes(), contains('fluent_auto_users_status'));
      final FluentIssue created = issues.firstWhere((i) => i.kind == FluentIssueKind.tuned);
      expect(created.code, contains("FluentIndex(['status'])"));

      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(task), 10000);
      await until(() => issues.any((i) => i.kind == FluentIssueKind.tuningReverted));
      expect(await indexes(), isNot(contains('fluent_auto_users_status')));
    });

    test('keeps an index that helps, respects the cap, and does nothing without tuning', () async {
      await open(config: FluentConfig(diagnostics: FluentDiagnostics(tuning: FluentTuning.full.copyWith(maxIndexes: 1))));
      final FluentTask byStatus = read('status');
      FluentTuner().proposeIndex(byStatus, users, const ['status']);
      FluentTuner().proposeIndex(read('age'), users, const ['age']);
      await until(() => issues.any((i) => i.kind == FluentIssueKind.tuned));
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(byStatus), 1);
      await pumpEventQueue();
      expect(await indexes(), containsAll(['fluent_auto_users_status']));
      expect(await indexes(), isNot(contains('fluent_auto_users_age')), reason: 'maxIndexes: 1');
      await db.close();

      await open();
      FluentTuner().proposeIndex(read('status'), users, const ['status']);
      await pumpEventQueue();
      expect(await indexes(), isNot(contains('fluent_auto_users_status')), reason: 'recommend only suggests');
    });

    test('memory pressure frees SQLite memory and the cache comes back with the app', () async {
      await open(config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      expect(issues.where((i) => i.kind == FluentIssueKind.tuningReverted), isEmpty);
      expect(issues.where((i) => i.kind == FluentIssueKind.tuned && i.subject == 'memory'), hasLength(1), reason: issues.map((i) => i.title).join(' | '));
      await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(issues.where((i) => i.kind == FluentIssueKind.tuned && i.subject == 'memory'), hasLength(2));
      expect((await users.rawQuery('PRAGMA cache_size')).single.values.single, isNot(-FluentTuner.lowMemoryCacheKib));
    });

    test('in the background maintenance runs once and periodic maintenance waits', () async {
      await open(config: const FluentConfig(diagnostics: FluentDiagnostics.auto));
      await users.save(users.row(const {'id': 1, 'status': 'a'}));
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      expect(FluentTuner().defersMaintenance(users.dbName), isTrue);
      await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse);
      expect(await users.count(), 1);
    });

    test('the read pool follows the cores only with the readConnections lever', () {
      final FluentGroup group = FluentGroup(dbKey: FluentDbKey('pool'), providerList: [usersTable()]);
      expect(FluentTuner.readConnections(group, const FluentConfig()), 2);
      expect(FluentTuner.readConnections(group, const FluentConfig(diagnostics: FluentDiagnostics.auto)), (Platform.numberOfProcessors ~/ 2).clamp(1, 4));
    });
  });

  group('Source rules', () {
    test('every exception the library creates says how to fix it', () {
      final RegExp create = RegExp(r'(?<!class )\bFluent\w+Exception\(');
      final List<String> missing = [];
      for (final FileSystemEntity f in Directory('lib/src').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart') || f.path.endsWith('fluent_exceptions.dart')) continue;
        final String s = f.readAsStringSync();
        for (final RegExpMatch m in create.allMatches(s)) {
          int depth = 1;
          int i = m.end;
          while (depth > 0 && i < s.length) {
            if (s[i] == '(') depth++;
            if (s[i] == ')') depth--;
            i++;
          }
          if (!s.substring(m.start, i).contains('hint:')) missing.add('${f.path}: ${s.substring(m.start, i).split('\n').first}');
        }
      }
      expect(missing, isEmpty);
    });
  });
}
