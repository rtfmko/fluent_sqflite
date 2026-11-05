// Relation loads and counts: chunked keys (no bound-variable overflow, no N+1), relation `where` with deferred
// conditions, and countRelated for every kind of relation.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart' as rm;

class Writer extends FluentStorable with FluentSoftDeletable {
  Writer({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Book extends FluentStorable with FluentRelations {
  Book({this.id, required this.title, this.author});

  final int? id;
  final String title;
  final Writer? author;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<Book, Writer>('author', (b) => b.author)];
}

class Note extends FluentStorable with FluentRelations {
  Note({this.id, required this.text, this.writer});

  final int? id;
  final String text;
  final Writer? writer;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<Note, Writer>('writer', (n) => n.writer)];
}

/// A link with data of its own: which reader has which book.
class Loan extends FluentStorable with FluentRelations {
  Loan({this.id, this.reader, this.book});

  final int? id;
  final Reader? reader;
  final Book? book;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Loan, Reader>('reader', (l) => l.reader),
    FluentRelation.one<Loan, Book>('book', (l) => l.book),
  ];
}

/// A composite key: references to it use two columns.
class DayStat extends FluentStorable {
  DayStat({required this.userId, required this.day});

  final int userId;
  final String day;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')];

  @override
  Map<String, dynamic> buildJson() => {'user_id': userId, 'day': day};
}

final FluentFilter byAnn = FluentFilter.related('author', FluentFilter.eq('name', 'Ann'));

class Reader extends FluentStorable with FluentRelations {
  Reader({this.id, required this.name, this.favorites, this.notes, this.loaned, this.idol, this.pin});

  final int? id;
  final String name;
  final List<Book>? favorites;
  final List<Note>? notes;
  final List<Book>? loaned;
  final Writer? idol;
  final FluentStorable? pin;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.manyToMany<Reader, Book>('favorites', (r) => r.favorites, where: byAnn, orderBy: 'title'),
    FluentRelation.many<Reader, Note>('notes', (r) => r.notes, where: FluentFilter.related('writer', FluentFilter.eq('name', 'Ann'))),
    FluentRelation.through<Reader, Loan, Book>('loaned', (r) => r.loaned, where: byAnn),
    FluentRelation.one<Reader, Writer>('idol', (r) => r.idol),
    FluentRelation.oneOf<Reader>('pin', (r) => r.pin, types: [Writer, DayStat]),
  ];
}

class WriterProvider extends FluentProvider<Writer> {
  @override
  String get tableName => 'writers';

  @override
  Writer get modelSample => Writer(name: '');

  @override
  Writer fromCacheJson(Map<String, dynamic> json) => Writer(id: json['id'] as int?, name: json['name'] as String);
}

class BookProvider extends FluentProvider<Book> {
  @override
  String get tableName => 'books';

  @override
  Book get modelSample => Book(title: '');

  @override
  Book fromCacheJson(Map<String, dynamic> json) => Book(id: json['id'] as int?, title: json['title'] as String, author: json['author'] as Writer?);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String, writer: json['writer'] as Writer?);
}

class LoanProvider extends FluentProvider<Loan> {
  @override
  String get tableName => 'loans';

  @override
  Loan get modelSample => Loan();

  @override
  Loan fromCacheJson(Map<String, dynamic> json) => Loan(id: json['id'] as int?, reader: json['reader'] as Reader?, book: json['book'] as Book?);
}

class DayStatProvider extends FluentProvider<DayStat> {
  @override
  String get tableName => 'day_stats';

  @override
  DayStat get modelSample => DayStat(userId: 0, day: '');

  @override
  DayStat fromCacheJson(Map<String, dynamic> json) => DayStat(userId: json['user_id'] as int, day: json['day'] as String);
}

class ReaderProvider extends FluentProvider<Reader> {
  @override
  String get tableName => 'readers';

  @override
  Reader get modelSample => Reader(name: '');

  @override
  Reader fromCacheJson(Map<String, dynamic> json) => Reader(
    id: json['id'] as int?,
    name: json['name'] as String,
    favorites: (json['favorites'] as List?)?.cast<Book>(),
    notes: (json['notes'] as List?)?.cast<Note>(),
    loaned: (json['loaned'] as List?)?.cast<Book>(),
    idol: json['idol'] as Writer?,
    pin: json['pin'] as FluentStorable?,
  );
}

