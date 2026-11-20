// Chaos runs (TEST_PLAN.md, technique 6; agent T8): G12, G18, G30, G19 (+ G1 / G7 after recovery).
//
// Two file databases with a same-named table "notes": A (soft delete notes, folders with an owned list of
// soft-deletable files, a syncable table with a fake server) and B (plain notes). Each seed runs phases; a phase is
// a few segments of UNAWAITED calls of every kind (writes, reads, transactions nested and cross-database, sync
// rounds, pause / resume) while random statements fail, with init / close / restart / deleteDatabases /
// die()+heal()+restart between the segments. A reference model keeps the COMMITTED state: an op counts only when its
// future completed successfully (inside a transaction: when the outermost transaction of its database committed).
// Within a phase every op claims its rows, so committed ops commute; clears are ordered after the writes of their
// segment (they are the last call on their table and no cross-database body can call later).
//
// After each phase: every call settled (G12, typed errors G13), heal, integrity of both files (G19), data == the
// committed reference (G18 / G1), a clean round of every call kind issued unawaited agrees with the serial
// expectation (G7), watches converge, the sync server and the device agree.
//
// Replay a seed: FLUENT_SEED=<seed> bash tool/mirror_test.sh t8 test/regressions/chaos_test.dart
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/faults.dart';
import '../helpers/fuzz.dart';
import '../helpers/guarantees.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------------------------------------------------

class CNote extends FluentStorable with FluentSoftDeletable {
  CNote({this.id, required this.text, this.n = 0});

  final int? id;
  final String text;
  final int n;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'n': n};
}

class ANoteProvider extends FluentProvider<CNote> {
  @override
  String get tableName => 'notes';

  @override
  CNote get modelSample => CNote(text: '');

  @override
  CNote fromCacheJson(Map<String, dynamic> json) => CNote(id: json['id'] as int?, text: json['text'] as String, n: (json['n'] as int?) ?? 0);
}

class PNote extends FluentStorable {
  PNote({this.id, required this.text, this.n = 0});

  final int? id;
  final String text;
  final int n;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'n': n};
}

class BNoteProvider extends FluentProvider<PNote> {
  @override
  String get tableName => 'notes';

  @override
  PNote get modelSample => PNote(text: '');

  @override
  PNote fromCacheJson(Map<String, dynamic> json) => PNote(id: json['id'] as int?, text: json['text'] as String, n: (json['n'] as int?) ?? 0);
}

