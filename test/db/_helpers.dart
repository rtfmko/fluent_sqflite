import 'package:fluent_sqflite/src/internal.dart';

/// A plain model with a text, an int and a nullable column.
class Gadget extends FluentStorable {
  Gadget({this.id, required this.name, this.qty = 0});

  final int? id;
  final String name;
  final int qty;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, 'qty': qty};

  @override
  String toString() => 'Gadget($id, $name, $qty)';
}

/// The provider of [Gadget]; [table] lets one class serve several tables.
class GadgetProvider extends FluentProvider<Gadget> {
  GadgetProvider([this.table = 'gadgets']);

  final String table;

  @override
  String get tableName => table;

  @override
  Gadget get modelSample => Gadget(name: '');

  @override
  Gadget fromCacheJson(Map<String, dynamic> json) => Gadget(id: json['id'] as int?, name: json['name'] as String, qty: (json['qty'] as int?) ?? 0);
}

/// A second provider class for the same model.
class OtherGadgetProvider extends GadgetProvider {
  OtherGadgetProvider([super.table = 'other_gadgets']);
}

/// A model with a full-text index.
class Page extends FluentStorable {
  Page({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};

  @override
  List<FluentIndex> get indexes => const [FluentIndex.fullText(['title'])];
}

/// Provider of [Page].
class PageProvider extends FluentProvider<Page> {
  @override
  String get tableName => 'pages';

  @override
  Page get modelSample => Page(title: '');

  @override
  Page fromCacheJson(Map<String, dynamic> json) => Page(id: json['id'] as int?, title: json['title'] as String);
}

/// A syncable model.
class Remote extends FluentStorable {
  Remote({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

/// Provider of [Remote] with sync.
class RemoteProvider extends FluentProvider<Remote> with FluentSyncable<Remote> {
  @override
  String get tableName => 'remotes';

  @override
  Remote get modelSample => Remote(name: '');

  @override
  Remote fromCacheJson(Map<String, dynamic> json) => Remote(id: json['id'] as int?, name: json['name'] as String);
}

/// A model nobody registers.
class Stranger extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': null};
}

/// A model whose rows expire.
class Expiring extends FluentStorable {
  Expiring({this.id, required this.name, super.timeToLive});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

/// Provider of [Expiring].
class ExpiringProvider extends FluentProvider<Expiring> {
  @override
  String get tableName => 'expiring';

  @override
  Expiring get modelSample => Expiring(name: '');

  @override
  Expiring fromCacheJson(Map<String, dynamic> json) => Expiring(id: json['id'] as int?, name: json['name'] as String);
}

/// Two models that reference each other.
class CycleA extends FluentStorable with FluentRelations {
  CycleA({this.id, this.b});

  final int? id;
  final CycleB? b;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<CycleA, CycleB>('b', (a) => a.b)];
}

/// See [CycleA].
class CycleB extends FluentStorable with FluentRelations {
  CycleB({this.id, this.a});

  final int? id;
  final CycleA? a;

  @override
  Map<String, dynamic> buildJson() => {'id': id};

  @override
  List<FluentRelation> get relations => [FluentRelation.one<CycleB, CycleA>('a', (b) => b.a)];
}

/// Provider of [CycleA].
class CycleAProvider extends FluentProvider<CycleA> {
  @override
  String get tableName => 'cycle_a';

  @override
  CycleA get modelSample => CycleA();

  @override
  CycleA fromCacheJson(Map<String, dynamic> json) => CycleA(id: json['id'] as int?, b: json['b'] as CycleB?);
}

/// Provider of [CycleB].
class CycleBProvider extends FluentProvider<CycleB> {
  @override
  String get tableName => 'cycle_b';

  @override
  CycleB get modelSample => CycleB();

  @override
  CycleB fromCacheJson(Map<String, dynamic> json) => CycleB(id: json['id'] as int?, a: json['a'] as CycleA?);
}
