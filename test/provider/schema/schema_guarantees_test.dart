// Guarantees of the schema sync (TEST_PLAN.md): G4 schema changes keep data, G21 only explicit deletion, G31 a repeated
// start changes nothing, G1 / G19 a failed start leaves the file as it was.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/faults.dart';
import '../../helpers/guarantees.dart';
import '../../helpers/schema_guard.dart';
import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

/// A parent model whose schema depends on [QParent.unique], with owned children, to start a table rebuild that rejects rows.
class QParent extends FluentStorable with FluentRelations {
  QParent({this.id, required this.name, this.kids});

  static bool unique = false;

  final int? id;
  final String name;
  final List<QKid>? kids;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.primary(), FluentDbColumn.text('name', isUnique: unique)];

  @override
  List<FluentRelation> get relations => [FluentRelation.many<QParent, QKid>('kids', (p) => p.kids, orderBy: 'id')];
}

class QKid extends FluentStorable {
  QKid({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class QParentProvider extends FluentProvider<QParent> {
  @override
  String get tableName => 'q_parent';

  @override
  QParent get modelSample => QParent(name: '');

  @override
  QParent fromCacheJson(Map<String, dynamic> json) => QParent(id: json['id'] as int?, name: json['name'] as String, kids: (json['kids'] as List<dynamic>?)?.cast<QKid>());
}

class QKidProvider extends FluentProvider<QKid> {
  @override
  String get tableName => 'q_kid';

  @override
  QKid get modelSample => QKid(label: '');

  @override
  QKid fromCacheJson(Map<String, dynamic> json) => QKid(id: json['id'] as int?, label: json['label'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'sg_${counter++}', persistent: true));
  tearDown(() => db.close());

  Future<Map<String, Object?>> row(DynamicProvider p, [int id = 1]) async => (await p.db.query(p.table, where: 'id = ?', whereArgs: [id])).single;

  /// G31 + G19 + G26: the same models again change nothing; the file is intact.
  Future<void> expectIdempotentStart(List<FluentProvider> Function() providers) async {
    final Map<String, Object?> before = await dumpFile(db.name);
    final int seen = db.issues.length;
    await db.restart(providers());
    final Map<String, Object?> after = await dumpFile(db.name);
    expect(dumpDiff(before, after), isNull, reason: 'G31: a second start with the same models changes nothing');
    expect([for (final FluentIssue i in db.issues.skip(seen)) if (i.type != FluentIssueType.hint && i.kind != FluentIssueKind.sharedModelType) i], isEmpty, reason: 'G31: and says nothing');
    await expectIntegrity(await openRaw(db.name));
    expectIssuesHaveFixes(db.issues);
  }

  group('G4: schema changes keep data', () {
    test('G4: rename x -> y, remove y, add x in one version is the column x kept: values stay (converted per the type), nothing is lost', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x'), FluentDbColumn.text('keep')]));
      await db.open([v1]);
      await v1.db.insert('t', {'x': '3', 'keep': 'k'});
      // The net model of the version: "x" without oldName (as a reader of the model sees it), "y" gone, this time as an integer.
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('x'), FluentDbColumn.text('keep')]));
      await db.restart([v2]);
      final Map<String, Object?> r = await row(v2);
      expect(r['x'], 3, reason: 'G4: the values of x are kept, converted to the new type, not replaced by an empty column');
      expect(r['keep'], 'k');
      expect(r.keys.where((k) => k.startsWith('__')), isEmpty, reason: 'G21: nothing needed archiving, no archive column appears');
      await expectIdempotentStart(() => [DynamicProvider('t', cols(() => [FluentDbColumn.integer('x'), FluentDbColumn.text('keep')]))]);
      await expectIntegrity(await openRaw(db.name));
    });

    test('G4: two columns that swap names through oldName lose neither value', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': 'was-a', 'b': 'was-b'});
      final DynamicProvider v2 = DynamicProvider(
        't',
        cols(() => [FluentDbColumn(name: 'a', type: FluentDbDataType.text, oldName: 'b'), FluentDbColumn(name: 'b', type: FluentDbDataType.text, oldName: 'a')]),
      );
      await db.restart([v2]);
      final Map<String, Object?> r = await row(v2);
      expect(r['a'], 'was-b', reason: 'G4: "a" is the column that was "b"');
      expect(r['b'], 'was-a', reason: 'G4: "b" is the column that was "a"');
      await expectIdempotentStart(() => [DynamicProvider('t', cols(() => [FluentDbColumn(name: 'a', type: FluentDbDataType.text, oldName: 'b'), FluentDbColumn(name: 'b', type: FluentDbDataType.text, oldName: 'a')]))]);
    });

