// Regression tests of the mapping audit (MAP-1 ... MAP-9).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/relation_models.dart';

enum _Mood { on, off }

class _Item extends FluentStorable {
  _Item({this.id, required this.title});

  int? id;
  String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class _ItemProvider extends FluentProvider<_Item> {
  @override
  String get tableName => 'items';

  @override
  _Item get modelSample => _Item(title: '');

  @override
  _Item fromCacheJson(Map<String, dynamic> json) => _Item(id: json['id'] as int?, title: json['title'] as String);
}

class _Pattern extends FluentStorable {
  _Pattern({this.id, required this.regex});

  int? id;
  RegExp regex;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(isolateMapping: FluentIsolateMapping.always);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'regex': regex};
}

_Pattern _patternFromJson(Map<String, dynamic> json) => _Pattern(id: json['id'] as int?, regex: json['regex'] as RegExp);

class _PatternProvider extends FluentProvider<_Pattern> {
  @override
  String get tableName => 'patterns';

  @override
  _Pattern get modelSample => _Pattern(regex: RegExp('x'));

  @override
  _Pattern fromCacheJson(Map<String, dynamic> json) => _patternFromJson(json);

  @override
  _Pattern Function(Map<String, dynamic> json)? get isolateFactory => _patternFromJson;
}

class _Task extends FluentStorable {
  _Task({this.id, this.mood});

  int? id;
  _Mood? mood;

  @override
  Map<String, List<Enum>> get enumValues => {'mood': _Mood.values};

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'mood': mood};
}

class _TaskProvider extends FluentProvider<_Task> {
  @override
  String get tableName => 'tasks';

  @override
  _Task get modelSample => _Task(mood: _Mood.on);

  @override
  _Task fromCacheJson(Map<String, dynamic> json) => _Task(id: json['id'] as int?, mood: json['mood'] as _Mood?);
}

class _RequiredTask extends _Task {
  _RequiredTask({super.id, super.mood});

  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.text('mood', isNotNull: true).copyWith(valueKind: FluentValueKind.enumValue)];
}

class _RequiredTaskProvider extends FluentProvider<_RequiredTask> {
  @override
  String get tableName => 'req_tasks';

  @override
  _RequiredTask get modelSample => _RequiredTask(mood: _Mood.on);

  @override
  _RequiredTask fromCacheJson(Map<String, dynamic> json) => _RequiredTask(id: json['id'] as int?, mood: json['mood'] as _Mood?);
}

class _Reading extends FluentStorable {
  _Reading({this.id, this.value, this.at});

  int? id;
  double? value;
  DateTime? at;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'value': value, 'at': at};
}

class _ReadingProvider extends FluentProvider<_Reading> {
  @override
  String get tableName => 'readings';

  @override
  _Reading get modelSample => _Reading(value: 1, at: DateTime(2000));

  @override
  _Reading fromCacheJson(Map<String, dynamic> json) => _Reading(id: json['id'] as int?, value: json['value'] as double?, at: json['at'] as DateTime?);
}

/// A model that never carries its key in buildJson (the generated key lives in metadata).
class _Keyless extends FluentStorable {
  _Keyless({required this.title});

  String title;

  @override
  Map<String, dynamic> buildJson() => {'title': title};
}

class _KeylessProvider extends FluentProvider<_Keyless> {
  @override
  String get tableName => 'keyless';

  @override
  _Keyless get modelSample => _Keyless(title: '');

  @override
  _Keyless fromCacheJson(Map<String, dynamic> json) => _Keyless(title: json['title'] as String);
}

class _RecordingTagProvider extends TagProvider {
  final List<Map<String, dynamic>> seen = [];

  @override
  Tag fromCacheJson(Map<String, dynamic> json) {
    seen.add(Map<String, dynamic>.of(json));
    return super.fromCacheJson(json);
  }
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'map_fix_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  test('MAP-1 buildJson wins over the injected key', () async {
    final items = _ItemProvider();
    await db.open([items]);

