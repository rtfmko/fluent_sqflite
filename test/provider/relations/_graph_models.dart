// Models of the relation guarantee tests (relations_guarantees_test.dart, relations_fuzz_test.dart): one owner with
// every relation kind. The models are mutable, so a test edits the instance it read (keeping what the library knows
// about it, e.g. which relations were loaded) and saves that instance — the way an app saves "what it loaded".
//
//   Owner (soft delete) ── boss ──────────────▶ Person              one (owners.boss_id, SET NULL)
//         ├─ profile ─────────────────────────▶ Profile             oneOwned (profiles.owner_id)
//         ├─ kids / topKids / bigKids / allKids ▶ Kid (soft delete)  many over kids.owner_id: the full list and three
//         │                                                         lazy views (limit 2, where n >= 5, includeDeleted)
//         ├─ tags ────────────────────────────▶ Tag (soft delete, composite key ns + label)   manyToMany
//         ├─ notes ───────────────────────────▶ Note.target         many via the polymorphic oneOf (Owner | Person)
//         ├─ memberships ─────────────────────▶ Membership (soft delete, role)               many (memberships.owner_id)
//         └─ groups ──── through Membership ──▶ Group
import 'package:fluent_sqflite/src/internal.dart';

class Owner extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Owner({this.id, required this.name, this.boss, this.profile, this.kids, this.topKids, this.bigKids, this.allKids, this.tags, this.notes, this.memberships, this.groups});

  int? id;
  String name;
  Person? boss;
  Profile? profile;
  List<Kid>? kids;
  List<Kid>? topKids;
  List<Kid>? bigKids;
  List<Kid>? allKids;
  List<Tag>? tags;
  List<Note>? notes;
  List<Membership>? memberships;
  List<Group>? groups;

  /// A copy with the same related instances and lists (the usual `copyWith` of an immutable model): lists given here
  /// replace the field.
  Owner copyWith({String? name, List<Kid>? kids, List<Kid>? topKids, List<Kid>? bigKids, List<Kid>? allKids, List<Tag>? tags, List<Note>? notes, List<Membership>? memberships}) => Owner(
    id: id,
    name: name ?? this.name,
    boss: boss,
    profile: profile,
    kids: kids ?? this.kids,
    topKids: topKids ?? this.topKids,
    bigKids: bigKids ?? this.bigKids,
    allKids: allKids ?? this.allKids,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
    memberships: memberships ?? this.memberships,
    groups: groups,
  );

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Owner, Person>('boss', (o) => o.boss),
    FluentRelation.oneOwned<Owner, Profile>('profile', (o) => o.profile),
    FluentRelation.many<Owner, Kid>('kids', (o) => o.kids, orderBy: 'id', lazy: true),
    FluentRelation.many<Owner, Kid>('topKids', (o) => o.topKids, foreignKey: 'owner_id', orderBy: 'n DESC, id', limit: 2, lazy: true),
    FluentRelation.many<Owner, Kid>('bigKids', (o) => o.bigKids, foreignKey: 'owner_id', where: FluentFilter.gte('n', 5), orderBy: 'id', lazy: true),
    FluentRelation.many<Owner, Kid>('allKids', (o) => o.allKids, foreignKey: 'owner_id', includeDeleted: true, orderBy: 'id', lazy: true),
    FluentRelation.manyToMany<Owner, Tag>('tags', (o) => o.tags, orderBy: 'label'),
    FluentRelation.many<Owner, Note>('notes', (o) => o.notes, via: 'target', orderBy: 'id'),
    FluentRelation.many<Owner, Membership>('memberships', (o) => o.memberships, orderBy: 'id'),
    FluentRelation.through<Owner, Membership, Group>('groups', (o) => o.groups, orderBy: 'id'),
  ];
}

class Person extends FluentStorable {
  Person({this.id, required this.name});

  int? id;
  String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Profile extends FluentStorable {
  Profile({this.id, required this.bio});

  int? id;
  String bio;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'bio': bio};
}

class Kid extends FluentStorable with FluentSoftDeletable {
  Kid({this.id, required this.text, this.n = 0});

  int? id;
  String text;
  int n;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'n': n};
}

/// Composite key (ns, label).
class Tag extends FluentStorable with FluentSoftDeletable {
  Tag({required this.ns, required this.label, this.title = ''});

  final String ns;
  final String label;
  String title;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('ns'), FluentDbColumn.text('label')];

  @override
  Map<String, dynamic> buildJson() => {'ns': ns, 'label': label, 'title': title};
}

/// A note on an owner or a person (polymorphic). The owner's notes are owned (`via: 'target'`), a person's are not.
class Note extends FluentStorable with FluentRelations {
  Note({this.id, required this.text, this.target});

  int? id;
  String text;
  FluentStorable? target;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};

  @override
  List<FluentRelation> get relations => [FluentRelation.oneOf<Note>('target', (n) => n.target, types: [Owner, Person])];
}

