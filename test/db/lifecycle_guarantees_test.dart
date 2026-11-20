// Guarantee tests: the app lifecycle (pause / resume / detach) reaches the library through the real binding
// (`TestWidgetsFlutterBinding.handleAppLifecycleStateChanged`), not through `FluentTuner.handleLifecycle`.
// What the library does on pause: PRAGMA optimize, a WAL checkpoint, a stats flush, and no periodic maintenance until
// the app is back (`FluentTuning.background` / `checkpoints`). None of it may stop or reorder the app's calls.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/guarantees.dart';
import '_helpers.dart';

void main() {
  final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpFluentTests();

  late FluentTestDb db;
  late LogWatch log;
  late GadgetProvider gadgets;

  FluentConfig configOf(FluentTuning tuning) => FluentConfig(diagnostics: FluentDiagnostics(tuning: tuning));

  Future<void> open(FluentTuning tuning, {bool persistent = false}) async {
    db = FluentTestDb(persistent: persistent);
    gadgets = GadgetProvider();
    await db.open([gadgets], fluentConfig: configOf(tuning));
  }

  /// What the library does on a lifecycle change is asynchronous (the observer starts it): let it finish.
  Future<void> lifecycle(AppLifecycleState state) async {
    binding.handleAppLifecycleStateChanged(state);
    await pumpEventQueue();
    await db.settle();
  }

  Iterable<String> tuner(String lever) => [for (final FluentLogRecord r in log.records) if ((r.tag ?? '').startsWith('FluentTuner:$lever')) r.message];

  setUp(() => log = LogWatch.install());

  tearDown(() async {
    await FluentTuner().handleLifecycle(AppLifecycleState.resumed);
    await db.close();
    log.uninstall();
  });

  test('G12: pause runs the background work once (optimize, checkpoint) and defers periodic maintenance; resume ends it', () async {
    await open(FluentTuning.full);
    await lifecycle(AppLifecycleState.inactive);
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isFalse, reason: 'inactive is not the background');
    expect(tuner('background'), isEmpty);

    await lifecycle(AppLifecycleState.paused);
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isTrue, reason: 'the observer is registered: the binding reached the tuner');
    expect(tuner('background'), ['PRAGMA optimize on "${gadgets.dbName}"']);
    expect(tuner('checkpoints'), ['PRAGMA wal_checkpoint(TRUNCATE) on "${gadgets.dbName}"']);

    await lifecycle(AppLifecycleState.hidden); // still in the background: nothing again
    expect(tuner('background'), hasLength(1));
    expect(tuner('checkpoints'), hasLength(1));

    await lifecycle(AppLifecycleState.resumed);
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isFalse);

    await lifecycle(AppLifecycleState.paused); // a second trip runs the work again
    expect(tuner('background'), hasLength(2));
    await lifecycle(AppLifecycleState.resumed);
    expectIssuesHaveFixes(db.issues);
    await expectIntegrity(gadgets.db);
  });

  test('G12: with the levers off a pause does nothing and defers nothing', () async {
    await open(FluentTuning.full.copyWith(background: false, checkpoints: false));
    await lifecycle(AppLifecycleState.paused);
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isFalse);
    expect(tuner('background'), isEmpty);
    expect(tuner('checkpoints'), isEmpty);
    await gadgets.save(Gadget(name: 'still works'));
    expect(await gadgets.count(), 1);
    await lifecycle(AppLifecycleState.resumed);
  });

  test('G7 / G12: calls made during the pause complete in call order and see the writes made before it', () async {
    await open(FluentTuning.full);
    await gadgets.saveAll([for (int i = 1; i <= 3; i++) Gadget(name: 'before $i')]);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused); // the background work is queued right now
    final List<Future<Object?>> calls = [
      gadgets.findAll(),
      gadgets.save(Gadget(name: 'during 1')),
      gadgets.findAll(),
      gadgets.saveAll([Gadget(name: 'during 2'), Gadget(name: 'during 3')]),
      gadgets.count(),
      gadgets.deleteWhere(FluentFilter.eq('name', 'before 1')),
      gadgets.findAll(),
    ];
    final List<Settled> out = await waitAllSettled(calls, names: ['find', 'save', 'find', 'saveAll', 'count', 'deleteWhere', 'find']);
    await pumpEventQueue();
    await db.settle();

    expect(out.every((s) => !s.failed), isTrue, reason: 'no call fails or hangs because of the pause');
    expect((out[0].value! as List).length, 3, reason: 'a read before the first write sees only the earlier rows');
    expect((out[2].value! as List).length, 4, reason: 'G7: it sees the write before it (3 + 1)');
    expect(out[4].value, 6, reason: 'G7: count sees both saves');
    expect((out[6].value! as List).length, 5, reason: 'G7: and the delete before the last read');
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isTrue);
    // The background work only runs on an idle database (it is skipped while calls are queued, never queued behind them).
    expect(db.issues.where((i) => i.kind == FluentIssueKind.tuningReverted), isEmpty);

    await lifecycle(AppLifecycleState.resumed);
    final List<String> names = [for (final Gadget g in await gadgets.findAll()) g.name]..sort();
    expect(names, ['before 2', 'before 3', 'during 1', 'during 2', 'during 3']);
    await expectIntegrity(gadgets.db);
    expectIssuesHaveFixes(db.issues);
  });

  test('G12: after resume the library works as before: writes, reads, streams and transactions', () async {
    await open(FluentTuning.full);
    await lifecycle(AppLifecycleState.paused);
    await gadgets.save(Gadget(name: 'in the background'));
    await lifecycle(AppLifecycleState.resumed);

    final List<int> counts = [];
    final sub = gadgets.watchValue<int>(() => gadgets.count()).listen(counts.add);
    await db.settle();
    await FluentDb.transaction(() async {
      await gadgets.save(Gadget(name: 'in a transaction'));
      await gadgets.save(Gadget(name: 'second'));
    });
    await db.settle();
    expect(counts, isNotEmpty);
    expect(counts.last, 3, reason: 'the stream hears the writes after the resume');
    await sub.cancel();
    expect(FluentTuner().defersMaintenance(gadgets.dbName), isFalse);
    await expectIntegrity(gadgets.db);
  });

  test('G19: detached does not lose committed data: the file reopens with every row', () async {
    await open(FluentTuning.full, persistent: true);
    await gadgets.saveAll([for (int i = 1; i <= 20; i++) Gadget(name: 'row $i', qty: i)]);
    await gadgets.deleteWhere(FluentFilter.eq('name', 'row 7'));
    final List<Gadget> committed = await gadgets.findAll(orderBy: 'id');

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final Future<int> late = gadgets.save(Gadget(name: 'saved while going away')).then((g) => 1); // queued behind the background work
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await late;
    await pumpEventQueue();
    await db.settle();

    await db.close(keepFile: true);
    final GadgetProvider again = GadgetProvider();
    await db.restart([again], fluentConfig: configOf(FluentTuning.full));
    final List<Gadget> after = await again.findAll(orderBy: 'id');
    expect([for (final Gadget g in after) g.name], [for (final Gadget g in committed) g.name, 'saved while going away']);
    expect([for (final Gadget g in after.take(committed.length)) g.qty], [for (final Gadget g in committed) g.qty]);
    await expectIntegrity(again.db);
    expectIssuesHaveFixes(db.issues);
  });
}
