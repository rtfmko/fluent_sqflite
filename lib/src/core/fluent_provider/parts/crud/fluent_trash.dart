// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Which rows reads see: the live ones (default), the live and the trashed ones ([FluentWithTrash]), or only the
/// trashed ones ([FluentTrash]). Carried by the zone of the call, so every read method follows it without a parameter.
enum _TrashScope {
  live,
  all,
  only;

  static final Object _key = Object();

  /// The scope of the current call.
  static _TrashScope get current => Zone.current[_key] as _TrashScope? ?? live;

  /// Runs [body] with this scope.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_key: this});
}

/// The trash and the trash-inclusive reads of models with [FluentSoftDeletable] — they exist only for such models.
extension FluentTrashAccess<T extends FluentSoftDeletable> on FluentProvider<T> {
  /// The trash: the soft-deleted rows — list, count, watch, restore, delete for good, empty.
  ///
  /// ```dart
  /// final List<Note> trashed = await notes.trash.find(orderBy: 'deleted_at DESC');
  /// await notes.trash.restore(note);
  /// await notes.trash.empty(olderThan: const Duration(days: 30));
  /// ```
  FluentTrash<T> get trash => FluentTrash<T>._(() => this);

  /// Reads that see the live and the trashed rows: every read method of the provider (`find`, `findById`, `count`,
  /// `watch`, aggregates, ...).
  ///
  /// ```dart
  /// final Note? any = await notes.withTrash.findById(id); // also when it is in the trash
  /// ```
  FluentWithTrash<T> get withTrash => FluentWithTrash<T>._(() => this);
}

/// The trash of a soft-delete table (see [FluentTrashAccess.trash]).
class FluentTrash<T extends FluentSoftDeletable> {
  FluentTrash._(this._resolve);

  /// The provider, looked up per call: a lookup error (`FluentDb.trash<T>()` of an unregistered model) arrives
  /// through the Future / Stream of the call, never at `trash` itself.
  final FluentProvider<T> Function() _resolve;

  FluentProvider<T> get _provider => _resolve();