    final item = _Item(title: 'a');
    await items.save(item);
    expect(item.primaryKeyValue, 1);
    item.id = 7;
    expect(item.primaryKeyValue, 7);
    expect(item.key['id'], 7);
    await items.save(item);
    expect(await items.findById(7), isNotNull);
    expect(await items.count(), 2);
  });

  test('MAP-1 the injected key fills a key buildJson never carries', () async {
    final keyless = _KeylessProvider();
    await db.open([keyless]);
    final k = _Keyless(title: 'one');
    await keyless.save(k);
    k.title = 'two';
    await keyless.save(k);
    expect(await keyless.count(), 1);
    expect((await keyless.findAll()).single.title, 'two');
  });

  test('MAP-2 RegExp flags round trip; a row holding only the pattern still reads', () async {
    final patterns = _PatternProvider();
    await db.open([patterns]);

    await patterns.save(_Pattern(regex: RegExp('a+', caseSensitive: false, multiLine: true, unicode: true, dotAll: true)));
    await patterns.save(_Pattern(regex: RegExp('plain')));
    final List<_Pattern> all = await patterns.findAll();
    final RegExp flagged = all[0].regex;
    expect(flagged.pattern, 'a+');
    expect([flagged.isCaseSensitive, flagged.isMultiLine, flagged.isUnicode, flagged.isDotAll], [false, true, true, true]);
    expect(all[1].regex.pattern, 'plain');
    expect(all[1].regex.isCaseSensitive, isTrue);

    final Database sql = patterns.db;
    await sql.update('patterns', {'regex': 'old+', '_fs_metadata': '{"regex":"regexp"}'}, where: 'id = ?', whereArgs: [2]);
    expect((await patterns.findById(2))!.regex.pattern, 'old+');
  });

  test('MAP-3 bad stored data fails with a FluentSchemaException naming table and column (also in a background isolate)', () async {
    final patterns = _PatternProvider();
    await db.open([patterns]);
    await patterns.save(_Pattern(regex: RegExp('ok')));
    final Database sql = patterns.db;
    await sql.update('patterns', {'regex': '(', '_fs_metadata': '{"regex":"regexp"}'});

    final List<FluentIssue> issues = [];
    await FluentLog.captureIssues(issues, () async {
      for (int i = 0; i < 2; i++) {
        await expectLater(
          patterns.findAll(),
          throwsA(
            isA<FluentSchemaException>()
                .having((e) => e.columnName, 'column', 'regex')
                .having((e) => e.message, 'message', contains('patterns.regex'))
                .having((e) => e.hint, 'hint', isNotNull),
          ),
        );
      }
    });
    expect(issues.where((i) => i.kind == FluentIssueKind.isolateFallback), isEmpty, reason: 'a data error must not switch isolate mapping off');

    await sql.update('patterns', {'regex': 'not json', '_fs_metadata': '{"regex":"regexp_flags"}'});
    await expectLater(patterns.findAll(), throwsA(isA<FluentSchemaException>()));
  });

  test('MAP-4 an unknown enum value reads as null (nullable column)', () async {
    final tasks = _TaskProvider();
    await db.open([tasks]);
    await tasks.save(_Task(mood: _Mood.on));
    await tasks.save(_Task(mood: _Mood.off));
    final Database sql = tasks.db;
    await sql.update('tasks', {'mood': 'gone'}, where: 'mood = ?', whereArgs: ['off']);

    final List<FluentIssue> issues = [];
    await FluentLog.captureIssues(issues, () async {
      expect((await tasks.findAll()).map((t) => t.mood), [_Mood.on, null]);
    });
    final warning = issues.where((i) => i.kind == FluentIssueKind.mappingValue).single;
    expect(warning.fix, contains('UPDATE'));
  });

  test('MAP-4 an unknown enum value in a NOT NULL column is a typed error naming value and column', () async {
    final required = _RequiredTaskProvider();
    await db.open([required]);
    await required.save(_RequiredTask(mood: _Mood.on));
    await required.db.execute("UPDATE req_tasks SET mood = 'gone'");

    await expectLater(
      required.findAll(),
      throwsA(
        isA<FluentSchemaException>()
            .having((e) => e.message, 'message', allOf(contains('gone'), contains('req_tasks.mood')))
            .having((e) => e.columnName, 'column', 'mood')
            .having((e) => e.hint, 'hint', isNotNull),
      ),
    );
  });

  test('MAP-5 microseconds are cut to milliseconds in timestamp mode (documented)', () async {
    final readings = _ReadingProvider();
    await db.open([readings]);
    final DateTime at = DateTime.utc(2024, 1, 2, 3, 4, 5, 6, 789);
    await readings.save(_Reading(value: 1, at: at));
    final DateTime back = (await readings.findAll()).single.at!;
    expect(back.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    expect(back.microsecond, 0);
  });

  test('MAP-6 NaN is refused with unsupportedValue; infinity round-trips', () async {
    final readings = _ReadingProvider();
    await db.open([readings]);

    await expectLater(
      readings.save(_Reading(value: double.nan, at: DateTime(2000))),
      throwsA(isA<FluentArgumentException>().having((e) => e.code, 'code', FluentErrorCode.unsupportedValue).having((e) => e.hint, 'hint', isNotNull)),
    );
    await readings.save(_Reading(value: double.infinity, at: DateTime(2000)));
    await readings.save(_Reading(value: double.negativeInfinity, at: DateTime(2000)));
    expect((await readings.findAll()).map((r) => r.value), [double.infinity, double.negativeInfinity]);
  });

  test('MAP-8 _unloaded_relations never reaches fromCacheJson but the model still knows its unloaded relations', () async {
    final tags = _RecordingTagProvider();
    await db.open([...relationProviders().where((p) => p is! TagProvider), tags]);
    await tags.save(Tag(label: 'x'));

    final Tag lazy = (await tags.findAll()).single;
    final Tag bare = (await tags.findAll(relations: FluentLoad.none)).single;

    expect(tags.seen, isNotEmpty);
    expect(tags.seen.any((json) => json.containsKey('_unloaded_relations')), isFalse);
    expect(lazy.isRelationLoaded('articles'), isFalse);
    expect(bare.isRelationLoaded('articles'), isFalse);
  });

  test('MAP-9 toSnakeCase: 2.0 rule (1.x names are adopted at start, see round3/legacy_names_test)', () {
    expect(FluentUtils.toSnakeCase('UserName'), 'user_name');
    expect(FluentUtils.toSnakeCase('userName'), 'user_name');
    expect(FluentUtils.toSnakeCase('Item2'), 'item2');
    expect(FluentUtils.toSnakeCase('HTTPServer'), 'http_server');
    expect(FluentUtils.toSnakeCase('Box<Note>'), 'box_note');
    expect(FluentUtils.toSnakeCase('user_name'), 'user_name');
  });
}