class FileRow extends FluentStorable with FluentSoftDeletable {
  FileRow({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class FileProvider extends FluentProvider<FileRow> {
  @override
  String get tableName => 'files';

  @override
  FileRow get modelSample => FileRow(name: '');

  @override
  FileRow fromCacheJson(Map<String, dynamic> json) => FileRow(id: json['id'] as int?, name: json['name'] as String);
}

class Folder extends FluentStorable with FluentRelations {
  Folder({this.id, required this.name, this.files});

  final int? id;
  final String name;
  final List<FileRow>? files;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Folder, FileRow>('files', (f) => f.files, orderBy: 'id')];
}

class FolderProvider extends FluentProvider<Folder> {
  @override
  String get tableName => 'folders';

  @override
  Folder get modelSample => Folder(name: '');

  @override
  Folder fromCacheJson(Map<String, dynamic> json) => Folder(id: json['id'] as int?, name: json['name'] as String, files: (json['files'] as List?)?.cast<FileRow>());
}

class SNote extends FluentStorable {
  SNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class SNoteProvider extends FluentProvider<SNote> with FluentSyncable<SNote> {
  @override
  String get tableName => 'snotes';

  @override
  SNote get modelSample => SNote(text: '');

  @override
  SNote fromCacheJson(Map<String, dynamic> json) => SNote(id: json['id'] as int?, text: json['text'] as String);
}

// ---------------------------------------------------------------------------------------------------------------------
// Reference model of the committed state
// ---------------------------------------------------------------------------------------------------------------------

typedef ANote = ({String text, int n, bool trashed});
typedef BNote = ({String text, int n});
typedef FileRef = ({String name, int folder, bool trashed});
typedef Apply = void Function(Ref r);

class Ref {
  final Map<int, ANote> a = {};
  final Map<int, BNote> b = {};
  final Map<int, String> folders = {};
  final Map<int, FileRef> files = {};

  /// Local-origin rows of the syncable table (ids below [serverIds]).
  final Map<int, String> s = {};

  Ref copy() => Ref()
    ..a.addAll(a)
    ..b.addAll(b)
    ..folders.addAll(folders)
    ..files.addAll(files)
    ..s.addAll(s);

  void clearA() {
    a.clear();
    folders.clear();
    files.clear();
    s.clear();
  }

  void clearB() => b.clear();
}

/// Server-origin ids of the syncable table start here; the device only writes ids below.
const int serverIds = 1000000;

/// A server that accepts pushes (failing every [failEvery]-th) and serves its own rows on every pull.
class FakeServer {
  /// Rows the device pushed.
  final Map<int, String> local = {};

  /// Rows that originate on the server (never changed, only added).
  final Map<int, String> own = {};
  int failEvery = 0;
  int _pushes = 0;
  final List<String> problems = [];

  Future<FluentPushResult<SNote>> push(FluentSyncBatch<SNote> batch) async {
    await Future<void>.delayed(Duration.zero);
    if (failEvery > 0 && ++_pushes % failEvery == 0) return const FluentPushResult.failed('server unavailable');
    for (final SNote n in batch.changed) {
      if (n.id! >= serverIds) {
        problems.add('G10: the device pushed server row ${n.id} it never changed');
        continue;
      }
      local[n.id!] = n.text;
    }
    for (final Object k in batch.deletedKeys) {
      local.remove(k as int);
    }
    return const FluentPushResult.accepted();
  }

  Future<FluentPullResult<SNote>> pull(FluentPullRequest r) async {
    await Future<void>.delayed(Duration.zero);
    return FluentPullResult(items: [for (final MapEntry<int, String> e in own.entries) SNote(id: e.key, text: e.value)], serverTime: DateTime.utc(2026));
  }
}

class _Rollback implements Exception {
  @override
  String toString() => 'deliberate rollback';
}

enum Db { a, b }

/// Two databases, their providers (the same instances for the whole run, like an app) and the reference.
class World {
  World(int seed) : keyA = FluentDbKey('chaos_a_$seed'), keyB = FluentDbKey('chaos_b_$seed');

  final FluentDbKey keyA;
  final FluentDbKey keyB;
  final ANoteProvider aNotes = ANoteProvider();
  final FolderProvider folders = FolderProvider();
  final FileProvider files = FileProvider();
  final SNoteProvider sNotes = SNoteProvider();
  final BNoteProvider bNotes = BNoteProvider();
  final FakeServer server = FakeServer();
  Ref ref = Ref();
  int _next = 1;

  int fresh() => _next++;

  FluentDbKey key(Db d) => d == Db.a ? keyA : keyB;

  List<FluentGroup> get groups => [
    FluentGroup(dbKey: keyA, providerList: [aNotes, folders, files, sNotes]),
    FluentGroup(dbKey: keyB, providerList: [bNotes]),
  ];

  Future<void> init() => FluentDb.init(groups, config: const FluentConfig(readConnections: 2));

  bool get open => FluentDb.isOpen(dbKey: keyA) && FluentDb.isOpen(dbKey: keyB);

  Future<FluentSyncResult<SNote>> sync() => sNotes.syncWithServer(onPush: server.push, onPull: server.pull);
}

/// The ops of one database whose outermost transaction is still open, per database.
class Frame {
  final Map<Db, List<Apply>> ops = {Db.a: [], Db.b: []};

  void add(Db d, Apply a) => ops[d]!.add(a);

  List<Apply> take(Db d) {
    final List<Apply> out = List.of(ops[d]!);
    ops[d]!.clear();
    return out;
  }

  void mergeInto(Frame parent) {
    for (final Db d in Db.values) {
      parent.ops[d]!.addAll(ops[d]!);
      ops[d]!.clear();
    }
  }
}

class Segment {
  final List<Apply> applies = [];

  /// Clears of this segment: after every write of it.
  final List<Apply> post = [];
}

class Op {
  Op(this.name, this.run, this.apply);

  final String name;
  final Future<Object?> Function() run;
  final Apply apply;
}

typedef Step = Future<void> Function(Frame frame);

// ---------------------------------------------------------------------------------------------------------------------
// One phase
// ---------------------------------------------------------------------------------------------------------------------

class Phase {
  Phase(this.w, this.f, this.faults, {required this.cross}) : start = w.ref.copy();

  final World w;
  final FluentFuzz f;
  final FaultyDatabaseFactory faults;

  /// Whether transactions may call into the other database (then no clears in this phase: see the file comment).
  /// Both directions at once (A→B beside B→A): the call that would close a wait cycle is refused with
  /// `FluentErrorCode.deadlock` (G12), caught like any failing nested transaction (rolled back, not applied).
  final bool cross;
  final Ref start;
  final List<Segment> segments = [];
  final List<Future<Object?>> calls = [];
  final List<String> names = [];
  final List<Object> nestedErrors = [];
  final Set<String> claimed = {};

  /// Lifecycle events, for the failure message.
  final List<String> events = [];

  Segment get seg => segments.last;

  void track(String name, Future<Object?> call) {
    call.ignore(); // settled (and its error checked) by waitAllSettled after the phase
    calls.add(call);
    names.add(name);
  }

  /// Issues [op] unawaited; it counts as committed in [s] when its future succeeds.
  void issue(Op op) {
    final Segment s = seg;
    track(op.name, Future<Object?>.sync(op.run).then((v) {
      s.applies.add(op.apply);
      return v;
    }));
  }

  bool _claim(String k) => claimed.add(k);

  /// An existing id of [rows] (start state) not yet claimed in this phase that satisfies [test].
  int? _existing<V>(String table, Map<int, V> rows, [bool Function(V v)? test]) {
    final List<int> ids = [for (final MapEntry<int, V> e in rows.entries) if (!claimed.contains('$table:${e.key}') && (test == null || test(e.value))) e.key];
    if (ids.isEmpty) return null;
    final int id = f.pick(ids);
    _claim('$table:$id');
    return id;
  }

  // --- writes --------------------------------------------------------------------------------------------------------

  Op writeOp(Db d) => d == Db.b ? _bWrite() : f.weighted<Op Function()>({_aWrite: 5, _folderWrite: 3, _sWrite: 2})();

  Op _aNew() {
    final int id = w.fresh();
    final String t = f.string();
    _claim('a:$id');
    return Op('A.notes.save new $id', () => w.aNotes.save(CNote(id: id, text: t)), (r) => r.a[id] = (text: t, n: 0, trashed: false));
  }

  Op _aWrite() {
    switch (f.weighted({'new': 3, 'all': 2, 'old': 2, 'inc': 2, 'text': 1, 'delete': 2, 'deleteWhere': 1, 'restore': 2, 'forever': 1})) {
      case 'all':
        final List<int> ids = [for (int i = f.intIn(2, 4); i > 0; i--) w.fresh()];
        final List<String> texts = [for (final int _ in ids) f.string()];
        for (final int id in ids) {
          _claim('a:$id');
        }
        return Op('A.notes.saveAll new $ids', () => w.aNotes.saveAll([for (int i = 0; i < ids.length; i++) CNote(id: ids[i], text: texts[i])]), (r) {
          for (int i = 0; i < ids.length; i++) {
            r.a[ids[i]] = (text: texts[i], n: 0, trashed: false);
          }
        });
      case 'old':
        final int? id = _existing('a', start.a);
        if (id == null) return _aNew();
        final String t = f.string();
        final int n = start.a[id]!.n;
        return Op('A.notes.save existing $id', () => w.aNotes.save(CNote(id: id, text: t, n: n)), (r) => r.a[id] = (text: t, n: n, trashed: false));
      case 'inc':
        final int? id = _existing('a', start.a);
        if (id == null) return _aNew();
        final int k = f.intIn(1, 9);
        return Op('A.notes.updateById $id n+=$k', () => w.aNotes.updateById(id, {'n': FluentUpdate.increment(k)}), (r) {
          final ANote? x = r.a[id];
          if (x != null && !x.trashed) r.a[id] = (text: x.text, n: x.n + k, trashed: false);
        });
      case 'text':
        final List<int> ids = [for (int i = f.intIn(1, 3); i > 0; i--) ?_existing('a', start.a)];
        if (ids.isEmpty) return _aNew();
        final String t = f.string();
        return Op('A.notes.updateWhere ids $ids', () => w.aNotes.updateWhere(FluentFilter.ids(ids), {'text': t}), (r) {
          for (final int id in ids) {
            final ANote? x = r.a[id];
            if (x != null && !x.trashed) r.a[id] = (text: t, n: x.n, trashed: false);
          }
        });
      case 'delete':
      case 'deleteWhere':
        final List<int> ids = [for (int i = f.intIn(1, 2); i > 0; i--) ?_existing('a', start.a)];
        if (ids.isEmpty) return _aNew();
        void apply(Ref r) {
          for (final int id in ids) {
            final ANote? x = r.a[id];
            if (x != null) r.a[id] = (text: x.text, n: x.n, trashed: true);
          }
        }

        return ids.length == 1
            ? Op('A.notes.deleteById ${ids.single}', () => w.aNotes.deleteById(ids.single), apply)
            : Op('A.notes.deleteWhere ids $ids', () => w.aNotes.deleteWhere(FluentFilter.ids(ids)), apply);
      case 'restore':
        final int? id = _existing('a', start.a, (v) => v.trashed);
        if (id == null) return _aNew();
        return Op('A.notes.trash.restoreById $id', () => w.aNotes.trash.restoreById(id), (r) {
          final ANote? x = r.a[id];
          if (x != null) r.a[id] = (text: x.text, n: x.n, trashed: false);
        });
      case 'forever':
        final int? id = _existing('a', start.a);
        if (id == null) return _aNew();
        return Op('A.notes.trash.deleteForeverById $id', () => w.aNotes.trash.deleteForeverById(id), (r) => r.a.remove(id));
      default:
        return _aNew();
    }
  }

  Op _bNew() {
    final int id = w.fresh();
    final String t = f.string();
    _claim('b:$id');
    return Op('B.notes.save new $id', () => w.bNotes.save(PNote(id: id, text: t)), (r) => r.b[id] = (text: t, n: 0));
  }

  Op _bWrite() {
    switch (f.weighted({'new': 3, 'all': 2, 'old': 2, 'inc': 2, 'delete': 2})) {
      case 'all':
        final List<int> ids = [for (int i = f.intIn(2, 4); i > 0; i--) w.fresh()];
        for (final int id in ids) {
          _claim('b:$id');
        }
        return Op('B.notes.saveAll new $ids', () => w.bNotes.saveAll([for (final int id in ids) PNote(id: id, text: 'b$id')]), (r) {
          for (final int id in ids) {
            r.b[id] = (text: 'b$id', n: 0);
          }
        });
      case 'old':
        final int? id = _existing('b', start.b);
        if (id == null) return _bNew();
        final String t = f.string();
        final int n = start.b[id]!.n;
        return Op('B.notes.save existing $id', () => w.bNotes.save(PNote(id: id, text: t, n: n)), (r) => r.b[id] = (text: t, n: n));
      case 'inc':
        final int? id = _existing('b', start.b);
        if (id == null) return _bNew();
        final int k = f.intIn(1, 9);
        return Op('B.notes.updateById $id n+=$k', () => w.bNotes.updateById(id, {'n': FluentUpdate.increment(k)}), (r) {
          final BNote? x = r.b[id];
          if (x != null) r.b[id] = (text: x.text, n: x.n + k);
        });
      case 'delete':
        final List<int> ids = [for (int i = f.intIn(1, 2); i > 0; i--) ?_existing('b', start.b)];
        if (ids.isEmpty) return _bNew();
        void apply(Ref r) => ids.forEach(r.b.remove);
        return ids.length == 1
            ? Op('B.notes.deleteById ${ids.single}', () => w.bNotes.deleteById(ids.single), apply)
            : Op('B.notes.deleteWhere ids $ids', () => w.bNotes.deleteWhere(FluentFilter.ids(ids)), apply);
      default:
        return _bNew();
    }
  }

  Op _folderNew() {
    final int id = w.fresh();
    _claim('folder:$id');
    final List<int> fileIds = [for (int i = f.intIn(0, 3); i > 0; i--) w.fresh()];
    return Op('folders.save new $id files $fileIds', () => w.folders.save(Folder(id: id, name: 'f$id', files: [for (final int x in fileIds) FileRow(id: x, name: 'n$x')]), relationSync: FluentRelationSyncMode.replace), (r) {
      r.folders[id] = 'f$id';
      for (final int x in fileIds) {
        r.files[x] = (name: 'n$x', folder: id, trashed: false);
      }
    });
  }

  Op _folderWrite() {
    switch (f.weighted({'new': 3, 'edit': 3, 'delete': 1, 'deleteFile': 2, 'restoreFile': 1})) {
      case 'edit':
        final int? id = _existing('folder', start.folders);
        if (id == null) return _folderNew();
        final List<int> live = [for (final MapEntry<int, FileRef> e in start.files.entries) if (e.value.folder == id && !e.value.trashed) e.key];
        final List<int> keep = f.subset(live);
        final List<int> added = [for (int i = f.intIn(0, 2); i > 0; i--) w.fresh()];
        final String name = 'g${f.intIn(0, 999)}';
        final List<int> all = [...keep, ...added];
        return Op('folders.save $id keep $keep add $added (replace)', () => w.folders.save(Folder(id: id, name: name, files: [for (final int x in all) FileRow(id: x, name: 'n$x')]), relationSync: FluentRelationSyncMode.replace), (r) {
          r.folders[id] = name;
          for (final MapEntry<int, FileRef> e in r.files.entries.toList()) {
            if (e.value.folder == id && !e.value.trashed && !all.contains(e.key)) r.files[e.key] = (name: e.value.name, folder: id, trashed: true);
          }
          for (final int x in all) {
            r.files[x] = (name: 'n$x', folder: id, trashed: false);
          }
        });
      case 'delete':
        final int? id = _existing('folder', start.folders);
        if (id == null) return _folderNew();
        return Op('folders.deleteById $id', () => w.folders.deleteById(id), (r) {
          if (r.folders.remove(id) != null) r.files.removeWhere((_, v) => v.folder == id);
        });
      case 'deleteFile':
      case 'restoreFile':
        final bool del = f.chance(0.6);
        final List<int> candidates = [
          for (final MapEntry<int, FileRef> e in start.files.entries)
            if (e.value.trashed != del && !claimed.contains('folder:${e.value.folder}')) e.key,
        ];
        if (candidates.isEmpty) return _folderNew();
        final int x = f.pick(candidates);
        _claim('folder:${start.files[x]!.folder}');
        return del
            ? Op('files.deleteById $x', () => w.files.deleteById(x), (r) {
                final FileRef? v = r.files[x];
                if (v != null) r.files[x] = (name: v.name, folder: v.folder, trashed: true);
              })
            : Op('files.trash.restoreById $x', () => w.files.trash.restoreById(x), (r) {
                final FileRef? v = r.files[x];
                if (v != null) r.files[x] = (name: v.name, folder: v.folder, trashed: false);
              });
      default:
        return _folderNew();
    }
  }

  Op _sWrite() {
    switch (f.weighted({'new': 3, 'old': 2, 'delete': 1})) {
      case 'old':
      case 'delete':
        final int? id = _existing('s', start.s);
        if (id == null) break;
        if (f.chance(0.5)) return Op('snotes.deleteById $id', () => w.sNotes.deleteById(id), (r) => r.s.remove(id));
        final String t = f.string();
        return Op('snotes.save existing $id', () => w.sNotes.save(SNote(id: id, text: t)), (r) => r.s[id] = t);
    }
    final int id = w.fresh();
    _claim('s:$id');
    final String t = f.string();
    return Op('snotes.save new $id', () => w.sNotes.save(SNote(id: id, text: t)), (r) => r.s[id] = t);
  }

  // --- reads ---------------------------------------------------------------------------------------------------------

  (String, Future<Object?> Function()) readOp() {
    final int any = f.intIn(1, w._next);
    final int depth = f.intIn(0, 3);
    final ExecutionPolicy policy = ExecutionPolicy(priority: f.intIn(-2, 2), cancelIfDuplicate: f.chance(0.7));
    return f.pick<(String, Future<Object?> Function())>([
      ('A.notes.find', () => w.aNotes.find(orderBy: 'id', limit: f.intIn(1, 20), policy: policy)),
      ('A.notes.findById $any', () => w.aNotes.findById(any, policy: policy)),
      ('A.notes.count', () => w.aNotes.count(policy: policy)),
      ('A.notes.exists $any', () => w.aNotes.exists(any)),
      ('A.notes.findPage', () => w.aNotes.findPage(orderBy: 'text', limit: 3)),
      ('A.notes.sum n', () => w.aNotes.sum('n')),
      ('A.notes.pluck text', () => w.aNotes.pluck<String>('text', limit: 5)),
      ('A.notes.withTrash.count', () => w.aNotes.withTrash.count()),
      ('A.notes.trash.find', () => w.aNotes.trash.find()),
      ('A.notes.findMaps', () => w.aNotes.findMaps(limit: 4)),
      ('folders.find depth $depth', () => w.folders.find(maxDepth: depth, relations: depth == 0 ? FluentLoad.none : FluentLoad.eager)),
      ('folders.findById $any', () => w.folders.findById(any, maxDepth: depth)),
      ('files.find', () => w.files.find(limit: 10)),
      ('snotes.find', () => w.sNotes.find()),
      ('snotes.pendingChanges', () => w.sNotes.pendingChanges()),
      ('B.notes.find', () => w.bNotes.find(orderBy: 'id', policy: policy)),
      ('B.notes.findByIds', () => w.bNotes.findByIds([any, any + 1, any + 2])),
      ('B.notes.count', () => w.bNotes.count()),
    ]);
  }

  // --- transactions --------------------------------------------------------------------------------------------------

  /// The body of a transaction of [d] (generated now, run later).
  Step body(Db d, int depth, Db top) {
    final List<Step> steps = [
      for (int i = f.intIn(1, 3); i > 0; i--) _writeStep(d, writeOp(d)),
    ];
    if (depth < 2 && f.chance(0.35)) steps.insert(f.intIn(0, steps.length), txnStep(d, depth + 1, top)); // savepoint
    if (cross && depth < 2 && f.chance(0.4)) {
      steps.insert(f.intIn(0, steps.length), txnStep(d == Db.a ? Db.b : Db.a, depth + 1, top)); // other database (may come back: A-in-B-in-A)
    }
    if (cross && f.chance(0.25)) steps.insert(f.intIn(0, steps.length), _crossRead(d == Db.a ? Db.b : Db.a));
    final bool rollback = f.chance(0.15);
    return (Frame frame) async {
      for (final Step s in steps) {
        await s(frame);
      }
      if (rollback) throw _Rollback();
    };
  }

  /// A read of the other database [d] inside a transaction body: it may wait behind a queued write there while that
  /// database's transaction waits for this one; then one of the two calls is refused (`deadlock`, G12). A refused read
  /// is caught (the body goes on), so it must be typed.
  Step _crossRead(Db d) => (Frame frame) async {
    try {
      await (d == Db.a ? w.aNotes.count() : w.bNotes.count());
    } on FluentException catch (e) {
      nestedErrors.add(e);
    }
  };

  Step _writeStep(Db d, Op op) => (Frame frame) async {
    await op.run();
    frame.add(d, op.apply);
  };

  /// A nested transaction of [d] inside a running body: a savepoint when [d] has an open transaction here, else a
  /// transaction of its own. Its failure is caught (the outer body goes on), so it must be typed.
  Step txnStep(Db d, int depth, Db top) {
    final Step inner = body(d, depth, top);
    return (Frame parent) async {
      final Segment s = seg;
      final bool nested = FluentTransactionScope.of(w.key(d).dbName) != null;
      final Frame mine = Frame();
      try {
        await FluentDb.transaction(() => inner(mine), dbKey: w.key(d));
        if (!nested) s.applies.addAll(mine.take(d));
      } on Object catch (e) {
        if (e is! _Rollback) nestedErrors.add(e);
        if (e is! FluentException && e is! _Rollback) rethrow;
        mine.take(d); // rolled back
      }
      mine.mergeInto(parent); // ops of other databases belong to their still open transactions
    };
  }

  void issueTxn(Db d) {
    final Step b = body(d, 0, d);
    final Segment s = seg;
    final Frame top = Frame();
    track(
      'transaction ${d.name}',
      FluentDb.transaction(() async {
        await b(top);
        return 'ok';
      }, dbKey: w.key(d)).then<Object?>(
        (v) {
          s.applies.addAll(top.take(d));
          return v;
        },
        onError: (Object e) {
          if (e is _Rollback) return null;
          throw e;
        },
      ),
    );
  }

  // --- bursts --------------------------------------------------------------------------------------------------------

  void burst(int n) {
    bool paused = false;
    for (int i = 0; i < n; i++) {
      switch (f.weighted({'write': 6, 'read': 4, 'txn': 3, 'sync': 1, 'pause': paused ? 0 : 1})) {
        case 'write':
          issue(writeOp(f.chance(0.7) ? Db.a : Db.b));
        case 'read':
          final (String name, Future<Object?> Function() run) = readOp();
          track(name, Future<Object?>.sync(run));
        case 'txn':
          issueTxn(f.chance(0.6) ? Db.a : Db.b);
        case 'sync':
          track('snotes.syncWithServer', w.sync());
        case 'pause':
          paused = true;
          final FluentDbKey? k = f.pick([null, w.keyA, w.keyB]);
          final int ms = f.intIn(0, 5);
          final Future<void> pause = FluentDb.pauseQueue(dbKey: k);
          track('pauseQueue ${k?.dbName ?? 'all'}', pause);
          track('resumeQueue ${k?.dbName ?? 'all'}', pause.whenComplete(() => Future<void>.delayed(Duration(milliseconds: ms), () => FluentDb.resumeQueue(dbKey: k))));
      }
    }
    if (cross) return;
    // Clears: the last call on their table in this segment (writes of later segments come after them).
    if (f.chance(0.12)) {
      final Segment s = seg;
      track('A.notes.clearTable', w.aNotes.clearTable().then((v) {
        s.post.add((r) => r.a.clear());
        return v;
      }));
    }
    if (f.chance(0.1)) {
      final Segment s = seg;
      track('FluentDb.clear B', FluentDb.clear(dbKey: w.keyB).then((_) {
        s.post.add((r) => r.clearB());
        return null;
      }));
    }
  }

  /// A lifecycle event while the calls of the segment run.
  Future<void> lifecycle(int faultSeed, double p, FaultKind kind) async {
    final String what = f.weighted({'none': 3, 'close+init': 2, 'restart': 2, 'deleteDatabases': cross ? 0 : 1, 'die': 2});
    events.add('$what after call ${calls.length}');
    switch (what) {
      case 'close+init':
        await waitAllSettled([FluentDb.close()], names: ['close'], timeout: const Duration(seconds: 20));
        await waitAllSettled([w.init()], names: ['init after close'], timeout: const Duration(seconds: 20));
      case 'restart':
        await waitAllSettled([FluentDb.restart()], names: ['restart'], timeout: const Duration(seconds: 20));
      case 'deleteDatabases':
        final Db? which = f.pick([null, Db.a, Db.b]);
        final Segment s = seg;
        faults.heal(); // the deletion itself must succeed: its outcome decides the reference
        if (!w.open) await w.init(); // a failed init earlier: deleteDatabases needs open databases
        await FluentDb.deleteDatabases(dbKey: which == null ? null : w.key(which)).timeout(const Duration(seconds: 20));
        s.post.add((r) {
          if (which != Db.b) r.clearA();
          if (which != Db.a) r.clearB();
        });
        if (which != Db.b) w.server.local.clear(); // a new user: the server forgets the device's rows
        faults.failRandomly(faultSeed, p, kind: kind);
      case 'die':
        // "The app died": every statement fails from now on, except ROLLBACK / close — SQLite rolls an open
        // transaction back when a killed process's file is opened again. (`faults.die()` also fails ROLLBACK, which
        // leaves sqflite_common_ffi's connection waiting forever for that transaction to end: an artefact of
        // dying in-process, not something a restarted app meets.)
        faults.failWhere((_) => true);
        try {
          await waitAllSettled(calls, names: names, timeout: const Duration(seconds: 20));
        } on TestFailure catch (e) {
          fail('${e.message} (while every statement fails after "die")\nEngine: ${FluentEngine().debugState()}');
        }
        faults.heal();
        await waitAllSettled([FluentDb.restart()], names: ['restart after die'], timeout: const Duration(seconds: 20));
        faults.failRandomly(faultSeed, p, kind: kind);
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------------------------------------------------

Future<void> settle() async {
  expect(await FluentEngine().whenIdle(const Duration(seconds: 20)), isTrue, reason: 'G12: the engine never became idle');
  await Future<void>.delayed(const Duration(milliseconds: 30));
  expect(await FluentEngine().whenIdle(const Duration(seconds: 20)), isTrue, reason: 'G12: the engine never became idle');
}

/// The stored state, read with raw SQL (ground truth), compared with [r]: everything equal, except server-origin
/// rows of the syncable table, which must be rows of the server.
Future<void> expectState(World w, Ref r, String when) async {
  final Database a = w.aNotes.db;
  final Database b = w.bNotes.db;
  await expectIntegrity(a, reason: 'A $when');
  await expectIntegrity(b, reason: 'B $when');
  String k(Map<String, Object?> row) => '${row['id']}';

  expectSameRows(
    await a.rawQuery('SELECT "id", "text", "n", "deleted_at" IS NOT NULL AS "trashed" FROM "notes"'),
    [for (final MapEntry<int, ANote> e in r.a.entries) {'id': e.key, 'text': e.value.text, 'n': e.value.n, 'trashed': e.value.trashed ? 1 : 0}],
    key: k,
    reason: 'G18/G1: A.notes $when',
  );
  expectSameRows(
    await b.rawQuery('SELECT "id", "text", "n" FROM "notes"'),
    [for (final MapEntry<int, BNote> e in r.b.entries) {'id': e.key, 'text': e.value.text, 'n': e.value.n}],
    key: k,
    reason: 'G18/G1/G30: B.notes $when',
  );
  expectSameRows(
    await a.rawQuery('SELECT "id", "name" FROM "folders"'),
    [for (final MapEntry<int, String> e in r.folders.entries) {'id': e.key, 'name': e.value}],
    key: k,
    reason: 'G18/G1: folders $when',
  );
  final String fk = [
    for (final Map<String, Object?> c in await a.rawQuery('PRAGMA table_info("files")')) c['name']! as String,
  ].firstWhere((c) => c.contains('folder'));
  expectSameRows(
    await a.rawQuery('SELECT "id", "name", "$fk" AS "folder", "deleted_at" IS NOT NULL AS "trashed" FROM "files"'),
    [for (final MapEntry<int, FileRef> e in r.files.entries) {'id': e.key, 'name': e.value.name, 'folder': e.value.folder, 'trashed': e.value.trashed ? 1 : 0}],
    key: k,
    reason: 'G18/G1: files $when',
  );
  final List<Map<String, Object?>> s = await a.rawQuery('SELECT "id", "text" FROM "snotes"');
  expectSameRows(
    [for (final Map<String, Object?> row in s) if ((row['id']! as int) < serverIds) row],
    [for (final MapEntry<int, String> e in r.s.entries) {'id': e.key, 'text': e.value}],
    key: k,
    reason: 'G18/G1: snotes (device rows) $when',
  );
  for (final Map<String, Object?> row in s) {
    final int id = row['id']! as int;
    if (id >= serverIds) expect(row['text'], w.server.own[id], reason: 'G24: pulled row $id is the server row ($when)');
  }
}

/// A clean round (no faults): every call kind issued unawaited on both databases; each result must equal the serial
/// expectation in call order (G7), and the round must work at all (G18: no stuck queue, pause, scope or lock).
Future<void> cleanRound(World w, String when) async {
  final Ref r = w.ref;
  final int liveA = r.a.values.where((v) => !v.trashed).length;
  final int countB = r.b.length;
  final int x = w.fresh(), y = w.fresh(), z = w.fresh(), bx = w.fresh(), bRolled = w.fresh(), fo = w.fresh();
  final int f1 = w.fresh(), f2 = w.fresh(), f3 = w.fresh(), sx = w.fresh();
  w.server.failEvery = 0;
  final List<(String, Future<Object?>, Object?)> calls = [];
  void call(String name, Future<Object?> fut, Object? expected) => calls.add((name, fut, expected));
  Future<Object?> ok(Future<Object?> f) => f.then((_) => null);

  call('A save v1', ok(w.aNotes.save(CNote(id: x, text: 'v1'))), null);
  call('B save', ok(w.bNotes.save(PNote(id: bx, text: 'b1'))), null);
  call('A save v2', ok(w.aNotes.save(CNote(id: x, text: 'v2'))), null);
  call('A findById sees v2', w.aNotes.findById(x).then((n) => n?.text), 'v2');
  call('A increment', w.aNotes.updateById(x, {'n': FluentUpdate.increment(5)}), 1);
  call('B increment', w.bNotes.updateById(bx, {'n': FluentUpdate.increment(2)}), 1);
  call('A n is 5', w.aNotes.findById(x).then((n) => n?.n), 5);
  call('B n is 2', w.bNotes.findById(bx).then((n) => n?.n), 2);
  call('A delete', w.aNotes.deleteById(x), 1);
  call('A exists after delete', w.aNotes.exists(x), false);
  call('A in trash', w.aNotes.trash.count(where: FluentFilter.ids([x])), 1);
  call('A restore', w.aNotes.trash.restoreById(x), 1);
  call('A live count', w.aNotes.count(), liveA + 1);
  call('B count', w.bNotes.count(), countB + 1);
  call('A delete forever', w.aNotes.trash.deleteForeverById(x), 1);
  call('A gone', w.aNotes.withTrash.findById(x).then((n) => n == null), true);
  call('B delete', w.bNotes.deleteById(bx), 1);
  call('B gone', w.bNotes.findById(bx).then((n) => n == null), true);
  call('folder save', ok(w.folders.save(Folder(id: fo, name: 'f', files: [FileRow(id: f1, name: 'a'), FileRow(id: f2, name: 'b')]), relationSync: FluentRelationSyncMode.replace)), null);
  call('folder files', w.folders.findById(fo).then((v) => [for (final FileRow r in v?.files ?? const []) r.id]), [f1, f2]);
  call('folder save replace', ok(w.folders.save(Folder(id: fo, name: 'g', files: [FileRow(id: f2, name: 'b2'), FileRow(id: f3, name: 'c')]), relationSync: FluentRelationSyncMode.replace)), null);
  call('folder files replaced', w.folders.findById(fo).then((v) => '${v?.name} ${[for (final FileRow r in v?.files ?? const []) '${r.id}:${r.name}']}'), 'g ${['$f2:b2', '$f3:c']}');
  call('removed file in trash', w.files.trash.count(where: FluentFilter.ids([f1])), 1);
  call('folder delete', w.folders.deleteById(fo), 1);
  call('files gone with folder', w.files.withTrash.count(where: FluentFilter.ids([f1, f2, f3])), 0);
  call('A transaction', FluentDb.transaction(() async {
    await w.aNotes.save(CNote(id: y, text: 'ty'));
    await w.aNotes.save(CNote(id: z, text: 'tz'));
    return 'ok';
  }, dbKey: w.keyA), 'ok');
  call('B rolled back', FluentDb.transaction(() async {
    await w.bNotes.save(PNote(id: bRolled, text: 'never'));
    throw _Rollback();
  }, dbKey: w.keyB).then<Object?>((_) => 'committed?', onError: (Object e) => e is _Rollback ? 'rolled back' : throw e), 'rolled back');
  call('A transaction rows', w.aNotes.findByIds([y, z]).then((l) => [for (final CNote n in l) n.text]..sort()), ['ty', 'tz']);
  call('B rollback left nothing', w.bNotes.exists(bRolled), false);
  call('snotes save', ok(w.sNotes.save(SNote(id: sx, text: 'sx'))), null);
  // A sync is several tasks, not one write: a read called during it may run before its bookkeeping, so the pending
  // count is read once it completed.
  call('sync, then nothing pending', w.sync().then((res) async => res.isSuccess ? 'pending ${await w.sNotes.pendingChanges()}' : '$res'), 'pending 0');

  final List<Settled> got = await waitAllSettled([for (final c in calls) c.$2], names: [for (final c in calls) c.$1], timeout: const Duration(seconds: 20));
  final List<String> wrong = [
    for (int i = 0; i < calls.length; i++)
      if (got[i].failed)
        '${calls[i].$1}: failed with ${got[i].error}'
      else if ('${got[i].value}' != '${calls[i].$3}')
        '${calls[i].$1}: expected ${calls[i].$3}, got ${got[i].value}',
  ];
  if (wrong.isNotEmpty) {
    final List<Map<String, Object?>> s = await w.sNotes.db.rawQuery('SELECT * FROM "snotes"');
    final List<Map<String, Object?>> t = await w.sNotes.db.rawQuery('SELECT * FROM "__fluent_tombstones"');
    fail('G7/G18: the clean round after recovery ($when) disagrees with the serial run:\n  ${wrong.join('\n  ')}\n  snotes: $s\n  tombstones: $t');
  }
  r.a[y] = (text: 'ty', n: 0, trashed: false);
  r.a[z] = (text: 'tz', n: 0, trashed: false);
  r.s[sx] = 'sx';
}

// ---------------------------------------------------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------------------------------------------------

Future<void> runChaos(int seed, FaultyDatabaseFactory faults, List<FluentIssue> issues, {int phases = 3, bool onlyA = false}) async {
  final FluentFuzz f = FluentFuzz(seed);
  final World w = World(seed);
  for (int i = 0; i < 4; i++) {
    w.server.own[serverIds + seed * 10 + i] = 'server $i';
  }
  await w.init();
  final List<String> log = [];
  for (int p = 0; p < phases; p++) {
    final Phase ph = Phase(w, f, faults, cross: !onlyA && f.chance(0.5));
    w.server.failEvery = f.pick([0, 0, 2, 3]);
    if (f.chance(0.5)) w.server.own[serverIds + seed * 10 + 4 + p] = 'server new $p';

    // Watches that live through the phase (G11 after recovery).
    final Map<String, List<Object?>> seen = {'A': [], 'B': [], 'F': []};
    final List<Object> watchErrors = [];
    final List<StreamSubscription<Object?>> subs = [
      w.aNotes.watch(orderBy: 'id').listen((v) => seen['A']!.add([for (final CNote n in v) '${n.id}:${n.text}:${n.n}']), onError: watchErrors.add),
      if (!onlyA) w.bNotes.watch(orderBy: 'id').listen((v) => seen['B']!.add([for (final PNote n in v) '${n.id}:${n.text}:${n.n}']), onError: watchErrors.add),
      w.folders.watch(orderBy: 'id').listen((v) => seen['F']!.add([for (final Folder d in v) '${d.id}:${d.name}:${[for (final FileRow r in d.files ?? const []) r.id]}']), onError: watchErrors.add),
    ];

    final int faultSeed = f.intIn(0, 1 << 30);
    final double p0 = f.pick([0.0, 0.02, 0.05, 0.1]);
    final FaultKind kind = f.pick(FaultKind.values);
    faults.failRandomly(faultSeed, p0, kind: kind);

    final int segs = f.intIn(1, 3);
    for (int s = 0; s < segs; s++) {
      ph.segments.add(Segment());
      if (onlyA) {
        for (int i = f.intIn(4, 12); i > 0; i--) {
          f.chance(0.25) ? ph.issueTxn(Db.a) : ph.issue(ph.writeOp(Db.a));
        }
      } else {
        ph.burst(f.intIn(4, 14));
      }
      if (s < segs - 1 || f.chance(0.5)) await ph.lifecycle(faultSeed + s + 1, p0, kind);
    }
    log.add('phase $p: ${ph.names.length} calls, faults p=$p0 ${kind.name}, cross=${ph.cross}, events ${ph.events}');

    // Recovery.
    try {
      await waitAllSettled(ph.calls, names: ph.names, timeout: const Duration(seconds: 20));
    } on TestFailure catch (e) {
      fail('seed $seed ${log.join('; ')}:\n${e.message}\nCalls: ${[for (int i = 0; i < ph.names.length; i++) '$i ${ph.names[i]}'].join(', ')}');
    }
    for (final Object e in ph.nestedErrors) {
      expectTypedError(e, reason: 'nested transaction');
    }
    faults.heal();
    await settle();
    if (!w.open) {
      await FluentDb.close(); // after a failed init / restart the library is closed; open it the way an app would
      await w.init();
    }
    for (final Segment s in ph.segments) {
      for (final Apply a in s.applies) {
        a(w.ref);
      }
      for (final Apply a in s.post) {
        a(w.ref);
      }
    }
    final String when = 'seed $seed phase $p (${log.join('; ')})';
    await expectState(w, w.ref, 'after $when');
    await cleanRound(w, when);
    await settle();
    await expectState(w, w.ref, 'after the clean round of $when');

    // The device and the server agree after the clean sync (G10 as recovery).
    expect(w.server.problems, isEmpty);
    expect(w.server.local, w.ref.s, reason: 'G10/G18: the server holds every device row after a clean sync ($when)');

    // Watches converge (G11) and only ever failed typed (G13).
    for (final Object e in watchErrors) {
      expectTypedError(e, reason: 'watch');
    }
    expect(seen['A']!.lastOrNull, [for (final CNote n in await w.aNotes.find(orderBy: 'id')) '${n.id}:${n.text}:${n.n}'], reason: 'G11: A.notes watch converged ($when)');
    if (!onlyA) expect(seen['B']!.lastOrNull, [for (final PNote n in await w.bNotes.find(orderBy: 'id')) '${n.id}:${n.text}:${n.n}'], reason: 'G11: B.notes watch converged ($when)');
    expect(
      seen['F']!.lastOrNull,
      [for (final Folder d in await w.folders.find(orderBy: 'id')) '${d.id}:${d.name}:${[for (final FileRow r in d.files ?? const []) r.id]}'],
      reason: 'G11: folders watch converged ($when)',
    );
    for (final StreamSubscription<Object?> s in subs) {
      await s.cancel();
    }
  }
  expectIssuesHaveFixes(issues);
  await FluentDb.deleteDatabases(reopen: false);
}

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  final List<FluentIssue> issues = [];
  StreamSubscription<FluentIssue>? listener;

  setUp(() async {
    await FluentTestDb.closeCurrent();
    await FluentDb.close();
    FluentDbInternals.reset();
    FluentLog.forgetIssues();
    issues.clear();
    listener = FluentDb.onIssue().listen(issues.add);
    faults = await FaultyDatabaseFactory.install();
  });

  tearDown(() async {
    faults.heal();
    await listener?.cancel();
    await FluentDb.close().timeout(const Duration(seconds: 10));
    FluentDbInternals.reset();
    faults.uninstall();
  });

  group('G12 / G18 / G19 / G30 chaos', () {
    for (final int seed in fuzzSeeds(base: 80000)) {
      test('G18: seed $seed — random calls, faults and lifecycle events on two databases end in the committed state, and the library recovers', () async {
        await runChaos(seed, faults, issues);
      });
    }
  });

  test('G12: two transactions that each call into the other database (A→B and B→A at once) both complete', () async {
    final World w = World(80999);
    await w.init();
    Future<List<Object?>> round(int base, {required bool together}) {
      final Completer<void> aIn = Completer<void>(), bIn = Completer<void>();
      final Future<Object?> ab = FluentDb.transaction(() async {
        await w.aNotes.save(CNote(id: base + 1, text: 'a'));
        aIn.complete();
        if (together) await bIn.future; // both hold their database now
        await FluentDb.transaction(() => w.bNotes.save(PNote(id: base + 2, text: 'from a')), dbKey: w.keyB);
        return 'ab';
      }, dbKey: w.keyA);
      final Future<Object?> ba = (together ? Future<void>.value() : ab.then<void>((_) {})).then(
        (_) => FluentDb.transaction(() async {
          await w.bNotes.save(PNote(id: base + 3, text: 'b'));
          bIn.complete();
          if (together) await aIn.future;
          await FluentDb.transaction(() => w.aNotes.save(CNote(id: base + 4, text: 'from b')), dbKey: w.keyA);
          return 'ba';
        }, dbKey: w.keyB),
      );
      return Future.wait([ab, ba].map((f) => f.then<Object?>((v) => v, onError: (Object e) => e)));
    }

    Future<Set<int>> ids(FluentProvider<FluentStorable> p) async => {for (final Map<String, Object?> r in await p.db.rawQuery('SELECT id FROM "notes"')) r['id']! as int};

    final List<Object?> r = await round(0, together: true).timeout(const Duration(seconds: 15), onTimeout: () => fail('G12: A→B and B→A at once hang'));
    // The call that would close the wait cycle is refused (typed); the other transaction commits.
    final List<Object?> refused = r.whereType<FluentException>().toList();
    expect(refused, hasLength(1), reason: 'G12: exactly one side is refused to break the cycle ($r)');
    final FluentException e = refused.single! as FluentException;
    expectTypedError(e);
    expect(e.code, FluentErrorCode.deadlock);
    final bool abWon = r[0] == 'ab';
    expect(r, abWon ? ['ab', e] : [e, 'ba']);
    // The refused transaction rolled back as a whole: only the winner's rows exist, in both databases.
    expect(await ids(w.aNotes), abWon ? {1} : {4});
    expect(await ids(w.bNotes), abWon ? {2} : {3});
    await settle();
    await expectIntegrity(w.aNotes.db);
    await expectIntegrity(w.bNotes.db);

    // A follow-up round, one after the other, works in both orders (no stale wait left behind).
    expect(await round(10, together: false).timeout(const Duration(seconds: 15)), ['ab', 'ba']);
    expect(await ids(w.aNotes), {abWon ? 1 : 4, 11, 14});
    expect(await ids(w.bNotes), {abWon ? 2 : 3, 12, 13});
    await expectIntegrity(w.aNotes.db);
    await expectIntegrity(w.bNotes.db);
    expectIssuesHaveFixes(issues);
    await FluentDb.deleteDatabases(reopen: false);
  });

  group('G30 isolation under chaos', () {
    // A fifth of the main chaos run (at least one seed, no upper cap); seeds from 180000 so they never share numbers
    // with the main group (80000 + FLUENT_FUZZ).
    for (final int seed in fuzzSeeds(base: 180000, share: 5)) {
      test('G30: seed $seed — chaos on database A only never changes database B (same table name)', () async {
        final World probe = World(seed);
        await probe.init();
        await probe.bNotes.saveAll([for (int i = 1; i <= 5; i++) PNote(id: i, text: 'b$i', n: i)]);
        final List<Map<String, Object?>> before = await probe.bNotes.db.rawQuery('SELECT * FROM "notes"');
        await FluentDb.close();
        FluentDbInternals.reset();
        await runChaosOnA(seed, faults, issues, before);
      });
    }
  });
}

/// Chaos on A only (calls, transactions, faults, deleteDatabases / clear of A), with B open beside it.
Future<void> runChaosOnA(int seed, FaultyDatabaseFactory faults, List<FluentIssue> issues, List<Map<String, Object?>> bBefore) async {
  final FluentFuzz f = FluentFuzz(seed);
  final World w = World(seed);
  await w.init();
  for (int p = 0; p < 2; p++) {
    final Phase ph = Phase(w, f, faults, cross: false);
    faults.failRandomly(f.intIn(0, 1 << 30), f.pick([0.02, 0.05, 0.1]), kind: f.pick(FaultKind.values));
    ph.segments.add(Segment());
    for (int i = f.intIn(6, 16); i > 0; i--) {
      f.chance(0.25) ? ph.issueTxn(Db.a) : ph.issue(ph.writeOp(Db.a));
    }
    if (f.chance(0.3)) ph.track('FluentDb.clear A', FluentDb.clear(dbKey: w.keyA));
    await waitAllSettled(ph.calls, names: ph.names, timeout: const Duration(seconds: 20));
    faults.heal();
    if (f.chance(0.5)) await FluentDb.deleteDatabases(dbKey: w.keyA);
    await settle();
    expectSameRows(await w.bNotes.db.rawQuery('SELECT * FROM "notes"'), bBefore, key: (r) => '${r['id']}', reason: 'G30: B.notes after chaos on A (seed $seed phase $p)');
    await expectIntegrity(w.aNotes.db);
    await expectIntegrity(w.bNotes.db);
  }
  expectIssuesHaveFixes(issues);
  await FluentDb.deleteDatabases(reopen: false);
}
