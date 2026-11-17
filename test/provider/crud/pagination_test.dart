// Keyset pagination (findPage) and the hint for paged reads without orderBy.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider posts;

  setUp(() async {
    db = FluentTestDb(name: 'pages_${DateTime.now().microsecondsSinceEpoch}');
    posts = DynamicProvider('posts', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('score'), FluentDbColumn.text('title')]);
    await db.open([posts]);
    // Scores repeat and one is NULL, so the key has to break ties.
    await posts.saveAll([
      for (int i = 1; i <= 25; i++) posts.row({'id': i, 'score': i == 13 ? null : i % 4, 'title': 't$i'}),
    ]);
  });

  tearDown(() => db.close());

  Future<List<int>> walk({String? orderBy, bool descending = false, int limit = 7, void Function(int page)? between}) async {
    final List<int> ids = [];
    FluentCursor? after;
    int page = 0;
    do {
      final FluentPage<DynamicModel> p = await posts.findPage(orderBy: orderBy, descending: descending, limit: limit, after: after);
      ids.addAll([for (final DynamicModel m in p.items) m.values['id'] as int]);
      after = p.next;
      between?.call(page++);
    } while (after != null);
    return ids;
  }

  test('walking all pages returns every row exactly once, in order (ties and NULL included)', () async {
    expect(await walk(), [for (int i = 1; i <= 25; i++) i], reason: 'default order: the key');

    final List<Map<String, Object?>> expectedAsc = await posts.db.rawQuery('SELECT id FROM posts ORDER BY score ASC, id ASC');
    expect(await walk(orderBy: 'score'), [for (final r in expectedAsc) r['id']]);
    final List<Map<String, Object?>> expectedDesc = await posts.db.rawQuery('SELECT id FROM posts ORDER BY score DESC, id DESC');
    expect(await walk(orderBy: 'score', descending: true, limit: 4), [for (final r in expectedDesc) r['id']]);
  });

  test('rows inserted between pages neither repeat nor shift the next page', () async {
    final FluentPage<DynamicModel> first = await posts.findPage(limit: 10);
    await posts.save(posts.row({'id': 0, 'score': 1, 'title': 'new, before the cursor'}));
    final FluentPage<DynamicModel> second = await posts.findPage(limit: 10, after: first.next);
    expect([for (final m in second.items) m.values['id']], [for (int i = 11; i <= 20; i++) i]);
  });

  test('the cursor survives as text; a cursor of another order is refused with a hint', () async {
    final FluentPage<DynamicModel> first = await posts.findPage(orderBy: 'score', limit: 5);
    final FluentCursor restored = FluentCursor.decode(first.next!.encode());
    expect(restored, first.next);
    expect((await FluentDb.findPage<DynamicModel>(orderBy: 'score', limit: 5, after: restored)).items, hasLength(5));
    await expectLater(posts.findPage(orderBy: 'title', after: restored), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('same orderBy'))));
    await expectLater(posts.findPage(orderBy: 'nope'), throwsA(isA<FluentArgumentException>()));
  });

  test('cursor values that do not fit the columns fail with a typed error before any SQL (known bug 3)', () async {
    final FluentPage<DynamicModel> first = await posts.findPage(orderBy: 'score', limit: 5);
    final FluentCursor good = first.next!;
    Matcher refused(String part) => throwsA(isA<FluentArgumentException>().having((e) => e.message, 'message', contains(part)).having((e) => e.hint, 'hint', isNotNull));
    await expectLater(posts.findPage(orderBy: 'score', limit: 5, after: FluentCursor(orderBy: 'score', descending: false, value: 'high', key: good.key)), refused('stores numbers'));
    await expectLater(posts.findPage(orderBy: 'score', limit: 5, after: FluentCursor(orderBy: 'score', descending: false, value: const {'a': 1}, key: good.key)), refused('not a stored value'));
    await expectLater(posts.findPage(orderBy: 'score', limit: 5, after: const FluentCursor(orderBy: 'score', descending: false, value: 1, key: {'uuid': 'x'})), refused('"id"'));
    await expectLater(posts.findPage(orderBy: 'score', limit: 5, after: const FluentCursor(orderBy: 'score', descending: false, value: 1, key: {'id': 'seven'})), refused('"id"'));
    // Text that is a number still fits a numeric column (SQLite converts it); text columns take any text.
    expect((await posts.findPage(orderBy: 'score', limit: 5, after: FluentCursor(orderBy: 'score', descending: false, value: '${good.value}', key: good.key))).items, isNotEmpty);
    final FluentPage<DynamicModel> byTitle = await posts.findPage(orderBy: 'title', limit: 5);
    expect((await posts.findPage(orderBy: 'title', limit: 5, after: FluentCursor.decode(byTitle.next!.encode()))).items, hasLength(5));
  });

  test('paged reads without orderBy get a hint once per table', () async {
    FluentLog.configure(enabled: true, console: false);
    final List<FluentIssue> hints = [];
    final sub = FluentDb.onIssue(types: {FluentIssueType.hint}).listen(hints.add);
    await posts.find(limit: 5, offset: 5);
    await posts.find(limit: 5, offset: 10);
    await posts.findFirst();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    FluentDb.setupLogging(enabled: false);
    expect(hints.where((h) => h.key.startsWith('unordered:')), hasLength(1));
    expect(hints.single.code, contains('findPage'));
  });
}
