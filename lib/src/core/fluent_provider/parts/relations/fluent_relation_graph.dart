// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// A declared [FluentRelation] after initialization: which provider it points to, which type it resolved to
/// and which columns / link table actually store it.
///
/// Built once per `FluentDb.init` by [buildFluentRelationGraph]; the user's declaration is never mutated.
class FluentRelationLink {
  FluentRelationLink._({
    required this.relation,
    required this.type,
    required this.owner,
    required this.target,
    required this.onDelete,
    this.foreignKeys = const [],
    this.referencedColumns = const [],
    this.linkTable,
    this.linkOwnerColumns = const [],
    this.linkTargetColumns = const [],
    this.decidedBy,
    this.linkModel,
    this.typeColumn,
    this.typeValue,
    this.targets = const {},
    this.targetColumns = const {},
    this.found = false,
    this.via,
    this.oneToOne = false,
  });

  /// The user's declaration.
  final FluentRelation relation;

  /// The resolved type (never [FluentRelationType.auto]).
  final FluentRelationType type;

  /// Provider that declares the relation.
  final FluentProvider owner;

  /// Provider of the related model.
  final FluentProvider target;

  /// Reference columns: on [owner] for [FluentRelationType.one], on [target] for owned children,
  /// empty for [FluentRelationType.manyToMany]. Several columns for a composite key.
  final List<String> foreignKeys;

  /// The key columns [foreignKeys] point to, in the same order (target key for `one`, owner key for owned).
  final List<String> referencedColumns;

  /// Delete rule of the reference column (or of both link table columns).
  final FluentOnDelete onDelete;

  /// Link table of a many-to-many relation.
  final String? linkTable;

  /// Link table columns pointing to the key of [owner].
  final List<String> linkOwnerColumns;

  /// Link table columns pointing to the key of [target].
  final List<String> linkTargetColumns;

  /// The reference column (columns joined with ", " for a composite key), `null` for many-to-many.
  String? get foreignKey => foreignKeys.isEmpty ? null : foreignKeys.join(', ');

  /// The link table column(s) pointing to [owner].
  String? get linkOwnerColumn => linkOwnerColumns.isEmpty ? null : linkOwnerColumns.join(', ');

  /// The link table column(s) pointing to [target].
  String? get linkTargetColumn => linkTargetColumns.isEmpty ? null : linkTargetColumns.join(', ');

  /// Reference column values for the key [id] of the referenced row (plain value or [FluentKey]).
  ///
  /// A `oneOf` reference has no single referenced table (its columns depend on the chosen type): use [columnsFor]
  /// with the table's own key. Calling this on one throws a [FluentRelationException].
  Map<String, Object?> referenceValues(Object? id) {
    if (type == FluentRelationType.oneOf) {
      throw FluentRelationException(
        '"$name" of ${owner.modelType} is a oneOf reference: its columns depend on the referenced table, so one key cannot fill them.',
        hint: 'Read the columns of one table with columnsFor(tableName) and the key of that table\'s model.',
      );
    }
    return {..._zipKey(foreignKeys, referencedColumns, id), if (typeValue != null) typeColumn!: typeValue};
  }

  /// Link table owner column values for the owner key [id].
  Map<String, Object?> linkOwnerValues(Object? id) => _zipKey(linkOwnerColumns, owner.keyColumnNames.toList(), id);

  /// Link table target column values for the target key [id].
  Map<String, Object?> linkTargetValues(Object? id) => _zipKey(linkTargetColumns, target.keyColumnNames.toList(), id);

  /// For `auto` relations: why this type was chosen.
  final String? decidedBy;

  /// For [FluentRelation.through]: the provider of the link model; its table is [linkTable].
  final FluentProvider? linkModel;

  /// For [FluentRelationType.oneOf] and the owned lists that point back through one: the column holding the table of
  /// the referenced model (`target_type`). [foreignKeys] holds the key column (`target_id`).
  final String? typeColumn;

  /// For an owned list through a `oneOf` reference: the value of [typeColumn] that means the owner's table.
  final String? typeValue;

  /// For [FluentRelationType.oneOf]: the value of [typeColumn] (the table name) → the provider of that table.
  final Map<String, FluentProvider> targets;

  /// For [FluentRelationType.oneOf]: the value of [typeColumn] → the reference columns of that table's key, in key
  /// order (`target_id`, or `target_user_id`, `target_day` for a composite key). [foreignKeys] holds them all.
  final Map<String, List<String>> targetColumns;

  /// Whether the relation was found in `buildJson` instead of declared (its value is read from `buildJson`).
  final bool found;

  /// For an owned list through a `oneOf`: the name of that `oneOf` relation of [target].
  final String? via;

  /// Whether `auto` decided this side of a one-to-one pair (both models hold a single model of the other): which
  /// table stores the key stays as it was stored before (see [FluentRelationSchema.keepOneToOneSides]).
  final bool oneToOne;

  /// For [FluentRelationType.oneOf]: the reference columns used for the referenced [table].
  List<String> columnsFor(String table) => targetColumns[table] ?? const [];

  /// Whether the reference is polymorphic (a `oneOf`, or an owned list through one): checked by the library, not by
  /// SQLite.
  bool get isPolymorphic => typeColumn != null;

  /// The owned list through a `oneOf`: only children whose [typeColumn] names the owner's table.
  FluentFilter get typeFilter => typeValue == null ? FluentFilter.empty : FluentFilter.eq(typeColumn!.quotedIdentifier, typeValue);

  /// [typeFilter] as SQL on the alias [alias] (`AND c."target_type" = 'posts'`), empty for other links.
  String typeCondition(String alias) => typeValue == null ? '' : ' AND $alias.${typeColumn!.quotedIdentifier} = ${fluentSqlLiteral(typeValue)}';

  /// Whether the links are rows of a model of their own ([FluentRelation.through]): read-only through this relation.
  bool get isThrough => linkModel != null;

  /// The link table as a SQL `FROM` source: the table, or for [isThrough] only its visible rows (not in the trash,
  /// not expired).
  String get linkSource {
    final String table = linkTable!.quotedIdentifier;
    final FluentProvider? model = linkModel;
    if (model == null) return table;
    final FluentFilter visible = model._visibility(deletedOnly: false, includeDeleted: relation.includeDeleted);
    if (visible.whereArgs.isNotEmpty) return table;
    // Only the key columns, also without a visibility rule: the link model's own columns (a role, expiry, timestamps)
    // would clash with the target's in joins and in the relation's where / orderBy.
    final String columns = [...linkOwnerColumns, ...linkTargetColumns].map((c) => c.quotedIdentifier).join(', ');
    return '(SELECT $columns FROM $table${visible.whereClause.isEmpty ? '' : ' WHERE ${visible.whereClause}'})';
  }

  /// Relation name.
  String get name => relation.name;

  /// Whether the relation holds a list.
  bool get isList => type.isList;

  /// Whether the reference column lives on the owner table.
  bool get isReference => type == FluentRelationType.one;

  /// Whether the related rows are owned children (reference column on the target table).
  bool get isOwned => type == FluentRelationType.many || type == FluentRelationType.oneOwned;

  /// Whether the relation uses a link table.
  bool get isManyToMany => type == FluentRelationType.manyToMany;

  /// One-line description for the debug relation tree.
  String describe() {
    final String how = switch (type) {
      FluentRelationType.one => '$name → ${target.tableName} (${owner.tableName}.$foreignKey, on delete ${onDelete.name})',
      FluentRelationType.oneOwned => '$name ← ${target.tableName}.$foreignKey${_typeNote()} (one owned, on delete ${onDelete.name})',
      FluentRelationType.many => '$name ← ${target.tableName}.$foreignKey${_typeNote()} (list, on delete ${onDelete.name})',
      FluentRelationType.oneOf => '$name → one of ${targets.keys.join(' | ')} (${owner.tableName}.$typeColumn, $foreignKey, on delete ${onDelete.name})',
      FluentRelationType.manyToMany => '$name ↔ ${target.tableName} ${isThrough ? 'through ${linkModel!.modelType}' : 'via'} $linkTable($linkOwnerColumn, $linkTargetColumn)',
      FluentRelationType.auto => '$name (unresolved)',
    };
    return decidedBy == null ? how : '$how  [auto: $decidedBy]';
  }

  String _typeNote() => typeValue == null ? '' : ' where $typeColumn = $typeValue';

  /// This link with the delete rule [rule] (see [_resolveSharedDeleteRules]).
  FluentRelationLink _withOnDelete(FluentOnDelete rule) => FluentRelationLink._(
    relation: relation,
    type: type,
    owner: owner,
    target: target,
    onDelete: rule,
    foreignKeys: foreignKeys,
    referencedColumns: referencedColumns,
    linkTable: linkTable,
    linkOwnerColumns: linkOwnerColumns,
    linkTargetColumns: linkTargetColumns,
    decidedBy: decidedBy,
    linkModel: linkModel,
    typeColumn: typeColumn,
    typeValue: typeValue,
    targets: targets,
    targetColumns: targetColumns,
    found: found,
    via: via,
    oneToOne: oneToOne,
  );

  @override
  String toString() => 'FluentRelationLink(${owner.tableName}.${describe()})';
}

/// [columns] → the part of [id] for the key column at the same place of [keyColumns]. `null` clears every column; a
/// plain value for a composite key is refused (it would fill one column and leave the others NULL).
Map<String, Object?> _zipKey(List<String> columns, List<String> keyColumns, Object? id) {
  if (columns.length == 1) return {columns.first: id is FluentKey ? id[keyColumns.first] : id};
  if (id != null && id is! FluentKey) throw _compositeKeyNeeded(keyColumns, id);
  return {for (int i = 0; i < columns.length; i++) columns[i]: id is FluentKey ? id[keyColumns[i]] : null};
}

FluentArgumentException _compositeKeyNeeded(List<String> keyColumns, Object id) => FluentArgumentException(
  'id',
  'the key ($id) refers to a table with the composite key (${keyColumns.join(', ')}); a single value cannot fill it.',
  hint: 'Pass a FluentKey: FluentKey({${keyColumns.map((k) => "'$k': ...").join(', ')}}), or the model\'s own .key.',
);

/// The values of [columns] in [row] as a key: the plain value for one column, a [FluentKey] otherwise
/// (keyed by [keyColumns], so it compares equal to the referenced row's own key). `null` when any part is missing.
Object? _rowTuple(Map<String, dynamic> row, List<String> columns, List<String> keyColumns) {
  if (columns.length == 1) return row[columns.first];
  final Map<String, Object?> values = {};
  for (int i = 0; i < columns.length; i++) {
    final Object? v = row[columns[i]];
    if (v == null) return null;
    values[keyColumns[i]] = v;
  }
  return FluentKey(values);
}

