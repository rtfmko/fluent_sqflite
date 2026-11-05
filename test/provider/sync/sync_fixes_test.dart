// Sync fixes: replace keeps unpushed edits, server keys of edited rows, deletes during a push, serialized syncs,
// merges racing a local edit, many rejected rows, watchRemote after cancel.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Item extends FluentStorable with FluentSoftDeletable {
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

/// Without soft delete: permanent deletes leave tombstones.
class Note extends FluentStorable {
  Note({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class NoteProvider extends FluentProvider<Note> with FluentSyncable<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

/// A local auto-increment id, and the server's own id (filled when the server knows the row).
class Ticket extends FluentStorable {
  Ticket({this.id, this.serverId, required this.title});

  final int? id;
  final String? serverId;
  final String title;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['server_id']);

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('server_id', isUnique: true), FluentDbColumn.text('title')];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'server_id': serverId, 'title': title};
}

class TicketProvider extends FluentProvider<Ticket> with FluentSyncable<Ticket> {
  @override
  String get tableName => 'tickets';

  @override
  Ticket get modelSample => Ticket(title: '');

  @override
  Ticket fromCacheJson(Map<String, dynamic> json) => Ticket(id: json['id'] as int?, serverId: json['server_id'] as String?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ItemProvider items;
  late NoteProvider notes;
  late TicketProvider tickets;

  setUp(() async {
    db = FluentTestDb(name: 'sync_fixes_${DateTime.now().microsecondsSinceEpoch}');
    items = ItemProvider();
    notes = NoteProvider();
    tickets = TicketProvider();
    await db.open([items, notes, tickets]);
  });

  tearDown(() => db.close());

  Future<FluentSyncResult<M>> pushAll<M extends FluentStorable>(FluentSyncable<M> p, [void Function(FluentSyncBatch<M> batch)? seen]) => p.syncWithServer(
    strategy: FluentSyncStrategy.push,
    onPush: (batch) async {
      seen?.call(batch);
      return const FluentPushResult.accepted();
    },
  );

  group('S1 watchRemote(store: replace)', () {
    test('keeps a local edit not pushed yet, and it stays pending', () async {
      await items.saveAll([Item(id: 1, name: 'a'), Item(id: 3, name: 'gone on server')]);
      await pushAll(items);
      await items.save(Item(id: 1, name: 'edited'));

      final FluentRemoteEvent<Item> last = await items
          .watchRemote(fetch: () async => FluentRemoteResponse([Item(id: 1, name: 'server'), Item(id: 2, name: 'b')]), store: FluentRemoteStore.replace, keepWatching: false)
          .last;
      expect(last.phase, FluentRemotePhase.fresh);
      expect((await items.findAll(orderBy: 'id')).map((i) => i.name), ['edited', 'b'], reason: 'synced rows are replaced, the unpushed edit stays');
      expect(await items.pendingChanges(), 1);
      final List<String> sent = [];
      await pushAll<Item>(items, (b) => sent.addAll(b.changed.map((i) => i.name)));
      expect(sent, ['edited']);
    });

    test('matches by the server key: a busy row is not inserted again (no UNIQUE failure)', () async {
      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Ticket(serverId: 's1', title: 'one')]));
      await tickets.updateWhere(FluentFilter.eq('server_id', 's1'), {'title': 'one (local)'});

      final FluentRemoteEvent<Ticket> last = await tickets
          .watchRemote(
            fetch: () async => FluentRemoteResponse([Ticket(serverId: 's1', title: 'one (server)'), Ticket(serverId: 's2', title: 'two')]),
            store: FluentRemoteStore.replace,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh, reason: '${last.error}');
      expect((await tickets.findAll(orderBy: 'server_id')).map((t) => '${t.serverId}:${t.title}'), ['s1:one (local)', 's2:two']);
    });

    test('matches by the server key rows outside where: updated in place, not duplicated', () async {
      await tickets.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [Ticket(serverId: 's1', title: 'one')]));
      final int id = (await tickets.findFirst())!.id!;

