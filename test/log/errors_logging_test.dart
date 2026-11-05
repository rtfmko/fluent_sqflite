// Errors & logging: typed errors with code / hint / cause, each error logged once, merged-batch failures,
// SQL errors of reads, masking of SQL arguments, levels, analyzer hints.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late DynamicProvider users;
  final List<FluentLogRecord> records = [];

  setUp(() async {
    db = FluentTestDb(name: 'errors_${DateTime.now().microsecondsSinceEpoch}');
    users = DynamicProvider('users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('email', isUnique: true)]);
    await db.open([users]);
    records.clear();
    FluentLog.reset();
    FluentDb.setupLogging(console: false, onRecord: records.add);
  });

  tearDown(() async {
    FluentLog.reset();
    FluentDb.setupLogging(enabled: false);
    await db.close();
  });

  List<FluentLogRecord> warnings() => records.where((r) => r.level == FluentLogLevel.warning).toList();

  test('a failing save reaches the caller typed, with code, hint and cause, and is logged once as a warning', () async {
    await users.save(users.row({'id': 1, 'email': 'ann@x'}));
    records.clear();

    final Object error = await users.save(users.row({'id': 2, 'email': 'ann@x'})).then<Object>((_) => 'saved', onError: (Object e) => e);
    expect(error, isA<FluentConstraintException>().having((e) => e.code, 'code', FluentErrorCode.uniqueViolation));
    final FluentConstraintException e = error as FluentConstraintException;
    expect(e.hint, contains('conflictOn'));
    expect(e.cause, isNotNull);

    expect(warnings(), hasLength(1));
    expect(warnings().single.error, same(e));
    expect(warnings().single.code, FluentErrorCode.uniqueViolation);
    expect(records.where((r) => r.level == FluentLogLevel.error), isEmpty, reason: 'the caller received it: not an error nobody saw');
  });

  test('a merged batch that fails logs only the call that really fails', () async {
    await users.save(users.row({'id': 1, 'email': 'a'}));
    records.clear();

    final List<Object?> results = await Future.wait([
      users.save(users.row({'id': 2, 'email': 'b'})).then<Object?>((r) => r, onError: (Object e) => e),
      users.save(users.row({'id': 3, 'email': 'a'})).then<Object?>((r) => r, onError: (Object e) => e),
      users.save(users.row({'id': 4, 'email': 'c'})).then<Object?>((r) => r, onError: (Object e) => e),
    ]);
    expect(results.map((r) => r is FluentConstraintException), [false, true, false]);
    expect(warnings(), hasLength(1));
  });

  test('SQL errors of reads become FluentQueryException with a hint, logged once', () async {
    await expectLater(
      users.rawQuery('SELECT * FROM nope'),
      throwsA(isA<FluentQueryException>().having((e) => e.code, 'code', FluentErrorCode.noSuchTable).having((e) => e.message, 'message', contains('"nope"'))),
    );
    await expectLater(users.find(where: FluentFilter.eq('missing_column', 1)), throwsA(isA<FluentQueryException>().having((e) => e.message, 'message', contains('missing_column'))));
    expect(warnings(), hasLength(2));
    expect(warnings().every((r) => r.hint != null), isTrue);
  });

  test('SQL arguments and paths are hidden in error texts unless showSqlArguments is on', () async {
    await users.save(users.row({'id': 1, 'email': 'secret@mail'}));
    final Object hidden = await users.save(users.row({'id': 2, 'email': 'secret@mail'})).then<Object>((_) => '', onError: (Object e) => e);
    expect('$hidden', contains('UNIQUE'));
    expect('$hidden', isNot(contains('secret@mail')));
    expect(records.map((r) => r.format()).join('\n'), isNot(contains('secret@mail')));

    FluentDb.setupLogging(showSqlArguments: true);
    final Object shown = await users.save(users.row({'id': 3, 'email': 'secret@mail'})).then<Object>((_) => '', onError: (Object e) => e);
    expect('$shown', contains('secret@mail'));
  });

  test('levels: records below the level are dropped; the level can be changed at any time', () async {
    FluentDb.setupLogging(level: FluentLogLevel.warning);
    await users.findById(1);
    expect(records, isEmpty);

    FluentDb.setupLogging(level: FluentLogLevel.debug);
    await users.findById(1);
    expect(records.where((r) => r.level == FluentLogLevel.debug), isNotEmpty, reason: 'switching to debug works after logs were written');

    records.clear();
    FluentDb.setupLogging(enabled: false);
    await users.findById(1);
    expect(records, isEmpty);
  });

  test('analyzer hints are published once per key and printed as hint records', () async {
    final List<FluentIssue> published = [];
    final sub = FluentDb.onIssue(types: {FluentIssueType.hint}).listen(published.add);
    const FluentIssue hint = FluentIssue(kind: FluentIssueKind.slowRead, table: 't', title: 'Do it faster', details: 'measured', code: 'code();');
    FluentLog.publish(hint);
    FluentLog.publish(hint);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(published, [hint]);
    final List<FluentLogRecord> printed = records.where((r) => r.level == FluentLogLevel.hint).toList();
    expect(printed, hasLength(1));
    expect(printed.single.format(), allOf(contains('Do it faster'), contains('code();')));
  });

  test('errors outside provider calls are logged once too; a failing onRecord callback does not break the call', () async {
    // FluentDb statics never throw synchronously: lookup errors arrive as failed futures / stream errors.
    final Future<_Unregistered?> lookup = FluentDb.findById<_Unregistered>(1);
    await expectLater(lookup, throwsA(isA<FluentConfigException>().having((e) => e.code, 'code', FluentErrorCode.providerNotFound)));
    expect(await FluentDb.count<_Unregistered>().catchError((Object _) => -1), -1);
    await expectLater(FluentDb.watch<_Unregistered>(), emitsError(isA<FluentConfigException>()));
    await expectLater(FluentDb.transaction(() async => 1, dbKey: FluentDbKey('nope')), throwsA(isA<FluentArgumentException>()));
    expect(warnings(), hasLength(4));
    records.clear();

    FluentDb.setupLogging(onRecord: (_) => throw StateError('sink'), level: FluentLogLevel.debug);
    expect(await users.findById(1), isNull);
  });

  test('the formatted record shows the code, the hint and the cause', () {
    final FluentQueryException e = FluentQueryException('Boom', hint: 'Fix it', cause: Exception("DatabaseException(x) sql 'SELECT ?' args [42]"));
    final String text = FluentLogRecord(level: FluentLogLevel.warning, message: e.message, time: DateTime(2026), error: e).format(redact: FluentLog.redact);
    expect(text, allOf(contains('sqlError: Boom'), contains('HINT: Fix it'), contains('CAUSE'), contains('args [hidden]')));
    expect(text, isNot(contains('42')));
  });
}

class _Unregistered extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1};
}
