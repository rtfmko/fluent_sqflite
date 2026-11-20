// Per-table row flags: reads skip the expiry condition while no row has an expiry (and hide expired rows as soon as
// one may), saves skip the trash lookup while the trash is empty (and revive trashed keys as soon as it may not be).
//
// `expiry IS NULL OR expiry > now` is served by no index: a `count()` of a table that never used timeToLive read every
// row (the partial expiry index only holds rows with an expiry). The table's flag is set at start (one probe of that
// index), by every save of a row with timeToLive, and by raw SQL.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';

class Note extends FluentStorable {
  Note({this.id, required this.text, this.ttl});

  final int? id;
  final String text;
  final Duration? ttl;

  @override
  Duration? get timeToLive => ttl;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late NoteProvider notes;

  setUp(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'expiry_check_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    notes = NoteProvider();
    await db.open([notes]);
  });

  tearDown(() async {
    await db.close();
    counter.uninstall();
  });

  bool readsCheckExpiry() => counter.statements.any((s) => s.startsWith('query') && s.contains('expiry_date'));

  test('a table whose rows never had an expiry reads without the expiry condition', () async {
    await notes.saveAll([for (int i = 1; i <= 20; i++) Note(id: i, text: 'n$i')]);
    counter.reset();
    expect(await notes.count(), 20);
    expect((await notes.findAll()).length, 20);
    expect(readsCheckExpiry(), isFalse, reason: counter.statements.join('\n'));
  });

  test('a save with timeToLive brings the check back: the row hides once it expired', () async {
    await notes.save(Note(id: 1, text: 'stays'));
    await notes.save(Note(id: 2, text: 'cache', ttl: const Duration(minutes: 5)));
    counter.reset();
    expect(await notes.count(), 2);
    expect(readsCheckExpiry(), isTrue);
    db.clock.advance(const Duration(minutes: 6));
    expect(await notes.count(), 1);
    expect((await notes.findAll()).single.text, 'stays');
  });

  test('rows with an expiry from an earlier run are found at start', () async {
    await notes.save(Note(id: 1, text: 'cache', ttl: const Duration(minutes: 5)));
    await notes.save(Note(id: 2, text: 'stays'));
    notes = NoteProvider();
    await db.restart([notes]);
    db.clock.advance(const Duration(minutes: 6));
    expect(await notes.count(), 1);
  });

  test('raw SQL that writes an expiry brings the check back', () async {
    await notes.saveAll([Note(id: 1, text: 'a'), Note(id: 2, text: 'b')]);
    expect(await notes.count(), 2);
    await notes.execute('UPDATE "notes" SET "expiry_date" = 1 WHERE "id" = 1');
    expect(await notes.count(), 1, reason: 'the row expired in 1970');
  });

  group('trash lookup of saves', () {
    late CommentProvider comments;

    Future<void> openComments() async {
      await db.close();
      db = FluentTestDb(name: 'trash_flag_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      comments = relationProviders().whereType<CommentProvider>().single;
      await db.open([comments]);
    }

    bool looksInTrash() => counter.statements.any((s) => s.contains('"deleted_at" IS NOT NULL'));

    test('saves on a table with an empty trash do not look for their keys in it', () async {
      await openComments();
      await comments.save(Comment(id: 1, text: 'a'));
      counter.reset();
      await comments.save(Comment(id: 1, text: 'b'));
      await comments.save(Comment(id: 2, text: 'c'));
      expect(looksInTrash(), isFalse, reason: counter.statements.join('\n'));
      expect((await comments.findById(1))?.text, 'b');
    });

    test('after a soft delete a save of the deleted key revives it', () async {
      await openComments();
      await comments.saveAll([Comment(id: 1, text: 'a'), Comment(id: 2, text: 'b')]);
      await comments.deleteById(1);
      final FluentSaveResult r = await comments.save(Comment(id: 1, text: 'back'));
      expect(r.restored, 1);
      expect((await comments.findById(1))?.text, 'back');
      expect(await comments.trash.count(), 0);
    });

    test('rows in the trash from an earlier run are found at start', () async {
      await openComments();
      await comments.saveAll([Comment(id: 1, text: 'a'), Comment(id: 2, text: 'b')]);
      await comments.deleteById(2);
      comments = relationProviders().whereType<CommentProvider>().single;
      await db.restart([comments]);
      expect((await comments.save(Comment(id: 2, text: 'back'))).restored, 1);
      expect(await comments.count(), 2);
    });

    test('raw SQL that moves a row into the trash brings the lookup back', () async {
      await openComments();
      await comments.saveAll([Comment(id: 1, text: 'a'), Comment(id: 2, text: 'b')]);
      await comments.execute('UPDATE "comments" SET "deleted_at" = 5 WHERE "id" = 1');
      expect((await comments.save(Comment(id: 1, text: 'back'))).restored, 1);
      expect(await comments.count(), 2);
    });
  });
}
