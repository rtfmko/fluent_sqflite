// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// When each `watchRemote` query last got and stored an answer (for `maxAge`).
const String _fetchStateTable = '__fluent_fetch_state';

/// Cache-then-server lists for any [FluentProvider] (offline-first screens).
extension FluentWatchRemote<T extends FluentStorable> on FluentProvider<T> {
  /// The cached rows at once, then the server's: an offline-first list in one stream of [FluentRemoteEvent]s.
  ///
  /// 1. **Cache** (with [source] [FluentRemoteSource.cacheThenRemote], the default): the rows matching [where] (by
  ///    [orderBy], at most [limit]) → `cached`. `remoteOnly` skips this event; `cacheOnly` never calls [fetch].
  /// 2. **Fetch**: [fetch] → `fetching` (the rows are still the cache). A failure (a throw, or
  ///    [FluentRemoteResponse.failed]) is tried again [retries] times after [retryDelay], doubled each time with
  ///    ±50 % jitter (not for HTTP 4xx other than 408 / 429).
  /// 3. **Store** by [store], then the rows are read again → `fresh`: [FluentRemoteStore.merge] (default) saves them,
  ///    `mirror` also deletes the cached rows of [where] the answer lacks, `replace` swaps the cached rows of [where]
  ///    for the answer, `none` stores nothing. `mirror` / `replace` with a [limit] work as `merge`. A failure →
  ///    `failed` with the cached rows and the error; statuses in [clearCacheOn] (e.g. `{401}`) also remove the cached
  ///    rows of [where].
  /// 4. While [keepWatching] (default), the stream stays open and emits the rows again whenever they change (the
  ///    phase and error stay the last ones). With `store: none` the stream ends after the fetched rows.
  ///
  /// A big answer can come in pages: pass [fetchPage] instead of [fetch]. It gets a [FluentRemoteRequest] (`page`,
  /// `cursor`) and returns a [FluentRemoteResponse] with `hasMore` and `cursor` set while more pages follow. Every
  /// page is fetched with the retries above and stored when it arrives (like the pages of a `syncWithServer` pull), a
  /// `fetching` event with the rows read so far follows each stored page, and `mirror` / `replace` delete the cached
  /// rows the server lacks only after the last page. A page that fails (after its retries), a cancel, or a store
  /// error in between leaves the pages stored so far and deletes nothing. `store: none` collects all pages.
  ///
  /// With [maxAge], the fetch is skipped (→ `fresh`) while the last stored answer of the same query (`where`,
  /// `limit`) is younger; for pull-to-refresh call it again without [maxAge]. Expired rows are shown while
  /// [includeExpired] (default: an old cache is better than an empty screen).
  ///
  /// Rows are matched with the server by `FluentTableConfig.serverKey` (else the key). For `FluentSyncable` providers
  /// fetched rows are stored as synced, and rows with local changes not sent yet are kept as they are by every store
  /// mode and by [clearCacheOn]; the time of the last `syncWithServer` pull is not touched. Cancelling the
  /// subscription stops retries, and an answer that arrives later is not stored. Fetch and store failures arrive as
  /// `failed` events, not as stream errors.
  ///
  /// ```dart
  /// StreamBuilder<FluentRemoteEvent<Post>>(
  ///   stream: posts.watchRemote(
  ///     fetch: () async => FluentRemoteResponse(await api.posts(userId: 1)),
  ///     where: FluentFilter.eq('user_id', 1),
  ///     store: FluentRemoteStore.mirror,
  ///   ),
  ///   builder: (context, s) => PostList(s.data?.items ?? const [], refreshing: s.data?.isFetching ?? true),
  /// );
  /// ```
  Stream<FluentRemoteEvent<T>> watchRemote({
    Future<FluentRemoteResponse<T>> Function()? fetch,
    Future<FluentRemoteResponse<T>> Function(FluentRemoteRequest request)? fetchPage,
    FluentFilter? where,
    String? orderBy,
    int? limit,
    FluentRemoteStore store = FluentRemoteStore.merge,
    FluentRemoteSource source = FluentRemoteSource.cacheThenRemote,
    Duration? maxAge,
    int retries = 0,
    Duration retryDelay = const Duration(milliseconds: 500),
    Set<int> clearCacheOn = const {},
    bool keepWatching = true,
    bool includeExpired = true,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    FluentRelationSyncMode? relationSync,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) {
    if (fetch == null && fetchPage == null && source != FluentRemoteSource.cacheOnly) {
      return Stream<FluentRemoteEvent<T>>.error(
        FluentLog.raise(
          FluentArgumentException(
            'fetch',
            'watchRemote on "$tableName" got neither fetch nor fetchPage',
            hint: 'Pass fetch: () async => FluentRemoteResponse(rows), or fetchPage: (request) async => ... for an answer in pages (or source: FluentRemoteSource.cacheOnly).',
          ),
          tag: 'sync:$tableName',
        ),
      );
    }
    if (fetch != null && fetchPage != null) {
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        'watchRemote on "$tableName" got fetch and fetchPage: fetch is ignored.',
        table: tableName,
        tag: 'sync:$tableName',
        hint: 'Pass only fetchPage (a single answer is a page without hasMore).',
      );
    }
    final Future<FluentRemoteResponse<T>> Function(FluentRemoteRequest request)? pager = fetchPage ?? (fetch == null ? null : (_) => fetch());
    // The generator only notices a cancel at its next `yield`; the flag also stops retries and the store of an
    // answer that arrives after the listener left.
    bool cancelled = false;
    StreamSubscription<FluentRemoteEvent<T>>? events;
    late final StreamController<FluentRemoteEvent<T>> controller;
    controller = StreamController<FluentRemoteEvent<T>>(
      onListen: () => events = _remoteEvents(
        fetchPage: pager,
        where: where,
        orderBy: orderBy,
        limit: limit,
        store: store,
        source: source,
        maxAge: maxAge,
        retries: retries,
        retryDelay: retryDelay,
        clearCacheOn: clearCacheOn,
        keepWatching: keepWatching,
        includeExpired: includeExpired,
        relations: relations,
        maxDepth: maxDepth,
        relationSync: relationSync,
        policy: policy,
        cancelled: () => cancelled,
      ).listen(controller.add, onError: controller.addError, onDone: controller.close),
      onPause: () => events?.pause(),
      onResume: () => events?.resume(),
      onCancel: () {
        cancelled = true;
        // Not awaited: an async* generator finishes its cancel only at its next `yield`, i.e. after an in-flight fetch
        // (maybe never). The flag makes it stop at once when the fetch ends; its answer is not stored.
        final Future<void>? done = events?.cancel();
        if (done != null) unawaited(done.then<void>((_) {}, onError: (Object _) {}));
        return null;
      },
    );
    return controller.stream;
  }

