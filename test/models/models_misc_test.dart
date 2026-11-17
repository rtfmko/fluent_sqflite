import 'dart:convert';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

enum _Mood { happy, sad }

void main() {
  setUpFluentTests();

  group('FluentGroup', () {
    final DynamicProvider notes = DynamicProvider('notes', () => [FluentDbColumn.primary(name: 'id')]);
    final DynamicProvider tags = DynamicProvider('tags', () => [FluentDbColumn.primary(name: 'id')]);

    test('two providers on one table are refused with a hint', () {
      final other = DynamicProvider('notes', () => [FluentDbColumn.primary(name: 'id')]);
      expect(
        () => FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes, other]),
        throwsA(isA<FluentSchemaException>().having((e) => e.hint, 'hint', contains('unique table')).having((e) => e.message, 'message', contains('"notes"'))),
      );
    });

    test('the same provider listed twice is one provider', () {
      final group = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes, notes, tags]);
      expect(group.providerList, hasLength(2));
    });

    test('defaults', () {
      final group = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes]);
      expect(group.readOnly, isFalse);
      expect(group.inMemory, isFalse);
      expect(group.resetOnSchemaError, isFalse);
      expect(group.historyLimit, 100);
      expect(group.archiveRetention, const Duration(days: 30));
      expect(group.removedColumns, FluentColumnRemoval.archive);
      expect(group.autoRelationFallback, FluentRelationType.manyToMany);
      expect(group.directory, isNull);
      expect(group.onMigrationPlan, isNull);
    });

    test('copyWith replaces what is given and keeps the rest', () {
      Future<bool> plan(FluentMigrationPlan p) async => true;
      final group = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes], directory: '/x', onMigrationPlan: plan);
      final same = group.copyWith();
      expect(same.directory, '/x');
      expect(same.onMigrationPlan, same.onMigrationPlan);
      expect(same.config, group.config);
      expect(same.providerList, group.providerList);

      final changed = group.copyWith(
        config: FluentDbConfig.highIntegrity,
        readOnly: true,
        removedColumns: FluentColumnRemoval.drop,
        historyLimit: 5,
        resetOnSchemaError: true,
        autoRelationFallback: FluentRelationType.many,
        inMemory: true,
      );
      expect(changed.config, FluentDbConfig.highIntegrity);
      expect(changed.readOnly, isTrue);
      expect(changed.removedColumns, FluentColumnRemoval.drop);
      expect(changed.historyLimit, 5);
      expect(changed.resetOnSchemaError, isTrue);
      expect(changed.autoRelationFallback, FluentRelationType.many);
      expect(changed.inMemory, isTrue);
      expect(changed.dbKey, group.dbKey);
    });

    test('copyWith can set directory, archiveRetention and onMigrationPlan to null explicitly', () {
      Future<bool> plan(FluentMigrationPlan p) async => true;
      final group = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes], directory: '/x', onMigrationPlan: plan);
      final cleared = group.copyWith(directory: null, archiveRetention: null, onMigrationPlan: null);
      expect(cleared.directory, isNull);
      expect(cleared.archiveRetention, isNull);
      expect(cleared.onMigrationPlan, isNull);
      final set = cleared.copyWith(directory: '/y', archiveRetention: const Duration(days: 1), onMigrationPlan: plan);
      expect(set.directory, '/y');
      expect(set.archiveRetention, const Duration(days: 1));
      expect(set.onMigrationPlan, same(plan));
    });

    test('copyWith revalidates nothing new but keeps the providers', () {
      final group = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes, tags]);
      expect(group.copyWith(historyLimit: 1).providerList, group.providerList);
    });

    test('resolvePath: in memory, custom directory, default databases path', () async {
      expect(await FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes], inMemory: true).resolvePath(), ':memory:');
      final custom = await FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes], directory: 'some/dir').resolvePath();
      expect(custom.replaceAll(r'\', '/'), 'some/dir/db.db');
      final byDefault = await FluentGroup(dbKey: FluentDbKey('mine'), providerList: [notes]).resolvePath();
      expect(byDefault.replaceAll(r'\', '/'), endsWith('/mine.db'));
    });

    test('equality is by database name only', () {
      final a = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes]);
      final b = FluentGroup(dbKey: FluentDbKey('db'), providerList: [tags], readOnly: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(FluentGroup(dbKey: FluentDbKey('other'), providerList: [notes])));
      expect(a == Object(), isFalse);
    });

    test('toString shows key, providers, config and non-default flags', () {
      final a = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes, tags]);
      expect(a.toString(), startsWith('FluentGroup{dbKey: db, providerCount: 2, config: FluentDbConfig{'));
      expect(a.toString(), isNot(contains('readOnly')));
      expect(a.toString(), isNot(contains('directory')));
      final b = FluentGroup(dbKey: FluentDbKey('db'), providerList: [notes], directory: '/x', readOnly: true);
      expect(b.toString(), contains('directory: <path hidden>')); // a path: shown only with showSqlArguments
      expect(b.toString(), isNot(contains('/x')));
      expect(b.toString(), contains('readOnly: true'));
    });
  });

  group('FluentRedactedError / FluentLogRecord', () {
    final DateTime time = DateTime(2026, 1, 2, 3, 4, 5, 6);

    FluentLogRecord record(FluentLogLevel level, {Object? error, StackTrace? stack, String? tag, String? hint, Map<String, dynamic>? context, FluentIssue? issue}) =>
        FluentLogRecord(level: level, message: 'msg', time: time, tag: tag, hint: hint, context: context, error: error, stackTrace: stack, issue: issue);

    test('FluentRedactedError prints type and message', () {
      expect(const FluentRedactedError(type: 'DatabaseException', message: 'boom').toString(), 'DatabaseException: boom');
    });

    test('format starts with the time, a level icon and the message', () {
      final text = record(FluentLogLevel.info).format();
      expect(text, '03:04:05.006 ℹ️ msg');
    });

    test('every level has its own icon', () {
      final icons = <String>{};
      for (final FluentLogLevel level in FluentLogLevel.values) {
        final text = record(level).format();
        expect(text, endsWith(' msg'));
        icons.add(text.substring('03:04:05.006 '.length, text.length - ' msg'.length));
      }
      expect(icons, hasLength(FluentLogLevel.values.length));
    });

    test('colors wrap the text in ANSI codes only when asked', () {
      for (final FluentLogLevel level in FluentLogLevel.values) {
        expect(record(level).format(), isNot(contains('\x1B')));
        expect(record(level).format(colors: true), contains('\x1B'));
      }
    });

    test('tag parts become brackets', () {
      expect(record(FluentLogLevel.info, tag: 'FluentDb:init').format(), contains('[FluentDb] [init]'));
    });

    test('context is appended and redacted', () {
      final text = record(FluentLogLevel.info, context: {'a': 1}).format();
      expect(text, contains('📦 {a: 1}'));
      expect(record(FluentLogLevel.info, context: {}).format(), isNot(contains('📦')));
      final custom = record(FluentLogLevel.info, context: {'secret': 'x'}).format(redact: (t) => t.replaceAll('secret', '***'));
      expect(custom, contains('{***: x}'));
    });

    test('the hint is shown, multi-line hints indented, and coloured when asked', () {
      final text = record(FluentLogLevel.warning, hint: 'line1\nline2').format();
      expect(text, contains('\n   💡 HINT: line1\n   line2'));
      expect(record(FluentLogLevel.warning, hint: 'h').format(colors: true), contains('HINT: h'));
    });

    test('a FluentException supplies code, hint and cause', () {
      final error = FluentConfigException('bad', hint: 'fix it', cause: 'root');
      final r = record(FluentLogLevel.error, error: error);
      expect(r.code, FluentErrorCode.invalidConfiguration);
      final text = r.format();
      expect(text, contains('invalidConfiguration: msg'));
      expect(text, contains('HINT: fix it'));
      expect(text, contains('⛔ CAUSE: root'));
    });

    test('an own hint wins over the exception hint', () {
      final r = record(FluentLogLevel.error, error: FluentConfigException('bad', hint: 'from error'), hint: 'own');
      expect(r.format(), contains('HINT: own'));
      expect(r.format(), isNot(contains('from error')));
    });

    test('a plain error is shown as the cause, without a code', () {
      final r = record(FluentLogLevel.error, error: StateError('x'));
      expect(r.code, isNull);
      expect(r.format(), contains('⛔ CAUSE: Bad state: x'));
      expect(record(FluentLogLevel.error).code, isNull);
    });

    test('a FluentException without a cause shows no cause line', () {
      expect(record(FluentLogLevel.error, error: FluentConfigException('bad')).format(), isNot(contains('CAUSE')));
    });

    test('stack traces are cut to stackLines and only for the error level', () {
      final stack = StackTrace.fromString(List.generate(12, (i) => '#$i frame').join('\n'));
      final text = record(FluentLogLevel.error, stack: stack).format(stackLines: 3);
      expect(text, contains('#0 frame'));
      expect(text, contains('#2 frame'));
      expect(text, isNot(contains('#3 frame')));
      expect(text, contains('... 9 more'));
      final all = record(FluentLogLevel.error, stack: stack).format(stackLines: 12);
      expect(all, contains('#11 frame'));
      expect(all, isNot(contains('more')));
      expect(record(FluentLogLevel.error, stack: stack).format(stackLines: 0), isNot(contains('#0 frame')));
      expect(record(FluentLogLevel.warning, stack: stack).format(), isNot(contains('#0 frame')));
      expect(record(FluentLogLevel.error, stack: stack).toString(), contains('... 4 more'));
    });

    test('an issue adds details, code, its key and the mute hint', () {
      const issue = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'T', details: 'd1\nd2', fix: 'F', code: 'a\nb', database: 'main', table: 'notes', subject: 'x');
      final text = record(FluentLogLevel.hint, issue: issue).format();
      expect(text, contains('\n   d1\n   d2'));
      expect(text, contains('\n     a\n     b'));
      expect(text, contains('(hint missingIndex:main:notes:x; mute: FluentDb.setupLogging(mute: {\'missingIndex:*\'}))'));
    });
  });

  group('FluentIssue / FluentReport', () {
    test('key drops trailing empty parts', () {
      expect(const FluentIssue(kind: FluentIssueKind.missingIndex, title: 't').key, 'missingIndex');
      expect(const FluentIssue(kind: FluentIssueKind.missingIndex, title: 't', table: 'n').key, 'missingIndex::n');
      expect(const FluentIssue(kind: FluentIssueKind.missingIndex, title: 't', database: 'd', subject: 's').key, 'missingIndex:d::s');
    });

    test('type and priority come from the kind unless the issue sets its own impact', () {
      const base = FluentIssue(kind: FluentIssueKind.missingIndex, title: 't');
      expect(base.type, FluentIssueType.hint);
      expect(base.priority, FluentIssueKind.missingIndex.impact);
      const own = FluentIssue(kind: FluentIssueKind.missingIndex, title: 't', impact: FluentIssueImpact.low);
      expect(own.priority, FluentIssueImpact.low);
    });

    test('equality is by key and title', () {
      const a = FluentIssue(kind: FluentIssueKind.missingIndex, title: 't', details: 'x');
      const b = FluentIssue(kind: FluentIssueKind.missingIndex, title: 't', details: 'y');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const FluentIssue(kind: FluentIssueKind.missingIndex, title: 'other')));
      expect(a, isNot(const FluentIssue(kind: FluentIssueKind.slowRead, title: 't')));
      expect(a == Object(), isFalse);
    });

    test('toString lists title, details, fix, code and the key', () {
      const issue = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'T', details: 'D', fix: 'F', code: 'C', table: 'n');
      expect(issue.toString(), 'T\nD\nFix: F\nC\n(hint missingIndex::n)');
      expect(const FluentIssue(kind: FluentIssueKind.missingIndex, title: 'T').toString(), 'T\n(hint missingIndex)');
    });

    test('an empty report says so', () {
      const report = FluentReport([]);
      expect(report.isEmpty, isTrue);
      expect(report.toString(), 'Nothing to report: no hints, no automatic changes, no warnings.');
    });

    test('hints are grouped by impact and the rest by type; sections are printed in order', () {
      const high = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'high one', details: 'd\ne', fix: 'f\ng', code: 'c1\nc2');
      const medium = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'medium one', subject: 'm', impact: FluentIssueImpact.medium);
      const low = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'low one', subject: 'l', impact: FluentIssueImpact.low);
      const auto = FluentIssue(kind: FluentIssueKind.readPoolFallback, title: 'auto one');
      const report = FluentReport([low, auto, medium, high]);
      expect(report.isEmpty, isFalse);
      expect(report.hints(FluentIssueImpact.high), [high]);
      expect(report.hints(FluentIssueImpact.medium), [medium]);
      expect(report.hints(FluentIssueImpact.low), [low]);
      expect(report.ofType(FluentIssueType.autoFix), [auto]);
      expect(report.ofType(FluentIssueType.warning), isEmpty);
      final text = report.toString();
      expect(text.indexOf('Important'), lessThan(text.indexOf('Medium')));
      expect(text.indexOf('Medium'), lessThan(text.indexOf('Small wins')));
      expect(text.indexOf('Small wins'), lessThan(text.indexOf('Changed automatically')));
      expect(text, contains('Important — fix first (1)'));
      expect(text, contains('    d\n    e'));
      expect(text, contains('    Fix: f\n    g'));
      expect(text, contains('      c1\n      c2'));
      expect(text, contains('(missingIndex)'));
      expect(text, isNot(contains('Warnings')));
      expect(text, isNot(contains('Errors nobody received')));
    });
  });

  group('FluentMigrationPlan / FluentSchemaChange', () {
    const drop = FluentSchemaChange(kind: FluentSchemaChangeKind.dropColumn, table: 'a', description: 'drop x');
    const add = FluentSchemaChange(kind: FluentSchemaChangeKind.addColumn, table: 'a', description: 'add y');
    const rebuild = FluentSchemaChange(kind: FluentSchemaChangeKind.rebuildTable, table: 'b', description: 'rebuild');

    test('losesData only for destructive kinds', () {
      expect(drop.losesData, isTrue);
      expect(const FluentSchemaChange(kind: FluentSchemaChangeKind.purgeArchive, table: 'a', description: '').losesData, isTrue);
      expect(const FluentSchemaChange(kind: FluentSchemaChangeKind.viewOrTriggerLost, table: 'a', description: '').losesData, isTrue);
      expect(add.losesData, isFalse);
      expect(add.toString(), 'a: add y');
    });

    test('plan flags and filters', () {
      const empty = FluentMigrationPlan(database: 'd', changes: [], issues: []);
      expect(empty.isEmpty, isTrue);
      expect(empty.losesData, isFalse);
      expect(empty.rebuilds, isFalse);
      expect(empty.warnings, isEmpty);
      expect(empty.toString(), contains('nothing to change'));

      const warning = FluentIssue(kind: FluentIssueKind.schemaFallback, title: 'warn');
      const hint = FluentIssue(kind: FluentIssueKind.missingIndex, title: 'hint');
      const plan = FluentMigrationPlan(database: 'd', changes: [drop, add, rebuild], issues: [warning, hint]);
      expect(plan.isEmpty, isFalse);
      expect(plan.losesData, isTrue);
      expect(plan.rebuilds, isTrue);
      expect(plan.changesOf('a'), [drop, add]);
      expect(plan.changesOf('zzz'), isEmpty);
      expect(plan.warnings, plan.issues.where((i) => i.type == FluentIssueType.warning || i.type == FluentIssueType.error).toList());
      expect(plan.warnings, isNot(contains(hint)));
    });

    test('a failure makes the plan non-empty even without changes', () {
      final plan = FluentMigrationPlan(database: 'd', changes: const [], issues: const [], failure: FluentSchemaException('nope'));
      expect(plan.isEmpty, isFalse);
      expect(plan.toString(), contains('✖ the start would fail: nope'));
    });

    test('toString groups changes by table, marks data loss and lists skipped code and issues', () {
      const warning = FluentIssue(kind: FluentIssueKind.schemaFallback, title: 'warn');
      const plan = FluentMigrationPlan(database: 'd', changes: [drop, add, rebuild], issues: [warning], isNewDatabase: true, skippedCode: ['v2', 'v3']);
      final text = plan.toString();
      expect(text, startsWith('=== Migration plan of "d" (new database) ===\n'));
      expect(text, contains('  a:\n    ⚠ drop x\n    - add y\n  b:\n    - rebuild'));
      expect(text, contains('onMigrate not run for the plan: v2, v3'));
      expect(text, contains('[${warning.type.name}] warn'));
    });
  });

  group('FluentArchivedColumn / FluentTableSnapshot', () {
    test('archived column round trips through json', () {
      final c = FluentArchivedColumn(original: 'o', archivedAs: '__a', type: 'TEXT', revision: 3, removedAt: DateTime.fromMillisecondsSinceEpoch(5000));
      final back = FluentArchivedColumn.fromJson(c.toJson());
      expect(back.original, 'o');
      expect(back.archivedAs, '__a');
      expect(back.type, 'TEXT');
      expect(back.revision, 3);
      expect(back.removedAt, DateTime.fromMillisecondsSinceEpoch(5000));
      expect(c.toString(), contains('o → __a (TEXT, r3,'));
    });

    test('a record without time and type starts its retention now (never epoch 0)', () {
      final db = FluentTestDb(name: 'snapshot_clock');
      addTearDown(db.close);
      final c = FluentArchivedColumn.fromJson({'original': 'o', 'archivedAs': 'a'});
      expect(c.type, '');
      expect(c.revision, 0);
      expect(c.removedAt.millisecondsSinceEpoch, greaterThan(0));
      final diff = DateTime.now().difference(c.removedAt).abs();
      expect(diff, lessThan(const Duration(minutes: 1)));
    });

    test('a snapshot round trips through json with every part', () {
      final snap = FluentTableSnapshot(
        table: 't',
        revision: 4,
        columns: {'id': 'INTEGER', 'name': 'TEXT'},
        key: ['id'],
        checks: ['CHECK (id > 0)'],
        withoutRowId: true,
        indexes: {'idx': 'CREATE INDEX x'},
        archived: [FluentArchivedColumn(original: 'o', archivedAs: 'a', type: 'T', revision: 1, removedAt: DateTime.fromMillisecondsSinceEpoch(1000))],
        pendingNotNull: {'name'},
        steps: {'v1': 'abc'},
        relations: {'r': 'fk'},
        fingerprint: 'fp',
        tableSql: 'sqlhash',
      );
      final back = FluentTableSnapshot.fromJson('t', 4, snap.toJson());
      expect(back.columns, snap.columns);
      expect(back.key, ['id']);
      expect(back.checks, snap.checks);
      expect(back.withoutRowId, isTrue);
      expect(back.indexes, snap.indexes);
      expect(back.archived.single.original, 'o');
      expect(back.pendingNotNull, {'name'});
      expect(back.steps, {'v1': 'abc'});
      expect(back.relations, {'r': 'fk'});
      expect(back.fingerprint, 'fp');
      expect(back.tableSql, 'sqlhash');
    });

    test('an empty json object gives an empty snapshot; optional keys are not written', () {
      final empty = FluentTableSnapshot.fromJson('t', 0, '{}');
      expect(empty.columns, isEmpty);
      expect(empty.key, isEmpty);
      expect(empty.checks, isEmpty);
      expect(empty.withoutRowId, isFalse);
      expect(empty.indexes, isEmpty);
      expect(empty.archived, isEmpty);
      expect(empty.pendingNotNull, isEmpty);
      expect(empty.steps, isEmpty);
      expect(empty.relations, isEmpty);
      expect(empty.fingerprint, isNull);
      final json = jsonDecode(FluentTableSnapshot(table: 't').toJson()) as Map<String, dynamic>;
      expect(json.containsKey('relations'), isFalse);
      expect(json.containsKey('fingerprint'), isFalse);
      expect(json.containsKey('tableSql'), isFalse);
    });

    test('invalid json is an error, not an empty snapshot', () {
      expect(() => FluentTableSnapshot.fromJson('t', 0, 'not json'), throwsFormatException);
    });

    test('toString describes the parts that are present', () {
      final snap = FluentTableSnapshot(
        table: 't',
        revision: 2,
        columns: {'a': 'INTEGER'},
        key: ['a'],
        withoutRowId: true,
        indexes: {'i': 'x'},
        archived: [FluentArchivedColumn(original: 'o', archivedAs: 'a', type: 'T', revision: 1, removedAt: DateTime.utc(2026))],
        pendingNotNull: {'p'},
        steps: {'s1': 'h'},
      );
      final text = snap.toString();
      expect(text, startsWith('t (revision 2)\n'));
      expect(text, contains('key: a (WITHOUT ROWID)'));
      expect(text, contains('indexes: i'));
      expect(text, contains('archived: o → a'));
      expect(text, contains('pending NOT NULL: p'));
      expect(text, contains('applied steps: s1'));
      final plain = FluentTableSnapshot(table: 't').toString();
      expect(plain, isNot(contains('indexes')));
      expect(plain, isNot(contains('archived')));
    });
  });

  group('FluentDbColumn', () {
    test('toString lists every non-default property', () {
      final column = FluentDbColumn(
        name: 'c',
        type: FluentDbDataType.integer,
        isPrimaryKey: true,
        isAutoIncrement: true,
        isNotNull: true,
        isUnique: true,
        indexed: true,
        oldName: 'old',
        defaultValue: 5,
        checkConstraint: 'c > 0',
        collation: FluentCollation.noCase,
        converter: const FluentEpochDateTimeConverter(),
      );
      final text = column.toString();
      for (final String part in [
        'name: "c"',
        'type: integer',
        'isPK: true',
        'isAutoIncrement: true',
        'isNotNull: true',
        'isUnique: true',
        'indexed: true',
        'autoCorrect: true',
        'oldName: "old"',
        'defaultValue: 5',
        'check: "c > 0"',
        'collate: noCase',
        'converter: FluentEpochDateTimeConverter',
      ]) {
        expect(text, contains(part));
      }
      final custom = FluentDbColumn(name: 'x', type: FluentDbDataType.custom, customSql: 'TEXT NOT NULL', autoCorrectAllowed: false);
      expect(custom.toString(), contains('customSql: "TEXT NOT NULL"'));
      expect(custom.toString(), isNot(contains('autoCorrect')));
    });

    test('blob and timestamp shortcuts', () {
      final blob = FluentDbColumn.blob('data', isNotNull: true);
      expect(blob.type, FluentDbDataType.blob);
      expect(blob.isNotNull, isTrue);
      final ts = FluentDbColumn.timestamp('at', isNotNull: true, indexed: true);
      expect(ts.type, FluentDbDataType.integer);
      expect(ts.valueKind, FluentValueKind.dateTime);
      expect(ts.isNotNull, isTrue);
      expect(ts.indexed, isTrue);
    });
  });

  group('converters', () {
    test('ISO date converter stores UTC text by default and local text when asked', () {
      const utc = FluentIsoDateTimeConverter();
      final local = DateTime(2026, 5, 6, 7, 8, 9);
      expect(utc.sqlType, FluentDbDataType.text);
      expect(utc.toSql(local), fluentIsoText(local.toUtc()));
      expect(utc.fromSql(utc.toSql(local)), local.toUtc());
      expect(const FluentIsoDateTimeConverter(toUtc: false).toSql(local), fluentIsoText(local));
      expect(const FluentIsoDateTimeConverter(toUtc: false).fromSql(fluentIsoText(local)), local);
      expect(() => utc.fromSql('garbage'), throwsFormatException);
    });

    test('epoch date converter keeps milliseconds and reads back local or UTC', () {
      const local = FluentEpochDateTimeConverter();
      const utc = FluentEpochDateTimeConverter(utc: true);
      final t = DateTime.utc(2026, 5, 6, 7, 8, 9, 123, 456);
      expect(local.sqlType, FluentDbDataType.integer);
      expect(local.toSql(t), t.millisecondsSinceEpoch);
      expect(local.fromSql(1000).isUtc, isFalse);
      expect(utc.fromSql(1000).isUtc, isTrue);
      expect(utc.fromSql(utc.toSql(t)), DateTime.utc(2026, 5, 6, 7, 8, 9, 123));
    });

    test('enum converter by name and by index, with lookup of stored values', () {
      const byName = FluentEnumConverter<_Mood>(_Mood.values);
      const byIndex = FluentEnumConverter<_Mood>(_Mood.values, byName: false);
      expect(byName.sqlType, FluentDbDataType.text);
      expect(byIndex.sqlType, FluentDbDataType.integer);
      expect(byName.toSql(_Mood.sad), 'sad');
      expect(byIndex.toSql(_Mood.sad), 1);
      expect(byName.fromSql('happy'), _Mood.happy);
      expect(byName.fromSql(1), _Mood.sad);
      expect(byIndex.fromSql('1'), _Mood.sad);
      expect(byName.encode('sad'), 'sad');
      expect(byName.encode(3), 3);
      expect(byName.encode(_Mood.happy), 'happy');
    });

    test('enum converter rejects unknown values and lookup returns null for them', () {
      const c = FluentEnumConverter<_Mood>(_Mood.values);
      expect(() => c.fromSql('angry'), throwsArgumentError);
      expect(() => c.fromSql(7), throwsArgumentError);
      expect(() => c.fromSql(-1), throwsArgumentError);
      expect(FluentEnumConverter.lookup(_Mood.values, 'nope'), isNull);
      expect(FluentEnumConverter.lookup(_Mood.values, _Mood.sad), _Mood.sad);
      expect(FluentEnumConverter.lookup(_Mood.values, '0'), _Mood.happy);
    });
  });

  group('FluentTask', () {
    FluentTask task(FluentDbAction action, {TableHelper? helper, int maxDepth = 1, bool ignoreLazy = false, Object? data, ExecutionPolicy policy = const ExecutionPolicy(), Object? tag}) =>
        FluentTask(action: action, table: 't', dbName: 'd', helper: helper, maxDepth: maxDepth, ignoreLazy: ignoreLazy, data: data, policy: policy, tag: tag);

    test('static weights follow the cost class of the action', () {
      expect(task(FluentDbAction.findById).staticWeight, 10);
      expect(task(FluentDbAction.save).staticWeight, 25);
      expect(task(FluentDbAction.count).staticWeight, 40);
      expect(task(FluentDbAction.clearTable).staticWeight, 100);
      expect(task(FluentDbAction.execute).staticWeight, 150);
      expect(task(FluentDbAction.aggregate).staticWeight, 30);
    });

    test('limit, order, depth and lazy modify the weight', () {
      expect(task(FluentDbAction.find).staticWeight, 80); // unbounded find, also without a helper
      expect(task(FluentDbAction.find, helper: TableHelper()).staticWeight, 80); // unbounded find
      expect(task(FluentDbAction.find, helper: TableHelper(limit: 10)).staticWeight, 25);
      expect(task(FluentDbAction.find, helper: TableHelper(limit: 101)).staticWeight, 50);
      expect(task(FluentDbAction.find, helper: TableHelper(limit: 100)).staticWeight, 25);
      expect(task(FluentDbAction.find, helper: TableHelper(orderBy: 'a')).staticWeight, 100);
      expect(task(FluentDbAction.find, maxDepth: 3).staticWeight, 80 + 90);
      expect(task(FluentDbAction.find, maxDepth: 0).staticWeight, 80);
      expect(task(FluentDbAction.find, ignoreLazy: true).staticWeight, 100);
    });

    test('isWriteOp / isStreamOp, also for SQL that changes data', () {
      expect(task(FluentDbAction.save).isWriteOp, isTrue);
      expect(task(FluentDbAction.find).isWriteOp, isFalse);
      expect(task(FluentDbAction.save).isStreamOp, isTrue);
      expect(task(FluentDbAction.find).isStreamOp, isFalse);
      bool changes(String? sql) => task(FluentDbAction.execute, helper: TableHelper(sql: sql)).isStreamOp;
      expect(changes('INSERT INTO t VALUES (1)'), isTrue);
      expect(changes('  update t set a = 1'), isTrue);
      expect(changes('DELETE FROM t'), isTrue);
      expect(changes('REPLACE INTO t VALUES (1)'), isTrue);
      expect(changes('SELECT 1'), isFalse);
      expect(changes('CREATE TABLE x (a)'), isFalse);
      expect(changes(null), isFalse);
      expect(changes('-- INSERT in a comment\nSELECT 1'), isFalse);
      expect(changes("/* DELETE */ SELECT 'DELETE'"), isFalse);
      expect(changes("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x"), isTrue);
      expect(changes("WITH x AS (SELECT 'INSERT') SELECT * FROM x"), isFalse);
      expect(changes('WITH x AS (SELECT 1) SELECT * FROM x'), isFalse);
      expect(task(FluentDbAction.find, helper: TableHelper(sql: 'DELETE FROM t')).isStreamOp, isFalse);
    });

    test('fingerprints differ by what is read, not by object identity', () {
      final a = task(FluentDbAction.find, helper: TableHelper(where: 'a = ?', whereArgs: [1]));
      final b = task(FluentDbAction.find, helper: TableHelper(where: 'a = ?', whereArgs: [1]));
      final c = task(FluentDbAction.find, helper: TableHelper(where: 'a = ?', whereArgs: [2]));
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint, isNot(c.fingerprint));
      expect(a.fingerprint, isNot(task(FluentDbAction.count, helper: TableHelper(where: 'a = ?', whereArgs: [1])).fingerprint));
      expect(a.fingerprint, isNot(task(FluentDbAction.find, maxDepth: 2, helper: TableHelper(where: 'a = ?', whereArgs: [1])).fingerprint));
      expect(a.fingerprint, isNot(task(FluentDbAction.find, ignoreLazy: true, helper: TableHelper(where: 'a = ?', whereArgs: [1])).fingerprint));
      expect(task(FluentDbAction.find, helper: TableHelper(limit: 1)).fingerprint, isNot(task(FluentDbAction.find, helper: TableHelper(limit: 2)).fingerprint));
      expect(task(FluentDbAction.find, helper: TableHelper(offset: 1)).fingerprint, isNot(task(FluentDbAction.find, helper: TableHelper(offset: 2)).fingerprint));
      expect(task(FluentDbAction.find, helper: TableHelper(orderBy: 'a')).fingerprint, isNot(task(FluentDbAction.find, helper: TableHelper(orderBy: 'b')).fingerprint));
      expect(task(FluentDbAction.find, helper: TableHelper(distinct: true)).fingerprint, isNot(task(FluentDbAction.find, helper: TableHelper()).fingerprint));
      expect(task(FluentDbAction.find, helper: TableHelper(columns: ['a'])).fingerprint, isNot(task(FluentDbAction.find, helper: TableHelper(columns: ['b'])).fingerprint));
      expect(task(FluentDbAction.rawQuery, helper: TableHelper(sql: 'SELECT ?', arguments: [1])).fingerprint, isNot(task(FluentDbAction.rawQuery, helper: TableHelper(sql: 'SELECT ?', arguments: [2])).fingerprint));
      expect(
        task(FluentDbAction.find, helper: TableHelper(deferred: [const FluentSearchCondition('a')])).fingerprint,
        isNot(task(FluentDbAction.find, helper: TableHelper(deferred: [const FluentSearchCondition('b')])).fingerprint),
      );
    });

    test('a write fingerprint includes the identity of its data', () {
      final one = Object();
      final two = Object();
      expect(task(FluentDbAction.save, data: one).fingerprint, task(FluentDbAction.save, data: one).fingerprint);
      expect(task(FluentDbAction.save, data: one).fingerprint, isNot(task(FluentDbAction.save, data: two).fingerprint));
      expect(task(FluentDbAction.find, data: one).fingerprint, task(FluentDbAction.find, data: two).fingerprint);
    });

    test('copyWith replaces the given fields and keeps the rest', () {
      final base = FluentTask(id: 1, table: 't', dbName: 'd', action: FluentDbAction.find, maxDepth: 2, ignoreLazy: true, tag: 'x', executionWeight: 7);
      final same = base.copyWith();
      expect(same.id, 1);
      expect(same.table, 't');
      expect(same.dbName, 'd');
      expect(same.action, FluentDbAction.find);
      expect(same.maxDepth, 2);
      expect(same.ignoreLazy, isTrue);
      expect(same.tag, 'x');
      expect(same.executionWeight, 7);
      final helper = TableHelper(limit: 3);
      final other = base.copyWith(id: 2, table: 'u', dbName: 'e', data: 'data', helper: helper, policy: ExecutionPolicy.fast, mergedTasks: [base]);
      expect(other.id, 2);
      expect(other.table, 'u');
      expect(other.dbName, 'e');
      expect(other.data, 'data');
      expect(other.helper, same.helper ?? helper);
      expect(other.policy, ExecutionPolicy.fast);
      expect(other.isBatched, isTrue);
      expect(base.isBatched, isFalse);
      expect(FluentTask(action: FluentDbAction.save, mergedTasks: const []).isBatched, isFalse);
    });

    test('toString shows only what differs from the defaults', () {
      final plain = task(FluentDbAction.find).toString();
      expect(plain, startsWith('FluentTask{id: 0, table: t, action: find, dbName: d'));
      expect(plain, isNot(contains('maxDepth')));
      expect(plain, isNot(contains('ignoreLazy')));
      expect(plain, isNot(contains('policy')));
      expect(plain, isNot(contains('tag')));
      expect(plain, isNot(contains('merged')));
      expect(plain, contains('weight: 80/0}'));
      final full = FluentTask(
        action: FluentDbAction.save,
        table: 't',
        maxDepth: 3,
        ignoreLazy: true,
        helper: TableHelper(limit: 1),
        policy: ExecutionPolicy.fast,
        tag: 'tg',
        mergedTasks: [task(FluentDbAction.save)],
      ).toString();
      expect(full, contains('maxDepth: 3'));
      expect(full, contains('ignoreLazy: true'));
      expect(full, contains('helper: '));
      expect(full, contains('policy: '));
      expect(full, contains('tag: tg'));
      expect(full, contains('merged: 1'));
      expect(full, isNot(contains('dbName')));
    });
  });
}
