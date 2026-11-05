// Reactivity: events for every table a call changes, relation operations in the engine, watchById, cost model.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ArticleProvider articles;
  late CommentProvider comments;
  late TagProvider tags;

  setUp(() async {
    db = FluentTestDb(name: 'react_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    final List<FluentProvider> providers = relationProviders();
    await db.open(providers);
    articles = providers.whereType<ArticleProvider>().single;
    comments = providers.whereType<CommentProvider>().single;
    tags = providers.whereType<TagProvider>().single;
  });

  tearDown(() => db.close());

  /// How many times [stream] emitted because of [action] (the first emission is not counted).
  Future<int> updates(Stream<Object?> stream, Future<void> Function() action) async {
    int n = 0;
    final StreamSubscription<Object?> sub = stream.listen((_) => n++);
    await db.settle();
    final int before = n;
    await action();
    await db.settle();
    await sub.cancel();
    return n - before;
  }

  test('saving a graph, attach, detach and cascades notify the related tables', () async {
    final List<String> events = [];
    final StreamSubscription<FluentChangeEvent<FluentStorable>> sub = FluentDb.onEvent<FluentStorable>().listen((e) => events.add('${e.modelType}.${e.kind.name}'));

    expect(await updates(comments.watch(), () => articles.save(Article(title: 'a', comments: [Comment(text: 'c1')], tags: [Tag(label: 't')]))), 1);
    expect(events, containsAll(['Article.save', 'Comment.save', 'Tag.save']));

    final Article a = (await articles.findAll()).single;
    expect(await updates(comments.watch(), () => articles.attach(a, 'comments', [Comment(text: 'c2')])), 1);
    expect(await updates(tags.watch(), () => articles.detach(a, 'tags', a.tags!)), 1, reason: 'the link rows of the tag changed');

    events.clear();
    expect(await updates(comments.watch(), () => articles.delete(a)), 1, reason: 'comments were deleted by the foreign key cascade');
    expect(events, containsAll(['Article.delete', 'Comment.delete']));
    await sub.cancel();
  });

  test('raw SQL that changes rows notifies the table; other SQL does not', () async {
    expect(await updates(comments.watch(), () => comments.execute("INSERT INTO comments (text, likes) VALUES ('raw', 0)")), 1);
    expect(await updates(comments.watch(), () => comments.execute('PRAGMA user_version = 3')), 0);
  });

  test('relation operations keep call order with queued writes', () async {
    final Article b = Article(title: 'b');
    await articles.save(b);
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    unawaited(
      FluentDb.transaction(() async {
        started.complete();
        await release.future;
      }),
    );
    await started.future;
    unawaited(comments.save(Comment(text: 'late')..injectRelationId('article_id', b.primaryKeyValue)));
    final Future<int> counted = articles.countRelated(b, 'comments');
    release.complete();
    expect(await counted, 1);
  });

  test('watchById follows one model', () async {
    final Article a = Article(title: 'a');
    final Article other = Article(title: 'other');
    await articles.saveAll([a, other]);

    final List<String?> seen = [];
    final StreamSubscription<Article?> sub = articles.watchById(a.primaryKeyValue).listen((m) => seen.add(m?.title));
    await db.settle();
    await articles.save(Article(id: other.primaryKeyValue as int, title: 'other 2'));
    await db.settle();
    expect(seen, ['a'], reason: 'another row changed');

    await articles.updateById(a.primaryKeyValue, {'title': 'a2'});
    await db.settle();
    await articles.delete(a);
    await db.settle();
    expect(seen, ['a', 'a2', null]);
    await sub.cancel();
  });

  test('query costs are measured per shape and written to the own stats table of the database on close', () async {
    for (int i = 0; i < 4; i++) {
      await comments.find(where: FluentFilter.eq('likes', i));
    }
    final FluentQueryCost? cost = FluentDb.engineStats().slowestQueries.where((c) => c.table == 'comments' && c.shape.contains('"likes" = ?')).firstOrNull;
    expect(cost, isNotNull, reason: 'one shape for all values of "likes"');
    expect(cost!.samples, greaterThanOrEqualTo(4));
    expect(cost.shape, isNot(contains('deleted_at')), reason: "the library's own visibility conditions are not part of the shape");
    expect(FluentDb.report().toString(), isNotEmpty);

    await db.close(keepFile: true);
    final Database file = await databaseFactoryFfi.openDatabase(join(await getDatabasesPath(), '${db.name}.db'));
    final List<Map<String, Object?>> rows = await file.query('__fluent_stats', where: 'tbl = ? AND action = ?', whereArgs: ['comments', 'find']);
    await file.close();
    expect(rows, isNotEmpty);
    expect(rows.first['avg_rows'], 0, reason: 'the rows a read returned are kept too');
  });
}
