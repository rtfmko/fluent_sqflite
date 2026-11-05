// Regression tests of the schema sync: NOT NULL defaults on rebuilds, adopted (pre-snapshot) tables, purges through
// the queue, full-text after purges, concurrent init, app indexes, AUTOINCREMENT, read-only full-text, retries,
// lost views and quarantine with a changed key.
// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/src/mixin/import_mixin.dart' show SqfliteInvokeHandler, buildDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

Future<Map<String, Object?>> columnInfo(Database db, String table, String column) async =>
    (await db.rawQuery("PRAGMA table_info('$table')")).firstWhere((r) => r['name'] == column);

Future<List<String>> history(Database db, String table) async => [
  for (final r in await db.query('__fluent_schema_history', columns: ['changes'], where: 'table_name = ?', whereArgs: [table], orderBy: 'id')) r['changes']! as String,
];

Future<String> tableSql(Database db, String table) async =>
    (await db.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])).single['sql']! as String;

Future<Set<String>> indexNames(Database db, String table) async =>
    {for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [table])) r['name']! as String};

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

/// Simulates a database written before schema snapshots existed: the snapshot of [table] is forgotten.
Future<void> forgetSnapshot(FluentTestDb db, String table) async {
  await db.close(keepFile: true);
  final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
  await raw.delete('__fluent_schema', where: 'table_name = ?', whereArgs: [table]);
  await raw.close();
}

