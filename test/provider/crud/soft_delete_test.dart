// Soft delete: unique values, trash view, orphan restore, withTrash, retention, indexes.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Account extends FluentStorable with FluentSoftDeletable, FluentRelations {
  Account({this.id, required this.email, this.tasks});

  final int? id;
  final String email;
  final List<Task>? tasks;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 1));

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'email': email};

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true)];

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Account, Task>('tasks', (a) => a.tasks, orderBy: 'title')];
}

class Task extends FluentStorable with FluentSoftDeletable {
  Task({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class AccountProvider extends FluentProvider<Account> {
  @override
  String get tableName => 'accounts';

  @override
  Account get modelSample => Account(email: '');

  @override
  Account fromCacheJson(Map<String, dynamic> json) => Account(id: json['id'] as int?, email: json['email'] as String, tasks: (json['tasks'] as List?)?.cast<Task>());
}

class TaskProvider extends FluentProvider<Task> {
  @override
  String get tableName => 'tasks';

  @override
  Task get modelSample => Task(title: '');

  @override
  Task fromCacheJson(Map<String, dynamic> json) => Task(id: json['id'] as int?, title: json['title'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late AccountProvider accounts;
  late TaskProvider tasks;

  setUp(() async {
    db = FluentTestDb(name: 'soft_${DateTime.now().microsecondsSinceEpoch}');
    accounts = AccountProvider();
    tasks = TaskProvider();
    await db.open([accounts, tasks]);
  });

  tearDown(() => db.close());

  test('rows in the trash do not keep their unique values; restoring a taken value fails clearly', () async {
    final Account old = Account(email: 'a@x');
    await accounts.save(old);
    await accounts.delete(old);

    final FluentSaveResult fresh = await accounts.save(Account(email: 'a@x'));
    expect(fresh.inserted, 1);
    await expectLater(accounts.save(Account(email: 'a@x')), throwsA(isA<FluentConstraintException>()), reason: 'live rows stay unique');

    await expectLater(accounts.trash.restore(old), throwsA(isA<FluentConstraintException>().having((e) => e.message, 'message', contains('UNIQUE'))));
    expect(await accounts.count(), 1);
  });

  test('conflictOn matches a trashed row like its key does: the row is restored, not duplicated', () async {
    final Account old = Account(email: 'a@x');
    await accounts.save(old);
    await accounts.delete(old);

    final Account incoming = Account(email: 'a@x');
    final FluentSaveResult result = await accounts.save(incoming, conflictOn: ['email']);
    expect(result.outcomes, [FluentRowOutcome.restored]);
    expect(incoming.primaryKeyValue, old.primaryKeyValue);
    expect(await accounts.withTrash.count(), 1);
  });

  test('a trashed owner loads the children deleted together with it', () async {
    final Account a = Account(email: 'a@x', tasks: [Task(title: 't1'), Task(title: 't2'), Task(title: 't3')]);
    await accounts.save(a);
    final Task alone = (await tasks.findFirst(where: FluentFilter.eq('title', 't3')))!;
    await tasks.delete(alone);
    await accounts.delete(a);

    final Account trashed = (await accounts.trash.find()).single;
    expect(trashed.tasks?.map((t) => t.title), ['t1', 't2'], reason: 't3 was deleted on its own');
  });

  test('restoring a child of a deleted owner is skipped; restoring the owner brings it back', () async {
    final Account a = Account(email: 'a@x', tasks: [Task(title: 't1')]);
    await accounts.save(a);
    await accounts.delete(a);

    final Task child = (await tasks.trash.find()).single;
    expect(await tasks.trash.restore(child), 0);
    expect(await tasks.count(), 0);

    expect(await accounts.trash.restore(a), 1);
    expect((await tasks.findAll()).map((t) => t.title), ['t1']);
  });

  test('withTrash reads live and trashed rows', () async {
    final Account a = Account(email: 'a@x');
    final Account b = Account(email: 'b@x');
    await accounts.saveAll([a, b]);
    await accounts.delete(b);

    expect(await accounts.count(), 1);
    expect(await accounts.withTrash.count(), 2);
    expect((await accounts.withTrash.findById(b.primaryKeyValue))?.deletedAt, isNotNull);
    expect(await accounts.withTrash.exists(b.primaryKeyValue), isTrue);
    expect(await accounts.withTrash.findAll(), hasLength(2));
    expect(await FluentDb.withTrash<Account>().count(), 2);
  });

  test('trash: count, restoreWhere, deleteForever; the model calls', () async {
    final Account a = Account(email: 'a@x');
    final Account b = Account(email: 'b@x');
    final Account c = Account(email: 'c@x');
    await accounts.saveAll([a, b, c]);
    await accounts.deleteAll([a, b, c]);
    expect(await accounts.trash.count(), 3);

    expect(await accounts.trash.restoreWhere(FluentFilter.eq('email', 'a@x')), 1);
    expect(await accounts.trash.deleteForeverById(b.primaryKeyValue), 1);
    expect(await accounts.withTrash.exists(b.primaryKeyValue), isFalse, reason: 'gone for good');

    expect(await c.restore(), 1);
    expect(await c.deleteForever(), 1);
    expect(await accounts.withTrash.count(), 1);
    expect(await FluentDb.trash<Account>().count(), 0);
  });

  test('trash.watch and withTrash.watch keep their scope on re-runs', () async {
    final Account a = Account(email: 'a@x');
    await accounts.save(a);
    final List<int> inTrash = [];
    final List<int> all = [];
    final StreamSubscription<List<Account>> s1 = accounts.trash.watch().listen((r) => inTrash.add(r.length));
    final StreamSubscription<List<Account>> s2 = accounts.withTrash.watch().listen((r) => all.add(r.length));
    await db.settle();
    await accounts.delete(a);
    await db.settle();
    await s1.cancel();
    await s2.cancel();
    expect(inTrash, [0, 1]);
    expect(all.toSet(), {1}, reason: 'the row stays in the withTrash view');
  });

  test('purge uses the model retention; the trash has its own small index', () async {
    final Account a = Account(email: 'a@x');
    await accounts.save(a);
    await accounts.delete(a);
    await accounts.execute('UPDATE accounts SET deleted_at = ? WHERE id = ?', arguments: [DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch, a.primaryKeyValue]);

    expect(await accounts.trash.empty(), 1, reason: 'retention of Account is 1 day');

    final List<Map<String, dynamic>> indexes = await accounts.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'accounts'");
    final Map<String, String> sqlOf = {for (final Map<String, dynamic> r in indexes) r['name'] as String: '${r['sql']}'};
    expect(sqlOf['idx_accounts_deleted_at'], contains('IS NOT NULL'));
    expect(sqlOf['uidx_accounts_email'], contains('IS NULL'));
  });
}
