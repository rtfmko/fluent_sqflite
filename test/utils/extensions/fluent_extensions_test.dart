// The calls on models themselves (active record), the helpers of fluent_extensions.dart, the mixins' columns and
// the name rules of FluentUtils.
@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';

class Stamped extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Stamped({this.id, required this.title});

  int? id;
  String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class StampedProvider extends FluentProvider<Stamped> {
  @override
  String get tableName => 'stamped';

  @override
  Stamped get modelSample => Stamped(title: '');

  @override
  Stamped fromCacheJson(Map<String, dynamic> json) => Stamped(id: json['id'] as int?, title: json['title'] as String)
    ..createdAt = json['created_at'] as DateTime?
    ..updatedAt = json['updated_at'] as DateTime?
    ..deletedAt = json['deleted_at'] as DateTime?;
}

class Lonely extends FluentStorable {
  Lonely({this.id});
  int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'v': 1};
}

class LonelyDeletable extends FluentStorable with FluentSoftDeletable {
  LonelyDeletable({this.id});
  int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'v': 1};
}

class LonelyRelations extends FluentStorable with FluentRelations {
  LonelyRelations({this.id});
  int? id;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'v': 1};

  @override
  List<FluentRelation> get relations => const [];
}

Future<void> expectCode(Future<Object?> f, FluentErrorCode code) async {
  try {
    await f;
    fail('expected a FluentException with $code');
  } on FluentException catch (e) {
    expect(e.code, code);
    expect(e.hint, isNotNull, reason: 'what, why and how to fix');
  }
}

