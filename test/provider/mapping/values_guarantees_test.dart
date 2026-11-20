// G6 / G17 / G29: every supported value reads back equal to what was saved (type x table date format x column mode),
// the stored forms and cursor text are goldens, and random values round trip. Agent T7, seed base 70000.
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color, Locale;

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fuzz.dart';
import '../../helpers/golden.dart';
import '../../helpers/guarantees.dart';

enum Tone { calm, loud, weird }

typedef Same = bool Function(Object? a, Object? b);

bool _sameDefault(Object? a, Object? b) {
  if (a is DateTime && b is DateTime) return a.isAtSameMomentAs(b) && a.isUtc == b.isUtc;
  if (a is double && b is double) return a == b;
  if (a is Uint8List && b is Uint8List) return listEquals(a, b);
  if (a is RegExp && b is RegExp) return a.pattern == b.pattern && a.isCaseSensitive == b.isCaseSensitive && a.isMultiLine == b.isMultiLine && a.isUnicode == b.isUnicode && a.isDotAll == b.isDotAll;
  if (a is List || a is Map) return jsonEncode(a) == jsonEncode(b);
  return a == b;
}

/// How one column is declared for a case: the plain column (inferred), a converter, or an enum setting.
class VMode {
  VMode(this.name, {this.column, this.storeEnumsAsNames = true, this.enumValues = false, this.expected, this.applies});

  final String name;
  final FluentDbColumn Function()? column;
  final bool storeEnumsAsNames;
  final bool enumValues;

  /// What reading back must give for a saved value (default: the value itself).
  final Object? Function(Object value)? expected;
  final bool Function(Object value)? applies;
}

class VCase {
  VCase(this.name, this.values, this.sample, {this.sortable = const [], this.compare, this.modes = const [], this.dateFormats = false, this.expectedPlain, this.golden = true, this.sameAs, this.plainColumn = true});

  final String name;
  final List<Object> values;

  /// Representative non-null value the model sample carries (column kind inference).
  final Object sample;

  /// The values whose order SQLite must give like [compare] (empty: no order guarantee for the type).
  final List<Object> sortable;
  final int Function(Object a, Object b)? compare;
  final List<VMode> modes;

  /// Whether the table date format changes the stored form.
  final bool dateFormats;

  /// What the plain column reads back for a saved value (default: the value itself).
  final Object? Function(Object value, FluentDateTimeFormat format)? expectedPlain;
  final bool golden;
  final Same? sameAs;

  /// Whether the type has a plain (inferred) column; enums need enumValues or a converter.
  final bool plainColumn;

  bool same(Object? a, Object? b) => (sameAs ?? _sameDefault)(a, b);
}

/// The model: `id` and one column `v` of the case's type.
class VModel extends FluentStorable {
  VModel(this.c, this.mode, this.format, {this.id, this.v});

  final VCase c;
  final VMode mode;
  final FluentDateTimeFormat format;
  final int? id;
  final Object? v;

  @override
  FluentTableConfig get tableConfig => FluentTableConfig(dateTimeFormat: format, storeEnumsAsNames: mode.storeEnumsAsNames);

  @override
  Map<String, List<Enum>> get enumValues => mode.enumValues ? {'v': Tone.values} : {};

  @override
  List<FluentDbColumn> get missingColumns => mode.column == null ? [] : [mode.column!()];

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'v': v};
}

class VProvider extends FluentProvider<VModel> {
  VProvider(this.c, this.mode, this.format, {this.table = 'vals', String? slotKey}) : slot = slotOf(slotKey ?? '${c.name}/${mode.name}/${format.name}');

  /// The model class this shape uses (the schema is cached per model type, so each shape needs its own class).
  final int slot;

  final VCase c;
  final VMode mode;
  final FluentDateTimeFormat format;
  final String table;

  @override
  String get tableName => table;

  VModel row({int? id, Object? v}) => vModels[slot](c, mode, format, id: id, v: v);

  @override
  VModel get modelSample => vModels[slot](c, mode, format, id: 0, v: c.sample);

  @override
  VModel fromCacheJson(Map<String, dynamic> json) => vModels[slot](c, mode, format, id: json['id'] as int?, v: json['v']);
}

DateTime _ms(DateTime d) => DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: d.isUtc);

final DateTime _maxUtc = DateTime.fromMillisecondsSinceEpoch(8640000000000000, isUtc: true);
final DateTime _minUtc = DateTime.fromMillisecondsSinceEpoch(-8640000000000000, isUtc: true);

