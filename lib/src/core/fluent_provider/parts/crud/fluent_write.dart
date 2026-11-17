// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Writing: save (insert / update), update of whole models, and field updates by key or filter.
///
/// Each call is atomic: it runs in its own transaction, or as a savepoint inside an open `FluentDb.transaction`.
/// Only `delete` / `restore` move rows to and from the trash, with one exception: `upsert` / `insertOnly` saves of a
/// key (or `conflictOn` values) whose row is in the trash bring that row back (outcome `restored`).
extension FluentWrite<T extends FluentStorable> on FluentProvider<T> {
  /// Saves [item] with its relations (see [saveAll]).
  ///
  /// ```dart
  /// final FluentSaveResult r = await users.save(user); // user.id now holds the generated key
  /// await users.save(user, strategy: FluentSaveStrategy.patch); // null fields keep their stored values
  /// ```
  Future<FluentSaveResult> save(
    T item, {
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) => saveAll([item], strategy: strategy, conflictOn: conflictOn, relationSync: relationSync, tag: tag, policy: policy);

  /// Saves [items] with their relations in one transaction; returns what happened to each item.
  ///
  /// * [strategy]: `upsert` (default) inserts new rows and updates existing ones; `insertOnly` skips existing rows;
  ///   `updateOnly` skips missing rows; `patch` updates existing rows but leaves `null` fields untouched.
  /// * [conflictOn]: identify existing rows by these (unique) columns instead of the key, e.g. a server id. The
  ///   stored key is kept and written back into the models. Unknown columns throw [FluentArgumentException]; columns
  ///   without a UNIQUE constraint are reported (`conflictOn` issue).
  /// * [relationSync]: `replace` removes related rows missing from the lists, `preserveLocal` keeps them
  ///   (default: each relation's `keepMissing`).
  /// * [tag] marks the change events (`FluentDb.onEvent(tag: ...)`), e.g. to tell server updates from user edits.
  ///
  /// [strategy] and [conflictOn] apply to [items] only: related models are always upserted by their key, and a
  /// reference whose target could not be saved keeps its stored value. Soft delete: a row in the trash (matched by
  /// the key or by `conflictOn`, a live row winning over a trashed one) is brought back by `upsert` / `insertOnly`
  /// (outcome `restored`; a row whose owner is still in the trash stays there, `skipped`) and skipped by
  /// `updateOnly` / `patch`. The same model (or key) twice in one call is written once: the last one wins, the first
  /// for `insertOnly`. Expired rows (`timeToLive` passed, hidden from reads) count as missing for `updateOnly` /
  /// `patch` (skipped); `insertOnly` writes over them (outcome `inserted`) and `upsert` updates them (renewed by the
  /// model's `timeToLive`).
  ///
  /// Generated keys are written back into the models. A conflict on another UNIQUE column throws
  /// [FluentConstraintException] (`FluentErrorCode.uniqueViolation`) instead of losing the row.
  ///
  /// ```dart
  /// final FluentSaveResult r = await users.saveAll(fromServer, conflictOn: ['server_id']);
  /// print('${r.inserted} new, ${r.updated} updated, ${r.skipped} skipped');
  /// ```
  Future<FluentSaveResult> saveAll(
    Iterable<T> items, {
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final List<T> list = items.toList(growable: false);
    if (list.isEmpty) return FluentSaveResult.empty;
    _checkConflictOn(conflictOn);
    final List<FluentRowOutcome> outcomes = await _run<List<FluentRowOutcome>>(
      FluentDbAction.save,
      data: list,
      helper: TableHelper(saveStrategy: strategy, conflictOn: conflictOn, syncMode: relationSync),
      policy: policy,
      tag: tag,
    );
    return FluentSaveResult(outcomes);
  }

  /// Updates the stored row of [item] (see [updateAll]); returns 1 when it exists, 0 otherwise.
  ///
  /// ```dart
  /// user.name = 'Ann';
  /// if (await users.update(user) == 0) print('not stored (or in the trash)');
  /// ```
  Future<int> update(T item, {bool withRelations = false, FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      updateAll([item], withRelations: withRelations, syncMode: syncMode, tag: tag, policy: policy);

  /// Updates the stored rows of [items] (strategy `updateOnly`, never inserts); items without a stored row, with
  /// their row in the trash or with an expired row (`timeToLive` passed: reads no longer see it) are skipped. Returns
  /// the number of updated rows. To renew an expired row, [save] it.
  ///
  /// With [withRelations] the related models are saved too (upserted): [syncMode] `preserveLocal` (default) keeps
  /// related rows missing from the lists, `replace` removes them.
  ///
  /// ```dart
  /// await articles.updateAll(edited, withRelations: true, syncMode: FluentRelationSyncMode.replace);
  /// ```
  Future<int> updateAll(
    Iterable<T> items, {
    bool withRelations = false,
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
  }) async {
    final List<T> list = items.toList(growable: false);
    if (list.isEmpty) return 0;
    final List<FluentRowOutcome> outcomes = await _run<List<FluentRowOutcome>>(
      FluentDbAction.update,
      data: list,
      helper: TableHelper(saveStrategy: FluentSaveStrategy.updateOnly, syncMode: withRelations ? syncMode : null),
      policy: policy,
      tag: tag,
    );
    return outcomes.where((o) => o == FluentRowOutcome.updated).length;
  }

  /// Sets [fields] (column → Dart value, or a [FluentUpdate] computed by SQLite) on the row with key [id]; returns 1
  /// when it exists, 0 otherwise — like [FluentRead.findById]: a row in the trash or one whose `timeToLive` has
  /// passed counts as missing ([includeExpired]: expired rows are updated too; their expiry stays as it is).
  ///
  /// Values are converted like on save; the updated-at time of `FluentTimestamps` models is set. Unknown or key
  /// columns and the columns the library keeps (soft delete, sync versions, expiry, `_fs_metadata`, archived
  /// columns) throw [FluentArgumentException].
  ///
  /// ```dart
  /// await users.updateById(42, {'last_login': DateTime.now(), 'active': true});
  /// await posts.updateById(7, {'views': FluentUpdate.increment(1)});
  /// ```
  Future<int> updateById(Object? id, Map<String, Object?> fields, {bool includeExpired = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (id == null || fields.isEmpty) return 0;
    return _run<int>(FluentDbAction.updateFields, helper: _helperFor(_updatable(keyFilter(id), includeExpired), dataMap: fields), policy: policy, tag: tag);
  }

  /// Sets [fields] on every row matching [where] that reads see (not in the trash; not expired unless
  /// [includeExpired]); returns the number of updated rows. Values and errors as in [updateById].
  ///
  /// ```dart
  /// await orders.updateWhere(FluentFilter.eq('status', 'new'), {'status': 'cancelled'});
  /// ```
  Future<int> updateWhere(FluentFilter where, Map<String, Object?> fields, {bool includeExpired = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    if (fields.isEmpty) return 0;
    return _run<int>(FluentDbAction.updateFields, helper: _helperFor(_updatable(where, includeExpired), dataMap: fields), policy: policy, tag: tag);
  }

  /// [where] narrowed to the rows field updates reach: never rows in the trash (whatever the trash scope of the
  /// call), expired rows only with [includeExpired].
  FluentFilter _updatable(FluentFilter where, bool includeExpired) =>
      _scoped(where, _visibility(includeExpired: includeExpired, deletedOnly: false, includeDeleted: false));
}
