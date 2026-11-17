// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../core/fluent_sqlite_internal.dart';

/// One call on a table, as the engine schedules and runs it: what to do ([action], [helper], [data]), which relations
/// a read loads ([maxDepth], [ignoreLazy]), how it is scheduled ([policy]) and the [tag] of its change events.
///
/// The values the engine derives from it ([fingerprint], [staticWeight], [costKey]) are computed on first use and
/// once per instance: a task is copied a few times on its way (table, policy, id), and most copies never need them.
class FluentTask {
  /// Creates a task.
  FluentTask({
    this.id = 0,
    this.table = '',
    this.dbName = '',
    required this.action,
    this.data,
    this.maxDepth = 1,
    this.ignoreLazy = false,
    this.helper,
    this.policy = const ExecutionPolicy(),
    this.tag,
    this.executionWeight = 0,
    this.mergedTasks,
  });

  /// Identifies the queued call (set by the engine).
  final int id;

  /// The table of the call.
  final String table;

  /// The database of [table].
  final String dbName;

  /// What the call does.
  final FluentDbAction action;

  /// The payload: models to write, or the body of a relation operation / transaction.
  final dynamic data;

  /// How many relation levels a read loads; 0 loads none (`FluentLoad.none`).
  final int maxDepth;

  /// Whether a read also loads the `lazy` relations (`FluentLoad.all`).
  final bool ignoreLazy;

  /// The condition, order, paging, SQL and write options of the call.
  final TableHelper? helper;

  /// Priority and read collapsing.
  final ExecutionPolicy policy;

  /// The `tag:` of the call, carried to its change events (`FluentChangeEvent.tag`).
  final Object? tag;

  /// The weight the scheduler orders reads by (static weight + measured cost), set when the task is queued.
  int executionWeight;

  /// Engine clock (ms) when the task entered the queue; used for aging.
  int enqueuedAt = 0;

  /// The calls merged into this one (adjacent saves, `findById` lookups); `null` for a single call.
  final List<FluentTask>? mergedTasks;

  /// Whether this task carries several merged calls.
  bool get isBatched => mergedTasks != null && mergedTasks!.isNotEmpty;

  /// Identifies identical reads: two reads with the same fingerprint (and no write between them) return the same rows.
  late final String fingerprint = _calculateFingerprint();

  /// The base cost of the task, from its action and shape (the scheduler adds the measured cost).
  late final int staticWeight = _calculateStaticWeight();

  /// The key of the task's query shape in the cost model (`FluentTableStatsTracker.keyOf`).
  late final String costKey = FluentTableStatsTracker.keyOf(this);

  /// A copy with the given values replaced (the derived values are computed again when needed).
  FluentTask copyWith({
    int? id,
    String? table,
    String? dbName,
    dynamic data,
    TableHelper? helper,
    ExecutionPolicy? policy,
    List<FluentTask>? mergedTasks,
  }) => FluentTask(
    id: id ?? this.id,
    table: table ?? this.table,
    dbName: dbName ?? this.dbName,
    action: action,
    data: data ?? this.data,
    maxDepth: maxDepth,
    ignoreLazy: ignoreLazy,
    helper: helper ?? this.helper,
    policy: policy ?? this.policy,
    tag: tag,
    executionWeight: executionWeight,
    mergedTasks: mergedTasks ?? this.mergedTasks,
  );

  /// Whether the call changes data.
  bool get isWriteOp => action.isWriteOp;

  /// Whether the call publishes a change event (raw SQL only when it changes rows).
  bool get isStreamOp => action.isStreamOp || (action == FluentDbAction.execute && _changesData(helper?.sql));

