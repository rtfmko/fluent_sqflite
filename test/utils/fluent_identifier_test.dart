import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  group('FluentIdentifier', () {
    test('quotedIdentifier doubles embedded quotes and keeps everything else', () {
      expect('a'.quotedIdentifier, '"a"');
      expect(''.quotedIdentifier, '""');
      expect('a"b'.quotedIdentifier, '"a""b"');
      expect('"'.quotedIdentifier, '""""');
      expect('""'.quotedIdentifier, '""""""');
      expect('with space'.quotedIdentifier, '"with space"');
      expect('ünï-çødé 名前'.quotedIdentifier, '"ünï-çødé 名前"');
      expect("it's".quotedIdentifier, '"it\'s"');
      expect('semi;colon--'.quotedIdentifier, '"semi;colon--"');
      expect('a\nb'.quotedIdentifier, '"a\nb"');
    });

    test('a quoted identifier cannot be broken out of (injection)', () {
      const hostile = 'x"; DROP TABLE users; --';
      final quoted = hostile.quotedIdentifier;
      expect(quoted, '"x""; DROP TABLE users; --"');
      final inner = quoted.substring(1, quoted.length - 1);
      expect(inner.replaceAll('""', ''), isNot(contains('"')));
    });

    test('isPlainIdentifier accepts letters, digits and underscores, not starting with a digit', () {
      for (final String ok in ['a', 'A', '_', '_a1', 'abc_DEF_123', 'select']) {
        expect(ok.isPlainIdentifier, isTrue, reason: ok);
      }
      for (final String bad in ['', '1a', 'a b', 'a-b', 'a.b', 'a(b)', 'a"b', 'ä', 'a\n', ' a', 'a ']) {
        expect(bad.isPlainIdentifier, isFalse, reason: bad);
      }
    });

    test('quotedIfPlain quotes only plain names', () {
      expect('name'.quotedIfPlain, '"name"');
      expect('select'.quotedIfPlain, '"select"');
      expect('lower(name)'.quotedIfPlain, 'lower(name)');
      expect('t.id'.quotedIfPlain, 't.id');
      expect('"already"'.quotedIfPlain, '"already"');
      expect('a b'.quotedIfPlain, 'a b');
      expect(''.quotedIfPlain, '');
    });

    test('quotedKeys quotes the keys of a row and keeps the values and the order', () {
      final row = <String, Object?>{'a': 1, 'b c': null, 'd"e': 'x'};
      final quoted = row.quotedKeys;
      expect(quoted, {'"a"': 1, '"b c"': null, '"d""e"': 'x'});
      expect(quoted.keys.toList(), ['"a"', '"b c"', '"d""e"']);
      expect(<String, Object?>{}.quotedKeys, isEmpty);
    });

    test('quotedAll quotes every column', () {
      expect(['a', 'b c'].quotedAll, ['"a"', '"b c"']);
      expect(<String>[].quotedAll, isEmpty);
      expect({'x'}.quotedAll, ['"x"']);
    });
  });
}
