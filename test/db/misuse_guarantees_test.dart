// T9 (TEST_PLAN.md): wrong settings (G27) and wrong models (G28) never cost data and never stop the library.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fuzz.dart';
import '../helpers/guarantees.dart';

class Note extends FluentStorable with FluentSoftDeletable {
  Note({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class NoteProvider extends FluentProvider<Note> {
  @override
  String get tableName => 'notes';

  @override
  Note get modelSample => Note(text: '');

  @override
  Note fromCacheJson(Map<String, dynamic> json) => Note(id: json['id'] as int?, text: json['text'] as String);
}

/// One wrong setting: [group] is the database part, [global] the library part.
class Setting {
  const Setting(this.name, {this.group = const FluentDbConfig(), this.global = const FluentConfig(), this.archive = const Duration(days: 30), this.history = 100, this.fallback = false});

  final String name;
  final FluentDbConfig group;
  final FluentConfig global;
  final Duration? archive;
  final int history;

  /// The setting cannot work: it must be refused typed, or replaced by a safe value with a `configFallback` warning.
  final bool fallback;
}

final List<Setting> settings = [
  const Setting('transactionWatchdog zero', global: FluentConfig(transactionWatchdog: Duration.zero), fallback: true),
  const Setting('transactionWatchdog negative', global: FluentConfig(transactionWatchdog: Duration(seconds: -5)), fallback: true),
  const Setting('pauseWatchdog zero', global: FluentConfig(pauseWatchdog: Duration.zero), fallback: true),
  const Setting('pauseWatchdog negative', global: FluentConfig(pauseWatchdog: Duration(milliseconds: -1)), fallback: true),
  const Setting('trashPurgeInterval zero', global: FluentConfig(trashPurgeInterval: Duration.zero), fallback: true),
  const Setting('trashPurgeInterval negative', global: FluentConfig(trashPurgeInterval: Duration(hours: -1)), fallback: true),
  const Setting('optimizeInterval zero', global: FluentConfig(optimizeInterval: Duration.zero), fallback: true),
  const Setting('optimizeInterval negative', global: FluentConfig(optimizeInterval: Duration(days: -1)), fallback: true),
  const Setting('all watchdogs and intervals null', global: FluentConfig(transactionWatchdog: null, pauseWatchdog: null, trashPurgeInterval: null, optimizeInterval: null)),
  const Setting('intervals huge', global: FluentConfig(transactionWatchdog: Duration(days: 365000), pauseWatchdog: Duration(days: 365000), trashPurgeInterval: Duration(days: 365000), optimizeInterval: Duration(days: 365000))),
  const Setting('intervals one microsecond', global: FluentConfig(transactionWatchdog: Duration(microseconds: 1), pauseWatchdog: Duration(microseconds: 1))),
  // G27 seeds 100402 / 102755: a 1 ms purge / optimize interval ran its job back to back, the library was never idle.
  const Setting('purge and optimize every millisecond', global: FluentConfig(trashPurgeInterval: Duration(milliseconds: 1), optimizeInterval: Duration(microseconds: 1)), fallback: true),
  const Setting('sliceAfterRows zero', global: FluentConfig(sliceAfterRows: 0)),
  const Setting('sliceAfterRows negative', global: FluentConfig(sliceAfterRows: -5)),
  const Setting('sliceAfterRows 1', global: FluentConfig(sliceAfterRows: 1)),
  const Setting('sliceAfterRows maxint', global: FluentConfig(sliceAfterRows: 9007199254740991)),
  const Setting('frameBudget zero', global: FluentConfig(frameBudget: Duration.zero)),
  const Setting('frameBudget negative', global: FluentConfig(frameBudget: Duration(milliseconds: -4))),
  const Setting('frameBudget huge', global: FluentConfig(frameBudget: Duration(days: 1000))),
  const Setting('frameBudget 1 us, isolates always', global: FluentConfig(frameBudget: Duration(microseconds: 1), isolateMapping: FluentIsolateMapping.always)),
  const Setting('trashRetention negative (global)', global: FluentConfig(trashRetention: Duration(days: -7)), fallback: true),
  const Setting('trashRetention negative (database)', group: FluentDbConfig(trashRetention: Duration(days: -1)), fallback: true),
  const Setting('trashRetention huge', global: FluentConfig(trashRetention: Duration(days: 365000000))),
  const Setting('archiveRetention negative', archive: Duration(days: -30), fallback: true),
  const Setting('archiveRetention zero', archive: Duration.zero),
  const Setting('archiveRetention null', archive: null),
  const Setting('historyLimit zero', history: 0),
  const Setting('historyLimit negative', history: -3, fallback: true),
  const Setting('historyLimit huge', history: 1 << 62),
  const Setting('readConnections negative (database)', group: FluentDbConfig(readConnections: -3), fallback: true),
  const Setting('readConnections negative (global)', global: FluentConfig(readConnections: -1), fallback: true),
  const Setting('readConnections 1000 (database)', group: FluentDbConfig(readConnections: 1000), fallback: true),
  const Setting('readConnections 0', group: FluentDbConfig(readConnections: 0)),
  const Setting('busyTimeout zero', group: FluentDbConfig(busyTimeout: Duration.zero)),
  const Setting('busyTimeout negative', group: FluentDbConfig(busyTimeout: Duration(seconds: -5)), fallback: true),
  const Setting('busyTimeout huge', group: FluentDbConfig(busyTimeout: Duration(days: 100000))),
  const Setting('busyTimeout null', group: FluentDbConfig(busyTimeout: null)),
  Setting('cacheSize 0 pages', group: FluentDbConfig(cacheSize: SQLiteCacheSize.pages(0))),
  Setting('cacheSize 0 kB', group: FluentDbConfig(cacheSize: SQLiteCacheSize.kiloBytes(0))),
  Setting('cacheSize negative pages (abs)', group: FluentDbConfig(cacheSize: SQLiteCacheSize.pages(-100))),
  Setting('cacheSize huge MB', group: FluentDbConfig(cacheSize: SQLiteCacheSize.megaBytes(1 << 40))),
  Setting('cacheSize huge pages', group: FluentDbConfig(cacheSize: SQLiteCacheSize.pages(1 << 62))),
  const Setting('journal off', group: FluentDbConfig(journalMode: SQLiteJournalMode.off)),
  const Setting('journal memory', group: FluentDbConfig(journalMode: SQLiteJournalMode.memory)),
  const Setting('journal truncate + synchronous off', group: FluentDbConfig(journalMode: SQLiteJournalMode.truncate, synchronous: SQLiteSynchronous.off)),
  const Setting('journal persist + extra', group: FluentDbConfig(journalMode: SQLiteJournalMode.persist, synchronous: SQLiteSynchronous.extra)),
  const Setting('foreign keys off + indexReferences + autoRelations', group: FluentDbConfig(enableForeignKeys: false, indexReferences: true, autoRelations: true)),
  const Setting('high integrity preset', group: FluentDbConfig.highIntegrity),
  const Setting('diagnostics off', global: FluentConfig(diagnostics: FluentDiagnostics.none)),
  const Setting('diagnostics full', group: FluentDbConfig(diagnostics: FluentDiagnostics.auto)),
  const Setting('default policy odd', global: FluentConfig(defaultPolicy: ExecutionPolicy(priority: -1000000))),
];

/// A model whose every declaration is supplied by a [Probe]: lets a test misdeclare anything.
class Probe {
  Probe({
    this.table = 'items',
    this.columns = _goodColumns,
    this.key,
    this.keys,
    this.build,
    this.read,
    this.sample,
    this.relations = const [],
    this.config,
  });

  final String table;
  final List<FluentDbColumn> Function() columns;
  final FluentDbColumn Function()? key;
  final List<FluentDbColumn> Function()? keys;
  final Map<String, dynamic> Function(Map<String, dynamic> values)? build;
  final ProbeModel Function(Probe probe, Map<String, dynamic> json)? read;
  final ProbeModel Function(Probe probe)? sample;
  final List<FluentRelation> relations;
  final FluentTableConfig? config;
}

List<FluentDbColumn> _goodColumns() => [FluentDbColumn.text('text')];

class ProbeModel extends FluentStorable with FluentRelations {
  ProbeModel(this.probe, [this.values = const {}]);

  final Probe probe;
  final Map<String, dynamic> values;

  @override
  FluentDbColumn get primaryKey => probe.key?.call() ?? super.primaryKey;

  @override
  List<FluentDbColumn> get primaryKeys => probe.keys?.call() ?? super.primaryKeys;

  @override
  List<FluentDbColumn> get tableSchema => probe.columns();

  @override
  List<FluentRelation> get relations => probe.relations;

  @override
  FluentTableConfig get tableConfig => probe.config ?? const FluentTableConfig();

  @override
  Map<String, dynamic> buildJson() => probe.build?.call(values) ?? Map<String, dynamic>.from(values);
}

class ProbeProvider extends FluentProvider<ProbeModel> {
  ProbeProvider(this.probe);

  final Probe probe;

  @override
  String get tableName => probe.table;

  @override
  ProbeModel get modelSample => probe.sample?.call(probe) ?? ProbeModel(probe);

  @override
  ProbeModel fromCacheJson(Map<String, dynamic> json) => probe.read?.call(probe, json) ?? ProbeModel(probe, json);
}

/// A model that no provider is registered for.
class Orphan extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': null};
}

/// One misdeclared model: what [declare] returns replaces the good providers at the second start.
class BadModel {
  const BadModel(this.name, this.declare, {this.mustReport = true});

  final String name;
  final List<FluentProvider> Function() declare;

  /// The declaration is wrong: the start must be refused typed or report an issue (a warning).
  final bool mustReport;
}

final Probe goodProbe = Probe();

List<FluentProvider> Function() one(Probe p) => () => [ProbeProvider(p)];

final List<BadModel> badModels = [
  BadModel('duplicate columns', one(Probe(columns: () => [FluentDbColumn.text('text'), FluentDbColumn.text('text')]))),
  BadModel('column named like the key', one(Probe(columns: () => [FluentDbColumn.text('id')]))),
  BadModel('key column missing from a custom key', one(Probe(key: () => FluentDbColumn.integer('nope')))),
  BadModel('key changes type (int to text)', one(Probe(key: () => FluentDbColumn.text('id')))),
  BadModel('key renamed', one(Probe(key: () => FluentDbColumn.primary(name: 'item_id')))),
  BadModel('composite key with a nullable part', one(Probe(keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.text('text')]))),
  BadModel('composite key naming a missing column', one(Probe(keys: () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('ghost')]))),
  BadModel('empty column name', one(Probe(columns: () => [FluentDbColumn.text('')]))),
  BadModel('column name with quote and space', one(Probe(columns: () => [FluentDbColumn.text('my "col" x')])), mustReport: false),
  BadModel('column named like a SQL keyword', one(Probe(columns: () => [FluentDbColumn.text('select'), FluentDbColumn.text('order')])), mustReport: false),
  BadModel('table named like a SQL keyword', one(Probe(table: 'select')), mustReport: false),
  BadModel('table with a space', one(Probe(table: 'my items')), mustReport: false),
  BadModel('table with a double quote', one(Probe(table: 'my"items')), mustReport: false),
  BadModel('empty table name', one(Probe(table: ''))),
  BadModel('table named like a bookkeeping table', one(Probe(table: '__fluent_schema'))),
  BadModel('table named with the sqlite_ prefix', one(Probe(table: 'sqlite_items'))),
  BadModel('buildJson throws', one(Probe(build: (_) => throw StateError('boom'))), mustReport: false),
  BadModel('buildJson returns a field the table does not have', one(Probe(build: (v) => {...v, 'extra': 1})), mustReport: false),
  BadModel('modelSample throws', one(Probe(sample: (_) => throw StateError('no sample')))),
  BadModel('fromCacheJson throws', one(Probe(read: (_, _) => throw StateError('cannot read'))), mustReport: false),
  BadModel('two providers for one table', () => [ProbeProvider(goodProbe), ProbeProvider(goodProbe)]),
  BadModel('two providers of different models for one table', () => [ProbeProvider(goodProbe), ProbeProvider(Probe(columns: () => [FluentDbColumn.integer('other')]))]),
  BadModel('relation to an unregistered model', one(Probe(relations: [FluentRelation.one<ProbeModel, Orphan>('orphan', (m) => null)]))),
  BadModel('relation with a foreign key that collides with a column', one(Probe(columns: () => [FluentDbColumn.text('text'), FluentDbColumn.text('parent_id')], relations: [FluentRelation.one<ProbeModel, ProbeModel>('parent', (m) => null)]))),
  BadModel('relation names a missing foreign key column on the child', () {
    final Probe child = Probe(table: 'kids');
    final Probe parent = Probe(relations: [FluentRelation<ProbeModel, ProbeModel>(name: 'kids', type: FluentRelationType.many, select: (m) => null, foreignKey: 'no_such_column')]);
    return [ProbeProvider(parent), ProbeProvider(child)];
  }),
  BadModel('two relations with the same name', one(Probe(relations: [FluentRelation.one<ProbeModel, ProbeModel>('same', (m) => null), FluentRelation.many<ProbeModel, ProbeModel>('same', (m) => null)]))),
  BadModel('relation cycle between two tables (one-owned both ways)', () {
    final Probe a = Probe(relations: [FluentRelation.oneOwned<ProbeModel, ProbeModel>('b', (m) => null)]);
    final Probe b = Probe(table: 'others', relations: [FluentRelation.oneOwned<ProbeModel, ProbeModel>('a', (m) => null)]);
    return [ProbeProvider(a), ProbeProvider(b)];
  }),
  BadModel('relation to a model served by two tables (ambiguous)', () {
    final Probe parent = Probe(relations: [FluentRelation.many<ProbeModel, ProbeModel>('kids', (m) => null)]);
    return [ProbeProvider(parent), ProbeProvider(Probe(table: 'others')), ProbeProvider(Probe(table: 'others2'))];
  }),
];

