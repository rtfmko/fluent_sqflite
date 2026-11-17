// Edge cases of the row mapping: damaged and stale type metadata, converter columns with tags, isolate mapping
// settings and the hint to add an isolateFactory.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

class _Upper extends FluentConverter<String, String> {
  const _Upper();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.text;

  @override
  String toSql(String value) => value.toUpperCase();

  @override
  String fromSql(String value) => value.toLowerCase();
}

class Reading extends FluentStorable {
  Reading({this.id, required this.label, required this.value, required this.at});

  final int? id;
  final String label;
  final double value;
  final DateTime at;

  static Reading fromJson(Map<String, dynamic> json) => Reading(id: json['id'] as int?, label: json['label'] as String, value: (json['value'] as num).toDouble(), at: json['at'] as DateTime);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label, 'value': value, 'at': at};
}

class ReadingProvider extends FluentProvider<Reading> {
  ReadingProvider({this.withFactory = true});

  final bool withFactory;

  @override
  String get tableName => 'readings';

  @override
  Reading get modelSample => Reading(label: '', value: 0, at: DateTime(2000));

  @override
  Reading fromCacheJson(Map<String, dynamic> json) => Reading.fromJson(json);

  @override
  Reading Function(Map<String, dynamic> json)? get isolateFactory => withFactory ? Reading.fromJson : null;
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'medges_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  Iterable<FluentIssue> issuesOf(FluentIssueKind kind) => db.issues.where((FluentIssue i) => i.kind == kind);

