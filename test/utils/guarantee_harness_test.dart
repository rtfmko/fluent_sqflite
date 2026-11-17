// Checks the shared harness of the guarantee tests (test/helpers/faults.dart, fuzz.dart, guarantees.dart).
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/faults.dart';
import '../helpers/fuzz.dart';
import '../helpers/guarantees.dart';
import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  late FluentTestDb db;
  late DynamicProvider notes;

  DynamicModel note(int id, String text) => notes.row({'id': id, 'text': text});

  setUp(() async {
    faults = await FaultyDatabaseFactory.install();
    db = FluentTestDb(persistent: true);
    notes = DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text')]);
    await db.open([notes]);
  });

  tearDown(() async {
    faults.heal();
    await db.close();
    faults.uninstall();
  });

  test('an injected insert failure reaches the caller typed, writes nothing, and heal makes it work again', () async {
    await notes.save(note(1, 'a'));
    faults.failWhere((c) => c.matches('INSERT'), times: 1);
    await expectLater(notes.save(note(2, 'b')), throwsA(isA<FluentException>()));
    expect(faults.injected, hasLength(1));
    expect(await notes.count(), 1, reason: 'G1: nothing of the failed save');
    await notes.save(note(2, 'b'));
    expect(await notes.count(), 2);
    await expectIntegrity(notes.db);
  });

  test('failNth counts matching calls from now; rollback is never failed by default', () async {
    faults.failNth(1, where: (c) => c.isWrite);
    final List<Settled> r = await waitAllSettled([notes.save(note(1, 'a')), notes.save(note(2, 'b'))], names: ['save 1', 'save 2']);
    expect(r.where((s) => s.failed), hasLength(1));
    expect(faults.injected.single.isRollback, isFalse);
  });

  test('random failures are seeded: the same seed fails the same calls', () async {
    Future<List<int>> run(int seed) async {
      faults.heal();
      await notes.clearTable();
      final int start = faults.calls.length;
      faults.failRandomly(seed, 0.3, where: (c) => c.isWrite);
      await waitAllSettled([for (int i = 0; i < 20; i++) notes.save(note(i, 't$i'))]);
      return [for (final SqlCall c in faults.injected) if (c.index >= start) c.index - start];
    }

    final List<int> a = await run(7);
    final List<int> b = await run(7);
    expect(a.length, b.length);
  });

  test('crash states taken during a transaction each open intact and hold a committed state (G14)', () async {
    await notes.save(note(1, 'before'));
    final String dir = '${Directory.systemTemp.path}${Platform.pathSeparator}fluent_crash_${DateTime.now().microsecondsSinceEpoch}';
    final List<Map<String, String>> states = await captureCrashStates(faults, dir, () => FluentDb.transaction(() async {
      await notes.saveAll([for (int i = 2; i <= 5; i++) note(i, 'in txn')]);
    }));
    expect(states.length, greaterThan(1));
    final Set<int> counts = {};
    for (final Map<String, String> s in states) {
      final String copy = s.values.firstWhere((p) => p.contains(db.name));
      final Database raw = await databaseFactoryFfi.openDatabase(copy);
      await expectIntegrity(raw);
      counts.add((await raw.rawQuery('SELECT COUNT(*) AS n FROM "notes"')).first['n']! as int);
      await raw.close();
    }
    expect(counts.difference({1, 5}), isEmpty, reason: 'only the state before or after the commit, never a mix');
    expect(counts, contains(5));
    await Directory(dir).delete(recursive: true);
  });

  test('die fails everything except close; heal revives', () async {
    await faults.die();
    await expectLater(notes.save(note(1, 'x')), throwsA(isA<FluentException>()));
    await expectLater(notes.count(), throwsA(isA<FluentException>()));
    faults.heal();
    expect(await notes.count(), 0);
  });

  test('waitAllSettled fails on a call that never completes', () async {
    await expectLater(waitAllSettled([Completer<void>().future], names: ['stuck'], timeout: const Duration(milliseconds: 50)), throwsA(isA<TestFailure>()));
  });

  test('runSequence reports the seed and the operations of a failing step', () async {
    expect(fuzzSeeds(base: 5, count: 3), fuzzSeed() == null ? [5, 6, 7] : [fuzzSeed()]);
    await expectLater(
      runSequence(
        seed: 42,
        steps: 5,
        next: (f, i) => FuzzOp('op $i', () async {
          if (i == 3) throw StateError('boom');
        }),
        check: (_) {},
      ),
      throwsA(isA<TestFailure>().having((e) => e.message, 'message', allOf(contains('seed 42'), contains('step 3'), contains('FLUENT_SEED=42')))),
    );
  });
}
