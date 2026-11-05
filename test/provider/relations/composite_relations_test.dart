// Relations to and from tables with a composite primary key: the references span several columns.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Composite key (region, code).
class Warehouse extends FluentStorable with FluentRelations {
  Warehouse({required this.region, required this.code, required this.name, this.bins, this.items});

  final String region;
  final int code;
  final String name;
  final List<Bin>? bins;
  final List<Item>? items;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('region'), FluentDbColumn.integer('code')];

  @override
  Map<String, dynamic> buildJson() => {'region': region, 'code': code, 'name': name};

  @override
  List<FluentRelation> get relations => [
    FluentRelation.many<Warehouse, Bin>('bins', (w) => w.bins, orderBy: 'label'),
    FluentRelation.manyToMany<Warehouse, Item>('items', (w) => w.items, orderBy: 'sku'),
  ];
}

class Bin extends FluentStorable {
  Bin({this.id, required this.label});

  final int? id;
  final String label;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label};
}

/// Composite key (sku, size).
class Item extends FluentStorable {
  Item({required this.sku, required this.size, required this.title});

  final String sku;
  final String size;
  final String title;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.text('sku'), FluentDbColumn.text('size')];

  @override
  Map<String, dynamic> buildJson() => {'sku': sku, 'size': size, 'title': title};
}

/// Plain key, references a composite-key warehouse.
class Shipment extends FluentStorable with FluentRelations {
  Shipment({this.id, required this.title, this.warehouse});

  final int? id;
  final String title;
  final Warehouse? warehouse;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<Shipment, Warehouse>('warehouse', (s) => s.warehouse)];
}

class WarehouseProvider extends FluentProvider<Warehouse> {
  @override
  String get tableName => 'warehouses';

  @override
  Warehouse get modelSample => Warehouse(region: '', code: 0, name: '');

  @override
  Warehouse fromCacheJson(Map<String, dynamic> json) => Warehouse(
    region: json['region'] as String,
    code: json['code'] as int,
    name: json['name'] as String,
    bins: (json['bins'] as List?)?.cast<Bin>(),
    items: (json['items'] as List?)?.cast<Item>(),
  );
}

class BinProvider extends FluentProvider<Bin> {
  @override
  String get tableName => 'bins';

  @override
  Bin get modelSample => Bin(label: '');

  @override
  Bin fromCacheJson(Map<String, dynamic> json) => Bin(id: json['id'] as int?, label: json['label'] as String);
}

class ItemProvider extends FluentProvider<Item> {
  @override
  String get tableName => 'items';

  @override
  Item get modelSample => Item(sku: '', size: '', title: '');

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(sku: json['sku'] as String, size: json['size'] as String, title: json['title'] as String);
}

class ShipmentProvider extends FluentProvider<Shipment> {
  @override
  String get tableName => 'shipments';

  @override
  Shipment get modelSample => Shipment(title: '');

  @override
  Shipment fromCacheJson(Map<String, dynamic> json) => Shipment(id: json['id'] as int?, title: json['title'] as String, warehouse: json['warehouse'] as Warehouse?);
}

Future<List<String>> columns(Database db, String table) async => [for (final r in await db.rawQuery("PRAGMA table_info('$table')")) r['name']! as String];

