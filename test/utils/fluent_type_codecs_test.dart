import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/material.dart' show Color, Locale, TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

enum _Mood { happy, sad }

void main() {
  setUpFluentTests();

  const FluentTableConfig config = FluentTableConfig();
  const FluentTableConfig iso = FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);
  const FluentTableConfig indexes = FluentTableConfig(storeEnumsAsNames: false);

  ({Object value, String? tag, String? lost})? enc(Object v, [FluentTableConfig c = config]) => FluentTypeCodecs.encode(v, c);
  Object? dec(String tag, Object stored) => FluentTypeCodecs.decode(tag, stored);

  group('encode', () {
    test('strings, numbers and bytes pass through untagged', () {
      expect(enc('x'), (value: 'x', tag: null, lost: null));
      expect(enc(5), (value: 5, tag: null, lost: null));
      expect(enc(1.5), (value: 1.5, tag: null, lost: null));
      final bytes = Uint8List.fromList([1, 2]);
      expect(enc(bytes)!.value, same(bytes));
      expect(enc(bytes)!.tag, isNull);
    });

    test('bool becomes 0 / 1 with its tag', () {
      expect(enc(true), (value: 1, tag: 'bool', lost: null));
      expect(enc(false), (value: 0, tag: 'bool', lost: null));
    });

    test('DateTime: milliseconds by default, ISO text on request, UTC has its own tag', () {
      final local = DateTime(2026, 1, 2, 3, 4, 5, 6);
      final utc = DateTime.utc(2026, 1, 2, 3, 4, 5, 6);
      expect(enc(local)!.value, local.millisecondsSinceEpoch);
      expect(enc(local)!.tag, 'datetime');
      expect(enc(utc)!.value, utc.millisecondsSinceEpoch);
      expect(enc(utc)!.tag, 'datetime_utc');
      expect(enc(local, iso)!.value, fluentIsoText(local));
      expect(enc(utc, iso)!.value, fluentIsoText(utc));
      expect(enc(utc, iso)!.value, endsWith('Z'));
    });

    test('microseconds are reported as lost only in the timestamp format', () {
      final micro = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
      expect(enc(micro)!.lost, 'microseconds');
      expect(enc(micro, iso)!.lost, isNull);
      expect(enc(DateTime.utc(2026, 1, 2, 3, 4, 5, 6))!.lost, isNull);
      expect(enc(DateTime(2026, 1, 2, 3, 4, 5, 6, 7))!.lost, 'microseconds');
    });

    test('Duration, BigInt, Uri, Color, Locale, TimeOfDay', () {
      expect(enc(const Duration(milliseconds: 5)), (value: 5000, tag: 'duration', lost: null));
      expect(enc(BigInt.parse('123456789012345678901234567890')), (value: '123456789012345678901234567890', tag: 'bigint', lost: null));
      expect(enc(Uri.parse('https://x.y/a?b=c'))!.value, 'https://x.y/a?b=c');
      expect(enc(Uri.parse('https://x.y/a?b=c'))!.tag, 'uri');
      expect(enc(const Color(0xFF112233)), (value: 0xFF112233, tag: 'color', lost: null));
      expect(enc(const Locale('de', 'CH')), (value: 'de-CH', tag: 'locale', lost: null));
      expect(enc(const TimeOfDay(hour: 7, minute: 5)), (value: '07:05', tag: 'timeofday', lost: null));
    });

    test('RegExp: default flags store the pattern, other flags a JSON list', () {
      expect(enc(RegExp(r'a+')), (value: r'a+', tag: 'regexp', lost: null));
      final flagged = enc(RegExp(r'a+', caseSensitive: false, multiLine: true))!;
      expect(flagged.tag, 'regexp_flags');
      expect(jsonDecode(flagged.value as String), [r'a+', false, true, false, false]);
      expect(enc(RegExp('a', unicode: true))!.tag, 'regexp_flags');
      expect(enc(RegExp('a', dotAll: true))!.tag, 'regexp_flags');
    });

    test('Map and List become JSON text', () {
      expect(enc({'a': 1}), (value: '{"a":1}', tag: 'json', lost: null));
      expect(enc([1, 'x', null]), (value: '[1,"x",null]', tag: 'json', lost: null));
      expect(enc(<String, Object?>{}), (value: '{}', tag: 'json', lost: null));
      expect(enc({'ü': 'ö "q"'})!.value, '{"ü":"ö \\"q\\""}');
    });

    test('JSON that cannot be encoded throws JsonUnsupportedObjectError (the sanitizer reports it)', () {
      expect(() => enc({'d': Object()}), throwsA(isA<JsonUnsupportedObjectError>()));
      expect(() => enc([DateTime(2026)]), throwsA(isA<JsonUnsupportedObjectError>()));
    });

    test('enums by name or by index', () {
      expect(enc(_Mood.sad), (value: 'sad', tag: 'enum', lost: null));
      expect(enc(_Mood.sad, indexes), (value: 1, tag: 'enum', lost: null));
    });

    test('unknown types are not encoded', () {
      expect(enc(Object()), isNull);
      expect(enc(const Symbol('x')), isNull);
    });
  });

  group('decode', () {
    test('bool accepts numbers and common strings, keeps other values', () {
      expect(dec('bool', 1), true);
      expect(dec('bool', 0), false);
      expect(dec('bool', 2), true);
      expect(dec('bool', 0.0), false);
      expect(dec('bool', '1'), true);
      expect(dec('bool', 'TRUE'), true);
      expect(dec('bool', 'true'), true);
      expect(dec('bool', 'no'), false);
      expect(dec('bool', '0'), false);
      final bytes = Uint8List(1);
      expect(dec('bool', bytes), same(bytes));
    });

    test('datetime from milliseconds, numeric text, ISO text; malformed text is kept as is', () {
      final t = DateTime.utc(2026, 1, 2, 3, 4, 5, 6);
      expect(dec('datetime_utc', t.millisecondsSinceEpoch), t);
      expect((dec('datetime_utc', t.millisecondsSinceEpoch)! as DateTime).isUtc, isTrue);
      expect((dec('datetime', t.millisecondsSinceEpoch)! as DateTime).isUtc, isFalse);
      expect(dec('datetime_utc', '${t.millisecondsSinceEpoch}'), t);
      expect(dec('datetime_utc', t.toIso8601String()), t);
      expect(dec('datetime', t.toIso8601String()), t);
      expect(dec('datetime_utc', 1700000000000.0), DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
      expect(dec('datetime_utc', DateTime(2020)), DateTime(2020));
      expect(dec('datetime', 'not a date'), 'not a date');
      expect(dec('datetime', ''), '');
    });

    test('a local ISO text without a zone is read as local for "datetime", converted for "datetime_utc"', () {
      final local = DateTime(2026, 3, 4, 5, 6, 7);
      final stored = local.toIso8601String();
      expect(dec('datetime', stored), local);
      expect(dec('datetime_utc', stored), local.toUtc());
    });

    test('duration needs an int', () {
      expect(dec('duration', 1500000), const Duration(microseconds: 1500000));
      expect(dec('duration', 'x'), 'x');
      expect(dec('duration', 1.5), 1.5);
    });

    test('bigint parses text; garbage stays', () {
      expect(dec('bigint', '123456789012345678901234567890'), BigInt.parse('123456789012345678901234567890'));
      expect(dec('bigint', 12), BigInt.from(12));
      expect(dec('bigint', 'zz'), 'zz');
      expect(dec('bigint', BigInt.two), BigInt.two);
    });

    test('regexp and flagged regexp', () {
      expect((dec('regexp', r'a+')! as RegExp).pattern, r'a+');
      final flagged = dec('regexp_flags', jsonEncode([r'a+', false, true, true, true]))! as RegExp;
      expect(flagged.pattern, r'a+');
      expect(flagged.isCaseSensitive, isFalse);
      expect(flagged.isMultiLine, isTrue);
      expect(flagged.isUnicode, isTrue);
      expect(flagged.isDotAll, isTrue);
      final r = RegExp('x');
      expect(dec('regexp', r), same(r));
      expect(dec('regexp_flags', r), same(r));
    });

    test('malformed regexp data throws, it cannot be guessed', () {
      expect(() => dec('regexp', '('), throwsFormatException);
      expect(() => dec('regexp_flags', 'not json'), throwsFormatException);
      expect(() => dec('regexp_flags', '[1]'), throwsA(isA<Error>()));
    });

    test('uri keeps text that cannot be parsed', () {
      expect(dec('uri', 'https://a.b/c'), Uri.parse('https://a.b/c'));
      expect(dec('uri', 'http://[bad'), 'http://[bad');
      final u = Uri.parse('x');
      expect(dec('uri', u), same(u));
    });

    test('color needs an int', () {
      expect(dec('color', 0xFF112233), const Color(0xFF112233));
      expect(dec('color', 'red'), 'red');
    });

    test('locale keeps script and region', () {
      expect(dec('locale', 'en'), const Locale('en'));
      expect(dec('locale', 'de-CH'), const Locale('de', 'CH'));
      expect(dec('locale', 'de_CH'), const Locale('de', 'CH'));
      final hant = dec('locale', 'zh-Hant-TW')! as Locale;
      expect(hant.languageCode, 'zh');
      expect(hant.scriptCode, 'Hant');
      expect(hant.countryCode, 'TW');
      final script = dec('locale', 'sr-Latn')! as Locale;
      expect(script.scriptCode, 'Latn');
      expect(script.countryCode, isNull);
      expect((dec('locale', 'es-419')! as Locale).countryCode, '419');
      expect(dec('locale', 5), 5);
    });

    test('timeofday: HH:mm, missing parts become 0, other shapes stay', () {
      expect(dec('timeofday', '07:05'), const TimeOfDay(hour: 7, minute: 5));
      expect(dec('timeofday', 'xx:yy'), const TimeOfDay(hour: 0, minute: 0));
      expect(dec('timeofday', '7:5:3'), '7:5:3');
      expect(dec('timeofday', 'noon'), 'noon');
      expect(dec('timeofday', 5), 5);
    });

    test('json parses, and malformed JSON text stays text', () {
      expect(dec('json', '{"a":[1,2]}'), {'a': [1, 2]});
      expect(dec('json', '[1,'), '[1,');
      expect(dec('json', 'null'), 'null'); // a JSON null cannot be a value here
      expect(dec('json', 5), 5);
    });

    test('enum: without values the stored value stays, with values names and indexes both work', () {
      expect(dec('enum', 'sad'), 'sad');
      expect(FluentTypeCodecs.decode('enum', 'sad', enumValues: _Mood.values), _Mood.sad);
      expect(FluentTypeCodecs.decode('enum', 1, enumValues: _Mood.values), _Mood.sad);
      expect(FluentTypeCodecs.decode('enum', 'unknown', enumValues: _Mood.values), 'unknown');
      expect(FluentTypeCodecs.decode('enum', 9, enumValues: _Mood.values), 9);
    });

    test('an unknown tag returns the stored value', () {
      expect(dec('nonsense', 'x'), 'x');
      expect(dec('nonsense', 3), 3);
    });
  });

  group('round trips', () {
    final values = <Object>[
      true,
      false,
      DateTime.utc(2026, 5, 6, 7, 8, 9, 10),
      DateTime(2026, 5, 6, 7, 8, 9, 10),
      const Duration(hours: 5, microseconds: 3),
      BigInt.parse('-98765432109876543210'),
      RegExp(r'^a\d+$'),
      RegExp('x', caseSensitive: false),
      Uri.parse('https://example.com/a b?x=1#f'),
      const Color(0x80FF00FF),
      const Locale('pt', 'BR'),
      const TimeOfDay(hour: 23, minute: 59),
      {'a': 1, 'b': ['x', null]},
      <Object?>[1, 2, 3],
    ];

    for (final Object v in values) {
      for (final FluentTableConfig c in [config, iso]) {
        test('${v.runtimeType} ${v.toString().length > 30 ? '' : v} survives ${c.dateTimeFormat.name}', () {
          final e = enc(v, c)!;
          final back = dec(e.tag!, e.value);
          if (v is RegExp) {
            expect((back! as RegExp).pattern, v.pattern);
            expect((back as RegExp).isCaseSensitive, v.isCaseSensitive);
          } else {
            expect(back, v);
          }
        });
      }
    }
  });

  group('FluentSqlSanitizer', () {
    FluentArgumentException? refused(Object? value, {String? key, String? table, bool allowNaN = false}) {
      try {
        FluentSqlSanitizer.sanitize(value: value, config: config, key: key, tableName: table, allowNaN: allowNaN);
      } on FluentArgumentException catch (e) {
        return e;
      }
      return null;
    }

    test('null stays null without a type tag', () {
      final r = FluentSqlSanitizer.sanitize(value: null, config: config);
      expect(r.value, isNull);
      expect(r.metaType, isNull);
    });

    test('values are encoded and the tag is returned as metaType', () {
      expect(FluentSqlSanitizer.sanitize(value: true, config: config).value, 1);
      expect(FluentSqlSanitizer.sanitize(value: true, config: config).metaType, 'bool');
      expect(FluentSqlSanitizer.sanitize(value: 'x', config: config).metaType, isNull);
    });

    test('NaN is refused with a hint, unless allowed (queries)', () {
      final e = refused(double.nan, key: 'score')!;
      expect(e.code, FluentErrorCode.unsupportedValue);
      expect(e.message, contains('score'));
      expect(e.message, contains('NaN'));
      expect(e.hint, contains('null'));
      expect(refused(double.nan, allowNaN: true), isNull);
      expect(refused(double.infinity), isNull);
    });

    test('the column name falls back to the table name and then to "unknown"', () {
      expect(refused(double.nan, table: 'notes')!.message, contains('"notes"'));
      expect(refused(double.nan)!.message, contains('"unknown"'));
      expect(refused(double.nan, key: 'k', table: 't')!.message, contains('"k"'));
    });

    test('unsupported types are refused and point to converters and relations', () {
      final e = refused(Object(), key: 'thing')!;
      expect(e.code, FluentErrorCode.unsupportedValue);
      expect(e.message, contains('Object'));
      expect(e.hint, contains('FluentConverter'));
      expect(e.hint, contains('FluentRelation'));
    });

    test('JSON collections with unencodable content are refused with their own hint', () {
      final e = refused({'d': Object()}, key: 'meta')!;
      expect(e.message, contains('JSON'));
      expect(e.hint, contains('FluentJsonConverter'));
    });

    test('the value stays out of the message unless SQL arguments are shown', () {
      final secret = _Secret();
      expect(refused(secret)!.message, isNot(contains('s3cr3t')));
      FluentLog.configure(showSqlArguments: true);
      addTearDown(() => FluentLog.configure(showSqlArguments: false));
      expect(refused(secret)!.message, contains('s3cr3t'));
    });

    test('lost microseconds are reported once as a precisionLost issue with a hint', () {
      final issues = <FluentIssue>[];
      FluentLog.captureIssuesSync(issues, () {
        FluentSqlSanitizer.sanitize(value: DateTime.utc(2026, 1, 1, 0, 0, 0, 0, 5), config: config, tableName: 'notes', key: 'at');
      });
      expect(issues, hasLength(1));
      expect(issues.single.kind, FluentIssueKind.precisionLost);
      expect(issues.single.table, 'notes');
      expect(issues.single.subject, 'at');
      expect(issues.single.fix, contains('iso8601'));
      expect(issues.single.code, contains('FluentDateTimeFormat.iso8601'));
    });

    test('no precision issue for allowNaN (query) values, ISO format or whole milliseconds', () {
      final issues = <FluentIssue>[];
      FluentLog.captureIssuesSync(issues, () {
        FluentSqlSanitizer.sanitize(value: DateTime.utc(2026, 1, 1, 0, 0, 0, 0, 5), config: config, allowNaN: true);
        FluentSqlSanitizer.sanitize(value: DateTime.utc(2026, 1, 1, 0, 0, 0, 0, 5), config: iso, tableName: 't', key: 'k');
        FluentSqlSanitizer.sanitize(value: DateTime.utc(2026, 1, 1, 0, 0, 0, 7), config: config, tableName: 't', key: 'k');
      });
      expect(issues, isEmpty);
    });

    test('sanitizeValueOnly is the query form: NaN allowed, no precision issue', () {
      final issues = <FluentIssue>[];
      FluentLog.captureIssuesSync(issues, () {
        expect(FluentSqlSanitizer.sanitizeValueOnly(true, config), 1);
        expect(FluentSqlSanitizer.sanitizeValueOnly(null, config), isNull);
        expect(FluentSqlSanitizer.sanitizeValueOnly(DateTime.utc(2026, 1, 1, 0, 0, 0, 0, 5), config), isA<int>());
      });
      expect(issues, isEmpty);
    });
  });
}

class _Secret {
  @override
  String toString() => 's3cr3t';
}
