// Audit probes for the public CRUD API (reads, aggregates, trash, raw SQL, watch streams).
// A failing test marks a suspected defect; the expectation is the correct behaviour.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

class Note extends FluentStorable with FluentSoftDeletable {
  Note({this.id, required this.title, this.score});

  final int? id;
  final String title;
  final int? score;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'score': score};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('title'), FluentDbColumn.integer('score')];
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(title: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, title: json['title'] as String, score: json['score'] as int?);
}

/// A table with a column the model does not carry (buildJson leaves it out).
class Wide extends FluentStorable {
  Wide({this.id, this.name});

  final int? id;
  final String? name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.integer('secret')];
}

class WideProvider extends FluentProvider<Wide> {
  @override
  String get tableName => 'wide';

  @override
  Wide get modelSample => Wide();

  @override
  Wide fromCacheJson(Map<String, dynamic> json) => Wide(id: json['id'] as int?, name: json['name'] as String?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider posts;
  late NoteProvider notes;
  late WideProvider wide;

  setUp(() async {
    db = FluentTestDb(name: 'crud_${DateTime.now().microsecondsSinceEpoch}');
    posts = DynamicProvider('posts', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('score'), FluentDbColumn.text('title')]);
    notes = NoteProvider();
    wide = WideProvider();
    await db.open([posts, notes, wide]);
  });

  tearDown(() => db.close());

  DynamicModel post(int id, int? score, [String title = 't']) => posts.row({'id': id, 'score': score, 'title': title});

  group('findByIds', () {
    test('keeps the order of the ids across chunks, skips missing and null ids, repeats duplicates', () async {
      await posts.saveAll([for (int i = 1; i <= 2000; i++) post(i, i % 7)]);
      final List<Object?> ids = [for (int i = 2500; i >= 1; i--) i, null, 5, 5];
      final List<DynamicModel> found = await posts.findByIds(ids);
      expect([for (final m in found) m.values['id']], [for (final Object? i in ids) if (i != null && (i as int) <= 2000) i]);
    });

    test('withTrash.findByIds sees trashed rows in every chunk; findByIds hides them', () async {
      await notes.saveAll([for (int i = 1; i <= 1500; i++) Note(id: i, title: 'n$i')]);
      for (int i = 2; i <= 1500; i += 2) {
        await notes.deleteById(i);
      }
      final List<int> all = [for (int i = 1; i <= 1500; i++) i];
      expect((await notes.findByIds(all)).length, 750);
      expect((await notes.withTrash.findByIds(all)).length, 1500);
    });
  });