    test('G4: a rename chain over several starts keeps the value; a freed name can be reused and starts empty', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': 'value'});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'b', type: FluentDbDataType.text, oldName: 'a')]));
      await db.restart([v2]);
      expect((await row(v2))['b'], 'value');
      // v3 renames again and, in the same version, a brand new column takes the freed name "a".
      final DynamicProvider v3 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'c', type: FluentDbDataType.text, oldName: 'b'), FluentDbColumn.text('a')]));
      await db.restart([v3]);
      final Map<String, Object?> r = await row(v3);
      expect(r['c'], 'value');
      expect(r['a'], isNull, reason: 'G4: the reused name is a new, empty column, not the old data');
      // oldName that skips a version: a column untouched in v4 keeps its data, then renames from the name of v3.
      final DynamicProvider v4 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'c', type: FluentDbDataType.text, oldName: 'b'), FluentDbColumn.text('a')]));
      await db.restart([v4]);
      expect((await row(v4))['c'], 'value', reason: 'G4: a stale oldName does nothing');
      await expectIntegrity(v4.db);
    });

    test('G4 / G25: oldName onto a name an existing column holds: the old holder is archived, the renamed column moves in, and it is reported', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x'), FluentDbColumn.text('y')]));
      await db.open([v1]);
      await v1.db.insert('t', {'x': 'X', 'y': 'Y'});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn(name: 'x', type: FluentDbDataType.text, oldName: 'y')]));
      await db.restart([v2]);
      final Map<String, Object?> r = await row(v2);
      expect(r['x'], 'Y', reason: 'G4: the rename is applied: "x" holds the values of "y"');
      expect(valuesOf(r), contains('X'), reason: 'G21: the previous values of "x" are archived');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.columnArchived), reason: 'G25: the archive is reported');
      expect(db.issues.map((i) => i.kind), isNot(contains(FluentIssueKind.schemaFallback)));
      expectIssuesHaveFixes(db.issues);
    });

    test('G4: an oldName naming a column that does not exist is ignored; the data of other columns stays', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': 'keep'});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn(name: 'n', type: FluentDbDataType.text, oldName: 'never_existed')]));
      await db.restart([v2]);
      final Map<String, Object?> r = await row(v2);
      expect(r['a'], 'keep');
      expect(r['n'], isNull);
    });

    test('G4 / G21: a removed column is archived with its values; restoreColumns brings them back exactly once', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('keep'), FluentDbColumn.text('note'), FluentDbColumn.integer('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'keep': 'k', 'note': 'precious', 'n': 7});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('keep')]));
      await db.restart([v2]);
      final Database raw = await openRaw(db.name);
      final List<String> archived = await archivedColumns(raw, 't');
      expect(archived, hasLength(2));
      final Map<String, Object?> r = (await raw.query('t')).single;
      expect(archived.map((c) => r[c]).toSet(), {'precious', 7}, reason: 'G21: nothing disappeared, G4: removals archive');
      await raw.close();

      final DynamicProvider v3 = DynamicProvider.spec(
        't',
        TableSpec(columns: cols(() => [FluentDbColumn.text('keep'), FluentDbColumn.text('note')]), migrations: const [FluentDbMigration(id: 'restore_note', restoreColumns: {'note': 'note'})]),
      );
      await db.restart([v3]);
      expect((await row(v3))['note'], 'precious');
      expect((await row(v3))['keep'], 'k');
      await expectIdempotentStart(
        () => [
          DynamicProvider.spec(
            't',
            TableSpec(columns: cols(() => [FluentDbColumn.text('keep'), FluentDbColumn.text('note')]), migrations: const [FluentDbMigration(id: 'restore_note', restoreColumns: {'note': 'note'})]),
          ),
        ],
      );
    });

    test('G4: a type change keeps every value that converts, and says what it did', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('n'), FluentDbColumn.integer('m')]));
      await db.open([v1]);
      await v1.db.insert('t', {'n': '42', 'm': 5});
      await v1.db.insert('t', {'n': '7', 'm': -3});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n'), FluentDbColumn.text('m')]));
      await db.restart([v2]);
      final List<Map<String, Object?>> rows = await v2.db.query('t', orderBy: 'id');
      expect([for (final Map<String, Object?> r in rows) r['n']], [42, 7]);
      expect([for (final Map<String, Object?> r in rows) r['m']], ['5', '-3']);
      expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.columnTypeChanged), reason: 'G25: the change is visible');
      expectIssuesHaveFixes(db.issues);
    });

    test('G4: a type change of a value that cannot convert keeps the value (SQLite keeps text in an INTEGER column)', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('n')]));
      await db.open([v1]);
      await v1.db.insert('t', {'n': 'not a number'});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.integer('n')]));
      await db.restart([v2]);
      expect((await row(v2))['n'], 'not a number', reason: 'G4: no value is replaced by NULL or 0');
    });

    test('G4: NOT NULL with a default on a table with rows fills the default; without default it stays pending and no row is lost', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': '1'});
      await v1.db.insert('t', {'a': '2'});
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('d', isNotNull: true, defaultValue: 'dflt'), FluentDbColumn.text('p', isNotNull: true)]));
      await db.restart([v2]);
      expect(await v2.db.query('t', orderBy: 'id'), hasLength(2));
      expect([for (final Map<String, Object?> r in await v2.db.query('t', orderBy: 'id')) r['d']], ['dflt', 'dflt']);
      expect([for (final Map<String, Object?> r in await v2.db.query('t', orderBy: 'id')) r['a']], ['1', '2']);
      await expectIntegrity(await openRaw(db.name));
    });

    test('G4: adding a UNIQUE column rule on duplicates quarantines the extra rows; every row is in the table or the quarantine', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code'), FluentDbColumn.text('note')]));
      await db.open([v1]);
      for (final List<String> r in [['a', '1'], ['b', '2'], ['a', '3'], ['c', '4'], ['b', '5']]) {
        await v1.db.insert('t', {'code': r[0], 'note': r[1]});
      }
      final DynamicProvider v2 = DynamicProvider('t', cols(() => [FluentDbColumn.text('code', isUnique: true), FluentDbColumn.text('note')]));
      await db.restart([v2]);
      final Database raw = await openRaw(db.name);
      final List<String> quarantine = await quarantineTables(raw, 't');
      expect(quarantine, hasLength(1));
      final Set<Object?> live = {for (final Map<String, Object?> r in await raw.query('t')) r['note']};
      final Set<Object?> held = {for (final Map<String, Object?> r in await raw.query(quarantine.single)) r['note']};
      expect({...live, ...held}, {'1', '2', '3', '4', '5'}, reason: 'G4: nothing lost');
      expect(live.intersection(held), isEmpty, reason: 'in exactly one place');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.rowsQuarantined));
      await raw.close();
      expectIssuesHaveFixes(db.issues);
    });

    Future<QParentProvider> quarantinedParent() async {
      QParent.unique = false;
      final QParentProvider parents = QParentProvider();
      final QKidProvider kids = QKidProvider();
      await db.open([parents, kids]);
      await parents.save(QParent(id: 1, name: 'dup', kids: [QKid(id: 10, label: 'a'), QKid(id: 11, label: 'b')]));
      await parents.save(QParent(id: 2, name: 'dup', kids: [QKid(id: 12, label: 'c')]));
      await parents.save(QParent(id: 3, name: 'single', kids: [QKid(id: 13, label: 'd')]));
      QParent.unique = true;
      addTearDown(() => QParent.unique = false);
      final QParentProvider after = QParentProvider();
      await db.restart([after, QKidProvider()]);
      return after;
    }

    test('G4 / G19: the children of a quarantined parent stay in place with their reference and are reported; moving the parent back repairs them', () async {
      final QParentProvider parentsAfter = await quarantinedParent();
      final Database raw = await openRaw(db.name);
      final List<Map<String, Object?>> liveParents = await raw.query('q_parent', orderBy: 'id');
      expect([for (final Map<String, Object?> r in liveParents) r['id']], [1, 3], reason: 'the first "dup" stays, the second is quarantined');
      final List<String> quarantine = await quarantineTables(raw, 'q_parent');
      expect(quarantine, hasLength(1));
      expect([for (final Map<String, Object?> r in await raw.query(quarantine.single)) r['id']], [2]);
      final Set<Object?> kidLabels = {for (final Map<String, Object?> r in await raw.query('q_kid')) r['label']};
      expect(kidLabels, {'a', 'b', 'c', 'd'}, reason: 'G4 / G21: no child row is lost or moved');
      final List<FluentIssue> dangling = [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.danglingReferences) i];
      final FluentIssue named = dangling.firstWhere((i) => '${i.title} ${i.details}'.contains(quarantine.single), orElse: () => fail('G25: an issue names the quarantine table the parents were moved to (got: ${dangling.map((i) => i.title).toList()})'));
      expect(named.fix, contains('Move the quarantined rows back'), reason: 'G26: and says how to repair it');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.rowsQuarantined));
      expectIssuesHaveFixes(db.issues);

      // The documented repair: the parent row goes back (under a free name); then nothing dangles and the children load.
      await raw.close();
      final Database fix = await openRaw(db.name, readOnly: false);
      await fix.execute('PRAGMA foreign_keys = OFF');
      await fix.insert('q_parent', {'id': 2, 'name': 'restored'});
      await fix.delete(quarantine.single, where: 'id = 2');
      await fix.execute('PRAGMA foreign_keys = ON');
      await expectIntegrity(fix, reason: 'after the parent is moved back');
      await fix.close();
      final QParent loaded = (await parentsAfter.findById(2))!;
      expect([for (final QKid k in loaded.kids ?? const <QKid>[]) k.label], ['c'], reason: 'the children of the restored parent load again');
    });

    test('G21: a table whose provider is not registered keeps its data; registering it again shows the rows', () async {
      final DynamicProvider a = DynamicProvider('t_a', cols(() => [FluentDbColumn.text('x')]));
      final DynamicProvider b = DynamicProvider('t_b', cols(() => [FluentDbColumn.text('y')]));
      await db.open([a, b]);
      await b.db.insert('t_b', {'y': 'kept'});
      await db.restart([DynamicProvider('t_a', cols(() => [FluentDbColumn.text('x')]))]);
      final Database raw = await openRaw(db.name);
      expect((await raw.query('t_b')).single['y'], 'kept', reason: 'G21: nothing removes a table the app stopped declaring');
      await raw.close();
      final DynamicProvider back = DynamicProvider('t_b', cols(() => [FluentDbColumn.text('y')]));
      await db.restart([DynamicProvider('t_a', cols(() => [FluentDbColumn.text('x')])), back]);
      expect((await back.db.query('t_b')).single['y'], 'kept');
      await expectIntegrity(back.db);
    });

    test('G4: a table recreated under the same name after its provider was dropped adopts the old table without losing rows', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a')]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': 'old'});
      await db.restart([DynamicProvider('other', cols(() => [FluentDbColumn.text('o')]))]);
      final DynamicProvider v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('extra')]));
      await db.restart([DynamicProvider('other', cols(() => [FluentDbColumn.text('o')])), v3]);
      expect((await row(v3))['a'], 'old');
    });

    test('G4: the new definition of a column whose archive name is already taken by an archive does not touch the archive', () async {
      // First removal archives "note" (r2); the second removal of a new "note" archives it under another revision name.
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('note')]));
      await db.open([v1]);
      await v1.db.insert('t', {'note': 'first'});
      await db.restart([DynamicProvider('t', cols(() => []))]);
      final DynamicProvider v3 = DynamicProvider('t', cols(() => [FluentDbColumn.text('note')]));
      await db.restart([v3]);
      await v3.db.update('t', {'note': 'second'});
      await db.restart([DynamicProvider('t', cols(() => []))]);
      final Database raw = await openRaw(db.name);
      final Map<String, Object?> r = (await raw.query('t')).single;
      final List<String> archived = await archivedColumns(raw, 't');
      expect(archived.map((c) => r[c]).toSet(), {'first', 'second'}, reason: 'G21: both generations survive');
      await raw.close();
    });

    test('G4: a column renamed onto the name of an archived column keeps both the archive and the renamed values', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('note'), FluentDbColumn.text('other')]));
      await db.open([v1]);
      await v1.db.insert('t', {'note': 'N', 'other': 'O'});
      await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('other')]))]);
      final Database probe = await openRaw(db.name);
      final String archiveName = (await archivedColumns(probe, 't')).single;
      await probe.close();
      final DynamicProvider v3 = DynamicProvider('t', cols(() => [FluentDbColumn(name: archiveName, type: FluentDbDataType.text, oldName: 'other')]));
      try {
        await db.restart([v3]);
      } on FluentException catch (e) {
        expectTypedError(e);
      }
      final Database raw = await openRaw(db.name);
      final Set<String> all = {for (final Map<String, Object?> r in await raw.query('t')) ...valuesOf(r)};
      expect(all, containsAll(['N', 'O']), reason: 'G21: both values still exist (renamed, archived or refused with a typed error)');
      await raw.close();
    });
  });

  group('G31: starts are idempotent', () {
    test('G31: a start with unchanged models changes no byte of the data, the schema bookkeeping or the DDL, for tables of every feature', () async {
      List<FluentProvider> providers() => [
        DynamicProvider.spec(
          'features',
          TableSpec(
            columns: () => [
              FluentDbColumn.primary(),
              FluentDbColumn.text('name', isNotNull: true, defaultValue: '', indexed: true),
              FluentDbColumn.integer('qty', isUnique: true),
              FluentDbColumn.boolean('flag'),
              FluentDbColumn.timestamp('at'),
              FluentDbColumn.real('score'),
              FluentDbColumn.blob('raw'),
            ],
            indexes: const [FluentIndex(['name', 'qty'], name: 'idx_features_combo')],
            checks: const [FluentCheck('"qty" >= 0')],
          ),
        ),
        DynamicProvider.spec(
          'keyed',
          TableSpec(
            columns: () => [FluentDbColumn.text('a'), FluentDbColumn.text('b'), FluentDbColumn.text('v')],
            keys: () => [FluentDbColumn.text('a'), FluentDbColumn.text('b')],
            withoutRowId: true,
          ),
        ),
      ];
      final List<FluentProvider> first = providers();
      await db.open(first);
      await (first[0] as DynamicProvider).db.insert('features', {'name': 'x', 'qty': 1, 'flag': 1, 'at': 5, 'score': 0.5});
      await (first[1] as DynamicProvider).db.insert('keyed', {'a': 'k1', 'b': 'k2', 'v': 'val'});
      await expectIdempotentStart(providers);
      await expectIdempotentStart(providers);
    });

    test('G31: the second start after every kind of change is a no-op (rename, archive, type, constraint, index)', () async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b'), FluentDbColumn.text('c'), FluentDbColumn.text('d', indexed: true)]));
      await db.open([v1]);
      await v1.db.insert('t', {'a': '1', 'b': '2', 'c': '3', 'd': '4'});
      List<FluentProvider> v2() => [
        DynamicProvider.spec(
          't',
          TableSpec(
            columns: cols(() => [FluentDbColumn(name: 'a2', type: FluentDbDataType.text, oldName: 'a'), FluentDbColumn.integer('b'), FluentDbColumn.text('c', isNotNull: true, defaultValue: 'z'), FluentDbColumn.text('e', isUnique: true)]),
            indexes: const [FluentIndex(['a2'], name: 'idx_t_a2')],
          ),
        ),
      ];
      await db.restart(v2());
      final Database raw = await openRaw(db.name);
      final Map<String, Object?> r = (await raw.query('t')).single;
      expect(r['a2'], '1');
      expect(r['b'], 2);
      expect(r['c'], '3');
      expect(valuesOf(r), contains('4'), reason: 'G21: the removed column "d" is archived');
      await raw.close();
      await expectIdempotentStart(v2);
    });
  });

  group('G4 / G1 / G31: oldName onto a name an existing column holds', () {
    late FaultyDatabaseFactory faults;

    setUp(() async => faults = await FaultyDatabaseFactory.install());
    tearDown(() async {
      faults.heal();
      await db.close();
      faults.uninstall();
    });

    FluentDbColumn text(String name, [String? oldName]) => FluentDbColumn(name: name, type: FluentDbDataType.text, oldName: oldName);

    // Each case: the model of the second version and what the row must hold afterwards ("archived": a value kept in an archive column).
    final Map<String, (List<FluentDbColumn> Function(), Map<String, String>)> cases = {
      'old holder archived, y renamed to x': (() => [text('x', 'y')], {'x': 'Y', 'archived': 'X'}),
      'swap through a temporary name': (() => [text('x', 'y'), text('y', 'x')], {'x': 'Y', 'y': 'X'}),
    };

    for (final MapEntry<String, (List<FluentDbColumn> Function(), Map<String, String>)> c in cases.entries) {
      List<FluentProvider> v2() => [DynamicProvider('t', cols(c.value.$1))];

      test('G4 / G31 / G17: ${c.key}: data moves, planMigrations shows a typed rename, a second start is a no-op', () async {
        final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x'), FluentDbColumn.text('y')]));
        await db.open([v1]);
        await v1.db.insert('t', {'x': 'X', 'y': 'Y'});
        await db.close(keepFile: true);

        final FluentMigrationPlan plan = await db.plan(v2());
        expect(plan.changes.map((ch) => ch.kind), contains(FluentSchemaChangeKind.renameColumn), reason: 'G17: the plan shows the rename');
        expect(plan.issues.map((i) => i.kind), isNot(contains(FluentIssueKind.schemaFallback)));
        final Database before = await openRaw(db.name);
        expect((await before.query('t')).single['x'], 'X', reason: 'G17: planning changed nothing');
        await before.close();

        final List<FluentProvider> started = v2();
        await db.open(started);
        final Map<String, Object?> r = await row(started.single as DynamicProvider);
        for (final MapEntry<String, String> e in c.value.$2.entries) {
          if (e.key == 'archived') {
            expect(valuesOf(r), contains(e.value), reason: 'G21: the previous values are archived');
          } else {
            expect(r[e.key], e.value, reason: 'G4: ${e.key}');
          }
        }
        expectIssuesHaveFixes(db.issues);
        await expectIdempotentStart(v2);
      });

      test('G1: ${c.key}: a failure at every statement leaves the old or the new state', () async {
        final DateTime fixed = DateTime.utc(2026, 5, 5, 12);
        Future<void> prepare() async {
          await db.close(); // deletes the file
          db.clock.set(fixed);
          final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('x'), FluentDbColumn.text('y')]));
          await db.open([v1]);
          await v1.db.insert('t', {'x': 'X', 'y': 'Y'});
          await db.close(keepFile: true);
        }

        const Set<String> skip = {'__fluent_stats', '__fluent_schema_history'};
        await prepare();
        db.clock.set(fixed);
        final int start = faults.calls.length;
        await db.open(v2());
        final int statements = faults.calls.length - start;
        final int commitAt = faults.calls.skip(start).toList().indexWhere((call) => call.isCommit);
        expect(commitAt, greaterThan(0));
        await db.close(keepFile: true);
        final Map<String, Object?> migrated = await dumpFile(db.name, skip: skip);
        Future<List<Map<String, Object?>>> rowsOfT() async {
          final Database raw = await openRaw(db.name);
          final List<Map<String, Object?>> rows = await raw.query('t', orderBy: 'id');
          await raw.close();
          return rows;
        }

        final List<Map<String, Object?>> migratedRows = await rowsOfT();

        for (int n = 0; n < statements; n++) {
          final String where = 'fault at statement $n of $statements';
          bool swallowed = false;
          await prepare();
          final Map<String, Object?> old = await dumpFile(db.name, skip: skip);
          db.clock.set(fixed);
          faults.failNth(n);
          Object? error;
          try {
            await db.open(v2());
          } catch (e) {
            error = e;
          }
          faults.heal();
          if (error != null) expectTypedError(error, reason: where);
          await db.close(keepFile: true);
          final Map<String, Object?> after = await dumpFile(db.name, skip: skip);
          if (n > commitAt) {
            expect(dumpDiff(migrated, after), isNull, reason: 'G1: $where is after the commit: the new state');
          } else if (error != null) {
            expect(dumpDiff(old, after), isNull, reason: 'G1: $where failed the start before the commit: the old state');
          } else {
            // An in-place ALTER that SQLite refused falls back to a rebuild (by design): same data, another physical table.
            swallowed = true;
            expect(await rowsOfT(), migratedRows, reason: 'G1: $where was absorbed by the rebuild fallback; the rows are those of the undisturbed run');
          }
          final Database raw = await openRaw(db.name);
          await expectIntegrity(raw, reason: where);
          await raw.close();
          db.clock.set(fixed);
          await db.open(v2());
          await db.close(keepFile: true);
          if (swallowed) {
            expect(await rowsOfT(), migratedRows, reason: 'G1 / G31: $where, then a healthy start keeps the rows of the undisturbed run');
          } else {
            expect(dumpDiff(migrated, await dumpFile(db.name, skip: skip)), isNull, reason: 'G1 / G31: $where, then a healthy start ends in the same state as an undisturbed one');
          }
        }
      });
    }
  });

  group('G1 / G19: a failed start leaves the file as it was', () {
    late FaultyDatabaseFactory faults;

    setUp(() async => faults = await FaultyDatabaseFactory.install());
    tearDown(() async {
      faults.heal();
      await db.close();
      faults.uninstall();
    });

    Future<void> openV1() async {
      final DynamicProvider v1 = DynamicProvider('t', cols(() => [FluentDbColumn.text('a'), FluentDbColumn.text('b'), FluentDbColumn.text('note')]));
      final DynamicProvider w1 = DynamicProvider('w', cols(() => [FluentDbColumn.text('x')]));
      await db.open([v1, w1]);
      await v1.db.insert('t', {'a': '1', 'b': '10', 'note': 'n1'});
      await v1.db.insert('t', {'a': '1', 'b': '20', 'note': 'n2'}); // duplicates on "a" -> quarantine in v2
      await v1.db.insert('t', {'a': '2', 'b': '30', 'note': 'n3'});
      await w1.db.insert('w', {'x': 'untouched'});
    }

    // A representative migration: rename + type change + new column + removal (archive) + UNIQUE with a duplicate
    // (rebuild with quarantine) + index + a step, over two tables.
    List<FluentProvider> v2() => [
      DynamicProvider.spec(
        't',
        TableSpec(
          columns: cols(() => [FluentDbColumn.text('a', isUnique: true), FluentDbColumn(name: 'bb', type: FluentDbDataType.integer, oldName: 'b'), FluentDbColumn.text('fresh', defaultValue: 'f')]),
          indexes: const [FluentIndex(['bb'], name: 'idx_t_bb')],
          migrations: const [FluentDbMigration(id: 'fix', rawSql: ["UPDATE t SET fresh = 'step'"])],
        ),
      ),
      DynamicProvider('w', cols(() => [FluentDbColumn.text('x'), FluentDbColumn.integer('y')])),
    ];

    test('G1: a failure at every statement of the start fails typed (or the start completes), the file is then unchanged, and the next start without the fault works', () async {
      final DateTime fixed = DateTime.utc(2026, 5, 5, 12);
      Future<void> prepare() async {
        await db.close(); // deletes the file
        db.clock.set(fixed);
        await openV1();
        await db.close(keepFile: true);
      }

      // Reference run: how many statements the migration issues, and the state it ends in.
      await prepare();
      db.clock.set(fixed);
      final int start = faults.calls.length;
      await db.open(v2());
      final int statements = faults.calls.length - start;
      // The statements after the schema transaction's COMMIT (foreign key check, pragma) run when the changes are already durable.
      final int commitAt = faults.calls.skip(start).toList().indexWhere((c) => c.isCommit);
      expect(commitAt, greaterThan(0));
      await db.close(keepFile: true);
      final Map<String, Object?> migrated = await dumpFile(db.name, skip: {'__fluent_stats', '__fluent_schema_history'});
      final Map<String, Object?> migratedNoSchema = Map.of(migrated)..remove('table:__fluent_schema');
      expect(statements, greaterThan(10), reason: 'the migration is made of many statements');

      int failedStarts = 0;
      for (int n = 0; n < statements; n++) {
        final String where = 'fault at statement $n of $statements';
        await prepare();
        final Map<String, Object?> before = await dumpFile(db.name, skip: {'__fluent_stats', '__fluent_schema_history'});
        db.clock.set(fixed);
        faults.failNth(n);
        Object? error;
        bool swallowed = false;
        try {
          await db.open(v2());
        } catch (e) {
          error = e;
        }
        faults.heal();
        if (error != null) {
          failedStarts++;
          expectTypedError(error, reason: where);
          await db.close(keepFile: true);
          final Map<String, Object?> after = await dumpFile(db.name, skip: {'__fluent_stats', '__fluent_schema_history'});
          if (n <= commitAt) {
            expect(dumpDiff(before, after), isNull, reason: 'G1 / G19: $where (${faults.injected.last}) is at or before the commit and failed the start, so the file must be as before');
          } else {
            expect(dumpDiff(migrated, after), isNull, reason: 'G1: $where (${faults.injected.last}) is after the commit: the file holds the whole change');
          }
          final Database raw = await openRaw(db.name);
          await expectIntegrity(raw, reason: where);
          await raw.close();
        } else {
          // Only advisory statements may be swallowed by design: a skipped index ("the table works without it") and the
          // foreign key check after the commit.
          final SqlCall hit = faults.injected.last;
          final bool index = hit.matches('INDEX');
          expect(index || n > commitAt, isTrue, reason: 'G1 / G25: $where was swallowed by the start, but only an index or work after the commit (check, maintenance) may be ($hit)');
          if (index) expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.indexSkipped), reason: 'G25: $where, a skipped index is reported');
          swallowed = index;
          await db.close(keepFile: true);
        }
        // The next start without the fault succeeds and reaches the migrated state (a skipped index is created now).
        db.clock.set(fixed);
        await db.open(v2());
        await db.close(keepFile: true);
        final Map<String, Object?> done = await dumpFile(db.name, skip: {'__fluent_stats', '__fluent_schema_history', if (swallowed) '__fluent_schema'});
        expect(dumpDiff(swallowed ? migratedNoSchema : migrated, done), isNull, reason: 'G1 / G31: $where, then a healthy start ends in the same state as an undisturbed one');
      }
      expect(failedStarts, greaterThan(statements ~/ 2), reason: 'most statements of a migration are essential: their failure fails the start');
    });
  });
}
