// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../exceptions/exceptions.dart';
import '../interfaces/interfaces.dart';
import '../utils/fluent_filter.dart';

/// What a relation means. The library derives columns, link tables, saving order and delete
/// behaviour from it — no SQL knowledge is needed.
enum FluentRelationType {
  /// A reference to another model, e.g. `Article.author → Person`.
  ///
  /// Stored as a column on **this** table (`author_id`). Deleting this row never deletes the
  /// referenced model; deleting the referenced model clears the column (default `onDelete`: [FluentOnDelete.setNull]).
  one,

  /// One child that belongs to this model, e.g. `User.profile → Profile`.
  ///
  /// Stored as a column on the **child** table (`user_id`). The child is deleted with its owner.
  oneOwned,

  /// A list of children that belong to this model, e.g. `Article.comments → [Comment]`.
  ///
  /// Stored as a column on the **child** table (`article_id`). Children are deleted with the owner;
  /// children removed from the list are deleted on save (to the trash when soft-deletable; unless `keepMissing`).
  many,

  /// A list of shared models, e.g. `Article.tags → [Tag]`.
  ///
  /// Stored in a link table created automatically. Saving only changes the links;
  /// the shared models themselves are never deleted through this relation.
  manyToMany,

  /// A reference to one model of several types, e.g. `Comment.target → Post or Photo` (see [FluentRelation.oneOf]).
  ///
  /// Stored in two columns on **this** table: `<name>_type` (the table of the referenced model) and `<name>_id`.
  /// SQLite cannot check such a reference, so the library does: deleting the referenced model clears the reference
  /// (or deletes this row, when the other side declares the list as owned: `many(..., via: '<name>')`).
  oneOf,

  /// Let the library decide from the whole database: the shape of `select` (list or single model),
  /// declarations on the other side, columns like `article_id`, and whether several models list the same type.
  ///
  /// When nothing decides, lists become [manyToMany] (never deletes shared data; `FluentGroup.autoRelationFallback`
  /// changes it) and single models [one]; the relation's `prefer` wins over both. An `auto` one-to-one pair (both
  /// models hold a single model of the other) keeps the table that stored its key on the last start. The choices and
  /// their reasons are reported once per database as an `autoRelations` hint, with the declarations that fix them.
  auto;

  /// Whether the relation holds a list.
  bool get isList => this == FluentRelationType.many || this == FluentRelationType.manyToMany;
}

/// What happens to the stored reference when the row it points to is deleted.
enum FluentOnDelete {
  /// Delete this row too.
  cascade('CASCADE'),

  /// Keep this row and clear the reference.
  setNull('SET NULL'),

  /// Refuse to delete the referenced row while this row points to it.
  restrict('RESTRICT');

  /// SQL keyword.
  final String sql;

  const FluentOnDelete(this.sql);
}

/// A relation of model [P] to model [C], declared in [FluentRelations.relations] of [P].
///
/// Use the shortcuts for the usual cases:
/// ```dart
/// @override
/// List<FluentRelation> get relations => [
///   FluentRelation.one<Article, Person>('author', (a) => a.author),
///   FluentRelation.one<Article, Person>('editor', (a) => a.editor),
///   FluentRelation.many<Article, Comment>('comments', (a) => a.comments),
///   FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags),
/// ];
/// ```
/// …or the full constructor when you want to set everything yourself (here a filtered second view of the same
/// comments, so it names their column explicitly):
/// ```dart
/// FluentRelation<Article, Comment>(
///   name: 'latestComments',
///   type: FluentRelationType.many,
///   select: (a) => a.latestComments,
///   foreignKey: 'article_id',
///   orderBy: 'created_at DESC',
///   limit: 5,
/// );
/// ```
///
/// The loaded value is passed to `fromCacheJson` under [name] (`json['author'] as Person?`,
/// `(json['comments'] as List?)?.cast<Comment>()`).
class FluentRelation<P extends FluentStorable, C extends FluentStorable> {
  /// Declares a relation. Everything except [name], [type] and [select] is optional; the library
  /// picks sensible defaults and explains its choice in the debug log.
  const FluentRelation({
    required this.name,
    required this.type,
    required this._select,
    this.foreignKey,
    this.linkTable,
    this.linkParentKey,
    this.linkChildKey,
    this.onDelete,
    this.lazy = false,
    this.keepMissing = false,
    this.orderBy,
    this.where,
    this.limit,
    this.includeDeleted = false,
    this.prefer,
    this.linkModel,
    this.parentVia,
    this.childVia,
    this.types = const [],
    this.via,
  });

