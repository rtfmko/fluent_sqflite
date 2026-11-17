// Audit round 2 of the schema sync: a column renamed with oldName next to a new column under the old name (item 14),
// the fast start with an FTS module this SQLite lacks (item 16), and the 1.x adoption only when needed: type values,
// unquoted 1.x indexes (item 17).
// ignore_for_file: implementation_imports, depend_on_referenced_packages
@Timeout(Duration(seconds: 20))
library;

import 'dart:convert';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

Future<List<String>> columnNames(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<Set<String>> indexNames(Database db, String table) async =>
    {for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [table])) r['name']! as String};

Future<List<String>> history(Database db, String table) async => [
  for (final r in await db.query('__fluent_schema_history', columns: ['changes'], where: 'table_name = ?', whereArgs: [table], orderBy: 'id')) r['changes']! as String,
];

/// Whether [start] ran the full schema sync (the fast start skips it and never creates the bookkeeping tables).
Future<bool> tookFullSync(Future<void> Function() start) async {
  final QueryCounter counter = await QueryCounter.install();
  try {
    await start();
    return counter.statements.any((s) => s.contains('CREATE TABLE IF NOT EXISTS "__fluent_schema"'));
  } finally {
    counter.uninstall();
  }
}

/// Creates the database file of [db] with [statements] only (a 1.x app wrote it: no schema snapshots).
Future<void> legacyFile(FluentTestDb db, List<String> statements) async {
  final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
  for (final String s in statements) {
    await raw.execute(s);
  }
  await raw.close();
}

FluentDbColumn renamed(String name, String oldName) => FluentDbColumn(name: name, type: FluentDbDataType.text, oldName: oldName);

// Item 17: default table names (`Doc2` → `doc2`, 1.x `doc_2`) with a polymorphic reference to them.
class Doc2 extends FluentStorable {
  Doc2({this.id, required this.title});

  final int? id;
  final String title;

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.primary(), FluentDbColumn.text('title', indexed: true)];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class Mark2 extends FluentStorable with FluentRelations {
  Mark2({this.id, this.target});

  final int? id;
  final FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [FluentRelation.oneOf<Mark2>('target', (m) => m.target, types: [Doc2])];
}

class Doc2Provider extends FluentProvider<Doc2> {
  @override
  Doc2 get modelSample => Doc2(title: '');

  @override
  Doc2 fromCacheJson(Map<String, dynamic> json) => Doc2(id: json['id'] as int?, title: json['title'] as String);
}

class Mark2Provider extends FluentProvider<Mark2> {
  @override
  Mark2 get modelSample => Mark2();