/// A stable map key for a plain id or a [FluentKey]: the values in key column order joined by `\u0001` (the relation
/// reader builds the same text from link rows).
String _tupleKey(Object? id) => id is FluentKey ? id.values.values.map((v) => '$v').join('\u0001') : '$id';

/// `"column" = value` on a value that is already stored (read from a row, or converted with `_storedId`): no converter
/// of the column is applied again. `null` gives `IS NULL`.
FluentFilter _storedEq(String column, Object? value) => value == null ? FluentFilter.isNull(column.quotedIdentifier) : FluentFilter('${column.quotedIdentifier} = ?', [value]);

/// `"column" IN (...)` on values that are already stored (see [_storedEq]).
FluentFilter _storedIn(String column, List<Object> values) => values.isEmpty ? const FluentFilter('1 = 0') : FluentFilter('${column.quotedIdentifier} IN (${List.filled(values.length, '?').join(', ')})', values);

/// `"column" IN (...)` on Dart values the column converts (like [FluentFilter.inList], but always bound arguments:
/// internal key lists are chunked by their callers, never moved to a temporary table).
FluentFilter _dartIn(String column, List<Object> values) => values.isEmpty
    ? const FluentFilter('1 = 0')
    : FluentFilter('${column.quotedIdentifier} IN (${List.filled(values.length, '?').join(', ')})', FluentFilterArgs(values, List<String?>.filled(values.length, column)));

/// A filter matching rows whose [columns] equal one of [ids] (plain values or [FluentKey]s keyed by [keyColumns]).
/// `null` ids match nothing (a missing key refers to no row) and are left out. [stored]: the values are SQLite values
/// (read from rows, or from reference columns) and are used as they are; otherwise they are Dart values that the
/// columns convert like on save.
FluentFilter _tupleFilter(List<String> columns, List<String> keyColumns, List<Object?> ids, {bool stored = false}) {
  if (columns.length == 1) {
    final List<Object> values = [for (final Object? id in ids) if ((id is FluentKey ? id[keyColumns.first] : id) case final Object v) v];
    if (values.isEmpty) return const FluentFilter('1 = 0');
    return stored ? _storedIn(columns.first, values) : _dartIn(columns.first, values);
  }
  final List<FluentKey> keys = [
    for (final Object? id in ids)
      if (id is FluentKey) id else if (id != null) throw _compositeKeyNeeded(keyColumns, id),
  ];
  if (keys.isEmpty) return const FluentFilter('1 = 0');
  FluentFilter eq(String column, Object? value) => stored ? _storedEq(column, value) : FluentFilter.eq(column.quotedIdentifier, value);
  return keys.map((id) => [for (int i = 0; i < columns.length; i++) eq(columns[i], id[keyColumns[i]])].reduce((a, b) => a.and(b))).reduce((a, b) => a.or(b));
}

/// Reference column names for a relation [name] pointing to [keyColumns]: `<name>_id` for a simple key,
/// `<name>_<key column>` for a composite key. An explicit / detected single column wins for simple keys.
List<String> _referenceColumnNames(String name, List<String> keyColumns, {String? explicit}) {
  if (keyColumns.length == 1) return [explicit ?? '${FluentUtils.toSnakeCase(name)}_id'];
  return [for (final String k in keyColumns) '${FluentUtils.toSnakeCase(name)}_$k'];
}

/// The default reference columns of an owned list, named like its owner (`Article` → `article_id`).
List<String> _ownerNamedColumns(FluentProvider owner, List<String> ownerKeys) {
  if (ownerKeys.length == 1) return [_fluentModelKey(owner.modelType)];
  final String prefix = _fluentModelKey(owner.modelType).replaceAll(RegExp(r'_id$'), '');
  return [for (final String k in ownerKeys) '${prefix}_$k'];
}

/// `Person` → `person_id`, `ArticleModel` → `article_id`.
String _fluentModelKey(Type type) {
  String name = type.toString();
  final int generic = name.indexOf('<');
  if (generic > 0) name = name.substring(0, generic);
  if (name.endsWith('Model') && name.length > 5) name = name.substring(0, name.length - 5);
  return '${FluentUtils.toSnakeCase(name)}_id';
}

/// One validated declaration while the graph is being built.
class _Declaration {
  _Declaration(this.owner, this.relation, this.target) : type = relation.type, shapeIsList = _shape(relation, owner);

  final FluentProvider owner;
  final FluentRelation relation;
  final FluentProvider target;

  /// Declared type, replaced by the resolved one for `auto`.
  FluentRelationType type;

  /// List (`true`), single (`false`) or unknown (`null`), from the select function.
  final bool? shapeIsList;

  /// Reference column found by `auto` (e.g. an existing `person_id`), if any.
  String? foreignKey;

  /// Why `auto` chose [type].
  String? decidedBy;

  /// Delete rule chosen by `auto` (the declaration's own `onDelete` wins).
  FluentOnDelete? onDelete;

  /// Found in `buildJson` instead of declared.
  bool found = false;

  /// For [FluentRelation.through]: the provider of the link model.
  FluentProvider? linkModel;

  /// For [FluentRelation.oneOf]: table name → provider of every type the reference may point to.
  Map<String, FluentProvider> targets = const {};

  /// For an owned list found automatically: the `oneOf` relation of the target that points back.
  String? via;

  /// Decided by `auto` as one side of a one-to-one pair.
  bool oneToOne = false;

  bool get isAuto => relation.type == FluentRelationType.auto;

  /// Whether this side holds a list (resolved type, or the shape for unresolved autos).
  bool? get holdsList => isAuto && type == FluentRelationType.auto ? shapeIsList : type.isList;

  static bool? _shape(FluentRelation relation, FluentProvider owner) {
    final bool? byType = relation.selectsList;
    if (byType != null) return byType;
    try {
      final Object? sample = relation.selectFrom(owner.modelSample);
      if (sample is Iterable) return true;
      if (sample is FluentStorable) return false;
    } catch (_) {
      // The sample cannot answer; the shape stays unknown.
    }
    return null;
  }
}

/// Resolves the declared relations of all [providers] of one database into [FluentRelationLink]s.
///
/// 1. **Collect:** every declaration is validated (problems → warning with a hint, the relation is skipped).
/// 2. **Decide:** `auto` relations are resolved with the full picture of the database
///    (see [FluentRelationType.auto]); [autoFallback] is used for lists without any signal.
/// 3. **Build:** reference columns, link tables and delete rules (one rule per shared reference column, see
///    [_resolveSharedDeleteRules]), then `through` links; the tree is written to the debug log. The `autoRelations`
///    hint is not published here but by [FluentRelationSchema.keepOneToOneSides], once the final graph is known.
///
/// [storedRelations] (table → relation name → storage, as kept in [FluentTableSnapshot.relations]) keeps the side
/// that stores the key of an `auto` one-to-one pair as it was stored before
/// (see [FluentRelationSchema.keepOneToOneSides]).
void buildFluentRelationGraph(
  Iterable<FluentProvider> providers, {
  required bool foreignKeysEnabled,
  FluentRelationType autoFallback = FluentRelationType.manyToMany,
  bool indexReferences = true,
  bool autoRelations = true,
  Map<String, Map<String, String>> storedRelations = const {},
}) {
  final List<FluentProvider> all = providers.toList(growable: false);
  void build() => _buildFluentRelationGraph(
    all,
    foreignKeysEnabled: foreignKeysEnabled,
    autoFallback: autoFallback,
    indexReferences: indexReferences,
    autoRelations: autoRelations,
    storedRelations: storedRelations,
  );
  // The same graph with the 1.x naming rule tells which tables / columns a 1.x database stored under other names.
  final Map<FluentProvider, _FluentGraphShape>? legacy = _legacyGraph(all, build);
  build();
  _recordLegacyNames(all, legacy);
}

