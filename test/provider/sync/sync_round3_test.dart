// Round 3: typed match keys, paged mirror reads, and paging/batching end to end (pull pages, push batches, watchRemote).
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

/// A row with a TEXT server key (`uid`), synced.
class RItem extends FluentStorable {
  RItem({this.id, required this.uid, this.name = ''});

  final int? id;
  final String uid;
  final String name;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['uid']);

  @override
  List<FluentDbColumn> get tableSchema => [
    FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true, isAutoIncrement: true),
    FluentDbColumn(name: 'uid', type: FluentDbDataType.text, isNotNull: true),
    FluentDbColumn(name: 'name', type: FluentDbDataType.text),
  ];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'uid': uid, 'name': name};
}

class RItemProvider extends FluentProvider<RItem> with FluentSyncable<RItem> {
  @override
  String get tableName => 'r_items';

  @override
  RItem get modelSample => RItem(uid: '');

  @override
  RItem fromCacheJson(Map<String, dynamic> json) => RItem(id: json['id'] as int?, uid: json['uid'] as String, name: (json['name'] as String?) ?? '');
}

/// The same row without sync (a plain cache table).
class CItem extends FluentStorable {
  CItem({this.id, required this.uid, this.name = ''});

  final int? id;
  final String uid;
  final String name;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['uid']);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'uid': uid, 'name': name};
}

class CItemProvider extends FluentProvider<CItem> {
  @override
  String get tableName => 'c_items';

  @override
  CItem get modelSample => CItem(uid: '');

  @override
  CItem fromCacheJson(Map<String, dynamic> json) => CItem(id: json['id'] as int?, uid: json['uid'] as String, name: (json['name'] as String?) ?? '');
}

/// Plain integer-keyed syncable rows (push batches, pull pages).
class PNote extends FluentStorable {
  PNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class PNoteProvider extends FluentProvider<PNote> with FluentSyncable<PNote> {
  @override
  String get tableName => 'p_notes';

  @override
  PNote get modelSample => PNote(text: '');

  @override
  PNote fromCacheJson(Map<String, dynamic> json) => PNote(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  group('typed match keys', () {
    late FluentTestDb db;

    tearDown(() => db.close());

    Future<DynamicProvider> open(List<FluentDbColumn> columns, {List<FluentDbColumn> Function()? keys}) async {
      final DynamicProvider provider = DynamicProvider.spec('t_${DateTime.now().microsecondsSinceEpoch}', TableSpec(columns: () => columns, keys: keys));
      db = FluentTestDb(name: 'r3_keys_${DateTime.now().microsecondsSinceEpoch}');
      await db.open([provider]);
      return provider;
    }

    final FluentDbColumn id = FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true, isAutoIncrement: true);

    test('TEXT key column: 1 and "1" are the same value, "01" is another', () async {
      final DynamicProvider p = await open([id, FluentDbColumn(name: 'code', type: FluentDbDataType.text), FluentDbColumn(name: 'v', type: FluentDbDataType.text)]);
      await p.saveAll([
        p.row({'code': 1, 'v': 'a'}),
        p.row({'code': '1', 'v': 'b'}),
        p.row({'code': '01', 'v': 'c'}),
      ], conflictOn: ['code']);
      final List<Map<String, dynamic>> rows = await p.findMaps(orderBy: '"code"');
      expect(rows.map((r) => r['code']).toList(), ['01', '1']);
      expect(rows.firstWhere((r) => r['code'] == '1')['v'], 'b', reason: 'the later row of the same value wins');
      // The stored "1" is found again by the integer 1.
      await p.saveAll([p.row({'code': 1, 'v': 'z'})], conflictOn: ['code']);
      expect(await p.count(), 2);
      expect((await p.findMaps(where: FluentFilter.eq('code', '1'))).single['v'], 'z');
    });

    test('INTEGER key column: 1, "1", "01" and 1.0 are one value', () async {
      final DynamicProvider p = await open([id, FluentDbColumn(name: 'n', type: FluentDbDataType.integer), FluentDbColumn(name: 'v', type: FluentDbDataType.text)]);
      await p.saveAll([
        p.row({'n': 1, 'v': 'a'}),
        p.row({'n': '1', 'v': 'b'}),
        p.row({'n': '01', 'v': 'c'}),
        p.row({'n': 2, 'v': 'd'}),
      ], conflictOn: ['n']);
      expect(await p.count(), 2);
      await p.saveAll([p.row({'n': 1, 'v': 'e'})], conflictOn: ['n']);
      expect(await p.count(), 2, reason: 'the stored 1 is found by the Dart 1');
      expect((await p.findMaps(where: FluentFilter.eq('n', 1))).single['v'], 'e');
    });

    test('null is not the text "null"', () async {
      final DynamicProvider p = await open([id, FluentDbColumn(name: 'label', type: FluentDbDataType.text), FluentDbColumn(name: 'v', type: FluentDbDataType.text)]);
      await p.saveAll([
        p.row({'label': 'null', 'v': 'a'}),
        p.row({'label': null, 'v': 'b'}),
        p.row({'label': null, 'v': 'c'}),
        p.row({'label': 'null', 'v': 'd'}),
      ], conflictOn: ['label']);
      // A missing value never matches (two rows), the text "null" is one value.
      expect(await p.count(), 3);
      expect((await p.findMaps(where: FluentFilter.eq('label', 'null'))).single['v'], 'd');
    });

    test('composite keys compare every column by its own type', () async {
      final DynamicProvider p = await open(
        [FluentDbColumn(name: 'a', type: FluentDbDataType.integer), FluentDbColumn(name: 'b', type: FluentDbDataType.text), FluentDbColumn(name: 'v', type: FluentDbDataType.text)],
        keys: () => [FluentDbColumn(name: 'a', type: FluentDbDataType.integer, isPrimaryKey: true), FluentDbColumn(name: 'b', type: FluentDbDataType.text, isPrimaryKey: true)],
      );
      await p.saveAll([
        p.row({'a': 1, 'b': '1', 'v': 'x'}),
        p.row({'a': '1', 'b': 1, 'v': 'y'}), // the same row
        p.row({'a': 1, 'b': '01', 'v': 'z'}), // another row
        p.row({'a': 2, 'b': '1', 'v': 'w'}),
      ]);
      expect(await p.count(), 3);
      expect((await p.findMaps(where: FluentFilter.eq('b', '1').and(FluentFilter.eq('a', 1)))).single['v'], 'y');
    });
  });

  group('sync with a TEXT server key', () {
    late FluentTestDb db;
    late RItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'r3_text_${DateTime.now().microsecondsSinceEpoch}');
      items = RItemProvider();
      await db.open([items]);
    });

