// Regressions found by the final audit: each test reproduces a confirmed bug.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';

/// A syncable table.
class Item extends FluentStorable {
  Item({this.id, required this.name});
  final int? id;
  final String name;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class ItemProvider extends FluentProvider<Item> with FluentSyncable<Item> {
  @override
  String get tableName => 'items';
  @override
  Item get modelSample => Item(name: '');
  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, name: json['name'] as String);
}

/// A shop whose wares block its deletion (ON DELETE RESTRICT); the table name sorts before the children.
class Shop extends FluentStorable with FluentRelations {
  Shop({this.id, required this.name, this.wares});
  final int? id;
  final String name;
  final List<Ware>? wares;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
  @override
  List<FluentRelation> get relations => [FluentRelation.many<Shop, Ware>('wares', (s) => s.wares, onDelete: FluentOnDelete.restrict)];
}

class Ware extends FluentStorable {
  Ware({this.id, required this.label});
  final int? id;
  final String label;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class ShopProvider extends FluentProvider<Shop> {
  @override
  String get tableName => 'a_shops';
  @override
  Shop get modelSample => Shop(name: '');
  @override
  Shop fromCacheJson(Map<String, dynamic> json) => Shop(id: json['id'] as int?, name: json['name'] as String, wares: (json['wares'] as List?)?.cast<Ware>());
}

class WareProvider extends FluentProvider<Ware> {
  @override
  String get tableName => 'wares';
  @override
  Ware get modelSample => Ware(label: '');
  @override
  Ware fromCacheJson(Map<String, dynamic> json) => Ware(id: json['id'] as int?, label: json['label'] as String);
}

/// A cache matched with the server by a date (not a String / int key).
class Day extends FluentStorable {
  Day({this.id, required this.date, required this.note});
  final int? id;
  final DateTime date;
  final String note;
  @override
  Map<String, dynamic> buildJson() => {'id': id, 'date': date, 'note': note};
  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['date']);
}

class DayProvider extends FluentProvider<Day> {
  @override
  String get tableName => 'days';
  @override
  Day get modelSample => Day(date: DateTime(2026), note: '');
  @override
  Day fromCacheJson(Map<String, dynamic> json) => Day(id: json['id'] as int?, date: json['date'] as DateTime, note: json['note'] as String);
}

/// A subclass with its own table.
class Special extends Comment {
  Special({super.id, required super.text});
}

class SpecialProvider extends FluentProvider<Special> {
  @override
  String get tableName => 'specials';
  @override
  Special get modelSample => Special(text: '');
  @override
  Special fromCacheJson(Map<String, dynamic> json) => Special(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  test('queued saves with different relationSync are not merged: preserveLocal keeps the children', () async {
    final FluentTestDb db = FluentTestDb();
    final ArticleProvider articles = ArticleProvider();
    final CommentProvider comments = CommentProvider();
    await db.open([articles, comments, PersonProvider(), ProfileProvider(), TagProvider()]);
    await articles.save(Article(title: 'a', comments: [Comment(text: 'c1'), Comment(text: 'c2')]));
    final Article stored = (await articles.findAll()).single;
    final Comment c1 = stored.comments!.firstWhere((c) => c.text == 'c1');

    final Future<Object?> running = articles.save(Article(title: 'running')); // starts at once; the next two wait together
    final Future<Object?> other = articles.save(Article(title: 'other'));
    final Future<Object?> keep = articles.save(Article(id: stored.id, title: 'a', comments: [c1]), relationSync: FluentRelationSyncMode.preserveLocal);
    await Future.wait([running, other, keep]);
    expect(await comments.count(), 2);
    await db.close();
  });

  test('FluentDb.clear empties tables kept by RESTRICT rules, and a failing clear fails instead of hanging', () async {
    final FluentTestDb db = FluentTestDb();
    final ShopProvider shops = ShopProvider();
    final WareProvider wares = WareProvider();
    await db.open([shops, wares]);
    await shops.save(Shop(name: 's', wares: [Ware(label: 'w')]));
    await FluentDb.clear().timeout(const Duration(seconds: 10));
    expect(await shops.count() + await wares.count(), 0);

    await shops.save(Shop(name: 'locked'));
    await shops.db.execute("CREATE TRIGGER no_delete BEFORE DELETE ON a_shops BEGIN SELECT RAISE(ABORT, 'locked'); END");
    await expectLater(FluentDb.clear().timeout(const Duration(seconds: 10)), throwsA(isNot(isA<TimeoutException>())));
    await db.close();
  });

  test('an emptied synced table is pulled in full again (clearTable and FluentDb.clear)', () async {
    final FluentTestDb db = FluentTestDb();
    final ItemProvider items = ItemProvider();
    await db.open([items]);
    Future<DateTime?> nextSince() async {
      DateTime? since;
      await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (request) async {
        since = request.since;
        return FluentPullResult<Item>(items: [Item(id: 1, name: 'one')], serverTime: DateTime(2026));
      });
      return since;
    }

    await nextSince();
    expect(await nextSince(), DateTime(2026));
    await items.clearTable();
    expect(await nextSince(), isNull);
    await FluentDb.clear();
    expect(await nextSince(), isNull);
    await db.close();
  });