  /// The events of [watchRemote]; stops fetching and storing once [cancelled].
  Stream<FluentRemoteEvent<T>> _remoteEvents({
    required Future<FluentRemoteResponse<T>> Function(FluentRemoteRequest request)? fetchPage,
    required FluentFilter? where,
    required String? orderBy,
    required int? limit,
    required FluentRemoteStore store,
    required FluentRemoteSource source,
    required Duration? maxAge,
    required int retries,
    required Duration retryDelay,
    required Set<int> clearCacheOn,
    required bool keepWatching,
    required bool includeExpired,
    required FluentLoad relations,
    required int maxDepth,
    required FluentRelationSyncMode? relationSync,
    required ExecutionPolicy policy,
    required bool Function() cancelled,
  }) async* {
    Future<List<T>> read() => find(where: where, orderBy: orderBy, limit: limit, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy);

    List<T> cache = const [];
    FluentRemotePhase phase = FluentRemotePhase.cached;
    Object? error;
    List<T>? fetched; // the answer itself with `store: none`

    if (source != FluentRemoteSource.cacheOnly) {
      if (source == FluentRemoteSource.cacheThenRemote) {
        cache = await read();
        yield FluentRemoteEvent(phase: FluentRemotePhase.cached, items: cache);
      }
      final String fetchKey = _fetchKey(where, limit);
      final DateTime? stored = maxAge == null ? null : await _lastFetch(fetchKey);
      if (stored != null && FluentClock.now().difference(stored) < maxAge!) {
        FluentLog.debug('watchRemote of "$tableName": the cache is fresh (stored ${FluentClock.now().difference(stored).inSeconds} s ago), fetch skipped', tag: 'sync:$tableName');
        phase = FluentRemotePhase.fresh;
      } else {
        yield FluentRemoteEvent(phase: FluentRemotePhase.fetching, items: cache);
        final (FluentRemoteResponse<T>?, Object?) first = await _fetchRemote(fetchPage!, const FluentRemoteRequest(), retries, retryDelay, cancelled);
        if (cancelled()) {
          FluentLog.debug('watchRemote of "$tableName" was cancelled during the fetch; the answer is not stored', tag: 'sync:$tableName');
          return;
        }
        error = first.$2;
        FluentRemoteResponse<T>? page = first.$1;
        if (error == null && page!.hasMore) {
          // An answer in pages: each page is stored when it arrives (like a pull); `mirror` / `replace` delete the
          // rows the server lacks only after the last page, so a failure or a cancel in between deletes nothing.
          final FluentRemoteStore each = _storeFor(store, limit);
          final bool deletes = each == FluentRemoteStore.mirror || each == FluentRemoteStore.replace;
          final Set<String> answered = {};
          bool keyless = false;
          bool storeFailed = false;
          final List<T> collected = [];
          for (int number = 0;; number++) {
            if (store == FluentRemoteStore.none) {
              collected.addAll(page!.items);
            } else {
              try {
                if (deletes && !keyless && !_collectAnswered(page!.items, answered)) keyless = true;
                await _storeRemote(page!.items, FluentRemoteStore.merge, where, null, relationSync);
              } catch (e) {
                _reportStoreFailed();
                error = e;
                storeFailed = true;
                break;
              }
            }
            if (cancelled()) return;
            if (!page.hasMore) break;
            if (store != FluentRemoteStore.none) yield FluentRemoteEvent(phase: FluentRemotePhase.fetching, items: await read());
            if (cancelled()) return;
            if (number + 1 >= _maxRemotePages) {
              error = FluentSyncException(
                'The server of "$tableName" kept sending pages (more than $_maxRemotePages)',
                code: FluentErrorCode.apiError,
                hint: 'Return hasMore: false on the last page, and a cursor that moves on with every page.',
              );
              break;
            }
            final (FluentRemoteResponse<T>?, Object?) next = await _fetchRemote(fetchPage, FluentRemoteRequest(cursor: page.cursor, page: number + 1), retries, retryDelay, cancelled);
            if (cancelled()) {
              FluentLog.debug('watchRemote of "$tableName" was cancelled during the fetch; the pages after page $number are not stored', tag: 'sync:$tableName');
              return;
            }
            if (next.$2 != null) {
              error = next.$2;
              break;
            }
            page = next.$1;
          }
          if (error == null && store == FluentRemoteStore.none) {
            fetched = collected;
          } else if (error == null && deletes && !keyless) {
            try {
              await _removeMissing(await _missingOnServer(answered, where), relationSync);
            } catch (e) {
              _reportStoreFailed();
              error = e;
              storeFailed = true;
            }
          }
          if (error == null && store != FluentRemoteStore.none && maxAge != null) {
            try {
              await _markFetched(fetchKey);
            } catch (e) {
              _reportStoreFailed();
              error = e;
            }
          }
          if (cancelled()) return;
          phase = error == null ? FluentRemotePhase.fresh : FluentRemotePhase.failed;
          if (error != null && !storeFailed) await _reportFetchFailed(error, clearCacheOn, where);
        } else if (error != null) {
          phase = FluentRemotePhase.failed;
          await _reportFetchFailed(error, clearCacheOn, where);
        } else if (store == FluentRemoteStore.none) {
          phase = FluentRemotePhase.fresh;
          fetched = page!.items;
        } else {
          try {
            await _storeRemote(page!.items, store, where, limit, relationSync);
            if (maxAge != null) await _markFetched(fetchKey);
            phase = FluentRemotePhase.fresh;
          } catch (e) {
            _reportStoreFailed();
            phase = FluentRemotePhase.failed;
            error = e;
          }
        }
      }
    }

    if (fetched != null) {
      yield FluentRemoteEvent(phase: phase, items: fetched);
    } else if (keepWatching) {
      final FluentRemotePhase last = phase;
      final Object? lastError = error;
      yield* watch(where: where, orderBy: orderBy, limit: limit, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy)
          .map((rows) => FluentRemoteEvent(phase: last, items: rows, error: lastError));
    } else {
      yield FluentRemoteEvent(phase: phase, items: await read(), error: error);
    }
  }