void _buildFluentRelationGraph(
  List<FluentProvider> all, {
  required bool foreignKeysEnabled,
  required FluentRelationType autoFallback,
  required bool indexReferences,
  required bool autoRelations,
  required Map<String, Map<String, String>> storedRelations,
}) {
  void rebuild(Map<String, Map<String, String>> stored) => buildFluentRelationGraph(
    all,
    foreignKeysEnabled: foreignKeysEnabled,
    autoFallback: autoFallback,
    indexReferences: indexReferences,
    autoRelations: autoRelations,
    storedRelations: stored,
  );
  final Map<Type, List<FluentProvider>> byModel = {};
  for (final FluentProvider p in all) {
    byModel.putIfAbsent(p.modelType, () => []).add(p);
  }

  for (final FluentProvider p in all) {
    p._links = <FluentRelationLink>[];
    p._incomingLinks = <FluentRelationLink>[];
    p._foreignKeysEnforced = foreignKeysEnabled;
    p._indexReferences = p._tableConfig.indexReferences ?? indexReferences;
    p._relationPeers = const [];
    _graphRebuild[p] = rebuild;
  }

  void skip(FluentProvider owner, FluentRelation r, String why, String hint) {
    FluentLog.issue(FluentIssueKind.relationDeclaration, 'Relation "${r.name}" of "${owner.tableName}" skipped: $why', table: owner.tableName, tag: 'FluentRelations', hint: hint);
  }

  // ---- 1. Collect -------------------------------------------------------------------------------------
  final List<_Declaration> declarations = [];
  for (final FluentProvider owner in all) {
    final FluentStorable sample = owner.modelSample;
    final Set<String> names = {};

    for (final FluentRelation r in sample is FluentRelations ? sample.relations : const <FluentRelation>[]) {
      final String example = 'FluentRelation.${r.type.name}<${owner.modelType}, Post>("${r.name}", ...)';

      if (r.name.trim().isEmpty) {
        skip(owner, r, 'the name is empty.', 'Give every relation a name, e.g. $example.');
        continue;
      }
      if (!names.add(r.name)) {
        skip(owner, r, 'the name is used twice.', 'Every relation of ${owner.modelType} needs a unique name, e.g. "author" and "editor".');
        continue;
      }
      if (r.parentType != owner.modelType && r.parentType != FluentStorable) {
        skip(owner, r, 'it is declared for ${r.parentType}, not for ${owner.modelType}.', 'Declare it as FluentRelation<${owner.modelType}, ${r.childType}>.');
        continue;
      }
      if (r.type == FluentRelationType.oneOf) {
        final _Declaration? d = _oneOfDeclaration(owner, r, byModel, skip);
        if (d != null) declarations.add(d);
        continue;
      }
      if (r.childType == FluentStorable || r.childType == dynamic) {
        skip(owner, r, 'the related model type is unknown.', 'Pass both generic types: $example.');
        continue;
      }
      final List<FluentProvider> targets = byModel[r.childType] ?? const [];
      if (targets.isEmpty) {
        skip(owner, r, 'no provider for ${r.childType} in this database.', 'Add the provider of ${r.childType} to the same FluentGroup as ${owner.runtimeType}.');
        continue;
      }
      if (targets.length > 1) {
        skip(
          owner,
          r,
          '${r.childType} is stored in several tables (${targets.map((p) => p.tableName).join(', ')}), the relation cannot choose one.',
          'Give each table its own model type (e.g. class ArchivedNote extends Note), so the relation names exactly one table.',
        );
        continue;
      }
      final FluentProvider target = targets.single;
      final _Declaration d = _Declaration(owner, r, target);
      if (r.linkModel != null) {
        final List<FluentProvider> vias = byModel[r.linkModel] ?? const [];
        if (vias.length != 1) {
          skip(
            owner,
            r,
            vias.isEmpty ? 'no provider for the link model ${r.linkModel} in this database.' : 'the link model ${r.linkModel} is stored in several tables.',
            vias.isEmpty ? 'Add the provider of ${r.linkModel} to the same FluentGroup as ${owner.runtimeType}.' : 'Give each table its own model type.',
          );
          continue;
        }
        d.linkModel = vias.single;
      }
      if (!d.isAuto && d.shapeIsList != null && d.shapeIsList != r.type.isList) {
        FluentLog.issue(
          FluentIssueKind.relationDeclaration,
          'Relation "${r.name}" of "${owner.tableName}" is declared as ${r.type.name}, but its select returns ${d.shapeIsList! ? 'a list' : 'a single model'}.',
          table: owner.tableName,
          tag: 'FluentRelations',
          hint: d.shapeIsList!
              ? 'For a list use FluentRelation.many / manyToMany (or auto).'
              : 'For a single model use FluentRelation.one / oneOwned (or auto).',
        );
      }
      declarations.add(d);
    }

    _findRelations(owner, sample, names, all, declarations, add: owner._tableConfig.autoRelations ?? autoRelations);
  }

  // ---- 2. Decide auto relations ------------------------------------------------------------------------
  final Map<FluentProvider, Set<String>> columnsCache = Map.identity();
  Set<String> columnsOf(FluentProvider p) => columnsCache[p] ??= {for (final FluentDbColumn c in p.modelSample.tableSchema) c.name};

  for (final _Declaration d in declarations) {
    if (d.isAuto) _decideAuto(d, declarations, columnsOf, autoFallback, storedRelations);
  }

  // ---- 3. Build links -----------------------------------------------------------------------------------
  for (final _Declaration d in declarations) {
    if (d.linkModel != null) continue; // after the links of the link models (see _throughLink)
    final FluentProvider owner = d.owner;
    final FluentProvider target = d.target;
    final FluentRelation r = d.relation;

    final List<String> ownerKeys = [for (final FluentDbColumn c in owner.modelSample.primaryKeys) c.name];
    final List<String> targetKeys = [for (final FluentDbColumn c in target.modelSample.primaryKeys) c.name];

    final FluentRelationLink link;
    final String? via = r.via ?? d.via;
    if (d.type == FluentRelationType.oneOf) {
      final Map<String, List<String>> columns = {for (final MapEntry<String, FluentProvider> t in d.targets.entries) t.key: _oneOfColumns(r.name, t.value)};
      link = FluentRelationLink._(
        relation: r,
        type: FluentRelationType.oneOf,
        owner: owner,
        target: target,
        targets: d.targets,
        targetColumns: columns,
        typeColumn: '${FluentUtils.toSnakeCase(r.name)}_type',
        foreignKeys: {for (final List<String> c in columns.values) ...c}.toList(),
        onDelete: r.onDelete ?? FluentOnDelete.setNull,
      );
      owner._links.add(link);
      continue;
    }
    if (via != null && (d.type == FluentRelationType.many || d.type == FluentRelationType.oneOwned)) {
      final _Declaration? back = declarations.where((b) => identical(b.owner, target) && b.relation.type == FluentRelationType.oneOf && b.relation.name == via).firstOrNull;
      if (back == null || !back.targets.values.any((p) => identical(p, owner))) {
        FluentLog.issue(
          FluentIssueKind.relationDeclaration,
          'Relation "${r.name}" of "${owner.tableName}" skipped: ${back == null ? '${target.modelType} has no oneOf relation "$via"' : '${target.modelType}.$via cannot point to ${owner.modelType}'}.',
          table: owner.tableName,
          database: owner.dbName,
          subject: r.name,
          tag: 'FluentRelations',
          hint: back == null
              ? "Declare it in ${target.modelType}: FluentRelation.oneOf<${target.modelType}>('$via', (m) => m.$via, types: [${owner.modelType}, ...])."
              : 'Add ${owner.modelType} to the types of ${target.modelType}.$via.',
        );
        continue;
      }
      link = FluentRelationLink._(
        relation: r,
        type: d.type,
        owner: owner,
        target: target,
        typeColumn: '${FluentUtils.toSnakeCase(via)}_type',
        typeValue: owner.tableName,
        foreignKeys: _oneOfColumns(via, owner),
        referencedColumns: ownerKeys,
        onDelete: r.onDelete ?? d.onDelete ?? FluentOnDelete.cascade,
        decidedBy: d.decidedBy,
        found: d.found,
        via: via,
      );
      owner._links.add(link);
      target._incomingLinks.add(link);
      continue;
    }
    switch (d.type) {
      case FluentRelationType.oneOf:
        continue; // built above
      case FluentRelationType.one:
        link = FluentRelationLink._(
          relation: r,
          type: d.type,
          owner: owner,
          target: target,
          foreignKeys: _referenceColumnNames(r.name, targetKeys, explicit: r.foreignKey ?? d.foreignKey),
          referencedColumns: targetKeys,
          onDelete: r.onDelete ?? FluentOnDelete.setNull,
          decidedBy: d.decidedBy,
          found: d.found,
          oneToOne: d.oneToOne,
        );

      case FluentRelationType.oneOwned:
      case FluentRelationType.many:
        final String? explicit = r.foreignKey ?? d.foreignKey;
        List<String>? fks = explicit != null && ownerKeys.length == 1 ? [explicit] : null;
        if (fks == null) {
          // Reuse the columns of a matching back-reference: Comment.article (one) ↔ Article.comments (many).
          final List<_Declaration> backRefs = [
            for (final _Declaration b in declarations)
              if (identical(b.owner, target) && identical(b.target, owner) && b.type == FluentRelationType.one && !identical(b, d)) b,
          ];
          final List<String> ownerNamed = _ownerNamedColumns(owner, ownerKeys);
          List<String> columnsOf(_Declaration b) => _referenceColumnNames(b.relation.name, ownerKeys, explicit: b.relation.foreignKey ?? b.foreignKey);
          final _Declaration? named = backRefs.where((b) => listEquals(columnsOf(b), ownerNamed)).firstOrNull;
          if (backRefs.length == 1) {
            fks = columnsOf(backRefs.first);
          } else if (named != null) {
            // Comment.article + Comment.featured + Article.comments: the reference named like the owner is the other
            // end of the list (they share the column); the other references are not ambiguous.
            fks = ownerNamed;
          } else if (backRefs.length > 1) {
            final List<String> options = [for (final _Declaration b in backRefs) _referenceColumnNames(b.relation.name, ownerKeys, explicit: b.relation.foreignKey ?? b.foreignKey).join(', ')];
            FluentLog.issue(
              FluentIssueKind.relationDeclaration,
              '"${owner.tableName}.${r.name}": ${target.modelType} references ${owner.modelType} ${backRefs.length} times '
                  '(${backRefs.map((b) => b.relation.name).join(', ')}), and none is named like the owner, so the list cannot tell which one it follows; '
                  'it uses its own column ${ownerNamed.join(', ')}.',
              table: owner.tableName,
              database: owner.dbName,
              subject: r.name,
              tag: 'FluentRelations',
              hint: 'Name the column the list follows with foreignKey.',
              code: "FluentRelation.many<${owner.modelType}, ${target.modelType}>('${r.name}', (m) => m.${r.name}, foreignKey: '${options.first}'),",
            );
          }
        }
        fks ??= _ownerNamedColumns(owner, ownerKeys);

        // Two owned lists sharing columns by accident (an explicit foreignKey is a deliberate choice, e.g. a filtered view).
        final List<String> current = fks;
        final bool clash = r.foreignKey == null && owner._links.any((l) => l.isOwned && identical(l.target, target) && listEquals(l.foreignKeys, current));
        if (clash) {
          final List<String> fallback = [for (final String c in current) '${FluentUtils.toSnakeCase(r.name)}_$c'];
          FluentLog.issue(
            FluentIssueKind.relationDeclaration,
            'Relation "${r.name}" of "${owner.tableName}" would share column(s) ${target.tableName}.${current.join(', ')} with another list; '
                'it uses ${fallback.join(', ')} instead.',
            table: owner.tableName,
            subject: r.name,
            tag: 'FluentRelations',
            hint: 'Set foreignKey explicitly when one model owns several lists of the same type, e.g. foreignKey: "${FluentUtils.toSnakeCase(r.name)}_id".',
          );
          fks = fallback;
        }
        link = FluentRelationLink._(
          relation: r,
          type: d.type,
          owner: owner,
          target: target,
          foreignKeys: fks,
          referencedColumns: ownerKeys,
          onDelete: r.onDelete ?? d.onDelete ?? FluentOnDelete.cascade,
          decidedBy: d.decidedBy,
          found: d.found,
          oneToOne: d.oneToOne,
        );

      case FluentRelationType.manyToMany:
      case FluentRelationType.auto:
        final bool self = identical(owner, target);
        final bool siblings = declarations.where((x) => identical(x.owner, owner) && identical(x.target, target) && x.type == FluentRelationType.manyToMany).length > 1;
        final List<String> tables = [owner.tableName, target.tableName]..sort();
        final String table = r.linkTable ?? (self || siblings ? '${owner.tableName}_${FluentUtils.toSnakeCase(r.name)}' : '${tables[0]}_${tables[1]}');
        List<String> linkColumns(Type model, List<String> keys, String? explicit) {
          if (keys.length == 1) return [explicit ?? _fluentModelKey(model)];
          final String prefix = _fluentModelKey(model).replaceAll(RegExp(r'_id$'), '');
          return [for (final String k in keys) '${prefix}_$k'];
        }

        final List<String> ownerColumns = linkColumns(owner.modelType, ownerKeys, r.linkParentKey);
        List<String> targetColumns = linkColumns(target.modelType, targetKeys, r.linkChildKey);
        if (targetColumns.any(ownerColumns.contains)) targetColumns = [for (final String c in targetColumns) 'related_$c'];
        link = FluentRelationLink._(
          relation: r,
          type: FluentRelationType.manyToMany,
          owner: owner,
          target: target,
          onDelete: FluentOnDelete.cascade,
          linkTable: table,
          linkOwnerColumns: ownerColumns,
          linkTargetColumns: targetColumns,
          decidedBy: d.decidedBy,
          found: d.found,
        );
    }

    owner._links.add(link);
    if (link.isOwned) target._incomingLinks.add(link);
    if (link.isOwned && owner._softDeleteColumn != null && target._softDeleteColumn == null) {
      FluentLog.issue(
        FluentIssueKind.relationSoftDelete,
        '"${owner.tableName}.${link.name}": ${owner.modelType} is soft-deletable but ${target.modelType} is not; '
        'children of an owner in the trash stay visible.',
        table: owner.tableName,
        tag: '${owner.tableName}:relations',
        hint: 'Add `with FluentSoftDeletable` to ${target.modelType}: its rows then go to the trash and come back together with the owner.',
      );
    }
  }

  final List<(String, FluentRelationLink)> shared = _resolveSharedDeleteRules(all);

  for (final _Declaration d in declarations) {
    final FluentRelationLink? link = d.linkModel == null ? null : _throughLink(d);
    if (link != null) d.owner._links.add(link);
  }

  final List<FluentProvider> peers = [for (final FluentProvider p in all) if (p._links.isNotEmpty || p._incomingLinks.isNotEmpty) p];
  for (final FluentProvider p in all) {
    p._relationPeers = peers;
  }

  if (!foreignKeysEnabled && all.any((p) => p._links.isNotEmpty)) {
    FluentLog.issue(
      FluentIssueKind.foreignKeysOff,
      'Foreign keys are disabled, so deleting a row will not remove its owned children automatically.',
      tag: 'FluentRelations',
      hint: 'Keep FluentDbConfig(enableForeignKeys: true) when you use relations. Orphans are still cleaned at start-up.',
    );
  }

  for (final FluentProvider p in all) {
    if (p._links.isEmpty) continue;
    FluentLog.debug('Relations of "${p.tableName}":\n  ${p._links.map((l) => l.describe()).join('\n  ')}', tag: 'FluentRelations');
  }
  // Reported once the stored relation storage is known (a pair may still keep its stored side, see
  // [FluentRelationSchema.keepOneToOneSides]): the hint then shows the final decisions only.
  void report() => _reportDecided(all, shared);
  for (final FluentProvider p in all) {
    _pendingDecisions[p] = report;
  }
}