  group('type metadata', () {
    DynamicProvider table() => DynamicProvider('m', () => [FluentDbColumn.integer('id'), FluentDbColumn.boolean('flag'), FluentDbColumn.timestamp('at'), FluentDbColumn.converted<String, String>('word', const _Upper())]);

    test('damaged metadata falls back to the column kinds and reports one mappingValue issue with a hint', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'flag': true, 'at': DateTime.utc(2030), 'word': 'hello'}));
      await p.db.rawUpdate("UPDATE m SET _fs_metadata = '{not json'");
      final DynamicModel m = (await p.findById(1))!;
      expect(m['flag'], true, reason: 'the column kind restores the bool');
      expect((m['at'] as DateTime).isAtSameMomentAs(DateTime.utc(2030)), isTrue, reason: 'same instant; the UTC flag lived only in the damaged metadata and no intact row showed it');
      expect(m['word'], 'hello');
      final FluentIssue issue = issuesOf(FluentIssueKind.mappingValue).single;
      expect(issue.title, contains('Corrupted type metadata in "m"'));
      expect(issue.fix, contains('Re-save'));
    });

    test('damaged metadata keeps the UTC flag: readable tags and the tags of intact rows are used (known bug 1)', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.saveAll([
        p.row({'id': 1, 'flag': true, 'at': DateTime.utc(2030), 'word': 'a'}),
        p.row({'id': 2, 'flag': true, 'at': DateTime.utc(2031), 'word': 'b'}),
        p.row({'id': 3, 'flag': true, 'at': DateTime.utc(2032), 'word': 'c'}),
      ]);
      // Cut off in the middle: the pair before the cut is still readable.
      await p.db.rawUpdate('''UPDATE m SET _fs_metadata = '{"at":"datetime_utc","fl' WHERE id = 2''');
      // Unreadable: the tag comes from the intact row read before it.
      await p.db.rawUpdate("UPDATE m SET _fs_metadata = '{not json' WHERE id = 3");
      final DynamicModel cut = (await p.findById(2))!;
      expect((cut['at'] as DateTime).isUtc, isTrue);
      expect(cut['at'], DateTime.utc(2031));
      expect(cut['flag'], true, reason: 'the column kind still restores the bool');
      final List<DynamicModel> all = await p.find(orderBy: 'id');
      expect(all.map((m) => (m['at'] as DateTime).isUtc), [true, true, true]);
      expect(all.last['at'], DateTime.utc(2032));
      expect(issuesOf(FluentIssueKind.mappingValue), isNotEmpty, reason: 'the damage is still reported');
    });

    test('metadata that is valid JSON but not an object is damaged too', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'flag': false, 'at': DateTime.utc(2030), 'word': 'x'}));
      await p.db.rawUpdate("UPDATE m SET _fs_metadata = '[1,2]'");
      expect((await p.findById(1))!['flag'], false);
      expect(issuesOf(FluentIssueKind.mappingValue), isNotEmpty);
    });

    test('a stale tag on a converter column is ignored: the converter reads the value, other tags still apply', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'flag': true, 'at': DateTime.utc(2030), 'word': 'abc'}));
      await p.db.rawUpdate('''UPDATE m SET _fs_metadata = '{"word":"datetime","flag":"bool"}' ''');
      final DynamicModel m = (await p.findById(1))!;
      expect(m['word'], 'abc', reason: 'decoded by the converter, not as a date');
      expect(m['flag'], true);
      expect(issuesOf(FluentIssueKind.mappingValue), isEmpty);
    });

    test('stored JSON that cannot be decoded reaches the model as raw text with a warning naming the column', () async {
      final DynamicProvider p = DynamicProvider('j', () => [FluentDbColumn.integer('id'), FluentDbColumn(name: 'data', type: FluentDbDataType.text, valueKind: FluentValueKind.json)]);
      await db.open([p]);
      await p.save(p.row({'id': 1, 'data': {'a': 1}}));
      expect((await p.findById(1))!['data'], {'a': 1});
      await p.db.rawUpdate("UPDATE j SET data = '{broken'");
      expect((await p.findById(1))!['data'], '{broken');
      final FluentIssue issue = issuesOf(FluentIssueKind.mappingValue).single;
      expect(issue.title, contains('"j.data"'));
      expect(issue.fix, contains('valid value'));
    });

    test('a patch over damaged metadata still works: the damaged tags are replaced by the patched ones', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.save(p.row({'id': 1, 'flag': true, 'at': DateTime.utc(2030), 'word': 'abc'}));
      await p.db.rawUpdate("UPDATE m SET _fs_metadata = '{not json'");
      final FluentSaveResult r = await p.save(p.row({'id': 1, 'flag': false, 'at': null, 'word': null}), strategy: FluentSaveStrategy.patch);
      expect(r.updated, 1);
      final DynamicModel m = (await p.findById(1))!;
      expect(m['flag'], false);
      expect(m['word'], 'abc', reason: 'null fields are left untouched by a patch');
    });

    test('an empty metadata text and a NULL one use the column kinds', () async {
      final DynamicProvider p = table();
      await db.open([p]);
      await p.db.rawInsert("INSERT INTO m (id, flag, at, word, _fs_metadata) VALUES (1, 1, 1000, 'ABC', '')");
      await p.db.rawInsert('INSERT INTO m (id, flag, at, word) VALUES (2, 0, 2000, NULL)');
      final DynamicModel a = (await p.findById(1))!;
      final DynamicModel b = (await p.findById(2))!;
      expect([a['flag'], a['at'], a['word']], [true, DateTime.fromMillisecondsSinceEpoch(1000), 'abc']);
      expect([b['flag'], b['at'], b['word']], [false, DateTime.fromMillisecondsSinceEpoch(2000), null]);
    });
  });

  group('isolate mapping', () {
    Future<void> fill(ReadingProvider p, int n) => p.saveAll([for (int i = 1; i <= n; i++) Reading(id: i, label: 'r$i', value: i / 4, at: DateTime.utc(2030, 1, 1, 0, 0, i))]);

    test('always without an isolateFactory maps on the UI isolate and suggests the factory once, with code to paste', () async {
      final ReadingProvider p = ReadingProvider(withFactory: false);
      await db.open([p], fluentConfig: const FluentConfig(isolateMapping: FluentIsolateMapping.always));
      await fill(p, 5);
      final List<Reading> found = await p.findAll(orderBy: 'id');
      expect(found.map((Reading r) => r.label), ['r1', 'r2', 'r3', 'r4', 'r5']);
      final FluentIssue issue = issuesOf(FluentIssueKind.isolate).single;
      expect(issue.details, contains('has no isolateFactory'));
      expect(issue.code, contains('get isolateFactory => Reading.fromJson'));
      await p.findAll();
      expect(issuesOf(FluentIssueKind.isolate), hasLength(1), reason: 'a hint is given once per run');
    });

    test('always with a factory, never and smart all return equal models', () async {
      final Map<String, List<Reading>> results = {};
      for (final FluentIsolateMapping mode in FluentIsolateMapping.values) {
        db = FluentTestDb(name: 'miso_${mode.name}_${DateTime.now().microsecondsSinceEpoch}');
        final ReadingProvider p = ReadingProvider();
        await db.open([p], fluentConfig: FluentConfig(isolateMapping: mode));
        await fill(p, 40);
        results[mode.name] = await p.findAll(orderBy: 'id');
        await db.close();
      }
      expect(results.length, FluentIsolateMapping.values.length);
      final List<Reading> base = results.values.first;
      expect(base, hasLength(40));
      for (final List<Reading> other in results.values) {
        expect(other.map((Reading r) => r.buildJson().toString()).toList(), base.map((Reading r) => r.buildJson().toString()).toList());
      }
      expect(base.first.at, DateTime.utc(2030, 1, 1, 0, 0, 1));
      expect(base.first.at.isUtc, isTrue);
      expect(base.last.value, 10.0);
    });

    test('never: nothing to suggest and nothing runs in a background isolate', () async {
      final ReadingProvider p = ReadingProvider(withFactory: false);
      await db.open([p], fluentConfig: const FluentConfig(isolateMapping: FluentIsolateMapping.never));
      await fill(p, 3);
      await p.findAll();
      expect(issuesOf(FluentIssueKind.isolate), isEmpty, reason: 'never: nothing to suggest');
    });
  });
}
