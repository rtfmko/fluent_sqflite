// Full-text search: FTS5 / FTS4 / off (LIKE), triggers on every write, ranking, user input, schema changes.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// The full-text columns of [Doc] (changed by the schema tests).
List<String> docText = ['title', 'body'];

class Doc extends FluentStorable with FluentSoftDeletable {
  Doc({this.id, required this.title, this.body = '', this.views = 0});

  final int? id;
  final String title;
  final String body;
  final int views;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'body': body, 'views': views};

  @override
  List<FluentIndex> get indexes => [if (docText.isNotEmpty) FluentIndex.fullText(docText)];
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String, body: json['body'] as String, views: json['views'] as int);
}

Future<bool> hasFts4(DocProvider docs) async {
  try {
    await docs.db.execute('CREATE VIRTUAL TABLE temp.probe4 USING fts4(x)');
    await docs.db.execute('DROP TABLE temp.probe4');
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DocProvider docs;
  late String name;

  Future<void> open([FluentFullText mode = FluentFullText.auto]) async {
    docs = DocProvider();
    await db.open([docs], config: FluentDbConfig(fullText: mode));
  }

  Future<void> seed() => docs.saveAll([
    Doc(title: 'Flutter databases', body: 'sqlite with fluent models'),
    Doc(title: 'Cooking', body: 'pasta and sauce, nothing about flutter'),
    Doc(title: 'Кошки и собаки', body: 'Домашние ЖИВОТНЫЕ'),
    Doc(title: 'Café crème', body: 'coffee'),
  ]);

  Future<List<String>> found(String text, {FluentFilter? where}) async => [for (final Doc d in await docs.search(text, where: where)) d.title];

  setUp(() {
    docText = ['title', 'body'];
    name = 'fts_${DateTime.now().microsecondsSinceEpoch}';
    db = FluentTestDb(name: name, persistent: true);
  });

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  for (final FluentFullText mode in FluentFullText.values) {
    group('mode ${mode.name}', () {
      bool unavailable = false;

      setUp(() async {
        await open(mode);
        await seed();
        // The FFI SQLite of the tests has FTS5 but no FTS4 (Android's has FTS4); fts4 mode then falls back to LIKE.
        unavailable = mode == FluentFullText.fts4 && !await hasFts4(docs);
        if (unavailable) markTestSkipped('this SQLite has no FTS4');
      });

      test('words in any column, all of them, case and diacritics ignored, any language', () async {
        if (unavailable) return;
        expect((await found('flutter')).toSet(), {'Flutter databases', 'Cooking'});
        expect(await found('flutter sqlite'), ['Flutter databases']);
        if (mode != FluentFullText.off) {
          expect(await found('животные'), ['Кошки и собаки'], reason: 'LIKE ignores case of ASCII letters only');
          expect(await found('cafe'), ['Café crème']);
        }
      });

      test('the last word is a prefix; quotes and operators are separators; empty text lists everything', () async {
        if (unavailable) return;
        expect(await found('datab'), ['Flutter databases']);
        if (mode != FluentFullText.off) expect(await docs.search('datab', prefix: false), isEmpty, reason: 'LIKE matches inside words');
        expect(await found('"flutter" -sqlite* (fluent'), ['Flutter databases']);
        expect(await found('  ""  '), hasLength(4));
      });

      test('every write updates the index; soft-deleted rows are not found', () async {
        if (unavailable) return;
        final Doc pasta = (await docs.search('pasta')).single;
        await docs.updateById(pasta.primaryKeyValue, {'body': 'risotto'});
        expect(await found('pasta'), isEmpty);
        expect(await found('risotto'), ['Cooking']);
        await docs.save(Doc(title: 'New flutter post'));
        expect(await found('flutter'), contains('New flutter post'));
        await docs.deleteWhere(FluentFilter.eq('title', 'Cooking'));
        expect(await found('risotto'), isEmpty);
        expect(await docs.withTrash.search('risotto'), hasLength(1));
        await docs.trash.deleteForeverWhere(FluentFilter.eq('title', 'Cooking'));
        expect(await docs.withTrash.search('risotto'), isEmpty);
      });

      test('FluentFilter.search combines with other conditions and other reads', () async {
        if (unavailable) return;
        await docs.updateWhere(FluentFilter.eq('title', 'Cooking'), {'views': 10});
        final FluentFilter f = FluentFilter.search('flutter').and(FluentFilter.gt('views', 5));
        expect([for (final Doc d in await docs.find(where: f)) d.title], ['Cooking']);
        expect(await docs.count(where: FluentFilter.search('flutter')), 2);
        expect(await found('flutter', where: FluentFilter.gt('views', 5)), ['Cooking']);
      });
    });
  }

  test('FTS5 ranks the best matches first; FluentDb.search', () async {
    await open();
    await docs.saveAll([
      Doc(title: 'one mention', body: 'a long text about many other things and dart once'),
      Doc(title: 'dart dart', body: 'dart everywhere: dart'),
    ]);
    expect((await FluentDb.search<Doc>('dart')).first.title, 'dart dart');
  });

  test('off: searches still work and a hint says they read every row', () async {
    await open(FluentFullText.off);
    await seed();
    await found('flutter');
    expect(FluentLog.shownHints.map((h) => h.kind), contains(FluentIssueKind.fullTextOff));
  });

  test('schema changes rebuild the index; removing it drops the FTS table; a model without one fails with a hint', () async {
    await open();
    await seed();
    Future<bool> ftsTable() async => (await docs.db.rawQuery("SELECT 1 FROM sqlite_master WHERE name = '__fluent_fts_docs'")).isNotEmpty;

    docText = ['title'];
    await open();
    expect(await found('sqlite'), isEmpty, reason: 'body is no longer indexed');
    expect(await found('databases'), ['Flutter databases']);

    docText = [];
    await open();
    expect(await ftsTable(), isFalse);
    await expectLater(docs.search('flutter'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('FluentIndex.fullText'))));

    docText = ['title', 'body'];
    await open();
    expect(await ftsTable(), isTrue);
    expect(await found('sqlite'), ['Flutter databases'], reason: 'filled from existing rows');
  });
}
