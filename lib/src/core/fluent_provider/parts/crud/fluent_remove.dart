// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Deleting and restoring.
///
/// For models `with FluentSoftDeletable` a delete only marks the row (its owned soft-deletable children are marked
/// with the same stamp, and come back with it on restore); `trash.deleteForever` removes rows permanently. Models
/// without soft delete are always removed permanently. Permanent deletes follow the relation rules (owned rows and
/// links are removed, references are cleared, `oneOf` references pointing to the rows are deleted or cleared) and
/// leave sync tombstones for the removed rows of syncable tables, at any depth. Each call is atomic (its own
/// transaction, or a savepoint inside `FluentDb.transaction`).
extension FluentRemove<T extends FluentStorable> on FluentProvider<T> {
  /// Deletes [item]; returns 1 when a row was deleted, 0 otherwise.
  ///
  /// Models with [FluentSoftDeletable] go to the trash (`trash.restore` brings them back, `trash.deleteForever`
  /// removes them for good); other models are removed permanently. [tag] marks the change event.
  ///
  /// Afterwards `item.deletedAt` holds the stamp stored for the row (a row already in the trash keeps its first
  /// stamp and returns 0); a model without a stored row keeps its `deletedAt`. The model changes once the write is
  /// committed: inside a `FluentDb.transaction` that rolls back, it keeps its old `deletedAt`.
  ///
  /// ```dart
  /// await notes.delete(note); // note.isDeleted == true
  /// await notes.trash.restore(note);
  /// ```
  Future<int> delete(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => deleteAll([item], tag: tag, policy: policy);

  /// Deletes the rows of [items] (see [delete], also for `deletedAt`); returns the number of deleted rows.
  Future<int> deleteAll(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) =>
      _removeItems(items.toList(growable: false), hard: false, tag: tag, policy: policy);

  /// Deletes the row with key [id] (see [delete]); returns 1 when a row was deleted, 0 otherwise.
  Future<int> deleteById(Object? id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      id == null ? 0 : _remove(TableHelper(arguments: [id]), hard: false, tag: tag, policy: policy);

  /// Deletes the rows matching [where] (see [delete]); returns the number of deleted rows.
  ///
  /// ```dart
  /// await notes.deleteWhere(FluentFilter.eq('archived', true));
  /// ```
  Future<int> deleteWhere(FluentFilter where, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async =>
      _remove(_helperFor(where), hard: false, tag: tag, policy: policy);

  /// Permanently removes rows whose time to live (`FluentStorable.timeToLive`) has passed; returns their number.
  /// Reads hide them anyway; this frees the space (it also runs at start). Local clean-up: no sync tombstones.
  Future<int> clearExpired({Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => _run<int>(FluentDbAction.clearExpired, policy: policy, tag: tag);

  /// Permanently removes all rows of the table (trashed ones too); returns their number.
  ///
  /// Local only: no sync tombstones, the server keeps its rows. The sync / fetch state of the table is reset, so the
  /// next `syncWithServer` pulls everything again and `watchRemote` fetches again.
  ///
  /// Syncable tables: rows with local changes the server never received are discarded too, and a warning
  /// (`unsentChangesDiscarded`) names how many. Run `syncWithServer` first to keep those changes.
  Future<int> clearTable({Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) => _run<int>(FluentDbAction.clearTable, policy: policy, tag: tag);
}

/// Deleting by keys / filter, to the trash or for good (shared by [FluentRemove] and the trash view).
extension _FluentRemoveRows<T extends FluentStorable> on FluentProvider<T> {
  /// Soft-deletes (tables with soft delete, unless [hard]) or removes the rows of [items]; the soft delete sets their
  /// `deletedAt` (see [_applyDeleteStamps]).
  Future<int> _removeItems(List<T> items, {required bool hard, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final List<Object> ids = [for (final T item in items) ?(item.primaryKeyValue as Object?)];
    if (ids.isEmpty) return 0;
    final bool soft = !hard && _softDeleteColumn != null;
    return _run<int>(soft ? FluentDbAction.delete : FluentDbAction.hardDelete, data: items, helper: TableHelper(arguments: ids), policy: policy, tag: tag);
  }

  /// The stored soft-delete stamps of the rows among [ids] (by [_tupleKey]); rows not found are missing.
  Future<Map<String, DateTime?>> _storedDeleteStamps(DatabaseExecutor ex, List<Object> ids) async {
    final String column = _softDeleteColumn!;
    final Map<String, DateTime?> found = {};
    await _forKeyChunks(ids, (keys) async {
      final List<Map<String, Object?>> rows = await ex.query(tableName.quotedIdentifier, columns: [...keyColumnNames, column].quotedAll, where: keys.whereClause, whereArgs: _sqlArgs(keys.whereArgs));
      for (int i = 0; i < rows.length; i++) {
        final Object? stamp = _decodeMaps([rows[i]]).first[column];
        found[_tupleKey(_normalizeKey(_dartIdOf(rows[i])))] = stamp is DateTime ? stamp : null;
      }
      return 0;
    });
    return found;
  }

  /// Gives the models the stamp that is stored for their rows (`null` for a live row); models without a row keep
  /// their `deletedAt`. [items] may be typed by a base type (`FluentDb.deleteAll`): models without soft delete are
  /// skipped.
  void _applyDeleteStamps(List<FluentStorable> items, Map<String, DateTime?> stamps) {
    for (final FluentStorable item in items) {
      final Object? id = item.primaryKeyValue;
      if (id == null || item is! FluentSoftDeletable) continue;
      final String key = _tupleKey(_normalizeKey(id));
      if (stamps.containsKey(key)) item.deletedAt = stamps[key];
    }
  }

  /// Soft-deletes (unless [hard]) or removes the rows of [helper] (keys in `arguments`, or a condition).
  Future<int> _remove(TableHelper helper, {required bool hard, Object? tag, ExecutionPolicy policy = const ExecutionPolicy()}) async {
    final bool soft = !hard && _softDeleteColumn != null;
    return _run<int>(soft ? FluentDbAction.delete : FluentDbAction.hardDelete, helper: helper, policy: policy, tag: tag);
  }
}
