// Guarantee tests: a process stopped at any point of a write (TEST_PLAN.md, agent T6): G14, G19.
//
// `captureCrashStates` copies the database files before every write / commit statement: each copy is what a killed
// process leaves on disk. Every copy is opened by the library itself (with the same providers) and must pass
// integrity_check and hold exactly a committed state: the one before or after the call (G14).
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/faults.dart';
import '../helpers/guarantees.dart';
import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';
import '_helpers.dart';

class SyncNote extends FluentStorable {
  SyncNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class SyncNotes extends FluentProvider<SyncNote> with FluentSyncable<SyncNote> {
  @override
  String get tableName => 'sync_notes';

  @override
  SyncNote get modelSample => SyncNote(text: '');

  @override
  SyncNote fromCacheJson(Map<String, dynamic> json) => SyncNote(id: json['id'] as int?, text: json['text'] as String);
}

/// Every row of every user table (and the sync tombstones), as text, per table.
Future<Map<String, String>> snapshotOf(Database d) async {
  final List<Map<String, Object?>> tables = await d.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND (name NOT LIKE '\\_\\_%' ESCAPE '\\' OR name = '__fluent_tombstones') "
    "AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name",
  );
  final Map<String, String> out = {};
  for (final Map<String, Object?> t in tables) {
    final String name = t['name']! as String;
    final List<Map<String, Object?>> rows = await d.rawQuery('SELECT * FROM "$name"');
    final List<String> lines = [for (final Map<String, Object?> r in rows) r.toString()]..sort();
    out[name] = lines.join('\n');
  }
  return out;
}

/// One crash state with the committed states it may hold.
class _Check {
  _Check(this.state, this.allowed, this.label, this.accept);

  final Map<String, String> state;
  final List<Map<String, String>> allowed;
  final String label;

