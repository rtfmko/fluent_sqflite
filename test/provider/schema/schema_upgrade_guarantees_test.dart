// G5: databases written by 1.x (real files of the 1.x code, tag archive/master-before-2.0), 2.0.0-dev.1 and 2.0.0-dev.2
// open with the current code without loss. Fixtures: test/fixtures/upgrade/*.db (+ *.dump.json = what was written);
// how they were made: test/fixtures/generator/upgrade_fixture_writer.dart.
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../fixtures/upgrade_models.dart';
import '../../helpers/guarantees.dart';
import '../../helpers/schema_guard.dart';

// The 1.x app's models, read by the current library.
class V1Author extends FluentStorable {
  V1Author({this.id, required this.name, this.born, this.rating = 0, this.active = true});

  final int? id;
  final String name;
  final DateTime? born;
  final double rating;
  final bool active;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'born': born, 'rating': rating, 'active': active};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.timestamp('born'), FluentDbColumn.real('rating'), FluentDbColumn.boolean('active')];
}

class V1Book extends FluentStorable with FluentSoftDeletable {
  V1Book({this.id, required this.title, this.pages = 0, this.authorId});

  final int? id;
  final String title;
  final int pages;
  final int? authorId;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'pages': pages, 'author_id': authorId};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.primary(), FluentDbColumn.text('title'), FluentDbColumn.integer('pages'), FluentDbColumn.integer('author_id')];
}

class V1AuthorProvider extends FluentProvider<V1Author> {
  @override
  V1Author get modelSample => V1Author(name: '');

  @override
  V1Author fromCacheJson(Map<String, dynamic> json) =>
      V1Author(id: json['id'] as int?, name: json['name'] as String, born: json['born'] as DateTime?, rating: (json['rating'] as num).toDouble(), active: json['active'] as bool);
}

class V1BookProvider extends FluentProvider<V1Book> {
  @override
  V1Book get modelSample => V1Book(title: '');