/// One delete rule per reference column: a `one` back-reference and an owned list over the same column
/// (`Category.parent` ↔ `Category.children`, both `categories.parent_id`) are one SQL `REFERENCES`, so both links get
/// the same [FluentRelationLink.onDelete] — the library's own cascades (orphan clean-up with foreign keys off,
/// tombstones, change events) then do what SQLite does.
///
/// An explicitly declared `onDelete` wins (the reference's, when both declare one). Otherwise the reference's rule
/// (`setNull`: a reference never deletes data), except when the reference is named like the owner of the list
/// (`Comment.article` + `Article.comments`, both `article_id`): the two are one relation seen from both ends and the
/// children are owned, so the list's rule (`cascade`) applies. Returns, for every column whose declarations disagreed, a note and
/// the link whose declaration states the rule (for the hint of [_reportDecided]).
List<(String, FluentRelationLink)> _resolveSharedDeleteRules(List<FluentProvider> all) {
  final List<(String, FluentRelationLink)> notes = [];
  final Map<String, List<FluentRelationLink>> byColumns = {};
  for (final FluentProvider p in all) {
    for (final FluentRelationLink l in p._links) {
      if (l.isPolymorphic || !(l.isReference || l.isOwned)) continue;
      // The table that holds the column, the column(s), and the table they point to.
      final (FluentProvider holder, FluentProvider referenced) = l.isReference ? (l.owner, l.target) : (l.target, l.owner);
      byColumns.putIfAbsent('${holder.tableName}|${l.foreignKeys.join(',')}|${referenced.tableName}', () => []).add(l);
    }
  }
  for (final List<FluentRelationLink> group in byColumns.values) {
    if (group.length < 2 || group.every((l) => l.onDelete == group.first.onDelete)) continue;
    final List<FluentRelationLink> explicit = [for (final FluentRelationLink l in group) if (l.relation.onDelete != null) l];
    final FluentRelationLink? reference = group.where((l) => l.isReference).firstOrNull;
    final FluentRelationLink? owned = group.where((l) => l.isOwned).firstOrNull;
    // The reference is named like the owner of the list: one relation, the owned side states the rule.
    final bool sameRelation = reference != null && owned != null && reference.relation.foreignKey == null && listEquals(reference.foreignKeys, _ownerNamedColumns(owned.owner, owned.referencedColumns));
    final FluentRelationLink decides = explicit.isNotEmpty ? (explicit.where((l) => l.isReference).firstOrNull ?? explicit.first) : (sameRelation ? owned : (reference ?? group.first));
    final FluentOnDelete rule = decides.onDelete;
    for (final FluentRelationLink l in group) {
      if (l.onDelete == rule) continue;
      final FluentRelationLink resolved = l._withOnDelete(rule);
      l.owner._links[l.owner._links.indexOf(l)] = resolved;
      if (l.isOwned) {
        final int i = l.target._incomingLinks.indexOf(l);
        if (i >= 0) l.target._incomingLinks[i] = resolved;
      }
    }
    final FluentProvider holder = decides.isReference ? decides.owner : decides.target;
    final String columns = '${holder.tableName}.${decides.foreignKeys.join(', ')}';
    final List<String> names = [for (final FluentRelationLink l in group) '${l.owner.modelType}.${l.name} (${l.onDelete.name})'];
    final FluentRelationLink other = group.firstWhere((l) => !identical(l, decides));
    notes.add((
      '${names.join(' and ')} share the reference $columns: on delete ${rule.name} applies to both '
          '(${decides.relation.onDelete != null ? 'declared by ${decides.owner.modelType}.${decides.name}' : "the reference's rule"}).',
      other._withOnDelete(rule),
    ));
  }
  return notes;
}

/// Reference columns of the `oneOf` relation [name] for the referenced [target]: `<name>_id` for a key of one column,
/// `<name>_<key column>` for each column of a composite key.
List<String> _oneOfColumns(String name, FluentProvider target) {
  final String prefix = FluentUtils.toSnakeCase(name);
  final List<String> keys = target.keyColumnNames.toList();
  return keys.length == 1 ? ['${prefix}_id'] : [for (final String k in keys) '${prefix}_$k'];
}

/// Validates a [FluentRelation.oneOf] declaration: every type needs exactly one provider.
_Declaration? _oneOfDeclaration(FluentProvider owner, FluentRelation r, Map<Type, List<FluentProvider>> byModel, void Function(FluentProvider, FluentRelation, String, String) skip) {
  if (r.types.isEmpty) {
    skip(owner, r, 'it has no types.', "List the models it may point to: FluentRelation.oneOf<${owner.modelType}>('${r.name}', ..., types: [Post, Photo]).");
    return null;
  }
  final Map<String, FluentProvider> targets = {};
  for (final Type t in r.types) {
    final List<FluentProvider> providers = byModel[t] ?? const [];
    if (providers.length != 1) {
      skip(
        owner,
        r,
        providers.isEmpty ? 'no provider for $t in this database.' : '$t is stored in several tables.',
        providers.isEmpty ? 'Add the provider of $t to the same FluentGroup, or remove $t from types.' : 'Give each table its own model type.',
      );
      return null;
    }
    targets[providers.single.tableName] = providers.single;
  }
  return _Declaration(owner, r, targets.values.first)..targets = targets;
}

/// Resolves a [FluentRelation.through] declaration with the `one` relations of its link model, or reports why not.
FluentRelationLink? _throughLink(_Declaration d) {
  final FluentRelation r = d.relation;
  final FluentProvider via = d.linkModel!;
  FluentRelationLink? side(FluentProvider to, String? name, String role) {
    final List<FluentRelationLink> candidates = [
      for (final FluentRelationLink l in via._links)
        if (l.isReference && identical(l.target, to) && (name == null || l.name == name)) l,
    ];
    if (candidates.length == 1) return candidates.single;
    FluentLog.issue(
      FluentIssueKind.relationDeclaration,
      'Relation "${r.name}" of "${d.owner.tableName}" skipped: ${via.modelType} has ${candidates.isEmpty ? 'no' : '${candidates.length}'} '
          '${name == null ? '' : '"$name" '}relation(s) of kind one to ${to.modelType}.',
      table: d.owner.tableName,
      database: d.owner.dbName,
      subject: r.name,
      tag: 'FluentRelations',
      hint: candidates.isEmpty
          ? 'Give ${via.modelType} a field holding the ${to.modelType} (or FluentRelation.one<${via.modelType}, ${to.modelType}>).'
          : 'Name the one to use with $role: ${candidates.map((l) => '"${l.name}"').join(' or ')}.',
    );
    return null;
  }

  final bool self = identical(d.owner, d.target);
  if (self && (r.parentVia == null || r.childVia == null)) {
    // Both sides of the link model point at the same table: only the names tell which side is which.
    FluentLog.issue(
      FluentIssueKind.relationDeclaration,
      'Relation "${r.name}" of "${d.owner.tableName}" skipped: it links ${d.owner.modelType} to itself through ${via.modelType}, '
          'so it needs parentVia and childVia (the relations of ${via.modelType} pointing at the owner and at the related row).',
      table: d.owner.tableName,
      database: d.owner.dbName,
      subject: r.name,
      tag: 'FluentRelations',
      hint: 'Name both sides of the link model, e.g. '
          "FluentRelation.through<${d.owner.modelType}, ${via.modelType}, ${d.owner.modelType}>('${r.name}', ..., parentVia: 'follower', childVia: 'followed').",
    );
    return null;
  }
  final FluentRelationLink? parent = side(d.owner, r.parentVia, 'parentVia');
  final FluentRelationLink? child = parent == null ? null : side(d.target, r.childVia, 'childVia');
  if (parent == null || child == null) return null;
  return FluentRelationLink._(
    relation: r,
    type: FluentRelationType.manyToMany,
    owner: d.owner,
    target: d.target,
    onDelete: FluentOnDelete.cascade,
    linkTable: via.tableName,
    linkOwnerColumns: parent.foreignKeys,
    linkTargetColumns: child.foreignKeys,
    linkModel: via,
  );
}

