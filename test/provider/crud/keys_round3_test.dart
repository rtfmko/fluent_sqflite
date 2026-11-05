// Round 3: converters on key columns, and the keys of batched lookups.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

/// String <-> String (like encryption): the stored form differs from the Dart value.
class _Enc extends FluentConverter<String, String> {
  const _Enc();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(String value) => 'enc:$value';

  @override
  String fromSql(String value) => value.substring(4);
}

/// int <-> String.
class _IntText extends FluentConverter<int, String> {
  const _IntText();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(int value) => 'n$value';

  @override
  int fromSql(String value) => int.parse(value.substring(1));
}

FluentDbColumn _encKey() => FluentDbColumn.converted('id', const _Enc()).copyWith(isPrimaryKey: true);

DynamicProvider _encTable(String name) => DynamicProvider(name, () => [_encKey(), FluentDbColumn.text('name')], key: _encKey);

Future<List<Object?>> _stored(DynamicProvider p, String column) async => [
  for (final Map<String, Object?> r in await p.db.rawQuery('SELECT ${column.quotedIdentifier} AS c FROM ${p.tableName.quotedIdentifier} ORDER BY 1')) r['c'],
];

// ---------------------------------------------------------------------------------------------------------------------
// Relations whose referenced key has a converter
// ---------------------------------------------------------------------------------------------------------------------

class Shelf extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Shelf({required this.id, this.name = '', this.books, this.labels});

  final String id;
  final String name;
  final List<Book>? books;
  final List<ShelfLabel>? labels;

  @override
  FluentDbColumn get primaryKey => _encKey();

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<Shelf, Book>('books', (s) => s.books, orderBy: 'id'),
    FluentRelation.manyToMany<Shelf, ShelfLabel>('labels', (s) => s.labels, orderBy: 'title'),
  ];
}

