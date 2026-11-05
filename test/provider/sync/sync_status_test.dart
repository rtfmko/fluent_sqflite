// watchRemote(maxAge), sync status stream, sync retries, schema hints at init.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

enum Mood { calm, busy }

class Task extends FluentStorable {
  Task({this.id, required this.title, this.owner = 0, this.mood = Mood.calm});

  final int? id;
  final String title;
  final int owner;
  final Mood mood;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'owner': owner, 'mood': mood};

  // mood has no enumValues on purpose (schema hint); owner / owner+title make the first index redundant.
  @override
  List<FluentIndex> get indexes => const [FluentIndex(['owner']), FluentIndex(['owner', 'title']), FluentIndex(['id'])];
}

class TaskProvider extends FluentProvider<Task> with FluentSyncable<Task> {
  @override
  String get tableName => 'tasks';

  @override
  Task get modelSample => Task(title: '');

  @override
  Task fromCacheJson(Map<String, dynamic> json) => Task(id: json['id'] as int?, title: json['title'] as String, owner: json['owner'] as int);
}

Future<void> pumpUntil(bool Function() done) async {
  for (int i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late TaskProvider tasks;

  setUp(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    db = FluentTestDb(name: 'sync_status_${DateTime.now().microsecondsSinceEpoch}');
    tasks = TaskProvider();
    await db.open([tasks]);
  });

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  group('watchRemote(maxAge)', () {
    int calls = 0;
    Future<FluentRemoteResponse<Task>> api() async {
      calls++;
      return FluentRemoteResponse([Task(id: 1, title: 'from api $calls')]);
    }

    setUp(() => calls = 0);

    Future<List<FluentRemoteEvent<Task>>> run({Duration? maxAge, FluentFilter? where, FluentRemoteStore store = FluentRemoteStore.merge}) =>
        tasks.watchRemote(fetch: api, where: where, maxAge: maxAge, store: store, keepWatching: false).toList();

    test('a fresh cache skips the fetch; another query, no maxAge or an old answer fetches', () async {
      const Duration fresh = Duration(minutes: 5);
      expect((await run(maxAge: fresh)).map((e) => e.phase), contains(FluentRemotePhase.fetching));
      final List<FluentRemoteEvent<Task>> cached = await run(maxAge: fresh);
      expect(calls, 1);
      expect(cached.map((e) => e.phase), [FluentRemotePhase.cached, FluentRemotePhase.fresh]);
      expect(cached.last.items.single.title, 'from api 1');

      await run(maxAge: fresh, where: FluentFilter.eq('owner', 0));
      expect(calls, 2, reason: 'another query has its own age');
      await run();
      expect(calls, 3, reason: 'without maxAge (pull to refresh)');
      await run(maxAge: Duration.zero);
      expect(calls, 4, reason: 'older than maxAge');
    });

    test('an answer that was not stored does not make the cache fresh', () async {
      await run(maxAge: const Duration(minutes: 5), store: FluentRemoteStore.none);
      await run(maxAge: const Duration(minutes: 5));
      expect(calls, 2);
    });
  });

  group('sync status', () {
    test('pending changes, syncing, idle with the time, failed with the error', () async {
      final List<FluentSyncStatus> seen = [];
      final sub = FluentDb.watchSyncStatus<Task>().listen(seen.add);
      await pumpUntil(() => seen.isNotEmpty);
      expect(seen.last.state, FluentSyncState.idle);
      expect(seen.last.pending, 0);

      await tasks.save(Task(title: 'local'));
      await pumpUntil(() => seen.last.pending == 1);
      expect(seen.last.hasPending, isTrue);

      final Completer<FluentPushResult<Task>> server = Completer<FluentPushResult<Task>>();
      final Future<FluentSyncResult<Task>> sync = tasks.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) => server.future);
      await pumpUntil(() => seen.last.isSyncing);
      server.complete(const FluentPushResult.accepted());
      await sync;
      await pumpUntil(() => seen.last.state == FluentSyncState.idle && seen.last.pending == 0);
      expect(seen.last.lastSyncedAt, isNotNull);

      await tasks.save(Task(title: 'second'));
      await tasks.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => throw StateError('offline'));
      await pumpUntil(() => seen.last.state == FluentSyncState.failed);
      expect(seen.last.lastError, isA<StateError>());
      expect(seen.last.pending, 1);
      await sub.cancel();
    });

    test('a provider without FluentSyncable gives an error event', () async {
      await expectLater(FluentDb.watchSyncStatus<_Plain>(), emitsError(isA<FluentException>()));
    });
  });

  test('retries: a failing sync is tried again with growing delays', () async {
    await tasks.save(Task(title: 'x'));
    int attempts = 0;
    final FluentSyncResult<Task> result = await tasks.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (_) async => ++attempts >= 3 ? const FluentPushResult.accepted() : const FluentPushResult.failed(),
      retries: 3,
      retryDelay: const Duration(milliseconds: 1),
    );
    expect(result.isSuccess, isTrue);
    expect(attempts, 3);

    await tasks.save(Task(title: 'y'));
    attempts = 0;
    final FluentSyncResult<Task> failed = await tasks.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async {
        attempts++;
        return const FluentPushResult.failed();
      },
      retries: 1, retryDelay: const Duration(milliseconds: 1));
    expect(failed.isSuccess, isFalse);
    expect(attempts, 2, reason: 'one try plus one retry');
  });

  test('schema hints at init: enum without enumValues, redundant indexes, auto-increment keys on synced tables', () async {
    final Set<String> keys = {for (final FluentIssue h in FluentLog.shownHints) h.key};
    final String db = tasks.dbName;
    expect(keys, containsAll(['enumValues:$db:tasks:mood', 'redundantIndex:$db:tasks:owner', 'redundantIndex:$db:tasks:id', 'syncKey:$db:tasks']));
    expect(keys, isNot(contains('redundantIndex:$db:tasks:owner,title')));
  });
}

class _Plain extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': null};
}
