// Audit tests for schema sync, migrations and full-text indexes. A test that FAILS demonstrates a bug.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'audit_schema_${counter++}', persistent: true));
  tearDown(() => db.close());

  group('SCH-1 rules declared in customSql of an added column', () {
    test('an added NOT NULL column declared through customSql starts with NULLs instead of failing the start', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});

      // Same column as FluentDbColumn.text('tag', isNotNull: true), which the library adds as a pending NOT NULL.
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn(name: 'tag', type: FluentDbDataType.text, customSql: 'TEXT NOT NULL')]));
      await db.restart([v2]);

      expect((await v2.db.query('t')).single['name'], 'kept');
    });

    test('an added UNIQUE column declared through customSql is added without failing the start', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn(name: 'code', type: FluentDbDataType.text, customSql: 'TEXT UNIQUE')]));
      await db.restart([v2]);

      expect((await v2.db.query('t')).single['name'], 'kept');
    });
  });

  group('SCH-2 rebuild with a view that reads another view', () {
    test('a rebuild of the table keeps a chain of views working', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'code': 'x'});
      await v1.db.execute('CREATE VIEW "v_first" AS SELECT "name" FROM "t"');
      await v1.db.execute('CREATE VIEW "v_second" AS SELECT "name" FROM "v_first"');

      // A new default is a changed definition: the table is rebuilt (not an in-place ALTER).
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', defaultValue: 'none'), FluentDbColumn.text('code')]));
      await db.restart([v2]);

      final rows = await v2.db.rawQuery('SELECT "name" FROM "v_second"');
      expect(rows.single['name'], 'a');
    });
  });

  group('SCH-4 full-text index after a rebuild', () {
    test('search finds the rows before and after the rebuild, and new rows are indexed by the triggers', () async {
      final v1Spec = TableSpec(columns: () => [FluentDbColumn.primary(), FluentDbColumn.text('title'), FluentDbColumn.text('body')], indexes: [const FluentIndex.fullText(['title'])]);
      final p1 = DynamicProvider.spec('docs', v1Spec);
      await db.open([p1]);
      await p1.db.insert('docs', {'title': 'alpha beta', 'body': 'x'});

      final v2Spec = TableSpec(
        columns: () => [FluentDbColumn.primary(), FluentDbColumn.text('title'), FluentDbColumn.text('body', defaultValue: 'none')],
        indexes: [const FluentIndex.fullText(['title'])],
      );
      final p2 = DynamicProvider.spec('docs', v2Spec);
      await db.restart([p2]);
      await p2.db.insert('docs', {'title': 'gamma delta', 'body': 'y'});

      final List<Map<String, Object?>> alpha = await p2.db.rawQuery("SELECT rowid AS r FROM \"__fluent_fts_docs\" WHERE \"__fluent_fts_docs\" MATCH 'alpha'");
      final List<Map<String, Object?>> gamma = await p2.db.rawQuery("SELECT rowid AS r FROM \"__fluent_fts_docs\" WHERE \"__fluent_fts_docs\" MATCH 'gamma'");
      expect(alpha.map((r) => r['r']).toList(), [1]);
      expect(gamma.length, 1);
      expect(gamma.single['r'], 2);
    });
  });

  group('Plan guard', () {
    test('a refused plan leaves the tables and their rows unchanged', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'kept'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', defaultValue: 'none'), FluentDbColumn.text('extra')]));
      await expectLater(db.restart([v2], onMigrationPlan: (FluentMigrationPlan plan) async => false), throwsA(anything));

      // Reopen with the old schema: nothing may have been applied by the refused plan.
      final v1Again = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v1Again]);
      final List<String> columns = [for (final r in await v1Again.db.rawQuery("PRAGMA table_info('t')")) r['name']! as String];
      expect(columns, isNot(contains('extra')));
      expect((await v1Again.db.query('t')).single['name'], 'kept');
    });
  });
}
