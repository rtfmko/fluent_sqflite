// Models of the upgrade fixtures (G5): the same declarations wrote `test/fixtures/upgrade/dev1.db` (2.0.0-dev.1) and
// `dev2.db` (2.0.0-dev.2) — see `generator/upgrade_fixture_writer.dart` — and the current code opens them.
// Public API only, so the writer also compiles in the old worktrees.
import 'package:fluent_sqflite/fluent_sqflite.dart';

class FxTag extends FluentStorable {
  FxTag({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

class FxBook extends FluentStorable with FluentSoftDeletable, FluentTimestamps {
  FxBook({this.id, required this.title, this.pages = 0});

  final int? id;
  final String title;
  final int pages;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'pages': pages};
}

class FxAuthor extends FluentStorable with FluentRelations {
  FxAuthor({this.id, required this.name, required this.born, this.rating = 0, this.active = true, this.books, this.tags});

  final int? id;
  final String name;
  final DateTime born;
  final double rating;
  final bool active;
  final List<FxBook>? books;
  final List<FxTag>? tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'born': born, 'rating': rating, 'active': active};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<FxAuthor, FxBook>('books', (a) => a.books, orderBy: 'id'),
    FluentRelation.manyToMany<FxAuthor, FxTag>('tags', (a) => a.tags, orderBy: 'id'),
  ];
}

/// A table that stores DateTime as ISO text.
class FxEvent extends FluentStorable {
  FxEvent({this.id, required this.at, required this.note});

  final int? id;
  final DateTime at;
  final String note;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'at': at, 'note': note};
}

class FxTodo extends FluentStorable {
  FxTodo({this.id, required this.text, this.done = false});

  final int? id;
  final String text;
  final bool done;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'done': done};
}

class FxCached extends FluentStorable {
  FxCached({this.id, required this.value, super.timeToLive});

  final int? id;
  final String value;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'value': value};
}

class FxTagProvider extends FluentProvider<FxTag> {
  @override
  String get tableName => 'fx_tags';

  @override
  FxTag get modelSample => FxTag(label: '');

  @override
  FxTag fromCacheJson(Map<String, dynamic> json) => FxTag(id: json['id'] as int?, label: json['label'] as String);
}

class FxBookProvider extends FluentProvider<FxBook> {
  @override
  String get tableName => 'fx_books';

  @override
  FxBook get modelSample => FxBook(title: '');

  @override
  FxBook fromCacheJson(Map<String, dynamic> json) => FxBook(id: json['id'] as int?, title: json['title'] as String, pages: json['pages'] as int? ?? 0);
}

class FxAuthorProvider extends FluentProvider<FxAuthor> {
  @override
  String get tableName => 'fx_authors';

  @override
  FxAuthor get modelSample => FxAuthor(name: '', born: DateTime.utc(2000));

  @override
  FxAuthor fromCacheJson(Map<String, dynamic> json) => FxAuthor(
    id: json['id'] as int?,
    name: json['name'] as String,
    born: json['born'] as DateTime,
    rating: (json['rating'] as num).toDouble(),
    active: json['active'] as bool,
    books: (json['books'] as List<dynamic>?)?.cast<FxBook>(),
    tags: (json['tags'] as List<dynamic>?)?.cast<FxTag>(),
  );
}

class FxEventProvider extends FluentProvider<FxEvent> {
  @override
  String get tableName => 'fx_events';

  @override
  FxEvent get modelSample => FxEvent(at: DateTime.utc(2000), note: '');

  @override
  FxEvent fromCacheJson(Map<String, dynamic> json) => FxEvent(id: json['id'] as int?, at: json['at'] as DateTime, note: json['note'] as String);
}

class FxTodoProvider extends FluentProvider<FxTodo> with FluentSyncable<FxTodo> {
  @override
  String get tableName => 'fx_todos';

  @override
  FxTodo get modelSample => FxTodo(text: '');

  @override
  FxTodo fromCacheJson(Map<String, dynamic> json) => FxTodo(id: json['id'] as int?, text: json['text'] as String, done: json['done'] as bool);
}

class FxCachedProvider extends FluentProvider<FxCached> {
  @override
  String get tableName => 'fx_cached';

  @override
  FxCached get modelSample => FxCached(value: '');

  @override
  FxCached fromCacheJson(Map<String, dynamic> json) => FxCached(id: json['id'] as int?, value: json['value'] as String);
}

/// The providers of the fixture databases (a fresh list each call): tags, books, authors, events, todos, cached.
List<FluentProvider<FluentStorable>> fxProviders() => [FxTagProvider(), FxBookProvider(), FxAuthorProvider(), FxEventProvider(), FxTodoProvider(), FxCachedProvider()];