int _compareRunes(String a, String b) {
  final List<int> x = a.runes.toList();
  final List<int> y = b.runes.toList();
  for (int i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return x.length.compareTo(y.length);
}

final List<VCase> cases = [
  VCase('bool', [true, false], true, sortable: [false, true], compare: (a, b) => (a as bool ? 1 : 0).compareTo(b as bool ? 1 : 0)),
  VCase(
    'int',
    [0, 1, -1, 42, 9223372036854775807, -9223372036854775808, 9007199254740993, -9007199254740993],
    0,
    sortable: [0, 1, -1, 42, 9223372036854775807, -9223372036854775808, 9007199254740993, -9007199254740993],
    compare: (a, b) => (a as int).compareTo(b as int),
  ),
  VCase(
    'double',
    [0.0, -0.0, 1.5, -1.5, 5e-324, 1.7976931348623157e308, -1.7976931348623157e308, 1e-300, 0.1, 3.0, double.infinity, double.negativeInfinity],
    0.5,
    sortable: [0.0, 1.5, -1.5, 5e-324, 1.7976931348623157e308, -1.7976931348623157e308, 1e-300, 0.1, 3.0, double.infinity, double.negativeInfinity],
    compare: (a, b) => (a as double).compareTo(b as double),
    
  ),
  VCase(
    'String',
    ['', 'a', "it's", 'say "x"', 'ä ß ж 漢字 🙂', 'line\nbreak\ttab', "Robert'); DROP TABLE vals;--", r'%_\', ' lead and trail ', '{"a":1}', '123', '007', '1e3', 'null', 'true', 'x' * 5000, '\u200b\u202e', 'é', 'é'],
    'x',
    sortable: ['', 'a', "it's", 'say "x"', 'ä ß ж 漢字 🙂', 'B', 'b', '10', '9', 'z', '🙂', '\uffff'],
    compare: (a, b) => _compareRunes(a as String, b as String),
  ),
  VCase(
    'DateTime',
    [
      DateTime.utc(1970),
      DateTime.utc(2024, 5, 6, 7, 8, 9, 10),
      DateTime.utc(2024, 5, 6, 7, 8, 9, 10, 7),
      DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999),
      DateTime.utc(1),
      _minUtc,
      _maxUtc,
      DateTime(2024, 5, 6, 7, 8, 9, 10),
      DateTime(2024, 5, 6, 7, 8, 9, 10, 7),
      DateTime(1900, 1, 1, 12),
    ],
    DateTime(2000),
    sortable: [DateTime.utc(1970), DateTime.utc(2024, 5, 6, 7, 8, 9, 10), DateTime.utc(2024, 5, 6, 7, 8, 9, 10, 7), DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999), DateTime.utc(1000), DateTime.utc(9999, 12, 31), DateTime.utc(2024, 5, 6, 7, 8, 9, 11)],
    compare: (a, b) => (a as DateTime).compareTo(b as DateTime),
    dateFormats: true,
    expectedPlain: (v, f) => f == FluentDateTimeFormat.timestamp ? _ms(v as DateTime) : v,
    modes: [
      VMode(
        'iso converter (toUtc)',
        column: () => FluentDbColumn.converted<DateTime, String>('v', const FluentIsoDateTimeConverter()),
        expected: (v) => (v as DateTime).toUtc(),
        applies: (v) => (v as DateTime).year >= 1 && v.year <= 9999,
      ),
      VMode(
        'iso converter (keep zone)',
        column: () => FluentDbColumn.converted<DateTime, String>('v', const FluentIsoDateTimeConverter(toUtc: false)),
        applies: (v) => (v as DateTime).year >= 1 && v.year <= 9999,
      ),
      VMode(
        'epoch converter (local)',
        column: () => FluentDbColumn.converted<DateTime, int>('v', const FluentEpochDateTimeConverter()),
        expected: (v) => DateTime.fromMillisecondsSinceEpoch((v as DateTime).millisecondsSinceEpoch),
      ),
      VMode(
        'epoch converter (utc)',
        column: () => FluentDbColumn.converted<DateTime, int>('v', const FluentEpochDateTimeConverter(utc: true)),
        expected: (v) => DateTime.fromMillisecondsSinceEpoch((v as DateTime).millisecondsSinceEpoch, isUtc: true),
      ),
    ],
  ),
  VCase(
    'Duration',
    [Duration.zero, const Duration(microseconds: 1), const Duration(microseconds: -1), const Duration(days: 365, hours: 5), const Duration(days: -400), const Duration(microseconds: 9223372036854775807), const Duration(microseconds: -9223372036854775808)],
    Duration.zero,
    sortable: [Duration.zero, const Duration(microseconds: 1), const Duration(microseconds: -1), const Duration(days: 365, hours: 5), const Duration(days: -400)],
    compare: (a, b) => (a as Duration).compareTo(b as Duration),
  ),
  VCase('BigInt', [BigInt.zero, BigInt.one, -BigInt.one, BigInt.two.pow(64), -BigInt.two.pow(200), BigInt.parse('123456789012345678901234567890')], BigInt.one),
  VCase('Uri', [Uri(), Uri.parse('https://example.com/a?b=c&d=%20#frag'), Uri.parse('mailto:x@y.z'), Uri.parse('a/b/../c'), Uri.parse('https://пример.рф/путь?q=漢字'), Uri.parse('file:///C:/x/y z.txt')], Uri()),
  VCase(
    'RegExp',
    [
      RegExp(''),
      RegExp('a+b'),
      RegExp(r'\d{3}-\d{4}'),
      RegExp('abc', caseSensitive: false),
      RegExp('^x\$', multiLine: true),
      RegExp('[\u{1F600}]', unicode: true),
      RegExp('a.b', dotAll: true),
      RegExp('p', caseSensitive: false, multiLine: true, unicode: true, dotAll: true),
      RegExp(r'["\[\],]+'),
    ],
    RegExp('x'),
  ),
  VCase('Color', [const Color(0xFF123456), const Color(0x00000000), const Color(0xFFFFFFFF), const Color.fromARGB(1, 2, 3, 4), const Color(0x80FF0000)], const Color(0xFF000000)),
  VCase(
    'Locale',
    [const Locale('en'), const Locale('en', 'US'), const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'), const Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn'), const Locale('pt', 'BR')],
    const Locale('en'),
  ),
  VCase('TimeOfDay', [const TimeOfDay(hour: 0, minute: 0), const TimeOfDay(hour: 23, minute: 59), const TimeOfDay(hour: 9, minute: 5), const TimeOfDay(hour: 12, minute: 0)], const TimeOfDay(hour: 1, minute: 1)),
  VCase(
    'enum',
    [Tone.calm, Tone.loud, Tone.weird],
    Tone.calm,
    plainColumn: false,
    modes: [
      VMode('enumValues by name', enumValues: true),
      VMode('enumValues by index', enumValues: true, storeEnumsAsNames: false),
      VMode('enum converter by name', column: () => FluentDbColumn.converted<Tone, Object>('v', const FluentEnumConverter<Tone>(Tone.values))),
      VMode('enum converter by index', column: () => FluentDbColumn.converted<Tone, Object>('v', const FluentEnumConverter<Tone>(Tone.values, byName: false))),
    ],
  ),
  VCase(
    'json list',
    [
      <Object?>[],
      <Object?>[1, 'a', true, null, 1.5, -0.0],
      [<Object?>[1, 2, <Object?>[]], 'ä 漢字 🙂', "it's \"q\""],
      <Object?>[9007199254740993, -9223372036854775808],
      <Object?>['{"a":1}', 'null'],
      {'a': 1, 'nested': {'x': true, 'l': [1, 2, 3], 'n': null}, '': 'empty key', 'ключ': 'значение'},
      <String, Object?>{},
    ],
    <Object?>[1],
    modes: [VMode('json converter', column: () => FluentDbColumn.converted<Object, String>('v', const FluentJsonConverter<Object>()))],
  ),
  VCase('Uint8List', [Uint8List(0), Uint8List.fromList([0]), Uint8List.fromList([0, 1, 2, 255, 0, 128]), Uint8List.fromList(List<int>.generate(70000, (i) => i % 256))], Uint8List.fromList([1])),
];

