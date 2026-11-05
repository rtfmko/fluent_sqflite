import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/schema_models.dart';

Future<List<Map<String, Object?>>> tableInfo(Database db, String table) => db.rawQuery("PRAGMA table_info('$table')");

void main() {
  setUpFluentTests();

  group('Primary key auto-correction', () {
    test('a key not marked as primary is promoted when autoCorrectAllowed is true', () async {
      final provider = DynamicProvider(
        'notes',
        () => [FluentDbColumn(name: 'uid', type: FluentDbDataType.text), FluentDbColumn.text('title')],
        key: () => FluentDbColumn(name: 'uid', type: FluentDbDataType.text),
      );
      final db = FluentTestDb(name: 'pk_autocorrect', persistent: true);
      await db.open([provider]);

      final uid = (await tableInfo(provider.db, 'notes')).firstWhere((c) => c['name'] == 'uid');
      expect(uid['pk'], 1);
      expect(provider.primaryKeyColumn.isPrimaryKey, isTrue);

      await db.close();
    });

    test('auto-correction is skipped when autoCorrectAllowed is false', () async {
      final provider = DynamicProvider(
        'plain',
        () => [FluentDbColumn.primary(), FluentDbColumn(name: 'code', type: FluentDbDataType.text, autoCorrectAllowed: false)],
        key: () => FluentDbColumn(name: 'code', type: FluentDbDataType.text, autoCorrectAllowed: false),
      );
      final db = FluentTestDb(name: 'pk_no_autocorrect', persistent: true);
      await db.open([provider]);

      final code = (await tableInfo(provider.db, 'plain')).firstWhere((c) => c['name'] == 'code');
      expect(code['pk'], 0);
      expect(provider.primaryKeyColumn.isPrimaryKey, isFalse);

      await db.close();
    });
  });

  group('Lifecycle robustness', () {
    test('close after a failed init does not throw', () async {
      FluentDbInternals.reset();
      // An invalid CHECK expression makes CREATE TABLE fail after the database file is opened.
      final broken = DynamicProvider.spec('broken', TableSpec(columns: () => [FluentDbColumn.primary()], checks: const [FluentCheck('this is not sql')]));

      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('failed_init'), providerList: [broken])]),
        throwsA(anything),
      );
      await expectLater(FluentDb.close(), completes);
      FluentDbInternals.reset();
    });

    test('invalid database name error mentions the name once', () async {
      FluentDbInternals.reset();
      final provider = DynamicProvider('t', () => [FluentDbColumn.primary()]);

      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('bad-name'), providerList: [provider])]),
        throwsA(
          isA<FluentConfigException>()
              .having((e) => e.code, 'code', FluentErrorCode.invalidDatabaseName)
              .having((e) => '"bad-name"'.allMatches(e.message).length, 'mentions of the name', 1)
              .having((e) => e.hint, 'hint', contains("FluentDbKey('bad_name')")),
        ),
      );
      FluentDbInternals.reset();
    });

    test('one model type in two tables: each provider works, calls by type fail with a hint, watchers stay per table', () async {
      final a = DynamicProvider('notes_a', () => [FluentDbColumn.primary(), FluentDbColumn.text('t')]);
      final b = DynamicProvider('notes_b', () => [FluentDbColumn.primary(), FluentDbColumn.text('t')]);
      final db = FluentTestDb(name: 'shared_type', persistent: true);
      await db.open([a, b]);

      await a.save(a.row({'id': 1, 't': 'a'}));
      await b.save(b.row({'id': 1, 't': 'b'}));
      expect((await a.findById(1))?['t'], 'a');
      expect((await b.findById(1))?['t'], 'b');

      await expectLater(FluentDb.find<DynamicModel>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.ambiguousProvider)));
      await expectLater(() => FluentDb.provider<DynamicProvider>(), throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', contains('reference'))));
      expect(FluentDbInternals.providerForTable('notes_b'), same(b));

      final List<int> emitted = [];
      final sub = a.watch().listen((rows) => emitted.add(rows.length));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final int before = emitted.length;
      await b.save(b.row({'id': 2, 't': 'b2'}));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted.length, before, reason: 'a write to notes_b does not refresh a watcher of notes_a');
      await a.save(a.row({'id': 2, 't': 'a2'}));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted.last, 2);
      await sub.cancel();

      await db.close();
    });

    test('in-memory groups write no file, are separate from each other and start empty again', () async {
      FluentDbInternals.reset();
      FluentGroup group(String name, DynamicProvider p) => FluentGroup(dbKey: FluentDbKey(name), providerList: [p], inMemory: true);
      DynamicProvider table() => DynamicProvider('items', () => [FluentDbColumn.primary(), FluentDbColumn.text('t')]);

      DynamicProvider one = table(), two = table();
      await FluentDb.init([group('mem_one', one), group('mem_two', two)]);
      await one.save(one.row({'id': 1, 't': 'x'}));
      expect(await one.count(), 1);
      expect(await two.count(), 0, reason: 'two in-memory groups are two databases');
      expect(File('${await getDatabasesPath()}/mem_one.db').existsSync(), isFalse);

      await FluentDb.close();
      FluentDbInternals.reset();
      one = table();
      two = table();
      await FluentDb.init([group('mem_one', one), group('mem_two', two)]);
      expect(await one.count(), 0, reason: 'data is gone after close');
      await FluentDb.close();
      FluentDbInternals.reset();
    });

    test('deleteDatabases(reopen: false) deletes the file and leaves the database closed', () async {
      final db = FluentTestDb(name: 'to_drop', persistent: true);
      await db.open([DynamicProvider('t', () => [FluentDbColumn.primary()])]);
      final path = '${await getDatabasesPath()}/to_drop.db';
      expect(File(path).existsSync(), isTrue);

      await FluentDb.deleteDatabases(reopen: false);

      expect(File(path).existsSync(), isFalse);
      expect(FluentDb.isOpen(), isFalse);
      await FluentTestDb.closeCurrent();
    });
  });

  test('a failing database closes the databases the same init opened', () async {
    FluentDbInternals.reset();
    final DynamicProvider good = DynamicProvider('g', () => [FluentDbColumn.primary(), FluentDbColumn.text('a')]);
    final DynamicProvider bad = DynamicProvider.spec('b', TableSpec(columns: () => [FluentDbColumn.primary()], checks: const [FluentCheck('no_such_column > 0')]));
    await expectLater(
      FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('init_good'), providerList: [good], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('init_bad'), providerList: [bad], inMemory: true),
      ]),
      throwsA(isA<FluentException>()),
    );
    expect(FluentDb.isOpen(dbKey: FluentDbKey('init_good')), isFalse);
    FluentDbInternals.reset();
  });
}