  /// Pages one fetch may have: a server that never says `hasMore: false` fails the fetch instead of looping.
  static const int _maxRemotePages = 10000;

  /// The failure of a fetch: logged, and the cache is cleared for the statuses of [clearCacheOn].
  Future<void> _reportFetchFailed(Object error, Set<int> clearCacheOn, FluentFilter? where) async {
    FluentLog.issue(
      FluentIssueKind.apiFailed,
      'fetch of watchRemote on "$tableName" failed',
      table: tableName,
      tag: 'sync:$tableName',
      hint: 'The cached rows stay; the error is in the failed event.',
      error: error,
    );
    final int? status = error is FluentSyncException ? error.statusCode : null;
    if (status != null && clearCacheOn.contains(status)) {
      try {
        await clearLocally(where ?? FluentFilter.empty);
      } catch (e) {
        // The failed write logged itself; the event still carries the fetch error.
        FluentLog.debug('Clearing the cache after HTTP $status failed: $e', tag: 'sync:$tableName');
      }
    }
  }

  /// The failure of storing fetched rows: the failed write logged the error itself; this says what it means.
  void _reportStoreFailed() {
    FluentLog.issue(
      FluentIssueKind.syncStoreFailed,
      'watchRemote could not store the fetched rows of "$tableName"',
      table: tableName,
      tag: 'sync:$tableName',
      hint: 'The cache keeps its previous rows. Check the error above (constraint, schema) and the rows fetch returns.',
    );
  }

