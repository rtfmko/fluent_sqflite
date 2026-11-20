// Savepoints of calls inside a transaction travel with the next statement (no round trip of their own), and a failing
// call still leaves nothing: its rollback is a statement of its own, never part of a batch.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/faults.dart';
import '../helpers/guarantees.dart';
import '../helpers/query_counter.dart';
import '../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late CommentProvider comments;
  late PersonProvider people;

  Future<void> open() async {
    db = FluentTestDb(name: 'lazy_sp_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    final List<FluentProvider> providers = relationProviders();
    comments = providers.whereType<CommentProvider>().single;
    people = providers.whereType<PersonProvider>().single;
    await db.open(providers);
    await comments.saveAll([for (int i = 1; i <= 10; i++) Comment(id: i, text: 't$i')]);
    await people.saveAll([for (int i = 1; i <= 10; i++) Person(id: i, name: 'p$i')]);
  }

  tearDown(() => db.close());

  test('calls inside a transaction send no SAVEPOINT / RELEASE of their own', () async {
    final QueryCounter counter = await QueryCounter.install();
    try {
      await open();
      await db.settle();
      counter.reset();
      await FluentDb.transaction(() async {
        await comments.save(Comment(id: 1, text: 'a'));
        await people.save(Person(id: 1, name: 'b'));
        await comments.updateById(2, {'likes': 3});
      }, dbKey: db.key);
      final List<String> control = [for (final String s in counter.statements) if (RegExp(r'^execute: (SAVEPOINT|RELEASE)').hasMatch(s)) s];
      expect(control, isEmpty, reason: counter.statements.join('\n'));
      expect((await comments.findById(1))?.text, 'a');
      expect((await people.findById(1))?.name, 'b');
      expect((await comments.findById(2))?.likes, 3);
    } finally {
      counter.uninstall();
    }
  });

  test('a call that fails after part of its writes leaves nothing; the transaction keeps the others', () async {
    final FaultyDatabaseFactory faults = await FaultyDatabaseFactory.install();
    try {
      await open();
      Object? caught;
      await FluentDb.transaction(() async {
        await people.save(Person(id: 1, name: 'kept'));
        // One call: an update of 3 (sent first) and an insert of 99, which fails.
        faults.failWhere((c) => c.matches('INSERT INTO "comments"'), times: 1);
        try {
          await comments.saveAll([Comment(id: 3, text: 'half'), Comment(id: 99, text: 'new')]);
        } catch (e) {
          caught = e;
        }
        await comments.save(Comment(id: 4, text: 'after'));
      }, dbKey: db.key);
      expect(caught, isA<FluentException>());
      expect((await comments.findById(3))?.text, 't3', reason: 'G1: the failed call wrote nothing');
      expect(await comments.findById(99), isNull);
      expect((await people.findById(1))?.name, 'kept');
      expect((await comments.findById(4))?.text, 'after');
      faults.heal();
      await expectIntegrity(comments.db);
    } finally {
      faults.heal();
      faults.uninstall();
    }
  });

  test('a batch that fails with the SAVEPOINT of an open nested transaction does not lose it (chaos seed 140939)', () async {
    final FaultyDatabaseFactory faults = await FaultyDatabaseFactory.install();
    try {
      await open();
      await FluentDb.transaction(() async {
        await expectLater(
          FluentDb.transaction<void>(() async {
            // The first statement of the nested transaction carries its SAVEPOINT: that batch fails.
            faults.failWhere((c) => c.matches(RegExp('^SAVEPOINT')), times: 1);
            await expectLater(comments.save(Comment(id: 7, text: 'fails')), throwsA(isA<FluentException>()));
            await comments.save(Comment(id: 8, text: 'inside, then rolled back'));
            throw StateError('the nested transaction fails');
          }, dbKey: db.key),
          throwsStateError,
        );
        await comments.save(Comment(id: 9, text: 'outer'));
      }, dbKey: db.key);
      expect((await comments.findById(7))?.text, 't7');
      expect((await comments.findById(8))?.text, 't8', reason: 'G1: the write made inside the failed nested transaction is rolled back');
      expect((await comments.findById(9))?.text, 'outer');
      faults.heal();
      await expectIntegrity(comments.db);
    } finally {
      faults.heal();
      faults.uninstall();
    }
  });

  test('a nested transaction that fails before any statement, and one that fails after some, roll back cleanly', () async {
    await open();
    await FluentDb.transaction(() async {
      await expectLater(FluentDb.transaction<void>(() async => throw StateError('nothing sent'), dbKey: db.key), throwsStateError);
      await expectLater(
        FluentDb.transaction<void>(() async {
          await comments.save(Comment(id: 5, text: 'gone'));
          await people.deleteById(5);
          throw StateError('after two writes');
        }, dbKey: db.key),
        throwsStateError,
      );
      await comments.save(Comment(id: 6, text: 'stays'));
    }, dbKey: db.key);
    expect((await comments.findById(5))?.text, 't5');
    expect((await people.findById(5))?.name, 'p5');
    expect((await comments.findById(6))?.text, 'stays');
  });
}