  /// The trashed models matching [where].
  Future<List<T>> find({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async => _TrashScope.only.run(() => _provider.find(where: where, orderBy: orderBy, limit: limit, offset: offset, relations: relations, maxDepth: maxDepth, policy: policy));

  /// The number of trashed rows matching [where].
  Future<int> count({FluentFilter? where, ExecutionPolicy policy = const ExecutionPolicy()}) async => _TrashScope.only.run(() => _provider.count(where: where, policy: policy));

  /// The trashed models now and after every change (a trash screen).
  Stream<List<T>> watch({FluentFilter? where, String? orderBy, int? limit, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _guardedStream(() => _TrashScope.only.run(() => _provider.watch(where: where, orderBy: orderBy, limit: limit, relations: relations, maxDepth: maxDepth, policy: policy)));

  /// Brings [item] back from the trash (with the owned rows deleted together with it) and clears `item.deletedAt`;
  /// returns 1 or 0. A row whose owner is still in the trash stays there (0, reported as a `trashStays` issue).
  ///
  /// ```dart
  /// if (await notes.trash.restore(note) == 1) print('back: ${note.isDeleted}'); // false
  /// ```
  Future<int> restore(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final int count = await restoreById(item.primaryKeyValue, tag: tag, policy: policy);
    if (count > 0) item.deletedAt = null;
    return count;
  }

  /// Brings the row with key [id] back from the trash (see [restore]); returns 1 or 0.
  Future<int> restoreById(Object? id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      id == null ? 0 : _provider._run<int>(FluentDbAction.restore, helper: TableHelper(arguments: [id]), policy: policy, tag: tag);

  /// Brings the trashed rows matching [where] back (see [restore]); returns their number.
  Future<int> restoreWhere(FluentFilter where, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _provider._run<int>(FluentDbAction.restore, helper: _provider._helperFor(where), policy: policy, tag: tag);

  /// Removes [item] permanently — live or trashed; returns 1 or 0. Follows the relation rules and leaves sync
  /// tombstones like every permanent delete (see [FluentRemove]).
  Future<int> deleteForever(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _provider._removeItems([item], hard: true, tag: tag, policy: policy);

  /// Removes the row with key [id] permanently; returns 1 or 0.
  Future<int> deleteForeverById(Object? id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      id == null ? 0 : _provider._remove(TableHelper(arguments: [id]), hard: true, tag: tag, policy: policy);

  /// Removes every row matching [where] permanently (live or trashed); returns their number.
  Future<int> deleteForeverWhere(FluentFilter where, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _provider._remove(_provider._helperFor(where), hard: true, tag: tag, policy: policy);

  /// Empties the trash: removes rows trashed more than [olderThan] ago for good (default: `trashRetention` of the
  /// table, else of the database, else `FluentConfig.trashRetention`; [Duration.zero] removes all of them). Returns
  /// their number. Also runs by itself (`FluentConfig.trashPurgeInterval`).
  ///
  /// Syncable tables: a row whose deletion was not pushed yet stays until `syncWithServer` pushed it; the owned
  /// syncable children removed with the purged rows leave tombstones.
  Future<int> empty({Duration? olderThan, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _provider._purgeTrash(olderThan: olderThan, tag: tag, policy: policy);
}

/// Reads of a soft-delete table that see the live and the trashed rows (see [FluentTrashAccess.withTrash]).
class FluentWithTrash<T extends FluentSoftDeletable> {
  FluentWithTrash._(this._resolve);

  /// The provider, looked up per call (see [FluentTrash]).
  final FluentProvider<T> Function() _resolve;

  /// Runs [read] in the "live and trashed" scope; a provider lookup error becomes the error of the returned Future /
  /// Stream (every read returns one of the two).
  R _all<R>(R Function(FluentProvider<T> p) read) {
    final FluentProvider<T> provider;
    try {
      provider = _resolve();
    } catch (e, s) {
      return (<R>[] is List<Stream<Object?>> ? Stream<Never>.error(e, s) : Future<Never>.error(e, s)) as R;
    }
    return _TrashScope.all.run(() => read(provider));
  }

  /// See [FluentRead.findById].
  Future<T?> findById(Object? id, {bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.findById(id, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findByIds].
  Future<List<T>> findByIds(Iterable<Object?> ids, {bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.findByIds(ids, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.find].
  Future<List<T>> find({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all((p) => p.find(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findFirst].
  Future<T?> findFirst({FluentFilter? where, String? orderBy, bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.findFirst(where: where, orderBy: orderBy, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findPage].
  Future<FluentPage<T>> findPage({
    FluentFilter? where,
    String? orderBy,
    bool descending = false,
    int limit = 50,
    FluentCursor? after,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all(
    (p) => p.findPage(where: where, orderBy: orderBy, descending: descending, limit: limit, after: after, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy),
  );

  /// See [FluentRead.count].
  Future<int> count({FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.count(where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.exists].
  Future<bool> exists(Object? id, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) => _all((p) => p.exists(id, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.existsWhere].
  Future<bool> existsWhere(FluentFilter where, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.existsWhere(where, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.findMaps].
  Future<List<Map<String, dynamic>>> findMaps({
    FluentFilter? where,
    List<String>? columns,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all((p) => p.findMaps(where: where, columns: columns, distinct: distinct, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.pluck].
  Future<List<V>> pluck<V>(
    String column, {
    FluentFilter? where,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all((p) => p.pluck<V>(column, where: where, distinct: distinct, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.countDistinct].
  Future<int> countDistinct(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.countDistinct(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.aggregate].
  Future<List<Map<String, dynamic>>> aggregate({
    required Map<String, FluentAggregate> values,
    List<String> groupBy = const [],
    FluentFilter? where,
    FluentFilter? having,
    String? orderBy,
    int? limit,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all((p) => p.aggregate(values: values, groupBy: groupBy, where: where, having: having, orderBy: orderBy, limit: limit, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.findAll].
  Future<List<T>> findAll({String? orderBy, int? limit, bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.findAll(orderBy: orderBy, limit: limit, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.search].
  Future<List<T>> search(
    String text, {
    FluentFilter? where,
    bool prefix = true,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all(
    (p) => p.search(text, where: where, prefix: prefix, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy),
  );

  /// See [FluentAggregates.sum].
  Future<num> sum(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.sum(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.avg].
  Future<double?> avg(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.avg(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.min].
  Future<V?> min<V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.min<V>(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.max].
  Future<V?> max<V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.max<V>(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentWatch.watch].
  Stream<List<T>> watch({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => _all((p) => p.watch(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentWatch.watchById].
  Stream<T?> watchById(Object? id, {bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _all((p) => p.watchById(id, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));
}

/// The trash purge for any provider (the library runs it for every soft-delete table).
extension _FluentTrashPurge<T extends FluentStorable> on FluentProvider<T> {
  /// Permanently removes rows soft-deleted more than [olderThan] ago (default: the resolved `trashRetention`).
  Future<int> _purgeTrash({Duration? olderThan, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (_softDeleteColumn == null) return 0;
    final Duration period = olderThan ?? _trashRetention;
    return _run<int>(FluentDbAction.purgeDeleted, helper: TableHelper(value: period), policy: policy, tag: tag);
  }
}

/// [open] as a stream whose synchronous errors (a provider lookup) arrive as stream errors.
Stream<R> _guardedStream<R>(Stream<R> Function() open) {
  try {
    return open();
  } catch (e, s) {
    return Stream<R>.error(e, s);
  }
}

/// `FluentDb.trash<T>()`: the trash of the provider [resolve] finds when a call runs.
FluentTrash<T> fluentLazyTrash<T extends FluentSoftDeletable>(FluentProvider<T> Function() resolve) => FluentTrash<T>._(resolve);

/// `FluentDb.withTrash<T>()`: reads with trash of the provider [resolve] finds when a call runs.
FluentWithTrash<T> fluentLazyWithTrash<T extends FluentSoftDeletable>(FluentProvider<T> Function() resolve) => FluentWithTrash<T>._(resolve);
