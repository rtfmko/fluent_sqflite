// A relation that changes how it is stored between two app versions: when the data cannot be moved, nothing is lost and
// the reason is reported (`relationChanged`) with the way out.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '_helpers.dart';

/// A model with a composite key (region, code).
class GK extends FluentStorable with FluentRelations {
  GK({this.region = '', this.code = 0, this.bs});

  String region;
  int code;
  List<GB>? bs;

  static List<FluentRelation> Function() declared = () => const [];

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('region'), FluentDbColumn.integer('code')];

  @override
  Map<String, dynamic> buildJson() => {'region': region, 'code': code};

  @override
  List<FluentRelation> get relations => declared();
}

class GKProvider extends FluentProvider<GK> {
  @override
  String get tableName => 'g_k';

  @override
  GK get modelSample => GK();

  @override
  GK fromCacheJson(Map<String, dynamic> json) => GK(region: json['region'] as String, code: json['code'] as int, bs: (json['bs'] as List?)?.cast<GB>());
}

Future<void> _dropColumn(DatabaseExecutor db, String table, String column) async {
  for (final Map<String, Object?> r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql LIKE ?", [table, '%"$column"%'])) {
    await db.execute('DROP INDEX "${r['name']}"');
  }
  await db.execute('ALTER TABLE "$table" DROP COLUMN "$column"');
}

List<FluentIssue> _changed(FluentTestDb db, String text) => [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.relationChanged && i.title.contains(text)) i];

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  tearDown(() async {
    resetG();
    GK.declared = () => const [];
    await db.close();
  });

  /// Version 1 [first] is written and filled by [fill]; [between] changes the file; then version 2 [second] starts.
  Future<(GAProvider, GBProvider, GCProvider)> twoVersions({
    required List<FluentRelation> Function() first,
    required List<FluentRelation> Function() second,
    Future<void> Function(GAProvider a, GBProvider b)? fill,
    Future<void> Function(GAProvider a)? between,
  }) async {
    GBase.declared[GA] = first;
    GAProvider a = GAProvider();
    GBProvider b = GBProvider();
    db = await openG([a, b, GCProvider()], persistent: true);
    if (fill != null) await fill(a, b);
    if (between != null) await between(a);
    GBase.declared[GA] = second;
    a = GAProvider();
    b = GBProvider();
    final GCProvider c = GCProvider();
    await db.restart([a, b, c]);
    return (a, b, c);
  }

  group('data that stays where it was', () {
    test('a reference that became an owned child, with its old column gone', () async {
      final (GAProvider a, _, _) = await twoVersions(
        first: () => [FluentRelation.one<GA, GB>('b', (GA x) => x.b)],
        second: () => [FluentRelation.oneOwned<GA, GB>('b', (GA x) => x.b)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'x')..b = GB(name: 'target')),
        between: (GAProvider a) => _dropColumn(a.db, 'g_a', 'b_id'),
      );
      final FluentIssue issue = _changed(db, 'the old column "g_a.b_id" is gone').single;
      expect(issue.fix, contains('migration step'));
      expect(await a.count(), 1, reason: 'the rows themselves stay');
    });

    test('an owned child that became a reference to another table', () async {
      await twoVersions(
        first: () => [FluentRelation.oneOwned<GA, GB>('x', (GA a) => a.b)],
        second: () => [FluentRelation.one<GA, GC>('x', (GA a) => a.c)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'x')..b = GB(name: 'child')),
      );
      expect(_changed(db, 'it was stored in "g_b"'), hasLength(1));
    });

    test('an owned child that became a reference, with its old column gone', () async {
      await twoVersions(
        first: () => [FluentRelation.oneOwned<GA, GB>('x', (GA a) => a.b)],
        second: () => [FluentRelation.one<GA, GB>('x', (GA a) => a.b)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'x')..b = GB(name: 'child')),
        between: (GAProvider a) async => _dropColumn(a.db, 'g_b', 'ga_id'),
      );
      expect(_changed(db, 'the old column "g_b.ga_id" is gone'), hasLength(1));
    });

    test('an owned list that became a reference while an owner holds several children', () async {
      final (_, GBProvider b, _) = await twoVersions(
        first: () => [FluentRelation.many<GA, GB>('x', (GA a) => a.bs)],
        second: () => [FluentRelation.one<GA, GB>('x', (GA a) => a.b)],
        fill: (GAProvider a, GBProvider b) async {
          await a.save(GA(name: 'owner')..bs = [GB(name: '1'), GB(name: '2')]);
          await a.save(GA(name: 'single')..bs = [GB(name: '3')]);
        },
      );
      final FluentIssue issue = _changed(db, 'own several GB rows, but a reference holds one').single;
      expect(issue.title, contains('1 GA row(s)'));
      expect(await b.count(), 3, reason: 'no child is deleted');
    });

    test('an owned list that became a many-to-many of another model', () async {
      await twoVersions(
        first: () => [FluentRelation.many<GA, GB>('x', (GA a) => a.bs)],
        second: () => [FluentRelation.manyToMany<GA, GC>('x', (GA a) => a.cs)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'owner')..bs = [GB(name: '1')]),
      );
      expect(_changed(db, 'it was stored in "g_b"'), hasLength(1));
    });

    test('an owned list that became a many-to-many, with its old column gone', () async {
      await twoVersions(
        first: () => [FluentRelation.many<GA, GB>('x', (GA a) => a.bs)],
        second: () => [FluentRelation.manyToMany<GA, GB>('x', (GA a) => a.bs)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'owner')..bs = [GB(name: '1')]),
        between: (GAProvider a) async => _dropColumn(a.db, 'g_b', 'ga_id'),
      );
      expect(_changed(db, 'the old column "g_b.ga_id" is gone'), hasLength(1));
    });

    test('a many-to-many that became an owned list, with its link table gone', () async {
      await twoVersions(
        first: () => [FluentRelation.manyToMany<GA, GB>('x', (GA a) => a.bs, linkTable: 'x_links')],
        second: () => [FluentRelation.many<GA, GB>('x', (GA a) => a.bs)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'owner')..bs = [GB(name: '1')]),
        between: (GAProvider a) => a.db.execute('DROP TABLE x_links'),
      );
      expect(_changed(db, 'the old link table "x_links" is gone'), hasLength(1));
    });

    test('a storage change between kinds nothing can move is reported with both storages', () async {
      await twoVersions(
        first: () => [FluentRelation.one<GA, GB>('x', (GA a) => a.b)],
        second: () => [FluentRelation.manyToMany<GA, GB>('x', (GA a) => a.bs)],
        fill: (GAProvider a, GBProvider b) async => a.save(GA(name: 'x')..b = GB(name: 'target')),
      );
      final FluentIssue issue = _changed(db, 'it was stored as "ref|').single;
      expect(issue.title, contains('is "link|'));
    });
  });

  group('composite keys', () {
    test('a list owned by a composite-key model that became a reference is not moved and says why', () async {
      GK.declared = () => [FluentRelation.many<GK, GB>('x', (GK k) => k.bs)];
      GKProvider k = GKProvider();
      db = await openG([k, GBProvider()], persistent: true);
      await k.save(GK(region: 'eu', code: 1)..bs = [GB(name: 'child')]);
      GK.declared = () => [FluentRelation.one<GK, GB>('x', (GK k) => null)];
      k = GKProvider();
      final GBProvider b = GBProvider();
      await db.restart([k, b]);
      expect(_changed(db, 'its keys have several columns').single.subject, 'x');
      expect(await b.count(), 1);
    });
  });
}
