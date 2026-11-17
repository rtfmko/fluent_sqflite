import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Parent extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

class _Child extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

class _Link extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {};
}

class _Data {
  const _Data(this.v);
  final int v;
}

void main() {
  setUpFluentTests();

  group('FluentRelation shortcuts', () {
    test('one', () {
      final r = FluentRelation.one<_Parent, _Child>('child', (p) => null, foreignKey: 'fk', onDelete: FluentOnDelete.restrict, lazy: true);
      expect(r.type, FluentRelationType.one);
      expect(r.foreignKey, 'fk');
      expect(r.onDelete, FluentOnDelete.restrict);
      expect(r.lazy, isTrue);
      expect(r.isList, isFalse);
      expect(r.parentType, _Parent);
      expect(r.childType, _Child);
    });

    test('oneOwned', () {
      final r = FluentRelation.oneOwned<_Parent, _Child>('child', (p) => null, foreignKey: 'fk', via: 'owner', includeDeleted: true);
      expect(r.type, FluentRelationType.oneOwned);
      expect(r.via, 'owner');
      expect(r.includeDeleted, isTrue);
      expect(r.isList, isFalse);
    });

    test('many keeps the list options', () {
      final r = FluentRelation.many<_Parent, _Child>(
        'kids',
        (p) => <_Child>[],
        foreignKey: 'fk',
        via: 'v',
        onDelete: FluentOnDelete.cascade,
        keepMissing: true,
        orderBy: 'name',
        where: FluentFilter.eq('ok', true),
        limit: 3,
      );
      expect(r.type, FluentRelationType.many);
      expect(r.isList, isTrue);
      expect(r.keepMissing, isTrue);
      expect(r.orderBy, 'name');
      expect(r.where!.whereClause, '"ok" = ?');
      expect(r.limit, 3);
      expect(r.onDelete, FluentOnDelete.cascade);
    });

    test('manyToMany keeps the link table options', () {
      final r = FluentRelation.manyToMany<_Parent, _Child>('tags', (p) => <_Child>[], linkTable: 'lnk', linkParentKey: 'p', linkChildKey: 'c', lazy: true);
      expect(r.type, FluentRelationType.manyToMany);
      expect(r.linkTable, 'lnk');
      expect(r.linkParentKey, 'p');
      expect(r.linkChildKey, 'c');
      expect(r.lazy, isTrue);
      expect(r.linkModel, isNull);
      expect(r.toString(), 'FluentRelation<_Parent, _Child>(tags, manyToMany)');
    });

    test('oneOf lists the allowed types and has a storable child', () {
      final r = FluentRelation.oneOf<_Parent>('target', (p) => null, types: [_Child, _Link], onDelete: FluentOnDelete.setNull);
      expect(r.type, FluentRelationType.oneOf);
      expect(r.types, [_Child, _Link]);
      expect(r.childType, FluentStorable);
      expect(r.onDelete, FluentOnDelete.setNull);
    });

    test('through points at a link model and keeps missing links', () {
      final r = FluentRelation.through<_Parent, _Link, _Child>('kids', (p) => <_Child>[], parentVia: 'a', childVia: 'b', orderBy: 'x', limit: 2, includeDeleted: true);
      expect(r.linkModel, _Link);
      expect(r.parentVia, 'a');
      expect(r.childVia, 'b');
      expect(r.keepMissing, isTrue);
      expect(r.orderBy, 'x');
      expect(r.limit, 2);
      expect(r.toString(), 'FluentRelation<_Parent, _Child>(kids, through _Link)');
    });

    test('auto passes every option on', () {
      final r = FluentRelation.auto<_Parent, _Child>('c', (p) => <_Child>[], foreignKey: 'fk', linkTable: 'l', onDelete: FluentOnDelete.cascade, lazy: true, keepMissing: true, orderBy: 'o', limit: 1);
      expect(r.foreignKey, 'fk');
      expect(r.linkTable, 'l');
      expect(r.lazy, isTrue);
      expect(r.keepMissing, isTrue);
      expect(r.limit, 1);
      expect(r.selectsList, isTrue);
    });
  });

  group('FluentException', () {
    test('constraint and query exceptions keep code, hint and cause', () {
      final c = FluentConstraintException('dup', code: FluentErrorCode.uniqueViolation, hint: 'h', cause: 'c');
      expect(c.code, FluentErrorCode.uniqueViolation);
      expect(c, isA<FluentException>());
      final q = FluentQueryException('bad sql', cause: 'root');
      expect(q.code, FluentErrorCode.sqlError);
      expect(q.cause, 'root');
    });

    test('argument exceptions name the argument', () {
      final e = FluentArgumentException('limit', 'must be positive', hint: 'use 1');
      expect(e.argument, 'limit');
      expect(e.message, 'Invalid limit: must be positive');
      expect(e.code, FluentErrorCode.invalidArgument);
    });

    test('toString shows type, code, hint and (redacted) cause', () {
      final e = FluentQueryException('oops', hint: 'try x', cause: 'deep');
      expect(e.toString(), 'FluentQueryException(sqlError): oops\n  Hint: try x\n  Cause: deep');
      expect(FluentQueryException('plain').toString(), 'FluentQueryException(sqlError): plain');
    });

    test('the stack trace is captured when none is given', () {
      expect(FluentQueryException('x').stackTrace.toString(), isNotEmpty);
      final given = StackTrace.fromString('given');
      expect(FluentQueryException('x', stackTrace: given).stackTrace, same(given));
    });
  });

  group('FluentRemoteResponse.isSuccess', () {
    test('is true for 2xx only', () {
      for (final int code in [200, 201, 204, 299]) {
        expect(FluentRemoteResponse<int>.failed(code).isSuccess, isTrue, reason: '$code');
      }
      for (final int code in [199, 300, 404, 500]) {
        expect(FluentRemoteResponse<int>.failed(code).isSuccess, isFalse, reason: '$code');
      }
      expect(const FluentRemoteResponse<int>([]).isSuccess, isTrue);
    });
  });

  group('FluentKey', () {
    test('needs a column, reports composite and completeness, prints itself', () {
      expect(() => FluentKey({}), throwsA(isA<FluentArgumentException>()));
      final single = FluentKey.single('id', 1);
      expect(single.isComposite, isFalse);
      expect(single.isComplete, isTrue);
      expect(single.columns, ['id']);
      expect(single['id'], 1);
      expect(single.toString(), 'FluentKey(id: 1)');
      final composite = FluentKey({'a': 1, 'b': null});
      expect(composite.isComposite, isTrue);
      expect(composite.isComplete, isFalse);
      expect(composite.toString(), 'FluentKey(a: 1, b: null)');
      expect(composite.filter.whereClause, '("a" = ?) AND ("b" IS NULL)');
    });

    test('equality ignores the order of the columns', () {
      expect(FluentKey({'a': 1, 'b': 2}), FluentKey({'b': 2, 'a': 1}));
      expect(FluentKey({'a': 1, 'b': 2}).hashCode, FluentKey({'b': 2, 'a': 1}).hashCode);
      expect(FluentKey({'a': 1}), isNot(FluentKey({'a': 2})));
      expect(FluentKey({'a': 1}) == Object(), isFalse);
    });

    test('the values map cannot be changed', () {
      final source = <String, Object?>{'a': 1};
      final key = FluentKey(source);
      source['a'] = 2;
      expect(key['a'], 1);
      expect(() => key.values['b'] = 1, throwsUnsupportedError);
    });
  });

  group('settings enums', () {
    test('journal mode and synchronous mode render their PRAGMA value', () {
      for (final SQLiteJournalMode m in SQLiteJournalMode.values) {
        expect(m.value, m.name.toUpperCase());
      }
      for (final SQLiteSynchronous s in SQLiteSynchronous.values) {
        expect(s.value, s.name.toUpperCase());
      }
      expect(SQLiteJournalMode.wal.value, 'WAL');
      expect(SQLiteSynchronous.full.value, 'FULL');
    });
  });

  group('FluentConverter', () {
    test('encode keeps null and acceptsValue checks the Dart type', () {
      const c = FluentEpochDateTimeConverter();
      expect(c.encode(null), isNull);
      expect(c.encode(DateTime.fromMillisecondsSinceEpoch(5)), 5);
      expect(c.acceptsValue(DateTime(2026)), isTrue);
      expect(c.acceptsValue('x'), isFalse);
      expect(c.acceptsValue(null), isFalse);
    });

    test('the JSON converter encodes, decodes and builds typed objects', () {
      const plain = FluentJsonConverter<Map<String, dynamic>>();
      expect(plain.sqlType, FluentDbDataType.text);
      expect(plain.toSql({'a': 1}), '{"a":1}');
      expect(plain.fromSql('{"a":1}'), {'a': 1});
      final typed = FluentJsonConverter<_Data>(fromJson: (json) => _Data((json! as Map<String, dynamic>)['v'] as int));
      expect(typed.fromSql('{"v":7}').v, 7);
      expect(() => plain.fromSql('not json'), throwsFormatException);
      expect(() => plain.fromSql('[1]'), throwsA(isA<TypeError>()));
    });
  });

  group('schema history', () {
    test('an entry prints its result, duration, changes and error', () {
      final at = DateTime.utc(2026, 1, 2);
      final ok = FluentSchemaHistoryEntry(table: 't', fromRevision: 1, toRevision: 2, changes: const ['add a', 'drop b'], success: true, appliedAt: at, durationMs: 12);
      expect(ok.toString(), '${at.toIso8601String()} t r1→r2 OK (12ms)\n    - add a\n    - drop b');
      final failed = FluentSchemaHistoryEntry(table: 't', fromRevision: 2, toRevision: 2, changes: const [], success: false, appliedAt: at, error: 'boom');
      expect(failed.toString(), '${at.toIso8601String()} t r2→r2 FAILED (0ms)\n    error: boom');
    });

    test('the report lists the tables and the history', () {
      final at = DateTime.utc(2026, 1, 2);
      final report = FluentSchemaReport(
        database: 'main',
        tables: [
          FluentTableSnapshot(table: 'notes', revision: 1, columns: {'id': 'INTEGER'}, key: ['id']),
        ],
        history: [FluentSchemaHistoryEntry(table: 'notes', fromRevision: 0, toRevision: 1, changes: const ['create'], success: true, appliedAt: at)],
      );
      final text = report.toString();
      expect(text, startsWith('=== Schema of "main" ===\nnotes (revision 1)'));
      expect(text, contains('--- history (newest first) ---'));
      expect(text, contains('notes r0→r1 OK'));
      expect(const FluentSchemaReport(database: 'e', tables: [], history: []).toString(), '=== Schema of "e" ===\n--- history (newest first) ---\n');
    });
  });

  group('FluentDbColumn rules', () {
    test('system columns', () {
      expect(FluentDbColumn.systemMetadata().name, '_fs_metadata');
      expect(FluentDbColumn.systemMetadata().autoCorrectAllowed, isFalse);
      final expiry = FluentDbColumn.systemExpiryDate('exp');
      expect(expiry.type, FluentDbDataType.integer);
      expect(expiry.autoCorrectAllowed, isFalse);
      final soft = FluentDbColumn.systemSoftDelete('gone');
      expect(soft.valueKind, FluentValueKind.dateTime);
      expect(soft.autoCorrectAllowed, isFalse);
      expect(FluentDbColumn.systemColumns('exp').map((c) => c.name), ['_fs_metadata', 'exp']);
    });

    test('rules come from the flags and from custom SQL', () {
      final plain = FluentDbColumn.text('a');
      expect(plain.effectiveNotNull, isFalse);
      expect(plain.effectiveUnique, isFalse);
      expect(plain.effectivePrimaryKey, isFalse);
      expect(plain.effectiveDefault, isFalse);
      expect(plain.hasExpressionDefault, isFalse);

      final flags = FluentDbColumn(name: 'a', type: FluentDbDataType.text, isNotNull: true, isUnique: true, isPrimaryKey: true, defaultValue: 'x');
      expect(flags.effectiveNotNull, isTrue);
      expect(flags.effectiveUnique, isTrue);
      expect(flags.effectivePrimaryKey, isTrue);
      expect(flags.effectiveDefault, isTrue);

      final custom = FluentDbColumn(name: 'a', type: FluentDbDataType.custom, customSql: 'text  not   null unique primary key default (lower(1))');
      expect(custom.effectiveNotNull, isTrue);
      expect(custom.effectiveUnique, isTrue);
      expect(custom.effectivePrimaryKey, isTrue);
      expect(custom.effectiveDefault, isTrue);
      expect(custom.hasExpressionDefault, isTrue);
      expect(FluentDbColumn(name: 'a', type: FluentDbDataType.custom, customSql: 'TEXT DEFAULT CURRENT_TIMESTAMP').hasExpressionDefault, isTrue);
      expect(FluentDbColumn(name: 'a', type: FluentDbDataType.custom, customSql: "TEXT DEFAULT 'x'").hasExpressionDefault, isFalse);
      expect(FluentDbColumn(name: 'a', type: FluentDbDataType.text, defaultValue: FluentSqlExpression.currentDate).hasExpressionDefault, isTrue);
    });

    test('withoutNotNull clears the flag and strips NOT NULL from custom SQL', () {
      expect(FluentDbColumn.text('a', isNotNull: true).withoutNotNull.isNotNull, isFalse);
      final custom = FluentDbColumn(name: 'a', type: FluentDbDataType.custom, customSql: 'TEXT NOT   NULL DEFAULT 1', isNotNull: true);
      final relaxed = custom.withoutNotNull;
      expect(relaxed.isNotNull, isFalse);
      expect(relaxed.customSql, 'TEXT DEFAULT 1');
      final noRule = FluentDbColumn(name: 'a', type: FluentDbDataType.custom, customSql: 'TEXT', isNotNull: true).withoutNotNull;
      expect(noRule.customSql, 'TEXT');
      expect(noRule.isNotNull, isFalse);
    });
  });

  group('constructors used at run time (not only as constants)', () {
    test('built from non-constant arguments', () {
      final cols = <String>['a', 'b'];
      expect(FluentIndex.unique(cols, name: 'n').unique, isTrue);
      expect(FluentIndex.unique(cols).columns, cols);
      final utc = <bool>[true];
      expect(FluentEpochDateTimeConverter(utc: utc.first).fromSql(0).isUtc, isTrue);
      final toUtc = <bool>[false];
      expect(FluentIsoDateTimeConverter(toUtc: toUtc.first).toSql(DateTime(2026)), fluentIsoText(DateTime(2026)));
      // ignore: prefer_const_constructors
      expect(FluentConflictPolicy<int>.keepServer().serverWins, isTrue);
      // ignore: prefer_const_constructors
      expect(FluentConflictPolicy<int>.keepLocal().serverWins, isFalse);
      final column = <String>['c'];
      expect(FluentAggregate.count(column.first).column, 'c');
    });
  });
}
