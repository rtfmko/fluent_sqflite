// Type safety of the read/write paths: what reaches SQLite, what comes back as a model and as a map.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/relation_models.dart';

enum Mood { happy, sad }

class Note extends FluentStorable {
  Note({
    this.id,
    required this.title,
    this.done = false,
    required this.createdAt,
    this.syncedAt,
    this.spent = Duration.zero,
    this.mood = Mood.happy,
    this.tags = const [],
    this.extra,
    this.big,
    this.link,
  });

  final int? id;
  final String title;
  final bool done;
  final DateTime createdAt;
  final DateTime? syncedAt;
  final Duration spent;
  final Mood mood;
  final List<String> tags;
  final Map<String, dynamic>? extra;
  final BigInt? big;
  final Uri? link;

  @override
  Map<String, List<Enum>> get enumValues => {'mood': Mood.values};

  @override
  Map<String, dynamic> buildJson() => {
    'id': id,
    'title': title,
    'done': done,
    'created_at': createdAt,
    'synced_at': syncedAt,
    'spent': spent,
    'mood': mood,
    'tags': tags,
    'extra': extra,
    'big': big,
    'link': link,
  };
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(
    title: '',
    createdAt: DateTime(2000),
    syncedAt: DateTime.utc(2000),
    tags: const [''],
    extra: const {},
    big: BigInt.zero,
    link: Uri(),
  );

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(
    id: json['id'] as int?,
    title: json['title'] as String,
    done: json['done'] as bool,
    createdAt: json['created_at'] as DateTime,
    syncedAt: json['synced_at'] as DateTime?,
    spent: json['spent'] as Duration,
    mood: json['mood'] as Mood,
    tags: (json['tags'] as List).cast<String>(),
    extra: json['extra'] as Map<String, dynamic>?,
    big: json['big'] as BigInt?,
    link: json['link'] as Uri?,
  );
}

/// Reads `done` with the wrong type: hydration must fail with a readable error.
class BrokenNoteProvider extends NoteProvider {
  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(title: json['title'] as String, done: (json['done'] as int) == 1, createdAt: DateTime(2000));
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late NoteProvider notes;
  late Database sql;

  final DateTime created = DateTime(2024, 5, 6, 7, 8, 9, 10);
  final DateTime synced = DateTime.utc(2024, 5, 6, 12);

  Note full() => Note(
    title: 'Full',
    done: true,
    createdAt: created,
    syncedAt: synced,
    spent: const Duration(minutes: 90),
    mood: Mood.sad,
    tags: const ['a', 'b'],
    extra: const {'n': 1, 'nested': {'x': true}},
    big: BigInt.parse('123456789012345678901234567890'),
    link: Uri.parse('https://example.com/a?b=c'),
  );

  setUp(() async {
    db = FluentTestDb(name: 'serialization_${DateTime.now().microsecondsSinceEpoch}');
    notes = NoteProvider();
    await db.open([notes]);
    sql = notes.db;
  });

  tearDown(() => db.close());

  test('every supported type survives a round trip, UTC dates keep their zone', () async {
    await notes.save(full());
    final n = (await notes.findAll()).single;

    expect(n.done, isTrue);
    expect(n.createdAt, created);
    expect(n.createdAt.isUtc, isFalse);
    expect(n.syncedAt, synced);
    expect(n.syncedAt!.isUtc, isTrue);
    expect(n.spent, const Duration(minutes: 90));
    expect(n.mood, Mood.sad);
    expect(n.tags, ['a', 'b']);
    expect(n.extra, {'n': 1, 'nested': {'x': true}});
    expect(n.big, BigInt.parse('123456789012345678901234567890'));
    expect(n.link, Uri.parse('https://example.com/a?b=c'));
  });

  test('only plain SQLite values are stored; column kinds make per-row metadata unnecessary', () async {
    await notes.save(full());
    final row = (await sql.query('notes')).single;

    for (final MapEntry<String, Object?> e in row.entries) {
      expect(e.value == null || e.value is int || e.value is String || e.value is double, isTrue, reason: '${e.key} = ${e.value.runtimeType}');
    }
    expect(row['done'], 1);
    expect(row['mood'], 'sad');
    expect(row['_fs_metadata'], '{"synced_at":"datetime_utc"}', reason: 'only the UTC date differs from its column kind');
  });

  test('rows written by raw SQL without metadata are restored by column kind', () async {
    await sql.insert('notes', {
      'title': 'Raw',
      'done': 1,
      'created_at': created.millisecondsSinceEpoch,
      'spent': const Duration(seconds: 5).inMicroseconds,
      'mood': 'sad',
      'tags': '["x"]',
    });
    final n = (await notes.findAll()).single;
    expect(n.done, isTrue);
    expect(n.createdAt, created);
    expect(n.spent, const Duration(seconds: 5));
    expect(n.mood, Mood.sad);
    expect(n.tags, ['x']);
    expect(n.primaryKeyValue, isNotNull);
  });

