// Audit (provider core / CRUD helper): regression and probe tests written during audit 2.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;

  setUp(() async {
    db = FluentTestDb(name: 'pc_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider(
      'users',
      () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name'), FluentDbColumn.text('note')],
    );
    await db.open([users]);
  });

  tearDown(() => db.close());

  DynamicModel user(Map<String, dynamic> values) => users.row(values);

  // PC-1: a save with conflictOn that updates a row by its unique column keeps the caller's own key on the model
  // instead of the key of the row that was really updated.
  test('PC-1 conflictOn: the saved model gets the key of the row that was updated, not a different key it carried', () async {
    await users.save(user({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));
    final DynamicModel incoming = user({'id': 9, 'email': 'ann@x', 'name': 'Ann (server)'});

    await users.save(incoming, conflictOn: ['email']);

    expect((await users.findById(7))?['name'], 'Ann (server)', reason: 'row 7 is the one matched by email');
    expect(await users.exists(9), isFalse);
    expect(incoming.primaryKeyValue, 7, reason: 'the model must point at the row that was written');
  });

  test('updateFields: FluentUpdate.add on a text column is refused with a typed error', () async {
    await users.save(user({'id': 1, 'email': 'a@x', 'name': 'a'}));
    await expectLater(
      users.updateById(1, {'name': FluentUpdate.increment()}),
      throwsA(isA<FluentArgumentException>()),
    );
  });

  test('patch keeps the stored value of a null field and writes the others', () async {
    await users.save(user({'id': 1, 'email': 'a@x', 'name': 'a', 'note': 'keep'}));
    await users.save(user({'id': 1, 'email': 'a@x', 'name': 'b', 'note': null}), strategy: FluentSaveStrategy.patch);
    expect((await users.findById(1))?['note'], 'keep');
    expect((await users.findById(1))?['name'], 'b');
  });

  test('a key that is not in the table is reported as not found, not as a crash', () async {
    expect(await users.exists(12345), isFalse);
  });
}
