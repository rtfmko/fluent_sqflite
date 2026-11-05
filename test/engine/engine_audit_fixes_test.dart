// Regression tests of the engine / transaction audit (ENG-1 ... ENG-10, OBS-8, DB-7, DB-11).
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';
import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;

  Future<void> openUsers({FluentConfig config = const FluentConfig()}) async {
    db = FluentTestDb(name: 'audit_fix_engine_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true), FluentDbColumn.text('name')]);
    await db.open([users], fluentConfig: config);
  }

  DynamicModel u(int id, String email, String name) => users.row({'id': id, 'email': email, 'name': name});

  /// Holds the database's write slot until the returned completer completes.
  Future<Completer<void>> hold() async {
    final Completer<void> started = Completer<void>();
    final Completer<void> release = Completer<void>();
    unawaited(
      FluentDb.transaction(() async {
        started.complete();
        await release.future;
      }),
    );
    await started.future;
    return release;
  }

  group('with users', () {
    setUp(() => openUsers());
    tearDown(() => db.close());

    test('ENG-1: a failed nested transaction publishes no event of its writes and drops its whenCommitted changes', () async {
      final List<FluentChangeEvent<dynamic>> events = [];
      final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.where((e) => e.table == 'users').listen(events.add);
      addTearDown(sub.cancel);
      bool committedChange = false;
      bool rethrown = false;
      await FluentDb.transaction(() async {
        await users.save(u(1, 'a@x', 'outer'));
        try {
          await FluentDb.transaction(() async {
            await users.save(u(2, 'b@x', 'inner'));
            FluentTransactionScope.whenCommitted(users.dbName, () => committedChange = true);
            throw StateError('inner failed');
          });
        } on StateError {
          rethrown = true; // the outer one goes on
        }
        await users.save(u(3, 'c@x', 'after'));
      });
      await db.settle();
      expect(rethrown, isTrue, reason: 'the nested transaction rethrows to its caller');
      expect(committedChange, isFalse);
      expect([for (final DynamicModel m in await users.findAll()) m.primaryKeyValue], [1, 3]);
      expect(events.expand((e) => e.items).length, 2, reason: 'only the saves that stayed publish');
    });

    test('ENG-1: a successful nested transaction keeps its writes', () async {
      await FluentDb.transaction(() async {
        await FluentDb.transaction(() async {
          await users.save(u(1, 'a@x', 'inner'));
        });
      });
      expect(await users.count(), 1);
    });

    test('ENG-2: clear() with a table that cannot be emptied throws a typed exception with cause and hint, and announces nothing', () async {
      await users.save(u(1, 'a@x', 'A'));
      await users.db.execute("CREATE TRIGGER audit_no_delete BEFORE DELETE ON users BEGIN SELECT RAISE(ABORT, 'locked'); END");
      await db.settle();
      final List<FluentChangeEvent<dynamic>> events = [];
      final StreamSubscription<FluentChangeEvent<dynamic>> sub = FluentEngine().changeStream.where((e) => e.table == 'users').listen(events.add);
      addTearDown(sub.cancel);

      Object? error;
      try {
        await FluentDb.clear(dbKey: db.key);
      } catch (e) {
        error = e;
      }
      expect(error, isA<FluentException>());
      expect((error! as FluentException).cause, isNotNull);
      expect((error as FluentException).hint, isNotEmpty);
      await db.settle();
      expect(events, isEmpty, reason: 'nothing was cleared, so nothing is broadcast');
      expect(await users.count(), 1);
    });

    test('ENG-7: clear() of a closed database fails with a typed error instead of reporting success', () async {
      await FluentDb.close();
      await expectLater(FluentDb.clear(), throwsA(isA<FluentConfigException>()));
      await expectLater(FluentDb.clear(dbKey: db.key), throwsA(isA<FluentConfigException>()));
    });

    test('DB-7: after close, FluentDb calls fail with notInitialized and a held provider with engineClosed', () async {
      await FluentDb.close();
      await expectLater(FluentDb.count<DynamicModel>(), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.notInitialized)));
      await expectLater(users.count(), throwsA(isA<FluentCancelledException>().having((e) => e.code, 'code', FluentErrorCode.engineClosed)));
    });

    test('ENG-3: the engine shut down from inside a transaction does not hang', () async {
      await FluentDb.transaction(() async {
        await users.save(u(1, 'a@x', 'A'));
        await FluentEngine().shutdown(drainTimeout: const Duration(seconds: 1)).timeout(const Duration(seconds: 5));
      }).timeout(const Duration(seconds: 10)).catchError((Object _) {});
    });

    test('ENG-6: collapsed findMaps callers get their own row maps', () async {
      await users.save(u(1, 'a@x', 'A'));
      final Completer<void> release = await hold();
      final int collapsedBefore = FluentDb.engineStats().collapsedReads;
      final Future<List<Map<String, dynamic>>> first = users.findMaps();
      final Future<List<Map<String, dynamic>>> second = users.findMaps();
      release.complete();
      final List<Map<String, dynamic>> a = await first;
      final List<Map<String, dynamic>> b = await second;
      expect(FluentDb.engineStats().collapsedReads, collapsedBefore + 1);
      a.first['name'] = 'changed by the first caller';
      expect(b.first['name'], 'A', reason: 'the second caller must not see the first caller\'s change');
      expect(identical(a.first, b.first), isFalse);
    });

    test('ENG-8: stats.completed counts finished tasks, not started ones', () async {
      await db.settle();
      final int before = FluentDb.engineStats().completed;
      final Completer<void> release = await hold();
      expect(FluentDb.engineStats().activeWrites, 1);
      expect(FluentDb.engineStats().completed, before, reason: 'the running transaction is not finished yet');
      release.complete();
      await db.settle();
      expect(FluentDb.engineStats().completed, before + 1);
    });

    test('ENG-10: a failing logging callback on the scheduling path never leaves callers waiting', () async {
      FluentDb.setupLogging(onRecord: (_) => throw StateError('broken log listener'), level: FluentLogLevel.debug, console: false, enabled: true);
      addTearDown(() => FluentDb.setupLogging(onRecord: (_) {}, enabled: false));
      final Completer<void> release = await hold();
      final List<Future<int>> calls = [for (var i = 0; i < 1100; i++) users.count()];
      release.complete();
      expect(await Future.wait(calls).timeout(const Duration(seconds: 30)), everyElement(0));
    });
  });

  group('transaction watchdog', () {
    late ArticleProvider articles;
    late CommentProvider comments;

    setUp(() async {
      db = FluentTestDb(name: 'audit_fix_adopt_${DateTime.now().microsecondsSinceEpoch}');
      final providers = relationProviders();
      await db.open(providers, fluentConfig: const FluentConfig(transactionWatchdog: Duration(milliseconds: 20)));
      articles = providers.whereType<ArticleProvider>().single;
      comments = providers.whereType<CommentProvider>().single;
    });
    tearDown(() => db.close());

    test('ENG-4: a read of several statements adopted by the watchdog finishes before the transaction commits', () async {
      await articles.save(Article(title: 'A', author: Person(name: 'Ann'), comments: [Comment(text: 'c1'), Comment(text: 'c2')], tags: [Tag(label: 't1')]));
      final int adoptedBefore = FluentDb.engineStats().adoptedReads;
      late Future<List<Article>> outside;
      await FluentDb.transaction(() async {
        outside = Zone.root.run(() => articles.find(relations: FluentLoad.eager));
        // The body ends the moment the watchdog took the read in: its later statements must not hit a closed transaction.
        while (FluentDb.engineStats().adoptedReads == adoptedBefore) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }).timeout(const Duration(seconds: 10));
      final List<Article> found = await outside.timeout(const Duration(seconds: 10));
      expect(found.single.author?.name, 'Ann');
      expect(found.single.comments, hasLength(2));
      expect(found.single.tags, hasLength(1));
    });

    test('ENG-5: an adopted read keeps the trash scope of its caller', () async {
      await articles.save(Article(title: 'A', comments: [Comment(text: 'live'), Comment(text: 'gone')]));
      final Comment gone = (await comments.find(where: FluentFilter.eq('text', 'gone'))).single;
      await comments.deleteById(gone.id);
      expect(await comments.count(), 1);
      final int adoptedBefore = FluentDb.engineStats().adoptedReads;
      late Future<List<Comment>> outside;
      await FluentDb.transaction(() async {
        outside = Zone.root.run(() => comments.withTrash.find());
        while (FluentDb.engineStats().adoptedReads == adoptedBefore) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }).timeout(const Duration(seconds: 10));
      expect((await outside).map((c) => c.text), unorderedEquals(['live', 'gone']));
    });
  });
}