      final FluentRemoteEvent<Ticket> last = await tickets
          .watchRemote(
            fetch: () async => FluentRemoteResponse([Ticket(serverId: 's1', title: 'one v2')]),
            where: FluentFilter.eq('title', 'nothing'),
            store: FluentRemoteStore.replace,
            keepWatching: false,
          )
          .last;
      expect(last.phase, FluentRemotePhase.fresh, reason: '${last.error}');
      final List<Ticket> all = await tickets.findAll();
      expect(all.map((t) => '${t.id}:${t.title}'), ['$id:one v2']);
      expect(await tickets.pendingChanges(), 0, reason: 'stored as synced');
    });
  });

  group('S2 server key of a row edited during its push', () {
    test('is stored without losing the edit; the next push carries it', () async {
      await tickets.save(Ticket(title: 'offline'));
      final FluentSyncResult<Ticket> first = await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          final Ticket t = batch.changed.single;
          await tickets.updateById(t.id!, {'title': 'edited during push'});
          return FluentPushResult.accepted(updated: [Ticket(id: t.id, serverId: 's9', title: t.title)]);
        },
      );
      expect(first.isSuccess, isTrue, reason: first.errorMessage);
      final Ticket stored = (await tickets.findFirst())!;
      expect(stored.serverId, 's9');
      expect(stored.title, 'edited during push');
      expect(await tickets.pendingChanges(), 1, reason: 'the edit is still to be sent');

      final List<Ticket> sent = [];
      await pushAll<Ticket>(tickets, (b) => sent.addAll(b.changed));
      expect(sent.map((t) => '${t.serverId}:${t.title}'), ['s9:edited during push']);
      expect(await tickets.pendingChanges(), 0);
    });

    test('a deletion after that push sends the server key', () async {
      await tickets.save(Ticket(title: 'offline'));
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          final Ticket t = batch.changed.single;
          await tickets.updateById(t.id!, {'title': 'edited'});
          return FluentPushResult.accepted(updated: [Ticket(id: t.id, serverId: 's8', title: t.title)]);
        },
      );
      await pushAll(tickets);
      await tickets.deleteWhere(FluentFilter.eq('server_id', 's8'));
      final List<Object> keys = [];
      await pushAll<Ticket>(tickets, (b) => keys.addAll(b.deletedKeys));
      expect(keys, ['s8']);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tombstoneWithoutKey), isEmpty);
    });

    test('a row not edited during the push gets the server version as synced (unchanged behaviour)', () async {
      await tickets.save(Ticket(title: 'plain'));
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async => FluentPushResult.accepted(updated: [for (final Ticket t in batch.changed) Ticket(id: t.id, serverId: 's7', title: '${t.title} (server)')]),
      );
      final Ticket stored = (await tickets.findFirst())!;
      expect('${stored.serverId}:${stored.title}', 's7:plain (server)');
      expect(await tickets.pendingChanges(), 0);
    });
  });

  group('S3 a permanent delete during the first push of a row', () {
    test('leaves a tombstone (primary key as server key), so the deletion is pushed', () async {
      await notes.save(Note(id: 1, text: 'x'));
      await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          await notes.deleteById(1);
          return const FluentPushResult.accepted();
        },
      );
      expect(await notes.pendingChanges(), 1);
      final List<Object> keys = [];
      await pushAll<Note>(notes, (b) => keys.addAll(b.deletedKeys));
      expect(keys, [1]);
      expect(await notes.pendingChanges(), 0);
    });

    test('uses the server key from the answer, and the answer does not bring the row back', () async {
      await tickets.save(Ticket(title: 'x'));
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          final Ticket t = batch.changed.single;
          await tickets.deleteById(t.id!);
          return FluentPushResult.accepted(updated: [Ticket(id: t.id, serverId: 's5', title: t.title)]);
        },
      );
      expect(await tickets.count(), 0, reason: 'the server answer does not resurrect the deleted row');
      final List<Object> keys = [];
      await pushAll<Ticket>(tickets, (b) => keys.addAll(b.deletedKeys));
      expect(keys, ['s5']);
    });

    test('without a server key in the answer: reported, nothing to send', () async {
      await tickets.save(Ticket(title: 'x'));
      await tickets.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          await tickets.deleteById(batch.changed.single.id!);
          return const FluentPushResult.accepted();
        },
      );
      expect(await tickets.pendingChanges(), 0);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.tombstoneWithoutKey), isNotEmpty);
    });

    test('a refused row deleted during the push leaves no tombstone', () async {
      await notes.save(Note(id: 1, text: 'x'));
      await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          await notes.deleteById(1);
          return const FluentPushResult.accepted(rejected: [1]);
        },
      );
      expect(await notes.pendingChanges(), 0, reason: 'the server never stored it');
    });

    test('a row edited (not deleted) during the push gets no tombstone', () async {
      await notes.save(Note(id: 1, text: 'x'));
      await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          await notes.save(Note(id: 1, text: 'y'));
          return const FluentPushResult.accepted();
        },
      );
      final List<Object> keys = [];
      final List<String> changed = [];
      await pushAll<Note>(notes, (b) {
        keys.addAll(b.deletedKeys);
        changed.addAll(b.changed.map((n) => n.text));
      });
      expect(keys, isEmpty);
      expect(changed, ['y']);
    });
  });

  group('S4 concurrent syncWithServer calls', () {
    test('run one after the other; identical waiting calls share one run', () async {
      final Completer<void> gate = Completer<void>();
      final List<String> log = [];
      int pulls = 0;
      await items.save(Item(id: 1, name: 'a'));
      final Future<FluentSyncResult<Item>> push = items.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (_) async {
          log.add('push start');
          await gate.future;
          log.add('push end');
          return const FluentPushResult.accepted();
        },
      );
      Future<FluentSyncResult<Item>> pull() => items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async {
          pulls++;
          log.add('pull start');
          await Future<void>.value();
          log.add('pull end');
          return const FluentPullResult();
        },
      );
      final Future<FluentSyncResult<Item>> b = pull();
      final Future<FluentSyncResult<Item>> c = pull();
      await db.settle();
      gate.complete();
      final List<FluentSyncResult<Item>> results = await Future.wait([push, b, c]);
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(pulls, 1, reason: 'the second pull waited and shared the first');
      expect(identical(results[1], results[2]), isTrue);
      expect(log, ['push start', 'push end', 'pull start', 'pull end']);
    });

    test('different waiting calls run one at a time', () async {
      final Completer<void> gate = Completer<void>();
      int active = 0, most = 0;
      Future<T> track<T>(Future<T> Function() body) async {
        active++;
        most = active > most ? active : most;
        try {
          return await body();
        } finally {
          active--;
        }
      }

      final Future<FluentSyncResult<Item>> first = items.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) => track(() async {
        await gate.future;
        return const FluentPullResult();
      }));
      final List<Future<FluentSyncResult<Item>>> others = [
        for (int i = 0; i < 3; i++)
          items.syncWithServer(strategy: FluentSyncStrategy.pull, where: FluentFilter.eq('id', i), onPull: (_) => track(() async {
            await items.count(); // a slow server: other calls get the chance to overlap
            await items.count();
            return const FluentPullResult();
          })),
      ];
      await db.settle();
      gate.complete();
      await Future.wait([first, ...others]);
      expect(most, 1);
    });
  });

  group('S5 merge conflicts', () {
    test('a local edit made while the merge runs wins and stays pending', () async {
      await items.save(Item(id: 1, name: 'local'));
      final FluentSyncResult<Item> result = await items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'remote')]),
        conflicts: FluentConflictPolicy.merge((local, remote) async {
          await items.save(Item(id: 1, name: 'newer'));
          return Item(id: 1, name: '${local.name}+${remote.name}');
        }),
      );
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(result.conflicts, 1);
      expect((await items.findById(1))?.name, 'newer');
      expect(await items.pendingChanges(), 1);
    });

    test('a row deleted while the merge runs is not brought back', () async {
      await notes.save(Note(id: 1, text: 'local'));
      await notes.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [Note(id: 1, text: 'remote')]),
        conflicts: FluentConflictPolicy.merge((local, remote) async {
          await notes.deleteById(1);
          return Note(id: 1, text: 'merged');
        }),
      );
      expect(await notes.findById(1), isNull);
    });

    test('an unchanged row gets the merge (unchanged behaviour)', () async {
      await items.save(Item(id: 1, name: 'local'));
      await items.syncWithServer(
        strategy: FluentSyncStrategy.pull,
        onPull: (_) async => FluentPullResult(items: [Item(id: 1, name: 'remote')]),
        conflicts: FluentConflictPolicy.merge((local, remote) async => Item(id: 1, name: '${local.name}+${remote.name}')),
      );
      expect((await items.findById(1))?.name, 'local+remote');
      expect(await items.pendingChanges(), 1);
    });
  });

  group('S7 pendingSyncBatch with many skipped keys', () {
    test('more skipped keys than SQL variables', () async {
      await items.saveAll([Item(id: 1, name: 'a'), Item(id: 2, name: 'b'), Item(id: 3, name: 'c')]);
      final FluentSyncBatch<Item> batch = await items.pendingSyncBatch(skip: [2, for (int i = 1000; i < 41000; i++) i]);
      expect(batch.changed.map((i) => i.id), [1, 3]);
    });

    test('a limit still returns a full batch after the skipped rows', () async {
      await items.saveAll([for (int i = 1; i <= 6; i++) Item(id: i, name: 'i$i')]);
      final FluentSyncBatch<Item> batch = await items.pendingSyncBatch(limit: 2, skip: const [1, 2, 4]);
      expect(batch.changed.map((i) => i.id), [3, 5]);
      final FluentSyncBatch<Item> none = await items.pendingSyncBatch(limit: 2, skip: const [1, 2, 3, 4, 5, 6]);
      expect(none.isEmpty, isTrue);
    });

    test('a push where every batch is refused finishes and counts all of them', () async {
      await items.saveAll([for (int i = 1; i <= 7; i++) Item(id: i, name: 'i$i')]);
      final FluentSyncResult<Item> result = await items.syncWithServer(
        strategy: FluentSyncStrategy.push,
        batchSize: 3,
        onPush: (batch) async => FluentPushResult.accepted(rejected: [for (final Item i in batch.changed) i.id!]),
      );
      expect(result.isSuccess, isTrue);
      expect(result.rejected, 7);
      expect(await items.pendingChanges(), 7);
    });
  });

  group('S8 watchRemote after the listener cancels', () {
    test('no more retries', () async {
      int calls = 0;
      late StreamSubscription<FluentRemoteEvent<Item>> sub;
      Future<void>? cancelled;
      sub = items
          .watchRemote(
            fetch: () async {
              calls++;
              cancelled ??= sub.cancel();
              return const FluentRemoteResponse<Item>.failed(503);
            },
            retries: 3,
            retryDelay: Duration.zero,
          )
          .listen((_) {});
      await db.settle();
      await cancelled;
      expect(calls, 1);
    });

    test('the fetched rows are not stored', () async {
      late StreamSubscription<FluentRemoteEvent<Item>> sub;
      Future<void>? cancelled;
      sub = items
          .watchRemote(
            fetch: () async {
              cancelled ??= sub.cancel();
              return FluentRemoteResponse([Item(id: 1, name: 'late')]);
            },
          )
          .listen((_) {});
      await db.settle();
      await cancelled;
      expect(await items.count(), 0);
    });

    test('a listener that stays gets every phase, also with pause and resume', () async {
      final List<FluentRemotePhase> phases = [];
      final StreamSubscription<FluentRemoteEvent<Item>> sub = items
          .watchRemote(fetch: () async => FluentRemoteResponse([Item(id: 1, name: 'a')]))
          .listen((e) => phases.add(e.phase));
      sub.pause();
      await db.settle();
      sub.resume();
      await db.settle();
      expect(phases, [FluentRemotePhase.cached, FluentRemotePhase.fetching, FluentRemotePhase.fresh]);
      await sub.cancel();
      expect(await items.count(), 1);
    });
  });
}