  @override
  Mark2 fromCacheJson(Map<String, dynamic> json) => Mark2(id: json['id'] as int?, target: json['target'] as FluentStorable?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'audit2_${counter++}', persistent: true));
  tearDown(() async {
    FluentFullTextSchema.moduleAvailableOverride = null;
    await db.close();
  });

  group('item 14: oldName plus a new column under the old name', () {
    test('the column is renamed and the new one added empty (in place); the next start is fast and keeps it', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      final v2 = DynamicProvider('t', cols(() => [renamed('full', 'name'), FluentDbColumn.text('name')]));
      await db.restart([v2]);
      expect(await columnNames(v2.db, 't'), containsAll(<String>['full', 'name']));
      expect(await v2.db.query('t', columns: ['full', 'name']), [
        {'full': 'Ann', 'name': null},
      ]);
      expect((await history(v2.db, 't')).last, allOf(contains('renamed column \\"name\\" to \\"full\\"'), contains('added column \\"name\\"')));
      await v2.save(v2.row({'full': 'Bob Full', 'name': 'Bob'}));

      final v3 = DynamicProvider('t', cols(() => [renamed('full', 'name'), FluentDbColumn.text('name')]));
      expect(await tookFullSync(() => db.restart([v3])), isFalse, reason: 'nothing changed since');
      expect(await v3.db.query('t', columns: ['full', 'name'], orderBy: 'id'), [
        {'full': 'Ann', 'name': null},
        {'full': 'Bob Full', 'name': 'Bob'},
      ]);
      expect(db.warnings, isEmpty);
    });

    test('with a rebuild the new column starts empty too (never a copy of the old data)', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      // A new CHECK rebuilds the table.
      final v2 = DynamicProvider.spec('t', TableSpec(columns: cols(() => [renamed('full', 'name'), FluentDbColumn.text('name')]), checks: const [FluentCheck('length(full) > 0')]));
      await db.restart([v2]);
      expect(await v2.db.query('t', columns: ['full', 'name']), [
        {'full': 'Ann', 'name': null},
      ]);
      expect((await history(v2.db, 't')).last, contains('rebuilt table'));
      expect((await columnNames(v2.db, 't')).where((c) => c.startsWith('__fluent_removed_')), isEmpty, reason: 'nothing archived');
    });

    test('edge: a chain of renames runs in order (b from a, c from b)', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': 'A', 'b': 'B'});

      final v2 = DynamicProvider('t', cols(() => [renamed('b', 'a'), renamed('c', 'b')]));
      await db.restart([v2]);
      expect((await columnNames(v2.db, 't')).where((c) => const {'a', 'b', 'c'}.contains(c) || c.startsWith('__fluent_removed_')), ['b', 'c']);
      expect(await v2.db.query('t', columns: ['b', 'c']), [
        {'b': 'A', 'c': 'B'},
      ]);
    });

    test('edge: two columns with the same oldName: the first takes the data, the second starts empty (reported)', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann'});

      final v2 = DynamicProvider('t', cols(() => [renamed('x', 'name'), renamed('y', 'name')]));
      await db.restart([v2]);
      expect(await v2.db.query('t', columns: ['x', 'y']), [
        {'x': 'Ann', 'y': null},
      ]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.schemaFallback && i.subject == 'y'), hasLength(1));
    });

    test('edge: a snapshot that misses a column of the model takes the full sync (no fast start over a broken table)', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'note': 'n'});
      // What an older version stored: the snapshot (fingerprint unchanged) does not know "note".
      final Map<String, dynamic> json = jsonDecode((await v1.db.query('__fluent_schema', where: 'table_name = ?', whereArgs: ['t'])).single['snapshot']! as String) as Map<String, dynamic>;
      (json['columns'] as Map<String, dynamic>).remove('note');
      await v1.db.update('__fluent_schema', {'snapshot': jsonEncode(json)}, where: 'table_name = ?', whereArgs: ['t']);

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      expect(await tookFullSync(() => db.restart([v2])), isTrue);
      expect(await v2.db.query('t', columns: ['name', 'note']), [
        {'name': 'Ann', 'note': 'n'},
      ]);
      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      expect(await tookFullSync(() => db.restart([v3])), isFalse, reason: 'repaired snapshot');
    });

    test('edge: a step that removes a column of the model is refused, nothing changes', () async {
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.open([v1]);
      await v1.db.insert('t', {'name': 'Ann', 'note': 'n'});

      final v2 = DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]),
          migrations: const [
            FluentDbMigration(id: 'oops', rawSql: ['ALTER TABLE "t" DROP COLUMN "note"']),
          ],
        ),
      );
      await expectLater(db.restart([v2]), throwsA(isA<FluentSchemaException>().having((e) => e.message, 'message', contains('"note"'))));

      final v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('note')]));
      await db.restart([v3]);
      expect(await v3.db.query('t', columns: ['name', 'note']), [
        {'name': 'Ann', 'note': 'n'},
      ]);
    });
  });

  group('item 16: the fast start and the FTS module of this SQLite', () {
    final TableSpec spec = TableSpec(columns: cols(() => [FluentDbColumn.text('body')]), indexes: [const FluentIndex.fullText(['body'])]);
    Future<List<String>> ftsObjects(Database d) async => [for (final r in await d.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE '__fluent_fts_t%'")) r['name']! as String];

    test('an index built with a module this SQLite lacks is dropped (with its triggers) and reported', () async {
      final v1 = DynamicProvider.spec('t', spec);
      await db.open([v1]);
      await v1.db.insert('t', {'body': 'hello'});
      expect(await ftsObjects(v1.db), isNotEmpty);

      FluentFullTextSchema.moduleAvailableOverride = (_) => false;
      final v2 = DynamicProvider.spec('t', spec);
      expect(await tookFullSync(() => db.restart([v2])), isTrue);
      expect(await ftsObjects(v2.db), isEmpty);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.fullTextFallback), isNotEmpty);
      await v2.save(v2.row({'body': 'world'}));
      expect((await v2.find(where: FluentFilter.search('world'))).map((m) => m['body']), ['world'], reason: 'LIKE search');

      // Still no module: nothing to do, the fast start applies again.
      final v3 = DynamicProvider.spec('t', spec);
      expect(await tookFullSync(() => db.restart([v3])), isFalse);
      expect(await ftsObjects(v3.db), isEmpty);
    });

    test('edge: a table without index on a SQLite that has the module now gets it built', () async {
      FluentFullTextSchema.moduleAvailableOverride = (_) => false;
      final v1 = DynamicProvider.spec('t', spec);
      await db.open([v1]);
      await v1.db.insert('t', {'body': 'hello there'});
      expect(await ftsObjects(v1.db), isEmpty);

      FluentFullTextSchema.moduleAvailableOverride = null;
      final v2 = DynamicProvider.spec('t', spec);
      expect(await tookFullSync(() => db.restart([v2])), isTrue);
      expect(await ftsObjects(v2.db), contains('__fluent_fts_t'));
      expect((await v2.find(where: FluentFilter.search('hello'))).map((m) => m['body']), ['hello there']);

      final v3 = DynamicProvider.spec('t', spec);
      expect(await tookFullSync(() => db.restart([v3])), isFalse, reason: 'the module is the stored one');
    });
  });

  group('item 17: 1.x adoption only when needed', () {
    const List<String> legacy = [
      'CREATE TABLE doc_2 (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)',
      'CREATE INDEX IF NOT EXISTS idx_doc_2_title ON doc_2 (title);',
      'CREATE TABLE mark_2 (id INTEGER PRIMARY KEY AUTOINCREMENT, target_type TEXT, target_id INTEGER)',
      "INSERT INTO doc_2 (id, title) VALUES (1, 'a')",
      "INSERT INTO mark_2 (id, target_type, target_id) VALUES (1, 'doc_2', 1)",
    ];

    test('type values are adopted with their table once; a later full sync neither scans nor rewrites them', () async {
      await legacyFile(db, legacy);
      final marks = Mark2Provider();
      await db.open([Doc2Provider(), marks]);
      expect((await marks.db.query('mark2')).single['target_type'], 'doc2');
      expect(((await marks.find()).single.target! as Doc2).title, 'a');
      expect((await indexNames(marks.db, 'doc2')).where((i) => i.contains('title')), ['idx_doc2_title'], reason: 'the 1.x index of the renamed table is not kept twice');

      // A value under the free 1.x name written after the adoption (e.g. by the app's own SQL) is the app's.
      await marks.db.insert('mark2', {'target_type': 'doc_2', 'target_id': 1});
      final Mark2Provider again = Mark2Provider();
      final QueryCounter counter = await QueryCounter.install();
      try {
        // Another removal setting changes the fingerprint: the full sync runs.
        await db.restart([Doc2Provider(), again], removedColumns: FluentColumnRemoval.drop);
        expect(counter.statements.where((s) => s.contains('CREATE TABLE IF NOT EXISTS "__fluent_schema"')), isNotEmpty, reason: 'full sync');
        expect(counter.statements.where((s) => s.contains('UPDATE "mark2" SET "target_type" = ? WHERE "target_type" = ?')), isEmpty);
      } finally {
        counter.uninstall();
      }
      expect([for (final r in await again.db.query('mark2', orderBy: 'id')) r['target_type']], ['doc2', 'doc_2']);
    });

    test('a 1.x index without quotes is the model\'s index: adopted, not reported, and the fast start applies', () async {
      await legacyFile(db, [
        'CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
        'CREATE INDEX IF NOT EXISTS idx_t_name ON t (name);',
        "INSERT INTO t (name) VALUES ('Ann')",
      ]);
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', indexed: true)]));
      await db.open([v1]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.indexSkipped), isEmpty);
      expect((await indexNames(v1.db, 't')).where((i) => i.contains('name')), ['idx_t_name']);
      final Map<String, dynamic> snapshot = jsonDecode((await v1.db.query('__fluent_schema', where: 'table_name = ?', whereArgs: ['t'])).single['snapshot']! as String) as Map<String, dynamic>;
      expect((snapshot['indexes'] as Map<String, dynamic>).keys, contains('idx_t_name'));

      final v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', indexed: true)]));
      expect(await tookFullSync(() => db.restart([v2])), isFalse);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.indexSkipped), isEmpty);
    });

    test('edge: an index of the same name with another definition stays the app\'s and is reported', () async {
      await legacyFile(db, [
        'CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, other TEXT)',
        'CREATE INDEX idx_t_name ON t (name, other)',
      ]);
      final v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('name', indexed: true), FluentDbColumn.text('other')]));
      await db.open([v1]);
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.indexSkipped), hasLength(1));
      expect((await v1.db.rawQuery("SELECT sql FROM sqlite_master WHERE name = 'idx_t_name'")).single['sql'], contains('other'));
    });
  });
}
