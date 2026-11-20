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

/// What a save of one owner's list may remove (see `_listScope`).
enum _ListScope {
  /// The list is the full state (loaded, or built by the app with items): stored rows missing from it are removed.
  full,

  /// Add and update only: the list was not loaded, or was read for another owner or relation.
  merge,

  /// Nothing to write: a list the read did not load, still empty (what `fromCacheJson` defaulted it to).
  skip,

  /// An empty list the app built (no read behind the model or the list): stored rows are kept and reported
  /// (`relationListKept`), unless the save says `relationSync: FluentRelationSyncMode.replace`.
  guard,
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
  /// * Only what a list could show is removed: nothing for a relation with a `limit` or one the model was read
  ///   without (`unloadedRelations`, or the list's own load info for a model rebuilt from a read, see [_listScope]),
  ///   only rows matching its `where` and visible to it. An empty list on a model the app built removes nothing
  ///   unless `relationSync: replace`. Related models read in the trash and still there are not written (no restore
  ///   through a save of the parent).
  ///
  /// [strategy] and [conflictOn] apply to [items] only (the caller's models); related models are always saved with
  /// `upsert`, so new children / references are never skipped by `updateOnly` / `patch` / `insertOnly` of the root.
  /// A root row that is skipped (also an existing row `insertOnly` leaves alone) writes no children and no links.
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
      // The owner key each row's children / links are written with: none for a skipped row (not written, or an
      // existing row `insertOnly` left alone: its stored children and links stay as they are).
      final List<Object?> ownerIds = List<Object?>.filled(items.length, null);
      for (int n = 0; n < todo.length; n++) {
        final int i = todo[n];
        // Rows that were not written (and do not exist) have no key; an existing row skipped by insertOnly keeps it.
        final Object? id = written[n].$1 == FluentRowOutcome.skipped && saveStrategy != FluentSaveStrategy.insertOnly ? null : written[n].$2;
        ids[i] = id;
        ownerIds[i] = written[n].$1 == FluentRowOutcome.skipped ? null : id;
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
          await _saveOwnedChildren(txn, link, items, todo, ownerIds, task, ctx);
        } else if (link.isThrough) {
          _warnThroughWrite(link, items, todo);
        } else if (link.isManyToMany) {
          await _saveLinks(txn, link, items, todo, ownerIds, task, ctx);
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

  /// Saves the owned children of [link] for the rows [todo] (owner keys in [ids]; `null`: no children are written)
  /// and removes the stored children missing from each list (unless `keepMissing`).
  ///
  /// Only children the list could have shown are removed: a relation with a `limit` shows part of them (nothing is
  /// removed), its `where` limits the removal to the rows it matches, and rows in the trash or expired are never
  /// taken for missing. A relation the model was read without (`unloadedRelations`: `FluentLoad.none`, lazy, depth
  /// cut-off, failed load) removes nothing; its children (when the app put some in) are saved. The same holds for a
  /// model rebuilt from a read (the list's load info, see [_listScope]); an empty list on a model the app built
  /// removes nothing unless `relationSync: replace` (reported). Children read in the trash (`includeDeleted`) that
  /// are still there are not written, so the save does not restore them.
  Future<void> _saveOwnedChildren(Transaction txn, FluentRelationLink link, List<T> items, List<int> todo, List<Object?> ids, FluentTask task, FluentRelationSaveContext ctx) async {
    final FluentProvider target = link.target;
    final List<FluentStorable> allChildren = [];
    final Map<int, List<FluentStorable>> childrenOf = {};
    final Set<int> mergeOnly = {}; // owners whose list was not loaded (or not read for them): nothing is removed
    final Set<int> guarded = {}; // owners with an empty list the app built: nothing is removed unless `replace`

    for (final int i in todo) {
      final List<FluentStorable>? children = _selectList(link, items[i], ctx);
      if (children == null) continue; // not loaded / not provided: leave stored children alone
      final Object? ownerId = ids[i];
      if (ownerId == null) continue;
      switch (_listScope(link, items[i], children, ownerId, ctx)) {
        case _ListScope.skip:
          continue;
        case _ListScope.merge:
          mergeOnly.add(i);
        case _ListScope.guard:
          guarded.add(i);
        case _ListScope.full:
          break;
      }
      final Map<String, Object?> reference = link.referenceValues(ownerId);
      for (final FluentStorable child in children) {
        reference.forEach(child.injectRelationId);
      }
      childrenOf[i] = children;
      allChildren.addAll(children);
    }
    if (childrenOf.isEmpty) return;

    final Map<FluentStorable, Object?> idOf = await _saveRelated(txn, link, allChildren, task, ctx);
    if (_keepMissing(link, ctx) || _showsPart(link)) return;

    // Children that are no longer in the owner's list are removed (owned data). The stored children are read and
    // compared in Dart, then removed by key in chunks: a `NOT IN (<every kept key>)` could exceed the variable limit.
    // Only rows the list could show: live (trashed children are gone already), not expired, matching its `where`.
    FluentFilter shown = target._visibility(deletedOnly: false, includeDeleted: false);
    if (link.relation.where != null) shown = shown.and(target._resolveRelated(link.relation.where!));
    await target._flushValueLists(txn);
    // Rows this save inserted (also through another list over the same reference, e.g. a full list next to a view
    // of it loaded with FluentLoad.all) were in no list the model was read with: never taken for missing.
    final Set<String> insertedNow = {
      for (final MapEntry<FluentStorable, FluentRowOutcome> e in ctx.outcomes.entries)
        if (e.value == FluentRowOutcome.inserted && ctx.savedIds[e.key] != null && target._stores(e.key, list: false)) _tupleKey(target._normalizeKey(ctx.savedIds[e.key])),
    };
    // The stored children of every owner, read with one query per chunk of owners (not one per owner).
    final Map<int, Map<String, Object?>> references = {
      for (final int i in childrenOf.keys) if (!mergeOnly.contains(i)) i: link.referenceValues(ids[i]), // ids are stored keys
    };
    final Map<int, List<Object>>? storedOf = await _keysByOwner(
      txn,
      table: target.tableName,
      keyColumns: target.keyColumnNames.toList(),
      references: references,
      where: shown.whereClause,
      whereArgs: target._args(shown),
      keyOf: (columns, values) => target._valuesKey(columns, values),
      idOf: target.idFromRow,
    );
    for (final MapEntry<int, List<FluentStorable>> entry in childrenOf.entries) {
      if (mergeOnly.contains(entry.key)) continue;
      final Set<String> keep = {...insertedNow, for (final FluentStorable c in entry.value) if (idOf[c] != null) _tupleKey(target._normalizeKey(idOf[c]))};
      final List<Object> existing = storedOf?[entry.key] ?? await target._keysWhere(txn, _equalsAll(references[entry.key]!, stored: true).and(shown));
      final List<Object> stale = [for (final Object id in existing) if (!keep.contains(_tupleKey(target._normalizeKey(id)))) id];
      if (stale.isEmpty) continue;
      if (guarded.contains(entry.key)) {
        _reportKeptList(link, items[entry.key], stale.length);
        continue;
      }
      final int removed = await target._removeOwnedKeys(txn, stale);
      if (removed > 0) {
        FluentLog.debug('Removed children missing from the list', tag: '$tableName:relations', context: {'relation': link.name, 'removed': removed});
      }
    }
  }

  /// What a save of [list] (the list of [link] in [item], owner key [ownerId]) may remove.
  ///
  /// The list's own load info comes first ([_listLoads], set by the read; it stays with the list when the model is
  /// rebuilt, e.g. by `copyWith`): a list read for this relation and owner is the full state when it was loaded, an
  /// unloaded one only adds (empty: nothing to do); a list read for another relation or owner only adds. Without it,
  /// a model that was read decides by `unloadedRelations`. A model the app built (no read behind it or its list)
  /// replaces with a list that has items; an empty one is [_ListScope.guard] (unless `relationSync: replace`).
  _ListScope _listScope(FluentRelationLink link, FluentStorable item, List<FluentStorable> list, Object ownerId, FluentRelationSaveContext ctx) {
    final Object? value = _selectRelation(link, item, ctx);
    final _ListLoad? load = value is List ? _listLoads[value] : null;
    if (load != null) {
      if (!identical(load.link, link) || load.owner != _tupleKey(_normalizeKey(ownerId))) return _ListScope.merge;
      if (load.loaded) return _ListScope.full;
      return list.isEmpty ? _ListScope.skip : _ListScope.merge;
    }
    if (_readModels[item] ?? false) {
      if (!item.unloadedRelations.contains(link.name)) return _ListScope.full;
      return list.isEmpty ? _ListScope.skip : _ListScope.merge;
    }
    if (list.isNotEmpty || ctx.keepMissingOverride == false) return _ListScope.full;
    return _ListScope.guard;
  }

  /// Reports that the empty list of [link] in [item] (a model the app built) left [kept] stored rows / links alone.
  void _reportKeptList(FluentRelationLink link, FluentStorable item, int kept) {
    final String what = link.isManyToMany ? 'link(s)' : 'child row(s)';
    FluentLog.issue(
      FluentIssueKind.relationListKept,
      'Saved a ${item.runtimeType} with an empty "${link.name}" list that was not read from the database; its $kept stored $what of "$tableName.${link.name}" were kept.',
      table: tableName,
      database: dbName,
      subject: link.name,
      tag: '$tableName:relations',
      hint: 'An empty list on a model the app built (or rebuilt from a read without "${link.name}") never removes anything. '
          'To clear the relation on purpose, save with relationSync: FluentRelationSyncMode.replace, or remove the rows with '
          '${link.isManyToMany ? 'detach' : 'detach / delete'}; to leave the relation untouched, set the field to null.',
      code: 'await provider.save(model, relationSync: FluentRelationSyncMode.replace);',
    );
  }

  /// Whether a loaded list of [link] shows only some of the related rows (a `limit`): rows missing from it are not
  /// removed, the rest of the list was simply not shown.
  bool _showsPart(FluentRelationLink link) => link.relation.limit != null && link.relation.limit! >= 0;

  /// Saves [related] (models of [link]'s target) and returns the stored key of each. Models read in the trash
  /// (`deletedAt` set, e.g. through `includeDeleted`) whose rows are still there are not written (a save of a
  /// trashed key would restore it); they keep their key, so their place in the list (and their link) stays.
  Future<Map<FluentStorable, Object?>> _saveRelated(Transaction txn, FluentRelationLink link, List<FluentStorable> related, FluentTask task, FluentRelationSaveContext ctx) async {
    final FluentProvider target = link.target;
    final Map<FluentStorable, Object?> idOf = Map.identity();
    if (related.isEmpty) return idOf;
    final Map<FluentStorable, Object> trashed = await target._stillInTrash(txn, related);
    final List<FluentStorable> toSave = trashed.isEmpty ? related : [for (final FluentStorable m in related) if (!trashed.containsKey(m)) m];
    if (trashed.isNotEmpty) {
      FluentLog.debug('Related models in the trash are left there (not saved)', tag: '$tableName:relations', context: {'relation': link.name, 'models': trashed.length});
    }
    final List<Object?> savedIds = toSave.isEmpty ? const [] : await target._saveGraph(txn, target._createTypedList(toSave), task, ctx);
    for (int k = 0; k < toSave.length; k++) {
      idOf[toSave[k]] = savedIds[k];
    }
    idOf.addAll(trashed);
    return idOf;
  }

  /// The models of [models] that were read in the trash (`deletedAt` set) and whose rows are still there, with their
  /// stored keys.
  Future<Map<FluentStorable, Object>> _stillInTrash(DatabaseExecutor ex, List<FluentStorable> models) async {
    final Map<FluentStorable, Object> result = Map.identity();
    if (_softDeleteColumn == null) return result;
    final Map<FluentStorable, Object> candidates = Map.identity();
    for (final FluentStorable m in models) {
      if (m is! FluentSoftDeletable || m.deletedAt == null) continue;
      final Object? id = _storedId(m.primaryKeyValue);
      if (id != null) candidates[m] = id;
    }
    if (candidates.isEmpty) return result;
    final Set<String> trashed = await _trashedKeys(ex, candidates.values.toList());
    candidates.forEach((m, id) {
      if (trashed.contains(_keyText(id))) result[m] = id;
    });
    return result;
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


  /// Saves the related models of the many-to-many [link] for the rows [todo] (owner keys in [ids]; `null`: nothing
  /// is written) and replaces their links (merged with `keepMissing`). Like owned children (see
  /// [_saveOwnedChildren]), only links the list could have shown are removed: none for a `limit` or a relation the
  /// model was read without, only links to targets matching the relation's `where` and visible to it (links to
  /// targets in the trash or expired stay, unless the relation shows trashed rows).
  Future<void> _saveLinks(Transaction txn, FluentRelationLink link, List<T> items, List<int> todo, List<Object?> ids, FluentTask task, FluentRelationSaveContext ctx) async {
    final FluentProvider target = link.target;
    final List<FluentStorable> allTargets = [];
    final Map<int, List<FluentStorable>> targetsOf = {};
    final Set<int> mergeOnly = {}; // owners whose list was not loaded (or not read for them): no link is removed
    final Set<int> guarded = {}; // owners with an empty list the app built: no link is removed unless `replace`

    for (final int i in todo) {
      final List<FluentStorable>? related = _selectList(link, items[i], ctx);
      if (related == null || ids[i] == null) continue;
      switch (_listScope(link, items[i], related, ids[i]!, ctx)) {
        case _ListScope.skip:
          continue;
        case _ListScope.merge:
          mergeOnly.add(i);
        case _ListScope.guard:
          guarded.add(i);
        case _ListScope.full:
          break;
      }
      targetsOf[i] = related;
      allTargets.addAll(related);
    }
    if (targetsOf.isEmpty) return;

    final Map<FluentStorable, Object?> idOf = await _saveRelated(txn, link, allTargets, task, ctx);
    final bool replace = !_keepMissing(link, ctx) && !_showsPart(link);
    FluentFilter? shown;
    final List<String> targetKeys = target.keyColumnNames.toList();

    // The stored links of every owner, read with one query per chunk of owners (not one per owner); null when an owner
    // is saved twice in this call (then each one reads and writes in turn, as the later one must see the earlier).
    final Map<int, List<Object>>? storedLinks = !replace
        ? null
        : await _keysByOwner(
            txn,
            table: link.linkTable!,
            keyColumns: link.linkTargetColumns,
            references: {for (final int i in targetsOf.keys) if (!mergeOnly.contains(i)) i: link.linkOwnerValues(ids[i])},
            keyOf: (columns, values) => values.map((v) => '$v').join('\u0001'),
            idOf: (row) => _rowTuple(row, link.linkTargetColumns, targetKeys),
          );
    final bool oneBatch = !replace || storedLinks != null;
    final List<(Object, List<Object>)> inserts = [];

    for (final MapEntry<int, List<FluentStorable>> entry in targetsOf.entries) {
      final Object ownerId = ids[entry.key]!;
      final List<Object> linked = [for (final FluentStorable t in entry.value) idOf[t]].whereType<Object>().toSet().toList();
      if (replace && !mergeOnly.contains(entry.key)) {
        // Stored links are read and compared in Dart, stale ones deleted in chunks (no `NOT IN` over every kept key).
        final FluentFilter ofOwner = _equalsAll(link.linkOwnerValues(ownerId), stored: true);
        final Set<String> keep = {for (final Object id in linked) _tupleKey(target._normalizeKey(id))};
        final List<Object> existing = storedLinks?[entry.key] ??
            [
              for (final Map<String, Object?> r in await txn.query(link.linkTable!.quotedIdentifier, columns: link.linkTargetColumns.quotedAll, where: ofOwner.whereClause, whereArgs: ofOwner.whereArgs))
                ?_rowTuple(r, link.linkTargetColumns, targetKeys),
            ];
        List<Object> stale = [for (final Object id in existing) if (!keep.contains(_tupleKey(target._normalizeKey(id)))) id];
        if (stale.isNotEmpty) {
          // Only links to targets the list could show (visible to the relation, matching its `where`).
          final FluentFilter visibleTargets = shown ??= link.relation.where == null ? target._relationVisibility(link) : target._relationVisibility(link).and(target._resolveRelated(link.relation.where!));
          await target._flushValueLists(txn);
          final Set<String> visible = {};
          final int perChunk = target.keysPerChunk(math.max(1, _maxParamsPerChunk - visibleTargets.whereArgs.length));
          for (int i = 0; i < stale.length; i += perChunk) {
            final FluentFilter where = target._keysFilterOf(stale.sublist(i, math.min(i + perChunk, stale.length)), stored: true).and(visibleTargets);
            for (final Object id in await target._keysWhere(txn, where)) {
              visible.add(_tupleKey(target._normalizeKey(id)));
            }
          }
          stale = [for (final Object id in stale) if (visible.contains(_tupleKey(target._normalizeKey(id)))) id];
        }
        if (stale.isNotEmpty && guarded.contains(entry.key)) {
          _reportKeptList(link, items[entry.key], stale.length);
          stale = const [];
        }
        final int step = math.max(1, (_maxParamsPerChunk - link.linkOwnerColumns.length) ~/ link.linkTargetColumns.length);
        int removed = 0;
        for (int i = 0; i < stale.length; i += step) {
          final FluentFilter where = ofOwner.and(_tupleFilter(link.linkTargetColumns, targetKeys, stale.sublist(i, math.min(i + step, stale.length)), stored: true));
          removed += await txn.delete(link.linkTable!.quotedIdentifier, where: where.whereClause, whereArgs: where.whereArgs);
        }
        if (removed > 0) FluentEngine.touch(target, FluentDbAction.update);
      }
      if (oneBatch) {
        inserts.add((ownerId, linked));
      } else {
        await _insertLinks(txn, link, ownerId, linked);
      }
    }
    // Every owner's links in one batch (they never conflict across owners).
    if (inserts.isNotEmpty) {
      final Batch batch = txn.batch();
      for (final (Object ownerId, List<Object> targetIds) in inserts) {
        for (final Object targetId in targetIds) {
          batch.insert(link.linkTable!.quotedIdentifier, {...link.linkOwnerValues(ownerId), ...link.linkTargetValues(targetId)}.quotedKeys, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      await batch.commit(noResult: true);
    }
  }

  /// For each owner of [references] (owner index → the stored values of the columns of [table] that point at it), the
  /// keys ([keyColumns], read by [idOf]) of the rows of [table] pointing at it and matching [where]: one query per chunk
  /// of owners instead of one per owner. [keyOf] makes the lookup key of reference values (rows and owners alike).
  /// `null` when two owners have the same values (an owner saved twice: the caller reads each one in turn).
  Future<Map<int, List<Object>>?> _keysByOwner(
    DatabaseExecutor txn, {
    required String table,
    required List<String> keyColumns,
    required Map<int, Map<String, Object?>> references,
    String where = '',
    List<Object?>? whereArgs,
    required String Function(List<String> columns, List<Object?> values) keyOf,
    required Object? Function(Map<String, Object?> row) idOf,
  }) async {
    if (references.isEmpty) return const {};
    final List<String> columns = references.values.first.keys.toList();
    final Map<String, int> ownerOf = {};
    for (final MapEntry<int, Map<String, Object?>> e in references.entries) {
      final List<Object?> values = [for (final String c in columns) e.value[c]];
      if (values.contains(null) || ownerOf.putIfAbsent(keyOf(columns, values), () => e.key) != e.key) return null;
    }
    final Map<int, List<Object>> found = {for (final int i in references.keys) i: <Object>[]};
    final List<MapEntry<int, Map<String, Object?>>> owners = references.entries.toList();
    final int extra = whereArgs?.length ?? 0;
    final int step = math.max(1, (_maxParamsPerChunk - extra) ~/ columns.length);
    final List<String> selected = {...keyColumns, ...columns}.toList();
    for (int from = 0; from < owners.length; from += step) {
      final List<MapEntry<int, Map<String, Object?>>> chunk = owners.sublist(from, math.min(from + step, owners.length));
      final String match = columns.length == 1
          ? '${columns.single.quotedIdentifier} IN (${List.filled(chunk.length, '?').join(', ')})'
          : chunk.map((_) => '(${columns.map((c) => '${c.quotedIdentifier} = ?').join(' AND ')})').join(' OR ');
      final List<Object?> args = [for (final MapEntry<int, Map<String, Object?>> e in chunk) for (final String c in columns) e.value[c], ...?whereArgs];
      final List<Map<String, Object?>> rows = await txn.query(table.quotedIdentifier, columns: selected.quotedAll, where: where.isEmpty ? match : '($match) AND ($where)', whereArgs: args);
      for (final Map<String, Object?> row in rows) {
        final int? owner = ownerOf[keyOf(columns, [for (final String c in columns) row[c]])];
        final Object? id = idOf(row);
        if (owner != null && id != null) found[owner]!.add(id);
      }
    }
    return found;
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
