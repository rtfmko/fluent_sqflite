// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.
// Internal to the package (not exported): no public API docs needed.
// ignore_for_file: public_member_api_docs

import 'package:fluent_sqflite/fluent_sqflite.dart';

// A blog-like model set for the scenarios: posts with an author, comments (owned, soft delete, each with an author),
// tags (many-to-many); accounts with a unique e-mail; entries with a limited eager list.

class BenchPerson extends FluentStorable {
  BenchPerson({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class BenchTag extends FluentStorable {
  BenchTag({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class BenchComment extends FluentStorable with FluentSoftDeletable, FluentRelations {
  BenchComment({this.id, required this.text, this.likes = 0, this.author});

  final int? id;
  final String text;
  final int likes;
  final BenchPerson? author;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'likes': likes};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<BenchComment, BenchPerson>('author', (c) => c.author)];
}

/// A post. [only] limits the declared relations to the named ones, so one benchmark database measures one relation
/// kind (`null`: all of them).
class BenchPost extends FluentStorable with FluentSoftDeletable, FluentRelations {
  BenchPost({this.id, required this.title, this.author, this.comments, this.tags, this.only});

  final int? id;
  final String title;
  final BenchPerson? author;
  final List<BenchComment>? comments;
  final List<BenchTag>? tags;
  final Set<String>? only;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [
    if (only == null || only!.contains('author')) FluentRelation.one<BenchPost, BenchPerson>('author', (p) => p.author),
    if (only == null || only!.contains('comments')) FluentRelation.many<BenchPost, BenchComment>('comments', (p) => p.comments, orderBy: 'id'),
    if (only == null || only!.contains('tags')) FluentRelation.manyToMany<BenchPost, BenchTag>('tags', (p) => p.tags, orderBy: 'label'),
  ];
}

class BenchNote extends FluentStorable {
  BenchNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

/// An entry with a long list of notes of which only the last [limit] are loaded (eager, window path).
class BenchEntry extends FluentStorable with FluentRelations {
  BenchEntry({this.id, required this.title, this.notes});

  static const int limit = 3;

  final int? id;
  final String title;
  final List<BenchNote>? notes;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<BenchEntry, BenchNote>('notes', (e) => e.notes, orderBy: 'id DESC', limit: limit)];
}

/// A row identified by its unique e-mail (the `conflictOn` upsert).
class BenchAccount extends FluentStorable {
  BenchAccount({this.id, required this.email, required this.name});

  final int? id;
  final String email;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'email': email, 'name': name};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isNotNull: true, isUnique: true), FluentDbColumn.text('name', isNotNull: true)];
}

class BenchPersonProvider extends FluentProvider<BenchPerson> {
  @override
  String get tableName => 'bench_people';

  @override
  BenchPerson get modelSample => BenchPerson(name: '');

  @override
  BenchPerson fromCacheJson(Map<String, dynamic> json) => BenchPerson(id: json['id'] as int?, name: json['name'] as String);
}

class BenchTagProvider extends FluentProvider<BenchTag> {
  @override
  String get tableName => 'bench_tags';

  @override
  BenchTag get modelSample => BenchTag(label: '');

  @override
  BenchTag fromCacheJson(Map<String, dynamic> json) => BenchTag(id: json['id'] as int?, label: json['label'] as String);
}

class BenchCommentProvider extends FluentProvider<BenchComment> {
  @override
  String get tableName => 'bench_comments';

  @override
  BenchComment get modelSample => BenchComment(text: '');

  @override
  BenchComment fromCacheJson(Map<String, dynamic> json) =>
      BenchComment(id: json['id'] as int?, text: json['text'] as String, likes: (json['likes'] as int?) ?? 0, author: json['author'] as BenchPerson?);
}

class BenchPostProvider extends FluentProvider<BenchPost> {
  BenchPostProvider({this.only});

  final Set<String>? only;

  @override
  String get tableName => 'bench_posts';

  @override
  BenchPost get modelSample => BenchPost(title: '', only: only);

  @override
  BenchPost fromCacheJson(Map<String, dynamic> json) => BenchPost(
    id: json['id'] as int?,
    title: json['title'] as String,
    author: json['author'] as BenchPerson?,
    comments: (json['comments'] as List<dynamic>?)?.cast<BenchComment>(),
    tags: (json['tags'] as List<dynamic>?)?.cast<BenchTag>(),
    only: only,
  );
}

class BenchNoteProvider extends FluentProvider<BenchNote> {
  @override
  String get tableName => 'bench_notes';

  @override
  BenchNote get modelSample => BenchNote(text: '');

  @override
  BenchNote fromCacheJson(Map<String, dynamic> json) => BenchNote(id: json['id'] as int?, text: json['text'] as String);
}

class BenchEntryProvider extends FluentProvider<BenchEntry> {
  @override
  String get tableName => 'bench_entries';

  @override
  BenchEntry get modelSample => BenchEntry(title: '');

  @override
  BenchEntry fromCacheJson(Map<String, dynamic> json) =>
      BenchEntry(id: json['id'] as int?, title: json['title'] as String, notes: (json['notes'] as List<dynamic>?)?.cast<BenchNote>());
}

class BenchAccountProvider extends FluentProvider<BenchAccount> {
  @override
  String get tableName => 'bench_accounts';

  @override
  BenchAccount get modelSample => BenchAccount(email: '', name: '');

  @override
  BenchAccount fromCacheJson(Map<String, dynamic> json) => BenchAccount(id: json['id'] as int?, email: json['email'] as String, name: json['name'] as String);
}
