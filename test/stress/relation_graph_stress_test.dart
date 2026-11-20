// Stress: big relation graphs (G1, G3, G6, G21, G19, N+1 guards on a big world).
//
// 1. A category tree (self-reference, children ordered by name) of depth 5 and breadth 4 (1365 nodes) per scale step,
//    saved with ONE save of its root, loaded back to its full depth and compared node by node; the statements of
//    the load grow with the depth and the chunks of 900 keys, never with the nodes.
// 2. scaled(2000) articles, each with an author and an editor from a shared pool of people, up to 10 owned comments
//    and up to 5 shared tags, saved in graph batches; read back with every relation and compared; the statements of
//    the read grow with the chunks, never with the rows. Then half the articles are deleted: their comments go with
//    them, the people and tags (only referenced) stay.
//
// FLUENT_STRESS=20 bash tool/mirror_test.sh stress test/stress/relation_graph_stress_test.dart
library;

import 'dart:math';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/guarantees.dart';
import '../helpers/query_counter.dart';
import '../helpers/relation_models.dart';
import 'stress.dart';

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late List<FluentProvider> providers;

  setUp(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'stress_graph_${DateTime.now().microsecondsSinceEpoch}');
    providers = relationProviders();
    await db.open(providers);
  });

  tearDown(() async {
    await db.close();
    counter.uninstall();
  });

  T provider<T>() => providers.whereType<T>().single;

  test('deep category trees are saved in one call and loaded back whole without N+1', timeout: Timeout(stressLimit()), () async {
    final StressReport report = StressReport('category trees');
    final CategoryProvider categories = provider<CategoryProvider>();
    const int depth = 5;
    const int breadth = 4;
    final int trees = stressScale();

    // Names are paths with fixed-width parts, so "ordered by name" is the order they were built in.
    Category build(String name, int level) =>
        Category(name: name, children: level == depth ? [] : [for (int i = 0; i < breadth; i++) build('$name.$i', level + 1)]);
    int nodesOf(Category c) => 1 + (c.children ?? const []).fold(0, (s, k) => s + nodesOf(k));

    for (int t = 0; t < trees; t++) {
      final Category tree = build('r${t.toString().padLeft(4, '0')}', 0);
      final int nodes = nodesOf(tree);
      await report.step('save tree $t ($nodes nodes) in one call', () => categories.save(tree));

      counter.reset();
      final Category loaded = await report.step(
        'load tree $t to depth $depth',
        () async => (await categories.find(where: FluentFilter.eq('name', tree.name), maxDepth: depth)).single,
        detail: (_) => '${counter.reads} reads',
      );
      void same(Category expected, Category got, int level) {
        expect(got.name, expected.name, reason: 'G6: node at level $level');
        if (level == depth) return;
        expect(got.children?.map((c) => c.name).toList(), expected.children!.map((c) => c.name).toList(), reason: 'G6: children of ${expected.name}');
        for (int i = 0; i < expected.children!.length; i++) {
          same(expected.children![i], got.children![i], level + 1);
        }
      }

      same(tree, loaded, 0);
      // Per level: the children, their parent back-reference, a chunk per 900 keys. A load per node would need
      // $nodes reads.
      final int bound = (depth + 1) * 4 + 4 * (nodes ~/ 900 + 1);
      expect(counter.reads, lessThanOrEqualTo(bound), reason: 'N+1: $nodes nodes loaded with ${counter.reads} reads:\n${counter.statements.take(40).join('\n')}');
    }
    expect(await categories.count(), trees * 1365, reason: 'G1: every node stored once');
    await expectIntegrity(categories.db, reason: 'stress trees');
    report.save();
  });

  test('thousands of articles with shared and owned relations read back whole without N+1', timeout: Timeout(stressLimit(secondsPerScale: 90)), () async {
    final StressReport report = StressReport('article graph');
    final ArticleProvider articles = provider<ArticleProvider>();
    final PersonProvider people = provider<PersonProvider>();
    final TagProvider tags = provider<TagProvider>();
    final CommentProvider comments = provider<CommentProvider>();
    final Random r = Random(77);
    final int total = scaled(2000);

    await people.saveAll([for (int i = 0; i < 100; i++) Person(id: i + 1, name: 'person $i')]);
    await tags.saveAll([for (int i = 0; i < 50; i++) Tag(id: i + 1, label: 'tag ${i.toString().padLeft(2, '0')}')]);
    Person person(int i) => Person(id: i + 1, name: 'person $i');
    Tag tag(int i) => Tag(id: i + 1, label: 'tag ${i.toString().padLeft(2, '0')}');

    // The reference: what each article must read back as.
    final Map<int, ({int author, int editor, List<String> comments, List<int> tags})> ref = {};
    int commentId = 0;
    await report.step('save $total article graphs in batches of 200', () async {
      for (int from = 1; from <= total; from += 200) {
        final List<Article> batch = [];
        for (int id = from; id < min(from + 200, total + 1); id++) {
          final int author = r.nextInt(100);
          final int editor = r.nextInt(100);
          final List<String> texts = [for (int c = r.nextInt(11); c > 0; c--) 'comment ${++commentId}'];
          final List<int> tagIds = (List<int>.generate(50, (i) => i)..shuffle(r)).take(r.nextInt(6)).toList()..sort();
          ref[id] = (author: author, editor: editor, comments: texts, tags: tagIds);
          batch.add(Article(
            id: id,
            title: 'article $id',
            author: person(author),
            editor: person(editor),
            comments: [for (final String t in texts) Comment(text: t)],
            tags: [for (final int t in tagIds) tag(t)],
          ));
        }
        await articles.saveAll(batch);
      }
    });

    Future<void> expectAllSame(String why) async {
      counter.reset();
      final List<Article> all = await report.step('read every article with its relations ($why)', () => articles.findAll(orderBy: 'id'), detail: (all) => '${all.length} rows, ${counter.reads} reads');
      expect(all.map((a) => a.id).toList(), (ref.keys.toList()..sort()), reason: 'G1 $why: the articles');
      for (final Article a in all) {
        final e = ref[a.id]!;
        expect(a.author?.name, 'person ${e.author}', reason: 'G6 $why: author of ${a.id}');
        expect(a.editor?.name, 'person ${e.editor}', reason: 'G6 $why: editor of ${a.id}');
        expect(a.comments?.map((c) => c.text).toList(), e.comments, reason: 'G6 $why: comments of ${a.id} (in id order)');
        expect(a.tags?.map((t) => t.label).toList(), [for (final int t in e.tags) tag(t).label], reason: 'G6 $why: tags of ${a.id} (by label)');
      }
      // articles + people (two references) + comments + link table + tags, each once per chunk of 900 owners.
      final int bound = 8 * (all.length ~/ 900 + 1);
      expect(counter.reads, lessThanOrEqualTo(bound), reason: 'N+1 $why: ${all.length} articles read with ${counter.reads} reads:\n${counter.statements.take(40).join('\n')}');
    }

    await expectAllSame('after the save');

    // Delete every second article: owned comments go with their article; people and tags are only referenced (G21).
    final List<int> gone = [for (final int id in ref.keys) if (id.isEven) id];
    await report.step('delete ${gone.length} articles', () => articles.deleteWhere(FluentFilter.ids(gone)));
    gone.forEach(ref.remove);
    await expectAllSame('after deleting half');
    expect(await comments.count(), ref.values.fold<int>(0, (s, e) => s + e.comments.length), reason: 'the comments of deleted articles are deleted with them');
    expect(await people.count(), 100, reason: 'G21: referenced people stay');
    expect(await tags.count(), 50, reason: 'G21: shared tags stay');
    await expectIntegrity(articles.db, reason: 'stress articles');
    report.save();
  });
}
