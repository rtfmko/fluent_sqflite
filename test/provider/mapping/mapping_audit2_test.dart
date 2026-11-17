// Regression tests of audit 2 (KNOWN_BUGS 34-38): stored column defaults, UTC flags in aggregates, cursor round trip,
// fixed-length ISO text, hints for column names that are not plain identifiers.
@Timeout(Duration(seconds: 20))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

enum _Level { low, high }

/// A dynamic model with its own table settings.
class _CfgModel extends DynamicModel {
  _CfgModel(super.spec, this.config, {super.values});

  final FluentTableConfig config;

  @override
  FluentTableConfig get tableConfig => config;
}

class _CfgProvider extends DynamicProvider {
  _CfgProvider(super.table, super.columns, {this.config = const FluentTableConfig()});

  final FluentTableConfig config;

  @override
  DynamicModel get modelSample => _CfgModel(spec, config);

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) => _CfgModel(spec, config, values: json);

  @override
  DynamicModel row(Map<String, dynamic> values) => _CfgModel(spec, config, values: values);
}

const FluentTableConfig _iso = FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

void main() {
  setUpFluentTests();
  late FluentTestDb db;
  setUp(() => db = FluentTestDb(name: 'audit2_map_${DateTime.now().microsecondsSinceEpoch}'));
  tearDown(() => db.close());

  group('34 column defaults are stored like the row writer stores them', () {
    test('a DateTime default of an ISO converter column reads back', () async {
      final p = _CfgProvider('def_conv', () => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.converted('at', const FluentIsoDateTimeConverter(), defaultValue: DateTime.utc(2020))]);
      await db.open([p]);
      await p.save(p.row({'name': 'x'}));
      final rows = await p.findAll();
      expect(rows.single['at'], DateTime.utc(2020));
      final raw = await p.rawQuery('SELECT "at" FROM def_conv');
      expect(raw.single['at'], '2020-01-01T00:00:00.000000Z');
    });

    test('a DateTime default on a plain column follows the table dateTimeFormat', () async {
      final iso = _CfgProvider('def_iso', () => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn(name: 'at', type: FluentDbDataType.text, valueKind: FluentValueKind.dateTime, defaultValue: DateTime.utc(2020, 1, 2, 3))], config: _iso);
      final millis = _CfgProvider('def_ms', () => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.timestamp('at').copyWith(defaultValue: DateTime.utc(2020, 1, 2, 3))]);
      await db.open([iso, millis]);
      await iso.save(iso.row({'name': 'x'}));
      await millis.save(millis.row({'name': 'x'}));
      expect((await iso.rawQuery('SELECT "at" FROM def_iso')).single['at'], '2020-01-02T03:00:00.000000Z');
      expect((await millis.rawQuery('SELECT "at" FROM def_ms')).single['at'], DateTime.utc(2020, 1, 2, 3).millisecondsSinceEpoch);
      expect((await iso.findAll()).single['at'], DateTime.utc(2020, 1, 2, 3));
      expect((await millis.findAll()).single['at'], DateTime.utc(2020, 1, 2, 3).toLocal());
    });

    test('an enum default uses the enum converter (index when names are off), a stored form stays as it is', () async {
      final byIndex = _CfgProvider(
        'def_enum',
        () => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.converted('lvl', const FluentEnumConverter<_Level>(_Level.values, byName: false), defaultValue: _Level.high)],
      );
      final byName = _CfgProvider('def_enum2', () => [FluentDbColumn.primary(), FluentDbColumn.text('name'), FluentDbColumn.converted('lvl', const FluentEnumConverter<_Level>(_Level.values), defaultValue: 'low')]);
      await db.open([byIndex, byName]);
      await byIndex.save(byIndex.row({'name': 'x'}));
      await byName.save(byName.row({'name': 'x'}));
      expect((await byIndex.rawQuery('SELECT "lvl" FROM def_enum')).single['lvl'], 1);
      expect((await byIndex.findAll()).single['lvl'], _Level.high);
      expect((await byName.findAll()).single['lvl'], _Level.low);
    });

    test('the DEFAULT text (so the schema fingerprint) follows the table settings', () async {
      final a = _CfgProvider('def_fp', () => [FluentDbColumn.primary(), FluentDbColumn(name: 'at', type: FluentDbDataType.text, valueKind: FluentValueKind.dateTime, defaultValue: DateTime.utc(2020))], config: _iso);
      final b = _CfgProvider('def_fp', () => [FluentDbColumn.primary(), FluentDbColumn(name: 'at', type: FluentDbDataType.text, valueKind: FluentValueKind.dateTime, defaultValue: DateTime.utc(2020))]);
      expect(a.getFullSchema.firstWhere((c) => c.name == 'at').sqlDefinition, contains("DEFAULT '2020-01-01T00:00:00.000000Z'"));
      expect(b.getFullSchema.firstWhere((c) => c.name == 'at').sqlDefinition, contains('DEFAULT ${DateTime.utc(2020).millisecondsSinceEpoch}'));
    });

    test('Infinity is a valid default, NaN is a typed error with a hint', () async {
      final p = _CfgProvider('def_inf', () => [FluentDbColumn.primary(), FluentDbColumn.real('hi', defaultValue: double.infinity), FluentDbColumn.real('lo', defaultValue: double.negativeInfinity), FluentDbColumn.text('name')]);
      await db.open([p]);
      await p.save(p.row({'name': 'x'}));
      final raw = (await p.rawQuery('SELECT "hi", "lo" FROM def_inf')).single;
      expect(raw['hi'], double.infinity);
      expect(raw['lo'], double.negativeInfinity);
      expect(fluentSqlLiteral(double.nan), 'NULL');
      expect(
        () => FluentDbColumn.real('x', defaultValue: double.nan).sqlDefinition,
        throwsA(isA<FluentSchemaException>().having((e) => e.hint, 'hint', isNotNull).having((e) => e.columnName, 'columnName', 'x')),
      );
    });

    test('a blob default is a blob literal', () {
      expect(fluentSqlLiteral(Uint8List.fromList([0, 15, 255])), "X'000fff'");
      expect(fluentSqlLiteral("it's"), "'it''s'");
    });
  });

  group('35 aggregate keeps the UTC flag', () {
    late _CfgProvider p;
    setUp(() async {
      p = _CfgProvider('agg_utc', () => [FluentDbColumn.primary(), FluentDbColumn.text('grp'), FluentDbColumn.text('at'), FluentDbColumn.text('other')]);
      await db.open([p]);
      await p.save(p.row({'grp': 'a', 'at': DateTime.utc(2026, 1, 1, 10), 'other': DateTime.utc(2026, 5)}));
      await p.save(p.row({'grp': 'a', 'at': DateTime.utc(2026, 1, 2, 10), 'other': DateTime.utc(2026, 6)}));
      await p.save(p.row({'grp': 'b', 'at': DateTime.utc(2026, 2, 1, 10), 'other': DateTime.utc(2026, 7)}));
    });

    test('several min / max values', () async {
      final r = (await p.aggregate(values: {'lo': const FluentAggregate.min('at'), 'hi': const FluentAggregate.max('at'), 'ol': const FluentAggregate.min('other')})).single;
      expect(r['lo'], DateTime.utc(2026, 1, 1, 10));
      expect((r['lo'] as DateTime).isUtc, isTrue);
      expect(r['hi'], DateTime.utc(2026, 2, 1, 10));
      expect(r['ol'], DateTime.utc(2026, 5));
    });

    test('group columns and grouped min / max', () async {
      final r = await p.aggregate(groupBy: ['at'], values: {'n': const FluentAggregate.count()}, orderBy: 'at');
      expect(r.map((e) => e['at']), [DateTime.utc(2026, 1, 1, 10), DateTime.utc(2026, 1, 2, 10), DateTime.utc(2026, 2, 1, 10)]);
      final g = await p.aggregate(groupBy: ['grp'], values: {'lo': const FluentAggregate.min('at'), 'hi': const FluentAggregate.max('at')}, orderBy: 'grp');
      expect(g.map((e) => e['hi']), [DateTime.utc(2026, 1, 2, 10), DateTime.utc(2026, 2, 1, 10)]);
      expect(g.every((e) => (e['lo'] as DateTime).isUtc && (e['hi'] as DateTime).isUtc), isTrue);
    });

    test('local values stay local, single min / max still work', () async {
      await p.save(p.row({'grp': 'c', 'at': DateTime(2026, 3, 1, 10), 'other': 'x'}));
      final g = await p.aggregate(groupBy: ['grp'], values: {'lo': const FluentAggregate.min('at'), 'hi': const FluentAggregate.max('at')}, where: FluentFilter.eq('grp', 'c'));
      expect((g.single['lo'] as DateTime).isUtc, isFalse);
      expect(g.single['lo'], DateTime(2026, 3, 1, 10));
      expect((await p.min<DateTime>('at', where: FluentFilter.eq('grp', 'a')))!.isUtc, isTrue);
    });

    test('a group mixing UTC and local values reports it and keeps working', () async {
      await p.save(p.row({'grp': 'a', 'at': DateTime(2026, 4, 1, 10), 'other': DateTime.utc(2026, 8)}));
      final r = (await p.aggregate(values: {'lo': const FluentAggregate.min('at'), 'hi': const FluentAggregate.max('at')})).single;
      expect(r['lo'], isNotNull);
      await db.settle();
      expect(db.issues.any((i) => i.kind == FluentIssueKind.mappingValue), isTrue);
    });
  });

  group('36 cursors round trip', () {
    test('a cursor over a BLOB column keeps its bytes', () async {
      final p = _CfgProvider('cur_blob', () => [FluentDbColumn.primary(), FluentDbColumn.blob('data')]);
      await db.open([p]);
      for (final b in [1, 2, 3, 4]) {
        await p.save(p.row({'data': Uint8List.fromList([b, b])}));
      }
      final first = await p.findPage(orderBy: 'data', limit: 2);
      final decoded = FluentCursor.decode(first.next!.encode());
      expect(decoded.value, isA<Uint8List>());
      expect(decoded, first.next);
      expect(decoded.hashCode, first.next.hashCode);
      final second = await p.findPage(orderBy: 'data', limit: 2, after: decoded);
      expect(second.items.map((e) => e['data']), [Uint8List.fromList([3, 3]), Uint8List.fromList([4, 4])]);
    });

    test('non-finite doubles and edge values survive encode / decode', () {
      for (final v in <Object?>[double.infinity, double.negativeInfinity, 1.5, 0, '', 'ü', 9007199254740993, null, Uint8List(0)]) {
        final c = FluentCursor(orderBy: 'a', descending: true, value: v, key: {'id': v});
        final back = FluentCursor.decode(c.encode());
        expect(back, c, reason: '$v');
        expect(back.descending, isTrue);
      }
      final nan = FluentCursor.decode(const FluentCursor(orderBy: 'a', descending: false, value: double.nan, key: {}).encode());
      expect((nan.value as double).isNaN, isTrue);
    });

    test('cursors of earlier 2.0 versions still decode, other values fail typed', () {
      final old = base64Url.encode(utf8.encode(jsonEncode({'o': 'a', 'd': false, 'v': 'x', 'k': {'id': 7}})));
      final c = FluentCursor.decode(old);
      expect(c.value, 'x');
      expect(c.key, {'id': 7});
      expect(() => FluentCursor(orderBy: 'a', descending: false, value: DateTime(2020), key: const {}).encode(), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotNull)));
      expect(() => FluentCursor.decode('not a cursor'), throwsA(isA<FluentArgumentException>()));
    });
  });

  group('37 ISO-8601 text has a fixed fraction', () {
    test('the codec writes six digits and sorts like time', () {
      expect(FluentTypeCodecs.encode(DateTime.utc(2026, 1, 1, 12, 0, 0, 123), _iso)!.value, '2026-01-01T12:00:00.123000Z');
      expect(FluentTypeCodecs.encode(DateTime.utc(2026, 1, 1, 12, 0, 0, 123, 456), _iso)!.value, '2026-01-01T12:00:00.123456Z');
      expect(FluentTypeCodecs.encode(DateTime.utc(2026), _iso)!.value, '2026-01-01T00:00:00.000000Z');
      final local = FluentTypeCodecs.encode(DateTime(2026, 1, 1, 1, 2, 3, 4), _iso)!.value as String;
      expect(local, matches(r'^2026-01-01T01:02:03\.004000$'));
      expect(const FluentIsoDateTimeConverter().toSql(DateTime.utc(2026, 1, 1, 0, 0, 0, 5)), '2026-01-01T00:00:00.005000Z');
    });

    test('order and range filters are right when microseconds appear', () async {
      final p = _CfgProvider('iso_sort', () => [FluentDbColumn.primary(), FluentDbColumn.text('label'), FluentDbColumn(name: 'at', type: FluentDbDataType.text, valueKind: FluentValueKind.dateTime)], config: _iso);
      await db.open([p]);
      final x = DateTime.utc(2026, 1, 1, 12, 0, 0, 123);
      final y = DateTime.utc(2026, 1, 1, 12, 0, 0, 123, 456);
      await p.save(p.row({'label': 'y', 'at': y}));
      await p.save(p.row({'label': 'x', 'at': x}));
      expect((await p.findAll(orderBy: 'at')).map((r) => r['label']), ['x', 'y']);
      expect((await p.find(where: FluentFilter.gt('at', x))).map((r) => r['label']), ['y']);
      expect((await p.find(where: FluentFilter.eq('at', x))).map((r) => r['label']), ['x']);
      expect((await p.findAll(orderBy: 'at')).map((r) => r['at']), [x, y]);
    });

    test('old three-digit values keep reading back and are reported once with the fix', () async {
      final p = _CfgProvider('iso_old', () => [FluentDbColumn.primary(), FluentDbColumn.text('label'), FluentDbColumn(name: 'at', type: FluentDbDataType.text, valueKind: FluentValueKind.dateTime)], config: _iso);
      await db.open([p]);
      await p.save(p.row({'label': 'new', 'at': DateTime.utc(2026, 1, 1, 12, 0, 0, 123, 456)}));
      await p.execute("INSERT INTO iso_old (label, at) VALUES ('old', '2026-01-01T12:00:00.123Z'), ('old2', '2026-01-01T12:00:00.500Z')");
      final rows = await p.findAll(orderBy: 'id');
      expect(rows.map((r) => r['at']), [DateTime.utc(2026, 1, 1, 12, 0, 0, 123, 456), DateTime.utc(2026, 1, 1, 12, 0, 0, 123), DateTime.utc(2026, 1, 1, 12, 0, 0, 500)]);
      await p.findAll();
      final issues = db.issues.where((i) => i.kind == FluentIssueKind.mappingValue && i.title.contains('three-digit')).toList();
      expect(issues, isNotEmpty);
      expect(issues.first.fix, contains('UPDATE'));
      // The statement of the hint rewrites old text to the new form.
      await p.execute(
        "UPDATE \"iso_old\" SET \"at\" = substr(\"at\", 1, instr(\"at\", '.') + 3) || '000' || substr(\"at\", instr(\"at\", '.') + 4) WHERE \"at\" GLOB '*.[0-9][0-9][0-9]' OR \"at\" GLOB '*.[0-9][0-9][0-9]Z'",
      );
      final fixed = await p.rawQuery('SELECT "at" FROM iso_old ORDER BY id');
      expect(fixed.map((r) => r['at']), ['2026-01-01T12:00:00.123456Z', '2026-01-01T12:00:00.123000Z', '2026-01-01T12:00:00.500000Z']);
    });

    test('isShortIso only matches the old form', () {
      expect(FluentTypeCodecs.isShortIso('2026-01-01T12:00:00.123Z'), isTrue);
      expect(FluentTypeCodecs.isShortIso('2026-01-01T12:00:00.123'), isTrue);
      expect(FluentTypeCodecs.isShortIso('2026-01-01T12:00:00.123000Z'), isFalse);
      expect(FluentTypeCodecs.isShortIso('2026-01-01T12:00:00Z'), isFalse);
      expect(FluentTypeCodecs.isShortIso('hello'), isFalse);
    });
  });

  group('38 names that are not plain identifiers', () {
    late _CfgProvider p;
    setUp(() async {
      p = _CfgProvider('space_cols', () => [FluentDbColumn.primary(), FluentDbColumn.text('first name')]);
      await db.open([p]);
      await p.save(p.row({'first name': 'ann'}));
    });

    test('an unquoted name in a filter points to quoting', () async {
      await expectLater(
        p.find(where: FluentFilter.eq('first name', 'ann')),
        throwsA(isA<FluentQueryException>().having((e) => e.hint, 'hint', allOf(contains('quoted'), contains('first name')))),
      );
      expect(await p.find(where: FluentFilter.eq('"first name"', 'ann')), hasLength(1));
    });

    test('an unquoted name in orderBy points to quoting, a quoted one works', () async {
      await expectLater(
        p.findAll(orderBy: 'first name DESC'),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('\'"first name"\''))),
      );
      expect(await p.findAll(orderBy: '"first name" DESC'), hasLength(1));
    });

    test('other invalid orderBy terms keep the general hint only', () async {
      await expectLater(
        p.findAll(orderBy: 'id; DROP TABLE x'),
        throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNot(contains('must be quoted')))),
      );
    });
  });
}
