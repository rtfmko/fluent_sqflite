// The tuner: every FluentTuning lever on and off, automatic indexes (create, check, keep, drop, failures), memory,
// background, checkpoints, frame budget, and that it only acts on idle databases through the queue.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  final List<FluentLogRecord> records = [];

  DynamicProvider usersTable() => DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);

  Future<void> open(FluentTuning tuning, {bool persistent = false, bool restart = false, FluentDiagnostics? diagnostics}) async {
    final FluentConfig config = FluentConfig(diagnostics: diagnostics ?? FluentDiagnostics(tuning: tuning));
    records.clear();
    FluentDb.setupLogging(console: false, onRecord: records.add, level: FluentLogLevel.debug, enabled: true);
    if (restart) {
      await db.restart([users], fluentConfig: config);
    } else {
      db = FluentTestDb(name: 'tuner_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
      users = usersTable();
      await db.open([users], fluentConfig: config);
    }
    await pumpEventQueue();
  }

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  FluentTask read(String column, {String? orderBy}) => FluentTask(
    table: users.tableName,
    dbName: users.dbName,
    action: FluentDbAction.find,
    helper: TableHelper(where: '"$column" = ?', whereArgs: const ['a'], shape: '"$column" = ?', orderBy: orderBy),
  );

  Future<void> until(bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await db.settle();
    }
  }

  Future<Set<String>> indexes() async => {for (final r in await users.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")) r['name']! as String};

  /// The issues of [kind] (the read pool report made at every start is not counted).
  Iterable<FluentIssue> issues(FluentIssueKind kind) => db.issues.where((i) => i.kind == kind && i.subject != 'readConnections');

  Iterable<String> debug(String tag) => [for (final FluentLogRecord r in records) if (r.level == FluentLogLevel.debug && (r.tag ?? '').startsWith('FluentTuner:$tag')) r.message];

  group('automatic indexes', () {
    test('created through the queue, reported once with the code; a second read of the same columns shares it', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      final FluentTask b = read('status', orderBy: 'age');
      FluentTuner().proposeIndex(a, users, const ['status']);
      FluentTuner().proposeIndex(b, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      await db.settle();
      expect(await indexes(), contains('fluent_auto_users_status'));
      final FluentIssue created = issues(FluentIssueKind.tuned).single;
      expect(created.type, FluentIssueType.autoFix);
      expect(created.table, 'users');
      expect(created.subject, 'status');
      expect(created.title, contains('dropped again if it does not help'));
      expect(created.code, contains("FluentIndex(['status'])"));
      expect(created.fix, contains('copyWith(indexes: false)'));
    });

    test('the same shape is not proposed twice while its check is running', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      await db.settle();
      expect(issues(FluentIssueKind.tuned), hasLength(1));
    });

    test('no columns, or the indexes lever off, does nothing; other levers do not create indexes', () async {
      await open(FluentTuning.full);
      FluentTuner().proposeIndex(read('status'), users, const []);
      await db.settle();
      expect(await indexes(), isNot(contains(startsWith(FluentTuner.autoIndexPrefix))));
      await db.close();

      await open(FluentTuning.noIndexes);
      FluentTuner().proposeIndex(read('status'), users, const ['status']);
      await db.settle();
      expect(await indexes(), isNot(contains('fluent_auto_users_status')));
      expect(issues(FluentIssueKind.tuned), isEmpty);
    });

    test('an index that helps one of two reads is kept even if the other read is not faster; unchecked reads wait', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      final FluentTask b = read('status', orderBy: 'age');
      FluentTuner().proposeIndex(a, users, const ['status']);
      FluentTuner().proposeIndex(b, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 1); // helped: before = slowReadMs (100)
      expect(debug('index'), anyElement(contains('helps')));
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(b), 100000); // not faster, but the index stays for a
      await db.settle();
      expect(await indexes(), contains('fluent_auto_users_status'));
      expect(issues(FluentIssueKind.tuningReverted), isEmpty);
    });

    test('a measurement of a shape that is not waiting for a verdict is ignored', () async {
      await open(FluentTuning.full);
      FluentTuner().onMeasured('nothing|waiting|here|x', 1e9);
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tuningReverted), isEmpty);
    });

    test('an index that does not help is dropped, reported with the reason, and not proposed again for that shape', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 95); // 100 -> 95: less than the 20 % gain
      await until(() => issues(FluentIssueKind.tuningReverted).isNotEmpty);
      final FluentIssue dropped = issues(FluentIssueKind.tuningReverted).single;
      expect(dropped.title, allOf(contains('Dropped the automatic index'), contains('~95 ms'), contains('before ~100 ms')));
      expect(dropped.fix, contains('FluentDb.report()'));
      expect(await indexes(), isNot(contains('fluent_auto_users_status')));

      FluentTuner().proposeIndex(a, users, const ['status']);
      await db.settle();
      expect(await indexes(), isNot(contains('fluent_auto_users_status')), reason: 'a failed shape is not tried again in this run');
      expect(issues(FluentIssueKind.tuned), hasLength(1));
    });

    test('the gain is measured against the average before: exactly 20 % faster keeps the index', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 100 * (1 - FluentTuner.indexGain));
      await db.settle();
      expect(await indexes(), contains('fluent_auto_users_status'));
    });

    test('the cap per database: no index above maxIndexes, and a dropped one gives its slot back', () async {
      await open(FluentTuning.full.copyWith(maxIndexes: 1));
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      FluentTuner().proposeIndex(read('age'), users, const ['age']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      await db.settle();
      expect(await indexes(), isNot(contains('fluent_auto_users_age')));
      expect(debug('index'), anyElement(contains('cap of 1')));

      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 1e6);
      await until(() => issues(FluentIssueKind.tuningReverted).isNotEmpty);
      FluentTuner().proposeIndex(read('age'), users, const ['age']);
      await until(() => issues(FluentIssueKind.tuned).length == 2);
      expect(await indexes(), contains('fluent_auto_users_age'));
    });

    test('an index that cannot be created is reported, the table works as before, and the shape is not retried', () async {
      await open(FluentTuning.full);
      final FluentTask bad = read('nope');
      FluentTuner().proposeIndex(bad, users, const ['nope']);
      await until(() => issues(FluentIssueKind.tuningReverted).isNotEmpty);
      final FluentIssue failed = issues(FluentIssueKind.tuningReverted).single;
      expect(failed.title, contains('could not be created'));
      expect(failed.subject, 'nope');
      expect(failed.error, isNotNull);
      expect(await users.count(), 0, reason: 'the table still works');

      FluentTuner().proposeIndex(bad, users, const ['nope']);
      await db.settle();
      expect(issues(FluentIssueKind.tuningReverted), hasLength(1));
      // The slot was given back: with the cap of 5 five other indexes can still be created.
      for (final String c in const ['id', 'status', 'age']) {
        FluentTuner().proposeIndex(read(c), users, [c]);
      }
      await until(() => issues(FluentIssueKind.tuned).length == 3);
      expect(await indexes(), containsAll(['fluent_auto_users_id', 'fluent_auto_users_status', 'fluent_auto_users_age']));
    });

    test('an index that cannot be dropped stays, with a hint to drop it by hand', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      await users.execute('PRAGMA query_only = ON');
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 1e6);
      await until(() => issues(FluentIssueKind.tuningReverted).isNotEmpty);
      await users.execute('PRAGMA query_only = OFF');
      final FluentIssue failed = issues(FluentIssueKind.tuningReverted).single;
      expect(failed.title, contains('could not be dropped'));
      expect(failed.fix, contains('DROP INDEX "fluent_auto_users_status"'));
      expect(await indexes(), contains('fluent_auto_users_status'));
    });

    test('a read that is not measured again within checkFor stops waiting and never drops the index', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      db.clock.advance(FluentTuner.checkFor + const Duration(minutes: 1));
      FluentTuner().proposeIndex(read('age'), users, const ['age']); // cleans the check list
      await until(() => issues(FluentIssueKind.tuned).length == 2);
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 1e6);
      await db.settle();
      expect(await indexes(), containsAll(['fluent_auto_users_status', 'fluent_auto_users_age']));
      expect(issues(FluentIssueKind.tuningReverted), isEmpty);
    });

    test('indexes of an earlier run count against the cap and are listed at the start', () async {
      await open(FluentTuning.full.copyWith(maxIndexes: 1), persistent: true);
      await users.execute('CREATE INDEX "fluent_auto_users_age" ON "users" ("age")');
      await open(FluentTuning.full.copyWith(maxIndexes: 1), restart: true);
      expect(debug('index'), anyElement(allOf(contains('fluent_auto_users_age'), contains('earlier run'))));
      FluentTuner().proposeIndex(read('status'), users, const ['status']);
      await db.settle();
      expect(await indexes(), isNot(contains('fluent_auto_users_status')), reason: 'the cap of 1 is used by the index of the earlier run');
      expect(await indexes(), contains('fluent_auto_users_age'), reason: 'schema sync leaves automatic indexes alone');
    });

    test('with the indexes lever off the start does not look for earlier indexes', () async {
      await open(FluentTuning.noIndexes, persistent: true);
      await users.execute('CREATE INDEX "fluent_auto_users_age" ON "users" ("age")');
      await open(FluentTuning.noIndexes, restart: true);
      expect(debug('index'), isEmpty);
    });
  });

  group('frame budget', () {
    double hz = 60;
    setUp(() => FluentTuner.refreshRateProbe = () => hz);
    tearDown(() => FluentTuner.refreshRateProbe = null);

    FluentConfig config(FluentTuning tuning) => FluentConfig(diagnostics: FluentDiagnostics(tuning: tuning));

    test('scaled to the refresh rate and reported once per value; 60 Hz and the lever off keep the configured budget', () async {
      await open(FluentTuning.full);
      hz = 120;
      expect(FluentTuner().frameBudget(config(FluentTuning.full)), const Duration(milliseconds: 2));
      expect(FluentTuner().frameBudget(config(FluentTuning.full)), const Duration(milliseconds: 2));
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'frameBudget'), hasLength(1), reason: 'reported once for the same budget');
      expect(issues(FluentIssueKind.tuned).single.title, contains('120 Hz'));

      hz = 30;
      expect(FluentTuner().frameBudget(config(FluentTuning.full)), const Duration(milliseconds: 8));
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'frameBudget'), hasLength(2));

      hz = 480;
      expect(FluentTuner().frameBudget(config(FluentTuning.full)), const Duration(milliseconds: 1), reason: 'never below 1 ms');

      hz = 60;
      expect(FluentTuner().frameBudget(config(FluentTuning.full)), const Duration(milliseconds: 4));

      hz = 120;
      expect(FluentTuner().frameBudget(config(const FluentTuning(indexes: true))), const Duration(milliseconds: 4), reason: 'the lever is off');
    });
  });

  group('memory pressure', () {
    test('frees memory once, shrinks the cache, and the cache comes back when the app resumes', () async {
      await open(FluentTuning.full);
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory'), hasLength(1));
      expect(debug('memory'), containsAll(['PRAGMA shrink_memory on "${users.dbName}"', 'PRAGMA cache_size = -512 on "${users.dbName}"']));
      expect((await users.rawQuery('PRAGMA cache_size')).single.values.single, -FluentTuner.lowMemoryCacheKib);

      await FluentTuner().handleMemoryPressure(); // already low: not reported again
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory'), hasLength(1));

      await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      final List<FluentIssue> tuned = issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory').toList();
      expect(tuned, hasLength(2));
      expect(tuned.last.title, contains('is back to'));
      expect((await users.rawQuery('PRAGMA cache_size')).single.values.single, isNot(-FluentTuner.lowMemoryCacheKib));
    });

    test('the memory lever off does nothing', () async {
      await open(FluentTuning.full.copyWith(memory: false));
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      expect(db.issues.where((i) => i.subject == 'memory'), isEmpty);
      expect(debug('memory'), isEmpty);
      expect((await users.rawQuery('PRAGMA cache_size')).single.values.single, isNot(-FluentTuner.lowMemoryCacheKib));
    });

    test('a busy database is left alone; its cache comes back when it is idle', () async {
      await open(FluentTuning.full);
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      final Completer<void> inside = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> tx = FluentDb.transaction(() async {
        inside.complete();
        await release.future;
      });
      await inside.future;
      await FluentTuner().handleLifecycle(AppLifecycleState.resumed); // busy: waits
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.title.contains('is back to')), isEmpty);
      release.complete();
      await tx;
      await until(() => issues(FluentIssueKind.tuned).any((i) => i.title.contains('is back to')));
      expect(issues(FluentIssueKind.tuned).where((i) => i.title.contains('is back to')), hasLength(1));
    });

    test('pressure while the database is busy changes nothing', () async {
      await open(FluentTuning.full);
      final Completer<void> inside = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> tx = FluentDb.transaction(() async {
        inside.complete();
        await release.future;
      });
      await inside.future;
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      release.complete();
      await tx;
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory'), isEmpty);
      expect(debug('memory'), isEmpty);
    });
  });

  group('read connections and closed databases', () {
    test('memory pressure also reaches the connections of the read pool', () async {
      await open(FluentTuning.full, persistent: true);
      await users.saveAll([for (int i = 0; i < 3; i++) users.row({'id': i, 'status': 'a', 'age': i})]);
      expect(await users.count(), 3); // a read on a pooled connection
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory'), hasLength(1));
      expect(issues(FluentIssueKind.tuningReverted), isEmpty);
      expect(await users.count(), 3, reason: 'reads still work with the small cache');
      await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(issues(FluentIssueKind.tuned).where((i) => i.title.contains('is back to')), hasLength(1));
    });

    test('the real display is used without a probe: a budget of at least 1 ms, never failing', () {
      FluentTuner.refreshRateProbe = null;
      final Duration budget = FluentTuner().frameBudget(const FluentConfig(diagnostics: FluentDiagnostics.auto));
      expect(budget, greaterThanOrEqualTo(const Duration(milliseconds: 1)));
    });

    test('an index whose database was closed meanwhile is not dropped, and nothing fails', () async {
      await open(FluentTuning.full);
      final FluentTask a = read('status');
      FluentTuner().proposeIndex(a, users, const ['status']);
      await until(() => issues(FluentIssueKind.tuned).isNotEmpty);
      FluentDbInternals.reset(); // the registry forgets the providers (as after a restart in between)
      FluentTuner().onMeasured(FluentTableStatsTracker.keyOf(a), 1e6);
      await pumpEventQueue();
      expect(debug('index'), anyElement(contains('is closed')));
      expect(issues(FluentIssueKind.tuningReverted), isEmpty);
    });
  });

  group('background and checkpoints', () {
    test('going to the background optimizes and checkpoints once, defers periodic maintenance, and resuming ends it', () async {
      await open(FluentTuning.full);
      await FluentTuner().handleLifecycle(AppLifecycleState.inactive);
      await pumpEventQueue();
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse, reason: 'inactive is not the background');
      expect(debug('background'), isEmpty);

      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(FluentTuner().defersMaintenance(users.dbName), isTrue);
      expect(debug('background'), ['PRAGMA optimize on "${users.dbName}"']);
      expect(debug('checkpoints'), ['PRAGMA wal_checkpoint(TRUNCATE) on "${users.dbName}"']);

      await FluentTuner().handleLifecycle(AppLifecycleState.hidden); // still in the background: nothing again
      await pumpEventQueue();
      expect(debug('background'), hasLength(1));

      await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse);
      await FluentTuner().handleLifecycle(AppLifecycleState.detached);
      await pumpEventQueue();
      expect(FluentTuner().defersMaintenance(users.dbName), isTrue);
      expect(debug('background'), hasLength(2));
    });

    test('the background lever off: no maintenance and no deferring; the checkpoint lever off: no checkpoint', () async {
      await open(FluentTuning.full.copyWith(background: false));
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse);
      expect(debug('background'), isEmpty);
      expect(debug('checkpoints'), hasLength(1));
      await db.close();

      await open(FluentTuning.full.copyWith(checkpoints: false));
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(debug('checkpoints'), isEmpty);
      expect(debug('background'), hasLength(1));
      await db.close();

      await open(FluentTuning.off);
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(debug('background'), isEmpty);
      expect(debug('checkpoints'), isEmpty);
    });

    test('going to the background writes the pending query costs of idle databases', () async {
      await open(FluentTuning.full, persistent: true);
      await users.count();
      await db.settle();
      FluentTableStatsTracker().record(FluentTask(table: 'users', dbName: db.name, action: FluentDbAction.find, helper: TableHelper(where: '"age" = ?', whereArgs: const [1], shape: '"age" = ? /* bg */')), 4);
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      final List<Map<String, Object?>> rows = await users.rawQuery('SELECT shape FROM "${FluentTableStatsTracker.table}"');
      expect(rows.map((r) => r['shape']), contains('"age" = ? /* bg */'));
    });

    test('a checkpoint runs after checkpointEveryWrites writes, only when idle, and counts again from zero', () async {
      await open(FluentTuning.full);
      for (int i = 0; i < FluentTuner.checkpointEveryWrites - 1; i++) {
        FluentTuner().onWrite(users.dbName);
      }
      expect(debug('checkpoints'), isEmpty);

      final Completer<void> inside = Completer<void>();
      final Completer<void> release = Completer<void>();
      final Future<void> tx = FluentDb.transaction(() async {
        inside.complete();
        await release.future;
      });
      await inside.future;
      FluentTuner().onWrite(users.dbName); // the 500th write, but the database is busy
      await pumpEventQueue();
      expect(debug('checkpoints'), isEmpty);
      release.complete();
      await tx;
      await db.settle();
      await until(() => debug('checkpoints').isNotEmpty);
      expect(debug('checkpoints'), ['PRAGMA wal_checkpoint(PASSIVE) on "${users.dbName}"'], reason: 'the first write after the database is idle runs it');
      await db.settle();

      for (int i = 0; i < FluentTuner.checkpointEveryWrites - 1; i++) {
        FluentTuner().onWrite(users.dbName);
      }
      await pumpEventQueue();
      expect(debug('checkpoints'), hasLength(1), reason: 'counted from zero after a checkpoint');
    });

    test('with the checkpoint lever off the writes are not counted', () async {
      await open(FluentTuning.full.copyWith(checkpoints: false));
      for (int i = 0; i < FluentTuner.checkpointEveryWrites * 2; i++) {
        FluentTuner().onWrite(users.dbName);
      }
      await pumpEventQueue();
      expect(debug('checkpoints'), isEmpty);
    });

    test('real writes reach the tuner: a database with many saves still works and reports no failure', () async {
      await open(FluentTuning.full);
      await users.saveAll([for (int i = 0; i < 20; i++) users.row({'id': i, 'status': 'a', 'age': i})]);
      for (int i = 0; i < 20; i++) {
        await users.updateById(i, {'age': i + 1});
      }
      await db.settle();
      expect(await users.count(), 20);
      expect(issues(FluentIssueKind.tuningReverted), isEmpty);
    });
  });

  group('observing the app', () {
    test('the binding forwards the lifecycle and memory pressure while databases with those levers are open', () async {
      await open(FluentTuning.full);
      final WidgetsBinding binding = WidgetsBinding.instance;
      binding.handleMemoryPressure();
      await until(() => issues(FluentIssueKind.tuned).any((i) => i.subject == 'memory'));
      expect(issues(FluentIssueKind.tuned).where((i) => i.subject == 'memory'), hasLength(1));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await until(() => FluentTuner().defersMaintenance(users.dbName));
      expect(FluentTuner().defersMaintenance(users.dbName), isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await until(() => !FluentTuner().defersMaintenance(users.dbName));
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse);
    });

    test('after the close nothing is observed or remembered: the tuner state is fresh', () async {
      await open(FluentTuning.full);
      await FluentTuner().handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
      await FluentTuner().handleMemoryPressure();
      await pumpEventQueue();
      await db.close();
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse);
      records.clear();
      WidgetsBinding.instance.handleMemoryPressure();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(debug('memory'), isEmpty);
      expect(debug('background'), isEmpty);
    });

    test('levers that need no observer (indexes only) do not register one', () async {
      await open(const FluentTuning(indexes: true));
      WidgetsBinding.instance.handleMemoryPressure();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(debug('memory'), isEmpty);
      expect(debug('background'), isEmpty);
      expect(FluentTuner().defersMaintenance(users.dbName), isFalse, reason: 'background lever is off: the observer never told the tuner');
    });

    test('FluentTuning.toString, equality and isOff', () {
      expect(FluentTuning.off.isOff, isTrue);
      expect(FluentTuning.off.toString(), 'FluentTuning.off');
      expect(FluentTuning.full.toString(), allOf(contains('indexes (max 5)'), contains('frameBudget')));
      expect(FluentTuning.full.copyWith(indexes: false), FluentTuning.noIndexes);
      expect(FluentTuning.full.hashCode, const FluentTuning(indexes: true, readConnections: true, memory: true, background: true, checkpoints: true, frameBudget: true).hashCode);
      expect(FluentTuning.full == FluentTuning.off, isFalse);
    });
  });
}
