import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';

enum Color3 { red, green, blue }

void main() {
  group('Identifiers', () {
    test('quotedIdentifier quotes and escapes', () {
      expect('order'.quotedIdentifier, '"order"');
      expect('we"ird'.quotedIdentifier, '"we""ird"');
    });

    test('quotedIfPlain leaves expressions untouched', () {
      expect('name'.quotedIfPlain, '"name"');
      expect('lower(name)'.quotedIfPlain, 'lower(name)');
      expect('t.id'.quotedIfPlain, 't.id');
    });

    test('FluentFilter quotes plain column names', () {
      expect(FluentFilter.eq('order', 1).whereClause, '"order" = ?');
      expect(FluentFilter.eq('lower(name)', 'a').whereClause, 'lower(name) = ?');
      expect(FluentFilter.inList('group', [1, 2]).whereClause, '"group" IN (?, ?)');
    });
  });

  group('fluentSqlLiteral', () {
    test('renders every supported value type', () {
      expect(fluentSqlLiteral(null), 'NULL');
      expect(fluentSqlLiteral(true), '1');
      expect(fluentSqlLiteral(false), '0');
      expect(fluentSqlLiteral(42), '42');
      expect(fluentSqlLiteral(2.5), '2.5');
      expect(fluentSqlLiteral("O'Hara"), "'O''Hara'");
      expect(fluentSqlLiteral(Color3.green), "'green'");
      expect(fluentSqlLiteral(DateTime.fromMillisecondsSinceEpoch(1000)), '1000');
      expect(fluentSqlLiteral(const FluentSqlExpression('CURRENT_DATE')), '(CURRENT_DATE)');
    });
  });

  group('FluentKey', () {
    test('equality ignores construction style', () {
      expect(FluentKey({'a': 1, 'b': 'x'}), FluentKey({'a': 1, 'b': 'x'}));
      expect(FluentKey({'a': 1, 'b': 'x'}).hashCode, FluentKey({'a': 1, 'b': 'x'}).hashCode);
      expect(FluentKey.single('id', 5), FluentKey({'id': 5}));
      expect(FluentKey({'a': 1}), isNot(FluentKey({'a': 2})));
    });

    test('exposes columns, completeness and a matching filter', () {
      final key = FluentKey({'user_id': 7, 'day': '2026-10-20'});

      expect(key.columns, ['user_id', 'day']);
      expect(key.isComposite, isTrue);
      expect(key.isComplete, isTrue);
      expect(key['day'], '2026-10-20');
      expect(key.filter.whereClause, '("user_id" = ?) AND ("day" = ?)');
      expect(key.filter.whereArgs, [7, '2026-10-20']);
      expect(FluentKey({'a': null}).isComplete, isFalse);
    });

    test('an empty key is rejected with a hint', () {
      expect(() => FluentKey({}), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', isNotNull)));
    });
  });

  group('FluentIndex and FluentCheck', () {
    test('index SQL quotes names and supports unique and partial indexes', () {
      expect(const FluentIndex(['last_name', 'first_name']).createSql('users'), 'CREATE INDEX IF NOT EXISTS "idx_users_last_name_first_name" ON "users" ("last_name", "first_name");');
      expect(const FluentIndex.unique(['email']).createSql('users'), 'CREATE UNIQUE INDEX IF NOT EXISTS "uidx_users_email" ON "users" ("email");');
      expect(
        const FluentIndex(['created_at'], name: 'recent', where: 'deleted_at IS NULL').createSql('users'),
        'CREATE INDEX IF NOT EXISTS "recent" ON "users" ("created_at") WHERE deleted_at IS NULL;',
      );
    });

    test('check SQL with and without a name', () {
      expect(const FluentCheck('a > 0').sql, 'CHECK (a > 0)');
      expect(const FluentCheck('a > 0', name: 'positive').sql, 'CONSTRAINT "positive" CHECK (a > 0)');
    });
  });

  group('Converters', () {
    test('enum converter round-trips by name and reports unknown names', () {
      const converter = FluentEnumConverter(Color3.values);
      expect(converter.encode(Color3.blue), 'blue');
      expect(converter.decode('red'), Color3.red);
      expect(converter.encode(null), isNull);
      expect(() => converter.decode('purple'), throwsArgumentError);
    });

    test('date and json converters round-trip', () {
      final date = DateTime.utc(2026, 10, 20, 12);
      expect(const FluentIsoDateTimeConverter().decode(const FluentIsoDateTimeConverter().encode(date)), date);
      expect(const FluentEpochDateTimeConverter().encode(date), date.millisecondsSinceEpoch);

      const json = FluentJsonConverter<Map<String, dynamic>>();
      expect(json.encode({'a': 1}), '{"a":1}');
      expect(json.decode('{"a":1}'), {'a': 1});
    });
  });
}
