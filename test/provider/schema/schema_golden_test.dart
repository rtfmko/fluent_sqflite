// G17: generated DDL and migration plans are a contract; they match golden files (test/golden/schema/).
// Update after a deliberate change: FLUENT_GOLDEN_UPDATE=1 FLUENT_GOLDEN_DIR="$PWD/test/golden" bash tool/mirror_test.sh t5 <this file>
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../fixtures/upgrade_models.dart';
import '../../helpers/golden.dart';
import '../../helpers/guarantees.dart';
import '../../helpers/schema_guard.dart';
import '../../helpers/schema_models.dart';

List<FluentDbColumn> Function() cols(List<FluentDbColumn> Function() extra) => () => [FluentDbColumn.primary(), ...extra()];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  setUp(() => db = FluentTestDb(name: 'golden_schema', persistent: true));
  tearDown(() => db.close());

  /// The DDL of the file: every table / index / trigger of the app's tables, in name order (bookkeeping tables are
  /// the library's own and have their own golden below).
  Future<String> ddl({bool bookkeeping = false}) async {
    final Database raw = await openRaw(db.name);
    try {
      final List<Map<String, Object?>> rows = await raw.rawQuery("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name");
      return [
        for (final Map<String, Object?> r in rows)
          if ((r['tbl_name']! as String).startsWith('__fluent_') == bookkeeping) '-- ${r['type']} ${r['name']}\n${r['sql']};',
      ].join('\n\n');
    } finally {
      await raw.close();
    }
  }

  test('G17: the DDL generated for representative models', () async {
    final List<FluentProvider<FluentStorable>> providers = [
      ...fxProviders(),
      DynamicProvider.spec(
        'plain_types',
        TableSpec(
          columns: () => [
            FluentDbColumn.primary(),
            FluentDbColumn.text('name', isNotNull: true, defaultValue: 'n', isUnique: true, collation: FluentCollation.noCase),
            FluentDbColumn.integer('qty', indexed: true, defaultValue: 0),
            FluentDbColumn.real('score'),
            FluentDbColumn.boolean('flag', defaultValue: false),
            FluentDbColumn.timestamp('at'),
            FluentDbColumn.blob('raw'),
          ],
          indexes: const [FluentIndex(['name', 'qty'], name: 'idx_plain_combo', unique: true)],
          checks: const [FluentCheck('"qty" >= 0')],
        ),
      ),
      DynamicProvider.spec(
        'composite',
        TableSpec(
          columns: () => [FluentDbColumn.text('a'), FluentDbColumn.text('b'), FluentDbColumn.text('v')],
          keys: () => [FluentDbColumn.text('a'), FluentDbColumn.text('b')],
          withoutRowId: true,
        ),
      ),
    ];
    db.clock.set(DateTime.utc(2026, 1, 1));
    await db.open(providers);
    await db.close(keepFile: true);
    expectGolden('schema/ddl_models.sql', await ddl());
    expectGolden('schema/ddl_bookkeeping.sql', await ddl(bookkeeping: true));
  });

  /// Opens version 1 of two tables, then plans [v2] (the file is not changed by planning).
  Future<String> plan(List<FluentProvider> Function() v2, {FluentColumnRemoval removal = FluentColumnRemoval.archive}) async {
    await db.close();
    db.clock.set(DateTime.utc(2026, 1, 1));
    final DynamicProvider t = DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')]));
    await db.open([t, DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]);
    await t.db.insert('t', {'name': 'Ann', 'nick': 'annie', 'age': '12', 'code': 'c'});
    final FluentMigrationPlan p = await db.plan(v2(), removedColumns: removal);
    return '$p\nlosesData: ${p.losesData}\nrebuilds: ${p.rebuilds}\nisEmpty: ${p.isEmpty}';
  }

  test('G17: planMigrations output for representative version changes', () async {
    final StringBuffer out = StringBuffer();
    final Map<String, Future<String> Function()> cases = {
      'unchanged': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]),
      'add column': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code'), FluentDbColumn.integer('extra')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]),
      'rename by oldName': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn(name: 'title', type: FluentDbDataType.text, oldName: 'name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]),
      'remove column (archived)': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age'), FluentDbColumn.text('code')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]),
      'remove column (dropped)': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('age'), FluentDbColumn.text('code')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))], removal: FluentColumnRemoval.drop),
      'type change': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.integer('age'), FluentDbColumn.text('code')])), DynamicProvider('u', cols(() => [FluentDbColumn.text('x')]))]),
      'unique + check + index': () => plan(() => [
        DynamicProvider.spec(
          't',
          TableSpec(
            columns: cols(() => [FluentDbColumn.text('name', isUnique: true), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')]),
            checks: const [FluentCheck('length("code") > 0')],
            indexes: const [FluentIndex(['nick'], name: 'idx_t_nick')],
          ),
        ),
        DynamicProvider('u', cols(() => [FluentDbColumn.text('x')])),
      ]),
      'new table, old table not declared': () => plan(() => [DynamicProvider('t', cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')])), DynamicProvider('v', cols(() => [FluentDbColumn.text('y')]))]),
      'step': () => plan(() => [
        DynamicProvider.spec(
          't',
          TableSpec(columns: cols(() => [FluentDbColumn.text('name'), FluentDbColumn.text('nick'), FluentDbColumn.text('age'), FluentDbColumn.text('code')]), migrations: const [FluentDbMigration(id: 'fix', rawSql: ["UPDATE t SET name = trim(name)"])]),
        ),
        DynamicProvider('u', cols(() => [FluentDbColumn.text('x')])),
      ]),
    };
    for (final MapEntry<String, Future<String> Function()> c in cases.entries) {
      out.writeln('=== ${c.key}');
      out.writeln(await c.value());
      out.writeln();
    }
    expectGolden('schema/plans.txt', out.toString());
    final Database raw = await openRaw(db.name);
    await expectIntegrity(raw);
    await raw.close();
    expectIssuesHaveFixes(db.issues);
  });
}
