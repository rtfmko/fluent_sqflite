import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

enum _Level { low, high }

class _Post extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

void main() {
  setUpFluentTests();

  group('comparison operators', () {
    test('every operator builds a quoted clause with one placeholder', () {
      expect(FluentFilter.eq('a', 1).whereClause, '"a" = ?');
      expect(FluentFilter.notEq('a', 1).whereClause, '"a" != ?');
      expect(FluentFilter.gt('a', 1).whereClause, '"a" > ?');
      expect(FluentFilter.gte('a', 1).whereClause, '"a" >= ?');
      expect(FluentFilter.lt('a', 1).whereClause, '"a" < ?');
      expect(FluentFilter.lte('a', 1).whereClause, '"a" <= ?');
      expect(FluentFilter.gte('a', 1).whereArgs, [1]);
      expect(FluentFilter.lte('a', 1).whereArgs, [1]);
    });

    test('null is turned into IS NULL / IS NOT NULL', () {
      expect(FluentFilter.eq('a', null).whereClause, '"a" IS NULL');
      expect(FluentFilter.eq('a', null).whereArgs, isEmpty);
      expect(FluentFilter.notEq('a', null).whereClause, '"a" IS NOT NULL');
      expect(FluentFilter.isNull('a').whereClause, '"a" IS NULL');
      expect(FluentFilter.isNotNull('a').whereClause, '"a" IS NOT NULL');
    });

    test('between has two arguments in order', () {
      final f = FluentFilter.between('a', 1, 5);
      expect(f.whereClause, '"a" BETWEEN ? AND ?');
      expect(f.whereArgs, [1, 5]);
    });

    test('values are converted to their stored form when SQL is read', () {
      final when = DateTime.fromMillisecondsSinceEpoch(5000);
      expect(FluentFilter.eq('a', true).whereArgs, [1]);
      expect(FluentFilter.eq('a', false).whereArgs, [0]);
      expect(FluentFilter.gt('a', when).whereArgs, [5000]);
      expect(FluentFilter.eq('a', _Level.high).whereArgs, ['high']);
      expect(FluentFilter.eq('a', const Duration(seconds: 2)).whereArgs, [2000000]);
    });

    test('an explicit table config decides the stored form (ISO text)', () {
      final when = DateTime.utc(2026, 1, 2, 3, 4, 5);
      const iso = FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);
      expect(FluentFilter.eq('a', when, config: iso).whereArgs, [fluentIsoText(when)]);
      expect(FluentFilter.between('a', when, when, config: iso).whereArgs, [fluentIsoText(when), fluentIsoText(when)]);
      const indexes = FluentTableConfig(storeEnumsAsNames: false);
      expect(FluentFilter.eq('a', _Level.high, config: indexes).whereArgs, [1]);
      expect(FluentFilter.inList('a', [_Level.low, _Level.high], config: indexes).whereArgs, [0, 1]);
      expect(FluentFilter.notInList('a', [_Level.high], config: indexes).whereArgs, [1]);
      expect(FluentFilter.notEq('a', _Level.high, config: indexes).whereArgs, [1]);
      expect(FluentFilter.gt('a', _Level.high, config: indexes).whereArgs, [1]);
      expect(FluentFilter.lt('a', _Level.high, config: indexes).whereArgs, [1]);
    });

    test('values that SQLite cannot store are refused when the filter is read', () {
      expect(() => FluentFilter.eq('a', Object()).whereArgs, throwsA(isA<FluentArgumentException>().having((e) => e.code, 'code', FluentErrorCode.unsupportedValue)));
      expect(() => FluentFilter.eq('a', double.nan).whereArgs, returnsNormally); // NaN is allowed in queries
    });

    test('whereArgs cannot be changed', () {
      final args = FluentFilter.eq('a', 1).whereArgs;
      expect(() => args.add(2), throwsUnsupportedError);
      expect(() => args[0] = 2, throwsUnsupportedError);
      expect(() => args.length = 0, throwsUnsupportedError);
      expect(() => args.clear(), throwsUnsupportedError);
    });

    test('a filter without arguments has an empty const list', () {
      expect(FluentFilter.isNull('a').whereArgs, isEmpty);
      expect(const FluentFilter('x = 1').whereArgs, isEmpty);
      expect(const FluentFilter('x = ?', [3]).whereArgs, [3]);
    });
  });

  group('column names', () {
    test('plain names are quoted, expressions and dotted names are left alone', () {
      expect(FluentFilter.eq('order', 1).whereClause, '"order" = ?');
      expect(FluentFilter.eq('lower(name)', 'a').whereClause, 'lower(name) = ?');
      expect(FluentFilter.eq('t.id', 1).whereClause, 't.id = ?');
      expect(FluentFilter.isNull('a b').whereClause, 'a b IS NULL');
    });

    test('an already quoted name stays and still knows its column for conversion', () {
      final f = FluentFilter.eq('"my col"', true);
      expect(f.whereClause, '"my col" = ?');
      expect((f.whereArgs as FluentFilterArgs).columnAt(0), 'my col');
      expect((FluentFilter.eq('"a""b"', 1).whereArgs as FluentFilterArgs).columnAt(0), 'a"b');
      expect((FluentFilter.eq('lower(a)', 1).whereArgs as FluentFilterArgs).columnAt(0), isNull);
      expect((FluentFilter.eq('plain', 1).whereArgs as FluentFilterArgs).columnAt(0), 'plain');
    });

    test('unicode names are not plain identifiers and are not quoted', () {
      expect('имя'.isPlainIdentifier, isFalse);
      expect(FluentFilter.eq('имя', 1).whereClause, 'имя = ?');
      expect('имя'.quotedIdentifier, '"имя"');
    });
  });

  group('lists', () {
    test('inList builds one placeholder per value', () {
      final f = FluentFilter.inList('a', [1, 2, 3]);
      expect(f.whereClause, '"a" IN (?, ?, ?)');
      expect(f.whereArgs, [1, 2, 3]);
      expect(FluentFilter.notInList('a', [1]).whereClause, '"a" NOT IN (?)');
    });

    test('an empty list never matches (IN) or always matches (NOT IN)', () {
      expect(FluentFilter.inList('a', []).whereClause, '1 = 0');
      expect(FluentFilter.notInList('a', []).whereClause, '1 = 1');
      expect(FluentFilter.inList('a', []).whereArgs, isEmpty);
    });

    test('a list up to 900 values binds its arguments in order', () {
      final values = List<Object>.generate(900, (i) => i);
      final f = FluentFilter.inList('a', values);
      expect('?'.allMatches(f.whereClause), hasLength(900));
      expect(f.whereArgs.length, 900);
      expect(f.whereArgs.first, 0);
      expect(f.whereArgs.last, 899);
    });

    test('a longer list is left to the provider (a temporary table, never more than 900 arguments)', () {
      final values = List<Object>.generate(1500, (i) => i);
      final f = FluentFilter.inList('a', values);
      expect(f.whereArgs, isEmpty);
      final FluentListCondition list = f.deferred.single as FluentListCondition;
      expect(FluentFilterArgs.rawOf(list.values), values);
      expect(list.negated, isFalse);
      expect((FluentFilter.notInList('a', values).deferred.single as FluentListCondition).negated, isTrue);
    });
  });

  group('text patterns', () {
    test('like passes the pattern unchanged', () {
      final f = FluentFilter.like('a', '50%_x');
      expect(f.whereClause, '"a" LIKE ?');
      expect(f.whereArgs, ['50%_x']);
    });

    test('contains / startsWith / endsWith escape the wildcards of the text', () {
      expect(FluentFilter.contains('a', '50%_\\').whereArgs, [r'%50\%\_\\%']);
      expect(FluentFilter.startsWith('a', 'x_').whereArgs, [r'x\_%']);
      expect(FluentFilter.endsWith('a', 'x%').whereArgs, [r'%x\%']);
      expect(FluentFilter.contains('a', 'x').whereClause, '"a" LIKE ? ESCAPE \'\\\'');
    });

    test('an empty text matches everything non-null', () {
      expect(FluentFilter.contains('a', '').whereArgs, ['%%']);
      expect(FluentFilter.startsWith('a', '').whereArgs, ['%']);
    });
  });

  group('and / or', () {
    test('combines with parentheses and concatenates the arguments in order', () {
      final f = FluentFilter.eq('a', 1).and(FluentFilter.eq('b', 2));
      expect(f.whereClause, '("a" = ?) AND ("b" = ?)');
      expect(f.whereArgs, [1, 2]);
      final g = FluentFilter.eq('a', 1).or(FluentFilter.eq('b', 2)).and(FluentFilter.eq('c', 3));
      expect(g.whereClause, '(("a" = ?) OR ("b" = ?)) AND ("c" = ?)');
      expect(g.whereArgs, [1, 2, 3]);
    });

    test('empty is the identity', () {
      final a = FluentFilter.eq('a', 1);
      expect(FluentFilter.empty.and(a), same(a));
      expect(a.and(FluentFilter.empty), same(a));
      expect(FluentFilter.empty.or(a), same(a));
      expect(a.or(FluentFilter.empty), same(a));
      expect(FluentFilter.empty.and(FluentFilter.empty).whereClause, '');
      expect(FluentFilter.empty.whereArgs, isEmpty);
    });

    test('the converted arguments still use their column after combining', () {
      final f = FluentFilter.eq('flag', true).and(FluentFilter.eq('n', 1)).or(FluentFilter.isNull('x'));
      expect(f.whereArgs, [1, 1]);
      final args = f.whereArgs as FluentFilterArgs;
      expect(args.columnAt(0), 'flag');
      expect(args.columnAt(1), 'n');
    });

    test('plain argument lists combine with column-aware ones', () {
      final a = const FluentFilter('x = ?', [true]).and(FluentFilter.eq('y', 5));
      final args = a.whereArgs as FluentFilterArgs;
      expect(args.raw, [true, 5]);
      expect(args.columnAt(0), isNull);
      expect(args.columnAt(1), 'y');
      expect(a.whereArgs, [1, 5]);
      final b = FluentFilter.eq('y', 5).and(const FluentFilter('x = ?', [false]));
      expect((b.whereArgs as FluentFilterArgs).columnAt(0), 'y');
      expect((b.whereArgs as FluentFilterArgs).columnAt(1), isNull);
      final c = const FluentFilter('x = ?', [1]).and(const FluentFilter('z = ?', [2]));
      expect((c.whereArgs as FluentFilterArgs).columns, isEmpty);
      expect(c.whereArgs, [1, 2]);
    });

    test('deep nesting keeps the structure and every argument', () {
      FluentFilter f = FluentFilter.eq('a', 0);
      for (int i = 1; i < 200; i++) {
        f = i.isEven ? f.and(FluentFilter.eq('a', i)) : f.or(FluentFilter.eq('a', i));
      }
      expect(f.whereArgs.length, 200);
      expect(f.whereArgs, List<int>.generate(200, (i) => i));
      expect('?'.allMatches(f.whereClause), hasLength(200));
    });
  });

  group('FluentFilterArgs', () {
    test('concat returns the other side when one is empty', () {
      final b = [1, 2];
      expect(identical(FluentFilterArgs.concat(const [], b), b), isTrue);
      expect(identical(FluentFilterArgs.concat(b, const []), b), isTrue);
      expect(FluentFilterArgs.concat(const [], const []), isEmpty);
    });

    test('rawOf unwraps, plain lists pass through', () {
      expect(FluentFilterArgs.rawOf(FluentFilterArgs([true])), [true]);
      final plain = [1];
      expect(identical(FluentFilterArgs.rawOf(plain), plain), isTrue);
    });

    test('the raw values are kept and the sql values are converted', () {
      final args = FluentFilterArgs([true, 'x', null]);
      expect(args.raw, [true, 'x', null]);
      expect(args, [1, 'x', null]);
      expect(args.length, 3);
      expect(args.columnAt(0), isNull);
    });

    test('one column per value is required', () {
      expect(() => FluentFilterArgs([1, 2], ['a']), throwsA(isA<AssertionError>()));
    });

    test('raw and columns are unmodifiable copies', () {
      final source = <Object?>[1];
      final args = FluentFilterArgs(source, ['a']);
      source.add(2);
      expect(args.raw, [1]);
      expect(() => args.raw.add(1), throwsUnsupportedError);
      expect(() => args.columns.add('x'), throwsUnsupportedError);
    });
  });

  group('deferred conditions', () {
    test('related / search / ids produce markers and keep the conditions', () {
      final f = FluentFilter.related<_Post>('comments');
      expect(f.whereClause, '\u00010\u0001');
      expect(f.deferred, hasLength(1));
      expect(f.deferred.single, isA<FluentRelatedCondition>());
      expect(FluentFilter.search('hello').deferred.single, isA<FluentSearchCondition>());
      expect(FluentFilter.ids([1, 2]).deferred.single, isA<FluentKeyCondition>());
      expect(f.whereArgs, isEmpty);
    });

    test('and / or renumber the markers of the second filter', () {
      final f = FluentFilter.related<_Post>('a').and(FluentFilter.search('x')).or(FluentFilter.ids([1]));
      expect(f.whereClause, '((\u00010\u0001) AND (\u00011\u0001)) OR (\u00012\u0001)');
      expect(f.deferred.map((c) => c.runtimeType), [FluentRelatedCondition, FluentSearchCondition, FluentKeyCondition]);
    });

    test('mixing a plain filter with a deferred one leaves the plain clause alone', () {
      final f = FluentFilter.eq('a', 1).and(FluentFilter.search('x'));
      expect(f.whereClause, '("a" = ?) AND (\u00010\u0001)');
      final g = FluentFilter.search('x').and(FluentFilter.eq('a', 1));
      expect(g.whereClause, '(\u00010\u0001) AND ("a" = ?)');
      expect(g.whereArgs, [1]);
    });

    test('description shows the conditions instead of the markers', () {
      final f = FluentFilter.related<_Post>('comments', FluentFilter.eq('ok', true)).and(FluentFilter.notRelated<_Post>('tags')).and(FluentFilter.search('x'));
      expect(f.description, '((related<_Post>(comments: "ok" = ?)) AND (notRelated<_Post>(tags))) AND (search(?))');
      expect(FluentFilter.eq('a', 1).description, '"a" = ?');
    });

    test('relatedCount description shows min and max; plain related has no type suffix', () {
      expect(FluentFilter.relatedCount<_Post>('c', min: 1, max: 3).description, 'relatedCount<_Post>(c, min: 1, max: 3)');
      expect(FluentFilter.related('c').description, 'related(c)');
      expect(FluentFilter.ids([1, 2, 3]).description, 'ids(3)');
    });

    test('fingerprints separate different conditions', () {
      String key(FluentFilter f) => fluentFilterKey(f);
      expect(key(FluentFilter.search('a')), key(FluentFilter.search('a')));
      expect(key(FluentFilter.search('a')), isNot(key(FluentFilter.search('b'))));
      expect(key(FluentFilter.search('a')), isNot(key(FluentFilter.search('a', prefix: false))));
      expect(key(FluentFilter.ids([1, 2])), isNot(key(FluentFilter.ids([2, 1]))));
      expect(key(FluentFilter.related<_Post>('a')), isNot(key(FluentFilter.related<_Post>('b'))));
      expect(key(FluentFilter.related<_Post>('a')), isNot(key(FluentFilter.notRelated<_Post>('a'))));
      expect(key(FluentFilter.related<_Post>('a')), isNot(key(FluentFilter.related<FluentStorable>('a'))));
      expect(key(FluentFilter.related<_Post>('a', FluentFilter.eq('x', 1))), isNot(key(FluentFilter.related<_Post>('a', FluentFilter.eq('x', 2)))));
      expect(key(FluentFilter.relatedCount<_Post>('a', min: 1)), isNot(key(FluentFilter.relatedCount<_Post>('a', min: 2))));
      expect(key(FluentFilter.relatedCount<_Post>('a', max: 1)), isNot(key(FluentFilter.relatedCount<_Post>('a', min: 1))));
    });

    test('the key of a null or empty filter is empty', () {
      expect(fluentFilterKey(null), '');
      expect(fluentFilterKey(FluentFilter.empty), '');
      expect(fluentFilterKey(FluentFilter.eq('a', 1)), isNotEmpty);
    });

    test('values in the key keep their type: 1, "1", 1.0 and true are different', () {
      final keys = {for (final Object v in [1, '1', 1.0, true]) fluentFilterKey(FluentFilter.eq('a', v))};
      expect(keys, hasLength(4));
    });

    test('search words split on everything that is not a letter, digit or mark (unicode aware)', () {
      expect(const FluentSearchCondition('hello, wörld-42!').words, ['hello', 'wörld', '42']);
      expect(const FluentSearchCondition('   ').words, isEmpty);
      expect(const FluentSearchCondition('привет мир').words, ['привет', 'мир']);
      expect(const FluentSearchCondition('').words, isEmpty);
    });
  });

  group('marker', () {
    test('the internal marker matches the deferred placeholders and captures their number', () {
      final matches = FluentFilterInternals.marker.allMatches('a 3 b 12').toList();
      expect(matches.map((m) => m[1]), ['3', '12']);
      expect(FluentFilterInternals.marker.hasMatch('plain ? text 1'), isFalse);
    });
  });

  group('fluentValueKey', () {
    test('lists and keys are order-aware / order-free as documented', () {
      expect(fluentValueKey([1, 2]), isNot(fluentValueKey([2, 1])));
      expect(fluentValueKey(FluentKey({'a': 1, 'b': 2})), fluentValueKey(FluentKey({'b': 2, 'a': 1})));
      expect(fluentValueKey(FluentKey({'a': 1})), isNot(fluentValueKey(FluentKey({'a': 2}))));
      expect(fluentValueKey(null), contains('Null'));
    });

    test('strings that look alike never collide (length prefix)', () {
      expect(fluentValueKey(['a,b']), isNot(fluentValueKey(['a', 'b'])));
      expect(fluentValueKey('a'), isNot(fluentValueKey('a ')));
    });

    test('plain values are keyed by value, other objects by identity', () {
      expect(fluentValueKey(DateTime.utc(2026)), fluentValueKey(DateTime.utc(2026)));
      expect(fluentValueKey(_Level.low), fluentValueKey(_Level.low));
      expect(fluentValueKey(BigInt.one), fluentValueKey(BigInt.one));
      expect(fluentValueKey(const Duration(seconds: 1)), fluentValueKey(const Duration(seconds: 1)));
      expect(fluentValueKey(Object()), isNot(fluentValueKey(Object())));
      final o = Object();
      expect(fluentValueKey(o), fluentValueKey(o));
    });
  });
}
