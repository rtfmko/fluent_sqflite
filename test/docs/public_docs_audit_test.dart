// Audit (public surface, documentation, test helpers). Documentation checks read the markdown files from the package
// root (flutter test runs there); behaviour checks use the README model and the fluent_sqflite_test helpers.
// ignore_for_file: avoid_redundant_argument_values
import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

// --- README quick start (copied as written) -----------------------------------------------------------------------

class Note extends FluentStorable with FluentTimestamps, FluentSoftDeletable {
  Note({this.id, required this.title, this.done = false});

  final int? id;
  final String title;
  final bool done;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'done': done};

  static Note fromJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, title: json['title'] as String, done: json['done'] as bool);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(title: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note.fromJson(json);
}

// --- helpers --------------------------------------------------------------------------------------------------------

/// The markdown files of the guide: README, doc/ and skills/ (not the generated copies of the migration table).
List<File> _markdownFiles() {
  final List<File> files = [File('README.md'), File('packages/fluent_sqflite_test/README.md')];
  for (final String dir in ['doc', 'skills']) {
    for (final FileSystemEntity e in Directory(dir).listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.md')) files.add(e);
    }
  }
  return files;
}

/// The same text with the copies of the migration table left out (they list removed names on purpose).
bool _isMigrationTable(File f) => f.path.replaceAll('\\', '/').endsWith('migrations.md');

/// GitHub's anchor for a heading.
String _slug(String heading) => heading.trim().toLowerCase().replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s'), '-');

Set<String> _anchorsOf(File f) {
  final Set<String> anchors = {};
  bool fenced = false;
  for (final String line in f.readAsLinesSync()) {
    if (line.trimLeft().startsWith('```')) fenced = !fenced;
    final RegExpMatch? h = fenced ? null : RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
    if (h != null) anchors.add(_slug(h.group(1)!));
  }
  return anchors;
}

/// The source of the library and of the helper / benchmark packages (the names the guides may cite).
String _libSource() {
  final StringBuffer sb = StringBuffer();
  for (final String dir in ['lib', 'packages/fluent_sqflite_test/lib', 'packages/fluent_sqflite_benchmark/lib']) {
    for (final FileSystemEntity e in Directory(dir).listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) sb.writeln(e.readAsStringSync());
    }
  }
  return sb.toString();
}

