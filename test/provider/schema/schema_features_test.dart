import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/schema_models.dart';

enum Status { draft, published }

Future<String> tableSql(Database db, String table) async =>
    (await db.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).first['sql']! as String;

Future<Set<String>> indexNames(Database db, String table) async =>
    {for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [table])) r['name']! as String};

Future<List<String>> columnNames(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

void main() {
  setUpFluentTests();

  group('Reserved words', () {
    test('columns named like SQL keywords work end to end', () async {
      final provider = DynamicProvider('orders', () => [FluentDbColumn.primary(), FluentDbColumn.integer('order'), FluentDbColumn.text('group')]);
      final db = FluentTestDb(name: 'reserved', persistent: true);
      await db.open([provider]);

      await provider.save(provider.row({'id': 1, 'order': 3, 'group': 'a'}));
      final found = await provider.findById(1);

      expect(found?['order'], 3);
      expect(found?['group'], 'a');
      expect(await provider.count(where: FluentFilter.eq('order', 3)), 1);
      await db.close();
    });
  });

  group('Composite primary key', () {
    final spec = TableSpec(
      columns: () => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day'), FluentDbColumn.integer('steps')],
      keys: () => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')],
      withoutRowId: true,
    );
    late DynamicProvider stats;
    late FluentTestDb db;

    setUp(() async {
      stats = DynamicProvider.spec('daily_stats', spec);
      db = FluentTestDb(name: 'composite_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      await db.open([stats]);
    });

    tearDown(() => db.close());

    test('table is created with PRIMARY KEY (a, b) and WITHOUT ROWID', () async {
      final sql = await tableSql(stats.db, 'daily_stats');
      expect(sql, contains('PRIMARY KEY ("user_id", "day")'));
      expect(sql, contains('WITHOUT ROWID'));

      final info = await stats.db.rawQuery("PRAGMA table_info('daily_stats')");
      final pk = {for (final r in info) r['name']: r['pk']};
      expect(pk['user_id'], 1);
      expect(pk['day'], 2);
      expect(stats.hasCompositeKey, isTrue);
    });

    test('save / upsert / find / exists / update / delete by FluentKey', () async {
      await stats.save(stats.row({'user_id': 1, 'day': 'mon', 'steps': 100}));
      await stats.save(stats.row({'user_id': 1, 'day': 'tue', 'steps': 200}));
      await stats.save(stats.row({'user_id': 2, 'day': 'mon', 'steps': 300}));

      // Upsert by the composite key updates instead of duplicating.
      await stats.save(stats.row({'user_id': 1, 'day': 'mon', 'steps': 150}));
      expect(await stats.count(), 3);

      final key = FluentKey({'user_id': 1, 'day': 'mon'});
      final found = await stats.findById(key);
      expect(found?['steps'], 150);
      expect(found?.key, key);
      expect(found?.primaryKeyValue, key);
      expect(await stats.exists(key), isTrue);
      expect(await stats.exists(FluentKey({'user_id': 9, 'day': 'mon'})), isFalse);

      await stats.updateById(key, {'steps': 175});
      expect((await stats.findById(key))?['steps'], 175);

      await stats.deleteById(key);
      await stats.deleteById(FluentKey({'user_id': 2, 'day': 'mon'}));
      expect(await stats.count(), 1);

      // A plain column filter still works on a composite-key table: all rows of user 1.
      await stats.deleteWhere(FluentFilter.eq('user_id', 1));
      expect(await stats.count(), 0);
    });

    test('a plain value for a composite key fails with a hint instead of a wrong query', () async {
      await expectLater(stats.findById(1), throwsA(isA<FluentArgumentException>().having((e) => e.code, 'code', FluentErrorCode.invalidKey).having((e) => e.hint, 'hint', contains('FluentKey'))));
    });
  });

  group('Indexes, checks and defaults', () {
    test('indexes are created on new tables and added to existing databases', () async {
      final db = FluentTestDb(name: 'indexes', persistent: true);
      final v1 = DynamicProvider('people', () => [FluentDbColumn.primary(), FluentDbColumn.text('email'), FluentDbColumn.text('last'), FluentDbColumn.text('first', indexed: true)]);
      await db.open([v1]);
      expect(await indexNames(v1.db, 'people'), {'idx_people_first', 'idx_people_expiry_date'});

      final v2 = DynamicProvider.spec(
        'people',
        TableSpec(
          columns: () => [FluentDbColumn.primary(), FluentDbColumn.text('email'), FluentDbColumn.text('last'), FluentDbColumn.text('first', indexed: true)],
          indexes: const [FluentIndex.unique(['email']), FluentIndex(['last', 'first']), FluentIndex(['missing_column'])],
        ),
      );
      await db.restart([v2]);

      expect(await indexNames(v2.db, 'people'), {'idx_people_first', 'idx_people_expiry_date', 'uidx_people_email', 'idx_people_last_first'});
      await expectLater(v2.db.insert('people', {'email': 'a@b.c'}).then((_) => v2.db.insert('people', {'email': 'a@b.c'})), throwsA(isA<DatabaseException>()));
      await db.close();
    });

    test('a unique index over duplicate data does not break init', () async {
      final db = FluentTestDb(name: 'dup_index', persistent: true);
      final v1 = DynamicProvider('tags', () => [FluentDbColumn.primary(), FluentDbColumn.text('name')]);
      await db.open([v1]);
      await v1.db.insert('tags', {'name': 'x'});
      await v1.db.insert('tags', {'name': 'x'});

      final v2 = DynamicProvider.spec('tags', TableSpec(columns: () => [FluentDbColumn.primary(), FluentDbColumn.text('name')], indexes: const [FluentIndex.unique(['name'])]));
      await expectLater(db.restart([v2]), completes);
      expect(await indexNames(v2.db, 'tags'), isNot(contains('uidx_tags_name')));
      await db.close();
    });

    test('table checks and typed defaults are applied', () async {
      final db = FluentTestDb(name: 'checks', persistent: true);
      final provider = DynamicProvider.spec(
        'periods',
        TableSpec(
          columns: () => [
            FluentDbColumn.primary(),
            FluentDbColumn.integer('start'),
            FluentDbColumn.integer('end'),
            FluentDbColumn.text('status', defaultValue: 'new'),
            FluentDbColumn.boolean('active', defaultValue: true),
          ],
          checks: const [FluentCheck('"end" >= "start"', name: 'valid_period')],
        ),
      );
      await db.open([provider]);

      await provider.db.insert('periods', {'start': 1, 'end': 2});
      final row = (await provider.db.query('periods')).single;
      expect(row['status'], 'new');
      expect(row['active'], 1);

      await expectLater(provider.db.insert('periods', {'start': 5, 'end': 1}), throwsA(isA<DatabaseException>()));
      await expectLater(provider.db.insert('periods', {'start': 1, 'end': 2, 'active': 7}), throwsA(isA<DatabaseException>()));
      await db.close();
    });
  });

  group('Converters', () {
    test('values are stored through the converter and read back as Dart types', () async {
      final db = FluentTestDb(name: 'converters', persistent: true);
      final provider = DynamicProvider('posts', () => [
        FluentDbColumn.primary(),
        FluentDbColumn.converted('status', const FluentEnumConverter(Status.values)),
        FluentDbColumn.converted('meta', const FluentJsonConverter<Map<String, dynamic>>()),
      ]);
      await db.open([provider]);

      await provider.save(provider.row({'id': 1, 'status': Status.published, 'meta': {'likes': 3}}));

      final raw = (await provider.db.query('posts')).single;
      expect(raw['status'], 'published');
      expect(raw['meta'], '{"likes":3}');

      final loaded = await provider.findById(1);
      expect(loaded?['status'], Status.published);
      expect(loaded?['meta'], {'likes': 3});
      await db.close();
    });
  });

  group('Migration steps', () {
    List<FluentDbColumn> columns() => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.text('legacy')];

    test('steps run once, in declaration order, and only on existing databases', () async {
      final db = FluentTestDb(name: 'steps', persistent: true);
      final log = <int>[];
      List<FluentDbMigration> migrations() => [
        FluentDbMigration(version: 3, onMigrate: (txn) async => log.add(3)),
        FluentDbMigration(version: 2, rawSql: const ["UPDATE items SET name = upper(name)"], onMigrate: (txn) async => log.add(2)),
      ];

      // Fresh database: steps are recorded, not executed.
      await db.open([DynamicProvider.spec('items', TableSpec(columns: columns, migrations: migrations()))]);
      expect(log, isEmpty);
      await db.close();

      // Existing database with data: steps run once.
      final v1 = DynamicProvider('items', columns);
      await db.open([v1]);
      await v1.db.insert('items', {'name': 'abc', 'legacy': 'x'});

      final v2 = DynamicProvider.spec('items', TableSpec(columns: columns, migrations: migrations()));
      await db.restart([v2]);
      expect(log, [3, 2]);
      expect((await v2.db.query('items')).single['name'], 'ABC');

      await db.restart([DynamicProvider.spec('items', TableSpec(columns: columns, migrations: migrations()))]);
      expect(log, [3, 2], reason: 'already applied steps must not run again');
      await db.close();
    });

    test('dropColumns removes a column the model no longer has, without archiving it first', () async {
      final db = FluentTestDb(name: 'drop_columns', persistent: true);
      final v1 = DynamicProvider('items', columns);
      await db.open([v1]);
      await v1.db.insert('items', {'name': 'keep', 'legacy': 'gone'});

      List<FluentDbColumn> withoutLegacy() => [FluentDbColumn.primary(), FluentDbColumn.text('name')];
      final v2 = DynamicProvider.spec('items', TableSpec(columns: withoutLegacy, migrations: const [FluentDbMigration(version: 1, dropColumns: ['legacy'])]));
      await db.restart([v2]);

      final List<String> names = await columnNames(v2.db, 'items');
      expect(names, isNot(contains('legacy')));
      expect(names.where((c) => c.startsWith('__fluent_removed_')), isEmpty);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.columnArchived), isEmpty, reason: 'dropped at once, never archived');
      expect((await v2.db.query('items')).single['name'], 'keep');
      await db.close();
    });

    test('dropColumns keeps a column that is still in the model', () async {
      final db = FluentTestDb(name: 'drop_kept', persistent: true);
      final v1 = DynamicProvider('items', columns);
      await db.open([v1]);
      await v1.db.insert('items', {'name': 'keep', 'legacy': 'still used'});

      final v2 = DynamicProvider.spec('items', TableSpec(columns: columns, migrations: const [FluentDbMigration(version: 1, dropColumns: ['legacy'])]));
      await db.restart([v2]);

      expect((await v2.db.query('items')).single['legacy'], 'still used');
      expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.migrationSkipped));
      await db.close();
    });

    test('a failing step rolls back and reports migrationFailed', () async {
      final db = FluentTestDb(name: 'failing_step', persistent: true);
      final v1 = DynamicProvider('items', columns);
      await db.open([v1]);

      final bad = DynamicProvider.spec('items', TableSpec(columns: columns, migrations: const [FluentDbMigration(version: 1, rawSql: ['UPDATE no_such_table SET x = 1'])]));
      await expectLater(db.restart([bad]), throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationFailed)));
      await db.close();
    });
  });

  group('Database configuration', () {
    test('custom directory and busy timeout', () async {
      final dir = await Directory.systemTemp.createTemp('fluent_custom_dir_');
      final provider = DynamicProvider('t', () => [FluentDbColumn.primary()]);
      FluentDbInternals.reset();

      await FluentDb.init([
        FluentGroup(
          dbKey: FluentDbKey('custom_dir'),
          providerList: [provider],
          directory: dir.path,
          config: const FluentDbConfig(busyTimeout: Duration(milliseconds: 1234)),
        ),
      ]);

      expect(File('${dir.path}${Platform.pathSeparator}custom_dir.db').existsSync(), isTrue);
      expect((await provider.db.rawQuery('PRAGMA busy_timeout')).single.values.first, 1234);

      await FluentDb.close();
      FluentDbInternals.reset();
    });

    test('read-only database: missing file gives a hint, existing file opens without schema sync', () async {
      FluentDbInternals.reset();
      final provider = DynamicProvider('catalog', () => [FluentDbColumn.primary(), FluentDbColumn.text('title')]);

      await expectLater(
        FluentDb.init([FluentGroup(dbKey: FluentDbKey('catalog_missing'), providerList: [provider], readOnly: true)]),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotFound).having((e) => e.hint, 'hint', contains('readOnly: false'))),
      );
      FluentDbInternals.reset();

      // Build the catalog, then reopen it read-only.
      final db = FluentTestDb(name: 'catalog', persistent: true);
      final writer = DynamicProvider('catalog', () => [FluentDbColumn.primary(), FluentDbColumn.text('title')]);
      await db.open([writer]);
      await writer.db.insert('catalog', {'title': 'Dune'});
      await db.close(keepFile: true);

      final reader = DynamicProvider('catalog', () => [FluentDbColumn.primary(), FluentDbColumn.text('title')]);
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('catalog'), providerList: [reader], readOnly: true)]);
      expect((await reader.db.query('catalog')).single['title'], 'Dune');
      await expectLater(reader.db.insert('catalog', {'title': 'x'}), throwsA(isA<DatabaseException>()));

      await FluentDb.close();
      FluentDbInternals.reset();
    });
  });
}
