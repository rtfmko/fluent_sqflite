---
name: fluent-sqflite-relations
description: >-
  Use when the user is modeling or using relations between fluent_sqflite models: FluentRelations on the model and
  FluentRelation (one, oneOwned, many, manyToMany, through with a link model, oneOf polymorphic references, auto),
  relations found from buildJson fields without declarations (autoRelations), reading related models in
  fromCacheJson, FluentLoad / maxDepth and lazy relations, loadRelations, findRelated, findParents, countRelated,
  saving model graphs, attach / detach (link: for through), keepMissing and delete rules.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: relations

## Rules

- Declare relations on the **model** with `with FluentRelations` and `List<FluentRelation> get relations`.
  Do not add `author_id`-style columns or link tables yourself: they are derived.
- Pick the type by meaning:
  - `one` — a reference to an independent model (`Article.author → Person`); deleting the article keeps the person.
  - `oneOwned` — one child that belongs to the owner (`User.profile`); deleted with the owner.
  - `many` — children that belong to the owner (`Article.comments`); deleted with the owner.
  - `manyToMany` — shared models (`Article.tags`); only the links are changed or removed.
  - `through` — shared models with data on the link (`User.groups` through a `Membership` model with a role).
  - `oneOf` — a reference to one of several types (`Comment.target`: post or photo); `many(..., via:)` on the owner.
  - `auto` — let the library decide when unsure (it reports the choice in the `autoRelations` hint).
- Fields need no declaration when the library can see them: put them into `buildJson` with a typed value in the
  sample (`posts: const []`, `profile: Profile(bio: '')`). The `autoRelations` hint lists what was decided with the
  declarations to copy; declare a relation when the guess is wrong (a declaration always wins).
  `FluentConfig(autoRelations: false)` turns the search off.
- Always pass both generic types: `FluentRelation.many<Article, Comment>(...)`.
- Read the relation in `fromCacheJson` under its name: `json['author'] as Person?`,
  `(json['comments'] as List?)?.cast<Comment>()`. Keep the field nullable: `null` means "not loaded".
- A `null` relation on save means "not loaded": stored data is untouched. A list (even empty) replaces the stored
  one — removed `many` children are deleted, removed `manyToMany` links are unlinked. Use `keepMissing: true` or
  `attach` / `detach` to change lists partially.
- Reads load the eager relations one level deep (`relations: FluentLoad.eager`, `maxDepth: 1`). For lists use
  `relations: FluentLoad.none` and load later with `model.loadRelations()`; mark big relations `lazy: true`.
  Loading is batched (one query per relation and level): never load relations in a loop per model.
- Models are immutable: `loadRelations` returns a loaded copy, it does not fill the instance.
- The relation calls (`loadRelations`, `findRelated`, `countRelated`, `attach`, `detach`) exist only for models with
  `FluentRelations`. `findParents<P>()` works on any model whose parent `P` has relations.
- All providers of a relation belong to the same `FluentGroup`. A relation target type must be stored in one table only.

- A list and a back-reference named like the owner share one column and cascade; declare `onDelete` on the reference
  to keep `SET NULL`. Trash scopes do not reach relation loads: use `includeDeleted: true` for trashed related rows.

## Declaring

```dart
class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.author, this.comments, this.tags});

  final int? id;
  final String title;
  final Person? author;
  final List<Comment>? comments;
  final List<Tag>? tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title}; // no relation fields here

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Article, Person>('author', (a) => a.author),
    FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'created_at'),
    FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags, lazy: true),
  ];
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
    comments: (json['comments'] as List?)?.cast<Comment>(),
    tags: (json['tags'] as List?)?.cast<Tag>(),
  );
}
```

## Data on the link (`through`) and several types (`oneOf`)

