import 'package:fluent_sqflite/src/internal.dart';

/// Everything that describes a table shape, so tests can declare "version 1" and "version 2"
/// of a table inline.
class TableSpec {
  const TableSpec({
    required this.columns,
    this.key,
    this.keys,
    this.indexes = const [],
    this.checks = const [],
    this.withoutRowId = false,
    this.migrations = const [],
  });

  final List<FluentDbColumn> Function() columns;
  final FluentDbColumn Function()? key;
  final List<FluentDbColumn> Function()? keys;
  final List<FluentIndex> indexes;
  final List<FluentCheck> checks;
  final bool withoutRowId;
  final List<FluentDbMigration> migrations;
}

/// A model whose schema is supplied by a [TableSpec] and whose row is a plain map.
class DynamicModel extends FluentStorable {
  DynamicModel(this.spec, {this.values = const {}});

  final TableSpec spec;

  /// Row values returned by [buildJson].
  final Map<String, dynamic> values;

  @override
  FluentDbColumn get primaryKey => spec.key?.call() ?? super.primaryKey;

  @override
  List<FluentDbColumn> get primaryKeys => spec.keys?.call() ?? super.primaryKeys;

  @override
  List<FluentDbColumn> get tableSchema => spec.columns();

  @override
  List<FluentIndex> get indexes => spec.indexes;

  @override
  List<FluentCheck> get checks => spec.checks;

  @override
  bool get withoutRowId => spec.withoutRowId;

  @override
  List<FluentDbMigration> get migrations => spec.migrations;

  @override
  Map<String, dynamic> buildJson() => Map<String, dynamic>.from(values);

  /// Shortcut for reading a column of a loaded row.
  dynamic operator [](String column) => values[column];
}

/// Provider for [DynamicModel].
class DynamicProvider extends FluentProvider<DynamicModel> {
  DynamicProvider(this.table, List<FluentDbColumn> Function() columns, {FluentDbColumn Function()? key}) : spec = TableSpec(columns: columns, key: key);

  DynamicProvider.spec(this.table, this.spec);

  /// Table name.
  final String table;

  /// Table shape.
  final TableSpec spec;

  @override
  String get tableName => table;

  @override
  DynamicModel get modelSample => DynamicModel(spec);

  @override
  DynamicModel fromCacheJson(Map<String, dynamic> json) => DynamicModel(spec, values: json);

  /// Builds a row instance for saving.
  DynamicModel row(Map<String, dynamic> values) => DynamicModel(spec, values: values);
}
