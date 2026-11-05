# Relations

Declare relations on the model with `FluentRelations`, next to the fields that hold them; the library derives the
columns, link tables, saving order and delete rules.

```dart
class Article extends FluentStorable with FluentRelations {
  Article({this.id, required this.title, this.author, this.comments, this.tags, this.cover});

  final int? id;
  final String title;
  final Person? author;
  final List<Comment>? comments;
  final List<Tag>? tags;
  final Cover? cover;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Article, Person>('author', (a) => a.author),         // column author_id on articles
    FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'id'), // article_id on comments
    FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags),          // link table, created automatically
    FluentRelation.oneOwned<Article, Cover>('cover', (a) => a.cover),       // article_id on covers
  ];
}
```

| Type | Meaning | Stored as | Deleting the owner |
|---|---|---|---|
| `one` | a reference (`Article.author`) | column on this table | keeps the referenced model |
| `oneOwned` | one child (`User.profile`) | column on the child | deletes the child |
| `many` | owned children (`Article.comments`) | column on the children | deletes the children |
| `manyToMany` | shared models (`Article.tags`) | link table | removes only the links |
| `through` | shared models with data on the link (`User.groups` through `Membership`) | the link model's table | removes only the links |
| `oneOf` | a reference to one of several types (`Comment.target`: a post or a photo) | `<name>_type` + `<name>_id` on this table | keeps the referenced model |
| `auto` | decided at init from the whole database | — | — |

`FluentRelation.auto<Article, Comment>('comments', (a) => a.comments)` lets the library choose. Every provider of a
relation must be in the same `FluentGroup`.

## Relations without declarations

A field that holds another stored model needs no declaration at all: put it into `buildJson` and give the sample a
value of that type, so the library can see it (a list of a known type, even empty, or a model instance).

```dart
class User extends FluentStorable {
  User({this.id, required this.name, this.posts = const [], this.profile});
  final int? id;
  final String name;
  final List<Post> posts;
  final Profile? profile;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'posts': posts, 'profile': profile};
}
// UserProvider: User get modelSample => User(name: '', profile: Profile(bio: ''));
```

At init the library looks at every provider of the database and decides each kind from both sides:

* `User.posts` + `Post.author` → `many` (column `posts.author_id`); both sides lists → `manyToMany`;
* `User.profile` + `Profile.user` → one-to-one with a single key column, on the table fewer relations point to
  (`profiles.user_id`); once stored, the pair keeps that table on later starts (switching `one` ↔ `oneOwned` moves the
  keys, `relationDataMoved`);
* a list with nothing on the other side → `manyToMany`: a guess never deletes data. Declare `many` when each post
  belongs to one user.

One hint (`autoRelations`) lists everything decided, with the declarations to copy; a declaration always wins. Turn
the search off with `FluentConfig(autoRelations: false)` (or per database / table). A field holding a model no
provider of the database stores is reported, never silently dropped. If a later version changes the kind of a
relation (a post gets `author`, so `User.posts` becomes `many`), the links are copied to the new place on the next
start (`relationDataMoved`); a post linked to several users is not moved, and a warning says why.

The relation calls below exist only for models with `FluentRelations` — on the model itself, on its provider and on
`FluentDb`.

## Data on the link: `through`

When a link needs data of its own (a role, a date), make it a model with a `one` relation (or a field) to each side,
and reach the other side through it:

```dart
class Membership extends FluentStorable { /* id, role, User? user, Group? group */ }

// in User:
FluentRelation.many<User, Membership>('memberships', (u) => u.memberships), // the links with their data
FluentRelation.through<User, Membership, Group>('groups', (u) => u.groups),  // the groups themselves
```

`groups` loads, filters (`FluentFilter.related('groups', ...)`) and counts like any list; memberships in the trash or
expired are left out. It is read-only: add links with
`await user.attach('groups', [admins], link: (g) => Membership(role: 'admin'))` (the references are filled in, a
group already linked is skipped) and remove them with `detach` (the memberships go to the trash when `Membership` is
soft-deletable). When the link model references a model twice (`Follow.follower`, `Follow.followee`), name them:
`through<Person, Follow, Person>('following', ..., parentVia: 'follower', childVia: 'followee')`.

Moving from `manyToMany` to a link model keeps the links: give the link model the old link table's name.

## One of several types: `oneOf`

```dart
// in Comment: the comment is on a post, a photo or a video
FluentRelation.oneOf<Comment>('target', (c) => c.target, types: [Post, Photo, Video]),
// in Post (optional): the comments of a post; deleted, trashed and restored with it
FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target'),
```