  /// Whether raw SQL changes rows (INSERT / UPDATE / DELETE / REPLACE): such `execute` calls publish an event,
  /// DDL and PRAGMA do not.
  ///
  /// Leading comments are skipped; for `WITH` the statement after the common table expressions decides (words
  /// inside their parentheses or in string literals do not count).
  static bool _changesData(String? sql) {
    if (sql == null) return false;
    String head = sql.replaceAll(_comments, ' ').replaceAll(_literals, "''").trimLeft().toUpperCase();
    if (head.startsWith('WITH')) {
      for (String inner = head; ; inner = head) {
        head = head.replaceAll(_innermostParens, ' ');
        if (head == inner) break;
      }
      return RegExp(r'\b(INSERT|UPDATE|DELETE|REPLACE)\b').hasMatch(head);
    }
    return head.startsWith('INSERT') || head.startsWith('UPDATE') || head.startsWith('DELETE') || head.startsWith('REPLACE');
  }

  static final RegExp _comments = RegExp(r'--[^\n]*|/\*.*?\*/', dotAll: true);
  static final RegExp _literals = RegExp(r"'(?:[^']|'')*'");
  static final RegExp _innermostParens = RegExp(r'\([^()]*\)');

  /// Everything that decides the rows a read returns; argument types are included so `1` and `'1'` differ, and
  /// deferred conditions (ids, search, related) with every value of theirs ([FluentDeferredCondition.fingerprint]).
  String _calculateFingerprint() {
    final StringBuffer sb = StringBuffer('$dbName:$table:${action.name}:$maxDepth:$ignoreLazy:');
    final TableHelper? h = helper;
    if (h != null) {
      sb.write('${fluentValueKey(h.id)}_${h.where}_${h.orderBy}_${h.limit}_${h.offset}_${h.sql}_${h.columns}_${h.distinct}_');
      for (final FluentDeferredCondition c in h.deferred ?? const <FluentDeferredCondition>[]) {
        sb.write('${c.fingerprint};');
      }
      sb.write('_');
      for (final Object? arg in h.whereArgs ?? const []) {
        sb.write('${fluentValueKey(arg)},');
      }
      sb.write('_');
      for (final Object? arg in h.arguments ?? const []) {
        sb.write('${fluentValueKey(arg)},');
      }
    }
    if (action.isWriteOp && data != null) sb.write('${identityHashCode(data)}:');
    return sb.toString();
  }

  /// The base cost: the action, the paging and order, the relation levels.
  int _calculateStaticWeight() {
    int w = switch (action) {
      FluentDbAction.findById || FluentDbAction.exists || FluentDbAction.restore => 10,
      FluentDbAction.update || FluentDbAction.save => 25,
      FluentDbAction.count ||
      FluentDbAction.updateFields ||
      FluentDbAction.delete ||
      FluentDbAction.hardDelete ||
      FluentDbAction.find ||
      FluentDbAction.findMaps ||
      FluentDbAction.rawQuery => 40,
      FluentDbAction.clearTable || FluentDbAction.clearExpired || FluentDbAction.purgeDeleted || FluentDbAction.wipeAll => 100,
      FluentDbAction.execute || FluentDbAction.transaction => 150,
      _ => 30,
    };
    final TableHelper? h = helper;
    final int? limit = h?.limit;
    if (limit != null) {
      w += limit <= 100 ? -15 : 10;
    } else if (action == FluentDbAction.find) {
      // An unbounded find (no helper at all, or a helper without a limit) may read the whole table.
      w += 40;
    }
    if (h?.orderBy != null) w += 20;
    // Relation levels cost queries; depth 0 (no relations) costs nothing extra.
    if (maxDepth > 1) w += maxDepth * 30;
    if (ignoreLazy) w += 20;
    return w;
  }

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentTask{id: $id, table: $table, action: ${action.name}');
    if (dbName.isNotEmpty) sb.write(', dbName: $dbName');
    if (maxDepth != 1) sb.write(', maxDepth: $maxDepth');
    if (ignoreLazy) sb.write(', ignoreLazy: true');
    if (helper != null) sb.write(', helper: $helper');
    if (policy != const ExecutionPolicy()) sb.write(', policy: $policy');
    if (tag != null) sb.write(', tag: $tag');
    if (isBatched) sb.write(', merged: ${mergedTasks!.length}');
    sb.write(', weight: $staticWeight/$executionWeight}');
    return sb.toString();
  }
}
