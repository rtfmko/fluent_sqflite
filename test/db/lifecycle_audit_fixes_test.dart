import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/schema_models.dart';

DynamicProvider items(String table) => DynamicProvider(table, () => [FluentDbColumn.primary(), FluentDbColumn.text('t')]);

class OneShot extends Iterable<FluentGroup> {
  OneShot(List<FluentGroup> groups) : _iterator = groups.iterator;

  final Iterator<FluentGroup> _iterator;

  @override
  Iterator<FluentGroup> get iterator => _iterator;
}

Future<String> fileOf(String name) async => join(await databaseFactory.getDatabasesPath(), '$name.db');

/// Creates the file of database [name] with one row in [table] and closes everything again.
Future<String> prebuilt(String name, String table) async {
  final DynamicProvider p = items(table);
  await FluentDb.init([FluentGroup(dbKey: FluentDbKey(name), providerList: [p])]);
  await p.save(p.row({'t': 'old'}));
  await FluentDb.close();
  FluentDbInternals.reset();
  return fileOf(name);
}

void main() {
  setUpFluentTests();

  late List<FluentIssue> issues;
  late StreamSubscription<FluentIssue> listener;
  late List<FluentLogRecord> records;

  setUp(() async {
    await FluentDb.close();
    FluentDbInternals.reset();
    issues = [];
    records = [];
    listener = FluentLog.issues.listen(issues.add);
    FluentLog.configure(level: FluentLogLevel.debug, onRecord: records.add, console: false);
  });

  tearDown(() async {
    FluentLifecycleHooks.deleteFile = (String path) => databaseFactory.deleteDatabase(path);
    await listener.cancel();
    await FluentDb.close();
    FluentDbInternals.reset();
    FluentLog.reset();
  });

  group('DB-1 a provider instance belongs to one group', () {
    test('init refuses it with a hint before anything is opened', () async {
      final DynamicProvider shared = items('shared');
      await expectLater(
        FluentDb.init([
          FluentGroup(dbKey: FluentDbKey('db1_a'), providerList: [shared], inMemory: true),
          FluentGroup(dbKey: FluentDbKey('db1_b'), providerList: [shared], inMemory: true),
        ]),
        throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', allOf(contains('one provider instance per group'), contains('two instances')))),
      );
      expect(FluentDb.isOpen(), isFalse);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('db1_a')), isFalse);
      expect(FluentDbInternals.providersOf('db1_a'), isEmpty);
    });

    test('planMigrations refuses it too', () async {
      final DynamicProvider shared = items('shared');
      await expectLater(
        FluentDb.planMigrations([
          FluentGroup(dbKey: FluentDbKey('db1_pa'), providerList: [shared], inMemory: true),
          FluentGroup(dbKey: FluentDbKey('db1_pb'), providerList: [shared], inMemory: true),
        ]),
        throwsA(isA<FluentConfigException>()),
      );
    });

    test('two instances of one class are fine, and restart keeps working with the same instance', () async {
      final DynamicProvider a = items('cache_items');
      final DynamicProvider b = items('main_items');
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('db1_x'), providerList: [a], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('db1_y'), providerList: [b], inMemory: true),
      ]);
      await FluentDb.restart();
      expect(a.dbName, 'db1_x');
      expect(b.dbName, 'db1_y');
      expect(FluentDb.isOpen(), isTrue);
    });
  });

  group('DB-2 deleteDatabases keeps read-only files', () {
    for (final bool reopen in [true, false]) {
      test('reopen: $reopen', () async {
        final String path = await prebuilt('db2_ro_$reopen', 'ro_items');
        final List<int> before = File(path).readAsBytesSync();
        final DynamicProvider ro = items('ro_items');
        final DynamicProvider rw = items('rw_items');
        await FluentDb.init([
          FluentGroup(dbKey: FluentDbKey('db2_ro_$reopen'), providerList: [ro], readOnly: true),
          FluentGroup(dbKey: FluentDbKey('db2_rw_$reopen'), providerList: [rw], inMemory: true),
        ]);
        await rw.save(rw.row({'t': 'x'}));

        await FluentDb.deleteDatabases(reopen: reopen);

        expect(File(path).existsSync(), isTrue);
        expect(File(path).readAsBytesSync(), before);
        expect(FluentDb.isOpen(dbKey: FluentDbKey('db2_ro_$reopen')), isTrue, reason: 'the read-only group stays open');
        expect(await ro.count(), 1);
        expect(FluentDb.isOpen(dbKey: FluentDbKey('db2_rw_$reopen')), reopen);
        if (reopen) expect(await rw.count(), 0);
      });
    }

    test('only read-only groups: nothing happens', () async {
      final String path = await prebuilt('db2_only', 'ro_items');
      final DynamicProvider ro = items('ro_items');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db2_only'), providerList: [ro], readOnly: true)]);
      await FluentDb.deleteDatabases();
      expect(File(path).existsSync(), isTrue);
      expect(await ro.count(), 1);
    });
  });

  group('DB-3 the legacy telemetry clean-up', () {
    test('keeps the file of a group named fluent_system (and its data)', () async {
      final DynamicProvider p = items('sys_items');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('fluent_system'), providerList: [p])]);
      await p.save(p.row({'t': 'kept'}));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File(await fileOf('fluent_system')).existsSync(), isTrue);
      expect(await p.count(), 1);
    });

    test('still deletes the legacy file when no group uses it', () async {
      final String legacy = await fileOf('fluent_system');
      final Database own = await databaseFactory.openDatabase(legacy);
      await own.execute('CREATE TABLE old_stats (x INTEGER)');
      await own.close();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db3_other'), providerList: [items('o')], inMemory: true)]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File(legacy).existsSync(), isFalse);
    });
  });

  group('DB-4 a delete is checked', () {
    test('deleteDatabases(reopen: true) fails loudly when the file stays', () async {
      final DynamicProvider p = items('t4');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db4_a'), providerList: [p])]);
      await p.save(p.row({'t': 'old'}));
      final String path = await fileOf('db4_a');
      FluentLifecycleHooks.deleteFile = (String _) async {}; // like a locked file: nothing happens, nothing is reported

      await expectLater(FluentDb.deleteDatabases(), throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', isNotNull)));
      expect(File(path).existsSync(), isTrue);
      expect(records.any((r) => r.message.contains('Database files deleted')), isFalse, reason: 'success must not be logged');
      expect(FluentDb.isOpen(dbKey: FluentDbKey('db4_a')), isFalse, reason: 'the old rows must not be served as "deleted"');
    });

    test('deleteDatabases(reopen: false) reports fileDeleteFailed and reopens the untouched database', () async {
      final DynamicProvider p = items('t4b');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db4_b'), providerList: [p])]);
      await p.save(p.row({'t': 'old'}));
      FluentLifecycleHooks.deleteFile = (String _) async => throw StateError('locked');

      await FluentDb.deleteDatabases(reopen: false);

      final FluentIssue issue = issues.singleWhere((i) => i.kind == FluentIssueKind.fileDeleteFailed);
      expect(issue.type, FluentIssueType.error);
      expect(records.any((r) => r.message.contains('Database files deleted')), isFalse);
      expect(await p.count(), 1);
    });

    test('a delete that works still works', () async {
      final DynamicProvider p = items('t4c');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db4_c'), providerList: [p])]);
      await p.save(p.row({'t': 'old'}));
      await FluentDb.deleteDatabases();
      expect(await p.count(), 0);
      expect(issues.where((i) => i.kind == FluentIssueKind.fileDeleteFailed), isEmpty);
    });

    test('resetOnSchemaError: a file that stays is not reported as recreated', () async {
      final String path = await fileOf('db4_reset');
      File(path).writeAsBytesSync(List<int>.filled(4096, 0x41));
      FluentLifecycleHooks.deleteFile = (String _) async {};

      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('db4_reset'), providerList: [items('r')], resetOnSchemaError: true)]),
        throwsA(isA<FluentConfigException>()),
      );
      await pumpEventQueue();
      expect(issues.any((i) => i.kind == FluentIssueKind.databaseRecreated), isFalse);
      expect(issues.any((i) => i.kind == FluentIssueKind.fileDeleteFailed), isTrue, reason: issues.map((i) => '${i.kind.name}: ${i.title}').join('; ') + records.map((r) => r.message).join(' / '));
      expect(File(path).existsSync(), isTrue);
    });
  });

  group('DB-5 / DB-6 resetOnSchemaError', () {
    test('the retry reuses the groups of a single-use Iterable (two groups)', () async {
      File(await fileOf('db5_bad')).writeAsBytesSync(List<int>.filled(4096, 0x41));
      await FluentDb.init(
        OneShot([
          FluentGroup(dbKey: FluentDbKey('db5_ok'), providerList: [items('ok')], inMemory: true),
          FluentGroup(dbKey: FluentDbKey('db5_bad'), providerList: [items('bad')], resetOnSchemaError: true),
        ]),
      );
      expect(FluentDb.isOpen(dbKey: FluentDbKey('db5_ok')), isTrue);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('db5_bad')), isTrue);
      expect(issues.any((i) => i.kind == FluentIssueKind.databaseRecreated), isTrue);
    });

    test('an in-memory group is never "recreated": no file delete, the typed error reaches the caller', () async {
      int deletes = 0;
      FluentLifecycleHooks.deleteFile = (String _) async => deletes++;
      final DynamicProvider broken = DynamicProvider.spec('broken', TableSpec(columns: () => [FluentDbColumn.primary()], checks: const [FluentCheck('this is not sql')]));
      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('db6_mem'), providerList: [broken], inMemory: true, resetOnSchemaError: true)]),
        throwsA(isA<FluentException>()),
      );
      expect(deletes, 0);
      await pumpEventQueue();
      expect(issues.any((i) => i.kind == FluentIssueKind.databaseRecreated), isFalse);
    });

    test('a throwing delete in the reset branch ends as the original typed error', () async {
      File(await fileOf('db6_throw')).writeAsBytesSync(List<int>.filled(4096, 0x41));
      FluentLifecycleHooks.deleteFile = (String _) async => throw StateError('boom');
      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('db6_throw'), providerList: [items('r')], resetOnSchemaError: true)]),
        throwsA(isA<FluentException>()),
      );
    });
  });

  group('DB-9 a failed init is logged once', () {
    test('one warning-or-error record for the failure', () async {
      final DynamicProvider broken = DynamicProvider.spec('broken9', TableSpec(columns: () => [FluentDbColumn.primary()], checks: const [FluentCheck('this is not sql')]));
      Object? error;
      try {
        await FluentDb.init([FluentGroup(dbKey: FluentDbKey('db9_fail'), providerList: [broken], inMemory: true)]);
      } catch (e) {
        error = e;
      }
      expect(error, isA<FluentException>());
      final List<FluentLogRecord> loud = records.where((r) => r.level.index >= FluentLogLevel.warning.index && (r.message.contains('db9_fail') || r.error == error)).toList();
      expect(loud, hasLength(1), reason: loud.map((r) => r.message).join('\n'));
      expect(loud.single.hint, isNotNull);
      expect(issues.where((i) => i.kind == FluentIssueKind.initFailed), hasLength(1));
    });
  });

  group('DB-10 planMigrations leaves read-only files alone', () {
    test('bytes and mtime unchanged, no journal files', () async {
      final String path = await prebuilt('db10_ro', 'ro_items');
      final List<int> before = File(path).readAsBytesSync();
      final DateTime mtime = File(path).lastModifiedSync();
      final DynamicProvider p = DynamicProvider('ro_items', () => [FluentDbColumn.primary(), FluentDbColumn.text('t'), FluentDbColumn.text('extra')]);

      final List<FluentMigrationPlan> plans = await FluentDb.planMigrations([FluentGroup(dbKey: FluentDbKey('db10_ro'), providerList: [p], readOnly: true)]);

      expect(plans, hasLength(1));
      expect(plans.single.database, 'db10_ro');
      expect(plans.single.changes, isEmpty);
      expect(File(path).readAsBytesSync(), before);
      expect(File(path).lastModifiedSync(), mtime);
      for (final String suffix in ['-journal', '-wal', '-shm']) {
        expect(File('$path$suffix').existsSync(), isFalse, reason: suffix);
      }
    });

    test('a missing read-only file is not created by the plan', () async {
      final String path = await fileOf('db10_missing');
      await FluentDb.planMigrations([FluentGroup(dbKey: FluentDbKey('db10_missing'), providerList: [items('m')], readOnly: true)]);
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('OBS-4 paths in log records', () {
    String text(FluentLogRecord r) => '${r.message} ${r.hint} ${r.context}';

    test('no record of init / close / delete carries a path by default', () async {
      final DynamicProvider p = items('obs');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('obs4_a'), providerList: [p])]);
      await FluentDb.deleteDatabases();
      await FluentDb.close();
      expect(records, isNotEmpty);
      expect(records.where((r) => text(r).contains('.db')), isEmpty);
    });

    test('a missing read-only file does not name the path; with showSqlArguments it does', () async {
      Future<String> message() async {
        try {
          await FluentDb.init([FluentGroup(dbKey: FluentDbKey('obs4_missing'), providerList: [items('m')], readOnly: true)]);
        } on FluentException catch (e) {
          return e.message;
        }
        return '';
      }

      expect(await message(), isNot(contains('obs4_missing.db')));
      FluentLog.configure(showSqlArguments: true);
      expect(await message(), contains('obs4_missing.db'));
    });

    test('with showSqlArguments the close record carries the path', () async {
      FluentLog.configure(showSqlArguments: true);
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('obs4_b'), providerList: [items('obs')])]);
      await FluentDb.close();
      expect(records.any((r) => r.message == 'Database closed successfully' && '${r.context}'.contains('obs4_b.db')), isTrue);
    });
  });
}