  test('Dart values are accepted as query arguments', () async {
    await notes.save(full());
    await notes.save(Note(title: 'Plain', createdAt: DateTime(2020)));

    expect((await notes.find(where: FluentFilter.eq('done', true))).map((n) => n.title), ['Full']);
    expect((await notes.find(where: FluentFilter.eq('mood', Mood.sad))).map((n) => n.title), ['Full']);
    expect((await notes.find(where: FluentFilter.eq('created_at', created))).map((n) => n.title), ['Full']);
    expect((await notes.find(where: FluentFilter.eq('spent', const Duration(minutes: 90)))).map((n) => n.title), ['Full']);
    expect((await notes.find(where: FluentFilter.eq('done', false))).map((n) => n.title), ['Plain']);
  });

  test('findMaps holds Dart values, rawQuery stored values; neither has internal columns', () async {
    await notes.save(full());

    final byColumn = (await notes.findMaps(where: FluentFilter.eq('title', 'Full'))).single;
    final byQuery = (await notes.rawQuery('SELECT * FROM notes WHERE done = ?', arguments: [true])).single;
    expect(byColumn['done'], true);
    expect(byQuery['done'], 1);
    for (final Map<String, dynamic> map in [byColumn, byQuery]) {
      expect(map.keys, isNot(contains('_fs_metadata')));
      expect(map['title'], 'Full');
    }
  });

  test('the generated key is known right after insert', () async {
    final note = Note(title: 'New', createdAt: DateTime(2020));
    await notes.save(note);
    expect(note.primaryKeyValue, isA<int>());
    expect((await notes.findById(note.primaryKeyValue))?.title, 'New');
  });

  test('enums with enumValues: stored by name; rows with an index, a name or an old type tag all read back', () async {
    final Note saved = full();
    await notes.save(saved);
    expect((await sql.query('notes')).single['mood'], 'sad');

    Future<Mood> readWith(Object stored, {String? meta}) async {
      await sql.update('notes', {'mood': stored, '_fs_metadata': meta}, where: 'id = ?', whereArgs: [saved.primaryKeyValue]);
      return (await notes.findById(saved.primaryKeyValue))!.mood;
    }

    expect(await readWith(1), Mood.sad, reason: 'index (storeEnumsAsNames: false or older versions)');
    expect(await readWith('0'), Mood.happy, reason: 'index as text');
    expect(await readWith('happy', meta: '{"mood":"enum"}'), Mood.happy, reason: 'a row written with the old per-row tag');
    expect(FluentEnumConverter.lookup(Mood.values, 'nope'), isNull);
    expect(const FluentEnumConverter(Mood.values, byName: false).toSql(Mood.sad), 1);
  });

  test('a value JSON cannot encode is rejected with the field name and a hint', () async {
    final bad = Note(title: 'Bad', createdAt: DateTime(2020), extra: {'when': DateTime(2020)});
    await expectLater(
      notes.save(bad),
      throwsA(
        isA<FluentArgumentException>()
            .having((e) => e.code, 'code', FluentErrorCode.unsupportedValue)
            .having((e) => e.message, 'message', contains('extra'))
            .having((e) => e.message, 'message (values are hidden by default)', isNot(contains('2020')))
            .having((e) => e.hint, 'hint', contains('toIso8601String')),
      ),
    );
    expect(await notes.count(), 0);
  });

  test('a fromCacheJson type mismatch fails with the received types and a hint', () async {
    await notes.save(full());
    final other = FluentTestDb(name: 'serialization_broken_${DateTime.now().microsecondsSinceEpoch}');
    final broken = BrokenNoteProvider();
    await other.open([broken]);
    try {
      await broken.save(full());
      await expectLater(broken.findAll(), throwsA(isA<FluentSchemaException>().having((e) => e.message, 'message', contains('done: bool'))));
    } finally {
      await other.close();
    }
  });

  group('relations on a freshly inserted model', () {
    late FluentTestDb relDb;
    late ArticleProvider articles;

    setUp(() async {
      relDb = FluentTestDb(name: 'serialization_rel_${DateTime.now().microsecondsSinceEpoch}');
      final providers = relationProviders();
      await relDb.open(providers);
      articles = providers.whereType<ArticleProvider>().single;
    });

    tearDown(() => relDb.close());

    test('attach / countOf / loadRelations use the generated key', () async {
      final article = Article(title: 'Fresh');
      await articles.save(article);

      await articles.attach(article, 'comments', [Comment(text: 'c1'), Comment(text: 'c2')]);
      expect(await articles.countRelated(article, 'comments'), 2);
      expect((await articles.loadRelations(article)).comments, hasLength(2));
    });
  });
}
