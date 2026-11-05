// The public API of 2.0: relation loading levels (FluentLoad), relations loaded later from the model, related and
// parent queries, model-level calls that depend on the model's mixins, key filters, tags and change kinds, lifecycle.
import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show getDatabasesPath;

import '../../helpers/relation_models.dart';
import '../../helpers/schema_models.dart';

class Session extends FluentStorable {
  Session({this.id, required this.token});

  final int? id;
  final String token;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'token': token};
}

class SessionProvider extends FluentProvider<Session> {
  @override
  String get tableName => 'sessions';

  @override
  Session get modelSample => Session(token: '');

  @override
  Session fromCacheJson(Map<String, dynamic> json) => Session(id: json['id'] as int?, token: json['token'] as String);
}

/// Every row of this table lives one hour after its last save.
class CacheEntry extends FluentStorable {
  CacheEntry({this.id, required this.value});

  final int? id;
  final String value;

  @override
  Duration? get timeToLive => const Duration(hours: 1);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'value': value};
}

class CacheProvider extends FluentProvider<CacheEntry> {
  @override
  String get tableName => 'cache';

  @override
  CacheEntry get modelSample => CacheEntry(value: '');

  @override
  CacheEntry fromCacheJson(Map<String, dynamic> json) => CacheEntry(id: json['id'] as int?, value: json['value'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ArticleProvider articles;
  late CommentProvider comments;
  late PersonProvider people;

  setUp(() async {
    db = FluentTestDb(name: 'api_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    final providers = relationProviders();
    await db.open([...providers, SessionProvider(), CacheProvider()]);
    articles = providers.whereType<ArticleProvider>().single;
    comments = providers.whereType<CommentProvider>().single;
    people = providers.whereType<PersonProvider>().single;
  });

  tearDown(() async {
    await db.close();
  });

  Future<Article> seed() async {
    final Person ann = Person(name: 'Ann');
    await FluentDb.saveAll<Article>([
      Article(
        title: 'First',
        author: ann,
        editor: Person(name: 'Bob'),
        comments: [Comment(text: 'c1', likes: 1), Comment(text: 'c2', likes: 7), Comment(text: 'c3')],
        tags: [Tag(label: 'dart'), Tag(label: 'sql')],
      ),
      Article(title: 'Second', author: ann, tags: [Tag(label: 'flutter')]),
    ]);
    return (await FluentDb.findFirst<Article>(where: FluentFilter.eq('title', 'First')))!;
  }

  group('Loading relations', () {
    test('relations: none reads only the row; loadRelations on the model adds them later', () async {
      await seed();
      final Article bare = (await FluentDb.findFirst<Article>(where: FluentFilter.eq('title', 'First'), relations: FluentLoad.none))!;
      expect(bare.author, isNull);
      expect(bare.comments, isNull);
      expect(bare.isRelationLoaded('author'), isFalse);

      final Article full = await bare.loadRelations();
      expect(full.author?.name, 'Ann');
      expect(full.comments!.map((c) => c.text), ['c1', 'c2', 'c3']);
      expect(full.topComments!.map((c) => c.text), ['c2', 'c1'], reason: 'all relations, the lazy ones too');

      final Article some = await bare.loadRelations(names: ['tags']);
      expect(some.tags!.map((t) => t.label), ['dart', 'sql']);
    });

    test('relations: all loads lazy relations with the read', () async {
      await seed();
      final Article eager = (await articles.findFirst(where: FluentFilter.eq('title', 'First')))!;
      expect(eager.topComments, isNull);
      final Article all = (await articles.findFirst(where: FluentFilter.eq('title', 'First'), relations: FluentLoad.all))!;
      expect(all.topComments, hasLength(2));
    });
  });

  group('Related and parent queries', () {
    test('findRelated filters, orders and pages a relation without loading the model', () async {
      final Article a = await seed();
      final List<Comment> liked = await a.findRelated<Comment>('comments', where: FluentFilter.gt('likes', 0), orderBy: 'likes DESC');
      expect(liked.map((c) => c.text), ['c2', 'c1']);
      expect((await a.findRelated<Comment>('comments', limit: 1, offset: 1)).single.text, 'c2', reason: "relation orderBy 'id'");
      expect((await a.findRelated<Tag>('tags')).map((t) => t.label), ['dart', 'sql'], reason: 'many-to-many');
      expect((await a.findRelated<Person>('author')).single.name, 'Ann', reason: 'a reference');
      expect(await a.countRelated('comments'), 3);
      expect(() => articles.findRelated<Tag>(a, 'comments'), throwsA(isA<FluentArgumentException>()));
    });

    test('findParents follows relations backwards: owner, many-to-many, references', () async {
      await seed();
      final Comment c2 = (await comments.findFirst(where: FluentFilter.eq('text', 'c2')))!;
      expect((await c2.findParents<Article>()).single.title, 'First');

      final Tag dart = (await FluentDb.findFirst<Tag>(where: FluentFilter.eq('label', 'dart')))!;
      expect((await dart.findParents<Article>()).single.title, 'First');

      final Person ann = (await people.findFirst(where: FluentFilter.eq('name', 'Ann')))!;
      expect(() => ann.findParents<Article>(), throwsA(isA<FluentRelationException>()), reason: 'author and editor both point to Person');
      expect((await ann.findParents<Article>(via: 'author', orderBy: 'title')).map((a) => a.title), ['First', 'Second']);
      expect(await ann.findParents<Article>(via: 'editor'), isEmpty);
    });

    test('attach / detach on the model', () async {
      final Article a = await seed();
      await a.attach('tags', [Tag(label: 'new')]);
      expect(await a.countRelated('tags'), 3);
      final Tag added = (await FluentDb.findFirst<Tag>(where: FluentFilter.eq('label', 'new')))!;
      await a.detach('tags', [added]);
      expect(await a.countRelated('tags'), 2);
    });
  });

  group('Calls that depend on the model', () {
    test('soft delete: delete, isDeleted, trash and restore on the model', () async {
      final Article a = await seed();
      final Comment c1 = a.comments!.first;
      await c1.delete();
      expect(c1.isDeleted, isTrue);
      expect((await FluentDb.trash<Comment>().find()).single.text, 'c1');
      expect(await c1.restore(), 1);
      expect(c1.isDeleted, isFalse);
      expect(await comments.count(), 3);
    });

    test('FluentFilter.ids and findByIds address rows by key, in the order asked', () async {
      await seed();
      final List<Object?> ids = (await comments.findAll(orderBy: 'id')).map((c) => c.primaryKeyValue).toList();
      expect((await comments.findByIds([ids[2], ids[0], 999])).map((c) => c.text), ['c3', 'c1']);
      expect(await comments.trash.deleteForeverWhere(FluentFilter.ids([ids[0], ids[1]])), 2);
      expect(await comments.count(), 1);
      expect(await comments.count(where: FluentFilter.ids(const [])), 0);
    });

    test('timeToLive on the model: rows expire after it, every save extends it', () async {
      db.clock.set(DateTime(2026, 5, 2, 10));
      await FluentDb.save<CacheEntry>(CacheEntry(id: 1, value: 'a'));
      final Session s = Session(id: 1, token: 't')..timeToLive = const Duration(minutes: 5);
      await s.save();
      expect(await FluentDb.count<CacheEntry>(), 1);

      db.clock.set(DateTime(2026, 5, 2, 10, 30));
      expect(await FluentDb.count<Session>(), 0, reason: '5 minutes are over');
      expect(await FluentDb.count<CacheEntry>(), 1);

      db.clock.set(DateTime(2026, 5, 2, 12));
      expect(await FluentDb.count<CacheEntry>(), 0, reason: 'one hour is over');
      expect(await FluentDb.count<CacheEntry>(includeExpired: true), 1);
    });
  });

  group('Computed updates and existence', () {
    test('increment / decrement / toggle / now are computed by SQLite; parallel increments lose nothing', () async {
      final Article a = await seed();
      final Comment c = a.comments!.first;
      await Future.wait([for (int i = 0; i < 50; i++) comments.updateById(c.primaryKeyValue, {'likes': FluentUpdate.increment()})]);
      expect((await comments.findById(c.primaryKeyValue))!.likes, 51, reason: 'started at 1');
      await comments.updateWhere(FluentFilter.eq('text', 'c2'), {'likes': FluentUpdate.decrement(2)});
      expect((await comments.findFirst(where: FluentFilter.eq('text', 'c2')))!.likes, 5);
      expect(() => comments.updateById(c.primaryKeyValue, {'text': FluentUpdate.increment()}), throwsA(isA<FluentArgumentException>()));
      expect(() => comments.updateById(c.primaryKeyValue, {'likes': FluentUpdate.toggle}), throwsA(isA<FluentArgumentException>()));
    });

    test('toggle flips a bool column and now stores the current time', () async {
      final DynamicProvider flags = DynamicProvider('flags', () => [FluentDbColumn.primary(), FluentDbColumn.boolean('done'), FluentDbColumn.timestamp('seen_at')]);
      await db.open([flags]);
      await flags.save(flags.row(const {'id': 1, 'done': false}));
      db.clock.set(DateTime(2026, 7, 1, 12));
      await flags.updateById(1, {'done': FluentUpdate.toggle, 'seen_at': FluentUpdate.now});
      final Map<String, dynamic> row = (await flags.findMaps()).single;
      expect(row['done'], isTrue);
      expect(row['seen_at'], DateTime(2026, 7, 1, 12));
    });

    test('existsWhere stops at the first matching visible row', () async {
      await seed();
      expect(await comments.existsWhere(FluentFilter.gt('likes', 5)), isTrue);
      expect(await FluentDb.existsWhere<Comment>(FluentFilter.gt('likes', 100)), isFalse);
      final Comment c2 = (await comments.findFirst(where: FluentFilter.eq('text', 'c2')))!;
      await c2.delete();
      expect(await comments.existsWhere(FluentFilter.gt('likes', 5)), isFalse, reason: 'the row is in the trash');
      expect(await comments.withTrash.existsWhere(FluentFilter.gt('likes', 5)), isTrue);
    });
  });

  group('Tags, change kinds, providers', () {
    test('tag: on provider writes reaches the events; kinds filter them', () async {
      final List<String> seen = [];
      final StreamSubscription<FluentChangeEvent<Session>> sub = FluentDb.onEvent<Session>(kinds: {FluentChangeKind.delete}).listen((e) => seen.add('${e.kind.name}:${e.tag}'));
      final SessionProvider sessions = FluentDb.provider<SessionProvider>();
      expect(identical(FluentDb.providerOf<Session>(), sessions), isTrue);

      await sessions.save(Session(id: 1, token: 'a'), tag: 'login');
      await sessions.deleteById(1, tag: 'logout');
      await pumpEventQueue();
      expect(seen, ['delete:logout'], reason: 'the save is filtered out by kinds');
      await sub.cancel();
    });
  });

  group('Lifecycle', () {
    test('clear empties the tables and keeps the database open', () async {
      await seed();
      final List<int> sizes = [];
      final StreamSubscription<List<Comment>> sub = comments.watch().listen((l) => sizes.add(l.length));
      Future<void> until(bool Function() done) async {
        for (int i = 0; i < 100 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await until(() => sizes.isNotEmpty);
      await FluentDb.clear(dbKey: FluentDbKey(db.name));
      await until(() => sizes.last == 0);
      expect(await comments.count(), 0);
      expect(sizes.last, 0, reason: 'watchers get the empty table');
      expect(FluentDb.isOpen(dbKey: FluentDbKey(db.name)), isTrue);
      await sub.cancel();
      await expectLater(FluentDb.clear(dbKey: FluentDbKey('missing')), throwsA(isA<FluentConfigException>()));
    });

    test('clear empties tables whose names look like internal ones, and keeps the bookkeeping tables', () async {
      final DynamicProvider odd = DynamicProvider('myfluent_items', () => [FluentDbColumn.primary(), FluentDbColumn.text('v')]);
      await db.open([odd]);
      await odd.save(DynamicModel(odd.spec, values: const {'id': 1, 'v': 'x'}));
      await FluentDb.clear();
      expect(await odd.count(), 0, reason: '"_" in LIKE matched any character: this table was skipped');
      expect(await odd.rawQuery('SELECT COUNT(*) AS c FROM "__fluent_schema"'), [
        {'c': greaterThan(0)},
      ]);
    });

    test('deleteDatabases deletes the file and opens a fresh database', () async {
      await seed();
      final String path = '${await getDatabasesPath()}/${db.name}.db';
      await FluentDb.deleteDatabases();
      expect(File(path).existsSync(), isTrue, reason: 'reopened right away');
      expect(FluentDb.isOpen(), isTrue);
      expect(await FluentDb.count<Article>(), 0);
      await FluentDb.save<Session>(Session(token: 'next user'));
      expect(await FluentDb.count<Session>(), 1);
    });

    test('restart keeps the data; cleanOrphans and forgetQueryStats run on demand', () async {
      await seed();
      await FluentDb.restart();
      expect(await FluentDb.count<Article>(), 2);
      await FluentDb.cleanOrphans();
      FluentDb.forgetQueryStats(dbKey: FluentDbKey(db.name));
      expect(FluentDb.queryStats(dbKey: FluentDbKey(db.name)).queries, isEmpty);
    });
  });
}
