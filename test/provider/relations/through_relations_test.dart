// FluentRelation.through: a list reached through a link model that carries data of its own.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class User extends FluentStorable with FluentRelations {
  User({this.id, required this.name, this.memberships = const [], this.groups = const []});

  final int? id;
  final String name;
  final List<Membership> memberships;
  final List<Group> groups;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<User, Membership>('memberships', (u) => u.memberships),
    FluentRelation.through<User, Membership, Group>('groups', (u) => u.groups),
  ];
}

class Group extends FluentStorable {
  Group({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

/// The link: who is in which group, with a role. Soft-deletable: leaving a group goes to the trash.
class Membership extends FluentStorable with FluentSoftDeletable {
  Membership({this.id, required this.role, this.user, this.group});

  final int? id;
  final String role;
  final User? user;
  final Group? group;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'role': role, 'user': user, 'group': group};
}

/// User → Follow → User: the link references the same model twice.
class Person extends FluentStorable with FluentRelations {
  Person({this.id, required this.name, this.following = const []});

  final int? id;
  final String name;
  final List<Person> following;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.through<Person, Follow, Person>('following', (p) => p.following, parentVia: 'follower', childVia: 'followee'),
  ];
}

class Follow extends FluentStorable {
  Follow({this.id, this.follower, this.followee});

  final int? id;
  final Person? follower;
  final Person? followee;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'follower': follower, 'followee': followee};
}

/// The earlier version: a plain list of groups (many-to-many through an automatic link table).
class PlainUser extends FluentStorable with FluentRelations {
  PlainUser({this.id, required this.name, this.groups = const []});

  final int? id;
  final String name;
  final List<Group> groups;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  // Named like the reference column of Membership.user (the model class of that version had another name).
  @override
  List<FluentRelation> get relations => [FluentRelation.manyToMany<PlainUser, Group>('groups', (u) => u.groups, linkParentKey: 'user_id')];
}

class PlainUserProvider extends FluentProvider<PlainUser> {
  @override
  String get tableName => 'users';

  @override
  PlainUser get modelSample => PlainUser(name: '');

  @override
  PlainUser fromCacheJson(Map<String, dynamic> json) => PlainUser(id: json['id'] as int?, name: json['name'] as String);
}

/// The link model takes over the automatic link table by using its name.
class LinkProvider extends MembershipProvider {
  @override
  String get tableName => 'groups_users';
}

class UserProvider extends FluentProvider<User> {
  @override
  String get tableName => 'users';

  @override
  User get modelSample => User(name: '');

  @override
  User fromCacheJson(Map<String, dynamic> json) => User(
    id: json['id'] as int?,
    name: json['name'] as String,
    memberships: (json['memberships'] as List?)?.cast<Membership>() ?? const [],
    groups: (json['groups'] as List?)?.cast<Group>() ?? const [],
  );
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
  Membership get modelSample => Membership(role: '', user: User(name: ''), group: Group(title: ''));

  @override
  Membership fromCacheJson(Map<String, dynamic> json) => Membership(id: json['id'] as int?, role: json['role'] as String, group: json['group'] as Group?);
}

class PersonProvider extends FluentProvider<Person> {
  @override
  String get tableName => 'people';

  @override
  Person get modelSample => Person(name: '');

  @override
  Person fromCacheJson(Map<String, dynamic> json) => Person(id: json['id'] as int?, name: json['name'] as String, following: (json['following'] as List?)?.cast<Person>() ?? const []);
}

class FollowProvider extends FluentProvider<Follow> {
  @override
  String get tableName => 'follows';

  @override
  Follow get modelSample => Follow(follower: Person(name: ''), followee: Person(name: ''));

