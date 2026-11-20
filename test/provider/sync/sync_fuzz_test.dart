// Random sync sequences against a reference model (TEST_PLAN.md, T2, technique 1): local edits (save, update, delete,
// hard delete, restore, clearLocally, replaceLocally, clearTable), server edits and syncWithServer rounds with every
// conflict policy, batch sizes, rejects, failed / thrown pushes, failed pull pages, cancels and edits made while a push
// or pull is in flight. After every step the stored rows, the per-row sync state and pendingChanges() equal the
// reference (G23, G24); every round sends each pending change once and marks exactly what the server accepted (G23);
// a final quiet round converges with the server (G10) and a round after it changes nothing (G31).
@Timeout(Duration(seconds: 120))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fuzz.dart';
import '../../helpers/guarantees.dart';
import 'sync_fake_server.dart';

class FItem extends FluentStorable with FluentSoftDeletable {
  FItem({this.id, required this.name});

  final int? id;
  final String name;

  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true); // keys shared with the server

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class FItems extends FluentProvider<FItem> with FluentSyncable<FItem> {
  @override
  String get tableName => 'f_items';

  @override
  FItem get modelSample => FItem(name: '');

  @override
  FItem fromCacheJson(Map<String, dynamic> json) => FItem(id: json['id'] as int?, name: json['name'] as String);
}

class FNote extends FluentStorable {
  FNote({this.id, required this.name});

  final int? id;
  final String name;

  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.integer, isPrimaryKey: true);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class FNotes extends FluentProvider<FNote> with FluentSyncable<FNote> {
  @override
  String get tableName => 'f_notes';

  @override
  FNote get modelSample => FNote(name: '');

  @override
  FNote fromCacheJson(Map<String, dynamic> json) => FNote(id: json['id'] as int?, name: json['name'] as String);
}

/// The reference of one local row.
class RefRow {
  RefRow(this.name, {this.trashed = false, this.pending = false, this.known = false, this.edit = 0});

  String name;
  bool trashed;

  /// Has a change the server did not get yet.
  bool pending;

  /// The server has this key alive (as far as the device knows): deleting it must tell the server.
  bool known;

  /// Sequence number of the last local change (a push marks a row only when its batch was read after it).
  int edit;

  @override
  String toString() => '$name${trashed ? ' (trash)' : ''}${pending ? ' *' : ''}${known ? ' k' : ''}';
}

/// The reference model of the device: rows, pending deletions, since, rows evicted from the cache by clearLocally.
class Ref {
  final Map<int, RefRow> rows = {};
  final Set<int> tombstones = {};
  final Set<int> evicted = {};
  int? since;
  int seq = 0;

  Set<int> get pending => {for (final MapEntry<int, RefRow> e in rows.entries) if (e.value.pending) e.key};
  Map<int, String> get live => {for (final MapEntry<int, RefRow> e in rows.entries) if (!e.value.trashed) e.key: e.value.name};
  Set<int> get trash => {for (final MapEntry<int, RefRow> e in rows.entries) if (e.value.trashed) e.key};

  void save(int k, String name) {
    final RefRow? r = rows[k];
    if (r != null) {
      r
        ..name = name
        ..trashed = false
        ..pending = true
        ..edit = ++seq;
    } else {
      // A key whose deletion was not sent yet: the server still has it.
      rows[k] = RefRow(name, pending: true, known: tombstones.remove(k), edit: ++seq);
    }
    // An evicted key stays evicted until the server sends its row again (a local row over it is not the cached one).
  }

  /// A local delete for good (hard model delete, or trash.deleteForever).
  void hardDelete(int k) {
    final RefRow r = rows.remove(k)!;
    // Told to the server unless the server deleted it already (a trash that was pushed or came from the server).
    if (r.known && !(r.trashed && !r.pending)) tombstones.add(k);
  }

  /// A row stored from the server, synced.
  void storeSynced(int k, String name) {
    rows[k] = RefRow(name, known: true);
    tombstones.remove(k);
    evicted.remove(k);
  }

  @override
  String toString() => 'rows $rows, tombstones $tombstones, since $since, evicted $evicted';
}

