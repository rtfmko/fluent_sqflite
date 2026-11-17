// Regression tests for the relation items of audit 2 (KNOWN_BUGS 1-5, 15): saving lists that show only part of the
// stored rows (limit / where / includeDeleted / unloaded), findParents through a oneOf reference, insertOnly on an
// existing root, and the start-up orphan clean-up after a schema change quarantined parent rows.
@Timeout(Duration(seconds: 20))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '_helpers.dart';

/// The relations of [Owner], set per test.
FluentRelation<Owner, Item> Function() itemsRelation = _defaultItems;
FluentRelation<Owner, Tag> Function() tagsRelation = _defaultTags;

FluentRelation<Owner, Item> _defaultItems() => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id');
FluentRelation<Owner, Tag> _defaultTags() => FluentRelation.manyToMany<Owner, Tag>('tags', (o) => o.tags, linkTable: 'a2_links', linkParentKey: 'owner_id', linkChildKey: 'tag_id', orderBy: 'id');

/// A CHECK the owner table gets in the second version (quarantine tests).
bool strictOwner = false;

class Owner extends FluentStorable with FluentRelations {
  Owner({this.id, required this.name, List<Item>? items, List<Tag>? tags}) : items = items ?? [], tags = tags ?? [];

  final int? id;
  final String name;

  /// Defaults to `[]` like many apps' `fromCacheJson` do (the case of an unloaded relation).
  List<Item> items;
  List<Tag> tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentCheck> get checks => strictOwner ? const [FluentCheck('length(name) > 1')] : const [];

  @override
  List<FluentRelation> get relations => [itemsRelation(), tagsRelation()];
}

class Item extends FluentStorable with FluentSoftDeletable {
  Item({this.id, required this.text, this.size = 0});

  final int? id;
  final String text;
  final int size;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text, 'size': size};
}

class Tag extends FluentStorable with FluentSoftDeletable {
  Tag({this.id, required this.label, this.color = 'red'});

  final int? id;
  final String label;
  final String color;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label, 'color': color};
}

class OwnerProvider extends FluentProvider<Owner> {
  @override
  String get tableName => 'a2_owners';

  @override
  Owner get modelSample => Owner(name: '');

  @override
  Owner fromCacheJson(Map<String, dynamic> json) => Owner(
    id: json['id'] as int?,
    name: json['name'] as String,
    items: (json['items'] as List?)?.cast<Item>(),
    tags: (json['tags'] as List?)?.cast<Tag>(),
  );
}

class ItemProvider extends FluentProvider<Item> {
  @override
  String get tableName => 'a2_items';

  @override
  Item get modelSample => Item(text: '');

  @override
  Item fromCacheJson(Map<String, dynamic> json) => Item(id: json['id'] as int?, text: json['text'] as String, size: json['size'] as int? ?? 0);
}

class TagProvider extends FluentProvider<Tag> {
  @override
  String get tableName => 'a2_tags';

  @override
  Tag get modelSample => Tag(label: '');

  @override
  Tag fromCacheJson(Map<String, dynamic> json) => Tag(id: json['id'] as int?, label: json['label'] as String, color: json['color'] as String? ?? '');
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late OwnerProvider owners;
  late ItemProvider items;
  late TagProvider tags;

  Future<void> open({bool persistent = false}) async {
    db = FluentTestDb(persistent: persistent);
    owners = OwnerProvider();
    items = ItemProvider();
    tags = TagProvider();
    await db.open([owners, items, tags]);
  }

  /// Texts of the live items (all owners).
  Future<List<String>> liveItems() async => [for (final Item i in await items.find(orderBy: 'id')) i.text];

  /// Texts of the items in the trash.
  Future<List<String>> trashedItems() async => [for (final Item i in await items.trash.find(orderBy: 'id')) i.text];

  /// Labels of the tags linked to the only owner (read straight from the link table, trashed tags too).
  Future<List<String>> linkedLabels() async {
    final List<Map<String, Object?>> rows = await owners.db.rawQuery('SELECT t.label FROM a2_tags t WHERE EXISTS (SELECT 1 FROM a2_links l WHERE l.tag_id = t.id) ORDER BY t.id');
    return [for (final Map<String, Object?> r in rows) r['label']! as String];
  }

  tearDown(() async {
    itemsRelation = _defaultItems;
    tagsRelation = _defaultTags;
    strictOwner = false;
    await db.close();
  });

