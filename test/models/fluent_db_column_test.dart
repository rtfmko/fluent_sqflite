import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';

enum Status { active, archived }

void main() {
  group('FluentDbColumn.sqlDefinition', () {
    test('primary key column is INTEGER PRIMARY KEY AUTOINCREMENT by default', () {
      expect(FluentDbColumn.primary().sqlDefinition, '"id" INTEGER PRIMARY KEY AUTOINCREMENT');
      expect(FluentDbColumn.primary(name: 'uid', isAutoIncrement: false).sqlDefinition, '"uid" INTEGER PRIMARY KEY');
    });

    test('constraints are rendered in a stable order', () {
      final column = FluentDbColumn(
        name: 'age',
        type: FluentDbDataType.integer,
        isNotNull: true,
        isUnique: true,
        defaultValue: 0,
        checkConstraint: 'age >= 0',
      );

      expect(column.sqlDefinition, '"age" INTEGER NOT NULL UNIQUE DEFAULT 0 CHECK (age >= 0)');
    });

    test('names that are SQL keywords are quoted', () {
      expect(FluentDbColumn.integer('order').sqlDefinition, '"order" INTEGER');
    });

    test('custom SQL with its own type is not prefixed with the column type', () {
      final column = FluentDbColumn(name: 'code', type: FluentDbDataType.text, customSql: 'TEXT NOT NULL');
      expect(column.sqlDefinition, '"code" TEXT NOT NULL');
    });

    test('custom SQL without a type gets the column type, and duplicated constraints are skipped', () {
      final column = FluentDbColumn(name: 'owner_id', type: FluentDbDataType.integer, isNotNull: true, customSql: 'NOT NULL REFERENCES users(id)');
      expect(column.sqlDefinition, '"owner_id" INTEGER NOT NULL REFERENCES users(id)');
    });

    test('invalid custom SQL type is rejected with a schema exception', () {
      expect(() => FluentDbColumn(name: 'x', type: FluentDbDataType.custom, customSql: 'VARCHAR(20)'), throwsA(isA<FluentSchemaException>()));
    });

    test('AUTOINCREMENT on a non-integer column is ignored instead of failing', () {
      final column = FluentDbColumn(name: 'uid', type: FluentDbDataType.text, isPrimaryKey: true, isAutoIncrement: true);
      expect(column.sqlDefinition, '"uid" TEXT PRIMARY KEY');
    });

    test('primary key clause can be left out for composite keys', () {
      final column = FluentDbColumn(name: 'day', type: FluentDbDataType.text, isPrimaryKey: true, isNotNull: true);
      expect(column.sqlDefinitionWith(inlinePrimaryKey: false), '"day" TEXT NOT NULL');
    });
  });

  group('Typed default values', () {
    test('plain Dart values are escaped automatically', () {
      expect(FluentDbColumn.text('status', defaultValue: "it's").sqlDefinition, '"status" TEXT DEFAULT \'it\'\'s\'');
      expect(FluentDbColumn.integer('n', defaultValue: 5).sqlDefinition, '"n" INTEGER DEFAULT 5');
      expect(FluentDbColumn.real('p', defaultValue: 1.5).sqlDefinition, '"p" REAL DEFAULT 1.5');
      expect(FluentDbColumn(name: 'e', type: FluentDbDataType.text, defaultValue: Status.archived).sqlDefinition, '"e" TEXT DEFAULT \'archived\'');
    });

    test('booleans become 0/1 and get a CHECK guard', () {
      expect(FluentDbColumn.boolean('done', defaultValue: true).sqlDefinition, '"done" INTEGER DEFAULT 1 CHECK ("done" IN (0, 1))');
    });

    test('SQL expressions are inserted in parentheses', () {
      final column = FluentDbColumn.text('created').copyWith(defaultValue: FluentSqlExpression.currentTimestamp);
      expect(column.sqlDefinition, '"created" TEXT DEFAULT (CURRENT_TIMESTAMP)');
    });
  });

  group('Collation and converters', () {
    test('collation is rendered as COLLATE', () {
      expect(FluentDbColumn.text('email', collation: FluentCollation.noCase).sqlDefinition, '"email" TEXT COLLATE NOCASE');
    });

    test('converted column takes its type from the converter', () {
      final column = FluentDbColumn.converted('status', const FluentEnumConverter(Status.values));
      expect(column.type, FluentDbDataType.text);
      expect(column.converter, isNotNull);
      expect(FluentDbColumn.converted('at', const FluentEpochDateTimeConverter()).type, FluentDbDataType.integer);
    });
  });

  group('FluentDbColumn.copyWith', () {
    test('returns a new column and leaves the original untouched', () {
      final original = FluentDbColumn.integer('user_id');
      final linked = original.copyWith(customSql: 'REFERENCES users(id)', indexed: true);

      expect(linked, isNot(same(original)));
      expect(linked.indexed, isTrue);
      expect(linked.sqlDefinition, '"user_id" INTEGER REFERENCES users(id)');
      expect(original.indexed, isFalse);
      expect(original.customSql, isNull);
      expect(original.sqlDefinition, '"user_id" INTEGER');
    });
  });
}