/// Creates the database file of [db] with [statements] only (an "old app version" wrote it).
Future<void> legacyFile(FluentTestDb db, List<String> statements) async {
  final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
  for (final String s in statements) {
    await raw.execute(s);
  }
  await raw.close();
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'fix_${counter++}', persistent: true));
  tearDown(() => db.close());

  group('SCH1 NOT NULL with a default on a rebuild', () {
    test('a nullable column that becomes NOT NULL with a default is filled with the default', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x')]));
      await db.open([v1]);
      await v1.db.insert('t', {'x': null});
      await v1.db.insert('t', {'x': 'kept'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x', isNotNull: true, defaultValue: 'a')]));
      await db.restart([v2]);
      expect([for (final r in await v2.db.query('t', orderBy: 'id')) r['x']], ['a', 'kept']);
      expect((await columnInfo(v2.db, 't', 'x'))['notnull'], 1);
    });

    test('a pending NOT NULL column that gets a default is filled and enforced', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('x', isNotNull: true)]));
      await db.restart([v2]);
      expect((await columnInfo(v2.db, 't', 'x'))['notnull'], 0, reason: 'pending: the existing row has no value');

      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('x', isNotNull: true, defaultValue: 'a')]));
      await db.restart([v3]);
      expect((await v3.db.query('t')).single['x'], 'a');
      expect((await columnInfo(v3.db, 't', 'x'))['notnull'], 1);
      final FluentTableSnapshot snapshot = (await readFluentSchemaSnapshots(v3.db)).firstWhere((s) => s.table == 't');
      expect(snapshot.pendingNotNull, isEmpty);
      expect((await history(v3.db, 't')).last, contains('enforced NOT NULL on \\"x\\"'));

      // Nothing left to do on the next start.
      final v4 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('x', isNotNull: true, defaultValue: 'a')]));
      final int before = (await history(v3.db, 't')).length;
      await db.restart([v4]);
      expect((await history(v4.db, 't')).length, before);
    });

    test('a pending NOT NULL column without a default stays pending while NULLs exist', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('x', isNotNull: true)]));
      await db.restart([v2]);
      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('x', isNotNull: true)]));
      await db.restart([v3]);
      expect((await columnInfo(v3.db, 't', 'x'))['notnull'], 0);
      expect((await v3.db.query('t')).single['name'], 'Ann');
    });

    test('an expression default fills NULLs too', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'n': null});
      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'n', type: FluentDbDataType.integer, isNotNull: true, defaultValue: const FluentSqlExpression('6 * 7'))]));
      await db.restart([v2]);
      expect((await v2.db.query('t')).single['n'], 42);
    });
  });

  group('SCH2 / SCH3 tables adopted without a snapshot', () {
    test('constraints of the model are applied once to an adopted table', () async {
      await legacyFile(db, ['CREATE TABLE "legacy" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "code" TEXT, "_fs_metadata" TEXT, "expiry_date" INTEGER)']);
      final p = DynamicProvider('legacy', cols(() => [FluentDbColumn.text('code', isUnique: true)]));
      await db.open([p]);
      await p.db.insert('legacy', {'code': 'a'});
      await expectLater(p.db.insert('legacy', {'code': 'a'}), throwsA(isA<DatabaseException>()), reason: 'UNIQUE is applied');
      expect(await tableSql(p.db, 'legacy'), contains('UNIQUE'));

      // The next start sees nothing to do.
      final int changes = (await history(p.db, 'legacy')).length;
      final again = DynamicProvider('legacy', cols(() => [FluentDbColumn.text('code', isUnique: true)]));
      await db.restart([again]);
      expect((await history(again.db, 'legacy')).length, changes);
    });

    test('an adopted table that already matches the model is not rebuilt', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code', isUnique: true, isNotNull: true, defaultValue: 'x'), FluentDbColumn.integer('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'code': 'a', 'n': 1});
      final String sqlBefore = await tableSql(v1.db, 't');
      await forgetSnapshot(db, 't');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code', isUnique: true, isNotNull: true, defaultValue: 'x'), FluentDbColumn.integer('n')]));
      await db.open([v2]);
      expect(await tableSql(v2.db, 't'), sqlBefore);
      expect((await history(v2.db, 't')).join(), isNot(contains('rebuilt')));
      expect((await v2.db.query('t')).single['code'], 'a');
    });

    test('defaults with commas and table CHECKs are read correctly when adopting', () async {
      TableSpec spec() => TableSpec(
        columns: cols(() => [FluentDbColumn.text('tags', isNotNull: true, defaultValue: 'a, (b)'), FluentDbColumn.integer('n')]),
        checks: const [FluentCheck('n IS NULL OR (n > 0 AND n < 10)')],
      );
      final v1 = DynamicProvider.spec('t', spec());
      await db.open([v1]);
      await v1.db.insert('t', {'n': 3});
      await forgetSnapshot(db, 't');

      final v2 = DynamicProvider.spec('t', spec());
      await db.open([v2]);
      expect((await history(v2.db, 't')).join(), isNot(contains('rebuilt')));
      expect((await v2.db.query('t')).single['tags'], 'a, (b)');
      final FluentTableSnapshot snapshot = (await readFluentSchemaSnapshots(v2.db)).firstWhere((s) => s.table == 't');
      expect(snapshot.checks, hasLength(1));
    });

    test('NOT NULL and REFERENCES on an adopted table are applied, data kept', () async {
      await legacyFile(db, [
        'CREATE TABLE "parent" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'CREATE TABLE "child" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "pid" INTEGER, "name" TEXT, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'INSERT INTO "parent" ("id") VALUES (1)',
        'INSERT INTO "child" ("pid", "name") VALUES (1, \'a\')',
      ]);
      final parent = DynamicProvider('parent', cols(() => []));
      final child = DynamicProvider('child', cols(() => [FluentDbColumn(name: 'pid', type: FluentDbDataType.integer, customSql: 'REFERENCES "parent" ("id") ON DELETE CASCADE'), FluentDbColumn.text('name', isNotNull: true)]));
      await db.open([parent, child]);
      expect(await tableSql(child.db, 'child'), allOf(contains('REFERENCES'), contains('NOT NULL')));
      expect((await child.db.query('child')).single['name'], 'a');
      await child.db.delete('parent');
      expect(await child.db.query('child'), isEmpty, reason: 'ON DELETE CASCADE now works');
    });

    test('a removed NOT NULL column of an adopted table is archived without its rule', () async {
      await legacyFile(db, [
        'CREATE TABLE "legacy" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "note" TEXT NOT NULL, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'INSERT INTO "legacy" ("name", "note") VALUES (\'Ann\', \'secret\')',
      ]);
      final p = DynamicProvider('legacy', cols(() => [FluentDbColumn.text('name')]));
      await db.open([p]);
      final Map<String, Object?> archive = (await p.db.rawQuery("PRAGMA table_info('legacy')")).firstWhere((r) => (r['name']! as String).startsWith('__fluent_removed_note'));
      expect(archive['notnull'], 0);
      expect((await p.db.query('legacy')).single[archive['name']! as String], 'secret');
      await p.save(p.row({'name': 'Bob'})); // would fail on the NOT NULL archive
      expect(await p.count(), 2);
    });

    test('a removed REFERENCES column of an adopted table is archived without its rule', () async {
      await legacyFile(db, [
        'CREATE TABLE "parent" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'CREATE TABLE "child" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "pid" INTEGER REFERENCES "parent" ("id") ON DELETE CASCADE, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'INSERT INTO "parent" ("id") VALUES (1)',
        'INSERT INTO "child" ("name", "pid") VALUES (\'a\', 1)',
      ]);
      final parent = DynamicProvider('parent', cols(() => []));
      final child = DynamicProvider('child', cols(() => [FluentDbColumn.text('name')]));
      await db.open([parent, child]);
      expect(await tableSql(child.db, 'child'), isNot(contains('REFERENCES')));
      await child.db.delete('parent');
      expect(await child.db.query('child'), hasLength(1), reason: 'the archive must not cascade-delete rows');
    });
  });

  group('SCH4 purgeArchivedColumns runs through the queue', () {
    List<FluentDbColumn> parentV1() => [FluentDbColumn.primary(), FluentDbColumn.text('old')];
    List<FluentDbColumn> parentV2() => [FluentDbColumn.primary()];
    List<FluentDbColumn> childCols() => [FluentDbColumn.primary(), FluentDbColumn(name: 'pid', type: FluentDbDataType.integer, customSql: 'REFERENCES "p" ("id")')];

    Future<(DynamicProvider, DynamicProvider)> archived() async {
      await db.open([DynamicProvider('p', parentV1), DynamicProvider('c', childCols)]);
      final p = DynamicProvider('p', parentV2);
      final c = DynamicProvider('c', childCols);
      await db.restart([p, c]);
      expect((await p.db.rawQuery("PRAGMA table_info('p')")).map((r) => r['name']), contains(startsWith('__fluent_removed_old')));
      return (p, c);
    }

    test('the purge is a queued write: it waits for a paused queue', () async {
      final (p, _) = await archived();
      await FluentDb.pauseQueue(dbKey: db.key);
      final Future<void> purge = FluentDb.purgeArchivedColumns(olderThan: Duration.zero, dbKey: db.key);
      expect(FluentDb.engineStats().queued, 1, reason: 'queued, not run beside the queue');
      FluentDb.resumeQueue(dbKey: db.key);
      await purge;
      expect((await p.db.rawQuery("PRAGMA table_info('p')")).map((r) => r['name']), isNot(contains(startsWith('__fluent_removed_old'))));
    });

    test('writes around the purge keep foreign keys on', () async {
      final (p, c) = await archived();
      final Future<void> purge = FluentDb.purgeArchivedColumns(olderThan: Duration.zero, dbKey: db.key);
      final Future<Object?> orphan = c.save(c.row({'pid': 999})).then<Object?>((_) => null, onError: (Object e) => e);
      await purge;
      expect(await orphan, isA<FluentException>(), reason: 'the FOREIGN KEY rule held');
      expect(await c.db.query('c'), isEmpty);
      expect((await p.db.rawQuery('PRAGMA foreign_keys')).first.values.first, 1);
    });

    test('schemaReport does not write', () async {
      final p = DynamicProvider('p', parentV2);
      await db.open([p]);
      await p.db.execute('DROP TABLE "__fluent_schema_history"');
      final List<FluentSchemaReport> reports = await FluentDb.schemaReport(dbKey: db.key);
      expect(reports.single.tables.map((t) => t.table), contains('p'));
      expect(reports.single.history, isEmpty);
      expect(await p.db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_schema_history'"), isEmpty, reason: 'nothing created from outside the queue');
    });
  });

  group('SCH5 full-text after a purge', () {
    TableSpec spec(List<FluentDbColumn> Function() columns) => TableSpec(
      columns: columns,
      key: () => FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true),
      indexes: const [FluentIndex.fullText(['title'])],
    );
    List<FluentDbColumn> v1() => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('title'), FluentDbColumn.text('old')];
    List<FluentDbColumn> v2() => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('title')];

    Future<List<String>> found(DynamicProvider p, String word) async => [for (final m in await p.search(word)) m['code'] as String];

    test('a purge that rebuilds the table keeps search results right', () async {
      final a = DynamicProvider.spec('docs', spec(v1));
      await db.open([a]);
      await a.saveAll([a.row({'code': 'a', 'title': 'apple', 'old': 'x'}), a.row({'code': 'b', 'title': 'banana', 'old': 'y'}), a.row({'code': 'c', 'title': 'cherry', 'old': 'z'})]);
      await a.db.delete('docs', where: 'code = ?', whereArgs: ['a']); // a rowid gap

      final b = DynamicProvider.spec('docs', spec(v2));
      await db.restart([b]);
      final String archive = (await b.db.rawQuery("PRAGMA table_info('docs')")).map((r) => r['name']! as String).firstWhere((n) => n.startsWith('__fluent_removed_old'));
      // A view on the archive makes DROP COLUMN impossible: the purge rebuilds the table.
      await b.db.execute('CREATE VIEW "docs_old" AS SELECT "$archive" FROM "docs"');

      await FluentDb.purgeArchivedColumns(olderThan: Duration.zero, dbKey: db.key);
      expect(await found(b, 'banana'), ['b']);
      expect(await found(b, 'cherry'), ['c']);

      // And after the next (fast) start.
      final c = DynamicProvider.spec('docs', spec(v2));
      await db.restart([c]);
      expect(await found(c, 'cherry'), ['c']);
    });

    test('a full-text index older than the table revision is rebuilt on the fast start path', () async {
      final a = DynamicProvider.spec('docs', spec(v2));
      await db.open([a]);
      await a.saveAll([a.row({'code': 'a', 'title': 'apple'}), a.row({'code': 'b', 'title': 'banana'})]);
      // Index content and its revision no longer fit the table (as after a rebuild by an older version).
      await a.db.execute('INSERT INTO "__fluent_fts_docs"("__fluent_fts_docs") VALUES (\'delete-all\')');
      await a.db.execute('UPDATE "__fluent_fts" SET revision = revision + 7');

      final b = DynamicProvider.spec('docs', spec(v2));
      await db.restart([b]);
      expect(await found(b, 'banana'), ['b']);
    });

    test('a rebuild keeps the rowids of a rowid table without an INTEGER key', () async {
      final a = DynamicProvider.spec('docs', spec(v2));
      await db.open([a]);
      await a.saveAll([a.row({'code': 'a', 'title': 'apple'}), a.row({'code': 'b', 'title': 'banana'})]);
      await a.db.delete('docs', where: 'code = ?', whereArgs: ['a']);
      final int rowid = (await a.db.rawQuery('SELECT rowid AS r FROM docs')).single['r']! as int;

      // A type change rebuilds the table.
      final b = DynamicProvider.spec('docs', spec(() => [...v2(), FluentDbColumn.integer('n', isUnique: true)]));
      await db.restart([b]);
      expect((await b.db.rawQuery('SELECT rowid AS r FROM docs')).single['r'], rowid);
      expect(await found(b, 'banana'), ['b']);
    });
  });

  group('SCH6 concurrent init / close', () {
    tearDown(() async {
      await FluentDb.close();
      FluentDbInternals.reset();
    });

    FluentGroup group(String name) => FluentGroup(dbKey: FluentDbKey(name), providerList: [DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))], inMemory: true);

    test('two concurrent init calls register every provider once', () async {
      FluentDbInternals.reset();
      final FluentGroup g = group('concurrent_a');
      await Future.wait([FluentDb.init([g]), FluentDb.init([g])]);
      expect(FluentDb.provider<DynamicProvider>(), isA<DynamicProvider>());
      expect(FluentDb.isOpen(), isTrue);
    });

    test('a close made during init runs after it', () async {
      FluentDbInternals.reset();
      final Future<void> init = FluentDb.init([group('concurrent_b')]);
      final Future<void> close = FluentDb.close();
      await init;
      await close;
      expect(FluentDb.isOpen(), isFalse);
    });
  });

  group('SCH7 app indexes named like the library', () {
    test('an index the app created with an idx_ name survives a rebuild', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('code')]));
      await db.open([v1]);
      await v1.db.execute('CREATE INDEX "idx_t_mine" ON "t" ("name")');
      await v1.db.execute('CREATE UNIQUE INDEX "uidx_t_mine" ON "t" ("code")');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.integer('code')]));
      await db.restart([v2]);
      expect(await history(v2.db, 't'), contains(contains('rebuilt')));
      expect(await indexNames(v2.db, 't'), containsAll(['idx_t_mine', 'uidx_t_mine']));
    });

    test('an adopted table does not claim app indexes', () async {
      await legacyFile(db, [
        'CREATE TABLE "legacy" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "_fs_metadata" TEXT, "expiry_date" INTEGER)',
        'CREATE INDEX "idx_legacy_name_custom" ON "legacy" ("name")',
      ]);
      final v1 = DynamicProvider('legacy', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      final v2 = DynamicProvider('legacy', cols(() => [FluentDbColumn.integer('name')])); // rebuild
      await db.restart([v2]);
      expect(await indexNames(v2.db, 'legacy'), contains('idx_legacy_name_custom'));
    });
  });

  group('SCH8 AUTOINCREMENT across a rebuild', () {
    test('ids of deleted rows are not used again', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      for (final String n in ['a', 'b', 'c']) {
        await v1.db.insert('t', {'name': n});
      }
      await v1.db.delete('t', where: 'id = 3');

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('name')]));
      await db.restart([v2]);
      expect(await v2.db.insert('t', {'name': 1}), 4);
    });
  });

  group('SCH9 read-only full-text', () {
    test('a read-only database uses its full-text index', () async {
      final spec = TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['title'])]);
      final writer = DynamicProvider.spec('docs', spec);
      await db.open([writer]);
      await writer.saveAll([writer.row({'title': 'apple pie'}), writer.row({'title': 'banana'})]);
      await db.close(keepFile: true);

      final QueryCounter counter = await QueryCounter.install();
      try {
        FluentDbInternals.reset();
        final reader = DynamicProvider.spec('docs', spec);
        await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [reader], readOnly: true)]);
        counter.reset();
        expect([for (final m in await reader.search('apple')) m['title']], ['apple pie']);
        expect(counter.statements.any((s) => s.contains('MATCH')), isTrue, reason: 'the FTS table, not LIKE');
      } finally {
        counter.uninstall();
        await FluentDb.close();
        FluentDbInternals.reset();
      }
    });
  });

  group('SCH10 resetOnSchemaError retry', () {
    test('databases opened before the failure are closed before the retry', () async {
      final FluentTestDb broken = FluentTestDb(name: 'fix_broken', persistent: true);
      final DynamicProvider failing = DynamicProvider.spec(
        'bad',
        TableSpec(columns: cols(() => [FluentDbColumn.text('x')]), migrations: const [FluentDbMigration(version: 1, rawSql: ['THIS IS NOT SQL'])]),
      );
      // The step only runs on an existing table: create it first.
      await broken.open([DynamicProvider('bad', cols(() => [FluentDbColumn.text('x')]))]);
      await broken.close(keepFile: true);

      final OpenTracker tracker = await OpenTracker.install();
      try {
        FluentDbInternals.reset();
        await FluentDb.init([
          FluentGroup(dbKey: FluentDbKey('fix_ok'), providerList: [DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))], inMemory: true),
          FluentGroup(dbKey: broken.key, providerList: [failing], resetOnSchemaError: true),
        ]);
        await FluentDb.close();
        expect(tracker.open, isEmpty, reason: 'every opened database is closed again');
      } finally {
        tracker.uninstall();
        FluentDbInternals.reset();
        await databaseFactory.deleteDatabase('${await getDatabasesPath()}/fix_broken.db');
      }
    });
  });

  group('SCH11 views a rebuild cannot recreate', () {
    test('count as data loss in the migration plan', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note', isNotNull: true)]));
      await db.open([v1]);
      await v1.db.execute('CREATE VIEW "t_notes" AS SELECT note FROM "t"');

      final FluentMigrationPlan plan = await db.plan([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      expect(plan.changes.map((c) => c.kind), contains(FluentSchemaChangeKind.viewOrTriggerLost));
      expect(plan.losesData, isTrue);
      expect(plan.changes.firstWhere((c) => c.kind == FluentSchemaChangeKind.viewOrTriggerLost).subject, 't_notes');
    });

    test('a view that is recreated is no loss', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note', isNotNull: true)]));
      await db.open([v1]);
      await v1.db.execute('CREATE VIEW "t_names" AS SELECT "name" FROM "t"');
      final FluentMigrationPlan plan = await db.plan([DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]))]);
      expect(plan.rebuilds, isTrue);
      expect(plan.losesData, isFalse);
    });
  });

  group('SCH12 quarantine with a changed key', () {
    test('rows duplicating the new key are quarantined, the start succeeds', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code'), FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'code': 'a', 'name': 'first'});
      await v1.db.insert('t', {'code': 'a', 'name': 'second'});
      await v1.db.insert('t', {'code': 'b', 'name': 'third'});

      final v2 = DynamicProvider(
        't',
        () => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('name')],
        key: () => FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true),
      );
      await db.restart([v2]);
      expect([for (final r in await v2.db.query('t', orderBy: 'code')) r['name']], ['first', 'third']);
      final List<Map<String, Object?>> rejected = await v2.db.query('__fluent_rejected_t_r2');
      expect(rejected.single['name'], 'second');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.rowsQuarantined));
    });

    test('a WITHOUT ROWID source with a changed key is quarantined row by row', () async {
      final v1 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: () => [FluentDbColumn(name: 'id', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('code')],
          key: () => FluentDbColumn(name: 'id', type: FluentDbDataType.text, isPrimaryKey: true),
          withoutRowId: true,
        ),
      );
      await db.open([v1]);
      await v1.db.insert('t', {'id': '1', 'code': 'a'});
      await v1.db.insert('t', {'id': '2', 'code': 'a'});

      final v2 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: () => [FluentDbColumn(name: 'id', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('code', isUnique: true)],
          key: () => FluentDbColumn(name: 'id', type: FluentDbDataType.text, isPrimaryKey: true),
          withoutRowId: true,
        ),
      );
      await db.restart([v2]);
      expect(await v2.db.query('t'), hasLength(1));
      expect(await v2.db.query('__fluent_rejected_t_r2'), hasLength(1));
    });

    test('when every row would be rejected the start fails and nothing changes', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'n': 1});
      final v2 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.integer('n')]), checks: const [FluentCheck('n > 5')]));
      await expectLater(db.restart([v2]), throwsA(isA<FluentException>()));
      FluentDbInternals.reset();
    });
  });
}

/// Tracks the databases opened through the global factory and not closed yet.
class OpenTracker {
  OpenTracker._(this._previous);

  final DatabaseFactory _previous;
  final Set<Object?> open = {};

  static Future<OpenTracker> install() async {
    final DatabaseFactory inner = databaseFactory;
    final OpenTracker tracker = OpenTracker._(inner);
    final DatabaseFactory tracking = buildDatabaseFactory(
      tag: 'tracking',
      invokeMethod: (String method, [Object? arguments]) async {
        final Object? result = await (inner as SqfliteInvokeHandler).invokeMethod<Object?>(method, arguments);
        if (method == 'openDatabase') tracker.open.add(result is Map ? result['id'] : result);
        if (method == 'closeDatabase' && arguments is Map) tracker.open.remove(arguments['id']);
        return result;
      },
    );
    await tracking.setDatabasesPath(await inner.getDatabasesPath());
    databaseFactoryOrNull = tracking;
    return tracker;
  }

  void uninstall() => databaseFactoryOrNull = _previous;
}
