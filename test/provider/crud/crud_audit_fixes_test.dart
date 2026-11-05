// Regression tests of the CRUD audit fixes (PC-1, CRUD-1..5, SYN-3, DOC-7).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

class Note extends FluentStorable with FluentSoftDeletable {
  Note({this.id, required this.title, this.score});

  final int? id;
  final String title;
  final int? score;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'score': score};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('title'), FluentDbColumn.integer('score')];
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(title: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, title: json['title'] as String, score: json['score'] as int?);
}

/// A table with a column the model does not carry.
class Wide extends FluentStorable {
  Wide({this.id, this.name});

  final int? id;
  final String? name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.integer('secret')];
}

class WideProvider extends FluentProvider<Wide> {
  @override
  String get tableName => 'wide';

  @override
  Wide get modelSample => Wide();

  @override
  Wide fromCacheJson(Map<String, dynamic> json) => Wide(id: json['id'] as int?, name: json['name'] as String?);
}

/// A syncable table.
class Item extends FluentStorable {
  Item({this.id, this.name});

  final int? id;
  final String? name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')];
}

class ItemProvider extends FluentProvider<Item> with FluentSyncable<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item();

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, name: json['name'] as String?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  late DynamicProvider posts;
  late NoteProvider notes;
  late WideProvider wide;
  late ItemProvider items;

  setUp(() async {
    db = FluentTestDb(name: 'crudfix_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);
    posts = DynamicProvider('posts', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('score'), FluentDbColumn.text('title')]);
    notes = NoteProvider();
    wide = WideProvider();
    items = ItemProvider();
    await db.open([users, posts, notes, wide, items]);
  });

  tearDown(() => db.close());

  DynamicModel user(Map<String, dynamic> values) => users.row(values);
  DynamicModel post(int id, int score, String title) => posts.row({'id': id, 'score': score, 'title': title});

  // The library hands the stored key to the model through injectRelationId (what a generated key uses too). A model
  // whose buildJson carries a key keeps answering with it until FluentStorable.primaryKeyValue prefers the injected
  // one, so these tests watch the injection itself (`metadata`).
  group('PC-1 conflictOn gives the model the key of the updated row', () {
    DynamicModel spy(Map<String, dynamic> values) => users.row(values);

    test('update path: the stored key is injected, the row is the matched one', () async {
      await users.save(user({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));
      final DynamicModel incoming = spy({'id': 9, 'email': 'ann@x', 'name': 'Ann 2'});
      final FluentSaveResult r = await users.save(incoming, conflictOn: ['email']);
      expect(r.updated, 1);
      expect(incoming.metadata, {'id': 7});
      expect(await users.exists(9), isFalse);
      expect((await users.findById(7))?['name'], 'Ann 2');
    });

    test('insert path: the caller key stays; a missing key is generated', () async {
      final DynamicModel withKey = spy({'id': 5, 'email': 'a@x', 'name': 'a'});
      final DynamicModel noKey = spy({'id': null, 'email': 'b@x', 'name': 'b'});
      final FluentSaveResult r = await users.saveAll([withKey, noKey], conflictOn: ['email']);
      expect(r.inserted, 2);
      expect(withKey.metadata, isEmpty);
      expect(noKey.metadata['id'], isNotNull);
    });

    test('insertOnly: a skipped model gets the stored key', () async {
      await users.save(user({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));
      final DynamicModel incoming = spy({'id': 9, 'email': 'ann@x', 'name': 'other'});
      final FluentSaveResult r = await users.save(incoming, strategy: FluentSaveStrategy.insertOnly, conflictOn: ['email']);
      expect(r.skipped, 1);
      expect(incoming.metadata, {'id': 7});
    });

    test('two models of one call matching one row both get its key', () async {
      await users.save(user({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));
      final DynamicModel a = spy({'id': 9, 'email': 'ann@x', 'name': 'a'});
      final DynamicModel b = spy({'id': 10, 'email': 'ann@x', 'name': 'b'});
      await users.saveAll([a, b], conflictOn: ['email']);
      expect(a.metadata, {'id': 7});
      expect(b.metadata, {'id': 7});
      expect(await users.count(), 1);
    });

    test('revive from the trash: the stored key is injected', () async {
      await notes.save(Note(id: 3, title: 'one', score: 1));
      await notes.deleteById(3);
      final Note again = Note(id: 8, title: 'one', score: 2);
      final FluentSaveResult r = await notes.save(again, conflictOn: ['title']);
      expect(r.restored, 1);
      expect(again.metadata, {'id': 3});
      expect(await notes.count(), 1);
      expect((await notes.findById(3))?.score, 2);
    });

    test('a plain save by key injects nothing when the key is already the one of the model', () async {
      final DynamicModel m = spy({'id': 4, 'email': 'k@x', 'name': 'k'});
      await users.save(m);
      await users.save(m);
      expect(m.metadata, isEmpty);
    });
  });

  group('CRUD-1 findPage refuses a column the model does not carry', () {
    test('before reading, also when everything fits on one page', () async {
      await wide.saveAll([Wide(id: 1, name: 'a')]);
      await expectLater(wide.findPage(orderBy: 'secret', limit: 10), throwsA(isA<FluentArgumentException>()));
      expect((await wide.findPage(orderBy: 'name', limit: 10)).items, hasLength(1));
    });

    test('a column buildJson writes still pages', () async {
      await notes.saveAll([Note(id: 1, title: 'a'), Note(id: 2, title: 'b')]);
      expect((await notes.findPage(orderBy: 'title', limit: 1)).next, isNotNull);
    });
  });

  group('CRUD-2 withTrash.pluck / countDistinct', () {
    test('see trashed rows', () async {
      await notes.saveAll([Note(id: 1, title: 'a', score: 1), Note(id: 2, title: 'b', score: 1), Note(id: 3, title: 'c', score: 2)]);
      await notes.deleteById(2);
      await notes.deleteById(3);
      expect(await notes.pluck<String>('title', orderBy: 'id'), ['a']);
      expect(await notes.withTrash.pluck<String>('title', orderBy: 'id'), ['a', 'b', 'c']);
      expect(await notes.countDistinct('score'), 1);
      expect(await notes.withTrash.countDistinct('score'), 2);
    });
  });

  group('CRUD-3 VACUUM behind comments', () {
    test('is detected after whitespace and comments', () async {
      final RegExp vacuum = RegExp(r'^(?:\s+|--[^\n]*(?:\n|$)|/\*.*?\*/)*VACUUM\b', caseSensitive: false, dotAll: true);
      // The statements run (the full-text rebuild is skipped for tables without a full-text index).
      for (final String sql in ['/* x */ VACUUM', '-- note\n  VACUUM', 'VACUUM', '  /* a */ -- b\n /* c */vacuum']) {
        expect(vacuum.hasMatch(sql), isTrue, reason: sql);
        await posts.execute(sql);
      }
      expect(vacuum.hasMatch('SELECT 1 /* VACUUM */'), isFalse);
    });
  });

  group('CRUD-4 negative limit / offset', () {
    test('are refused through the Future', () async {
      await posts.saveAll([post(1, 1, 'a'), post(2, 2, 'b')]);
      Future<void> refused(Future<Object?> Function() call) => expectLater(call(), throwsA(isA<FluentArgumentException>()));
      await refused(() => posts.find(limit: -1));
      await refused(() => posts.find(orderBy: 'id', offset: -3));
      await refused(() => posts.findAll(limit: -1));
      await refused(() => posts.findMaps(limit: -1));
      await refused(() => posts.findMaps(offset: -1));
      await refused(() => posts.pluck<int>('id', limit: -1));
      await refused(() => posts.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['score'], limit: -1));
      await refused(() => posts.search('x', limit: -1));
      expect(await posts.find(limit: 0), isEmpty);
      expect(await posts.find(orderBy: 'id', limit: 1, offset: 1), hasLength(1));
    });
  });

  group('CRUD-5 unordered hint names the called method', () {
    test('pluck', () async {
      final List<FluentIssue> issues = [];
      FluentLog.forgetIssues();
      await FluentLog.captureIssues(issues, () => posts.pluck<int>('id', limit: 5));
      final FluentIssue hint = issues.firstWhere((i) => i.kind == FluentIssueKind.unordered);
      expect(hint.code, contains('provider.pluck('));
      expect(hint.details, contains('pluck('));
    });
  });

  group('SYN-3 clearTable on a syncable table', () {
    test('warns about unsent rows and still empties the table', () async {
      final List<FluentIssue> issues = [];
      await items.saveAll([Item(id: 1, name: 'a'), Item(id: 2, name: 'b')]);
      await FluentLog.captureIssues(issues, () async {
        expect(await items.clearTable(), 2);
      });
      expect(await items.count(), 0);
      final Iterable<FluentIssue> warned = issues.where((i) => i.kind == FluentIssueKind.unsentChangesDiscarded);
      expect(warned, hasLength(1));
      expect(warned.single.fix, contains('syncWithServer'));
    });

    test('no warning for a table without sync', () async {
      final List<FluentIssue> issues = [];
      await posts.save(post(1, 1, 'a'));
      await FluentLog.captureIssues(issues, () => posts.clearTable());
      expect(issues.where((i) => i.kind == FluentIssueKind.unsentChangesDiscarded), isEmpty);
    });
  });

  group('DOC-7 errors of an unregistered provider come through the Future / Stream', () {
    test('every call', () async {
      final DynamicProvider ghost = DynamicProvider('ghost', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      final NoteProvider ghostNotes = NoteProvider();
      final DynamicModel row = ghost.row({'id': 1, 'name': 'x'});
      final Map<String, Future<Object?> Function()> calls = {
        'find': () => ghost.find(),
        'findById': () => ghost.findById(1),
        'findByIds': () => ghost.findByIds([1, 2]),
        'findFirst': () => ghost.findFirst(),
        'findAll': () => ghost.findAll(),
        'count': () => ghost.count(),
        'exists': () => ghost.exists(1),
        'existsWhere': () => ghost.existsWhere(FluentFilter.eq('id', 1)),
        'findMaps': () => ghost.findMaps(),
        'pluck': () => ghost.pluck<int>('id'),
        'search': () => ghost.search('x'),
        'findPage': () => ghost.findPage(),
        'aggregate': () => ghost.aggregate(values: {'n': const FluentAggregate.count()}),
        'sum': () => ghost.sum('id'),
        'countDistinct': () => ghost.countDistinct('id'),
        'rawQuery': () => ghost.rawQuery('SELECT 1'),
        'execute': () => ghost.execute('DELETE FROM ghost'),
        'save': () => ghost.save(row),
        'saveAll': () => ghost.saveAll([row]),
        'update': () => ghost.update(row),
        'updateById': () => ghost.updateById(1, {'name': 'y'}),
        'updateWhere': () => ghost.updateWhere(FluentFilter.eq('id', 1), {'name': 'y'}),
        'delete': () => ghost.delete(row),
        'deleteAll': () => ghost.deleteAll([row]),
        'deleteById': () => ghost.deleteById(1),
        'deleteWhere': () => ghost.deleteWhere(FluentFilter.eq('id', 1)),
        'clearExpired': () => ghost.clearExpired(),
        'clearTable': () => ghost.clearTable(),
        'trash.find': () => ghostNotes.trash.find(),
        'trash.count': () => ghostNotes.trash.count(),
        'trash.restoreById': () => ghostNotes.trash.restoreById(1),
        'trash.restoreWhere': () => ghostNotes.trash.restoreWhere(FluentFilter.eq('id', 1)),
        'trash.deleteForeverById': () => ghostNotes.trash.deleteForeverById(1),
        'trash.deleteForeverWhere': () => ghostNotes.trash.deleteForeverWhere(FluentFilter.eq('id', 1)),
        'trash.empty': () => ghostNotes.trash.empty(),
        'withTrash.find': () => ghostNotes.withTrash.find(),
        'withTrash.findById': () => ghostNotes.withTrash.findById(1),
        'withTrash.count': () => ghostNotes.withTrash.count(),
        'withTrash.pluck': () => ghostNotes.withTrash.pluck<int>('id'),
        'withTrash.aggregate': () => ghostNotes.withTrash.aggregate(values: {'n': const FluentAggregate.count()}),
      };
      final List<String> thrown = [];
      for (final MapEntry<String, Future<Object?> Function()> e in calls.entries) {
        Future<Object?> future;
        try {
          future = e.value();
        } catch (error) {
          thrown.add(e.key);
          continue;
        }
        await expectLater(future, throwsA(isA<FluentException>()), reason: e.key);
      }
      expect(thrown, isEmpty, reason: 'these calls threw synchronously');
    });

    test('streams', () async {
      final DynamicProvider ghost = DynamicProvider('ghost', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      final NoteProvider ghostNotes = NoteProvider();
      final Map<String, Stream<Object?> Function()> streams = {
        'watch': () => ghost.watch(),
        'watchById': () => ghost.watchById(1),
        'watchValue': () => ghost.watchValue(() => ghost.count()),
        'trash.watch': () => ghostNotes.trash.watch(),
        'withTrash.watch': () => ghostNotes.withTrash.watch(),
        'withTrash.watchById': () => ghostNotes.withTrash.watchById(1),
      };
      final List<String> thrown = [];
      for (final MapEntry<String, Stream<Object?> Function()> e in streams.entries) {
        Stream<Object?> stream;
        try {
          stream = e.value();
        } catch (error) {
          thrown.add(e.key);
          continue;
        }
        await expectLater(stream, emitsError(isA<FluentException>()), reason: e.key);
      }
      expect(thrown, isEmpty, reason: 'these streams threw synchronously');
    });
  });
}
