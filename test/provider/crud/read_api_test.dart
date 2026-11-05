// Every read method sees the same rows: soft-deleted rows are hidden everywhere except the trash (`trash`, `withTrash`).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late CommentProvider comments;
  late Comment alive;
  late Comment dead;

  setUp(() async {
    db = FluentTestDb(name: 'read_api_${DateTime.now().microsecondsSinceEpoch}');
    comments = CommentProvider();
    await db.open([comments]);
    alive = Comment(text: 'alive', likes: 1);
    dead = Comment(text: 'dead', likes: 2);
    await comments.saveAll([alive, dead]);
    await comments.delete(dead);
  });

  tearDown(() => db.close());

  test('model reads hide soft-deleted rows', () async {
    expect((await comments.findAll()).map((c) => c.text), ['alive']);
    expect((await comments.findFirst())?.text, 'alive');
    expect(await comments.findById(dead.primaryKeyValue), isNull);
    expect((await comments.findById(alive.primaryKeyValue))?.text, 'alive');
    expect(await comments.find(where: FluentFilter.eq('text', 'dead')), isEmpty);
    expect(await comments.find(where: FluentFilter.gt('likes', 0)), hasLength(1));
  });

  test('exists and count agree with the model reads', () async {
    expect(await comments.exists(dead.primaryKeyValue), isFalse);
    expect(await comments.exists(alive.primaryKeyValue), isTrue);
    expect(await comments.count(), 1);
  });

  test('map reads hide them too; trash.find is the trash', () async {
    expect(await comments.findMaps(where: FluentFilter.eq('text', 'dead')), isEmpty);
    expect((await comments.trash.find()).map((c) => c.text), ['dead']);
  });

  test('restoring brings a row back to every read', () async {
    await comments.trash.restoreById(dead.primaryKeyValue);
    expect(await comments.exists(dead.primaryKeyValue), isTrue);
    expect((await comments.findAll(orderBy: 'text')).map((c) => c.text), ['alive', 'dead']);
  });

  test('the FluentDb facade passes ordering and filters through', () async {
    await comments.trash.restoreById(dead.primaryKeyValue);
    expect((await FluentDb.findAll<Comment>(orderBy: 'likes DESC')).map((c) => c.text), ['dead', 'alive']);
    expect((await FluentDb.find<Comment>(where: FluentFilter.gt('likes', 1))).map((c) => c.text), ['dead']);
    expect((await FluentDb.findFirst<Comment>(orderBy: 'likes'))?.text, 'alive');
    expect((await FluentDb.find<Comment>(orderBy: 'likes', limit: 1, offset: 1)).map((c) => c.text), ['dead']);
  });

  test('orderBy names columns only: user input can never run SQL', () async {
    final FluentTestDb db = FluentTestDb(name: 'order_by');
    final PersonProvider people = PersonProvider();
    await db.open([people]);
    await people.saveAll([Person(name: 'b'), Person(name: 'A')]);

    for (final String ok in ['name', 'name DESC, id', '"name" COLLATE NOCASE ASC', 'lower(name) NULLS LAST', 'people.name', 'RANDOM()']) {
      expect(await people.find(orderBy: ok), hasLength(2), reason: ok);
    }
    for (final String bad in ['name; DROP TABLE people', '(SELECT name FROM people LIMIT 1)', 'name -- x', 'CASE WHEN 1 THEN name END']) {
      await expectLater(people.find(orderBy: bad), throwsA(isA<FluentArgumentException>()), reason: bad);
    }
    await db.close();
  });
}
