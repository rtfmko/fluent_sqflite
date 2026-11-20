// Random version chains of 1-3 tables (TEST_PLAN.md, technique 1): every start with a changed model keeps every row
// and value where the guarantee says (G4), nothing else disappears (G21), and a second start changes nothing (G31).
// Replay: FLUENT_SEED=<seed> bash tool/mirror_test.sh t5 test/provider/schema/schema_fuzz_test.dart
@Timeout(Duration(seconds: 120))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fuzz.dart';
import '../../helpers/guarantees.dart';
import '../../helpers/schema_guard.dart';
import '../../helpers/schema_models.dart';

class _Col {
  _Col(this.id, this.name, this.type) : startName = name;

  int id; // an added column that takes over a removed column's name on disk takes over its id (and values)
  String name;
  String startName; // the name at the start of this version: the oldName of a rename
  String type; // 't' text, 'i' integer
  bool unique = false;
  bool indexed = false;
  bool isNew = true; // created in this version
}

class _Table {
  _Table(this.name);

  final String name;
  final List<_Col> cols = [];
  final Map<int, Map<int, int>> values = {}; // row id -> column id -> value
  final Map<int, Set<String>> ever = {}; // row id -> every value ever written to it
  int nextRow = 1;
}

class _World {
  final List<_Table> tables = [];
  int nextCol = 0;
  int nextName = 0;
  final Set<String> freed = {}; // names once used and free now: reused on purpose
  final Set<String> removedNow = {}; // removed in this version: the name still holds a column on disk, so it is not reused until the next one
  final Map<String, _Col> removedStart = {}; // removed in this version, by table.name the column has on disk (its startName)
  int quarantined = 0;
  int renames = 0;
  int removals = 0;
  int typeChanges = 0;
}

int _renames = 0, _removals = 0, _typeChanges = 0, _quarantines = 0, _restarts = 0;