class Group extends FluentStorable {
  Group({this.id, required this.title});

  int? id;
  String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

/// The link of `Owner.groups` with data of its own.
class Membership extends FluentStorable with FluentRelations, FluentSoftDeletable {
  Membership({this.id, required this.role, this.owner, this.group});

  int? id;
  String role;
  Owner? owner;
  Group? group;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'role': role};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Membership, Owner>('owner', (m) => m.owner),
    FluentRelation.one<Membership, Group>('group', (m) => m.group),
  ];
}

List<T>? _list<T>(Object? v) => (v as List?)?.cast<T>();

class OwnerProvider extends FluentProvider<Owner> {
  @override
  String get tableName => 'owners';

  @override
  Owner get modelSample => Owner(name: '');

  @override
  Owner fromCacheJson(Map<String, dynamic> json) => Owner(
    id: json['id'] as int?,
    name: json['name'] as String,
    boss: json['boss'] as Person?,
    profile: json['profile'] as Profile?,
    kids: _list<Kid>(json['kids']),
    topKids: _list<Kid>(json['topKids']),
    bigKids: _list<Kid>(json['bigKids']),
    allKids: _list<Kid>(json['allKids']),
    tags: _list<Tag>(json['tags']),
    notes: _list<Note>(json['notes']),
    memberships: _list<Membership>(json['memberships']),
    groups: _list<Group>(json['groups']),
  );
}

/// Owners whose lists are never null: a relation the read did not load gets an empty list (a growable `[]`, or the
/// shared `const []` with [constDefaults]), like most apps write `fromCacheJson`.
class DenseOwnerProvider extends OwnerProvider {
  DenseOwnerProvider({this.constDefaults = false});

  final bool constDefaults;

  List<M> _or<M>(List<M>? v) => v ?? (constDefaults ? const [] : <M>[]);

  @override
  Owner fromCacheJson(Map<String, dynamic> json) {
    final Owner o = super.fromCacheJson(json);
    return Owner(
      id: o.id,
      name: o.name,
      boss: o.boss,
      profile: o.profile,
      kids: _or(o.kids),
      topKids: _or(o.topKids),
      bigKids: _or(o.bigKids),
      allKids: _or(o.allKids),
      tags: _or(o.tags),
      notes: _or(o.notes),
      memberships: _or(o.memberships),
      groups: _or(o.groups),
    );
  }
}

class PersonProvider extends FluentProvider<Person> {
  @override
  String get tableName => 'persons';

  @override
  Person get modelSample => Person(name: '');

  @override
  Person fromCacheJson(Map<String, dynamic> json) => Person(id: json['id'] as int?, name: json['name'] as String);
}

class ProfileProvider extends FluentProvider<Profile> {
  @override
  String get tableName => 'profiles';

  @override
  Profile get modelSample => Profile(bio: '');

  @override
  Profile fromCacheJson(Map<String, dynamic> json) => Profile(id: json['id'] as int?, bio: json['bio'] as String);
}

class KidProvider extends FluentProvider<Kid> {
  @override
  String get tableName => 'kids';

  @override
  Kid get modelSample => Kid(text: '');

  @override
  Kid fromCacheJson(Map<String, dynamic> json) => Kid(id: json['id'] as int?, text: json['text'] as String, n: json['n'] as int);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'tags';

  @override
  Tag get modelSample => Tag(ns: '', label: '');

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(ns: json['ns'] as String, label: json['label'] as String, title: json['title'] as String);
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String, target: json['target'] as FluentStorable?);
}

class GroupProvider extends FluentProvider<Group> {
  @override
  String get tableName => 'groups';

  @override
  Group get modelSample => Group(title: '');

  @override
  Group fromCacheJson(Map<String, dynamic> json) => Group(id: json['id'] as int?, title: json['title'] as String);
}

class MembershipProvider extends FluentProvider<Membership> {
  @override
  String get tableName => 'memberships';

  @override
  Membership get modelSample => Membership(role: '');

  @override
  Membership fromCacheJson(Map<String, dynamic> json) =>
      Membership(id: json['id'] as int?, role: json['role'] as String, owner: json['owner'] as Owner?, group: json['group'] as Group?);
}

/// The providers of one graph database.
class Graph {
  Graph({KidProvider? kids, OwnerProvider? owners}) : kids = kids ?? KidProvider(), owners = owners ?? OwnerProvider();

  final OwnerProvider owners;
  final PersonProvider persons = PersonProvider();
  final ProfileProvider profiles = ProfileProvider();
  final KidProvider kids;
  final TagProvider tags = TagProvider();
  final NoteProvider notes = NoteProvider();
  final GroupProvider groups = GroupProvider();
  final MembershipProvider memberships = MembershipProvider();

  List<FluentProvider> get all => [owners, persons, profiles, kids, tags, notes, groups, memberships];
}
