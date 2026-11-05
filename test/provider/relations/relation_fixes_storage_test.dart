// How relations are stored between app versions (a one-to-one pair keeps its side, ref ↔ owned data moves) and one
// delete rule per shared reference column.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart' as rm;

// ---- auto one-to-one pair -----------------------------------------------------------------------------------

class PUser extends FluentStorable {
  PUser({this.id, required this.name, this.profile});

  final int? id;
  final String name;
  final PProfile? profile;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'profile': profile};
}

class PProfile extends FluentStorable {
  PProfile({this.id, required this.bio, this.user});

  final int? id;
  final String bio;
  final PUser? user;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'bio': bio, 'user': user};
}

/// Added in the next version: one more relation points to the profile.
class PNote extends FluentStorable {
  PNote({this.id, required this.text, this.profile});

  final int? id;
  final String text;
  final PProfile? profile;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'profile': profile};
}

class PUserProvider extends FluentProvider<PUser> {
  @override
  String get tableName => 'users';

  @override
  PUser get modelSample => PUser(name: '', profile: PProfile(bio: ''));

  @override
  PUser fromCacheJson(Map<String, dynamic> json) => PUser(id: json['id'] as int?, name: json['name'] as String, profile: json['profile'] as PProfile?);
}

class PProfileProvider extends FluentProvider<PProfile> {
  @override
  String get tableName => 'profiles';

  @override
  PProfile get modelSample => PProfile(bio: '', user: PUser(name: ''));

  @override
  PProfile fromCacheJson(Map<String, dynamic> json) => PProfile(id: json['id'] as int?, bio: json['bio'] as String, user: json['user'] as PUser?);
}

class PNoteProvider extends FluentProvider<PNote> {
  @override
  String get tableName => 'notes';

  @override
  PNote get modelSample => PNote(text: '', profile: PProfile(bio: ''));

  @override
  PNote fromCacheJson(Map<String, dynamic> json) => PNote(id: json['id'] as int?, text: json['text'] as String, profile: json['profile'] as PProfile?);
}

// ---- declared relations that change their kind between versions ----------------------------------------------

/// The declaration of `DUser.profile` in the "app version" under test.
List<FluentRelation> Function() userRelations = () => [];

class DUser extends FluentStorable with FluentRelations {
  DUser({this.id, required this.name, this.profile});

  final int? id;
  final String name;
  final DProfile? profile;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => userRelations();
}

class DProfile extends FluentStorable {
  DProfile({this.id, required this.bio});

  final int? id;
  final String bio;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'bio': bio};
}

class DUserProvider extends FluentProvider<DUser> {
  @override
  String get tableName => 'users';

  @override
  DUser get modelSample => DUser(name: '');

  @override
  DUser fromCacheJson(Map<String, dynamic> json) => DUser(id: json['id'] as int?, name: json['name'] as String, profile: json['profile'] as DProfile?);
}

class DProfileProvider extends FluentProvider<DProfile> {
  @override
  String get tableName => 'profiles';

  @override
  DProfile get modelSample => DProfile(bio: '');

  @override
  DProfile fromCacheJson(Map<String, dynamic> json) => DProfile(id: json['id'] as int?, bio: json['bio'] as String);
}

List<FluentRelation> asReference({String? foreignKey}) => [FluentRelation.one<DUser, DProfile>('profile', (u) => u.profile, foreignKey: foreignKey)];

List<FluentRelation> asOwned() => [FluentRelation.oneOwned<DUser, DProfile>('profile', (u) => u.profile, foreignKey: 'user_id')];

// ---- shared reference column with a declared rule ---------------------------------------------------------------

class Node extends FluentStorable with FluentRelations {
  Node({this.id, required this.name, this.parent, this.children});

  final int? id;
  final String name;
  final Node? parent;
  final List<Node>? children;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.one<Node, Node>('parent', (n) => n.parent),
    FluentRelation.many<Node, Node>('children', (n) => n.children, onDelete: FluentOnDelete.cascade),
  ];
}

class NodeProvider extends FluentProvider<Node> {
  @override
  String get tableName => 'nodes';

  @override
  Node get modelSample => Node(name: '');

  @override
  Node fromCacheJson(Map<String, dynamic> json) => Node(id: json['id'] as int?, name: json['name'] as String, children: (json['children'] as List?)?.cast<Node>());
}

Future<Map<String, String>> foreignKeys(FluentProvider p) async => {
  for (final r in await p.db.rawQuery('PRAGMA foreign_key_list("${p.tableName}")')) '${r['from']}': '${r['table']}.${r['to']} ON DELETE ${r['on_delete']}',
};

