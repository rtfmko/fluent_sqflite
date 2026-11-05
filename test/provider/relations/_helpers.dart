// Shared models for the relation graph / ops tests: three generic models (GA, GB, GC) whose relations and extra
// `buildJson` fields are chosen per test, so one file can declare many shapes without a class per case.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';

/// Base of [GA], [GB], [GC]: every model has a single and a list field for each of the three models.
abstract class GBase extends FluentStorable with FluentRelations {
  int? id;
  String name = '';
  GA? a;
  GB? b;
  GC? c;
  List<GA> as = [];
  List<GB> bs = [];
  List<GC> cs = [];
  FluentStorable? thing;
  Object? dyn;

  /// Key column type per model type (default: auto-increment integer), set by the tests.
  static final Map<Type, FluentDbDataType> keyTypes = {};

  @override
  FluentDbColumn get primaryKey {
    final FluentDbDataType? type = keyTypes[runtimeType];
    if (type == null || type == FluentDbDataType.integer) return super.primaryKey;
    return FluentDbColumn(name: 'id', type: type, isPrimaryKey: true);
  }

  /// The stored key of a saved model (a save injects the generated key into the instance).
  int get rowId => primaryKeyValue! as int;

  /// The cache json this model was built from (relations the reader filled are in here by relation name).
  Map<String, dynamic> raw = const {};

  /// Relations per model type, set by the tests.
  static final Map<Type, List<FluentRelation> Function()> declared = {};

  /// Columns per model type that replace the inferred column of the same name (or add one), set by the tests.
  static final Map<Type, List<FluentDbColumn> Function()> columns = {};

  /// Extra `buildJson` fields per model type, set by the tests.
  static final Map<Type, Map<String, dynamic> Function(GBase)> extras = {};

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name, ...?extras[runtimeType]?.call(this)};

  @override
  List<FluentRelation> get relations => declared[runtimeType]?.call() ?? const [];

  Map<String, dynamic> _schemaJson() {
    try {
      return buildJson();
    } catch (_) {
      return {'id': id, 'name': name}; // a buildJson that throws is the case under test; the schema still needs columns
    }
  }

  /// Not cached (the base class caches per model type, but the tests change the fields between databases).
  @override
  List<FluentDbColumn> get tableSchema {
    final List<FluentDbColumn> custom = columns[runtimeType]?.call() ?? const [];
    return [
      ...primaryKeys,
      for (final MapEntry<String, dynamic> e in _schemaJson().entries)
        if (e.key != 'id' && e.value is! FluentStorable && e.value is! Iterable<FluentStorable> && !custom.any((FluentDbColumn c) => c.name == e.key))
          FluentDbColumn(name: e.key, type: e.value is int ? FluentDbDataType.integer : FluentDbDataType.text),
      ...custom,
    ];
  }
}

class GA extends GBase {
  GA({int? id, String name = ''}) {
    this.id = id;
    this.name = name;
  }
}

class GB extends GBase {
  GB({int? id, String name = ''}) {
    this.id = id;
    this.name = name;
  }
}

class GC extends GBase {
  GC({int? id, String name = ''}) {
    this.id = id;
    this.name = name;
  }
}

/// A soft-deletable model.
class GS extends GBase with FluentSoftDeletable {
  GS({int? id, String name = ''}) {
    this.id = id;
    this.name = name;
  }
}

/// Clears what the tests declared (call in `tearDown`).
void resetG() {
  GBase.declared.clear();
  GBase.extras.clear();
  GBase.columns.clear();
  GBase.keyTypes.clear();
}

T _fill<T extends GBase>(T m, Map<String, dynamic> j) {
  m.id = j['id'] as int?;
  m.name = j['name'] as String? ?? '';
  m.raw = j;
  if (j['a'] is GA) m.a = j['a'] as GA;
  if (j['b'] is GB) m.b = j['b'] as GB;
  if (j['c'] is GC) m.c = j['c'] as GC;
  if (j['as'] is List) m.as = (j['as'] as List).cast<GA>();
  if (j['bs'] is List) m.bs = (j['bs'] as List).cast<GB>();
  if (j['cs'] is List) m.cs = (j['cs'] as List).cast<GC>();
  if (j['thing'] is FluentStorable) m.thing = j['thing'] as FluentStorable;
  return m;
}

class GAProvider extends FluentProvider<GA> {
  @override
  String get tableName => 'g_a';

  @override
  GA get modelSample => GA();

  @override
  GA fromCacheJson(Map<String, dynamic> json) => _fill(GA(), json);
}

class GBProvider extends FluentProvider<GB> {
  @override
  String get tableName => 'g_b';

  @override
  GB get modelSample => GB();

  @override
  GB fromCacheJson(Map<String, dynamic> json) => _fill(GB(), json);
}

class GCProvider extends FluentProvider<GC> {
  @override
  String get tableName => 'g_c';

  @override
  GC get modelSample => GC();

  @override
  GC fromCacheJson(Map<String, dynamic> json) => _fill(GC(), json);
}

class GSProvider extends FluentProvider<GS> {
  @override
  String get tableName => 'g_s';

  @override
  GS get modelSample => GS();

  @override
  GS fromCacheJson(Map<String, dynamic> json) => _fill(GS(), json);
}

/// A second table for the model of [GBProvider].
class GB2Provider extends FluentProvider<GB> {
  @override
  String get tableName => 'g_b2';

  @override
  GB get modelSample => GB();

  @override
  GB fromCacheJson(Map<String, dynamic> json) => _fill(GB(), json);
}

/// Opens a test database with [providers] and returns it; [persistent] for restarts / read pools.
Future<FluentTestDb> openG(
  List<FluentProvider> providers, {
  bool persistent = false,
  FluentConfig fluentConfig = const FluentConfig(),
  FluentDbConfig config = const FluentDbConfig(),
}) async {
  final FluentTestDb db = FluentTestDb(persistent: persistent);
  await db.open(providers, fluentConfig: fluentConfig, config: config);
  return db;
}

/// The issues of [kind] a database raised.
List<FluentIssue> issuesOf(FluentTestDb db, FluentIssueKind kind) => [for (final FluentIssue i in db.issues) if (i.kind == kind) i];

/// The issues of kind `relationDeclaration` whose title contains [text].
List<FluentIssue> declarationIssues(FluentTestDb db, String text) => [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.relationDeclaration && i.title.contains(text)) i];

/// Saves [model] and returns it (its generated key is injected by the save).
Future<T> put<T extends GBase>(FluentProvider<T> provider, T model) async {
  await provider.save(model);
  return model;
}

/// Saves [models] and returns them.
Future<List<T>> putAll<T extends GBase>(FluentProvider<T> provider, List<T> models) async {
  await provider.saveAll(models);
  return models;
}
