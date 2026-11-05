// The schema side of the relation graph: reference columns and their FOREIGN KEY clauses, link table rebuilds, and the
// clean-up of dangling references when SQLite does not enforce foreign keys.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers.dart';

FluentRelationLink _link(FluentProvider p, String name) => p.relationLinks.singleWhere((FluentRelationLink l) => l.name == name);

Future<String> _sqlOf(FluentProvider p, String table) async {
  final List<Map<String, Object?>> rows = await p.db.rawQuery('SELECT sql FROM sqlite_master WHERE name = ?', [table]);
  return rows.isEmpty ? '' : rows.single['sql']! as String;
}

Future<int> _count(FluentProvider p, String table) async => (await p.db.rawQuery('SELECT COUNT(*) AS c FROM "$table"')).first['c']! as int;

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  group('soft delete and owned lists', () {
    test('an owned list of a soft-deletable owner with a hard-deleted child type is reported', () async {
      GBase.declared[GS] = () => [FluentRelation.many<GS, GB>('bs', (GS s) => s.bs)];
      db = await openG([GSProvider(), GBProvider()]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.relationSoftDelete).single;
      expect(issue.title, contains('GS is soft-deletable but GB is not'));
      expect(issue.fix, contains('FluentSoftDeletable'));
    });

    test('no report when the child is soft-deletable too', () async {
      GBase.declared[GS] = () => [FluentRelation.many<GS, GS>('children', (GS s) => s.bs.cast<GS>(), foreignKey: 'parent_id')];
      db = await openG([GSProvider()]);
      expect(issuesOf(db, FluentIssueKind.relationSoftDelete), isEmpty);
    });
  });

  group('reference columns', () {
    test('a reference on the primary key column becomes a table-level FOREIGN KEY with the declared rule', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b, foreignKey: 'id', onDelete: FluentOnDelete.cascade)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b]);
      final String sql = await _sqlOf(a, 'g_a');
      expect(sql, contains('FOREIGN KEY ("id") REFERENCES "g_b"("id") ON DELETE CASCADE'));
      expect(sql.split('FOREIGN KEY').length, 2, reason: 'the clause is written once');

      await b.save(GB(id: 1, name: 'b'));
      await a.save(GA(id: 1, name: 'a'));
      expect(await _count(a, 'g_a'), 1);
      await b.delete(GB(id: 1));
      expect(await _count(a, 'g_a'), 0, reason: 'the key column follows the delete rule of its reference');
    });

    test('an own REFERENCES with another ON DELETE is kept and reported', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      GBase.columns[GA] = () => [FluentDbColumn(name: 'b_id', type: FluentDbDataType.integer, customSql: 'REFERENCES g_b(id) ON DELETE CASCADE')];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final FluentIssue issue = declarationIssues(db, 'has its own REFERENCES with ON DELETE CASCADE').single;
      expect(issue.subject, 'b_id');
      expect(issue.fix, contains('Remove REFERENCES'));
      expect(await _sqlOf(a, 'g_a'), contains('ON DELETE CASCADE'));
    });

    test('an own REFERENCES without ON DELETE counts as NO ACTION', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      GBase.columns[GA] = () => [FluentDbColumn(name: 'b_id', type: FluentDbDataType.integer, customSql: 'REFERENCES g_b(id)')];
      db = await openG([GAProvider(), GBProvider()]);
      expect(declarationIssues(db, 'ON DELETE NO ACTION'), hasLength(1));
    });

    test('an own REFERENCES with the same rule is silent', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      GBase.columns[GA] = () => [FluentDbColumn(name: 'b_id', type: FluentDbDataType.integer, customSql: 'REFERENCES g_b(id) ON DELETE SET NULL')];
      db = await openG([GAProvider(), GBProvider()]);
      expect(declarationIssues(db, 'own REFERENCES'), isEmpty);
    });

    test('a declared column with other custom SQL gets the REFERENCES appended and an index', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      GBase.columns[GA] = () => [FluentDbColumn(name: 'b_id', type: FluentDbDataType.integer, customSql: 'DEFAULT NULL')];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()]);
      final String sql = await _sqlOf(a, 'g_a');
      expect(sql, contains('DEFAULT NULL REFERENCES "g_b"("id") ON DELETE SET NULL'));
      expect((await a.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'g_a'")).map((Map<String, Object?> r) => r['name']).join(), contains('b_id'));
    });
  });

  group('link table changes', () {
    List<FluentRelation> links(String parent, String child) => [FluentRelation.manyToMany<GA, GB>('bs', (GA a) => a.bs, linkTable: 'ab_links', linkParentKey: parent, linkChildKey: child)];

    test('a link table whose columns all change keeps the old links aside, again with a free name', () async {
      GBase.declared[GA] = () => links('p1', 'c1');
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()], persistent: true);
      final GA owner = GA(name: 'x')..bs = [GB(name: 'one'), GB(name: 'two')];
      await a.save(owner);
      expect(await _count(a, 'ab_links'), 2);

      GBase.declared[GA] = () => links('p2', 'c2');
      final GAProvider a2 = GAProvider();
      await db.restart([a2, GBProvider()]);
      final FluentIssue first = issuesOf(db, FluentIssueKind.relationChanged).last;
      expect(first.title, contains('"ab_links" of "g_a.bs" has key columns the old links have no values for'));
      expect(first.title, contains('__fluent_old_ab_links'));
      expect(first.fix, contains('migration step'));
      expect(await _count(a2, '__fluent_old_ab_links'), 2, reason: 'no link is lost');
      expect(await _count(a2, 'ab_links'), 0);
      expect(await _sqlOf(a2, 'ab_links'), contains('"p2"'));

      GBase.declared[GA] = () => links('p3', 'c3');
      final GAProvider a3 = GAProvider();
      await db.restart([a3, GBProvider()]);
      expect(await _count(a3, '__fluent_old_ab_links'), 2, reason: 'the earlier aside stays');
      expect(await _sqlOf(a3, '__fluent_old_ab_links_2'), contains('"p2"'));
      expect(await _sqlOf(a3, 'ab_links'), contains('"p3"'));
    });

    test('links that collapse under a new key type stay in the aside table together with all old links', () async {
      GBase.declared[GA] = () => links('p', 'c');
      GBase.keyTypes[GB] = FluentDbDataType.text;
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()], persistent: true);
      await a.db.insert('g_a', {'id': 1, 'name': 'owner'});
      await a.db.insert('g_b', {'id': '1', 'name': 'one'});
      await a.db.insert('g_b', {'id': '01', 'name': 'zero-one'});
      await a.db.insert('ab_links', {'p': 1, 'c': '1'});
      await a.db.insert('ab_links', {'p': 1, 'c': '01'});

      // The key of GB becomes an integer: '1' and '01' are the same key now.
      GBase.keyTypes.clear();
      final GAProvider a2 = GAProvider();
      await db.restart([a2, GBProvider()]);
      final FluentIssue issue = issuesOf(db, FluentIssueKind.relationChanged).last;
      expect(issue.title, contains('was rebuilt for its new shape; 1 links did not fit it and all old links were kept in "__fluent_old_ab_links"'));
      expect(issue.code, contains('INSERT OR IGNORE INTO ab_links'));
      expect(await _count(a2, '__fluent_old_ab_links'), 2);
      expect(await _count(a2, 'ab_links'), 1, reason: 'the links that fit the new key are copied, the colliding one is only in the aside table');
    });

    test('a link table that keeps its columns and only changes the key type is rebuilt in place', () async {
      GBase.declared[GA] = () => links('p1', 'c1');
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()], persistent: true);
      await a.save(GA(name: 'x')..bs = [GB(name: 'one')]);
      expect(await _count(a, 'ab_links'), 1);

      // The same names again after a restart: nothing changes.
      final GAProvider same = GAProvider();
      await db.restart([same, GBProvider()]);
      expect(await _count(same, 'ab_links'), 1);
      expect(issuesOf(db, FluentIssueKind.relationChanged), isEmpty);
    });
  });

  group('cleanupOrphans without foreign keys', () {
    const FluentDbConfig noKeys = FluentDbConfig(enableForeignKeys: false);

    test('references to a missing model are cleared, or the row is deleted for cascade', () async {
      GBase.declared[GA] = () => [
        FluentRelation.one<GA, GB>('b', (GA a) => a.b),
        FluentRelation.one<GA, GC>('c', (GA a) => a.c, onDelete: FluentOnDelete.cascade),
      ];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider(), GCProvider()], config: noKeys);
      await a.db.insert('g_a', {'id': 1, 'name': 'cleared', 'b_id': 99, 'c_id': null});
      await a.db.insert('g_a', {'id': 2, 'name': 'deleted', 'b_id': null, 'c_id': 77});
      await a.db.insert('g_a', {'id': 3, 'name': 'fine', 'b_id': null, 'c_id': null});
      await a.cleanupOrphans(a.db);
      final List<Map<String, Object?>> rows = await a.db.query('g_a', orderBy: 'id');
      expect(rows.map((Map<String, Object?> r) => r['name']), ['cleared', 'fine']);
      expect(rows.first['b_id'], isNull);
    });

    test('owned children of a missing owner are deleted, links to missing rows are removed', () async {
      GBase.declared[GA] = () => [
        FluentRelation.many<GA, GB>('bs', (GA a) => a.bs),
        FluentRelation.manyToMany<GA, GC>('cs', (GA a) => a.cs, linkTable: 'ac_links'),
      ];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c], config: noKeys);
      await a.save(GA(name: 'real')..bs = [GB(name: 'kept')]..cs = [GC(name: 'linked')]);
      final String ownerColumn = _link(a, 'bs').foreignKeys.single;
      await b.db.insert('g_b', {'name': 'orphan', ownerColumn: 99});
      await a.db.insert('ac_links', {_link(a, 'cs').linkOwnerColumns.single: 99, _link(a, 'cs').linkTargetColumns.single: 1});
      expect(await _count(a, 'ac_links'), 2);

      await b.cleanupOrphans(b.db);
      expect((await b.db.query('g_b')).map((Map<String, Object?> r) => r['name']), ['kept']);

      // Only the links to the given table: GA's link to GB is not looked at, the link table is.
      await a.cleanupOrphans(a.db, pointingTo: c);
      expect(await _count(a, 'ac_links'), 1);
    });

    test('deleting a row cleans the references to it when foreign keys are off', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b], config: noKeys);
      await b.save(GB(id: 5, name: 'target'));
      await a.db.insert('g_a', {'id': 1, 'name': 'refers', 'b_id': 5});
      await b.delete(GB(id: 5));
      expect((await a.db.query('g_a')).single['b_id'], isNull);
    });

    test('polymorphic references: owned rows are deleted, others cleared, RESTRICT left alone', () async {
      GBase.declared[GA] = () => [FluentRelation.many<GA, GB>('bs', (GA a) => a.bs, via: 'owner')];
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: [GA, GC])];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      db = await openG([a, b, GCProvider()], config: noKeys);
      await b.db.insert('g_b', {'name': 'owned', 'owner_type': 'g_a', 'owner_id': 99});
      await b.db.insert('g_b', {'name': 'plain', 'owner_type': 'g_c', 'owner_id': 98});
      await b.db.insert('g_b', {'name': 'free', 'owner_type': null, 'owner_id': null});
      await b.cleanupOrphans(b.db);
      final List<Map<String, Object?>> rows = await b.db.query('g_b', orderBy: 'name');
      expect(rows.map((Map<String, Object?> r) => r['name']), ['free', 'plain']);
      final Map<String, Object?> plain = rows.last;
      expect(plain['owner_type'], isNull, reason: 'a reference nobody owns is cleared');
      expect(plain['owner_id'], isNull);
    });

    test('a RESTRICT polymorphic reference is reported, not changed', () async {
      GBase.declared[GB] = () => [FluentRelation.oneOf<GB>('owner', (GB b) => b.thing, types: [GA], onDelete: FluentOnDelete.restrict)];
      final GBProvider b = GBProvider();
      db = await openG([GAProvider(), b], config: noKeys);
      await b.db.insert('g_b', {'name': 'stuck', 'owner_type': 'g_a', 'owner_id': 99});
      await b.cleanupOrphans(b.db);
      expect(await _count(b, 'g_b'), 1);
      expect(issuesOf(db, FluentIssueKind.danglingReferences).single.title, contains('RESTRICT'));
    });

    test('a missing relation column is a typed schema exception that keeps the data', () async {
      GBase.declared[GA] = () => [FluentRelation.one<GA, GB>('b', (GA a) => a.b)];
      final GAProvider a = GAProvider();
      db = await openG([a, GBProvider()], config: noKeys);
      await a.db.insert('g_a', {'id': 1, 'name': 'row', 'b_id': 99});
      await a.db.execute('DROP INDEX idx_g_a_b_id');
      await a.db.execute('ALTER TABLE g_a DROP COLUMN b_id');
      await expectLater(a.cleanupOrphans(a.db), throwsA(isA<FluentSchemaException>().having((FluentSchemaException e) => e.hint, 'hint', contains('relation columns exist'))));
      expect(await _count(a, 'g_a'), 1);
    });
  });
}