/// One random sequence on one model ([soft]: with soft delete).
class SyncFuzz<T extends FluentStorable> {
  SyncFuzz({
    required this.db,
    required this.p,
    required this.server,
    required this.make,
    required this.nameOf,
    required this.soft,
    this.trashIds,
    this.deleteForever,
    this.restore,
  });

  final FluentTestDb db;
  final FluentSyncable<T> p;
  final FakeServer<T> server;
  final T Function(int id, String name) make;
  final String Function(T model) nameOf;
  final bool soft;
  final Future<Set<int>> Function()? trashIds;
  final Future<int> Function(int id)? deleteForever;
  final Future<int> Function(int id)? restore;
  final Ref ref = Ref();

  static const int keys = 8;
  int _names = 0;

  String _name(FluentFuzz f) => 'n${_names++}${f.chance(0.2) ? f.string(max: 4) : ''}';

  /// The ids of live rows / trashed rows / any row of the reference.
  List<int> get _live => ref.live.keys.toList()..sort();
  List<int> get _trashed => ref.trash.toList()..sort();

  FuzzOp next(FluentFuzz f, int step) {
    final String op = f.weighted({
      'save': 6,
      'update': 2,
      'delete': 3,
      if (soft) 'deleteForever': 1,
      if (soft) 'restore': 2,
      'clearLocally': 1,
      'replaceLocally': 1,
      'clearTable': 1,
      'serverEdit': 4,
      'serverDelete': 2,
      'sync': 7,
    });
    switch (op) {
      case 'save':
        final int k = f.intIn(1, keys);
        final String n = _name(f);
        return FuzzOp('save($k, $n)', () async {
          await p.save(make(k, n));
          ref.save(k, n);
        });
      case 'update':
        if (_live.isEmpty) return _noop();
        final int k = f.pick(_live);
        final String n = _name(f);
        return FuzzOp('updateById($k, $n)', () async {
          expect(await p.updateById(k, {'name': n}), 1);
          ref.save(k, n);
        });
      case 'delete':
        if (_live.isEmpty) return _noop();
        final int k = f.pick(_live);
        return FuzzOp('deleteById($k)', () async {
          expect(await p.deleteById(k), 1);
          if (soft) {
            ref.rows[k]!
              ..trashed = true
              ..pending = true
              ..edit = ++ref.seq;
          } else {
            ref.hardDelete(k);
          }
        });
      case 'deleteForever':
        if (ref.rows.isEmpty) return _noop();
        final int k = f.pick(ref.rows.keys.toList()..sort());
        return FuzzOp('trash.deleteForeverById($k)', () async {
          await deleteForever!(k);
          ref.hardDelete(k);
        });
      case 'restore':
        if (_trashed.isEmpty) return _noop();
        final int k = f.pick(_trashed);
        return FuzzOp('trash.restoreById($k)', () async {
          expect(await restore!(k), 1);
          ref.rows[k]!
            ..trashed = false
            ..pending = true
            ..edit = ++ref.seq;
        });
      case 'clearLocally':
        return FuzzOp('clearLocally(all)', () async {
          await p.clearLocally(FluentFilter.empty);
          for (final int k in ref.rows.keys.toList()) {
            if (!ref.rows[k]!.pending) {
              ref.rows.remove(k);
              ref.evicted.add(k);
            }
          }
        });
      case 'replaceLocally':
        return FuzzOp('replaceLocally(all, server rows)', () async {
          final Map<int, String> answer = server.alive;
          await p.replaceLocally(FluentFilter.empty, [for (final MapEntry<int, String> e in answer.entries) make(e.key, e.value)]);
          for (final int k in ref.rows.keys.toList()) {
            if (!ref.rows[k]!.pending) {
              ref.rows.remove(k);
              ref.evicted.add(k);
            }
          }
          answer.forEach((k, n) {
            if (ref.rows[k]?.pending ?? false) {
              ref.rows[k]!.known = true; // the server has it; the local change stays
              return;
            }
            if (ref.tombstones.contains(k)) return;
            ref.storeSynced(k, n);
          });
        });
      case 'clearTable':
        return FuzzOp('clearTable', () async {
          await p.clearTable();
          ref.rows.clear();
          ref.tombstones.clear();
          ref.evicted.clear();
          ref.since = null;
        });
      case 'serverEdit':
        final int k = f.intIn(1, keys);
        final String n = 's${_names++}';
        return FuzzOp('server.edit($k, $n)', () async => server.edit(k, n));
      case 'serverDelete':
        final int k = f.intIn(1, keys);
        return FuzzOp('server.delete($k)', () async => server.delete(k));
      default:
        return _sync(f);
    }
  }

