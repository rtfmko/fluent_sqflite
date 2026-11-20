// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Live queries.
extension FluentWatch<T extends FluentStorable> on FluentProvider<T> {
  /// The models matching [where] now, and again after every committed change of this table, of a table its loaded
  /// relations read (all [maxDepth] levels) or of a table a `FluentFilter.related` condition in [where] reads.
  /// Parameters are those of [FluentRead.find]; the trash scope of the call (`withTrash`, `trash`) is kept.
  ///
  /// The query runs when the stream is listened to. Changes within [coalesce] (one frame by default) cause one run;
  /// changes arriving while it runs cause one more run. A change of this table that names its rows (`save`,
  /// `update`, `delete` of models) re-runs the query only when one of those rows is in the current result or matches
  /// the query now; with an [offset], with relations that read this table itself, and for every other change it
  /// always re-runs. The query also runs again when the next shown row expires (`timeToLive`).
  /// A failed run is a stream error; the stream keeps watching. Cancel the subscription to stop: nothing runs or is
  /// emitted afterwards (with `StreamBuilder` this happens automatically). The stream is single-subscription.
  ///
  /// ```dart
  /// StreamBuilder<List<Todo>>(
  ///   stream: todos.watch(where: FluentFilter.eq('done', false), orderBy: 'created_at'),
  ///   builder: (context, snapshot) => TodoList(snapshot.data ?? const []),
  /// );
  /// ```
  Stream<List<T>> watch({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    Duration coalesce = const Duration(milliseconds: 16),
  }) {
    late final StreamController<List<T>> controller;
    // Re-runs happen in event callbacks, outside the zone of this call: keep its trash scope (withTrash / trash).
    final _TrashScope scope = _TrashScope.current;
    StreamSubscription<FluentChangeEvent<dynamic>>? changes;
    final List<FluentChangeEvent<dynamic>> pending = [];
    Timer? frame;
    FluentClockAlarm? expiry; // follows the library clock (a test that moves it sees rows expire)
    bool running = false;
    bool dirty = false;
    // Set by onCancel: nothing runs, emits or arms a timer afterwards (a refresh in flight stops at its next step).
    bool cancelled = false;
    Set<String> shown = {};
    // Tables (not model types: one model may live in several tables or databases) whose changes can alter the result.
    final Set<String> loaded;
    final Set<String> watched;
    final bool selfLoaded;
    try {
      loaded = {
        ..._loadedTables(relations == FluentLoad.none ? 0 : maxDepth, all: relations == FluentLoad.all),
        ..._relatedTables(where),
      };
      watched = {'$dbName/$tableName', ...loaded};
      // A table whose relations load (or filter by) rows of itself: a changed row may be a child of a shown one.
      selfLoaded = loaded.contains('$dbName/$tableName');
    } catch (e, s) {
      return Stream<List<T>>.error(e, s); // like every other failure of the stream (a provider that is not registered)
    }

    Future<void> refresh() async {
      if (cancelled) return;
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          final List<T> result = await scope.run(() => find(
            where: where,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            includeExpired: includeExpired,
            relations: relations,
            maxDepth: maxDepth,
            policy: policy,
          ));
          if (cancelled || controller.isClosed) return;
          shown = {for (final T m in result) if (m.primaryKeyValue != null) _tupleKey(m.primaryKeyValue as Object)};
          controller.add(result);
          // Rows that expire leave the result without any change event: look again when the next one does.
          expiry?.cancel();
          expiry = null;
          if (!includeExpired && result.isNotEmpty) {
            final int? next = await scope.run(() => _nextExpiry(where, policy));
            if (next != null && !cancelled && !controller.isClosed && !dirty) {
              expiry = FluentClockAlarm(next + 1, refresh, tag: '$tableName:watch');
            }
          }
        } while (dirty && !cancelled);
      } catch (e, s) {
        if (!cancelled && !controller.isClosed) controller.addError(e, s);
      } finally {
        running = false;
      }
    }

    // Whether [events] can change the result (see the doc above); errors count as "yes".
    Future<bool> affects(List<FluentChangeEvent<dynamic>> events) async {
      // With an offset, a change in front of the window moves it; with self-loading relations, a changed row may be
      // a loaded child: neither shows in the keys of the result.
      if (offset != null || selfLoaded) return true;
      final List<Object> keys = [];
      for (final FluentChangeEvent<dynamic> event in events) {
        if (event.table != tableName || event.dbName != dbName || event.items.isEmpty) return true;
        for (final Object? item in event.items) {
          final Object? key = item is FluentStorable ? item.primaryKeyValue : null;
          if (key == null || shown.contains(_tupleKey(key))) return true;
          keys.add(key);
        }
      }
      if (keys.length > 500) return true;
      try {
        return await scope.run(() => count(where: _scoped(where, keysFilter(keys)), includeExpired: includeExpired, policy: policy)) > 0;
      } catch (e) {
        // Cannot tell whether the change matters: query again (safe, only costs one read).
        FluentLog.debug('Relevance check of a change failed; the watch reads again: $e', tag: '$tableName:watch');
        return true;
      }
    }

    Future<void> onFrame() async {
      frame = null;
      if (cancelled) return;
      final List<FluentChangeEvent<dynamic>> batch = [...pending];
      pending.clear();
      if (running) {
        dirty = true;
      } else if (await affects(batch) && !cancelled) {
        await refresh();
      }
    }

    controller = StreamController<List<T>>(
      onListen: () {
        changes = FluentEngine().changeStream.where((e) => watched.contains('${e.dbName}/${e.table}')).listen((event) {
          if (cancelled) return;
          pending.add(event);
          frame ??= Timer(coalesce, onFrame);
        });
        refresh();
      },
      onCancel: () {
        cancelled = true;
        pending.clear();
        frame?.cancel();
        expiry?.cancel();
        return changes?.cancel();
      },
    );
    return controller.stream;
  }

  /// When the next row matching [where] expires (epoch milliseconds), `null` when none will.
  Future<int?> _nextExpiry(FluentFilter? where, ExecutionPolicy policy) => _run<int?>(
    FluentDbAction.relationRead,
    policy: policy,
    data: () async {
      final String column = _expiryColumn.quotedIdentifier;
      final FluentFilter visible = _resolveRelated(_scoped(where, _visibility()).and(FluentFilter('$column IS NOT NULL')));
      await _flushValueLists();
      final List<Map<String, Object?>> rows = await executor.rawQuery(
        'SELECT MIN($column) AS next FROM ${tableName.quotedIdentifier} WHERE ${visible.whereClause}',
        _sqlArgs(visible.whereArgs),
      );
      return rows.first['next'] as int?;
    },
  );

  /// Tables (`db/table`) the relations a read loads come from, [depth] levels deep: every target of a `oneOf`, the link
  /// model of a `through` relation; lazy relations only with [all].
  Set<String> _loadedTables(int depth, {required bool all}) {
    final Set<String> tables = {};
    final Set<String> seen = {};
    void visit(FluentProvider p, int left) {
      if (left <= 0 || !seen.add('${p.dbName}/${p.tableName}|$left')) return;
      for (final FluentRelationLink l in p._links) {
        if (l.relation.lazy && !all) continue;
        final FluentProvider? linkModel = l.linkModel;
        if (linkModel != null) tables.add('${linkModel.dbName}/${linkModel.tableName}');
        for (final FluentProvider t in l.type == FluentRelationType.oneOf ? l.targets.values : [l.target]) {
          tables.add('${t.dbName}/${t.tableName}');
          visit(t, left - 1);
        }
      }
    }

    visit(this, depth);
    return tables;
  }

  /// The result of [query] now, and again after every committed change of this table, of a table its relations
  /// (lazy ones too, one level) load from, or of the tables of [alsoOn]; a new result equal to the last one (lists
  /// and maps compared deeply) is not emitted. Changes within [coalesce] cause one run; a failed run is a stream
  /// error. Cancel the subscription to stop watching.
  ///
  /// For values that are not lists of models: aggregates, counts, projections.
  ///
  /// ```dart
  /// StreamBuilder<num>(
  ///   stream: orders.watchValue(() => orders.sum('total', where: FluentFilter.eq('status', OrderStatus.paid))),
  ///   builder: (context, s) => Text('${s.data ?? 0}'),
  /// );
  /// ```
  Stream<R> watchValue<R>(Future<R> Function() query, {List<FluentProvider> alsoOn = const [], Duration coalesce = const Duration(milliseconds: 16)}) {
    late final StreamController<R> controller;
    StreamSubscription<FluentChangeEvent<dynamic>>? changes;
    Timer? frame;
    bool running = false;
    bool dirty = false;
    bool emitted = false;
    bool cancelled = false;
    R? last;
    final Set<String> watched;
    try {
      watched = {
        '$dbName/$tableName',
        ..._loadedTables(1, all: true),
        for (final FluentProvider p in alsoOn) '${p.dbName}/${p.tableName}',
      };
    } catch (e, s) {
      return Stream<R>.error(e, s); // a provider that is not registered
    }

    Future<void> refresh() async {
      if (cancelled) return;
      if (running) {
        dirty = true;
        return;
      }
      running = true;
      try {
        do {
          dirty = false;
          final R result = await query();
          if (cancelled || controller.isClosed) return;
          if (!emitted || !_sameValue(result, last)) {
            emitted = true;
            last = result;
            controller.add(result);
          }
        } while (dirty && !cancelled);
      } catch (e, s) {
        if (!cancelled && !controller.isClosed) controller.addError(e, s);
      } finally {
        running = false;
      }
    }

    controller = StreamController<R>(
      onListen: () {
        changes = FluentEngine().changeStream.where((e) => watched.contains('${e.dbName}/${e.table}')).listen((_) {
          if (cancelled) return;
          frame ??= Timer(coalesce, () {
            frame = null;
            refresh();
          });
        });
        refresh();
      },
      onCancel: () {
        cancelled = true;
        frame?.cancel();
        return changes?.cancel();
      },
    );
    return controller.stream;
  }

  /// Tables (`db/table`) the related conditions of [filter] read, along their relation paths.
  Set<String> _relatedTables(FluentFilter? filter) {
    final Set<String> tables = {};
    for (final FluentRelatedCondition c in (filter?.deferred ?? const <FluentDeferredCondition>[]).whereType<FluentRelatedCondition>()) {
      FluentProvider current = this;
      for (final String name in c.relation.split('.')) {
        final FluentRelationLink? link = current._links.where((l) => l.name == name).firstOrNull;
        if (link == null) break;
        current = link.target;
        tables.add('${current.dbName}/${current.tableName}');
        if (link.linkTable != null) tables.add('$dbName/${link.linkTable}');
      }
      tables.addAll(current._relatedTables(c.where));
    }
    return tables;
  }

  /// Deep equality of query results (lists and maps of plain values).
  static bool _sameValue(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final Object? key in a.keys) {
        if (!b.containsKey(key) || !_sameValue(a[key], b[key])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// The model with key [id] now, and again whenever it (or a table its relations load from) changes; `null` while
  /// it does not exist (a `null` [id] gives one `null`). Parameters are those of [FluentRead.findById] and [watch].
  ///
  /// ```dart
  /// StreamBuilder<Order?>(stream: orders.watchById(orderId), builder: (context, s) => OrderCard(s.data));
  /// ```
  Stream<T?> watchById(
    Object? id, {
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    Duration coalesce = const Duration(milliseconds: 16),
  }) {
    if (id == null) return Stream<T?>.value(null);
    final FluentFilter byKey;
    try {
      byKey = keyFilter(id);
    } catch (e, s) {
      return Stream<T?>.error(e, s); // like every other failure of the stream
    }
    return watch(
      where: byKey,
      limit: 1,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
      coalesce: coalesce,
    ).map((found) => found.isEmpty ? null : found.first);
  }
}
