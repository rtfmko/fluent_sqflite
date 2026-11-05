// A 1.x table that exists next to its 2.0 name is never renamed over: the rows stay where they are and the issue says
// how to bring them over.
@Timeout(Duration(seconds: 30))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Item2 extends FluentStorable {
  Item2({this.id, this.name = ''});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Item2Provider extends FluentProvider<Item2> {
  @override
  Item2 get modelSample => Item2();

  @override
  Item2 fromCacheJson(Map<String, dynamic> json) => Item2(id: json['id'] as int?, name: json['name'] as String);
}

/// An automatic one-to-one pair: both sides hold the other as a single model.
class Card2 extends FluentStorable {
  Card2({this.id, this.label = '', this.holder});

  final int? id;
  final String label;
  final Holder2? holder;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label, 'holder': holder};
}

class Holder2 extends FluentStorable {
  Holder2({this.id, this.name = '', this.card});

  final int? id;
  final String name;
  final Card2? card;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'card': card};
}

class Card2Provider extends FluentProvider<Card2> {
  @override
  Card2 get modelSample => Card2(holder: Holder2());

  @override
  Card2 fromCacheJson(Map<String, dynamic> json) => Card2(id: json['id'] as int?, label: json['label'] as String, holder: json['holder'] as Holder2?);
}

class Holder2Provider extends FluentProvider<Holder2> {
  @override
  Holder2 get modelSample => Holder2(card: Card2());

  @override
  Holder2 fromCacheJson(Map<String, dynamic> json) => Holder2(id: json['id'] as int?, name: json['name'] as String, card: json['card'] as Card2?);
}

void main() {
  setUpFluentTests();

  test('a 1.x table next to its 2.0 table is kept and reported, with the rows of both untouched', () async {
    final FluentTestDb db = FluentTestDb(persistent: true);
    addTearDown(db.close);
    await FluentUtils.withLegacyNames(() async {
      final Item2Provider old = Item2Provider();
      await db.open([old]);
      expect(old.tableName, 'item_2', reason: 'the 1.x name');
      await old.save(Item2(name: 'old row'));
    });
    // The 2.0 table already exists (an app that started 2.0 once against a copy, or by hand).
    final Item2Provider current = Item2Provider();
    await db.restart([current]);
    // Hand-made leftovers: put the 1.x table back next to the 2.0 one, then start with the snapshot of the 1.x state.
    expect(current.tableName, 'item2');
    final List<Map<String, Object?>> tables = await current.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'item%'");
    expect(tables.map((Map<String, Object?> r) => r['name']), ['item2'], reason: 'adopted by the first 2.0 start');
    expect((await current.find()).map((Item2 i) => i.name), ['old row']);

    await current.db.execute('CREATE TABLE "item_2" (id INTEGER PRIMARY KEY, name TEXT)');
    await current.db.execute("INSERT INTO \"item_2\" VALUES (7, 'leftover')");
    // Make the next start run a full sync (a changed schema fingerprint), so the adoption is looked at again.
    await current.db.execute('DELETE FROM "__fluent_schema"');
    final Item2Provider again = Item2Provider();
    await db.restart([again]);
    expect((await again.find()).map((Item2 i) => i.name), ['old row'], reason: 'the 2.0 table is the one in use');
    expect((await again.db.rawQuery('SELECT name FROM item_2')).single['name'], 'leftover', reason: 'never dropped or merged');
    final List<FluentIssue> issues = [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.schemaFallback && i.subject == 'item_2') i];
    expect(issues, isNotEmpty);
    expect(issues.first.title, contains('"item2" exists too'));
    expect(issues.first.code, contains('INSERT OR IGNORE INTO "item2" SELECT * FROM "item_2"'));
  });

  test('a one-to-one pair of a 1.x database keeps the side that stored the key under the 1.x table names', () async {
    final FluentTestDb db = FluentTestDb(persistent: true);
    addTearDown(db.close);
    late final bool cardStoredKey;
    await FluentUtils.withLegacyNames(() async {
      final Card2Provider cards = Card2Provider();
      final Holder2Provider holders = Holder2Provider();
      await db.open([cards, holders]);
      expect(cards.tableName, 'card_2');
      cardStoredKey = cards.relationLinks.single.isReference;
      await cards.save(Card2(label: 'gold', holder: Holder2(name: 'Ann')));
    });
    final Card2Provider cards = Card2Provider();
    final Holder2Provider holders = Holder2Provider();
    await db.restart([cards, holders]);
    expect(cards.tableName, 'card2');
    expect(cards.relationLinks.single.isReference, cardStoredKey, reason: 'the key stays on the table that stored it');
    final Card2 card = (await cards.find()).single;
    expect(card.holder?.name, 'Ann', reason: 'the reference survives the rename');
    expect((await holders.find()).single.card?.label, 'gold');
  });
}