List<VMode> modesOf(VCase c) => [if (c.plainColumn) VMode('plain'), ...c.modes];

String describe(Object? v) {
  if (v == null) return 'null';
  if (v is DateTime) return 'DateTime(${v.toIso8601String()})';
  if (v is Uint8List) return 'Uint8List(${v.length > 8 ? '${v.sublist(0, 8)}...' : v.toString()})';
  if (v is RegExp) return 'RegExp(${v.pattern}, cs=${v.isCaseSensitive} ml=${v.isMultiLine} u=${v.isUnicode} da=${v.isDotAll})';
  if (v is Color) return 'Color(0x${v.toARGB32().toRadixString(16)})';
  if (v is TimeOfDay) return 'TimeOfDay(${v.hour}:${v.minute})';
  if (v is String && v.length > 40) return 'String(len ${v.length})';
  if (v is BigInt) return 'BigInt($v)';
  if (v is Uri) return 'Uri($v)';
  if (v is List || v is Map) return 'json(${jsonEncode(v)})';
  return '${v.runtimeType}($v)';
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  setUp(() => db = FluentTestDb(name: 'values_${DateTime.now().microsecondsSinceEpoch}', persistent: true));
  tearDown(() => db.close());

  Future<VProvider> open(VCase c, VMode mode, FluentDateTimeFormat format) async {
    final VProvider p = VProvider(c, mode, format);
    await db.open([p]);
    return p;
  }

  Object? expectedOf(VCase c, VMode mode, FluentDateTimeFormat format, Object? v) {
    if (v == null) return null;
    if (mode.expected != null) return mode.expected!(v);
    if (mode.name == 'plain' && c.expectedPlain != null) return c.expectedPlain!(v, format);
    return v;
  }

  List<Object> valuesFor(VCase c, VMode mode) => [for (final Object v in c.values) if (mode.applies?.call(v) ?? true) v];

  void expectOnlyKnownIssues(Iterable<FluentIssueKind> allowed) {
    for (final FluentIssue i in db.warnings) {
      expect(allowed, contains(i.kind), reason: 'G6/G25: unexpected warning ${i.kind.name}: ${i.title}');
    }
    expectIssuesHaveFixes(db.issues);
  }

  for (final VCase c in cases) {
    for (final VMode mode in modesOf(c)) {
      for (final FluentDateTimeFormat format in (c.dateFormats && mode.name == 'plain') ? FluentDateTimeFormat.values : [FluentDateTimeFormat.timestamp]) {
        final String label = '${c.name} / ${mode.name}${c.dateFormats && mode.name == 'plain' ? ' / ${format.name}' : ''}';

        test('G6: $label: save, read, findMaps, filter, pluck, update, null', () async {
          final VProvider p = await open(c, mode, format);
          final List<Object> values = valuesFor(c, mode);
          final List<VModel> models = [for (int i = 0; i < values.length; i++) p.row(id: i + 1, v: values[i])];
          await p.saveAll([...models, p.row(id: values.length + 1, v: null)]);

          final List<VModel> back = await p.find(orderBy: 'id');
          expect(back, hasLength(values.length + 1));
          for (int i = 0; i < values.length; i++) {
            final Object? want = expectedOf(c, mode, format, values[i]);
            expect(c.same(back[i].v, want), isTrue, reason: 'G6: ${describe(values[i])} read back as ${describe(back[i].v)}, expected ${describe(want)}');
          }
          expect(back.last.v, isNull, reason: 'G6: null stays null');

          final List<Map<String, dynamic>> maps = await p.findMaps(orderBy: 'id');
          for (int i = 0; i < values.length; i++) {
            expect(c.same(maps[i]['v'], expectedOf(c, mode, format, values[i])), isTrue, reason: 'G6: findMaps of ${describe(values[i])} gave ${describe(maps[i]['v'])}');
            expect(maps[i].keys.toSet(), {'id', 'v'}, reason: 'G29: findMaps has exactly the model fields');
          }

          // pluck
          final List<Object?> plucked = await p.pluck<Object?>('v', orderBy: 'id');
          for (int i = 0; i < values.length; i++) {
            expect(c.same(plucked[i], expectedOf(c, mode, format, values[i])), isTrue, reason: 'G6: pluck of ${describe(values[i])} gave ${describe(plucked[i])}');
          }
          expect(plucked.last, isNull);

          // eq filter: a value finds exactly the rows that read back equal to it (-0.0 and 0.0 are equal for SQL)
          final Same looseEq = c.name == 'double' ? (a, b) => a is double && b is double && a == b : c.same;
          for (int i = 0; i < values.length; i++) {
            final Object want = expectedOf(c, mode, format, values[i])!;
            final List<VModel> found = await p.find(where: FluentFilter.eq('v', values[i]), orderBy: 'id');
            final List<int> expectedIds = [for (int k = 0; k < values.length; k++) if (looseEq(expectedOf(c, mode, format, values[k]), want)) k + 1];
            expect(found.map((m) => m.id).toList(), expectedIds, reason: 'G6: eq filter with ${describe(values[i])}');
          }
          expect((await p.find(where: FluentFilter.isNull('v'))).map((m) => m.id), [values.length + 1]);

          // update path: the same value goes through updateById
          for (int i = 0; i < values.length; i++) {
            final Object next = values[(i + 1) % values.length];
            await p.updateById(i + 1, {'v': next});
            final VModel? m = await p.findById(i + 1);
            expect(c.same(m!.v, expectedOf(c, mode, format, next)), isTrue, reason: 'G6: updateById with ${describe(next)} read back ${describe(m.v)}');
          }

          if (mode.name == 'plain' && c.dateFormats && format == FluentDateTimeFormat.timestamp) {
            final bool lossy = values.any((v) => (v as DateTime).microsecond != 0);
            expect(db.issues.any((i) => i.kind == FluentIssueKind.precisionLost), lossy, reason: 'G6: the timestamp format reports the microseconds it drops');
          } else if (c.name == 'DateTime') {
            expect(db.issues.any((i) => i.kind == FluentIssueKind.precisionLost), isFalse, reason: 'G6: nothing is dropped, nothing is reported');
          }
          expectOnlyKnownIssues(const [FluentIssueKind.precisionLost]);
          await expectIntegrity(p.db);
        });

        if (c.sortable.isNotEmpty && (mode.applies == null)) {
          test('G6: $label: order by, min and max follow the Dart order', () async {
            final VProvider p = await open(c, mode, format);
            final List<Object> values = c.sortable;
            await p.saveAll([for (int i = 0; i < values.length; i++) p.row(id: i + 1, v: values[i])]);
            final List<Object?> expected = [for (final Object v in values) expectedOf(c, mode, format, v)]..sort((a, b) => c.compare!(a!, b!));
            for (final bool desc in [false, true]) {
              final List<VModel> sorted = await p.find(orderBy: desc ? 'v DESC' : 'v');
              final List<Object?> want = desc ? expected.reversed.toList() : expected;
              expect(sorted.length, want.length);
              for (int i = 0; i < want.length; i++) {
                expect(c.same(sorted[i].v, want[i]), isTrue, reason: 'G6: order ${desc ? 'DESC' : 'ASC'} position $i: got ${describe(sorted[i].v)}, expected ${describe(want[i])}');
              }
            }
            final Object? lo = await p.min<Object>('v');
            final Object? hi = await p.max<Object>('v');
            expect(c.same(lo, expected.first), isTrue, reason: 'G6: min gave ${describe(lo)}, expected ${describe(expected.first)}');
            expect(c.same(hi, expected.last), isTrue, reason: 'G6: max gave ${describe(hi)}, expected ${describe(expected.last)}');
            // comparison filters agree with the Dart order too
            final Object mid = expected[expected.length ~/ 2]!;
            final List<VModel> above = await p.find(where: FluentFilter.gt('v', mid));
            expect(above.length, expected.where((e) => c.compare!(e!, mid) > 0).length, reason: 'G6: gt filter after ${describe(mid)}');
            final List<VModel> upTo = await p.find(where: FluentFilter.lte('v', mid));
            expect(upTo.length, expected.where((e) => c.compare!(e!, mid) <= 0).length, reason: 'G6: lte filter up to ${describe(mid)}');
            expectOnlyKnownIssues(const [FluentIssueKind.precisionLost]);
            await expectIntegrity(p.db);
          });
        }

        test('G11/G6: $label: a watch shows the same values as a read', () async {
          final VProvider p = await open(c, mode, format);
          final List<Object> values = valuesFor(c, mode).take(4).toList();
          await p.saveAll([for (int i = 0; i < values.length; i++) p.row(id: i + 1, v: values[i])]);
          final List<VModel> first = await p.watch(orderBy: 'id').first.timeout(const Duration(seconds: 10));
          for (int i = 0; i < values.length; i++) {
            expect(c.same(first[i].v, expectedOf(c, mode, format, values[i])), isTrue, reason: 'G6: watch of ${describe(values[i])} gave ${describe(first[i].v)}');
          }
          await db.settle();
        });
      }
    }
  }

  group('G17: stored forms', () {
    // The stored value, its SQLite type and the type metadata of every value of the matrix (timezone independent
    // values only: UTC dates, no local DateTime).
    bool deterministic(Object v) => !(v is DateTime && !v.isUtc);

    Future<String> storedForms(VCase c, VMode mode, FluentDateTimeFormat format) async {
      final VProvider p = await open(c, mode, format);
      final List<Object> values = [for (final Object v in valuesFor(c, mode)) if (deterministic(v)) v];
      final StringBuffer out = StringBuffer('# ${c.name} / ${mode.name} / ${format.name}\n');
      for (int i = 0; i < values.length; i++) {
        await p.save(p.row(id: i + 1, v: values[i]));
        final Map<String, Object?> row = (await p.db.rawQuery('SELECT v, typeof(v) AS t, length(v) AS n, _fs_metadata AS m FROM vals WHERE id = ?', [i + 1])).single;
        Object? stored = row['v'];
        if (stored is List<int>) stored = 'x\'${stored.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\' (${stored.length} bytes)';
        if (stored is String && stored.length > 60) stored = '${stored.substring(0, 60)}... (${stored.length} chars)';
        out.writeln('${describe(values[i])} -> ${row['t']} $stored | meta ${row['m']}');
      }
      await db.close();
      return out.toString();
    }

    test('G17: the stored form and _fs_metadata of every value of the matrix match the golden', () async {
      final StringBuffer all = StringBuffer();
      for (final VCase c in cases) {
        for (final VMode mode in modesOf(c)) {
          for (final FluentDateTimeFormat format in (c.dateFormats && mode.name == 'plain') ? FluentDateTimeFormat.values : [FluentDateTimeFormat.timestamp]) {
            all.writeln(await storedForms(c, mode, format));
          }
        }
      }
      expectGolden('values/stored_forms.txt', all.toString());
    });

    test('G17: the cursor text of representative cursors matches the golden', () {
      final List<FluentCursor> cursors = [
        const FluentCursor(orderBy: 'id', descending: false, value: 5, key: {'id': 5}),
        const FluentCursor(orderBy: 'name', descending: true, value: 'Zoë 🙂', key: {'id': 12}),
        const FluentCursor(orderBy: 'score', descending: false, value: 1.5, key: {'id': 1}),
        const FluentCursor(orderBy: 'score', descending: false, value: double.infinity, key: {'id': 2}),
        const FluentCursor(orderBy: 'score', descending: true, value: double.negativeInfinity, key: {'id': 3}),
        const FluentCursor(orderBy: 'score', descending: true, value: double.nan, key: {'id': 4}),
        const FluentCursor(orderBy: 'at', descending: false, value: 1714979289010, key: {'id': 7}),
        FluentCursor(orderBy: 'blob', descending: false, value: Uint8List.fromList([0, 1, 255]), key: const {'id': 1}),
        const FluentCursor(orderBy: 'flag', descending: false, value: null, key: {'a': 'x', 'b': 2}),
        const FluentCursor(orderBy: 'big', descending: false, value: 9007199254740993, key: {'id': 9223372036854775807}),
      ];
      final StringBuffer out = StringBuffer();
      for (final FluentCursor cursor in cursors) {
        final String text = cursor.encode();
        out.writeln('$cursor => $text');
        final FluentCursor back = FluentCursor.decode(text);
        expect(back, cursor, reason: 'G6: a cursor decodes to what was encoded');
        expect(back.encode(), text, reason: 'G17: encode is stable');
      }
      expectGolden('values/cursors.txt', out.toString());
    });
  });

  group('G6: known gaps', () {
    test('G6: -0.0 keeps its sign', () async {
      final VCase c = cases.firstWhere((c) => c.name == 'double');
      final VProvider p = await open(c, VMode('plain'), FluentDateTimeFormat.timestamp);
      await p.save(p.row(id: 1, v: -0.0));
      expect((await p.findById(1))!.v, isA<double>().having((d) => d.isNegative, 'isNegative', isTrue));
    }, skip: 'LIMIT: SQLite stores the REAL -0.0 as 0.0 (the value is equal, the sign is lost); not reported, not in the docs');

    test('G25/G26: a converter declared in missingColumns for a buildJson field (as doc/models.md shows) raises no warning', () async {
      final VCase c = cases.firstWhere((c) => c.name == 'DateTime');
      final VMode mode = c.modes.first;
      final VProvider p = await open(c, mode, FluentDateTimeFormat.timestamp);
      await p.save(p.row(id: 1, v: DateTime.utc(2024)));
      expect(db.warnings.where((i) => i.kind == FluentIssueKind.schemaFallback), isEmpty);
    });
  });

  group('G6: random values', () {
    for (final int seed in fuzzSeeds(base: 70000)) {
      test('G6: random values of every type round trip (seed $seed)', () async {
        final FluentFuzz fuzz = FluentFuzz(seed);
        final FluentDateTimeFormat format = fuzz.pick(FluentDateTimeFormat.values);
        final List<Object> strings = [for (int i = 0; i < 12; i++) fuzz.string(max: 30)];
        final List<Object> doubles = [for (int i = 0; i < 12; i++) fuzz.float()];
        final List<Object> ints = [for (int i = 0; i < 12; i++) fuzz.pick([fuzz.intIn(-1000000, 1000000), wide(fuzz), 9223372036854775807, -9223372036854775808])];
        final List<Object> dates = [for (int i = 0; i < 12; i++) fuzz.dateTime()];
        final List<Object> bigs = [for (int i = 0; i < 6; i++) BigInt.from(wide(fuzz)) * BigInt.from(fuzz.intIn(1, 1 << 30))];
        final List<Object> durations = [for (int i = 0; i < 8; i++) Duration(microseconds: wide(fuzz))];
        final List<Object> jsons = [
          for (int i = 0; i < 6; i++) <Object?>[fuzz.string(), fuzz.intIn(-99, 99), fuzz.chance(0.5), null, {fuzz.string(max: 4): fuzz.string()}],
        ];
        final List<(String, List<Object>, Object, bool)> groups = [
          ('String', strings, 'x', false),
          ('double', doubles, 0.5, false),
          ('int', ints, 0, false),
          ('DateTime', dates, DateTime(2000), true),
          ('BigInt', bigs, BigInt.one, false),
          ('Duration', durations, Duration.zero, false),
          ('json', jsons, <Object?>[1], false),
        ];
        int n = 0;
        for (final (String name, List<Object> values, Object sample, bool isDate) in groups) {
          // ISO text of a local time has no offset: in the hour repeated when the clocks go back it reads back as the
          // first instant with that wall-clock time (reported as precisionLost).
          final VCase c = VCase(name, values, sample, expectedPlain: isDate ? (v, f) => f == FluentDateTimeFormat.timestamp ? _ms(v as DateTime) : _wallClock(v as DateTime) : null);
          final VMode mode = VMode('plain');
          final VProvider p = VProvider(c, mode, format, table: 'rnd${n++}');
          await db.open([p]);
          await p.saveAll([for (int i = 0; i < values.length; i++) p.row(id: i + 1, v: values[i])]);
          final List<VModel> back = await p.find(orderBy: 'id');
          for (int i = 0; i < values.length; i++) {
            final Object? want = expectedOf(c, mode, format, values[i]);
            expect(c.same(back[i].v, want), isTrue, reason: 'G6 seed $seed: $name ${describe(values[i])} read back as ${describe(back[i].v)}');
            final List<VModel> found = await p.find(where: FluentFilter.eq('v', values[i]));
            expect(found.any((m) => m.id == i + 1), isTrue, reason: 'G6 seed $seed: eq filter finds ${describe(values[i])}');
          }
          await expectIntegrity(p.db);
        }
        expectOnlyKnownIssues(const [FluentIssueKind.precisionLost]);
      });
    }
  });
}