  /// A relation whose type is decided by the library (see [FluentRelationType.auto]).
  ///
  /// ```dart
  /// FluentRelation.auto<Article, Comment>('comments', (a) => a.comments),
  /// FluentRelation.auto<Article, Person>('author', (a) => a.author),
  /// FluentRelation.auto<Article, Note>('notes', (a) => a.notes, prefer: FluentRelationType.many),
  /// ```
  /// [prefer] is used only when the database gives no clear signal; clear signals always win.
  static FluentRelation<P, C> auto<P extends FluentStorable, C extends FluentStorable>(
    String name,
    Object? Function(P parent) select, {
    FluentRelationType? prefer,
    String? foreignKey,
    String? linkTable,
    FluentOnDelete? onDelete,
    bool lazy = false,
    bool keepMissing = false,
    String? orderBy,
    FluentFilter? where,
    int? limit,
    bool includeDeleted = false,
  }) => FluentRelation<P, C>(
    name: name,
    type: FluentRelationType.auto,
    select: select,
    prefer: prefer,
    foreignKey: foreignKey,
    linkTable: linkTable,
    onDelete: onDelete,
    lazy: lazy,
    keepMissing: keepMissing,
    orderBy: orderBy,
    where: where,
    limit: limit,
    includeDeleted: includeDeleted,
  );

  /// A reference to another model, stored as `<name>_id` on this table (`<name>_<key column>` for a composite key).
  ///
  /// Saving the parent saves the referenced model first (upsert) and writes its key; a `null` value leaves the stored
  /// reference unchanged. [onDelete] defaults to [FluentOnDelete.setNull]: deleting the referenced model clears it.
  /// ```dart
  /// FluentRelation.one<Article, Person>('author', (a) => a.author),
  /// FluentRelation.one<Article, Person>('editor', (a) => a.editor, foreignKey: 'editor_person_id', onDelete: FluentOnDelete.restrict),
  /// ```
  static FluentRelation<P, C> one<P extends FluentStorable, C extends FluentStorable>(
    String name,
    C? Function(P parent) select, {
    String? foreignKey,
    FluentOnDelete? onDelete,
    bool lazy = false,
  }) => FluentRelation<P, C>(name: name, type: FluentRelationType.one, select: select, foreignKey: foreignKey, onDelete: onDelete, lazy: lazy);

  /// One child owned by this model (deleted together with it); the key column lives on the child table.
  ///
  /// [foreignKey] defaults to the column of a matching `one` back-reference on [C], otherwise `<model>_id`. [via]
  /// names the [oneOf] relation of [C] that points back (see [many]).
  /// ```dart
  /// FluentRelation.oneOwned<User, Profile>('profile', (u) => u.profile),
  /// ```
  static FluentRelation<P, C> oneOwned<P extends FluentStorable, C extends FluentStorable>(
    String name,
    C? Function(P parent) select, {
    String? foreignKey,
    String? via,
    FluentOnDelete? onDelete,
    bool lazy = false,
    bool includeDeleted = false,
  }) => FluentRelation<P, C>(
    name: name,
    type: FluentRelationType.oneOwned,
    select: select,
    foreignKey: foreignKey,
    via: via,
    onDelete: onDelete,
    lazy: lazy,
    includeDeleted: includeDeleted,
  );

  /// A list of children owned by this model: the key column lives on the child table, children are deleted with the
  /// owner, and on save children missing from the list are deleted (unless [keepMissing]; a `null` list leaves the
  /// stored children unchanged).
  ///
  /// [via] names the [oneOf] relation of [C] the children point back with. [where], [orderBy] and [limit] shape the
  /// loaded list (a filtered view of a list names the same column with [foreignKey]).
  /// ```dart
  /// FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'created_at DESC'),
  /// FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target'),
  /// ```
  static FluentRelation<P, C> many<P extends FluentStorable, C extends FluentStorable>(
    String name,
    List<C>? Function(P parent) select, {
    String? foreignKey,
    String? via,
    FluentOnDelete? onDelete,
    bool lazy = false,
    bool keepMissing = false,
    String? orderBy,
    FluentFilter? where,
    int? limit,
    bool includeDeleted = false,
  }) => FluentRelation<P, C>(
    name: name,
    type: FluentRelationType.many,
    select: select,
    foreignKey: foreignKey,
    via: via,
    onDelete: onDelete,
    lazy: lazy,
    keepMissing: keepMissing,
    orderBy: orderBy,
    where: where,
    limit: limit,
    includeDeleted: includeDeleted,
  );

