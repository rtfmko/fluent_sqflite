// Guarantee tests: failures and outside influence (TEST_PLAN.md, agent T6): G1, G13, G15, G19, G20, G25.
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

/// A soft-delete model with an optional time to live.
class Memo extends FluentStorable with FluentSoftDeletable {
  Memo({this.id, required this.text, super.timeToLive});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class MemoProvider extends FluentProvider<Memo> {
  MemoProvider([this.table = 'memos']);

  final String table;

  @override
  String get tableName => table;

  @override
  Memo get modelSample => Memo(text: '');

  @override
  Memo fromCacheJson(Map<String, dynamic> json) => Memo(id: json['id'] as int?, text: json['text'] as String);
}

typedef Snapshot = Map<String, String>;

/// Every row of every user table (no bookkeeping, no full-text tables), as text, per table.
Future<Snapshot> snapshotOf(Database d) async {
  final List<Map<String, Object?>> tables = await d.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE '\\_\\_%' ESCAPE '\\' "
    "AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name",
  );
  final Snapshot out = {};
  for (final Map<String, Object?> t in tables) {
    final String name = t['name']! as String;
    final List<Map<String, Object?>> rows = await d.rawQuery('SELECT * FROM "$name"');
    // The library keeps stamps strictly increasing across runs, so only "trashed or not" is compared.
    final List<String> lines = [for (final Map<String, Object?> r in rows) {...r, if (r['deleted_at'] != null) 'deleted_at': 'trashed'}.toString()]..sort();
    out[name] = lines.join('\n');
  }
  return out;
}

/// What a scenario needs: the providers, the state before the faults, and the steps (calls) the faults hit.
class Scenario {
  Scenario({required this.providers, required this.steps, this.setup, this.persistent = false});

  final List<FluentProvider> providers;

  /// The provider whose connection is open after [setup] (default: the first one).
  FluentProvider? live;
  final bool persistent;

  /// Runs after open, before any fault (may restart the database with other providers).
  final Future<void> Function(FluentTestDb db)? setup;

  /// The calls made one after the other; each one is atomic (G1).
  final List<Future<void> Function()> steps;
}

