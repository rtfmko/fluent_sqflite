@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';
import '../provider/relations/auto_relations_test.dart' as rel;
import '_helpers.dart';

void main() {
  setUpFluentTests();

  setUp(() async {
    await FluentTestDb.closeCurrent();
    await FluentDb.close();
    FluentDbInternals.reset();
    FluentLog.forgetIssues();
  });

  tearDown(() async {
    await FluentDb.close();
    FluentDbInternals.reset();
  });

  FluentGroup gadgetGroup(String name, [List<FluentProvider>? providers]) => FluentGroup(dbKey: FluentDbKey(name), providerList: providers ?? [GadgetProvider()], inMemory: true);

  group('29 init after close shares no pending init', () {
    test('init(A), close(), init(B) without awaiting: B is open, A is closed', () async {
      final Future<void> a = FluentDb.init([gadgetGroup('ord_a')]);
      final Future<void> c = FluentDb.close();
      final Future<void> b = FluentDb.init([gadgetGroup('ord_b')]);
      await Future.wait([a, c, b]).timeout(const Duration(seconds: 5));
      expect(FluentDb.isOpen(dbKey: FluentDbKey('ord_a')), isFalse);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('ord_b')), isTrue);
    });

    test('init(A), restart(), init(B): the later init still runs in order (B is dropped only because A is open again)', () async {
      final Future<void> a = FluentDb.init([gadgetGroup('rs_a')]);
      final Future<void> r = FluentDb.restart();
      final Future<void> b = FluentDb.init([gadgetGroup('rs_b')]);
      await Future.wait([a, r, b]).timeout(const Duration(seconds: 5));
      expect(FluentDb.isOpen(dbKey: FluentDbKey('rs_a')), isTrue);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('rs_b')), isFalse); // like any init after an init completed
    });

    test('two concurrent inits without anything between still share one initialization', () async {
      final GadgetProvider first = GadgetProvider();
      final GadgetProvider second = GadgetProvider();
      final Future<void> a = FluentDb.init([gadgetGroup('sh_a', [first])]);
      final Future<void> b = FluentDb.init([gadgetGroup('sh_b', [second])]);
      await Future.wait([a, b]).timeout(const Duration(seconds: 5));
      expect(FluentDb.isOpen(dbKey: FluentDbKey('sh_a')), isTrue);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('sh_b')), isFalse);
    });

    test('a failing first init does not take the later init down with it', () async {
      final Future<void> a = FluentDb.init([gadgetGroup('bad name!')]);
      final Future<void> c = FluentDb.close();
      final Future<void> b = FluentDb.init([gadgetGroup('after_fail')]);
      await expectLater(a, throwsA(isA<FluentConfigException>()));
      await Future.wait([c, b]).timeout(const Duration(seconds: 5));
      expect(FluentDb.isOpen(dbKey: FluentDbKey('after_fail')), isTrue);
    });
  });

  group('30 paths are redacted', () {
    test('Windows, POSIX, UNC and quoted paths are hidden', () {
      const List<String> texts = [
        r"Creating directory failed, path = 'C:\Users\me\My Docs\app.db' (OS Error: x)",
        r'cannot open C:\Users\me\app.db now',
        "failed at '/home/me/my docs/app.db'",
        'cannot open /home/me/app.db now',
        r'share \\server\share\app.db is gone',
        'C:/Users/me/app.db',
      ];
      for (final String text in texts) {
        final String shown = FluentLog.redact(text);
        expect(shown, contains('<path hidden>'), reason: text);
        expect(shown, isNot(contains('me')), reason: text);
        expect(shown, isNot(contains('app.db')), reason: text);
      }
    });

    test('ordinary text, URLs and fractions stay as they are', () {
      const List<String> texts = ['and/or both', 'ratio 1/2 of a/b', 'GET https://example.com/a/b failed', 'table "a" column b: x', 'time 10:30/11:00'];
      for (final String text in texts) {
        expect(FluentLog.redact(text), text);
      }
    });

    test('showSqlArguments shows the paths again', () {
      FluentDb.setupLogging(showSqlArguments: true);
      addTearDown(() => FluentDb.setupLogging(showSqlArguments: false));
      expect(FluentLog.redact(r'C:\Users\me\app.db'), r'C:\Users\me\app.db');
    });

    test('FluentGroup.toString hides the directory unless showSqlArguments', () {
      final FluentGroup g = FluentGroup(dbKey: FluentDbKey('str_a'), providerList: [GadgetProvider()], directory: '/home/secret_user/dbs');
      expect(g.toString(), isNot(contains('secret_user')));
      expect(g.toString(), contains('directory'));
      FluentDb.setupLogging(showSqlArguments: true);
      addTearDown(() => FluentDb.setupLogging(showSqlArguments: false));
      expect(g.toString(), contains('secret_user'));
    });

    test('an init that fails on a directory keeps the path out of the message and the records', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('probe_dir_');
      addTearDown(() => tmp.delete(recursive: true));
      final File file = File('${tmp.path}/iam_a_file')..writeAsStringSync('x');
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(enabled: true, console: false, onRecord: records.add, level: FluentLogLevel.debug);
      addTearDown(() => FluentDb.setupLogging(removeOnRecord: true));
      Object? err;
      try {
        await FluentDb.init([FluentGroup(dbKey: FluentDbKey('path_a'), providerList: [GadgetProvider()], directory: file.path)]);
      } catch (e) {
        err = e;
      }
      expect(err, isA<FluentException>());
      final String all = '${(err! as FluentException).message}\n${(err as FluentException)}\n${records.map((r) => '${r.message} ${r.error}').join('\n')}';
      expect(all, isNot(contains('probe_dir_')));
      expect(all, isNot(contains('iam_a_file')));
    });
  });

  group('31 the database config is known during init', () {
    test('quiet diagnostics of one database silence its init-time hints', () async {
      final FluentTestDb db = FluentTestDb(name: 'diag_a');
      await db.open([rel.UserProvider(), rel.PostProvider(), rel.ProfileProvider(), rel.TagProvider()], config: const FluentDbConfig(diagnostics: FluentDiagnostics.quiet));
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.autoRelations), isEmpty);
      await db.close();
    });

    test('database diagnostics that collect win over quiet global ones (edge)', () async {
      final FluentTestDb db = FluentTestDb(name: 'diag_b');
      await db.open(
        [rel.UserProvider(), rel.PostProvider(), rel.ProfileProvider(), rel.TagProvider()],
        config: const FluentDbConfig(diagnostics: FluentDiagnostics.recommend),
        fluentConfig: const FluentConfig(diagnostics: FluentDiagnostics.quiet),
      );
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.autoRelations), isNotEmpty);
      await db.close();
    });

    test('the engine knows the config before the schema sync, and forgets it when init fails', () async {
      List<FluentDbColumn> cols() => [FluentDbColumn.text('name')];
      final FluentTestDb first = FluentTestDb(name: 'peek_a', persistent: true);
      await first.open([DynamicProvider('t', cols)]);
      FluentDbConfig? seen;
      final DynamicProvider p = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols,
          migrations: [
            FluentDbMigration(
              version: 1,
              onMigrate: (txn) async {
                seen = FluentEngine().dbConfig('peek_a');
                throw StateError('stop');
              },
            ),
          ],
        ),
      );
      const FluentDbConfig cfg = FluentDbConfig(diagnostics: FluentDiagnostics.quiet);
      Object? err;
      try {
        await first.restart([p], config: cfg);
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      expect(seen, same(cfg));
      expect(FluentEngine().dbConfig('peek_a'), isNull);
    });
  });

  group('32 intervals that cannot work', () {
    test('FluentClockTimer with a zero or negative interval does not start and warns', () async {
      final List<FluentIssue> issues = [];
      final StreamSubscription<FluentIssue> sub = FluentLog.issues.listen(issues.add);
      addTearDown(sub.cancel);
      int runs = 0;
      final FluentClockTimer zero = FluentClockTimer(Duration.zero, () async => runs++, tag: 'zero_timer');
      final FluentClockTimer negative = FluentClockTimer(const Duration(milliseconds: -5), () async => runs++, tag: 'neg_timer');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs, 0);
      expect(zero.isCancelled, isTrue);
      expect(negative.isCancelled, isTrue);
      expect(issues.where((i) => i.kind == FluentIssueKind.configFallback).length, 2);
    });

    test('a run never starts while the previous one is running', () async {
      final Completer<void> release = Completer<void>();
      int started = 0;
      int running = 0;
      int maxRunning = 0;
      final FluentClockTimer timer = FluentClockTimer(const Duration(milliseconds: 10), () async {
        started++;
        running++;
        if (running > maxRunning) maxRunning = running;
        await release.future;
        running--;
      });
      addTearDown(timer.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(started, 1);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(started, greaterThan(1));
      expect(maxRunning, 1);
    });

    test('an overlong run is caught up once, not in a loop', () async {
      final Completer<void> first = Completer<void>();
      int started = 0;
      final FluentClockTimer timer = FluentClockTimer(const Duration(milliseconds: 20), () async {
        started++;
        if (started == 1) await first.future;
      });
      addTearDown(timer.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(started, 1);
      first.complete();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(started, lessThan(6)); // roughly one run per 20 ms, never a burst
    });

    test('configure with zero / negative intervals falls back to the defaults with warnings', () async {
      final List<FluentIssue> issues = [];
      final StreamSubscription<FluentIssue> sub = FluentLog.issues.listen(issues.add);
      addTearDown(sub.cancel);
      await FluentDb.init([gadgetGroup('cfg_iv')]);
      FluentDb.configure(const FluentConfig(trashPurgeInterval: Duration.zero, optimizeInterval: Duration(seconds: -1), pauseWatchdog: Duration.zero, transactionWatchdog: Duration(milliseconds: -3)));
      expect(FluentDb.config.trashPurgeInterval, const FluentConfig().trashPurgeInterval);
      expect(FluentDb.config.optimizeInterval, const FluentConfig().optimizeInterval);
      expect(FluentDb.config.pauseWatchdog, const FluentConfig().pauseWatchdog);
      expect(FluentDb.config.transactionWatchdog, const FluentConfig().transactionWatchdog);
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: true));
      await Future<void>.delayed(Duration.zero);
      expect(issues.where((i) => i.kind == FluentIssueKind.configFallback).length, 4);
    });

    test('init(config:) with a zero interval is fixed too; null still switches the job off (edge)', () async {
      final FluentTestDb db = FluentTestDb(name: 'cfg_iv2');
      await db.open([GadgetProvider()], fluentConfig: const FluentConfig(optimizeInterval: Duration.zero, trashPurgeInterval: null));
      expect(FluentDb.config.optimizeInterval, const FluentConfig().optimizeInterval);
      expect(FluentDb.config.trashPurgeInterval, isNull);
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: true));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.configFallback), hasLength(1));
      await db.close();
    });
  });

  group('33 settings and logging', () {
    test('configure right after an unawaited init is kept', () async {
      final Future<void> f = FluentDb.init([gadgetGroup('cfg_a')], config: const FluentConfig(trashRetention: Duration(days: 1)));
      FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 99)));
      await f;
      expect(FluentDb.config.trashRetention, const Duration(days: 99));
    });

    test('init without config keeps what configure set; an explicit config wins when configure came before', () async {
      FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 42)));
      await FluentDb.init([gadgetGroup('cfg_b')]);
      expect(FluentDb.config.trashRetention, const Duration(days: 42));
      await FluentDb.close();
      await FluentDb.init([gadgetGroup('cfg_b')], config: const FluentConfig(trashRetention: Duration(days: 3)));
      expect(FluentDb.config.trashRetention, const Duration(days: 3));
      await FluentDb.close();
      await FluentDb.init([gadgetGroup('cfg_b')]); // the settings in use stay
      expect(FluentDb.config.trashRetention, const Duration(days: 3));
    });

    test('planMigrations does not change the global settings', () async {
      FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 11)));
      await FluentDb.planMigrations([gadgetGroup('plan_a')], config: const FluentConfig(trashRetention: Duration(days: 5)));
      expect(FluentDb.config.trashRetention, const Duration(days: 11));
      await FluentDb.planMigrations([gadgetGroup('plan_a')]); // default: the settings in use
      expect(FluentDb.config.trashRetention, const Duration(days: 11));
    });

    test('a failing restart callback keeps paths out of the message', () async {
      await FluentDb.init([gadgetGroup('rcb_a')]);
      Object? err;
      try {
        await FluentDb.restart(update: (g) => throw StateError(r"cannot read 'C:\Users\secret_user\x.json'"));
      } catch (e) {
        err = e;
      }
      expect(err, isA<FluentConfigException>());
      expect((err! as FluentConfigException).message, isNot(contains('secret_user')));
    });

    test('setupLogging(removeOnRecord: true) removes the sink; onRecord: null keeps it', () async {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(enabled: true, console: false, onRecord: records.add, level: FluentLogLevel.debug);
      addTearDown(() {
        FluentDb.setupLogging(removeOnRecord: true);
        FluentLog.reset();
        FluentDb.setupLogging(enabled: false);
      });
      FluentLog.info('one');
      // ignore: avoid_redundant_argument_values
      FluentDb.setupLogging(onRecord: null);
      FluentLog.info('two');
      expect(records.map((r) => r.message), ['one', 'two']);
      FluentDb.setupLogging(removeOnRecord: true);
      FluentLog.info('three');
      expect(records, hasLength(2));
      // A new sink in the same call is set after the removal.
      final List<FluentLogRecord> other = [];
      FluentDb.setupLogging(removeOnRecord: true, onRecord: other.add);
      FluentLog.info('four');
      expect(records, hasLength(2));
      expect(other, hasLength(1));
    });

    test('a failure whose text only mentions "busy" still recreates a resetOnSchemaError file', () async {
      final FluentTestDb db = FluentTestDb(name: 'busy_a', persistent: true);
      List<FluentDbColumn> cols() => [FluentDbColumn.text('name')];
      await db.open([DynamicProvider('t', cols)]);
      final DynamicProvider failing = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols,
          migrations: [FluentDbMigration(version: 1, onMigrate: (txn) async => throw StateError('the busy list is empty'))],
        ),
      );
      await db.restart([failing], resetOnSchemaError: true);
      expect(db.issues.any((i) => i.kind == FluentIssueKind.databaseRecreated), isTrue);
      await db.close();
    });
  });
}