FluentRelationLink linkOf(FluentProvider p, String name) => p.relationLinks.singleWhere((l) => l.name == name);

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  int counter = 0;
  setUp(() => db = FluentTestDb(name: 'relation_storage_${counter++}', persistent: true));
  tearDown(() => db.close());

  group('REL4: an auto one-to-one pair keeps the side that stores the key', () {
    test('a new pair: the model fewer relations point to stores the key', () async {
      final PUserProvider users = PUserProvider();
      final PProfileProvider profiles = PProfileProvider();
      await db.open([users, profiles, PNoteProvider()]);
      expect(linkOf(users, 'profile').type, FluentRelationType.one, reason: 'Note points to Profile too, so users stores the key');
      expect(linkOf(profiles, 'user').type, FluentRelationType.oneOwned);
    });

    test('adding an unrelated relation does not move the key: existing profiles still load', () async {
      final PUserProvider users = PUserProvider();
      final PProfileProvider profiles = PProfileProvider();
      await db.open([users, profiles]);
      expect(linkOf(profiles, 'user').type, FluentRelationType.one, reason: 'a tie: profiles stores the key');
      await users.save(PUser(name: 'Ann', profile: PProfile(bio: 'hi')));

      final PUserProvider next = PUserProvider();
      final PProfileProvider nextProfiles = PProfileProvider();
      final int before = db.issues.length;
      await db.restart([next, nextProfiles, PNoteProvider()]);
      expect(linkOf(nextProfiles, 'user').type, FluentRelationType.one, reason: 'kept as stored');
      expect(linkOf(next, 'profile').type, FluentRelationType.oneOwned);
      expect(linkOf(next, 'profile').decidedBy, contains('as stored'));
      expect((await next.findAll()).single.profile?.bio, 'hi');
      expect((await nextProfiles.findAll()).single.user?.name, 'Ann');
      expect(db.warnings, isEmpty);
      final FluentIssue hint = db.issues.lastWhere((i) => i.kind == FluentIssueKind.autoRelations);
      expect(hint.title, contains('kept as stored'));
      final List<FluentIssue> hints = db.issues.skip(before).where((i) => i.kind == FluentIssueKind.autoRelations).toList();
      expect(hints, hasLength(1), reason: 'the switched decision is never reported, only the final one');

      // The next start keeps it as well, and the schema is not synchronized again.
      final PUserProvider third = PUserProvider();
      await db.restart([third, PProfileProvider(), PNoteProvider()]);
      expect((await third.findAll()).single.profile?.bio, 'hi');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationChanged || i.kind == FluentIssueKind.relationDataMoved), isEmpty);
    });

    test('planMigrations sees the kept side: no change is planned', () async {
      await db.open([PUserProvider(), PProfileProvider()]);
      final FluentMigrationPlan plan = await db.plan([PUserProvider(), PProfileProvider(), PNoteProvider()]);
      expect(plan.changes.where((c) => c.table == 'users' || c.table == 'profiles'), isEmpty, reason: '$plan');
    });
  });

  group('REL4: a reference and an owned child swapping the table move the keys', () {
    tearDown(() => userRelations = () => []);

    test('one → oneOwned: the key moves from users.profile_id to profiles.user_id', () async {
      userRelations = asReference;
      final DUserProvider users = DUserProvider();
      await db.open([users, DProfileProvider()]);
      await users.save(DUser(name: 'Ann', profile: DProfile(bio: 'ann')));
      await users.save(DUser(name: 'Bob', profile: DProfile(bio: 'bob')));
      await users.save(DUser(name: 'Cid'));

      userRelations = asOwned;
      final DUserProvider next = DUserProvider();
      await db.restart([next, DProfileProvider()]);
      final List<DUser> all = await next.findAll(orderBy: 'name');
      expect([for (final DUser u in all) u.profile?.bio], ['ann', 'bob', null]);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDataMoved), hasLength(1));
      expect(db.warnings, isEmpty);
    });

    test('oneOwned → one: the key moves from profiles.user_id to users.profile_id', () async {
      userRelations = asOwned;
      final DUserProvider users = DUserProvider();
      await db.open([users, DProfileProvider()]);
      await users.save(DUser(name: 'Ann', profile: DProfile(bio: 'ann')));
      await users.save(DUser(name: 'Cid'));

      userRelations = asReference;
      final DUserProvider next = DUserProvider();
      await db.restart([next, DProfileProvider()]);
      expect([for (final DUser u in await next.findAll(orderBy: 'name')) u.profile?.bio], ['ann', null]);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDataMoved), hasLength(1));
    });

    test('a profile referenced by two users is not moved: a warning says why', () async {
      userRelations = asReference;
      final DUserProvider users = DUserProvider();
      final DProfileProvider profiles = DProfileProvider();
      await db.open([users, profiles]);
      await users.save(DUser(name: 'Ann', profile: DProfile(bio: 'shared')));
      final DProfile shared = (await profiles.findAll()).single;
      await users.save(DUser(name: 'Bob', profile: shared));

      userRelations = asOwned;
      await db.restart([DUserProvider(), DProfileProvider()]);
      expect(db.warnings.map((i) => i.kind), contains(FluentIssueKind.relationChanged));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationDataMoved), isEmpty);
    });

    test('a storage change nothing can move is reported', () async {
      userRelations = asReference;
      final DUserProvider users = DUserProvider();
      await db.open([users, DProfileProvider()]);
      await users.save(DUser(name: 'Ann', profile: DProfile(bio: 'ann')));

      userRelations = () => asReference(foreignKey: 'main_profile_id');
      await db.restart([DUserProvider(), DProfileProvider()]);
      final FluentIssue warning = db.warnings.singleWhere((i) => i.kind == FluentIssueKind.relationChanged);
      expect(warning.title, contains('"users.profile"'));
    });

    test('an unchanged relation reports nothing on restart', () async {
      userRelations = asReference;
      await db.open([DUserProvider(), DProfileProvider()]);
      await db.restart([DUserProvider(), DProfileProvider()]);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.relationChanged || i.kind == FluentIssueKind.relationDataMoved), isEmpty);
    });
  });

  group('REL5: one delete rule per shared reference column', () {
    test('a back-reference and an owned list over parent_id: both links use the reference rule', () async {
      final rm.CategoryProvider categories = rm.CategoryProvider();
      await db.open(rm.relationProviders()..removeWhere((p) => p is rm.CategoryProvider)..add(categories));
      expect(linkOf(categories, 'parent').onDelete, FluentOnDelete.setNull);
      expect(linkOf(categories, 'children').onDelete, FluentOnDelete.setNull, reason: 'the same column as parent: SQL has ON DELETE SET NULL');
      expect(await foreignKeys(categories), {'parent_id': 'categories.id ON DELETE SET NULL'});
      final FluentIssue hint = db.issues.singleWhere((i) => i.kind == FluentIssueKind.autoRelations);
      expect(hint.details, contains('share the reference categories.parent_id'));
      expect(hint.code, contains('onDelete: FluentOnDelete.setNull'));
    });

    test('with foreign keys off, deleting a parent keeps its children like SQLite would (was: deleted)', () async {
      final rm.CategoryProvider categories = rm.CategoryProvider();
      await db.open([categories], config: const FluentDbConfig(enableForeignKeys: false));
      await categories.save(rm.Category(name: 'root', children: [rm.Category(name: 'a'), rm.Category(name: 'b')]));
      final rm.Category root = (await categories.find(where: FluentFilter.eq('name', 'root'))).single;
      await categories.delete(root);
      final List<Map<String, Object?>> rows = await categories.db.query('categories', orderBy: 'name');
      expect([for (final r in rows) r['name']], ['a', 'b']);
      expect([for (final r in rows) r['parent_id']], [null, null]);
    });

    test('with foreign keys on the result is the same', () async {
      final rm.CategoryProvider categories = rm.CategoryProvider();
      await db.open([categories]);
      await categories.save(rm.Category(name: 'root', children: [rm.Category(name: 'a')]));
      await categories.delete((await categories.find(where: FluentFilter.eq('name', 'root'))).single);
      expect((await categories.findAll()).single.name, 'a');
    });

    test('a declared onDelete on the list wins for both, also in SQL', () async {
      final NodeProvider nodes = NodeProvider();
      await db.open([nodes]);
      expect(linkOf(nodes, 'parent').onDelete, FluentOnDelete.cascade);
      expect(linkOf(nodes, 'children').onDelete, FluentOnDelete.cascade);
      expect(await foreignKeys(nodes), {'parent_id': 'nodes.id ON DELETE CASCADE'});
      await nodes.save(Node(name: 'root', children: [Node(name: 'a')]));
      await nodes.delete((await nodes.find(where: FluentFilter.eq('name', 'root'))).single);
      expect(await nodes.findAll(), isEmpty);
    });

    test('relations on different columns keep their own rules', () async {
      final List<FluentProvider> providers = rm.relationProviders();
      await db.open(providers);
      final rm.ArticleProvider articles = providers.whereType<rm.ArticleProvider>().single;
      expect(linkOf(articles, 'comments').onDelete, FluentOnDelete.cascade);
      expect(linkOf(articles, 'author').onDelete, FluentOnDelete.setNull);
    });
  });
}