  FuzzOp _noop() => FuzzOp('noop', () async {});

  FuzzOp _sync(FluentFuzz f) {
    final FluentSyncStrategy strategy = f.weighted({FluentSyncStrategy.full: 3, FluentSyncStrategy.push: 1, FluentSyncStrategy.pull: 1});
    final int policy = f.intIn(0, 2);
    final int? batchSize = f.pick(<int?>[null, 1, 2, 500]);
    final List<PushAnswer> answers = [
      if (f.chance(0.2)) ...[for (int i = f.intIn(0, 2); i > 0; i--) PushAnswer.accept, f.pick([PushAnswer.fail, PushAnswer.throwError])],
    ];
    final Set<int> reject = f.chance(0.2) ? f.subset([for (int k = 1; k <= keys; k++) k], keep: 0.3).toSet() : {};
    final Set<int> foreign = f.chance(0.1) ? {100 + f.intIn(0, 5)} : {};
    final int pageSize = f.pick([1, 2, 3, 1000]);
    final int? failPage = f.chance(0.15) ? f.intIn(0, 2) : null;
    final int? pushEditAt = f.chance(0.2) ? f.intIn(0, 1) : null;
    final int pushEditKey = f.intIn(1, keys);
    final String pushEditName = _name(f);
    final int? pullEditAt = f.chance(0.2) ? f.intIn(0, 2) : null;
    final bool pullEditIsServer = f.chance(0.5);
    final int pullEditKey = f.intIn(1, keys);
    final String pullEditName = _name(f);
    final int cancelKind = f.chance(0.1) ? f.intIn(1, 2) : 0; // 1: during a push call, 2: during a pull page
    final int cancelAt = f.intIn(0, 1);
    final String policyName = ['keepLocal', 'keepServer', 'merge'][policy];
    return FuzzOp(
      'sync(${strategy.name}, $policyName, batch $batchSize, answers $answers, reject $reject, foreign $foreign, page $pageSize, '
      'failPage $failPage, pushEdit ${pushEditAt == null ? '-' : '@$pushEditAt $pushEditKey'}, pullEdit ${pullEditAt == null ? '-' : '@$pullEditAt ${pullEditIsServer ? 'server' : 'local'} $pullEditKey'}, '
      'cancel ${cancelKind == 0 ? '-' : '${cancelKind == 1 ? 'push' : 'pull'}@$cancelAt'})',
      () => _round(
        strategy: strategy,
        policy: policy,
        batchSize: batchSize,
        answers: answers,
        reject: reject,
        foreign: foreign,
        pageSize: pageSize,
        failPage: failPage,
        pushEditAt: pushEditAt,
        pushEditKey: pushEditKey,
        pushEditName: pushEditName,
        pullEditAt: pullEditAt,
        pullEditIsServer: pullEditIsServer,
        pullEditKey: pullEditKey,
        pullEditName: pullEditName,
        cancelKind: cancelKind,
        cancelAt: cancelAt,
      ),
    );
  }