/// A 62-bit integer (FluentFuzz.intIn takes at most 2^32 values).
int wide(FluentFuzz fuzz) => (fuzz.intIn(0, 1 << 30) << 32 | fuzz.intIn(0, 1 << 31)) * (fuzz.chance(0.5) ? 1 : -1);

final Map<String, int> _slots = {};

/// One model class per shape.
int slotOf(String key) => _slots.putIfAbsent(key, () => _slots.length);

typedef VMaker = VModel Function(VCase c, VMode mode, FluentDateTimeFormat format, {int? id, Object? v});

final List<VMaker> vModels = <VMaker>[
  VM0.new,
  VM1.new,
  VM2.new,
  VM3.new,
  VM4.new,
  VM5.new,
  VM6.new,
  VM7.new,
  VM8.new,
  VM9.new,
  VM10.new,
  VM11.new,
  VM12.new,
  VM13.new,
  VM14.new,
  VM15.new,
  VM16.new,
  VM17.new,
  VM18.new,
  VM19.new,
  VM20.new,
  VM21.new,
  VM22.new,
  VM23.new,
  VM24.new,
  VM25.new,
  VM26.new,
  VM27.new,
  VM28.new,
  VM29.new,
  VM30.new,
  VM31.new,
  VM32.new,
  VM33.new,
  VM34.new,
  VM35.new,
  VM36.new,
  VM37.new,
  VM38.new,
  VM39.new,
  VM40.new,
  VM41.new,
  VM42.new,
  VM43.new,
  VM44.new,
  VM45.new,
  VM46.new,
  VM47.new,
  VM48.new,
  VM49.new,
  VM50.new,
  VM51.new,
  VM52.new,
  VM53.new,
  VM54.new,
  VM55.new,
  VM56.new,
  VM57.new,
  VM58.new,
  VM59.new,
];