  /// Calls [fetchPage] with retries (none once [cancelled]); the answer, or the last error.
  Future<(FluentRemoteResponse<T>?, Object?)> _fetchRemote(
    Future<FluentRemoteResponse<T>> Function(FluentRemoteRequest request) fetchPage,
    FluentRemoteRequest request,
    int retries,
    Duration retryDelay,
    bool Function() cancelled,
  ) async {
    for (int attempt = 0;; attempt++) {
      Object error;
      try {
        final FluentRemoteResponse<T> response = await fetchPage(request);
        if (response.isSuccess) return (response, null);
        error = FluentSyncException(
          'The server answered ${response.statusCode} for "$tableName"',
          statusCode: response.statusCode,
          code: FluentErrorCode.apiError,
          hint: 'Nothing was stored; the cached rows stay. Statuses 200–299 count as success.',
          cause: response.error,
        );
      } catch (e) {
        error = e;
      }
      if (attempt >= retries || !fluentRetryCanHelp(error) || cancelled()) return (null, error);
      await Future<void>.delayed(fluentRetryDelay(retryDelay, attempt));
      if (cancelled()) return (null, error);
    }
  }

  /// The `maxAge` key of a query: table, condition (with its values) and limit.
  String _fetchKey(FluentFilter? where, int? limit) => jsonEncode([tableName, fluentFilterKey(where), limit]);