  @override
  Follow fromCacheJson(Map<String, dynamic> json) => Follow(id: json['id'] as int?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late UserProvider users;
  late GroupProvider groups;
  late MembershipProvider memberships;

  setUp(() async {
    users = UserProvider();
    groups = GroupProvider();
    memberships = MembershipProvider();
    db = FluentTestDb();
    await db.open([users, groups, memberships]);
  });

  tearDown(() => db.close());

  Future<User> ann() async => (await users.findAll()).single;

  test('attach builds the link model; the list and the links with their data load', () async {
    await users.save(User(name: 'Ann'));
    await users.attach(await ann(), 'groups', [Group(title: 'admins'), Group(title: 'readers')], link: (g) => Membership(role: (g as Group).title == 'admins' ? 'owner' : 'member'));

    final User loaded = (await users.findAll(maxDepth: 2)).single; // memberships → group is the second level
    expect(loaded.groups.map((g) => g.title), unorderedEquals(['admins', 'readers']));
    expect({for (final Membership m in loaded.memberships) m.group?.title: m.role}, {'admins': 'owner', 'readers': 'member'});

    await users.attach(loaded, 'groups', [loaded.groups.first], link: (_) => Membership(role: 'again'));
    expect(await memberships.count(), 2, reason: 'a group already linked is not linked twice');
  });

  test('filters and counts go through the link model', () async {
    await users.saveAll([User(name: 'Ann'), User(name: 'Bob')]);
    final User a = (await users.find(where: FluentFilter.eq('name', 'Ann'))).single;
    await users.attach(a, 'groups', [Group(title: 'admins')], link: (_) => Membership(role: 'owner'));

    final List<User> admins = await users.find(where: FluentFilter.related('groups', FluentFilter.eq('title', 'admins')));
    expect(admins.single.name, 'Ann');
    expect(await users.countRelated(a, 'groups'), 1);
  });

  test('detach moves the link to the trash; the group stays and is no longer listed', () async {
    await users.save(User(name: 'Ann'));
    await users.attach(await ann(), 'groups', [Group(title: 'admins')], link: (_) => Membership(role: 'owner'));
    final User loaded = await ann();
    await users.detach(loaded, 'groups', loaded.groups);

    expect((await ann()).groups, isEmpty);
    expect(await groups.count(), 1);
    expect(await memberships.trash.count(), 1, reason: 'the link model is soft-deletable');
  });

  test('the list is read-only: attach needs a link, new models in the list are reported', () async {
    await users.save(User(name: 'Ann'));
    await users.attach(await ann(), 'groups', [Group(title: 'x')]);
    expect(await groups.count(), 0);
    expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.ignoredCall));

    await users.save(User(id: (await ann()).id, name: 'Ann', groups: [Group(title: 'new')]));
    expect(await memberships.count(), 0);
    expect(db.warnings.where((i) => i.kind == FluentIssueKind.ignoredCall && i.title.contains('read-only')), isNotEmpty);
  });

  test('an automatic link table becomes a link model by taking its table name; the links stay', () async {
    await db.close();
    final FluentTestDb file = FluentTestDb(name: 'through_upgrade', persistent: true);
    final PlainUserProvider plain = PlainUserProvider();
    await file.open([plain, GroupProvider()]);
    await plain.save(PlainUser(name: 'Ann', groups: [Group(title: 'admins')]));

    final UserProvider upgraded = UserProvider();
    await file.restart([upgraded, GroupProvider(), LinkProvider()]);
    expect((await upgraded.findAll()).single.groups.single.title, 'admins');
    expect(file.issues.where((i) => i.kind == FluentIssueKind.unusedLinkTable), isEmpty, reason: 'the table is in use by the link model');
    await file.close();
  });

  test('a link model referencing the same model twice needs parentVia / childVia', () async {
    await db.close();
    final PersonProvider people = PersonProvider();
    final FluentTestDb other = FluentTestDb(name: 'follows');
    await other.open([people, FollowProvider()]);
    await people.saveAll([Person(name: 'Ann'), Person(name: 'Bob')]);
    final List<Person> all = await people.findAll(orderBy: 'name');
    await people.attach(all.first, 'following', [all.last], link: (_) => Follow());

    final Person a = (await people.find(where: FluentFilter.eq('name', 'Ann'))).single;
    expect(a.following.single.name, 'Bob');
    final Person b = (await people.find(where: FluentFilter.eq('name', 'Bob'))).single;
    expect(b.following, isEmpty);
    await other.close();
  });
}
