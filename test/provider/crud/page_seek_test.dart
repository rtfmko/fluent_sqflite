// Keyset paging seeks to the cursor in the index of its column: every page costs the same, whatever its position.
// Before, `c > v OR (c = v AND key > k)` alone made SQLite scan the index from the first row on every page, so walking
// a big table was quadratic (stress: 1 000 000 rows, 25 ms per page at the end). Checked by the query plan.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late DynamicProvider rows;

  setUp(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'page_seek_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    rows = DynamicProvider.spec(
      'rows',
      TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('n'), FluentDbColumn.text('name')], indexes: const [FluentIndex(['n'])]),
    );
    await db.open([rows]);
    // Ties in n (5 rows per value) and some NULLs.
    await rows.saveAll([for (int i = 1; i <= 3000; i++) rows.row({'id': i, 'n': i % 50 == 0 ? null : i % 600, 'name': 'r$i'})]);
  });

  tearDown(() async {
    await db.close();
    counter.uninstall();
  });

  Future<List<int>> walk({required bool descending}) async {
    final List<int> ids = [];
    FluentCursor? after;
    do {
      final FluentPage<DynamicModel> page = await rows.findPage(orderBy: 'n', descending: descending, limit: 70, after: after);
      ids.addAll(page.items.map((m) => m['id'] as int));
      after = page.next;
    } while (after != null);
    return ids;
  }

  Future<String> planOfLastPage() async {
    final String sql = counter.statements.lastWhere((s) => s.contains('LIMIT 71') && s.contains('>=') || s.contains('<='));
    final String query = sql.substring(sql.indexOf(':') + 2);
    final List<Map<String, Object?>> plan = await rows.db.rawQuery('EXPLAIN QUERY PLAN $query', List.filled('?'.allMatches(query).length, 1));
    return plan.map((r) => r['detail']).join(' | ');
  }

  test('ascending: every row once, in (n, id) order, and the page query seeks in the index', () async {
    final List<int> ids = await walk(descending: false);
    final List<Map<String, Object?>> expected = await rows.db.rawQuery('SELECT "id" FROM "rows" ORDER BY "n" ASC, "id" ASC');
    expect(ids, [for (final r in expected) r['id']]);
    final String plan = await planOfLastPage();
    expect(plan, contains('SEARCH'), reason: plan);
    expect(plan, isNot(contains('SCAN')), reason: plan);
  });

  test('descending (NULLs last): every row once, in order', () async {
    final List<int> ids = await walk(descending: true);
    final List<Map<String, Object?>> expected = await rows.db.rawQuery('SELECT "id" FROM "rows" ORDER BY "n" DESC, "id" DESC');
    expect(ids, [for (final r in expected) r['id']]);
  });
}