void main() {
  setUpFluentTests();

  group('documentation matches the code', () {
    test('every #anchor link in README, doc/ and skills/ points to an existing heading', () {
      final List<String> broken = [];
      for (final File f in _markdownFiles()) {
        for (final RegExpMatch m in RegExp(r'\]\(([^()\s#]*)#([^()\s]+)\)').allMatches(f.readAsStringSync())) {
          final String path = m.group(1)!;
          final String anchor = m.group(2)!;
          final File target = path.isEmpty ? f : File('${f.parent.path}/$path');
          if (!target.existsSync()) {
            broken.add('${f.path}: missing file $path');
            continue;
          }
          if (!_anchorsOf(target).contains(anchor)) broken.add('${f.path}: "#$anchor" is not a heading of ${target.path}');
        }
      }
      expect(broken, isEmpty, reason: broken.join('\n'));
    });

    test('every Type.member named in README, doc/, skills/ and llms.txt exists in lib/', () {
      final String lib = _libSource();
      final List<File> docs = [..._markdownFiles().where((f) => !_isMigrationTable(f)), File('llms.txt')];
      final RegExp call = RegExp(r'\b(Fluent\w+|ExecutionPolicy|SQLiteCacheSize|SQLiteJournalMode|SQLiteSynchronous)\.([a-zA-Z_]\w*)');
      final Set<String> missing = {};
      for (final File f in docs) {
        for (final RegExpMatch m in call.allMatches(f.readAsStringSync())) {
          final String member = m.group(2)!;
          if (!RegExp('\\b$member\\b').hasMatch(lib)) missing.add('${m.group(1)}.$member (in ${f.path})');
        }
      }
      expect(missing, isEmpty, reason: missing.join('\n'));
    });

    test('migrations.md: a row naming FluentDb.report() as old says it is still the 2.0 report', () {
      final List<String> rows = File('doc/ai/migrations.md')
          .readAsLinesSync()
          .where((l) => l.startsWith('| `') && l.split('|').length > 2 && l.split('|')[1].contains('FluentDb.report()'))
          .toList();
      for (final String row in rows) {
        expect(row, contains('in 2.0 `FluentDb.report()` is'), reason: 'report() exists in 2.0: $row');
      }
    });

    test('migrations.md: every FluentDb.* named as a new name exists in lib/', () {
      final String lib = _libSource();
      final List<String> missing = [];
      for (final String l in File('doc/ai/migrations.md').readAsLinesSync()) {
        final List<String> cells = l.split('|');
        if (!l.startsWith('| `') || cells.length < 3) continue;
        for (final RegExpMatch m in RegExp(r'FluentDb\.(\w+)\(').allMatches(cells[2])) {
          if (!RegExp(r'static [^;{=]*\b' + m.group(1)! + r'\b[<(]').hasMatch(lib)) missing.add(m.group(0)!);
        }
      }
      expect(missing, isEmpty, reason: 'named as new names but not in lib/');
    });

    test('migrations.md: the new names for FluentDataEvent helpers exist on FluentRemoteEvent', () {
      final String event = File('lib/src/models/remote/fluent_remote_event.dart').readAsStringSync();
      final String row = File('doc/ai/migrations.md').readAsLinesSync().firstWhere((l) => l.startsWith('| `FluentDataEvent` helpers'));
      final List<String> missing = [
        for (final RegExpMatch m in RegExp(r'`(?:e\.|!e\.)?(\w+)`').allMatches(row.split('|')[2]))
          if (m.group(1) != 'FluentRemoteEvent' && !RegExp(r'(get|final [\w<>?]+) ' + m.group(1)! + r'\b').hasMatch(event)) m.group(1)!,
      ];
      expect(missing, isEmpty, reason: 'migrations.md maps old helpers to: ${missing.join(', ')}');
    });

    test('models.md: every link into writing.md resolves to a heading', () {
      final Set<String> anchors = _anchorsOf(File('doc/writing.md'));
      final List<String> broken = [
        for (final RegExpMatch m in RegExp(r'writing\.md#([\w-]+)').allMatches(File('doc/models.md').readAsStringSync()))
          if (!anchors.contains(m.group(1))) m.group(1)!,
      ];
      expect(broken, isEmpty);
    });
  });

  group('public surface', () {
    test('FluentFilter does not expose its internal fields (deferred conditions are hidden from the public API)', () {
      final String src = File('lib/src/utils/fluent_filter.dart').readAsStringSync();
      final RegExpMatch? publicDeferred = RegExp(r'^\s+final List<FluentDeferredCondition> deferred;', multiLine: true).firstMatch(src);
      final RegExpMatch? publicMarker = RegExp(r'^\s+static final RegExp relatedMarker', multiLine: true).firstMatch(src);
      expect(publicDeferred, isNull, reason: 'public field "deferred" has the hidden type FluentDeferredCondition');
      expect(publicMarker, isNull, reason: 'public static "relatedMarker" is a parser marker of the library');
    });
  });

  group('behaviour the guides promise', () {
    late FluentTestDb db;
    late NoteProvider notes;

    setUp(() async {
      notes = NoteProvider();
      db = FluentTestDb();
      await db.open([notes]);
    });

    tearDown(() => db.close());

    test('README quick start: save, find, update, soft delete, restore, watch and keyset paging', () async {
      final FluentSaveResult saved = await notes.save(Note(title: 'Buy milk'));
      expect(saved.inserted, 1);
      final List<Note> open = await notes.find(where: FluentFilter.eq('done', false), orderBy: 'created_at DESC');
      expect(open.single.title, 'Buy milk');
      expect(await notes.updateById(1, {'done': true}), 1);
      await notes.deleteById(1);
      expect(await notes.find(), isEmpty);
      expect((await notes.trash.find()).single.title, 'Buy milk');
      expect(await notes.trash.restoreById(1), 1);

      for (int i = 0; i < 5; i++) {
        await notes.save(Note(title: 'n$i'));
      }
      final Set<Object?> seen = {};
      FluentPage<Note> page = await notes.findPage(orderBy: 'created_at', descending: true, limit: 2);
      seen.addAll(page.items.map((n) => n.id));
      while (page.hasMore) {
        page = await notes.findPage(orderBy: 'created_at', descending: true, limit: 2, after: page.next);
        seen.addAll(page.items.map((n) => n.id));
      }
      expect(seen, hasLength(6));
    });

    test('findByIds returns the models in the order of the ids (reading.md)', () async {
      for (int i = 0; i < 3; i++) {
        await notes.save(Note(title: 'n$i'));
      }
      final List<Note> picked = await notes.findByIds([3, 1, 2]);
      expect(picked.map((n) => n.id), [3, 1, 2]);
    });

    test('a cursor kept as text (FluentCursor.decode) continues the same page (reading.md)', () async {
      for (int i = 0; i < 5; i++) {
        await notes.save(Note(title: 'n$i'));
      }
      final FluentPage<Note> first = await notes.findPage(orderBy: 'id', limit: 2);
      final FluentCursor cursor = first.next!;
      final FluentCursor decoded = FluentCursor.decode(cursor.encode());
      final FluentPage<Note> direct = await notes.findPage(orderBy: 'id', limit: 2, after: cursor);
      final FluentPage<Note> viaText = await notes.findPage(orderBy: 'id', limit: 2, after: decoded);
      expect(viaText.items.map((n) => n.id), direct.items.map((n) => n.id));
    });

    test('contains() matches % and _ literally (reading.md)', () async {
      await notes.save(Note(title: 'Sale 50% off'));
      await notes.save(Note(title: 'Sale 500 off'));
      final List<Note> hit = await notes.find(where: FluentFilter.contains('title', '50%'));
      expect(hit.map((n) => n.title), ['Sale 50% off']);
    });

    test('rawQuery refuses SQL that writes with FluentArgumentException (reading.md)', () async {
      await notes.save(Note(title: 'a'));
      await expectLater(notes.rawQuery('DELETE FROM notes'), throwsA(isA<FluentArgumentException>()));
      expect(await notes.count(), 1);
    });

    test('a call on an unregistered provider reports through its Future, not synchronously (errors-and-logging.md)', () async {
      final NoteProvider orphan = NoteProvider();
      late Future<List<Note>> pending;
      expect(() => pending = orphan.find(), returnsNormally);
      await expectLater(pending, throwsA(isA<FluentException>()));
    });

    test('updateById refuses library columns such as deleted_at (writing.md, skills writes)', () async {
      await notes.save(Note(title: 'a'));
      await expectLater(notes.updateById(1, {'deleted_at': 1}), throwsA(isA<FluentArgumentException>()));
    });

    test('updateOnly skips a missing row; upsert of a trashed key restores it (writing.md)', () async {
      final FluentSaveResult missing = await notes.save(Note(id: 99, title: 'x'), strategy: FluentSaveStrategy.updateOnly);
      expect(missing.skipped, 1);
      expect(await notes.count(), 0);

      final Note kept = Note(title: 'kept');
      await notes.save(kept);
      await notes.delete(kept);
      final FluentSaveResult back = await notes.save(Note(id: kept.primaryKeyValue as int?, title: 'kept again'));
      expect(back.restored, 1);
      expect((await notes.findAll()).single.title, 'kept again');
    });

    test('a soft-deleted note is still in the trash after 1 day and emptied after 8 days (testing.md)', () async {
      final Note note = Note(title: 'a');
      await notes.save(note);
      await notes.delete(note);
      db.clock.advance(const Duration(days: 1));
      expect(await notes.trash.count(), 1);
      db.clock.advance(const Duration(days: 7));
      expect(await notes.trash.empty(), 1);
    });

    test('a database name with a dash fails with invalidDatabaseName (error-codes.md)', () async {
      final FluentTestDb bad = FluentTestDb(name: 'my-db');
      await expectLater(
        bad.open([NoteProvider()]),
        throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.invalidDatabaseName)),
      );
      await bad.close();
    });
  });

  group('fluent_sqflite_test helpers', () {
    test('close() puts the clock back and may be called twice', () async {
      final FluentTestDb db = FluentTestDb();
      await db.open([NoteProvider()]);
      db.clock.advance(const Duration(days: 40));
      expect(db.clock.isMoved, isTrue);
      await db.close();
      expect(db.clock.isMoved, isFalse);
      expect(db.clock.now.difference(DateTime.now()).inSeconds.abs(), lessThan(5));
      await db.close();
    });

    test('restart() needs persistent: true', () async {
      final FluentTestDb db = FluentTestDb();
      await db.open([NoteProvider()]);
      await expectLater(db.restart([NoteProvider()]), throwsA(isA<TestFailure>()));
      await db.close();
    });

    test('plan() of a second database leaves the open one usable (testing helper, suspected)', () async {
      final FluentTestDb open = FluentTestDb();
      final NoteProvider notes = NoteProvider();
      await open.open([notes]);
      await notes.save(Note(title: 'a'));

      final FluentTestDb other = FluentTestDb(persistent: true);
      final FluentMigrationPlan plan = await other.plan([NoteProvider()]);
      expect(plan.losesData, isFalse);

      expect(open.isOpen, isTrue);
      expect(await notes.count(), 1);
      await open.close();
    });
  });
}
