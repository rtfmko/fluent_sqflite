// Edge cases of watch / watchById / watchValue: which changes re-run a query, cancelling with work pending, deep
// equality of values, errors through the stream, relation link tables.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/schema_models.dart';

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

class Membership extends FluentStorable {
  Membership({this.id, required this.role, this.user, this.group});

  final int? id;
  final String role;
  final User? user;
  final Group? group;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'role': role, 'user': user, 'group': group};
}

class UserProvider extends FluentProvider<User> {
  @override
  String get tableName => 'users';

  @override
  User get modelSample => User(name: '');

  @override
  User fromCacheJson(Map<String, dynamic> json) => User(id: json['id'] as int?, name: json['name'] as String, memberships: (json['memberships'] as List?)?.cast<Membership>() ?? const [], groups: (json['groups'] as List?)?.cast<Group>() ?? const []);
}

class GroupProvider extends FluentProvider<Group> {
  @override
  String get tableName => 'groups_';

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
  Membership fromCacheJson(Map<String, dynamic> json) => Membership(id: json['id'] as int?, role: json['role'] as String, user: json['user'] as User?, group: json['group'] as Group?);
}

class Ephemeral extends FluentStorable {
  Ephemeral({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class EphemeralProvider extends FluentProvider<Ephemeral> {
  @override
  String get tableName => 'ephemerals';

  @override
  Ephemeral get modelSample => Ephemeral(name: '');

  @override
  Ephemeral fromCacheJson(Map<String, dynamic> json) => Ephemeral(id: json['id'] as int?, name: json['name'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'wedges_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  DynamicProvider rows() => DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('grp'), FluentDbColumn.integer('n')]);

  group('watch decides whether a change matters', () {
    test('a change to rows outside the result does not re-read; a change to a shown row does', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      await p.saveAll([for (int i = 1; i <= 3; i++) p.row({'id': i, 'grp': 'a', 'n': i})]);
      final List<List<Object?>> seen = [];
      final StreamSubscription<List<DynamicModel>> sub = p.watch(where: FluentFilter.eq('grp', 'a'), orderBy: 'id').listen((List<DynamicModel> l) => seen.add([for (final DynamicModel m in l) m['n']]));
      await db.settle();
      expect(seen, hasLength(1));

      await p.save(p.row({'id': 10, 'grp': 'b', 'n': 99}));
      await db.settle();
      expect(seen, hasLength(1), reason: 'the saved row is not part of the result');

      await p.updateById(2, {'n': 20});
      await db.settle();
      expect(seen.last, [1, 20, 3]);

      await p.save(p.row({'id': 11, 'grp': 'a', 'n': 7}));
      await db.settle();
      expect(seen.last, [1, 20, 3, 7], reason: 'a new matching row joins the result');
      await sub.cancel();
    });

    test('a change with more than 500 rows skips the relevance check and re-reads', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'grp': 'a', 'n': 1}));
      int emissions = 0;
      final StreamSubscription<List<DynamicModel>> sub = p.watch(where: FluentFilter.eq('grp', 'a')).listen((_) => emissions++);
      await db.settle();
      expect(emissions, 1);

      await p.saveAll([for (int i = 100; i < 120; i++) p.row({'id': i, 'grp': 'b', 'n': i})]);
      await db.settle();
      expect(emissions, 1, reason: '20 foreign rows: one count query proves they do not matter');

      await p.saveAll([for (int i = 1000; i < 1600; i++) p.row({'id': i, 'grp': 'b', 'n': i})]);
      await db.settle();
      expect(emissions, 2, reason: '600 foreign rows are too many keys to check: the query runs again');
      await sub.cancel();
    });

    test('with an offset every change re-reads (a change in front moves the window)', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      await p.saveAll([for (int i = 1; i <= 5; i++) p.row({'id': i, 'grp': 'a', 'n': i})]);
      final List<List<Object?>> seen = [];
      final StreamSubscription<List<DynamicModel>> sub = p.watch(orderBy: 'id', limit: 2, offset: 2).listen((List<DynamicModel> l) => seen.add([for (final DynamicModel m in l) m['id']]));
      await db.settle();
      expect(seen.last, [3, 4]);
      await p.deleteWhere(FluentFilter.eq('id', 1));
      await db.settle();
      expect(seen.last, [4, 5]);
      await sub.cancel();
    });

    test('cancelling with a change still waiting for its frame stops everything: no read, no emission', () async {
      final DynamicProvider p = rows();
      final QueryCounter counter = await QueryCounter.install();
      try {
        await db.open([p]);
        await p.save(p.row({'id': 1, 'grp': 'a', 'n': 1}));
        int emissions = 0;
        final StreamSubscription<List<DynamicModel>> sub = p.watch(coalesce: const Duration(seconds: 30)).listen((_) => emissions++);
        await db.settle();
        expect(emissions, 1);
        await p.updateById(1, {'n': 2}); // the change waits 30 s for its frame
        counter.reset();
        await sub.cancel();
        await db.settle();
        expect(emissions, 1);
        expect(counter.reads, 0, reason: 'the pending frame was cancelled together with the subscription');
      } finally {
        counter.uninstall();
      }
    });

    test('cancelling a watch of rows that expire cancels the expiry timer', () async {
      final EphemeralProvider p = EphemeralProvider();
      await db.open([p]);
      db.clock.set(DateTime.utc(2030));
      await p.save(Ephemeral(id: 1, name: 'a'));
      final List<List<int?>> seen = [];
      final StreamSubscription<List<Ephemeral>> sub = p.watch().listen((List<Ephemeral> l) => seen.add([for (final Ephemeral e in l) e.id]));
      await db.settle();
      expect(seen.single, [1]);
      await sub.cancel();
      db.clock.advance(const Duration(hours: 1));
      await db.settle();
      expect(seen, hasLength(1), reason: 'nothing runs after the cancel');
    });

    test('rows that expire leave the result by themselves; a refresh in between re-arms the timer', () async {
      final EphemeralProvider p = EphemeralProvider();
      await db.open([p]);
      // The timer is a real one (the test clock cannot make it fire sooner): row 1 lives 400 ms, row 2 an hour.
      await p.save(Ephemeral(id: 1, name: 'a')..timeToLive = const Duration(milliseconds: 400));
      final List<List<int?>> seen = [];
      final Completer<void> gone = Completer<void>();
      final StreamSubscription<List<Ephemeral>> sub = p.watch().listen((List<Ephemeral> l) {
        seen.add([for (final Ephemeral e in l) e.id]);
        if (seen.length > 1 && !l.any((Ephemeral e) => e.id == 1) && !gone.isCompleted) gone.complete();
      });
      await db.settle();
      expect(seen.first, [1]);
      await p.save(Ephemeral(id: 2, name: 'b')..timeToLive = const Duration(hours: 1)); // a refresh while the timer is armed
      await gone.future.timeout(const Duration(seconds: 10));
      expect(seen.last, [2], reason: 'row 1 expired without any change event');
      await sub.cancel();
    });

    test('a stream error (closed table) reaches the listener, the watch of an unregistered model fails through the stream', () async {
      final DynamicProvider p = rows();
      final DynamicProvider stranger = DynamicProvider('other', () => [FluentDbColumn.integer('id')]);
      await db.open([p]);
      await expectLater(stranger.watch(), emitsError(isA<FluentConfigException>()));
      await expectLater(stranger.watchById(1), emitsError(isA<FluentConfigException>()));
    });

    test('relations: link and target tables are watched, a through relation included', () async {
      final UserProvider users = UserProvider();
      final GroupProvider groups = GroupProvider();
      final MembershipProvider memberships = MembershipProvider();
      await db.open([users, groups, memberships]);
      final User u = User(name: 'ann');
      await users.save(u);
      final Group g = Group(title: 'g1');
      await groups.save(g);
      final List<List<String>> seen = [];
      final StreamSubscription<List<User>> sub = users.watch().listen((List<User> l) => seen.add([for (final User x in l) '${x.name}:${x.groups.map((Group gr) => gr.title).join(',')}']));
      await db.settle();
      expect(seen.last, ['ann:']);
      await memberships.save(Membership(role: 'admin', user: u, group: g));
      await db.settle();
      expect(seen.last, ['ann:g1'], reason: 'a change of the link table re-runs the query');
      await groups.updateById(g.primaryKeyValue, {'title': 'renamed'});
      await db.settle();
      expect(seen.last, ['ann:renamed'], reason: 'a change of the target table re-runs it too');
      await sub.cancel();
    });
  });

  group('watchValue', () {
    test('equal results are not emitted again (lists and maps compare deeply)', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      await p.saveAll([p.row({'id': 1, 'grp': 'a', 'n': 1}), p.row({'id': 2, 'grp': 'b', 'n': 2})]);
      final List<List<Map<String, Object?>>> seen = [];
      final StreamSubscription<List<Map<String, Object?>>> sub = p
          .watchValue<List<Map<String, Object?>>>(() async {
            final List<Map<String, dynamic>> r = await p.findMaps(columns: ['grp'], orderBy: 'grp');
            return [
              for (final Map<String, dynamic> m in r) {...m, 'tags': <Object?>['x', m['grp']], 'nested': {'k': <Object?>[1, 2]}},
            ];
          })
          .listen(seen.add);
      await db.settle();
      expect(seen, hasLength(1));
      await p.updateById(1, {'n': 5}); // changes the table, not the result
      await db.settle();
      expect(seen, hasLength(1), reason: 'the same value is not emitted twice');
      await p.save(p.row({'id': 3, 'grp': 'c', 'n': 3}));
      await db.settle();
      expect(seen, hasLength(2));
      expect(seen.last.map((Map<String, Object?> m) => m['grp']), ['a', 'b', 'c']);
      await sub.cancel();
    });

    test('alsoOn tables re-run the query; a failing query is a stream error and the next change recovers', () async {
      final DynamicProvider p = rows();
      final DynamicProvider q = DynamicProvider('u', () => [FluentDbColumn.integer('id')]);
      await db.open([p, q]);
      bool failNext = false;
      final List<Object?> seen = [];
      final List<Object> errors = [];
      final StreamSubscription<int> sub = p
          .watchValue<int>(() async {
            if (failNext) throw StateError('boom');
            return q.count();
          }, alsoOn: [q])
          .listen(seen.add, onError: errors.add);
      await db.settle();
      expect(seen, [0]);
      await q.save(q.row({'id': 1}));
      await db.settle();
      expect(seen, [0, 1]);
      failNext = true;
      await q.save(q.row({'id': 2}));
      await db.settle();
      expect(errors.single, isA<StateError>());
      failNext = false;
      await q.save(q.row({'id': 3}));
      await db.settle();
      expect(seen.last, 3);
      await sub.cancel();
    });

    test('cancelling a watchValue with a change waiting stops it', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      int runs = 0;
      final StreamSubscription<int> sub = p.watchValue<int>(() async => ++runs, coalesce: const Duration(seconds: 30)).listen((_) {});
      await db.settle();
      expect(runs, 1);
      await p.save(p.row({'id': 1, 'grp': 'a', 'n': 1}));
      await sub.cancel();
      await db.settle();
      expect(runs, 1);
    });
  });

  group('watchById', () {
    test('null id gives one null; a missing row gives null, then the row once it exists, then null again', () async {
      final DynamicProvider p = rows();
      await db.open([p]);
      expect(await p.watchById(null).toList(), [null]);
      final List<Object?> seen = [];
      final StreamSubscription<DynamicModel?> sub = p.watchById(1).listen((DynamicModel? m) => seen.add(m?['n']));
      await db.settle();
      expect(seen, [null]);
      await p.save(p.row({'id': 1, 'grp': 'a', 'n': 4}));
      await db.settle();
      expect(seen, [null, 4]);
      await p.deleteWhere(FluentFilter.eq('id', 1));
      await db.settle();
      expect(seen, [null, 4, null]);
      await sub.cancel();
    });

    test('a key that does not fit the table is a stream error with a hint', () async {
      final DynamicProvider p = DynamicProvider.spec('c', TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')], keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')]));
      await db.open([p]);
      await expectLater(p.watchById(1), emitsError(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotEmpty)));
    });
  });
}
