// Full-text schema edges: skipped columns, tables without rowid, the unchanged-index fast path, read-only adoption.
// ignore_for_file: implementation_imports, depend_on_referenced_packages
@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;

  setUp(() => db = FluentTestDb(name: 'fte_${counter++}_${DateTime.now().microsecondsSinceEpoch}', persistent: true));
  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  test('a missing column and a non-text column are skipped with a fullTextSkipped warning naming the text columns', () async {
    final p = DynamicProvider.spec(
      'docs',
      TableSpec(
        columns: cols(() => [FluentDbColumn.text('title'), FluentDbColumn.integer('views')]),
        indexes: const [FluentIndex.fullText(['title', 'ghost', 'views'])],
      ),
    );
    await db.open([p]);
    expect(p.fullTextColumns, ['title']);
    final List<FluentIssue> skipped = db.issues.where((i) => i.kind == FluentIssueKind.fullTextSkipped).toList();
    expect(skipped, hasLength(2));
    expect(skipped.map((i) => i.title).join('|'), allOf(contains('no such column'), contains('not a text column')));
    expect(skipped.every((i) => (i.fix ?? '').contains('title')), isTrue, reason: 'the hint lists the usable text columns');
    await p.save(p.row({'title': 'hello world', 'views': 1}));
    expect((await p.search('hello')).single['title'], 'hello world');
  });

  test('the same columns listed twice by two indexes are indexed once', () async {
    final p = DynamicProvider.spec(
      'docs',
      TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['title']), FluentIndex.fullText(['title'])]),
    );
    await db.open([p]);
    expect(p.fullTextColumns, ['title']);
  });

  test('only skipped columns: no index is built and searching explains how to declare one', () async {
    final p = DynamicProvider.spec('docs', TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['ghost'])]));
    await db.open([p]);
    expect(p.fullTextColumns, isEmpty);
    expect((await p.db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_fts_docs'")), isEmpty);
    await expectLater(p.search('x'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('FluentIndex.fullText'))));
  });

  test('a table without rowid gets a fullTextSkipped warning, no index, and searches still work through LIKE', () async {
    final p = DynamicProvider.spec(
      'wr',
      TableSpec(
        columns: () => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true), FluentDbColumn.text('title')],
        key: () => FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true),
        withoutRowId: true,
        indexes: const [FluentIndex.fullText(['title'])],
      ),
    );
    await db.open([p]);
    expect(db.issues.where((i) => i.kind == FluentIssueKind.fullTextSkipped).map((i) => i.title), contains(contains('no rowid')));
    expect(await p.db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_fts_wr'"), isEmpty);
    await p.save(p.row({'code': 'a', 'title': 'quick brown fox'}));
    expect((await p.search('brown')).single['code'], 'a');
  });

  test('a full sync that changes another table keeps this table\'s unchanged index (no rebuild)', () async {
    final docsSpec = TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['title'])]);
    final v1 = DynamicProvider.spec('docs', docsSpec);
    final o1 = DynamicProvider('other', cols(() => [FluentDbColumn.text('a')]));
    await db.open([v1, o1]);
    await v1.save(v1.row({'title': 'persisted words'}));
    final Object? before = (await v1.db.rawQuery("SELECT rootpage FROM sqlite_master WHERE name = '__fluent_fts_docs'")).single['rootpage'];

    final v2 = DynamicProvider.spec('docs', docsSpec);
    final o2 = DynamicProvider('other', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
    await db.restart([v2, o2]);
    expect((await v2.search('persisted')).single['title'], 'persisted words');
    expect((await v2.db.rawQuery("SELECT rootpage FROM sqlite_master WHERE name = '__fluent_fts_docs'")).single['rootpage'], before, reason: 'not dropped and created again');
  });

  test('a read-only database whose full-text meta table is unreadable falls back to LIKE', () async {
    final spec = TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['title'])]);
    final writer = DynamicProvider.spec('docs', spec);
    await db.open([writer]);
    await writer.save(writer.row({'title': 'apple pie'}));
    await db.close(keepFile: true);

    final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db');
    await raw.execute('DROP TABLE "__fluent_fts"');
    await raw.execute('CREATE TABLE "__fluent_fts" (tbl TEXT)');
    await raw.close();

    try {
      FluentDbInternals.reset();
      final reader = DynamicProvider.spec('docs', spec);
      await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [reader], readOnly: true)]);
      expect([for (final m in await reader.search('apple')) m['title']], ['apple pie']);
    } finally {
      await FluentDb.close();
      FluentDbInternals.reset();
    }
  });

  test('a read-only database in fts4 mode ignores an fts5 index and searches with LIKE', () async {
    final spec = TableSpec(columns: cols(() => [FluentDbColumn.text('title')]), indexes: const [FluentIndex.fullText(['title'])]);
    final writer = DynamicProvider.spec('docs', spec);
    await db.open([writer]);
    await writer.save(writer.row({'title': 'apple pie'}));
    await db.close(keepFile: true);
    try {
      FluentDbInternals.reset();
      final reader = DynamicProvider.spec('docs', spec);
      await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [reader], readOnly: true, config: const FluentDbConfig(fullText: FluentFullText.fts4))]);
      expect([for (final m in await reader.search('apple')) m['title']], ['apple pie']);
    } finally {
      await FluentDb.close();
      FluentDbInternals.reset();
    }
  });
}