class VM0 extends VModel {
  VM0(super.c, super.mode, super.format, {super.id, super.v});
}

class VM1 extends VModel {
  VM1(super.c, super.mode, super.format, {super.id, super.v});
}

class VM2 extends VModel {
  VM2(super.c, super.mode, super.format, {super.id, super.v});
}

class VM3 extends VModel {
  VM3(super.c, super.mode, super.format, {super.id, super.v});
}

class VM4 extends VModel {
  VM4(super.c, super.mode, super.format, {super.id, super.v});
}

class VM5 extends VModel {
  VM5(super.c, super.mode, super.format, {super.id, super.v});
}

class VM6 extends VModel {
  VM6(super.c, super.mode, super.format, {super.id, super.v});
}

class VM7 extends VModel {
  VM7(super.c, super.mode, super.format, {super.id, super.v});
}

class VM8 extends VModel {
  VM8(super.c, super.mode, super.format, {super.id, super.v});
}

class VM9 extends VModel {
  VM9(super.c, super.mode, super.format, {super.id, super.v});
}

class VM10 extends VModel {
  VM10(super.c, super.mode, super.format, {super.id, super.v});
}

class VM11 extends VModel {
  VM11(super.c, super.mode, super.format, {super.id, super.v});
}

class VM12 extends VModel {
  VM12(super.c, super.mode, super.format, {super.id, super.v});
}

