// Stress: many databases, many tables, many concurrent callers (G1, G7, G12, G14, G19, G30, G31 on a big world).
//
// 10 file databases with 20 tables each (200 providers, one provider class for every table). scaled(8) clients run
// at once; each awaits its own calls one after another (an app's screens and services) and owns its rows (ids and a
// "client" column), so the reference of committed state is exact: saves, batch saves, updates, deletes, reads of
// its rows (it must see its own writes), counts by filter, and transactions over several tables of one database
// that commit or roll back. Afterwards every table equals the reference, every file is intact, and a restart (the
// second start skips the schema sync) finds the same data.
//
// FLUENT_STRESS=20 bash tool/mirror_test.sh stress test/stress/many_tables_stress_test.dart
library;

import 'dart:math';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/guarantees.dart';
import '../helpers/schema_models.dart';
import 'stress.dart';

const int _dbs = 10;
const int _tablesPerDb = 20;

final TableSpec _spec = TableSpec(
  columns: () => [FluentDbColumn.integer('client'), FluentDbColumn.text('name'), FluentDbColumn.integer('n'), FluentDbColumn.text('data')],
  indexes: const [FluentIndex(['client'])],
);

class _Rollback implements Exception {}

void main() {
  setUpFluentTests();

  test('200 tables in 10 databases under concurrent clients keep every guarantee', timeout: Timeout(stressLimit(secondsPerScale: 120)), () async {
    final StressReport report = StressReport('many tables, many clients');
    final List<FluentDbKey> keys = [for (int d = 0; d < _dbs; d++) FluentDbKey('stress_many_$d')];
    List<List<DynamicProvider>> tables = [];
    List<FluentGroup> groups() {
      tables = [
        for (int d = 0; d < _dbs; d++) [for (int t = 0; t < _tablesPerDb; t++) DynamicProvider.spec('t${t.toString().padLeft(2, '0')}', _spec)],
      ];
      return [for (int d = 0; d < _dbs; d++) FluentGroup(dbKey: keys[d], providerList: tables[d])];
    }

    await report.step('first start: ${_dbs * _tablesPerDb} tables created', () => FluentDb.init(groups(), config: const FluentConfig(readConnections: 2)));

    // Reference of the committed state: [db][table] -> id -> row.
    final List<List<Map<int, Map<String, Object?>>>> ref = [
      for (int d = 0; d < _dbs; d++) [for (int t = 0; t < _tablesPerDb; t++) <int, Map<String, Object?>>{}],
    ];
    final int clients = scaled(8);
    const int opsPerClient = 150;
    int reads = 0;
    int writes = 0;
    int rolledBack = 0;

    Future<void> client(int c) async {
      final Random r = Random(1000 + c);
      int next = 0;
      Map<String, Object?> row(int id) => {'id': id, 'client': c, 'name': 'c$c-${r.nextInt(1 << 20)}', 'n': r.nextInt(1000), 'data': 'd' * r.nextInt(2048)};
      int newId() => c * 1000000 + ++next;
      List<int> mine(int d, int t) => ref[d][t].keys.where((id) => id ~/ 1000000 == c).toList();

      for (int op = 0; op < opsPerClient; op++) {
        final int d = r.nextInt(_dbs);
        final int t = r.nextInt(_tablesPerDb);
        final DynamicProvider p = tables[d][t];
        final String where = 'client $c, op $op, db $d, table $t';
        switch (r.nextInt(8)) {
          case 0:
            final Map<String, Object?> v = row(newId());
            await p.save(p.row(v));
            ref[d][t][v['id']! as int] = v;
            writes++;
          case 1:
            final List<Map<String, Object?>> vs = [for (int i = r.nextInt(50) + 1; i > 0; i--) row(newId())];
            await p.saveAll([for (final v in vs) p.row(v)]);
            for (final v in vs) {
              ref[d][t][v['id']! as int] = v;
            }
            writes++;
          case 2:
            final List<int> ids = mine(d, t);
            if (ids.isEmpty) continue;
            final Map<String, Object?> v = row(ids[r.nextInt(ids.length)]);
            await p.save(p.row(v));
            ref[d][t][v['id']! as int] = v;
            writes++;
          case 3:
            final List<int> ids = mine(d, t);
            if (ids.isEmpty) continue;
            final int id = ids[r.nextInt(ids.length)];
            expect(await p.deleteById(id), 1, reason: 'G7: delete of an existing row ($where)');
            ref[d][t].remove(id);
            writes++;
          case 4:
            final List<int> ids = mine(d, t);
            if (ids.isEmpty) continue;
            final int id = ids[r.nextInt(ids.length)];
            final DynamicModel? got = await p.findById(id);
            expect(got?.values, ref[d][t][id], reason: 'G7: a client reads its own last write ($where, id $id)');
            reads++;
          case 5:
            expect(await p.count(where: FluentFilter.eq('client', c)), mine(d, t).length, reason: 'G7 / G30: the rows of this client ($where)');
            reads++;
          default:
            // A transaction over three tables of one database; one in three rolls back.
            final List<int> ts = [for (int i = 0; i < 3; i++) r.nextInt(_tablesPerDb)];
            final List<(int, Map<String, Object?>)> planned = [for (final int tt in ts) for (int i = r.nextInt(5) + 1; i > 0; i--) (tt, row(newId()))];
            final bool rollback = r.nextInt(3) == 0;
            try {
              await FluentDb.transaction(() async {
                for (final (int tt, Map<String, Object?> v) in planned) {
                  await tables[d][tt].save(tables[d][tt].row(v));
                }
                if (rollback) throw _Rollback();
              }, dbKey: keys[d]);
              for (final (int tt, Map<String, Object?> v) in planned) {
                ref[d][tt][v['id']! as int] = v;
              }
              writes++;
            } on _Rollback {
              rolledBack++;
            }
        }
      }
    }

    await report.step('$clients clients x $opsPerClient calls at once', () async {
      final List<Settled> settled = await waitAllSettled([for (int c = 0; c < clients; c++) client(c)], names: [for (int c = 0; c < clients; c++) 'client $c'], timeout: stressLimit(secondsPerScale: 90), typedErrors: false);
      for (int c = 0; c < settled.length; c++) {
        if (settled[c].failed) fail('client $c: ${settled[c].error}');
      }
    }, detail: (_) => '$writes writes, $reads checked reads, $rolledBack rolled-back transactions');

    Future<void> expectAllSame(String why) async {
      int rows = 0;
      for (int d = 0; d < _dbs; d++) {
        for (int t = 0; t < _tablesPerDb; t++) {
          final List<DynamicModel> all = await tables[d][t].findAll();
          rows += all.length;
          expectSameRows([for (final m in all) m.values], ref[d][t].values.toList(), key: (row) => '${row['id']}', reason: 'G1 $why: db $d table $t');
        }
        await expectIntegrity(tables[d].first.db, reason: 'G19 $why: db $d');
      }
      report.note('$why: $rows rows in ${_dbs * _tablesPerDb} tables equal the reference');
    }

    await report.step('compare every table', () => expectAllSame('after the clients'));
    await report.step('close', FluentDb.close);
    await report.step('second start (schema up to date)', () => FluentDb.init(groups(), config: const FluentConfig(readConnections: 2)));
    await report.step('compare after the restart', () => expectAllSame('after the restart'));
    await FluentDb.deleteDatabases(reopen: false);
    await FluentDb.close();
    report.save();
  });
}
