// Fixes found while reviewing the code comments: a through link model without soft delete / expiry exposed its own
// columns in joins, countRelated of a `one` ignored the relation's where, toSnakeCase doubled existing underscores,
// task descriptions showed SQL arguments.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Reader extends FluentStorable with FluentRelations {
  Reader({this.id, required this.name, this.books = const [], this.favourite});

  final int? id;
  final String name;
  final List<Book> books;
  final Book? favourite;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'favourite': favourite};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.through<Reader, Loan, Book>('books', (r) => r.books, orderBy: 'title', where: FluentFilter.notEq('title', 'X')),
    FluentRelation<Reader, Book>(name: 'favourite', type: FluentRelationType.one, select: (r) => r.favourite, where: FluentFilter.eq('title', 'B')),
  ];
}

class Book extends FluentStorable {
  Book({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

/// A plain link model (no soft delete, no expiry) whose own `title` column has the same name as the target's.
class Loan extends FluentStorable {
  Loan({this.id, required this.title, this.reader, this.book});

  final int? id;
  final String title;
  final Reader? reader;
  final Book? book;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'reader': reader, 'book': book};
}

class ReaderProvider extends FluentProvider<Reader> {
  @override
  String get tableName => 'readers';

  @override
  Reader get modelSample => Reader(name: '', favourite: Book(title: ''));

  @override
  Reader fromCacheJson(Map<String, dynamic> json) =>
      Reader(id: json['id'] as int?, name: json['name'] as String, books: (json['books'] as List<Book>?) ?? const [], favourite: json['favourite'] as Book?);
}

class BookProvider extends FluentProvider<Book> {
  @override
  String get tableName => 'books';

  @override
  Book get modelSample => Book(title: '');

  @override
  Book fromCacheJson(Map<String, dynamic> json) => Book(id: json['id'] as int?, title: json['title'] as String);
}

class LoanProvider extends FluentProvider<Loan> {
  @override
  String get tableName => 'loans';

  @override
  Loan get modelSample => Loan(title: '', reader: Reader(name: ''), book: Book(title: ''));

  @override
  Loan fromCacheJson(Map<String, dynamic> json) => Loan(id: json['id'] as int?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  group('relations', () {
    late FluentTestDb db;
    late ReaderProvider readers;

    setUp(() async {
      readers = ReaderProvider();
      db = FluentTestDb(name: 'comment_review_fixes');
      await db.open([readers, BookProvider(), LoanProvider()]);
    });

    tearDown(() => db.close());

    test('a through list over a plain link model filters and orders by the target column (no ambiguous column)', () async {
      await readers.save(Reader(name: 'Ann'));
      final Reader ann = (await readers.findAll()).single;
      await readers.attach(ann, 'books', [Book(title: 'B'), Book(title: 'A')], link: (b) => Loan(title: 'loan of ${(b as Book).title}'));
      expect((await readers.findAll()).single.books.map((b) => b.title), ['A', 'B']);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
    });

    test('aggregate refuses related / search / ids conditions in having (typed, with a hint)', () async {
      await expectLater(
        readers.aggregate(values: {'n': const FluentAggregate.count()}, having: FluentFilter.ids([1])),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('where'))),
      );
    });

    test('watchById with a key that does not fit the table is a stream error, not a throw', () async {
      final Stream<Reader?> stream = readers.watchById(FluentKey({'nope': 1}));
      await expectLater(stream, emitsError(isA<FluentException>()));
    });

    test('countRelated of a one reference applies the relation where', () async {
      await readers.save(Reader(name: 'Ann', favourite: Book(title: 'A')));
      await readers.save(Reader(name: 'Bob', favourite: Book(title: 'B')));
      final List<Reader> all = await readers.findAll(orderBy: 'name');
      expect(await readers.countRelated(all[0], 'favourite'), 0, reason: 'book "A" does not match the relation where');
      expect(await readers.countRelated(all[1], 'favourite'), 1);
    });
  });

  test('toSnakeCase keeps existing underscores; digits stay with their word', () {
    expect(FluentUtils.toSnakeCase('userName'), 'user_name');
    expect(FluentUtils.toSnakeCase('user_name'), 'user_name');
    expect(FluentUtils.toSnakeCase('mainAuthor_profile'), 'main_author_profile');
    expect(FluentUtils.toSnakeCase('Item2'), 'item2');
    expect(FluentUtils.toSnakeCase('UserProfile'), 'user_profile');
  });

  test('an empty FluentKey is a typed error', () {
    expect(() => FluentKey({}), throwsA(isA<FluentArgumentException>()));
  });

  test('task descriptions hide SQL arguments and keys unless showSqlArguments', () {
    final TableHelper helper = TableHelper(where: '"email" = ?', whereArgs: ['ann@example.com'], id: 7);
    expect(helper.toString(), isNot(contains('ann@example.com')));
    expect(helper.toString(), isNot(contains('id: 7')));
  });
}
