// Fixes made by the lead while merging the audit-2 fixers: the key a conflictOn save replaced (PC-1) together with
// "buildJson wins" (MAP-1), and FluentDb.trash / withTrash of an unregistered model (DB-8).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/relation_models.dart';
import '../../helpers/schema_models.dart';

DynamicProvider _users() => DynamicProvider('lead_users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);

void main() {
  setUpFluentTests();
  late FluentTestDb db;

  tearDown(() => db.close());

  group('PC-1 + MAP-1: the key of a conflictOn save', () {
    test('the matched row key wins over the stale key the model carries, then the model wins once it changes', () async {
      db = FluentTestDb(name: 'lead_keys');
      final DynamicProvider users = _users();
      await db.open([users]);
      await users.save(users.row({'id': 7, 'email': 'ann@x', 'name': 'Ann'}));

      final Map<String, dynamic> values = {'id': 9, 'email': 'ann@x', 'name': 'Ann B.'};
      final DynamicModel incoming = users.row(values);
      await users.save(incoming, conflictOn: ['email']);
      expect(incoming.primaryKeyValue, 7, reason: 'the stored row has key 7');
      expect(incoming.key['id'], 7);
      expect(await users.count(), 1);

      // A later save of the same instance updates row 7, not a new row 9.
      values['name'] = 'Ann C.';
      await users.save(incoming);
      expect(await users.count(), 1);
      expect((await users.findById(7))?.values['name'], 'Ann C.');

      // The user changes the key on purpose: buildJson wins again.
      values['id'] = 11;
      values['email'] = 'ann@y';
      expect(incoming.primaryKeyValue, 11);
      await users.save(incoming);
      expect((await users.findById(11))?.values['email'], 'ann@y');
    });

    test('a generated key still fills a model saved without one, and a changed key wins over it', () async {
      db = FluentTestDb(name: 'lead_generated');
      final DynamicProvider users = _users();
      await db.open([users]);
      final Map<String, dynamic> values = {'email': 'a@x', 'name': 'A'};
      final DynamicModel m = users.row(values);
      await users.save(m);
      final Object? generated = m.primaryKeyValue;
      expect(generated, isNotNull);
      values['id'] = 50;
      expect(m.primaryKeyValue, 50);
    });
  });

  group('DB-8: FluentDb.trash / withTrash never throw at the call', () {
    test('an unregistered model fails through the Futures and Streams of the calls', () async {
      db = FluentTestDb(name: 'lead_trash');
      await db.open([_users()]);
      late FluentTrash<Comment> trash;
      late FluentWithTrash<Comment> withTrash;
      expect(() => trash = FluentDb.trash<Comment>(), returnsNormally);
      expect(() => withTrash = FluentDb.withTrash<Comment>(), returnsNormally);
      await expectLater(trash.find(), throwsA(isA<FluentException>()));
      await expectLater(trash.count(), throwsA(isA<FluentException>()));
      await expectLater(trash.restoreById(1), throwsA(isA<FluentException>()));
      await expectLater(trash.deleteForever(Comment(id: 1, text: 'x')), throwsA(isA<FluentException>()));
      await expectLater(trash.empty(), throwsA(isA<FluentException>()));
      await expectLater(trash.watch(), emitsError(isA<FluentException>()));
      await expectLater(withTrash.find(), throwsA(isA<FluentException>()));
      await expectLater(withTrash.findById(1), throwsA(isA<FluentException>()));
      await expectLater(withTrash.watch(), emitsError(isA<FluentException>()));
    });

    test('a registered model still works through FluentDb.trash', () async {
      db = FluentTestDb(name: 'lead_trash_ok');
      final CommentProvider comments = CommentProvider();
      await db.open([comments]);
      final Comment c = Comment(text: 'x');
      await comments.save(c);
      await comments.delete(c);
      expect(await FluentDb.trash<Comment>().count(), 1);
      expect(await FluentDb.withTrash<Comment>().count(), 1);
      expect(await FluentDb.trash<Comment>().restore(c), 1);
    });
  });
}
