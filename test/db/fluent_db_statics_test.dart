@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';
import '_helpers.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  tearDown(() async {
    await db.close();
  });

  Future<void> open([List<FluentProvider>? providers]) async {
    db = FluentTestDb();
    await db.open(providers ?? [GadgetProvider(), CommentProvider(), PageProvider(), RemoteProvider()]);
  }

  Future<void> seed() async {
    await FluentDb.saveAll<Gadget>([Gadget(name: 'a', qty: 1), Gadget(name: 'b', qty: 2), Gadget(name: 'c', qty: 2), Gadget(name: 'd', qty: 5)]);
  }

  group('reads', () {
    setUp(() async {
      await open();
      await seed();
    });

    test('findById, findByIds, find, findAll, findFirst, findPage', () async {
      expect((await FluentDb.findById<Gadget>(1))?.name, 'a');
      expect(await FluentDb.findById<Gadget>(99), isNull);
      expect((await FluentDb.findByIds<Gadget>([3, 1])).map((g) => g.name), ['c', 'a']);
      expect((await FluentDb.find<Gadget>(where: FluentFilter.eq('qty', 2), orderBy: 'name DESC')).map((g) => g.name), ['c', 'b']);
      expect((await FluentDb.find<Gadget>(orderBy: 'id', limit: 2, offset: 1)).map((g) => g.name), ['b', 'c']);
      expect((await FluentDb.findAll<Gadget>(orderBy: 'id', limit: 3)).length, 3);
      expect((await FluentDb.findFirst<Gadget>(where: FluentFilter.gt('qty', 1), orderBy: 'id DESC'))?.name, 'd');
      final FluentPage<Gadget> page = await FluentDb.findPage<Gadget>(orderBy: 'id', limit: 3);
      expect(page.items.map((g) => g.name), ['a', 'b', 'c']);
      final FluentPage<Gadget> next = await FluentDb.findPage<Gadget>(orderBy: 'id', limit: 3, after: page.next);
      expect(next.items.map((g) => g.name), ['d']);
    });

    test('count, exists, existsWhere, findMaps, pluck', () async {
      expect(await FluentDb.count<Gadget>(), 4);
      expect(await FluentDb.count<Gadget>(where: FluentFilter.eq('qty', 2)), 2);
      expect(await FluentDb.exists<Gadget>(1), isTrue);
      expect(await FluentDb.exists<Gadget>(77), isFalse);
      expect(await FluentDb.existsWhere<Gadget>(FluentFilter.eq('name', 'd')), isTrue);
      expect(await FluentDb.existsWhere<Gadget>(FluentFilter.eq('name', 'zz')), isFalse);
      final maps = await FluentDb.findMaps<Gadget>(columns: ['name'], orderBy: 'name', limit: 2);
      expect(maps, [
        {'name': 'a'},
        {'name': 'b'},
      ]);
      expect(await FluentDb.pluck<Gadget, int>('qty', distinct: true, orderBy: 'qty'), [1, 2, 5]);
      expect(await FluentDb.pluck<Gadget, String>('name', orderBy: 'name', limit: 2, offset: 1), ['b', 'c']);
    });

    test('aggregates', () async {
      expect(await FluentDb.sum<Gadget>('qty'), 10);
      expect(await FluentDb.sum<Gadget>('qty', where: FluentFilter.eq('qty', 2)), 4);
      expect(await FluentDb.avg<Gadget>('qty'), 2.5);
      expect(await FluentDb.min<Gadget, int>('qty'), 1);
      expect(await FluentDb.max<Gadget, int>('qty'), 5);
      expect(await FluentDb.countDistinct<Gadget>('qty'), 3);
      final rows = await FluentDb.aggregate<Gadget>(
        values: {'n': const FluentAggregate.count(), 'total': const FluentAggregate.sum('qty')},
        groupBy: ['qty'],
        having: FluentFilter.gt('qty', 1),
        orderBy: 'qty',
      );
      expect(rows.map((r) => [r['qty'], r['n'], r['total']]), [
        [2, 2, 4],
        [5, 1, 5],
      ]);
    });

    test('rawQuery and execute pick the database by the model type', () async {
      expect((await FluentDb.rawQuery<Gadget>('SELECT COUNT(*) AS n FROM gadgets WHERE qty > ?', arguments: [1])).single['n'], 3);
      expect(await FluentDb.execute<Gadget>('UPDATE gadgets SET qty = qty + 1 WHERE name = ?', arguments: ['a']), 1);
      expect((await FluentDb.findById<Gadget>(1))?.qty, 2);
    });

    test('search finds by the full-text index', () async {
      await FluentDb.saveAll<Page>([Page(title: 'hello world'), Page(title: 'goodbye')]);
      final List<Page> found = await FluentDb.search<Page>('hel', orderBy: 'id', limit: 5, offset: 0);
      expect(found.map((p) => p.title), ['hello world']);
      expect(await FluentDb.search<Page>('hello', prefix: false, where: FluentFilter.eq('title', 'goodbye')), isEmpty);
    });

    test('watch, watchById and watchValue follow the changes', () async {
      final List<List<String>> lists = [];
      final List<String?> ones = [];
      final List<num> totals = [];
      final subs = [
        FluentDb.watch<Gadget>(orderBy: 'id', limit: 10, offset: 0, where: FluentFilter.gt('qty', 0)).listen((l) => lists.add([for (final Gadget g in l) g.name])),
        FluentDb.watchById<Gadget>(1).listen((g) => ones.add(g?.name)),
        FluentDb.watchValue<Gadget, num>(() => FluentDb.sum<Gadget>('qty')).listen(totals.add),
      ];
      await db.settle();
      expect(lists.last, ['a', 'b', 'c', 'd']);
      expect(ones.last, 'a');
      expect(totals.last, 10);

      await FluentDb.updateById<Gadget>(1, {'name': 'z', 'qty': 10});
      await db.settle();
      expect(ones.last, 'z');
      expect(totals.last, 19);
      for (final s in subs) {
        await s.cancel();
      }
    });

    test('watchValue alsoOn resolves the other model types and reacts to their tables', () async {
      final List<int> counts = [];
      final StreamSubscription<int> sub = FluentDb.watchValue<Gadget, int>(() => FluentDb.count<Page>(), alsoOn: [Page]).listen(counts.add);
      await db.settle();
      expect(counts.last, 0);
      await FluentDb.save<Page>(Page(title: 'x'));
      await db.settle();
      expect(counts.last, 1);
      await sub.cancel();
    });

    test('watchValue with an unknown alsoOn type is an error event', () async {
      await expectLater(FluentDb.watchValue<Gadget, int>(() async => 1, alsoOn: [Stranger]), emitsError(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound)));
    });
  });

  group('writes', () {
    setUp(() async {
      await open();
      await seed();
    });

    test('save, update, updateAll, updateById, updateWhere', () async {
      final FluentSaveResult saved = await FluentDb.save<Gadget>(Gadget(name: 'e', qty: 7), tag: 'x');
      expect(saved.outcomes, hasLength(1));
      final Gadget e = (await FluentDb.findFirst<Gadget>(where: FluentFilter.eq('name', 'e')))!;
      expect(await FluentDb.update<Gadget>(Gadget(id: e.id, name: 'e2', qty: 8)), 1);
      expect(await FluentDb.updateAll<Gadget>([Gadget(id: 1, name: 'a2', qty: 1), Gadget(id: 2, name: 'b2', qty: 2)]), 2);
      expect(await FluentDb.updateById<Gadget>(3, {'qty': 30}), 1);
      expect(await FluentDb.updateWhere<Gadget>(FluentFilter.eq('qty', 2), {'qty': 20}), 1);
      expect((await FluentDb.findAll<Gadget>(orderBy: 'id')).map((g) => '${g.name}:${g.qty}'), ['a2:1', 'b2:20', 'c:30', 'd:5', 'e2:8']);
    });

    test('updateAll / deleteAll of nothing change nothing', () async {
      expect(await FluentDb.updateAll<Gadget>(const []), 0);
      expect(await FluentDb.deleteAll<Gadget>(const []), 0);
    });

    test('delete, deleteAll, deleteById, deleteWhere, clearTable, clearExpired', () async {
      expect(await FluentDb.delete<Gadget>(Gadget(id: 1, name: 'a')), 1);
      expect(await FluentDb.deleteAll<Gadget>([Gadget(id: 2, name: 'b'), Gadget(id: 3, name: 'c')]), 2);
      expect(await FluentDb.deleteById<Gadget>(4), 1);
      expect(await FluentDb.deleteById<Gadget>(4), 0);
      await seed();
      expect(await FluentDb.deleteWhere<Gadget>(FluentFilter.gt('qty', 1)), 3);
      expect(await FluentDb.clearExpired<Gadget>(tag: 't'), 0);
      expect(await FluentDb.clearTable<Gadget>(), greaterThan(0));
      expect(await FluentDb.count<Gadget>(), 0);
    });

    test('saveAll keeps the outcome order across model types and writes them in one transaction', () async {
      final FluentSaveResult result = await FluentDb.saveAll<FluentStorable>([Gadget(name: 'm'), Page(title: 'p'), Gadget(name: 'n')]);
      expect(result.outcomes, hasLength(3));
      expect(await FluentDb.count<Gadget>(), 6);
      expect(await FluentDb.count<Page>(), 1);
    });

    test('a collection with an unregistered type fails before anything is written', () async {
      final before = await FluentDb.count<Gadget>();
      await expectLater(
        FluentDb.saveAll<FluentStorable>([Gadget(name: 'ok'), Page(title: 'p'), Stranger()]),
        throwsA(isA<FluentConfigException>()),
      );
      expect(await FluentDb.count<Gadget>(), before);
    });

    test('deleteAll across model types sums', () async {
      await FluentDb.save<Page>(Page(title: 'p'));
      expect(await FluentDb.deleteAll<FluentStorable>([Gadget(id: 1, name: 'a'), Page(id: 1, title: 'p')]), 2);
    });

    test('an item held in a base-typed variable is saved by the provider of its runtime type', () async {
      final FluentStorable item = Gadget(name: 'plain');
      await FluentDb.save<FluentStorable>(item);
      expect(await FluentDb.count<Gadget>(), 5);
    });
  });

  group('trash', () {
    setUp(() async {
      await open([CommentProvider(), PersonProvider(), ProfileProvider()]);
    });

    test('trash and withTrash resolve the provider per call', () async {
      await FluentDb.saveAll<Comment>([Comment(text: 'a'), Comment(text: 'b')]);
      final Comment first = (await FluentDb.findFirst<Comment>(orderBy: 'id'))!;
      expect(await FluentDb.delete<Comment>(first), 1);
      expect(await FluentDb.count<Comment>(), 1);
      expect((await FluentDb.trash<Comment>().find()).map((c) => c.text), ['a']);
      expect((await FluentDb.withTrash<Comment>().findAll()).length, 2);
      expect(await FluentDb.trash<Comment>().restore(first), 1);
      expect(await FluentDb.count<Comment>(), 2);
    });

    test('trash on an unknown database fails through the future, not synchronously', () async {
      final trash = FluentDb.trash<Comment>(dbKey: FluentDbKey('nope'));
      await expectLater(trash.find(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
    });
  });

  group('lookup errors go through futures and streams', () {
    setUp(() async {
      await open();
    });

    test('an unregistered model type', () async {
      await expectLater(FluentDb.find<Stranger>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound).having((e) => e.hint, 'hint', contains('Stranger'))));
      await expectLater(FluentDb.watch<Stranger>(), emitsError(isA<FluentConfigException>()));
      await expectLater(FluentDb.watchById<Stranger>(1), emitsError(isA<FluentConfigException>()));
      await expectLater(FluentDb.save<Stranger>(Stranger()), throwsA(isA<FluentConfigException>()));
      await expectLater(FluentDb.updateAll<Stranger>([Stranger()]), throwsA(isA<FluentConfigException>()));
    });

    test('a dbKey that has no such database', () async {
      await expectLater(
        FluentDb.find<Gadget>(dbKey: FluentDbKey('elsewhere')),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen).having((e) => e.message, 'message', contains('"elsewhere"'))),
      );
    });

    test('providerForTable, lookupByTable, providersOf, providerForType', () async {
      expect(FluentDbInternals.providerForTable('gadgets', dbName: db.name), isA<GadgetProvider>());
      expect(FluentDbInternals.providerForTable('gadgets'), isA<GadgetProvider>());
      expect(FluentDbInternals.lookupByTable('gadgets', db.name), isNotNull);
      expect(FluentDbInternals.lookupByTable('nothing', db.name), isNull);
      expect(FluentDbInternals.lookupByTable('gadgets', 'other'), isNull);
      expect(FluentDbInternals.providersOf(db.name), hasLength(4));
      expect(FluentDbInternals.providersOf('other'), isEmpty);
      expect(FluentDbInternals.providerForType(Gadget), isA<GadgetProvider>());
      expect(() => FluentDbInternals.providerForTable('nothing'), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound)));
      expect(() => FluentDbInternals.providerForTable('nothing', dbName: db.name), throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', contains('FluentGroup'))));
    });

    test('provider<P>() finds by provider class', () async {
      expect(FluentDb.provider<GadgetProvider>(), isA<GadgetProvider>());
      expect(FluentDb.provider<PageProvider>(dbKey: db.key), isA<PageProvider>());
      expect(() => FluentDb.provider<PersonProvider>(), throwsA(isA<FluentConfigException>()));
    });
  });

  group('before init', () {
    test('every call fails with notInitialized through its future', () async {
      db = FluentTestDb();
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      await expectLater(FluentDb.find<Gadget>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await expectLater(FluentDb.save<Gadget>(Gadget(name: 'x')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await expectLater(FluentDb.clear(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await expectLater(FluentDb.clear(dbKey: FluentDbKey('x')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
      // G25: a named database that is not open is never skipped silently.
      await expectLater(FluentDb.cleanOrphans(dbKey: FluentDbKey('x')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
      await expectLater(FluentDb.schemaReport(dbKey: FluentDbKey('x')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
      await expectLater(FluentDb.transaction(() async => 1), throwsA(isA<FluentArgumentException>()));
      expect(FluentDb.isOpen(), isFalse);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('x')), isFalse);
      expect(await FluentDb.schemaReport(), isEmpty);
    });
  });

  group('ambiguous providers', () {
    test('one model in two tables of a database cannot be found by type, the hint says what to do', () async {
      await open([GadgetProvider('g1'), GadgetProvider('g2')]);
      await expectLater(
        FluentDb.find<Gadget>(),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.ambiguousProvider).having((e) => e.hint, 'hint', contains('Keep a reference to each provider instance'))),
      );
      await expectLater(
        FluentDb.find<Gadget>(dbKey: db.key),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.ambiguousProvider)),
      );
      expect(() => FluentDb.provider<GadgetProvider>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.ambiguousProvider)));
      // The table lookup still works.
      expect(FluentDbInternals.providerForTable('g2'), isA<GadgetProvider>());
    });

    test('two provider classes for one model: the hint names the provider call', () async {
      await open([GadgetProvider('g1'), OtherGadgetProvider('g2')]);
      await expectLater(
        FluentDb.count<Gadget>(),
        throwsA(isA<FluentConfigException>().having((e) => e.hint, 'hint', contains('FluentDb.provider<'))),
      );
      expect(FluentDb.provider<OtherGadgetProvider>(), isA<OtherGadgetProvider>());
    });

    test('the same model in two databases needs a dbKey', () async {
      db = FluentTestDb(name: 'amb_unused');
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('amb_one'), providerList: [GadgetProvider('same_a')], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('amb_two'), providerList: [GadgetProvider('same_b')], inMemory: true),
      ]);
      addTearDown(() async {
        await FluentDb.close();
        FluentDbInternals.reset();
      });
      await expectLater(
        FluentDb.find<Gadget>(),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.ambiguousProvider).having((e) => e.message, 'message', allOf(contains('amb_one'), contains('amb_two')))),
      );
      await FluentDb.save<Gadget>(Gadget(name: 'in one'), dbKey: FluentDbKey('amb_one'));
      expect(await FluentDb.count<Gadget>(dbKey: FluentDbKey('amb_one')), 1);
      expect(await FluentDb.count<Gadget>(dbKey: FluentDbKey('amb_two')), 0);
      expect(FluentDb.isOpen(dbKey: FluentDbKey('amb_two')), isTrue);
    });
  });

  group('collections across databases', () {
    test('items of two databases are written in their own transactions and reported as crossDatabase', () async {
      db = FluentTestDb(name: 'cross_unused');
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      final issues = <FluentIssue>[];
      final sub = FluentDb.onIssue().listen(issues.add);
      FluentLog.forgetIssues();
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('cross_a'), providerList: [GadgetProvider()], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('cross_b'), providerList: [PageProvider()], inMemory: true),
      ]);
      addTearDown(() async {
        await sub.cancel();
        await FluentDb.close();
        FluentDbInternals.reset();
      });
      await FluentDb.saveAll<FluentStorable>([Gadget(name: 'x'), Page(title: 'y')]);
      await Future<void>.delayed(Duration.zero);
      expect(await FluentDb.count<Gadget>(), 1);
      expect(await FluentDb.count<Page>(), 1);
      expect(issues.where((i) => i.kind == FluentIssueKind.crossDatabase), hasLength(1));
      expect(issues.firstWhere((i) => i.kind == FluentIssueKind.crossDatabase).fix, contains('one database group'));
    });
  });

  group('onIssue, report, engineStats, queryStats', () {
    setUp(() async {
      await open();
    });

    test('onIssue filters by type and kind', () async {
      final all = <FluentIssue>[];
      final warnings = <FluentIssue>[];
      final ignored = <FluentIssue>[];
      final s1 = FluentDb.onIssue().listen(all.add);
      final s2 = FluentDb.onIssue(types: {FluentIssueType.warning}).listen(warnings.add);
      final s3 = FluentDb.onIssue(kinds: {FluentIssueKind.ignoredCall}).listen(ignored.add);
      FluentLog.forgetIssues();
      await FluentDb.pendingChanges<Gadget>(); // not syncable: ignoredCall
      await Future<void>.delayed(Duration.zero);
      expect(ignored, hasLength(1));
      expect(all.map((i) => i.kind), contains(FluentIssueKind.ignoredCall));
      expect(warnings.every((i) => i.type == FluentIssueType.warning), isTrue);
      await s1.cancel();
      await s2.cancel();
      await s3.cancel();
    });

    test('report, engineStats and queryStats can be read; forgetQueryStats empties them', () async {
      await FluentDb.save<Gadget>(Gadget(name: 'x'));
      await FluentDb.findAll<Gadget>();
      expect(FluentDb.report(), isA<FluentReport>());
      expect(FluentDb.engineStats().completed, greaterThan(0));
      expect(FluentDb.engineStats().queued, 0);
      FluentDb.forgetQueryStats(dbKey: db.key, table: 'gadgets');
      expect(FluentDb.queryStats(dbKey: db.key, table: 'gadgets').toString(), isNotNull);
      FluentDb.forgetQueryStats();
    });

    test('setupLogging routes records to onRecord and respects the master switch', () async {
      final records = <FluentLogRecord>[];
      FluentDb.setupLogging(enabled: true, console: false, level: FluentLogLevel.debug, onRecord: records.add);
      await FluentDb.count<Gadget>();
      expect(records, isNotEmpty);
      records.clear();
      FluentDb.setupLogging(enabled: false);
      await FluentDb.count<Gadget>();
      expect(records, isEmpty);
    });

    test('pauseQueue holds new calls until resumeQueue', () async {
      await FluentDb.pauseQueue(dbKey: db.key);
      bool done = false;
      final Future<int> pending = FluentDb.count<Gadget>().whenComplete(() => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse);
      FluentDb.resumeQueue(dbKey: db.key);
      expect(await pending, 0);
      await FluentDb.pauseQueue();
      FluentDb.resumeQueue();
    });
  });

  group('sync statics', () {
    setUp(() async {
      await open();
    });

    test('a provider without FluentSyncable: no work, an ignoredCall issue and a failed result', () async {
      final FluentSyncResult<Gadget> result = await FluentDb.syncWithServer<Gadget>(onPush: (b) async => const FluentPushResult.accepted());
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not use FluentSyncable'));
      expect(await FluentDb.pendingChanges<Gadget>(), 0);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall).map((i) => i.title), anyElement(contains('does not sync')));
      expect(db.issues.firstWhere((i) => i.kind == FluentIssueKind.ignoredCall).fix, contains('with FluentSyncable<Gadget>'));
    });

    test('watchSyncStatus of a table that does not sync is an error event with a hint', () async {
      await expectLater(
        FluentDb.watchSyncStatus<Gadget>(),
        emitsError(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.syncNotSupported).having((e) => e.hint, 'hint', contains('with FluentSyncable<Gadget>'))),
      );
    });

    test('a syncable provider: pendingChanges counts, syncWithServer pushes and pulls, status streams', () async {
      await FluentDb.saveAll<Remote>([Remote(name: 'r1'), Remote(name: 'r2')]);
      expect(await FluentDb.pendingChanges<Remote>(), 2);
      expect(await FluentDb.pendingChanges<Remote>(where: FluentFilter.eq('name', 'r1')), 1);
      final statuses = <FluentSyncStatus>[];
      final sub = FluentDb.watchSyncStatus<Remote>().listen(statuses.add);
      int pushed = 0;
      final FluentSyncResult<Remote> result = await FluentDb.syncWithServer<Remote>(
        onPush: (batch) async {
          pushed += batch.changed.length;
          return const FluentPushResult.accepted();
        },
        onPull: (request) async => FluentPullResult<Remote>(items: [Remote(id: 50, name: 'server')]),
      );
      expect(result.isSuccess, isTrue);
      expect(pushed, 2);
      expect(result.pulled, 1);
      expect(await FluentDb.pendingChanges<Remote>(), 0);
      expect((await FluentDb.findById<Remote>(50))?.name, 'server');
      await db.settle();
      expect(statuses, isNotEmpty);
      await sub.cancel();
    });

    test('watchRemote emits the cache, then the server answer', () async {
      await FluentDb.save<Remote>(Remote(name: 'cached'));
      final events = <FluentRemoteEvent<Remote>>[];
      final sub = FluentDb.watchRemote<Remote>(fetch: () async => FluentRemoteResponse<Remote>([Remote(id: 9, name: 'fresh')])).listen(events.add);
      await db.settle();
      expect(events, isNotEmpty);
      expect((await FluentDb.findById<Remote>(9))?.name, 'fresh');
      await sub.cancel();
    });

    test('watchRemote of an unregistered model is an error event', () async {
      await expectLater(
        FluentDb.watchRemote<Stranger>(fetch: () async => const FluentRemoteResponse<Stranger>(<Stranger>[])),
        emitsError(isA<FluentConfigException>()),
      );
    });
  });

  group('transaction', () {
    test('commits together, rolls back on error, and nested calls join', () async {
      await open();
      await expectLater(
        FluentDb.transaction(() async {
          await FluentDb.save<Gadget>(Gadget(name: 'in tx'));
          await FluentDb.transaction(() async => FluentDb.save<Gadget>(Gadget(name: 'nested')));
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(await FluentDb.count<Gadget>(), 0);
      final int n = await FluentDb.transaction(() async {
        await FluentDb.save<Gadget>(Gadget(name: 'one'));
        await FluentDb.save<Gadget>(Gadget(name: 'two'));
        return FluentDb.count<Gadget>();
      });
      expect(n, 2);
    });

    test('several open groups need a dbKey; an unknown group is refused', () async {
      db = FluentTestDb(name: 'tx_unused');
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      await FluentDb.init([
        FluentGroup(dbKey: FluentDbKey('tx_a'), providerList: [GadgetProvider()], inMemory: true),
        FluentGroup(dbKey: FluentDbKey('tx_b'), providerList: [PageProvider()], inMemory: true),
      ]);
      addTearDown(() async {
        await FluentDb.close();
        FluentDbInternals.reset();
      });
      await expectLater(
        FluentDb.transaction(() async => 1),
        throwsA(isA<FluentArgumentException>().having((e) => '${e.message} ${e.cause}', 'message', anything)),
      );
      await expectLater(FluentDb.transaction(() async => 1, dbKey: FluentDbKey('tx_c')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
      expect(await FluentDb.transaction(() async => FluentDb.count<Gadget>(), dbKey: FluentDbKey('tx_a')), 0);
      await FluentDb.transaction(() async {
        await FluentDb.save<Gadget>(Gadget(name: 'a'), dbKey: FluentDbKey('tx_a'));
      }, dbKey: FluentDbKey('tx_a'));
      expect(await FluentDb.count<Gadget>(dbKey: FluentDbKey('tx_a')), 1);
    });

    test('close, restart and deleteDatabases called inside a transaction are ignored with an ignoredCall issue', () async {
      await open();
      await FluentDb.transaction(() async {
        await FluentDb.close();
        await FluentDb.restart();
        await FluentDb.deleteDatabases();
        await FluentDb.save<Gadget>(Gadget(name: 'still open'));
      });
      expect(FluentDb.isOpen(), isTrue);
      expect(await FluentDb.count<Gadget>(), 1);
      final calls = db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall).map((i) => i.title).toList();
      expect(calls, hasLength(3));
      expect(calls, containsAll([contains('FluentDb.close'), contains('FluentDb.restart'), contains('FluentDb.deleteDatabases')]));
    });
  });

  group('clear', () {
    test('deletes every row of the database, keeps tables, and wakes watchers', () async {
      await open();
      await seed();
      await FluentDb.save<Page>(Page(title: 'p'));
      final lists = <int>[];
      final sub = FluentDb.watch<Gadget>().listen((l) => lists.add(l.length));
      await db.settle();
      expect(lists.last, 4);
      await FluentDb.clear();
      await db.settle();
      expect(await FluentDb.count<Gadget>(), 0);
      expect(await FluentDb.count<Page>(), 0);
      expect(lists.last, 0);
      await FluentDb.clear(dbKey: db.key);
      await sub.cancel();
    });

    test('an unknown database is refused with databaseNotOpen and a list of the open ones', () async {
      await open();
      await expectLater(
        FluentDb.clear(dbKey: FluentDbKey('ghost')),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen).having((e) => e.hint, 'hint', contains(db.name))),
      );
    });

    test('a database whose connection was closed behind the library is reported, not claimed cleared', () async {
      final g = GadgetProvider();
      await open([g]);
      await g.db.close();
      await expectLater(FluentDb.clear(), throwsA(anything));
    });
  });

  group('schemaReport and purgeArchivedColumns', () {
    test('schemaReport lists tables; a dbKey filters; inside a transaction it reads through it', () async {
      await open();
      final reports = await FluentDb.schemaReport();
      expect(reports.single.database, db.name);
      expect(reports.single.tables.map((t) => t.table), containsAll(['gadgets', 'comments']));
      await expectLater(FluentDb.schemaReport(dbKey: FluentDbKey('other')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)), reason: 'G25: an unknown dbKey is refused, not skipped');
      final inTx = await FluentDb.transaction(() => FluentDb.schemaReport(dbKey: db.key));
      expect(inTx.single.tables, isNotEmpty);
    });

    test('schemaReport skips a closed connection; purgeArchivedColumns skips unknown and closed databases', () async {
      final g = GadgetProvider();
      await open([g]);
      await expectLater(FluentDb.purgeArchivedColumns(olderThan: Duration.zero, dbKey: FluentDbKey('other')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
      await FluentDb.purgeArchivedColumns(olderThan: Duration.zero);
      await g.db.close();
      expect(await FluentDb.schemaReport(), isEmpty);
      await FluentDb.purgeArchivedColumns(olderThan: Duration.zero);
      expect(FluentDb.isOpen(dbKey: db.key), isFalse);
    });
  });

  group('cleanOrphans and configure', () {
    test('cleanOrphans for one database and for all', () async {
      await open();
      await FluentDb.cleanOrphans();
      await FluentDb.cleanOrphans(dbKey: db.key);
      await expectLater(FluentDb.cleanOrphans(dbKey: FluentDbKey('other')), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.databaseNotOpen)));
    });

    test('configure replaces the settings and config reads them back', () async {
      await open();
      final FluentConfig before = FluentDb.config;
      addTearDown(() => FluentDb.configure(before));
      FluentDb.configure(const FluentConfig(optimizeInterval: null, trashPurgeInterval: null));
      expect(FluentDb.config.optimizeInterval, isNull);
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      await db.settle();
      FluentDb.configure(const FluentConfig(optimizeInterval: Duration(hours: 1), trashPurgeInterval: Duration(hours: 2)));
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: true));
      await db.settle();
    });
  });
}