  /// A list of shared models connected through an automatic link table.
  ///
  /// Saving the parent saves the related models (upsert) and replaces its links (merges them with [keepMissing]); the
  /// related models are never deleted through this relation. [linkTable] defaults to both table names, sorted and
  /// joined with `_` (`articles_tags`); [linkParentKey] / [linkChildKey] default to `<model>_id` (simple keys only).
  /// ```dart
  /// FluentRelation.manyToMany<Article, Tag>('tags', (a) => a.tags),
  /// FluentRelation.manyToMany<User, User>('friends', (u) => u.friends, linkParentKey: 'user_id', linkChildKey: 'friend_id'),
  /// ```
  static FluentRelation<P, C> manyToMany<P extends FluentStorable, C extends FluentStorable>(
    String name,
    List<C>? Function(P parent) select, {
    String? linkTable,
    String? linkParentKey,
    String? linkChildKey,
    bool lazy = false,
    bool keepMissing = false,
    String? orderBy,
    FluentFilter? where,
    int? limit,
    bool includeDeleted = false,
  }) => FluentRelation<P, C>(
    name: name,
    type: FluentRelationType.manyToMany,
    select: select,
    linkTable: linkTable,
    linkParentKey: linkParentKey,
    linkChildKey: linkChildKey,
    lazy: lazy,
    keepMissing: keepMissing,
    orderBy: orderBy,
    where: where,
    limit: limit,
    includeDeleted: includeDeleted,
  );

  /// A reference to one model of several [types] (a polymorphic reference), e.g. a comment on a post or a photo:
  /// ```dart
  /// // in Comment:
  /// FluentRelation.oneOf<Comment>('target', (c) => c.target, types: [Post, Photo]),
  /// // in Post (optional): the comments of a post, deleted with it
  /// FluentRelation.many<Post, Comment>('comments', (p) => p.comments, via: 'target'),
  /// ```
  /// Columns `target_type` (the table name: `posts`) and `target_id` are added to the table of [P]. The value is a
  /// [FluentStorable] (`json['target'] as FluentStorable?`, test it with `is Post`). A type with a composite key is
  /// stored in one column per key column (`target_user_id`, `target_day`). SQLite cannot check such a reference, so
  /// the library does: deleting a referenced model clears the reference ([onDelete] `setNull`, the default) or deletes
  /// the row ([FluentOnDelete.cascade], or when its side declares the list with `via:`, like any owned list).
  static FluentRelation<P, FluentStorable> oneOf<P extends FluentStorable>(
    String name,
    FluentStorable? Function(P parent) select, {
    required List<Type> types,
    FluentOnDelete? onDelete,
    bool lazy = false,
  }) => FluentRelation<P, FluentStorable>(name: name, type: FluentRelationType.oneOf, select: select, types: types, onDelete: onDelete, lazy: lazy);

  /// A list of [C] reached through the link model [L], for links that carry data of their own (a role, a date).
  ///
  /// [L] is an ordinary model with its own provider and a `one` relation to [P] and one to [C]:
  /// ```dart
  /// class Membership extends FluentStorable { User? user; Group? group; String role; ... }
  ///
  /// // in User:
  /// FluentRelation.many<User, Membership>('memberships', (u) => u.memberships), // the links with their data
  /// FluentRelation.through<User, Membership, Group>('groups', (u) => u.groups),  // the groups themselves
  /// ```
  /// The list is loaded (and filtered with `FluentFilter.related('groups', ...)`, counted) like any list; links
  /// in the trash or expired are left out (shown with [includeDeleted]). It is **read-only**: add and remove links
  /// with `users.attach(user, 'groups', [group], link: (g) => Membership(role: 'admin'))` / `detach`, or by saving
  /// [L] models; new models put into the list are not saved (reported).
  ///
  /// [parentVia] / [childVia] name the relations of [L] to use when [L] references [P] or [C] more than once
  /// (e.g. `Follow.follower` and `Follow.followee` for `User → Follow → User`).
  static FluentRelation<P, C> through<P extends FluentStorable, L extends FluentStorable, C extends FluentStorable>(
    String name,
    List<C>? Function(P parent) select, {
    String? parentVia,
    String? childVia,
    bool lazy = false,
    String? orderBy,
    FluentFilter? where,
    int? limit,
    bool includeDeleted = false,
  }) => FluentRelation<P, C>(
    name: name,
    type: FluentRelationType.manyToMany,
    select: select,
    linkModel: L,
    parentVia: parentVia,
    childVia: childVia,
    lazy: lazy,
    keepMissing: true,
    orderBy: orderBy,
    where: where,
    limit: limit,
    includeDeleted: includeDeleted,
  );