The table gets `target_type` (the referenced table, e.g. `posts`) and `target_id`; a type with a composite key gets one
column per key column (`target_user_id`, `target_day`). The value is a `FluentStorable`
(`json['target'] as FluentStorable?`, then `is Post`). SQLite cannot check such a reference, so the library does:
deleting a post deletes its comments (the post declares the list), deleting a video clears the reference. A list field
of comments found in `buildJson` is matched with the `oneOf` too.

Filter by the reference like any relation; the type argument picks one type, without it any type counts and the
condition applies to each:

```dart
await comments.find(where: FluentFilter.related('target'));                                     // on anything
await comments.find(where: FluentFilter.related<Post>('target', FluentFilter.eq('title', 'x'))); // on post "x"
await comments.find(where: FluentFilter.notRelated('target'));                                  // on nothing
```

## Reading relation values

The loaded value arrives in `fromCacheJson` under the relation name:

```dart
@override
Article fromCacheJson(Map<String, dynamic> json) => Article(
  id: json['id'] as int?,
  title: json['title'] as String,
  author: json['author'] as Person?,
  comments: (json['comments'] as List?)?.cast<Comment>(),
  tags: (json['tags'] as List?)?.cast<Tag>(),
);
```

Every read takes `relations:` — `FluentLoad.eager` (default: the relations without `lazy: true`), `FluentLoad.none`
(only the rows, fastest) or `FluentLoad.all` (lazy ones too) — and `maxDepth` (default 1: the relations of the related
models are not loaded). Relations load batched: one query per relation and level, never per row.

Load the relations later, when they are needed. Models are immutable, so `loadRelations` returns a loaded copy:

```dart
final Article bare = (await FluentDb.findById<Article>(id, relations: FluentLoad.none))!; // just the row
final Article full = await bare.loadRelations();                     // every relation, lazy ones too
final Article some = await bare.loadRelations(names: ['comments']);  // only these (besides the eager ones)
bare.isRelationLoaded('comments');                                   // false: it was not read
```

## Querying relations

Query a relation instead of loading it (with a filter, order and paging), count it, or go the other way: from a model
to the models that point to it.

```dart
final List<Comment> liked = await article.findRelated<Comment>('comments', where: FluentFilter.gt('likes', 10), limit: 20);
final int n = await article.countRelated('comments');                  // count without loading
final Article? owner = (await comment.findParents<Article>()).firstOrNull;
final List<Article> written = await ann.findParents<Article>(via: 'author'); // Article has author and editor
```

`findParents` works on any model (the parent needs `FluentRelations`); `via` names the relation when the parent has
several to this model. To filter parents by their related models, use `FluentFilter.related` (see [Reading](reading.md)).

A `one` reference and an owned list over the same column (`Category.parent` / `children`) share one delete rule: the
declared one, else the reference's (`setNull`); the `autoRelations` hint lists such columns.

Options per relation: `foreignKey`, `onDelete` (`cascade`, `setNull`, `restrict`), `orderBy`, `where`, `limit`,
`includeDeleted`, `keepMissing`, `lazy`; for many-to-many `linkTable`, `linkParentKey`, `linkChildKey`.

## Saving a graph

`save` writes the model and its related models in one transaction. A list replaces what is stored: children removed
from a `many` list are deleted, tags removed from a `manyToMany` list are unlinked (`keepMissing: true` keeps them).
A `null` relation means *not loaded* — the stored data is left untouched.

```dart
await Article(title: 'Hi', author: ann, comments: [Comment(text: 'first')], tags: [dart, flutter]).save();
await article.update(withRelations: true); // syncMode: preserveLocal keeps rows missing from the lists
await article.attach('tags', [newTag]);     // add without rewriting the list
await article.detach('tags', [oldTag]);
```

## Rules

* One model type stored in several tables cannot be the target of a relation (the relation would not know the
  table): give each table its own model type.
* Self-references (trees, `Person.manager`) and composite keys on either side work.
* Soft delete cascades to owned soft-deletable children and comes back with `restore`.

* A list and a back-reference named like its owner (`Article.comments` and `Comment.article`) are one relation: they
  share the column and the children are deleted with the owner, unless the reference declares `onDelete`. A
  reference named otherwise (`Category.parent` next to `children`) keeps its own rule (`SET NULL`).
* Relation loads use the relation's own visibility, not the trash scope of the call: `trash.find(relations: ...)` and
  `withTrash` load live related rows; trashed ones show only with `includeDeleted: true` (and owned children trashed
  together with their owner).
* `cleanupOrphans` leaves dangling rows of `RESTRICT` links alone and reports them (`danglingReferences`).
