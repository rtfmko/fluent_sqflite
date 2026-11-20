// Stress: one big table of wide rows (G1, G6, G7, G12, G16, G19 on a big world).
//
// scaled(5000) rows of nine columns of every built-in kind (int, double, bool, UTC DateTime, text, blob, JSON list),
// with ties in the paging column, a share of wide rows (256 KB text + 64 KB blob) and three huge ones (4 MB + 4 MB).
// Steps: bulk insert, count, a keyset walk over every page, a full read compared with the reference, a burst of
// unawaited writes and reads (every read sees the writes called before it), a rolled-back and a committed big
// transaction, the full comparison again and the file's integrity.
//
// FLUENT_STRESS=20 bash tool/mirror_test.sh stress test/stress/big_db_stress_test.dart
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/guarantees.dart';
import 'stress.dart';

class Wide extends FluentStorable {
  Wide({required this.id, required this.name, required this.n, required this.price, required this.flag, required this.at, required this.blob, required this.body, required this.tags});

  final int id;
  final String name;
  final int n;
  final double price;
  final bool flag;
  final DateTime at;
  final Uint8List blob;
  final String body;
  final List<String> tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'n': n, 'price': price, 'flag': flag, 'at': at, 'blob': blob, 'body': body, 'tags': tags};

  @override
  List<FluentIndex> get indexes => const [FluentIndex(['n'])];

  Wide copy({String? name, int? n}) => Wide(id: id, name: name ?? this.name, n: n ?? this.n, price: price, flag: flag, at: at, blob: blob, body: body, tags: tags);

  /// Field by field (instants and the UTC flag of [at], bytes of [blob]).
  bool same(Wide o) =>
      id == o.id && name == o.name && n == o.n && price == o.price && flag == o.flag && at == o.at && at.isUtc == o.at.isUtc &&
      const ListEquality<int>().equals(blob, o.blob) && body == o.body && const ListEquality<String>().equals(tags, o.tags);

  @override
  String toString() => 'Wide($id, $name, n $n, body ${body.length}, blob ${blob.length})';
}

class WideProvider extends FluentProvider<Wide> {
  @override
  String get tableName => 'wide';

  @override
  Wide get modelSample => Wide(id: 0, name: '', n: 0, price: 0.5, flag: false, at: DateTime.utc(2000), blob: Uint8List(1), body: '', tags: const ['']);

  @override
  Wide fromCacheJson(Map<String, dynamic> json) => Wide(
    id: json['id'] as int,
    name: json['name'] as String,
    n: json['n'] as int,
    price: (json['price'] as num).toDouble(),
    flag: json['flag'] as bool,
    at: json['at'] as DateTime,
    blob: json['blob'] as Uint8List,
    body: json['body'] as String,
    tags: (json['tags'] as List).cast<String>(),
  );
}

