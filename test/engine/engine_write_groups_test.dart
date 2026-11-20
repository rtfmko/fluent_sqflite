// Adjacent writes that cannot be merged into one statement (deletes, updates, saves of other tables) share one
// transaction: each call runs in its own SAVEPOINT (it succeeds or fails alone), the callers are completed after the
// commit, and a failed commit runs the calls again one by one. Checked by statement counts and by the results of every
// call, never by wall-clock time.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

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
    db = FluentTestDb(name: 'write_groups_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    final List<FluentProvider> providers = relationProviders();
    comments = providers.whereType<CommentProvider>().single;
    people = providers.whereType<PersonProvider>().single;
    await db.open(providers);
    await comments.saveAll([for (int i = 1; i <= 300; i++) Comment(id: i, text: 't$i', likes: i % 5)]);
    await people.saveAll([for (int i = 1; i <= 100; i++) Person(id: i, name: 'p$i')]);
  }

  tearDown(() => db.close());

  int begins(QueryCounter c) => c.statements.where((s) => s.contains('BEGIN')).length;

  test('200 adjacent deletes share a few transactions; every caller gets its own count', () async {
    final QueryCounter counter = await QueryCounter.install();
    try {
      await open();
      counter.reset();
      final List<int> results = await Future.wait([for (int i = 1; i <= 200; i++) comments.deleteById(i % 2 == 0 ? i : 1000 + i)]);
      expect(results, [for (int i = 1; i <= 200; i++) i % 2 == 0 ? 1 : 0]);
      expect(begins(counter), lessThanOrEqualTo(10), reason: 'one transaction per group of adjacent writes, not per call:\n${counter.statements.take(20).join('\n')}');
      expect(await comments.count(), 200);
    } finally {
      counter.uninstall();
    }
  });

  test('mixed adjacent writes on two tables keep call order and each result', () async {
    await open();
    final List<Future<Object?>> calls = [
      people.deleteById(1),
      comments.updateById(5, {'likes': 42}),
      people.save(Person(id: 1, name: 'back')),
      comments.deleteById(5),
      comments.save(Comment(id: 5, text: 'new five', likes: 7)),
      people.updateWhere(FluentFilter.eq('name', 'back'), {'name': 'again'}),
      comments.deleteWhere(FluentFilter.ids([6, 7, 8])),
    ];
    final List<Object?> r = await Future.wait(calls);
    expect(r[0], 1);
    expect(r[1], 1);
    expect(r[3], 1);
    expect(r[5], 1);
    expect(r[6], 3);
    expect((await people.findById(1))?.name, 'again');
    final Comment five = (await comments.findById(5))!;
    expect((five.text, five.likes), ('new five', 7));
    expect(await comments.findByIds([6, 7, 8]), isEmpty);
  });

  test('a failing write in a group fails alone: the others commit, nothing of it is written', () async {
    final FaultyDatabaseFactory faults = await FaultyDatabaseFactory.install();
    try {
      await open();
      faults.failWhere((c) => c.matches('UPDATE "comments"') && c.matches('"text"'), times: 1);
      final List<Settled> r = await waitAllSettled([
        comments.deleteById(10),
        comments.save(Comment(id: 11, text: 'changed')),
        comments.updateById(12, {'likes': 99}),
        people.deleteById(2),
      ], names: ['delete 10', 'save 11 (fails)', 'update 12', 'delete person 2']);
      expect([for (final Settled s in r) s.failed], [false, true, false, false]);
      expect(await comments.findById(10), isNull);
      expect((await comments.findById(11))?.text, 't11', reason: 'G1: the failed save wrote nothing');
      expect((await comments.findById(12))?.likes, 99);
      expect(await people.findById(2), isNull);
      faults.heal();
      await expectIntegrity(comments.db);
    } finally {
      faults.heal();
      faults.uninstall();
    }
  });

  test('a watcher sees the result of every grouped write', () async {
    await open();
    final List<List<Comment>> seen = [];
    final StreamSubscription<List<Comment>> sub = comments.watch(where: FluentFilter.ids([20, 21, 22])).listen(seen.add);
    await db.settle();
    await Future.wait([comments.deleteById(20), comments.updateById(21, {'likes': 77}), comments.deleteById(22)]);
    await db.settle();
    await sub.cancel();
    expect(seen.last.map((c) => (c.id, c.likes)), [(21, 77)]);
  });

  test('a failed commit runs the calls again one by one: every caller still gets its result', () async {
    final FaultyDatabaseFactory faults = await FaultyDatabaseFactory.install();
    try {
      await open();
      // The first delete starts at once, alone (its own transaction); the 29 behind it run as a group: its COMMIT fails.
      faults.failNth(1, where: (c) => c.isCommit && (c.sql ?? '').trim().toUpperCase().startsWith('COMMIT'));
      final List<int> results = await Future.wait([for (int i = 30; i < 60; i++) comments.deleteById(i)]);
      expect(results, List.filled(30, 1));
      expect(faults.injected, hasLength(1));
      expect(await comments.count(where: FluentFilter.ids([for (int i = 30; i < 60; i++) i])), 0);
      faults.heal();
      await expectIntegrity(comments.db);
    } finally {
      faults.heal();
      faults.uninstall();
    }
  });
}