Future<List<Map<String, Object?>>> rows(Database db, String table) => db.rawQuery('SELECT * FROM "$table"');

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late WarehouseProvider warehouses;
  late ShipmentProvider shipments;
  late ItemProvider items;
  late Database sql;

  setUp(() async {
    db = FluentTestDb(name: 'composite_rel_${DateTime.now().microsecondsSinceEpoch}');
    warehouses = WarehouseProvider();
    shipments = ShipmentProvider();
    items = ItemProvider();
    await db.open([warehouses, BinProvider(), items, shipments]);
    sql = warehouses.db;
  });

  tearDown(() => db.close());

  Warehouse north() => Warehouse(
    region: 'north',
    code: 1,
    name: 'North 1',
    bins: [Bin(label: 'A'), Bin(label: 'B')],
    items: [Item(sku: 'tee', size: 'M', title: 'Tee M'), Item(sku: 'tee', size: 'L', title: 'Tee L')],
  );

  test('schema: one reference column per key column and a table-level FOREIGN KEY', () async {
    expect(await columns(sql, 'shipments'), containsAll(['warehouse_region', 'warehouse_code']));
    expect(await columns(sql, 'bins'), containsAll(['warehouse_region', 'warehouse_code']));
    expect(await columns(sql, 'items_warehouses'), containsAll(['warehouse_region', 'warehouse_code', 'item_sku', 'item_size']));

    final fks = await sql.rawQuery("PRAGMA foreign_key_list('shipments')");
    expect({for (final r in fks) '${r['from']}->${r['table']}.${r['to']}'}, {'warehouse_region->warehouses.region', 'warehouse_code->warehouses.code'});
    expect(fks.map((r) => r['id']).toSet(), hasLength(1), reason: 'one multi-column constraint, not two single ones');
  });

  test('save and load a graph with composite keys on both sides', () async {
    await warehouses.save(north());
    await warehouses.save(Warehouse(region: 'north', code: 2, name: 'North 2', bins: [Bin(label: 'Z')]));

    final loaded = await warehouses.findById(FluentKey({'region': 'north', 'code': 1}));
    expect(loaded!.bins!.map((b) => b.label), ['A', 'B']);
    expect(loaded.items!.map((i) => '${i.sku}/${i.size}'), unorderedEquals(['tee/M', 'tee/L']));

    final other = await warehouses.findById(FluentKey({'region': 'north', 'code': 2}));
    expect(other!.bins!.map((b) => b.label), ['Z'], reason: 'children are grouped by the whole key, not by region alone');
    expect(other.items, isEmpty);

    await shipments.save(Shipment(title: 'S1', warehouse: other));
    final shipment = (await shipments.findAll()).single;
    expect(shipment.warehouse?.name, 'North 2');
    expect((await rows(sql, 'shipments')).single, containsPair('warehouse_code', 2));
  });

  test('re-saving removes stale owned children and links of that owner only', () async {
    await warehouses.save(north());
    await warehouses.save(Warehouse(region: 'north', code: 2, name: 'North 2', bins: [Bin(label: 'Z')], items: [Item(sku: 'tee', size: 'M', title: 'Tee M')]));

    final saved = (await warehouses.findById(FluentKey({'region': 'north', 'code': 1})))!;
    await warehouses.save(Warehouse(region: 'north', code: 1, name: 'North 1', bins: [saved.bins!.first], items: [saved.items!.first]));

    final again = (await warehouses.findById(FluentKey({'region': 'north', 'code': 1})))!;
    expect(again.bins!.map((b) => b.label), ['A']);
    expect(again.items, hasLength(1));
    expect((await warehouses.findById(FluentKey({'region': 'north', 'code': 2})))!.bins, hasLength(1));
    expect(await rows(sql, 'items_warehouses'), hasLength(2));
  });

  test('countOf, attach and detach work with composite keys', () async {
    await warehouses.save(north());
    final w = (await warehouses.findById(FluentKey({'region': 'north', 'code': 1})))!;

    expect(await warehouses.countRelated(w, 'bins'), 2);
    expect(await warehouses.countRelated(w, 'items'), 2);

    final extra = Item(sku: 'cap', size: 'S', title: 'Cap');
    await items.save(extra);
    await warehouses.attach(w, 'items', [extra]);
    await warehouses.attach(w, 'bins', [Bin(label: 'C')]);
    expect(await warehouses.countRelated(w, 'items'), 3);
    expect(await warehouses.countRelated(w, 'bins'), 3);

    await warehouses.detach(w, 'items', [w.items!.first, extra]);
    expect(await warehouses.countRelated(w, 'items'), 1);
    expect(await items.count(), 3, reason: 'detach only removes links');

    await warehouses.detach(w, 'bins', [w.bins!.first]);
    expect(await warehouses.countRelated(w, 'bins'), 2);

    await shipments.save(Shipment(title: 'S1', warehouse: w));
    final s = (await shipments.findAll()).single;
    expect(await shipments.countRelated(s, 'warehouse'), 1);
  });

  test('deleting the owner cascades over every key column', () async {
    await warehouses.save(north());
    await warehouses.save(Warehouse(region: 'south', code: 1, name: 'South 1', bins: [Bin(label: 'Q')], items: [Item(sku: 'tee', size: 'M', title: 'Tee M')]));

    await warehouses.deleteById(FluentKey({'region': 'north', 'code': 1}));

    expect((await rows(sql, 'bins')).map((r) => r['label']), ['Q']);
    expect(await rows(sql, 'items_warehouses'), hasLength(1));
    expect(await items.count(), 2, reason: 'shared items survive');
  });

  test('loadRelations fills a lazily read model', () async {
    await warehouses.save(north());
    final rowsOnly = await warehouses.findMaps(where: FluentFilter.eq('region', 'north'));
    expect(rowsOnly.single.keys, isNot(contains('_fs_metadata')));
    final plain = Warehouse(region: 'north', code: 1, name: 'North 1');
    final full = await warehouses.loadRelations(plain);
    expect(full.bins, hasLength(2));
    expect(full.items, hasLength(2));
  });
}