  /// Another committed state that may be seen (e.g. a prefix of independent calls), besides [allowed].
  final bool Function(Map<String, String> seen)? accept;
}

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  late FluentTestDb db;
  late Directory scratch;
  int copyCounter = 0;
  final List<_Check> checks = [];

  setUp(() async {
    faults = await FaultyDatabaseFactory.install();
    scratch = await Directory.systemTemp.createTemp('fluent_crash_');
    db = FluentTestDb(persistent: true);
    checks.clear();
  });

  tearDown(() async {
    faults.heal();
    await db.close();
    faults.uninstall();
    try {
      await scratch.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file for a moment; the system cleans its temp directory.
    }
  });

  /// Runs [step] while copying the files before every write / commit statement; each copy may hold the state before
  /// or after it (only after with [onlyAfter]).
  Future<void> record(String name, Future<void> Function() step, Database Function() dbNow, {bool onlyAfter = false, bool Function(Map<String, String> seen)? accept}) async {
    final Map<String, String> before = await snapshotOf(dbNow());
    final String dir = '${scratch.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'\W'), '_')}';
    final List<Map<String, String>> states = await captureCrashStates(faults, dir, step);
    final Map<String, String> after = await snapshotOf(dbNow());
    expect(states.length, greaterThan(1), reason: '$name sends writes');
    for (int k = 0; k < states.length; k++) {
      checks.add(_Check(states[k], [if (!onlyAfter) before, after], '$name, crash #$k of ${states.length}', accept));
    }
  }

  /// Closes the original, then opens every recorded copy with [providers] and checks G14 / G19.
  Future<void> verify(List<FluentProvider> Function() providers, {Future<void> Function(Database raw, int matched, String label)? more}) async {
    final String originalName = db.name;
    await db.close(keepFile: true);
    expect(checks, isNotEmpty);
    for (final _Check c in checks) {
      final String main = c.state.values.firstWhere((p) => p.contains(originalName));
      final String name = 'crash_copy_${copyCounter++}';
      final String target = '${await getDatabasesPath()}/$name.db';
      for (final String suffix in const ['', '-wal', '-journal']) {
        final File f = File('$main$suffix');
        if (f.existsSync()) await f.copy('$target$suffix');
      }
      final FluentTestDb copy = FluentTestDb(name: name, persistent: true);
      try {
        final List<FluentProvider> ps = providers();
        await copy.open(ps).timeout(const Duration(seconds: 20));
        final Database raw = ps.first.db;
        await expectIntegrity(raw, reason: 'G14 ${c.label}');
        expectIssuesHaveFixes(copy.issues);
        final Map<String, String> seenMap = await snapshotOf(raw);
        final String seen = seenMap.toString();
        final int matched = c.allowed.indexWhere((a) => a.toString() == seen);
        if (matched < 0 && (c.accept?.call(seenMap) ?? false)) continue;
        expect(matched, greaterThanOrEqualTo(0), reason: 'G14: ${c.label}: neither the committed state before nor the one after:\nseen   : $seen\nallowed: ${c.allowed}');
        await more?.call(raw, matched, c.label);
      } finally {
        await copy.close();
      }
    }
    db = FluentTestDb(name: originalName, persistent: true); // so tearDown removes the original's file
  }

  List<FluentProvider> relationSet(GadgetProvider g, ArticleProvider a, CommentProvider c) => [g, PersonProvider(), ProfileProvider(), c, TagProvider(), a, CategoryProvider()];

  group('G14: a process stopped at any point of a write', () {
    test('G14: single save, update and delete', () async {
      final GadgetProvider g = GadgetProvider();
      await db.open([g]);
      await g.saveAll([Gadget(name: 'a'), Gadget(name: 'b')]);
      await record('save new', () => g.save(Gadget(name: 'new', qty: 1)), () => g.db);
      await record('save update', () => g.save(Gadget(id: 1, name: 'a2', qty: 2)), () => g.db);
      await record('delete', () => g.deleteById(2), () => g.db);
      await record('updateWhere', () => g.updateWhere(FluentFilter.gt('qty', 0), {'qty': 9}), () => g.db);
      await verify(() => [GadgetProvider()]);
    });

    test('G14: a merged batch of unawaited saves and a saveAll', () async {
      final GadgetProvider g = GadgetProvider();
      await db.open([g]);
      await g.save(Gadget(name: 'seed'));
      // Independent calls: each commits on its own (or all together, when merged), so the state is the seed plus a
      // prefix m0..m(k-1) of the calls, in call order, never a gap, never half a row.
      bool prefix(Map<String, String> seen) {
        final List<String> names = [for (final Match m in RegExp(r'name: (\w+),').allMatches(seen['gadgets']!)) m.group(1)!]..sort();
        final int k = names.length - 1;
        return k >= 0 && names.contains('seed') && names.where((n) => n != 'seed').toList().join() == [for (int i = 0; i < k; i++) 'm$i'].join();
      }

      await record('merged', () => Future.wait([for (int i = 0; i < 5; i++) g.save(Gadget(name: 'm$i', qty: i))]), () => g.db, accept: prefix);
      await record('saveAll', () => g.saveAll([Gadget(id: 1, name: 'x'), Gadget(name: 'y'), Gadget(name: 'z')]), () => g.db);
      await verify(() => [GadgetProvider()]);
    });

    test('G14: a transaction with several writes and relation saves', () async {
      final GadgetProvider g = GadgetProvider();
      final ArticleProvider a = ArticleProvider();
      final CommentProvider c = CommentProvider();
      await db.open(relationSet(g, a, c));
      await a.save(Article(title: 'a1', author: Person(name: 'ann'), comments: [Comment(text: 'c1'), Comment(text: 'c2')], tags: [Tag(label: 'red')]));
      await record(
        'transaction',
        () => FluentDb.transaction(() async {
          await g.save(Gadget(name: 't1'));
          await a.save(Article(title: 'a2', author: Person(name: 'bob'), comments: [Comment(text: 'k1')], tags: [Tag(label: 'red'), Tag(label: 'blue')]));
          await c.deleteById(1);
          await g.saveAll([Gadget(name: 't2'), Gadget(name: 't3')]);
        }),
        () => g.db,
      );
      await record(
        'relation replace',
        () => a.save(Article(id: 1, title: 'a1 edited', comments: [Comment(id: 2, text: 'c2 edited')], tags: [Tag(label: 'blue')]), relationSync: FluentRelationSyncMode.replace),
        () => g.db,
      );
      await record('cascade delete', () => a.deleteById(1), () => g.db);
      await record('restore', () => c.trash.restoreById(1), () => g.db);
      await verify(() => relationSet(GadgetProvider(), ArticleProvider(), CommentProvider()));
    });

    test('G14: clearTable, trash emptying, FluentDb.clear', () async {
      final GadgetProvider g = GadgetProvider();
      final ArticleProvider a = ArticleProvider();
      final CommentProvider c = CommentProvider();
      await db.open(relationSet(g, a, c));
      await g.saveAll([Gadget(name: 'g1'), Gadget(name: 'g2')]);
      await a.save(Article(title: 'a1', comments: [Comment(text: 'c1'), Comment(text: 'c2')], tags: [Tag(label: 'red')]));
      await c.deleteById(2);
      await record('empty trash', () => c.trash.empty(olderThan: Duration.zero), () => g.db);
      await record('clearTable', () => g.clearTable(), () => g.db);
      await record('clear', () => FluentDb.clear(), () => g.db);
      await verify(() => relationSet(GadgetProvider(), ArticleProvider(), CommentProvider()));
    });

    test('G14: sync bookkeeping (push, tombstones) is never half done', () async {
      final SyncNotes notes = SyncNotes();
      await db.open([notes]);
      await notes.saveAll([SyncNote(text: 'a'), SyncNote(text: 'b'), SyncNote(text: 'c')]);
      // A push commits twice: first the sent marker (synced_version -1: the server may know the row, it stays pending),
      // then the accepted versions. A copy between the two holds the state before with some rows marked -1: committed
      // and safe (the rows are pushed again; a later delete sends a tombstone).
      String unmarked(String text) => text.replaceAll(RegExp(r'synced_version: -?\d+'), 'synced_version: *');
      bool Function(Map<String, String>) sentMarkedOver(Map<String, String> before) =>
          (seen) => seen.values.any((t) => t.contains('synced_version: -1')) && seen.keys.every((k) => unmarked(seen[k]!) == unmarked(before[k] ?? ''));
      await record('push', () => notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted()).then((_) {}), () => notes.db, accept: sentMarkedOver(await snapshotOf(notes.db)));
      await notes.deleteById(1);
      await notes.save(SyncNote(id: 2, text: 'b edited'));
      await record('push delete and edit', () => notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult.accepted()).then((_) {}), () => notes.db, accept: sentMarkedOver(await snapshotOf(notes.db)));
      await notes.deleteById(3);
      await record('delete of a synced row', () => notes.deleteById(2), () => notes.db);
      await verify(() => [SyncNotes()]);
    });

    test('G14 G4: a migration (rename, new column, type change with a table rebuild) keeps every row, whenever the process stops', () async {
      DynamicProvider v1() => DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text'), FluentDbColumn.text('old_name'), FluentDbColumn.text('qty')]);
      DynamicProvider v2() => DynamicProvider(
        'notes',
        () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text'), FluentDbColumn.text('new_name').copyWith(oldName: 'old_name'), FluentDbColumn.integer('qty'), FluentDbColumn.integer('extra', defaultValue: 5)],
      );
      final DynamicProvider p1 = v1();
      await db.open([p1]);
      await p1.saveAll([p1.row({'id': 1, 'text': 'a', 'old_name': 'x', 'qty': '10'}), p1.row({'id': 2, 'text': 'b', 'old_name': 'y', 'qty': '20'})]);
      final DynamicProvider live = v2();
      Database current = p1.db;
      await record('migration', () async {
        await db.restart([live]);
        current = live.db;
      }, () => current, onlyAfter: true);
      await verify(() => [v2()], more: (Database raw, int matched, String label) async {
        final List<Map<String, Object?>> rows = await raw.rawQuery('SELECT id, text, new_name, qty, extra FROM notes ORDER BY id');
        expect(rows.map((r) => [r['id'], r['text'], r['new_name'], r['qty']]).toList(), [
          [1, 'a', 'x', 10],
          [2, 'b', 'y', 20],
        ], reason: 'G4 / G14: $label: every row and value survived');
      });
    });
  });
}