/// Adds the fields of [owner]'s `buildJson` that hold models of another provider (and are not declared) as `auto`
/// relations. Fields holding models no provider stores are reported: they would never be saved. Without [add]
/// (`autoRelations: false`) such fields are only reported: they are neither columns nor relations.
void _findRelations(FluentProvider owner, FluentStorable sample, Set<String> names, List<FluentProvider> all, List<_Declaration> declarations, {required bool add}) {
  final Map<String, dynamic> json;
  try {
    json = sample.buildJson();
  } catch (e, s) {
    FluentLog.issue(
      FluentIssueKind.relationDeclaration,
      'Fields of "${owner.tableName}" holding other models are not detected: buildJson of its modelSample threw.',
      table: owner.tableName,
      database: owner.dbName,
      tag: 'FluentRelations',
      error: e,
      stackTrace: s,
      hint: 'Make buildJson work for modelSample (give required fields sample values), or declare the relations with FluentRelations.',
    );
    return;
  }
  for (final MapEntry<String, dynamic> field in json.entries) {
    final Object? value = field.value;
    final bool list = value is Iterable<FluentStorable>;
    if (names.contains(field.key) || (!list && value is! FluentStorable)) continue;
    if (!add) {
      FluentLog.issue(
        FluentIssueKind.relationDeclaration,
        'Field "${field.key}" of "${owner.tableName}" holds ${value.runtimeType}, but autoRelations is off and no relation is declared for it; it is not saved.',
        table: owner.tableName,
        database: owner.dbName,
        subject: field.key,
        tag: 'FluentRelations',
        hint: 'Declare the relation (with FluentRelations), turn autoRelations on for this table, or leave the field out of buildJson.',
      );
      continue;
    }

    final List<FluentProvider> matches = [for (final FluentProvider p in all) if (p._stores(value, list: list)) p];
    // The most specific model wins (class SpecialPost extends Post): the one every other match also accepts.
    final List<FluentProvider> targets = [
      for (final FluentProvider p in matches)
        if (matches.every((o) => o._stores(p.modelSample, list: false))) p,
    ];
    if (targets.length != 1) {
      FluentLog.issue(
        FluentIssueKind.relationDeclaration,
        targets.isEmpty
            ? 'Field "${field.key}" of "${owner.tableName}" holds ${value.runtimeType}, but no provider of this database stores that model; it is not saved.'
            : 'Field "${field.key}" of "${owner.tableName}" holds ${value.runtimeType}, which is stored in several tables '
                  '(${targets.map((p) => p.tableName).join(', ')}); it is not saved.',
        table: owner.tableName,
        database: owner.dbName,
        subject: field.key,
        tag: 'FluentRelations',
        hint: targets.isEmpty
            ? 'Add the provider of that model to the same FluentGroup, or leave the field out of buildJson.'
            : 'Give each table its own model type (class ArchivedPost extends Post), or declare the relation with the type of the table.',
      );
      continue;
    }
    names.add(field.key);
    declarations.add(_Declaration(owner, targets.single._foundRelation(field.key), targets.single)..found = true);
  }
}

/// One hint per database: the relations decided automatically, with the declarations that fix them, and the
/// reference columns two relations share with one delete rule ([shared], see [_resolveSharedDeleteRules]).
void _reportDecided(List<FluentProvider> all, List<(String, FluentRelationLink)> shared) {
  final List<FluentRelationLink> decided = [
    for (final FluentProvider p in all)
      for (final FluentRelationLink l in p._links) if (l.decidedBy != null) l,
  ];
  if (decided.isEmpty && shared.isEmpty) return;
  final List<FluentRelationLink> stating = [
    for (final (String _, FluentRelationLink l) in shared) if (!decided.any((d) => identical(d.owner, l.owner) && d.name == l.name)) l,
  ];
  String declarationOf(FluentRelationLink l) => _declarationOf(shared.where((x) => identical(x.$2.owner, l.owner) && x.$2.name == l.name).firstOrNull?.$2 ?? l);
  final String declarations = [
    for (final FluentProvider p in all)
      if (decided.any((l) => identical(l.owner, p))) ...[
        '// ${p.modelType}${p.modelSample is FluentRelations ? '' : ' (add: with FluentRelations)'}',
        '@override',
        'List<FluentRelation> get relations => [',
        for (final FluentRelationLink l in decided)
          if (identical(l.owner, p)) '  ${declarationOf(l)},',
        '];',
      ],
    if (stating.isNotEmpty) '// The delete rule of shared reference columns, stated explicitly:',
    for (final FluentRelationLink l in stating) '${declarationOf(l)}, // in ${l.owner.modelType}.relations',
  ].join('\n');
  final int kept = decided.where((l) => l.decidedBy!.endsWith(_keptAsStored)).length;
  final String sharing = shared.isEmpty ? '' : '${shared.length} reference column(s) shared by two relations use one delete rule';
  FluentLog.issue(
    FluentIssueKind.autoRelations,
    decided.isEmpty
        ? '$sharing in "${all.first.dbName}".'
        : '${decided.length} relation(s) of "${all.first.dbName}" were decided automatically${kept == 0 ? '' : ' ($kept kept as stored)'}'
              '${sharing.isEmpty ? '' : '; $sharing'}.',
    details: [for (final FluentRelationLink l in decided) '${l.owner.modelType}.${l.describe()}', for (final (String note, FluentRelationLink _) in shared) note].join('\n'),
    database: all.first.dbName,
    tag: 'FluentRelations',
    hint: decided.isEmpty
        ? "Declare onDelete on one of the two relations to choose the rule (both follow it); a declared rule wins over the reference's."
        : 'Check that each one means what you want; declare it to fix it (a declaration always wins), or turn the '
              "search off with autoRelations: false.${shared.isEmpty ? '' : " A shared reference column has one delete rule: a declared onDelete wins, otherwise the reference's."}",
    code: declarations,
  );
}

/// The declaration that reproduces [link] exactly: the same columns / link table, delete rule and `via`.
String _declarationOf(FluentRelationLink link) {
  final List<String> options = [
    if (link.via != null) "via: '${link.via}'"
    else if ((link.isReference || link.isOwned) && link.foreignKeys.length == 1) "foreignKey: '${link.foreignKeys.single}'",
    if (link.isManyToMany) "linkTable: '${link.linkTable}'",
    if (link.isManyToMany && link.linkOwnerColumns.length == 1) "linkParentKey: '${link.linkOwnerColumns.single}'",
    if (link.isManyToMany && link.linkTargetColumns.length == 1) "linkChildKey: '${link.linkTargetColumns.single}'",
    if (!link.isManyToMany && link.onDelete != (link.isReference ? FluentOnDelete.setNull : FluentOnDelete.cascade)) 'onDelete: FluentOnDelete.${link.onDelete.name}',
  ];
  return "FluentRelation.${link.type.name}<${link.owner.modelType}, ${link.target.modelType}>('${link.name}', (m) => m.${link.name}"
      '${options.isEmpty ? '' : ', ${options.join(', ')}'})';
}