  group('1: lists with limit / where save only what they show', () {
    test('re-saving a model loaded with a limited list keeps the children past the limit', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', limit: 2);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2'), Item(text: 'a3')]));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.items.map((i) => i.text), ['a1', 'a2']);
      await owners.save(loaded);
      expect(await liveItems(), ['a1', 'a2', 'a3']);
    });

    test('a limited list: new children are added, children dropped from it are not removed (it shows only part)', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', limit: 2);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2'), Item(text: 'a3')]));
      final Owner loaded = (await owners.findAll()).single;
      await owners.save(Owner(id: loaded.id, name: 'A', items: [loaded.items.last, Item(text: 'new')]));
      expect(await liveItems(), ['a1', 'a2', 'a3', 'new']);
    });

    test('a list with where: rows outside it stay, a row of the view dropped from the list is removed', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', where: FluentFilter.gt('size', 5));
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'small', size: 1), Item(text: 'big1', size: 10), Item(text: 'big2', size: 20)]));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.items.map((i) => i.text), ['big1', 'big2']);
      await owners.save(loaded);
      expect(await liveItems(), ['small', 'big1', 'big2']);

      await owners.save(Owner(id: loaded.id, name: 'A', items: [loaded.items.first]));
      expect(await liveItems(), ['small', 'big1']);
      expect(await trashedItems(), ['big2'], reason: 'removed children of a soft-delete model go to the trash');
    });

    test('a many-to-many list with limit keeps the links it did not show', () async {
      tagsRelation = () => FluentRelation.manyToMany<Owner, Tag>('tags', (o) => o.tags, linkTable: 'a2_links', linkParentKey: 'owner_id', linkChildKey: 'tag_id', orderBy: 'id', limit: 1);
      await open();
      await owners.save(Owner(name: 'A', tags: [Tag(label: 't1'), Tag(label: 't2')]));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.tags.map((t) => t.label), ['t1']);
      await owners.save(loaded);
      expect(await linkedLabels(), ['t1', 't2']);
    });

    test('a many-to-many list with where keeps links to targets outside it, removes dropped ones inside it', () async {
      tagsRelation = () => FluentRelation.manyToMany<Owner, Tag>('tags', (o) => o.tags, linkTable: 'a2_links', linkParentKey: 'owner_id', linkChildKey: 'tag_id', orderBy: 'id', where: FluentFilter.eq('color', 'red'));
      await open();
      await owners.save(Owner(name: 'A', tags: [Tag(label: 'r1'), Tag(label: 'b1', color: 'blue'), Tag(label: 'r2')]));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.tags.map((t) => t.label), ['r1', 'r2']);
      await owners.save(loaded);
      expect(await linkedLabels(), ['r1', 'b1', 'r2']);

      await owners.save(Owner(id: loaded.id, name: 'A', tags: [loaded.tags.first]));
      expect(await linkedLabels(), ['r1', 'b1']);
    });

    test('a link to a tag in the trash survives a save of the owner and shows again after the restore', () async {
      await open();
      await owners.save(Owner(name: 'A', tags: [Tag(label: 't1'), Tag(label: 't2')]));
      await tags.deleteWhere(FluentFilter.eq('label', 't2'));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.tags.map((t) => t.label), ['t1']);
      await owners.save(loaded);
      await tags.trash.restoreWhere(FluentFilter.eq('label', 't2'));
      expect((await owners.findAll()).single.tags.map((t) => t.label), ['t1', 't2']);
    });

    test('an unrestricted list still removes the children dropped from it', () async {
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2')]));
      final Owner loaded = (await owners.findAll()).single;
      await owners.save(Owner(id: loaded.id, name: 'A', items: [loaded.items.first]));
      expect(await liveItems(), ['a1']);
    });
  });

  group('2: lists loaded with includeDeleted do not restore their trashed rows', () {
    test('re-saving an includeDeleted list keeps trashed children in the trash', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', includeDeleted: true);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'live'), Item(text: 'trashed')]));
      await items.deleteWhere(FluentFilter.eq('text', 'trashed'));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.items.map((i) => i.text), ['live', 'trashed']);
      await owners.save(loaded);
      expect(await liveItems(), ['live']);
      expect(await trashedItems(), ['trashed']);
      expect(issuesOf(db, FluentIssueKind.trashRevived), isEmpty);
    });

    test('live children of the list are still written; a trashed child dropped from it stays in the trash', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', includeDeleted: true);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'live'), Item(text: 'trashed')]));
      await items.deleteWhere(FluentFilter.eq('text', 'trashed'));
      final Owner loaded = (await owners.findAll()).single;
      final Item live = loaded.items.first;
      await owners.save(Owner(id: loaded.id, name: 'A', items: [Item(id: live.id, text: 'edited'), Item(text: 'added')]));
      expect(await liveItems(), ['edited', 'added']);
      expect(await trashedItems(), ['trashed']);
    });

    test('a many-to-many list with includeDeleted keeps its trashed target in the trash and keeps the link', () async {
      tagsRelation = () => FluentRelation.manyToMany<Owner, Tag>('tags', (o) => o.tags, linkTable: 'a2_links', linkParentKey: 'owner_id', linkChildKey: 'tag_id', orderBy: 'id', includeDeleted: true);
      await open();
      await owners.save(Owner(name: 'A', tags: [Tag(label: 't1'), Tag(label: 't2')]));
      await tags.deleteWhere(FluentFilter.eq('label', 't2'));
      final Owner loaded = (await owners.findAll()).single;
      expect(loaded.tags.map((t) => t.label), ['t1', 't2']);
      await owners.save(loaded);
      expect([for (final Tag t in await tags.find()) t.label], ['t1']);
      expect(await linkedLabels(), ['t1', 't2']);
    });

    test('a new model with the key of a trashed child (not read from the trash) still restores it, as a save does', () async {
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'c1')]));
      final Owner loaded = (await owners.findAll()).single;
      final int childId = loaded.items.single.id!;
      await items.deleteWhere(FluentFilter.eq('text', 'c1'));
      await owners.save(Owner(id: loaded.id, name: 'A', items: [Item(id: childId, text: 'c1 back')]));
      expect(await liveItems(), ['c1 back']);
      expect(await trashedItems(), isEmpty);
    });
  });

  group('3: relations a read did not load are not rewritten', () {
    test('saving a model read with FluentLoad.none keeps its children and links', () async {
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2')], tags: [Tag(label: 't1')]));
      final Owner bare = (await owners.findAll(relations: FluentLoad.none)).single;
      expect(bare.unloadedRelations, containsAll(['items', 'tags']));
      expect(bare.items, isEmpty);
      await owners.save(bare);
      expect(await liveItems(), ['a1', 'a2']);
      expect(await linkedLabels(), ['t1']);
    });

    test('a lazy relation the read skipped: children the app adds are saved, the stored ones stay', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', lazy: true);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2')]));
      final Owner read = (await owners.findAll()).single;
      expect(read.isRelationLoaded('items'), isFalse);
      read.items = [Item(text: 'a3')];
      await owners.save(read);
      expect(await liveItems(), ['a1', 'a2', 'a3']);
    });

    test('after loadRelations the list is loaded again and a removal applies', () async {
      itemsRelation = () => FluentRelation.many<Owner, Item>('items', (o) => o.items, foreignKey: 'owner_id', orderBy: 'id', lazy: true);
      await open();
      await owners.save(Owner(name: 'A', items: [Item(text: 'a1'), Item(text: 'a2')]));
      final Owner full = await owners.loadRelations((await owners.findAll()).single);
      expect(full.isRelationLoaded('items'), isTrue);
      full.items = [full.items.first];
      await owners.save(full);
      expect(await liveItems(), ['a1']);
    });
  });

  group('4: findParents through a oneOf reference', () {
    tearDown(resetG);

    test('returns only the parents pointing to this type, for every type of the reference', () async {
      await db.close();
      GBase.declared[GA] = () => [FluentRelation.oneOf<GA>('thing', (GA a) => a.thing, types: [GB, GC])];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c]);
      final GB b1 = await put(b, GB()..id = 1..name = 'b1');
      final GC c1 = await put(c, GC()..id = 1..name = 'c1');
      await put(a, GA()..name = 'toC'..thing = c1);
      await put(a, GA()..name = 'toB'..thing = b1);

      expect((await b.findParents<GA>(b1, via: 'thing')).map((x) => x.name), ['toB']);
      expect((await c.findParents<GA>(c1, via: 'thing')).map((x) => x.name), ['toC']);
      expect((await c.findParents<GA>(c1)).map((x) => x.name), ['toC'], reason: 'the oneOf relation is found without via');
    });

    test('a further where applies, and a model without parents gives an empty list', () async {
      await db.close();
      GBase.declared[GA] = () => [FluentRelation.oneOf<GA>('thing', (GA a) => a.thing, types: [GB, GC])];
      final GAProvider a = GAProvider();
      final GBProvider b = GBProvider();
      final GCProvider c = GCProvider();
      db = await openG([a, b, c]);
      final GC c1 = await put(c, GC()..name = 'c1');
      final GC c2 = await put(c, GC()..name = 'c2');
      await put(a, GA()..name = 'x'..thing = c1);
      await put(a, GA()..name = 'y'..thing = c1);
      expect((await c.findParents<GA>(c1, where: FluentFilter.eq('name', 'y'))).map((x) => x.name), ['y']);
      expect(await c.findParents<GA>(c2), isEmpty);
    });
  });

  group('5: insertOnly on an existing root', () {
    test('a skipped (existing) root leaves its stored children and links alone', () async {
      await open();
      await owners.save(Owner(id: 1, name: 'orig', items: [Item(text: 'x'), Item(text: 'y')], tags: [Tag(label: 't1')]));
      final FluentSaveResult r = await owners.save(Owner(id: 1, name: 'other', items: [Item(text: 'z')], tags: [Tag(label: 't2')]), strategy: FluentSaveStrategy.insertOnly);
      expect(r.outcomes, [FluentRowOutcome.skipped]);
      expect(await liveItems(), ['x', 'y']);
      expect(await linkedLabels(), ['t1']);
      expect((await owners.findById(1))!.name, 'orig');
      expect([for (final Tag t in await tags.find()) t.label], ['t1'], reason: 'nothing of the skipped graph is written');
    });

    test('insertOnly of a new root still writes its children and links', () async {
      await open();
      final FluentSaveResult r = await owners.save(Owner(id: 7, name: 'new', items: [Item(text: 'z')], tags: [Tag(label: 't2')]), strategy: FluentSaveStrategy.insertOnly);
      expect(r.outcomes, [FluentRowOutcome.inserted]);
      expect(await liveItems(), ['z']);
      expect(await linkedLabels(), ['t2']);
    });
  });

  group('15: children of parent rows a schema change quarantined', () {
    test('are kept by the start-up clean-up, reported, and load again once the parent is moved back', () async {
      await open(persistent: true);
      await owners.save(Owner(name: 'ok', items: [Item(text: 'a1')], tags: [Tag(label: 't1')]));
      await owners.save(Owner(name: 'x', items: [Item(text: 'b1'), Item(text: 'b2')], tags: [Tag(label: 't2')]));

      strictOwner = true;
      owners = OwnerProvider();
      items = ItemProvider();
      tags = TagProvider();
      await db.restart([owners, items, tags]);
      final List<Map<String, Object?>> quarantine = await owners.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '__fluent_rejected%'");
      expect(quarantine, hasLength(1));
      expect((await owners.findAll()).map((o) => o.name), ['ok']);
      final List<Map<String, Object?>> stored = await owners.db.rawQuery('SELECT text FROM a2_items ORDER BY id');
      expect([for (final Map<String, Object?> r in stored) r['text']], ['a1', 'b1', 'b2'], reason: 'children of a quarantined owner must not be deleted');
      expect(await linkedLabels(), ['t1', 't2'], reason: 'links of a quarantined owner stay');
      final List<FluentIssue> kept = [for (final FluentIssue i in issuesOf(db, FluentIssueKind.danglingReferences)) if (i.title.contains('quarantine') || i.title.contains('__fluent_rejected')) i];
      expect(kept, isNotEmpty);
      expect(kept.first.fix, contains('Move the quarantined rows back'));

      // The app fixes the rejected row and moves it back: its children are there again.
      final String q = quarantine.single['name']! as String;
      await owners.db.execute('INSERT INTO a2_owners (id, name) SELECT id, name || name FROM "$q"');
      await owners.db.execute('DROP TABLE "$q"');
      final Owner restored = (await owners.find(where: FluentFilter.eq('name', 'xx'))).single;
      expect(restored.items.map((i) => i.text), ['b1', 'b2']);
      expect(restored.tags.map((t) => t.label), ['t2']);
    });

    test('a dangling reference to a row that is in no quarantine is still cleaned up', () async {
      await open(persistent: true);
      await owners.save(Owner(name: 'ok', items: [Item(text: 'a1')]));
      await owners.save(Owner(name: 'x', items: [Item(text: 'b1')]));
      await owners.save(Owner(name: 'stays', items: [Item(text: 'c1')]));
      // An owner deleted while foreign keys were off (e.g. by another tool): its child dangles.
      await owners.db.execute('PRAGMA foreign_keys = OFF');
      await owners.db.execute("DELETE FROM a2_owners WHERE name = 'ok'");
      await owners.db.execute('PRAGMA foreign_keys = ON');

      strictOwner = true;
      owners = OwnerProvider();
      items = ItemProvider();
      tags = TagProvider();
      await db.restart([owners, items, tags]);
      final List<Map<String, Object?>> stored = await owners.db.rawQuery('SELECT text FROM a2_items ORDER BY id');
      expect([for (final Map<String, Object?> r in stored) r['text']], ['b1', 'c1'], reason: 'the child of the deleted owner is removed, the one of the quarantined owner kept');
    });
  });
}
