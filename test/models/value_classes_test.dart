import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tag {
  const _Tag();
  @override
  String toString() => 'tag!';
}

class _Parent extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

class _Other extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

void main() {
  setUpFluentTests();

  group('FluentChangeEvent', () {
    test('toString shows model, table, kind and the number of items', () {
      final event = FluentChangeEvent<int>(modelType: String, table: 'notes', dbName: 'main', kind: FluentChangeKind.save, items: [1, 2, 3]);
      expect(event.toString(), 'FluentChangeEvent{model: String, table: main/notes, kind: save, itemsCount: 3}');
    });

    test('toString adds the tag only when there is one', () {
      final event = FluentChangeEvent<int>(modelType: int, table: 't', dbName: 'd', kind: FluentChangeKind.delete, tag: const _Tag());
      expect(event.toString(), contains(', tag: tag!'));
      expect(event.items, isEmpty);
      expect(FluentChangeEvent<int>(modelType: int, table: 't', dbName: 'd', kind: FluentChangeKind.delete).toString(), isNot(contains('tag')));
    });
  });

  group('FluentEngineStats', () {
    test('toString lists the counters and rounds the wait', () {
      const stats = FluentEngineStats(
        queued: 1,
        activeReads: 2,
        activeWrites: 3,
        completed: 4,
        collapsedReads: 5,
        mergedSaves: 6,
        batchedLookups: 7,
        splitBatches: 8,
        adoptedReads: 9,
        averageWaitMs: 12.345,
        maxWaitMs: 99,
      );
      final text = stats.toString();
      expect(text, contains('queued: 1'));
      expect(text, contains('active: 2 reads / 3 writes'));
      expect(text, contains('completed: 4'));
      expect(text, contains('collapsed: 5'));
      expect(text, contains('mergedSaves: 6'));
      expect(text, contains('batchedLookups: 7'));
      expect(text, contains('splitBatches: 8'));
      expect(text, contains('adoptedReads: 9'));
      expect(text, contains('wait: 12.3 ms avg / 99 ms max'));
      expect(stats.slowestQueries, isEmpty);
    });
  });

  group('FluentQueryCost / FluentQueryStats', () {
    const cost = FluentQueryCost(database: 'main', table: 'notes', action: 'find', shape: 'title =', averageMs: 3.456, samples: 7, failures: 0);

    test('toString shows shape, average, samples and optional rows / failures', () {
      expect(cost.toString(), 'notes.find title =: 3.5 ms × 7');
      const withRows = FluentQueryCost(database: 'main', table: 'n', action: 'find', shape: '', averageMs: 1, samples: 2, failures: 3, averageRows: 41.6);
      expect(withRows.toString(), 'n.find (all rows): 1.0 ms × 2, ~42 rows (3 failed)');
    });

    test('the stats table is empty-aware and lists every query', () {
      expect(const FluentQueryStats([]).toString(), 'No queries measured yet.');
      const withRows = FluentQueryCost(database: 'main', table: 'n', action: 'count', shape: 'x', averageMs: 2, samples: 3, failures: 1, averageRows: 10);
      final text = const FluentQueryStats([cost, withRows]).toString();
      expect(text, startsWith('Measured queries (avg ms × runs):\n'));
      expect(text, contains('main/notes find title ='));
      expect(text, contains('main/n count x  (~10 rows)  (1 failed)'));
      expect(text.trimRight().split('\n'), hasLength(3));
    });
  });

  group('FluentDbConfig', () {
    test('toString shows the non-default parts', () {
      expect(const FluentDbConfig().toString(), startsWith('FluentDbConfig{journal: wal, sync: normal'));
      expect(const FluentDbConfig().toString(), isNot(contains('fk: off')));
      final text = const FluentDbConfig(enableForeignKeys: false, readConnections: 3).toString();
      expect(text, contains(', fk: off'));
      expect(text, contains(', readConnections: 3'));
    });

    test('highIntegrity uses the rollback journal with full synchronous writes', () {
      expect(FluentDbConfig.highIntegrity.journalMode, SQLiteJournalMode.delete);
      expect(FluentDbConfig.highIntegrity.synchronous, SQLiteSynchronous.full);
      expect(FluentDbConfig.highIntegrity.tempStoreInMemory, isFalse);
    });

    test('the narrower settings stay null unless set (resolved from the wider level)', () {
      const c = FluentDbConfig();
      expect(c.trashRetention, isNull);
      expect(c.indexReferences, isNull);
      expect(c.autoRelations, isNull);
      expect(c.fullText, isNull);
      expect(c.diagnostics, isNull);
      expect(c.batchKeys, isNull);
      expect(c.busyTimeout, const Duration(seconds: 5));
    });
  });

  group('SQLiteCacheSize', () {
    test('kilobytes and megabytes are stored negative, pages positive', () {
      expect(SQLiteCacheSize.kiloBytes(100).rawValue, -100);
      expect(SQLiteCacheSize.kiloBytes(-100).rawValue, -100);
      expect(SQLiteCacheSize.megaBytes(2).rawValue, -2048);
      expect(SQLiteCacheSize.pages(50).rawValue, 50);
      expect(SQLiteCacheSize.pages(-50).rawValue, 50);
      expect(SQLiteCacheSize.defaultSize.rawValue, -10000);
    });

    test('toString names the unit', () {
      expect(SQLiteCacheSize.kiloBytes(64).toString(), 'SQLiteCacheSize(64 KB)');
      expect(SQLiteCacheSize.pages(10).toString(), 'SQLiteCacheSize(10 pages)');
    });
  });

  group('FluentDiagnostics / FluentTuning', () {
    test('presets', () {
      expect(FluentDiagnostics.none.hints, isFalse);
      expect(FluentDiagnostics.none.costModel, isFalse);
      expect(FluentDiagnostics.quiet.hints, isFalse);
      expect(FluentDiagnostics.quiet.costModel, isTrue);
      expect(FluentDiagnostics.recommend, const FluentDiagnostics());
      expect(FluentDiagnostics.auto.tuning, FluentTuning.full);
      expect(const FluentDiagnostics().tuning.isOff, isTrue);
    });

    test('copyWith replaces only what is given', () {
      const base = FluentDiagnostics();
      expect(base.copyWith(), base);
      final changed = base.copyWith(hints: false, hintsInRelease: true, costModel: false, tuning: FluentTuning.full);
      expect(changed.hints, isFalse);
      expect(changed.hintsInRelease, isTrue);
      expect(changed.costModel, isFalse);
      expect(changed.tuning, FluentTuning.full);
      expect(changed, isNot(base));
    });

    test('equality and hashCode cover every field', () {
      expect(const FluentDiagnostics(), const FluentDiagnostics());
      expect(const FluentDiagnostics().hashCode, const FluentDiagnostics().hashCode);
      expect(const FluentDiagnostics(hints: false), isNot(const FluentDiagnostics()));
      expect(const FluentDiagnostics(hintsInRelease: true), isNot(const FluentDiagnostics()));
      expect(const FluentDiagnostics(costModel: false), isNot(const FluentDiagnostics()));
      expect(const FluentDiagnostics(tuning: FluentTuning.full), isNot(const FluentDiagnostics()));
      expect(const FluentDiagnostics().toString(), 'FluentDiagnostics(hints: true, hintsInRelease: false, costModel: true, tuning: FluentTuning.off)');
    });

    test('tuning copyWith, equality and levers', () {
      expect(FluentTuning.off.isOff, isTrue);
      expect(FluentTuning.full.isOff, isFalse);
      expect(FluentTuning.noIndexes.indexes, isFalse);
      expect(FluentTuning.noIndexes.readConnections, isTrue);
      expect(FluentTuning.off.copyWith(), FluentTuning.off);
      final one = FluentTuning.off.copyWith(indexes: true, maxIndexes: 2);
      expect(one.indexes, isTrue);
      expect(one.maxIndexes, 2);
      expect(one.isOff, isFalse);
      for (final FluentTuning t in [
        FluentTuning.off.copyWith(readConnections: true),
        FluentTuning.off.copyWith(memory: true),
        FluentTuning.off.copyWith(background: true),
        FluentTuning.off.copyWith(checkpoints: true),
        FluentTuning.off.copyWith(frameBudget: true),
        FluentTuning.off.copyWith(indexes: true),
        FluentTuning.off.copyWith(maxIndexes: 9),
      ]) {
        expect(t, isNot(FluentTuning.off));
        expect(t.hashCode, isNot(FluentTuning.off.hashCode));
        expect(t, t.copyWith());
      }
    });

    test('tuning toString lists the enabled levers', () {
      expect(FluentTuning.off.toString(), 'FluentTuning.off');
      expect(FluentTuning.full.toString(), 'FluentTuning(indexes (max 5), readConnections, memory, background, checkpoints, frameBudget)');
      expect(FluentTuning.off.copyWith(memory: true).toString(), 'FluentTuning(memory)');
    });
  });

  group('FluentIndex / FluentCheck', () {
    test('names and create statements', () {
      const plain = FluentIndex(['a', 'b']);
      expect(plain.nameFor('t'), 'idx_t_a_b');
      expect(const FluentIndex.unique(['a']).nameFor('t'), 'uidx_t_a');
      expect(const FluentIndex(['a'], name: 'mine').nameFor('t'), 'mine');
      expect(plain.createSql('t'), 'CREATE INDEX IF NOT EXISTS "idx_t_a_b" ON "t" ("a", "b");');
      expect(const FluentIndex.unique(['a']).createSql('t'), 'CREATE UNIQUE INDEX IF NOT EXISTS "uidx_t_a" ON "t" ("a");');
      expect(const FluentIndex(['a'], where: ' b > 1 ').createSql('t'), endsWith('("a") WHERE b > 1;'));
      expect(const FluentIndex(['a'], where: '   ').createSql('t'), endsWith('("a");'));
    });

    test('quotes odd table and column names', () {
      const idx = FluentIndex(['we"ird col'], name: 'my idx');
      expect(idx.createSql('ta ble'), 'CREATE INDEX IF NOT EXISTS "my idx" ON "ta ble" ("we""ird col");');
    });

    test('full-text indexes are not unique and have no condition', () {
      const idx = FluentIndex.fullText(['title', 'body']);
      expect(idx.fullText, isTrue);
      expect(idx.unique, isFalse);
      expect(idx.where, isNull);
      expect(idx.toString(), 'FluentIndex.fullText(title, body)');
    });

    test('equality and hashCode compare every field and the column order', () {
      expect(const FluentIndex(['a', 'b']), const FluentIndex(['a', 'b']));
      expect(const FluentIndex(['a', 'b']).hashCode, const FluentIndex(['a', 'b']).hashCode);
      expect(const FluentIndex(['a', 'b']), isNot(const FluentIndex(['b', 'a'])));
      expect(const FluentIndex(['a']), isNot(const FluentIndex(['a', 'b'])));
      expect(const FluentIndex(['a']), isNot(const FluentIndex.unique(['a'])));
      expect(const FluentIndex(['a']), isNot(const FluentIndex(['a'], name: 'x')));
      expect(const FluentIndex(['a']), isNot(const FluentIndex(['a'], where: 'x')));
      expect(const FluentIndex(['a']), isNot(const FluentIndex.fullText(['a'])));
      expect(const FluentIndex(['a']) == Object(), isFalse);
    });

    test('toString', () {
      expect(const FluentIndex(['a']).toString(), 'FluentIndex(a)');
      expect(const FluentIndex.unique(['a', 'b'], where: 'x').toString(), 'FluentIndex(a, b, unique, where: x)');
    });

    test('FluentCheck builds its clause, with or without a name', () {
      expect(const FluentCheck('a > 0').sql, 'CHECK (a > 0)');
      expect(const FluentCheck('a > 0', name: 'positive').sql, 'CONSTRAINT "positive" CHECK (a > 0)');
      expect(const FluentCheck('a > 0'), const FluentCheck('a > 0'));
      expect(const FluentCheck('a > 0').hashCode, const FluentCheck('a > 0').hashCode);
      expect(const FluentCheck('a > 0'), isNot(const FluentCheck('a > 0', name: 'x')));
      expect(const FluentCheck('a > 0'), isNot(const FluentCheck('a > 1')));
      expect(const FluentCheck('a > 0') == Object(), isFalse);
      expect(const FluentCheck('a > 0').toString(), 'FluentCheck(a > 0)');
    });
  });

  group('FluentUpdate', () {
    test('increment and decrement are additions with a sign', () {
      expect(FluentUpdate.increment().operation, FluentUpdateOperation.add);
      expect(FluentUpdate.increment().amount, 1);
      expect(FluentUpdate.increment(2.5).amount, 2.5);
      expect(FluentUpdate.decrement().amount, -1);
      expect(FluentUpdate.decrement(4).amount, -4);
    });

    test('equality and hashCode', () {
      expect(FluentUpdate.increment(3), FluentUpdate.increment(3));
      expect(FluentUpdate.increment(3).hashCode, FluentUpdate.increment(3).hashCode);
      expect(FluentUpdate.increment(3), isNot(FluentUpdate.increment(4)));
      expect(FluentUpdate.increment(3), isNot(FluentUpdate.decrement(3)));
      expect(FluentUpdate.now, isNot(FluentUpdate.toggle));
      expect(FluentUpdate.now == Object(), isFalse);
    });

    test('toString', () {
      expect(FluentUpdate.increment(2).toString(), 'FluentUpdate.increment(2)');
      expect(FluentUpdate.decrement(2).toString(), 'FluentUpdate.decrement(2)');
      expect(FluentUpdate.now.toString(), 'FluentUpdate.now');
      expect(FluentUpdate.toggle.toString(), 'FluentUpdate.toggle');
    });
  });

  group('FluentSqlExpression / fluentSqlLiteral', () {
    test('equality, hashCode, toString', () {
      expect(const FluentSqlExpression('X'), const FluentSqlExpression('X'));
      expect(const FluentSqlExpression('X').hashCode, const FluentSqlExpression('X').hashCode);
      expect(const FluentSqlExpression('X'), isNot(const FluentSqlExpression('Y')));
      expect(const FluentSqlExpression('X') == Object(), isFalse);
      expect(FluentSqlExpression.currentTimestamp.toString(), 'FluentSqlExpression(CURRENT_TIMESTAMP)');
      expect(FluentSqlExpression.currentDate.sql, 'CURRENT_DATE');
    });

    test('literals', () {
      expect(fluentSqlLiteral(const FluentSqlExpression('1+1')), '(1+1)');
      expect(fluentSqlLiteral(1.5), '1.5');
      expect(fluentSqlLiteral("it's"), "'it''s'");
      expect(fluentSqlLiteral(DateTime.fromMillisecondsSinceEpoch(1234)), '1234');
      expect(fluentSqlLiteral(FluentChangeKind.save), "'save'");
      expect(fluentSqlLiteral(Uri.parse('a/b')), "'a/b'");
      expect(fluentSqlLiteral("'; DROP TABLE x; --"), "'''; DROP TABLE x; --'");
    });
  });

  group('FluentDbMigration', () {
    test('hasSteps and label', () {
      expect(const FluentDbMigration().hasSteps, isFalse);
      expect(const FluentDbMigration().label, isNull);
      expect(const FluentDbMigration(version: 3).label, 'v3');
      expect(const FluentDbMigration(version: 3, id: 'x').label, 'x');
      expect(const FluentDbMigration(rawSql: ['a']).hasSteps, isTrue);
      expect(const FluentDbMigration(dropColumns: ['a']).hasSteps, isTrue);
      expect(const FluentDbMigration(restoreColumns: {'a': 'b'}).hasSteps, isTrue);
      expect(FluentDbMigration(onMigrate: (_) async {}).hasSteps, isTrue);
    });

    test('contentHash is stable, 8 hex digits and depends on every step', () {
      const m = FluentDbMigration(rawSql: ['ALTER x'], dropColumns: ['a'], restoreColumns: {'b': 'c'});
      expect(m.contentHash, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(m.contentHash, const FluentDbMigration(rawSql: ['ALTER x'], dropColumns: ['a'], restoreColumns: {'b': 'c'}).contentHash);
      final hashes = {
        m.contentHash,
        const FluentDbMigration(rawSql: ['ALTER y'], dropColumns: ['a'], restoreColumns: {'b': 'c'}).contentHash,
        const FluentDbMigration(rawSql: ['ALTER x'], dropColumns: ['z'], restoreColumns: {'b': 'c'}).contentHash,
        const FluentDbMigration(rawSql: ['ALTER x'], dropColumns: ['a'], restoreColumns: {'b': 'd'}).contentHash,
        FluentDbMigration(rawSql: const ['ALTER x'], dropColumns: const ['a'], restoreColumns: const {'b': 'c'}, onMigrate: (_) async {}).contentHash,
      };
      expect(hashes, hasLength(5));
    });

    test('the step lists are separated: a drop is not a raw statement', () {
      expect(const FluentDbMigration(dropColumns: ['a']).contentHash, isNot(const FluentDbMigration(rawSql: ['a']).contentHash));
    });

    test('toString lists only the present parts', () {
      expect(const FluentDbMigration().toString(), 'FluentDbMigration{}');
      final text = FluentDbMigration(version: 2, rawSql: const ['a', 'b'], dropColumns: const ['c'], restoreColumns: const {'d': 'e'}, onMigrate: (_) async {}).toString();
      expect(text, 'FluentDbMigration{label: v2, rawSql: 2, dropColumns: [c], restoreColumns: {d: e}, onMigrate: yes}');
    });
  });

  group('FluentSaveResult', () {
    test('counts every outcome', () {
      final r = FluentSaveResult([
        FluentRowOutcome.inserted,
        FluentRowOutcome.inserted,
        FluentRowOutcome.updated,
        FluentRowOutcome.restored,
        FluentRowOutcome.skipped,
      ]);
      expect(r.inserted, 2);
      expect(r.updated, 1);
      expect(r.restored, 1);
      expect(r.skipped, 1);
      expect(r.saved, 4);
      expect(r.toString(), 'FluentSaveResult(inserted: 2, updated: 1, restored: 1, skipped: 1)');
    });

    test('empty result', () {
      expect(FluentSaveResult.empty.saved, 0);
      expect(FluentSaveResult.empty.outcomes, isEmpty);
      expect(FluentSaveResult.empty.toString(), 'FluentSaveResult(inserted: 0, updated: 0, restored: 0, skipped: 0)');
    });
  });

  group('FluentSyncResult and friends', () {
    test('itemsProcessed adds pushed and pulled', () {
      const r = FluentSyncResult<int>(strategy: FluentSyncStrategy.full, isSuccess: true, pushed: 2, pulled: 3);
      expect(r.itemsProcessed, 5);
      expect(r.toString(), 'FluentSyncResult(full, ok, pushed: 2, pulled: 3, conflicts: 0, remoteDeleted: 0)');
    });

    test('toString tells failed from cancelled and shows rejected only when > 0', () {
      const failed = FluentSyncResult<int>(strategy: FluentSyncStrategy.push, isSuccess: false, errorMessage: 'boom', rejected: 2);
      expect(failed.toString(), contains('failed: boom'));
      expect(failed.toString(), endsWith(', rejected: 2)'));
      const cancelled = FluentSyncResult<int>(strategy: FluentSyncStrategy.pull, isSuccess: false, isCancelled: true);
      expect(cancelled.toString(), contains(', cancelled,'));
      expect(cancelled.toString(), isNot(contains('rejected')));
    });

    test('FluentSyncStatus flags, equality and toString', () {
      const idle = FluentSyncStatus(state: FluentSyncState.idle, pending: 0);
      expect(idle.isSyncing, isFalse);
      expect(idle.hasPending, isFalse);
      expect(idle.toString(), 'FluentSyncStatus(idle, pending: 0)');
      final at = DateTime.utc(2026, 1, 2);
      final busy = FluentSyncStatus(state: FluentSyncState.syncing, pending: 2, lastSyncedAt: at, lastError: 'e');
      expect(busy.isSyncing, isTrue);
      expect(busy.hasPending, isTrue);
      expect(busy.toString(), 'FluentSyncStatus(syncing, pending: 2, last: $at, error: e)');
      expect(busy, FluentSyncStatus(state: FluentSyncState.syncing, pending: 2, lastSyncedAt: at, lastError: 'e'));
      expect(busy.hashCode, FluentSyncStatus(state: FluentSyncState.syncing, pending: 2, lastSyncedAt: at, lastError: 'e').hashCode);
      expect(busy, isNot(idle));
      expect(idle, isNot(const FluentSyncStatus(state: FluentSyncState.idle, pending: 1)));
      expect(idle, isNot(const FluentSyncStatus(state: FluentSyncState.failed, pending: 0)));
      expect(idle, isNot(FluentSyncStatus(state: FluentSyncState.idle, pending: 0, lastSyncedAt: at)));
      expect(idle, isNot(const FluentSyncStatus(state: FluentSyncState.idle, pending: 0, lastError: 'x')));
      expect(idle == Object(), isFalse);
    });

    test('FluentSyncBatch counts changed, deleted and key-only deletions', () {
      final empty = FluentSyncBatch<int>(changed: const [], deleted: const [], deletedKeys: const [], versions: const [], tombstones: const []);
      expect(empty.isEmpty, isTrue);
      expect(empty.length, 0);
      final batch = FluentSyncBatch<int>(changed: const [1, 2], deleted: const [3], deletedKeys: const ['k'], versions: const [], tombstones: const []);
      expect(batch.isEmpty, isFalse);
      expect(batch.length, 4);
      expect(FluentSyncBatch<int>(changed: const [], deleted: const [], deletedKeys: const ['k'], versions: const [], tombstones: const []).isEmpty, isFalse);
    });

    test('FluentPushResult states', () {
      const ok = FluentPushResult<int>.accepted(updated: [1], rejected: ['r']);
      expect(ok.isAccepted, isTrue);
      expect(ok.updated, [1]);
      expect(ok.rejected, ['r']);
      expect(ok.error, isNull);
      const no = FluentPushResult<int>.failed('bad');
      expect(no.isAccepted, isFalse);
      expect(no.error, 'bad');
      expect(no.updated, isEmpty);
      expect(no.rejected, isEmpty);
      expect(const FluentPushResult<int>.failed().error, isNull);
    });

    test('FluentPullRequest / FluentPullResult / FluentConflictPolicy', () {
      expect(const FluentPullRequest().toString(), 'FluentPullRequest(since: null, page: 0)');
      expect(FluentPullRequest(since: DateTime.utc(2026), cursor: 'c', page: 2).toString(), contains('page: 2, cursor: c'));
      const pull = FluentPullResult<int>();
      expect(pull.items, isEmpty);
      expect(pull.deletedKeys, isEmpty);
      expect(pull.hasMore, isFalse);
      expect(pull.serverTime, isNull);
      expect(const FluentConflictPolicy<int>.keepLocal().serverWins, isFalse);
      expect(const FluentConflictPolicy<int>.keepLocal().merge, isNull);
      expect(const FluentConflictPolicy<int>.keepServer().serverWins, isTrue);
      final merge = FluentConflictPolicy<int>.merge((int a, int b) async => a + b);
      expect(merge.serverWins, isFalse);
      expect(merge.merge, isNotNull);
    });
  });

  group('FluentRemote*', () {
    test('request toString', () {
      expect(const FluentRemoteRequest().toString(), 'FluentRemoteRequest(page: 0)');
      expect(const FluentRemoteRequest(cursor: 'abc', page: 2).toString(), 'FluentRemoteRequest(page: 2, cursor: abc)');
    });

    test('response constructors', () {
      const ok = FluentRemoteResponse<int>([1, 2], hasMore: true, cursor: 'n');
      expect(ok.items, [1, 2]);
      expect(ok.statusCode, 200);
      expect(ok.hasMore, isTrue);
      expect(ok.cursor, 'n');
      expect(ok.error, isNull);
      expect(FluentRemoteResponse<int>.single(5).items, [5]);
      expect(FluentRemoteResponse<int>.single(null).items, isEmpty);
      expect(FluentRemoteResponse<int>.single(5, statusCode: 201).statusCode, 201);
      const failed = FluentRemoteResponse<int>.failed(503, 'down');
      expect(failed.statusCode, 503);
      expect(failed.error, 'down');
      expect(failed.items, isEmpty);
      expect(failed.hasMore, isFalse);
    });

    test('event phases and toString', () {
      const cached = FluentRemoteEvent<int>(phase: FluentRemotePhase.cached, items: [1]);
      expect(cached.isFetching, isFalse);
      expect(cached.isFresh, isFalse);
      expect(cached.hasError, isFalse);
      expect(cached.isEmpty, isFalse);
      expect(cached.toString(), 'FluentRemoteEvent(cached, 1 item(s))');
      expect(const FluentRemoteEvent<int>(phase: FluentRemotePhase.fetching).isFetching, isTrue);
      expect(const FluentRemoteEvent<int>(phase: FluentRemotePhase.fresh).isFresh, isTrue);
      expect(const FluentRemoteEvent<int>(phase: FluentRemotePhase.fresh).isEmpty, isTrue);
      const failed = FluentRemoteEvent<int>(phase: FluentRemotePhase.failed, error: 'x');
      expect(failed.hasError, isTrue);
      expect(failed.toString(), 'FluentRemoteEvent(failed, 0 item(s), error: x)');
    });
  });

  group('FluentPage / FluentCursor', () {
    test('hasMore follows the cursor', () {
      expect(const FluentPage<int>([1], null).hasMore, isFalse);
      const cursor = FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 1});
      expect(const FluentPage<int>([1], cursor).hasMore, isTrue);
    });

    test('encode and decode round trip, for value kinds JSON keeps', () {
      for (final Object? value in [1, 'text', 2.5, null, true, 'ünï "q"']) {
        final cursor = FluentCursor(orderBy: 'name', descending: true, value: value, key: const {'id': 7, 'k2': 'x'});
        final decoded = FluentCursor.decode(cursor.encode());
        expect(decoded, cursor);
        expect(decoded.hashCode, cursor.hashCode);
        expect(decoded.descending, isTrue);
        expect(decoded.key, {'id': 7, 'k2': 'x'});
      }
    });

    test('the encoded form is URL safe base64 of JSON', () {
      const cursor = FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 1});
      final json = jsonDecode(utf8.decode(base64Url.decode(cursor.encode()))) as Map<String, dynamic>;
      expect(json, {'o': 'a', 'd': false, 'v': 1, 'k': {'id': 1}});
    });

    test('decoding garbage fails', () {
      expect(() => FluentCursor.decode('%%%'), throwsA(isA<FormatException>()));
      expect(() => FluentCursor.decode(base64Url.encode(utf8.encode('[1]'))), throwsA(isA<TypeError>()));
    });

    test('equality compares every field and the key map', () {
      const base = FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 1});
      expect(base, const FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 1}));
      expect(base, isNot(const FluentCursor(orderBy: 'b', descending: false, value: 1, key: {'id': 1})));
      expect(base, isNot(const FluentCursor(orderBy: 'a', descending: true, value: 1, key: {'id': 1})));
      expect(base, isNot(const FluentCursor(orderBy: 'a', descending: false, value: 2, key: {'id': 1})));
      expect(base, isNot(const FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 2})));
      expect(base == Object(), isFalse);
    });

    test('hashCode ignores key order', () {
      const a = FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'x': 1, 'y': 2});
      const b = FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'y': 2, 'x': 1});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('toString', () {
      expect(const FluentCursor(orderBy: 'a', descending: false, value: 1, key: {'id': 1}).toString(), 'FluentCursor(a ASC after 1 / {id: 1})');
      expect(const FluentCursor(orderBy: 'a', descending: true, value: 1, key: {}).toString(), startsWith('FluentCursor(a DESC'));
    });
  });

  group('FluentDbKey', () {
    test('keys of the same name are equal and usable as map keys', () {
      final a = FluentDbKey('cache');
      final b = FluentDbKey('cache');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(FluentDbKey('other')));
      expect({a: 1}[b], 1);
      expect(<FluentDbKey>{a, b}, hasLength(1));
      expect(a.toString(), 'cache');
      expect(a == Object(), isFalse);
    });
  });

  group('FluentDbDataType.fromType', () {
    test('maps Dart values to SQLite storage classes', () {
      expect(FluentDbDataType.fromType(1), FluentDbDataType.integer);
      expect(FluentDbDataType.fromType(true), FluentDbDataType.integer);
      expect(FluentDbDataType.fromType(const Duration(seconds: 1)), FluentDbDataType.integer);
      expect(FluentDbDataType.fromType(1.5), FluentDbDataType.real);
      expect(FluentDbDataType.fromType(Uint8List(1)), FluentDbDataType.blob);
      expect(FluentDbDataType.fromType('s'), FluentDbDataType.text);
      expect(FluentDbDataType.fromType(DateTime(2026)), FluentDbDataType.text);
      expect(FluentDbDataType.fromType(const <String, int>{}), FluentDbDataType.text);
      expect(FluentDbDataType.fromType(null), FluentDbDataType.text);
      expect(FluentDbDataType.fromType(FluentChangeKind.save), FluentDbDataType.text);
    });
  });

  group('exceptions', () {
    test('FluentEngineException defaults to the engineError code', () {
      final e = FluentEngineException('broken', hint: 'restart', cause: 'c');
      expect(e.code, FluentErrorCode.engineError);
      expect(e.hint, 'restart');
      expect(e.cause, 'c');
      expect(e.message, 'broken');
    });

    test('FluentCancelledException defaults to engineClosed', () {
      expect(FluentCancelledException('closed').code, FluentErrorCode.engineClosed);
    });

    test('every typed exception has its default code and keeps its extras', () {
      expect(FluentConfigException('x').code, FluentErrorCode.invalidConfiguration);
      final schema = FluentSchemaException('x', modelName: 'M', columnName: 'c');
      expect(schema.code, FluentErrorCode.schemaConflict);
      expect(schema.modelName, 'M');
      expect(schema.columnName, 'c');
      expect(FluentSyncException('x', statusCode: 404).statusCode, 404);
      expect(FluentSyncException('x').code, FluentErrorCode.syncFailed);
      expect(FluentSyncException('x').statusCode, isNull);
      expect(FluentSyncException('x'), isA<FluentException>());
    });
  });

  group('FluentRelation', () {
    test('toString names the types and the relation kind', () {
      final r = FluentRelation<FluentStorable, FluentStorable>(name: 'items', type: FluentRelationType.many, select: (FluentStorable p) => null);
      expect(r.toString(), 'FluentRelation<FluentStorable, FluentStorable>(items, many)');
      expect(r.parentType, FluentStorable);
      expect(r.childType, FluentStorable);
    });

    test('selectFrom rejects a parent of another type with a hint', () {
      final r = FluentRelation<_Parent, FluentStorable>(name: 'items', type: FluentRelationType.many, select: (_Parent p) => ['x']);
      expect(r.selectFrom(_Parent()), ['x']);
      expect(
        () => r.selectFrom(_Other()),
        throwsA(isA<FluentRelationException>().having((e) => e.hint, 'hint', contains('FluentRelation<_Other, FluentStorable>'))),
      );
    });

    test('isList follows the type; for auto the select decides', () {
      final many = FluentRelation<FluentStorable, FluentStorable>(name: 'a', type: FluentRelationType.many, select: (FluentStorable p) => null);
      final one = FluentRelation<FluentStorable, FluentStorable>(name: 'a', type: FluentRelationType.one, select: (FluentStorable p) => null);
      Object? untyped(FluentStorable p) => null;
      final auto = FluentRelation<FluentStorable, FluentStorable>(name: 'a', type: FluentRelationType.auto, select: untyped);
      final autoList = FluentRelation<FluentStorable, FluentStorable>(name: 'a', type: FluentRelationType.auto, select: (FluentStorable p) => <FluentStorable>[]);
      final autoOne = FluentRelation<FluentStorable, FluentStorable>(name: 'a', type: FluentRelationType.auto, select: (FluentStorable p) => _Other());
      expect(many.isList, isTrue);
      expect(one.isList, isFalse);
      expect(auto.selectsList, isNull);
      expect(auto.isList, isFalse);
      expect(autoList.selectsList, isTrue);
      expect(autoList.isList, isTrue);
      expect(autoOne.selectsList, isFalse);
      expect(autoOne.isList, isFalse);
    });

    test('auto() builds an auto relation with the preference', () {
      final r = FluentRelation.auto<_Parent, _Other>('notes', (_Parent p) => null, prefer: FluentRelationType.many);
      expect(r.type, FluentRelationType.auto);
      expect(r.prefer, FluentRelationType.many);
      expect(r.name, 'notes');
    });
  });
}
