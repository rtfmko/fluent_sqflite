// How a relation link turns keys into column values: single and composite keys, FluentKeys, null, and the refusal of a
// single value for a composite key.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers.dart';

/// A model with a composite key (region, code).
class GKey extends FluentStorable {
  GKey({this.region = '', this.code = 0});

  final String region;
  final int code;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('region'), FluentDbColumn.integer('code')];

  @override
  Map<String, dynamic> buildJson() => {'region': region, 'code': code};
}

class GKeyProvider extends FluentProvider<GKey> {
  @override
  String get tableName => 'g_key';

  @override
  GKey get modelSample => GKey();

  @override
  GKey fromCacheJson(Map<String, dynamic> json) => GKey(region: json['region'] as String, code: json['code'] as int);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    await db.close();
  });

  Future<GBProvider> open() async {
    GBase.declared[GB] = () => [
      FluentRelation<GB, GKey>(name: 'k', type: FluentRelationType.one, select: (GB x) => x.dyn),
      FluentRelation<GB, GKey>(name: 'ks', type: FluentRelationType.manyToMany, select: (GB x) => x.dyn, linkTable: 'b_keys'),
    ];
    final GBProvider b = GBProvider();
    db = await openG([b, GKeyProvider()]);
    return b;
  }

  test('a composite reference fills one column per key part', () async {
    final GBProvider b = await open();
    final FluentRelationLink link = b.relationLinks.singleWhere((FluentRelationLink l) => l.name == 'k');
    expect(link.foreignKeys, ['k_region', 'k_code']);
    expect(link.referenceValues(FluentKey({'region': 'eu', 'code': 7})), {'k_region': 'eu', 'k_code': 7});
    expect(link.referenceValues(null), {'k_region': null, 'k_code': null}, reason: 'null clears every column');
  });

  test('a single value for a composite key is refused with the way to build a FluentKey', () async {
    final GBProvider b = await open();
    final FluentRelationLink link = b.relationLinks.singleWhere((FluentRelationLink l) => l.name == 'k');
    expect(
      () => link.referenceValues(5),
      throwsA(
        isA<FluentArgumentException>()
            .having((FluentArgumentException e) => e.message, 'message', contains('composite key (region, code)'))
            .having((FluentArgumentException e) => e.hint, 'hint', contains("FluentKey({'region': ...")),
      ),
    );
  });

  test('link tables to a composite key have a column per part, and link values zip the key', () async {
    final GBProvider b = await open();
    final FluentRelationLink link = b.relationLinks.singleWhere((FluentRelationLink l) => l.name == 'ks');
    expect(link.linkOwnerColumns, ['gb_id']);
    expect(link.linkTargetColumns, hasLength(2));
    expect(link.linkTargetColumns.every((String c) => c.endsWith('region') || c.endsWith('code')), isTrue);
    final Map<String, Object?> values = link.linkTargetValues(FluentKey({'region': 'us', 'code': 2}));
    expect(values.values, ['us', 2]);
    expect(() => link.linkTargetValues('us'), throwsA(isA<FluentArgumentException>()));
    expect(link.linkOwnerValues(3), {'gb_id': 3});
  });
}
