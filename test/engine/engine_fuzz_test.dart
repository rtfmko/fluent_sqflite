// Random interleavings of unawaited calls on two databases with same-named tables, compared with a serial run of the
// same calls in call order (TEST_PLAN.md, agent T3): G7 (order, read-your-writes, merging / collapsing / batching /
// the read pool never change a result), G12 (every call settles), G30 (same-named tables never mix), G1 (merged
// batches with failing calls).
//
// Four databases are open at once, all with the tables `items` and `notes`: c0 / c1 take each burst of calls fired
// without awaiting (merged saves, findById floods, collapsing reads, priorities, transactions nested, side by side and
// across both databases, pauses), s0 / s1 take the same calls awaited one by one. After every burst each call's result
// and every table must be equal.
//
// Replay one seed: FLUENT_SEED=<seed> bash tool/mirror_test.sh t3 test/engine/engine_fuzz_test.dart
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fuzz.dart';
import '../helpers/guarantees.dart';
import '../helpers/schema_models.dart';

const int _seedBase = 30000;

List<FluentDbColumn> _itemColumns() => [FluentDbColumn.integer('id'), FluentDbColumn.text('code', isUnique: true), FluentDbColumn.text('name'), FluentDbColumn.integer('qty')];

List<FluentDbColumn> _noteColumns() => [FluentDbColumn.integer('id'), FluentDbColumn.text('text')];

/// One database of the run.
class _Db {
  _Db(this.key) : items = DynamicProvider('items', _itemColumns), notes = DynamicProvider('notes', _noteColumns);

  final FluentDbKey key;
  final DynamicProvider items;
  final DynamicProvider notes;
}

/// The two databases one side of the comparison uses.
class _World {
  _World(this.dbs);

  final List<_Db> dbs;
}

/// A transaction rolled back on purpose; carries what its calls returned.
class _Rollback implements Exception {
  _Rollback(this.results);

  final List<Object?> results;

  @override
  String toString() => 'rollback';
}

/// One generated call (or burst control).
class _Op {
  _Op(this.name, this.run, {this.serial, this.isYield = false});

  final String name;

  /// Fires the call on a world and returns its result (normalized by the caller).
  final Future<Object?> Function(_World w) run;

  /// What the serial run does instead ([run] when `null`); pauses / resumes do nothing there.
  final Future<Object?> Function(_World w)? serial;

  /// Lets the concurrent run make progress (nothing in the serial run).
  final bool isYield;

  @override
  String toString() => name;
}

/// A comparable form of a call's result.
Object? _norm(Object? v) => switch (v) {
  null || int() || bool() || String() || double() => v,
  final FluentSaveResult r => r.outcomes.map((o) => o.name).join(','),
  final DynamicModel m => {for (final String c in m.values.keys.where((k) => !k.startsWith('_')).toList()..sort()) c: m[c]},
  final Map<Object?, Object?> m => {for (final Object? k in m.keys.where((k) => !'$k'.startsWith('_')).toList()..sort((a, b) => '$a'.compareTo('$b'))) '$k': _norm(m[k])},
  final List<Object?> l => [for (final Object? x in l) _norm(x)],
  _ => 'unexpected ${v.runtimeType}',
};

Object? _normError(Object e) => switch (e) {
  final _Rollback r => ['rollback', ..._norm(r.results)! as List<Object?>],
  final FluentException f => 'error:${f.code.name}',
  _ => 'untyped error ${e.runtimeType}: $e', // G13: never equal to a typed one, and reported below
};

/// [op] on [w], its outcome normalized (never fails).
Future<Object?> _fire(Future<Object?> Function(_World) op, _World w) => Future<Object?>.sync(() => op(w)).then(_norm, onError: (Object e) => _normError(e));

