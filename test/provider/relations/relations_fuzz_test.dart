// Model-based random tests of relations (TEST_PLAN.md, T1): random graph operations run against the database and
// against a plain Dart reference model of every table; after each step the stored rows, the visible reads and the
// relation calls must equal the reference.
//
// Replay one sequence: FLUENT_SEED=<seed> bash tool/mirror_test.sh t1 test/provider/relations/relations_fuzz_test.dart
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/faults.dart';
import '../../helpers/fuzz.dart';
import '../../helpers/guarantees.dart';
import '_graph_models.dart';

// ---------------------------------------------------------------------------------------------------------------
// Reference model: the committed state of every table. `gen` is the soft-delete generation (null: live); rows
// trashed by one call share a generation, like they share a stamp in the database.
// ---------------------------------------------------------------------------------------------------------------

class ROwner {
  ROwner(this.name, this.boss, [this.gen]);
  String name;
  int? boss;
  int? gen;
  ROwner copy() => ROwner(name, boss, gen);
}

class RKid {
  RKid(this.owner, this.text, this.n, [this.gen]);
  final int owner;
  String text;
  int n;
  int? gen;
  RKid copy() => RKid(owner, text, n, gen);
}

class RTag {
  RTag(this.title, [this.gen]);
  String title;
  int? gen;
  RTag copy() => RTag(title, gen);
}

class RNote {
  RNote(this.text, this.type, this.target);
  String text;
  String? type;
  int? target;
  RNote copy() => RNote(text, type, target);
}

class RMem {
  RMem(this.role, this.owner, this.group, [this.gen]);
  String role;
  final int owner;
  int? group;
  int? gen;
  RMem copy() => RMem(role, owner, group, gen);
}

class Ref {
  Map<int, ROwner> owners = {};
  Map<int, String> persons = {};
  Map<int, (int, String)> profiles = {}; // id -> (owner, bio)
  Map<int, RKid> kids = {};
  Map<String, RTag> tags = {}; // "ns|label"
  Set<String> links = {}; // "owner|ns|label"
  Map<int, RNote> notes = {};
  Map<int, String> groups = {};
  Map<int, RMem> mems = {};
  int gen = 0;

  int nextGen() => ++gen;

  Ref copy() => Ref()
    ..owners = {for (final e in owners.entries) e.key: e.value.copy()}
    ..persons = Map.of(persons)
    ..profiles = Map.of(profiles)
    ..kids = {for (final e in kids.entries) e.key: e.value.copy()}
    ..tags = {for (final e in tags.entries) e.key: e.value.copy()}
    ..links = Set.of(links)
    ..notes = {for (final e in notes.entries) e.key: e.value.copy()}
    ..groups = Map.of(groups)
    ..mems = {for (final e in mems.entries) e.key: e.value.copy()}
    ..gen = gen;

  List<int> get liveOwners => [for (final e in owners.entries) if (e.value.gen == null) e.key]..sort();
  List<int> get trashedOwners => [for (final e in owners.entries) if (e.value.gen != null) e.key]..sort();
  List<String> get liveTags => [for (final e in tags.entries) if (e.value.gen == null) e.key]..sort();
  List<int> liveKidsOf(int owner) => [for (final e in kids.entries) if (e.value.owner == owner && e.value.gen == null) e.key]..sort();
  List<int> allKidsOf(int owner) => [for (final e in kids.entries) if (e.value.owner == owner) e.key]..sort();
  List<String> liveTagsOf(int owner) => [for (final String l in links) if (l.startsWith('$owner|') && tags[l.substring('$owner|'.length)]!.gen == null) l.substring('$owner|'.length)]..sort();
  List<int> notesOf(int owner) => [for (final e in notes.entries) if (e.value.type == 'owners' && e.value.target == owner) e.key]..sort();
  List<int> liveMemsOf(int owner) => [for (final e in mems.entries) if (e.value.owner == owner && e.value.gen == null) e.key]..sort();
  List<int> groupsOf(int owner) => {for (final int m in liveMemsOf(owner)) ?mems[m]!.group}.toList()..sort();
  int? profileOf(int owner) => [for (final e in profiles.entries) if (e.value.$1 == owner) e.key].firstOrNull;

  /// Soft-deletes the owner with its live owned soft-deletable rows (kids, memberships) in one generation.
  void trashOwner(int id) {
    final int g = nextGen();
    owners[id]!.gen = g;
    for (final RKid k in kids.values) {
      if (k.owner == id && k.gen == null) k.gen = g;
    }
    for (final RMem m in mems.values) {
      if (m.owner == id && m.gen == null) m.gen = g;
    }
  }

  void restoreOwner(int id) {
    final int g = owners[id]!.gen!;
    owners[id]!.gen = null;
    for (final RKid k in kids.values) {
      if (k.owner == id && k.gen == g) k.gen = null;
    }
    for (final RMem m in mems.values) {
      if (m.owner == id && m.gen == g) m.gen = null;
    }
  }

  /// G21: what a permanent delete of an owner removes — the owner, its owned rows (kids, profile, notes through the
  /// polymorphic `via`, memberships) and its links; nothing else.
  void hardDeleteOwner(int id) {
    owners.remove(id);
    kids.removeWhere((_, k) => k.owner == id);
    profiles.removeWhere((_, p) => p.$1 == id);
    notes.removeWhere((_, n) => n.type == 'owners' && n.target == id);
    mems.removeWhere((_, m) => m.owner == id);
    links.removeWhere((l) => l.startsWith('$id|'));
  }
}

String tagKey(Tag t) => '${t.ns}|${t.label}';

// ---------------------------------------------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------------------------------------------

class _Rollback implements Exception {}

