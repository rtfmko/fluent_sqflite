// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// State of one save call across the whole model graph.
class FluentRelationSaveContext {
  /// Creates a context. [keepMissingOverride] forces list replacement (`false`) or merging (`true`)
  /// for every relation; `null` uses each relation's own `keepMissing`.
  FluentRelationSaveContext({this.keepMissingOverride});

  /// See the constructor.
  final bool? keepMissingOverride;

  /// Saved instances → their primary key value (each instance is written once per call).
  final Map<FluentStorable, Object?> savedIds = Map.identity();

  /// Instances currently being saved (cycle guard).
  final Set<FluentStorable> inProgress = Set.identity();

  /// What happened to each saved model's row.
  final Map<FluentStorable, FluentRowOutcome> outcomes = Map.identity();

  /// `buildJson` of each model whose relations were found in it (built once per save, not once per relation).
  final Map<FluentStorable, Map<String, dynamic>> json = Map.identity();
}

/// Saving models together with their relations, in an order that always satisfies the
/// foreign keys: referenced models → the models themselves → owned children → many-to-many links.
extension _FluentRelationWriter<T extends FluentStorable> on FluentProvider<T> {
  /// Saves [items] and everything reachable through their relations inside [txn].
  ///
  /// Returns the primary key value of every item (new auto-increment ids included).
  /// * `one`: the referenced model is saved first and its id is written to the reference column;
  ///   `null` leaves the stored reference unchanged.
  /// * owned children (`many` / `oneOwned`): saved with the owner id; children missing from the list are
  ///   deleted unless `keepMissing`. `null` leaves the stored children unchanged.
  /// * `manyToMany`: related models are saved, then the links are replaced (or merged with `keepMissing`).
  ///
  /// [strategy] and [conflictOn] apply to [items] only (the caller's models); related models are always saved with
  /// `upsert`, so new children / references are never skipped by `updateOnly` / `patch` / `insertOnly` of the root.
  /// The same instance repeated in [items] is written once and every occurrence gets its key.
  Future<List<Object?>> _saveGraph(Transaction txn, List<T> items, FluentTask task, FluentRelationSaveContext ctx, {FluentSaveStrategy? strategy, List<String>? conflictOn}) async {
    final FluentSaveStrategy saveStrategy = strategy ?? FluentSaveStrategy.upsert;
    final List<Object?> ids = List<Object?>.filled(items.length, null);
    final List<int> todo = [];
    // Repeated instances of this call -> the index of their first occurrence (written once, see above).
    final Map<FluentStorable, int> firstIndex = Map.identity();
    final Map<int, int> repeats = {};

    for (int i = 0; i < items.length; i++) {
      final T item = items[i];
      if (ctx.savedIds.containsKey(item)) {
        ids[i] = ctx.savedIds[item];
      } else if (firstIndex.containsKey(item)) {
        repeats[i] = firstIndex[item]!;
      } else if (ctx.inProgress.contains(item)) {
        // Cycle (e.g. a person who is their own manager): use the key we already have.
        ids[i] = idFromRow(_prepareSqlJson(item));
      } else {
        ctx.inProgress.add(item);
        firstIndex[item] = i;
        todo.add(i);
      }
    }
    if (todo.isEmpty) return ids;

    try {
      // 1. Referenced models first: their ids go into this table's reference columns.
      final Map<String, Map<FluentStorable, Object?>> referenceIds = {};
      for (final FluentRelationLink link in _links) {
        if (!link.isReference) continue;
        final List<FluentStorable> targets = [];
        final Set<FluentStorable> seen = Set.identity();
        for (final int i in todo) {
          final Object? value = _selectRelation(link, items[i], ctx);
          if (value != null && value is! FluentStorable) _notAModel(link, value);
          if (value is FluentStorable && _relatedOfTargetType(this, link, [value]).isNotEmpty && seen.add(value)) targets.add(value);
        }
        if (targets.isEmpty) continue;
        final List<Object?> targetIds = await link.target._saveGraph(txn, link.target._createTypedList(targets), task, ctx);
        referenceIds[link.name] = Map.identity()..addEntries([for (int k = 0; k < targets.length; k++) MapEntry(targets[k], targetIds[k])]);
      }
      // Polymorphic references: each referenced model is saved by the provider of its type.
      final Map<String, Map<FluentStorable, (String, Object?)>> oneOfRefs = {};
      for (final FluentRelationLink link in _links) {
        if (link.type != FluentRelationType.oneOf) continue;
        final Map<FluentProvider, List<FluentStorable>> byProvider = Map.identity();
        final Set<FluentStorable> seen = Set.identity();
        for (final int i in todo) {
          final Object? value = _selectRelation(link, items[i], ctx);
          if (value != null && value is! FluentStorable) _notAModel(link, value);
          if (value is! FluentStorable || !seen.add(value)) continue;
          final FluentProvider? p = link.targets.values.where((p) => p._stores(value, list: false)).firstOrNull;
          if (p == null) {
            FluentLog.issue(
              FluentIssueKind.relationValue,
              '"$tableName.${link.name}" holds a ${value.runtimeType}, which is not one of its types (${link.targets.values.map((p) => p.modelType).join(', ')}); the reference is not saved.',
              table: tableName,
              database: dbName,
              subject: link.name,
              tag: '$tableName:relations',
              hint: 'Add ${value.runtimeType} to the types of "${link.name}".',
            );
            continue;
          }
          (byProvider[p] ??= []).add(value);
        }
        final Map<FluentStorable, (String, Object?)> refs = Map.identity();
        for (final MapEntry<FluentProvider, List<FluentStorable>> e in byProvider.entries) {
          final List<Object?> targetIds = await e.key._saveGraph(txn, e.key._createTypedList(e.value), task, ctx);
          for (int k = 0; k < e.value.length; k++) {
            refs[e.value[k]] = (e.key.tableName, targetIds[k]);
          }
        }
        oneOfRefs[link.name] = refs;
      }

      // 2. The rows themselves.
      final List<Map<String, dynamic>> rows = [];
      for (final int i in todo) {
        final Map<String, dynamic> row = _prepareSqlJson(items[i]);
        for (final FluentRelationLink link in _links) {
          if (!link.isReference) continue;
          final Object? value = _selectRelation(link, items[i], ctx);
          if (value is! FluentStorable) continue;
          // A target that was not written (and has no key) leaves the stored reference unchanged.
          final Object? targetId = referenceIds[link.name]?[value];
          if (targetId != null) row.addAll(link.referenceValues(targetId));
        }
        for (final FluentRelationLink link in _links) {
          if (link.type != FluentRelationType.oneOf) continue;
          final (String, Object?)? ref = oneOfRefs[link.name]?[_selectRelation(link, items[i], ctx)];
          if (ref == null) continue;
          // The columns of the other types are cleared: the row points to one model only.
          row.addAll({for (final String c in link.foreignKeys) c: null, link.typeColumn!: ref.$1});
          row.addAll(_zipKey(link.columnsFor(ref.$1), link.targets[ref.$1]!.keyColumnNames.toList(), ref.$2));
        }
        rows.add(row);
      }
      // conflictOn applies to the models passed by the caller (related tables are saved without it).
      final List<_WrittenRow> written = await _writeRows(txn, rows, saveStrategy, conflictOn: conflictOn, synced: task.helper?.syncWrite ?? false);
      _injectKeys([for (final int i in todo) items[i]], written);
      for (int n = 0; n < todo.length; n++) {
        final int i = todo[n];
        // Rows that were not written (and do not exist) get no children / links.
        final Object? id = written[n].$1 == FluentRowOutcome.skipped && saveStrategy != FluentSaveStrategy.insertOnly ? null : written[n].$2;
        ids[i] = id;
        ctx.savedIds[items[i]] = id;
        ctx.outcomes[items[i]] = written[n].$1;
      }
      for (final MapEntry<int, int> r in repeats.entries) {
        ids[r.key] = ids[r.value];
      }
      final List<Object?> changed = [for (int n = 0; n < todo.length; n++) if (written[n].$1 != FluentRowOutcome.skipped) items[todo[n]]];
      if (changed.isNotEmpty) FluentEngine.touch(this, FluentDbAction.save, changed);

      for (final FluentRelationLink link in _links) {
        if (link.isOwned) {
          await _saveOwnedChildren(txn, link, items, todo, ids, task, ctx);
        } else if (link.isThrough) {
          _warnThroughWrite(link, items, todo);
        } else if (link.isManyToMany) {
          await _saveLinks(txn, link, items, todo, ids, task, ctx);
        }
      }
    } finally {
      for (final int i in todo) {
        ctx.inProgress.remove(items[i]);
      }
    }
    return ids;
  }