/// Resolves one `auto` declaration from the full picture of the database (strongest signal first).
void _decideAuto(_Declaration d, List<_Declaration> all, Set<String> Function(FluentProvider) columnsOf, FluentRelationType listFallback, Map<String, Map<String, String>> stored) {
  final FluentProvider owner = d.owner;
  final FluentProvider target = d.target;
  final FluentRelation r = d.relation;
  final String ownerKey = _fluentModelKey(owner.modelType);
  final String byName = '${FluentUtils.toSnakeCase(r.name)}_id';
  final String byType = _fluentModelKey(target.modelType);

  final List<_Declaration> backs = [
    for (final _Declaration b in all)
      if (identical(b.owner, target) && identical(b.target, owner) && !identical(b, d) && b.relation.type != FluentRelationType.oneOf) b,
  ];
  final List<_Declaration> explicitBacks = backs.where((b) => !b.isAuto).toList();
  final List<_Declaration> autoBacks = backs.where((b) => b.isAuto).toList();

  void decide(FluentRelationType type, String why, {String? foreignKey}) {
    d.type = type;
    d.decidedBy = why;
    d.foreignKey = foreignKey;
  }

  FluentRelationType? preferIf(bool list) {
    final FluentRelationType? prefer = r.prefer;
    if (prefer == null || prefer == FluentRelationType.auto) return null;
    if (prefer.isList == list) return prefer;
    FluentLog.issue(
      FluentIssueKind.relationDeclaration,
      'prefer: ${prefer.name} of "${r.name}" in "${owner.tableName}" ignored: select returns ${list ? 'a list' : 'a single model'}.',
      table: owner.tableName,
      tag: 'FluentRelations',
      hint: list ? 'Use prefer: many or manyToMany for lists.' : 'Use prefer: one or oneOwned for single models.',
    );
    return null;
  }

  bool? isList = d.shapeIsList;
  if (isList == null) {
    // Shape unknown (e.g. select returns dynamic): let the columns tell, otherwise the fallback.
    if (columnsOf(owner).contains(byName) || columnsOf(owner).contains(byType)) {
      isList = false;
    } else if (columnsOf(target).contains(ownerKey)) {
      isList = true;
    } else {
      final FluentRelationType chosen = (r.prefer != null && r.prefer != FluentRelationType.auto) ? r.prefer! : listFallback;
      decide(chosen, 'select type unknown, no column signal → ${chosen.name}');
      FluentLog.issue(
        FluentIssueKind.relationDeclaration,
        'auto relation "${r.name}" of "${owner.tableName}": cannot tell if select returns a list or a single model; using ${chosen.name}.',
        table: owner.tableName,
        tag: 'FluentRelations',
        hint: 'Give the field a concrete type (List<${target.modelType}>? or ${target.modelType}?) or declare the relation type explicitly.',
      );
      return;
    }
  }

  if (isList) {
    // The target points back with a polymorphic reference that may hold this model: an owned list through it.
    final _Declaration? poly = all.where((b) => identical(b.owner, target) && b.relation.type == FluentRelationType.oneOf && b.targets.values.any((p) => identical(p, owner))).firstOrNull;
    if (poly != null) {
      d.via = poly.relation.name;
      return decide(FluentRelationType.many, '${target.modelType}.${poly.relation.name} can point to ${owner.modelType}');
    }
    final _Declaration? explicitOne = explicitBacks.where((b) => b.type == FluentRelationType.one).firstOrNull;
    if (explicitOne != null) return decide(FluentRelationType.many, '${target.modelType} declares one "${explicitOne.relation.name}" back');
    final _Declaration? explicitList = explicitBacks.where((b) => b.type.isList).firstOrNull;
    if (explicitList != null) return decide(FluentRelationType.manyToMany, '${target.modelType} declares list "${explicitList.relation.name}" back');
    if (autoBacks.any((b) => b.shapeIsList == true)) return decide(FluentRelationType.manyToMany, 'both sides list each other');
    final _Declaration? autoSingle = autoBacks.where((b) => b.shapeIsList == false).firstOrNull;
    if (autoSingle != null) return decide(FluentRelationType.many, '${target.modelType}.${autoSingle.relation.name} points back');

    // A column of the target pointing at this owner is the stronger signal: each owner keeps its own children (comments
    // of posts and of photos), even when another model lists the same type.
    if (columnsOf(target).contains(ownerKey)) return decide(FluentRelationType.many, '${target.tableName} has column "$ownerKey"');

    final List<String> otherOwners = {
      for (final _Declaration x in all)
        if (identical(x.target, target) && !identical(x.owner, owner) && (x.holdsList ?? false)) x.owner.modelType.toString(),
    }.toList();
    if (otherOwners.isNotEmpty) return decide(FluentRelationType.manyToMany, '${target.modelType} is also listed by ${otherOwners.join(', ')} (shared)');

    final FluentRelationType chosen = preferIf(true) ?? (listFallback.isList ? listFallback : FluentRelationType.manyToMany);
    return decide(chosen, 'no signal → ${r.prefer != null ? 'prefer' : 'fallback'} ${chosen.name}');
  }

  // Single model.
  final _Declaration? explicitListBack = explicitBacks.where((b) => b.type.isList).firstOrNull;
  if (explicitListBack != null) return decide(FluentRelationType.one, '${target.modelType} declares list "${explicitListBack.relation.name}" back');
  final _Declaration? explicitOneBack = explicitBacks.where((b) => b.type == FluentRelationType.one).firstOrNull;
  if (explicitOneBack != null) return decide(FluentRelationType.oneOwned, '${target.modelType}.${explicitOneBack.relation.name} references ${owner.modelType}');
  if (autoBacks.any((b) => b.shapeIsList == true)) return decide(FluentRelationType.one, '${target.modelType} lists ${owner.modelType}');

  // One-to-one: both sides hold a single model of the other. Exactly one table stores the key.
  final _Declaration? pair = identical(owner, target) ? null : autoBacks.where((b) => b.shapeIsList == false).firstOrNull;
  if (pair != null) {
    final String column = '${FluentUtils.toSnakeCase(r.name)}_id';
    d.oneToOne = true;
    final (bool storesKey, bool kept) = _storesPairKey(d, pair, all, columnsOf, stored);
    final String why = kept ? ' $_keptAsStored' : '';
    if (storesKey) {
      return decide(FluentRelationType.one, 'one-to-one with ${target.modelType}.${pair.relation.name}; "${owner.tableName}" stores the key$why', foreignKey: columnsOf(owner).contains(column) ? column : null);
    }
    d.onDelete = FluentOnDelete.setNull; // a guess never deletes data
    return decide(FluentRelationType.oneOwned, 'one-to-one with ${target.modelType}.${pair.relation.name}; "${target.tableName}" stores the key$why');
  }

  if (columnsOf(owner).contains(byName)) return decide(FluentRelationType.one, '${owner.tableName} has column "$byName"', foreignKey: byName);
  if (columnsOf(owner).contains(byType)) return decide(FluentRelationType.one, '${owner.tableName} has column "$byType"', foreignKey: byType);
  if (columnsOf(target).contains(ownerKey) && !identical(owner, target)) return decide(FluentRelationType.oneOwned, '${target.tableName} has column "$ownerKey"');

  final FluentRelationType chosen = preferIf(false) ?? FluentRelationType.one;
  decide(chosen, 'no signal → ${r.prefer != null ? 'prefer' : 'default'} ${chosen.name} (a reference never deletes data)');
}

/// Marks a one-to-one decision that kept the side stored before (in [FluentRelationLink.decidedBy]).
const String _keptAsStored = '(as stored)';

/// For a one-to-one pair of `auto` relations: whether [d]'s table stores the key (the same answer from both sides),
/// and whether that is the side [stored] before.
///
/// The table whose model declares the column; otherwise the side that stored the key before (so adding an unrelated
/// relation never moves the key, which would lose the references); otherwise, for a new pair, the model fewer
/// relations point to (`Profile` rather than `User`); otherwise the first table name.
(bool, bool) _storesPairKey(_Declaration d, _Declaration pair, List<_Declaration> all, Set<String> Function(FluentProvider) columnsOf, Map<String, Map<String, String>> stored) {
  bool hasColumn(_Declaration x) => columnsOf(x.owner).contains('${FluentUtils.toSnakeCase(x.relation.name)}_id');
  if (hasColumn(d) != hasColumn(pair)) return (hasColumn(d), false);
  // 'ref|…' on a side: that side's table stored the key; 'owned|…': the other side's table did.
  bool? storedOn(_Declaration x) => switch (stored[x.owner.tableName]?[x.relation.name]?.split('|').first) {
    'ref' => true,
    'owned' => false,
    _ => null,
  };
  final bool? pairBefore = storedOn(pair);
  final bool? before = storedOn(d) ?? (pairBefore == null ? null : !pairBefore);
  if (before != null) return (before, true);
  int pointedTo(FluentProvider p) => all.where((x) => identical(x.target, p)).length;
  final int mine = pointedTo(d.owner);
  final int theirs = pointedTo(pair.owner);
  if (mine != theirs) return (mine < theirs, false);
  return (d.owner.tableName.compareTo(pair.owner.tableName) < 0, false);
}

/// How to build the relation graph of a provider's database again with the stored relation storage, set by
/// [buildFluentRelationGraph] (used by `_keepOneToOneSides`).
final Expando<void Function(Map<String, Map<String, String>> stored)> _graphRebuild = Expando('fluentRelationGraph');

/// The decision report of the last [buildFluentRelationGraph] of a database, kept on each of its providers (published once by
/// [FluentRelationSchema.keepOneToOneSides]).
final Expando<void Function()> _pendingDecisions = Expando('fluentRelationDecisions');

/// Schema side of relations: reference columns, link tables and orphan clean-up.
extension FluentRelationSchema<T extends FluentStorable> on FluentProvider<T> {
  /// Before the schema of [providers] (one database) is compared with [db]: `auto` one-to-one pairs keep the table
  /// that stored their key on the last start (see [FluentRelationLink.oneToOne]).
  /// Then reports the relation decisions (`autoRelations` hint) of the final graph.
  static Future<void> keepOneToOneSides(DatabaseExecutor db, Iterable<FluentProvider> providers) async {
    await _keepOneToOneSides(db, providers);
    final void Function()? report = providers.map((p) => _pendingDecisions[p]).nonNulls.firstOrNull;
    for (final FluentProvider p in providers) {
      _pendingDecisions[p] = null;
    }
    report?.call();
  }

  /// Names of the declared relations (never stored as columns).
  Set<String> get _relationNames {
    // Asked for every saved row: built once per relation graph (the graph build fills [_links] in place).
    final Set<String>? cached = _linkNames;
    if (cached != null && identical(_linkNamesOf, _links) && _linkNamesCount == _links.length) return cached;
    _linkNamesOf = _links;
    _linkNamesCount = _links.length;
    return _linkNames = Set.unmodifiable({for (final FluentRelationLink l in _links) l.name});
  }

