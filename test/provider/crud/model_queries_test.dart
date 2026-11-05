// Model-level queries: projections (findMaps columns, pluck), aggregates, watchValue.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

enum OrderStatus { open, paid, cancelled }

class Order extends FluentStorable with FluentSoftDeletable {
  Order({this.id, required this.status, required this.total, required this.placedAt, this.tags = const [], this.note});

  final int? id;
  final OrderStatus status;
  final double total;
  final DateTime placedAt;
  final List<String> tags;
  final String? note;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'status': status, 'total': total, 'placed_at': placedAt, 'tags': tags, 'note': note};

  @override
  Map<String, List<Enum>> get enumValues => {'status': OrderStatus.values};
}

class OrderProvider extends FluentProvider<Order> {
  @override
  String get tableName => 'orders';

  @override
  Order get modelSample => Order(status: OrderStatus.open, total: 0, placedAt: DateTime(2000), tags: const [''], note: '');

  @override
  Order fromCacheJson(Map<String, dynamic> json) => Order(
    id: json['id'] as int?,
    status: json['status'] as OrderStatus,
    total: (json['total'] as num).toDouble(),
    placedAt: json['placed_at'] as DateTime,
    tags: (json['tags'] as List).cast<String>(),
    note: json['note'] as String?,
  );
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late OrderProvider orders;
  final DateTime day = DateTime(2026, 10, 2);

  setUp(() async {
    db = FluentTestDb(name: 'model_queries_${DateTime.now().microsecondsSinceEpoch}');
    orders = OrderProvider();
    await db.open([orders]);
    await orders.saveAll([
      Order(status: OrderStatus.paid, total: 10, placedAt: day, tags: const ['a']),
      Order(status: OrderStatus.paid, total: 30, placedAt: day.add(const Duration(days: 2)), tags: const ['b']),
      Order(status: OrderStatus.open, total: 5, placedAt: day.add(const Duration(days: 1))),
      Order(status: OrderStatus.cancelled, total: 100, placedAt: day.add(const Duration(days: 3))),
    ]);
    await orders.deleteWhere(FluentFilter.eq('status', OrderStatus.cancelled)); // in the trash: never counted
  });

  tearDown(() => db.close());

  group('projections', () {
    test('findMaps returns Dart values and only the asked columns', () async {
      final List<Map<String, dynamic>> all = await orders.findMaps(orderBy: 'id');
      expect(all.first['status'], OrderStatus.paid);
      expect(all.first['placed_at'], day);
      expect(all.first['tags'], ['a']);
      expect(all.first.containsKey('_fs_metadata'), isFalse);

      final List<Map<String, dynamic>> light = await orders.findMaps(columns: ['id', 'placed_at'], orderBy: 'id');
      expect(light, hasLength(3));
      expect(light.first.keys, unorderedEquals(['id', 'placed_at']));
      expect(light.first['placed_at'], day);
    });

    test('pluck returns typed values; distinct; wrong type or column fail with a hint', () async {
      expect(await orders.pluck<OrderStatus>('status', distinct: true, orderBy: 'status'), [OrderStatus.open, OrderStatus.paid]);
      expect(await orders.pluck<DateTime>('placed_at', orderBy: 'placed_at'), [day, day.add(const Duration(days: 1)), day.add(const Duration(days: 2))]);
      expect(await orders.pluck<String?>('note'), [null, null, null]);
      await expectLater(orders.pluck<int>('status'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('pluck<OrderStatus>'))));
      await expectLater(orders.findMaps(columns: ['totl']), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('total'))));
    });
  });

  group('aggregates', () {
    test('sum, avg, min, max, countDistinct skip the trash and return Dart values', () async {
      expect(await orders.sum('total'), 45);
      expect(await orders.withTrash.sum('total'), 145);
      expect(await orders.avg('total'), 15);
      expect(await orders.min<DateTime>('placed_at'), day);
      expect(await orders.max<OrderStatus>('status'), OrderStatus.paid, reason: 'by stored name: "paid" > "open"');
      expect(await orders.countDistinct('status'), 2);
    });

    test('an empty set: sum 0, avg / min / max null', () async {
      final FluentFilter none = FluentFilter.gt('total', 1000);
      expect(await orders.sum('total', where: none), 0);
      expect(await orders.avg('total', where: none), isNull);
      expect(await orders.max<DateTime>('placed_at', where: none), isNull);
      expect(await orders.countDistinct('status', where: none), 0);
    });

    test('aggregate groups, filters with having on result names, orders and decodes group columns', () async {
      final List<Map<String, dynamic>> rows = await orders.aggregate(
        groupBy: ['status'],
        values: {'orders': const FluentAggregate.count(), 'total': const FluentAggregate.sum('total'), 'last': const FluentAggregate.max('placed_at')},
        orderBy: 'total DESC',
      );
      expect(rows, [
        {'status': OrderStatus.paid, 'orders': 2, 'total': 40, 'last': day.add(const Duration(days: 2))},
        {'status': OrderStatus.open, 'orders': 1, 'total': 5, 'last': day.add(const Duration(days: 1))},
      ]);
      final List<Map<String, dynamic>> big = await orders.aggregate(groupBy: ['status'], values: {'total': const FluentAggregate.sum('total')}, having: FluentFilter.gt('total', 10));
      expect(big.single['status'], OrderStatus.paid, reason: '"total" in having is the sum, not the column');
    });

    test('sum of a non-numeric column and bad names fail with a hint', () async {
      await expectLater(orders.sum('placed_at'), throwsA(isA<FluentArgumentException>().having((e) => e.hint, 'hint', contains('min / max'))));
      await expectLater(orders.aggregate(values: const {}), throwsA(isA<FluentArgumentException>()));
      await expectLater(orders.aggregate(groupBy: ['status'], values: {'status': const FluentAggregate.count()}), throwsA(isA<FluentArgumentException>()));
    });

    test('FluentDb statics', () async {
      expect(await FluentDb.sum<Order>('total'), 45);
      expect(await FluentDb.pluck<Order, OrderStatus>('status', distinct: true, orderBy: 'status'), hasLength(2));
      expect((await FluentDb.aggregate<Order>(values: {'n': const FluentAggregate.count()})).single['n'], 3);
    });
  });

  test('watchValue emits now and after changes, skipping equal results', () async {
    final List<num> seen = [];
    final sub = orders.watchValue(() => orders.sum('total')).listen(seen.add);
    await db.settle();
    await orders.save(Order(status: OrderStatus.open, total: 5, placedAt: day));
    await db.settle();
    await orders.updateWhere(FluentFilter.eq('total', 5.0), {'note': 'x'}); // the sum does not change
    await db.settle();
    await sub.cancel();
    expect(seen, [45, 50]);
  });
}
