// Expensive counts read again before anything changed are answered from the engine's cache: one `PRAGMA data_version`
// instead of a scan. Every write of the app, and every commit of another connection on the same file (another isolate
// or process), makes the next count read the table again; a transaction's uncommitted view is never kept.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/query_counter.dart';
import '../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late QueryCounter counter;
  late FluentTestDb db;
  late CommentProvider comments;
  const int rows = 300000;

  setUpAll(() async {
    counter = await QueryCounter.install();
    db = FluentTestDb(name: 'count_cache', persistent: true);
    comments = relationProviders().whereType<CommentProvider>().single;
    await db.open([comments]);
    // Many rows, written directly (fast), so a count scans long enough to be worth caching.
    await comments.db.transaction((txn) async {
      for (int from = 1; from <= rows; from += 5000) {
        final Batch b = txn.batch();
        for (int i = from; i < from + 5000; i++) {
          b.rawInsert('INSERT INTO "comments" ("id", "text", "likes") VALUES (?, ?, ?)', [i, 't', i % 7]);
        }
        await b.commit(noResult: true);
      }
    });
    // The cost model learns that this count is expensive (it needs a few runs).
    for (int i = 0; i < 4; i++) {
      await comments.count();
    }
  });

  tearDownAll(() async {
    await db.close();
    counter.uninstall();
  });

  int counts() => counter.statements.where((s) => s.contains('COUNT(')).length;

  test('a count read again before anything changed runs no scan', () async {
    expect(await comments.count(), rows);
    counter.reset();
    expect(await comments.count(), rows);
    expect(await comments.count(), rows);
    expect(counts(), 0, reason: counter.statements.join('\n'));
    expect(counter.statements.where((s) => s.contains('data_version')), isNotEmpty);
  });

  test('a write of the app makes the next count read the table again', () async {
    await comments.count();
    await comments.save(Comment(id: rows + 1, text: 'new'));
    counter.reset();
    expect(await comments.count(), rows + 1);
    expect(counts(), 1);
    await comments.deleteById(rows + 1);
    expect(await comments.count(), rows);
  });

  test('a commit of another connection on the same file makes the next count read again', () async {
    await comments.count();
    final Database other = await databaseFactory.openDatabase(comments.db.path, options: OpenDatabaseOptions(singleInstance: false));
    try {
      await other.rawInsert('INSERT INTO "comments" ("id", "text", "likes") VALUES (?, ?, ?)', [rows + 2, 'outside', 0]);
    } finally {
      await other.close();
    }
    expect(await comments.count(), rows + 1, reason: 'never the cached count from before the other commit');
    await comments.deleteById(rows + 2);
    expect(await comments.count(), rows);
  });

  test('a count inside a transaction that rolls back is never kept', () async {
    await comments.count();
    try {
      await FluentDb.transaction(() async {
        await comments.save(Comment(id: rows + 3, text: 'tx'));
        expect(await comments.count(), rows + 1, reason: 'the transaction sees its own write');
        throw StateError('roll back');
      }, dbKey: db.key);
    } on StateError {
      // expected
    }
    expect(await comments.count(), rows);
    expect(await comments.count(), rows);
  });
}