  /// One sync round; updates the reference from what the server received and answered.
  Future<void> _round({
    required FluentSyncStrategy strategy,
    required int policy,
    required int? batchSize,
    required List<PushAnswer> answers,
    required Set<int> reject,
    required Set<int> foreign,
    required int pageSize,
    required int? failPage,
    required int? pushEditAt,
    required int pushEditKey,
    required String pushEditName,
    required int? pullEditAt,
    required bool pullEditIsServer,
    required int pullEditKey,
    required String pullEditName,
    required int cancelKind,
    required int cancelAt,
  }) async {
    final FluentCancelToken cancel = FluentCancelToken();
    final Set<int> pendingAtStart = ref.pending;
    final Set<int> tombsAtStart = {...ref.tombstones};
    final int firstCall = server.received.length;
    final Map<int, int> batchSeq = {}; // push call -> seq when its batch had been read
    bool editedDuringPush = false;
    int? cancelledCall;
    int? cancelledPage;
    final List<FluentPullResult<T>> pages = [];

    server
      ..quiet()
      ..pushAnswers.addAll(answers)
      ..rejectKeys = reject
      ..rejectForeign = foreign
      ..pageSize = pageSize
      ..failPullPage = failPage;
    server.duringPush = (call, batch) async {
      batchSeq[call] = ++ref.seq;
      // Once sent, the server may have the rows (whatever its answer): deleting one later must tell it.
      for (final int k in [for (final T m in [...batch.changed, ...batch.deleted]) _idOf(m)]) {
        ref.rows[k]?.known = true;
      }
      final int local = call - firstCall;
      if (pushEditAt == local && !(ref.rows[pushEditKey]?.trashed ?? false)) {
        editedDuringPush = true;
        await p.save(make(pushEditKey, pushEditName));
        ref.save(pushEditKey, pushEditName);
      }
      if (cancelKind == 1 && cancelAt == local) {
        cancelledCall = call;
        cancel.cancel();
      }
    };
    server.duringPull = (request) async {
      if (pullEditAt == request.page) {
        if (pullEditIsServer) {
          server.edit(pullEditKey, pullEditName);
        } else if (!(ref.rows[pullEditKey]?.trashed ?? false)) {
          await p.save(make(pullEditKey, pullEditName));
          ref.save(pullEditKey, pullEditName);
        }
      }
      if (cancelKind == 2 && cancelAt == request.page) {
        cancelledPage = request.page;
        cancel.cancel();
      }
    };

    final FluentConflictPolicy<T> conflicts = switch (policy) {
      0 => FluentConflictPolicy<T>.keepLocal(),
      1 => FluentConflictPolicy<T>.keepServer(),
      _ => FluentConflictPolicy<T>.merge((l, r) async => make(_idOf(l), '${nameOf(l)}+${nameOf(r)}')),
    };
    // ---- push: what the server accepted, and what the library may mark (settled once the push phase is over) ----
    int accepted = 0;
    int rejected = 0;
    bool pushFailed = false;
    bool pushSettled = false;
    void settlePush() {
      if (pushSettled) return;
      pushSettled = true;
      for (final ReceivedBatch b in server.received.sublist(firstCall)) {
        final bool late = cancelledCall != null && b.call >= cancelledCall!;
        if (!b.accepted) {
          pushFailed = true;
          continue;
        }
        if (late) continue; // the answer is ignored: nothing marked
        accepted += b.rowKeys.length + b.deletedKeys.length - b.rejected.length;
        rejected += b.rejected.length;
        for (final int k in b.rowKeys) {
          if (b.rejected.contains(k)) continue;
          final RefRow? r = ref.rows[k];
          if (r != null && r.edit < batchSeq[b.call]!) r.pending = false;
        }
        ref.tombstones.removeAll(b.deletedKeys);
      }
    }

    // ---- pull: a page is applied by the library before it asks for the next one ----
    int applied = 0;
    void applyPages(int upTo) {
      for (; applied < upTo; applied++) {
        _applyPage(pages[applied], policy);
        if (!pages[applied].hasMore) ref.since = pages.first.serverTime!.millisecondsSinceEpoch;
      }
    }

    final FluentSyncResult<T> result = await p
        .syncWithServer(
          strategy: strategy,
          batchSize: batchSize,
          conflicts: conflicts,
          cancel: cancel,
          onPush: server.onPush,
          onPull: (request) async {
            settlePush();
            applyPages(request.page);
            final FluentPullResult<T> page = await server.onPull(request);
            pages.add(page);
            return page;
          },
        )
        .timeout(const Duration(seconds: 15));
    server.quiet();
    settlePush();
    final List<ReceivedBatch> batches = server.received.sublist(firstCall);

    // G23: every pending change went once; only changes that were pending (or edited meanwhile) went.
    final List<String> sent = [for (final ReceivedBatch b in batches) ...b.rowKeys.map((k) => 'row $k'), for (final ReceivedBatch b in batches) ...b.deletedKeys.map((k) => 'key $k')];
    if (strategy != FluentSyncStrategy.pull) {
      for (final ReceivedBatch b in batches) {
        for (final int k in b.rowKeys) {
          expect(pendingAtStart.contains(k) || (editedDuringPush && k == pushEditKey), isTrue, reason: 'G23: row $k was sent but had no change ($b)');
        }
        for (final int k in b.deletedKeys) {
          expect(tombsAtStart, contains(k), reason: 'G23: deletion of $k was sent but was not pending');
        }
      }
      final bool clean = !pushFailed && cancelledCall == null && !editedDuringPush;
      if (clean) {
        expect(sent, hasLength(sent.toSet().length), reason: 'G23: nothing is sent twice in one round: $sent');
        expect(sent.toSet(), {...pendingAtStart.map((k) => 'row $k'), ...tombsAtStart.map((k) => 'key $k')}, reason: 'G23: every pending change is sent');
        if (result.isSuccess || !result.isCancelled) {
          expect(result.pushed, accepted, reason: 'G23: pushed counts what the server accepted');
          expect(result.rejected, rejected, reason: 'G23: rejected counts what the server refused');
        }
      }
    }

    final bool pullRan = strategy != FluentSyncStrategy.push && !pushFailed && cancelledCall == null;
    if (pullRan && pages.isNotEmpty && pages.last.hasMore == false && cancelledPage == null) {
      applyPages(pages.length);
      expect(result.isSuccess, isTrue, reason: 'a complete round succeeds: ${result.errorMessage}');
    }
    if (pushFailed || cancelledCall != null) expect(result.isSuccess, isFalse, reason: 'a failed or cancelled push stops the round');
    if (strategy == FluentSyncStrategy.push && !pushFailed && cancelledCall == null) expect(result.isSuccess, isTrue, reason: 'a push the server accepted succeeds: ${result.errorMessage}');
    if (!result.isSuccess && !result.isCancelled) expectTypedError(result.error!, reason: 'sync error');
  }

