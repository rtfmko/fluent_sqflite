@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';
import '_helpers.dart';

void main() {
  setUpFluentTests();

  late List<FluentIssue> issues;
  late StreamSubscription<FluentIssue> listener;
  FluentTestDb? db;

  setUp(() async {
    await FluentTestDb.closeCurrent();
    FluentDbInternals.reset();
    FluentLog.forgetIssues();
    issues = [];
    listener = FluentDb.onIssue().listen(issues.add);
  });

  tearDown(() async {
    await listener.cancel();
    await db?.close();
    db = null;
    await FluentDb.close();
    FluentDbInternals.reset();
    FluentDb.setupLogging(enabled: false);
  });

  Future<String> fileOf(String name) async => '${await getDatabasesPath()}/$name.db';

  List<FluentIssue> ofKind(FluentIssueKind kind) => [for (final FluentIssue i in issues) if (i.kind == kind) i];

  Future<void> idle() => FluentEngine().whenIdle(const Duration(seconds: 5));

  group('init arguments', () {
    test('a duplicate group is reported and the first one is used', () async {
      final first = GadgetProvider('dup_first');
      final second = PageProvider();
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('dup_db'), providerList: [first], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('dup_db'), providerList: [second], inMemory: true),
      ]);
      await Future<void>.delayed(Duration.zero);
      final dup = ofKind(FluentIssueKind.duplicateGroup);
      expect(dup, hasLength(1));
      expect(dup.single.title, contains('"dup_db"'));
      expect(FluentDbInternals.providersOf('dup_db'), [first]);
      await expectLater(FluentDb.find<Page>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound)));
    });

    test('no groups: a noGroups issue, nothing opens, and calls fail with notInitialized', () async {
      await FluentDb.init(const <FluentGroup>[]);
      await Future<void>.delayed(Duration.zero);
      expect(ofKind(FluentIssueKind.noGroups), hasLength(1));
      expect(FluentDb.isOpen(), isFalse);
      await expectLater(FluentDb.find<Gadget>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
    });

    test('a group without providers counts as no group', () async {
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('empty_group'), providerList: const <FluentProvider>[], inMemory: true)]);
      await Future<void>.delayed(Duration.zero);
      expect(FluentDb.isOpen(), isFalse);
    });

    test('invalid names are refused before a file is touched, with a rename hint', () async {
      for (final String name in ['has space', 'dash-name', 'dot.name', 'ünï']) {
        await expectLater(
          FluentDb.init([FluentGroup(dbKey: FluentDbKey(name), providerList: [GadgetProvider()], inMemory: true)]),
          throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.invalidDatabaseName).having((e) => e.hint, 'hint', contains("FluentDbKey('"))),
          reason: name,
        );
        expect(FluentDb.isOpen(), isFalse);
      }
    });

    test('an in-memory read-only group is opened writable with a configFallback issue', () async {
      final g = GadgetProvider();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('mem_ro'), providerList: [g], inMemory: true, readOnly: true)]);
      await Future<void>.delayed(Duration.zero);
      expect(ofKind(FluentIssueKind.configFallback).map((i) => i.title), anyElement(contains('in memory and read-only')));
      await FluentDb.save<Gadget>(Gadget(name: 'writable'));
      expect(await FluentDb.count<Gadget>(), 1);
    });

    test('several groups: each has its own providers, isOpen per key, clear per key', () async {
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('multi_a'), providerList: [GadgetProvider()], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('multi_b'), providerList: [PageProvider()], inMemory: true),
      ]);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('multi_a')), isTrue);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('multi_b')), isTrue);
      await FluentDb.save<Gadget>(Gadget(name: 'g'));
      await FluentDb.save<Page>(Page(title: 'p'));
      await FluentDb.clear(dbKey: FluentDbKey('multi_a'));
      expect(await FluentDb.count<Gadget>(), 0);
      expect(await FluentDb.count<Page>(), 1);
    });
  });

  group('a damaged file', () {
    test('init fails with a typed error, logs it once, opens nothing and can be retried after the fix', () async {
      final String path = await fileOf('damaged_file');
      await File(path).writeAsBytes(List<int>.generate(4096, (i) => (i * 7) % 251));
      final records = <FluentLogRecord>[];
      FluentDb.setupLogging(enabled: true, console: false, level: FluentLogLevel.warning, onRecord: records.add);
      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('damaged_file'), providerList: [GadgetProvider()])]),
        throwsA(isA<FluentException>()),
      );
      expect(FluentDb.isOpen(), isFalse);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('damaged_file')), isFalse);
      expect(records.where((r) => r.level.index >= FluentLogLevel.warning.index), hasLength(1), reason: 'an error the caller receives is logged once, as a warning');
      await File(path).delete();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('damaged_file'), providerList: [GadgetProvider()])]);
      expect(FluentDb.isOpen(), isTrue);
      await FluentDb.save<Gadget>(Gadget(name: 'ok'));
      expect(await FluentDb.count<Gadget>(), 1);
    });

    test('resetOnSchemaError recreates a damaged file and reports the automatic change', () async {
      final String path = await fileOf('damaged_reset');
      await File(path).writeAsBytes(List<int>.generate(4096, (i) => (i * 13) % 241));
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('damaged_reset'), providerList: [GadgetProvider()], resetOnSchemaError: true)]);
      await Future<void>.delayed(Duration.zero);
      expect(FluentDb.isOpen(), isTrue);
      expect(await FluentDb.count<Gadget>(), 0);
      expect(ofKind(FluentIssueKind.databaseRecreated), hasLength(1));
    });
  });

  group('serialized lifecycle', () {
    test('concurrent init calls share one initialization', () async {
      final g1 = GadgetProvider();
      final g2 = GadgetProvider('never_used');
      final Future<void> a = FluentDb.init([FluentGroup(dbKey: FluentDbKey('conc_a'), providerList: [g1], inMemory: true)]);
      final Future<void> b = FluentDb.init([FluentGroup(dbKey: FluentDbKey('conc_b'), providerList: [g2], inMemory: true)]);
      await Future.wait([a, b]);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('conc_a')), isTrue);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('conc_b')), isFalse, reason: 'the second call joined the first');
    });

    test('init, close and restart queued back to back run in call order', () async {
      final g = GadgetProvider();
      final groups = [FluentGroup(dbKey: FluentDbKey('order_db'), providerList: [g], inMemory: true)];
      final futures = <Future<void>>[
        FluentDb.init(groups),
        FluentDb.close(),
        FluentDb.init(groups),
        FluentDb.restart(),
        FluentDb.close(),
      ];
      await Future.wait(futures);
      expect(FluentDb.isOpen(), isFalse);
      await FluentDb.init(groups);
      expect(FluentDb.isOpen(), isTrue);
    });

    test('close finishes queued calls first, then later calls fail with notInitialized', () async {
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('close_db'), providerList: [GadgetProvider()], inMemory: true)]);
      final Future<FluentSaveResult> saving = FluentDb.save<Gadget>(Gadget(name: 'queued'));
      final Future<void> closing = FluentDb.close();
      await saving;
      await closing;
      expect(FluentDb.isOpen(), isFalse);
      await expectLater(FluentDb.count<Gadget>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await FluentDb.close(); // closing twice is fine
    });

    test('restart without an earlier init is an ignoredCall', () async {
      await FluentDb.restart();
      await Future<void>.delayed(Duration.zero);
      expect(ofKind(FluentIssueKind.ignoredCall), isNotEmpty);
      expect(FluentDb.isOpen(), isFalse);
    });

    test('restart(update:) can add a provider and keeps the data of a file database', () async {
      final g = GadgetProvider();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('restart_upd'), providerList: [g])]);
      addTearDown(() async {
        await FluentDb.deleteDatabases(reopen: false);
      });
      await FluentDb.save<Gadget>(Gadget(name: 'kept'));
      await FluentDb.restart(update: (groups) => [for (final FluentGroup x in groups) FluentGroup(dbKey: x.dbKey, providerList: [...x.providerList, PageProvider()])]);
      expect(await FluentDb.count<Gadget>(), 1);
      await FluentDb.save<Page>(Page(title: 'new table'));
      expect(await FluentDb.count<Page>(), 1);
    });

    test('deleteDatabases: nothing open, or an unknown / closed key, is refused with databaseNotFound', () async {
      await expectLater(FluentDb.deleteDatabases(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotFound).having((e) => e.message, 'message', contains('No database is open'))));
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('del_db'), providerList: [GadgetProvider()], inMemory: true)]);
      await expectLater(
        FluentDb.deleteDatabases(dbKey: FluentDbKey('del_other')),
        throwsA(isA<FluentConfigException>().having((e) => e.message, 'message', contains('"del_other" is not open'))),
      );
    });

    test('deleteDatabases(dbKey:) deletes one file and reopens it empty while the other keeps its rows', () async {
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('del_one'), providerList: [GadgetProvider()]),
        FluentGroup(dbKey: FluentDbKey('del_two'), providerList: [PageProvider()]),
      ]);
      addTearDown(() async {
        await FluentDb.deleteDatabases(reopen: false);
      });
      await FluentDb.save<Gadget>(Gadget(name: 'g'));
      await FluentDb.save<Page>(Page(title: 'p'));
      await FluentDb.deleteDatabases(dbKey: FluentDbKey('del_one'));
      expect(await FluentDb.count<Gadget>(), 0);
      expect(await FluentDb.count<Page>(), 1);
      expect(File(await fileOf('del_two')).existsSync(), isTrue);
    });
  });

  group('circular references', () {
    test('two tables referencing each other are reported as circularReference and still work', () async {
      final a = CycleAProvider();
      final b = CycleBProvider();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('cycle_db'), providerList: [a, b], inMemory: true)]);
      await Future<void>.delayed(Duration.zero);
      final cycles = ofKind(FluentIssueKind.circularReference);
      expect(cycles, isNotEmpty);
      expect(cycles.first.fix, contains('cycle'));
      expect(FluentDb.isOpen(), isTrue);
      await FluentDb.save<CycleA>(CycleA());
      expect(await FluentDb.count<CycleA>(), 1);
    });
  });

  group('damaged bookkeeping', () {
    test('an unreadable query-stats table only means the costs are measured again', () async {
      db = FluentTestDb(name: 'stats_broken', persistent: true);
      final g = GadgetProvider();
      await db!.open([g]);
      await g.db.execute('DROP TABLE __fluent_stats');
      await g.db.execute('CREATE TABLE __fluent_stats (unrelated TEXT)');
      await db!.restart([GadgetProvider()]);
      await FluentDb.save<Gadget>(Gadget(name: 'x'));
      expect(await FluentDb.count<Gadget>(), 1);
      expect(db!.warnings, isEmpty);
    });
  });

  group('read pool', () {
    test('a database that is not in WAL mode gets no read pool and still reads', () async {
      db = FluentTestDb(name: 'no_wal', persistent: true);
      await db!.open(
        [GadgetProvider()],
        config: const FluentDbConfig(journalMode: SQLiteJournalMode.delete, readConnections: 2),
      );
      await FluentDb.save<Gadget>(Gadget(name: 'x'));
      expect(await FluentDb.count<Gadget>(), 1);
      expect(issues.where((i) => i.kind == FluentIssueKind.readPoolFallback), isEmpty, reason: 'not a failure: nothing to pool');
    });
  });

  group('maintenance', () {
    test('expired rows are removed at the start; a failing delete is reported and the database still opens', () async {
      db = FluentTestDb(name: 'maint_ttl', persistent: true);
      final p = ExpiringProvider();
      await db!.open([p]);
      await FluentDb.saveAll<Expiring>([Expiring(name: 'short', timeToLive: const Duration(hours: 1)), Expiring(name: 'forever')]);
      db!.clock.advance(const Duration(hours: 2));
      expect(await FluentDb.count<Expiring>(), 1, reason: 'expired rows are hidden');
      await db!.restart([ExpiringProvider()]);
      expect((await FluentDb.count<Expiring>(includeExpired: true)), 1, reason: 'removed by the start-up clean-up');

      // Now a delete that always fails.
      await FluentDb.save<Expiring>(Expiring(name: 'again', timeToLive: const Duration(hours: 1)));
      final raw = FluentDb.provider<ExpiringProvider>().db;
      await raw.execute("CREATE TRIGGER no_delete BEFORE DELETE ON expiring BEGIN SELECT RAISE(ABORT, 'locked by test'); END");
      db!.clock.advance(const Duration(hours: 2));
      await db!.restart([ExpiringProvider()]);
      expect(FluentDb.isOpen(), isTrue);
      expect(await FluentDb.count<Expiring>(), 1, reason: 'the expired row is hidden although it could not be removed');
      expect(await FluentDb.count<Expiring>(includeExpired: true), 2);
      await FluentDb.provider<ExpiringProvider>().db.execute('DROP TRIGGER IF EXISTS no_delete');
    });

    test('cleanOrphans reports a failing clean-up to the caller, and the start-up one as maintenanceFailed', () async {
      db = FluentTestDb(name: 'maint_orphans', persistent: true);
      const FluentDbConfig noFk = FluentDbConfig(enableForeignKeys: false);
      final people = PersonProvider();
      await db!.open([people, ProfileProvider()], config: noFk);
      final raw = people.db;
      final fk = (await raw.rawQuery("PRAGMA foreign_key_list('people')")).map((r) => r['from']! as String).toList();
      expect(fk, isNotEmpty);
      await raw.execute('INSERT INTO people (name, ${fk.first}) VALUES (?, ?)', ['orphan', 12345]);
      await raw.execute("CREATE TRIGGER no_upd BEFORE UPDATE ON people BEGIN SELECT RAISE(ABORT, 'locked by test'); END");
      await raw.execute("CREATE TRIGGER no_del BEFORE DELETE ON people BEGIN SELECT RAISE(ABORT, 'locked by test'); END");

      await expectLater(FluentDb.cleanOrphans(), throwsA(anything));

      await db!.restart([PersonProvider(), ProfileProvider()], config: noFk);
      expect(FluentDb.isOpen(), isTrue);
      expect(db!.issues.where((i) => i.kind == FluentIssueKind.maintenanceFailed).map((i) => i.title), anyElement(contains('Failed to clean up dangling references in "people"')));
    });
  });

  group('timers', () {
    Future<void> waitUntil(Future<bool> Function() done, FluentTestDb t) async {
      for (int i = 0; i < 100; i++) {
        if (await done()) return;
        await t.settle(frame: const Duration(milliseconds: 40));
      }
      fail('the timer never did its work');
    }

    test('the optimize timer queues PRAGMA optimize on its own', () async {
      db = FluentTestDb(name: 'timer_opt', persistent: true);
      await db!.open([GadgetProvider()], fluentConfig: const FluentConfig(optimizeInterval: Duration(milliseconds: 30), trashPurgeInterval: null));
      await db!.settle();
      final int before = FluentDb.engineStats().completed;
      await waitUntil(() async => FluentDb.engineStats().completed > before, db!);
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: true));
    });

    test('the optimize timer skips read-only databases', () async {
      final String path = await fileOf('timer_ro');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('timer_ro'), providerList: [GadgetProvider()])]);
      await FluentDb.close();
      FluentDbInternals.reset();
      expect(File(path).existsSync(), isTrue);
      await FluentDb.init(
        [FluentGroup(dbKey: FluentDbKey('timer_ro'), providerList: [GadgetProvider()], readOnly: true)],
        config: const FluentConfig(optimizeInterval: Duration(milliseconds: 20), trashPurgeInterval: null),
      );
      final int before = FluentDb.engineStats().completed;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await idle();
      expect(FluentDb.engineStats().completed, before, reason: 'no PRAGMA optimize was queued on a read-only file');
      await FluentDb.close();
      await File(path).delete();
    });

    test('the trash purge timer removes trash past its retention', () async {
      db = FluentTestDb(name: 'timer_purge', persistent: true);
      await db!.open([CommentProvider()], fluentConfig: const FluentConfig(trashRetention: Duration(days: 1), trashPurgeInterval: null, optimizeInterval: null));
      await FluentDb.saveAll<Comment>([Comment(text: 'a'), Comment(text: 'b')]);
      final Comment a = (await FluentDb.findFirst<Comment>(orderBy: 'id'))!;
      await FluentDb.delete<Comment>(a);
      db!.clock.advance(const Duration(days: 2));
      expect(await FluentDb.withTrash<Comment>().count(), 2, reason: 'still in the trash: nothing purged yet');
      FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 1), trashPurgeInterval: Duration(milliseconds: 30), optimizeInterval: null));
      await waitUntil(() async => await FluentDb.withTrash<Comment>().count() == 1, db!);
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: false));
      FluentDb.configure(const FluentConfig(trashPurgeInterval: null, optimizeInterval: null));
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
    });

    test('the trash purge timer follows the library clock: moving db.clock runs it (known bug 4)', () async {
      db = FluentTestDb(name: 'timer_clock', persistent: true);
      await db!.open([CommentProvider()], fluentConfig: const FluentConfig(trashRetention: Duration(days: 1), trashPurgeInterval: Duration(hours: 6), optimizeInterval: null));
      await FluentDb.saveAll<Comment>([Comment(text: 'a'), Comment(text: 'b')]);
      await FluentDb.delete<Comment>((await FluentDb.findFirst<Comment>(orderBy: 'id'))!);
      db!.clock.advance(const Duration(hours: 1));
      await db!.settle();
      expect(await FluentDb.withTrash<Comment>().count(), 2, reason: 'neither the retention nor the interval has passed');
      db!.clock.advance(const Duration(days: 2));
      await waitUntil(() async => await FluentDb.withTrash<Comment>().count() == 1, db!);
    });

    test('a clock timer reports a failing run, keeps running, and stops for good on cancel', () async {
      final FluentTestClock clock = FluentTestClock();
      int runs = 0;
      final FluentClockTimer timer = FluentClockTimer(const Duration(hours: 1), () async {
        runs++;
        throw StateError('boom');
      });
      try {
        clock.advance(const Duration(minutes: 30));
        await Future<void>.delayed(Duration.zero);
        expect(runs, 0);
        clock.advance(const Duration(minutes: 31));
        await Future<void>.delayed(Duration.zero);
        expect(runs, 1, reason: 'the error stays inside the timer');
        clock.advance(const Duration(hours: 2));
        await Future<void>.delayed(Duration.zero);
        expect(runs, 2);
        clock.advance(const Duration(days: -10));
        clock.advance(const Duration(hours: 1));
        await Future<void>.delayed(Duration.zero);
        expect(runs, 3, reason: 'a clock moved back does not stall the timer');
        timer.cancel();
        clock.advance(const Duration(days: 1));
        await Future<void>.delayed(Duration.zero);
        expect(runs, 3);
        expect(timer.isCancelled, isTrue);
      } finally {
        timer.cancel();
        clock.reset();
      }
    });

    test('timers stop with close and are not started before init', () async {
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      FluentDb.configure(const FluentConfig(optimizeInterval: Duration(milliseconds: 30)));
      await Future<void>.delayed(Duration.zero);
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      db = FluentTestDb();
      await db!.open([GadgetProvider()]);
      expect(FluentDbInternals.maintenanceTimers.optimize, isTrue);
      await FluentDb.close();
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      FluentDb.configure(const FluentConfig());
    });
  });

  group('archive purge', () {
    test('purgeArchivedColumns deletes the archived column once it is older than the limit', () async {
      db = FluentTestDb(name: 'archive_purge', persistent: true);
      DynamicProvider v(List<FluentDbColumn> Function() cols) => DynamicProvider('arch', cols);
      await db!.open([v(() => [FluentDbColumn.primary(), FluentDbColumn.text('keep'), FluentDbColumn.text('gone')])]);
      final p1 = FluentDb.provider<DynamicProvider>();
      await p1.save(p1.row({'keep': 'k', 'gone': 'g'}));
      await db!.restart([v(() => [FluentDbColumn.primary(), FluentDbColumn.text('keep')])]);

      Future<List<String>> columns() async => [for (final r in await FluentDb.provider<DynamicProvider>().db.rawQuery("PRAGMA table_info('arch')")) r['name']! as String];
      final archived = (await columns()).where((c) => c.startsWith('__fluent_removed')).toList();
      expect(archived, hasLength(1), reason: 'the removed column is kept under an archive name');

      await FluentDb.purgeArchivedColumns(olderThan: const Duration(days: 7));
      expect((await columns()).where((c) => c.startsWith('__fluent_removed')), hasLength(1), reason: 'too young to purge');
      db!.clock.advance(const Duration(days: 8));
      await FluentDb.purgeArchivedColumns(olderThan: const Duration(days: 7));
      expect(await columns(), containsAll(['id', 'keep']));
      expect((await columns()).where((c) => c.startsWith('__fluent_removed')), isEmpty);
      final report = (await FluentDb.schemaReport()).single;
      expect(report.tables.single.archived, isEmpty);
    });
  });
}
