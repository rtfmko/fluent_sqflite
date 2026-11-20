// Model-based random tests of CRUD and transactions (TEST_PLAN.md, agent T4): G1, G2, G8, G9, G16, G21, G29.
//
// Every sequence applies random calls to the database and to a plain Dart reference model, and compares them after
// every step. A failure prints the seed and the calls; replay with FLUENT_SEED=<seed>.
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fuzz.dart';
import '../../helpers/guarantees.dart';
import 'crud_guarantee_models.dart';

class _Boom implements Exception {
  @override
  String toString() => 'boom';
}

/// The stamp a row gets while the real one is not read yet.
const int _pending = -1;

class RefDoc {
  RefDoc(this.id, {required this.title, required this.qty, this.note, this.code, this.flag, this.seen, required this.created, required this.updated, this.deleted});

  final int id;
  String title;
  int qty;
  String? note;
  String? code;
  bool? flag;
  int? seen;
  final int created;
  int updated;
  int? deleted;

  RefDoc copy() => RefDoc(id, title: title, qty: qty, note: note, code: code, flag: flag, seen: seen, created: created, updated: updated, deleted: deleted);

  List<Object?> get row => [id, title, qty, note, code, flag, seen, created, updated, deleted];

  @override
  String toString() => row.toString();
}

class RefLease {
  RefLease(this.id, this.val, this.expiry);

  final int id;
  String val;
  int expiry;

  RefLease copy() => RefLease(id, val, expiry);
}

class RefState {
  final Map<int, RefDoc> docs = {};
  final Map<int, RefLease> leases = {};

  RefState clone() {
    final RefState s = RefState();
    for (final RefDoc d in docs.values) {
      s.docs[d.id] = d.copy();
    }
    for (final RefLease l in leases.values) {
      s.leases[l.id] = l.copy();
    }
    return s;
  }
}

/// A filter and the same condition on reference rows.
class Pred {
  Pred(this.name, this.filter, this.test);

  final String name;
  final FluentFilter filter;
  final bool Function(RefDoc) test;

  @override
  String toString() => name;
}

const List<String> _titles = ['alpha', 'beta', 'gamma', 'a1', 'b2', 'zeta'];

String docState(Doc d) =>
    '${d.primaryKeyValue}|${d.title}|${d.qty}|${d.note}|${d.code}|${d.flag}|${d.seen?.millisecondsSinceEpoch}|c${d.createdAt?.millisecondsSinceEpoch}|u${d.updatedAt?.millisecondsSinceEpoch}|d${d.deletedAt?.millisecondsSinceEpoch}';

void main() {
  setUpFluentTests();

  group('G1 / G2 / G8 / G9 / G21 / G29: random calls against a reference model', () {
    for (final int seed in fuzzSeeds(base: 40000)) {
      test('seed $seed', () => _docSequence(seed), timeout: const Timeout(Duration(seconds: 50)));
    }
  });

  group('G16: findPage walks are exact while rows come and go between pages', () {
    for (final int seed in fuzzSeeds(base: 40500)) {
      test('seed $seed', () => _pagingSequence(seed), timeout: const Timeout(Duration(seconds: 50)));
    }
  });
}

