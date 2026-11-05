// Writing and deleting: save strategies, conflictOn, unique conflicts, field updates, soft delete with cascade,
// purge, expiry, events.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/schema_models.dart';

class Album extends FluentStorable with FluentSoftDeletable, FluentRelations {
  Album({this.id, required this.title, this.photos});

  final int? id;
  final String title;
  final List<Photo>? photos;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Album, Photo>('photos', (a) => a.photos, orderBy: 'url')];
}

class Photo extends FluentStorable with FluentSoftDeletable {
  Photo({this.id, required this.url});

  final int? id;
  final String url;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'url': url};
}

class AlbumProvider extends FluentProvider<Album> {
  @override
  String get tableName => 'albums';

  @override
  Album get modelSample => Album(title: '');

  @override
  Album fromCacheJson(Map<String, dynamic> json) => Album(id: json['id'] as int?, title: json['title'] as String, photos: (json['photos'] as List?)?.cast<Photo>());
}

class PhotoProvider extends FluentProvider<Photo> {
  @override
  String get tableName => 'photos';

  @override
  Photo get modelSample => Photo(url: '');

  @override
  Photo fromCacheJson(Map<String, dynamic> json) => Photo(id: json['id'] as int?, url: json['url'] as String);
}

class Memo extends FluentStorable with FluentTimestamps {
  Memo({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class MemoProvider extends FluentProvider<Memo> {
  @override
  String get tableName => 'memos';

  @override
  Memo get modelSample => Memo(text: '');

  @override
  Memo fromCacheJson(Map<String, dynamic> json) => Memo(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  late AlbumProvider albums;
  late PhotoProvider photos;
  late MemoProvider memos;
  late Database sql;

  setUp(() async {
    db = FluentTestDb(name: 'write_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider(
      'users',
      () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name'), FluentDbColumn.text('note'), FluentDbColumn.timestamp('seen_at'), FluentDbColumn.timestamp('born_at')],
    );
    albums = AlbumProvider();
    photos = PhotoProvider();
    memos = MemoProvider();
    await db.open([users, albums, photos, memos]);
    sql = users.db;
  });

  tearDown(() => db.close());

  DynamicModel user(Map<String, dynamic> values) => users.row(values);

  group('save', () {
    test('upsert inserts, then updates; the result counts rows and generated keys come back', () async {
      final DynamicModel ann = user({'id': null, 'email': 'ann@x', 'name': 'Ann'});
      final FluentSaveResult first = await users.save(ann);
      expect((first.inserted, first.updated, first.skipped), (1, 0, 0));
      expect(ann.primaryKeyValue, isA<int>());

      final FluentSaveResult second = await users.saveAll([user({'id': ann.primaryKeyValue, 'email': 'ann@x', 'name': 'Ann 2'}), user({'id': null, 'email': 'bob@x', 'name': 'Bob'})]);
      expect((second.inserted, second.updated), (1, 1));
      expect(await users.count(), 2);
    });

    test('a conflict on another UNIQUE column throws and rolls the whole save back', () async {
      await users.save(user({'id': 1, 'email': 'ann@x', 'name': 'Ann'}));
      await expectLater(
        users.saveAll([user({'id': 2, 'email': 'new@x', 'name': 'New'}), user({'id': 3, 'email': 'ann@x', 'name': 'Dup'})]),
        throwsA(isA<FluentConstraintException>().having((e) => e.message, 'message', contains('UNIQUE'))),
      );
      expect(await users.count(), 1, reason: 'nothing is lost silently and nothing is half-saved');
    });

    test('insertOnly skips existing rows; updateOnly skips missing ones; patch keeps null fields', () async {
      await users.save(user({'id': 1, 'email': 'ann@x', 'name': 'Ann', 'note': 'keep'}));

      final FluentSaveResult inserted = await users.saveAll([user({'id': 1, 'email': 'ann@x', 'name': 'X'}), user({'id': 2, 'email': 'bob@x', 'name': 'Bob'})], strategy: FluentSaveStrategy.insertOnly);
      expect((inserted.inserted, inserted.skipped), (1, 1));
      expect((await users.findById(1))?['name'], 'Ann');

      final FluentSaveResult updated = await users.saveAll([user({'id': 9, 'email': 'z@x', 'name': 'Z'})], strategy: FluentSaveStrategy.updateOnly);
      expect(updated.skipped, 1);
      expect(await users.exists(9), isFalse);

      await users.save(user({'id': 1, 'email': 'ann@x', 'name': 'Ann 2', 'note': null}), strategy: FluentSaveStrategy.patch);
      expect((await users.findById(1))?['note'], 'keep');
      expect((await users.findById(1))?['name'], 'Ann 2');
    });

    test('conflictOn updates the row with the same unique value and returns its stored key', () async {
      await users.save(user({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));
      final DynamicModel fromServer = user({'id': null, 'email': 'ann@x', 'name': 'Ann (server)'});

      final FluentSaveResult result = await users.save(fromServer, conflictOn: ['email']);
      expect(result.updated, 1);
      expect(fromServer.primaryKeyValue, 7);
      expect((await users.findById(7))?['name'], 'Ann (server)');
      expect(await users.count(), 1);

      expect(() => users.save(fromServer, conflictOn: ['nope']), throwsA(isA<FluentArgumentException>()));
    });

    test('the same key twice in one call is written once (the last one wins)', () async {
      final FluentSaveResult result = await users.saveAll([user({'id': 1, 'email': 'a@x', 'name': 'first'}), user({'id': 1, 'email': 'a@x', 'name': 'last'})]);
      expect(result.outcomes, hasLength(2));
      expect(await users.count(), 1);
      expect((await users.findById(1))?['name'], 'last');
    });

    test('concurrent saves get their own results', () async {
      final List<FluentSaveResult> results = await Future.wait([
        for (int i = 0; i < 5; i++) users.save(user({'id': i + 1, 'email': '$i@x', 'name': 'u$i'}), strategy: i.isEven ? FluentSaveStrategy.upsert : FluentSaveStrategy.insertOnly),
      ]);
      expect(results.map((r) => r.outcomes.length), everyElement(1));
      expect(await users.count(), 5);
    });
  });

  group('update', () {
    test('updateById / updateWhere set fields; unknown columns fail with a hint', () async {
      await users.saveAll([user({'id': 1, 'email': 'a@x', 'name': 'A'}), user({'id': 2, 'email': 'b@x', 'name': 'B'})]);

      expect(await users.updateById(1, {'note': 'vip'}), 1);
      expect(await users.updateById(99, {'note': 'x'}), 0);
      expect(await users.updateWhere(FluentFilter.isNull('note'), {'note': 'regular'}), 1);
      expect((await users.findById(2))?['note'], 'regular');

      await expectLater(users.updateById(1, {'missing': 1}), throwsA(isA<FluentArgumentException>()));
      await expectLater(users.updateById(1, {'id': 5}), throwsA(isA<FluentArgumentException>()));
    });

    test('type tags stay exact when a field changes between UTC and local time', () async {
      await users.save(user({'id': 1, 'email': 'a@x', 'name': 'A'}));

      await users.updateWhere(FluentFilter.eq('id', 1), {'seen_at': DateTime.utc(2024, 1, 2)});
      expect(((await users.findById(1))?['seen_at'] as DateTime).isUtc, isTrue);

      await users.updateById(1, {'seen_at': DateTime(2024, 1, 3)});
      final DateTime local = (await users.findById(1))?['seen_at'] as DateTime;
      expect(local.isUtc, isFalse, reason: 'the old UTC tag must not survive');
      expect(local, DateTime(2024, 1, 3));
    });

    test('update errors are typed', () async {
      await users.saveAll([user({'id': 1, 'email': 'a@x', 'name': 'A'}), user({'id': 2, 'email': 'b@x', 'name': 'B'})]);
      await expectLater(users.update(user({'id': 2, 'email': 'a@x', 'name': 'B'})), throwsA(isA<FluentConstraintException>()));
      expect(await users.update(user({'id': 3, 'email': 'c@x', 'name': 'C'})), 0);
    });
  });

  group('soft delete', () {
    Future<Object?> stamp(String table, int id) async => (await sql.rawQuery('SELECT deleted_at FROM $table WHERE id = ?', [id])).single['deleted_at'];

    test('one stamp format; deleting again keeps the first stamp; deletedAt is loaded', () async {
      final Album a = Album(title: 'a');
      final Album b = Album(title: 'b');
      final Album c = Album(title: 'c');
      await albums.saveAll([a, b, c]);

      await albums.delete(a);
      await albums.deleteById(b.primaryKeyValue);
      await albums.deleteWhere(FluentFilter.eq('title', 'c'));
      for (final Album x in [a, b, c]) {
        expect(await stamp('albums', x.primaryKeyValue as int), isA<int>());
      }
      expect(a.deletedAt, isNotNull);

      final Object? first = await stamp('albums', a.primaryKeyValue as int);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await albums.delete(a), 0);
      expect(await stamp('albums', a.primaryKeyValue as int), first);

      final List<Album> trash = await albums.trash.find(orderBy: 'title');
      expect(trash.map((x) => x.deletedAt), everyElement(isA<DateTime>()));
    });

    test('saving the key of a deleted model brings it back (outcome restored); updates skip the trash', () async {
      final Album a = Album(title: 'a', photos: [Photo(url: '1')]);
      await albums.save(a);
      await albums.delete(a);

      expect(await albums.update(Album(id: a.primaryKeyValue as int, title: 'not')), 0);
      expect(await albums.updateById(a.primaryKeyValue, {'title': 'not'}), 0);

      final Album again = Album(id: a.primaryKeyValue as int, title: 'renamed')..deletedAt = DateTime.now();
      final FluentSaveResult result = await albums.save(again);
      expect(result.restored, 1);
      expect(again.deletedAt, isNull);
      final Album? back = await albums.findById(a.primaryKeyValue);
      expect(back?.title, 'renamed');
      expect(back?.photos?.map((p) => p.url), ['1'], reason: 'children deleted with it come back too');
      expect(await albums.trash.find(), isEmpty);
    });

    test('owned children are deleted and restored together with the owner', () async {
      final Album album = Album(title: 'trip', photos: [Photo(url: '1'), Photo(url: '2'), Photo(url: '3')]);
      await albums.save(album);
      final Photo removedBefore = (await photos.findFirst(where: FluentFilter.eq('url', '3')))!;
      await photos.delete(removedBefore);

      await albums.delete(album);
      expect(await photos.count(), 0);

      expect(await albums.trash.restore(album), 1);
      expect((await photos.findAll(orderBy: 'url')).map((p) => p.url), ['1', '2'], reason: 'the photo deleted earlier stays in the trash');
      expect((await albums.findById(album.primaryKeyValue))?.photos?.map((p) => p.url), ['1', '2']);
    });

    test('hard delete and purge remove rows permanently, also legacy text stamps', () async {
      final Album a = Album(title: 'a');
      final Album b = Album(title: 'b');
      await albums.saveAll([a, b]);
      expect(await albums.trash.deleteForeverById(a.primaryKeyValue), 1);
      expect(await albums.count(), 1);

      await albums.delete(b);
      expect(await albums.trash.empty(olderThan: const Duration(days: 1)), 0);
      expect(await albums.trash.empty(olderThan: Duration.zero), 1);

      final Album old = Album(title: 'old');
      await albums.save(old);
      await sql.rawUpdate('UPDATE albums SET deleted_at = ? WHERE id = ?', [DateTime(2020).toIso8601String(), old.primaryKeyValue]);
      expect(await albums.trash.empty(olderThan: const Duration(days: 30)), 1);
    });
  });

  group('expiry and events', () {
    test('expired rows are hidden from reads unless includeExpired; clearExpired removes them', () async {
      final DynamicModel fresh = user({'id': 1, 'email': 'a@x', 'name': 'fresh'});
      final DynamicModel stale = user({'id': 2, 'email': 'b@x', 'name': 'stale'})..timeToLive = const Duration(hours: -1);
      await users.saveAll([fresh, stale]);

      expect((await users.findAll()).map((u) => u['name']), ['fresh']);
      expect(await users.findById(2), isNull);
      expect(await users.count(), 1);
      expect(await users.findAll(includeExpired: true), hasLength(2));

      expect(await users.clearExpired(), 1);
      expect(await users.count(includeExpired: true), 1);
    });

    test('writes that change nothing publish no change event', () async {
      final List<FluentChangeKind> events = [];
      final StreamSubscription<FluentChangeEvent<Album>> sub = FluentDb.onEvent<Album>().listen((e) => events.add(e.kind));

      await albums.deleteWhere(FluentFilter.eq('title', 'none'));
      await albums.save(Album(title: 'x'));
      await Future<void>.delayed(Duration.zero);
      expect(events, [FluentChangeKind.save]);
      await sub.cancel();
    });
  });

  group('timestamps and watch', () {
    test('createdAt is set once, updatedAt on every write', () async {
      final Memo memo = Memo(text: 'a');
      await memos.save(memo);
      final Memo created = (await memos.findById(memo.primaryKeyValue))!;
      expect(created.createdAt, isNotNull);
      expect(created.updatedAt, created.createdAt);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await memos.save(Memo(id: memo.primaryKeyValue as int, text: 'b'));
      final Memo saved = (await memos.findById(memo.primaryKeyValue))!;
      expect(saved.createdAt, created.createdAt);
      expect(saved.updatedAt!.isAfter(created.updatedAt!), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await memos.updateById(memo.primaryKeyValue, {'text': 'c'});
      expect((await memos.findById(memo.primaryKeyValue))!.updatedAt!.isAfter(saved.updatedAt!), isTrue);
    });

    test('watch emits now and after every change; bursts are coalesced', () async {
      final List<List<String>> seen = [];
      final StreamSubscription<List<Memo>> sub = memos.watch(orderBy: 'text').listen((list) => seen.add([for (final Memo m in list) m.text]));
      await db.settle();
      expect(seen, [<String>[]]);

      await memos.save(Memo(text: 'a'));
      await db.settle();
      expect(seen.last, ['a']);

      await Future.wait([memos.save(Memo(text: 'b')), memos.save(Memo(text: 'c'))]);
      await db.settle();
      expect(seen.last, ['a', 'b', 'c']);
      expect(seen.length, lessThanOrEqualTo(4));

      await sub.cancel();
      await memos.save(Memo(text: 'd'));
      await db.settle();
      expect(seen.last, ['a', 'b', 'c'], reason: 'no updates after cancel');
    });
  });

  group('follow-ups', () {
    test('patch replaces the type tags of patched fields and keeps the others', () async {
      await users.save(user({'id': 1, 'email': 'a@x', 'name': 'A', 'seen_at': DateTime.utc(2024), 'born_at': DateTime.utc(1990)}));

      await users.save(user({'id': 1, 'email': 'a@x', 'name': null, 'seen_at': DateTime(2024, 5), 'born_at': null}), strategy: FluentSaveStrategy.patch);
      final DynamicModel row = (await users.findById(1))!;
      expect((row['seen_at'] as DateTime).isUtc, isFalse, reason: 'patched: the old UTC tag is gone');
      expect(row['seen_at'], DateTime(2024, 5));
      expect((row['born_at'] as DateTime).isUtc, isTrue, reason: 'untouched: its tag is kept');
      expect(row['name'], 'A');
    });

    test('a collection of several model types is saved in one transaction', () async {
      await users.save(user({'id': 1, 'email': 'a@x', 'name': 'A'}));
      await expectLater(
        FluentDb.saveAll<FluentStorable>([Album(title: 'kept?'), user({'id': 2, 'email': 'a@x', 'name': 'dup'})]),
        throwsA(isA<FluentConstraintException>()),
      );
      expect(await albums.count(), 0, reason: 'the album is rolled back with the failing user');

      final FluentSaveResult ok = await FluentDb.saveAll<FluentStorable>([Album(title: 'x'), user({'id': 3, 'email': 'c@x', 'name': 'C'}), Album(title: 'y')]);
      expect(ok.inserted, 3);
      expect(await albums.count(), 2);
    });

    test('watch skips changes of rows that are not shown and do not match', () async {
      int runs = 0;
      final StreamSubscription<List<Memo>> sub = memos.watch(where: FluentFilter.eq('text', 'a')).listen((_) => runs++);
      await db.settle();
      expect(runs, 1);

      await memos.save(Memo(text: 'other'));
      await db.settle();
      expect(runs, 1, reason: 'not shown and does not match');

      final Memo a = Memo(text: 'a');
      await memos.save(a);
      await db.settle();
      expect(runs, 2, reason: 'a new matching row');

      await memos.save(Memo(id: a.primaryKeyValue as int, text: 'b'));
      await db.settle();
      expect(runs, 3, reason: 'a shown row changed');
      await sub.cancel();
    });
  });
}
