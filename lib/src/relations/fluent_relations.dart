// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../interfaces/interfaces.dart';
import 'fluent_relation.dart';

/// A model with relations to other models: references, owned children, shared many-to-many lists.
///
/// The relations are declared on the model, next to the fields that hold them; the providers of every related model
/// must be in the same `FluentGroup`. With this mixin the relation calls become available: `loadRelations`,
/// `findRelated`, `countRelated`, `attach`, `detach` (on the model, its provider and `FluentDb`).
///
/// ```dart
/// class Article extends FluentStorable with FluentRelations {
///   Article({this.id, required this.title, this.author, this.comments});
///
///   final int? id;
///   final String title;
///   final Person? author;
///   final List<Comment>? comments;
///
///   @override
///   Map<String, dynamic> buildJson() => {'id': id, 'title': title};
///
///   @override
///   List<FluentRelation> get relations => [
///     FluentRelation.one<Article, Person>('author', (a) => a.author),
///     FluentRelation.many<Article, Comment>('comments', (a) => a.comments, orderBy: 'id'),
///   ];
/// }
/// ```
mixin FluentRelations on FluentStorable {
  /// The relations of this model; each needs a unique [FluentRelation.name].
  List<FluentRelation> get relations;
}