class Book extends FluentStorable {
  Book({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class ShelfLabel extends FluentStorable {
  ShelfLabel({required this.id, required this.title});

  final String id;
  final String title;

  @override
  FluentDbColumn get primaryKey => _encKey();

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class Pin extends FluentStorable with FluentRelations {
  Pin({this.id, required this.text, this.shelf});

  final int? id;
  final String text;
  final Shelf? shelf;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<Pin, Shelf>('shelf', (p) => p.shelf)];
}

class ShelfProvider extends FluentProvider<Shelf> {
  @override
  String get tableName => 'shelves';

  @override
  Shelf get modelSample => Shelf(id: '');

  @override
  Shelf fromCacheJson(Map<String, dynamic> json) =>
      Shelf(id: json['id'] as String, name: json['name'] as String, books: (json['books'] as List?)?.cast<Book>(), labels: (json['labels'] as List?)?.cast<ShelfLabel>());
}

class BookProvider extends FluentProvider<Book> {
  @override
  String get tableName => 'books';

  @override
  Book get modelSample => Book(title: '');

  @override
  Book fromCacheJson(Map<String, dynamic> json) => Book(id: json['id'] as int?, title: json['title'] as String);
}

class ShelfLabelProvider extends FluentProvider<ShelfLabel> {
  @override
  String get tableName => 'shelf_labels';

  @override
  ShelfLabel get modelSample => ShelfLabel(id: '', title: '');

  @override
  ShelfLabel fromCacheJson(Map<String, dynamic> json) => ShelfLabel(id: json['id'] as String, title: json['title'] as String);
}

class PinProvider extends FluentProvider<Pin> {
  @override
  String get tableName => 'pins';

  @override
  Pin get modelSample => Pin(text: '');

  @override
  Pin fromCacheJson(Map<String, dynamic> json) => Pin(id: json['id'] as int?, text: json['text'] as String, shelf: json['shelf'] as Shelf?);
}

void main() {
  setUpFluentTests();
  int counter = 0;
  late FluentTestDb db;

  setUp(() => db = FluentTestDb(name: 'keys_${counter++}'));
  tearDown(() => db.close());

  group('String converter on the primary key', () {
    late DynamicProvider p;

    setUp(() async {
      p = _encTable('enc');
      await db.open([p]);
      await p.save(p.row({'id': 'a', 'name': 'A'}));
      await p.save(p.row({'id': 'b', 'name': 'B'}));
    });

    test('stored once converted', () async {
      expect(await _stored(p, 'id'), ['enc:a', 'enc:b']);
    });

    test('findById / exists', () async {
      expect((await p.findById('a'))?['name'], 'A');
      expect(await p.findById('zzz'), isNull);
      expect(await p.exists('b'), isTrue);
    });

    test('findByIds (merged and direct) keep order and nulls', () async {
      expect((await p.findByIds(['b', 'a'])).map((m) => m['name']), ['B', 'A']);
      final List<DynamicModel?> merged = await Future.wait([p.findById('b'), p.findById('x'), p.findById('a'), p.findById('b')]);
      expect(merged.map((m) => m?['name']), ['B', null, 'A', 'B']);
    });

    test('save upsert updates the same row', () async {
      await p.save(p.row({'id': 'a', 'name': 'A2'}));
      expect(await p.count(), 2);
      expect((await p.findById('a'))?['name'], 'A2');
      expect(await _stored(p, 'id'), ['enc:a', 'enc:b']);
    });

    test('save with conflictOn the key column', () async {
      await p.save(p.row({'id': 'a', 'name': 'A3'}), conflictOn: ['id']);
      expect(await p.count(), 2);
      expect((await p.findById('a'))?['name'], 'A3');
    });

    test('update / delete by id / delete by filter', () async {
      await p.update(p.row({'id': 'a', 'name': 'A4'}));
      expect((await p.findById('a'))?['name'], 'A4');
      expect(await p.deleteById('a'), 1);
      expect(await p.count(), 1);
      expect(await p.deleteWhere(FluentFilter.eq('id', 'b')), 1);
    });

    test('user filters convert once', () async {
      expect(await p.count(where: FluentFilter.eq('id', 'a')), 1);
      expect(await p.count(where: FluentFilter.ids(['a', 'b'])), 2);
    });
  });

  group('int converter on the primary key', () {
    late DynamicProvider p;
    FluentDbColumn key() => FluentDbColumn.converted('id', const _IntText()).copyWith(isPrimaryKey: true);

    setUp(() async {
      p = DynamicProvider('inttext', () => [key(), FluentDbColumn.text('name')], key: key);
      await db.open([p]);
      await p.save(p.row({'id': 1, 'name': 'one'}));
      await p.save(p.row({'id': 2, 'name': 'two'}));
    });

    test('lookups, upsert and delete', () async {
      expect(await _stored(p, 'id'), ['n1', 'n2']);
      expect((await p.findById(2))?['name'], 'two');
      expect((await Future.wait([p.findById(2), p.findById(9), p.findById(1)])).map((m) => m?['name']), ['two', null, 'one']);
      await p.save(p.row({'id': 1, 'name': 'uno'}));
      expect(await p.count(), 2);
      expect((await p.findById(1))?['name'], 'uno');
      expect(await p.deleteById(1), 1);
      expect(await p.count(), 1);
    });
  });

  group('more write paths with converters', () {
    test('composite key with a converted column: save, update, find, delete', () async {
      final FluentDbColumn a = FluentDbColumn.converted('a', const _Enc()).copyWith(isPrimaryKey: true);
      final FluentDbColumn b = FluentDbColumn.integer('b').copyWith(isPrimaryKey: true);
      final DynamicProvider p = DynamicProvider.spec('comp_enc', TableSpec(columns: () => [a, b, FluentDbColumn.text('name')], keys: () => [a, b]));
      await db.open([p]);
      await p.saveAll([p.row({'a': 'x', 'b': 1, 'name': 'x1'}), p.row({'a': 'x', 'b': 2, 'name': 'x2'}), p.row({'a': 'y', 'b': 1, 'name': 'y1'})]);
      await p.save(p.row({'a': 'x', 'b': 2, 'name': 'x2!'}));
      expect(await p.count(), 3);
      expect((await p.findById(FluentKey({'b': 2, 'a': 'x'})))?['name'], 'x2!');
      expect((await p.findByIds([FluentKey({'a': 'y', 'b': 1}), FluentKey({'a': 'x', 'b': 1})])).map((m) => m['name']), ['y1', 'x1']);
      expect(await p.deleteById(FluentKey({'a': 'x', 'b': 1})), 1);
      expect(await p.count(), 2);
      expect(await _stored(p, 'a'), ['enc:x', 'enc:y']);
    });

    test('conflictOn a converted unique column updates the matching row and keeps its key', () async {
      FluentDbColumn email() => FluentDbColumn.converted('email', const _Enc()).copyWith(isUnique: true);
      final DynamicProvider p = DynamicProvider('conflict_enc', () => [FluentDbColumn.integer('id'), email(), FluentDbColumn.text('name')]);
      await db.open([p]);
      await p.save(p.row({'id': 1, 'email': 'a@x', 'name': 'first'}));
      final DynamicModel again = p.row({'id': 2, 'email': 'a@x', 'name': 'second'});
      await p.save(again, conflictOn: ['email']);
      expect(await p.count(), 1);
      expect((await p.findById(1))?['name'], 'second');
      expect(await _stored(p, 'email'), ['enc:a@x']);
      expect(again.primaryKeyValue, 1, reason: 'the model takes the key of the row that was updated');
    });

    test('updateById / updateWhere / patch on a converted key', () async {
      final DynamicProvider p = _encTable('upd_enc');
      await db.open([p]);
      await p.saveAll([p.row({'id': 'a', 'name': 'A'}), p.row({'id': 'b', 'name': 'B'})]);
      expect(await p.updateById('a', {'name': 'A2'}), 1);
      expect(await p.updateWhere(FluentFilter.eq('id', 'b'), {'name': 'B2'}), 1);
      await p.save(p.row({'id': 'a', 'name': null}), strategy: FluentSaveStrategy.patch);
      expect((await p.findAll(orderBy: 'id')).map((m) => m['name']), ['A2', 'B2']);
      await p.save(p.row({'id': 'c', 'name': 'C'}), strategy: FluentSaveStrategy.insertOnly);
      await p.save(p.row({'id': 'c', 'name': 'C2'}), strategy: FluentSaveStrategy.insertOnly);
      expect((await p.findById('c'))?['name'], 'C');
      expect(await p.count(), 3);
    });

    test('a DateTime key (codec) is not rewritten into the model by a save', () async {
      final FluentDbColumn at = FluentDbColumn.timestamp('at').copyWith(isPrimaryKey: true);
      final DynamicProvider p = DynamicProvider('dt_key', () => [at, FluentDbColumn.text('name')], key: () => at);
      await db.open([p]);
      final DateTime when = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final DynamicModel row = p.row({'at': when, 'name': 'x'});
      await p.save(row);
      expect(row.primaryKeyValue, when);
      await p.save(p.row({'at': when, 'name': 'y'}));
      expect(await p.count(), 1);
      expect((await p.findById(when))?['name'], 'y');
    });
  });

  group('relations with a converted referenced key', () {
    late ShelfProvider shelves;
    late BookProvider books;
    late ShelfLabelProvider labels;
    late PinProvider pins;

    setUp(() async {
      shelves = ShelfProvider();
      books = BookProvider();
      labels = ShelfLabelProvider();
      pins = PinProvider();
      await db.open([shelves, books, labels, pins]);
    });

    Future<List<Object?>> column(String table, String column) async => [
      for (final Map<String, Object?> r in await shelves.db.rawQuery('SELECT ${column.quotedIdentifier} AS c FROM ${table.quotedIdentifier} ORDER BY 1')) r['c'],
    ];

    test('owned list: save, load, replace, find, count', () async {
      await shelves.save(Shelf(id: 's1', name: 'one', books: [Book(title: 'a'), Book(title: 'b')]));
      expect(await column('shelves', 'id'), ['enc:s1']);
      expect(await column('books', 'shelf_id'), ['enc:s1', 'enc:s1']);
      final Shelf loaded = (await shelves.findById('s1'))!;
      expect(loaded.books!.map((b) => b.title), ['a', 'b']);
      expect(await shelves.countRelated(loaded, 'books'), 2);
      expect((await shelves.findRelated<Book>(loaded, 'books')).map((b) => b.title), ['a', 'b']);
      await shelves.save(Shelf(id: 's1', name: 'one', books: [loaded.books!.first]));
      expect(await books.count(), 1);
      expect(await column('books', 'shelf_id'), ['enc:s1']);
    });

    test('loadRelations / attach / detach on an owned list', () async {
      await shelves.save(Shelf(id: 's1', name: 'one'));
      final Shelf bare = (await shelves.findById('s1', relations: FluentLoad.none))!;
      await shelves.attach(bare, 'books', [Book(title: 'x'), Book(title: 'y')]);
      expect(await column('books', 'shelf_id'), ['enc:s1', 'enc:s1']);
      final Shelf withBooks = await shelves.loadRelations(bare, names: ['books']);
      expect(withBooks.books!.map((b) => b.title), ['x', 'y']);
      await shelves.detach(withBooks, 'books', [withBooks.books!.first]);
      expect(await books.count(), 1);
    });

    test('many-to-many: save, load, attach, detach, count', () async {
      await shelves.save(Shelf(id: 's1', labels: [ShelfLabel(id: 'l1', title: 'A'), ShelfLabel(id: 'l2', title: 'B')]));
      expect(await column('shelf_labels', 'id'), ['enc:l1', 'enc:l2']);
      final Shelf loaded = (await shelves.findById('s1'))!;
      expect(loaded.labels!.map((l) => l.title), ['A', 'B']);
      await shelves.detach(loaded, 'labels', [loaded.labels!.first]);
      expect((await shelves.findById('s1'))!.labels!.map((l) => l.title), ['B']);
      await shelves.attach(loaded, 'labels', [ShelfLabel(id: 'l3', title: 'C')]);
      expect((await shelves.findById('s1'))!.labels!.map((l) => l.title), ['B', 'C']);
      expect(await shelves.countRelated(loaded, 'labels'), 2);
    });

    test('a single reference to a converted key loads the parent', () async {
      await shelves.save(Shelf(id: 's1', name: 'one'));
      final Shelf shelf = (await shelves.findById('s1'))!;
      await pins.save(Pin(text: 'p', shelf: shelf));
      expect(await column('pins', 'shelf_id'), ['enc:s1']);
      final Pin pin = (await pins.findAll()).single;
      expect(pin.shelf?.id, 's1');
      expect(await pins.countRelated(pin, 'shelf'), 1);
      expect((await shelves.findParents<Pin>(shelf)).map((p) => p.text), ['p']);
    });

    test('delete cascades to children; soft delete and restore follow the converted key', () async {
      await shelves.save(Shelf(id: 's1', books: [Book(title: 'a')], labels: [ShelfLabel(id: 'l1', title: 'A')]));
      final Shelf shelf = (await shelves.findById('s1'))!;
      expect(await shelves.delete(shelf), 1);
      expect(await shelves.findById('s1'), isNull);
      expect(shelf.deletedAt, isNotNull);
      expect(await shelves.trash.restoreById('s1'), 1);
      final Shelf back = (await shelves.findById('s1'))!;
      expect(back.books!.map((b) => b.title), ['a']);
      expect(await shelves.deleteById('s1'), 1);
      expect(await shelves.trash.deleteForeverById('s1'), 1);
      expect(await books.count(), 0);
    });

    test('save over a trashed row with the converted key brings it back', () async {
      await shelves.save(Shelf(id: 's1', name: 'old'));
      await shelves.deleteById('s1');
      await shelves.save(Shelf(id: 's1', name: 'new'));
      expect((await shelves.findById('s1'))?.name, 'new');
      expect(await shelves.count(), 1);
    });
  });

  group('sync with a converted key', () {
    late EncDocProvider docs;
    late EncNoteProvider notes;

    setUp(() async {
      docs = EncDocProvider();
      notes = EncNoteProvider();
      await db.open([docs, notes]);
    });

    test('a pull matches rows by the Dart key: the second pull updates, it does not insert', () async {
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncDoc(id: 'a', name: 'one'), EncDoc(id: 'b', name: 'two')]));
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncDoc(id: 'a', name: 'one!')]));
      expect((await docs.findAll(orderBy: 'id')).map((d) => d.name), ['one!', 'two']);
      expect(await docs.pendingSyncCount(), 0);
    });

    test('push sends Dart keys and marks the rows synced', () async {
      await docs.save(EncDoc(id: 'a', name: 'one'));
      final List<String> sent = [];
      await docs.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sent.addAll(batch.changed.map((d) => d.id));
          return const FluentPushResult.accepted();
        },
      );
      expect(sent, ['a']);
      expect(await docs.pendingSyncCount(), 0);
      await docs.save(EncDoc(id: 'a', name: 'edited'));
      expect(await docs.pendingSyncCount(), 1);
    });

    test('a pull with deletedKeys removes the row (soft delete)', () async {
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncDoc(id: 'a', name: 'one'), EncDoc(id: 'b', name: 'two')]));
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: ['a']));
      expect((await docs.findAll()).map((d) => d.id), ['b']);
      expect((await docs.trash.find()).map((d) => d.id), ['a']);
    });

    test('a pull does not overwrite a local change not pushed yet', () async {
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncDoc(id: 'a', name: 'one')]));
      await docs.save(EncDoc(id: 'a', name: 'local'));
      await docs.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncDoc(id: 'a', name: 'server')]));
      expect((await docs.findById('a'))?.name, 'local');
    });

    test('hard deletes leave tombstones with the Dart key; a pull of the same key does not bring the row back', () async {
      await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncNote(id: 'n1', text: 'x'), EncNote(id: 'n2', text: 'y')]));
      await notes.deleteById('n1');
      await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [EncNote(id: 'n1', text: 'x again')]));
      expect((await notes.findAll()).map((n) => n.id), ['n2'], reason: 'the local deletion is not pushed yet and wins');
      final List<Object> sent = [];
      await notes.syncWithServer(
        strategy: FluentSyncStrategy.push,
        onPush: (batch) async {
          sent.addAll(batch.deletedKeys);
          return const FluentPushResult.accepted();
        },
      );
      expect(sent, ['n1']);
      await notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(deletedKeys: ['n2']));
      expect(await notes.count(), 0);
    });
  });

  group('batched lookups: keys from rows or from models', () {
    Future<List<Object?>> lookups(RecProvider p, List<Object?> ids) async => [for (final Rec? r in await Future.wait([for (final Object? id in ids) p.findById(id)])) r?.name];

    for (final FluentBatchKeys mode in FluentBatchKeys.values) {
      group(mode.name, () {
        test('plain keys: order, missing ids (null in position), duplicates', () async {
          final RecProvider p = RecProvider(mode);
          await db.open([p]);
          await p.saveAll([Rec(id: 1, name: 'a'), Rec(id: 2, name: 'b'), Rec(id: 3, name: 'c')]);
          expect(await lookups(p, [3, 9, 1, 3, 2, 9]), ['c', null, 'a', 'c', 'b', null]);
        });

        test('keys given as text for an integer column', () async {
          final RecProvider p = RecProvider(mode);
          await db.open([p]);
          await p.saveAll([Rec(id: 1, name: 'a'), Rec(id: 2, name: 'b')]);
          expect(await lookups(p, ['2', '1']), ['b', 'a']);
        });

        test('converted keys (String and int converters)', () async {
          final DynamicProvider enc = DynamicProvider('enc_$counter', () => [_encKey(), FluentDbColumn.text('name')], key: _encKey);
          FluentDbColumn intKey() => FluentDbColumn.converted('id', const _IntText()).copyWith(isPrimaryKey: true);
          final DynamicProvider ints = DynamicProvider('ints_$counter', () => [intKey(), FluentDbColumn.text('name')], key: intKey);
          await db.open([enc, ints], fluentConfig: FluentConfig(batchKeys: mode));
          await enc.saveAll([enc.row({'id': 'x', 'name': 'X'}), enc.row({'id': 'y', 'name': 'Y'})]);
          await ints.saveAll([ints.row({'id': 7, 'name': 'seven'}), ints.row({'id': 8, 'name': 'eight'})]);
          expect((await Future.wait([enc.findById('y'), enc.findById('q'), enc.findById('x')])).map((m) => m?['name']), ['Y', null, 'X']);
          expect((await Future.wait([ints.findById(8), ints.findById(1), ints.findById(7)])).map((m) => m?['name']), ['eight', null, 'seven']);
        });

        test('composite keys in any column order', () async {
          final FluentDbColumn a = FluentDbColumn.integer('a').copyWith(isPrimaryKey: true);
          final FluentDbColumn b = FluentDbColumn.text('b').copyWith(isPrimaryKey: true);
          final DynamicProvider p = DynamicProvider.spec(
            'comp_$counter',
            TableSpec(columns: () => [a, b, FluentDbColumn.text('name')], keys: () => [a, b]),
          );
          await db.open([p], fluentConfig: FluentConfig(batchKeys: mode));
          await p.saveAll([p.row({'a': 1, 'b': 'x', 'name': '1x'}), p.row({'a': 1, 'b': 'y', 'name': '1y'}), p.row({'a': 2, 'b': 'x', 'name': '2x'})]);
          final List<DynamicModel?> found = await Future.wait([
            p.findById(FluentKey({'b': 'y', 'a': 1})),
            p.findById(FluentKey({'a': 2, 'b': 'x'})),
            p.findById(FluentKey({'a': 9, 'b': 'x'})),
            p.findById(FluentKey({'b': 'y', 'a': 1})),
          ]);
          expect(found.map((m) => m?['name']), ['1y', '2x', null, '1y']);
        });
      });
    }

    test('fromRows takes the keys from the rows: no buildJson per model', () async {
      final RecProvider p = RecProvider(FluentBatchKeys.fromRows);
      await db.open([p]);
      await p.saveAll([for (int i = 1; i <= 6; i++) Rec(id: i, name: 'n$i')]);
      Rec.buildCalls = 0;
      expect(await lookups(p, [1, 2, 3, 4, 5, 6]), ['n1', 'n2', 'n3', 'n4', 'n5', 'n6']);
      expect(Rec.buildCalls, 0);
    });

    test('fromModels reads buildJson of every returned model', () async {
      final RecProvider p = RecProvider(FluentBatchKeys.fromModels);
      await db.open([p]);
      await p.saveAll([for (int i = 1; i <= 6; i++) Rec(id: i, name: 'n$i')]);
      Rec.buildCalls = 0;
      expect(await lookups(p, [1, 2, 3, 4, 5, 6]), ['n1', 'n2', 'n3', 'n4', 'n5', 'n6']);
      expect(Rec.buildCalls, greaterThanOrEqualTo(3), reason: 'the merged lookups read the key of every returned model');
    });

    Future<int> buildCallsOf(RecProvider p, {FluentDbConfig config = const FluentDbConfig(), FluentConfig fluentConfig = const FluentConfig()}) async {
      await db.open([p], config: config, fluentConfig: fluentConfig);
      await p.saveAll([for (int i = 1; i <= 6; i++) Rec(id: i, name: 'n$i')]);
      Rec.buildCalls = 0;
      expect(await lookups(p, [1, 2, 3, 4, 5, 6]), ['n1', 'n2', 'n3', 'n4', 'n5', 'n6']);
      return Rec.buildCalls;
    }

    test('the setting defaults to fromRows (global)', () async {
      expect(const FluentConfig().batchKeys, FluentBatchKeys.fromRows);
      expect(const FluentDbConfig().batchKeys, isNull);
      expect(const FluentTableConfig().batchKeys, isNull);
      expect(await buildCallsOf(RecProvider(null)), 0);
    });

    test('the database setting overrides the global one', () async {
      expect(await buildCallsOf(RecProvider(null), config: const FluentDbConfig(batchKeys: FluentBatchKeys.fromModels)), greaterThanOrEqualTo(3));
    });

    test('the global setting applies when table and database say nothing', () async {
      expect(await buildCallsOf(RecProvider(null), fluentConfig: const FluentConfig(batchKeys: FluentBatchKeys.fromModels)), greaterThanOrEqualTo(3));
    });

    test('the table setting wins over database and global', () async {
      expect(
        await buildCallsOf(RecProvider(FluentBatchKeys.fromRows), config: const FluentDbConfig(batchKeys: FluentBatchKeys.fromModels), fluentConfig: const FluentConfig(batchKeys: FluentBatchKeys.fromModels)),
        0,
      );
    });

    for (final FluentBatchKeys mode in FluentBatchKeys.values) {
      test('${mode.name}: a model whose fromCacheJson changes the key is still found by the requested key', () async {
        final ShiftedProvider p = ShiftedProvider(mode);
        await db.open([p]);
        await p.saveAll([Shifted(id: 1, name: 'a'), Shifted(id: 2, name: 'b'), Shifted(id: 3, name: 'c'), Shifted(id: 4, name: 'd')]);
        final List<Shifted?> found = await Future.wait([for (final int id in [4, 2, 9, 1]) p.findById(id)]);
        expect(found.map((m) => m?.name), ['d', 'b', null, 'a']);
      });
    }

    for (final FluentBatchKeys mode in FluentBatchKeys.values) {
      test('${mode.name}: a row SQLite matches in another form (NOCASE key) is found, and fromRows reports it once', () async {
        final NoCaseProvider p = NoCaseProvider(mode);
        await db.open([p]);
        await p.save(NoCase(id: 'ABC', name: 'upper'));
        await p.save(NoCase(id: 'xyz', name: 'lower'));
        final List<NoCase?> found = await Future.wait([for (final String id in ['xyz', 'abc', 'aBc', 'nope', 'XYZ']) p.findById(id)]);
        expect(found.map((m) => m?.name), ['lower', 'upper', 'upper', null, 'lower']);
        expect(db.issues.where((i) => i.kind == FluentIssueKind.batchKeysMismatch), hasLength(mode == FluentBatchKeys.fromRows ? 1 : 0));
      });
    }
  });
}