  /// Adds reference columns of [_links] (`one`) and [_incomingLinks] (owned children) to [finalMap].
  ///
  /// A simple key gets a column-level `REFERENCES`; a composite key gets one column per key part plus a
  /// table-level `FOREIGN KEY (...)` constraint (collected in [_relationConstraints]) and an index.
  void _addRelationColumns(Map<String, FluentDbColumn> finalMap) {
    final List<String> constraints = [];
    final List<FluentIndex> indexes = [];
    // The 1.x name of a library column (renamed by the schema sync), unless the model has a column of that name.
    final Map<String, String> legacyColumns = _legacyNames[this]?.columns ?? const {};
    String? legacy(String column) => switch (legacyColumns[column]) {
      final String old when !finalMap.containsKey(old) => old,
      _ => null,
    };

    void addReference(List<String> columns, FluentProvider referenced, List<String> referencedColumns, FluentOnDelete onDelete) {
      final List<FluentDbColumn> referencedKeys = referenced.modelSample.primaryKeys;
      FluentDbDataType typeOf(String key) {
        final FluentDbColumn c = referencedKeys.firstWhere((k) => k.name == key, orElse: () => referencedKeys.first);
        return c.type == FluentDbDataType.custom ? FluentDbDataType.text : c.type;
      }

      if (columns.length == 1) {
        final String column = columns.first;
        final String fkSql = 'REFERENCES ${referenced.tableName.quotedIdentifier}(${referencedColumns.first.quotedIdentifier}) ON DELETE ${onDelete.sql}';
        final FluentDbColumn? existing = finalMap[column];
        if (existing == null) {
          finalMap[column] = FluentDbColumn(name: column, type: typeOf(referencedColumns.first), customSql: fkSql, indexed: _indexReferences, oldName: legacy(column));
          return;
        }
        if (existing.isPrimaryKey) {
          // A key column (one-to-one on the shared key) keeps its definition; the reference goes into a table-level
          // FOREIGN KEY, so SQLite still runs the declared delete rule.
          final String clause = 'FOREIGN KEY (${column.quotedIdentifier}) $fkSql';
          if (!constraints.contains(clause)) constraints.add(clause);
          return;
        }
        final String? userSql = existing.customSql?.trim();
        if (userSql != null && userSql.toUpperCase().contains('REFERENCES')) {
          // The app's own REFERENCES wins; SQLite follows its delete rule, not the declared one.
          final String own = RegExp(r'ON\s+DELETE\s+(SET\s+NULL|SET\s+DEFAULT|CASCADE|RESTRICT|NO\s+ACTION)', caseSensitive: false).firstMatch(userSql)?.group(1)?.toUpperCase().replaceAll(RegExp(r'\s+'), ' ') ?? 'NO ACTION';
          if (own != onDelete.sql.toUpperCase()) {
            FluentLog.issue(
              FluentIssueKind.relationDeclaration,
              'Column "$tableName.$column" has its own REFERENCES with ON DELETE $own; the relation declares ON DELETE ${onDelete.sql}, which SQLite does not apply.',
              table: tableName,
              database: dbName,
              subject: column,
              tag: '$tableName:relations',
              hint: 'Remove REFERENCES from the customSql of "$column" (the relation writes it), or declare the same rule: onDelete matching ON DELETE $own.',
            );
          }
          return;
        }
        finalMap[column] = existing.copyWith(customSql: userSql == null || userSql.isEmpty ? fkSql : '$userSql $fkSql', indexed: existing.indexed || _indexReferences);
        return;
      }

      for (int i = 0; i < columns.length; i++) {
        finalMap.putIfAbsent(columns[i], () => FluentDbColumn(name: columns[i], type: typeOf(referencedColumns[i]), oldName: legacy(columns[i])));
      }
      final String clause =
          'FOREIGN KEY (${columns.map((c) => c.quotedIdentifier).join(', ')}) '
          'REFERENCES ${referenced.tableName.quotedIdentifier}(${referencedColumns.map((c) => c.quotedIdentifier).join(', ')}) ON DELETE ${onDelete.sql}';
      if (!constraints.contains(clause)) constraints.add(clause);
      final String indexName = 'idx_${tableName}_${columns.join('_')}';
      if (_indexReferences && !indexes.any((x) => x.nameFor(tableName) == indexName)) indexes.add(FluentIndex(columns, name: indexName));
    }

    for (final FluentRelationLink link in _links) {
      if (link.isReference) addReference(link.foreignKeys, link.target, link.referencedColumns, link.onDelete);
      if (link.type == FluentRelationType.oneOf) {
        // No REFERENCES: the row may point to any of the tables (the library keeps the references valid).
        final Map<String, Set<FluentDbDataType>> typesOf = {};
        for (final MapEntry<String, FluentProvider> t in link.targets.entries) {
          final List<FluentDbColumn> keys = t.value.modelSample.primaryKeys;
          final List<String> columns = link.columnsFor(t.key);
          for (int i = 0; i < columns.length; i++) {
            (typesOf[columns[i]] ??= {}).add(keys[i].type == FluentDbDataType.custom ? FluentDbDataType.text : keys[i].type);
          }
        }
        finalMap.putIfAbsent(link.typeColumn!, () => FluentDbColumn.text(link.typeColumn!).copyWith(oldName: legacy(link.typeColumn!)));
        for (final MapEntry<String, Set<FluentDbDataType>> c in typesOf.entries) {
          // Mixed key types: no declared type, so every key keeps its own type.
          finalMap.putIfAbsent(c.key, () => c.value.length == 1 ? FluentDbColumn(name: c.key, type: c.value.single, oldName: legacy(c.key)) : FluentDbColumn(name: c.key, type: FluentDbDataType.custom, customSql: '', oldName: legacy(c.key)));
        }
        for (final List<String> columns in {for (final List<String> c in link.targetColumns.values) c.join('\u0001'): c}.values) {
          final String indexName = 'idx_${tableName}_${link.typeColumn}_${columns.join('_')}';
          if (_indexReferences && !indexes.any((x) => x.nameFor(tableName) == indexName)) indexes.add(FluentIndex([link.typeColumn!, ...columns], name: indexName));
        }
      }
    }
    for (final FluentRelationLink link in _incomingLinks) {
      if (!link.isPolymorphic) addReference(link.foreignKeys, link.owner, link.referencedColumns, link.onDelete);
    }
    _relationConstraints = constraints;
    _relationIndexes = indexes;
  }

  /// Creates the link tables of many-to-many relations declared by this provider, and brings an existing one to the
  /// current shape (key type or columns changed) without losing its links.
  Future<void> syncLinkTables(DatabaseExecutor executor, {List<FluentSchemaChange>? changes}) async {
    for (final FluentRelationLink link in _links) {
      if (!link.isManyToMany || link.isThrough) continue;
      final String table = link.linkTable!;
      final Map<String, String> wanted = _linkColumns(link);
      final Map<String, String> existing = {
        for (final Map<String, Object?> r in await executor.rawQuery('PRAGMA table_info(${table.quotedIdentifier})'))
          r['name']! as String: ((r['type'] as String?) ?? '').toUpperCase(),
      };
      if (existing.isNotEmpty && !mapEquals(existing, wanted)) {
        await _rebuildLinkTable(executor, link, existing.keys.where(wanted.containsKey).toList());
        changes?.add(FluentSchemaChange(kind: FluentSchemaChangeKind.linkTable, table: table, subject: link.name, description: 'rebuilt link table of "$tableName.${link.name}" for its new shape'));
      } else {
        await _executeLogged(executor, _linkTableSql(link, table));
        if (existing.isEmpty) {
          changes?.add(FluentSchemaChange(kind: FluentSchemaChangeKind.linkTable, table: table, subject: link.name, description: 'created link table of "$tableName.${link.name}"'));
        }
      }
      await _executeLogged(executor, _linkIndexSql(link));
    }
  }

  Future<void> _executeLogged(DatabaseExecutor executor, String sql) async {
    FluentLog.sql(sql, tag: '$tableName:relations');
    await executor.execute(sql);
  }

  /// Copies the links into the new shape of the link table. When the new shape cannot take every old link (no column
  /// in common, a new key column without values, rows the new types reject) the old table is kept aside under a free
  /// `__fluent_old_<table>` name (never dropped) and a `relationChanged` issue says how to bring the links back.
  Future<void> _rebuildLinkTable(DatabaseExecutor executor, FluentRelationLink link, List<String> common) async {
    final String table = link.linkTable!;
    final bool covers = common.isNotEmpty && _linkColumns(link).keys.every(common.contains);
    final String temp = '__fluent_tmp_$table';
    await executor.execute('DROP TABLE IF EXISTS ${temp.quotedIdentifier}');
    await _executeLogged(executor, _linkTableSql(link, temp));
    int lost = 0;
    if (covers) {
      final String columns = common.map((c) => c.quotedIdentifier).join(', ');
      final int before = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM ${table.quotedIdentifier}')) ?? 0;
      // Duplicates of the new key collapse; rows the new types reject stay in the old table (kept aside below).
      await executor.execute('INSERT OR IGNORE INTO ${temp.quotedIdentifier} ($columns) SELECT $columns FROM ${table.quotedIdentifier}');
      final int distinct = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM (SELECT DISTINCT $columns FROM ${table.quotedIdentifier})')) ?? 0;
      final int copied = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM ${temp.quotedIdentifier}')) ?? 0;
      lost = distinct - copied;
      if (lost <= 0) {
        await executor.execute('DROP TABLE ${table.quotedIdentifier}');
        await executor.execute('ALTER TABLE ${temp.quotedIdentifier} RENAME TO ${table.quotedIdentifier}');
        FluentLog.info('Link table "$table" of "$tableName.${link.name}" rebuilt for its new shape', tag: '$tableName:relations', context: {'links': before, 'kept': copied});
        return;
      }
    }
    // Keep every old link: the old table moves aside (a free name, earlier asides stay), the new one takes its place.
    String aside = '__fluent_old_$table';
    for (int n = 2; Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM sqlite_master WHERE name = ?', [aside]))! > 0; n++) {
      aside = '__fluent_old_${table}_$n';
    }
    await executor.execute('ALTER TABLE ${table.quotedIdentifier} RENAME TO ${aside.quotedIdentifier}');
    await executor.execute('ALTER TABLE ${temp.quotedIdentifier} RENAME TO ${table.quotedIdentifier}');
    FluentLog.issue(
      FluentIssueKind.relationChanged,
      covers
          ? 'The link table "$table" of "$tableName.${link.name}" was rebuilt for its new shape; $lost links did not fit it '
                'and all old links were kept in "$aside".'
          : 'The link table "$table" of "$tableName.${link.name}" has key columns the old links have no values for; '
                'the old links were kept in "$aside".',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Copy them into "$table" with a migration step if they are still valid, then drop "$aside".',
      code: "FluentDbMigration(id: 'links_$table', rawSql: ['INSERT OR IGNORE INTO $table (...) SELECT ... FROM $aside', 'DROP TABLE $aside']),",
    );
  }

  /// Column name → declared type of the link table of [link].
  Map<String, String> _linkColumns(FluentRelationLink link) {
    String typeOf(FluentDbColumn key) => key.type == FluentDbDataType.custom ? 'TEXT' : key.type.sql;
    final List<FluentDbColumn> ownerKeys = modelSample.primaryKeys;
    final List<FluentDbColumn> targetKeys = link.target.modelSample.primaryKeys;
    return {
      for (int i = 0; i < link.linkOwnerColumns.length; i++) link.linkOwnerColumns[i]: typeOf(ownerKeys[i]),
      for (int i = 0; i < link.linkTargetColumns.length; i++) link.linkTargetColumns[i]: typeOf(targetKeys[i]),
    };
  }

  /// `CREATE TABLE IF NOT EXISTS` of the link table of [link], named [name].
  String _linkTableSql(FluentRelationLink link, String name) {
    // SQLite wants every column definition before the table constraints.
    final List<String> parts = [];
    final List<String> constraints = [];
    void side(List<String> columns, FluentProvider referenced) {
      final List<FluentDbColumn> keys = referenced.modelSample.primaryKeys;
      for (int i = 0; i < columns.length; i++) {
        final FluentDbColumn key = keys[i];
        parts.add('${columns[i].quotedIdentifier} ${key.type == FluentDbDataType.custom ? 'TEXT' : key.type.sql} NOT NULL');
      }
      constraints.add(
        'FOREIGN KEY (${columns.map((c) => c.quotedIdentifier).join(', ')}) REFERENCES ${referenced.tableName.quotedIdentifier}'
        '(${keys.map((k) => k.name.quotedIdentifier).join(', ')}) ON DELETE CASCADE',
      );
    }

    side(link.linkOwnerColumns, this);
    side(link.linkTargetColumns, link.target);
    parts
      ..add('PRIMARY KEY (${[...link.linkOwnerColumns, ...link.linkTargetColumns].map((c) => c.quotedIdentifier).join(', ')})')
      ..addAll(constraints);
    return 'CREATE TABLE IF NOT EXISTS ${name.quotedIdentifier} (\n  ${parts.join(',\n  ')}\n);';
  }

