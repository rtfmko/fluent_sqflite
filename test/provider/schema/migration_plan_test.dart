// FluentDb.planMigrations and FluentGroup.onMigrationPlan: what a start would change, before it changes anything.
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

Future<List<String>> columns(Database db, String table) async => [for (final r in await db.rawQuery('PRAGMA table_info("$table")')) r['name']! as String];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'plan_${counter++}', persistent: true));
  tearDown(() => db.close());

  List<FluentDbColumn> v1() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age')];
  List<FluentDbColumn> v2() => [FluentDbColumn.text('name'), FluentDbColumn.text('display'), FluentDbColumn.integer('age')];

  Future<void> openV1() async {
    final DynamicProvider p = DynamicProvider('t', cols(v1));
    await db.open([p]);
    await p.db.insert('t', {'name': 'Ann', 'nick': 'annie', 'age': '12'});
  }

  test('a database that does not exist is planned in memory and not created', () async {
    final FluentMigrationPlan plan = await db.plan([DynamicProvider('t', cols(v1))]);
    expect(plan.isNewDatabase, isTrue);
    expect(plan.changes.map((c) => c.kind), contains(FluentSchemaChangeKind.createTable));
    expect(File('${await getDatabasesPath()}/${db.name}.db').existsSync(), isFalse);
  });

  test('a plan lists typed changes and issues and changes nothing; the start then applies the same', () async {
    await openV1();
    final FluentMigrationPlan plan = await db.plan([DynamicProvider('t', cols(v2))]);

    expect(plan.isNewDatabase, isFalse);
    final Map<FluentSchemaChangeKind, List<String?>> byKind = {};
    for (final FluentSchemaChange c in plan.changes) {
      (byKind[c.kind] ??= []).add(c.subject);
    }
    expect(byKind[FluentSchemaChangeKind.addColumn], ['display']);
    expect(byKind[FluentSchemaChangeKind.archiveColumn], ['nick']);
    expect(byKind[FluentSchemaChangeKind.changeColumn], ['age']);
    expect(plan.rebuilds, isTrue);
    expect(plan.losesData, isFalse);
    expect(plan.issues.map((i) => i.kind), containsAll([FluentIssueKind.possibleRename, FluentIssueKind.columnTypeChanged, FluentIssueKind.columnArchived]));
    expect('$plan', contains('archived column "nick"'));

    // Nothing happened: the old columns and the data are still there, nothing was reported.
    final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db', singleInstance: false);
    expect(await columns(raw, 't'), containsAll(['nick', 'age']));
    expect(await columns(raw, 't'), isNot(contains('display')));
    await raw.close();
    expect(db.issues.where((i) => i.kind == FluentIssueKind.possibleRename), isEmpty);

    final DynamicProvider applied = DynamicProvider('t', cols(v2));
    await db.restart([applied]);
    expect(await columns(applied.db, 't'), contains('display'));
    expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.possibleRename), reason: 'the real start reports them');
  });

  test('an unchanged schema plans nothing', () async {
    await openV1();
    expect((await db.plan([DynamicProvider('t', cols(v1))])).isEmpty, isTrue);
  });

  test('dropping data is marked; onMigrate runs only with runCode, and is rolled back', () async {
    await openV1();
    final List<String> ran = [];
    List<FluentDbMigration> steps() => [
      FluentDbMigration(id: 'code', onMigrate: (txn) async {
        ran.add('code');
        await txn.insert('t', {'name': 'from step'});
      }),
    ];
    DynamicProvider v3() => DynamicProvider.spec('t', TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]), migrations: steps()));

    final FluentMigrationPlan dropping = await db.plan([v3()], removedColumns: FluentColumnRemoval.drop);
    expect(dropping.losesData, isTrue);
    expect(dropping.changes.where((c) => c.losesData).single.subject, 'nick');
    expect(dropping.skippedCode, ['t.code']);
    expect(ran, isEmpty);

    final FluentMigrationPlan withCode = await db.plan([v3()], runCode: true);
    expect(ran, ['code']);
    expect(withCode.skippedCode, isEmpty);
    final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db', singleInstance: false);
    expect(await raw.query('t'), hasLength(1), reason: 'the row of the step was rolled back');
    await raw.close();
  });

  test('a database already open plans nothing, with a warning', () async {
    await openV1();
    final List<FluentMigrationPlan> plans = await FluentDb.planMigrations([FluentGroup(dbKey: db.key, providerList: [DynamicProvider('t', cols(v2))])]);
    expect(plans.single.isEmpty, isTrue);
    await db.settle(); // issues arrive as stream events
    expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.ignoredCall));
  });

  test('onMigrationPlan can refuse a start: nothing changes, migrationRefused says why', () async {
    await openV1();
    bool safe(FluentMigrationPlan plan) => !plan.losesData;

    final DynamicProvider dropping = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]));
    await expectLater(
      db.restart([dropping], removedColumns: FluentColumnRemoval.drop, onMigrationPlan: safe),
      throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationRefused).having((e) => e.hint, 'hint', contains('dropped column "nick"'))),
    );
    final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db', singleInstance: false);
    expect(await columns(raw, 't'), contains('nick'));
    await raw.close();

    int calls = 0;
    final DynamicProvider archiving = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]));
    await db.restart([archiving], onMigrationPlan: (plan) {
      calls++;
      return safe(plan);
    });
    expect(calls, 1);
    expect(await columns(archiving.db, 't'), contains('__fluent_removed_nick_r2'));

    await db.restart([DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]))], onMigrationPlan: (_) {
      calls++;
      return false;
    });
    expect(calls, 1, reason: 'an unchanged schema asks nothing');
  });

  test('a refused plan never deletes the file, even with resetOnSchemaError', () async {
    await openV1();
    final DynamicProvider dropping = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age')]));
    await expectLater(
      db.restart([dropping], removedColumns: FluentColumnRemoval.drop, resetOnSchemaError: true, onMigrationPlan: (p) => !p.losesData),
      throwsA(isA<FluentSchemaException>().having((e) => e.code, 'code', FluentErrorCode.migrationRefused)),
    );
    final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db', singleInstance: false);
    expect((await raw.query('t')).single['nick'], 'annie');
    await raw.close();
  });

  test('a step that fails is part of the plan, not an exception', () async {
    await openV1();
    final DynamicProvider bad = DynamicProvider.spec('t', TableSpec(columns: cols(v1), migrations: const [FluentDbMigration(id: 'x', rawSql: ['UPDATE nope SET a = 1'])]));
    final FluentMigrationPlan plan = await db.plan([bad]);
    expect(plan.failure?.code, FluentErrorCode.migrationFailed);
    expect(plan.isEmpty, isFalse);
    expect('$plan', contains('would fail'));
  });

  test('a table changed outside the library is synchronized again on the next start', () async {
    await openV1();
    final DynamicProvider same = DynamicProvider('t', cols(v1));
    await db.restart([same]);
    await same.db.execute('ALTER TABLE t ADD COLUMN "by_hand" TEXT');

    final DynamicProvider again = DynamicProvider('t', cols(v1));
    await db.restart([again]);
    expect(await columns(again.db, 't'), contains('__fluent_removed_by_hand_r2'), reason: 'the fast path noticed the change');
  });
}
