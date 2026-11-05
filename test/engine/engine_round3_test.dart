// Round 3 regression tests of the engine: shutdown / pause from inside tasks (ENG-3), failing observer hooks (ENG-10),
// the stats flush timer (OBS-8), configure() during init (DB-11), the analyzer's query plan through the queue and the
// isolate mapping that tries again after a failure.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:isolate';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database, getDatabasesPath, openDatabase;

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  final List<FluentLogRecord> records = [];

  Future<void> openUsers({bool persistent = false, FluentConfig config = const FluentConfig()}) async {
    db = FluentTestDb(name: 'r3_engine_${DateTime.now().microsecondsSinceEpoch}', persistent: persistent);
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);
    await db.open([users], fluentConfig: config);
    records.clear();
    FluentDb.setupLogging(console: false, onRecord: records.add, level: FluentLogLevel.debug, enabled: true);
  }

  DynamicModel u(int id, [String? name]) => users.row({'id': id, 'email': 'u$id@x', 'name': name ?? 'user $id'});

  /// Holds the database's write slot until the returned completer completes.
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

  tearDown(() async {
    FluentEngine.observerProbe = null;
    FluentEngine.statsWriteGate = null;
    FluentEngine.statsFlushInterval = const Duration(minutes: 5);
    FluentAnalyzer.releaseMode = false;
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  Iterable<FluentIssue> ignored() => db.issues.where((i) => i.kind == FluentIssueKind.ignoredCall);

  group('ENG-3: lifecycle calls from inside a task', () {
    setUp(() => openUsers(persistent: true));

    test('FluentDb.close inside a transaction body is ignored and reported; the transaction commits, the database stays open', () async {
      await FluentDb.transaction(() async {
        await users.save(u(1));
        await FluentDb.close().timeout(const Duration(seconds: 5));
        await users.save(u(2)); // still usable in the same transaction
      }).timeout(const Duration(seconds: 10));
      await db.settle();
      expect(FluentDb.isOpen(), isTrue);
      expect(await users.count(), 2);
      expect(ignored().map((i) => i.title), contains(contains('FluentDb.close')));
    });

    test('restart and deleteDatabases inside a transaction are ignored the same way, data is kept', () async {
      await FluentDb.transaction(() async {
        await users.save(u(1));
        await FluentDb.restart().timeout(const Duration(seconds: 5));
        await FluentDb.deleteDatabases().timeout(const Duration(seconds: 5));
      }).timeout(const Duration(seconds: 10));
      expect(await users.count(), 1);
      expect(ignored().where((i) => i.title.contains('FluentDb.restart')), hasLength(1));
      expect(ignored().where((i) => i.title.contains('FluentDb.deleteDatabases')), hasLength(1));
    });

    test('close inside a nested transaction: both levels commit, later calls run', () async {
      await FluentDb.transaction(() async {
        await users.save(u(1));
        await FluentDb.transaction(() async {
          await users.save(u(2));
          await FluentDb.close().timeout(const Duration(seconds: 5));
        });
        await users.save(u(3));
      }).timeout(const Duration(seconds: 10));
      expect(await users.count(), 3);
      expect(FluentDb.isOpen(), isTrue);
    });

    test('a failed (rolled back) transaction that asked to close still rolls back and the database stays open', () async {
      await expectLater(
        FluentDb.transaction(() async {
          await users.save(u(1));
          await FluentDb.close();
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(await users.count(), 0);
      expect(FluentDb.isOpen(), isTrue);
    });

    test('close inside a read task (mapping callback of the provider) is ignored; the read returns its rows', () async {
      final _CloseOnMap provider = _CloseOnMap();
      await db.open([provider]);
      await provider.save(provider.row({'id': 1, 'name': 'a'}));
      provider.armed = true;
      final List<DynamicModel> rows = await provider.find().timeout(const Duration(seconds: 10));
      expect(rows, hasLength(1));
      expect(provider.callbackResult, 'ignored');
      expect(FluentDb.isOpen(), isTrue);
      expect(ignored(), isNotEmpty);
    });

    test('pauseQueue inside a transaction is cancelled: the queue is not paused and a queued call runs after the commit', () async {
      late Future<int> outside;
      await FluentDb.transaction(() async {
        outside = Zone.root.run(() => users.count()); // queued behind the transaction (outside its scope)
        await users.save(u(1));
        await FluentEngine().pauseQueue(dbName: users.dbName).timeout(const Duration(seconds: 5));
        await FluentEngine().pauseQueue().timeout(const Duration(seconds: 5));
      }).timeout(const Duration(seconds: 10));
      expect(await outside.timeout(const Duration(seconds: 10)), 1);
      expect(ignored().where((i) => i.title.contains('pauseQueue')), hasLength(1), reason: 'an ignored call is reported once per run');
      expect(await users.count(), 1, reason: 'the queue runs: nothing is paused');
    });

    test('pauseQueue inside a stream listener subscribed in a transaction body still works after the body ended', () async {
      // The listener keeps the zone of the body, but the body's mark ended with it: this is no longer "inside a task".
      final Completer<void> heard = Completer<void>();
      late StreamSubscription<FluentChangeEvent<dynamic>> sub;
      await FluentDb.transaction(() async {
        sub = FluentEngine().changeStream.where((e) => e.table == 'users').listen((_) async {
          if (!heard.isCompleted) heard.complete();
        });
      });
      await users.save(u(1));
      await heard.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      final Future<void> paused = FluentEngine().pauseQueue(dbName: users.dbName).timeout(const Duration(seconds: 5));
      await paused;
      final Future<int> blocked = users.count();
      FluentEngine().resumeQueue(dbName: users.dbName);
      expect(await blocked, 1);
    });

    test('engine shutdown inside a transaction is ignored and reported: the body ends, a call queued behind it runs, the engine stays open', () async {
      late Future<Object?> queued;
      await FluentDb.transaction(() async {
        await users.save(u(1));
        queued = Zone.root.run(() => users.count().then<Object?>((v) => v, onError: (Object e) => e));
        await FluentEngine().shutdown(drainTimeout: const Duration(seconds: 1)).timeout(const Duration(seconds: 5));
      }).timeout(const Duration(seconds: 10));
      expect(await queued.timeout(const Duration(seconds: 10)), 1);
      expect(ignored().where((i) => i.title.contains('shut down from inside')), hasLength(1));
      expect(await users.count(), 1);
    });
  });

  group('ENG-10: a failing observer hook never changes what the tasks do', () {
    const List<String> hooks = ['onDispatch', 'onEnqueue', 'onStart', 'onDone', 'onFinish', 'record', 'recordFailure', 'forget', 'tunerWrite', 'tunerIdle', 'flushStats'];

    /// Queues, behind a held write slot and in call order: merged saves, collapsed reads, a merged lookup, a write barrier,
    /// a merged batch with a failing call, and a table clear. Returns what each call gave, in call order.
    Future<List<Object?>> scenario() async {
      final Completer<void> release = await hold();
      Future<Object?> outcome(Future<Object?> call) => call.then<Object?>((v) => v, onError: (Object e) => e);
      final List<Future<Object?>> calls = [
        outcome(users.save(u(1)).then((_) => 's1')),
        outcome(users.save(u(2)).then((_) => 's2')), // merged with the save before it
        outcome(users.count()), // 2: after both saves
        outcome(users.count()), // 2: collapsed onto the read before it
        outcome(users.findById(1).then((m) => m?.values['name'])),
        outcome(users.findById(2).then((m) => m?.values['name'])),
        outcome(users.findById(99).then((m) => m?.values['name'])), // the three lookups become one IN query
        outcome(users.save(u(3)).then((_) => 's3')), // a barrier: the reads before it saw two rows
        outcome(users.count()), // 3
        outcome(users.save(u(5)).then((_) => 's5')),
        outcome(users.save(users.row({'id': 9, 'email': 'u1@x', 'name': 'duplicate email'})).then((_) => 's9')), // merged with s5, fails alone
        outcome(users.count()), // 4: s5 stays, the duplicate is gone
        outcome(users.clearTable()), // 4
        outcome(users.count()), // 0
      ];
      release.complete();
      return Future.wait(calls).timeout(const Duration(seconds: 30));
    }

    final List<Object?> expected = [
      's1', 's2', 2, 2, 'user 1', 'user 2', null, 's3', 3, 's5', isA<FluentConstraintException>(), 4, 4, 0, //
    ];

    int observerReports() => records.where((r) => r.tag == 'FluentEngine:observer').length;

    for (final String hook in hooks) {
      test('$hook throwing: results and order are those of a normal run, the failure is reported once', () async {
        await openUsers();
        final Map<String, int> hits = {};
        FluentEngine.observerProbe = (String name) {
          hits[name] = (hits[name] ?? 0) + 1;
          if (name == hook) throw StateError('broken $hook');
        };
        final List<Object?> results = await scenario();
        expect(results, expected);
        expect(hits[hook], greaterThan(0), reason: '$hook was exercised by the scenario');
        expect(observerReports(), 1, reason: 'one report for all the failures of the run');
        await db.settle();
        expect(FluentEngine().isIdle, isTrue);
        expect(await users.count(), 0, reason: 'the engine still works afterwards');
      });
    }

    test('every hook throwing at once: same results, one report', () async {
      await openUsers();
      FluentEngine.observerProbe = (String name) => throw StateError('broken $name');
      expect(await scenario(), expected);
      expect(observerReports(), 1);
      await db.settle();
    });

    test('inside a transaction: statistics failing neither fail the calls nor the commit', () async {
      await openUsers();
      FluentEngine.observerProbe = (String name) => throw StateError('broken $name');
      final int count = await FluentDb.transaction(() async {
        await users.save(u(1));
        await users.save(u(2));
        return users.count();
      }).timeout(const Duration(seconds: 10));
      expect(count, 2);
      FluentEngine.observerProbe = null;
      expect(await users.count(), 2);
    });

    test('the failure is reported again for a later run of the engine (after a close and open)', () async {
      await openUsers();
      FluentEngine.observerProbe = (String name) => name == 'onEnqueue' ? throw StateError('broken') : null;
      await users.count();
      await users.count();
      expect(observerReports(), 1);
      await openUsers();
      FluentEngine.observerProbe = (String name) => name == 'onEnqueue' ? throw StateError('broken again') : null;
      await users.count();
      expect(observerReports(), 1, reason: 'records were cleared on open: one new report');
    });
  });

  group('OBS-8: the stats flush follows changes made while a flush runs', () {
    setUp(() => openUsers(persistent: true));

    FluentTask shaped(String shape) => FluentTask(table: 'users', dbName: users.dbName, action: FluentDbAction.find, helper: TableHelper(where: '"name" = ?', shape: shape));

    Future<List<String>> storedKeys() async => [for (final Map<String, Object?> row in await users.db.rawQuery('SELECT key FROM "${FluentTableStatsTracker.table}"')) '${row['key']}'];

    test('a change made while a flush writes is written by the next flush, without another task finishing', () async {
      FluentEngine.statsFlushInterval = const Duration(milliseconds: 50);
      final Completer<void> firstHeld = Completer<void>();
      final Completer<void> releaseFirst = Completer<void>();
      final Completer<void> secondEntered = Completer<void>();
      int entries = 0;
      FluentEngine.statsWriteGate = (String _) async {
        entries++;
        if (entries == 1) {
          firstHeld.complete();
          await releaseFirst.future;
        } else if (!secondEntered.isCompleted) {
          secondEntered.complete();
        }
      };
      await users.count(); // a measurement: the first flush starts (or is armed) and stops at the gate
      await firstHeld.future.timeout(const Duration(seconds: 10));
      FluentTableStatsTracker().record(shaped('"name" = ? /* made during the flush */'), 5);
      expect(secondEntered.isCompleted, isFalse, reason: 'the running flush does not start a second one');
      releaseFirst.complete();
      await secondEntered.future.timeout(const Duration(seconds: 10));
      FluentEngine.statsWriteGate = null;
      for (int i = 0; i < 200 && !(await storedKeys()).any((k) => k.contains('made during the flush')); i++) {
        await pumpEventQueue();
      }
      expect(await storedKeys(), contains(contains('made during the flush')));
      expect(entries, 2, reason: 'one more flush for the change, not a flush per event');
    });

    test('nothing changed: no further flush is armed after one', () async {
      FluentEngine.statsFlushInterval = const Duration(milliseconds: 20);
      int entries = 0;
      FluentEngine.statsWriteGate = (String _) async => entries++;
      await users.count();
      await db.settle();
      await db.settle();
      final int afterFirst = entries;
      await db.settle();
      expect(entries, afterFirst);
      expect(afterFirst, lessThanOrEqualTo(2));
    });

    test('a close during a held flush waits for it and still writes the change made meanwhile', () async {
      FluentEngine.statsFlushInterval = const Duration(milliseconds: 50);
      final Completer<void> firstHeld = Completer<void>();
      final Completer<void> releaseFirst = Completer<void>();
      bool first = true;
      FluentEngine.statsWriteGate = (String _) async {
        if (!first) return;
        first = false;
        firstHeld.complete();
        await releaseFirst.future;
      };
      await users.count();
      await firstHeld.future.timeout(const Duration(seconds: 10));
      FluentTableStatsTracker().record(shaped('"name" = ? /* before close */'), 5);
      final Future<void> closing = FluentDb.close();
      releaseFirst.complete();
      await closing.timeout(const Duration(seconds: 20));
      FluentEngine.statsWriteGate = null;
      final Database raw = await openDatabase('${await getDatabasesPath()}/${db.name}.db', singleInstance: false);
      final List<Map<String, Object?>> rows = await raw.rawQuery('SELECT key FROM "${FluentTableStatsTracker.table}"');
      await raw.close();
      expect(rows.map((r) => r['key']), contains(contains('before close')));
    });
  });

  group('DB-11: configure() during init', () {
    DynamicProvider v1() => DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
    DynamicProvider v2() => DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.text('extra')]);

    setUp(() async {
      db = FluentTestDb(name: 'r3_db11_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      await db.open([v1()]);
    });

    /// Restarts with a schema change (its plan callback runs while the init is in progress) calling [during] there.
    Future<void> restartWith(FluentConfig initial, void Function() during) async {
      int calls = 0;
      await db.restart(
        [v2()],
        fluentConfig: initial,
        onMigrationPlan: (_) {
          calls++;
          during();
          return true;
        },
      );
      expect(calls, 1, reason: 'the plan callback ran during the init');
    }

    const FluentConfig none = FluentConfig(trashPurgeInterval: null, optimizeInterval: null);

    test('a configure that turns the maintenance off wins over the config the init started with', () async {
      await restartWith(const FluentConfig(), () => FluentDb.configure(none));
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      expect(FluentDb.config.trashPurgeInterval, isNull);
    });

    test('a configure that turns it on wins over an init without maintenance', () async {
      await restartWith(none, () => FluentDb.configure(const FluentConfig()));
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: true));
      expect(FluentDb.config.optimizeInterval, const FluentConfig().optimizeInterval);
    });

    test('several configures during one init: the last one wins, timers and stored config agree', () async {
      await restartWith(const FluentConfig(), () {
        FluentDb.configure(none);
        FluentDb.configure(const FluentConfig(trashPurgeInterval: Duration(hours: 1), optimizeInterval: null));
      });
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: false));
      expect(FluentDb.config.trashPurgeInterval, const Duration(hours: 1));
      expect(FluentDb.config.optimizeInterval, isNull);
    });

    test('configure after the init applies at once; after a close it only stores the config and starts no timer', () async {
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: true));
      FluentDb.configure(none);
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      FluentDb.configure(const FluentConfig());
      expect(FluentDbInternals.maintenanceTimers, (purge: true, optimize: true));
      await FluentDb.close();
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
      FluentDb.configure(const FluentConfig());
      await pumpEventQueue();
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false), reason: 'nothing runs while the databases are closed');
    });

    test('a configure during the init of a failing start leaves no timers behind', () async {
      await expectLater(
        db.restart(
          [v2()],
          onMigrationPlan: (_) {
            FluentDb.configure(const FluentConfig());
            return false; // refuses the plan: the start fails
          },
        ),
        throwsA(isA<FluentSchemaException>()),
      );
      await pumpEventQueue();
      expect(FluentDbInternals.maintenanceTimers, (purge: false, optimize: false));
    });
  });

  group('analyzer: the query plan goes through the queue', () {
    late DynamicProvider people;

    FluentTask slow(String where, List<Object?> args) => FluentTask(
      table: 'people',
      dbName: people.dbName,
      action: FluentDbAction.find,
      helper: TableHelper(where: where, whereArgs: args, shape: where),
    );

    setUp(() async {
      db = FluentTestDb(name: 'r3_explain_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      people = DynamicProvider('people', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('status'), FluentDbColumn.integer('age')]);
      await db.open([people]);
      FluentAnalyzer().reset();
      FluentLog.reset();
    });

    test('while a user transaction is open the plan waits in the queue, never deadlocks, and is published after the commit', () async {
      final Completer<void> release = await hold();
      final int completedBefore = FluentEngine().stats.completed;
      final Future<void> explained = FluentAnalyzer().explain(slow('"status" = ?', ['a']), people, '~500 ms');
      final Future<int> userRead = Zone.root.run(() => people.count()); // a user call queued after the plan read
      await pumpEventQueue();
      expect(FluentEngine().stats.completed, completedBefore, reason: 'nothing runs while the transaction holds the slot, the plan included');
      expect(FluentLog.shownHints, isEmpty);
      release.complete();
      await explained.timeout(const Duration(seconds: 10));
      expect(await userRead.timeout(const Duration(seconds: 10)), 0);
      expect(FluentLog.shownHints.single.key, endsWith(':people:status'));
      expect(FluentLog.shownHints.single.details, contains('SCAN'));
    });

    test('a plan asked for from inside a transaction body does not make the body wait for it', () async {
      final FluentTask task = slow('"status" = ?', ['a']);
      await FluentDb.transaction(() async {
        FluentAnalyzer().onSlowShape(task, 500, 3); // started in the body, not awaited
        await people.save(people.row({'id': 1, 'status': 'a', 'age': 3}));
        expect(await people.count(), 1);
      }).timeout(const Duration(seconds: 10));
      await db.settle();
      expect(FluentLog.shownHints.map((h) => h.key), contains(endsWith(':people:status')));
      expect(await people.count(), 1);
    });

    test('the plan is a background read: user reads of higher priority queued after it run before it', () async {
      final Completer<void> release = await hold();
      final List<String> order = [];
      final Future<void> explained = FluentAnalyzer().explain(slow('"status" = ?', ['b']), people, '~500 ms').then((_) => order.add('plan'));
      final Future<void> urgent = Zone.root.run(() => people.count(policy: ExecutionPolicy.fast)).then((_) => order.add('urgent'));
      release.complete();
      await Future.wait([explained, urgent]).timeout(const Duration(seconds: 10));
      expect(order, ['urgent', 'plan']);
    });

    test('in release the plan is never queued', () async {
      FluentAnalyzer.releaseMode = true;
      final int before = FluentEngine().stats.completed;
      await FluentAnalyzer().explain(slow('"status" = ?', ['c']), people, '~500 ms');
      await db.settle();
      expect(FluentEngine().stats.completed, before);
    });
  });

  group('isolate mapping retries after a failure', () {
    final List<ReceivePort> ports = [];
    tearDown(() {
      for (final ReceivePort port in ports) {
        port.close();
      }
      ports.clear();
    });

    late _IsolateProvider provider;

    Future<void> openItems() async {
      db = FluentTestDb(name: 'r3_isolate_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      provider = _IsolateProvider(ports);
      await db.open([provider], fluentConfig: const FluentConfig(isolateMapping: FluentIsolateMapping.always));
      await provider.saveAll([for (int i = 1; i <= 120; i++) _Item(id: i, name: 'n$i')]);
      await db.settle();
    }

    Future<String> readBatch() async {
      final List<_Item> all = await provider.findAll(orderBy: 'id');
      expect([for (final _Item i in all) i.id], [for (int i = 1; i <= 120; i++) i], reason: 'every batch is complete and ordered, whatever isolate built it');
      return all.first.builtIn;
    }

    Iterable<FluentIssue> fallbacks() => db.issues.where((i) => i.kind == FluentIssueKind.isolateFallback);

    test('after one failure the next batches are mapped on the UI isolate, then the isolate is tried again and works', () async {
      await openItems();
      expect(await readBatch(), startsWith('fluent_sqflite:'), reason: 'works at first');
      provider.broken = true;
      expect(await readBatch(), isNot(startsWith('fluent_sqflite:')), reason: 'the failing batch falls back to the UI isolate');
      await db.settle();
      expect(fallbacks(), hasLength(1));
      expect(fallbacks().single.title, contains('next 2 batch'));
      provider.broken = false; // the failure was temporary
      expect(await readBatch(), isNot(startsWith('fluent_sqflite:')), reason: 'pause: batch 1 of 2');
      expect(await readBatch(), isNot(startsWith('fluent_sqflite:')), reason: 'pause: batch 2 of 2');
      expect(await readBatch(), startsWith('fluent_sqflite:'), reason: 'tried again, and it works');
      await db.settle();
      expect(fallbacks().map((i) => i.title), [contains('next 2 batch'), contains('background isolate again')]);
      expect(await readBatch(), startsWith('fluent_sqflite:'), reason: 'stays on');
      await db.settle();
      expect(fallbacks(), hasLength(2));
    });

    test('a failure that stays doubles the pause (2, 4, 8 batches), the results stay right', () async {
      await openItems();
      provider.broken = true;
      final List<int> pauses = [];
      for (int round = 0; round < 3; round++) {
        await readBatch(); // fails: a pause starts
        await db.settle();
        pauses.add(int.parse(RegExp(r'next (\d+) batch').firstMatch(fallbacks().last.title)!.group(1)!));
        final int reported = fallbacks().length;
        for (int i = 0; i < pauses.last; i++) {
          expect(await readBatch(), isNot(startsWith('fluent_sqflite:')));
        }
        await db.settle();
        expect(fallbacks().length, reported, reason: 'no new report during the pause');
      }
      expect(pauses, [2, 4, 8]);
    });
  });
}

/// A provider whose mapping callback (it runs inside the read task) tries to close the database.
class _CloseOnMap extends DynamicProvider {
  _CloseOnMap() : super('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);

  bool armed = false;
  String? callbackResult;

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) {
    if (armed) {
      armed = false;
      unawaited(FluentDb.close().then((_) => callbackResult = 'ignored'));
    }
    return super.fromCacheJson(json);
  }
}

class _Item extends FluentStorable {
  _Item({this.id, required this.name, this.builtIn = ''});

  final int? id;
  final String name;
  final String builtIn;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  /// The isolate factory: static, no provider access.
  static _Item fromJson(Map<String, dynamic> json) => _Item(id: json['id'] as int?, name: json['name'] as String, builtIn: Isolate.current.debugName ?? 'main');
}

/// Items whose isolate factory can be made unsendable (a closure over a port), to make the isolate fail on demand.
class _IsolateProvider extends FluentProvider<_Item> {
  _IsolateProvider(this._ports);

  final List<ReceivePort> _ports;

  /// While true, the isolate factory cannot be sent to a background isolate.
  bool broken = false;

  @override
  String get tableName => 'items';

  @override
  _Item get modelSample => _Item(id: 0, name: '');

  @override
  _Item fromCacheJson(Map<String, dynamic> json) => _Item.fromJson(json);

  @override
  _Item Function(Map<String, dynamic> json)? get isolateFactory {
    if (!broken) return _Item.fromJson;
    final ReceivePort port = ReceivePort();
    _ports.add(port);
    return (Map<String, dynamic> json) => _Item.fromJson({...json, 'port': port.sendPort});
  }
}