  @override
  V1Book fromCacheJson(Map<String, dynamic> json) => V1Book(id: json['id'] as int?, title: json['title'] as String, pages: json['pages'] as int, authorId: json['author_id'] as int?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'ug_${counter++}', persistent: true));
  tearDown(() => db.close());

  Future<void> install(String fixture) async {
    final String target = '${await getDatabasesPath()}/${db.name}.db';
    for (final String suffix in ['', '-wal', '-shm', '-journal']) {
      final File f = File('$target$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File('test/fixtures/upgrade/$fixture.db').copySync(target);
    // The app of the fixture ran on 2026-03-01: the clock is there, so the trash is not past its retention (documented purge).
    db.clock.set(DateTime.utc(2026, 3, 1, 14));
  }

  Future<void> expectDevFixture(String fixture) async {
    await install(fixture);
    final List<FluentProvider<FluentStorable>> p = fxProviders();
    await db.open(p);
    await db.settle();
    if (fixture == 'dev1') {
      // dev.1 wrote ISO text with a three-digit fraction ("...06.000Z"); the start pads it to six digits, so it must say so.
      final Database before = await openDatabase(File('test/fixtures/upgrade/dev1.db').absolute.path, readOnly: true, singleInstance: false);
      final bool storedShort = (await before.rawQuery('SELECT 1 FROM fx_events WHERE "at" GLOB ? LIMIT 1', ['*T??:??:??.???Z'])).isNotEmpty;
      await before.close();
      if (storedShort) {
        final FluentIssue adopted = db.issues.firstWhere((i) => i.kind == FluentIssueKind.storedFormatAdopted, orElse: () => fail('G25 / G26: the rewrite of the stored ISO text must be reported as an autoFix'));
        expect(adopted.type, FluentIssueType.autoFix);
        expect(adopted.fix, isNotEmpty);
      }
    }
    final FxBookProvider books = p[1] as FxBookProvider;
    final FxAuthorProvider authors = p[2] as FxAuthorProvider;
    final FxEventProvider events = p[3] as FxEventProvider;
    final FxTodoProvider todos = p[4] as FxTodoProvider;
    final FxCachedProvider cached = p[5] as FxCachedProvider;

    final List<FxAuthor> all = await authors.find(orderBy: 'id');
    expect(all.map((a) => a.name), ['Ann', 'Bob'], reason: 'G5: every row');
    final FxAuthor ann = all[0];
    expect(ann.born.isUtc, isTrue, reason: 'G5: the UTC flag survives');
    expect(ann.born, DateTime.utc(1980, 5, 17, 8, 30, 15, 123), reason: 'G5: the stored millisecond precision');
    expect([ann.rating, ann.active], [4.5, true]);
    expect([all[1].rating, all[1].active], [-0.125, false]);
    expect(all[1].born, DateTime.utc(1990, 1, 2, 3, 4, 5));
    expect(ann.books!.map((b) => b.title), ['First'], reason: 'G5: relations, the trashed book is hidden');
    expect(ann.tags!.map((t) => t.label), ['x', 'y']);
    expect(all[1].books!.map((b) => b.title), ['Third']);
    expect(all[1].tags!.map((t) => t.label), ['x']);

    expect((await books.trash.find()).map((b) => b.title), ['Second'], reason: 'G5: the trash state');
    expect((await books.withTrash.find(orderBy: 'id')).map((b) => b.id), [10, 11, 12]);
    final FxBook first = (await books.findById(10))!;
    expect(first.createdAt!.isAtSameMomentAs(DateTime.utc(2026, 3, 1, 12)), isTrue, reason: 'G5: stamps of FluentTimestamps (read as local times)');
    expect(first.updatedAt!.isAtSameMomentAs(DateTime.utc(2026, 3, 1, 12)), isTrue);
    expect((await books.trash.find()).single.deletedAt!.isAtSameMomentAs(DateTime.utc(2026, 3, 1, 13)), isTrue);
    await books.trash.restoreById(11);
    expect((await books.findById(11))?.title, 'Second', reason: 'G9: an old trashed row restores');
    expect((await authors.findById(1))!.books!.map((b) => b.id), [10, 11]);

    final List<FxEvent> ev = await events.find(orderBy: 'id');
    expect(ev.map((e) => e.at), [DateTime.utc(2026, 2, 3, 4, 5, 6, 7, 8), DateTime.utc(2026, 2, 3, 4, 5, 6)], reason: 'G5: iso8601 text, microseconds and UTC flag');
    expect(ev.every((e) => e.at.isUtc), isTrue);

    expect((await todos.find(orderBy: 'id')).map((t) => [t.id, t.text, t.done]), [
      [1, 'pushed then edited', true],
      [2, 'pending', false],
    ]);
    expect(await todos.pendingChanges(), 3, reason: 'G10 / G5: two edited rows and one deletion still wait for the server');
    final List<Object> sentRows = [];
    final List<Object> sentDeletes = [];
    final FluentSyncResult<FxTodo> r = await todos.syncWithServer(
      strategy: FluentSyncStrategy.push,
      onPush: (batch) async {
        sentRows.addAll([for (final FxTodo t in batch.changed) t.id!]);
        sentDeletes.addAll(batch.deletedKeys);
        return const FluentPushResult<FxTodo>.accepted();
      },
    );
    expect(r.isSuccess, isTrue, reason: r.errorMessage);
    expect(sentRows..sort((a, b) => (a as int).compareTo(b as int)), [1, 2]);
    expect(sentDeletes, [3], reason: 'G5: the tombstone written by the old version is pushed');
    expect(await todos.pendingChanges(), 0);

    expect((await cached.find(orderBy: 'id')).map((c) => c.value), ['fresh', 'forever'], reason: 'G5: expiry rows kept');

    // G31: the next start changes nothing; G19 intact; G26 fixes. The first start has made its one-time conversions.
    await db.settle();
    await db.close(keepFile: true);
    final Map<String, Object?> before = await dumpFile(db.name);
    final int seen = db.issues.length;
    await db.open(fxProviders());
    await db.settle();
    await db.close(keepFile: true);
    expect(dumpDiff(before, await dumpFile(db.name)), isNull, reason: 'G31: a second start with the same models changes nothing');
    expect([for (final FluentIssue i in db.issues.skip(seen)) if (i.type != FluentIssueType.hint) i.kind], isEmpty, reason: 'G5: conversions run once: nothing reported again');
    expectIssuesHaveFixes(db.issues);
    final Database raw = await openRaw(db.name);
    await expectIntegrity(raw);
    await raw.close();
  }

  test('G5: a database written by 2.0.0-dev.1 opens without loss (rows, values, relations, trash, iso8601, sync state, expiry)', () => expectDevFixture('dev1'));

  test('G5: a database written by 2.0.0-dev.2 opens without loss (rows, values, relations, trash, iso8601, sync state, expiry)', () => expectDevFixture('dev2'));

  test('G5 / G21: opening a dev fixture keeps every stored row of every table (the file only gains)', () async {
    for (final String f in ['dev1', 'dev2']) {
      await install(f);
      final Map<String, Object?> original = await dumpFile(db.name);
      await db.open(fxProviders());
      await db.settle();
      await db.close(keepFile: true);
      final Database raw = await openRaw(db.name);
      for (final MapEntry<String, Object?> e in original.entries) {
        if (!e.key.startsWith('table:') || e.key.startsWith('table:__fluent_')) continue;
        final String table = e.key.substring(6);
        final List<Map<String, Object?>> was = ((e.value! as Map<String, Object?>)['rows']! as List<Object?>).cast<Map<String, Object?>>();
        final List<Map<String, Object?>> now = await raw.query(table, orderBy: 'rowid');
        expect(now.length, was.length, reason: '$f: $table keeps its rows');
        for (int i = 0; i < was.length; i++) {
          for (final MapEntry<String, Object?> c in was[i].entries) {
            final Object? a = now[i][c.key];
            final Object? b = c.value;
            // ISO text of an iso8601 table may be rewritten in the current format: the same instant (G5: lossless conversion).
            final bool sameInstant = a is String && b is String && DateTime.tryParse(a) != null && DateTime.tryParse(b) != null && DateTime.parse(a) == DateTime.parse(b);
            if (!sameInstant) expect(normValue(a), normValue(b), reason: '$f: $table row $i column ${c.key} is stored exactly as written');
          }
        }
      }
      await raw.close();
      await db.close();
    }
  });

  group('a database written by the real 1.x code', () {
    List<FluentProvider<FluentStorable>> providers() => [V1AuthorProvider(), V1BookProvider()];

    test('G5: tables named by the 1.x rule are adopted, every row and value survives, the trash state and the format conversions are kept', () async {
      await install('v1');
      final List<FluentProvider<FluentStorable>> p = providers();
      await db.open(p);
      final V1AuthorProvider authors = p[0] as V1AuthorProvider;
      final V1BookProvider books = p[1] as V1BookProvider;
      expect(authors.tableName, 'v1_author');
      final Database probe = await openRaw(db.name);
      expect(await tableNames(probe), containsAll(['v1_author', 'v1_book']), reason: 'G5: the 1.x names v_1_* are renamed');
      expect(await tableNames(probe), isNot(contains('v_1_author')));
      await probe.close();
      expect(db.issues.map((i) => i.kind), contains(FluentIssueKind.legacyNameAdopted), reason: 'G5: reported');

      final List<V1Author> a = await authors.find(orderBy: 'id');
      expect(a.map((x) => x.name), ['Ann', 'Bob']);
      expect(a[0].born!.isAtSameMomentAs(DateTime.utc(1980, 5, 17, 8, 30)), isTrue, reason: 'G6 / G5: the 1.x timestamp is the same instant (1.x stored it as a local time)');
      expect(a[0].born!.isUtc, isFalse, reason: 'G6: the flag the 1.x metadata recorded');
      expect(a[1].born, isNull);
      expect([a[0].rating, a[0].active, a[1].rating, a[1].active], [4.5, true, 3.25, false]);
      expect((await books.find(orderBy: 'id')).map((b) => [b.id, b.title, b.pages, b.authorId]), [
        [1, 'First', 100, 1],
        [3, 'Third', 7, 2],
      ], reason: 'G5: visible rows; the trashed one is hidden');
      final List<V1Book> trashed = await books.trash.find();
      expect(trashed.map((b) => b.title), ['Second'], reason: 'G5 / G9: the trash state of the 1.x row');
      expect(trashed.single.deletedAt, isNotNull);
      await books.trash.restoreById(2);
      expect((await books.findById(2))?.title, 'Second');

      await db.settle();
      await db.close(keepFile: true);
      final Map<String, Object?> before = await dumpFile(db.name);
      final int seen = db.issues.length;
      await db.open(providers());
      await db.settle();
      await db.close(keepFile: true);
      expect(dumpDiff(before, await dumpFile(db.name)), isNull, reason: 'G31: adoption runs once');
      expect([for (final FluentIssue i in db.issues.skip(seen)) if (i.type != FluentIssueType.hint) i.kind], isEmpty);
      expectIssuesHaveFixes(db.issues);
      final Database raw = await openRaw(db.name);
      await expectIntegrity(raw);
      await raw.close();
    });

    test('G5 / G21: no stored value of the 1.x file is lost (renamed tables hold every old cell)', () async {
      await install('v1');
      final Map<String, Object?> original = await dumpFile(db.name);
      await db.open(providers());
      await db.settle();
      await db.close(keepFile: true);
      final Database raw = await openRaw(db.name);
      for (final String old in ['v_1_author', 'v_1_book']) {
        final List<Map<String, Object?>> was = (((original['table:$old']! as Map<String, Object?>)['rows']!) as List<Object?>).cast<Map<String, Object?>>();
        final List<Map<String, Object?>> now = await raw.query(old.replaceFirst('v_1_', 'v1_'), orderBy: 'id');
        expect(now.length, was.length);
        for (int i = 0; i < was.length; i++) {
          for (final MapEntry<String, Object?> c in was[i].entries) {
            if (c.key == '_fs_metadata' || c.key == 'deleted_at') continue; // converted forms, checked through the models above
            expect(normValue(now[i][c.key]), normValue(c.value), reason: '$old row $i column ${c.key}');
          }
        }
        expect(await columnNames(raw, old.replaceFirst('v_1_', 'v1_')), containsAll(was.first.keys.where((k) => k != '_fs_metadata')));
      }
      await raw.close();
    });
  });
}
