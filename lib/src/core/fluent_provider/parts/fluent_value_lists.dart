// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// Long value lists of one task ([FluentFilter.ids], [FluentFilter.inList], [FluentFilter.notInList] with more values
/// than one statement may bind): each goes into a temporary table of the connection the task runs on, and the
/// statement compares with that table. Works on every SQLite version (old ones refuse more than 999 arguments), with
/// every key type, also on read-only connections (the TEMP schema is per connection and writable), and the values
/// never appear in the SQL text.
///
/// A zone value of [FluentProvider.internalExecute]: the filter is resolved first ([_FluentValueListsSql]), the code
/// that runs the statement fills the tables right before it ([_flushValueLists]), the tables are dropped when the task
/// ends. Inside a transaction they are created in it (a rollback drops them too).
class _FluentValueLists {
  static final Object _key = Object();
  static int _counter = 0;

  /// The lists of the running task, or `null` outside a task.
  static _FluentValueLists? get current => Zone.current[_key] as _FluentValueLists?;

  /// Lists of SQL built before its task runs (aggregate, ranked search: [_resolveDetached]), by table name; the task
  /// takes them over ([adoptFrom]) while the call is running.
  static final Map<String, ({String name, int width, List<Object?> values})> _detached = {};
  static final RegExp _names = RegExp(r'__fluent_list_\d+');

  /// Whether lists registered here are kept for a task that runs later.
  bool _keep = false;

  final List<({String name, int width, List<Object?> values})> _pending = [];
  final List<String> _created = [];

  bool get hasPending => _pending.isNotEmpty;

  /// Whether tables were created (and must be dropped when the task ends).
  bool get hasTables => _created.isNotEmpty;

  /// Registers [values] (stored values, [width] per row) and returns the table name the SQL may use.
  String add(int width, List<Object?> values) {
    final String name = '__fluent_list_${++_counter}';
    final ({String name, int width, List<Object?> values}) list = (name: name, width: width, values: values);
    _pending.add(list);
    if (_keep) _detached[name] = list;
    return name;
  }

  /// Creates and fills the pending tables on [db].
  Future<void> flush(DatabaseExecutor db) async {
    while (_pending.isNotEmpty) {
      final ({String name, int width, List<Object?> values}) list = _pending.removeAt(0);
      final String columns = [for (int i = 0; i < list.width; i++) _valueColumn(i)].join(', ');
      // IF NOT EXISTS + DELETE: a task that runs again on the same connection (a retry) starts from an empty table.
      await db.execute('CREATE TEMP TABLE IF NOT EXISTS ${list.name.quotedIdentifier} ($columns)');
      _created.add(list.name);
      await db.execute('DELETE FROM temp.${list.name.quotedIdentifier}');
      final int rowsPerInsert = math.max(1, FluentFilterInternals.maxListArguments ~/ list.width);
      final String row = '(${List.filled(list.width, '?').join(', ')})';
      final Batch batch = db.batch();
      for (int i = 0; i < list.values.length; i += rowsPerInsert * list.width) {
        final List<Object?> chunk = list.values.sublist(i, math.min(i + rowsPerInsert * list.width, list.values.length));
        batch.rawInsert('INSERT INTO temp.${list.name.quotedIdentifier} VALUES ${List.filled(chunk.length ~/ list.width, row).join(', ')}', chunk);
      }
      await batch.commit(noResult: true);
    }
  }

  /// Drops the tables of this task from [db] (best effort: a closed connection has none left).
  Future<void> drop(DatabaseExecutor db) async {
    for (final String name in _created) {
      try {
        await db.execute('DROP TABLE IF EXISTS temp.${name.quotedIdentifier}');
      } catch (_) {
        // The connection is gone or the transaction ended: the table went with it.
      }
    }
    _created.clear();
    _pending.clear();
  }