  String _linkIndexSql(FluentRelationLink link) {
    final String table = link.linkTable!.quotedIdentifier;
    final String targetIndex = 'idx_${link.linkTable}_${link.linkTargetColumns.join('_')}'.quotedIdentifier;
    return _indexReferences
        ? 'CREATE INDEX IF NOT EXISTS $targetIndex ON $table (${link.linkTargetColumns.map((c) => c.quotedIdentifier).join(', ')});'
        : 'DROP INDEX IF EXISTS $targetIndex;';
  }

  /// The statements that create the link tables of this provider and their indexes (part of the schema fingerprint).
  List<String> _linkTableStatements() => [
    for (final FluentRelationLink link in _links)
      if (link.isManyToMany && !link.isThrough) ...[_linkTableSql(link, link.linkTable!), _linkIndexSql(link)],
  ];

  /// After rows of this table were hard-deleted: fixes dangling references in related tables when
  /// SQLite does not enforce foreign keys (with enforcement the database does it by itself).
  Future<void> _cleanupAfterDelete(DatabaseExecutor executor) async {
    if (_foreignKeysEnforced || _relationPeers.isEmpty) return;
    // Only references to this table can have become dangling: the peers check those links, not all of theirs.
    for (final FluentProvider peer in _relationPeers) {
      await peer.cleanupOrphans(executor, pointingTo: this);
    }
  }

  /// Removes references that point to rows which no longer exist (a safety net for databases
  /// with foreign keys disabled, or rows written before the constraints existed).
  ///
  /// Only truly dangling references are touched: owned children of a missing owner are deleted
  /// (or their reference cleared for `setNull`), references to a missing model are cleared, and
  /// link rows to missing rows are removed. Rows that are simply not referenced are never deleted.
  /// References to rows the schema sync moved to a quarantine table (`__fluent_rejected_<table>_r<n>`) are kept and
  /// reported (`danglingReferences`): they are valid again once those rows are moved back.
  ///
  /// With [pointingTo] only the links to that table are checked (after rows of it were deleted).
  Future<void> cleanupOrphans(DatabaseExecutor executor, {FluentProvider? pointingTo}) async {
    bool concerns(FluentProvider other) => pointingTo == null || identical(other, pointingTo);
    final String me = tableName.quotedIdentifier;

    Future<void> run(String sql) async {
      FluentLog.sql(sql, tag: '$tableName:cleanupOrphans');
      final int count = await executor.rawUpdate(sql);
      if (count > 0) {
        FluentLog.debug('Dangling references fixed', tag: '$tableName:cleanupOrphans', context: {'rows': count, 'sql': sql});
      }
    }

    String matches(String alias, List<String> keys, String table, List<String> columns) =>
        [for (int i = 0; i < columns.length; i++) '$alias.${keys[i].quotedIdentifier} = $table.${columns[i].quotedIdentifier}'].join(' AND ');

    // Quarantine tables of the database (rows a new CHECK / UNIQUE rejected at a start), read once per call.
    List<String>? rejectedTables;
    final Map<String, Set<String>> rejectedColumns = {};
    // The quarantine tables of [referenced] that hold every column of [keys].
    Future<List<String>> quarantinesOf(FluentProvider referenced, List<String> keys) async {
      rejectedTables ??= [
        for (final Map<String, Object?> r in await executor.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND substr(name, 1, 18) = '__fluent_rejected_'"))
          r['name']! as String,
      ];
      final RegExp own = RegExp('^${RegExp.escape('__fluent_rejected_${referenced.tableName}_r')}\\d+(?:_\\d+)?\$');
      final List<String> result = [];
      for (final String q in rejectedTables!.where(own.hasMatch)) {
        final Set<String> columns = rejectedColumns[q] ??= {
          for (final Map<String, Object?> r in await executor.rawQuery('PRAGMA table_info(${q.quotedIdentifier})')) r['name']! as String,
        };
        if (keys.every(columns.contains)) result.add(q);
      }
      return result;
    }

    // Rows of this table whose [columns] point to a [referenced] row that is gone; rows pointing to a quarantined row
    // are left out and reported.
    Future<String> missing(List<String> columns, FluentProvider referenced, List<String> keys, {String? only}) async {
      final String gone = '${only == null ? '' : '$only AND '}${columns.first.quotedIdentifier} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ${referenced.tableName.quotedIdentifier} r WHERE ${matches('r', keys, me, columns)})';
      final List<String> quarantines = await quarantinesOf(referenced, keys);
      if (quarantines.isEmpty) return gone;
      final String inQuarantine = quarantines.map((q) => 'EXISTS (SELECT 1 FROM ${q.quotedIdentifier} q WHERE ${matches('q', keys, me, columns)})').join(' OR ');
      final int kept = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM $me WHERE $gone AND ($inQuarantine)')) ?? 0;
      if (kept > 0) {
        FluentLog.issue(
          FluentIssueKind.danglingReferences,
          '$kept row(s) of "$tableName" reference "${referenced.tableName}" rows that a schema change moved to ${quarantines.map((q) => '"$q"').join(', ')}; they were kept (nothing deleted or cleared).',
          table: tableName,
          database: dbName,
          subject: referenced.tableName,
          tag: '$tableName:cleanupOrphans',
          hint: 'Move the quarantined rows back into "${referenced.tableName}" (fix them and copy them with a migration step: see the rowsQuarantined warning); '
              'the references are valid again. When you drop the quarantine table instead, the next clean-up removes these rows or clears their references.',
        );
      }
      return '$gone AND NOT ($inQuarantine)';
    }

    String clear(List<String> columns) => columns.map((c) => '${c.quotedIdentifier} = NULL').join(', ');

    // RESTRICT means "never remove or change this row because of the reference": dangling rows of such a link are left
    // alone and reported (they exist because foreign keys were off or the data came from outside).
    Future<bool> restricted(FluentRelationLink link, String where) async {
      if (link.onDelete != FluentOnDelete.restrict) return false;
      final int count = Sqflite.firstIntValue(await executor.rawQuery('SELECT COUNT(*) FROM $me WHERE $where')) ?? 0;
      if (count > 0) {
        FluentLog.issue(
          FluentIssueKind.danglingReferences,
          '$count row(s) of "$tableName" reference ${link.isReference ? link.target.tableName : link.owner.tableName} rows that do not exist ("${link.name}" is RESTRICT, so they were left alone).',
          table: tableName,
          database: dbName,
          subject: link.name,
          tag: '$tableName:cleanupOrphans',
          hint: 'Fix the rows yourself, or change the rule: FluentRelation(... onDelete: FluentOnDelete.setNull) clears the reference, '
              'FluentOnDelete.cascade deletes the rows.',
        );
      }
      return true;
    }

    try {
      // Owned children stored in this table whose owner is gone.
      for (final FluentRelationLink link in _incomingLinks) {
        if (link.isPolymorphic || !concerns(link.owner)) continue; // polymorphic: with the oneOf reference below
        final String where = await missing(link.foreignKeys, link.owner, link.referencedColumns);
        if (await restricted(link, where)) continue;
        await run(link.onDelete == FluentOnDelete.cascade ? 'DELETE FROM $me WHERE $where' : 'UPDATE $me SET ${clear(link.foreignKeys)} WHERE $where');
      }
      for (final FluentRelationLink link in _links) {
        if (link.type == FluentRelationType.oneOf) {
          // Polymorphic references to a model that is gone (cleared, or deleted when that side owns the rows).
          for (final MapEntry<String, FluentProvider> t in link.targets.entries) {
            if (!concerns(t.value)) continue;
            final bool owned = t.value._links.any((l) => l.isPolymorphic && identical(l.target, this) && l.typeColumn == link.typeColumn && l.onDelete == FluentOnDelete.cascade);
            final String where = await missing(link.columnsFor(t.key), t.value, t.value.keyColumnNames.toList(), only: '${link.typeColumn!.quotedIdentifier} = ${fluentSqlLiteral(t.key)}');
            if (!owned && await restricted(link, where)) continue;
            await run(owned || link.onDelete == FluentOnDelete.cascade ? 'DELETE FROM $me WHERE $where' : 'UPDATE $me SET ${clear([link.typeColumn!, ...link.foreignKeys])} WHERE $where');
          }
        } else if (link.isReference) {
          if (!concerns(link.target)) continue;
          // References from this table to a model that is gone.
          final String where = await missing(link.foreignKeys, link.target, link.referencedColumns);
          if (await restricted(link, where)) continue;
          await run(link.onDelete == FluentOnDelete.cascade ? 'DELETE FROM $me WHERE $where' : 'UPDATE $me SET ${clear(link.foreignKeys)} WHERE $where');
        } else if (link.isManyToMany && !link.isThrough) {
          if (pointingTo != null && !identical(pointingTo, this) && !identical(link.target, pointingTo)) continue;
          // (Rows of a link model are cleaned by that model's own relations.)
          final String table = link.linkTable!.quotedIdentifier;
          // Link rows to a quarantined owner or target stay (see above).
          String keptIn(List<String> quarantines, List<String> keys, List<String> columns) =>
              quarantines.isEmpty ? '' : ' AND NOT (${quarantines.map((q) => 'EXISTS (SELECT 1 FROM ${q.quotedIdentifier} q WHERE ${matches('q', keys, table, columns)})').join(' OR ')})';
          final List<String> ownerKeys = keyColumnNames.toList();
          final List<String> targetKeys = link.target.keyColumnNames.toList();
          final String ownerGone = 'NOT EXISTS (SELECT 1 FROM $me o WHERE ${matches('o', ownerKeys, table, link.linkOwnerColumns)})${keptIn(await quarantinesOf(this, ownerKeys), ownerKeys, link.linkOwnerColumns)}';
          final String targetGone =
              'NOT EXISTS (SELECT 1 FROM ${link.target.tableName.quotedIdentifier} t WHERE ${matches('t', targetKeys, table, link.linkTargetColumns)})${keptIn(await quarantinesOf(link.target, targetKeys), targetKeys, link.linkTargetColumns)}';
          await run('DELETE FROM $table WHERE ($ownerGone) OR ($targetGone)');
        }
      }
    } on DatabaseException catch (e, st) {
      // Logged by the maintenance that runs it.
      throw FluentSchemaException(
        'Cleaning dangling relation references of "$tableName" failed',
        modelName: modelType.toString(),
        hint: 'The data itself is unchanged. Check that the relation columns exist (restart applies pending schema changes).',
        cause: e,
        stackTrace: st,
      );
    }
  }
}