class VM13 extends VModel {
  VM13(super.c, super.mode, super.format, {super.id, super.v});
}

class VM14 extends VModel {
  VM14(super.c, super.mode, super.format, {super.id, super.v});
}

class VM15 extends VModel {
  VM15(super.c, super.mode, super.format, {super.id, super.v});
}

class VM16 extends VModel {
  VM16(super.c, super.mode, super.format, {super.id, super.v});
}

class VM17 extends VModel {
  VM17(super.c, super.mode, super.format, {super.id, super.v});
}

class VM18 extends VModel {
  VM18(super.c, super.mode, super.format, {super.id, super.v});
}

class VM19 extends VModel {
  VM19(super.c, super.mode, super.format, {super.id, super.v});
}

class VM20 extends VModel {
  VM20(super.c, super.mode, super.format, {super.id, super.v});
}

class VM21 extends VModel {
  VM21(super.c, super.mode, super.format, {super.id, super.v});
}

class VM22 extends VModel {
  VM22(super.c, super.mode, super.format, {super.id, super.v});
}

class VM23 extends VModel {
  VM23(super.c, super.mode, super.format, {super.id, super.v});
}

class VM24 extends VModel {
  VM24(super.c, super.mode, super.format, {super.id, super.v});
}

class VM25 extends VModel {
  VM25(super.c, super.mode, super.format, {super.id, super.v});
}