  int _idOf(T m) => (m.buildJson()['id'] as int?)!;

  /// The reference effect of one pull page under [policy] (0 keepLocal, 1 keepServer, 2 merge), remote deletes auto.
  void _applyPage(FluentPullResult<T> page, int policy) {
    for (final T item in page.items) {
      final int k = _idOf(item);
      final String n = nameOf(item);
      final RefRow? r = ref.rows[k];
      final bool localChange = (r?.pending ?? false) || ref.tombstones.contains(k);
      if (policy == 1 || !localChange) {
        ref.storeSynced(k, n);
      } else if (policy == 2 && r != null && r.pending && !r.trashed) {
        r
          ..name = '${r.name}+$n'
          ..known = true
          ..edit = ++ref.seq;
      } else {
        r?.known = true; // the server has the row; the local change wins
      }
    }
    for (final Object key in page.deletedKeys) {
      final int k = key as int;
      final RefRow? r = ref.rows[k];
      if (r == null) continue;
      if (policy != 1 && r.pending) continue;
      if (soft) {
        // The server deleted this key, so it knew it: a restore and a delete for good before the next push report the
        // deletion again (like for a row that came from the server; a deletion of a key the server lacks is harmless).
        r
          ..trashed = true
          ..pending = false
          ..known = true;
      } else {
        ref.rows.remove(k);
      }
    }
  }

  /// G23 / G24: the stored state equals the reference.
  Future<void> check(int step) async {
    final Map<int, String> live = {for (final Map<String, dynamic> r in await p.findMaps()) r['id'] as int: r['name'] as String};
    expect(live, ref.live, reason: 'live rows (ref: $ref)');
    if (soft) expect(await trashIds!(), ref.trash, reason: 'trash (ref: $ref)');
    final SyncState s = await SyncState.read(db, p);
    expect(s.pending, ref.pending, reason: 'G23: rows with changes to push (ref: $ref)');
    expect(s.tombstones, ref.tombstones, reason: 'G23: deletions to push (ref: $ref)');
    expect(await p.pendingChanges(), ref.pending.length + ref.tombstones.length, reason: 'G23: pendingChanges() agrees');
    expect(s.lastPull, ref.since, reason: 'G24: since moves only after a complete pull');
  }

