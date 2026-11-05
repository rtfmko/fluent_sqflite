// Regression tests for audit 1 in FIXED_ISSUES.md (the numbers are the items of that list). Each test failed (or could not be
// written) before its fix.
import 'dart:ui' show Locale;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';

/// Converter that fails on negative numbers (a value of its Dart type it cannot store).
class _StrictConverter extends FluentConverter<int, String> {
  const _StrictConverter();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(int value) => value < 0 ? throw const FormatException('negative') : 'n$value';

  @override
  int fromSql(String value) => int.parse(value.substring(1));
}

/// A model whose buildJson returns an unmodifiable map.
class _FrozenModel extends DynamicModel {
  _FrozenModel(super.spec, {super.values});

  @override
  Map<String, dynamic> buildJson() => Map.unmodifiable(values);
}

class _FrozenProvider extends DynamicProvider {
  _FrozenProvider() : super('frozen', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);

  @override
  DynamicModel row(Map<String, dynamic> values) => _FrozenModel(spec, values: values);
}

/// A provider whose factory throws something other than a TypeError.
class _ThrowingFactoryProvider extends DynamicProvider {
  _ThrowingFactoryProvider() : super('throwing', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) => throw const FormatException('bad row');
}

// --- 58: tables and columns sqflite's own helpers would not quote -------------------------------------------------

class _OddPeople extends PersonProvider {
  @override
  String get tableName => 'my people';
}

class _OddArticles extends ArticleProvider {
  @override
  String get tableName => 'my-articles';
}

class _OddComments extends CommentProvider {
  @override
  String get tableName => 'my "comments"';
}

class _OddTags extends TagProvider {
  @override
  String get tableName => 'my tags';
}

class _OddItem extends FluentStorable with FluentSoftDeletable {
  _OddItem({this.id, required this.name});
  final int? id;
  final String name;
  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('full name')];
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'full name': name};
}

class _OddItems extends FluentProvider<_OddItem> with FluentSyncable<_OddItem> {
  @override
  String get tableName => 'sync items';
  @override
  _OddItem get modelSample => _OddItem(name: '');
  @override
  _OddItem fromCacheJson(Map<String, dynamic> json) => _OddItem(id: json['id'] as int?, name: json['full name'] as String);
}

// --- 12: two owners list the same model, each with its own column --------------------------------------------------

class Post extends FluentStorable {
  Post({this.id, this.notes = const []});
  final int? id;
  final List<Note> notes;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'notes': notes};
}

class Photo extends FluentStorable {
  Photo({this.id, this.notes = const []});
  final int? id;
  final List<Note> notes;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'notes': notes};
}

class Note extends FluentStorable {
  Note({this.id, this.text = ''});
  final int? id;
  final String text;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.primary(), FluentDbColumn.text('text'), FluentDbColumn.integer('post_id'), FluentDbColumn.integer('photo_id')];
}

class PostProvider extends FluentProvider<Post> {
  @override
  String get tableName => 'posts';
  @override
  Post get modelSample => Post(notes: [Note()]);
  @override
  Post fromCacheJson(Map<String, dynamic> json) => Post(id: json['id'] as int?, notes: (json['notes'] as List?)?.cast<Note>() ?? const []);
}

class PhotoProvider extends FluentProvider<Photo> {
  @override
  String get tableName => 'photos';
  @override
  Photo get modelSample => Photo(notes: [Note()]);
  @override
  Photo fromCacheJson(Map<String, dynamic> json) => Photo(id: json['id'] as int?, notes: (json['notes'] as List?)?.cast<Note>() ?? const []);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';
  @override
  Note get modelSample => Note();
  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String? ?? '');
}

// --- 32: a self-through relation without parentVia / childVia ------------------------------------------------------

class Member extends FluentStorable with FluentRelations {
  Member({this.id, this.name = '', this.following = const []});
  final int? id;
  final String name;
  final List<Member> following;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
  @override
  List<FluentRelation> get relations => [FluentRelation.through<Member, Follow, Member>('following', (m) => m.following)];
}

class Follow extends FluentStorable {
  Follow({this.id, this.follower, this.followed});
  final int? id;
  final Member? follower;
  final Member? followed;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'follower': follower, 'followed': followed};
}

