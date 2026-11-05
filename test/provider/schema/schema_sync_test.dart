import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

Future<List<String>> columns(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<Map<String, Object?>> columnInfo(Database db, String table, String column) async =>
    (await db.rawQuery("PRAGMA table_info('$table')")).firstWhere((r) => r['name'] == column);

Future<int> revision(Database db, String table) async =>
    (await db.query('__fluent_schema', columns: ['revision'], where: 'table_name = ?', whereArgs: [table])).single['revision']! as int;

Future<int> historyCount(Database db, String table) async =>
    (await db.rawQuery('SELECT COUNT(*) AS c FROM __fluent_schema_history WHERE table_name = ?', [table])).first['c']! as int;

Future<Set<String>> indexes(Database db, String table) async =>
    {for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [table])) r['name']! as String};

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'sync_${counter++}', persistent: true));
  tearDown(() => db.close());

  group('Snapshot', () {
    test('an unchanged model does nothing on restart', () async {
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code', indexed: true)]));
      await db.open([p]);
      expect(await revision(p.db, 't'), 1);
      expect(await historyCount(p.db, 't'), 1);

      final again = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code', indexed: true)]));
      await db.restart([again]);
      expect(await revision(again.db, 't'), 1);
      expect(await historyCount(again.db, 't'), 1);
    });

    test('a start with an unchanged schema skips the sync and its write transaction', () async {
      List<FluentDbColumn> c() => [FluentDbColumn.text('name', indexed: true)];
      final articles = DynamicProvider('a', cols(c));
      await db.open([articles, DynamicProvider('b', cols(c))]);
      await articles.db.insert('a', {'name': 'kept'});

      final QueryCounter counter = await QueryCounter.install();
      try {
        final again = DynamicProvider('a', cols(c));
        await db.restart([again, DynamicProvider('b', cols(c))]);
        final List<String> schemaWrites = [
          for (final String s in counter.statements)
            if (RegExp(r'CREATE|ALTER|foreign_key_check|foreign_keys = OFF|table_info', caseSensitive: false).hasMatch(s)) s,
        ];
        expect(schemaWrites, isEmpty, reason: 'only the snapshot reads, no DDL and no foreign key switching');
        expect((await again.db.query('a')).single['name'], 'kept');
      } finally {
        counter.uninstall();
      }

      // A change takes the full sync again.
      final changed = DynamicProvider('a', cols(() => [FluentDbColumn.text('name', indexed: true), FluentDbColumn.text('extra')]));
      await db.restart([changed, DynamicProvider('b', cols(c))]);
      expect(await columns(changed.db, 'a'), contains('extra'));
    });

    test('a custom-type column does not rebuild the table on every start', () async {
      List<FluentDbColumn> c() => [FluentDbColumn(name: 'code', type: FluentDbDataType.custom, customSql: 'TEXT NOT NULL')];
      await db.open([DynamicProvider('t', cols(c))]);
      final p = DynamicProvider('t', cols(c));
      await db.restart([p]);
      expect(await revision(p.db, 't'), 1);
    });

    test('a database created before snapshots is adopted without data loss', () async {
      // An "old app version" created the table itself.
      await db.open([DynamicProvider('other', cols(() => []))]);
      await FluentTestDb.closeCurrent();

      final file = '${await getDatabasesPath()}/${db.name}.db';
      final legacy = await openDatabase(file);
      await legacy.execute('CREATE TABLE "legacy" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "created" BLOB, "_fs_metadata" TEXT, "expiry_date" INTEGER)');
      await legacy.insert('legacy', {'name': 'kept', 'created': 1000});
      await legacy.close();

      final p = DynamicProvider('legacy', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.timestamp('created')]));
      await db.open([p]);

      final row = (await p.db.query('legacy')).single;
      expect(row['name'], 'kept');
      expect(row['created'], 1000);
      expect((await columnInfo(p.db, 'legacy', 'created'))['type'], 'INTEGER', reason: 'timestamp is INTEGER now');
    });
  });

  group('Columns', () {
    test('added column → ADD COLUMN, rename via oldName keeps the data', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'title', type: FluentDbDataType.text, oldName: 'name'), FluentDbColumn.integer('age')]));
      await db.restart([v2]);

      final row = (await v2.db.query('t')).single;
      expect(row['title'], 'Ann');
      expect(row.containsKey('age'), isTrue);
      expect(await revision(v2.db, 't'), 2);
    });

    test('removed column is archived with its data; a new column with the same name starts clean', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'note': 'secret'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v2]);
      expect(await columns(v2.db, 't'), contains('__fluent_removed_note_r2'));
      expect((await v2.db.query('t')).single['__fluent_removed_note_r2'], 'secret');
      expect((await v2.findById(1))?['note'], isNull, reason: 'archived data is never read');

      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('note')]));
      await db.restart([v3]);
      final row = (await v3.db.query('t')).single;
      expect(row['note'], isNull);
      expect((await columnInfo(v3.db, 't', 'note'))['type'], 'INTEGER');
      expect(row['__fluent_removed_note_r2'], 'secret');
    });

    test('inserts keep working after a column is archived', () async {
      // NOT NULL with a default: renamed in place (the default fills it); without one: rebuilt without the constraint.
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code', isNotNull: true, defaultValue: 'x'), FluentDbColumn.text('must', isNotNull: true)]));
      await db.open([v1]);
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v2]);
      await v2.db.insert('t', {'name': 'new row'});
      expect((await columnInfo(v2.db, 't', '__fluent_removed_must_r2'))['notnull'], 0);
      expect(await columns(v2.db, 't'), contains('__fluent_removed_code_r2'), reason: 'renamed first, then carried over by the rebuild');
    });

    test('a removed column is archived in place, without rebuilding the table', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'note': 'secret'});

      final QueryCounter counter = await QueryCounter.install();
      try {
        final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
        await db.restart([v2]);
        expect(counter.statements.where((s) => s.contains('__fluent_tmp_')), isEmpty, reason: 'no rebuild');
        expect((await v2.db.query('t')).single['__fluent_removed_note_r2'], 'secret');
      } finally {
        counter.uninstall();
      }
    });

    test('FluentColumnRemoval.drop deletes removed columns', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.open([v1], removedColumns: FluentColumnRemoval.drop);
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v2], removedColumns: FluentColumnRemoval.drop);
      expect(await columns(v2.db, 't'), isNot(contains('note')));
      expect((await columns(v2.db, 't')).where((c) => c.startsWith('__fluent_removed_')), isEmpty);
    });

    test('NOT NULL without default on a non-empty table is pending, then enforced once filled', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      List<FluentDbColumn> v2cols() => [FluentDbColumn.text('name'), FluentDbColumn.text('status', isNotNull: true)];
      final v2 = DynamicProvider('t', cols(v2cols));
      await db.restart([v2]);
      expect((await columnInfo(v2.db, 't', 'status'))['notnull'], 0, reason: 'pending');

      await v2.db.update('t', {'status': 'active'});
      final v3 = DynamicProvider('t', cols(v2cols));
      await db.restart([v3]);
      expect((await columnInfo(v3.db, 't', 'status'))['notnull'], 1, reason: 'enforced after the rows were filled');
      expect((await v3.db.query('t')).single['status'], 'active');
    });

    test('NOT NULL without default on an empty table is applied right away', () async {
      await db.open([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('status', isNotNull: true)]));
      await db.restart([v2]);
      expect((await columnInfo(v2.db, 't', 'status'))['notnull'], 1);
    });

    test('a changed constraint rebuilds the table and keeps rows', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('email')]));
      await db.open([v1]);
      await v1.db.insert('t', {'email': 'a@b.c'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('email', isUnique: true, collation: FluentCollation.noCase)]));
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['email'], 'a@b.c');
      await expectLater(v2.db.insert('t', {'email': 'A@B.C'}), throwsA(isA<DatabaseException>()), reason: 'UNIQUE + NOCASE now apply');
    });

    test('rows a new CHECK / UNIQUE rejects are moved to a quarantine table, never deleted', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('start'), FluentDbColumn.integer('end'), FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.insert('t', {'id': 1, 'start': 1, 'end': 5, 'code': 'a'});
      await v1.db.insert('t', {'id': 2, 'start': 9, 'end': 3, 'code': 'b'});
      await v1.db.insert('t', {'id': 3, 'start': 2, 'end': 4, 'code': 'a'});

      final v2 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: () => [FluentDbColumn.primary(), FluentDbColumn.integer('start'), FluentDbColumn.integer('end'), FluentDbColumn.text('code', isUnique: true)],
          checks: const [FluentCheck('"end" >= "start"')],
        ),
      );
      await db.restart([v2]);
      expect([for (final r in await v2.db.query('t', orderBy: 'id')) r['id']], [1], reason: 'id 2 breaks the CHECK, id 3 the UNIQUE');
      final List<Map<String, Object?>> tables = await v2.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '__fluent_rejected_t_r%'");
      expect(tables, hasLength(1));
      final String quarantine = tables.single['name']! as String;
      expect([for (final r in await v2.db.rawQuery('SELECT id FROM "$quarantine" ORDER BY id')) r['id']], [2, 3]);
    });

    test('when the new schema rejects every row, the change fails and the table is unchanged', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'id': 1, 'n': -1});

      final v2 = DynamicProvider.spec('t', TableSpec(columns: () => [FluentDbColumn.primary(), FluentDbColumn.integer('n')], checks: const [FluentCheck('"n" > 0')]));
      await expectLater(db.restart([v2]), throwsA(isA<FluentException>()));
      final v1Again = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n')]));
      await db.restart([v1Again]);
      expect((await v1Again.db.query('t')).single['n'], -1);
    });

    test('a primary key change is applied', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.insert('t', {'id': 1, 'code': 'a'});

      final v2 = DynamicProvider.spec('t', TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('code')], keys: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('code')]));
      await db.restart([v2]);
      expect((await columnInfo(v2.db, 't', 'code'))['pk'], 2);
      expect((await v2.db.query('t')).single['code'], 'a');
    });
  });

  group('Indexes', () {
    test('changed indexes are recreated, removed ones dropped, foreign ones untouched', () async {
      final v1 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]), indexes: const [FluentIndex(['a'], name: 'idx_t_custom')]));
      await db.open([v1]);
      await v1.db.execute('CREATE INDEX "my_own" ON "t" ("b")');

      final v2 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]), indexes: const [FluentIndex(['a', 'b'], name: 'idx_t_custom')]));
      await db.restart([v2]);
      final sql = (await v2.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'idx_t_custom'")).single['sql']! as String;
      expect(sql, contains('"a", "b"'));

      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
      await db.restart([v3]);
      expect(await indexes(v3.db, 't'), {'my_own', 'idx_t_expiry_date'});
    });

    test("the app's own indexes survive a rebuild", () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
      await db.open([v1]);
      await v1.db.execute('CREATE INDEX "my_own" ON "t" ("b")');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a', isNotNull: true, defaultValue: ''), FluentDbColumn.text('b')]));
      await db.restart([v2]);
      expect(await indexes(v2.db, 't'), contains('my_own'));

      // An index on a column removed by a rebuild cannot come back: reported, the rest goes on.
      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a', isNotNull: true, defaultValue: 'z')]));
      await db.restart([v3]);
      expect(await indexes(v3.db, 't'), isNot(contains('my_own')));
      expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.viewOrTrigger));
    });
  });

  group('Rebuild safety', () {
    test('user triggers survive a rebuild', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('updates', defaultValue: 0)]));
      await db.open([v1]);
      await v1.db.execute('CREATE TRIGGER "count_updates" AFTER UPDATE OF "name" ON "t" BEGIN UPDATE "t" SET "updates" = "updates" + 1 WHERE "id" = NEW."id"; END');
      await v1.db.insert('t', {'name': 'a'});

      // Type change → rebuild.
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: ''), FluentDbColumn.integer('updates', defaultValue: 0)]));
      await db.restart([v2]);
      await v2.db.update('t', {'name': 'b'});
      expect((await v2.db.query('t')).single['updates'], 1);
    });

    test('a trigger of another table that uses the rebuilt table keeps working', () async {
      final log = DynamicProvider('log', cols(() => [FluentDbColumn.text('what')]));
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1, log]);
      await v1.db.execute('CREATE TRIGGER "log_to_t" AFTER INSERT ON "log" BEGIN INSERT INTO "t" ("name") VALUES (NEW."what"); END');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: '')]));
      await db.restart([v2, DynamicProvider('log', cols(() => [FluentDbColumn.text('what')]))]);
      await v2.db.insert('log', {'what': 'x'});
      expect((await v2.db.query('t')).single['name'], 'x');
    });
  });

  group('Warnings about the data', () {
    test('a type change on a table with rows says how to convert the values', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('age')]));
      await db.open([v1]);
      await v1.db.insert('t', {'age': '12'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('age')]));
      await db.restart([v2]);
      final FluentIssue issue = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.columnTypeChanged);
      expect(issue.code, contains('CAST(age AS INTEGER)'));
      expect((await v2.db.query('t')).single['age'], 12, reason: 'SQLite converts the values that fit');
    });

    test('a removed and an added column of the same type look like a rename', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'nick': 'annie'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('display')]));
      await db.restart([v2]);
      final FluentIssue issue = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.possibleRename);
      expect(issue.code, contains("restoreColumns: {'nick': 'display'}"));
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.possibleRename && i.subject == 'name'), isEmpty);
    });

    test('a column back in the model hints at its archived values; restoreColumns brings them back', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('phone')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'phone': '123'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]); // rolled back

      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('phone')]));
      await db.restart([v3]);
      expect((await v3.db.query('t')).single['phone'], isNull, reason: 'never restored by itself');
      final FluentIssue hint = db.issues.singleWhere((i) => i.kind == FluentIssueKind.columnRestorable);
      expect(hint.code, contains("restoreColumns: {'phone': 'phone'}"));

      final v4 = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('phone')]), migrations: const [FluentDbMigration(id: 'restore_phone', restoreColumns: {'phone': 'phone'})]),
      );
      await db.restart([v4]);
      expect((await v4.db.query('t')).single['phone'], '123');
    });
  });

  group('One-time steps', () {
    List<FluentDbColumn> base() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')];

    test('dropColumns removes archived copies; restoreColumns brings data back', () async {
      final v1 = DynamicProvider('t', cols(base));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'nick': 'annie'});

      // Release 2: "nick" removed → archived.
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);

      // Release 3: new column "display" + restore archived "nick" into it.
      final v3 = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('display')]), migrations: const [FluentDbMigration(id: 'restore_nick', restoreColumns: {'nick': 'display'})]),
      );
      await db.restart([v3]);
      final row = (await v3.db.query('t')).single;
      expect(row['display'], 'annie');
      expect(row.keys.where((k) => k.startsWith('__fluent_removed_')), isEmpty);
    });

    test('dropColumns deletes the archive for good', () async {
      final v1 = DynamicProvider('t', cols(base));
      await db.open([v1]);
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);

      final v3 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('name')]), migrations: const [FluentDbMigration(version: 1, dropColumns: ['nick'])]));
      await db.restart([v3]);
      expect((await columns(v3.db, 't')).where((c) => c.startsWith('__fluent_removed_')), isEmpty);
    });

    test('restoring into a column of another type fails and rolls back', () async {
      final v1 = DynamicProvider('t', cols(base));
      await db.open([v1]);
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);

      final bad = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('display')]), migrations: const [FluentDbMigration(id: 'r', restoreColumns: {'nick': 'display'})]),
      );
      await expectLater(db.restart([bad]), throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationFailed)));

      final report = await _reportAfterReopen(db, DynamicProvider('t', cols(() => [FluentDbColumn.text('name')])));
      expect(report.history.first.success, isFalse, reason: 'the failed attempt is recorded after the rollback');
    });

    test('a seeding step on a new table is only marked as applied, with a hint', () async {
      final p = DynamicProvider.spec('t', TableSpec(columns: cols(base), migrations: const [FluentDbMigration(id: 'seed', rawSql: ["INSERT INTO t (name) VALUES ('admin')"])]));
      await db.open([p]);
      expect(await p.db.query('t'), isEmpty);
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.stepOnNewTable));
    });

    test('provider calls inside onMigrate join the schema transaction', () async {
      final v1 = DynamicProvider('t', cols(base));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'nick': 'annie'});

      late DynamicProvider v2;
      v2 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(base),
          migrations: [
            FluentDbMigration(
              id: 'upper',
              onMigrate: (_) async {
                final rows = await v2.findAll();
                await v2.saveAll([for (final r in rows) v2.row({...r.values, 'nick': (r['nick'] as String).toUpperCase()})]);
              },
            ),
          ],
        ),
      );
      await db.restart([v2]).timeout(const Duration(seconds: 10));
      expect((await v2.db.query('t')).single['nick'], 'ANNIE');
    });

    test('an applied step that was edited afterwards does not run again', () async {
      final log = <String>[];
      final v1 = DynamicProvider('t', cols(base));
      await db.open([v1]);

      await db.restart([DynamicProvider.spec('t', TableSpec(columns: cols(base), migrations: [FluentDbMigration(id: 's1', rawSql: const ['SELECT 1'], onMigrate: (_) async => log.add('first'))]))]);
      await db.restart([DynamicProvider.spec('t', TableSpec(columns: cols(base), migrations: [FluentDbMigration(id: 's1', rawSql: const ['SELECT 2'], onMigrate: (_) async => log.add('edited'))]))]);
      expect(log, ['first']);
    });
  });

  group('Archive retention, report, reset', () {
    test('archives older than the retention are purged at start, or right away on demand', () async {
      final v1 = DynamicProvider('t', cols(base0));
      await db.open([v1]);
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([p], archiveRetention: null);
      expect((await columns(p.db, 't')).where((c) => c.startsWith('__fluent_removed_')), hasLength(1), reason: 'null keeps archives');

      await FluentDb.purgeArchivedColumns(olderThan: Duration.zero);
      expect((await columns(p.db, 't')).where((c) => c.startsWith('__fluent_removed_')), isEmpty);
    });

    test('schemaReport lists tables and history', () async {
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([p]);
      final report = (await FluentDb.schemaReport()).single;
      expect(report.tables.map((t) => t.table), ['t']);
      expect(report.history.single.changes.first, contains('created table'));
      expect(report.toString(), contains('revision 1'));
    });

    test('history keeps at most historyLimit entries per table', () async {
      await db.open([DynamicProvider('t', cols(() => [FluentDbColumn.text('a')]))], historyLimit: 2);
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]))], historyLimit: 2);
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b'), FluentDbColumn.text('c')]));
      await db.restart([p], historyLimit: 2);
      expect(await historyCount(p.db, 't'), 2);
    });

    test('resetOnSchemaError recreates the file only when asked to', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'x'});

      final failing = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('name')]), migrations: const [FluentDbMigration(id: 'bad', rawSql: ['UPDATE missing SET a = 1'])]));
      await expectLater(db.restart([failing]), throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationFailed)));

      final recovered = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('name')]), migrations: const [FluentDbMigration(id: 'bad', rawSql: ['UPDATE missing SET a = 1'])]));
      await db.restart([recovered], resetOnSchemaError: true);
      expect(await recovered.db.query('t'), isEmpty, reason: 'the file was recreated; on a fresh table the step is only recorded');
    });
  });
}

List<FluentDbColumn> base0() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')];

Future<FluentSchemaReport> _reportAfterReopen(FluentTestDb db, DynamicProvider provider) async {
  await db.restart([provider]);
  return (await FluentDb.schemaReport()).single;
}
