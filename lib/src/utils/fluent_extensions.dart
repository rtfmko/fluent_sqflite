// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../core/core.dart';
import '../interfaces/interfaces.dart';
import '../models/models.dart';
import '../relations/relations.dart';
import '../soft_delete/soft_delete.dart';
import 'utils.dart';

/// Reading typed values from raw JSON maps (internal: hidden from the public API).
extension FluentJsonExtension on Map<String, dynamic> {
  /// Attempts to extract a [DateTime] from the map by the given [key].
  ///
  /// This method is flexible and supports:
  /// * **int**: Interpreted as milliseconds since epoch.
  /// * **String**: Interpreted as an ISO 8601 formatted date.
  ///
  /// Returns `null` if the key is missing, the value is `null`, or the
  /// format is unrecognized.
  ///
  /// ```dart
  /// final Map<String, dynamic> json = {'created_at': 1777755600000, 'updated_at': '2026-05-03T12:00:00Z'};
  /// final DateTime? created = json.tryGetDateTime('created_at');
  /// final DateTime? updated = json.tryGetDateTime('updated_at');
  /// ```
  DateTime? tryGetDateTime(String key) {
    final dynamic value = this[key];
    if (value == null) return null;

    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }
}

/// ANSI colors for the library's console logs (internal: hidden from the public API).
extension FluentColorStrings on String {
  // ANSI Escape Sequences for terminal colors
  static const _reset = '\x1B[0m'; // Resets the color to default
  static const _red = '\x1B[31m'; // Errors and critical failures
  static const _green = '\x1B[32m'; // Success and completed operations
  static const _yellow = '\x1B[33m'; // Warnings and non-critical alerts
  static const _cyan = '\x1B[36m'; // Info, tags, and system messages
  static const _magenta = '\x1B[35m'; // SQL executor
  static const _gold = '\x1B[93m'; // Hints color

  /// Wraps the string in ANSI red color.
  String get red => '$_red$this$_reset';

  /// Wraps the string in ANSI green color.
  String get green => '$_green$this$_reset';

  /// Wraps the string in ANSI yellow color.
  String get yellow => '$_yellow$this$_reset';

  /// Wraps the string in ANSI cyan color.
  String get cyan => '$_cyan$this$_reset';

  /// Wraps the string in ANSI magenta color.
  String get magenta => '$_magenta$this$_reset';

  /// Wraps the string in ANSI gold color.
  String get gold => '$_gold$this$_reset';
}

/// Log formatting of [DateTime] (internal: hidden from the public API).
extension FluentDateTimeX on DateTime {
  /// A fixed-width local time `HH:mm:ss.mmm` for log lines, e.g. `05:46:24.123`.
  String get toFluentTimestamp =>
      "${hour.toString().padLeft(2, '0')}:"
      "${minute.toString().padLeft(2, '0')}:"
      "${second.toString().padLeft(2, '0')}."
      "${millisecond.toString().padLeft(3, '0')}";
}

/// How unset values of a policy are inherited (call → provider → `FluentConfig.defaultPolicy` → defaults).
extension ExecutionPolicyUtils on ExecutionPolicy {
  /// The defaults every policy falls back to: priority 0, duplicates collapsed.
  static const ExecutionPolicy defaults = ExecutionPolicy(priority: 0, cancelIfDuplicate: true);

  /// The priority, `0` when not set.
  int get effectivePriority => priority ?? 0;

  /// This policy with unset values taken from [parent].
  ExecutionPolicy merge(ExecutionPolicy? parent) {
    if (parent == null) return this;
    return ExecutionPolicy(priority: priority ?? parent.priority, cancelIfDuplicate: cancelIfDuplicate ?? parent.cancelIfDuplicate);
  }

  /// This policy with unset values taken from [defaults].
  ExecutionPolicy flatten() => merge(defaults);
}


