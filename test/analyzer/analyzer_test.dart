// The analyzer: query plans of slow reads, measured hints, call-pattern detectors, the report, muting and release mode.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  final List<FluentLogRecord> records = [];
  final List<FluentIssue> published = [];
  late final Stream<FluentIssue> hints = FluentDb.onIssue(types: {FluentIssueType.hint});

  setUp(() async {
    db = FluentTestDb(name: 'analyzer_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
    await db.open([users]);
    records.clear();
    published.clear();
    FluentLog.reset();
    FluentAnalyzer().reset();
    FluentDb.setupLogging(console: false, onRecord: records.add);
  });

  tearDown(() async {
    FluentAnalyzer.releaseMode = false;
    FluentAnalyzer.clock = null;
    FluentDb.configure(const FluentConfig());
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  Set<String> kinds() => {for (final FluentIssue h in FluentLog.shownHints) h.kind.name};

  FluentTask read(String where, List<Object?> args, {String? orderBy, FluentDbAction action = FluentDbAction.find}) => FluentTask(
    table: users.tableName,
    dbName: users.dbName,
    action: action,
    helper: TableHelper(where: where, whereArgs: args, shape: where, orderBy: orderBy),
  );

  group('slow reads', () {
    test('the query plan of an unindexed filter gives the index, equality columns first, then the order', () async {
      await FluentAnalyzer().explain(read('"status" = ? AND "age" > ?', ['a', 3]), users, '~500 ms');
      final FluentIssue hint = FluentLog.shownHints.single;
      expect(hint.key, 'missingIndex:${users.dbName}:users:status,age');
      expect(hint.details, contains('SCAN'));
      expect(hint.code, contains("FluentIndex(['status', 'age'])"));

      await FluentAnalyzer().explain(read('"status" = ?', ['a'], orderBy: 'age DESC'), users, '~500 ms');
      expect(FluentLog.shownHints.map((h) => h.key), contains('missingIndex:${users.dbName}:users:status,age'), reason: 'same index serves the order');
    });

    test('a filter an index serves, or a read without filter and order, gets no index hint', () async {
      await FluentAnalyzer().explain(read('"email" = ?', ['a@x']), users, '~500 ms');
      await FluentAnalyzer().explain(FluentTask(table: users.tableName, dbName: users.dbName, action: FluentDbAction.find), users, '~500 ms');
      expect(FluentLog.shownHints, isEmpty);
    });

    test('in release (hintsInRelease) the plan is not read: the unindexed columns are suggested', () async {
      FluentAnalyzer.releaseMode = true;
      FluentDb.configure(const FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true)));
      await FluentAnalyzer().explain(read('"status" = ?', ['a']), users, '~500 ms');
      expect(FluentLog.shownHints.single.key, endsWith(':users:status'));
      expect(FluentLog.shownHints.single.details, isNot(contains('Query plan')));
    });

    test("LIKE '%…' gets a prefix hint (by the average of several runs), startsWith does not", () {
      final FluentTask prefix = read('"email" LIKE ?', ['a%']);
      final FluentTask contains = read('"status" = ? AND "email" LIKE ?', ['x', '%a%']);
      for (final FluentTask t in [prefix, contains]) {
        for (int i = 0; i < FluentTableStatsTracker.minSamples; i++) {
          FluentTableStatsTracker().record(t, 50);
        }
      }
      FluentAnalyzer().onFinish(prefix, users, 50, const []);
      expect(FluentLog.shownHints, isEmpty);
      FluentAnalyzer().onFinish(contains, users, 50, const []);
      expect(FluentLog.shownHints.single.key, 'like:${users.dbName}:users:email');
    });

  });

  group('call patterns', () {
    test('a loop of awaited single saves gets saveAll; merged or batched saves do not', () async {
      await users.saveAll([for (int i = 0; i < 100; i++) users.row({'id': i, 'email': 'b$i'})]);
      await Future.wait([for (int i = 100; i < 200; i++) users.save(users.row({'id': i, 'email': 'b$i'}))]);
      expect(kinds(), isNot(contains('saveLoop')));
      for (int i = 200; i < 200 + FluentAnalyzer.saveLoopCalls; i++) {
        await users.save(users.row({'id': i, 'email': 'b$i'}));
      }
      expect(kinds(), contains('saveLoop'));
      expect(FluentLog.shownHints.firstWhere((h) => h.kind.name == 'saveLoop').code, contains('saveAll'));
    });

    test('a loop of awaited findById calls gets a findByIds read', () async {
      await users.saveAll([for (int i = 0; i < 40; i++) users.row({'id': i, 'email': 'c$i'})]);
      for (int i = 0; i < FluentAnalyzer.lookupLoopCalls; i++) {
        await users.findById(i);
      }
      expect(FluentLog.shownHints.singleWhere((h) => h.kind.name == 'lookupLoop').code, contains('findByIds<DynamicModel>(ids)'));
    });

    test('big unpaged reads and deep offsets suggest findPage', () async {
      await users.saveAll([for (int i = 0; i < FluentAnalyzer.bigReadRows; i++) users.row({'id': i, 'email': 'd$i'})]);
      await users.find(limit: 10);
      expect(kinds(), isNot(contains('bigRead')));
      await users.findAll();
      expect(kinds(), contains('bigRead'));
      await users.find(orderBy: 'id', limit: 10, offset: FluentAnalyzer.deepOffset);
      expect(kinds(), contains('deepOffset'));
    });

    test('a flood of unawaited calls gets a batching hint', () async {
      await Future.wait([for (int i = 0; i < FluentAnalyzer.floodQueue + 50; i++) users.updateById(i, {'status': 'x'})]);
      expect(kinds(), contains('flood'));
    });

    test('the same read polled while the data did not change suggests watch; a rebuild storm does not', () async {
      int now = 0;
      FluentAnalyzer.clock = () => now;
      for (int i = 0; i < FluentAnalyzer.pollingRuns * 2; i++) {
        await users.findById(1); // all at the same time: rebuilds, not a timer
      }
      expect(kinds(), isNot(contains('polling')));
      for (int i = 0; i < FluentAnalyzer.pollingRuns; i++) {
        now += 1000;
        await users.count();
      }
      expect(FluentLog.shownHints.singleWhere((h) => h.kind.name == 'polling').code, contains('FluentDb.watch'));

      FluentLog.reset();
      FluentDb.setupLogging(console: false);
      for (int i = 0; i < FluentAnalyzer.pollingRuns; i++) {
        now += 1000;
        await users.save(users.row({'id': i, 'email': 'e$i'})); // the data changes between the reads: watch would emit too
        await users.count();
      }
      expect(kinds(), isNot(contains('polling')));
    });

    test('a call that waited long in the queue gets a hint naming the slow call before it', () {
      final FluentTask slow = read('"status" = ?', ['a']);
      FluentAnalyzer().onDone(slow, 1500);
      FluentAnalyzer().onStart(read('"age" = ?', [1]), FluentAnalyzer.queueWaitMs + 200);
      final FluentIssue hint = FluentLog.shownHints.single;
      expect(hint.key, 'queueWait:${users.dbName}');
      expect(hint.details, contains('find on "users" (1500 ms)'));
    });
  });

  group('delivery', () {
    test('hints are kept for the report, published, sent to onRecord and show their key and how to mute them', () async {
      final sub = hints.listen(published.add);
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        await users.save(users.row({'id': i, 'email': 'f$i'}));
      }
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(published.map((h) => h.kind), contains(FluentIssueKind.saveLoop));
      final FluentLogRecord record = records.firstWhere((r) => r.issue?.kind == FluentIssueKind.saveLoop);
      expect(record.level, FluentLogLevel.hint);
      expect(record.format(), allOf(contains('(hint saveLoop:'), contains("mute: {'saveLoop:*'}")));
      final FluentReport report = FluentDb.report();
      expect(report.ofType(FluentIssueType.hint).map((h) => h.kind), contains(FluentIssueKind.saveLoop));
      expect(report.toString(), contains('Important — fix first'));
      expect(report.toString(), contains('saveAll'));
    });

    test('a log level above hint keeps hints out of the log, not out of onIssue and the report', () async {
      FluentDb.setupLogging(level: FluentLogLevel.warning);
      final sub = hints.listen(published.add);
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.unordered, table: 'a', title: 'A', details: 'w'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(records.where((r) => r.level == FluentLogLevel.hint), isEmpty);
      expect(published.single.key, 'unordered::a');
      expect(FluentDb.report().issues.map((h) => h.key), contains('unordered::a'));
    });

    test('muted keys and prefixes are dropped everywhere', () async {
      FluentDb.setupLogging(mute: {'unordered::a', 'like:*'});
      final sub = hints.listen(published.add);
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.unordered, table: 'a', title: 'A', details: 'w'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.like, table: 'x', subject: 'y', title: 'B', details: 'w'));
      FluentLog.publish(const FluentIssue(kind: FluentIssueKind.unordered, table: 'b', title: 'C', details: 'w'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(published.map((h) => h.key), ['unordered::b']);
      expect(records.map((r) => r.issue?.key).nonNulls, ['unordered::b']);
      expect(FluentDb.report().issues.map((h) => h.key), isNot(contains('unordered::a')));
    });

    test('in release the analyzer is off unless hintsInRelease', () async {
      FluentAnalyzer.releaseMode = true;
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        await users.save(users.row({'id': i, 'email': 'g$i'}));
      }
      expect(kinds(), isNot(contains('saveLoop')));

      FluentDb.configure(const FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true)));
      for (int i = 0; i < FluentAnalyzer.saveLoopCalls; i++) {
        await users.save(users.row({'id': 100 + i, 'email': 'g${100 + i}'}));
      }
      expect(kinds(), contains('saveLoop'));
    });
  });
}
