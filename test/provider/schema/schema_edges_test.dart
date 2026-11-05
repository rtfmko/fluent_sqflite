// Schema sync edges: archived oldName, dropped renames, pending NOT NULL on rebuilds, rowid conversion, AUTOINCREMENT
// of emptied tables, legacy migration tables, adopted archives, quoted names, app indexes, unlabeled / restoring /
// dropping steps.
// ignore_for_file: implementation_imports, depend_on_referenced_packages
@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

Future<List<String>> columnNames(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<String> tableSql(Database db, String table) async => (await db.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).single['sql']! as String;

Iterable<FluentIssue> issuesOf(FluentTestDb db, FluentIssueKind kind) => db.issues.where((i) => i.kind == kind);

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;

  setUp(() => db = FluentTestDb(name: 'se_${counter++}_${DateTime.now().microsecondsSinceEpoch}', persistent: true));
  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('renames', () {
    test('oldName pointing at an archived column starts empty and reports a schemaFallback with the restore step', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'nick': 'nn'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v2]);
      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn(name: 'handle', type: FluentDbDataType.text, oldName: 'nick')]));
      await db.restart([v3]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.schemaFallback).single;
      expect(issue.title, contains('"nick" is archived'));
      expect(issue.fix, contains('restoreColumns: {"nick": "handle"}'));
      final row = (await v3.db.query('t')).single;
      expect(row['handle'], isNull);
      expect(await columnNames(v3.db, 't'), contains(predicate<String>((n) => n.startsWith('__fluent_removed_nick_'))));
    });

    test('a removed + added column of the same REAL type is reported as a possible rename (archive)', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.real('score')]));
      await db.open([v1]);
      await v1.db.insert('t', {'score': 1.5});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.real('points')]));
      await db.restart([v2]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.possibleRename).single;
      expect(issue.fix, contains('restoreColumns'));
      expect(issue.code, contains("'score': 'points'"));
    });

    test('with removedColumns: drop the possible-rename hint says the values are gone and points at oldName', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1], removedColumns: FluentColumnRemoval.drop);
      await v1.db.insert('t', {'name': 'a', 'nick': 'nn'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('handle')]));
      await db.restart([v2], removedColumns: FluentColumnRemoval.drop);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.possibleRename).single;
      expect(issue.fix, contains('oldName'));
      expect(issue.code, contains("oldName: 'nick'"));
      expect(await columnNames(v2.db, 't'), isNot(contains('nick')));
      expect((await v2.db.query('t')).single['handle'], isNull);
    });

    test('removedColumns: drop inside a rebuild removes the column with its data and keeps no archive', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('age'), FluentDbColumn.text('junk')]));
      await db.open([v1], removedColumns: FluentColumnRemoval.drop);
      await v1.db.insert('t', {'name': 'a', 'age': 3, 'junk': 'x'});
      // age changes type (rebuild) while junk disappears.
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]));
      await db.restart([v2], removedColumns: FluentColumnRemoval.drop);
      final List<String> names = await columnNames(v2.db, 't');
      expect(names, isNot(contains('junk')));
      expect(names.where((n) => n.startsWith('__fluent_removed_')), isEmpty);
      expect((await v2.db.query('t')).single['name'], 'a');
    });
  });

  group('rebuilds', () {
    test('a column made NOT NULL without default while rows are NULL stays nullable (columnKeptNullable) through a rebuild', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('tag')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a'});
      await v1.db.insert('t', {'name': 'b', 'tag': 'x'});
      // Changing the type of "name" forces a rebuild; "tag" becomes NOT NULL.
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.blob('name'), FluentDbColumn.text('tag', isNotNull: true)]));
      await db.restart([v2]);
      expect(issuesOf(db, FluentIssueKind.columnKeptNullable).single.title, contains('"tag"'));
      expect(await v2.db.query('t'), hasLength(2));
      expect((await tableSql(v2.db, 't')).toUpperCase(), isNot(contains('"TAG" TEXT NOT NULL')));
    });

    test('a new NOT NULL column without default on a table with rows is added nullable in a rebuild too', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.blob('name'), FluentDbColumn.text('extra', isNotNull: true)]));
      await db.restart([v2]);
      expect(issuesOf(db, FluentIssueKind.columnKeptNullable).single.title, contains('"extra"'));
      expect((await v2.db.query('t')).single['extra'], isNull);
    });

    test('rowid table <-> WITHOUT ROWID converts with the data and records the change', () async {
      FluentDbColumn code() => FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true);
      final v1 = DynamicProvider.spec('t', TableSpec(columns: () => [code(), FluentDbColumn.text('name')], key: code));
      await db.open([v1]);
      await v1.db.insert('t', {'code': 'a', 'name': 'x'});
      final v2 = DynamicProvider.spec('t', TableSpec(columns: () => [code(), FluentDbColumn.text('name')], key: code, withoutRowId: true));
      await db.restart([v2]);
      expect((await tableSql(v2.db, 't')).toUpperCase(), contains('WITHOUT ROWID'));
      expect((await v2.db.query('t')).single['name'], 'x');
      final v3 = DynamicProvider.spec('t', TableSpec(columns: () => [code(), FluentDbColumn.text('name')], key: code));
      await db.restart([v3]);
      expect((await tableSql(v3.db, 't')).toUpperCase(), isNot(contains('WITHOUT ROWID')));
      expect((await v3.db.query('t')).single['name'], 'x');
      final List<String> history = [for (final r in await v3.db.query('__fluent_schema_history', columns: ['changes'], where: 'table_name = ?', whereArgs: ['t'])) r['changes']! as String];
      expect(history.join('|'), allOf(contains('converted to WITHOUT ROWID'), contains('converted to a rowid table')));
    });

    test('AUTOINCREMENT of an emptied table survives a rebuild: deleted ids do not come back', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      for (int i = 0; i < 3; i++) {
        await v1.db.insert('t', {'name': 'n$i'});
      }
      await v1.db.delete('t');
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.blob('name')]));
      await db.restart([v2]);
      expect(await v2.db.insert('t', {'name': 'x'}), 4);
    });
  });

  group('adopting a database', () {
    Future<void> legacyFile(List<String> statements) async {
      final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
      for (final String s in statements) {
        await raw.execute(s);
      }
      await raw.close();
    }

    test('steps recorded in the old __fluent_migrations table count as applied', () async {
      await legacyFile([
        'CREATE TABLE "t" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        "INSERT INTO \"t\" (\"name\") VALUES ('keep')",
        'CREATE TABLE "__fluent_migrations" ("table_name" TEXT, "version" INTEGER)',
        "INSERT INTO \"__fluent_migrations\" VALUES ('t', 2)",
      ]);
      final p = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name')]), migrations: const [FluentDbMigration(version: 2, rawSql: ["UPDATE \"t\" SET \"name\" = 'changed'"])]),
      );
      await db.open([p]);
      expect((await p.db.query('t')).single['name'], 'keep', reason: 'step v2 already ran in the old version');
    });

    test('archived columns found on disk when the snapshot is rebuilt can still be restored', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'nick': 'nn'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      await db.close(keepFile: true);
      final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
      await raw.delete('__fluent_schema', where: 'table_name = ?', whereArgs: ['t']);
      await raw.close();

      final v3 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('display')]),
          migrations: const [FluentDbMigration(id: 'restore_nick', restoreColumns: {'nick': 'display'})],
        ),
      );
      await db.open([v3]);
      expect((await v3.db.query('t')).single['display'], 'nn');
    });
  });

  test('a column name with a double quote survives parse, add and rebuild', () async {
    final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('we"ird')]));
    await db.open([v1]);
    await v1.db.rawInsert('INSERT INTO t ("we""ird") VALUES (?)', ['v']);
    final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('we"ird'), FluentDbColumn.text('plain')]));
    await db.restart([v2]);
    final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.blob('we"ird'), FluentDbColumn.text('plain')]));
    await db.restart([v3]);
    expect((await v3.db.query('t')).single['we"ird'], isNotNull);
    expect(await columnNames(v3.db, 't'), contains('we"ird'));
  });

  test('an index of the app that equals the index of the model is accepted without a warning', () async {
    final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
    await db.open([v1]);
    const FluentIndex index = FluentIndex(['name']);
    await v1.db.execute(index.createSql('t'));
    final v2 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('name')]), indexes: const [index]));
    await db.restart([v2]);
    expect(issuesOf(db, FluentIssueKind.indexSkipped), isEmpty);
    expect(await v2.db.rawQuery('SELECT 1 FROM sqlite_master WHERE name = ?', [index.nameFor('t')]), hasLength(1));
  });

  group('migration steps', () {
    DynamicProvider withStep(List<FluentDbColumn> Function() columns, List<FluentDbMigration> steps) => DynamicProvider.spec('t', TableSpec(columns: columns, migrations: steps));

    test('a step without version or id is skipped with a hint', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a'});
      final v2 = withStep(cols(() => [FluentDbColumn.text('name')]), [
        const FluentDbMigration(rawSql: ["UPDATE \"t\" SET \"name\" = 'x'"]),
      ]);
      await db.restart([v2]);
      expect(issuesOf(db, FluentIssueKind.migrationSkipped).single.title, contains('no version or id'));
      expect((await v2.db.query('t')).single['name'], 'a');
    });

    test('restoreColumns of an unknown archived column is skipped; the hint lists what is archived', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('old')]));
      await db.open([v1]);
      final v2 = withStep(cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('now')]), [
        const FluentDbMigration(id: 'r1', restoreColumns: {'ghost': 'now'}),
      ]);
      await db.restart([v2]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.migrationSkipped).single;
      expect(issue.title, contains('no archived column "ghost"'));
      expect(issue.fix, contains('old'));
    });

    test('restoreColumns with no archive at all says there is nothing to restore', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      final v2 = withStep(cols(() => [FluentDbColumn.text('name')]), [
        const FluentDbMigration(id: 'r1', restoreColumns: {'ghost': 'name'}),
      ]);
      await db.restart([v2]);
      expect(issuesOf(db, FluentIssueKind.migrationSkipped).single.fix, contains('has no archived columns'));
    });

    test('restoreColumns into a column that is not in the model fails the start with a typed error', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('old')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'a', 'old': 'o'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      final v3 = withStep(cols(() => [FluentDbColumn.text('name')]), [
        const FluentDbMigration(id: 'r1', restoreColumns: {'old': 'nowhere'}),
      ]);
      await expectLater(
        db.restart([v3]),
        throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationFailed).having((e) => e.hint, 'hint', contains('Add "nowhere" to the model first'))),
      );
    });

    test('dropColumns of one archive keeps the other archived columns', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'x', 'a': '1', 'b': '2'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      final v3 = withStep(cols(() => [FluentDbColumn.text('name')]), [
        const FluentDbMigration(id: 'drop_a', dropColumns: ['a']),
      ]);
      await db.restart([v3]);
      final List<String> names = await columnNames(v3.db, 't');
      expect(names.where((n) => n.startsWith('__fluent_removed_a_')), isEmpty);
      expect(names.where((n) => n.startsWith('__fluent_removed_b_')), hasLength(1));
      expect((await v3.db.query('t')).single['name'], 'x');
    });

    test('a live column SQLite cannot drop in place (UNIQUE) is dropped by a rebuild; other archives are carried over', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('gone'), FluentDbColumn.text('code', isUnique: true)]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'x', 'gone': 'g', 'code': 'c'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code', isUnique: true)]))]);
      final v3 = withStep(cols(() => [FluentDbColumn.text('name')]), [
        const FluentDbMigration(id: 'drop_code', dropColumns: ['code']),
      ]);
      await db.restart([v3]);
      final List<String> names = await columnNames(v3.db, 't');
      expect(names, isNot(contains('code')));
      expect(names.where((n) => n.startsWith('__fluent_removed_gone_')), hasLength(1), reason: 'the earlier archive is kept');
      expect((await v3.db.query('t')).single['name'], 'x');
    });
  });
}