/// One random operation: [run] acts on the database, [apply] changes the reference the same way (called only when
/// [run] committed).
class GraphOp {
  GraphOp(this.name, this.run, this.apply);
  final String name;
  final Future<void> Function() run;
  final void Function(Ref ref) apply;
}

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;

  setUp(() async => faults = await FaultyDatabaseFactory.install());

  tearDown(() async {
    faults.heal();
    await FluentTestDb.closeCurrent();
    faults.uninstall();
  });

  for (final int seed in fuzzSeeds(base: 10000)) {
    test('G1 G3 G8 G9 G11 G21 G29: random relation graph operations match the reference model (seed $seed)', () async {
      await _runGraphSequence(seed, faults, steps: 30);
    });
  }
}

Future<void> _runGraphSequence(int seed, FaultyDatabaseFactory faults, {required int steps}) async {
  // Lists of relations a read did not load: null, a growable [] or the shared const [] (by seed).
  final Graph g = Graph(owners: switch (seed % 3) {
    0 => null,
    1 => DenseOwnerProvider(),
    _ => DenseOwnerProvider(constDefaults: true),
  });
  final FluentTestDb db = FluentTestDb();
  await db.open(g.all);
  await db.settle(); // the start-up maintenance (trash purge, expiry) is done before faults are injected
  final Database raw = g.owners.db;
  Ref ref = Ref();
  int counter = 0;

  // G11: watches of the owner and kid tables, compared with a fresh query now and then.
  List<Owner>? watchedOwners;
  List<Kid>? watchedKids;
  final subs = [
    g.owners.watch(orderBy: 'id').listen((v) => watchedOwners = v),
    g.kids.watch(orderBy: 'id').listen((v) => watchedKids = v),
  ];

  Owner ownerOf(int id) => Owner(id: id, name: ref.owners[id]!.name);
  Person personOf(int id) => Person(id: id, name: ref.persons[id]!);
  Group groupOf(int id) => Group(id: id, title: ref.groups[id]!);
  Kid kidOf(int id) => Kid(id: id, text: ref.kids[id]!.text, n: ref.kids[id]!.n);
  Tag tagOf(String key) {
    final List<String> p = key.split('|');
    return Tag(ns: p[0], label: p[1], title: ref.tags[key]!.title);
  }

  Tag newTag(FluentFuzz f) {
    final int c = counter++;
    return Tag(ns: c.isEven ? 'a' : 'b', label: 'L${c ~/ 2}', title: f.string(max: 5));
  }

  int idOf(FluentStorable m) => m.primaryKeyValue! as int;

  // ----- operations -----------------------------------------------------------------------------------------------

  GraphOp createOwner(FluentFuzz f) {
    final String name = f.string(max: 6);
    final List<int> persons = ref.persons.keys.toList();
    final Person? boss = f.chance(0.5) ? (persons.isNotEmpty && f.chance(0.5) ? personOf(f.pick(persons)) : Person(name: f.string(max: 5))) : null;
    final Profile? profile = f.chance(0.5) ? Profile(bio: f.string(max: 5)) : null;
    final List<Kid> kids = [for (int i = f.intIn(0, 3); i > 0; i--) Kid(text: f.string(max: 5), n: f.intIn(0, 9))];
    final List<Tag> tags = [for (final String k in f.subset(ref.liveTags, keep: 0.3)) tagOf(k), if (f.chance(0.4)) newTag(f)];
    final List<Note> notes = [for (int i = f.intIn(0, 2); i > 0; i--) Note(text: f.string(max: 5))];
    final Owner o = Owner(name: name, boss: boss, profile: profile, kids: kids, tags: tags, notes: notes);
    return GraphOp('createOwner($name, boss: ${boss?.id ?? (boss == null ? '-' : 'new')}, profile: ${profile != null}, kids: ${kids.length}, tags: ${tags.map(tagKey)}, notes: ${notes.length})', () => g.owners.save(o), (r) {
      final int id = idOf(o);
      if (boss != null) r.persons[idOf(boss)] = boss.name;
      r.owners[id] = ROwner(name, boss == null ? null : idOf(boss));
      if (profile != null) r.profiles[idOf(profile)] = (id, profile.bio);
      for (final Kid k in kids) {
        r.kids[idOf(k)] = RKid(id, k.text, k.n);
      }
      for (final Tag t in tags) {
        r.tags.putIfAbsent(tagKey(t), () => RTag(t.title)).title = t.title;
        r.links.add('$id|${tagKey(t)}');
      }
      for (final Note n in notes) {
        r.notes[idOf(n)] = RNote(n.text, 'owners', id);
      }
    });
  }

  /// G3: edit the eagerly loaded lists of an owner and save the instance that was read.
  GraphOp editEager(FluentFuzz f, int id) {
    final bool rename = f.chance(0.3);
    final String name = f.string(max: 6);
    final bool editTags = f.chance(0.6);
    final double keepTag = f.pick([0.0, 0.5, 1.0]);
    final List<String> addTags = f.subset(ref.liveTags, keep: 0.2);
    final bool addNewTag = f.chance(0.3);
    final bool editNotes = f.chance(0.5);
    final bool editProfile = f.chance(0.4);
    final bool replaceProfile = f.chance(0.5);
    final bool changeBoss = f.chance(0.3);
    final List<int> persons = ref.persons.keys.toList();
    final int? bossId = persons.isNotEmpty && f.chance(0.6) ? f.pick(persons) : null;
    final bool editMems = f.chance(0.4);
    final int fseed = f.intIn(0, 1 << 30);
    final FluentFuzz e = FluentFuzz(fseed);
    late Owner o;
    final List<Note> newNotes = [];
    Profile? newProfile;
    Person? boss;
    Tag? createdTag;
    final List<Tag> addedTags = [];
    return GraphOp('editEager(owner $id, rename: $rename, tags: $editTags/$keepTag+$addTags+$addNewTag, notes: $editNotes, profile: $editProfile/$replaceProfile, boss: $changeBoss/$bossId, mems: $editMems, edits: $fseed)', () async {
      o = (await g.owners.findById(id))!;
      if (rename) o.name = name;
      if (editTags) {
        createdTag = addNewTag ? newTag(e) : null;
        addedTags
          ..clear()
          ..addAll([for (final String k in addTags) tagOf(k), ?createdTag]);
        o.tags = [...e.subset(o.tags!, keep: keepTag), ...addedTags];
      }
      if (editNotes) {
        final List<Note> kept = e.subset(o.notes!, keep: 0.6);
        for (final Note n in kept) {
          if (e.chance(0.4)) n.text = e.string(max: 5);
        }
        newNotes
          ..clear()
          ..addAll([if (e.chance(0.5)) Note(text: e.string(max: 5))]);
        o.notes = [...kept, ...newNotes];
      }
      if (editProfile) {
        if (replaceProfile || o.profile == null) {
          newProfile = Profile(bio: e.string(max: 5));
          o.profile = newProfile;
        } else {
          o.profile!.bio = e.string(max: 5);
        }
      }
      if (changeBoss) {
        boss = bossId != null ? personOf(bossId) : Person(name: e.string(max: 5));
        o.boss = boss;
      }
      if (editMems) {
        final List<Membership> kept = e.subset(o.memberships!, keep: 0.6);
        for (final Membership m in kept) {
          if (e.chance(0.4)) m.role = e.string(max: 4);
        }
        o.memberships = kept;
      }
      await g.owners.save(o);
    }, (r) {
      final ROwner ro = r.owners[id]!;
      if (rename) ro.name = name;
      if (editTags) {
        final Set<String> listed = {for (final Tag t in o.tags!) tagKey(t)};
        for (final Tag t in addedTags) {
          r.tags.putIfAbsent(tagKey(t), () => RTag(t.title));
        }
        // Only links to live targets the list could show are removed (G3).
        r.links.removeWhere((l) => l.startsWith('$id|') && !listed.contains(l.substring('$id|'.length)) && r.tags[l.substring('$id|'.length)]!.gen == null);
        for (final String k in listed) {
          r.links.add('$id|$k');
        }
      }
      if (editNotes) {
        final Set<int> listed = {};
        for (final Note n in o.notes!) {
          final int nid = idOf(n);
          listed.add(nid);
          r.notes[nid] = RNote(n.text, 'owners', id);
        }
        r.notes.removeWhere((nid, n) => n.type == 'owners' && n.target == id && !listed.contains(nid));
      }
      if (editProfile) {
        if (newProfile != null) {
          r.profiles.removeWhere((_, p) => p.$1 == id);
          r.profiles[idOf(newProfile!)] = (id, newProfile!.bio);
        } else {
          r.profiles[idOf(o.profile!)] = (id, o.profile!.bio);
        }
      }
      if (changeBoss) {
        r.persons[idOf(boss!)] = boss!.name;
        ro.boss = idOf(boss!);
      }
      if (editMems) {
        final Set<int> listed = {for (final Membership m in o.memberships!) idOf(m)};
        for (final Membership m in o.memberships!) {
          r.mems[idOf(m)]!.role = m.role;
        }
        final List<int> removed = [for (final int m in r.liveMemsOf(id)) if (!listed.contains(m)) m];
        if (removed.isNotEmpty) {
          final int gen = r.nextGen();
          for (final int m in removed) {
            r.mems[m]!.gen = gen;
          }
        }
      }
    });
  }

  /// G3 / G8: load one kid list (full, limit view, where view, includeDeleted view), check it against the reference,
  /// edit it and save the instance: only rows the list could show are removed.
  GraphOp editKids(FluentFuzz f, int id) {
    final String view = f.pick(['kids', 'topKids', 'bigKids', 'allKids']);
    final FluentLoad first = f.pick([FluentLoad.none, FluentLoad.eager]);
    final int fseed = f.intIn(0, 1 << 30);
    late Owner o;
    late List<Kid> loaded;
    final List<Kid> kept = [];
    final List<Kid> added = [];
    late List<int> liveBefore;
    late Map<int, int> nBefore;
    return GraphOp('editKids(owner $id, $view, first: ${first.name}, edits: $fseed)', () async {
      final FluentFuzz e = FluentFuzz(fseed);
      liveBefore = ref.liveKidsOf(id);
      nBefore = {for (final int k in ref.allKidsOf(id)) k: ref.kids[k]!.n};
      o = await g.owners.loadRelations((await g.owners.findById(id, relations: first))!, names: [view]);
      loaded = switch (view) {
        'kids' => o.kids!,
        'topKids' => o.topKids!,
        'bigKids' => o.bigKids!,
        _ => o.allKids!,
      };
      // G8: the loaded view holds exactly what the relation shows.
      final List<int> live = ref.liveKidsOf(id);
      final List<int> expected = switch (view) {
        'kids' => live,
        'topKids' => (List.of(live)..sort((a, b) => ref.kids[b]!.n != ref.kids[a]!.n ? ref.kids[b]!.n - ref.kids[a]!.n : a - b)).take(2).toList(),
        'bigKids' => [for (final int k in live) if (ref.kids[k]!.n >= 5) k],
        _ => ref.allKidsOf(id),
      };
      expect([for (final Kid k in loaded) idOf(k)], expected, reason: 'G8: loaded $view of owner $id');
      for (final Kid k in loaded) {
        expect((k.text, k.n), (ref.kids[idOf(k)]!.text, ref.kids[idOf(k)]!.n), reason: 'G29: fields of kid ${idOf(k)}');
      }
      kept
        ..clear()
        ..addAll(e.subset(loaded, keep: 0.6));
      for (final Kid k in kept) {
        if (e.chance(0.4)) k.n = e.intIn(0, 9);
        if (e.chance(0.3)) k.text = e.string(max: 5);
      }
      added
        ..clear()
        ..addAll([for (int i = e.intIn(0, 2); i > 0; i--) Kid(text: e.string(max: 5), n: e.intIn(0, 9))]);
      final List<Kid> list = [...kept, ...added];
      switch (view) {
        case 'kids':
          o.kids = list;
        case 'topKids':
          o.topKids = list;
        case 'bigKids':
          o.bigKids = list;
        default:
          o.allKids = list;
      }
      await g.owners.save(o);
    }, (r) {
      final Set<int> listed = {for (final Kid k in kept) idOf(k)};
      for (final Kid k in kept) {
        final RKid rk = r.kids[idOf(k)]!;
        if (rk.gen != null) continue; // read from the trash: not written (no restore through the parent)
        rk
          ..text = k.text
          ..n = k.n;
      }
      for (final Kid k in added) {
        r.kids[idOf(k)] = RKid(id, k.text, k.n);
      }
      final List<int> removed = switch (view) {
        'topKids' => const [], // a limit shows part of the list: nothing is removed
        'bigKids' => [for (final int k in liveBefore) if (!listed.contains(k) && nBefore[k]! >= 5) k],
        _ => [for (final int k in liveBefore) if (!listed.contains(k)) k],
      };
      if (removed.isNotEmpty) {
        final int gen = r.nextGen();
        for (final int k in removed) {
          r.kids[k]!.gen = gen;
        }
      }
    });
  }

  /// G3: a model read without its relations (none / depth 0) gets new children and links; nothing is removed.
  GraphOp mergeUnloaded(FluentFuzz f, int id) {
    final bool none = f.chance(0.5);
    final Kid kid = Kid(text: f.string(max: 5), n: f.intIn(0, 9));
    final List<String> live = ref.liveTags;
    final Tag tag = live.isNotEmpty && f.chance(0.5) ? tagOf(f.pick(live)) : newTag(f);
    final Note note = Note(text: f.string(max: 5));
    return GraphOp('mergeUnloaded(owner $id, ${none ? 'relations: none' : 'lazy kids'}, tag: ${tagKey(tag)})', () async {
      final Owner o = (await g.owners.findById(id, relations: none ? FluentLoad.none : FluentLoad.eager))!;
      expect(o.isRelationLoaded('kids'), isFalse, reason: 'G8: a lazy relation is not loaded');
      expect(o.isRelationLoaded('tags'), !none, reason: 'G8: relations: none loads no relation');
      o
        ..kids = [kid]
        ..tags = [...?o.tags, tag]
        ..notes = [...?o.notes, note];
      await g.owners.save(o);
    }, (r) {
      r.kids[idOf(kid)] = RKid(id, kid.text, kid.n);
      r.tags.putIfAbsent(tagKey(tag), () => RTag(tag.title));
      r.links.add('$id|${tagKey(tag)}');
      r.notes[idOf(note)] = RNote(note.text, 'owners', id);
    });
  }

  /// G3: a model rebuilt with copyWith from a read (no lists loaded, eager lists, every list, or one kid view loaded
  /// and edited in place, or copied with `[...]`) is saved: only rows the list showed and lost are removed.
  GraphOp rebuildOwner(FluentFuzz f, int id) {
    final String source = f.pick(['none', 'eager', 'all', 'kids', 'topKids', 'bigKids', 'allKids']);
    final bool copy = f.chance(0.3);
    final String name = f.string(max: 6);
    final int fseed = f.intIn(0, 1 << 30);
    final Set<int> dropped = {};
    final Set<String> droppedTags = {};
    late List<int> liveBefore;
    late bool emptied;
    return GraphOp('rebuildOwner(owner $id, from: $source, copy: $copy, edits: $fseed)', () async {
      final FluentFuzz e = FluentFuzz(fseed);
      liveBefore = ref.liveKidsOf(id);
      dropped.clear();
      droppedTags.clear();
      emptied = false;
      switch (source) {
        case 'none' || 'eager' || 'all':
          final Owner o = (await g.owners.findById(id, relations: switch (source) { 'none' => FluentLoad.none, 'eager' => FluentLoad.eager, _ => FluentLoad.all }))!;
          if (source == 'eager' && o.tags != null) {
            // Tags dropped from the read list itself (the rebuilt owner carries the same instance).
            final List<Tag> kept = e.subset(o.tags!);
            droppedTags.addAll([for (final Tag t in o.tags!) if (!kept.contains(t)) tagKey(t)]);
            o.tags!.removeWhere((t) => !kept.contains(t));
          }
          await g.owners.save(o.copyWith(name: name));
        default:
          final Owner o = await g.owners.loadRelations((await g.owners.findById(id, relations: FluentLoad.none))!, names: [source]);
          final List<Kid> list = switch (source) {
            'kids' => o.kids!,
            'topKids' => o.topKids!,
            'bigKids' => o.bigKids!,
            _ => o.allKids!,
          };
          final List<Kid> kept = e.subset(list);
          dropped.addAll([for (final Kid k in list) if (!kept.contains(k)) idOf(k)]);
          final List<Kid> next;
          if (copy) {
            next = [...kept];
          } else {
            list.removeWhere((k) => !kept.contains(k));
            next = list;
          }
          emptied = copy && next.isEmpty;
          await g.owners.save(switch (source) {
            'kids' => o.copyWith(name: name, kids: next),
            'topKids' => o.copyWith(name: name, topKids: next),
            'bigKids' => o.copyWith(name: name, bigKids: next),
            _ => o.copyWith(name: name, allKids: next),
          });
      }
    }, (r) {
      r.owners[id]!.name = name;
      r.links.removeWhere((l) => l.startsWith('$id|') && droppedTags.contains(l.substring('$id|'.length)) && r.tags[l.substring('$id|'.length)]!.gen == null);
      // A limit removes nothing; an empty copied list is the app's own empty list: nothing removed (reported).
      if (source == 'topKids' || emptied) return;
      final List<int> removed = [for (final int k in liveBefore) if (dropped.contains(k)) k];
      if (removed.isEmpty) return;
      final int gen = r.nextGen();
      for (final int k in removed) {
        r.kids[k]!.gen = gen;
      }
    });
  }

  /// G3: an owner built by the app with empty lists removes nothing (reported); with relationSync: replace it clears
  /// its live kids, the links to its live tags and its notes.
  GraphOp builtOwner(FluentFuzz f, int id) {
    final bool replace = f.chance(0.4);
    final String name = f.string(max: 6);
    return GraphOp('builtOwner(owner $id, empty lists, replace: $replace)', () async {
      final Owner o = Owner(id: id, name: name, kids: [], tags: [], notes: []);
      await g.owners.save(o, relationSync: replace ? FluentRelationSyncMode.replace : null);
    }, (r) {
      r.owners[id]!.name = name;
      if (!replace) return;
      final List<int> kids = r.liveKidsOf(id);
      if (kids.isNotEmpty) {
        final int gen = r.nextGen();
        for (final int k in kids) {
          r.kids[k]!.gen = gen;
        }
      }
      r.links.removeWhere((l) => l.startsWith('$id|') && r.tags[l.substring('$id|'.length)]!.gen == null);
      r.notes.removeWhere((_, n) => n.type == 'owners' && n.target == id);
    });
  }

  /// G3 / G31: saving what was read, unchanged, at any load mode and depth changes nothing.
  GraphOp saveUnchanged(FluentFuzz f, int id) {
    final FluentLoad mode = f.pick(FluentLoad.values);
    final int depth = f.intIn(0, 3);
    return GraphOp('saveUnchanged(owner $id, ${mode.name}, maxDepth: $depth)', () async {
      await g.owners.save((await g.owners.findById(id, relations: mode, maxDepth: depth))!);
    }, (_) {});
  }

  /// G3: with every list loaded (the full list and its views over the same column), a child added to the full list
  /// is kept: the views were read before it existed.
  GraphOp addWithAllLoaded(FluentFuzz f, int id) {
    final List<Kid> added = [for (int i = f.intIn(1, 2); i > 0; i--) Kid(text: f.string(max: 5), n: f.intIn(0, 9))];
    final int depth = f.intIn(1, 2);
    return GraphOp('addWithAllLoaded(owner $id, ${added.length} kid(s), maxDepth: $depth)', () async {
      final Owner o = (await g.owners.findById(id, relations: FluentLoad.all, maxDepth: depth))!;
      o.kids = [...o.kids!, ...added];
      await g.owners.save(o);
    }, (r) {
      for (final Kid k in added) {
        r.kids[idOf(k)] = RKid(id, k.text, k.n);
      }
    });
  }

  GraphOp attach(FluentFuzz f, int id) {
    final List<int> groups = ref.groups.keys.toList();
    final Group group = groups.isNotEmpty && f.chance(0.6) ? groupOf(f.pick(groups)) : Group(title: f.string(max: 5));
    final String role = f.string(max: 4);
    Membership? made;
    return GraphOp('attach(owner $id, group ${group.id ?? 'new'}, $role)', () async {
      made = null;
      await g.owners.attach(ownerOf(id), 'groups', [group], link: (_) => made = Membership(role: role));
    }, (r) {
      final int gid = idOf(group);
      r.groups[gid] = group.title;
      final bool linked = r.liveMemsOf(id).any((m) => r.mems[m]!.group == gid);
      if (made != null && made!.primaryKeyValue != null) {
        expect(linked, isFalse, reason: 'a group already linked is not linked twice');
        r.mems[idOf(made!)] = RMem(role, id, gid);
      } else {
        expect(linked, isTrue, reason: 'attach skipped only a group that is linked');
      }
    });
  }

  GraphOp detach(FluentFuzz f, int id, int gid) => GraphOp('detach(owner $id, group $gid)', () => g.owners.detach(ownerOf(id), 'groups', [groupOf(gid)]), (r) {
    final List<int> mems = [for (final int m in r.liveMemsOf(id)) if (r.mems[m]!.group == gid) m];
    if (mems.isEmpty) return;
    final int gen = r.nextGen();
    for (final int m in mems) {
      r.mems[m]!.gen = gen;
    }
  });

  GraphOp personNote(FluentFuzz f) {
    final List<int> persons = ref.persons.keys.toList();
    final List<int> owners = ref.owners.keys.toList();
    final bool onOwner = owners.isNotEmpty && (persons.isEmpty || f.chance(0.4));
    final FluentStorable target = onOwner ? ownerOf(f.pick(owners)) : (persons.isNotEmpty ? personOf(f.pick(persons)) : Person(name: f.string(max: 5)));
    final Note note = Note(text: f.string(max: 5), target: target);
    return GraphOp('saveNote(on ${target.runtimeType} ${target.primaryKeyValue ?? 'new'})', () => g.notes.save(note), (r) {
      if (target is Person) r.persons[idOf(target)] = target.name;
      // Saving a model whose row is in the trash brings it back (documented upsert outcome "restored", with the rows
      // deleted together with it): the reference is saved through the note.
      if (target is Owner && r.owners[idOf(target)]!.gen != null) r.restoreOwner(idOf(target));
      r.notes[idOf(note)] = RNote(note.text, onOwner ? 'owners' : 'persons', idOf(target));
    });
  }

  GraphOp newThing(FluentFuzz f) {
    switch (f.intIn(0, 2)) {
      case 0:
        final Person p = Person(name: f.string(max: 5));
        return GraphOp('newPerson', () => g.persons.save(p), (r) => r.persons[idOf(p)] = p.name);
      case 1:
        final Group gr = Group(title: f.string(max: 5));
        return GraphOp('newGroup', () => g.groups.save(gr), (r) => r.groups[idOf(gr)] = gr.title);
      default:
        final Tag t = newTag(f);
        return GraphOp('newTag(${tagKey(t)})', () => g.tags.save(t), (r) => r.tags[tagKey(t)] = RTag(t.title));
    }
  }

  GraphOp? removal(FluentFuzz f) {
    final List<GraphOp Function()> choices = [
      if (ref.liveOwners.isNotEmpty)
        () {
          final int id = f.pick(ref.liveOwners);
          return GraphOp('deleteOwner($id)', () => g.owners.delete(ownerOf(id)), (r) => r.trashOwner(id));
        },
      if (ref.trashedOwners.isNotEmpty)
        () {
          final int id = f.pick(ref.trashedOwners);
          return GraphOp('restoreOwner($id)', () => g.owners.trash.restore(ownerOf(id)), (r) => r.restoreOwner(id));
        },
      if (ref.owners.isNotEmpty)
        () {
          final int id = f.pick(ref.owners.keys.toList());
          return GraphOp('deleteOwnerForever($id)', () => g.owners.trash.deleteForever(ownerOf(id)), (r) => r.hardDeleteOwner(id));
        },
      if (ref.kids.values.any((k) => k.gen == null))
        () {
          final int id = f.pick([for (final e in ref.kids.entries) if (e.value.gen == null) e.key]);
          return GraphOp('deleteKid($id)', () => g.kids.delete(kidOf(id)), (r) => r.kids[id]!.gen = r.nextGen());
        },
      if (ref.kids.values.any((k) => k.gen != null))
        () {
          final int id = f.pick([for (final e in ref.kids.entries) if (e.value.gen != null) e.key]);
          return GraphOp('restoreKid($id)', () => g.kids.trash.restore(kidOf(id)), (r) {
            // A kid whose owner is in the trash stays there (trashStays).
            if (r.owners[r.kids[id]!.owner]!.gen == null) r.kids[id]!.gen = null;
          });
        },
      if (ref.kids.isNotEmpty)
        () {
          final int id = f.pick(ref.kids.keys.toList());
          return GraphOp('deleteKidForever($id)', () => g.kids.trash.deleteForever(kidOf(id)), (r) => r.kids.remove(id));
        },
      if (ref.liveTags.isNotEmpty)
        () {
          final String k = f.pick(ref.liveTags);
          return GraphOp('deleteTag($k)', () => g.tags.delete(tagOf(k)), (r) => r.tags[k]!.gen = r.nextGen());
        },
      if (ref.tags.values.any((t) => t.gen != null))
        () {
          final String k = f.pick([for (final e in ref.tags.entries) if (e.value.gen != null) e.key]);
          return GraphOp('restoreTag($k)', () => g.tags.trash.restore(tagOf(k)), (r) => r.tags[k]!.gen = null);
        },
      if (ref.tags.isNotEmpty)
        () {
          final String k = f.pick(ref.tags.keys.toList());
          return GraphOp('deleteTagForever($k)', () => g.tags.trash.deleteForever(tagOf(k)), (r) {
            r.tags.remove(k);
            r.links.removeWhere((l) => l.substring(l.indexOf('|') + 1) == k);
          });
        },
      if (ref.persons.isNotEmpty)
        () {
          final int id = f.pick(ref.persons.keys.toList());
          return GraphOp('deletePerson($id)', () => g.persons.delete(personOf(id)), (r) {
            r.persons.remove(id);
            for (final ROwner o in r.owners.values) {
              if (o.boss == id) o.boss = null; // SET NULL
            }
            for (final RNote n in r.notes.values) {
              if (n.type == 'persons' && n.target == id) {
                n
                  ..type = null
                  ..target = null; // the polymorphic reference is cleared
              }
            }
          });
        },
      if (ref.groups.isNotEmpty)
        () {
          final int id = f.pick(ref.groups.keys.toList());
          return GraphOp('deleteGroup($id)', () => g.groups.delete(groupOf(id)), (r) {
            r.groups.remove(id);
            for (final RMem m in r.mems.values) {
              if (m.group == id) m.group = null;
            }
          });
        },
    ];
    return choices.isEmpty ? null : f.pick(choices)();
  }

  GraphOp nextOp(FluentFuzz f) {
    final List<int> live = ref.liveOwners;
    final String kind = f.weighted({
      'create': live.length < 2 ? 10 : 3,
      if (live.isNotEmpty) 'eager': 4,
      if (live.isNotEmpty) 'kids': 5,
      if (live.isNotEmpty) 'merge': 2,
      if (live.isNotEmpty) 'unchanged': 2,
      if (live.isNotEmpty) 'addAll': 1,
      if (live.isNotEmpty) 'rebuild': 4,
      if (live.isNotEmpty) 'built': 1,
      if (live.isNotEmpty) 'attach': 2,
      if (live.any((o) => ref.groupsOf(o).isNotEmpty)) 'detach': 1,
      'note': 1,
      'new': 1,
      'remove': 4,
    });
    switch (kind) {
      case 'eager':
        return editEager(f, f.pick(live));
      case 'kids':
        return editKids(f, f.pick(live));
      case 'merge':
        return mergeUnloaded(f, f.pick(live));
      case 'addAll':
        return addWithAllLoaded(f, f.pick(live));
      case 'rebuild':
        return rebuildOwner(f, f.pick(live));
      case 'built':
        return builtOwner(f, f.pick(live));
      case 'unchanged':
        return saveUnchanged(f, f.pick(live));
      case 'attach':
        return attach(f, f.pick(live));
      case 'detach':
        final int o = f.pick([for (final int o in live) if (ref.groupsOf(o).isNotEmpty) o]);
        return detach(f, o, f.pick(ref.groupsOf(o)));
      case 'note':
        return personNote(f);
      case 'new':
        return newThing(f);
      case 'remove':
        return removal(f) ?? createOwner(f);
      default:
        return createOwner(f);
    }
  }

  // ----- checks -----------------------------------------------------------------------------------------------------

  Future<void> checkStored() async {
    // gen <-> stamp must be a one-to-one map: rows trashed by one call share a stamp, rows of different calls never.
    final Map<int, Object?> stampOfGen = {};
    final Map<Object?, int> genOfStamp = {};
    void pair(String what, int? gen, Object? stamp) {
      expect(stamp != null, gen != null, reason: 'G9 / G21: $what is ${gen == null ? 'live' : 'in the trash'}');
      if (gen == null) return;
      expect(stampOfGen.putIfAbsent(gen, () => stamp), stamp, reason: 'G9: rows trashed together share one stamp ($what)');
      expect(genOfStamp.putIfAbsent(stamp, () => gen), gen, reason: 'G9: rows trashed by different calls never share a stamp ($what)');
    }

    Future<List<Map<String, Object?>>> q(String sql) => raw.rawQuery(sql);

    final List<Map<String, Object?>> owners = await q('SELECT id, name, boss_id, deleted_at FROM owners');
    expect({for (final r in owners) r['id']}, ref.owners.keys.toSet(), reason: 'G21: owner rows');
    for (final r in owners) {
      final ROwner o = ref.owners[r['id']]!;
      expect((r['name'], r['boss_id']), (o.name, o.boss), reason: 'owner ${r['id']}');
      pair('owner ${r['id']}', o.gen, r['deleted_at']);
    }
    final List<Map<String, Object?>> kids = await q('SELECT id, owner_id, text, n, deleted_at FROM kids');
    expect({for (final r in kids) r['id']}, ref.kids.keys.toSet(), reason: 'G3 / G21: kid rows');
    for (final r in kids) {
      final RKid k = ref.kids[r['id']]!;
      expect((r['owner_id'], r['text'], r['n']), (k.owner, k.text, k.n), reason: 'kid ${r['id']}');
      pair('kid ${r['id']}', k.gen, r['deleted_at']);
    }
    final List<Map<String, Object?>> tags = await q('SELECT ns, label, title, deleted_at FROM tags');
    expect({for (final r in tags) '${r['ns']}|${r['label']}'}, ref.tags.keys.toSet(), reason: 'G21: tag rows');
    for (final r in tags) {
      final RTag t = ref.tags['${r['ns']}|${r['label']}']!;
      expect(r['title'], t.title, reason: 'tag ${r['ns']}|${r['label']}');
      pair('tag ${r['ns']}|${r['label']}', t.gen, r['deleted_at']);
    }
    expect({for (final r in await q('SELECT owner_id, tag_ns, tag_label FROM owners_tags')) '${r['owner_id']}|${r['tag_ns']}|${r['tag_label']}'}, ref.links, reason: 'G3 / G21: links');
    expect({for (final r in await q('SELECT id, owner_id, bio FROM profiles')) r['id']: (r['owner_id'], r['bio'])}, ref.profiles, reason: 'G3 / G21: profiles');
    expect({for (final r in await q('SELECT id, name FROM persons')) r['id']: r['name']}, ref.persons, reason: 'G21: persons');
    expect({for (final r in await q('SELECT id, title FROM groups')) r['id']: r['title']}, ref.groups, reason: 'G21: groups');
    expect({for (final r in await q('SELECT id, text, target_type, target_id FROM notes')) r['id']: (r['text'], r['target_type'], r['target_id'])}, {
      for (final e in ref.notes.entries) e.key: (e.value.text, e.value.type, e.value.target),
    }, reason: 'G3 / G21: notes');
    final List<Map<String, Object?>> mems = await q('SELECT id, role, owner_id, group_id, deleted_at FROM memberships');
    expect({for (final r in mems) r['id']}, ref.mems.keys.toSet(), reason: 'G21: membership rows');
    for (final r in mems) {
      final RMem m = ref.mems[r['id']]!;
      expect((r['role'], r['owner_id'], r['group_id']), (m.role, m.owner, m.group), reason: 'membership ${r['id']}');
      pair('membership ${r['id']}', m.gen, r['deleted_at']);
    }
  }

  Future<void> checkVisible(FluentFuzz f) async {
    final List<Owner> owners = await g.owners.find(orderBy: 'id');
    expect([for (final Owner o in owners) o.id], ref.liveOwners, reason: 'G8: live owners');
    for (final Owner o in owners) {
      final int id = o.id!;
      final ROwner ro = ref.owners[id]!;
      expect(o.name, ro.name, reason: 'G29');
      expect(o.boss?.id, ro.boss, reason: 'G8: boss of $id');
      if (o.boss != null) expect(o.boss!.name, ref.persons[ro.boss], reason: 'G29: boss fields');
      final int? p = ref.profileOf(id);
      expect((o.profile?.id, o.profile?.bio), (p, p == null ? null : ref.profiles[p]!.$2), reason: 'G8: profile of $id');
      expect({for (final Tag t in o.tags!) tagKey(t)}, ref.liveTagsOf(id).toSet(), reason: 'G8: tags of $id (trashed tags hidden)');
      expect(o.tags!.length, ref.liveTagsOf(id).length);
      expect([for (final Note n in o.notes!) n.id], ref.notesOf(id), reason: 'G8: notes of $id');
      expect([for (final Membership m in o.memberships!) m.id], ref.liveMemsOf(id), reason: 'G8: memberships of $id');
      expect([for (final Group gr in o.groups!) gr.id], ref.groupsOf(id), reason: 'G8: groups of $id (through)');
      expect(o.isRelationLoaded('kids'), isFalse, reason: 'lazy relation not loaded');
      expect(o.kids ?? const <Kid>[], isEmpty, reason: 'its default (null or empty)');
    }
    expect([for (final Kid k in await g.kids.find(orderBy: 'id')) k.id], [for (final e in ref.kids.entries) if (e.value.gen == null) e.key]..sort(), reason: 'G8: live kids');
    expect(await g.kids.trash.count(), ref.kids.values.where((k) => k.gen != null).length, reason: 'G8: kids in the trash');
    expect([for (final Owner o in await g.owners.trash.find(orderBy: 'id', relations: FluentLoad.none)) o.id], ref.trashedOwners, reason: 'G8: owners in the trash');
    expect(await g.owners.withTrash.count(), ref.owners.length, reason: 'G8: withTrash');
    expect(await g.tags.count(), ref.liveTags.length, reason: 'G8: live tags');
    // G8: a relation filter agrees with the loaded lists.
    expect(await g.owners.count(where: FluentFilter.related<Kid>('kids')), ref.liveOwners.where((o) => ref.liveKidsOf(o).isNotEmpty).length, reason: 'G8: related(kids)');
    expect(await g.owners.count(where: FluentFilter.related<Tag>('tags')), ref.liveOwners.where((o) => ref.liveTagsOf(o).isNotEmpty).length, reason: 'G8: related(tags)');
    if (ref.liveOwners.isNotEmpty) {
      final int id = f.pick(ref.liveOwners);
      final Owner o = ownerOf(id);
      expect(await g.owners.countRelated(o, 'kids'), ref.liveKidsOf(id).length, reason: 'G8: countRelated kids of $id');
      expect(await g.owners.countRelated(o, 'tags'), ref.liveTagsOf(id).length, reason: 'G8: countRelated tags of $id');
      expect(await g.owners.countRelated(o, 'groups'), ref.groupsOf(id).length, reason: 'G8: countRelated groups of $id');
      expect([for (final Kid k in await g.owners.findRelated<Kid>(o, 'kids')) k.id], ref.liveKidsOf(id), reason: 'G8: findRelated kids of $id');
      expect([for (final Kid k in await g.owners.findRelated<Kid>(o, 'bigKids', orderBy: 'id')) k.id], [for (final int k in ref.liveKidsOf(id)) if (ref.kids[k]!.n >= 5) k], reason: 'G8: findRelated bigKids of $id');
    }
    if (ref.kids.isNotEmpty) {
      final int k = f.pick(ref.kids.keys.toList());
      final int owner = ref.kids[k]!.owner;
      expect([for (final Owner o in await g.kids.findParents<Owner>(kidOf(k), via: 'kids', relations: FluentLoad.none)) o.id], [if (ref.owners[owner]!.gen == null && ref.kids[k]!.gen == null) owner],
          reason: 'G8: findParents of kid $k (the owners whose list holds it: none for a kid in the trash)');
    }
  }

  Future<void> checkWatches() async {
    await db.settle();
    expect([for (final Owner o in watchedOwners ?? const []) (o.id, o.name, o.tags?.length)], [
      for (final int id in ref.liveOwners) (id, ref.owners[id]!.name, ref.liveTagsOf(id).length),
    ], reason: 'G11: the owner watch converged');
    expect([for (final Kid k in watchedKids ?? const []) (k.id, k.text, k.n)], [
      for (final e in (ref.kids.entries.where((e) => e.value.gen == null).toList()..sort((a, b) => a.key - b.key))) (e.key, e.value.text, e.value.n),
    ], reason: 'G11: the kid watch converged');
  }

  // ----- the sequence -------------------------------------------------------------------------------------------------

  final FluentFuzz checks = FluentFuzz(seed + 1);
  try {
    await runSequence(
      seed: seed,
      steps: steps,
      next: (f, i) {
        final GraphOp op = nextOp(f);
        // Most steps commit; some run in a transaction that rolls back (G1), some fail at a random write (G1).
        final String mode = f.weighted({'plain': 7, 'rollback': 2, 'fault': 2});
        final int nth = f.intIn(0, 4);
        final FaultKind kind = f.pick(FaultKind.values);
        switch (mode) {
          case 'rollback':
            return FuzzOp('rollback(${op.name})', () async {
              final Ref before = ref.copy();
              try {
                await FluentDb.transaction(() async {
                  await op.run();
                  throw _Rollback();
                });
              } on _Rollback catch (_) {}
              ref = before; // G1: nothing of it stays
            });
          case 'fault':
            return FuzzOp('fault(write #$nth, ${kind.name}, ${op.name})', () async {
              final int injected = faults.injected.length;
              faults.failNth(nth, where: (c) => c.isWrite && !c.matches('"deleted_at" < ?'), kind: kind); // not a background trash purge
              Object? error;
              try {
                await op.run();
              } catch (e) {
                error = e;
              } finally {
                faults.heal();
              }
              if (error == null) {
                expect(faults.injected.length, injected, reason: 'a call that met an injected failure cannot succeed silently: ${faults.injected.skip(injected).join('; ')}');
                op.apply(ref);
              } else {
                if (error is TestFailure) throw error;
                expectTypedError(error, reason: op.name);
                expect(faults.injected.length, greaterThan(injected), reason: 'only the injected failure fails: $error');
              }
            });
          default:
            return FuzzOp(op.name, () async {
              await op.run();
              op.apply(ref);
            });
        }
      },
      check: (i) async {
        await checkStored();
        await checkVisible(checks);
        await expectIntegrity(raw, reason: 'step $i');
        if (i % 7 == 6 || i == steps - 1) await checkWatches();
      },
    );
    expectIssuesHaveFixes(db.issues);
  } finally {
    for (final s in subs) {
      await s.cancel();
    }
  }
}