  /// When the query [key] last stored an answer; `null` if never (or the bookkeeping table is missing).
  Future<DateTime?> _lastFetch(String key) => _run<DateTime?>(
    FluentDbAction.relationRead,
    data: () async {
      try {
        final List<Map<String, Object?>> rows = await executor.query(_fetchStateTable, columns: ['fetched_at'], where: 'query = ?', whereArgs: [key]);
        return rows.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(rows.first['fetched_at']! as int);
      } on DatabaseException {
        return null; // created with the first stored answer
      }
    },
  );

  /// Records that the query [key] stored an answer now.
  Future<void> _markFetched(String key) => _run<void>(
    FluentDbAction.relationWrite,
    data: () => _write('Remember the fetch time', (txn) async {
      await txn.execute('CREATE TABLE IF NOT EXISTS ${_fetchStateTable.quotedIdentifier} (query TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL)');
      await txn.insert(_fetchStateTable, {'query': key, 'fetched_at': FluentClock.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
    }),
  );

  /// [store] as it works with [limit]: `mirror` / `replace` of a page are `merge` (with a warning).
  FluentRemoteStore _storeFor(FluentRemoteStore store, int? limit) {
    if (limit == null || (store != FluentRemoteStore.mirror && store != FluentRemoteStore.replace)) return store;
    FluentLog.issue(
      FluentIssueKind.ignoredCall,
      'store: ${store.name} on "$tableName" works as merge: with a limit the answer is a page, not the full set.',
      table: tableName,
      tag: 'sync:$tableName',
      hint: 'Use ${store.name} without limit (with a `where` that matches exactly what the server returns), or merge for pages.',
    );
    return FluentRemoteStore.merge;
  }

  /// Stores fetched rows by [store] (see [watchRemote]).
  Future<void> _storeRemote(List<T> items, FluentRemoteStore store, FluentFilter? where, int? limit, FluentRelationSyncMode? relationSync) async {
    store = _storeFor(store, limit);
    switch (store) {
      case FluentRemoteStore.none:
        return;
      case FluentRemoteStore.replace:
        await replaceLocally(where ?? FluentFilter.empty, items, relationSync: relationSync);
      case FluentRemoteStore.merge:
      case FluentRemoteStore.mirror:
        List<Object> missing = const [];
        if (store == FluentRemoteStore.mirror) {
          final Set<String> answered = {};
          if (_collectAnswered(items, answered)) missing = await _missingOnServer(answered, where);
        }
        if (_syncColumns != null) {
          // Like a pull: stored as synced, local changes not sent yet win; the time of the last pull stays.
          final Map<int, Object> busy = await unpushedCounterparts(items);
          await applyPull(
            FluentPullResult<T>(deletedKeys: missing),
            remote: [for (int i = 0; i < items.length; i++) if (!busy.containsKey(i)) items[i]],
            relationSync: relationSync,
          );
        } else {
          await _mergeLocally(items, missing, relationSync);
        }
    }
  }

  /// Removes the rows of the [missing] server keys (what `mirror` deletes after the last page).
  Future<void> _removeMissing(List<Object> missing, FluentRelationSyncMode? relationSync) {
    if (missing.isEmpty) return Future<void>.value();
    if (_syncColumns != null) return applyPull(FluentPullResult<T>(deletedKeys: missing), remote: const [], relationSync: relationSync);
    return _mergeLocally(const [], missing, relationSync);
  }

  /// Saves [items] and removes the rows of the [missing] server keys (soft delete when the model has it) in one
  /// transaction: the cache never shows half of an answer, and a failure keeps the previous rows.
  Future<void> _mergeLocally(List<T> items, List<Object> missing, FluentRelationSyncMode? relationSync) => _run<void>(
    FluentDbAction.relationWrite,
    data: () => _write('Store the answer', (txn) async {
      final List<String>? conflictOn = setEquals(_serverKey.toSet(), keyColumnNames.toSet()) ? null : _serverKey;
      if (items.isNotEmpty) {
        final FluentTask task = FluentTask(action: FluentDbAction.save, table: tableName, dbName: dbName, helper: TableHelper(syncMode: relationSync));
        if (_links.isNotEmpty) {
          await _saveGraph(txn, items, task, FluentRelationSaveContext(keepMissingOverride: _keepMissingOverride(task)), conflictOn: conflictOn);
        } else {
          _injectKeys(items, await _writeRows(txn, [for (final T item in items) _prepareSqlJson(item)], FluentSaveStrategy.upsert, conflictOn: conflictOn));
          FluentEngine.touch(this, FluentDbAction.save, items);
        }
      }
      await _forServerKeyChunks(missing, (keys) async {
        final FluentFilter where = _resolveRelated(keys);
        await (_softDeleteColumn != null ? _softDeleteWhere(txn, where, _softDeleteStamp()) : _hardDeleteWhere(txn, where));
      });
    }),
  );

  /// Adds the typed server keys of [items] to [answered]. `false` (with a warning) when a fetched row has no server
  /// key: then nothing can be matched safely and `mirror` deletes nothing.
  bool _collectAnswered(List<T> items, Set<String> answered) {
    final List<String> columns = _serverKey;
    for (final T item in items) {
      final Map<String, dynamic> row = _prepareSqlJson(item);
      final List<Object?> values = [for (final String c in columns) row[c]];
      if (values.contains(null)) {
        FluentLog.issue(
          FluentIssueKind.ignoredCall,
          'store: mirror on "$tableName" deleted nothing: a fetched row has no server key (${columns.join(', ')}).',
          table: tableName,
          tag: 'sync:$tableName',
          hint: 'Fill ${columns.join(', ')} in the rows fetch returns, or set FluentTableConfig(serverKey: [...]) to the columns the server fills.',
        );
        return false;
      }
      answered.add(_valuesKey(columns, values));
    }
    return true;
  }

  /// Rows read per query when `mirror` looks for cached rows the server lacks.
  static const int _mirrorPageSize = 500;

  /// Server keys of the cached rows of [where] whose key is not in [answered]. The cached keys are read page by page
  /// (keyset paging over the primary key), so memory holds one page and the keys to delete, not every cached row.
  Future<List<Object>> _missingOnServer(Set<String> answered, FluentFilter? where) async {
    final List<String> columns = _serverKey;
    final List<String> keys = keyColumnNames.toList();
    final List<String> selected = {...keys, ...columns}.toList();
    final String order = keys.map((k) => '${k.quotedIdentifier} ASC').join(', ');
    // findMaps returns Dart values, the answer was prepared as stored values: compare both as stored values.
    Object? stored(Object? value) => FluentSqlSanitizer.sanitizeValueOnly(value, _tableConfig);
    final List<Object> missing = [];
    FluentFilter? after;
    for (;;) {
      final List<Map<String, dynamic>> page = await findMaps(where: after == null ? where : _scoped(where, after), columns: selected, orderBy: order, limit: _mirrorPageSize, includeExpired: true);
      for (final Map<String, dynamic> r in page) {
        if (_serverKeyOf(r) case final Object key when !answered.contains(_valuesKey(columns, [for (final String c in columns) stored(r[c])]))) missing.add(key);
      }
      if (page.length < _mirrorPageSize) return missing;
      final Map<String, dynamic> last = page.last;
      after = _afterCursor(FluentCursor(orderBy: keys.first, descending: false, value: stored(last[keys.first]), key: {for (final String k in keys) k: stored(last[k])}), keys.first, keys, false);
    }
  }
}
