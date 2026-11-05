// FluentDb.transaction: one SQLite transaction for every call inside, no deadlock with the engine queue.
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late CommentProvider comments;
  late PersonProvider people;

  setUp(() async {
    db = FluentTestDb(name: 'txn_${DateTime.now().microsecondsSinceEpoch}');
    final providers = relationProviders();
    await db.open(providers);
    comments = providers.whereType<CommentProvider>().single;
    people = providers.whereType<PersonProvider>().single;
  });

  tearDown(() => db.close());

  test('commits writes of several tables; reads inside see them', () async {
    final int seen = await FluentDb.transaction(() async {
      await comments.save(Comment(text: 'a'));
      await FluentDb.save<Person>(Person(name: 'Ann'));
      return comments.count();
    }).timeout(const Duration(seconds: 5));

    expect(seen, 1);
    expect(await comments.count(), 1);
    expect(await people.count(), 1);
  });

  test('an error rolls everything back and is rethrown', () async {
    await expectLater(
      FluentDb.transaction<void>(() async {
        await comments.save(Comment(text: 'a'));
        await people.save(Person(name: 'Ann'));
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(await comments.count(), 0);
    expect(await people.count(), 0);
  });

  test('change events are published after the commit, none after a rollback', () async {
    final List<FluentChangeKind> events = [];
    final StreamSubscription<FluentChangeEvent<Comment>> sub = FluentDb.onEvent<Comment>().listen((e) => events.add(e.kind));

    await FluentDb.transaction(() async {
      await comments.save(Comment(text: 'a'));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty, reason: 'not committed yet');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, [FluentChangeKind.save]);

    await FluentDb.transaction<void>(() async {
      await comments.save(Comment(text: 'b'));
      throw StateError('rollback');
    }).catchError((Object _) {});
    await Future<void>.delayed(Duration.zero);
    expect(events, [FluentChangeKind.save]);
    await sub.cancel();
  });

  test('nested transactions join the outer one', () async {
    await expectLater(
      FluentDb.transaction<void>(() async {
        await FluentDb.transaction(() => comments.save(Comment(text: 'inner')));
        throw StateError('outer fails');
      }),
      throwsStateError,
    );
    expect(await comments.count(), 0);
  });

  test('operations outside wait for the transaction and do not see its writes early', () async {
    final Completer<void> inside = Completer<void>();
    final Completer<void> release = Completer<void>();
    final Future<void> txn = FluentDb.transaction(() async {
      await comments.save(Comment(text: 'a'));
      inside.complete();
      await release.future;
    });
    await inside.future;

    final Future<int> outside = comments.count();
    bool done = false;
    unawaited(outside.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(done, isFalse, reason: 'the queued read waits for the transaction');

    release.complete();
    await txn;
    expect(await outside, 1);
  });

  test('relation operations inside a transaction', () async {
    await FluentDb.transaction(() async {
      final Person ann = Person(name: 'Ann', profile: Profile(bio: 'hi'));
      await people.save(ann);
      expect(await people.countRelated(ann, 'profile'), 1);
    });
    expect(await people.count(), 1);
  });
}
