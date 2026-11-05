// Round 3 fixes made by the lead: microseconds dropped by the timestamp format are reported (precisionLost).
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/schema_models.dart';

DynamicProvider _events(String table) => DynamicProvider(table, () => [FluentDbColumn.integer('id'), FluentDbColumn.timestamp('at')]);

void main() {
  setUpFluentTests();
  policyTests();

  group('precisionLost', precisionTests);
}

void precisionTests() {
  late FluentTestDb db;

  tearDown(() => db.close());

  List<FluentIssue> lost() => [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.precisionLost) i];

  group('precisionLost: the timestamp format keeps milliseconds', () {
    test('a DateTime with microseconds is saved as milliseconds and reported once per column', () async {
      db = FluentTestDb(name: 'r3_micro');
      final DynamicProvider events = _events('r3_micro_events');
      await db.open([events]);
      final DateTime at = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
      await events.save(events.row({'id': 1, 'at': at}));
      await events.save(events.row({'id': 2, 'at': at.add(const Duration(microseconds: 1))}));
      final Object? stored = (await events.findById(1))?.values['at'];
      expect(stored, DateTime.utc(2026, 1, 2, 3, 4, 5, 6), reason: 'the microseconds are cut, the rest is kept');
      expect(lost(), hasLength(1), reason: 'once per run and column');
      expect(lost().single.title, contains('"at"'));
      expect(lost().single.fix, contains('iso8601'));
      expect(lost().single.code, contains('FluentDateTimeFormat.iso8601'));
    });

    test('whole milliseconds, null values and query arguments report nothing', () async {
      db = FluentTestDb(name: 'r3_micro_ok');
      final DynamicProvider events = _events('r3_micro_ok_events');
      await db.open([events]);
      await events.save(events.row({'id': 1, 'at': DateTime.utc(2026, 1, 2, 3, 4, 5, 6)}));
      await events.save(events.row({'id': 2, 'at': null}));
      await events.find(where: FluentFilter.gt('at', DateTime.utc(2026, 1, 1, 0, 0, 0, 0, 5)));
      expect(lost(), isEmpty);
    });

    test('the iso8601 format keeps the microseconds and reports nothing', () async {
      db = FluentTestDb(name: 'r3_micro_iso');
      final DynamicProvider events = _IsoEvents();
      await db.open([events]);
      final DateTime at = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
      await events.save(events.row({'id': 1, 'at': at}));
      expect((await events.findById(1))?.values['at'], at);
      expect(lost(), isEmpty);
    });
  });
}

class _IsoEvents extends DynamicProvider {
  _IsoEvents() : super('r3_micro_iso_events', () => [FluentDbColumn.integer('id'), FluentDbColumn.timestamp('at')]);

  @override
  DynamicModel get modelSample => _IsoModel(spec);

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) => _IsoModel(spec, values: json);

  @override
  DynamicModel row(Map<String, dynamic> values) => _IsoModel(spec, values: values);
}

class _IsoModel extends DynamicModel {
  _IsoModel(super.spec, {super.values});

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);
}

class _FreshPolicyUsers extends DynamicProvider {
  _FreshPolicyUsers() : super('r3_policy_users', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);

  @override
  ExecutionPolicy get policy => ExecutionPolicy.fresh;
}

void policyTests() {
  group('FluentProvider.policy is the default of its calls', () {
    late FluentTestDb db;
    tearDown(() => db.close());

    Future<(bool, bool)> sameInstances(DynamicProvider users, {ExecutionPolicy policy = const ExecutionPolicy()}) async {
      final List<List<DynamicModel>> both = await Future.wait([users.find(policy: policy), users.find(policy: policy)]);
      return (identical(both[0].single, both[1].single), both[0].single.values['name'] == 'Ann');
    }

    test('a provider policy fresh: identical reads are not collapsed; a call policy overrides it', () async {
      db = FluentTestDb(name: 'r3_policy');
      final _FreshPolicyUsers users = _FreshPolicyUsers();
      final DynamicProvider plain = DynamicProvider('r3_policy_plain', () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')]);
      await db.open([users, plain]);
      await users.save(users.row({'id': 1, 'name': 'Ann'}));
      await plain.save(plain.row({'id': 1, 'name': 'Ann'}));
      expect(await sameInstances(plain), (true, true), reason: 'default: collapsed, same instances');
      expect(await sameInstances(users), (false, true), reason: 'provider policy fresh: own query each');
      expect(await sameInstances(users, policy: const ExecutionPolicy(cancelIfDuplicate: true)), (true, true), reason: 'the call wins');
    });
  });
}