  group('aggregates', () {
    test('empty table: counts are 0, sum is 0, avg / min / max are null', () async {
      expect(await posts.count(), 0);
      expect(await posts.sum('score'), 0);
      expect(await posts.avg('score'), isNull);
      expect(await posts.min<int>('score'), isNull);
      expect(await posts.max<int>('score'), isNull);
      expect(await posts.countDistinct('score'), 0);
      expect(await posts.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['score']), isEmpty);
      expect(await posts.aggregate(values: {'n': const FluentAggregate.count(), 's': const FluentAggregate.sum('score')}), [
        {'n': 0, 's': 0},
      ]);
    });

    test('NULLs are ignored by sum / avg / min / max / countDistinct; count(column) skips them', () async {
      await posts.saveAll([post(1, 4), post(2, null), post(3, 8), post(4, null), post(5, 8)]);
      expect(await posts.sum('score'), 20);
      expect(await posts.avg('score'), closeTo(20 / 3, 1e-9));
      expect(await posts.min<int>('score'), 4);
      expect(await posts.max<int>('score'), 8);
      expect(await posts.countDistinct('score'), 2);
      expect((await posts.aggregate(values: {'n': const FluentAggregate.count('score'), 'all': const FluentAggregate.count()})).single, {'n': 3, 'all': 5});
    });

    test('filters apply to every value; having and orderBy work on result names', () async {
      await posts.saveAll([post(1, 1), post(2, 2), post(3, 2), post(4, 3), post(5, 3), post(6, 3)]);
      final List<Map<String, dynamic>> rows = await posts.aggregate(
        groupBy: ['score'],
        values: {'n': const FluentAggregate.count(), 'total': const FluentAggregate.sum('id')},
        where: FluentFilter.gt('id', 1),
        having: FluentFilter.gte('n', 2),
        orderBy: 'score DESC',
      );
      expect(rows, [
        {'score': 3, 'n': 3, 'total': 15},
        {'score': 2, 'n': 2, 'total': 5},
      ]);
      expect(await posts.sum('score', where: FluentFilter.eq('score', 99)), 0);
    });

    test('sum of a text column and orderBy naming a table column that is not a result are refused', () async {
      await posts.saveAll([post(1, 1, 'a')]);
      await expectLater(posts.sum('title'), throwsA(isA<FluentArgumentException>()));
      await expectLater(posts.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['score'], orderBy: 'title'), throwsA(isA<FluentArgumentException>()));
      await expectLater(posts.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['score'], orderBy: 'score; DELETE FROM posts'), throwsA(isA<FluentArgumentException>()));
    });

    test('pluck refuses a NULL for a non-nullable type and accepts it for a nullable one', () async {
      await posts.saveAll([post(1, 1), post(2, null)]);
      await expectLater(posts.pluck<int>('score', orderBy: 'id'), throwsA(isA<FluentArgumentException>()));
      expect(await posts.pluck<int?>('score', orderBy: 'id'), [1, null]);
    });
  });

  group('soft delete reads', () {
    test('a second delete keeps the first stamp; reads hide the trash; the trash scope shows it', () async {
      final Note n = Note(title: 'a');
      await notes.save(n);
      expect(await notes.delete(n), 1);
      final DateTime? first = n.deletedAt;
      expect(first, isNotNull);
      expect(await notes.delete(n), 0);
      expect(n.deletedAt, first);
      expect(await notes.count(), 0);
      expect(await notes.exists(n.primaryKeyValue), isFalse);
      expect(await notes.sum('id'), 0);
      expect(await notes.withTrash.count(), 1);
      expect(await notes.trash.count(), 1);
    });

    test('findPage walks live rows exactly once when trashed rows sit between them', () async {
      await notes.saveAll([for (int i = 1; i <= 30; i++) Note(id: i, title: 'n$i', score: i % 3)]);
      for (int i = 1; i <= 30; i += 4) {
        await notes.deleteById(i);
      }
      final List<Object?> seen = [];
      FluentCursor? after;
      do {
        final FluentPage<Note> p = await notes.findPage(orderBy: 'score', limit: 4, after: after);
        seen.addAll([for (final Note m in p.items) m.id]);
        after = p.next;
      } while (after != null);
      final List<Map<String, Object?>> expected = await posts.db.rawQuery('SELECT id FROM notes WHERE deleted_at IS NULL ORDER BY score ASC, id ASC');
      expect(seen, [for (final r in expected) r['id']]);
    });
  });

  group('findPage', () {
    test('an ordering column the model does not carry is refused before any page is read', () async {
      await wide.saveAll([Wide(id: 1, name: 'a'), Wide(id: 2, name: 'b')]);
      await expectLater(wide.findPage(orderBy: 'secret', limit: 10), throwsA(isA<FluentArgumentException>()));
    });
  });

  group('raw SQL', () {
    test('read-only statements run; statements that change data or settings are refused', () async {
      await posts.saveAll([post(1, 1)]);
      expect(await posts.rawQuery('SELECT 1 AS one -- ;\n'), [
        {'one': 1},
      ]);
      expect(await posts.rawQuery('WITH c AS (SELECT 2 AS x) SELECT x FROM c'), [
        {'x': 2},
      ]);
      expect(await posts.rawQuery('PRAGMA table_info("posts")'), isNotEmpty);
      expect(await posts.rawQuery('/* ; */ SELECT COUNT(*) AS n FROM posts;'), [
        {'n': 1},
      ]);
      for (final String sql in [
        'SELECT 1; DELETE FROM posts',
        'WITH c AS (SELECT 1) DELETE FROM posts',
        'PRAGMA user_version = 3',
        '/* note */ INSERT INTO posts (id) VALUES (99)',
        '-- x\nUPDATE posts SET score = 0',
        'PRAGMA journal_mode(WAL)',
        'REPLACE INTO posts (id) VALUES (98)',
        'VACUUM',
        'DELETE FROM posts',
      ]) {
        await expectLater(posts.rawQuery(sql), throwsA(isA<FluentArgumentException>()), reason: sql);
      }
      expect(await posts.count(), 1);
    });

    test('execute publishes a change for writes (also after a comment) and not for DDL or PRAGMA', () async {
      await posts.saveAll([post(1, 1)]);
      final List<int> emissions = [];
      final sub = posts.watchValue(() => posts.count()).listen(emissions.add);
      await db.settle();
      await posts.execute("/* bulk */ INSERT INTO posts (id, score, title) VALUES (2, 2, 'x')");
      await db.settle();
      expect(emissions.last, 2);
      final int before = emissions.length;
      await posts.execute('CREATE INDEX IF NOT EXISTS ix_posts_title ON posts (title)');
      await posts.execute('PRAGMA user_version = 1');
      await db.settle();
      expect(emissions.length, before);
      await sub.cancel();
    });
  });

  group('more probes', () {
    test('pluck distinct keeps one NULL and orders it first ascending; aggregate groups NULL with min', () async {
      await posts.saveAll([post(1, 1, 'b'), post(2, 1, 'a'), post(3, null, 'c'), post(4, 2, 'd'), post(5, null, 'e')]);
      expect(await posts.pluck<int?>('score', distinct: true, orderBy: 'score'), [null, 1, 2]);
      final List<Map<String, dynamic>> rows = await posts.aggregate(groupBy: ['score'], values: {'first': const FluentAggregate.min('title')}, orderBy: 'score');
      expect(rows, [
        {'score': null, 'first': 'c'},
        {'score': 1, 'first': 'a'},
        {'score': 2, 'first': 'd'},
      ]);
    });

    test('updateById and refresh ignore trashed rows; watchById follows delete and restore', () async {
      final Note n = Note(title: 'a', score: 1);
      await notes.save(n);
      final List<Note?> seen = [];
      final sub = notes.watchById(n.primaryKeyValue).listen(seen.add);
      await db.settle();
      expect(seen.last?.title, 'a');
      await n.delete();
      await db.settle();
      expect(seen.last, isNull);
      expect(await notes.updateById(n.primaryKeyValue, {'title': 'changed'}), 0);
      expect(await n.refresh(), isNull);
      await notes.trash.restore(n);
      await db.settle();
      expect(seen.last?.title, 'a');
      await sub.cancel();
    });
  });

  group('watch set-based writes', () {
    test('a set-based write that changes no visible row does not re-emit the result', () async {
      await posts.saveAll([post(1, 1)]);
      final List<List<DynamicModel>> emitted = [];
      final sub = posts.watch(where: FluentFilter.eq('score', 1)).listen(emitted.add);
      await db.settle();
      expect(emitted, hasLength(1));
      await posts.updateWhere(FluentFilter.eq('score', 99), {'title': 'x'});
      await posts.deleteWhere(FluentFilter.eq('id', 1000));
      await db.settle();
      expect(emitted, hasLength(1), reason: 'nothing changed: the result is the same list');
      await sub.cancel();
    });
  });

  group('watch', () {
    test('emits for relevant changes only and stops after cancel', () async {
      await posts.saveAll([post(1, 1)]);
      final List<List<DynamicModel>> emitted = [];
      final sub = posts.watch(where: FluentFilter.eq('score', 1)).listen(emitted.add);
      await db.settle();
      expect(emitted, hasLength(1));
      await posts.save(post(50, 2)); // not matching: no emission
      await db.settle();
      expect(emitted, hasLength(1));
      await posts.save(post(51, 1)); // matching
      await db.settle();
      expect(emitted.last.map((m) => m.values['id']).toList(), [1, 51]);
      await sub.cancel();
      final int count = emitted.length;
      await posts.save(post(52, 1));
      await db.settle();
      expect(emitted.length, count);
    });

    test('a failing query is delivered as a stream error', () async {
      await posts.saveAll([post(1, 1)]);
      await expectLater(posts.watch(where: FluentFilter.eq('nope', 1)), emitsError(isA<FluentException>()));
    });

    test('watchById with an id that does not fit the key is a stream error; trash.watch follows deletes', () async {
      await expectLater(posts.watchById(FluentKey({'nope': 1})), emitsError(isA<FluentException>()));
      final List<List<Note>> trashed = [];
      final sub = notes.trash.watch().listen(trashed.add);
      await db.settle();
      final Note n = Note(title: 'x');
      await notes.save(n);
      await notes.delete(n);
      await db.settle();
      expect(trashed.last.map((m) => m.title).toList(), ['x']);
      await sub.cancel();
    });
  });
}