class EncDoc extends FluentStorable with FluentSoftDeletable {
  EncDoc({required this.id, required this.name});

  final String id;
  final String name;

  @override
  FluentDbColumn get primaryKey => _encKey();

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class EncDocProvider extends FluentProvider<EncDoc> with FluentSyncable<EncDoc> {
  @override
  String get tableName => 'enc_docs';

  @override
  EncDoc get modelSample => EncDoc(id: '', name: '');

  @override
  EncDoc fromCacheJson(Map<String, dynamic> json) => EncDoc(id: json['id'] as String, name: json['name'] as String);
}

class EncNote extends FluentStorable {
  EncNote({required this.id, required this.text});

  final String id;
  final String text;

  @override
  FluentDbColumn get primaryKey => _encKey();

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class EncNoteProvider extends FluentProvider<EncNote> with FluentSyncable<EncNote> {
  @override
  String get tableName => 'enc_notes';

  @override
  EncNote get modelSample => EncNote(id: '', text: '');

  @override
  EncNote fromCacheJson(Map<String, dynamic> json) => EncNote(id: json['id'] as String, text: json['text'] as String);
}

class Rec extends FluentStorable {
  Rec({required this.id, required this.name, this.batchKeys});

  /// How often `buildJson` ran (the cost `FluentBatchKeys.fromRows` avoids).
  static int buildCalls = 0;

