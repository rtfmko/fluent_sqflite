// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// On-demand operations on the relations of a model with [FluentRelations]: loading, querying, counting, attaching
/// and detaching.
extension FluentRelationOps<T extends FluentRelations> on FluentProvider<T> {
  /// A fresh copy of [model] with its relations loaded — e.g. after a read with `relations: FluentLoad.none` or for
  /// `lazy` relations. Models are immutable, so the loaded copy is returned; [model] stays as it is.
  ///
  /// [names]: only these relations besides the eager ones (empty: every relation, the lazy ones too). Unknown names are
  /// reported with a hint and ignored. [maxDepth]: how many levels deep (relations of the related models). A model
  /// without a key, or whose row is gone, is returned unchanged (reported as `ignoredCall`).
  ///
  /// ```dart
  /// final Article bare = (await articles.findById(1, relations: FluentLoad.none))!;
  /// final Article full = await articles.loadRelations(bare);
  /// final Article withComments = await articles.loadRelations(bare, names: ['comments']);
  /// ```
  Future<T> loadRelations(T model, {List<String> names = const [], int maxDepth = 1}) {
    return _run<T>(FluentDbAction.relationRead, data: () async {
      final Set<String> known = {for (final FluentRelationLink l in _links) l.name};
      final List<String> unknown = names.where((n) => !known.contains(n)).toList();
      if (unknown.isNotEmpty) {
        FluentLog.issue(
          FluentIssueKind.ignoredCall,
          'Unknown relations $unknown of "$tableName" ignored.',
          table: tableName,
          tag: '$tableName:relations',
          hint: known.isEmpty ? '$modelType declares no relations.' : 'Known relations: ${known.join(', ')}.',
        );
      }

      final Object? id = model.primaryKeyValue;
      if (id == null) {
        FluentLog.issue(FluentIssueKind.ignoredCall, 'loadRelations: ${model.runtimeType} has no key yet, nothing to load.', tag: '$tableName:relations', hint: 'Save the model first, or pass a model read from the database.');
        return model;
      }

      final FluentFilter byKey = keyFilter(id);
      final List<Map<String, dynamic>> rows = await executor.query(tableName.quotedIdentifier, where: byKey.whereClause, whereArgs: _sqlArgs(byKey.whereArgs), limit: 1);
      if (rows.isEmpty) {
        FluentLog.issue(FluentIssueKind.ignoredCall, 'loadRelations: no "$tableName" row with key $id.', table: tableName, tag: '$tableName:relations', hint: 'The model may have been deleted, or it was never saved.');
        return model;
      }

      final FluentTask task = FluentTask(action: FluentDbAction.findById, table: tableName, dbName: dbName, maxDepth: maxDepth, ignoreLazy: names.isEmpty);
      final List<Map<String, dynamic>> hydrated = await _processRowsBatch(rows, task, force: names.where(known.contains).toSet());
      return _assembleModel(hydrated.first);
    });
  }

  /// Number of models related to [model] through relation [name], without loading them: one `COUNT(*)` query.
  ///
  /// Counts what a load would show: respects the relation's `where` (also its related / search / ids conditions),
  /// hides expired rows and soft-deleted rows unless the relation has `includeDeleted`; its `limit` is not applied.
  /// A single reference (`one`, `oneOf`, also to a composite key) counts 1 only when the referenced row exists and is
  /// visible. An unknown relation (reported) or a model without a key counts 0.
  ///
  /// ```dart
  /// final int comments = await articles.countRelated(article, 'comments');
  /// ```
  Future<int> countRelated(T model, String name) {
    return _run<int>(FluentDbAction.relationRead, data: () async {
      final FluentRelationLink? link = _linkNamed(name, 'countRelated');
      final Object? id = model.primaryKeyValue;
      if (link == null || id == null) return 0;

      switch (link.type) {
        case FluentRelationType.oneOf:
          final FluentFilter byKey = keyFilter(id);
          final List<Map<String, Object?>> rows = await executor.query(tableName.quotedIdentifier, columns: [link.typeColumn!, ...link.foreignKeys].quotedAll, where: byKey.whereClause, whereArgs: _sqlArgs(byKey.whereArgs), limit: 1);
          final Object? type = rows.firstOrNull?[link.typeColumn!];
          final FluentProvider? target = type is String ? link.targets[type] : null;
          if (target == null) return 0;
          // The key columns of the referenced type (several for a composite key), not just the first column.
          final Object? ref = _rowTuple(rows.first, link.columnsFor(type! as String), target.keyColumnNames.toList());
          if (ref == null) return 0;
          return _countRows(target, target._keyFilterOf(ref, stored: true).and(target._relationVisibility(link))); // ref is a stored value
        case FluentRelationType.one:
        case FluentRelationType.oneOwned:
        case FluentRelationType.many:
        case FluentRelationType.manyToMany:
          final FluentProvider target = link.target;
          FluentFilter where = _relatedRowsOf(link, _storedId(id)!);
          if (link.relation.where != null) where = where.and(link.relation.where!);
          return _countRows(target, where.and(target._relationVisibility(link)));
        case FluentRelationType.auto:
          return 0;
      }
    });
  }

