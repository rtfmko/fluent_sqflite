// Edge cases of the provider core: SQL errors mapped to typed exceptions, schema fallbacks, custom column affinities in
// conflictOn matching, update operations, converter failures, keys and aggregates.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/query_counter.dart';
import '../../helpers/relation_models.dart';
import '../../helpers/schema_models.dart';

class _BadConverter extends FluentConverter<int, String> {
  const _BadConverter({this.failOnEncode = false});

  final bool failOnEncode;

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(int value) => failOnEncode ? throw StateError('cannot encode') : 'n$value';

  @override
  int fromSql(String value) => int.parse(value.substring(1)); // fails for text that is not "n<number>"
}

class _ServerKeyed extends FluentStorable {
  _ServerKeyed({this.id, this.code});

  final int? id;
  final String? code;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(serverKey: ['no_such_column']);

  @override
  List<FluentDbColumn> get tableSchema => [FluentDbColumn.integer('id'), FluentDbColumn.text('code')];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'code': code};
}

class _ServerKeyedProvider extends FluentProvider<_ServerKeyed> with FluentSyncable<_ServerKeyed> {
  @override
  String get tableName => 'server_keyed';

  @override
  _ServerKeyed get modelSample => _ServerKeyed();

  @override
  _ServerKeyed fromCacheJson(Map<String, dynamic> json) => _ServerKeyed(id: json['id'] as int?, code: json['code'] as String?);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'pedges_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  Iterable<FluentIssue> issuesOf(FluentIssueKind kind) => db.issues.where((FluentIssue i) => i.kind == kind);