  test('watch follows every loaded level and drops rows when they expire', () async {
    final FluentTestDb db = FluentTestDb();
    final PersonProvider people = PersonProvider();
    final ProfileProvider profiles = ProfileProvider();
    final ArticleProvider articles = ArticleProvider();
    await db.open([articles, people, profiles, CommentProvider(), TagProvider()]);
    await articles.save(Article(title: 'a', author: Person(name: 'Ann', profile: Profile(bio: 'old'))));

    final List<String?> bios = [];
    final StreamSubscription<List<Article>> sub = articles.watch(maxDepth: 3).listen((rows) => bios.add(rows.single.author?.profile?.bio));
    await db.settle();
    final Profile profile = (await profiles.findAll()).single;
    await profiles.save(Profile(id: profile.id, bio: 'new')); // two levels below articles
    await db.settle();
    expect(bios, ['old', 'new']);
    await sub.cancel();

    final List<int> sizes = [];
    final StreamSubscription<List<Article>> expiring = articles.watch().listen((rows) => sizes.add(rows.length));
    await articles.save(Article(title: 'short')..timeToLive = const Duration(milliseconds: 300));
    await db.settle();
    // The expiry is real time: no change event announces it, the stream's own timer does.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await db.settle();
    expect(sizes.last, 1, reason: 'the expired article left the list without any write');
    await expiring.cancel();
    await db.close();
  });

  test('sync: different rows are not answered by a running sync; edited rows stop the push loop; serverTime hint', () async {
    final FluentTestDb db = FluentTestDb();
    final ItemProvider items = ItemProvider();
    await db.open([items]);
    await items.saveAll([Item(name: 'a'), Item(name: 'b')]);

    final List<int> sentA = [];
    final List<int> sentB = [];
    final Completer<void> gate = Completer<void>();
    final Future<FluentSyncResult<Item>> first = items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      where: FluentFilter.eq('name', 'a'),
      onPush: (batch) async {
        await gate.future;
        sentA.addAll([for (final Item i in batch.changed) i.id!]);
        return const FluentPushResult.accepted();
      },
    );
    final Future<FluentSyncResult<Item>> second = items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      where: FluentFilter.eq('name', 'b'),
      onPush: (batch) async {
        sentB.addAll([for (final Item i in batch.changed) i.id!]);
        return const FluentPushResult.accepted();
      },
    );
    gate.complete();
    await Future.wait([first, second]);
    expect([sentA.length, sentB.length], [1, 1], reason: 'each call synced its own rows');

    int calls = 0;
    final Item a = (await items.find(where: FluentFilter.eq('name', 'a'))).single;
    await items.save(Item(id: a.id, name: 'a'));
    await items.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: 1,
      onPush: (batch) async {
        calls++;
        await items.save(Item(id: a.id, name: 'a$calls')); // edited again while it is being sent
        return const FluentPushResult.accepted();
      },
    );
    expect(calls, lessThanOrEqualTo(2));

    await items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult<Item>(items: []));
    expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.pullClock));
    await db.close();
  });

  test('watchRemote mirror keeps rows matched by a date server key', () async {
    final FluentTestDb db = FluentTestDb();
    final DayProvider days = DayProvider();
    await db.open([days]);
    List<Day> answer() => [Day(date: DateTime(2026), note: 'one'), Day(date: DateTime(2026, 1, 2), note: 'two')];
    for (int i = 0; i < 2; i++) {
      await days.watchRemote(fetch: () async => FluentRemoteResponse(answer()), store: FluentRemoteStore.mirror, keepWatching: false).last;
    }
    final List<Day> stored = await days.findAll(orderBy: 'date');
    expect(stored.map((d) => d.note), ['one', 'two']);
    expect(stored.map((d) => d.id).toSet(), hasLength(2), reason: 'matched, not deleted and inserted again');
    await db.close();
  });

  test('a model saved through a variable of its base type goes to its own table', () async {
    final FluentTestDb db = FluentTestDb();
    final CommentProvider comments = CommentProvider();
    final SpecialProvider specials = SpecialProvider();
    await db.open([comments, specials]);
    final Comment special = Special(text: 'mine');
    await FluentDb.save<Comment>(special);
    expect([await comments.count(), await specials.count()], [0, 1]);
    await db.close();
  });
}