class MemberProvider extends FluentProvider<Member> {
  @override
  String get tableName => 'members';
  @override
  Member get modelSample => Member();
  @override
  Member fromCacheJson(Map<String, dynamic> json) => Member(id: json['id'] as int?, name: json['name'] as String? ?? '');
}

class FollowProvider extends FluentProvider<Follow> {
  @override
  String get tableName => 'follows';
  @override
  Follow get modelSample => Follow(follower: Member(), followed: Member());
  @override
  Follow fromCacheJson(Map<String, dynamic> json) => Follow(id: json['id'] as int?);
}

// --- 33: an own REFERENCES with another delete rule ---------------------------------------------------------------

class Shelf extends FluentStorable {
  Shelf({this.id});
  final int? id;
  @override
  Map<String, dynamic> buildJson() => {'id': id};
}

class Box extends FluentStorable with FluentRelations {
  Box({this.id, this.shelf});
  final int? id;
  final Shelf? shelf;
  @override
  Map<String, dynamic> buildJson() => {'id': id};
  @override
  List<FluentDbColumn> get tableSchema => [
    FluentDbColumn.primary(),
    FluentDbColumn(name: 'shelf_id', type: FluentDbDataType.integer, customSql: 'INTEGER REFERENCES shelves(id) ON DELETE SET NULL'),
  ];
  @override
  List<FluentRelation> get relations => [
    FluentRelation<Box, Shelf>(name: 'shelf', type: FluentRelationType.one, select: (b) => b.shelf, foreignKey: 'shelf_id', onDelete: FluentOnDelete.cascade),
  ];
}

class ShelfProvider extends FluentProvider<Shelf> {
  @override
  String get tableName => 'shelves';
  @override
  Shelf get modelSample => Shelf();
  @override
  Shelf fromCacheJson(Map<String, dynamic> json) => Shelf(id: json['id'] as int?);
}

class BoxProvider extends FluentProvider<Box> {
  @override
  String get tableName => 'boxes';
  @override
  Box get modelSample => Box();
  @override
  Box fromCacheJson(Map<String, dynamic> json) => Box(id: json['id'] as int?);
}