  final int id;
  final String name;
  final FluentBatchKeys? batchKeys;

  @override
  FluentTableConfig get tableConfig => FluentTableConfig(batchKeys: batchKeys);

  @override
  Map<String, dynamic> buildJson() {
    buildCalls++;
    return {'id': id, 'name': name};
  }
}

class RecProvider extends FluentProvider<Rec> {
  RecProvider(this.mode);

  final FluentBatchKeys? mode;

  @override
  String get tableName => 'recs';

  @override
  Rec get modelSample => Rec(id: 0, name: '', batchKeys: mode);

  @override
  Rec fromCacheJson(Map<String, dynamic> json) => Rec(id: json['id'] as int, name: json['name'] as String, batchKeys: mode);
}

/// The loaded model reports another key than the stored row (`fromCacheJson` adds 1000).
class Shifted extends FluentStorable {
  Shifted({required this.id, required this.name, this.batchKeys});

  final int id;
  final String name;
  final FluentBatchKeys? batchKeys;

  @override
  FluentTableConfig get tableConfig => FluentTableConfig(batchKeys: batchKeys);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class ShiftedProvider extends FluentProvider<Shifted> {
  ShiftedProvider(this.mode);

  final FluentBatchKeys mode;

  @override
  String get tableName => 'shifted';

  @override
  Shifted get modelSample => Shifted(id: 0, name: '', batchKeys: mode);

  @override
  Shifted fromCacheJson(Map<String, dynamic> json) => Shifted(id: (json['id'] as int) + 1000, name: json['name'] as String, batchKeys: mode);
}

class NoCase extends FluentStorable {
  NoCase({required this.id, required this.name, this.batchKeys});

  final String id;
  final String name;
  final FluentBatchKeys? batchKeys;

  @override
  FluentTableConfig get tableConfig => FluentTableConfig(batchKeys: batchKeys);

  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'id', type: FluentDbDataType.custom, customSql: 'TEXT PRIMARY KEY COLLATE NOCASE', isPrimaryKey: true);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class NoCaseProvider extends FluentProvider<NoCase> {
  NoCaseProvider(this.mode);

  final FluentBatchKeys mode;

  @override
  String get tableName => 'nocase';

  @override
  NoCase get modelSample => NoCase(id: '', name: '', batchKeys: mode);

  @override
  NoCase fromCacheJson(Map<String, dynamic> json) => NoCase(id: json['id'] as String, name: json['name'] as String, batchKeys: mode);
}
