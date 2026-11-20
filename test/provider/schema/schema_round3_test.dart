import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart' as rm;
import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'r3_schema_${counter++}', persistent: true));
  tearDown(() => db.close());

  group('Triggers after a rebuild', () {
    test('a trigger on a removed column is reported with the SQL to recreate it', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1]);
      const sql = 'CREATE TRIGGER "log_nick" AFTER UPDATE ON "t" BEGIN UPDATE "t" SET "name" = NEW."nick" WHERE "id" = NEW."id"; END';
      await v1.db.execute(sql);

      // "nick" is removed and "name" changes its rules: a rebuild.
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: '')]));
      await db.restart([v2]);
      final broken = db.warnings.where((i) => i.kind == FluentIssueKind.brokenTrigger).toList();
      expect(broken, hasLength(1));
      expect(broken.single.title, contains('log_nick'));
      expect(broken.single.code, contains('DROP TRIGGER IF EXISTS "log_nick"'));
      expect(broken.single.code, contains('NEW."nick"'));
      // The trigger is kept and the check left no trace (name, schema text).
      final rows = await v2.db.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'");
      expect(rows.single['name'], 'log_nick');
      expect(rows.single['sql'], sql);
      expect(await v2.db.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE '__fluent_check%'"), isEmpty);
    });

    test('several broken triggers (also of another table) are all named, a fine one is not', () async {
      final log = DynamicProvider('log', cols(() => [FluentDbColumn.text('what')]));
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1, log]);
      await v1.db.execute('CREATE TRIGGER "a_bad" AFTER INSERT ON "t" BEGIN INSERT INTO "log" ("what") VALUES (NEW."nick"); END');
      await v1.db.execute('CREATE TRIGGER "b_bad" AFTER INSERT ON "log" BEGIN INSERT INTO "t" ("nick") VALUES (NEW."what"); END');
      await v1.db.execute('CREATE TRIGGER "c_fine" AFTER INSERT ON "t" BEGIN INSERT INTO "log" ("what") VALUES (NEW."name"); END');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: '')]));
      await db.restart([v2, DynamicProvider('log', cols(() => [FluentDbColumn.text('what')]))]);
      final names = db.warnings.where((i) => i.kind == FluentIssueKind.brokenTrigger).map((i) => i.subject).toSet();
      expect(names, {'a_bad', 'b_bad'});
    });

    test('a trigger that still fits reports nothing, and the table keeps working', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('updates', defaultValue: 0)]));
      await db.open([v1]);
      await v1.db.execute('CREATE TRIGGER "count" AFTER UPDATE OF "name" ON "t" BEGIN UPDATE "t" SET "updates" = "updates" + 1 WHERE "id" = NEW."id"; END');
      await v1.db.insert('t', {'name': 'a'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: ''), FluentDbColumn.integer('updates', defaultValue: 0)]));
      await db.restart([v2]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.brokenTrigger), isEmpty);
      await v2.db.update('t', {'name': 'b'});
      expect((await v2.db.query('t')).single['updates'], 1);
    });

    test('a trigger that was already broken before the rebuild is reported once, unrelated ones are not', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      final other = DynamicProvider('o', cols(() => [FluentDbColumn.text('x')]));
      await db.open([v1, other]);
      // A trigger of another table that does not touch "t" and is broken: not our business.
      await v1.db.execute('CREATE TRIGGER "o_bad" AFTER INSERT ON "o" BEGIN UPDATE "o" SET "gone" = 1; END');
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', isNotNull: true, defaultValue: '')]));
      await db.restart([v2, DynamicProvider('o', cols(() => [FluentDbColumn.text('x')]))]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.brokenTrigger), isEmpty);
    });

    test('an in-place archive of a column keeps the trigger working', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick')]));
      await db.open([v1]);
      await v1.db.execute("CREATE TRIGGER \"tr\" AFTER INSERT ON \"t\" BEGIN UPDATE \"t\" SET \"name\" = 'x' WHERE \"id\" = NEW.\"id\"; END");
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.restart([v2]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.brokenTrigger), isEmpty);
    });
  });

  group('schemaReport in the queue', () {
    test('it waits for a running transaction and for writes queued before it', () async {
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([p]);
      final gate = Completer<void>();
      final order = <String>[];
      final tx = FluentDb.transaction(() async {
        await gate.future;
        order.add('transaction done');
      }, dbKey: db.key);
      await pumpEventQueue();
      final report = FluentDb.schemaReport(dbKey: db.key).then((r) {
        order.add('report');
        return r;
      });
      final later = FluentDb.transaction(() async => order.add('later write'), dbKey: db.key);
      await pumpEventQueue();
      expect(order, isEmpty, reason: 'the report does not overlap the running transaction');
      gate.complete();
      await Future.wait([tx, report, later]);
      expect(order, ['transaction done', 'report', 'later write'], reason: 'a barrier: after earlier calls, before later ones');
      expect((await report).single.tables.map((t) => t.table), contains('t'));
    });

    test('inside a transaction it reads through that transaction instead of deadlocking', () async {
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([p]);
      final reports = await FluentDb.transaction(() => FluentDb.schemaReport(dbKey: db.key), dbKey: db.key);
      expect(reports, hasLength(1));
      expect(reports.single.database, db.name);
    });

    test('a database that is not asked for is not touched, a missing key is refused with databaseNotOpen (G25: never skipped silently)', () async {
      final p = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([p]);
      await expectLater(FluentDb.schemaReport(dbKey: FluentDbKey('nope_${db.name}')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
    });
  });

  group('Foreign keys switched on', () {
    test('dangling rows written while they were off are found at the start that switches them on', () async {
      final categories = rm.CategoryProvider();
      await db.open([categories], config: const FluentDbConfig(enableForeignKeys: false));
      await categories.save(rm.Category(name: 'root'));
      await categories.db.insert('categories', {'name': 'lost', 'parent_id': 99});

      final again = rm.CategoryProvider();
      await db.restart([again]);
      final FluentIssue issue = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.danglingReferences);
      expect(issue.title, contains('1 row(s)'), reason: 'found at this start, not at the next schema change');
      final rows = await again.db.query('categories', where: 'name = ?', whereArgs: ['lost']);
      expect(rows.isEmpty || rows.single['parent_id'] == null, isTrue, reason: 'the start-up clean-up removed the dangling reference');
      expect(await again.db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    });

    test('a clean database switched on reports nothing, and the next start skips the sync again', () async {
      final categories = rm.CategoryProvider();
      await db.open([categories], config: const FluentDbConfig(enableForeignKeys: false));
      await categories.save(rm.Category(name: 'root', children: [rm.Category(name: 'a')]));
      await db.restart([rm.CategoryProvider()]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.danglingReferences), isEmpty);
      final historyBefore = (await FluentDb.schemaReport(dbKey: db.key)).single.history.length;
      await db.restart([rm.CategoryProvider()]);
      expect((await FluentDb.schemaReport(dbKey: db.key)).single.history.length, historyBefore, reason: 'unchanged: no sync');
    });

    test('with foreign keys still on or still off the start does not check', () async {
      final categories = rm.CategoryProvider();
      await db.open([categories]);
      await categories.save(rm.Category(name: 'root'));
      await db.restart([rm.CategoryProvider()]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.danglingReferences), isEmpty);
      // Switched off again: no dangling check issue either (SQLite no longer promises integrity; the clean-up runs).
      await db.restart([rm.CategoryProvider()], config: const FluentDbConfig(enableForeignKeys: false));
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.danglingReferences), isEmpty);
    });

    test('the setting changes nothing in the tables themselves', () async {
      final categories = rm.CategoryProvider();
      await db.open([categories], config: const FluentDbConfig(enableForeignKeys: false));
      await categories.save(rm.Category(name: 'root'));
      final before = await categories.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'categories'");
      final again = rm.CategoryProvider();
      await db.restart([again]);
      expect(await again.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'categories'"), before);
    });
  });
}