  /// Takes over the detached lists [sql] names.
  void adoptFrom(String? sql) {
    if (sql == null || !sql.contains('__fluent_list_')) return;
    for (final RegExpMatch m in _names.allMatches(sql)) {
      final ({String name, int width, List<Object?> values})? list = _detached[m[0]!];
      if (list != null && !_pending.contains(list)) _pending.add(list);
    }
  }

  static String _valueColumn(int i) => '__fluent_v$i'.quotedIdentifier;
}

/// SQL of long key and value lists ([_FluentValueLists]).
extension _FluentValueListsSql<T extends FluentStorable> on FluentProvider<T> {
  /// The key condition of [FluentFilter.ids]: bound arguments up to [FluentFilterInternals.maxListArguments], else a
  /// temporary table of the task (outside a task, where no table can be filled: the arguments, as newer SQLite
  /// versions take up to 32766).
  FluentFilter _idsSql(FluentKeyCondition keys) {
    final _FluentValueLists? lists = _FluentValueLists.current;
    if (keys.ids.length * primaryKeyColumns.length <= FluentFilterInternals.maxListArguments || lists == null) return _keysFilterOf(keys.ids);
    final List<FluentDbColumn> columns = primaryKeyColumns;
    final List<Object?> values = [];
    for (final Object? id in keys.ids) {
      final FluentKey key = _normalizeKey(id);
      if (!hasCompositeKey && key[columns.first.name] == null) throw _keyError(id, 'The key value is null.');
      for (final FluentDbColumn c in columns) {
        values.add(_filterValue(key[c.name], c.name));
      }
    }
    final String table = 'temp.${lists.add(columns.length, values).quotedIdentifier}';
    if (!hasCompositeKey) return FluentFilter('${columns.first.name.quotedIdentifier} IN (SELECT ${_FluentValueLists._valueColumn(0)} FROM $table)');
    // `IS` also matches a NULL part of a composite key, like the `IS NULL` of a short list.
    final String match = [for (int i = 0; i < columns.length; i++) '${columns[i].name.quotedIdentifier} IS ${_FluentValueLists._valueColumn(i)}'].join(' AND ');
    return FluentFilter('EXISTS (SELECT 1 FROM $table WHERE $match)');
  }

  /// A long [FluentFilter.inList] / [FluentFilter.notInList] as a comparison with a temporary table of the task
  /// (outside a task: bound arguments).
  FluentFilter _listSql(FluentListCondition list) {
    final _FluentValueLists? lists = _FluentValueLists.current;
    final String placeholders = List.filled(list.values.length, '?').join(', ');
    final String operator = list.negated ? 'NOT IN' : 'IN';
    final String column = list.column.quotedIfPlain;
    if (lists == null) return FluentFilter('$column $operator ($placeholders)', list.values);
    final String table = lists.add(1, _sqlArgs(list.values) ?? const []);
    return FluentFilter('$column $operator (SELECT ${_FluentValueLists._valueColumn(0)} FROM temp.${table.quotedIdentifier})');
  }

  /// [filter] resolved outside a task, for SQL that a task runs later: its long lists stay available to that task
  /// until [release] (call it when the call completed).
  ({FluentFilter filter, void Function() release}) _resolveDetached(FluentFilter filter) {
    if (filter.deferred.isEmpty) return (filter: filter, release: () {});
    final _FluentValueLists lists = _FluentValueLists().._keep = true;
    final FluentFilter resolved = runZoned(() => _resolveRelated(filter), zoneValues: {_FluentValueLists._key: lists});
    final List<String> names = [for (final l in lists._pending) l.name];
    return (filter: resolved, release: () => names.forEach(_FluentValueLists._detached.remove));
  }

  /// Fills the temporary tables the filters resolved so far need, on [db] (default: the task's connection). Code that
  /// resolves a filter itself ([_resolveRelated]) and runs it calls this before the statement.
  Future<void> _flushValueLists([DatabaseExecutor? db]) async {
    final _FluentValueLists? lists = _FluentValueLists.current;
    if (lists != null && lists.hasPending) await lists.flush(db ?? executor);
  }
}