void main() {
  setUpFluentTests();

  late FaultyDatabaseFactory faults;
  late FluentTestDb db;
  late LogWatch log;

  setUp(() async {
    faults = await FaultyDatabaseFactory.install();
    db = FluentTestDb();
    log = LogWatch.install();
  });

  tearDown(() async {
    faults.heal();
    await db.close();
    log.uninstall();
    faults.uninstall();
  });

  bool counted(SqlCall c) => !c.isRollback && c.method != 'closeDatabase';

  /// Opens a fresh database for [build], runs [Scenario.setup] and returns the scenario.
  Future<Scenario> prepare(Scenario Function() build) async {
    faults.heal();
    faults.calls.clear();
    faults.injected.clear();
    log.records.clear();
    db = FluentTestDb(persistent: build().persistent);
    final Scenario s = build();
    await db.open(s.providers);
    db.clock.set(DateTime.utc(2026, 5, 1, 12));
    await s.setup?.call(db);
    return s;
  }

  Database rawDb(Scenario s) => (s.live ?? s.providers.first).db;

  /// Dry run: the snapshot before, after each step, and the number of SQL calls of every step.
  Future<({List<Snapshot> snaps, List<int> counts})> dryRun(Scenario Function() build) async {
    final Scenario s = await prepare(build);
    final List<Snapshot> snaps = [await snapshotOf(rawDb(s))];
    final List<int> counts = [];
    for (final Future<void> Function() step in s.steps) {
      final int from = faults.calls.length;
      await step().timeout(const Duration(seconds: 10));
      counts.add(faults.calls.skip(from).where(counted).length);
      snaps.add(await snapshotOf(rawDb(s)));
    }
    return (snaps: snaps, counts: counts);
  }

  /// G1 / G13 / G19 / G25: fails the n-th SQL call of the scenario, for every n and a rotating fault kind (every kind
  /// for the first, the last and the COMMIT).
  Future<void> faultMatrix(String name, Scenario Function() build, {bool allKinds = false}) async {
    final ({List<Snapshot> snaps, List<int> counts}) dry = await dryRun(build);
    final int total = dry.counts.fold(0, (a, b) => a + b);
    expect(total, greaterThan(0), reason: '$name: the scenario sends SQL');
    for (int n = 0; n < total; n++) {
      final List<FaultKind> kinds = allKinds || n == 0 || n == total - 1 || n == total - 2 ? FaultKind.values : [FaultKind.values[n % FaultKind.values.length]];
      for (final FaultKind kind in kinds) {
        final String label = '$name: call #$n of $total failing with ${kind.name}';
        final Scenario s = await prepare(build);
        faults.failNth(n, kind: kind, where: counted);
        int done = 0;
        Object? error;
        for (final Future<void> Function() step in s.steps) {
          try {
            await step().timeout(const Duration(seconds: 10));
            done++;
          } catch (e) {
            error = e;
            break;
          }
        }
        final List<SqlCall> injected = List.of(faults.injected);
        faults.heal();
        expect(injected, hasLength(1), reason: '$label: the fault was injected (the scenario sends the same SQL every time)');
        if (error != null) {
          expectTypedError(error, reason: label);
          expect(await snapshotOf(rawDb(s)), dry.snaps[done], reason: 'G1: $label failed in step $done: the data equals the state before it (injected: ${injected.single})');
        } else {
          expect(await snapshotOf(rawDb(s)), dry.snaps.last, reason: 'G1: $label was absorbed: the result is the complete one (injected: ${injected.single})');
        }
        if (error != null) {
          expect(log.records.any((r) => r.level.index >= FluentLogLevel.warning.index), isTrue, reason: 'G25: $label was logged as a warning or error (error: $error)');
        }
        await expectIntegrity(rawDb(s), reason: label);
        // The next call works.
        final GadgetProvider probe = GadgetProvider('probe_after_fault');
        expect(probe.tableName, isNotEmpty);
        await (s.live ?? s.providers.first).count().timeout(const Duration(seconds: 10));
        expectIssuesHaveFixes(db.issues);
      }
    }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // The standard data: gadgets, a graph of articles / people / comments (soft delete) / tags, one trashed comment.
  // ------------------------------------------------------------------------------------------------------------------

  Future<void> seed(GadgetProvider g, ArticleProvider articles, CommentProvider comments) async {
    await g.saveAll([Gadget(name: 'g1', qty: 1), Gadget(name: 'g2', qty: 2), Gadget(name: 'g3', qty: 3)]);
    await articles.save(
      Article(
        title: 'a1',
        author: Person(name: 'ann'),
        comments: [Comment(text: 'c1'), Comment(text: 'c2')],
        tags: [Tag(label: 'red'), Tag(label: 'blue')],
      ),
    );
    await articles.save(Article(title: 'a2', comments: [Comment(text: 'c3')]));
    await comments.deleteById(3); // c3 in the trash
  }

  Scenario standard(List<Future<void> Function()> Function(GadgetProvider g, ArticleProvider a, CommentProvider c) steps, {bool seedData = true}) {
    final GadgetProvider g = GadgetProvider();
    final ArticleProvider a = ArticleProvider();
    final CommentProvider c = CommentProvider();
    return Scenario(
      providers: [g, PersonProvider(), ProfileProvider(), c, TagProvider(), a, CategoryProvider()],
      setup: (_) => seedData ? seed(g, a, c) : Future.value(),
      steps: steps(g, a, c),
    );
  }

  group('G1 G13 G19 G25: a failing statement of any call', () {
    test('G1: save of a new row', () => faultMatrix('save new', () => standard((g, a, c) => [() => g.save(Gadget(name: 'new', qty: 9))])));
    test('G1: save of an existing row', () => faultMatrix('save existing', () => standard((g, a, c) => [() => g.save(Gadget(id: 1, name: 'changed', qty: 9))])));
    test('G1: saveAll of new and existing rows', () => faultMatrix('saveAll', () => standard((g, a, c) => [() => g.saveAll([Gadget(id: 2, name: 'x'), Gadget(name: 'y'), Gadget(name: 'z')])])));
    test('G1: update / updateById / updateWhere', () => faultMatrix('updates', () => standard((g, a, c) => [
      () => g.update(Gadget(id: 1, name: 'u', qty: 5)),
      () => g.updateById(2, {'qty': 20}),
      () => g.updateWhere(FluentFilter.gt('qty', 0), {'qty': 7}),
    ])));
    test('G1: delete / deleteById', () => faultMatrix('deletes', () => standard((g, a, c) => [() => g.deleteById(1), () => g.deleteById(2)])));
    test('G1: soft delete and restore (cascade over the trash)', () => faultMatrix('trash', () => standard((g, a, c) => [() => c.deleteById(1), () => c.trash.restoreById(3), () => c.trash.restoreById(1)])));
    test('G1: a transaction with several writes', () => faultMatrix('transaction', () => standard((g, a, c) => [
      () => FluentDb.transaction(() async {
        await g.save(Gadget(name: 't1'));
        await g.saveAll([Gadget(name: 't2'), Gadget(id: 1, name: 't3')]);
        await g.deleteById(2);
        await c.save(Comment(text: 'tc'));
      }),
    ])));
    test('G1: a savepoint inside a transaction', () => faultMatrix('savepoint', () => standard((g, a, c) => [
      () => FluentDb.transaction(() async {
        await g.save(Gadget(name: 'outer'));
        await FluentDb.transaction(() async {
          await g.save(Gadget(name: 'inner'));
          await g.deleteById(1);
        });
        await g.save(Gadget(name: 'outer2'));
      }),
    ])));
    test('G1: a relation save (new article with author, comments, tags)', () => faultMatrix('relation new', () => standard((g, a, c) => [
      () => a.save(Article(title: 'n', author: Person(name: 'bob'), comments: [Comment(text: 'k1'), Comment(text: 'k2')], tags: [Tag(label: 'red'), Tag(label: 'green')])),
    ])));
    test('G1: a relation save that replaces children and links', () => faultMatrix('relation replace', () => standard((g, a, c) => [
      () => a.save(Article(id: 1, title: 'a1 edited', comments: [Comment(id: 1, text: 'c1 edited'), Comment(text: 'c4')], tags: [Tag(label: 'blue')]), relationSync: FluentRelationSyncMode.replace),
    ])));
    test('G1: deleting an owner (cascade) and clearing tables', () => faultMatrix('cascade', () => standard((g, a, c) => [() => a.deleteById(1), () => a.clearTable(), () => g.clearTable()])));
    test('G1: emptying the trash', () => faultMatrix('purgeTrash', () => standard((g, a, c) => [() => c.trash.empty(olderThan: Duration.zero)])));
    test('G1: FluentDb.clear', () => faultMatrix('clear', () => standard((g, a, c) => [() => FluentDb.clear()])));
    test('G1: cleanOrphans', () => faultMatrix('cleanOrphans', () => standard((g, a, c) => [() => FluentDb.cleanOrphans()])));
    test('G1: purgeArchivedColumns', () {
      return faultMatrix('purgeArchivedColumns', () {
        final DynamicProvider v1 = DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text'), FluentDbColumn.text('extra')]);
        final DynamicProvider v2 = DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text')]);
        late Scenario sc;
        sc = Scenario(
          providers: [v1],
          persistent: true,
          setup: (FluentTestDb d) async {
            await v1.saveAll([v1.row({'id': 1, 'text': 'a', 'extra': 'x'}), v1.row({'id': 2, 'text': 'b', 'extra': 'y'})]);
            await d.restart([v2]);
            sc.live = v2;
          },
          steps: [() => FluentDb.purgeArchivedColumns(olderThan: Duration.zero)],
        );
        return sc;
      });
    });
    test('G1 G13: reads (find, findById, count, relations) fail typed and change nothing', () => faultMatrix('reads', () => standard((g, a, c) => [
      () => g.find(),
      () => g.findById(1),
      () => g.count(),
      () => a.find(),
      () => c.trash.find(),
    ])));
    test('G1: consecutive writes and reads', () => faultMatrix('mixed', () => standard((g, a, c) => [
      () => g.save(Gadget(name: 'm1')),
      () => g.find(),
      () => g.save(Gadget(name: 'm2')),
      () => g.count(),
      () => g.deleteById(1),
    ])));

    test('G1: a merged batch of unawaited saves: every caller gets its own outcome, nothing is half written', () async {
      Scenario build() {
        final GadgetProvider g = GadgetProvider();
        return Scenario(providers: [g], steps: []);
      }

      // Dry run: statements of five unawaited saves.
      Scenario s = await prepare(build);
      final GadgetProvider dry = s.providers.first as GadgetProvider;
      final int from = faults.calls.length;
      await Future.wait([for (int i = 0; i < 5; i++) dry.save(Gadget(name: 'b$i'))]);
      final int total = faults.calls.skip(from).where(counted).length;
      expect(total, greaterThan(0));
      for (int n = 0; n < total; n++) {
        for (final FaultKind kind in FaultKind.values) {
          final String label = 'merged batch: call #$n of $total, ${kind.name}';
          s = await prepare(build);
          final GadgetProvider g = s.providers.first as GadgetProvider;
          faults.failNth(n, kind: kind, where: counted);
          final List<Settled> r = await waitAllSettled([for (int i = 0; i < 5; i++) g.save(Gadget(name: 'b$i'))], names: [for (int i = 0; i < 5; i++) 'save b$i']);
          expect(faults.injected, hasLength(1), reason: label);
          faults.heal();
          final List<String> stored = (await g.find()).map((e) => e.name).toList()..sort();
          final List<String> expected = [for (int i = 0; i < 5; i++) if (!r[i].failed) 'b$i'];
          expect(stored, expected, reason: 'G1: $label: stored rows are exactly the saves that succeeded');
          expect(r.where((e) => e.failed).length, lessThanOrEqualTo(1), reason: '$label: one fault fails at most the call it hit');
          if (r.any((e) => e.failed)) log.expectLogged('', level: FluentLogLevel.warning);
          await expectIntegrity(g.db, reason: label);
          await g.save(Gadget(name: 'after'));
          expect(await g.count(), expected.length + 1);
          expectIssuesHaveFixes(db.issues);
        }
      }
    });

    test('G1: a failing savepoint rolls back only itself when the app catches the error', () async {
      final Scenario s = await prepare(() => Scenario(providers: [GadgetProvider()], steps: []));
      final GadgetProvider g = s.providers.first as GadgetProvider;
      await FluentDb.transaction(() async {
        await g.save(Gadget(name: 'a'));
        faults.failNth(0, where: (c) => c.isWrite && c.matches('INSERT'));
        try {
          await FluentDb.transaction(() async {
            await g.save(Gadget(name: 'b'));
          });
          fail('the inner transaction must fail');
        } on FluentException catch (e) {
          expectTypedError(e);
        }
        await g.save(Gadget(name: 'c'));
      });
      expect((await g.find()).map((e) => e.name).toList()..sort(), ['a', 'c']);
      await expectIntegrity(g.db);
    });

    test('G1: the failure of a transaction body rolls everything back and the next transaction works', () async {
      final Scenario s = await prepare(() => Scenario(providers: [GadgetProvider()], steps: []));
      final GadgetProvider g = s.providers.first as GadgetProvider;
      await g.save(Gadget(name: 'keep'));
      await expectLater(
        FluentDb.transaction(() async {
          await g.save(Gadget(name: 'gone1'));
          await g.save(Gadget(name: 'gone2'));
          throw StateError('app error');
        }),
        throwsA(isA<StateError>()),
      );
      expect((await g.find()).map((e) => e.name), ['keep']);
      await FluentDb.transaction(() => g.save(Gadget(name: 'ok')));
      expect(await g.count(), 2);
      await expectIntegrity(g.db);
    });
  });

  group('G1 G19: the schema start', () {
    test('G1: a failure at every statement of a migration: the start fails typed, the file is unchanged, the next start succeeds', () async {
      DynamicProvider v1() => DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text'), FluentDbColumn.text('old_name')]);
      DynamicProvider v2() => DynamicProvider('notes', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('text'), FluentDbColumn.text('new_name').copyWith(oldName: 'old_name'), FluentDbColumn.integer('extra', defaultValue: 5)]);
      Future<(FluentTestDb, Snapshot, String)> start() async {
        faults.heal();
        faults.calls.clear();
        faults.injected.clear();
        final FluentTestDb d = FluentTestDb(persistent: true);
        db = d;
        final DynamicProvider p = v1();
        await d.open([p]);
        await p.saveAll([p.row({'id': 1, 'text': 'a', 'old_name': 'x'}), p.row({'id': 2, 'text': 'b', 'old_name': 'y'})]);
        await d.close(keepFile: true);
        final String path = '${await getDatabasesPath()}/${d.name}.db';
        final Database raw = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
        final Snapshot before = await snapshotOf(raw);
        await raw.close();
        return (d, before, path);
      }

      // Dry run to count the statements of the migrating start.
      var (FluentTestDb d, Snapshot before, String path) = await start();
      await db.close(keepFile: true);
      final FluentTestDb dryDb = FluentTestDb(name: d.name, persistent: true);
      db = dryDb;
      final int from = faults.calls.length;
      await dryDb.open([v2()]);
      final int total = faults.calls.skip(from).where(counted).length;
      final Database migrated = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      final Snapshot after = await snapshotOf(migrated);
      await migrated.close();
      expect(after['notes'], contains('new_name'), reason: 'the dry run migrated');
      await dryDb.close();
      expect(total, greaterThan(3));

      for (int n = 0; n < total; n++) {
        final FaultKind kind = FaultKind.values[n % FaultKind.values.length];
        final String label = 'migration: call #$n of $total, ${kind.name}';
        (d, before, path) = await start();
        faults.failNth(n, kind: kind, where: counted);
        Object? error;
        try {
          await d.open([v2()]).timeout(const Duration(seconds: 10));
        } catch (e) {
          error = e;
        }
        final bool injected = faults.injected.isNotEmpty;
        faults.heal();
        expect(injected, isTrue, reason: label);
        if (error != null) {
          expectTypedError(error, reason: label);
          final Database raw = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
          final Snapshot now = await snapshotOf(raw);
          expect(now.toString() == before.toString() || now.toString() == after.toString(), isTrue, reason: 'G1: $label: the failed start left the file as it was or fully migrated, never in between: $now');
          await expectIntegrity(raw, reason: label);
          await raw.close();
          log.expectLogged('');
        }
        // Without the fault the start succeeds and every row survives.
        final DynamicProvider p = v2();
        await d.open([p]);
        expect(await p.count(), 2, reason: '$label: the data is there after the next start');
        expect((await p.findById(1))?['new_name'], 'x', reason: '$label: the renamed column kept its value');
        await expectIntegrity(p.db, reason: label);
        await d.close();
      }
    });
  });

  group('G20: outside influence', () {
    Future<(GadgetProvider, String)> persistentDb({List<FluentProvider>? more}) async {
      db = FluentTestDb(persistent: true);
      final GadgetProvider g = GadgetProvider();
      await db.open([g, ...?more]);
      return (g, '${await getDatabasesPath()}/${db.name}.db');
    }

    test('G20: another connection holds the write lock (BEGIN EXCLUSIVE): the write reports typed, the data is intact, the library recovers when the lock is gone', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'before'));
      final Database other = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      await other.execute('PRAGMA busy_timeout = 0');
      await other.execute('BEGIN EXCLUSIVE');
      Object? error;
      try {
        await g.save(Gadget(name: 'blocked')).timeout(const Duration(seconds: 30));
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'the write cannot succeed while another connection holds the file');
      expectTypedError(error!);
      log.expectLogged('');
      await other.execute('ROLLBACK');
      await other.close();
      expect((await g.find()).map((e) => e.name), ['before'], reason: 'G20: committed data intact');
      await g.save(Gadget(name: 'after'));
      expect(await g.count(), 2, reason: 'G20: recovered once the lock is gone');
      await expectIntegrity(g.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G20: a read while another connection holds a write lock either answers or reports typed, then recovers', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'one'));
      final Database other = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      await other.execute('BEGIN IMMEDIATE');
      await other.insert('gadgets', {'name': 'uncommitted', 'qty': 1});
      Object? error;
      List<Gadget>? rows;
      try {
        rows = await g.find().timeout(const Duration(seconds: 30));
      } catch (e) {
        error = e;
      }
      if (error != null) {
        expectTypedError(error);
      } else {
        expect(rows!.map((e) => e.name), ['one'], reason: 'G20: never the uncommitted row of another connection');
      }
      await other.execute('ROLLBACK');
      await other.close();
      expect(await g.count(), 1);
      await expectIntegrity(g.db);
    });

    for (final FaultKind kind in FaultKind.values) {
      test('G20: ${kind.name} on every write: typed errors, committed data intact, recovers after the cause is gone', () async {
        final (GadgetProvider g, _) = await persistentDb();
        await g.saveAll([Gadget(name: 'a'), Gadget(name: 'b')]);
        faults.failWhere((c) => c.isWrite || c.isCommit, kind: kind);
        final List<Settled> r = await waitAllSettled([g.save(Gadget(name: 'x')), g.deleteById(1), g.updateById(2, {'qty': 5}), FluentDb.transaction(() => g.save(Gadget(name: 'y')))], names: ['save', 'delete', 'update', 'transaction']);
        expect(r.every((e) => e.failed), isTrue, reason: 'no write can succeed: ${r.map((e) => e.failed)}');
        expect((await g.find()).map((e) => e.name).toList()..sort(), ['a', 'b'], reason: 'G20: the committed state, reads still work');
        log.expectLogged('');
        faults.heal();
        await g.save(Gadget(name: 'c'));
        expect(await g.count(), 3);
        await expectIntegrity(g.db);
        expectIssuesHaveFixes(db.issues);
      });
    }

    test('G20: the file is deleted while the database is closed: the next start creates a fresh file, no crash', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'x'));
      await db.close(keepFile: true);
      for (final String suffix in const ['', '-wal', '-shm', '-journal']) {
        final File f = File('$path$suffix');
        if (f.existsSync()) await f.delete();
      }
      final GadgetProvider g2 = GadgetProvider();
      await db.open([g2]);
      expect(await g2.count(), 0, reason: 'a new, empty file; no error');
      await g2.save(Gadget(name: 'y'));
      expect(await g2.count(), 1);
      await expectIntegrity(g2.db);
    });

    test('G20: the file is replaced by garbage while closed: the start fails typed with a hint and does not touch the file', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'x'));
      await db.close(keepFile: true);
      await File(path).writeAsBytes(List<int>.generate(4096, (i) => (i * 7) % 251));
      for (final String suffix in const ['-wal', '-shm', '-journal']) {
        final File f = File('$path$suffix');
        if (f.existsSync()) await f.delete();
      }
      final List<int> garbage = await File(path).readAsBytes();
      Object? error;
      try {
        await db.open([GadgetProvider()]).timeout(const Duration(seconds: 20));
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'a file that is not a database cannot be opened');
      expectTypedError(error!);
      expect(await File(path).readAsBytes(), garbage, reason: 'G21: the file is left untouched (no silent reset)');
    });

    test('G20: the file is replaced by an older copy of itself while closed: opens intact with that copy\'s data', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'old'));
      await db.close(keepFile: true);
      final File copy = await File(path).copy('$path.bak');
      final GadgetProvider g2 = GadgetProvider();
      await db.open([g2]);
      await g2.save(Gadget(name: 'newer'));
      await db.close(keepFile: true);
      await copy.copy(path);
      for (final String suffix in const ['-wal', '-shm', '-journal']) {
        final File f = File('$path$suffix');
        if (f.existsSync()) await f.delete();
      }
      final GadgetProvider g3 = GadgetProvider();
      await db.open([g3]);
      expect((await g3.find()).map((e) => e.name), ['old']);
      await expectIntegrity(g3.db);
      await File('$path.bak').delete();
    });

    test('G20: DDL by another connection between calls (an extra column and an extra table): the library keeps working and the data is intact', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'a', qty: 1));
      final Database other = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      await other.execute('ALTER TABLE gadgets ADD COLUMN foreign_col TEXT');
      await other.execute('CREATE TABLE outsider (id INTEGER PRIMARY KEY, v TEXT)');
      await other.insert('outsider', {'id': 1, 'v': 'mine'});
      await other.close();
      Object? error;
      try {
        await g.save(Gadget(name: 'b', qty: 2));
        expect((await g.find(orderBy: 'name')).map((e) => e.name), ['a', 'b']);
      } catch (e) {
        error = e;
      }
      if (error != null) expectTypedError(error);
      await db.restart([GadgetProvider()]);
      final GadgetProvider g2 = db.isOpen ? GadgetProvider() : g;
      final Database raw = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      expect((await raw.rawQuery('SELECT v FROM outsider')).single['v'], 'mine', reason: 'G21: the foreign table is not dropped by the library');
      expect((await raw.rawQuery('SELECT name FROM gadgets ORDER BY name')).map((r) => r['name']).toList(), isNotEmpty);
      await expectIntegrity(raw);
      await raw.close();
      expect(g2.tableName, 'gadgets');
    });

    test('G20: writes by another connection between calls are seen by later reads', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'a'));
      final Database other = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      await other.insert('gadgets', {'name': 'from outside', 'qty': 3});
      await other.close();
      expect((await g.find(orderBy: 'name')).map((e) => e.name), ['a', 'from outside']);
      expect(await g.count(), 2);
      await g.deleteById(1);
      expect(await g.count(), 1);
      await expectIntegrity(g.db);
    });

    test('G20: the app is paused (queue paused) with writes waiting, then resumed: every call completes in order, no stuck queue', () async {
      final (GadgetProvider g, _) = await persistentDb();
      await FluentDb.pauseQueue();
      final List<Future<Object?>> calls = [for (int i = 0; i < 4; i++) g.save(Gadget(name: 'p$i'))];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      FluentDb.resumeQueue();
      await waitAllSettled(calls, names: [for (int i = 0; i < 4; i++) 'p$i']);
      expect((await g.find(orderBy: 'id')).map((e) => e.name), ['p0', 'p1', 'p2', 'p3']);
      await expectIntegrity(g.db);
    });

    test('G20: the process dies during a write and the next start works (die + reopen of the same file)', () async {
      final (GadgetProvider g, String path) = await persistentDb();
      await g.save(Gadget(name: 'committed'));
      await faults.die();
      await waitAllSettled([g.save(Gadget(name: 'lost')), FluentDb.transaction(() => g.save(Gadget(name: 'lost2')))], names: ['save', 'transaction']);
      faults.heal();
      await db.restart([GadgetProvider()]);
      final GadgetProvider g2 = GadgetProvider();
      await db.restart([g2]);
      expect((await g2.find()).map((e) => e.name), ['committed']);
      await expectIntegrity(g2.db);
      expect(File(path).existsSync(), isTrue);
    });

    test('G20: the clock moved back and forth around expiry / trash: nothing is lost that was not due, rows past their time go only when asked', () async {
      final MemoProvider p = MemoProvider();
      final MemoProvider t = MemoProvider('trashed_memos');
      db = FluentTestDb();
      await db.open([p, t]);
      await p.save(Memo(text: 'ttl', timeToLive: const Duration(hours: 1)));
      await p.save(Memo(text: 'forever'));
      final Memo n1 = Memo(text: 'trashed');
      await t.save(n1);
      await t.delete(n1);
      expect((await p.find()).map((Memo e) => e.text).toList()..sort(), ['forever', 'ttl']);
      db.clock.advance(const Duration(hours: 2));
      expect((await p.find()).map((Memo e) => e.text), ['forever'], reason: 'expired rows are hidden');
      db.clock.advance(const Duration(hours: -3)); // back before the save
      expect((await p.find()).map((Memo e) => e.text).toList()..sort(), ['forever', 'ttl'], reason: 'G20: the row was never deleted; clock back = visible again');
      db.clock.advance(const Duration(days: 400));
      expect((await p.find()).map((Memo e) => e.text), ['forever']);
      db.clock.advance(const Duration(days: -800));
      expect((await t.trash.find()).map((Memo e) => e.text), ['trashed'], reason: 'G21: the trash is kept while the clock is wrong');
      await db.settle();
      expect((await t.trash.find()).map((Memo e) => e.text), ['trashed']);
      expect((await t.withTrash.find()).length, 1);
      await expectIntegrity(p.db);
      expectIssuesHaveFixes(db.issues);
    });
  });

  group('G15: private', () {
    test('G15: no value and no path in the log or the errors, while errors are logged; showSqlArguments shows the values', () async {
      const String secret = 'S3CR3T-value-4711';
      const String user = 'jane.doe-private-user';
      final Directory dir = await Directory.systemTemp.createTemp('fluent_priv_');
      final String sub = '${dir.path}${Platform.pathSeparator}$user';
      await Directory(sub).create();
      final String previous = await databaseFactory.getDatabasesPath();
      await databaseFactory.setDatabasesPath(sub);
      try {
        db = FluentTestDb(name: 'private_db', persistent: true);
        final GadgetProvider g = GadgetProvider();
        final DynamicProvider accounts = DynamicProvider('accounts', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true)]);
        await db.open([g, accounts]);
        await g.save(Gadget(name: secret, qty: 1));
        await accounts.save(accounts.row({'id': 1, 'email': '$secret@example.com'}));

        Future<void> scenario() async {
          // Real SQLite errors that carry the statement arguments, injected failures, bad filters.
          await expectLater(accounts.save(accounts.row({'id': 2, 'email': '$secret@example.com'})), throwsA(isA<FluentConstraintException>()));
          faults.failWhere((c) => c.isWrite && c.matches('INSERT'), times: 1);
          await expectLater(g.save(Gadget(name: '$secret-2')), throwsA(isA<FluentException>()));
          faults.failWhere((c) => c.isRead, times: 1);
          await expectLater(g.find(where: FluentFilter.eq('name', secret)), throwsA(isA<FluentException>()));
          faults.heal();
          await expectLater(g.updateWhere(FluentFilter.eq('name', secret), {'nonexistent_col': secret}), throwsA(isA<FluentException>()));
          await expectLater(g.save(Gadget(id: 1, name: secret), conflictOn: ['no_such_column']), throwsA(isA<FluentException>()));
          await expectLater(g.find(where: FluentFilter.eq('no_such_column', secret)), throwsA(isA<FluentException>()));
        }

        await scenario();
        expect(log.records, isNotEmpty);
        log.expectLogged('', level: FluentLogLevel.warning);
        log.expectNoLeaks([secret, user, 'private_db.db', dir.path]);
        for (final FluentIssue i in db.issues) {
          for (final String text in [i.title, i.details ?? '', i.fix ?? '']) {
            expect(text.contains(secret), isFalse, reason: 'G15: issue ${i.kind.name} carries a value: $text');
            expect(text.contains(user), isFalse, reason: 'G15: issue ${i.kind.name} carries a path: $text');
          }
        }
        // The exceptions the caller gets carry no values or paths either (the original error is the cause).
        try {
          await accounts.save(accounts.row({'id': 3, 'email': '$secret@example.com'}));
          fail('unique violation expected');
        } on FluentException catch (e) {
          final String text = '${e.message} ${e.hint} $e';
          expect(text.contains(secret), isFalse, reason: 'G15: exception text: $text');
          expect(text.contains(user), isFalse, reason: 'G15: exception text: $text');
        }

        // With showSqlArguments the values may appear.
        log.records.clear();
        FluentDb.setupLogging(showSqlArguments: true);
        await scenario();
        expect(log.records.any((r) => LogWatch.textOf(r).contains(secret)), isTrue, reason: 'showSqlArguments: true shows the arguments');
      } finally {
        FluentDb.setupLogging(showSqlArguments: false);
        faults.heal();
        await db.close();
        await databaseFactory.setDatabasesPath(previous);
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold the file for a moment.
        }
      }
    });
  });

  group('G25: FluentDb.clear retries', () {
    test('G25: a one-off I/O error on one table is absorbed by the retry pass and still published once, with the table, the redacted error and a fix', () async {
      final GadgetProvider gadgets = GadgetProvider();
      final MemoProvider memos = MemoProvider();
      db = FluentTestDb();
      await db.open([gadgets, memos]);
      await gadgets.saveAll([Gadget(name: 'secret-one'), Gadget(name: 'secret-two')]);
      await memos.save(Memo(text: 'm'));
      log.records.clear();
      faults.failWhere((c) => c.isWrite && c.matches('DELETE FROM "gadgets"'), times: 1);

      await FluentDb.clear().timeout(const Duration(seconds: 10));
      await db.settle();

      expect(faults.injected, hasLength(1), reason: 'the fault fired once');
      expect(await gadgets.count(), 0);
      expect(await memos.count(), 0);
      final List<FluentIssue> retried = db.issues.where((i) => i.kind == FluentIssueKind.clearRetried).toList();
      expect(retried, hasLength(1), reason: 'G25: a retry that absorbed a real error is visible');
      expect(retried.single.type, FluentIssueType.warning);
      expect(retried.single.table, 'gadgets');
      expect(retried.single.fix, isNotEmpty);
      expect(retried.single.title, contains('gadgets'));
      expect(log.records.where((r) => r.issue?.kind == FluentIssueKind.clearRetried), hasLength(1), reason: 'G25: logged once');
      log.expectNoLeaks(const ['secret-one', 'secret-two']);
      expectIssuesHaveFixes(db.issues);
      await expectIntegrity(gadgets.db);
    });
  });
}
