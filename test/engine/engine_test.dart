// Engine scheduling: writes keep call order, merged saves stay isolated, identical reads collapse, lookups batch.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  late CommentProvider comments;

  setUp(() async {
    db = FluentTestDb(name: 'engine_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);
    comments = CommentProvider();
    await db.open([users, comments]);
  });

  tearDown(() => db.close());

  DynamicModel u(int id, String email, String name) => users.row({'id': id, 'email': email, 'name': name});

  /// Holds the database's write slot until the returned completer completes: calls made meanwhile queue up.
  Future<Completer<void>> hold() async {
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    unawaited(
      FluentDb.transaction(() async {
        started.complete();
        await release.future;
      }),
    );
    await started.future;
    return release;
  }

  test('reads without relations weigh least; deeper relation levels weigh more', () {
    FluentTask read(int depth, {bool all = false}) => FluentTask(action: FluentDbAction.find, table: 't', maxDepth: depth, ignoreLazy: all);
    expect(read(0).staticWeight, lessThanOrEqualTo(read(1).staticWeight));
    expect(read(1).staticWeight, lessThan(read(3).staticWeight));
    expect(read(1, all: true).staticWeight, greaterThan(read(1).staticWeight));
    final FluentTask copy = read(0).copyWith(id: 7);
    expect(copy.fingerprint, read(0).fingerprint, reason: 'the id is not part of the fingerprint');
  });

  test('an unbounded find never weighs less than a filtered or a limited one (known bug 2)', () {
    FluentTask find([TableHelper? helper]) => FluentTask(action: FluentDbAction.find, table: 't', helper: helper);
    final FluentTask unfiltered = find();
    final FluentTask filtered = find(TableHelper(where: '"a" = ?', whereArgs: const [1]));
    final FluentTask limited = find(TableHelper(where: '"a" = ?', whereArgs: const [1], limit: 10));
    expect(unfiltered.staticWeight, greaterThanOrEqualTo(filtered.staticWeight));
    expect(filtered.staticWeight, greaterThan(limited.staticWeight));
    expect(unfiltered.staticWeight, greaterThan(limited.staticWeight));
  });

  test('a flood of lookups is answered by few IN queries and keeps priorities', () async {
    await users.saveAll([for (int i = 1; i <= 300; i++) u(i, 'm$i@x', 'U$i')]);
    final Completer<void> release = await hold();
    final List<Future<DynamicModel?>> found = [for (int i = 1; i <= 300; i++) users.findById(i)];
    final Future<int> urgent = users.count(policy: ExecutionPolicy.fast);
    final int before = FluentDb.engineStats().batchedLookups;
    release.complete();
    expect((await Future.wait(found)).every((m) => m != null), isTrue);
    expect(await urgent, 300);
    expect(FluentDb.engineStats().batchedLookups - before, greaterThanOrEqualTo(290));
  });

  test('writes keep call order: delete then save leaves the saved row', () async {
    await users.save(u(1, 'a@x', 'old'));
    final Completer<void> release = await hold();
    final Future<int> deleted = users.deleteById(1);
    final Future<FluentSaveResult> saved = users.save(u(1, 'a@x', 'new'));
    release.complete();
    await Future.wait([deleted, saved]);
    expect((await users.findById(1))?['name'], 'new');
  });

  test('a read called after a write sees it', () async {
    final Completer<void> release = await hold();
    unawaited(users.save(u(5, 'e@x', 'five')));
    final Future<DynamicModel?> found = users.findById(5);
    release.complete();
    expect((await found)?['name'], 'five');
  });

  test('a waiting write is not overtaken by later reads of other tables', () async {
    final List<String> order = [];
    final Completer<void> release = await hold();
    final List<Future<void>> calls = [
      users.count().then((_) => order.add('read users')),
      users.save(u(1, 'a@x', 'A')).then((_) => order.add('write users')),
      comments.count().then((_) => order.add('read comments')),
    ];
    release.complete();
    await Future.wait(calls);
    expect(order, ['read users', 'write users', 'read comments']);
  });

  test('a failing call of a merged save fails alone; every call gets its own event tag', () async {
    await users.save(u(1, 'a@x', 'A'));
    final List<Object?> tags = [];
    final StreamSubscription<FluentChangeEvent<DynamicModel>> sub = FluentDb.onEvent<DynamicModel>().listen((e) => tags.add(e.tag));
    final FluentEngineStats before = FluentDb.engineStats();

    final Completer<void> release = await hold();
    final Future<String> good = FluentDb.save<DynamicModel>(u(2, 'b@x', 'good'), tag: 'good').then((r) => 'ok', onError: (Object e) => 'failed');
    final Future<String> bad = FluentDb.save<DynamicModel>(u(3, 'a@x', 'dup'), tag: 'bad').then((r) => 'ok', onError: (Object e) => 'failed: ${e.runtimeType}');
    final Future<String> other = FluentDb.save<DynamicModel>(u(4, 'd@x', 'other'), tag: 'other').then((r) => 'ok', onError: (Object e) => 'failed');
    release.complete();

    expect([await good, await bad, await other], ['ok', 'failed: FluentConstraintException', 'ok']);
    expect(await users.count(), 3);
    await pumpEventQueue();
    expect(tags, ['good', 'other']);

    final FluentEngineStats after = FluentDb.engineStats();
    expect(after.mergedSaves - before.mergedSaves, 3);
    expect(after.splitBatches - before.splitBatches, 1);
    await sub.cancel();
  });

  test('identical reads in flight are answered by one query, each caller gets its own list', () async {
    await users.saveAll([u(1, 'a@x', 'A'), u(2, 'b@x', 'B')]);
    final int collapsed = FluentDb.engineStats().collapsedReads;

    final Completer<void> release = await hold();
    final Future<List<DynamicModel>> first = users.findAll(orderBy: 'id');
    final Future<List<DynamicModel>> second = users.findAll(orderBy: 'id');
    release.complete();

    final List<DynamicModel> a = await first;
    final List<DynamicModel> b = await second;
    expect(FluentDb.engineStats().collapsedReads - collapsed, 1);
    expect(identical(a, b), isFalse);
    expect(b.map((m) => m['name']), ['A', 'B']);
  });

  test('queued findById calls of one table share one IN query', () async {
    await users.saveAll([u(1, 'a@x', 'A'), u(2, 'b@x', 'B'), u(3, 'c@x', 'C')]);
    final int batched = FluentDb.engineStats().batchedLookups;

    final Completer<void> release = await hold();
    final List<Future<DynamicModel?>> lookups = [users.findById(3), users.findById(1), users.findById(99), users.findById(2)];
    release.complete();

    expect([for (final DynamicModel? m in await Future.wait(lookups)) m?['name']], ['C', 'A', null, 'B']);
    expect(FluentDb.engineStats().batchedLookups - batched, 4);
  });

  test('engine stats report the queue', () async {
    final Completer<void> release = await hold();
    final Future<int> pending = users.count();
    final FluentEngineStats busy = FluentDb.engineStats();
    expect(busy.queued, greaterThanOrEqualTo(1));
    expect(busy.activeWrites, 1);
    release.complete();
    await pending;
    expect(FluentDb.engineStats().maxWaitMs, greaterThanOrEqualTo(0));
  });

  test('a read called after a write is never answered by an earlier read', () async {
    final Completer<void> release = await hold();
    final Future<List<DynamicModel>> before = users.findAll();
    unawaited(users.save(u(1, 'a@x', 'A')));
    final Future<List<DynamicModel>> after = users.findAll();
    release.complete();
    expect(await before, isEmpty);
    expect((await after).map((m) => m['name']), ['A']);
  });

  test('closing lets the calls already made finish; later calls fail clearly', () async {
    await users.save(u(1, 'a@x', 'A'));
    final Completer<void> release = await hold();
    final Future<int> queued = users.count();
    final Future<void> closing = FluentTestDb.closeCurrent();
    release.complete();
    await closing;
    expect(await queued, 1);
    await expectLater(users.count(), throwsA(anything));
  });

  test('pauseQueue inside a transaction is cancelled instead of waiting for itself', () async {
    await FluentDb.transaction(() async {
      await FluentDb.pauseQueue().timeout(const Duration(seconds: 2));
      await users.save(u(1, 'a@x', 'A'));
    });
    expect(await users.count(), 1, reason: 'the queue keeps running');
  });

  test('the transaction watchdog runs waiting reads inside a transaction that awaits them', () async {
    await users.save(u(1, 'a@x', 'A'));
    final int adopted = FluentDb.engineStats().adoptedReads;
    final Completer<Future<int>> outside = Completer<Future<int>>();
    // A read made outside the transaction after it started (e.g. by another part of the app) ...
    Timer(const Duration(milliseconds: 50), () => outside.complete(Zone.root.run(() => users.count())));
    final int seen = await FluentDb.transaction(() async {
      await users.save(u(2, 'b@x', 'B'));
      return await (await outside.future); // ... awaited inside: without the watchdog this never finishes.
    }).timeout(const Duration(seconds: 10));
    expect(seen, 2, reason: 'the read ran inside the transaction and sees its write');
    expect(FluentDb.engineStats().adoptedReads - adopted, 1);
  });

  test('thousands of unawaited saves are merged and stay fast', () async {
    final Stopwatch sw = Stopwatch()..start();
    await Future.wait([for (int i = 0; i < 5000; i++) users.save(u(i + 1, '$i@x', 'n$i'))]);
    expect(await users.count(), 5000);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