```dart
// in User: memberships carry the role, groups are reached through them (read-only list)
FluentRelation.many<User, Membership>('memberships', (u) => u.memberships),
FluentRelation.through<User, Membership, Group>('groups', (u) => u.groups),
await user.attach('groups', [admins], link: (g) => Membership(role: 'admin')); // writes a Membership
await user.detach('groups', [admins]);                                       // removes it (trash if soft-deletable)

// in Comment: one of several types (columns target_type + target_id)
FluentRelation.oneOf<Comment>('target', (c) => c.target, types: [Post, Photo]),
// in Post: its comments, deleted / trashed / restored with it
FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target'),
```

- `Membership` is an ordinary model with a `one` relation (or field) to each side; `parentVia` / `childVia` name them
  when it references a model twice. Moving from `manyToMany`: give the link model the old link table name.
- `oneOf` values are `FluentStorable?` (`json['target'] as FluentStorable?`); a composite target key gets one column per
  key column. Filter it like any relation: `FluentFilter.related<Post>('target', where)` picks one type, without the
  type argument any type counts and `where` applies to each.

## Loading

```dart
final Article? a = await FluentDb.findById<Article>(1);                       // author + comments, tags not (lazy)
final List<Article> list = await FluentDb.findAll<Article>(relations: FluentLoad.none); // rows only
final Article full = await list.first.loadRelations();                        // everything, lazy ones too
final Article withTags = await a!.loadRelations(names: ['tags']);
final List<Article> deep = await FluentDb.findAll<Article>(maxDepth: 2);      // comments' relations too
final List<Article> all = await FluentDb.findAll<Article>(relations: FluentLoad.all);
a.isRelationLoaded('tags');                                                  // false
```

## Querying relations and parents

```dart
final List<Comment> top = await a.findRelated<Comment>('comments', where: FluentFilter.gt('likes', 5), orderBy: 'likes DESC', limit: 10);
final int n = await a.countRelated('comments');
final Article? owner = (await comment.findParents<Article>()).firstOrNull;
final List<Article> tagged = await dart.findParents<Article>(orderBy: 'title');  // many-to-many backwards
final List<Article> byAnn = await ann.findParents<Article>(via: 'author');       // several relations to Person
```

## Filtering by relations

```dart
await FluentDb.find<Article>(where: FluentFilter.related('author', FluentFilter.eq('name', 'Ann')));
await FluentDb.find<Article>(where: FluentFilter.notRelated('tags'));
await FluentDb.find<Article>(where: FluentFilter.relatedCount('comments', min: 5));
```

Works for every relation type and in every read, `count`, aggregates, `deleteWhere` and `watch`; paths follow several
relations (`'author.company'`). Reference columns are indexed (`indexReferences`, on by default).

## Saving

```dart
await Article(title: 'Hi', author: ann, comments: [Comment(text: 'first')], tags: [dart]).save();
await article.attach('tags', [flutter]);
await article.detach('tags', [dart]);
await article.update(withRelations: true); // keeps rows missing from the lists (preserveLocal)
```

A `one` and an owned list over the same column share one delete rule (the declared one, else `setNull`); an auto
one-to-one pair keeps the table that stored its key last time.

Options: `foreignKey`, `onDelete: FluentOnDelete.setNull / cascade / restrict`, `orderBy`, `where`, `limit`,
`includeDeleted`, `keepMissing`, `lazy`; `manyToMany`: `linkTable`, `linkParentKey`, `linkChildKey`; `through`:
`parentVia`, `childVia`; owned lists through a `oneOf`: `via`.

A relation that changes its kind between versions (many-to-many ↔ owned list) keeps its data: the links are copied
on the next start (`relationDataMoved`), or kept with a `relationChanged` warning when they do not fit.

Full constructor for read-only views:

```dart
FluentRelation<Article, Comment>(
  name: 'topComments',
  type: FluentRelationType.many,
  select: (a) => a.topComments,
  foreignKey: 'article_id',
  orderBy: 'likes DESC',
  limit: 3,
  lazy: true,
  keepMissing: true,
),
```