void main() {
  setUpFluentTests();

  List<FluentDbColumn> Function() columnsOf(_Table t) {
    final List<(String, String, String?, bool, bool)> snapshot = [for (final _Col c in t.cols) (c.name, c.type, c.isNew || c.startName == c.name ? null : c.startName, c.unique, c.indexed)];
    return () => [
      FluentDbColumn.primary(),
      for (final (String, String, String?, bool, bool) c in snapshot)
        FluentDbColumn(name: c.$1, type: c.$2 == 't' ? FluentDbDataType.text : FluentDbDataType.integer, oldName: c.$3, isUnique: c.$4, indexed: c.$5),
    ];
  }

  List<FluentProvider> providers(_World w) => [for (final _Table t in w.tables) DynamicProvider(t.name, columnsOf(t))];

  String freshName(FluentFuzz f, _World w, _Table t, {bool adopt = false}) {
    final Set<String> live = {for (final _Col c in t.cols) c.name};
    // A name a removed column still holds on disk can be taken by an added column (the column is kept, see below), never by a rename.
    final List<String> reusable = [for (final String n in w.freed) if (!live.contains(n) && !w.removedNow.contains(n) && (adopt || !w.removedStart.containsKey('${t.name}.$n'))) n];
    if (reusable.isNotEmpty && f.chance(0.35)) return f.pick(reusable);
    String n;
    do {
      n = 'c${w.nextName++}';
    } while (live.contains(n));
    return n;
  }

  /// Mutates the model (one version step) and returns what it did.
  String mutate(FluentFuzz f, _World w) {
    final List<String> done = [];
    w.removedNow.clear();
    w.removedStart.clear();
    for (final _Table t in w.tables) {
      for (final _Col c in t.cols) {
        c.startName = c.name;
        c.isNew = false;
      }
    }
    final int ops = f.intIn(1, 3);
    for (int i = 0; i < ops; i++) {
      final _Table t = f.pick(w.tables);
      switch (f.weighted({'add': 3, 'remove': 2, 'rename': 3, 'type': 2, 'index': 1, 'unique': 1})) {
        case 'add':
          final _Col c = _Col(w.nextCol++, freshName(f, w, t, adopt: true), f.pick(['t', 'i']));
          t.cols.add(c);
          done.add('${t.name}: add ${c.name}:${c.type}');
        case 'remove':
          if (t.cols.length < 2) break;
          final _Col c = f.pick(t.cols);
          t.cols.remove(c);
          w.freed.add(c.name);
          w.removedNow.add(c.name);
          if (!c.isNew) w.removedStart['${t.name}.${c.startName}'] = c;
          w.removals++;
          done.add('${t.name}: remove ${c.name}');
        case 'rename':
          if (t.cols.isEmpty) break;
          final _Col c = f.pick(t.cols);
          if (c.isNew) break; // a column created in this version has no old name
          final String to = freshName(f, w, t);
          w.freed.add(c.name);
          done.add('${t.name}: rename ${c.name} -> $to');
          c.name = to;
          w.freed.remove(to);
          w.renames++;
        case 'type':
          if (t.cols.isEmpty) break;
          final _Col c = f.pick(t.cols);
          if (c.isNew) break;
          c.type = c.type == 't' ? 'i' : 't';
          w.typeChanges++;
          done.add('${t.name}: ${c.name} -> ${c.type}');
        case 'index':
          if (t.cols.isEmpty) break;
          final _Col c = f.pick(t.cols);
          c.indexed = !c.indexed;
          done.add('${t.name}: ${c.name} indexed=${c.indexed}');
        case 'unique':
          if (t.cols.isEmpty) break;
          final _Col c = f.pick(t.cols);
          if (c.unique) break;
          c.unique = true;
          done.add('${t.name}: ${c.name} unique');
      }
    }
    // Rename x -> y, remove y and add x (in any order) within one version: the model has a column x without oldName and
    // the database still holds column x with data. That is the original column x kept (values converted per the new
    // type), not an empty one.
    for (final _Table t in w.tables) {
      for (final _Col c in t.cols) {
        final _Col? kept = c.isNew ? w.removedStart.remove('${t.name}.${c.name}') : null;
        if (kept == null) continue;
        c.id = kept.id;
        c.isNew = false;
      }
    }
    return done.isEmpty ? 'no change' : done.join('; ');
  }

  Future<void> insertRows(FluentFuzz f, _World w, FluentTestDb db, List<FluentProvider> ps) async {
    for (int ti = 0; ti < w.tables.length; ti++) {
      final _Table t = w.tables[ti];
      final DynamicProvider p = ps[ti] as DynamicProvider;
      for (int k = f.intIn(0, 3); k > 0; k--) {
        final int id = t.nextRow++;
        final Map<String, Object?> row = {'id': id};
        final Map<int, int> vals = {};
        final Set<String> ever = {};
        for (final _Col c in t.cols) {
          if (f.chance(0.15)) continue; // null
          // Unique columns get distinct values; others a small range so that a later UNIQUE finds duplicates.
          final int v = c.unique ? 1000 + id : f.intIn(1, 4);
          vals[c.id] = v;
          ever.add('$v');
          row[c.name] = c.type == 't' ? '$v' : v;
        }
        t.values[id] = vals;
        t.ever[id] = ever;
        await p.db.insert(t.name, row);
      }
    }
  }

  Future<void> verify(_World w, FluentTestDb db, {required String when}) async {
    final Database raw = await openRaw(db.name);
    try {
      for (final _Table t in w.tables) {
        final Map<int, Map<String, Object?>> live = {for (final Map<String, Object?> r in await raw.query(t.name)) r['id']! as int: r};
        final Map<int, Map<String, Object?>> held = {};
        for (final String q in await quarantineTables(raw, t.name)) {
          for (final Map<String, Object?> r in await raw.query(q)) {
            held[r['id']! as int] = r;
          }
        }
        _quarantines += (await quarantineTables(raw, t.name)).length;
        for (final MapEntry<int, Map<int, int>> row in t.values.entries) {
          final int id = row.key;
          final bool inLive = live.containsKey(id);
          final bool inHeld = held.containsKey(id);
          expect(inLive || inHeld, isTrue, reason: 'G21 $when: ${t.name} row $id disappeared');
          expect(inLive && inHeld, isFalse, reason: 'G4 $when: ${t.name} row $id is in the table and in the quarantine');
          if (inLive) {
            for (final _Col c in t.cols) {
              expect(normValue(live[id]![c.name]), row.value.containsKey(c.id) ? '${row.value[c.id]}' : 'NULL', reason: 'G4 $when: ${t.name} row $id column ${c.name}');
            }
          }
          final Set<String> present = valuesOf(inLive ? live[id]! : held[id]!);
          for (final String v in t.ever[id]!) {
            expect(present, contains(v), reason: 'G21 $when: ${t.name} row $id lost the value $v (live, archived or quarantined)');
          }
        }
        expect(live.length + held.length, t.values.length, reason: 'G21 $when: ${t.name} has extra or missing rows');
      }
    } finally {
      await raw.close();
    }
  }

  Future<void> runChain(int seed, {int versions = 0}) async {
    final FluentFuzz fz = FluentFuzz(seed);
    final _World w = _World();
    final int tableCount = fz.intIn(1, 3);
    for (int i = 0; i < tableCount; i++) {
      final _Table t = _Table('f$i');
      for (int c = fz.intIn(1, 3); c > 0; c--) {
        t.cols.add(_Col(w.nextCol++, 'c${w.nextName++}', fz.pick(['t', 'i'])));
      }
      w.tables.add(t);
    }
    final int total = versions > 0 ? versions : fz.intIn(3, 6);
    final FluentTestDb db = FluentTestDb(name: 'sfz_$seed', persistent: true);
    addTearDown(db.close);
    db.clock.set(DateTime.utc(2026, 4, 1));
    List<FluentProvider> ps = providers(w);
    await db.open(ps);
    await insertRows(fz, w, db, ps);

    await runSequence(
      seed: seed,
      steps: total,
      next: (_, i) => FuzzOp('version ${i + 2}', () async {
        final String what = mutate(fz, w);
        // Reported with the seed on failure through the operation name below.
        ps = providers(w);
        try {
          await db.restart(ps);
        } catch (e) {
          fail('start of version ${i + 2} failed ($what): $e');
        }
        await db.settle();
        await verify(w, db, when: 'after version ${i + 2} [$what]');
        // G31: the same models again change nothing.
        await db.close(keepFile: true);
        final Map<String, Object?> before = await dumpFile(db.name);
        final int seen = db.issues.length;
        ps = providers(w);
        db.clock.set(DateTime.utc(2026, 4, 1));
        await db.open(ps);
        await db.settle();
        await db.close(keepFile: true);
        expect(dumpDiff(before, await dumpFile(db.name)), isNull, reason: 'G31: a second start after "$what" changes nothing');
        expect([for (final FluentIssue x in db.issues.skip(seen)) if (x.type != FluentIssueType.hint && x.kind != FluentIssueKind.sharedModelType) x.kind], isEmpty, reason: 'G31: a second start says nothing');
        // Next version: more rows, using the live column names.
        db.clock.set(DateTime.utc(2026, 4, 1));
        ps = providers(w);
        await db.open(ps);
        await insertRows(fz, w, db, ps);
        for (final _Table t in w.tables) {
          for (final _Col c in t.cols) {
            c.isNew = false;
          }
        }
      }),
      check: (_) {},
      stepTimeout: const Duration(seconds: 60),
    );
    _renames += w.renames;
    _removals += w.removals;
    _typeChanges += w.typeChanges;
    _restarts += total;
    final Database raw = await openRaw(db.name);
    await expectIntegrity(raw);
    await raw.close();
    expectIssuesHaveFixes(db.issues);
  }

  // One test per seed: the file's timeout applies to each chain, so FLUENT_FUZZ scales without hitting it.
  for (final int seed in fuzzSeeds(base: 50000)) {
    test('G4 / G21 / G31: random version chains (add, remove, rename, type change, index, unique) keep every row and value, and a second start changes nothing (seed $seed)', () => runChain(seed));
  }

  test('the generator really exercises renames, removals and type changes (counts over the chains of this run)', () {
    if (fuzzSeed() != null) return; // one replayed seed need not hit every case
    expect([_renames, _removals, _typeChanges, _restarts], everyElement(greaterThan(0)), reason: 'renames $_renames removals $_removals type changes $_typeChanges quarantines $_quarantines starts $_restarts');
    // ignore: avoid_print
    print('schema fuzz: starts $_restarts renames $_renames removals $_removals type changes $_typeChanges quarantine tables seen $_quarantines');
  });
}