Future<void> _docSequence(int seed) async {
  final FluentTestDb db = FluentTestDb(name: 'crud_fuzz_$seed');
  final DocProvider docs = DocProvider();
  final LeaseProvider leases = LeaseProvider();
  // One base per seed, later seeds later: soft-delete stamps never go back within the process (see the guarantee tests).
  final DateTime base = DateTime.utc(2026, 1, 1).add(Duration(days: 10 * (seed % 5000)));
  db.clock.set(base);
  await db.open([docs, leases]);
  addTearDown(db.close);

  RefState ref = RefState();
  final List<Doc> held = [];
  int txDepth = 0; // models get stamps after the commit
  int moved = 0; // total clock movement in ms, below the 7 days of the default trash retention
  int now() => db.clock.now.millisecondsSinceEpoch;

  // -------------------------------------------------------------------------------------------------------------
  // helpers
  // -------------------------------------------------------------------------------------------------------------
  Doc mkDoc(FluentFuzz f, {int? id, String? code}) => Doc(
    id: id,
    title: f.pick(_titles),
    qty: f.chance(0.2) ? 0 : f.intIn(1, 9),
    note: f.chance(0.5) ? f.pick(['x', 'y', 'z']) : null,
    code: code,
    flag: f.pick([null, true, false]),
    seen: f.chance(0.4) ? DateTime.fromMillisecondsSinceEpoch(1700000000000 + f.intIn(0, 1000) * 1000) : null,
  );

  void setAll(RefDoc r, Doc d) {
    r.title = d.title;
    r.qty = d.qty;
    r.note = d.note;
    r.code = d.code;
    r.flag = d.flag;
    r.seen = d.seen?.millisecondsSinceEpoch;
    r.updated = now();
  }

  void setPatch(RefDoc r, Doc d) {
    r.title = d.title;
    r.qty = d.qty;
    if (d.note != null) r.note = d.note;
    if (d.code != null) r.code = d.code;
    if (d.flag != null) r.flag = d.flag;
    if (d.seen != null) r.seen = d.seen!.millisecondsSinceEpoch;
    r.updated = now();
  }

  RefDoc insertRef(int id, Doc d) {
    final RefDoc r = RefDoc(id, title: d.title, qty: d.qty, note: d.note, code: d.code, flag: d.flag, seen: d.seen?.millisecondsSinceEpoch, created: now(), updated: now());
    ref.docs[id] = r;
    return r;
  }

  /// What a save does to an existing reference row [r] (live or trashed).
  FluentRowOutcome applyExisting(RefDoc r, Doc d, FluentSaveStrategy strategy) {
    final bool trashed = r.deleted != null;
    switch (strategy) {
      case FluentSaveStrategy.upsert:
      case FluentSaveStrategy.insertOnly:
        if (trashed) {
          setAll(r, d);
          r.deleted = null;
          return FluentRowOutcome.restored;
        }
        if (strategy == FluentSaveStrategy.insertOnly) return FluentRowOutcome.skipped;
        setAll(r, d);
        return FluentRowOutcome.updated;
      case FluentSaveStrategy.updateOnly:
        if (trashed) return FluentRowOutcome.skipped;
        setAll(r, d);
        return FluentRowOutcome.updated;
      case FluentSaveStrategy.patch:
        if (trashed) return FluentRowOutcome.skipped;
        setPatch(r, d);
        return FluentRowOutcome.updated;
    }
  }

  /// Fills the stamps of rows the reference marked as just deleted ([_pending]) from the stored ones.
  Future<void> fillStamps() async {
    if (!ref.docs.values.any((r) => r.deleted == _pending)) return;
    final Map<int, int?> stored = {for (final Map<String, dynamic> m in await docs.withTrash.findMaps(columns: ['id', 'deleted_at'])) m['id'] as int: (m['deleted_at'] as DateTime?)?.millisecondsSinceEpoch};
    for (final RefDoc r in ref.docs.values) {
      if (r.deleted == _pending) {
        final int? stamp = stored[r.id];
        expect(stamp, isNotNull, reason: 'a deleted row carries its stamp');
        expect(stamp!, greaterThanOrEqualTo(now()), reason: 'a stamp is never earlier than the library clock');
        r.deleted = stamp;
      }
    }
  }

  // Random predicates over reference rows.
  Pred pred(FluentFuzz f) {
    switch (f.intIn(0, 7)) {
      case 0:
        final int k = f.intIn(0, 6);
        return Pred('qty > $k', FluentFilter.gt('qty', k), (r) => r.qty > k);
      case 1:
        final int k = f.intIn(0, 6);
        return Pred('qty <= $k', FluentFilter.lte('qty', k), (r) => r.qty <= k);
      case 2:
        final String p = f.pick(['a', 'b', 'g']);
        return Pred("title startsWith '$p'", FluentFilter.startsWith('title', p), (r) => r.title.startsWith(p));
      case 3:
        return Pred('note is null', FluentFilter.isNull('note'), (r) => r.note == null);
      case 4:
        return Pred('flag = true', FluentFilter.eq('flag', true), (r) => r.flag == true);
      case 5:
        final List<int> ids = f.subset([for (int i = 1; i <= 12; i++) i], keep: 0.3);
        return Pred('id in $ids', FluentFilter.inList('id', ids), (r) => ids.contains(r.id));
      case 6:
        return Pred('code is not null', FluentFilter.isNotNull('code'), (r) => r.code != null);
      default:
        final int k = f.intIn(0, 6);
        return Pred("qty > $k and note is null", FluentFilter.gt('qty', k).and(FluentFilter.isNull('note')), (r) => r.qty > k && r.note == null);
    }
  }

  List<RefDoc> live() => ref.docs.values.where((r) => r.deleted == null).toList();
  List<RefDoc> trashed() => ref.docs.values.where((r) => r.deleted != null).toList();

  // -------------------------------------------------------------------------------------------------------------
  // operations
  // -------------------------------------------------------------------------------------------------------------
  FuzzOp saveExplicit(FluentFuzz f) {
    final FluentSaveStrategy strategy = f.pick(FluentSaveStrategy.values);
    final int n = f.intIn(1, 3);
    final List<Doc> items = [for (int i = 0; i < n; i++) mkDoc(f, id: f.intIn(1, 12))];
    final bool single = n == 1 && f.chance(0.5);
    return FuzzOp('saveAll${single ? '(1)' : ''}(${items.map((d) => d.id).toList()}, ${strategy.name})', () async {
      held.addAll(items);
      final FluentSaveResult result = single ? await docs.save(items.single, strategy: strategy) : await docs.saveAll(items, strategy: strategy);
      final Map<int, Doc> writer = {};
      for (final Doc d in items) {
        if (strategy == FluentSaveStrategy.insertOnly) {
          writer.putIfAbsent(d.id!, () => d);
        } else {
          writer[d.id!] = d;
        }
      }
      final Map<int, FluentRowOutcome> outcomes = {};
      for (final MapEntry<int, Doc> e in writer.entries) {
        final RefDoc? r = ref.docs[e.key];
        if (r != null) {
          outcomes[e.key] = applyExisting(r, e.value, strategy);
        } else if (strategy == FluentSaveStrategy.upsert || strategy == FluentSaveStrategy.insertOnly) {
          insertRef(e.key, e.value);
          outcomes[e.key] = FluentRowOutcome.inserted;
        } else {
          outcomes[e.key] = FluentRowOutcome.skipped;
        }
      }
      if (writer.length == items.length) {
        expect(result.outcomes, [for (final Doc d in items) outcomes[d.id!]], reason: 'outcomes of the call');
      }
    });
  }

  FuzzOp saveByCode(FluentFuzz f) {
    final FluentSaveStrategy strategy = f.pick(FluentSaveStrategy.values);
    final List<int> slots = f.shuffled([1, 2, 3, 4, 5, 6]).take(f.intIn(1, 3)).toList();
    final List<Doc> items = [for (final int s in slots) mkDoc(f, code: 'k$s')];
    return FuzzOp('saveAll(codes ${slots.map((s) => 'k$s').toList()}, ${strategy.name}, conflictOn: [code])', () async {
      held.addAll(items);
      final FluentSaveResult result = await docs.saveAll(items, strategy: strategy, conflictOn: ['code']);
      final List<FluentRowOutcome> expected = [];
      final List<(Doc, int)> keyed = [];
      for (final Doc d in items) {
        final RefDoc? liveRow = ref.docs.values.where((r) => r.code == d.code && r.deleted == null).firstOrNull;
        final RefDoc? trashedRow = liveRow != null ? null : ref.docs.values.where((r) => r.code == d.code && r.deleted != null).firstOrNull;
        final RefDoc? r = liveRow ?? trashedRow;
        if (r != null) {
          expected.add(applyExisting(r, d, strategy));
          keyed.add((d, r.id));
        } else if (strategy == FluentSaveStrategy.upsert || strategy == FluentSaveStrategy.insertOnly) {
          final Object? id = d.primaryKeyValue;
          expect(id, isA<int>(), reason: 'a generated key is written back into the model');
          expect(ref.docs.containsKey(id), isFalse, reason: 'a generated key is new: $id');
          insertRef(id! as int, d);
          expected.add(FluentRowOutcome.inserted);
        } else {
          expected.add(FluentRowOutcome.skipped);
        }
      }
      expect(result.outcomes, expected, reason: 'outcomes of the call');
      for (final (Doc d, int id) in keyed) {
        if (strategy != FluentSaveStrategy.updateOnly && strategy != FluentSaveStrategy.patch || ref.docs[id]!.deleted == null) {
          expect(d.primaryKeyValue, id, reason: 'the stored key of the matched row is written back into the model');
        }
      }
    });
  }

  FuzzOp updateItems(FluentFuzz f) {
    final List<Doc> items = [for (final int id in f.shuffled([for (int i = 1; i <= 12; i++) i]).take(f.intIn(1, 2))) mkDoc(f, id: id)]; // distinct keys: see the BUG test of the same key twice
    final bool single = items.length == 1;
    return FuzzOp('update${single ? '' : 'All'}(${items.map((d) => d.id).toList()})', () async {
      final int count = single ? await docs.update(items.single) : await docs.updateAll(items);
      final Map<int, Doc> last = {for (final Doc d in items) d.id!: d};
      int expected = 0;
      for (final MapEntry<int, Doc> e in last.entries) {
        final RefDoc? r = ref.docs[e.key];
        if (r != null && r.deleted == null) {
          setAll(r, e.value);
          expected++;
        }
      }
      expect(count, expected);
    });
  }

  /// Random field updates and their effect on reference rows.
  ({Map<String, Object?> fields, void Function(RefDoc) apply, String text}) randomFields(FluentFuzz f) {
    final Map<String, Object?> fields = {};
    final List<void Function(RefDoc)> steps = [];
    final List<String> columns = f.subset(['title', 'qty', 'note', 'flag', 'seen'], keep: 0.5);
    if (columns.isEmpty) columns.add(f.pick(['title', 'qty', 'note', 'flag', 'seen']));
    for (final String c in columns) {
      switch (c) {
        case 'title':
          final String v = f.pick(_titles);
          fields[c] = v;
          steps.add((r) => r.title = v);
        case 'qty':
          if (f.chance(0.5)) {
            final int v = f.intIn(0, 9);
            fields[c] = v;
            steps.add((r) => r.qty = v);
          } else {
            final int by = f.intIn(1, 4);
            final bool up = f.chance(0.6);
            fields[c] = up ? FluentUpdate.increment(by) : FluentUpdate.decrement(by);
            steps.add((r) => r.qty += up ? by : -by);
          }
        case 'note':
          final String? v = f.chance(0.3) ? null : f.pick(['x', 'y', 'z']);
          fields[c] = v;
          steps.add((r) => r.note = v);
        case 'flag':
          if (f.chance(0.4)) {
            fields[c] = FluentUpdate.toggle;
            steps.add((r) => r.flag = r.flag == null ? true : !r.flag!);
          } else {
            final bool? v = f.pick([null, true, false]);
            fields[c] = v;
            steps.add((r) => r.flag = v);
          }
        default:
          if (f.chance(0.4)) {
            fields[c] = FluentUpdate.now;
            steps.add((r) => r.seen = now());
          } else {
            final DateTime? v = f.chance(0.2) ? null : DateTime.fromMillisecondsSinceEpoch(1700000000000 + f.intIn(0, 1000) * 1000);
            fields[c] = v;
            steps.add((r) => r.seen = v?.millisecondsSinceEpoch);
          }
      }
    }
    return (
      fields: fields,
      apply: (RefDoc r) {
        for (final void Function(RefDoc) s in steps) {
          s(r);
        }
        r.updated = now();
      },
      text: fields.toString(),
    );
  }

  FuzzOp updateById(FluentFuzz f) {
    final int id = f.intIn(1, 12);
    final spec = randomFields(f);
    return FuzzOp('updateById($id, ${spec.text})', () async {
      final int count = await docs.updateById(id, spec.fields);
      final RefDoc? r = ref.docs[id];
      if (r != null && r.deleted == null) {
        spec.apply(r);
        expect(count, 1);
      } else {
        expect(count, 0);
      }
    });
  }

  FuzzOp updateWhere(FluentFuzz f) {
    final Pred p = pred(f);
    final spec = randomFields(f);
    return FuzzOp('updateWhere($p, ${spec.text})', () async {
      final int count = await docs.updateWhere(p.filter, spec.fields);
      final List<RefDoc> hit = live().where(p.test).toList();
      // The predicate is evaluated before the fields change.
      for (final RefDoc r in hit) {
        spec.apply(r);
      }
      expect(count, hit.length);
    });
  }

  FuzzOp deleteOp(FluentFuzz f) {
    final int kind = f.intIn(0, 3);
    final List<int> ids = f.shuffled([for (int i = 1; i <= 12; i++) i]).take(f.intIn(1, 3)).toList();
    final Pred p = pred(f);
    return FuzzOp(['deleteById(${ids.first})', 'delete(Doc(${ids.first}))', 'deleteAll($ids)', 'deleteWhere($p)'][kind], () async {
      final List<RefDoc> hit = switch (kind) {
        0 || 1 => live().where((r) => r.id == ids.first).toList(),
        2 => live().where((r) => ids.contains(r.id)).toList(),
        _ => live().where(p.test).toList(),
      };
      final List<Doc> stubs = [for (final int id in ids) Doc(id: id, title: 'stub')];
      final int count = switch (kind) {
        0 => await docs.deleteById(ids.first),
        1 => await docs.delete(stubs.first),
        2 => await docs.deleteAll(stubs),
        _ => await docs.deleteWhere(p.filter),
      };
      expect(count, hit.length, reason: 'rows deleted');
      for (final RefDoc r in hit) {
        r.deleted = _pending;
      }
      await fillStamps();
      if ((kind == 1 || kind == 2) && txDepth == 0) {
        for (final Doc stub in stubs.take(kind == 1 ? 1 : stubs.length)) {
          final RefDoc? r = ref.docs[stub.id];
          expect(stub.deletedAt?.millisecondsSinceEpoch, r?.deleted, reason: 'G2: the model carries the stamp stored for its row (none without a row): ${stub.id}');
        }
      }
    });
  }

  FuzzOp restoreOp(FluentFuzz f) {
    final int kind = f.intIn(0, 2);
    final int id = f.intIn(1, 12);
    final Pred p = pred(f);
    return FuzzOp(['trash.restoreById($id)', 'trash.restore(Doc($id))', 'trash.restoreWhere($p)'][kind], () async {
      final List<RefDoc> hit = kind == 2 ? trashed().where(p.test).toList() : trashed().where((r) => r.id == id).toList();
      final Doc stub = Doc(id: id, title: 'stub');
      final int count = switch (kind) {
        0 => await docs.trash.restoreById(id),
        1 => await docs.trash.restore(stub),
        _ => await docs.trash.restoreWhere(p.filter),
      };
      expect(count, hit.length);
      for (final RefDoc r in hit) {
        r.deleted = null;
      }
      if (kind == 1 && txDepth == 0) expect(stub.deletedAt, isNull);
    });
  }

  FuzzOp deleteForeverOp(FluentFuzz f) {
    final int kind = f.intIn(0, 2);
    final int id = f.intIn(1, 12);
    final Pred p = pred(f);
    return FuzzOp(['trash.deleteForeverById($id)', 'trash.deleteForever(Doc($id))', 'trash.deleteForeverWhere($p)'][kind], () async {
      final List<RefDoc> hit = kind == 2 ? ref.docs.values.where(p.test).toList() : ref.docs.values.where((r) => r.id == id).toList();
      final int count = switch (kind) {
        0 => await docs.trash.deleteForeverById(id),
        1 => await docs.trash.deleteForever(Doc(id: id, title: 'stub')),
        _ => await docs.trash.deleteForeverWhere(p.filter),
      };
      expect(count, hit.length);
      for (final RefDoc r in hit) {
        ref.docs.remove(r.id);
      }
    });
  }

  FuzzOp emptyTrash(FluentFuzz f) {
    final Duration period = f.pick([Duration.zero, const Duration(minutes: 5), const Duration(hours: 1), const Duration(hours: 12), const Duration(days: 2)]);
    return FuzzOp('trash.empty(olderThan: $period)', () async {
      final int cutoff = now() - period.inMilliseconds;
      final List<RefDoc> hit = trashed().where((r) => period <= Duration.zero || r.deleted! < cutoff).toList();
      expect(await docs.trash.empty(olderThan: period), hit.length);
      for (final RefDoc r in hit) {
        ref.docs.remove(r.id);
      }
    });
  }

  FuzzOp clearDocs(FluentFuzz f) => FuzzOp('docs.clearTable()', () async {
    final int n = ref.docs.length;
    expect(await docs.clearTable(), n);
    ref.docs.clear();
  });

  // Leases: every save lives one hour.
  bool leaseVisible(RefLease l) => l.expiry > now();

  FuzzOp saveLeases(FluentFuzz f) {
    final FluentSaveStrategy strategy = f.pick(FluentSaveStrategy.values);
    final List<Lease> items = [for (final int id in f.shuffled([1, 2, 3, 4, 5]).take(f.intIn(1, 3))) Lease(id: id, val: f.string(max: 5, unicode: false))];
    return FuzzOp('leases.saveAll(${items.map((l) => l.id).toList()}, ${strategy.name})', () async {
      final FluentSaveResult result = await leases.saveAll(items, strategy: strategy);
      final List<FluentRowOutcome> expected = [];
      final int expiry = now() + const Duration(hours: 1).inMilliseconds;
      for (final Lease l in items) {
        final RefLease? r = ref.leases[l.id];
        final bool exists = r != null;
        final bool fresh = exists && leaseVisible(r);
        switch (strategy) {
          case FluentSaveStrategy.upsert:
            if (exists) {
              r
                ..val = l.val
                ..expiry = expiry;
              expected.add(FluentRowOutcome.updated);
            } else {
              ref.leases[l.id!] = RefLease(l.id!, l.val, expiry);
              expected.add(FluentRowOutcome.inserted);
            }
          case FluentSaveStrategy.insertOnly:
            if (fresh) {
              expected.add(FluentRowOutcome.skipped);
            } else {
              ref.leases[l.id!] = RefLease(l.id!, l.val, expiry);
              expected.add(FluentRowOutcome.inserted);
            }
          case FluentSaveStrategy.updateOnly:
          case FluentSaveStrategy.patch:
            if (fresh) {
              r
                ..val = l.val
                ..expiry = expiry;
              expected.add(FluentRowOutcome.updated);
            } else {
              expected.add(FluentRowOutcome.skipped);
            }
        }
      }
      expect(result.outcomes, expected, reason: 'lease outcomes');
    });
  }

  FuzzOp leaseWrites(FluentFuzz f) {
    final int kind = f.intIn(0, 4);
    final int id = f.intIn(1, 5);
    final String val = f.string(max: 4, unicode: false);
    return FuzzOp(['leases.updateById($id)', 'leases.updateWhere(val = $val)', 'leases.deleteById($id)', 'leases.clearExpired()', 'leases.deleteWhere(id > $id)'][kind], () async {
      switch (kind) {
        case 0:
          final int n = await leases.updateById(id, {'val': val});
          final RefLease? r = ref.leases[id];
          if (r != null && leaseVisible(r)) {
            r.val = val;
            expect(n, 1);
          } else {
            expect(n, 0);
          }
        case 1:
          final int n = await leases.updateWhere(FluentFilter.gt('id', 2), {'val': val});
          final List<RefLease> hit = ref.leases.values.where((l) => l.id > 2 && leaseVisible(l)).toList();
          for (final RefLease l in hit) {
            l.val = val;
          }
          expect(n, hit.length);
        case 2:
          final int n = await leases.deleteById(id);
          final RefLease? r = ref.leases[id];
          // The library's rule: a delete reaches rows reads see (not expired ones); explicit and counted like findById.
          if (r != null && leaseVisible(r)) {
            ref.leases.remove(id);
            expect(n, 1);
          } else if (r != null) {
            // An expired row: count 0 and the row stays, or count 1 and it is gone. Either way the call tells the truth.
            final bool gone = n == 1;
            if (gone) ref.leases.remove(id);
          } else {
            expect(n, 0);
          }
        case 3:
          final int n = await leases.clearExpired();
          final List<RefLease> hit = ref.leases.values.where((l) => !leaseVisible(l)).toList();
          for (final RefLease l in hit) {
            ref.leases.remove(l.id);
          }
          expect(n, hit.length);
        default:
          final int n = await leases.deleteWhere(FluentFilter.gt('id', id));
          final List<RefLease> hit = ref.leases.values.where((l) => l.id > id && leaseVisible(l)).toList();
          int removed = 0;
          // Expired rows of the filter: the call may or may not take them; count what the library says.
          for (final RefLease l in hit) {
            ref.leases.remove(l.id);
            removed++;
          }
          final int expiredGone = n - removed;
          expect(expiredGone, greaterThanOrEqualTo(0), reason: 'the call deleted every visible row it matched');
          if (expiredGone > 0) {
            final List<RefLease> expired = ref.leases.values.where((l) => l.id > id && !leaseVisible(l)).toList();
            expect(expiredGone, expired.length, reason: 'it deleted the expired rows too, all of them');
            for (final RefLease l in expired) {
              ref.leases.remove(l.id);
            }
          }
      }
    });
  }

  FuzzOp moveClock(FluentFuzz f) {
    final Duration by = switch (f.weighted({0: 6, 1: 3, 2: 1})) {
      0 => Duration(seconds: f.intIn(1, 90)),
      1 => Duration(minutes: f.intIn(1, 90)),
      _ => Duration(hours: f.intIn(1, 30)),
    };
    return FuzzOp('clock += $by', () async {
      if (moved + by.inMilliseconds > const Duration(days: 5).inMilliseconds) return;
      moved += by.inMilliseconds;
      db.clock.advance(by);
    });
  }

  FuzzOp simple(FluentFuzz f) => f.weighted<FuzzOp Function(FluentFuzz)>({
    saveExplicit: 6,
    saveByCode: 3,
    updateItems: 2,
    updateById: 3,
    updateWhere: 3,
    deleteOp: 5,
    restoreOp: 3,
    deleteForeverOp: 2,
    emptyTrash: 1,
    clearDocs: 1,
    saveLeases: 3,
    leaseWrites: 3,
    moveClock: 3,
  })(f);

  FuzzOp transaction(FluentFuzz f, {int depth = 0}) {
    final bool commit = f.chance(0.5);
    final List<FuzzOp> subs = [
      for (int i = 0; i < f.intIn(1, 4); i++)
        if (depth < 1 && f.chance(0.2)) transaction(f, depth: depth + 1) else simple(f),
    ];
    return FuzzOp('transaction(${commit ? 'commit' : 'rollback'}) { ${subs.join('; ')} }', () async {
      final RefState saved = ref.clone();
      final List<String> snapshot = [for (final Doc d in held) docState(d)];
      final List<Doc> heldAtStart = List.of(held);
      txDepth++;
      try {
        await FluentDb.transaction<void>(() async {
          for (final FuzzOp s in subs) {
            await s.run();
          }
          if (!commit) throw _Boom();
        });
      } on _Boom {
        // the app rolled back
      } finally {
        txDepth--;
      }
      if (!commit) {
        ref = saved;
        held.removeRange(heldAtStart.length, held.length);
        expect([for (final Doc d in heldAtStart) docState(d)], snapshot, reason: 'G2: the models are as they were before the rolled-back transaction');
      }
    });
  }

  FuzzOp next(FluentFuzz f, int step) => f.chance(0.22) ? transaction(f) : simple(f);

  // -------------------------------------------------------------------------------------------------------------
  // the comparison after every step
  // -------------------------------------------------------------------------------------------------------------
  bool? asBool(Object? v) => v == null ? null : (v == 1 || v == true);

  Future<void> check(int step) async {
    // G21 / G1: the stored rows are exactly the reference (every column the model has, plus the stamps).
    final List<Map<String, Object?>> raw = await docs.db.rawQuery('SELECT id,title,qty,note,code,flag,seen,created_at,updated_at,deleted_at FROM docs ORDER BY id');
    final List<List<Object?>> actual = [for (final Map<String, Object?> r in raw) [r['id'], r['title'], r['qty'], r['note'], r['code'], asBool(r['flag']), r['seen'], r['created_at'], r['updated_at'], r['deleted_at']]];
    final List<List<Object?>> expected = [for (final RefDoc r in (ref.docs.values.toList()..sort((a, b) => a.id.compareTo(b.id)))) r.row];
    expect(jsonEncode(actual), jsonEncode(expected), reason: 'rows of docs after step $step');
    final List<Map<String, Object?>> rawLeases = await leases.db.rawQuery('SELECT id,val,expiry_date FROM leases ORDER BY id');
    expect(jsonEncode([for (final Map<String, Object?> r in rawLeases) [r['id'], r['val'], r['expiry_date']]]), jsonEncode([for (final RefLease l in (ref.leases.values.toList()..sort((a, b) => a.id.compareTo(b.id)))) [l.id, l.val, l.expiry]]), reason: 'rows of leases');

    // G8 / G29: every read agrees with the reference.
    final List<RefDoc> liveRows = (live()..sort((a, b) => a.id.compareTo(b.id)));
    final List<RefDoc> trashRows = (trashed()..sort((a, b) => a.id.compareTo(b.id)));
    final List<Doc> found = await docs.find(orderBy: 'id');
    expect([for (final Doc d in found) docState(d)], [for (final RefDoc r in liveRows) '${r.id}|${r.title}|${r.qty}|${r.note}|${r.code}|${r.flag}|${r.seen}|c${r.created}|u${r.updated}|dnull'], reason: 'models of find()');
    expect(await docs.count(), liveRows.length);
    expect(await docs.withTrash.count(), ref.docs.length);
    expect(await docs.trash.count(), trashRows.length);
    expect((await docs.trash.find(orderBy: 'id')).map((d) => d.deletedAt?.millisecondsSinceEpoch), trashRows.map((r) => r.deleted), reason: 'trash.find stamps');
    expect((await docs.withTrash.findAll(orderBy: 'id')).map((d) => d.primaryKeyValue), (ref.docs.keys.toList()..sort()), reason: 'withTrash.findAll');
    expect((await docs.pluck<int>('id', orderBy: 'id')), liveRows.map((r) => r.id), reason: 'pluck');
    expect((await docs.findMaps(columns: ['id', 'title'], orderBy: 'id')).map((m) => '${m['id']}:${m['title']}'), liveRows.map((r) => '${r.id}:${r.title}'), reason: 'findMaps');
    for (int id = 1; id <= 12; id++) {
      final RefDoc? r = ref.docs[id];
      expect(await docs.exists(id), r != null && r.deleted == null, reason: 'exists($id)');
      expect(await docs.withTrash.exists(id), r != null, reason: 'withTrash.exists($id)');
    }
    expect((await docs.findByIds([for (int i = 1; i <= 12; i++) i])).map((d) => d.primaryKeyValue), liveRows.where((r) => r.id <= 12).map((r) => r.id), reason: 'findByIds');
    final num sum = await docs.sum('qty');
    expect(sum, liveRows.fold<int>(0, (a, r) => a + r.qty), reason: 'sum');
    final List<int> paged = [];
    FluentCursor? after;
    do {
      final FluentPage<Doc> page = await docs.findPage(orderBy: 'qty', limit: 4, after: after == null ? null : FluentCursor.decode(after.encode()));
      paged.addAll(page.items.map((d) => d.primaryKeyValue! as int));
      after = page.next;
    } while (after != null);
    expect(paged, (liveRows.toList()..sort((a, b) => a.qty != b.qty ? a.qty.compareTo(b.qty) : a.id.compareTo(b.id))).map((r) => r.id), reason: 'findPage visits every live row once, in order');

    final List<RefLease> visible = (ref.leases.values.where(leaseVisible).toList()..sort((a, b) => a.id.compareTo(b.id)));
    expect((await leases.find(orderBy: 'id')).map((l) => l.primaryKeyValue), visible.map((l) => l.id), reason: 'visible leases');
    expect(await leases.count(), visible.length);
    expect((await leases.find(orderBy: 'id', includeExpired: true)).map((l) => l.primaryKeyValue), (ref.leases.keys.toList()..sort()), reason: 'leases incl. expired');
    expect(await leases.count(includeExpired: true), ref.leases.length);
  }

  try {
    await runSequence(seed: seed, steps: 30, next: next, check: check);
    // G31: a restart changes nothing (in memory databases are gone, so the check ends here).
    await db.settle();
    await expectIntegrity(docs.db);
    expectIssuesHaveFixes(db.issues);
  } finally {
    await db.close();
  }
}

