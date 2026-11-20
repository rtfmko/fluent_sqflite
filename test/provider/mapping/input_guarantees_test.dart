// G22 / G29: bad input never breaks the library (converted losslessly or refused typed, nothing written), and
// reads, saves and updates carry exactly the requested fields. Agent T7, seed base 70000.
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fuzz.dart';
import '../../helpers/guarantees.dart';

enum Tone { calm, loud }

/// A model with every kind of internal bookkeeping: soft delete, timestamps, expiry, sync versions, type metadata.
class Item extends FluentStorable with FluentSoftDeletable, FluentTimestamps {
  Item(this.raw, {super.timeToLive});

  Item.of({int? id, String name = 'n', int qty = 1, double price = 0.5, List<Object?> tags = const [1], DateTime? at, Tone? mood = Tone.calm, Uint8List? blob, bool flag = true, String? note, super.timeToLive})
    : raw = {'id': id, 'name': name, 'qty': qty, 'price': price, 'tags': tags, 'at': at ?? DateTime.utc(2024, 5, 6), 'mood': mood, 'blob': blob ?? Uint8List.fromList([1, 2]), 'flag': flag, 'note': note ?? ''};

  /// The values `buildJson` returns (anything: tests put wrong types here).
  final Map<String, dynamic> raw;

  @override
  Map<String, List<Enum>> get enumValues => {'mood': Tone.values};

  /// NOT NULL: the model field is declared again (the documented way to add a constraint).
  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.text('name', isNotNull: true)];

  @override
  Map<String, dynamic> buildJson() => raw;
}

class ItemProvider extends FluentProvider<Item> with FluentSyncable<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item.of(mood: Tone.calm, note: 'x');

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(json);
}

const List<String> modelFields = ['id', 'name', 'qty', 'price', 'tags', 'at', 'mood', 'blob', 'flag', 'note'];

/// Columns the library keeps for itself: they must never show up in what a read returns.
const List<String> bookkeeping = ['_fs_metadata', 'expiry_date', 'sync_version', 'synced_version'];