  /// `SELECT COUNT(*)` of the rows of [target] matching [where] (related / search conditions resolved on [target]).
  Future<int> _countRows(FluentProvider target, FluentFilter where) async {
    final FluentFilter resolved = target._resolveRelated(where);
    final List<Map<String, Object?>> rows = await target.executor.rawQuery(
      'SELECT COUNT(*) AS c FROM ${target.tableName.quotedIdentifier}${resolved.whereClause.isEmpty ? '' : ' WHERE ${resolved.whereClause}'}',
      target._sqlArgs(resolved.whereArgs),
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Adds [related] models to relation [name] of [model] without rewriting the whole list.
  ///
  /// * `manyToMany`: the models are saved (upsert) and linked; existing links stay.
  /// * `many` / `oneOwned`: the models are saved as children of [model]; the other children stay.
  /// * `through`: the models are saved, and [link] builds the link model for each one not linked yet (its references
  ///   to [model] and the related model are filled in): `link: (group) => Membership(role: 'admin')`.
  ///
  /// Not used for single references (`one`, `oneOf`: set the field and save). An unknown relation, a [model] without
  /// a key or a `through` relation without [link] is reported (`ignoredCall`) and nothing is written.
  ///
  /// ```dart
  /// await articles.attach(article, 'tags', [dart, flutter]);
  /// await users.attach(user, 'groups', [admins], link: (group) => Membership(role: 'admin'));
  /// ```
  Future<void> attach(T model, String name, List<FluentStorable> related, {FluentStorable Function(FluentStorable related)? link}) {
    final FluentStorable Function(FluentStorable related)? buildLink = link;
    return _run<void>(FluentDbAction.relationWrite, data: () async {
      final FluentRelationLink? link = _linkNamed(name, 'attach');
      final Object? id = model.primaryKeyValue;
      if (link == null || related.isEmpty) return;
      if (id == null) {
        FluentLog.issue(FluentIssueKind.ignoredCall, 'attach: ${model.runtimeType} has no key yet.', tag: '$tableName:relations', hint: 'Save the model first, then attach related models.');
        return;
      }
      if (link.isReference || link.type == FluentRelationType.oneOf) {
        FluentLog.issue(FluentIssueKind.ignoredCall, 'attach is not used for "$name" (a single reference).', tag: '$tableName:relations', hint: 'Set the field on the model and save it instead.');
        return;
      }
      if (link.isThrough && buildLink == null) {
        FluentLog.issue(
          FluentIssueKind.ignoredCall,
          'attach: "$name" links through ${link.linkModel!.modelType}, but no link was given; nothing was attached.',
          table: tableName,
          database: dbName,
          subject: name,
          tag: '$tableName:relations',
          hint: 'Say how to build the ${link.linkModel!.modelType} of each link.',
          code: "attach(model, '$name', [...], link: (related) => ${link.linkModel!.modelType}(...));",
        );
        return;
      }

      final List<FluentStorable> accepted = _relatedOfTargetType(this, link, related);
      if (accepted.isEmpty) return;
      final Object storedId = _storedId(id)!; // references and link rows hold the stored key
      await _runInTransaction((txn) async {
        final FluentTask task = FluentTask(action: FluentDbAction.save, table: link.target.tableName, dbName: dbName);
        final FluentRelationSaveContext ctx = FluentRelationSaveContext(keepMissingOverride: true);
        if (link.isOwned) {
          final Map<String, Object?> reference = link.referenceValues(storedId);
          for (final FluentStorable child in accepted) {
            reference.forEach(child.injectRelationId);
          }
          await link.target._saveGraph(txn, link.target._createTypedList(accepted), task, ctx);
        } else {
          final List<Object?> ids = await link.target._saveGraph(txn, link.target._createTypedList(accepted), task, ctx);
          if (link.isThrough) {
            await _insertThroughLinks(txn, link, storedId, accepted, ids, buildLink!);
          } else {
            await _insertLinks(txn, link, storedId, ids.whereType<Object>().toList());
          }
        }
      });
    });
  }

  /// Saves one link model per related model that is not linked yet, with both references filled in.
  Future<void> _insertThroughLinks(Transaction txn, FluentRelationLink link, Object ownerId, List<FluentStorable> related, List<Object?> ids, FluentStorable Function(FluentStorable) build) async {
    final FluentProvider via = link.linkModel!;
    final FluentFilter mine = _equalsAll(link.linkOwnerValues(ownerId), stored: true); // ownerId and the ids are stored keys
    final List<String> targetKeys = link.target.keyColumnNames.toList();
    final Set<String> linked = {
      for (final Map<String, Object?> r in await txn.rawQuery('SELECT * FROM ${link.linkSource} AS l WHERE ${mine.whereClause}', mine.whereArgs))
        _tupleKey(_rowTuple(r, link.linkTargetColumns, targetKeys)),
    };
    final List<FluentStorable> rows = [];
    for (int i = 0; i < related.length; i++) {
      final Object? targetId = ids[i];
      if (targetId == null || !linked.add(_tupleKey(targetId))) continue;
      final FluentStorable row = build(related[i]);
      if (!via._stores(row, list: false)) {
        FluentLog.issue(
          FluentIssueKind.relationValue,
          'attach: the link for "${link.name}" is a ${row.runtimeType}, not a ${via.modelType}; it was skipped.',
          table: tableName,
          database: dbName,
          subject: link.name,
          tag: '$tableName:relations',
          hint: 'Return a ${via.modelType} from link.',
        );
        continue;
      }
      link.linkOwnerValues(ownerId).forEach(row.injectRelationId);
      link.linkTargetValues(targetId).forEach(row.injectRelationId);
      rows.add(row);
    }
    if (rows.isEmpty) return;
    await via._saveGraph(txn, via._createTypedList(rows), FluentTask(action: FluentDbAction.save, table: via.tableName, dbName: dbName), FluentRelationSaveContext());
  }

  /// Removes [related] models from relation [name] of [model].
  ///
  /// * `manyToMany`: only the links are removed; the shared models stay.
  /// * `through`: the link models are deleted (to the trash when they are soft-deletable); the related models stay.
  /// * `many` / `oneOwned`: the children are deleted (to the trash when soft-deletable; they are owned by [model]).
  ///
  /// [related] models are matched by key (models without one are skipped). Not used for single references (`one`,
  /// `oneOf`): reported as `ignoredCall`, like an unknown relation.
  ///
  /// ```dart
  /// await articles.detach(article, 'tags', [dart]);
  /// ```
  Future<void> detach(T model, String name, List<FluentStorable> related) {
    return _run<void>(FluentDbAction.relationWrite, data: () async {
      final FluentRelationLink? link = _linkNamed(name, 'detach');
      final Object? id = model.primaryKeyValue;
      if (link == null || id == null || related.isEmpty) return;
      if (link.isReference || link.type == FluentRelationType.oneOf) {
        FluentLog.issue(FluentIssueKind.ignoredCall, 'detach is not used for "$name" (a single reference).', tag: '$tableName:relations', hint: 'Clear the field on the model and save it, or delete the referenced model.');
        return;
      }

      final List<Object> ids = [for (final FluentStorable r in related) r.primaryKeyValue].whereType<Object>().toList();
      if (ids.isEmpty) return;
      final Object storedId = _storedId(id)!; // references and link rows hold the stored key

      await _runInTransaction((txn) async {
        if (link.isOwned) {
          final Map<String, Object?> owner = link.referenceValues(storedId);
          // Keys in chunks below the variable limit (the owner reference adds a few arguments to each statement).
          await link.target._forKeyChunks(ids, (keys) => link.target._removeOwned(txn, _equalsAll(owner, stored: true).and(keys)));
        } else {
          final FluentProvider? via = link.linkModel;
          final List<String> targetKeys = link.target.keyColumnNames.toList();
          final Map<String, Object?> owner = link.linkOwnerValues(storedId);
          final List<Object> storedTargets = [for (final Object t in ids) link.target._storedId(t)!];
          final int step = math.max(1, (_maxParamsPerChunk - owner.length) ~/ link.linkTargetColumns.length);
          int removed = 0;
          for (int i = 0; i < ids.length; i += step) {
            final FluentFilter where = _equalsAll(owner, stored: true).and(_tupleFilter(link.linkTargetColumns, targetKeys, storedTargets.sublist(i, math.min(i + step, storedTargets.length)), stored: true));
            // Rows of a link model go through its provider: the trash, timestamps and sync see them.
            removed += via != null ? await via._removeOwned(txn, where) : await txn.delete(link.linkTable!.quotedIdentifier, where: where.whereClause, whereArgs: where.whereArgs);
          }
          if (removed > 0) {
            FluentEngine.touch(link.target, FluentDbAction.update);
            if (via != null) FluentEngine.touch(via, FluentDbAction.delete);
          }
        }
      });
    });
  }

  /// The models of relation [name] of [model], queried instead of loaded: filtered by [where], ordered by [orderBy]
  /// (default: the relation's), paged with [limit] / [offset]. The relation's own `where` and `includeDeleted` apply,
  /// its `limit` does not. [R] is the related model type; a model without a key gives an empty list.
  ///
  /// Throws a [FluentRelationException] for an unknown relation, a [FluentArgumentException] for a `oneOf` relation
  /// (read it with [loadRelations]) or when [R] is not the related model type.
  ///
  /// ```dart
  /// final List<Comment> liked = await articles.findRelated<Comment>(article, 'comments', where: FluentFilter.gt('likes', 10), limit: 20);
  /// ```
  Future<List<R>> findRelated<R extends FluentStorable>(
    T model,
    String name, {
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final FluentRelationLink link = _relationFor(name, 'findRelated');
    if (link.type == FluentRelationType.oneOf) {
      throw FluentLog.raise(
        FluentArgumentException('name', 'findRelated: "$name" of $modelType is a single reference to one of several tables.', hint: "Read it with the model: (await provider.loadRelations(model, names: ['$name'])).$name"),
        tag: '$tableName:findRelated',
      );
    }
    final FluentProvider target = link.target;
    if (target is! FluentProvider<R>) {
      throw FluentLog.raise(
        FluentArgumentException('R', 'relation "$name" of $modelType holds ${target.modelType}, not $R.', hint: "findRelated<${target.modelType}>(model, '$name')"),
        tag: '$tableName:findRelated',
      );
    }
    final Object? id = model.primaryKeyValue;
    if (id == null) return <R>[];
    FluentFilter scope = _relatedRowsOf(link, _storedId(id)!);
    if (link.relation.where != null) scope = scope.and(link.relation.where!);
    if (where != null) scope = scope.and(where);
    Future<List<R>> read() => target.find(
      where: scope,
      orderBy: orderBy ?? link.relation.orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    );
    // The relation's own `includeDeleted` shows its trashed rows, like when it is loaded.
    // The relation decides, not the trash scope of the caller (`trash.findRelated` ...).
    return (link.relation.includeDeleted ? _TrashScope.all : _TrashScope.live).run(read);
  }

  /// A filter on the target table of [link]: the rows related to the row of this table with key [id].
  FluentFilter _relatedRowsOf(FluentRelationLink link, Object id) {
    final FluentProvider target = link.target;
    final String t = target.tableName.quotedIdentifier;
    final List<String> targetKeys = target.keyColumnNames.toList();
    switch (link.type) {
      case FluentRelationType.oneOwned:
      case FluentRelationType.many:
        return _equalsAll(link.referenceValues(id), stored: true);
      case FluentRelationType.manyToMany:
        final Map<String, Object?> owner = link.linkOwnerValues(id);
        final String match = [for (int i = 0; i < link.linkTargetColumns.length; i++) '"__fluent_l".${link.linkTargetColumns[i].quotedIdentifier} = $t.${targetKeys[i].quotedIdentifier}'].join(' AND ');
        final String ownerMatch = [for (final String c in owner.keys) '"__fluent_l".${c.quotedIdentifier} = ?'].join(' AND ');
        return FluentFilter('EXISTS (SELECT 1 FROM ${link.linkSource} AS "__fluent_l" WHERE $ownerMatch AND $match)', owner.values.toList());
      case FluentRelationType.oneOf:
        return const FluentFilter('1 = 0'); // refused by findRelated
      case FluentRelationType.one:
      case FluentRelationType.auto:
        final FluentKey key = _normalizeKey(id);
        final String ownerMatch = [for (final String c in keyColumnNames) '"__fluent_o".${c.quotedIdentifier} = ?'].join(' AND ');
        final String match = [for (int i = 0; i < link.foreignKeys.length; i++) '"__fluent_o".${link.foreignKeys[i].quotedIdentifier} = $t.${link.referencedColumns[i].quotedIdentifier}'].join(' AND ');
        return FluentFilter('EXISTS (SELECT 1 FROM ${tableName.quotedIdentifier} AS "__fluent_o" WHERE $ownerMatch AND $match)', [for (final String c in keyColumnNames) key[c]]);
    }
  }

  FluentRelationLink? _linkNamed(String name, String operation) {
    for (final FluentRelationLink l in _links) {
      if (l.name == name) return l;
    }
    FluentLog.issue(
      FluentIssueKind.ignoredCall,
      '$operation: "$tableName" has no relation "$name".',
      table: tableName,
      tag: '$tableName:relations',
      hint: _links.isEmpty ? 'Declare relations in $modelType.relations (with FluentRelations).' : 'Known relations: ${_links.map((l) => l.name).join(', ')}.',
    );
    return null;
  }

}

/// Finding the models that point to a model: its parents (owners) and the models that reference it.
extension FluentParentOps<T extends FluentStorable> on FluentProvider<T> {
  /// The models [P] whose relation points to [model]: the article of a comment, the articles of a tag, the
  /// articles whose `author` is a person. [via] names the relation of [P] when [P] has several relations to this model
  /// (`author` and `editor`); the other parameters are those of `find`. Several relations over the same reference
  /// (a full list and a filtered view of it) count as one: the unfiltered one is used. A model without a key gives an
  /// empty list.
  ///
  /// Throws a [FluentRelationException] when [P] has no relation to this model, or several and no [via]; a
  /// [FluentConfigException] when no provider (or several) stores [P].
  ///
  /// ```dart
  /// final Article? article = (await comments.findParents<Article>(comment)).firstOrNull;
  /// final List<Article> edited = await people.findParents<Article>(ann, via: 'editor', orderBy: 'title');
  /// ```
  Future<List<P>> findParents<P extends FluentRelations>(
    T model, {
    String? via,
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final FluentProvider owner = FluentDbInternals.providerForType(P, dbName: dbName);
    final List<FluentRelationLink> candidates = [
      for (final FluentRelationLink l in owner._links)
        if (identical(l.target, this) && (via == null || l.name == via)) l,
    ];
    // Several relations over the same reference (a full list and a filtered view of it, like comments / topComments)
    // point from the same parents: take the unfiltered one.
    final Set<String> references = {for (final FluentRelationLink l in candidates) '${l.type.isList}|${l.linkTable}|${l.foreignKeys}|${l.referencedColumns}'};
    final List<FluentRelationLink> links = references.length == 1 && candidates.length > 1
        ? [candidates.firstWhere((l) => l.relation.where == null && l.relation.limit == null, orElse: () => candidates.first)]
        : candidates;
    if (links.length != 1) {
      final List<String> all = [for (final FluentRelationLink l in owner._links) if (identical(l.target, this)) l.name];
      throw FluentLog.raise(
        FluentRelationException(
          links.isEmpty
              ? (via == null ? '$P has no relation to $modelType.' : '$P has no relation "$via" to $modelType.')
              : '$P has ${links.length} relations to $modelType (${all.join(', ')}); findParents cannot choose.',
          hint: links.isEmpty
              ? (all.isEmpty ? 'Declare one in $P.relations, e.g. FluentRelation.many<$P, $modelType>(...).' : 'Relations of $P to $modelType: ${all.join(', ')}.')
              : "Name the relation: findParents<$P>(model, via: '${all.first}').",
        ),
        tag: '$tableName:findParents',
      );
    }
    final Object? id = model.primaryKeyValue;
    if (id == null) return <P>[];
    final FluentFilter pointsHere = FluentFilter.related(links.single.name, keyFilter(id));
    return (owner as FluentProvider<P>).find(
      where: where == null ? pointsHere : pointsHere.and(where),
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    );
  }
}
