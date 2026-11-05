// Models used by the relation tests: an article with two references to Person (author, editor),
// an owned list (comments), shared tags (many-to-many), an owned profile (one-owned),
// and self-references (Person.manager, Category tree).
import 'package:fluent_sqflite/src/internal.dart';

class Person extends FluentStorable with FluentRelations {
  Person({this.id, required this.name, this.manager, this.profile});

  final int? id;
  final String name;
  final Person? manager;
  final Profile? profile;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  String toString() => 'Person($id, $name)';

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Person, Person>('manager', (p) => p.manager),
    FluentRelation.oneOwned<Person, Profile>('profile', (p) => p.profile),
  ];
}

class Profile extends FluentStorable {
  Profile({this.id, required this.bio});

  final int? id;
  final String bio;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'bio': bio};
}

class Comment extends FluentStorable with FluentSoftDeletable {
  Comment({this.id, required this.text, this.likes = 0});

  final int? id;
  final String text;
  final int likes;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'likes': likes};
}

class Tag extends FluentStorable with FluentRelations {
  Tag({this.id, required this.label, this.articles});

  final int? id;
  final String label;
  final List<Article>? articles;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};

  @override
  List<FluentRelation> get relations => [FluentRelation.manyToMany<Tag, Article>('articles', (t) => t.articles, lazy: true)];
}

class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.author, this.editor, this.comments, this.tags, this.topComments});

  final int? id;
  final String title;
  final Person? author;
  final Person? editor;
  final List<Comment>? comments;
  final List<Tag>? tags;
  final List<Comment>? topComments;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Article, Person>('author', (a) => a.author),
    FluentRelation.one<Article, Person>('editor', (a) => a.editor),
    FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'id'),
    FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags, orderBy: 'label'),
    // Read-only view over the same comments: two most liked, lazy, never written.
    FluentRelation<Article, Comment>(
      name: 'topComments',
      type: FluentRelationType.many,
      select: (a) => a.topComments,
      foreignKey: 'article_id',
      orderBy: 'likes DESC',
      where: FluentFilter.gt('likes', 0),
      limit: 2,
      lazy: true,
      keepMissing: true,
    ),
  ];
}

class Category extends FluentStorable with FluentRelations {
  Category({this.id, required this.name, this.parent, this.children});

  final int? id;
  final String name;
  final Category? parent;
  final List<Category>? children;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Category, Category>('parent', (c) => c.parent),
    FluentRelation.many<Category, Category>('children', (c) => c.children, orderBy: 'name'),
  ];
}

class PersonProvider extends FluentProvider<Person> {
  @override
  String get tableName => 'people';

  @override
  Person get modelSample => Person(name: '');

  @override
  Person fromCacheJson(Map<String, dynamic> json) =>
      Person(id: json['id'] as int?, name: json['name'] as String, manager: json['manager'] as Person?, profile: json['profile'] as Profile?);
}

class ProfileProvider extends FluentProvider<Profile> {
  @override
  String get tableName => 'profiles';

  @override
  Profile get modelSample => Profile(bio: '');

  @override
  Profile fromCacheJson(Map<String, dynamic> json) => Profile(id: json['id'] as int?, bio: json['bio'] as String);
}

class CommentProvider extends FluentProvider<Comment> {
  @override
  String get tableName => 'comments';

  @override
  Comment get modelSample => Comment(text: '');

  @override
  Comment fromCacheJson(Map<String, dynamic> json) => Comment(id: json['id'] as int?, text: json['text'] as String, likes: (json['likes'] as int?) ?? 0);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'tags';

  @override
  Tag get modelSample => Tag(label: '');

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(id: json['id'] as int?, label: json['label'] as String, articles: (json['articles'] as List?)?.cast<Article>());
}

class ArticleProvider extends FluentProvider<Article> {
  @override
  String get tableName => 'articles';

  @override
  Article get modelSample => Article(title: '');

  @override
  Article fromCacheJson(Map<String, dynamic> json) => Article(
    id: json['id'] as int?,
    title: json['title'] as String,
    author: json['author'] as Person?,
    editor: json['editor'] as Person?,
    comments: (json['comments'] as List?)?.cast<Comment>(),
    tags: (json['tags'] as List?)?.cast<Tag>(),
    topComments: (json['topComments'] as List?)?.cast<Comment>(),
  );
}

class CategoryProvider extends FluentProvider<Category> {
  @override
  String get tableName => 'categories';

  @override
  Category get modelSample => Category(name: '');

  @override
  Category fromCacheJson(Map<String, dynamic> json) =>
      Category(id: json['id'] as int?, name: json['name'] as String, parent: json['parent'] as Category?, children: (json['children'] as List?)?.cast<Category>());
}

List<FluentProvider> relationProviders() => [PersonProvider(), ProfileProvider(), CommentProvider(), TagProvider(), ArticleProvider(), CategoryProvider()];
