// Audit tests: row mapping, type conversion and model base classes (MAP-n findings).
import 'dart:ui' show Color, Locale;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

enum _Mood { on, off }

// --- MAP-1: a key changed after the first save ----------------------------------------------------------------------

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

// --- MAP-2 / MAP-3: RegExp ----------------------------------------------------------------------------------------

class _Pattern extends FluentStorable {
  _Pattern({this.id, required this.regex});

  int? id;
  RegExp regex;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'regex': regex};
}

class _PatternProvider extends FluentProvider<_Pattern> {
  @override
  String get tableName => 'patterns';

  @override
  _Pattern get modelSample => _Pattern(regex: RegExp('x'));

  @override
  _Pattern fromCacheJson(Map<String, dynamic> json) => _Pattern(id: json['id'] as int?, regex: json['regex'] as RegExp);
}

// --- MAP-4: explicit converter whose stored form is not a plain SQLite value -----------------------------------------

/// Stores a UTC DateTime through a DateTime (a value SQLite cannot bind unless the library converts it).
class _UtcConverter extends FluentConverter<DateTime, DateTime> {
  const _UtcConverter();

  @override
  FluentDbDataType get sqlType => FluentDbDataType.integer;

  @override
  DateTime toSql(DateTime value) => value.toUtc();

  @override
  DateTime fromSql(DateTime value) => value;
}

class _Stamped extends FluentStorable {
  _Stamped({this.id, required this.stamp});

  int? id;
  DateTime stamp;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'stamp': stamp};
}

class _StampedProvider extends FluentProvider<_Stamped> {
  @override
  String get tableName => 'stamped';

  @override
  _Stamped get modelSample => _Stamped(stamp: DateTime(2000));

  // (Not a provider member: the converter below is not applied, so this control test only round-trips a DateTime.)
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.converted('stamp', const _UtcConverter())];

  @override
  _Stamped fromCacheJson(Map<String, dynamic> json) => _Stamped(id: json['id'] as int?, stamp: json['stamp'] as DateTime);
}

// --- MAP-5: an enum value that no longer exists in enumValues --------------------------------------------------------

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

// --- MAP-6 / MAP-7: precision of DateTime and double ------------------------------------------------------------------

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

// --- Built-in types that must round-trip --------------------------------------------------------------------------

class _Mixed extends FluentStorable {
  _Mixed({this.id, required this.locale, required this.color, required this.time, required this.spent, required this.big, required this.uri});

  int? id;
  Locale locale;
  Color color;
  TimeOfDay time;
  Duration spent;
  BigInt big;
  Uri uri;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'locale': locale, 'color': color, 'time': time, 'spent': spent, 'big': big, 'uri': uri};
}

class _MixedProvider extends FluentProvider<_Mixed> {
  @override
  String get tableName => 'mixed';

  @override
  _Mixed get modelSample => _Mixed(locale: const Locale('en'), color: const Color(0xFF000000), time: const TimeOfDay(hour: 0, minute: 0), spent: Duration.zero, big: BigInt.zero, uri: Uri());

  @override
  _Mixed fromCacheJson(Map<String, dynamic> json) => _Mixed(
    id: json['id'] as int?,
    locale: json['locale'] as Locale,
    color: json['color'] as Color,
    time: json['time'] as TimeOfDay,
    spent: json['spent'] as Duration,
    big: json['big'] as BigInt,
    uri: json['uri'] as Uri,
  );
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() {
    db = FluentTestDb(name: 'mapping_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() => db.close());

  test('MAP-1 a model whose key was changed after its first save is saved under the new key', () async {
    final items = _ItemProvider();
    await db.open([items]);

    final item = _Item(title: 'a');
    await items.save(item); // generated id 1
    item.id = 7; // the user changes the key
    await items.save(item);

    expect(await items.findById(7), isNotNull, reason: 'buildJson says id 7; the stale generated id 1 must not win');
    expect(await items.count(), 2);
  });

  test('MAP-2 RegExp flags survive a round trip', () async {
    final patterns = _PatternProvider();
    await db.open([patterns]);

    await patterns.save(_Pattern(regex: RegExp('a+', caseSensitive: false, multiLine: true)));
    final RegExp back = (await patterns.findAll()).single.regex;

    expect(back.pattern, 'a+');
    expect(back.isCaseSensitive, isFalse);
    expect(back.isMultiLine, isTrue);
  });

  test('MAP-3 a stored RegExp that does not compile fails with a FluentException, not a raw FormatException', () async {
    final patterns = _PatternProvider();
    await db.open([patterns]);
    await patterns.save(_Pattern(regex: RegExp('ok')));
    final Database sql = patterns.db;
    await sql.update('patterns', {'regex': '(', '_fs_metadata': '{"regex":"regexp"}'});

    await expectLater(patterns.findAll(), throwsA(isA<FluentException>()));
  });

  test('MAP-4 (passes) a converter that stores a DateTime round-trips unchanged', () async {
    final stamped = _StampedProvider();
    await db.open([stamped]);

    final DateTime utc = DateTime.utc(2024, 1, 2, 3, 4, 5);
    await stamped.save(_Stamped(stamp: utc));

    expect((await stamped.findAll()).single.stamp, utc);
  });

  test('MAP-5 one stored enum value that matches no enum value does not block the whole read', () async {
    final tasks = _TaskProvider();
    await db.open([tasks]);
    await tasks.save(_Task(mood: _Mood.on));
    await tasks.save(_Task(mood: _Mood.off));
    final Database sql = tasks.db;
    await sql.update('tasks', {'mood': 'gone'}, where: 'mood = ?', whereArgs: ['off']);

    final List<_Task> all = await tasks.findAll();
    expect(all, hasLength(2));
    expect(all.where((t) => t.mood == null), hasLength(1));
  });

  test('MAP-6 DateTime microseconds are cut to milliseconds with the default (timestamp) format (documented)', () async {
    final readings = _ReadingProvider();
    await db.open([readings]);

    final DateTime at = DateTime.utc(2024, 1, 2, 3, 4, 5, 6, 7);
    await readings.save(_Reading(value: 1, at: at));

    expect((await readings.findAll()).single.at!.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
  });

  test('MAP-7 a NaN double is refused with a typed error instead of being stored as NULL', () async {
    final readings = _ReadingProvider();
    await db.open([readings]);

    await expectLater(
      readings.save(_Reading(value: double.nan, at: DateTime(2000))),
      throwsA(isA<FluentArgumentException>().having((e) => e.code, 'code', FluentErrorCode.unsupportedValue)),
    );
  });

  test('built-in types (Locale with script and region, Color, TimeOfDay, Duration, BigInt, Uri) round-trip', () async {
    final mixed = _MixedProvider();
    await db.open([mixed]);

    final _Mixed m = _Mixed(
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
      color: const Color(0x80112233),
      time: const TimeOfDay(hour: 9, minute: 5),
      spent: const Duration(microseconds: 1234567),
      big: BigInt.parse('123456789012345678901234567890'),
      uri: Uri.parse('https://example.com/a?b=c#d'),
    );
    await mixed.save(m);
    final _Mixed back = (await mixed.findAll()).single;

    expect(back.locale, m.locale);
    expect(back.color, m.color);
    expect(back.time, m.time);
    expect(back.spent, m.spent);
    expect(back.big, m.big);
    expect(back.uri, m.uri);
  });
}