void main() {
  setUpFluentTests();

  group('REL3: relation loads are chunked', () {
    late QueryCounter counter;
    late FluentTestDb db;
    late rm.ArticleProvider articles;

    setUp(() async {
      counter = await QueryCounter.install();
      db = FluentTestDb();
      final List<FluentProvider> providers = rm.relationProviders();
      articles = providers.whereType<rm.ArticleProvider>().single;
      await db.open(providers);
    });

    tearDown(() async {
      await db.close();
      counter.uninstall();
    });

    /// [count] articles, each with its own author, two comments and the tags `t0` / `t1` (fast: plain SQL).
    Future<void> seed(int count) async {
      final String n = 'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < $count)';
      await articles.db.execute('$n INSERT INTO people (id, name) SELECT i, \'p\' || i FROM n');
      await articles.db.execute('$n INSERT INTO articles (id, title, author_id) SELECT i, \'a\' || i, i FROM n');
      await articles.db.execute('$n INSERT INTO comments (id, text, likes, article_id) SELECT i * 2, \'second\', 0, i FROM n');
      await articles.db.execute('$n INSERT INTO comments (id, text, likes, article_id) SELECT i * 2 - 1, \'first\', 0, i FROM n');
      await articles.db.execute("INSERT INTO tags (id, label) VALUES (1, 't1'), (2, 't0')");
      await articles.db.execute('$n INSERT INTO articles_tags (article_id, tag_id) SELECT i, 1 FROM n UNION ALL SELECT i, 2 FROM n');
    }

    Future<int> readsOf(Future<Object?> Function() load) async {
      counter.reset();
      await load();
      return counter.reads;
    }

    test('a list above the chunk size loads every relation in full', () async {
      await seed(1200);
      final List<rm.Article> all = await articles.findAll(orderBy: 'id');
      expect(all, hasLength(1200));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
      for (final rm.Article a in all) {
        expect(a.author?.name, 'p${a.id}');
        expect(a.comments!.map((c) => c.text), ['first', 'second'], reason: 'orderBy id holds within every owner');
        expect(a.tags!.map((t) => t.label), ['t0', 't1'], reason: 'orderBy label holds within every owner');
      }
    });

    test('more keys than SQLite takes in one statement still load (was: every relation left unloaded)', () async {
      await seed(33000);
      final List<rm.Article> all = await articles.findAll(relations: FluentLoad.eager);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
      expect(all.where((a) => a.author == null), isEmpty);
      expect(all.where((a) => a.comments?.length != 2), isEmpty);
      expect(all.where((a) => a.tags?.length != 2), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a moderate list loads in one query per relation (no N+1)', () async {
      await seed(5);
      final int few = await readsOf(() => articles.findAll());
      await articles.db.execute('DELETE FROM articles_tags');
      await articles.db.execute('DELETE FROM comments');
      await articles.db.execute('DELETE FROM articles');
      await articles.db.execute('DELETE FROM people');
      await articles.db.execute('DELETE FROM tags');
      await seed(800);
      final int moderate = await readsOf(() => articles.findAll());
      expect(moderate, few, reason: 'statements:\n${counter.statements.join('\n')}');
    });

    test('above the chunk size the number of queries grows per chunk, not per row', () async {
      await seed(2000);
      final int reads = await readsOf(() => articles.findAll());
      // articles + author / editor / comments / tags in 3 chunks each (editor has no keys: no query).
      expect(reads, lessThanOrEqualTo(1 + 3 * 3 + 3), reason: 'statements:\n${counter.statements.join('\n')}');
    });
  });

  group('relation where, countRelated', () {
    late FluentTestDb db;
    late ReaderProvider readers;
    late WriterProvider writers;
    late BookProvider books;
    late LoanProvider loans;
    late DayStatProvider stats;
    late Writer ann;
    late Writer bob;

    setUp(() async {
      db = FluentTestDb();
      readers = ReaderProvider();
      writers = WriterProvider();
      books = BookProvider();
      loans = LoanProvider();
      stats = DayStatProvider();
      await db.open([writers, books, NoteProvider(), loans, stats, readers]);
      await writers.saveAll([Writer(name: 'Ann'), Writer(name: 'Bob')]);
      ann = (await writers.find(where: FluentFilter.eq('name', 'Ann'))).single;
      bob = (await writers.find(where: FluentFilter.eq('name', 'Bob'))).single;
    });

    tearDown(() => db.close());

    Future<Reader> reader() async {
      await readers.save(
        Reader(
          name: 'R',
          favorites: [Book(title: 'b', author: ann), Book(title: 'a', author: ann), Book(title: 'x', author: bob)],
          notes: [Note(text: 'n1', writer: ann), Note(text: 'n2', writer: bob), Note(text: 'n3', writer: ann)],
          idol: ann,
        ),
      );
      final Reader r = (await readers.findAll(relations: FluentLoad.none)).single;
      for (final Book b in await books.findAll()) {
        await loans.save(Loan(reader: r, book: b));
      }
      return r;
    }

    test('REL6: a related condition in the where of a many-to-many list is written as SQL', () async {
      await reader();
      final Reader r = (await readers.findAll()).single;
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
      expect(r.favorites!.map((b) => b.title), ['a', 'b']);
    });

    test('REL6: ... and of a through list', () async {
      await reader();
      final Reader r = (await readers.findAll()).single;
      expect(r.loaned!.map((b) => b.title), unorderedEquals(['a', 'b']));
    });

    test('REL6: ... and of an owned list', () async {
      await reader();
      final Reader r = (await readers.findAll()).single;
      expect(r.notes!.map((n) => n.text), unorderedEquals(['n1', 'n3']));
    });

    test('REL6/REL8: countRelated applies a related where to many, many-to-many and through lists', () async {
      final Reader r = await reader();
      expect(await readers.countRelated(r, 'notes'), 2);
      expect(await readers.countRelated(r, 'favorites'), 2);
      expect(await readers.countRelated(r, 'loaned'), 2);
    });

    test('REL6: findRelated applies the related where of the relation', () async {
      final Reader r = await reader();
      expect((await readers.findRelated<Book>(r, 'favorites')).map((b) => b.title), ['a', 'b']);
      expect((await readers.findRelated<Note>(r, 'notes')).map((n) => n.text), unorderedEquals(['n1', 'n3']));
    });

    test('REL8: many-to-many countRelated without rows, and for a model without links', () async {
      await readers.save(Reader(name: 'empty'));
      final Reader empty = (await readers.findAll(relations: FluentLoad.none)).single;
      expect(await readers.countRelated(empty, 'favorites'), 0);
      expect(await readers.countRelated(empty, 'loaned'), 0);
      expect(await readers.countRelated(empty, 'notes'), 0);
    });

    test('REL7: countRelated of one counts only a visible referenced row', () async {
      final Reader r = await reader();
      expect(await readers.countRelated(r, 'idol'), 1);
      await writers.delete(ann); // to the trash
      expect(await readers.countRelated(r, 'idol'), 0, reason: 'a trashed idol is not loaded either');
      expect((await readers.findAll()).single.idol, isNull);
      await readers.save(Reader(name: 'none'));
      final Reader none = (await readers.find(where: FluentFilter.eq('name', 'none'), relations: FluentLoad.none)).single;
      expect(await readers.countRelated(none, 'idol'), 0);
    });

    test('REL3: oneOf references to a composite key above the chunk size all load', () async {
      const String n = 'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)';
      await readers.db.execute("$n INSERT INTO day_stats (user_id, day) SELECT i, 'd' || i FROM n");
      await readers.db.execute("$n INSERT INTO readers (id, name, pin_type, pin_user_id, pin_day) SELECT i, 'r' || i, 'day_stats', i, 'd' || i FROM n");
      final List<Reader> all = await readers.findAll();
      expect(all, hasLength(1000));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationLoadFailed), isEmpty);
      for (final Reader r in all) {
        final DayStat pin = r.pin! as DayStat;
        expect(pin.day, 'd${pin.userId}');
        expect(pin.userId, r.id);
      }
    });

    test('REL7: countRelated of oneOf works for a target with a composite key', () async {
      await stats.save(DayStat(userId: 7, day: 'mon'));
      await readers.save(Reader(name: 'stat', pin: DayStat(userId: 7, day: 'mon')));
      await readers.save(Reader(name: 'writer', pin: bob));
      await readers.save(Reader(name: 'nothing'));
      Future<int> pins(String name) async => readers.countRelated((await readers.find(where: FluentFilter.eq('name', name), relations: FluentLoad.none)).single, 'pin');
      expect(await pins('stat'), 1);
      expect(await pins('writer'), 1);
      expect(await pins('nothing'), 0);
      await writers.delete(bob); // to the trash
      expect(await pins('writer'), 0);
      expect((await readers.find(where: FluentFilter.eq('name', 'stat'))).single.pin, isA<DayStat>());
    });
  });

  group('REL8: count statement', () {
    late FluentTestDb db;
    late QueryCounter counter;

    setUp(() async {
      counter = await QueryCounter.install();
      db = FluentTestDb();
    });

    tearDown(() async {
      await db.close();
      counter.uninstall();
    });

    test('many-to-many countRelated is one COUNT(*) query', () async {
      final ReaderProvider readers = ReaderProvider();
      final WriterProvider writers = WriterProvider();
      await db.open([writers, BookProvider(), NoteProvider(), LoanProvider(), DayStatProvider(), readers]);
      await writers.save(Writer(name: 'Ann'));
      final Writer ann = (await writers.findAll()).single;
      await readers.save(Reader(name: 'R', favorites: [for (int i = 0; i < 5; i++) Book(title: 'b$i', author: ann)]));
      final Reader r = (await readers.findAll(relations: FluentLoad.none)).single;
      counter.reset();
      expect(await readers.countRelated(r, 'favorites'), 5);
      final List<String> reads = [for (final String s in counter.statements) if (s.startsWith('query')) s];
      expect(reads, hasLength(1), reason: '$reads');
      expect(reads.single, contains('COUNT(*)'));
    });
  });
}