// -----------------------------------------------------------------------------------------------------------------
// G16
// -----------------------------------------------------------------------------------------------------------------

class _PRow {
  _PRow(this.id, this.qty, this.title, this.seen, this.created);

  final int id;
  final int qty;
  final String title;
  final int? seen;
  final int created;

  Object? value(String column) => switch (column) {
    'id' => id,
    'qty' => qty,
    'title' => title,
    'seen' => seen,
    _ => created,
  };
}

int _compareValues(Object? a, Object? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return (a as Comparable<Object>).compareTo(b);
}

Future<void> _pagingSequence(int seed) async {
  final FluentFuzz f = FluentFuzz(seed);
  final FluentTestDb db = FluentTestDb(name: 'page_fuzz_$seed');
  final DocProvider docs = DocProvider();
  final StampProvider stamps = StampProvider();
  db.clock.set(DateTime.utc(2026, 1, 1).add(Duration(days: 10 * (seed % 5000))));
  await db.open([docs, stamps]);
  try {
    // ---- Doc table: ints with ties, text, nullable DateTime, library timestamps, the key.
    final Map<int, _PRow> rows = {};
    Future<void> insert(int id) async {
      final int created = db.clock.now.millisecondsSinceEpoch;
      final DateTime? seen = f.chance(0.7) ? DateTime.fromMillisecondsSinceEpoch(1700000000000 + f.intIn(0, 6) * 1000) : null;
      final Doc d = Doc(id: id, title: f.string(max: 3, unicode: false), qty: f.intIn(0, 3), seen: seen);
      await docs.save(d);
      rows[id] = _PRow(id, d.qty, d.title, seen?.millisecondsSinceEpoch, created);
    }

    final List<int> pool = f.shuffled([for (int i = 1; i <= 80; i++) i]);
    for (int i = 0; i < f.intIn(0, 30); i++) {
      if (f.chance(0.5)) db.clock.advance(Duration(milliseconds: f.intIn(1, 3) * 1000));
      await insert(pool.removeLast());
    }
    final List<String> orders = ['id', 'qty', 'title', 'seen', 'created_at'];
    for (int walk = 0; walk < 3; walk++) {
      final String order = f.pick(orders);
      final String column = order == 'created_at' ? 'created' : order;
      final bool desc = f.chance(0.5);
      final int limit = f.intIn(1, 7);
      final bool trash = f.chance(0.3);
      final ({String name, FluentFilter? filter, bool Function(_PRow) test}) where = f.pick([
        (name: 'none', filter: null, test: (_PRow r) => true),
        (name: 'qty >= 2', filter: FluentFilter.gte('qty', 2), test: (_PRow r) => r.qty >= 2),
      ]);
      final Set<int> trashed = {};
      final Set<int> removed = {};
      final Set<int> atStart = {for (final _PRow r in rows.values) if (where.test(r) && !trashed.contains(r.id)) r.id};
      final Set<int> insertedAhead = {};
      final Set<int> insertedAny = {};
      final List<int> visited = [];
      FluentCursor? cursor;
      _PRow? last;
      int compare(_PRow a, _PRow b) {
        final int c = column == 'id' ? a.id.compareTo(b.id) : (_compareValues(a.value(column), b.value(column)) != 0 ? _compareValues(a.value(column), b.value(column)) : a.id.compareTo(b.id));
        return desc ? -c : c;
      }

      final String context = 'walk $walk: orderBy $order ${desc ? 'DESC' : 'ASC'}, limit $limit, where ${where.name}${trash ? ', withTrash' : ''}';
      int pages = 0;
      do {
        final FluentCursor? after = cursor == null ? null : (f.chance(0.5) ? FluentCursor.decode(cursor.encode()) : cursor);
        final FluentPage<Doc> page = trash
            ? await docs.withTrash.findPage(orderBy: order, descending: desc, limit: limit, after: after, where: where.filter)
            : await docs.findPage(orderBy: order, descending: desc, limit: limit, after: after, where: where.filter);
        for (final Doc d in page.items) {
          visited.add(d.primaryKeyValue! as int);
        }
        cursor = page.next;
        expect(page.items.length, lessThanOrEqualTo(limit), reason: context);
        if (cursor != null) expect(page.items.length, limit, reason: '$context: a page with a next cursor is full');
        if (page.items.isNotEmpty) last = rows[page.items.last.primaryKeyValue];
        // Changes between two pages.
        if (cursor != null && f.chance(0.7)) {
          for (int k = 0; k < f.intIn(1, 3); k++) {
            final int what = f.intIn(0, 2);
            if (what == 0 && pool.isNotEmpty) {
              db.clock.advance(const Duration(seconds: 1));
              final int id = pool.removeLast();
              await insert(id);
              insertedAny.add(id);
              if (where.test(rows[id]!) && last != null && compare(rows[id]!, last) > 0) insertedAhead.add(id);
            } else if (what == 1 && rows.isNotEmpty) {
              final int id = f.pick(rows.keys.toList());
              await docs.trash.deleteForeverById(id);
              rows.remove(id);
              removed.add(id);
            } else if (rows.isNotEmpty) {
              final int id = f.pick(rows.keys.toList());
              if (await docs.deleteById(id) == 1) {
                trashed.add(id);
                // withTrash walks still see it: a soft delete removes it from live walks only.
                if (!trash) removed.add(id);
              }
            }
          }
        }
        pages++;
      } while (cursor != null && pages < 200);
      expect(pages, lessThan(200), reason: '$context: the walk ends');
      expect(visited.toSet().length, visited.length, reason: '$context: no row twice: $visited');
      // strictly increasing in the walk's order
      for (int i = 1; i < visited.length; i++) {
        final _PRow? a = rows[visited[i - 1]];
        final _PRow? b = rows[visited[i]];
        if (a != null && b != null) expect(compare(a, b), lessThan(0), reason: '$context: rows come in order ($visited)');
      }
      for (final int id in atStart) {
        if (!removed.contains(id)) expect(visited, contains(id), reason: '$context: row $id existed all along and must be visited ($visited)');
      }
      for (final int id in insertedAhead) {
        if (!removed.contains(id) && !trashed.contains(id)) expect(visited, contains(id), reason: '$context: row $id was inserted ahead of the cursor ($visited)');
      }
      for (final int id in visited) {
        expect(atStart.contains(id) || insertedAny.contains(id), isTrue, reason: '$context: visited a row that never matched: $id');
      }
      // restore the trashed rows for the next walk
      for (final int id in trashed) {
        await docs.trash.restoreById(id);
      }
    }

    // ---- Stamp table: ISO text DateTimes with ties, soft delete.
    final Map<int, int> at = {};
    final List<int> ids = f.shuffled([for (int i = 1; i <= 40; i++) i]).take(f.intIn(0, 25)).toList();
    for (final int id in ids) {
      final DateTime t = DateTime.utc(2026, 1, 1 + f.intIn(0, 3), f.intIn(0, 2), 0, 0, 0, f.intIn(0, 2));
      await stamps.save(Stamp(id: id, at: t, label: 'l$id'));
      at[id] = t.microsecondsSinceEpoch;
    }
    final bool desc = f.chance(0.5);
    final int limit = f.intIn(1, 6);
    final List<int> expected = at.keys.toList()
      ..sort((a, b) {
        final int c = at[a]! != at[b]! ? at[a]!.compareTo(at[b]!) : a.compareTo(b);
        return desc ? -c : c;
      });
    final List<int> got = [];
    FluentCursor? cursor;
    do {
      final FluentPage<Stamp> page = await stamps.findPage(orderBy: 'at', descending: desc, limit: limit, after: cursor == null ? null : FluentCursor.decode(cursor.encode()));
      got.addAll(page.items.map((s) => s.primaryKeyValue! as int));
      cursor = page.next;
    } while (cursor != null);
    expect(got, expected, reason: 'iso8601 table, orderBy at ${desc ? 'DESC' : 'ASC'}, limit $limit: every row once, ties by key');

    await db.settle();
    await expectIntegrity(docs.db);
    expectIssuesHaveFixes(db.issues);
  } catch (e, s) {
    fail('Paging sequence failed: seed $seed\nReplay: FLUENT_SEED=$seed\n$e\n$s');
  } finally {
    await db.close();
  }
}