class VM26 extends VModel {
  VM26(super.c, super.mode, super.format, {super.id, super.v});
}

class VM27 extends VModel {
  VM27(super.c, super.mode, super.format, {super.id, super.v});
}

class VM28 extends VModel {
  VM28(super.c, super.mode, super.format, {super.id, super.v});
}

class VM29 extends VModel {
  VM29(super.c, super.mode, super.format, {super.id, super.v});
}

class VM30 extends VModel {
  VM30(super.c, super.mode, super.format, {super.id, super.v});
}

class VM31 extends VModel {
  VM31(super.c, super.mode, super.format, {super.id, super.v});
}

class VM32 extends VModel {
  VM32(super.c, super.mode, super.format, {super.id, super.v});
}

class VM33 extends VModel {
  VM33(super.c, super.mode, super.format, {super.id, super.v});
}

class VM34 extends VModel {
  VM34(super.c, super.mode, super.format, {super.id, super.v});
}

class VM35 extends VModel {
  VM35(super.c, super.mode, super.format, {super.id, super.v});
}

class VM36 extends VModel {
  VM36(super.c, super.mode, super.format, {super.id, super.v});
}

class VM37 extends VModel {
  VM37(super.c, super.mode, super.format, {super.id, super.v});
}

class VM38 extends VModel {
  VM38(super.c, super.mode, super.format, {super.id, super.v});
}