  group('SQL errors become typed exceptions with codes and hints', () {
    test('NOT NULL, CHECK and UNIQUE violations on save', () async {
      final DynamicProvider p = DynamicProvider.spec(
        't',
        TableSpec(
          columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name', isNotNull: true), FluentDbColumn.integer('score'), FluentDbColumn.text('code', isUnique: true)],
          checks: const [FluentCheck('score >= 0')],
        ),
      );
      await db.open([p]);
      await expectLater(
        p.save(p.row({'id': 1, 'name': null, 'score': 1, 'code': 'a'})),
        throwsA(isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.notNullViolation).having((e) => e.hint, 'hint', contains('defaultValue'))),
      );
      await expectLater(
        p.save(p.row({'id': 1, 'name': 'x', 'score': -5, 'code': 'a'})),
        throwsA(isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.checkViolation).having((e) => e.hint, 'hint', contains('checks'))),
      );
      await p.save(p.row({'id': 1, 'name': 'x', 'score': 5, 'code': 'a'}));
      await expectLater(
        p.save(p.row({'id': 2, 'name': 'y', 'score': 5, 'code': 'a'})),
        throwsA(isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.uniqueViolation)),
      );
      expect(await p.count(), 1, reason: 'failed saves leave nothing behind');
    });

    test('a table that does not exist: the raw SQL names it, the hint says where to look', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id')]);
      await db.open([p]);
      await expectLater(
        p.execute('INSERT INTO "not_there" VALUES (1)'),
        throwsA(isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.noSuchTable).having((e) => e.hint, 'hint', contains('Check the table name'))),
      );
      await expectLater(p.rawQuery('SELECT * FROM "not_there"'), throwsA(isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.noSuchTable)));
    });

    test('a write on a read-only database reports readOnly', () async {
      db = FluentTestDb(name: 'ro_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final DynamicProvider writer = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      await db.open([writer]);
      await writer.save(writer.row({'id': 1, 'name': 'a'}));
      await db.close(keepFile: true);
      FluentDbInternals.reset();
      final DynamicProvider reader = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      try {
        await FluentDb.init([FluentGroup(dbKey: db.key, providerList: [reader], readOnly: true)]);
        expect(await reader.count(), 1);
        await expectLater(reader.save(reader.row({'id': 2, 'name': 'b'})), throwsA(isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.readOnly)));
        await expectLater(reader.execute('DELETE FROM t'), throwsA(isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.readOnly)));
      } finally {
        await FluentDb.close();
        FluentDbInternals.reset();
      }
    });

    test('rawQuery refuses statements that write, before anything runs', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id')]);
      await db.open([p]);
      await p.save(p.row({'id': 1}));
      await expectLater(p.rawQuery('DELETE FROM t'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('execute()'))));
      await expectLater(p.rawQuery('DROP TABLE t'), throwsA(isA<FluentArgumentException>()));
      expect(await p.count(), 1);
    });
  });

  group('schema fallbacks are reported, never thrown', () {
    test('WITHOUT ROWID with an AUTOINCREMENT key is ignored', () async {
      final DynamicProvider p = DynamicProvider.spec('t', TableSpec(columns: () => [FluentDbColumn.primary(), FluentDbColumn.text('name')], withoutRowId: true));
      await db.open([p]);
      expect(issuesOf(FluentIssueKind.schemaFallback).map((i) => i.title), contains(contains('WITHOUT ROWID ignored')));
      await p.save(p.row({'name': 'works'}));
      expect((await p.findAll()).single['name'], 'works');
    });

    test('a key column listed twice and AUTOINCREMENT on a composite key are ignored', () async {
      final DynamicProvider dup = DynamicProvider.spec(
        'dup',
        TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')], keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('a'), FluentDbColumn.integer('b')]),
      );
      final DynamicProvider auto = DynamicProvider.spec(
        'auto',
        TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')], keys: () => [FluentDbColumn.primary(name: 'a'), FluentDbColumn.integer('b')]),
      );
      await db.open([dup, auto]);
      final List<String> titles = issuesOf(FluentIssueKind.schemaFallback).map((FluentIssue i) => i.title).toList();
      expect(titles, contains(contains('Duplicate primary key column "a"')));
      expect(titles, contains(contains('AUTOINCREMENT on composite key column "a"')));
      expect(dup.primaryKeyColumns.map((FluentDbColumn c) => c.name), ['a', 'b']);
      await dup.save(dup.row({'a': 1, 'b': 2}));
      expect(await dup.count(), 1);
      await auto.save(auto.row({'a': 1, 'b': 2}));
      await auto.save(auto.row({'a': 1, 'b': 3}));
      expect(await auto.count(), 2);
    });

    test('a default value that does not fit the column type is reported with a hint', () async {
      final DynamicProvider p = DynamicProvider(
        't',
        () => [FluentDbColumn.integer('id'), FluentDbColumn(name: 'n', type: FluentDbDataType.integer, defaultValue: 'abc'), FluentDbColumn(name: 'r', type: FluentDbDataType.real, defaultValue: 'x')],
      );
      await db.open([p]);
      final List<FluentIssue> found = issuesOf(FluentIssueKind.schemaFallback).toList();
      expect(found.map((FluentIssue i) => i.title), containsAll([contains('"t.n"'), contains('"t.r"')]));
      expect(found.firstWhere((FluentIssue i) => i.title.contains('t.n')).fix, contains('int or bool'));
      expect(found.firstWhere((FluentIssue i) => i.title.contains('t.r')).fix, contains('number'));
    });

    test('a default that fits (numeric text, bool, DateTime, expression) raises no issue', () async {
      final DynamicProvider p = DynamicProvider(
        't',
        () => [
          FluentDbColumn.integer('id'),
          FluentDbColumn(name: 'a', type: FluentDbDataType.integer, defaultValue: '7'),
          FluentDbColumn(name: 'b', type: FluentDbDataType.integer, defaultValue: true),
          FluentDbColumn(name: 'c', type: FluentDbDataType.real, defaultValue: '1.5'),
          FluentDbColumn(name: 'd', type: FluentDbDataType.real, defaultValue: 2),
        ],
      );
      await db.open([p]);
      expect(issuesOf(FluentIssueKind.schemaFallback), isEmpty);
    });

    test('a unique index over duplicate rows is skipped with a hint; the table keeps working', () async {
      db = FluentTestDb(name: 'dupidx_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      final DynamicProvider v1 = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('code')]);
      await db.open([v1]);
      await v1.saveAll([v1.row({'id': 1, 'code': 'x'}), v1.row({'id': 2, 'code': 'x'})]);
      final DynamicProvider v2 = DynamicProvider.spec('t', TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('code')], indexes: const [FluentIndex.unique(['code'])]));
      await db.restart([v2]);
      final FluentIssue issue = issuesOf(FluentIssueKind.indexSkipped).single;
      expect(issue.fix, contains('duplicate values in (code)'));
      expect(await v2.count(), 2);
    });

    test('a serverKey naming an unknown column falls back to the primary key with a hint', () async {
      final _ServerKeyedProvider p = _ServerKeyedProvider();
      await db.open([p]);
      await p.save(_ServerKeyed(id: 1, code: 'a'));
      final FluentSyncResult<_ServerKeyed> result = await p.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => FluentPullResult(items: [_ServerKeyed(id: 1, code: 'server')]));
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      final FluentIssue issue = issuesOf(FluentIssueKind.serverKeyIgnored).single;
      expect(issue.title, contains('no_such_column'));
      expect(issue.fix, contains('serverKey'));
      await p.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult(items: []));
      expect(issuesOf(FluentIssueKind.serverKeyIgnored), hasLength(1), reason: 'reported once per run');
    });
  });

  group('custom column affinities decide how conflictOn matches values', () {
    DynamicProvider custom(String sqlType) => DynamicProvider(
      't',
      () => [FluentDbColumn.integer('id'), FluentDbColumn(name: 'k', type: FluentDbDataType.custom, customSql: sqlType)],
    );

    test('REAL columns have REAL affinity: 1.5 and "1.5" are the same value', () async {
      for (final String t in ['REAL', 'REAL NOT NULL']) {
        final DynamicProvider p = custom(t);
        db = FluentTestDb(name: 'aff_${t.hashCode}_${DateTime.now().microsecondsSinceEpoch}');
        await db.open([p]);
        await p.save(p.row({'id': 1, 'k': 1.5}));
        final FluentSaveResult r = await p.save(p.row({'id': 2, 'k': '1.5'}), conflictOn: ['k']);
        expect(r.updated, 1, reason: t);
        expect(await p.count(), 1, reason: t);
        await db.close();
      }
    });

    test('a column without affinity (BLOB or no type word) keeps text as text and compares bytes', () async {
      final DynamicProvider p = custom('BLOB');
      await db.open([p]);
      await p.save(p.row({'id': 1, 'k': <int>[1, 2, 255]}));
      await p.save(p.row({'id': 2, 'k': '12'}));
      FluentSaveResult r = await p.save(p.row({'id': 3, 'k': <int>[1, 2, 255]}), conflictOn: ['k']);
      expect(r.updated, 1);
      expect(await p.count(), 2);
      r = await p.save(p.row({'id': 4, 'k': 12}), conflictOn: ['k']);
      expect(r.inserted, 1, reason: 'the number 12 is not the text "12" in a column without affinity');
      expect(await p.count(), 3);
    });

    test('INTEGER / NUMERIC columns convert numeric text: " 7 " equals 7, blank text equals nothing', () async {
      for (final String t in ['INTEGER', 'NUMERIC']) {
        final DynamicProvider p = custom(t);
        db = FluentTestDb(name: 'affi_${t.hashCode}_${DateTime.now().microsecondsSinceEpoch}');
        await db.open([p]);
        await p.save(p.row({'id': 1, 'k': 7}));
        FluentSaveResult r = await p.save(p.row({'id': 2, 'k': ' 7 '}), conflictOn: ['k']);
        expect(r.updated, 1, reason: t);
        r = await p.save(p.row({'id': 3, 'k': '  '}), conflictOn: ['k']);
        expect(r.inserted, 1, reason: '$t: blank text is text');
        r = await p.save(p.row({'id': 4, 'k': 'abc'}), conflictOn: ['k']);
        expect(r.inserted, 1, reason: '$t: text that is no number stays text');
        r = await p.save(p.row({'id': 5, 'k': 'abc'}), conflictOn: ['k']);
        expect(r.updated, 1, reason: '$t: equal text');
        await db.close();
      }
    });

    test('TEXT-affinity custom types compare numbers as their text', () async {
      for (final String t in ['TEXT', 'TEXT COLLATE NOCASE']) {
        final DynamicProvider p = custom(t);
        db = FluentTestDb(name: 'afft_${t.hashCode}_${DateTime.now().microsecondsSinceEpoch}');
        await db.open([p]);
        await p.save(p.row({'id': 1, 'k': '12'}));
        final FluentSaveResult r = await p.save(p.row({'id': 2, 'k': 12}), conflictOn: ['k']);
        expect(r.updated, 1, reason: t);
        await db.close();
      }
    });
  });

  group('update operations', () {
    test('toggle only works on bool columns and says so otherwise', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.boolean('done')]);
      await db.open([p]);
      await p.save(p.row({'id': 1, 'name': 'a', 'done': false}));
      await expectLater(p.updateById(1, {'name': FluentUpdate.toggle}), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('bool'))));
      expect(await p.updateById(1, {'done': FluentUpdate.toggle}), 1);
      expect((await p.findById(1))!['done'], true);
      expect(await p.updateWhere(FluentFilter.eq('id', 1), {'done': FluentUpdate.toggle}), 1);
      expect((await p.findById(1))!['done'], false);
    });

    test('increment / decrement / now on numbers and timestamps, null and unknown columns', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('n'), FluentDbColumn.timestamp('at')]);
      await db.open([p]);
      db.clock.set(DateTime.utc(2030));
      await p.save(p.row({'id': 1, 'n': 5, 'at': null}));
      await p.updateById(1, {'n': FluentUpdate.increment(3), 'at': FluentUpdate.now});
      expect((await p.findById(1))!['n'], 8);
      expect((await p.findById(1))!['at'], DateTime.utc(2030));
      await p.updateWhere(FluentFilter.gt('n', 0), {'n': FluentUpdate.decrement(10)});
      expect((await p.findById(1))!['n'], -2);
      await expectLater(p.updateById(1, {'nope': 1}), throwsA(isA<FluentArgumentException>()));
      expect(await p.updateById(99, {'n': 1}), 0);
      await expectLater(p.updateById(1, {}), anyOf(completion(0), throwsA(isA<FluentArgumentException>())));
    });
  });

  group('converters', () {
    test('a converter that throws while storing or reading raises a schema exception naming the column', () async {
      final DynamicProvider enc = DynamicProvider('enc', () => [FluentDbColumn.integer('id'), FluentDbColumn.converted<int, String>('v', const _BadConverter(failOnEncode: true))]);
      final DynamicProvider dec = DynamicProvider('dec', () => [FluentDbColumn.integer('id'), FluentDbColumn.converted<int, String>('v', const _BadConverter())]);
      await db.open([enc, dec]);
      await expectLater(
        enc.save(enc.row({'id': 1, 'v': 3})),
        throwsA(isA<FluentSchemaException>().having((e) => e.hint, 'hint', contains('buildJson() must return')).having((e) => e.message, 'message', contains('enc.v'))),
      );
      await dec.save(dec.row({'id': 1, 'v': 3}));
      await dec.db.update('dec', {'v': 'garbage'});
      await expectLater(dec.findById(1), throwsA(isA<FluentSchemaException>().having((e) => e.hint, 'hint', contains('migrate it')).having((e) => e.cause, 'cause', isA<FormatException>())));
    });
  });

  group('filter values and converters', () {
    test('a filter value the converter cannot encode is an argument error naming the column, not a silent mismatch', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.converted<int, String>('v', const _BadConverter(failOnEncode: true))]);
      await db.open([p]);
      await expectLater(
        p.find(where: FluentFilter.eq('v', 3)),
        throwsA(isA<FluentArgumentException>().having((e) => e.message, 'message', contains('t.v')).having((e) => e.hint, 'hint', contains('stored form')).having((e) => e.cause, 'cause', isA<StateError>())),
      );
      expect(await p.find(where: FluentFilter.eq('v', 'n3')), isEmpty, reason: 'the stored form passes through');
    });
  });

  group('keys', () {
    test('findById / findByIds take Maps and FluentKeys for composite keys; a null part matches nothing', () async {
      final DynamicProvider p = DynamicProvider.spec('c', TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b'), FluentDbColumn.text('v')], keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')]));
      await db.open([p]);
      await p.saveAll([p.row({'a': 1, 'b': 1, 'v': 'x'}), p.row({'a': 1, 'b': 2, 'v': 'y'})]);
      expect((await p.findById({'a': 1, 'b': 2}))!['v'], 'y');
      expect((await p.findById(FluentKey({'a': 1, 'b': 1})))!['v'], 'x');
      expect(await p.findByIds([
        {'a': 1, 'b': 1},
        {'a': 1, 'b': 2},
      ]), hasLength(2));
      expect(await p.findByIds([
        {'a': 1, 'b': null},
      ]), isEmpty);
      await expectLater(p.findById(1), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotEmpty)));
      await expectLater(p.findById({'a': 1}), throwsA(isA<FluentArgumentException>()));
    });

    test('primaryKeyColumn of a composite table is reported with a hint, primaryKeyColumns lists the key', () async {
      final DynamicProvider p = DynamicProvider.spec('c', TableSpec(columns: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')], keys: () => [FluentDbColumn.integer('a'), FluentDbColumn.integer('b')]));
      await db.open([p]);
      expect(p.hasCompositeKey, isTrue);
      expect(p.primaryKeyColumns.map((FluentDbColumn c) => c.name), ['a', 'b']);
      expect(p.primaryKeyColumn.name, 'a', reason: 'the first key column');
    });

    test('relatedProvider resolves a registered model and fails typed for an unknown one', () async {
      final PersonProvider people = PersonProvider();
      final ProfileProvider profiles = ProfileProvider();
      await db.open([people, profiles]);
      expect(people.relatedProvider(Profile), same(profiles));
      expect(() => people.relatedProvider(Comment), throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound)));
    });
  });

  group('aggregates', () {
    test('min / max with a Dart type that does not match the column say which type to use', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name'), FluentDbColumn.integer('n')]);
      await db.open([p]);
      await p.saveAll([p.row({'id': 1, 'name': 'a', 'n': 3}), p.row({'id': 2, 'name': 'b', 'n': 9})]);
      expect(await p.min<int>('n'), 3);
      expect(await p.max<String>('name'), 'b');
      await expectLater(p.max<int>('name'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('max<String>'))));
      expect(await p.max<int>('n', where: FluentFilter.eq('id', 99)), isNull);
    });

    test('aggregate without a column: only count works, the others say which column to pass', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('n')]);
      await db.open([p]);
      await p.saveAll([p.row({'id': 1, 'n': 3}), p.row({'id': 2, 'n': 9})]);
      expect(await p.aggregate(values: {'c': const FluentAggregate.count()}), [
        {'c': 2},
      ]);
      expect(await p.aggregate(values: {'s': const FluentAggregate.sum('n'), 'a': const FluentAggregate.avg('n')}, having: FluentFilter.gt('s', 5)), [
        {'s': 12, 'a': 6.0},
      ]);
      await expectLater(p.aggregate(values: {'s': const FluentAggregate.sum('missing')}), throwsA(isA<FluentArgumentException>()));
    });

    test('aggregate refuses no values, deferred conditions in having, name clashes and bad limits, each with a hint', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.integer('n')]);
      await db.open([p]);
      await expectLater(p.aggregate(values: {}), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('at least one value'))));
      await expectLater(
        p.aggregate(values: {'c': const FluentAggregate.count()}, having: FluentFilter.ids([1])),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('Move the condition to where'))),
      );
      await expectLater(p.aggregate(values: {'n': const FluentAggregate.count()}, groupBy: ['n']), throwsA(isA<FluentArgumentException>()));
      await expectLater(p.aggregate(values: {'': const FluentAggregate.count()}), throwsA(isA<FluentArgumentException>()));
      await expectLater(p.aggregate(values: {'c': const FluentAggregate.count()}, limit: -1), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('limit: 0 or more'))));
      expect(await p.aggregate(values: {'c': const FluentAggregate.count()}, limit: 0), isEmpty);
      await expectLater(p.aggregate(values: {'c': const FluentAggregate.count()}, groupBy: ['nope']), throwsA(isA<FluentArgumentException>()));
    });
  });

  group('schema: key and index fallbacks', () {
    test('a model that declares no key columns gets the default id key, with a hint', () async {
      final DynamicProvider p = DynamicProvider.spec('t', TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')], keys: () => []));
      await db.open([p]);
      expect(issuesOf(FluentIssueKind.schemaFallback).map((FluentIssue i) => i.title), contains(contains('declares no primary key columns')));
      expect(p.primaryKeyColumns.map((FluentDbColumn c) => c.name), ['id']);
      await p.save(p.row({'name': 'a'}));
      expect(await p.count(), 1);
    });

    test('a plain index that cannot be created is skipped with the generic hint', () async {
      final DynamicProvider p = DynamicProvider.spec(
        't',
        TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')], indexes: const [FluentIndex(['name'], where: 'no_such_column > 1')]),
      );
      await db.open([p]);
      final FluentIssue issue = issuesOf(FluentIssueKind.indexSkipped).single;
      expect(issue.fix, contains('index columns and the "where" condition'));
      await p.save(p.row({'id': 1, 'name': 'a'}));
      expect(await p.count(), 1);
    });
  });

  group('VACUUM and fetch state', () {
    test('VACUUM rebuilds the full-text index of a table whose rowids can change', () async {
      final QueryCounter counter = await QueryCounter.install();
      try {
        final DynamicProvider p = DynamicProvider.spec(
          'notes',
          TableSpec(
            columns: () => [FluentDbColumn.text('slug'), FluentDbColumn.text('title')],
            key: () => FluentDbColumn(name: 'slug', type: FluentDbDataType.text, isPrimaryKey: true),
            indexes: const [FluentIndex.fullText(['title'])],
          ),
        );
        await db.open([p]);
        await p.saveAll([for (final String w in ['apple', 'banana', 'cherry']) p.row({'slug': w, 'title': '$w tart'})]);
        await p.deleteWhere(FluentFilter.eq('slug', 'apple'));
        counter.reset();
        await p.execute('VACUUM');
        expect(counter.statements.where((String s) => s.contains("'rebuild'")), hasLength(1), reason: 'one rebuild for the one full-text table');
        expect([for (final DynamicModel m in await p.search('tart', orderBy: 'slug')) m['slug']], ['banana', 'cherry']);
        expect(await p.search('apple'), isEmpty);
      } finally {
        counter.uninstall();
      }
    });

    test('VACUUM leaves tables alone whose key is the rowid', () async {
      final QueryCounter counter = await QueryCounter.install();
      try {
        final DynamicProvider p = DynamicProvider.spec('notes', TableSpec(columns: () => [FluentDbColumn.integer('id'), FluentDbColumn.text('title')], indexes: const [FluentIndex.fullText(['title'])]));
        await db.open([p]);
        await p.save(p.row({'id': 1, 'title': 'apple'}));
        counter.reset();
        await p.execute('VACUUM');
        expect(counter.statements.where((String s) => s.contains("'rebuild'")), isEmpty);
        expect(await p.search('apple'), hasLength(1));
      } finally {
        counter.uninstall();
      }
    });

    test('clearTable makes watchRemote fetch again even inside maxAge', () async {
      final DynamicProvider p = DynamicProvider('t', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      await db.open([p]);
      int fetches = 0;
      Future<void> load() => p
          .watchRemote(
            fetch: () async {
              fetches++;
              return FluentRemoteResponse([p.row({'id': 1, 'name': 'server'})]);
            },
            maxAge: const Duration(hours: 1),
            keepWatching: false,
          )
          .last;
      await load();
      expect(fetches, 1);
      await load();
      expect(fetches, 1, reason: 'the cache is fresh');
      await p.clearTable();
      await load();
      expect(fetches, 2, reason: 'the table was emptied: the fetch state was forgotten');
      expect(await p.count(), 1);
    });
  });
}
