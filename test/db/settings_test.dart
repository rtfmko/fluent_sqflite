// Settings: table → database → global scope, runtime changes, the pause watchdog, query stats kept in each database.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/relation_models.dart';

class Memo extends FluentStorable with FluentSoftDeletable {
  Memo({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

/// Same shape as [Memo], with its own trash retention.
class Draft extends Memo {
  Draft({super.id, required super.text});

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 2));
}

class MemoProvider extends FluentProvider<Memo> {
  @override
  String get tableName => 'memos';

  @override
  Memo get modelSample => Memo(text: '');

  @override
  Memo fromCacheJson(Map<String, dynamic> json) => Memo(id: json['id'] as int?, text: json['text'] as String);
}

class DraftProvider extends FluentProvider<Draft> {
  @override
  String get tableName => 'drafts';

  @override
  Draft get modelSample => Draft(text: '');

  @override
  Draft fromCacheJson(Map<String, dynamic> json) => Draft(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() => db = FluentTestDb(name: 'settings_${DateTime.now().microsecondsSinceEpoch}', persistent: true));

  tearDown(() async {
    await db.close();
  });

  group('Scope: table → database → global', () {
    /// Deletes one row of each table at [deletedAt], then purges the trash at [now]; returns the rows left in it.
    Future<(int memos, int drafts)> purgeAt(MemoProvider memos, DraftProvider drafts, DateTime deletedAt, DateTime now) async {
      db.clock.set(deletedAt);
      await memos.save(Memo(text: 'm'));
      await drafts.save(Draft(text: 'd'));
      await memos.deleteWhere(const FluentFilter('1 = 1'));
      await drafts.deleteWhere(const FluentFilter('1 = 1'));
      db.clock.set(now);
      await memos.trash.empty();
      await drafts.trash.empty();
      return ((await memos.trash.find()).length, (await drafts.trash.find()).length);
    }

    test('trash retention: the table wins over the database, the database over the global setting', () async {
      final MemoProvider memos = MemoProvider();
      final DraftProvider drafts = DraftProvider();
      final DateTime start = DateTime(2026, 3, 2);

      await db.open([memos, drafts], fluentConfig: const FluentConfig(trashRetention: Duration(days: 10)));
      expect(await purgeAt(memos, drafts, start, start.add(const Duration(days: 5))), (1, 0), reason: 'global 10 days; drafts 2 days');

      await db.open([memos, drafts], config: const FluentDbConfig(trashRetention: Duration(days: 3)), fluentConfig: const FluentConfig(trashRetention: Duration(days: 10)));
      await memos.trash.empty(olderThan: Duration.zero);
      expect(await purgeAt(memos, drafts, start, start.add(const Duration(days: 4))), (0, 0), reason: 'database 3 days beats global 10');
    });

    test('indexReferences: a table can turn the reference indexes off while its database keeps them', () async {
      await db.open(relationProviders());
      final List<Map<String, Object?>> withIndex = await FluentDb.provider<ArticleProvider>().db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'articles' AND sql LIKE '%author_id%'");
      expect(withIndex, isNotEmpty, reason: 'on by default');

      await db.open(relationProviders(), config: const FluentDbConfig(indexReferences: false));
      final List<Map<String, Object?>> without = await FluentDb.provider<ArticleProvider>().db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'articles' AND sql LIKE '%author_id%'");
      expect(without, isEmpty, reason: 'the database turned them off');
    });
  });

  group('Runtime', () {
    test('configure replaces the global settings at once', () async {
      await db.open([MemoProvider()]);
      expect(FluentDb.config.trashRetention, const Duration(days: 7));
      FluentDb.configure(const FluentConfig(trashRetention: Duration(days: 1), optimizeInterval: null));
      expect(FluentDb.config.trashRetention, const Duration(days: 1));
      expect(FluentDb.config.optimizeInterval, isNull);
    });

    test('the pause watchdog resumes a forgotten pause and reports the automatic change', () async {
      final MemoProvider memos = MemoProvider();
      await db.open([memos], fluentConfig: const FluentConfig(pauseWatchdog: Duration(milliseconds: 50)));
      final List<FluentLogRecord> warnings = [];
      FluentDb.setupLogging(enabled: true, onRecord: (r) {
        if (r.issue?.kind == FluentIssueKind.queueResumed) warnings.add(r);
      });
      await FluentDb.pauseQueue();
      final Future<FluentSaveResult> save = memos.save(Memo(text: 'waits'));
      expect((await save).inserted, 1, reason: 'the queue was resumed by the watchdog');
      expect(warnings.single.message, contains('resumed automatically'));
      FluentDb.setupLogging(enabled: false, onRecord: (_) {});
    });
  });

  group('Query stats', () {
    test('kept in the database, loaded again after a restart; rows and mapping cost included', () async {
      final MemoProvider memos = MemoProvider();
      await db.open([memos]);
      await memos.saveAll([for (int i = 0; i < 60; i++) Memo(text: 'm$i')]);
      for (int i = 0; i < 3; i++) {
        await memos.find(where: FluentFilter.startsWith('text', 'm1'));
      }
      await memos.findAll();
      final FluentQueryCost find = FluentDb.queryStats(table: 'memos').queries.firstWhere((c) => c.action == 'find' && c.shape.contains('LIKE'));
      expect(find.averageRows, 11, reason: 'm1, m10..m19');
      expect(FluentTableStatsTracker().mappingMicros(db.name, 'memos'), isNotNull, reason: '60 rows were mapped');

      await db.restart([MemoProvider()]);
      final FluentQueryStats stats = FluentDb.queryStats(dbKey: FluentDbKey(db.name));
      expect(stats.queries.where((c) => c.action == 'find' && c.samples >= 3), isNotEmpty, reason: 'loaded from __fluent_stats');
      expect(FluentTableStatsTracker().mappingMicros(db.name, 'memos'), isNotNull, reason: 'smart mapping knows the cost right after start');
      expect(stats.toString(), contains('memos find'));
    });

    test('in-memory databases keep their stats in memory only', () async {
      final MemoProvider memos = MemoProvider();
      final FluentTestDb memory = FluentTestDb();
      await memory.open([memos]);
      await memos.findAll();
      expect(FluentDb.queryStats(table: 'memos').queries, isNotEmpty);
      final List<Map<String, Object?>> tables = await memos.db.rawQuery("SELECT name FROM sqlite_master WHERE name = '__fluent_stats'");
      expect(tables, isEmpty);
      await memory.close();
    });

    test('the telemetry file of earlier versions is deleted at start', () async {
      final String legacy = join(await getDatabasesPath(), 'fluent_system.db');
      final Database old = await databaseFactoryFfi.openDatabase(legacy);
      await old.execute('CREATE TABLE fluent_cost_model (key TEXT)');
      await old.close();
      await db.open([MemoProvider()]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await databaseFactoryFfi.databaseExists(legacy), isFalse);
    });
  });
}