void main() {
  setUpFluentTests();
  int counter = 0;
  late FluentTestDb db;

  setUp(() => db = FluentTestDb(name: 'known_bugs_${counter++}', persistent: true));
  tearDown(() => db.close());

  Future<String> pathOf(FluentTestDb d) async => '${await getDatabasesPath()}/${d.name}.db';

  group('keys and equality', () {
    test('3: equal FluentKeys in another column order are one Set entry', () {
      expect({FluentKey({'a': 1, 'b': 2}), FluentKey({'b': 2, 'a': 1})}, hasLength(1));
      expect(fluentValueKey(FluentKey({'a': 1, 'b': 2})), fluentValueKey(FluentKey({'b': 2, 'a': 1})));
    });

    test('5 / 45: providers are equal by instance; a group keeps them after setDbName; two of one table fail clearly', () {
      final DynamicProvider a = DynamicProvider('t', () => [FluentDbColumn.text('name')]);
      final FluentGroup group = FluentGroup(dbKey: FluentDbKey('g'), providerList: [a]);
      a.setDbName('other');
      expect(group.providerList.contains(a), isTrue);
      expect(a == DynamicProvider('t', () => [FluentDbColumn.text('name')]), isFalse);
      expect(
        () => FluentGroup(dbKey: FluentDbKey('g'), providerList: [a, DynamicProvider('t', () => [FluentDbColumn.text('name')])]),
        throwsA(isA<FluentSchemaException>()),
      );
    });

    test('47: keyFilter(null) is refused like keysFilter', () {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.text('name')]);
      expect(() => p.keyFilter(null), throwsA(isA<FluentArgumentException>()));
    });

    test('65: two FluentDbKey(name) keys are equal', () {
      expect(FluentDbKey('a'), FluentDbKey('a'));
      expect({FluentDbKey('a'), FluentDbKey('a')}, hasLength(1));
    });
  });

  group('schema', () {
    test('4: no declared key + an id column in tableSchema: id becomes the primary key, saves upsert', () async {
      final DynamicProvider p = DynamicProvider.spec('nokey', TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')], keys: () => []));
      await db.open([p]);
      expect(p.primaryKeyColumns.single.isPrimaryKey, isTrue);
      await p.save(p.row({'id': 1, 'name': 'a'}));
      await p.save(p.row({'id': 1, 'name': 'b'}));
      expect(await p.count(), 1);
      expect((await p.findById(1))!['name'], 'b');
    });

    test('22: a composite key keeps the value kind of its columns (DateTime key part finds its row)', () async {
      List<FluentDbColumn> keys() => [FluentDbColumn(name: 'day', type: FluentDbDataType.integer, valueKind: FluentValueKind.dateTime), FluentDbColumn.integer('user')];
      final DynamicProvider p = DynamicProvider.spec('daily', TableSpec(columns: () => [...keys(), FluentDbColumn.integer('n')], keys: keys));
      await db.open([p]);
      final DateTime day = DateTime(2026, 11, 4);
      await p.save(p.row({'day': day, 'user': 1, 'n': 5}));
      expect(p.primaryKeyColumns.first.valueKind, FluentValueKind.dateTime);
      expect(await p.findById(FluentKey({'day': day, 'user': 1})), isNotNull);
    });

    test('9: archived columns on disk the snapshot does not know survive a rebuild', () async {
      List<FluentDbColumn> v1() => [FluentDbColumn.text('name'), FluentDbColumn.text('size')];
      List<FluentDbColumn> v2() => [FluentDbColumn.text('name'), FluentDbColumn.integer('size')]; // type change: rebuild
      await db.open([DynamicProvider('t', v1)]);
      await FluentDb.execute<DynamicModel>('ALTER TABLE t ADD COLUMN "__fluent_removed_old_r1" TEXT', dbKey: db.key);
      await FluentDb.execute<DynamicModel>('UPDATE t SET "__fluent_removed_old_r1" = \'kept\'', dbKey: db.key);
      await db.restart([DynamicProvider('t', v2)]);
      final Database raw = await openDatabase(await pathOf(db), singleInstance: false);
      final List<String> columns = [for (final Map<String, Object?> r in await raw.rawQuery('PRAGMA table_info(t)')) r['name']! as String];
      await raw.close();
      expect(columns, contains('__fluent_removed_old_r1'));
    });

    test('54: an archive record without removedAt is not expired at once', () {
      final FluentArchivedColumn a = FluentArchivedColumn.fromJson({'original': 'x', 'archivedAs': '__fluent_removed_x_r1'});
      expect(DateTime.now().difference(a.removedAt).inMinutes, lessThan(1));
    });

    test('62: a damaged snapshot does not stop the start; data stays, steps do not run again', () async {
      int ran = 0;
      TableSpec spec() => TableSpec(
        columns: () => [FluentDbColumn.text('name')],
        migrations: [FluentDbMigration(id: 'once', onMigrate: (_) async => ran++)],
      );
      await db.open([DynamicProvider.spec('t', spec())]);
      final DynamicProvider p = DynamicProvider.spec('t', spec());
      await FluentDb.execute<DynamicModel>("INSERT INTO t (name) VALUES ('a')", dbKey: db.key);
      await FluentDb.execute<DynamicModel>("UPDATE __fluent_schema SET snapshot = '{broken' WHERE table_name = 't'", dbKey: db.key);
      final int before = ran;
      await db.restart([p]);
      expect(await p.count(), 1);
      expect(ran, before, reason: 'the applied step must not run again');
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.schemaFallback));
    });
  });

  group('writes and mapping', () {
    test('23: buildJson may return an unmodifiable map', () async {
      final _FrozenProvider p = _FrozenProvider();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'name': 'a'}));
      expect(await p.count(), 1);
    });

    test('24: a filter value the converter fails on is an error, not a silent raw value', () async {
      final DynamicProvider p = DynamicProvider('conv', () => [FluentDbColumn.converted('code', const _StrictConverter())]);
      await db.open([p]);
      await p.save(p.row({'code': 3}));
      expect(await p.count(where: FluentFilter.eq('code', 3)), 1);
      expect(await p.count(where: FluentFilter.eq('code', 'n3')), 1, reason: 'the stored form is used as it is');
      await expectLater(() => p.count(where: FluentFilter.eq('code', -1)), throwsA(isA<FluentArgumentException>()));
    });

    test('16: a factory throwing something other than a TypeError arrives typed', () async {
      final _ThrowingFactoryProvider p = _ThrowingFactoryProvider();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'name': 'a'}));
      await expectLater(p.findAll(), throwsA(isA<FluentSchemaException>()));
    });

    test('26: findPage refuses columns the model does not carry before reading', () async {
      final DynamicProvider p = DynamicProvider('paged', () => [FluentDbColumn.text('name')]);
      await db.open([p]);
      await expectLater(p.findPage(orderBy: 'expiry_date'), throwsA(isA<FluentArgumentException>()));
      await expectLater(p.findPage(orderBy: '_fs_metadata'), throwsA(isA<FluentArgumentException>()));
    });

    test('28: a rolled-back save leaves the model as it was (deletedAt)', () async {
      final CommentProvider comments = CommentProvider();
      await db.open([comments]);
      final Comment c = Comment(text: 'x');
      await comments.save(c);
      await comments.delete(c);
      expect(c.deletedAt, isNotNull);
      await expectLater(
        FluentDb.transaction(() async {
          await comments.save(c);
          throw StateError('roll back');
        }),
        throwsA(anything),
      );
      expect(c.deletedAt, isNotNull, reason: 'the save was rolled back, the row is still in the trash');
    });

    test('42: corrupt stored JSON is reported (the raw text still reaches the model)', () async {
      final DynamicProvider p = DynamicProvider('js', () => [FluentDbColumn(name: 'data', type: FluentDbDataType.text, valueKind: FluentValueKind.json)]);
      await db.open([p]);
      await p.save(p.row({'data': {'a': 1}}));
      await FluentDb.execute<DynamicModel>("UPDATE js SET data = '{bad'", dbKey: db.key);
      final DynamicModel row = (await p.findAll()).single;
      expect(row['data'], '{bad');
      await db.settle();
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.mappingValue));
    });
  });

  group('relations', () {
    test('12: two owners listing one model, each with its own column, both own their children (many)', () async {
      final PostProvider posts = PostProvider();
      final PhotoProvider photos = PhotoProvider();
      await db.open([posts, photos, NoteProvider()]);
      expect(posts.relationLinks.single.type, FluentRelationType.many);
      expect(photos.relationLinks.single.type, FluentRelationType.many);
    });

    test('32: a self-through relation without parentVia / childVia is reported', () async {
      await db.open([MemberProvider(), FollowProvider()]);
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDeclaration).map((i) => i.title), contains(contains('parentVia')));
    });

    test('33: an own REFERENCES with another delete rule than the declared one is reported', () async {
      await db.open([ShelfProvider(), BoxProvider()]);
      await db.settle();
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDeclaration).map((i) => i.title), contains(contains('ON DELETE SET NULL')));
    });

    test('49: a relation limit is applied per owner by SQLite', () async {
      final ArticleProvider articles = ArticleProvider();
      await db.open([articles, PersonProvider(), CommentProvider(), TagProvider(), ProfileProvider()]);
      await articles.save(Article(title: 'a', comments: [for (int i = 1; i <= 5; i++) Comment(text: 'c$i', likes: i)]));
      await articles.save(Article(title: 'b', comments: [Comment(text: 'x', likes: 9)]));
      final List<Article> all = await articles.findAll(orderBy: 'title', relations: FluentLoad.all);
      expect(all[0].topComments!.map((c) => c.likes), [5, 4]);
      expect(all[1].topComments!.map((c) => c.likes), [9]);
    });
  });

  group('lifecycle', () {
    test('11 / 46: deleteDatabases(reopen: false) is not undone by a later restart', () async {
      await db.open([DynamicProvider('t', () => [FluentDbColumn.text('name')])]);
      final String path = await pathOf(db);
      await FluentDb.deleteDatabases(dbKey: db.key, reopen: false);
      await FluentDb.restart();
      expect(await databaseFactory.databaseExists(path), isFalse);
    });

    test('19: an update callback that throws leaves the databases open', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.text('name')]);
      await db.open([p]);
      await expectLater(FluentDb.restart(update: (_) => throw StateError('bad callback')), throwsA(isA<FluentConfigException>()));
      expect(FluentDb.isOpen(dbKey: db.key), isTrue);
      expect(await p.count(), 0);
    });

    test('8: VACUUM on a table without INTEGER key keeps full-text search right', () async {
      final DynamicProvider p = DynamicProvider.spec(
        'docs',
        TableSpec(
          columns: () => [FluentDbColumn.text('code'), FluentDbColumn.text('body')],
          keys: () => [FluentDbColumn(name: 'code', type: FluentDbDataType.text, isPrimaryKey: true)],
          indexes: const [FluentIndex.fullText(['body'])],
        ),
      );
      await db.open([p]);
      for (int i = 0; i < 20; i++) {
        await p.save(p.row({'code': 'k$i', 'body': 'word$i'}));
      }
      await p.deleteAll([for (int i = 0; i < 10; i++) p.row({'code': 'k$i'})]);
      await p.execute('VACUUM');
      final List<DynamicModel> hits = await p.find(where: FluentFilter.search('word15'));
      expect(hits.map((m) => m['code']), ['k15']);
    });
  });

  group('values, logs, helpers', () {
    test('43: a locale keeps script and region', () {
      final Object restored = FluentTypeCodecs.decode('locale', 'zh-Hant-TW')!;
      expect(restored, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'));
    });

    test('44: the epoch converter can read back UTC times', () {
      final DateTime utc = DateTime.utc(2026, 11, 4, 12);
      const FluentEpochDateTimeConverter converter = FluentEpochDateTimeConverter(utc: true);
      expect(converter.fromSql(converter.toSql(utc)), utc);
    });

    test('39: SQL arguments are hidden anywhere in an error text', () {
      expect(FluentLog.redact('UNIQUE failed sql INSERT args [secret@mail.com] (code 2067)'), isNot(contains('secret')));
      expect(FluentLog.redact('x sql INSERT args [secret]}'), isNot(contains('secret')));
    });

    test('40 / 41: the onRecord sink and the console text get redacted messages', () {
      final List<FluentLogRecord> records = [];
      FluentDb.setupLogging(enabled: true, console: false, level: FluentLogLevel.warning, onRecord: records.add);
      addTearDown(() => FluentDb.setupLogging(enabled: false, onRecord: (_) {}));
      FluentLog.report(FluentConfigException('failed: sql INSERT args [secret] (code 19)', hint: 'fix it'));
      expect(records, isNotEmpty);
      expect(records.last.message, isNot(contains('secret')));
      expect(records.last.format(), isNot(contains('secret')));
    });

    test('50: the clock reports a replacement by a flag', () {
      expect(FluentClock.isReplaced, isFalse);
      FluentClock.testNow = () => DateTime(2026);
      expect(FluentClock.isReplaced, isTrue);
      FluentClock.testNow = null;
      expect(FluentClock.isReplaced, isFalse);
    });

    test('58: orderBy accepts quoted identifiers with escaped quotes', () async {
      final DynamicProvider p = DynamicProvider('q', () => [FluentDbColumn.text('we"ird')]);
      await db.open([p]);
      await p.save(p.row({'we"ird': 'a'}));
      expect(await p.find(orderBy: '"we""ird" DESC'), hasLength(1));
    });

    test('58b: tables and columns with quotes, spaces and dashes save, update, read and delete', () async {
      final DynamicProvider p = DynamicProvider('my items-2', () => [FluentDbColumn.text('we"ird'), FluentDbColumn.text('first name'), FluentDbColumn.integer('order')]);
      await db.open([p]);
      final DynamicModel a = p.row({'we"ird': 'a', 'first name': 'Ann', 'order': 1});
      await p.save(a);
      await p.saveAll([p.row({'we"ird': 'b', 'first name': 'Bob', 'order': 2}), p.row({'we"ird': 'c', 'first name': 'Cid', 'order': 3})]);
      final Object? id = (await p.find(where: FluentFilter.eq('"we""ird"', 'a'))).single.values['id'];
      expect(id, isNotNull);
      await p.save(p.row({'id': id, 'we"ird': 'a2', 'first name': 'Ann', 'order': 1}));
      await p.save(p.row({'id': id, 'first name': 'Anna'}), strategy: FluentSaveStrategy.patch);
      final DynamicModel? read = await p.findById(id);
      expect(read?.values['we"ird'], 'a2');
      expect(read?.values['first name'], 'Anna');
      expect(await p.count(where: FluentFilter.eq('"first name"', 'Bob')), 1);
      expect(await p.find(where: FluentFilter.gt('order', 1), orderBy: '"first name"'), hasLength(2));
      expect(await p.deleteWhere(FluentFilter.eq('"we""ird"', 'b')), 1);
      expect(await p.count(), 2);
      expect(await p.deleteById(id), 1);
      await p.clearTable();
      expect(await p.count(), 0);
    });

    test('58c: relations, soft delete and sync work on such tables', () async {
      final _OddArticles articles = _OddArticles();
      final _OddComments comments = _OddComments();
      final _OddItems items = _OddItems();
      await db.open([_OddPeople(), articles, comments, _OddTags(), items]);
      await articles.save(Article(
        id: 1,
        title: 'A',
        author: Person(name: 'Ann'),
        comments: [Comment(text: 'c1', likes: 2), Comment(text: 'c2', likes: 1), Comment(text: 'c3')],
        tags: [Tag(label: 'x'), Tag(label: 'y')],
      ));
      Article loaded = (await articles.findById(1))!;
      expect(loaded.author?.name, 'Ann');
      expect(loaded.comments!.map((c) => c.text), ['c1', 'c2', 'c3']);
      expect(loaded.tags!.map((t) => t.label), ['x', 'y']);
      expect((await articles.loadRelations(loaded, names: ['topComments'])).topComments!.map((c) => c.text), ['c1', 'c2']);
      await articles.save(Article(id: 1, title: 'A', comments: [loaded.comments!.first], tags: [loaded.tags!.last]));
      loaded = (await articles.findById(1))!;
      expect(loaded.comments!.map((c) => c.text), ['c1']);
      expect(loaded.tags!.map((t) => t.label), ['y']);
      expect(await comments.trash.count(), 2);
      expect(await comments.trash.restoreWhere(FluentFilter.eq('text', 'c2')), 1);
      expect(await articles.deleteById(1), 1);
      expect(await articles.count(), 0);

      await items.saveAll([_OddItem(id: 1, name: 'one'), _OddItem(id: 2, name: 'two')]);
      expect(await items.pendingChanges(), 2);
      await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
      expect(await items.pendingChanges(), 0);
      await items.deleteById(2);
      await items.trash.deleteForeverById(2);
      final List<Object> deleted = [];
      await items.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          deleted.addAll(batch.deletedKeys);
          return const FluentPushResult.accepted();
        },
      );
      expect(deleted, [2]);
      await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [_OddItem(id: 3, name: 'three')]));
      expect((await items.findById(3))?.name, 'three');
    });

    test('60: the retry delay is finite and capped for any attempt', () {
      expect(fluentRetryDelay(const Duration(seconds: 1), 100000), lessThanOrEqualTo(fluentMaxRetryDelay));
    });

    test('61: copyWith clears nullable fields with null', () {
      final FluentDbColumn c = FluentDbColumn.text('a', defaultValue: 'x').copyWith(defaultValue: null);
      expect(c.defaultValue, isNull);
      expect(FluentDbColumn.text('a', defaultValue: 'x').copyWith(isNotNull: true).defaultValue, 'x');
      final FluentGroup g = FluentGroup(dbKey: FluentDbKey('g'), providerList: const []).copyWith(archiveRetention: null);
      expect(g.archiveRetention, isNull);
    });

    test('66: raw SQL writes are found after comments and behind common table expressions', () {
      FluentTask task(String sql) => FluentTask(action: FluentDbAction.execute, table: 't', dbName: 'd', helper: TableHelper(sql: sql));
      expect(task('-- note\nDELETE FROM t').isStreamOp, isTrue);
      expect(task('/* x */ UPDATE t SET a = 1').isStreamOp, isTrue);
      expect(task("WITH x AS (SELECT 'update' AS w) SELECT * FROM x").isStreamOp, isFalse);
      expect(task('WITH x AS (SELECT 1) DELETE FROM t WHERE id IN x').isStreamOp, isTrue);
    });
  });
}