void main() {
  setUpFluentTests();

  final List<FluentIssue> issues = [];
  StreamSubscription<FluentIssue>? issueSub;

  tearDown(() async {
    FluentDb.resumeQueue();
    await FluentEngine().whenIdle(const Duration(seconds: 5));
    await FluentDb.close().timeout(const Duration(seconds: 10));
    FluentDbInternals.reset();
    await issueSub?.cancel();
  });

  Future<(_World, _World)> open(int seed, {required bool pool}) async {
    await FluentTestDb.closeCurrent();
    FluentDbInternals.reset();
    issues.clear();
    await issueSub?.cancel();
    issueSub = FluentDb.onIssue().listen(issues.add);
    final List<_Db> dbs = [for (final String n in const ['c0', 'c1', 's0', 's1']) _Db(FluentDbKey('fuzz_${seed}_${n}_${DateTime.now().microsecondsSinceEpoch}'))];
    await FluentDb.init([
      for (final _Db d in dbs)
        FluentGroup(
          dbKey: d.key,
          providerList: [d.items, d.notes],
          inMemory: !pool,
          config: pool ? const FluentDbConfig(readConnections: 2) : const FluentDbConfig(),
        ),
    ]);
    return (_World([dbs[0], dbs[1]]), _World([dbs[2], dbs[3]]));
  }

  Future<List<Object?>> snapshot(_World w) async => [
    for (final _Db d in w.dbs) ...[
      [for (final DynamicModel m in await d.items.find(orderBy: 'id')) _norm(m)],
      [for (final DynamicModel m in await d.notes.find(orderBy: 'id')) _norm(m)],
    ],
  ];

  // ---------------------------------------------------------------------------------------------------------------
  // Generator
  // ---------------------------------------------------------------------------------------------------------------

  DynamicModel item(_Db d, int? id, String? code, String? name, int? qty) => d.items.row({'id': id, 'code': code, 'name': name, 'qty': qty});

  String? code(FluentFuzz f) => f.chance(0.4) ? null : 'c${f.intIn(1, 4)}';

  ExecutionPolicy policy(FluentFuzz f) => f.pick(const [
    ExecutionPolicy(),
    ExecutionPolicy.fast,
    ExecutionPolicy.background,
    ExecutionPolicy.fresh,
    ExecutionPolicy(priority: 3, cancelIfDuplicate: false),
  ]);


  FluentFilter filter(FluentFuzz f) {
    final int n = f.intIn(0, 5);
    return f.pick<FluentFilter Function()>([
      () => FluentFilter.gt('qty', n),
      () => FluentFilter.lte('id', n),
      () => FluentFilter.isNotNull('code'),
      () => FluentFilter.eq('name', 'n$n'),
    ])();
  }

  /// A write on database [d] of a world.
  _Op write(FluentFuzz f, int d) {
    final int? id = f.chance(0.2) ? null : f.intIn(1, 6);
    final String? c = code(f);
    final String name = 'n${f.intIn(0, 5)}';
    final int? qty = f.chance(0.2) ? null : f.intIn(0, 9);
    switch (f.intIn(0, 10)) {
      case 0:
        final FluentSaveStrategy s = f.pick(FluentSaveStrategy.values);
        return _Op('db$d save($id, $c, $name, $qty, ${s.name})', (w) async {
          final DynamicModel m = item(w.dbs[d], id, c, name, qty);
          final FluentSaveResult r = await w.dbs[d].items.save(m, strategy: s);
          return [r, m.primaryKeyValue];
        });
      case 1:
        return _Op('db$d save the same new model twice ($c, $name)', (w) async {
          final DynamicModel m = item(w.dbs[d], null, c, name, qty);
          final List<Object?> r = await Future.wait([_fire((_) => w.dbs[d].items.save(m), w), _fire((_) => w.dbs[d].items.save(m), w)]);
          return [...r, m.primaryKeyValue];
        });
      case 2:
        final int n = f.intIn(1, 3);
        final List<(int?, String?)> rows = [for (int i = 0; i < n; i++) (f.chance(0.3) ? null : f.intIn(1, 6), code(f))];
        return _Op('db$d saveAll($rows, $name)', (w) async {
          final List<DynamicModel> ms = [for (final (int?, String?) r in rows) item(w.dbs[d], r.$1, r.$2, name, qty)];
          final FluentSaveResult r = await w.dbs[d].items.saveAll(ms);
          return [r, for (final DynamicModel m in ms) m.primaryKeyValue];
        });
      case 3:
        final String cc = 'c${f.intIn(1, 4)}';
        return _Op('db$d save conflictOn code=$cc ($name)', (w) async {
          final DynamicModel m = item(w.dbs[d], null, cc, name, qty);
          final FluentSaveResult r = await w.dbs[d].items.save(m, conflictOn: ['code']);
          return [r, m.primaryKeyValue];
        });
      case 4:
        final int k = f.intIn(1, 6);
        final bool inc = f.chance(0.5);
        return _Op('db$d updateById($k, ${inc ? 'qty+1' : 'name=$name'})', (w) => w.dbs[d].items.updateById(k, inc ? {'qty': FluentUpdate.increment()} : {'name': name}));
      case 5:
        final FluentFilter Function() wf = f.pick<FluentFilter Function()>([() => FluentFilter.gt('qty', 4), () => FluentFilter.isNull('code'), () => FluentFilter.lte('id', 2)]);
        return _Op('db$d updateWhere(${wf()}, name=$name)', (w) => w.dbs[d].items.updateWhere(wf(), {'name': name}));
      case 6:
        final int k = f.intIn(1, 6);
        return _Op('db$d deleteById($k)', (w) => w.dbs[d].items.deleteById(k));
      case 7:
        return _Op('db$d save a new model and delete it ($c)', (w) async {
          final DynamicModel m = item(w.dbs[d], null, c, name, qty);
          return Future.wait([_fire((_) => w.dbs[d].items.save(m), w), _fire((_) => w.dbs[d].items.delete(m), w)]);
        });
      case 8:
        final int k = f.intIn(1, 4);
        return _Op('db$d notes.save($k, $name)', (w) => w.dbs[d].notes.save(w.dbs[d].notes.row({'id': k, 'text': name})));
      case 9:
        final int k = f.intIn(1, 6);
        return _Op('db$d patch($k, name=$name)', (w) => w.dbs[d].items.save(item(w.dbs[d], k, null, name, null), strategy: FluentSaveStrategy.patch));
      default:
        final int k = f.intIn(1, 4);
        return _Op('db$d notes.deleteById($k)', (w) => w.dbs[d].notes.deleteById(k));
    }
  }

  /// A read on database [d] of a world.
  _Op read(FluentFuzz f, int d) {
    final ExecutionPolicy p = policy(f);
    switch (f.intIn(0, 6)) {
      case 0:
      case 1:
        final int k = f.intIn(1, 7);
        return _Op('db$d findById($k, $p)', (w) => w.dbs[d].items.findById(k, policy: p));
      case 2:
        final FluentFilter wf = filter(f);
        final int? limit = f.chance(0.3) ? f.intIn(1, 3) : null;
        return _Op('db$d find($wf, limit $limit, $p)', (w) => w.dbs[d].items.find(where: wf, orderBy: 'id', limit: limit, policy: p));
      case 3:
        final FluentFilter? wf = f.chance(0.5) ? null : filter(f);
        return _Op('db$d count($wf, $p)', (w) => w.dbs[d].items.count(where: wf, policy: p));
      case 4:
        return _Op('db$d findMaps($p)', (w) => w.dbs[d].items.findMaps(orderBy: 'id', policy: p));
      case 5:
        final int k = f.intIn(1, 7);
        return _Op('db$d exists($k)', (w) => w.dbs[d].items.exists(k, policy: p));
      default:
        return _Op('db$d notes.find($p)', (w) => w.dbs[d].notes.find(orderBy: 'id', policy: p));
    }
  }

  /// A transaction on database [d]: its calls awaited one by one or fired together, maybe a nested transaction
  /// (savepoint) among them, maybe rolled back.
  _Op transaction(FluentFuzz f, int d, {int depth = 0}) {
    final List<_Op> inner = [
      for (int i = f.intIn(1, 4); i > 0; i--)
        if (depth == 0 && f.chance(0.15)) transaction(f, d, depth: depth + 1) else if (f.chance(0.6)) write(f, d) else read(f, d),
    ];
    final bool together = f.chance(0.4);
    final bool rollback = f.chance(0.3);
    return _Op('db$d transaction${depth > 0 ? ' (nested)' : ''}${together ? ' (calls fired together)' : ''}${rollback ? ' rolled back' : ''} $inner', (w) => FluentDb.transaction(() async {
      final List<Object?> results = together
          ? await Future.wait([for (final _Op op in inner) _fire(op.run, w)])
          : [for (final _Op op in inner) await _fire(op.run, w)];
      if (rollback) throw _Rollback(results);
      return results;
    }, dbKey: w.dbs[d].key));
  }

  /// A transaction on [d] with one on the other database inside, and one on [d] again inside that (G30: each write
  /// lands in its own database; the inner one on [d] is a savepoint of the outer one).
  _Op crossTransaction(FluentFuzz f, int d) {
    final _Op a1 = write(f, d);
    final _Op b1 = write(f, 1 - d);
    final _Op a2 = f.chance(0.5) ? write(f, d) : read(f, d);
    final bool rollback = f.chance(0.3);
    return _Op('db$d transaction [$a1, db${1 - d} transaction [$b1, db$d transaction [$a2]]]${rollback ? ' rolled back' : ''}', (w) => FluentDb.transaction(() async {
      final Object? r1 = await _fire(a1.run, w);
      final Object? r2 = await _fire((w) => FluentDb.transaction(() async {
        final Object? rb = await _fire(b1.run, w);
        final Object? ra = await _fire((w) => FluentDb.transaction(() => a2.run(w), dbKey: w.dbs[d].key), w);
        return [rb, ra];
      }, dbKey: w.dbs[1 - d].key), w);
      if (rollback) throw _Rollback([r1, r2]);
      return [r1, r2];
    }, dbKey: w.dbs[d].key));
  }

  /// One burst: calls fired without awaiting in the concurrent run. A transaction across both databases ends a burst:
  /// its inner transaction is called only when its body runs, after the calls fired later in the burst.
  List<_Op> burst(FluentFuzz f) {
    final List<_Op> ops = [];
    int? pausedDb; // -1: all
    _Op resume() {
      final int target = pausedDb!;
      pausedDb = null;
      return _Op(
        'resumeQueue(${target < 0 ? 'all' : 'db$target'})',
        (w) async {
          FluentDb.resumeQueue(dbKey: target < 0 ? null : w.dbs[target].key);
          return 'resumed';
        },
        serial: (_) async => 'resumed',
      );
    }

    final int n = f.intIn(3, 14);
    for (int i = 0; i < n; i++) {
      final int d = f.intIn(0, 1);
      final String kind = f.weighted({'write': 8, 'read': 8, 'transaction': 3, 'yield': 2, 'pause': 1, 'cross': 1});
      if (pausedDb != null && f.chance(0.25)) ops.add(resume());
      switch (kind) {
        case 'write':
          ops.add(write(f, d));
        case 'read':
          // Floods: the same lookup or read several times in a row (batched / collapsed).
          final _Op r = read(f, d);
          for (int k = f.chance(0.3) ? f.intIn(2, 5) : 1; k > 0; k--) {
            ops.add(r);
          }
        case 'transaction':
          ops.add(transaction(f, d));
        case 'yield':
          final int times = f.intIn(1, 20);
          ops.add(_Op('yield($times)', (_) => pumpEventQueue(times: times).then((_) => null), isYield: true));
        case 'pause':
          if (pausedDb != null) break;
          final int target = f.chance(0.3) ? -1 : d;
          pausedDb = target;
          ops.add(_Op('pauseQueue(${target < 0 ? 'all' : 'db$target'})', (w) => FluentDb.pauseQueue(dbKey: target < 0 ? null : w.dbs[target].key).then((_) => 'paused'), serial: (_) async => 'paused'));
        case 'cross':
          if (pausedDb != null) ops.add(resume());
          ops.add(crossTransaction(f, d));
          return ops;
      }
    }
    if (pausedDb != null) ops.add(resume());
    return ops;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Runs
  // ---------------------------------------------------------------------------------------------------------------

  Future<List<Object?>> concurrent(List<_Op> ops, _World w) async {
    final List<Future<Object?>> calls = [];
    final List<String> names = [];
    final List<int> index = [];
    for (int i = 0; i < ops.length; i++) {
      final _Op op = ops[i];
      if (op.isYield) {
        await op.run(w);
        continue;
      }
      calls.add(_fire(op.run, w));
      names.add('$i: $op');
      index.add(i);
    }
    final List<Settled> settled = await waitAllSettled(calls, names: names); // G12
    final List<Object?> out = List.filled(ops.length, 'yield');
    for (int k = 0; k < index.length; k++) {
      out[index[k]] = settled[k].value;
    }
    return out;
  }

  Future<List<Object?>> serial(List<_Op> ops, _World w) async => [for (final _Op op in ops) op.isYield ? 'yield' : await _fire(op.serial ?? op.run, w).timeout(const Duration(seconds: 10))];

  void expectNoUntyped(List<Object?> results, List<_Op> ops) {
    for (int i = 0; i < results.length; i++) {
      expect('${results[i]}'.contains('untyped error'), isFalse, reason: 'G13: call $i (${ops[i]}) failed with an untyped error: ${results[i]}');
    }
  }

  // Counted over every seed of this run (both variants), checked by the last test.
  int merged = 0;
  int collapsed = 0;
  int batched = 0;

  Future<void> run({required bool pool, required int seed}) async {
    {
      final (_World c, _World s) = await open(seed, pool: pool);
      final FluentEngineStats before = FluentDb.engineStats();
      List<_Op> ops = const [];
      List<Object?> got = const [];
      List<Object?> want = const [];
      await runSequence(
        seed: seed,
        steps: 6,
        stepTimeout: const Duration(seconds: 30),
        next: (f, step) {
          ops = burst(f);
          return FuzzOp('burst $step: $ops', () async {
            got = await concurrent(ops, c);
            want = await serial(ops, s);
          });
        },
        check: (step) async {
          expectNoUntyped(got, ops);
          for (int i = 0; i < ops.length; i++) {
            expect(got[i], want[i], reason: 'G7: call $i (${ops[i]}) of burst $step returned another result than in a serial run');
          }
          expect(await snapshot(c), await snapshot(s), reason: 'G7 / G30: the tables after burst $step differ from a serial run (items / notes of db0, db1)');
        },
      );
      final FluentEngineStats after = FluentDb.engineStats();
      merged += after.mergedSaves - before.mergedSaves;
      collapsed += after.collapsedReads - before.collapsedReads;
      batched += after.batchedLookups - before.batchedLookups;
      for (final _Db d in [...c.dbs, ...s.dbs]) {
        await expectIntegrity(d.items.db);
      }
      expectIssuesHaveFixes(issues);
      await FluentDb.close().timeout(const Duration(seconds: 10));
      FluentDbInternals.reset();
    }
  }

  // One test per seed, so FLUENT_FUZZ scales without hitting a test timeout. The read-pool variant uses its own seeds.
  for (final int seed in fuzzSeeds(base: _seedBase)) {
    test('G7 / G12 / G30: random bursts of unawaited calls on two databases equal a serial run (one connection each, seed $seed)', () => run(pool: false, seed: seed));
  }
  for (final int seed in fuzzSeeds(base: _seedBase + 100000)) {
    test('G7 / G12 / G30: random bursts of unawaited calls on two databases equal a serial run (files with a read pool, seed $seed)', () => run(pool: true, seed: seed));
  }

  test("the generator really exercises the engine's shortcuts (merged saves, collapsed reads, batched lookups)", () {
    if (fuzzSeed() != null) return; // one replayed seed need not hit every shortcut
    expect(merged, greaterThan(0), reason: 'saves were merged');
    expect(collapsed, greaterThan(0), reason: 'identical reads were collapsed');
    expect(batched, greaterThan(0), reason: 'lookups were batched');
  });
}