  /// A `through` list is read-only: new (unsaved) models in it would be lost silently, so they are reported.
  void _warnThroughWrite(FluentRelationLink link, List<T> items, List<int> todo) {
    for (final int i in todo) {
      final List<FluentStorable>? related = _selectList(link, items[i]);
      if (related == null || related.every((r) => r.primaryKeyValue != null)) continue;
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        '"${link.name}" of "$tableName" is read-only (it goes through ${link.linkModel!.modelType}); the new models in it were not saved.',
        table: tableName,
        database: dbName,
        subject: link.name,
        tag: '$tableName:relations',
        hint: 'Add links with attach and a link model, or save ${link.linkModel!.modelType} models.',
        code: "await provider.attach(model, '${link.name}', [...], link: (related) => ${link.linkModel!.modelType}(...));",
      );
      return;
    }
  }

  Object? _selectRelation(FluentRelationLink link, FluentStorable item, [FluentRelationSaveContext? ctx]) {
    if (link.found && ctx != null) return (ctx.json[item] ??= item.buildJson())[link.name];
    // Items of this provider are always the relation's parent type (a relation of another type is skipped at init).
    return link.relation.selectFrom(item);
  }

  List<FluentStorable>? _selectList(FluentRelationLink link, FluentStorable item, [FluentRelationSaveContext? ctx]) {
    final Object? value = _selectRelation(link, item, ctx);
    if (value == null) return null;
    if (value is FluentStorable) return _relatedOfTargetType(this, link, [value]);
    if (value is Iterable) {
      final List<FluentStorable> models = value.whereType<FluentStorable>().toList();
      if (models.length < value.length) _notAModel(link, value.firstWhere((Object? v) => v is! FluentStorable));
      return _relatedOfTargetType(this, link, models);
    }
    _notAModel(link, value);
    return null;
  }

  /// Reports that the select of [link] returned [value], which is not a model: it is not saved (`relationValue`).
  void _notAModel(FluentRelationLink link, Object? value) {
    final String expected = link.isList ? 'a List of ${link.target.modelType}' : (link.type == FluentRelationType.oneOf ? 'one of ${link.targets.values.map((p) => p.modelType).join(', ')}' : '${link.target.modelType}');
    FluentLog.issue(
      FluentIssueKind.relationValue,
      'Relation "${link.name}" of "$tableName" returned ${value.runtimeType}; expected $expected. It is not saved.',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'Return the related model(s) from the select function of "${link.name}" (or null).',
    );
  }

  bool _keepMissing(FluentRelationLink link, FluentRelationSaveContext ctx) => ctx.keepMissingOverride ?? link.relation.keepMissing;

  Future<void> _saveOwnedChildren(Transaction txn, FluentRelationLink link, List<T> items, List<int> todo, List<Object?> ids, FluentTask task, FluentRelationSaveContext ctx) async {
    final FluentProvider target = link.target;
    final List<FluentStorable> allChildren = [];
    final Map<int, List<FluentStorable>> childrenOf = {};

    for (final int i in todo) {
      final List<FluentStorable>? children = _selectList(link, items[i], ctx);
      if (children == null) continue; // not loaded / not provided: leave stored children alone
      final Object? ownerId = ids[i];
      if (ownerId == null) continue;
      final Map<String, Object?> reference = link.referenceValues(ownerId);
      for (final FluentStorable child in children) {
        reference.forEach(child.injectRelationId);
      }
      childrenOf[i] = children;
      allChildren.addAll(children);
    }
    if (childrenOf.isEmpty) return;

    final List<Object?> childIds = allChildren.isEmpty ? const [] : await target._saveGraph(txn, target._createTypedList(allChildren), task, ctx);
    if (_keepMissing(link, ctx)) return;

    // Children that are no longer in the owner's list are removed (owned data). The stored children are read and
    // compared in Dart, then removed by key in chunks: a `NOT IN (<every kept key>)` could exceed the variable limit.
    final Map<FluentStorable, Object?> idOf = Map.identity()..addEntries([for (int k = 0; k < allChildren.length; k++) MapEntry(allChildren[k], childIds[k])]);
    final String? childDeleted = target._softDeleteColumn;
    for (final MapEntry<int, List<FluentStorable>> entry in childrenOf.entries) {
      final Set<String> keep = {for (final FluentStorable c in entry.value) if (idOf[c] != null) _tupleKey(target._normalizeKey(idOf[c]))};
      FluentFilter owned = _equalsAll(link.referenceValues(ids[entry.key]), stored: true); // ids are stored keys
      if (childDeleted != null) owned = owned.and(FluentFilter.isNull(childDeleted.quotedIdentifier)); // trashed children are gone already
      final List<Object> stale = [for (final Object id in await target._keysWhere(txn, owned)) if (!keep.contains(_tupleKey(target._normalizeKey(id)))) id];
      if (stale.isEmpty) continue;
      final int removed = await target._removeOwnedKeys(txn, stale);
      if (removed > 0) {
        FluentLog.debug('Removed children missing from the list', tag: '$tableName:relations', context: {'relation': link.name, 'removed': removed});
      }
    }
  }

  /// Deletes owned rows matching [filter] (soft delete when the model supports it).
  Future<int> _removeOwned(Transaction txn, FluentFilter filter) =>
      _softDeleteColumn != null ? _softDeleteWhere(txn, filter, _softDeleteStamp()) : _hardDeleteWhere(txn, filter);

  /// Deletes the owned rows with the stored keys [ids] (read from rows), in chunks (soft delete with one stamp when the model supports it).
  Future<int> _removeOwnedKeys(Transaction txn, List<Object> ids) {
    if (_softDeleteColumn == null) return _forKeyChunks(ids, (keys) => _hardDeleteWhere(txn, keys), stored: true);
    final Object stamp = _softDeleteStamp();
    return _forKeyChunks(ids, (keys) => _softDeleteWhere(txn, keys, stamp), stored: true);
  }


  Future<void> _saveLinks(Transaction txn, FluentRelationLink link, List<T> items, List<int> todo, List<Object?> ids, FluentTask task, FluentRelationSaveContext ctx) async {
    final FluentProvider target = link.target;
    final List<FluentStorable> allTargets = [];
    final Map<int, List<FluentStorable>> targetsOf = {};

    for (final int i in todo) {
      final List<FluentStorable>? related = _selectList(link, items[i], ctx);
      if (related == null || ids[i] == null) continue;
      targetsOf[i] = related;
      allTargets.addAll(related);
    }
    if (targetsOf.isEmpty) return;

    final List<Object?> targetIds = allTargets.isEmpty ? const [] : await target._saveGraph(txn, target._createTypedList(allTargets), task, ctx);
    final Map<FluentStorable, Object?> idOf = Map.identity()..addEntries([for (int k = 0; k < allTargets.length; k++) MapEntry(allTargets[k], targetIds[k])]);

    for (final MapEntry<int, List<FluentStorable>> entry in targetsOf.entries) {
      final Object ownerId = ids[entry.key]!;
      final List<Object> linked = [for (final FluentStorable t in entry.value) idOf[t]].whereType<Object>().toSet().toList();
      if (!_keepMissing(link, ctx)) {
        // Stored links are read and compared in Dart, stale ones deleted in chunks (no `NOT IN` over every kept key).
        final List<String> targetKeys = target.keyColumnNames.toList();
        final FluentFilter ofOwner = _equalsAll(link.linkOwnerValues(ownerId), stored: true);
        final Set<String> keep = {for (final Object id in linked) _tupleKey(target._normalizeKey(id))};
        final List<Object> stale = [
          for (final Map<String, Object?> r in await txn.query(link.linkTable!.quotedIdentifier, columns: link.linkTargetColumns.quotedAll, where: ofOwner.whereClause, whereArgs: ofOwner.whereArgs))
            if (_rowTuple(r, link.linkTargetColumns, targetKeys) case final Object id when !keep.contains(_tupleKey(target._normalizeKey(id)))) id,
        ];
        final int step = math.max(1, (_maxParamsPerChunk - link.linkOwnerColumns.length) ~/ link.linkTargetColumns.length);
        int removed = 0;
        for (int i = 0; i < stale.length; i += step) {
          final FluentFilter where = ofOwner.and(_tupleFilter(link.linkTargetColumns, targetKeys, stale.sublist(i, math.min(i + step, stale.length)), stored: true));
          removed += await txn.delete(link.linkTable!.quotedIdentifier, where: where.whereClause, whereArgs: where.whereArgs);
        }
        if (removed > 0) FluentEngine.touch(target, FluentDbAction.update);
      }
      await _insertLinks(txn, link, ownerId, linked);
    }
  }

  Future<void> _insertLinks(DatabaseExecutor executor, FluentRelationLink link, Object ownerId, List<Object> targetIds) async {
    if (targetIds.isEmpty) return;
    final Batch batch = executor.batch();
    for (final Object targetId in targetIds) {
      batch.insert(link.linkTable!.quotedIdentifier, {...link.linkOwnerValues(ownerId), ...link.linkTargetValues(targetId)}.quotedKeys, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }
}


/// `a = ? AND b = ?` for every column → value pair. [stored]: the values are SQLite values (read from rows) and are
/// used as they are; otherwise they are Dart values that the column converts like on save.
FluentFilter _equalsAll(Map<String, Object?> values, {bool stored = false}) =>
    values.entries.map((e) => stored ? _storedEq(e.key, e.value) : FluentFilter.eq(e.key.quotedIdentifier, e.value)).reduce((a, b) => a.and(b));

/// The models of [models] that [link] relates (its target type); the others are reported (`relationValue`) and left
/// out: a list holding a model of another type would otherwise fail with a raw cast error.
List<FluentStorable> _relatedOfTargetType(FluentProvider owner, FluentRelationLink link, List<FluentStorable> models) {
  final FluentProvider target = link.target;
  final List<FluentStorable> accepted = [for (final FluentStorable m in models) if (target._stores(m, list: false)) m];
  if (accepted.length == models.length) return models;
  final FluentStorable wrong = models.firstWhere((m) => !target._stores(m, list: false));
  FluentLog.issue(
    FluentIssueKind.relationValue,
    'Relation "${link.name}" of "${owner.tableName}" holds a ${wrong.runtimeType}, but relates ${target.modelType}; ${models.length - accepted.length} such value(s) were not saved.',
    table: owner.tableName,
    database: owner.dbName,
    subject: link.name,
    tag: '${owner.tableName}:relations',
    hint: 'Put only ${target.modelType} models into "${link.name}".',
  );
  return accepted;
}