class VM39 extends VModel {
  VM39(super.c, super.mode, super.format, {super.id, super.v});
}

class VM40 extends VModel {
  VM40(super.c, super.mode, super.format, {super.id, super.v});
}

class VM41 extends VModel {
  VM41(super.c, super.mode, super.format, {super.id, super.v});
}

class VM42 extends VModel {
  VM42(super.c, super.mode, super.format, {super.id, super.v});
}

class VM43 extends VModel {
  VM43(super.c, super.mode, super.format, {super.id, super.v});
}

class VM44 extends VModel {
  VM44(super.c, super.mode, super.format, {super.id, super.v});
}

class VM45 extends VModel {
  VM45(super.c, super.mode, super.format, {super.id, super.v});
}

class VM46 extends VModel {
  VM46(super.c, super.mode, super.format, {super.id, super.v});
}

class VM47 extends VModel {
  VM47(super.c, super.mode, super.format, {super.id, super.v});
}

class VM48 extends VModel {
  VM48(super.c, super.mode, super.format, {super.id, super.v});
}

class VM49 extends VModel {
  VM49(super.c, super.mode, super.format, {super.id, super.v});
}

class VM50 extends VModel {
  VM50(super.c, super.mode, super.format, {super.id, super.v});
}

class VM51 extends VModel {
  VM51(super.c, super.mode, super.format, {super.id, super.v});
}

class VM52 extends VModel {
  VM52(super.c, super.mode, super.format, {super.id, super.v});
}

class VM53 extends VModel {
  VM53(super.c, super.mode, super.format, {super.id, super.v});
}

class VM54 extends VModel {
  VM54(super.c, super.mode, super.format, {super.id, super.v});
}

class VM55 extends VModel {
  VM55(super.c, super.mode, super.format, {super.id, super.v});
}

class VM56 extends VModel {
  VM56(super.c, super.mode, super.format, {super.id, super.v});
}

class VM57 extends VModel {
  VM57(super.c, super.mode, super.format, {super.id, super.v});
}

class VM58 extends VModel {
  VM58(super.c, super.mode, super.format, {super.id, super.v});
}

class VM59 extends VModel {
  VM59(super.c, super.mode, super.format, {super.id, super.v});
}

/// [d] as ISO text without an offset reads back: a local time becomes the first instant with its wall-clock time.
DateTime _wallClock(DateTime d) => d.isUtc ? d : DateTime(d.year, d.month, d.day, d.hour, d.minute, d.second, d.millisecond, d.microsecond);