String norm(Object? v) {
  if (v is DateTime) return '${v.toUtc().microsecondsSinceEpoch}/${v.isUtc}';
  if (v is Uint8List) return 'bytes${v.toList()}';
  if (v is List || v is Map) return jsonEncode(v);
  return '${v.runtimeType == double ? 'd' : ''}$v';
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late ItemProvider items;

  setUp(() async {
    db = FluentTestDb(name: 'input_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
    items = ItemProvider();
    await db.open([items]);
  });

  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> rawRows() => items.db.rawQuery('SELECT * FROM items ORDER BY id');

  /// Duplicate-column warnings of NOT NULL declarations are the documented way to add a constraint here; every other
  /// warning is a surprise.
  void expectCleanIssues({Set<FluentIssueKind> allowed = const {}}) {
    for (final FluentIssue i in db.warnings) {
      if (i.kind == FluentIssueKind.schemaFallback && i.title.startsWith('Duplicate column')) continue;
      expect(allowed, contains(i.kind), reason: 'unexpected warning ${i.kind.name}: ${i.title}');
    }
    // Analyzer hints (e.g. deepOffset) carry their advice in details / code and no fix text: reported for T10, not checked here.
    expectIssuesHaveFixes(db.issues.where((i) => i.type != FluentIssueType.hint));
  }

  Future<void> expectTyped(Future<Object?> Function() call, {String? reason}) async {
    Object? error;
    try {
      await call();
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: '$reason: the call must be refused');
    expectTypedError(error!, reason: reason);
  }

  Future<void> seed([int n = 5]) async {
    await items.saveAll([
      for (int i = 1; i <= n; i++) Item.of(id: i, name: 'item $i', qty: i, price: i / 2, tags: [i], at: DateTime.utc(2024, 1, i), mood: i.isEven ? Tone.loud : Tone.calm, note: 'note $i'),
    ]);
  }

  group('G29: exactly what was asked', () {
    test('G29: findMaps without columns returns the model fields, never the library bookkeeping', () async {
      await items.save(Item.of(id: 1, timeToLive: const Duration(hours: 1)));
      await items.save(Item.of(id: 2, at: DateTime.utc(2000)));
      final List<Map<String, dynamic>> maps = await items.findMaps(orderBy: 'id');
      for (final Map<String, dynamic> m in maps) {
        for (final String hidden in bookkeeping) {
          expect(m.keys, isNot(contains(hidden)), reason: 'G29: findMaps shows internal column $hidden');
        }
        expect(m.keys.where((k) => k.startsWith('__fluent_')), isEmpty);
        for (final String f in modelFields) {
          expect(m.keys, contains(f), reason: 'G29: findMaps misses model field $f');
        }
      }
      expect(maps[0]['tags'], [1]);
      expect((maps[1]['at'] as DateTime).isUtc, isTrue);
      expect(maps[0]['mood'], Tone.calm);
      // distinct reads the same columns: no bookkeeping there either
      final List<Map<String, dynamic>> distinct = await items.findMaps(distinct: true, orderBy: 'id');
      expect(distinct.first.keys.where(bookkeeping.contains), isEmpty);
      expectCleanIssues();
      await expectIntegrity(items.db);
    });

    test('G29: findMaps(columns:), pluck and aggregate return exactly the requested keys', () async {
      await seed();
      final List<Map<String, dynamic>> some = await items.findMaps(columns: ['name', 'at'], orderBy: 'id');
      expect(some, hasLength(5));
      expect(some.every((m) => m.keys.length == 2 && m.keys.contains('name') && m.keys.contains('at')), isTrue, reason: 'G29: only the requested columns');
      expect((some.first['at'] as DateTime).isUtc, isTrue);
      final List<Map<String, dynamic>> dist = await items.findMaps(columns: ['mood'], distinct: true, orderBy: 'mood');
      expect(dist.every((m) => m.keys.length == 1 && m.keys.first == 'mood'), isTrue);
      expect(dist.map((m) => m['mood']).toSet(), {Tone.calm, Tone.loud});
      expect(await items.pluck<String>('name', orderBy: 'id'), ['item 1', 'item 2', 'item 3', 'item 4', 'item 5']);
      final List<Map<String, dynamic>> agg = await items.aggregate(groupBy: ['mood'], values: {'n': const FluentAggregate.count(), 'total': const FluentAggregate.sum('qty')}, orderBy: 'n DESC');
      expect(agg.every((m) => m.keys.toSet().containsAll({'mood', 'n', 'total'}) && m.keys.length == 3), isTrue, reason: 'G29: aggregate has the group columns and the named values only: $agg');
      expect(agg.map((m) => m['total']).fold<num>(0, (a, b) => a + (b as num)), 15);
      expect(await items.sum('qty'), 15);
      expect(await items.min<DateTime>('at'), DateTime.utc(2024, 1, 1));
      expect((await items.max<DateTime>('at'))!.isUtc, isTrue);
      expectCleanIssues();
    });

    test('G29: a model read back carries exactly the fields it was saved with', () async {
      final List<Item> saved = [
        Item.of(id: 1, name: "O'Brien", qty: -7, price: 2.25, tags: ['a', 1, null, true], at: DateTime.utc(2030, 1, 2, 3, 4, 5, 6), mood: null, blob: Uint8List.fromList([0, 255]), flag: false, note: ''),
        Item.of(id: 2, timeToLive: const Duration(days: 1)),
      ];
      await items.saveAll(saved);
      final List<Item> back = await items.find(orderBy: 'id');
      for (int i = 0; i < saved.length; i++) {

        for (final String f in modelFields) {
          expect(norm(back[i].raw[f]), norm(saved[i].raw[f]), reason: 'G29: field $f of item ${i + 1}');
        }
        expect(back[i].createdAt, isNotNull, reason: 'the library sets the timestamps of the model');
      }
      expectCleanIssues();
    });

    test('G29: a save writes exactly the model fields; the bookkeeping columns hold only what the library puts there', () async {
      await items.save(Item.of(id: 1));
      await items.save(Item.of(id: 2, timeToLive: const Duration(hours: 2)));
      final List<Map<String, Object?>> rows = await rawRows();
      expect(rows.first.keys.toSet(), {...modelFields, '_fs_metadata', 'expiry_date', 'created_at', 'updated_at', 'deleted_at', 'sync_version', 'synced_version'}, reason: 'G29: no other column appears');
      expect(rows[0]['expiry_date'], isNull, reason: 'G29: no timeToLive, no expiry');
      expect(rows[1]['expiry_date'], isA<int>());
      expect(rows[1]['expiry_date'] as int, greaterThan(DateTime.now().millisecondsSinceEpoch), reason: 'the expiry lies in the future');
      expect(rows[0]['deleted_at'], isNull);
      expect(rows[0]['name'], 'n');
      expect(rows[0]['qty'], 1);
      expect(rows[0]['flag'], 1);
      expect(rows[0]['tags'], '[1]');
      expectCleanIssues();
      await expectIntegrity(items.db);
    });

    test('G29: a patch changes only the fields it names; other rows and columns stay byte for byte', () async {
      await seed();
      final List<Map<String, Object?>> before = await rawRows();

      // patch strategy: null fields keep their stored values
      final Item patch = Item({'id': 3, 'name': null, 'qty': 99, 'price': null, 'tags': null, 'at': null, 'mood': null, 'blob': null, 'flag': null, 'note': null});
      await items.save(patch, strategy: FluentSaveStrategy.patch);
      List<Map<String, Object?>> after = await rawRows();
      for (int i = 0; i < before.length; i++) {
        if (before[i]['id'] != 3) {
          expect(after[i], before[i], reason: 'G29: row ${before[i]['id']} must not change');
          continue;
        }
        final Set<String> changed = {for (final String k in before[i].keys) if ('${before[i][k]}' != '${after[i][k]}') k};
        expect(changed.difference({'qty', 'updated_at', 'sync_version'}), isEmpty, reason: 'G29: a patch of qty changed $changed');
        expect(after[i]['qty'], 99);
      }

      // updateById / updateWhere
      final List<Map<String, Object?>> mid = after;
      expect(await items.updateById(2, {'note': 'edited'}), 1);
      after = await rawRows();
      for (int i = 0; i < mid.length; i++) {
        final Set<String> changed = {for (final String k in mid[i].keys) if ('${mid[i][k]}' != '${after[i][k]}') k};
        if (mid[i]['id'] == 2) {
          expect(changed.difference({'note', 'updated_at', 'sync_version'}), isEmpty, reason: 'G29: updateById changed $changed');
          expect(after[i]['note'], 'edited');
        } else {
          expect(changed, isEmpty, reason: 'G29: updateById(2) changed row ${mid[i]['id']}');
        }
      }
      final List<Map<String, Object?>> beforeWhere = after;
      expect(await items.updateWhere(FluentFilter.gte('qty', 5), {'qty': FluentUpdate.increment(1), 'flag': false}), 2);
      after = await rawRows();
      for (int i = 0; i < beforeWhere.length; i++) {
        final Set<String> changed = {for (final String k in beforeWhere[i].keys) if ('${beforeWhere[i][k]}' != '${after[i][k]}') k};
        if ((beforeWhere[i]['qty'] as int) >= 5) {
          expect(changed.difference({'qty', 'flag', 'updated_at', 'sync_version'}), isEmpty, reason: 'G29: updateWhere changed $changed');
          expect(after[i]['flag'], 0);
        } else {
          expect(changed, isEmpty, reason: 'G29: updateWhere changed a row that does not match: ${beforeWhere[i]['id']}');
        }
      }
      expectCleanIssues();
      await expectIntegrity(items.db);
    });

    test('G29/G22: unknown, key and bookkeeping columns in an update are refused typed and change nothing', () async {
      await seed(2);
      final List<Map<String, Object?>> before = await rawRows();
      for (final String column in ['nope', 'id', '_fs_metadata', 'expiry_date', 'sync_version', 'deleted_at', '__fluent_removed_x', 'name; DROP TABLE items']) {
        await expectTyped(() => items.updateById(1, {column: 1}), reason: 'updateById column "$column"');
        await expectTyped(() => items.updateWhere(FluentFilter.gt('qty', 0), {column: 1}), reason: 'updateWhere column "$column"');
      }
      expect(await rawRows(), before, reason: 'G22: nothing written');
      expectCleanIssues(allowed: {FluentIssueKind.schemaFallback});
      await expectIntegrity(items.db);
    });
  });

  group('G22: bad values on save', () {
    final List<Object?> cyclic = <Object?>[];
    cyclic.add(cyclic);
    Object deepList(int depth) {
      Object d = <Object?>[];
      for (int i = 0; i < depth; i++) {
        d = [d];
      }
      return d;
    }

    final Map<String, Item Function()> refused = {
      'NaN price': () => Item.of(price: double.nan),
      'NaN in an int column': () => Item({...Item.of().raw, 'qty': double.nan}),
      'NaN inside a list': () => Item.of(tags: [double.nan]),
      'infinity inside a list': () => Item.of(tags: [double.infinity]),
      'a Set where a list belongs': () => Item({...Item.of().raw, 'tags': {1, 2}}),
      'a cyclic list': () => Item.of(tags: cyclic),
      'a map with non-string keys': () => Item({...Item.of().raw, 'tags': {1: 'a'}}),
      'a DateTime inside JSON': () => Item.of(tags: [DateTime(2000)]),
      'a list nested 100000 deep': () => Item.of(tags: [deepList(100000)]),
      'null in a NOT NULL column': () => Item({...Item.of().raw, 'name': null}),
      'an Object': () => Item({...Item.of().raw, 'qty': Object()}),
      'a function': () => Item({...Item.of().raw, 'qty': () => 1}),
      'a Duration in an enum column': () => Item({...Item.of().raw, 'mood': Duration.zero}),
      'a string key': () => Item({...Item.of().raw, 'id': 'abc'}),
      'a fractional key': () => Item({...Item.of().raw, 'id': 1.5}),
      'a bool of 5 in a bool column': () => Item({...Item.of().raw, 'flag': 5}),
      'a string in a bool column': () => Item({...Item.of().raw, 'flag': 'yes'}),
    };

    for (final MapEntry<String, Item Function()> e in refused.entries) {
      test('G22: ${e.key} is refused typed with a hint and nothing is written', () async {
        await seed(2);
        final List<Map<String, Object?>> before = await rawRows();
        await expectTyped(() => items.save(e.value()), reason: e.key);
        await expectTyped(() => items.saveAll([Item.of(id: 50, name: 'fine'), e.value()]), reason: '${e.key} in a batch');
        expect(await rawRows(), before, reason: 'G1/G22: the failed calls (and the fine row saved with them) wrote nothing');
        // the library still works
        await items.save(Item.of(id: 60, name: 'after'));
        expect(await items.count(), 3);
        expectCleanIssues(allowed: {FluentIssueKind.mappingValue});
        await expectIntegrity(items.db);
      });
    }

    final Map<String, (Item Function(), String, Object? Function(Map<String, dynamic>))> converted = {
      'infinity price': (() => Item.of(price: double.infinity), 'price', (m) => m['price']),
      'negative infinity price': (() => Item.of(price: double.negativeInfinity), 'price', (m) => m['price']),
      'an int in a real column': (() => Item({...Item.of().raw, 'price': 3}), 'price', (m) => m['price']),
      'a whole double in an int column': (() => Item({...Item.of().raw, 'qty': 3.0}), 'qty', (m) => m['qty']),
      'a numeric string in an int column': (() => Item({...Item.of().raw, 'qty': '12'}), 'qty', (m) => m['qty']),
      'a number in a text column': (() => Item({...Item.of().raw, 'name': 5}), 'name', (m) => m['name']),
      'an embedded NUL in a string': (() => Item.of(name: 'a\u0000b'), 'name', (m) => m['name']),
      'a 10 MB string': (() => Item.of(note: 'é' * 5000000), 'note', (m) => m['note']),
      'JSON nested 900 deep': (() => Item.of(tags: [deepList(900)]), 'tags', (m) => m['tags']),
      'unicode keys and values in JSON': (() => Item.of(tags: [{'ключ': '漢字🙂', '': ''}]), 'tags', (m) => m['tags']),
      'an empty blob': (() => Item.of(blob: Uint8List(0)), 'blob', (m) => m['blob']),
      'a 5 MB blob': (() => Item.of(blob: Uint8List.fromList(List<int>.filled(5000000, 7))), 'blob', (m) => m['blob']),
      'the extreme ints': (() => Item.of(qty: -9223372036854775808), 'qty', (m) => m['qty']),
    };

    for (final MapEntry<String, (Item Function(), String, Object? Function(Map<String, dynamic>))> e in converted.entries) {
      test('G22: ${e.key} is stored exactly (or numerically equal) and reads back', () async {
        final Item item = e.value.$1();
        await items.save(item);
        final Item back = (await items.findAll()).single;
        final Object? want = item.raw[e.value.$2];
        final Object? got = e.value.$3(back.raw);
        if (want is num && got is num) {
          expect(got == want || '$got' == '$want', isTrue, reason: 'G22: ${e.key}: saved $want, read $got');
        } else if (e.key == 'a number in a text column') {
          expect(got, '$want', reason: 'a number in a text column is stored as its text');
        } else if (want is String && got is num && want.isNotEmpty) {
          expect(got.toString(), want, reason: 'a numeric string in an int column is stored as that number');
        } else {
          expect(norm(got), norm(want), reason: 'G22: ${e.key} must come back unchanged');
        }
        expectCleanIssues();
        await expectIntegrity(items.db);
      });
    }

    test('G22: a String that is no number is refused for an INTEGER / REAL column', () async {
      await expectTyped(() => items.save(Item({...Item.of().raw, 'qty': 'abc'})), reason: 'qty = "abc"');
      await expectTyped(() => items.save(Item({...Item.of().raw, 'price': 'x'})), reason: 'price = "x"');
      expect(await items.count(), 0);
    });

    test('G22: numeric text that converts without loss stays allowed in INTEGER / REAL columns; other text is refused', () async {
      await items.save(Item({...Item.of().raw, 'id': 1, 'qty': '42', 'price': '1.5'}));
      await items.save(Item({...Item.of().raw, 'id': 2, 'qty': ' 7 ', 'price': '-3e2'}));
      expect((await rawRows()).map((r) => r['qty']), [42, 7]);
      for (final String bad in ['0x10', '', '1,5', 'NaN', '12abc']) {
        await expectTyped(() => items.save(Item({...Item.of().raw, 'id': 9, 'qty': bad})), reason: 'qty = "$bad"');
      }
      await expectTyped(() => items.updateById(1, {'qty': 'abc'}), reason: 'a field update is checked too');
      expect(await items.count(), 2);
      expect((await rawRows()).first['qty'], 42, reason: 'a refused update writes nothing');
    });

    test('G22: a BigInt too big for an INTEGER column is refused instead of being rounded to a double', () async {
      final BigInt huge = BigInt.parse('99999999999999999999');
      await items.save(Item({...Item.of().raw, 'qty': huge, 'id': 1}), strategy: FluentSaveStrategy.upsert).then((_) {}, onError: (_) {});
      final List<Map<String, Object?>> rows = await rawRows();
      expect(rows.where((r) => r['qty'].toString() == '99999999999999999999.0' || r['qty'] is double), isEmpty, reason: 'G22: the value 99999999999999999999 was silently stored as a rounded double');
    });

    test('G22: a BigInt inside int64 is accepted for an INTEGER column, one beyond it is refused and nothing is written', () async {
      await items.save(Item({...Item.of().raw, 'qty': BigInt.from(5), 'id': 2}));
      await expectTyped(() => items.save(Item({...Item.of().raw, 'qty': BigInt.parse('9223372036854775808'), 'id': 3})), reason: 'int64 max + 1');
      expect(await items.count(), 1);
    });

    test('G22: a string with a lone surrogate is refused (or reported) instead of being silently changed to U+FFFD', () async {
      final String broken = 'a${String.fromCharCode(0xD800)}b';
      try {
        await items.save(Item.of(id: 1, name: broken));
      } on FluentException {
        return; // refused: fine
      }
      final Item back = (await items.findAll()).single;
      final bool reported = db.issues.any((i) => i.kind == FluentIssueKind.precisionLost);
      expect(back.raw['name'] == broken || reported, isTrue, reason: 'G22: the text was changed on the way and nobody was told');
    });

    test('G22: a lone surrogate is refused, a valid surrogate pair is stored unchanged', () async {
      await expectTyped(() => items.save(Item.of(id: 2, name: String.fromCharCode(0xDC00))), reason: 'lone low surrogate');
      await expectTyped(() => items.save(Item.of(id: 2, name: 'x${String.fromCharCode(0xD83D)}')), reason: 'trailing high surrogate');
      await items.save(Item.of(id: 3, name: 'ok \u{1F600}'));
      expect((await items.findById(3))!.raw['name'], 'ok \u{1F600}');
      expect(await items.count(), 1);
    });

    test('G22: unknown stored enum values read back as null with a warning that has a fix; a read never throws', () async {
      await seed(3);
      await items.db.rawUpdate("UPDATE items SET mood = 'zzz' WHERE id = 1");
      await items.db.rawUpdate('UPDATE items SET mood = 99 WHERE id = 2');
      final List<Item> all = await items.find(orderBy: 'id');
      expect(all[0].raw['mood'], isNull);
      expect(all[1].raw['mood'], isNull);
      expect(all[2].raw['mood'], Tone.calm);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.mappingValue), isNotEmpty, reason: 'G25: the unknown value is reported');
      expectCleanIssues(allowed: {FluentIssueKind.mappingValue});
      await expectIntegrity(items.db);
    });

    test('G22: raw rows with values of the wrong type read back as stored values or typed errors, never crash', () async {
      await seed(3);
      await items.db.rawUpdate("UPDATE items SET tags = '{broken json', at = 'not a date', qty = 'many', price = x'00' WHERE id = 1");
      Object? error;
      List<Item>? rows;
      try {
        rows = await items.find(orderBy: 'id');
      } catch (e) {
        error = e;
      }
      if (error != null) {
        expectTypedError(error, reason: 'damaged rows');
      } else {
        expect(rows, hasLength(3), reason: 'G22: the undamaged rows are read');
      }
      expect(await items.count(), 3, reason: 'the damaged row still counts');
      expect(await items.pluck<int>('id', orderBy: 'id'), [1, 2, 3]);
      expectCleanIssues(allowed: {FluentIssueKind.mappingValue});
      await expectIntegrity(items.db);
    });
  });

  group('G22: bad input on reads', () {
    test('G22: 50 000 ids: findByIds answers exactly; one WHERE with that many ids is refused typed or answered exactly', () async {
      await seed(100);
      final List<int> ids = List<int>.generate(50000, (i) => i + 1);
      expect((await items.findByIds(ids)).map((m) => m.raw['id']), List<int>.generate(100, (i) => i + 1), reason: 'G22: every existing id once, in order');
      final List<int> thirds = ids.where((i) => i % 3 == 0).toList();
      expect((await items.findByIds(thirds)).map((m) => m.raw['id']).toSet(), {for (int i = 3; i <= 99; i += 3) i});
      // A single WHERE cannot be split: the library refuses it typed (documented) instead of failing in SQLite.
      Future<void> exactOrTyped(Future<int> Function() run, int expected, String what) async {
        Object? error;
        int? got;
        try {
          got = await run();
        } catch (e) {
          error = e;
        }
        if (error != null) {
          expectTypedError(error, reason: what);
        } else {
          expect(got, expected, reason: 'G22: $what');
        }
      }

      await exactOrTyped(() => items.count(where: FluentFilter.ids(ids)), 100, 'ids(50000)');
      await exactOrTyped(() => items.count(where: FluentFilter.inList('qty', ids)), 100, 'inList(50000)');
      await exactOrTyped(() => items.count(where: FluentFilter.notInList('qty', ids)), 0, 'notInList(50000)');
      expect(await items.count(where: FluentFilter.ids(const [])), 0);
      expect(await items.count(where: FluentFilter.inList('qty', const [])), 0);
      expect(await items.count(), 100, reason: 'nothing changed');
      expectCleanIssues();
    });

    test('G22: garbage cursor text is refused typed with a hint', () {
      final String validJson = base64Url.encode(utf8.encode('{"o":"id","d":false,"v":1,"k":{"id":1}}'));
      final List<String> garbage = [
        '',
        '!!!',
        'abc',
        'e30=', // {}
        'W10=', // []
        base64Url.encode(utf8.encode('{"o":1}')),
        base64Url.encode(utf8.encode('{"o":"id","d":"no","v":1,"k":{}}')),
        base64Url.encode(utf8.encode('{"o":"id","d":false,"v":1}')),
        base64Url.encode(utf8.encode('not json')),
        base64Url.encode(const [0xff, 0xfe, 0xfd]),
        validJson.substring(0, validJson.length ~/ 2),
        '${validJson}ZZZ',
        'x' * 100000,
      ];
      for (final String text in garbage) {
        Object? error;
        try {
          FluentCursor.decode(text);
        } catch (e) {
          error = e;
        }
        expect(error, isNotNull, reason: 'G22: "${text.length > 30 ? '${text.substring(0, 30)}...' : text}" is no cursor');
        expectTypedError(error!, reason: 'cursor text');
      }
      // a valid one still works
      expect(FluentCursor.decode(validJson).orderBy, 'id');
    });

    test('G22: a cursor of another order, a wrong value type or an incomplete key never crashes findPage', () async {
      await seed(10);
      final FluentPage<Item> first = await items.findPage(orderBy: 'qty', limit: 3);
      final List<FluentCursor> odd = [
        FluentCursor(orderBy: 'name', descending: false, value: 'x', key: first.next!.key),
        FluentCursor(orderBy: 'qty', descending: true, value: first.next!.value, key: first.next!.key),
        FluentCursor(orderBy: 'qty', descending: false, value: 'zzz', key: first.next!.key),
        FluentCursor(orderBy: 'qty', descending: false, value: 3, key: const {}),
        FluentCursor(orderBy: 'qty', descending: false, value: 3, key: const {'nope': 1}),
        FluentCursor(orderBy: 'qty', descending: false, value: null, key: first.next!.key),
        FluentCursor(orderBy: 'qty', descending: false, value: double.nan, key: first.next!.key),
        FluentCursor(orderBy: 'qty', descending: false, value: Uint8List(2), key: first.next!.key),
      ];
      for (final FluentCursor c in odd) {
        Object? error;
        FluentPage<Item>? page;
        try {
          page = await items.findPage(orderBy: 'qty', limit: 3, after: c);
        } catch (e) {
          error = e;
        }
        if (error != null) {
          expectTypedError(error, reason: 'cursor $c');
        } else {
          expect(page!.items.length, lessThanOrEqualTo(3), reason: 'a cursor with odd values still gives a page of at most the limit');
        }
      }
      expectCleanIssues();
    });

    test('G22: orderBy and column injection attempts are refused typed; the table and its rows are untouched', () async {
      await seed();
      final List<Map<String, Object?>> before = await rawRows();
      final List<String> attempts = [
        'id; DROP TABLE items',
        'id; DELETE FROM items',
        'id) UNION SELECT 1 --',
        '(SELECT 1)',
        "id, (SELECT name FROM items LIMIT 1)",
        'id DESC; --',
        'name --',
        '1',
        "name' OR '1'='1",
        'id /* x */',
        'randomblob(10)',
        'nope',
        '',
        '   ',
        ',',
        'id,',
        'id DESC DESC',
        'id UP',
        '"id"; DROP TABLE items; --',
      ];
      for (final String order in attempts) {
        await expectTyped(() => items.find(orderBy: order), reason: 'find orderBy "$order"');
        await expectTyped(() => items.findMaps(orderBy: order), reason: 'findMaps orderBy "$order"');
        await expectTyped(() => items.findFirst(orderBy: order), reason: 'findFirst orderBy "$order"');
        await expectTyped(() => items.pluck<int>('id', orderBy: order), reason: 'pluck orderBy "$order"');
        await expectTyped(() => items.watch(orderBy: order).first.timeout(const Duration(seconds: 5)), reason: 'watch orderBy "$order"');
      }
      for (final String order in ['id; DROP TABLE items', '(SELECT 1)', 'nope', 'id) --']) {
        await expectTyped(() => items.findPage(orderBy: order), reason: 'findPage orderBy "$order"');
        await expectTyped(() => items.aggregate(values: {'n': const FluentAggregate.count()}, orderBy: order), reason: 'aggregate orderBy "$order"');
      }
      for (final String column in ['id, name FROM items --', 'id; DROP TABLE items', '*', 'nope', '', 'name AS x', '"id"']) {
        await expectTyped(() => items.findMaps(columns: [column]), reason: 'findMaps column "$column"');
        await expectTyped(() => items.pluck<Object?>(column), reason: 'pluck column "$column"');
        await expectTyped(() => items.aggregate(groupBy: [column], values: {'n': const FluentAggregate.count()}), reason: 'aggregate groupBy "$column"');
        await expectTyped(() => items.sum(column), reason: 'sum column "$column"');
        await expectTyped(() => items.min<Object>(column), reason: 'min column "$column"');
      }
      expect(await rawRows(), before, reason: 'G22: nothing changed');
      // the accepted forms still work
      for (final String ok in ['abs(id)', 'items.id', 'name', 'name DESC', 'qty ASC, id DESC', 'name COLLATE NOCASE', 'qty DESC NULLS LAST', '"name"', 'id']) {
        expect(await items.find(orderBy: ok), hasLength(5), reason: 'orderBy "$ok" is valid');
      }
      expectCleanIssues(allowed: {FluentIssueKind.schemaFallback});
      await expectIntegrity(items.db);
    });

    test('G22: filter values of the wrong type or with SQL in them never match by accident, never throw untyped', () async {
      await seed();
      await items.save(Item.of(id: 20, name: '100% sure', note: "a_b\\c'd"));
      await items.save(Item.of(id: 21, name: 'x', note: 'axb'));
      final List<Map<String, Object?>> before = await rawRows();
      Future<List<int>> ids(FluentFilter f) async => [for (final Item i in await items.find(where: f, orderBy: 'id')) i.raw['id'] as int];

      expect(await ids(FluentFilter.eq('name', "x' OR '1'='1")), isEmpty);
      expect(await ids(FluentFilter.eq('name', "'; DROP TABLE items; --")), isEmpty);
      expect(await ids(FluentFilter.contains('name', '%')), [20], reason: 'a % is literal');
      expect(await ids(FluentFilter.contains('note', '_')), [20], reason: 'a _ is literal');
      expect(await ids(FluentFilter.contains('note', r'\')), [20], reason: 'a backslash is literal');
      expect(await ids(FluentFilter.startsWith('name', '100%')), [20]);
      expect(await ids(FluentFilter.endsWith('note', "'d")), [20]);
      expect(await ids(FluentFilter.like('name', 'item _')), [1, 2, 3, 4, 5]);
      // values that cannot match: no rows, no error
      expect(await ids(FluentFilter.eq('qty', 'abc')), isEmpty);
      expect(await ids(FluentFilter.eq('qty', Uint8List(1))), isEmpty);
      expect(await ids(FluentFilter.eq('at', 'not a date')), isEmpty);
      expect(await ids(FluentFilter.eq('mood', 99)), isEmpty);
      expect(await ids(FluentFilter.eq('mood', 'zzz')), isEmpty);
      expect(await ids(FluentFilter.eq('price', double.nan)), isEmpty, reason: 'NaN never equals anything');
      expect(await ids(FluentFilter.between('qty', 5, 1)), isEmpty);
      expect(await ids(FluentFilter.between('qty', 2, 3)), [2, 3]);
      expect(await ids(FluentFilter.inList('mood', [Tone.loud])), [2, 4]);
      expect(await ids(FluentFilter.inList('mood', ['loud', 1])), [2, 4], reason: 'a name or an index finds the same enum');
      expect(await ids(FluentFilter.gt('price', double.infinity)), isEmpty);
      expect(await ids(FluentFilter.lt('price', double.infinity)), isNotEmpty);
      expect(await ids(FluentFilter.eq('flag', true)), isNotEmpty);
      expect(await ids(FluentFilter.eq('flag', 'true')), isEmpty);
      expect(await ids(FluentFilter.eq('tags', [1])), [1, 20, 21], reason: 'a list is compared as its JSON');
      // a filter on a column that does not exist is a typed error
      await expectTyped(() => items.find(where: FluentFilter.eq('nope', 1)), reason: 'unknown column');
      await expectTyped(() => items.count(where: FluentFilter.eq('nope', 1)), reason: 'unknown column in count');
      // a value no codec takes is refused typed
      await expectTyped(() => items.find(where: FluentFilter.eq('qty', Object())), reason: 'Object as filter value');
      await expectTyped(() => items.find(where: FluentFilter.eq('tags', {1: 2})), reason: 'map with int keys as filter value');
      expect(await rawRows(), before, reason: 'G22: nothing changed');
      expectCleanIssues(allowed: {FluentIssueKind.schemaFallback});
      await expectIntegrity(items.db);
    });

    test('G22: wrong limits, offsets and ids are refused typed or answered with nothing; nothing crashes', () async {
      await seed();
      await expectTyped(() => items.find(limit: -1), reason: 'limit -1');
      await expectTyped(() => items.find(limit: 1, offset: -1), reason: 'offset -1');
      await expectTyped(() => items.findPage(limit: 0), reason: 'page limit 0');
      await expectTyped(() => items.findPage(limit: -5), reason: 'page limit -5');
      expect(await items.find(limit: 0), isEmpty);
      expect(await items.find(limit: 9223372036854775807, orderBy: 'id'), hasLength(5));
      expect(await items.find(limit: 2, offset: 9223372036854775807, orderBy: 'id'), isEmpty);
      for (final Object? id in <Object?>[null, 'abc', 1.5, double.nan, double.infinity, 999999999999, -1, [], <Object?>[1], Object()]) {
        Object? error;
        Item? found;
        try {
          found = await items.findById(id);
        } catch (e) {
          error = e;
        }
        if (error != null) {
          expectTypedError(error, reason: 'findById($id)');
        } else {
          expect(found, isNull, reason: 'G22: findById($id) finds nothing');
        }
        Object? error2;
        try {
          await items.exists(id);
          await items.updateById(id, {'note': 'x'});
          await items.deleteById(id);
        } catch (e) {
          error2 = e;
        }
        if (error2 != null) expectTypedError(error2, reason: 'id $id');
      }
      expect(await items.count(), 5, reason: 'nothing was deleted by the odd ids');
      expectCleanIssues();
      await expectIntegrity(items.db);
    });
  });

  group('G22: random strings and values', () {
    for (final int seed in fuzzSeeds(base: 70100)) {
      test('G22: random strings (quotes, wildcards, unicode) are stored, found by eq / contains / startsWith, and never act as SQL (seed $seed)', () async {
        final FluentFuzz fuzz = FluentFuzz(seed);
        final List<String> names = {for (int i = 0; i < 12; i++) fuzz.string(max: 20)}.toList();
        names.add("x'); DROP TABLE items; --");
        await items.saveAll([for (int i = 0; i < names.length; i++) Item.of(id: i + 1, name: names[i], note: names[(i + 1) % names.length])]);
        for (int i = 0; i < names.length; i++) {
          final String n = names[i];
          final Set<int> expected = {for (int k = 0; k < names.length; k++) if (names[k] == n) k + 1};
          final Set<int> got = {for (final Item m in await items.find(where: FluentFilter.eq('name', n))) m.raw['id'] as int};
          expect(got, expected, reason: 'G22 seed $seed: eq "$n"');
          if (n.isNotEmpty) {
            // LIKE ignores the case of ASCII letters only (startsWith / contains are LIKE patterns).
            final Set<int> startsWith = {for (int k = 0; k < names.length; k++) if (_asciiLower(names[k]).startsWith(_asciiLower(n))) k + 1};
            expect({for (final Item m in await items.find(where: FluentFilter.startsWith('name', n))) m.raw['id'] as int}, startsWith, reason: 'G22 seed $seed: startsWith "$n"');
            final Set<int> contains = {for (int k = 0; k < names.length; k++) if (_asciiLower(names[k]).contains(_asciiLower(n))) k + 1};
            expect({for (final Item m in await items.find(where: FluentFilter.contains('name', n))) m.raw['id'] as int}, contains, reason: 'G22 seed $seed: contains "$n" (LIKE is case-insensitive for ASCII)');
          }
        }
        expect((await items.findAll(orderBy: 'id')).map((m) => m.raw['name']).toList(), names, reason: 'G6 seed $seed: names round trip');
        expect(await items.count(), names.length);
        expectCleanIssues();
        await expectIntegrity(items.db);
      });
    }
  });
}

/// [s] with ASCII letters in lower case: how SQLite's `LIKE` compares (other letters keep their case).
String _asciiLower(String s) => s.replaceAllMapped(RegExp('[A-Z]'), (Match m) => m[0]!.toLowerCase());
