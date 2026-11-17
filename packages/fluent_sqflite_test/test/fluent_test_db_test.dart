// The test helpers themselves: open / restart / close, the clock, settle, issues.
import 'dart:async';
import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
// ignore: implementation_imports
import 'package:fluent_sqflite/src/internal.dart' show FluentLog;
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Note extends FluentStorable with FluentSoftDeletable {
  Note({this.id, required this.text});

  final int? id;
  final String text;

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

  test('a database in memory by default; a second open closes the first', () async {
    final NoteProvider notes = NoteProvider();
    final FluentTestDb first = FluentTestDb();
    await first.open([notes]);
    await notes.save(Note(text: 'a'));
    expect(await notes.count(), 1);
    expect(File('${await getDatabasesPath()}/${first.name}.db').existsSync(), isFalse);

    final FluentTestDb second = FluentTestDb();
    final NoteProvider fresh = NoteProvider();
    await second.open([fresh]);
    expect(first.isOpen, isFalse);
    expect(await fresh.count(), 0);
    await second.close();
    await second.close(); // twice is fine
  });

  test('restart keeps a persistent file; close removes it', () async {
    final FluentTestDb db = FluentTestDb(persistent: true);
    final NoteProvider notes = NoteProvider();
    await db.open([notes]);
    await notes.save(Note(text: 'kept'));
    final NoteProvider again = NoteProvider();
    await db.restart([again]);
    expect((await again.findAll()).single.text, 'kept');
    final String path = '${await getDatabasesPath()}/${db.name}.db';
    expect(File(path).existsSync(), isTrue);
    await db.close();
    expect(File(path).existsSync(), isFalse);
  });

  test('the clock moves trash retention and stamps; close puts it back', () async {
    final FluentTestDb db = FluentTestDb();
    final NoteProvider notes = NoteProvider();
    await db.open([notes]);
    expect(db.clock.isMoved, isFalse);

    final Note note = Note(text: 'old');
    await notes.save(note);
    await notes.delete(note);
    expect(await notes.trash.empty(), 0, reason: 'deleted just now');
    db.clock.advance(const Duration(days: 8));
    await db.settle();
    expect(await notes.trash.count(), 0, reason: 'older than the default retention of 7 days: the purge timer ran');

    db.clock.set(DateTime(2030));
    expect(db.clock.now, DateTime(2030));
    db.clock.advance(const Duration(hours: 1));
    expect(db.clock.now, DateTime(2030, 1, 1, 1), reason: 'a stopped clock stays stopped');

    await db.close();
    expect(DateTime.now().difference(db.clock.now).abs(), lessThan(const Duration(seconds: 5)));
  });

  test('settle waits for watch streams instead of a fixed delay', () async {
    final FluentTestDb db = FluentTestDb();
    final NoteProvider notes = NoteProvider();
    await db.open([notes]);
    final List<int> sizes = [];
    final StreamSubscription<List<Note>> sub = notes.watch().listen((rows) => sizes.add(rows.length));
    await db.settle();
    await notes.saveAll([Note(text: 'a'), Note(text: 'b')]);
    await db.settle();
    expect(sizes, [0, 2]);
    await sub.cancel();
    await db.close();
  });

  test('issues are collected per database; failOnWarnings fails close', () async {
    final FluentTestDb db = FluentTestDb(failOnWarnings: true);
    await db.open([NoteProvider()]);
    await FluentDb.syncWithServer<Note>(); // not a FluentSyncable provider: a warning
    expect(db.warnings, isNotEmpty);
    await expectLater(db.close(), throwsA(isA<TestFailure>().having((f) => f.message, 'message', contains('warning'))));

    final FluentTestDb quiet = FluentTestDb();
    await quiet.open([NoteProvider()]);
    expect(quiet.warnings, isEmpty, reason: 'issues start afresh for every database');
    await quiet.close();
  });

  test('plan shows what a new version would change, without changing it', () async {
    final FluentTestDb db = FluentTestDb(persistent: true);
    await db.open([NoteProvider()]);

    final FluentMigrationPlan plan = await db.plan([NoteProvider()]);
    expect(plan.isEmpty, isTrue, reason: 'the same models change nothing');
    expect(plan.losesData, isFalse);
    expect(db.isOpen, isFalse, reason: 'plan closes the database first');
    await db.close();
  });

  test('DOC-8: plan of another test database leaves the open one open and usable', () async {
    final FluentTestDb open = FluentTestDb();
    final NoteProvider notes = NoteProvider();
    await open.open([notes]);
    await notes.save(Note(text: 'kept'));

    final FluentTestDb other = FluentTestDb(persistent: true);
    final FluentMigrationPlan plan = await other.plan([NoteProvider()]);
    expect(plan.isEmpty, isFalse, reason: 'the other file does not exist yet');
    expect(open.isOpen, isTrue, reason: 'an in-memory database would lose its rows if the plan closed it');
    expect((await notes.findAll()).single.text, 'kept');
    await open.close();
    await other.close();
  });

  test('restart needs a persistent database', () async {
    final FluentTestDb db = FluentTestDb();
    await db.open([NoteProvider()]);
    await expectLater(db.restart([NoteProvider()]), throwsA(isA<TestFailure>()));
    await db.close();
  });

  group('logging is reset after every test', () {
    final List<FluentLogRecord> records = [];

    test('a test sets a sink, showSqlArguments and a mute', () {
      FluentDb.setupLogging(enabled: true, console: false, onRecord: records.add, showSqlArguments: true, mute: {'x:*'}, level: FluentLogLevel.debug);
      FluentLog.info('inside the first test');
      expect(records, hasLength(1));
    });

    test('the next test starts with the defaults: no sink, no mute, arguments hidden, logging off', () {
      expect(FluentLog.showSqlArguments, isFalse);
      expect(FluentLog.mute, isEmpty);
      expect(FluentLog.isEnabled, isFalse);
      FluentLog.info('after the reset');
      expect(records, hasLength(1), reason: 'the sink of the first test is gone');
    });
  });
}