    tearDown(() => db.close());

    test('a pull conflicts with the local change of "7", not of "07"', () async {
      await items.save(RItem(uid: '7', name: 'local'));
      await items.save(RItem(uid: '07', name: 'other'));
      final FluentSyncResult<RItem> result = await items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [RItem(uid: '7', name: 'server7'), RItem(uid: '007', name: 'server007')]),
      );
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(result.conflicts, 1, reason: 'only "7" has a local change; "007" is a new row');
      expect(result.pulled, 1);
      expect((await items.findAll(orderBy: 'uid')).map((r) => '${r.uid}:${r.name}').toList(), ['007:server007', '07:other', '7:local']);
    });

    test('a tombstone of "7" does not hold back "07"', () async {
      await items.save(RItem(uid: '7', name: 'a'));
      await items.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted());
      await items.deleteWhere(FluentFilter.eq('uid', '7'));
      expect(await items.pendingChanges(), 1);
      final FluentSyncResult<RItem> result = await items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [RItem(uid: '07', name: 'new'), RItem(uid: '7', name: 'back')]),
      );
      expect(result.conflicts, 1, reason: 'the pending deletion of "7" wins');
      expect((await items.findAll()).map((r) => r.uid).toList(), ['07']);
    });
  });

  group('watchRemote mirror reads the cached keys in pages', () {
    late QueryCounter counter;
    late FluentTestDb db;
    late CItemProvider items;

    setUp(() async {
      counter = await QueryCounter.install();
      db = FluentTestDb(name: 'r3_mirror_${DateTime.now().microsecondsSinceEpoch}');
      items = CItemProvider();
      await db.open([items]);
    });

    tearDown(() async {
      await db.close();
      counter.uninstall();
    });

    test('1300 cached rows, 300 on the server: same result, keys read 500 at a time', () async {
      await items.saveAll([for (int i = 0; i < 1300; i++) CItem(uid: 'u$i', name: 'local')]);
      counter.reset();
      final FluentRemoteEvent<CItem> last = await items
          .watchRemote(
            fetch: () async => FluentRemoteResponse([for (int i = 0; i < 300; i++) CItem(uid: 'u${i * 4}', name: 'server')]),
            store: FluentRemoteStore.mirror,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect(await items.count(), 300);
      expect((await items.findAll()).every((r) => r.name == 'server'), isTrue);
      final int pages = counter.statements.where((s) => s.contains('LIMIT 500')).length;
      expect(pages, 3, reason: '500 + 500 + 300 rows');
    });

    test('a page boundary right at the end and an empty answer', () async {
      await items.saveAll([for (int i = 0; i < 1000; i++) CItem(uid: 'u$i')]);
      await items.watchRemote(fetch: () async => const FluentRemoteResponse<CItem>([]), store: FluentRemoteStore.mirror, keepWatching: false).last;
      expect(await items.count(), 0);
    });

    test('the TEXT key "01" and "1" are different rows for mirror', () async {
      await items.saveAll([CItem(uid: '1'), CItem(uid: '01')]);
      await items.watchRemote(fetch: () async => FluentRemoteResponse([CItem(uid: '1')]), store: FluentRemoteStore.mirror, keepWatching: false).last;
      expect((await items.findAll()).map((r) => r.uid).toList(), ['1']);
    });
  });

  group('push in batches', () {
    late FluentTestDb db;
    late PNoteProvider notes;

    setUp(() async {
      db = FluentTestDb(name: 'r3_push_${DateTime.now().microsecondsSinceEpoch}');
      notes = PNoteProvider();
      await db.open([notes]);
      await notes.saveAll([for (int i = 1; i <= 1200; i++) PNote(id: i, text: 'n$i')]);
    });

    tearDown(() => db.close());

    test('1200 rows go in 3 batches of 500 / 500 / 200, in key order', () async {
      final List<List<int?>> sizes = [];
      final FluentSyncResult<PNote> result = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sizes.add([batch.changed.length, batch.changed.first.id, batch.changed.last.id]);
          return const FluentPushResult.accepted();
        },
      );
      expect(result.isSuccess, isTrue);
      expect(result.pushed, 1200);
      expect(sizes, [
        [500, 1, 500],
        [500, 501, 1000],
        [200, 1001, 1200],
      ]);
      expect(await notes.pendingChanges(), 0);
    });

    test('rows rejected in one batch do not block the others and stay pending', () async {
      final FluentSyncResult<PNote> result = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async => FluentPushResult.accepted(rejected: [for (final PNote n in batch.changed) if (n.id == 7 || n.id == 600) n.id!]),
      );
      expect(result.isSuccess, isTrue);
      expect(result.pushed, 1198);
      expect(result.rejected, 2);
      expect(await notes.pendingChanges(), 2);
    });

    test('a failure in batch 2 keeps batch 1 synced; the next sync sends the rest', () async {
      int calls = 0;
      final FluentSyncResult<PNote> failed = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          calls++;
          if (calls == 2) return FluentPushResult.failed(StateError('server down'));
          return const FluentPushResult.accepted();
        },
      );
      expect(failed.isSuccess, isFalse);
      expect(failed.pushed, 500);
      expect(await notes.pendingChanges(), 700);

      final List<int> sent = [];
      final FluentSyncResult<PNote> again = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sent.add(batch.changed.length);
          return const FluentPushResult.accepted();
        },
      );
      expect(again.isSuccess, isTrue);
      expect(sent, [500, 200]);
      expect(await notes.pendingChanges(), 0);
    });

    test('a throw in batch 2 is a failed result, batch 1 stays synced', () async {
      int calls = 0;
      final FluentSyncResult<PNote> failed = await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          if (++calls == 2) throw TimeoutException('slow');
          return const FluentPushResult.accepted();
        },
      );
      expect(failed.isSuccess, isFalse);
      expect(await notes.pendingChanges(), 700);
    });
  });

  group('pull in pages', () {
    late FluentTestDb db;
    late PNoteProvider notes;

    setUp(() async {
      db = FluentTestDb(name: 'r3_pull_${DateTime.now().microsecondsSinceEpoch}');
      notes = PNoteProvider();
      await db.open([notes]);
    });

    tearDown(() => db.close());

    FluentPullResult<PNote> pageOf(int from, int to, {bool more = false, Object? cursor}) =>
        FluentPullResult(items: [for (int i = from; i <= to; i++) PNote(id: i, text: 'p$i')], hasMore: more, cursor: cursor, serverTime: DateTime.utc(2030));

    test('three pages with a cursor, each stored when it arrives, since moves after the last', () async {
      final List<String> seen = [];
      final FluentSyncResult<PNote> result = await notes.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (request) async {
          seen.add('${request.page}:${request.cursor}');
          if (request.page > 0) expect(await notes.lastPull(), isNull, reason: 'since moves only after the last page');
          return switch (request.page) {
            0 => pageOf(1, 100, more: true, cursor: 'c1'),
            1 => pageOf(101, 200, more: true, cursor: 'c2'),
            _ => pageOf(201, 250),
          };
        },
      );
      expect(result.isSuccess, isTrue);
      expect(result.pulled, 250);
      expect(seen, ['0:null', '1:c1', '2:c2']);
      expect(await notes.count(), 250);
      expect((await notes.lastPull())!.toUtc(), DateTime.utc(2030));
      expect(await notes.pendingChanges(), 0);
    });

    test('an empty page in the middle and an empty last page', () async {
      final FluentSyncResult<PNote> result = await notes.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (request) async => switch (request.page) {
          0 => pageOf(1, 10, more: true, cursor: 1),
          1 => const FluentPullResult(hasMore: true, cursor: 2),
          2 => pageOf(11, 12, more: true, cursor: 3),
          _ => const FluentPullResult(),
        },
      );
      expect(result.isSuccess, isTrue);
      expect(result.pulled, 12);
    });

    test('a failing page keeps the earlier pages and does not move since', () async {
      final FluentSyncResult<PNote> result = await notes.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (request) async {
          if (request.page == 1) throw TimeoutException('lost');
          return pageOf(1, 20, more: true, cursor: 'x');
        },
      );
      expect(result.isSuccess, isFalse);
      expect(await notes.count(), 20);
      expect(await notes.lastPull(), isNull);
    });
  });

  group('watchRemote in pages', () {
    late FluentTestDb db;
    late CItemProvider items;

    setUp(() async {
      db = FluentTestDb(name: 'r3_pages_${DateTime.now().microsecondsSinceEpoch}');
      items = CItemProvider();
      await db.open([items]);
    });

    tearDown(() => db.close());

    FluentRemoteResponse<CItem> page(int from, int to, {bool more = false, Object? cursor}) => FluentRemoteResponse([for (int i = from; i <= to; i++) CItem(uid: 'u$i', name: 'server')], hasMore: more, cursor: cursor);

    test('pages are stored as they arrive; mirror deletes only after the last page', () async {
      await items.saveAll([for (int i = 1; i <= 10; i++) CItem(uid: 'u$i', name: 'local')]);
      final List<String> requests = [];
      final List<int> counts = [];
      final List<FluentRemoteEvent<CItem>> events = await items
          .watchRemote(
            fetchPage: (request) async {
              requests.add('${request.page}:${request.cursor}');
              counts.add(await items.count()); // the rows before this page is stored
              return switch (request.page) {
                0 => page(1, 3, more: true, cursor: 'a'),
                1 => page(4, 5, more: true, cursor: 'b'),
                _ => page(6, 7),
              };
            },
            store: FluentRemoteStore.mirror,
            keepWatching: false,
          )
          .toList();
      expect(requests, ['0:null', '1:a', '2:b']);
      expect(counts, [10, 10, 10], reason: 'nothing is deleted before the last page');
      expect(events.last.phase, FluentRemotePhase.fresh);
      expect((await items.findAll(orderBy: 'id')).map((r) => r.uid).toList(), ['u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7']);
      expect(events.where((e) => e.isFetching).length, greaterThanOrEqualTo(3), reason: 'a fetching event follows each stored page');
    });

    test('a page that fails keeps the stored pages and deletes nothing', () async {
      await items.saveAll([for (int i = 1; i <= 10; i++) CItem(uid: 'u$i', name: 'local')]);
      final FluentRemoteEvent<CItem> last = await items
          .watchRemote(
            fetchPage: (request) async {
              if (request.page == 1) throw TimeoutException('lost');
              return page(1, 3, more: true, cursor: 'a');
            },
            store: FluentRemoteStore.mirror,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.failed);
      expect(last.error, isA<FluentSyncException>().having((e) => e.cause, 'cause', isA<TimeoutException>()).having((e) => e.hint, 'hint', isNotEmpty));
      expect(await items.count(), 10, reason: 'the rows missing on the server are still there');
      expect((await items.find(where: FluentFilter.eq('name', 'server'))).length, 3);
    });

    test('a failing page is retried on its own', () async {
      int attempts = 0;
      final FluentRemoteEvent<CItem> last = await items
          .watchRemote(
            fetchPage: (request) async {
              if (request.page == 1 && ++attempts == 1) throw TimeoutException('once');
              return request.page == 0 ? page(1, 2, more: true, cursor: 1) : page(3, 4);
            },
            retries: 1,
            retryDelay: const Duration(milliseconds: 1),
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect(await items.count(), 4);
    });

    test('cancelling between pages stops the fetch and deletes nothing', () async {
      await items.saveAll([for (int i = 1; i <= 5; i++) CItem(uid: 'u$i', name: 'local')]);
      final Completer<FluentRemoteResponse<CItem>> second = Completer();
      int fetches = 0;
      final StreamSubscription<FluentRemoteEvent<CItem>> sub = items
          .watchRemote(
            fetchPage: (request) {
              fetches++;
              return request.page == 0 ? Future.value(page(1, 2, more: true, cursor: 1)) : second.future;
            },
            store: FluentRemoteStore.mirror,
          )
          .listen((_) {});
      while (fetches < 2) {
        await pumpEventQueue();
      }
      unawaited(sub.cancel());
      second.complete(FluentRemoteResponse([CItem(uid: 'late')]));
      await pumpEventQueue();
      await db.settle();
      expect(fetches, 2);
      expect(await items.count(), 5, reason: 'the last page was never stored, so nothing was deleted');
      expect(await items.find(where: FluentFilter.eq('uid', 'late')), isEmpty);
    });

    test('the first page empty and final, and an empty last page after data', () async {
      await items.save(CItem(uid: 'old'));
      await items.watchRemote(fetchPage: (_) async => const FluentRemoteResponse<CItem>([]), store: FluentRemoteStore.mirror, keepWatching: false).last;
      expect(await items.count(), 0);

      final FluentRemoteEvent<CItem> last = await items
          .watchRemote(fetchPage: (r) async => r.page == 0 ? page(1, 2, more: true, cursor: 1) : const FluentRemoteResponse<CItem>([]), store: FluentRemoteStore.mirror, keepWatching: false)
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect(await items.count(), 2);
    });

    test('store none collects every page', () async {
      final FluentRemoteEvent<CItem> last = await items
          .watchRemote(
            fetchPage: (r) async => switch (r.page) {
              0 => page(1, 2, more: true, cursor: 1),
              1 => page(3, 4, more: true, cursor: 2),
              _ => page(5, 5),
            },
            store: FluentRemoteStore.none,
          )
          .last;
      expect(last.items.map((r) => r.uid).toList(), ['u1', 'u2', 'u3', 'u4', 'u5']);
      expect(await items.count(), 0);
    });

    test('a server that never ends fails the fetch instead of looping', () async {
      final FluentRemoteEvent<CItem> last = await items.watchRemote(fetchPage: (r) async => FluentRemoteResponse<CItem>(const [], hasMore: true, cursor: r.page), store: FluentRemoteStore.none, keepWatching: false).last;
      expect(last.phase, FluentRemotePhase.failed);
      expect(last.error, isA<FluentSyncException>());
    });

    test('fetch alone still works, and neither fetch nor fetchPage is a typed error', () async {
      final FluentRemoteEvent<CItem> last = await items.watchRemote(fetch: () async => page(1, 2), keepWatching: false).last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect(items.watchRemote(), emitsError(isA<FluentArgumentException>()));
    });
  });
}