void main() {
  setUpFluentTests();

  group('FluentUtils names', () {
    test('toSnakeCase: words, acronyms, digits, separators, leading underscore', () {
      const Map<String, String> cases = {
        'UserName': 'user_name',
        'userName': 'user_name',
        'HTTPServer': 'http_server',
        'userID': 'user_id',
        'item2Box': 'item2_box',
        'Item2': 'item2',
        'Box<Note>': 'box_note',
        'Map<String, int>': 'map_string_int',
        '_Draft': '_draft',
        'a__b': 'a_b',
        'trail_': 'trail',
        '': '',
        'already_snake': 'already_snake',
        'ABC': 'abc',
        'a b': 'a_b',
      };
      cases.forEach((String input, String expected) => expect(FluentUtils.toSnakeCase(input), expected, reason: input));
    });

    test('legacySnakeCase and withLegacyNames follow the 1.x rule', () {
      expect(FluentUtils.legacySnakeCase('Item2'), 'item_2');
      expect(FluentUtils.legacySnakeCase('HTTPServer'), 'h_t_t_p_server');
      expect(FluentUtils.legacySnakeCase('Box<Note>'), 'box_<_note_>');
      expect(FluentUtils.legacySnakeCase('_Draft'), '_draft');
      expect(FluentUtils.legacySnakeCase(''), '');
      expect(FluentUtils.withLegacyNames(() => FluentUtils.toSnakeCase('HTTPServer')), 'h_t_t_p_server');
      expect(FluentUtils.toSnakeCase('HTTPServer'), 'http_server', reason: 'only inside the zone');
    });
  });

  group('helpers of fluent_extensions.dart', () {
    test('tryGetDateTime: int, ISO text, missing, null, other types, bad text', () {
      final Map<String, dynamic> json = {'ms': 1777755600000, 'iso': '2026-05-03T12:00:00Z', 'nul': null, 'num': 1.5, 'bad': 'nope'};
      expect(json.tryGetDateTime('ms'), DateTime.fromMillisecondsSinceEpoch(1777755600000));
      expect(json.tryGetDateTime('iso'), DateTime.utc(2026, 5, 3, 12));
      expect(json.tryGetDateTime('missing'), isNull);
      expect(json.tryGetDateTime('nul'), isNull);
      expect(json.tryGetDateTime('num'), isNull);
      expect(json.tryGetDateTime('bad'), isNull);
    });

    test('ANSI colors wrap the text and reset', () {
      expect('x'.red, '\x1B[31mx\x1B[0m');
      expect('x'.green, '\x1B[32mx\x1B[0m');
      expect('x'.yellow, '\x1B[33mx\x1B[0m');
      expect('x'.cyan, '\x1B[36mx\x1B[0m');
      expect('x'.magenta, '\x1B[35mx\x1B[0m');
      expect('x'.gold, '\x1B[93mx\x1B[0m');
    });

    test('toFluentTimestamp pads every part', () {
      expect(DateTime(2026, 1, 2, 3, 4, 5, 6).toFluentTimestamp, '03:04:05.006');
      expect(DateTime(2026, 1, 2, 13, 14, 15, 123).toFluentTimestamp, '13:14:15.123');
    });

    test('ExecutionPolicy: defaults, effectivePriority, merge, flatten', () {
      expect(ExecutionPolicyUtils.defaults, const ExecutionPolicy(priority: 0, cancelIfDuplicate: true));
      expect(const ExecutionPolicy().effectivePriority, 0);
      expect(const ExecutionPolicy(priority: 4).effectivePriority, 4);
      const ExecutionPolicy own = ExecutionPolicy(priority: 2);
      expect(own.merge(null), own);
      expect(own.merge(const ExecutionPolicy(priority: 9, cancelIfDuplicate: false)), const ExecutionPolicy(priority: 2, cancelIfDuplicate: false));
      expect(own.flatten(), const ExecutionPolicy(priority: 2, cancelIfDuplicate: true));
      expect(const ExecutionPolicy(cancelIfDuplicate: false).flatten(), const ExecutionPolicy(priority: 0, cancelIfDuplicate: false));
    });
  });

  group('mixins', () {
    test('FluentTimestamps and FluentSoftDeletable: columns, names, isDeleted', () {
      final Stamped s = Stamped(title: 't');
      expect(s.createdAtColumn, 'created_at');
      expect(s.updatedAtColumn, 'updated_at');
      expect(s.softDeleteColumn, 'deleted_at');
      expect(s.createdAt, isNull);
      expect(s.isDeleted, isFalse);
      s.deletedAt = DateTime(2026);
      expect(s.isDeleted, isTrue);
      expect(s.buildJson().keys, ['id', 'title'], reason: 'library columns are not part of buildJson');
    });
  });

  group('active record calls', () {
    late FluentTestDb db;

    setUp(() async {
      db = FluentTestDb();
      await db.open([...relationProviders(), StampedProvider()]);
    });

    tearDown(() => db.close());

    test('save / update / exists / refresh / delete on a plain model', () async {
      final Person ann = Person(name: 'Ann');
      final FluentSaveResult r = await ann.save();
      expect(r, isNotNull);
      expect(ann.primaryKeyValue, isNotNull, reason: 'the generated key is injected');
      expect(await ann.exists(), isTrue);
      expect(await ann.update(), 1);
      expect(await Person(id: 999, name: 'ghost').update(), 0, reason: 'update never inserts');
      expect(await Person(id: 999, name: 'ghost').exists(), isFalse);
      expect((await ann.refresh())!.name, 'Ann');
      expect(await ann.delete(), 1);
      expect(await ann.delete(), 0);
      expect(await ann.refresh(), isNull);
      expect(await ann.exists(), isFalse);
    });

    test('save with strategy, tag, policy, dbKey; update with relations', () async {
      final Person ann = Person(name: 'Ann');
      await ann.save(strategy: FluentSaveStrategy.insertOnly, tag: 'first', policy: const ExecutionPolicy(priority: 3), dbKey: db.key);
      expect(await ann.update(withRelations: true, syncMode: FluentRelationSyncMode.replace, tag: 't', dbKey: db.key), 1);
      expect(await ann.exists(includeExpired: true, dbKey: db.key), isTrue);
      expect((await ann.refresh(relations: FluentLoad.none, dbKey: db.key))!.name, 'Ann');
    });

    test('soft-deletable model: delete goes to the trash, restore brings it back, deleteForever removes it', () async {
      final Stamped s = Stamped(title: 'a');
      await s.save();
      expect(await s.delete(), 1);
      expect(s.isDeleted, isTrue, reason: 'deletedAt holds the stored stamp after the commit');
      expect(await s.exists(), isFalse);
      expect(await s.refresh(), isNull);
      expect(await s.restore(tag: 'r'), 1);
      expect(s.isDeleted, isFalse);
      expect(await s.exists(), isTrue);
      expect(await s.restore(), 0, reason: 'nothing in the trash');
      expect(await s.deleteForever(), 1);
      expect(await s.deleteForever(), 0);
      expect(await s.exists(), isFalse);
    });

    test('deleteForever works on a trashed model', () async {
      final Stamped s = Stamped(title: 'a');
      await s.save();
      await s.delete();
      expect(await s.deleteForever(policy: const ExecutionPolicy(priority: 1), dbKey: db.key), 1);
      expect(await FluentDb.trash<Stamped>().find(), isEmpty);
    });

    test('timestamps are written by the library on save and update', () async {
      final Stamped s = Stamped(title: 'a');
      await s.save();
      final Stamped first = (await s.refresh())!;
      expect(first.createdAt, isNotNull);
      expect(first.updatedAt, isNotNull);
      db.clock.advance(const Duration(minutes: 5));
      s.title = 'b';
      await s.save();
      final Stamped second = (await s.refresh())!;
      expect(second.title, 'b');
      expect(second.createdAt, first.createdAt, reason: 'created_at is set once');
      expect(second.updatedAt!.isAfter(first.updatedAt!), isTrue);
    });

    test('relation calls: loadRelations, findRelated, countRelated, findParents, attach, detach', () async {
      final Article article = Article(
        title: 'A',
        author: Person(name: 'Ann'),
        comments: [Comment(text: 'c1', likes: 1), Comment(text: 'c2', likes: 5)],
        tags: [Tag(label: 'dart')],
      );
      await article.save();

      final Article bare = (await article.refresh(relations: FluentLoad.none))!;
      expect(bare.comments, isNull);
      final Article full = await bare.loadRelations(names: ['comments'], maxDepth: 1, dbKey: db.key);
      expect(full.comments!.map((c) => c.text), ['c1', 'c2']);

      final List<Comment> top = await full.findRelated<Comment>('comments', where: FluentFilter.gt('likes', 0), orderBy: 'likes DESC', limit: 1, offset: 0, relations: FluentLoad.none, dbKey: db.key);
      expect(top.map((c) => c.text), ['c2']);
      expect(await full.countRelated('comments'), 2);
      expect(await full.countRelated('comments', dbKey: db.key), 2);

      final List<Article> parents = await full.comments!.first.findParents<Article>(via: 'comments', where: FluentFilter.eq('title', 'A'), orderBy: 'id', limit: 5, offset: 0, relations: FluentLoad.none, dbKey: db.key);
      expect(parents.single.title, 'A');
      expect((await full.comments!.first.findParents<Article>()).single.title, 'A');

      await full.attach('tags', [Tag(label: 'sql')]);
      expect(await full.countRelated('tags'), 2);
      final List<Tag> tags = await full.findRelated<Tag>('tags', orderBy: 'label');
      await full.detach('tags', [tags.first], dbKey: db.key);
      expect(await full.countRelated('tags'), 1);
    });

    test('collections: saveAll, updateAll, deleteAll', () async {
      final List<Person> people = [Person(name: 'a'), Person(name: 'b'), Person(name: 'c')];
      final FluentSaveResult r = await people.saveAll(tag: 'bulk', dbKey: db.key);
      expect(r, isNotNull);
      expect(await FluentDb.count<Person>(), 3);
      expect(await people.updateAll(withRelations: true, syncMode: FluentRelationSyncMode.replace), 3);
      expect(await <Person>[].saveAll(), isNotNull, reason: 'empty is fine');
      expect(await <Person>[].updateAll(), 0);
      expect(await <Person>[].deleteAll(), 0);
      expect(await people.take(2).deleteAll(policy: const ExecutionPolicy(priority: 1)), 2);
      expect(await FluentDb.count<Person>(), 1);
    });
  });

  group('performance', () {
    test('saveAll of N models is a batch, not one statement per model', () async {
      final QueryCounter counter = await QueryCounter.install();
      try {
        final FluentTestDb db = FluentTestDb();
        await db.open(relationProviders());
        final List<Person> people = [for (int i = 0; i < 50; i++) Person(name: 'p$i')];
        counter.reset();
        await people.saveAll();
        expect(counter.reads + counter.writes, lessThan(people.length), reason: 'batched, not one statement per model');
        await db.close();
      } finally {
        counter.uninstall();
      }
    });
  });

  group('errors through the Future', () {
    late FluentTestDb db;

    setUp(() async {
      db = FluentTestDb();
      await db.open([...relationProviders(), StampedProvider()]);
    });

    tearDown(() => db.close());

    test('a model without a provider: every call fails with providerNotFound, never throws synchronously', () async {
      final Lonely m = Lonely(id: 1);
      await expectCode(m.save(), FluentErrorCode.providerNotFound);
      await expectCode(m.update(), FluentErrorCode.providerNotFound);
      await expectCode(m.exists(), FluentErrorCode.providerNotFound);
      await expectCode(m.delete(), FluentErrorCode.providerNotFound);
      await expectCode(m.refresh(), FluentErrorCode.providerNotFound);
      await expectCode([m].saveAll(), FluentErrorCode.providerNotFound);
      await expectCode([m].updateAll(), FluentErrorCode.providerNotFound);
      await expectCode([m].deleteAll(), FluentErrorCode.providerNotFound);
    });

    test('soft-deletable and relation models without a provider', () async {
      final LonelyDeletable d = LonelyDeletable(id: 1);
      await expectCode(d.restore(), FluentErrorCode.providerNotFound);
      await expectCode(d.deleteForever(), FluentErrorCode.providerNotFound);
      final LonelyRelations r = LonelyRelations(id: 1);
      await expectCode(r.loadRelations(), FluentErrorCode.providerNotFound);
      await expectCode(r.findRelated<Tag>('x'), FluentErrorCode.providerNotFound);
      await expectCode(r.countRelated('x'), FluentErrorCode.providerNotFound);
      await expectCode(r.attach('x', []), FluentErrorCode.providerNotFound);
      await expectCode(r.detach('x', []), FluentErrorCode.providerNotFound);
      await expectCode(Comment(text: 'c').findParents<Article>(via: 'nope'), FluentErrorCode.invalidRelation);
    });

    test('an unknown database key fails with providerNotFound', () async {
      await expectCode(Person(name: 'a').save(dbKey: FluentDbKey('nowhere')), FluentErrorCode.providerNotFound);
    });

    test('before init: notInitialized or providerNotFound, still through the Future', () async {
      await db.close();
      final Future<Object?> f = Person(name: 'a').save();
      await expectLater(f, throwsA(isA<FluentException>()));
    });
  });
}