/// Calls on a model itself: `await user.save()`, `await user.delete()`, `final posts = await comment.findParents<Post>()`.
///
/// Each call finds the provider by the model's type (see the matching `FluentDb` method); pass a [FluentDbKey] as
/// `dbKey` when the type is stored in several databases (otherwise `FluentConfigException` with
/// `FluentErrorCode.ambiguousProvider`). Models with [FluentSoftDeletable] also get `restore` / `deleteForever`
/// ([FluentTrashRecords]), models with [FluentRelations] the relation calls ([FluentRelationRecords]).
extension FluentActiveRecords<T extends FluentStorable> on T {
  /// Saves this model with its relations (see [FluentWrite.saveAll] for [strategy], [conflictOn], [relationSync]).
  ///
  /// ```dart
  /// await user.save();
  /// await user.save(strategy: FluentSaveStrategy.patch, tag: 'profile-edit');
  /// ```
  Future<FluentSaveResult> save({
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => FluentDb.save<T>(this, strategy: strategy, conflictOn: conflictOn, relationSync: relationSync, tag: tag, policy: policy, dbKey: dbKey);

  /// Updates the stored row of this model, never inserts (see [FluentWrite.updateAll]); returns 1 or 0.
  ///
  /// ```dart
  /// await article.update(withRelations: true, syncMode: FluentRelationSyncMode.replace);
  /// ```
  Future<int> update({
    bool withRelations = false,
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => FluentDb.update<T>(this, withRelations: withRelations, syncMode: syncMode, tag: tag, policy: policy, dbKey: dbKey);

  /// Whether this model's row is stored and visible (not in the trash; not expired unless [includeExpired]).
  Future<bool> exists({bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      FluentDb.exists<T>(primaryKeyValue, includeExpired: includeExpired, policy: policy, dbKey: dbKey);

  /// Deletes this model (see [FluentRemove.delete]): to the trash for [FluentSoftDeletable] models (then `deletedAt`
  /// holds the stored stamp), for good otherwise. Returns 1 or 0.
  ///
  /// ```dart
  /// await note.delete();
  /// await note.restore();
  /// ```
  Future<int> delete({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      FluentDb.delete<T>(this, tag: tag, policy: policy, dbKey: dbKey);

  /// A fresh copy of this model from the database, or `null` when it is gone (or in the trash, or expired);
  /// [relations] says which relations load.
  Future<T?> refresh({FluentLoad relations = FluentLoad.eager, int maxDepth = 1, FluentDbKey? dbKey}) =>
      FluentDb.findById<T>(primaryKeyValue, relations: relations, maxDepth: maxDepth, dbKey: dbKey);

  /// The models [P] whose relation points to this model (see [FluentDb.findParents]): the article of a comment, the
  /// articles of a tag. [via] names the relation when [P] has several to this model.
  ///
  /// ```dart
  /// final Article? article = (await comment.findParents<Article>()).firstOrNull;
  /// ```
  Future<List<P>> findParents<P extends FluentRelations>({
    String? via,
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    FluentDbKey? dbKey,
  }) => FluentDb.findParents<P>(this, via: via, where: where, orderBy: orderBy, limit: limit, offset: offset, relations: relations, maxDepth: maxDepth, dbKey: dbKey);
}

/// Calls on a model with [FluentSoftDeletable]: `await note.restore()`, `await note.deleteForever()`.
extension FluentTrashRecords<T extends FluentSoftDeletable> on T {
  /// Brings this model back from the trash and clears `deletedAt` (see [FluentTrash.restore]); returns 1 or 0.
  Future<int> restore({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) => FluentDb.trash<T>(dbKey: dbKey).restore(this, tag: tag, policy: policy);

  /// Removes this model permanently, live or trashed (see [FluentTrash.deleteForever]); returns 1 or 0.
  Future<int> deleteForever({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      FluentDb.trash<T>(dbKey: dbKey).deleteForever(this, tag: tag, policy: policy);
}

/// Calls on a model with [FluentRelations]: load its relations later, query or count them, add and remove links.
///
/// ```dart
/// final Article bare = (await FluentDb.findById<Article>(1, relations: FluentLoad.none))!;
/// final Article full = await bare.loadRelations();            // every relation, lazy ones too
/// final List<Comment> top = await full.findRelated<Comment>('comments', orderBy: 'likes DESC', limit: 3);
/// ```
extension FluentRelationRecords<T extends FluentRelations> on T {
  /// A copy of this model with its relations loaded (see [FluentDb.loadRelations]); [names]: only these besides the
  /// eager ones, empty: all of them.
  Future<T> loadRelations({List<String> names = const [], int maxDepth = 1, FluentDbKey? dbKey}) => FluentDb.loadRelations<T>(this, names: names, maxDepth: maxDepth, dbKey: dbKey);

  /// The models of relation [name], queried with a filter, order and paging (see [FluentDb.findRelated]).
  Future<List<R>> findRelated<R extends FluentStorable>(
    String name, {
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    FluentDbKey? dbKey,
  }) => FluentDb.findRelated<T, R>(this, name, where: where, orderBy: orderBy, limit: limit, offset: offset, relations: relations, maxDepth: maxDepth, dbKey: dbKey);

  /// Number of models of relation [name], without loading them (see [FluentDb.countRelated]).
  Future<int> countRelated(String name, {FluentDbKey? dbKey}) => FluentDb.countRelated<T>(this, name, dbKey: dbKey);

  /// Adds [related] to relation [name] (see [FluentDb.attach]).
  Future<void> attach(String name, List<FluentStorable> related, {FluentStorable Function(FluentStorable related)? link, FluentDbKey? dbKey}) =>
      FluentDb.attach<T>(this, name, related, link: link, dbKey: dbKey);

  /// Removes [related] from relation [name] (see [FluentDb.detach]).
  Future<void> detach(String name, List<FluentStorable> related, {FluentDbKey? dbKey}) => FluentDb.detach<T>(this, name, related, dbKey: dbKey);
}

/// Calls on collections of models: `await users.saveAll()`.
extension FluentStorableCollectionX<T extends FluentStorable> on Iterable<T> {
  /// Saves the models with their relations (see [FluentWrite.saveAll]).
  ///
  /// ```dart
  /// final FluentSaveResult r = await fromServer.saveAll(conflictOn: ['server_id']);
  /// ```
  Future<FluentSaveResult> saveAll({
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => FluentDb.saveAll<T>(this, strategy: strategy, conflictOn: conflictOn, relationSync: relationSync, tag: tag, policy: policy, dbKey: dbKey);

  /// Updates the stored rows of the models, never inserts (see [FluentWrite.updateAll]); returns the number updated.
  Future<int> updateAll({
    bool withRelations = false,
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => FluentDb.updateAll<T>(this, withRelations: withRelations, syncMode: syncMode, tag: tag, policy: policy, dbKey: dbKey);

  /// Deletes the models (see [FluentRemove.delete]); returns the number of deleted rows.
  Future<int> deleteAll({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      FluentDb.deleteAll<T>(this, tag: tag, policy: policy, dbKey: dbKey);
}