void main() {
  setUpFluentTests();

  test('a big table of wide rows keeps every guarantee', timeout: Timeout(stressLimit(secondsPerScale: 120)), () async {
    final StressReport report = StressReport('big table of wide rows');
    final Random r = Random(4242);
    final int total = scaled(5000);
    final FluentTestDb db = FluentTestDb(name: 'stress_big', persistent: true);
    final WideProvider p = WideProvider();
    await db.open([p]);
    final Map<int, Wide> ref = {};

    String text(int length) => String.fromCharCodes([for (int i = 0; i < length; i++) 32 + r.nextInt(0x24F - 32)]);
    Uint8List bytes(int length) => Uint8List.fromList([for (int i = 0; i < length; i++) r.nextInt(256)]);
    int wideRows = 0;
    Wide make(int id) {
      final bool huge = id <= 3;
      final bool wide = !huge && id % 50 == 0 && wideRows++ < 200;
      return Wide(
        id: id,
        name: text(r.nextInt(40)),
        n: r.nextInt(max(1, total ~/ 3)), // ties: about three rows per value
        price: (r.nextDouble() - 0.5) * 1e6,
        flag: r.nextBool(),
        at: DateTime.fromMillisecondsSinceEpoch(r.nextInt(1 << 31) * 1000 + r.nextInt(1000), isUtc: true),
        blob: bytes(huge ? 4 << 20 : wide ? 64 << 10 : r.nextInt(256)),
        body: huge ? 'x' * (4 << 20) : wide ? text(256 << 10) : text(r.nextInt(200)),
        tags: [for (int i = r.nextInt(6); i > 0; i--) text(8)],
      );
    }

    await report.step('insert $total rows in batches of 500', () async {
      for (int from = 1; from <= total; from += 500) {
        final List<Wide> batch = [for (int id = from; id < min(from + 500, total + 1); id++) make(id)];
        await p.saveAll(batch);
        for (final Wide w in batch) {
          ref[w.id] = w;
        }
      }
    });
    expect(await p.count(), total, reason: 'G1: every row of every batch is there');

    // G16: a keyset walk over a column with ties returns every row exactly once, in (n, id) order.
    final List<Wide> walked = await report.step('keyset walk, pages of 700', () async {
      final List<Wide> all = [];
      FluentCursor? after;
      do {
        final FluentPage<Wide> page = await p.findPage(orderBy: 'n', limit: 700, after: after);
        all.addAll(page.items);
        after = page.next;
      } while (after != null);
      return all;
    }, detail: (all) => '${all.length} rows');
    final List<int> expectedOrder = (ref.values.toList()..sort((a, b) => a.n != b.n ? a.n.compareTo(b.n) : a.id.compareTo(b.id))).map((w) => w.id).toList();
    expect(walked.map((w) => w.id).toList(), expectedOrder, reason: 'G16: every row once, in order');

    Future<void> expectAllSame(String why) async {
      final List<Wide> all = await report.step('full read ($why)', () => p.findAll(orderBy: 'id'), detail: (all) => '${all.length} rows');
      expect(all.length, ref.length, reason: '$why: row count');
      for (final Wide w in all) {
        final Wide? e = ref[w.id];
        if (e == null || !w.same(e)) fail('G6 $why: row ${w.id} reads back as $w, expected $e');
      }
    }

    await expectAllSame('after the insert');

    // G7 / G12: a burst of unawaited calls; each read sees every write called before it.
    final int burst = scaled(1000);
    final List<Future<Object?>> calls = [];
    final List<String> names = [];
    final List<void Function(Object? value)> checks = [];
    final List<int> ids = ref.keys.toList();
    await report.step('burst of $burst unawaited calls', () async {
      for (int i = 0; i < burst; i++) {
        final int id = ids[r.nextInt(ids.length)];
        switch (r.nextInt(6)) {
          case 0 || 1:
            final Wide changed = (ref[id] ?? make(id)).copy(name: 'v$i', n: r.nextInt(1000));
            ref[id] = changed;
            calls.add(p.save(changed));
            names.add('save $id');
            checks.add((_) {});
          case 2:
            final bool existed = ref.remove(id) != null;
            calls.add(p.deleteById(id));
            names.add('deleteById $id');
            checks.add((v) => expect(v, existed ? 1 : 0, reason: 'G7: deleteById $id (call $i)'));
          case 3:
            final int count = ref.length;
            calls.add(p.count());
            names.add('count');
            checks.add((v) => expect(v, count, reason: 'G7: count sees every write before it (call $i)'));
          default:
            final Wide? expected = ref[id];
            calls.add(p.findById(id));
            names.add('findById $id');
            checks.add((v) {
              final Wide? got = v as Wide?;
              if (expected == null ? got != null : got == null || !got.same(expected)) fail('G7: findById $id (call $i) read $got, expected $expected');
            });
        }
      }
      final List<Settled> settled = await waitAllSettled(calls, names: names, timeout: stressLimit(secondsPerScale: 30));
      for (int i = 0; i < settled.length; i++) {
        if (settled[i].failed) fail('${names[i]} failed: ${settled[i].error}');
        checks[i](settled[i].value);
      }
    });

    // G1: a big transaction that fails changes nothing; one that commits changes every row.
    final List<Wide> some = ref.values.take(min(ref.length, scaled(1000))).toList();
    await report.step('rolled-back transaction of ${some.length} saves', () async {
      Object? error;
      try {
        await FluentDb.transaction(() async {
          await p.saveAll([for (final Wide w in some) w.copy(name: 'rolled back')]);
          await p.deleteWhere(FluentFilter.ids(some.take(10).map((w) => w.id).toList()));
          throw StateError('roll back');
        }, dbKey: db.key);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'the transaction rethrows');
    });
    await expectAllSame('after the rollback');
    await report.step('committed transaction of ${some.length} saves', () async {
      await FluentDb.transaction(() async {
        await p.saveAll([for (final Wide w in some) w.copy(name: 'committed')]);
      }, dbKey: db.key);
      for (final Wide w in some) {
        ref[w.id] = w.copy(name: 'committed');
      }
    });
    await expectAllSame('after the commit');

    await expectIntegrity(p.db, reason: 'stress big table');
    expect(db.warnings, isEmpty, reason: 'no warnings: ${db.warnings.map((i) => i.title).join('; ')}');
    await db.close();
    report.save();
  });
}