String _describe(FluentConfig g) =>
    'FluentConfig(tx ${g.transactionWatchdog}, pause ${g.pauseWatchdog}, purge ${g.trashPurgeInterval}, optimize ${g.optimizeInterval}, slice ${g.sliceAfterRows}, frame ${g.frameBudget}, retention ${g.trashRetention}, readers ${g.readConnections}, ${g.isolateMapping.name})';

FuzzOp _configureOp(FluentConfig g) => FuzzOp('configure ${_describe(g)}', () async => FluentDb.configure(g));

FuzzOp _restartOp(FluentFuzz f, FluentConfig g, FluentDbConfig c, Duration? archive, int history, FluentTestDb Function() db, NoteProvider notes) => FuzzOp(
  'restart ${_describe(g)}, $c busy ${c.busyTimeout}, readers ${c.readConnections}, retention ${c.trashRetention}, archive $archive, history $history',
  () async {
    try {
      await db().restart([notes], config: c, fluentConfig: g, archiveRetention: archive, historyLimit: history);
    } on FluentException catch (e) {
      expectTypedError(e);
      await db().restart([notes]);
    }
  },
);

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late NoteProvider notes;

  setUp(() {
    db = FluentTestDb(name: 'misuse_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    notes = NoteProvider();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed() async {
    await db.open([notes]);
    await notes.saveAll([for (int i = 1; i <= 10; i++) Note(text: 'note $i')]);
    await notes.deleteWhere(FluentFilter.ids([9, 10])); // two rows in the trash
    await notes.save(Note(text: 'kept in the trash'));
    await notes.deleteById(11);
    await db.settle();
  }

  Future<void> expectData({String? reason}) async {
    expect((await notes.findAll()).map((n) => n.text).toSet(), {for (int i = 1; i <= 8; i++) 'note $i'}, reason: 'G27: live rows ${reason ?? ''}');
    expect((await notes.trash.find()).map((n) => n.id).toSet(), {9, 10, 11}, reason: 'G21/G27: trashed rows are not purged by a wrong setting ${reason ?? ''}');
  }

  group('G27: wrong settings', () {
    for (final Setting s in settings) {
      test('G27: ${s.name}', () async {
        await seed();
        Object? refused;
        try {
          await db.restart([notes], config: s.group, fluentConfig: s.global, archiveRetention: s.archive, historyLimit: s.history);
        } catch (e) {
          refused = e;
        }
        if (refused != null) {
          expectTypedError(refused, reason: 'refused ${s.name}');
          await db.restart([notes]);
          await expectData(reason: 'after a refused start');
          return;
        }
        await db.settle();
        await expectData(reason: 'with ${s.name}');
        if (s.fallback) {
          expect(db.issues.any((i) => i.kind == FluentIssueKind.configFallback), isTrue, reason: 'G27: ${s.name} must report configFallback; got ${db.issues.map((i) => i.kind.name).toList()}');
        }
        // The library keeps working.
        await notes.save(Note(text: 'after'));
        expect(await notes.count(), 9);
        await expectIntegrity(notes.db, reason: s.name);
        expectIssuesHaveFixes(db.issues);
        // A second start with good settings: all rows back.
        await db.restart([notes]);
        expect((await notes.findAll()).length, 9, reason: 'after restart with the good settings');
        expect((await notes.trash.find()).map((n) => n.id).toSet(), {9, 10, 11});
      });
    }
  });

  group('G27: settings changed at run time and contradictory combinations', () {
    test('G27: configure() with settings that cannot work falls back with a warning and the library keeps working', () async {
      await seed();
      FluentDb.configure(const FluentConfig(transactionWatchdog: Duration(seconds: -1), pauseWatchdog: Duration.zero, trashPurgeInterval: Duration(days: -1), optimizeInterval: Duration.zero, readConnections: 99, trashRetention: Duration(days: -2)));
      await db.settle();
      final Set<String> kinds = {for (final FluentIssue i in db.issues) '${i.kind.name}:${i.subject}'};
      for (final String s in ['transactionWatchdog', 'pauseWatchdog', 'trashPurgeInterval', 'optimizeInterval', 'readConnections']) {
        expect(kinds, contains('configFallback:$s'), reason: 'G27: $s is reported');
      }
      expect(FluentDb.config.transactionWatchdog, greaterThan(Duration.zero));
      expect(FluentDb.config.trashPurgeInterval, greaterThan(Duration.zero));
      await notes.save(Note(text: 'after configure'));
      expect((await notes.findAll()).map((n) => n.text), containsAll([for (int i = 1; i <= 8; i++) 'note $i']), reason: 'G27: live rows after configure');
      // The negative trash retention is skipped when the trash is purged: nothing is lost.
      await notes.purgeTrash();
      await db.settle();
      expect((await notes.trash.find()).map((n) => n.id).toSet(), {9, 10, 11}, reason: 'G21/G27: a negative retention purges nothing');
      expect(db.issues.any((i) => i.kind == FluentIssueKind.configFallback && i.subject == 'trashRetention'), isTrue);
      await expectIntegrity(notes.db);
      expectIssuesHaveFixes(db.issues);
    });

    test('G27: readOnly + a changed model never writes: rows and file stay as they were', () async {
      final ProbeProvider good = ProbeProvider(goodProbe);
      await db.open([good]);
      await good.saveAll([for (int i = 1; i <= 5; i++) ProbeModel(goodProbe, {'id': i, 'text': 'row $i'})]);
      await db.close(keepFile: true);
      final Probe changed = Probe(columns: () => [FluentDbColumn.text('text'), FluentDbColumn.integer('added', isNotNull: true, defaultValue: 0)]);
      FluentDbInternals.reset();
      Object? refused;
      try {
        await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [ProbeProvider(changed)], readOnly: true)]);
        final ProbeProvider p = FluentDbInternals.providersOf(db.name).whereType<ProbeProvider>().first;
        await waitAllSettled([p.findAll(), p.save(ProbeModel(changed, {'text': 'no'})), p.count()], names: ['read', 'write on a read-only database', 'count']);
      } catch (e) {
        refused = e;
      }
      if (refused != null) expectTypedError(refused);
      await FluentDb.close();
      FluentDbInternals.reset();
      final Database raw = await databaseFactoryFfi.openDatabase('${await getDatabasesPath()}/${db.name}.db');
      expect((await raw.rawQuery('SELECT "id", "text" FROM "items" ORDER BY "id"')).map((r) => r['text']).toList(), [for (int i = 1; i <= 5; i++) 'row $i'], reason: 'G27: a read-only start changed nothing');
      expect((await raw.rawQuery('PRAGMA table_info("items")')).map((r) => r['name']), isNot(contains('added')), reason: 'no migration ran on a read-only file');
      await expectIntegrity(raw);
      await raw.close();
    });

    test('G27: a read-only database that does not exist is refused typed and nothing is created', () async {
      Object? refused;
      try {
        await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [ProbeProvider(goodProbe)], readOnly: true)]);
      } catch (e) {
        refused = e;
      }
      expect(refused, isNotNull);
      expectTypedError(refused!);
      expect(await databaseFactoryFfi.databaseExists('${await getDatabasesPath()}/${db.name}.db'), isFalse);
      FluentDbInternals.reset();
    });

    test('G27: inMemory + readOnly + read pool + wal start with a warning, not an error', () async {
      final ProbeProvider p = ProbeProvider(goodProbe);
      FluentDbInternals.reset();
      await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [p], inMemory: true, readOnly: true, config: const FluentDbConfig(readConnections: 3))]);
      await p.save(ProbeModel(goodProbe, {'text': 'mem'}));
      expect(await p.count(), 1);
      await expectIntegrity(p.db);
      await FluentDb.close();
      FluentDbInternals.reset();
    });

    for (final int seed in fuzzSeeds(base: 90000)) {
      test('G27: random settings between restarts and configure() never lose a row (seed $seed)', () async {
        final Set<int> live = {};
        final Set<int> trash = {};
        await db.open([notes]);
        Duration? dur(FluentFuzz f) => f.pick<Duration?>(const [null, Duration.zero, Duration(seconds: -3), Duration(milliseconds: 1), Duration(days: 1), Duration(days: 365000)]);
        FluentConfig globalOf(FluentFuzz f) => FluentConfig(
          transactionWatchdog: dur(f),
          pauseWatchdog: dur(f),
          trashPurgeInterval: dur(f),
          optimizeInterval: dur(f),
          sliceAfterRows: f.pick(const [-1, 0, 1, 300, 1 << 40]),
          frameBudget: f.pick(const [Duration.zero, Duration(milliseconds: -4), Duration(milliseconds: 4), Duration(days: 9)]),
          // Zero would purge the trash on purpose (documented), so the reference stays simple without it.
          trashRetention: f.pick(const [Duration(days: -1), Duration(days: 7), Duration(days: 365000000)]),
          readConnections: f.pick(const [null, -2, 0, 1, 4, 50]),
          isolateMapping: f.pick(FluentIsolateMapping.values),
          indexReferences: f.chance(0.5),
          autoRelations: f.chance(0.5),
        );
        FluentDbConfig groupOf(FluentFuzz f) => FluentDbConfig(
          enableForeignKeys: f.chance(0.8),
          journalMode: f.pick(const [SQLiteJournalMode.wal, SQLiteJournalMode.delete, SQLiteJournalMode.truncate, SQLiteJournalMode.memory, SQLiteJournalMode.persist]),
          synchronous: f.pick(SQLiteSynchronous.values),
          cacheSize: f.pick([SQLiteCacheSize.pages(0), SQLiteCacheSize.kiloBytes(1), SQLiteCacheSize.megaBytes(1 << 30), SQLiteCacheSize.defaultSize]),
          busyTimeout: f.pick(const [null, Duration.zero, Duration(seconds: -1), Duration(seconds: 5), Duration(days: 99999)]),
          readConnections: f.pick(const [null, -1, 0, 2, 9]),
          trashRetention: f.pick(const [null, Duration(days: -3), Duration(days: 30)]),
          diagnostics: f.pick(const [null, FluentDiagnostics.none, FluentDiagnostics.quiet, FluentDiagnostics.recommend, FluentDiagnostics.auto]),
          tempStoreInMemory: f.chance(0.5),
        );
        int next = 0;
        await runSequence(
          seed: seed,
          steps: 8,
          next: (FluentFuzz f, int step) => f.weighted<FuzzOp>({
            FuzzOp('save', () async {
              final String text = 'n${++next}';
              await notes.save(Note(text: text));
              live.add((await notes.findAll()).firstWhere((x) => x.text == text).id!);
            }): 4,
            FuzzOp('delete one', () async {
              if (live.isEmpty) return;
              final int id = f.pick(live.toList());
              await notes.deleteById(id);
              live.remove(id);
              trash.add(id);
            }): 2,
            _restartOp(f, globalOf(f), groupOf(f), dur(f), f.pick(const [-5, 0, 1, 100]), () => db, notes): 3,
            _configureOp(globalOf(f)): 2,
            FuzzOp('purge trash with the configured retention', () async {
              await notes.purgeTrash();
            }): 1,
          }),
          check: (int step) async {
            await db.settle();
            expect((await notes.findAll()).map((n) => n.id).toSet(), live, reason: 'G21/G27: live rows');
            expect((await notes.trash.find()).map((n) => n.id).toSet(), trash, reason: 'G21/G27: trashed rows (only an explicit purge may remove them)');
          },
        );
        await expectIntegrity(notes.db);
        expectIssuesHaveFixes(db.issues);
      });
    }
  });

  group('G28: wrong models', () {
    for (final BadModel bad in badModels) {
      test('G28: ${bad.name}', () async {
        final ProbeProvider good = ProbeProvider(goodProbe);
        await db.open([good]);
        await good.saveAll([for (int i = 1; i <= 5; i++) ProbeModel(goodProbe, {'id': i, 'text': 'row $i'})]);
        await db.settle();

        Object? refused;
        try {
          await db.restart(bad.declare());
          await db.settle();
        } catch (e) {
          refused = e;
        }
        final List<FluentIssue> issues = db.issues;
        if (refused != null) {
          expectTypedError(refused, reason: 'refused ${bad.name}');
        } else if (bad.mustReport) {
          expect(issues.where((i) => i.type != FluentIssueType.hint), isNotEmpty, reason: 'G28: ${bad.name} was accepted without a warning');
        }
        expectIssuesHaveFixes(issues);

        // A bad model that was accepted: its calls complete with a value or a typed error (G12, G13), never raw errors.
        if (refused == null) {
          final ProbeProvider first = FluentDbInternals.providersOf(db.name).whereType<ProbeProvider>().first;
          await waitAllSettled([
            first.save(ProbeModel(first.probe, {'text': 'x'})),
            first.findAll(),
            first.count(),
            first.findAll(),
          ], names: ['save', 'findAll', 'count', 'findAll again']);
          expectIssuesHaveFixes(db.issues);
        }

        // Back to the good model: every row is back, the file is intact, the library works.
        final ProbeProvider again = ProbeProvider(goodProbe);
        await db.restart([again]);
        await db.settle();
        // The model of the bad start may have dropped a column: its values are then archived, never gone (G4 / G21).
        final List<Map<String, Object?>> raw = await again.db.rawQuery('SELECT * FROM "items" ORDER BY "id"');
        expect(raw.map((r) => r['id']).where((id) => (id! as int) <= 5).toList(), [1, 2, 3, 4, 5], reason: 'G28: rows survive the bad model "${bad.name}"');
        for (final Map<String, Object?> r in raw.where((r) => (r['id']! as int) <= 5)) {
          expect(r.values.contains('row ${r['id']}'), isTrue, reason: 'G28: the text of row ${r['id']} is kept (in its column or an archive) after "${bad.name}"');
        }
        await expectIntegrity(again.db);
        await again.save(ProbeModel(goodProbe, {'text': 'later'}));
        expect(await again.count(), greaterThanOrEqualTo(6));
      });
    }
  });
}
