import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/schema_models.dart';

/// Closes everything the library has open and forgets its registry (between tests).
Future<void> resetAll() async {
  await FluentDb.close();
  FluentDbInternals.reset();
}

DynamicProvider items([String table = 'items']) => DynamicProvider(table, () => [FluentDbColumn.primary(), FluentDbColumn.text('t')]);

/// A single-use Iterable: a second pass yields nothing (the caller's own iterable, handed to `init` twice).
class OneShot extends Iterable<FluentGroup> {
  OneShot(List<FluentGroup> groups) : _iterator = groups.iterator;

  final Iterator<FluentGroup> _iterator;

  @override
  Iterator<FluentGroup> get iterator => _iterator;
}

void main() {
  setUpFluentTests();

  setUp(resetAll);
  tearDown(resetAll);

  group('Registry consistency', () {
    test('a provider instance shared by two groups is refused with a hint (DB-1 decision)', () async {
      final FluentDbKey a = FluentDbKey('audit_shared_a');
      final FluentDbKey b = FluentDbKey('audit_shared_b');
      final DynamicProvider shared = items('shared');

      await expectLater(
        FluentDb.init([
          FluentGroup(dbKey: a, providerList: [shared], inMemory: true),
          FluentGroup(dbKey: b, providerList: [shared], inMemory: true),
        ]),
        throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', contains('one provider instance per group'))),
      );
      expect(FluentDb.isOpen(), isFalse);
    });

    test('a failing second group leaves no database of the call open', () async {
      final DynamicProvider first = items('first_ok');
      final DynamicProvider broken = DynamicProvider.spec('broken', TableSpec(columns: () => [FluentDbColumn.primary()], checks: const [FluentCheck('this is not sql')]));

      await expectLater(
        FluentDb.init([
          FluentGroup(dbKey: FluentDbKey('audit_first_ok'), providerList: [first], inMemory: true),
          FluentGroup(dbKey: FluentDbKey('audit_broken'), providerList: [broken], inMemory: true),
        ]),
        throwsA(anything),
      );

      expect(FluentDb.isOpen(), isFalse);
      expect(first.dbOrNull?.isOpen ?? false, isFalse, reason: 'the database of the first group was opened and must be closed again');
    });

    test('calls after close fail with the documented errors', () async {
      // The doc of FluentDb.close: FluentDb calls (provider lookup) fail with notInitialized, a held provider with engineClosed.
      final held = items('closed_api');
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('audit_closed_api'), providerList: [held], inMemory: true)]);
      await FluentDb.close();

      await expectLater(FluentDb.count<DynamicModel>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await expectLater(held.count(), throwsA(isA<FluentCancelledException>()));
    });
  });

  group('File safety', () {
    test('deleteDatabases does not delete a read-only (prebuilt) database file', () async {
      final FluentTestDb first = FluentTestDb(name: 'audit_ro_delete', persistent: true);
      await first.open([items('ro_items')]);
      await first.close(keepFile: true);
      final String path = join(await databaseFactory.getDatabasesPath(), 'audit_ro_delete.db');
      expect(File(path).existsSync(), isTrue, reason: 'precondition: the file exists');

      FluentDbInternals.reset();
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('audit_ro_delete'), providerList: [items('ro_items')], readOnly: true)]);

      Object? error;
      try {
        await FluentDb.deleteDatabases();
      } catch (e) {
        error = e; // reopening the read-only group fails once its file is gone
      }
      expect(File(path).existsSync(), isTrue, reason: 'a read-only file is not the library\'s data to delete');
      expect(error, isNull, reason: 'deleteDatabases() threw: $error');
    });

    test('init does not delete the file of a group that is named fluent_system', () async {
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('fluent_system'), providerList: [items('sys_items')])]);
      final String file = join(await databaseFactory.getDatabasesPath(), 'fluent_system.db');
      // The legacy-file clean-up runs unawaited after init; give it time to run.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(File(file).existsSync(), isTrue, reason: 'init deleted the file of an open group');
    });

    test('resetOnSchemaError retry keeps the groups when the caller passes a single-use Iterable', () async {
      final String path = join(await databaseFactory.getDatabasesPath(), 'audit_retry.db');
      // Garbage file: the first open fails ("file is not a database"), resetOnSchemaError deletes it and retries.
      File(path).writeAsBytesSync(List<int>.filled(4096, 0x41));

      final OneShot groups = OneShot([FluentGroup(dbKey: FluentDbKey('audit_retry'), providerList: [items('retry')], resetOnSchemaError: true)]);
      await FluentDb.init(groups);

      expect(FluentDb.isOpen(dbKey: FluentDbKey('audit_retry')), isTrue, reason: 'the retry re-read the Iterable, found no groups and opened nothing');
    });
  });
}