  /// G10 / G31: a quiet round converges; another one changes nothing; a full refresh equals the server.
  Future<void> converge() async {
    server.quiet();
    final FluentSyncResult<T> first = await server.sync(p, batchSize: null);
    expect(first.isSuccess, isTrue, reason: first.errorMessage);
    expect(await p.pendingChanges(), 0, reason: 'G10: a quiet round pushes every change');
    expect((await server.sync(p)).isSuccess, isTrue); // the echo of the pushed rows
    final Map<int, String> live = {for (final Map<String, dynamic> r in await p.findMaps()) r['id'] as int: r['name'] as String};
    final Map<int, String> alive = server.alive;
    for (final MapEntry<int, String> e in live.entries) {
      expect(alive[e.key], e.value, reason: 'G10: local row ${e.key} equals the server (ref: $ref)');
    }
    for (final int k in alive.keys) {
      if (!live.containsKey(k)) expect(ref.evicted, contains(k), reason: 'G10: server row $k is missing locally without clearLocally (ref: $ref)');
    }
    final String before = (await SyncState.read(db, p)).dump;
    final FluentSyncResult<T> quiet = await server.sync(p);
    expect(quiet.isSuccess, isTrue);
    expect((quiet.pushed, quiet.pulled), (0, 0), reason: 'G31: nothing new');
    expect((await SyncState.read(db, p)).dump, before, reason: 'G31: a quiet round changes nothing');
    // A full refresh: everything the server has, nothing else.
    await p.clearTable();
    expect((await server.sync(p, strategy: FluentSyncStrategy.pull)).isSuccess, isTrue);
    expect({for (final Map<String, dynamic> r in await p.findMaps()) r['id'] as int: r['name'] as String}, alive, reason: 'G10: nothing lost or doubled');
  }
}

void main() {
  setUpFluentTests();

  for (final int seed in fuzzSeeds(base: 20000)) {
    final bool soft = seed.isEven;
    test('G10 / G23 / G24 / G31: random sync sequence, ${soft ? 'soft delete' : 'hard delete'} model, seed $seed', () async {
      final FluentTestDb db = FluentTestDb(name: 'sync_fuzz_$seed');
      try {
        if (soft) {
          final FItems items = FItems();
          await db.open([items]);
          final SyncFuzz<FItem> fuzz = SyncFuzz<FItem>(
            db: db,
            p: items,
            server: FakeServer<FItem>(idOf: (m) => m.id!, nameOf: (m) => m.name, make: (id, n) => FItem(id: id, name: n)),
            make: (id, n) => FItem(id: id, name: n),
            nameOf: (m) => m.name,
            soft: true,
            trashIds: () async => {for (final FItem i in await items.trash.find()) i.id!},
            deleteForever: items.trash.deleteForeverById,
            restore: items.trash.restoreById,
          );
          await runSequence(seed: seed, steps: 31, next: (f, i) => i == 30 ? FuzzOp('converge (quiet rounds, refresh)', fuzz.converge) : fuzz.next(f, i), check: (i) => i == 30 ? null : fuzz.check(i));
          await expectIntegrity(items.db);
        } else {
          final FNotes notes = FNotes();
          await db.open([notes]);
          final SyncFuzz<FNote> fuzz = SyncFuzz<FNote>(
            db: db,
            p: notes,
            server: FakeServer<FNote>(idOf: (m) => m.id!, nameOf: (m) => m.name, make: (id, n) => FNote(id: id, name: n)),
            make: (id, n) => FNote(id: id, name: n),
            nameOf: (m) => m.name,
            soft: false,
          );
          await runSequence(seed: seed, steps: 31, next: (f, i) => i == 30 ? FuzzOp('converge (quiet rounds, refresh)', fuzz.converge) : fuzz.next(f, i), check: (i) => i == 30 ? null : fuzz.check(i));
          await expectIntegrity(notes.db);
        }
        expectIssuesHaveFixes(db.issues);
      } finally {
        await db.close();
      }
    });
  }
}
