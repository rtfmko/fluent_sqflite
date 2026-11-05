// Regression tests for SCH-1 .. SCH-6 (schema sync, migration steps, full-text index, index names).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) =>
    () => [FluentDbColumn.primary(), ...extra()];

Future<List<String>> columnNames(DatabaseExecutor db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<int> historyCount(DatabaseExecutor db) async => (await db.query('__fluent_schema_history')).length;

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'fix_schema_${counter++}', persistent: true));
  tearDown(() => db.close());

  FluentDbColumn custom(String name, String sql) => FluentDbColumn(name: name, type: FluentDbDataType.text, customSql: sql);

  group('SCH-1 rules written in customSql of an added column', () {
    test('NOT NULL without default: the column is added pending, rows are kept, the second start is a no-op', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});
      List<FluentDbColumn> v2cols() => [FluentDbColumn.text('name'), custom('tag', 'TEXT NOT NULL')];
      final v2 = DynamicProvider('t', cols(v2cols));
      await db.restart([v2]);
      final Map<String, Object?> row = (await v2.db.query('t')).single;
      expect(row['name'], 'kept');
      expect(row['tag'], isNull);
      final int before = await historyCount(v2.db);
      final v3 = DynamicProvider('t', cols(v2cols));
      await db.restart([v3]);
      expect(await historyCount(v3.db), before);
    });

    test('NOT NULL with DEFAULT in customSql is added with the default', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), custom('tag', "TEXT NOT NULL DEFAULT 'x'")]));
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['tag'], 'x');
    });

    test('UNIQUE on a table with rows: rebuilt, rows kept, uniqueness enforced', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a'});
      await v1.db.insert('t', {'name': 'b'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), custom('code', 'TEXT UNIQUE')]));
      await db.restart([v2]);
      expect(await v2.db.query('t'), hasLength(2));
      await v2.db.insert('t', {'name': 'c', 'code': 'z'});
      await expectLater(v2.db.insert('t', {'name': 'd', 'code': 'z'}), throwsA(anything));
    });

    test('CHECK and DEFAULT in customSql work and the second start is a no-op', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});
      List<FluentDbColumn> v2cols() => [FluentDbColumn.text('name'), custom('size', "TEXT DEFAULT 'm' CHECK (size IN ('s', 'm', 'l'))")];
      final v2 = DynamicProvider('t', cols(v2cols));
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['size'], 'm');
      await expectLater(v2.db.insert('t', {'name': 'x', 'size': 'xl'}), throwsA(anything));
      final int before = await historyCount(v2.db);
      final v3 = DynamicProvider('t', cols(v2cols));
      await db.restart([v3]);
      expect(await historyCount(v3.db), before);
    });

    test('a DEFAULT expression in customSql is added by a rebuild', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), custom('at', "TEXT DEFAULT (datetime('now'))")]));
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['at'], isNotNull);
    });

    test('withoutNotNull strips the customSql rule', () {
      final String sql = custom('a', 'TEXT not  null').withoutNotNull.sqlDefinition.toUpperCase();
      expect(sql, isNot(contains('NULL')));
      expect(sql, contains('TEXT'));
    });
  });

  group('SCH-2 full-text index on a device without FTS', () {
    tearDown(() => FluentFullTextSchema.moduleAvailableOverride = null);

    test('the old index and its triggers are dropped, writes keep working, a fullTextFallback issue is reported', () async {
      final p1 = DynamicProvider.spec('docs', TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: [const FluentIndex.fullText(['title'])]));
      await db.open([p1]);
      await p1.db.insert('docs', {'title': 'alpha'});
      expect(await p1.db.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE '%fluent_fts_docs%'"), isNotEmpty);

      FluentFullTextSchema.moduleAvailableOverride = (String module) => false;
      // A changed table forces the full sync (and the full-text pass).
      final p2 = DynamicProvider.spec(
        'docs',
        TableSpec(columns: cols(() => [FluentDbColumn.text('title'), FluentDbColumn.text('extra')]), indexes: [const FluentIndex.fullText(['title'])]),
      );
      await db.restart([p2]);
      expect(await p2.db.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE '%fluent_fts_docs%'"), isEmpty);
      await p2.db.insert('docs', {'title': 'beta'});
      expect(await p2.db.query('docs'), hasLength(2));
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.fullTextFallback));
    });
  });

  group('SCH-3 dropColumns of a pending step', () {
    test('the step can copy data out of the column it drops', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('legacy')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'legacy': 'old-a'});
      final v2 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('modern')]),
          migrations: const [
            FluentDbMigration(id: 'move_legacy', rawSql: ['UPDATE "t" SET "modern" = "legacy"'], dropColumns: ['legacy']),
          ],
        ),
      );
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['modern'], 'old-a');
      final List<String> names = await columnNames(v2.db, 't');
      expect(names, isNot(contains('legacy')));
      expect(names.where((c) => c.startsWith('__fluent_removed_')), isEmpty);
    });

    test('onMigrate reads the column too; a column dropped by a rebuild (other changes pending) works as well', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('legacy', isNotNull: true, defaultValue: 'd')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'legacy': 'old-a'});
      String? seen;
      final spec = TableSpec(
        columns: cols(() => [FluentDbColumn.text('name', defaultValue: 'n'), FluentDbColumn.text('modern')]),
        migrations: [
          FluentDbMigration(
            id: 'move_legacy',
            dropColumns: const ['legacy'],
            onMigrate: (txn) async {
              seen = (await txn.rawQuery('SELECT "legacy" FROM "t"')).single['legacy'] as String?;
              await txn.execute('UPDATE "t" SET "modern" = "legacy"');
            },
          ),
        ],
      );
      final v2 = DynamicProvider.spec('t', spec);
      await db.restart([v2]);
      expect(seen, 'old-a');
      expect((await v2.db.query('t')).single['modern'], 'old-a');
      expect(await columnNames(v2.db, 't'), isNot(contains('legacy')));
      // The step is applied: a second start neither runs it nor looks for the column.
      seen = null;
      final v3 = DynamicProvider.spec('t', spec);
      await db.restart([v3]);
      expect(seen, isNull);
      expect(await v3.db.query('t'), hasLength(1));
    });
  });

  group('SCH-4 quarantine names', () {
    test('an existing quarantine table is never overwritten: the new one gets another name', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.insert('t', {'code': 'a'});
      await v1.db.insert('t', {'code': 'a'});
      await v1.db.insert('t', {'code': 'b'});
      await v1.db.execute('CREATE TABLE "__fluent_rejected_t_r2" ("keep" TEXT)');
      await v1.db.insert('__fluent_rejected_t_r2', {'keep': 'mine'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code', isUnique: true)]));
      await db.restart([v2]);
      expect(await v2.db.query('t'), hasLength(2));
      expect((await v2.db.query('__fluent_rejected_t_r2')).single['keep'], 'mine');
      expect(await v2.db.query('__fluent_rejected_t_r2_2'), hasLength(1));
    });
  });

  group('SCH-5 an index of the app with the name of a model index', () {
    test('another definition is not adopted, replaced or dropped; a warning is reported', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.execute('CREATE INDEX "my_idx" ON "t" ("code")');

      final v2 = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code')]), indexes: [const FluentIndex(['name'], name: 'my_idx')]),
      );
      await db.restart([v2]);
      final String sql = (await v2.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'my_idx'")).single['sql']! as String;
      expect(sql, contains('"code"'));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.indexSkipped), isNotEmpty);

      // A rebuild leaves it alone too.
      final v3 = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('code')]), indexes: [const FluentIndex(['name'], name: 'my_idx')]),
      );
      await db.restart([v3]);
      final String after = (await v3.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'my_idx'")).single['sql']! as String;
      expect(after, contains('"code"'));

      // The model no longer declares the index: the app's one stays.
      final v4 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('code')]));
      await db.restart([v4]);
      expect(await v4.db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = 'my_idx'"), isNotEmpty);
    });
  });

  group('SCH-6 steps with the same label', () {
    test('id "v2" and version 2 are refused before anything runs', () async {
      final p = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('name')]),
          migrations: const [
            FluentDbMigration(id: 'v2', rawSql: ['SELECT 1']),
            FluentDbMigration(version: 2, rawSql: ['SELECT 2']),
          ],
        ),
      );
      await expectLater(db.open([p]), throwsA(isA<FluentSchemaException>().having((e) => e.hint, 'hint', isNotNull)));
    });

    test('two equal ids are refused', () async {
      final p = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('name')]),
          migrations: const [
            FluentDbMigration(id: 'fix', rawSql: ['SELECT 1']),
            FluentDbMigration(id: 'fix', rawSql: ['SELECT 2']),
          ],
        ),
      );
      await expectLater(db.open([p]), throwsA(isA<FluentSchemaException>()));
    });
  });
}
