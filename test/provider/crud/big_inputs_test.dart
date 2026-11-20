// Big inputs in every public call: lists of keys, values and models far beyond what one SQLite statement binds.
//
// SQLite before 3.32 (Android 11 and older) refuses statements with more than 999 arguments; newer versions 32766.
// Every call must accept any reasonable size and split or move the values itself: after each test no statement
// bound more than 999 arguments (QueryCounter.maxArguments), whatever SQLite the tests run on.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';
import '../../helpers/schema_models.dart';

class _Enc extends FluentConverter<String, String> {
  const _Enc();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(String value) => 'enc:$value';

  @override
  String fromSql(String value) => value.substring(4);
}

const int _n = 3000;
const int _oldSqliteLimit = 999;

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late List<FluentProvider> providers;
  late CommentProvider comments;

  setUp(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'big_inputs_${DateTime.now().microsecondsSinceEpoch}');
    providers = relationProviders();
    comments = providers.whereType<CommentProvider>().single;
    await db.open(providers);
    counter.reset();
  });

  tearDown(() async {
    final int widest = counter.maxArguments;
    final String? statement = counter.widest;
    await db.close();
    counter.uninstall();
    expect(widest, lessThanOrEqualTo(_oldSqliteLimit), reason: 'a statement bound $widest arguments (old SQLite refuses more than 999): $statement');
  });

  List<int> ids([int from = 1, int count = _n]) => [for (int i = from; i < from + count; i++) i];
  Future<void> seed() => comments.saveAll([for (final int id in ids()) Comment(id: id, text: 'c$id', likes: id % 10)]);

  group('writes', () {
    test('saveAll inserts and then upserts $_n rows', () async {
      await seed();
      expect(await comments.count(), _n);
      final FluentSaveResult again = await comments.saveAll([for (final int id in ids()) Comment(id: id, text: 'v2 $id', likes: 1)]);
      expect(again.outcomes.length, _n);
      expect(await comments.count(where: FluentFilter.eq('likes', 1)), _n);
    });

    test('updateAll / updateWhere(ids) / updateWhere(inList) change $_n rows', () async {
      await seed();
      expect(await comments.updateAll([for (final int id in ids()) Comment(id: id, text: 'u$id', likes: 2)]), _n);
      expect(await comments.updateWhere(FluentFilter.ids(ids()), {'likes': 3}), _n);
      expect(await comments.updateWhere(FluentFilter.inList('id', ids()), {'likes': 4}), _n);
      expect(await comments.count(where: FluentFilter.eq('likes', 4)), _n);
    });

    test('deleteWhere(ids) / deleteAll / deleteWhere(inList) remove $_n rows (soft) and the trash takes them back', () async {
      await seed();
      expect(await comments.deleteWhere(FluentFilter.ids(ids(1, 1000))), 1000);
      expect(await comments.deleteAll([for (final int id in ids(1001, 1000)) Comment(id: id, text: '')]), 1000);
      expect(await comments.deleteWhere(FluentFilter.inList('id', ids(2001, 1000))), 1000);
      expect(await comments.count(), 0);
      expect(await comments.trash.count(where: FluentFilter.ids(ids())), _n);
      expect((await comments.trash.find(where: FluentFilter.ids(ids()))).length, _n);
      expect(await comments.trash.restoreWhere(FluentFilter.ids(ids())), _n);
      expect(await comments.count(), _n);
      expect(await comments.deleteWhere(FluentFilter.ids(ids())), _n);
      expect(await comments.trash.deleteForeverWhere(FluentFilter.ids(ids())), _n);
      expect(await comments.withTrash.count(), 0);
    });

    test('a hard delete by $_n keys (no soft delete)', () async {
      final PersonProvider people = providers.whereType<PersonProvider>().single;
      await people.saveAll([for (final int id in ids()) Person(id: id, name: 'p$id')]);
      expect(await people.deleteWhere(FluentFilter.ids(ids(1, 2000))), 2000);
      expect(await people.deleteAll([for (final int id in ids(2001, 1000)) Person(id: id, name: '')]), 1000);
      expect(await people.count(), 0);
    });
  });

  group('reads', () {
    test('findByIds / find(ids) / find(inList) / notInList return the right rows', () async {
      await seed();
      expect((await comments.findByIds(ids())).length, _n);
      final List<Comment> page = await comments.find(where: FluentFilter.ids(ids()), orderBy: 'id', limit: 10, offset: 2500);
      expect(page.map((c) => c.id), ids(2501, 10));
      expect((await comments.find(where: FluentFilter.inList('id', ids(1, 2000)))).length, 2000);
      expect((await comments.find(where: FluentFilter.notInList('id', ids(1, 2000)))).length, 1000);
      expect((await comments.find(where: FluentFilter.ids(ids(1, 2000)).and(FluentFilter.eq('likes', 0)))).length, 200);
      expect((await comments.find(where: FluentFilter.ids(ids(1, 1500)).or(FluentFilter.ids(ids(1501, 1500))))).length, _n);
    });

    test('count / exists / aggregates / findMaps / findPage with $_n keys', () async {
      await seed();
      final FluentFilter all = FluentFilter.ids(ids());
      expect(await comments.count(where: all), _n);
      expect(await comments.existsWhere(FluentFilter.ids(ids(_n + 1, 2000)).or(FluentFilter.ids([5]))), isTrue);
      expect(await comments.sum('likes', where: all), _n ~/ 10 * 45);
      expect(await comments.avg('likes', where: all), 4.5);
      expect(await comments.countDistinct('likes', where: FluentFilter.inList('id', ids())), 10);
      final List<Map<String, dynamic>> groups = await comments.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['likes'], where: all, orderBy: 'likes');
      expect(groups.map((g) => g['n']), List.filled(10, _n ~/ 10));
      expect((await comments.findMaps(where: all, columns: ['id'])).length, _n);
      int walked = 0;
      FluentCursor? after;
      do {
        final FluentPage<Comment> p = await comments.findPage(where: all, limit: 700, after: after);
        walked += p.items.length;
        after = p.next;
      } while (after != null);
      expect(walked, _n);
    });

    test('watch(ids) emits the $_n rows and follows a change', () async {
      await seed();
      final StreamIterator<List<Comment>> it = StreamIterator(comments.watch(where: FluentFilter.ids(ids())));
      expect(await it.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      expect(it.current.length, _n);
      await comments.deleteWhere(FluentFilter.ids(ids(1, 1000)));
      expect(await it.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      expect(it.current.length, 2000);
      await it.cancel();
    });
  });

  group('connections, keys and transactions', () {
    test('a composite key with a converted part: find, count, update and delete by $_n keys', () async {
      final FluentDbColumn a = FluentDbColumn.converted('a', const _Enc()).copyWith(isPrimaryKey: true);
      final FluentDbColumn b = FluentDbColumn.integer('b').copyWith(isPrimaryKey: true);
      final DynamicProvider p = DynamicProvider.spec('pairs', TableSpec(columns: () => [a, b, FluentDbColumn.text('name')], keys: () => [a, b]));
      await db.open([p]);
      FluentKey key(int i) => FluentKey({'a': 'k${i % 7}', 'b': i});
      await p.saveAll([for (final int i in ids()) p.row({'a': 'k${i % 7}', 'b': i, 'name': 'n$i'})]);
      final List<FluentKey> keys = [for (final int i in ids()) key(i)];
      expect((await p.findByIds(keys)).length, _n);
      expect((await p.find(where: FluentFilter.ids(keys))).length, _n);
      expect(await p.count(where: FluentFilter.ids([...keys.take(2000), FluentKey({'a': 'k0', 'b': 999999})])), 2000);
      expect(await p.updateWhere(FluentFilter.ids(keys.skip(1000)), {'name': 'u'}), 2000);
      expect(await p.deleteWhere(FluentFilter.ids(keys.take(1500))), 1500);
      expect(await p.count(), 1500);
    });

    test('a file with a read pool: big lists on read-only connections, in a transaction and after its rollback', () async {
      await db.close();
      final FluentTestDb file = FluentTestDb(name: 'big_inputs_file_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      providers = relationProviders();
      comments = providers.whereType<CommentProvider>().single;
      await file.open(providers, fluentConfig: const FluentConfig(readConnections: 2));
      await seed();
      // Reads at once: each on a pooled read-only connection with its own temporary table.
      final List<int> counts = await Future.wait([for (int i = 0; i < 6; i++) comments.count(where: FluentFilter.ids(ids(1, 1000 + i * 300)))]);
      expect(counts, [for (int i = 0; i < 6; i++) 1000 + i * 300]);
      Object? error;
      try {
        await FluentDb.transaction(() async {
          expect(await comments.deleteWhere(FluentFilter.ids(ids(1, 2000))), 2000);
          expect(await comments.count(where: FluentFilter.inList('id', ids())), 1000, reason: 'the transaction reads its own delete');
          throw StateError('roll back');
        }, dbKey: file.key);
      } catch (e) {
        error = e;
      }
      expect(error, isA<StateError>());
      expect(await comments.count(where: FluentFilter.ids(ids())), _n, reason: 'the rollback restored every row');
      await FluentDb.transaction(() => comments.updateWhere(FluentFilter.ids(ids()), {'likes': 9}), dbKey: file.key);
      expect(await comments.count(where: FluentFilter.eq('likes', 9)), _n);
      await file.close();
      db = file; // closed again by tearDown (no-op)
    });

    test('big lists inside related(), aggregate and a ranked search', () async {
      final ArticleProvider articles = providers.whereType<ArticleProvider>().single;
      await articles.saveAll([for (final int id in ids(1, 1200)) Article(id: id, title: 'a$id', comments: [Comment(text: 'c$id', likes: id % 3)])]);
      final List<int> commentIds = [for (final Comment c in await comments.findAll()) c.id!];
      expect(await articles.count(where: FluentFilter.related<Comment>('comments', FluentFilter.ids(commentIds.take(1100)))), 1100);
      expect(await articles.count(where: FluentFilter.notRelated<Comment>('comments', FluentFilter.inList('id', commentIds.take(1100).toList()))), 100);
      final List<Map<String, dynamic>> byLikes = await comments.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['likes'], where: FluentFilter.ids(commentIds), orderBy: 'likes');
      expect(byLikes.map((r) => r['n']), [400, 400, 400]);
    });
  });

  group('relations', () {
    test('an article with $_n comments and 2000 tags: save, load, attach, detach, related filters', () async {
      final ArticleProvider articles = providers.whereType<ArticleProvider>().single;
      final TagProvider tags = providers.whereType<TagProvider>().single;
      await tags.saveAll([for (final int id in ids(1, 2000)) Tag(id: id, label: 't$id')]);
      await articles.save(Article(id: 1, title: 'big', comments: [for (final int id in ids()) Comment(text: 'c$id')], tags: [for (final int id in ids(1, 1000)) Tag(id: id, label: 't$id')]));
      Article a = (await articles.findById(1))!;
      expect(a.comments!.length, _n);
      expect(a.tags!.length, 1000);
      await articles.attach(a, 'tags', [for (final int id in ids(1001, 1000)) Tag(id: id, label: 't$id')]);
      expect(await articles.countRelated(a, 'tags'), 2000);
      expect(await articles.count(where: FluentFilter.related<Tag>('tags', FluentFilter.ids(ids(1, 2000)))), 1);
      await articles.detach(a, 'tags', [for (final int id in ids(1, 1500)) Tag(id: id, label: '')]);
      a = await articles.loadRelations(a);
      expect(a.tags!.length, 500);
      expect(await tags.count(), 2000, reason: 'detach removes links, not tags');
    });
  });
}
