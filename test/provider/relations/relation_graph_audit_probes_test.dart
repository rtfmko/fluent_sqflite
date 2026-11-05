// Audit tests for relation declarations, graph resolution and relation storage.
// The models are named without a leading underscore on purpose: the default reference column is `<model>_id` in
// snake case, and the bug under test depends on that name.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Owns a list of comments.
class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.comments});

  final int? id;
  final String title;
  final List<Comment>? comments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Article, Comment>('comments', (a) => a.comments)];
}

/// Two references to an article: `article` (default column `article_id`) and `featured`.
class Comment extends FluentStorable with FluentRelations {
  Comment({this.id, required this.text, this.article, this.featured});

  final int? id;
  final String text;
  final Article? article;
  final Article? featured;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Comment, Article>('article', (c) => c.article),
    FluentRelation.one<Comment, Article>('featured', (c) => c.featured),
  ];
}

class ArticleProvider extends FluentProvider<Article> {
  @override
  String get tableName => 'rg_articles';

  @override
  Article get modelSample => Article(title: '');

  @override
  Article fromCacheJson(Map<String, dynamic> json) =>
      Article(id: json['id'] as int?, title: json['title'] as String, comments: (json['comments'] as List?)?.cast<Comment>());
}

class CommentProvider extends FluentProvider<Comment> {
  @override
  String get tableName => 'rg_comments';

  @override
  Comment get modelSample => Comment(text: '');

  @override
  Comment fromCacheJson(Map<String, dynamic> json) => Comment(
    id: json['id'] as int?,
    text: json['text'] as String,
    article: json['article'] as Article?,
    featured: json['featured'] as Article?,
  );
}

Future<int> _count(Database sql, String table) async => (await sql.rawQuery('SELECT COUNT(*) AS c FROM "$table"')).first['c']! as int;

/// Opens a fresh database with the two models; [body] gets the article provider and the raw database.
Future<void> _withDb(Future<void> Function(ArticleProvider articles, Database sql) body) async {
  final FluentTestDb db = FluentTestDb(name: 'rg_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
  final List<FluentProvider> providers = [ArticleProvider(), CommentProvider()];
  await db.open(providers);
  try {
    await body(providers.whereType<ArticleProvider>().single, providers.whereType<ArticleProvider>().single.db);
  } finally {
    await db.close();
  }
}

void main() {
  setUpFluentTests();

  group('relation graph', () {
    test('RG-1a owned list shares the column of the reference named like its owner (one relation, two ends)', () async {
      await _withDb((articles, sql) async {
        // Two `one` back-references make the owned list ambiguous. The graph logs "it uses its own column" but falls
        // back to `article_id`, which is the column of `Comment.article`.
        final FluentRelationLink commentsLink = articles.relationLinks.singleWhere((l) => l.name == 'comments');
        expect(commentsLink.foreignKeys, ['article_id'], reason: 'Comment.article is the other end of Article.comments; the rule is the list CASCADE');
        expect(commentsLink.onDelete, FluentOnDelete.cascade);
      });
    });

    test('RG-1b deleting the article deletes its owned comments (foreign keys on)', () async {
      await _withDb((articles, sql) async {
        final Article article = Article(title: 'A', comments: [Comment(text: 'c1'), Comment(text: 'c2')]);
        await articles.save(article);
        expect(await _count(sql, 'rg_comments'), 2);
        await articles.delete(article);
        // An owned list is deleted with its owner (default onDelete: cascade). The shared column takes the reference's
        // SET NULL instead, so the comments survive without an owner.
        expect(await _count(sql, 'rg_comments'), 0, reason: 'comments are owned by the article and must be deleted with it');
      });
    });

    test('declarations are never mutated by the graph build', () async {
      final Comment sample = Comment(text: '');
      final List<FluentRelation> declared = sample.relations;
      expect(declared.first.onDelete, isNull);
      expect(declared.first.foreignKey, isNull);
    });
  });
}