  /// Relation name: the key in `fromCacheJson`. Unique per model.
  final String name;

  /// What the relation means (see [FluentRelationType]).
  final FluentRelationType type;

  final Object? Function(P parent) _select;

  /// The column that stores the reference. Defaults: `<name>_id` on this table for [FluentRelationType.one];
  /// for owned children the column of a matching `one` back-reference on the child, otherwise `<model>_id`.
  /// Used for simple keys only: a composite key is stored in `<name>_<key column>` (`<model>_<key column>`) columns.
  final String? foreignKey;

  /// Name of the link table for [FluentRelationType.manyToMany] (default: both table names, sorted and joined with `_`;
  /// `<table>_<name>` for a model linked to itself or several lists of the same type).
  final String? linkTable;

  /// Column of the link table pointing to this model (default `<model>_id`).
  final String? linkParentKey;

  /// Column of the link table pointing to the related model (default `<related model>_id`, prefixed with `related_`
  /// when it equals [linkParentKey]).
  final String? linkChildKey;

  /// Delete rule of the stored reference. Defaults: [FluentOnDelete.setNull] for [FluentRelationType.one] and
  /// [FluentRelationType.oneOf], [FluentOnDelete.cascade] for owned children. Link table rows are always deleted with
  /// either side.
  ///
  /// A `one` back-reference and an owned list over the same column (`Category.parent` and `Category.children`, both
  /// `parent_id`) share one rule, carried by both relations: the declared one (the reference's, when both declare
  /// one), otherwise the reference's `setNull`. The `autoRelations` hint reports it when the two disagreed.
  final FluentOnDelete? onDelete;

  /// Load only on demand (`provider.loadRelations(model, names: ['name'])`, or reads with `relations: FluentLoad.all`)
  /// instead of with every query.
  final bool lazy;

  /// When saving a list, keep stored children / links that are missing from the list
  /// (by default the list is treated as complete).
  final bool keepMissing;

  /// SQL `ORDER BY` over the related table's columns for loaded lists, e.g. `'created_at DESC'` (also the default
  /// order of `findRelated`).
  final String? orderBy;

  /// Extra filter on the related rows of lists and owned children: applies to loads, `findRelated`, `countRelated`
  /// and `FluentFilter.related` conditions. May hold `related`, `search` and `ids` conditions.
  final FluentFilter? where;

  /// Maximum number of loaded items per owner (loads only: `countRelated` counts all, `findRelated` takes its own).
  final int? limit;

  /// Also load soft-deleted related models.
  final bool includeDeleted;

  /// For [FluentRelationType.auto]: the type to use when the database gives no clear signal.
  final FluentRelationType? prefer;

  /// For [through]: the link model whose rows connect [P] and [C].
  final Type? linkModel;

  /// For [through]: the relation of the link model that points to [P] (needed when there are several).
  final String? parentVia;

  /// For [through]: the relation of the link model that points to [C] (needed when there are several).
  final String? childVia;

  /// For [oneOf]: the model types the reference may point to.
  final List<Type> types;

  /// For an owned list ([many] / [oneOwned]): the [oneOf] relation of [C] that points back to [P].
  final String? via;

  /// Whether `select` returns a list (`true`), a single model (`false`), or `null` when its static type
  /// does not tell (e.g. `dynamic`). Read from the function's runtime type, no instance needed.
  bool? get selectsList {
    if (_select is Iterable<Object?>? Function(P)) return true;
    if (_select is FluentStorable? Function(P)) return false;
    return null;
  }

  /// The parent model type.
  Type get parentType => P;

  /// The related model type.
  Type get childType => C;

  /// Whether the relation holds a list (for [FluentRelationType.auto]: as far as `select` tells).
  bool get isList => type == FluentRelationType.auto ? (selectsList ?? false) : type.isList;

  /// Reads the related value(s) from [parent]. Throws a [FluentRelationException] with a hint when
  /// [parent] is not a [P].
  Object? selectFrom(FluentStorable parent) {
    if (parent is! P) {
      throw FluentRelationException(
        'Relation "$name" expects a parent of type $P but got ${parent.runtimeType}.',
        hint: 'Declare it as FluentRelation<${parent.runtimeType}, $C>.',
      );
    }
    return _select(parent);
  }

  @override
  String toString() => 'FluentRelation<$P, $C>($name, ${linkModel == null ? type.name : 'through $linkModel'})';
}
