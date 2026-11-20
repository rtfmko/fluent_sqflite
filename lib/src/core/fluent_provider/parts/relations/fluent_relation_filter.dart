// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../fluent_provider.dart';

/// Aliases of the subqueries of one resolved filter (`"_r0"`, `"_l1"`, ...), unique within the statement.
class _AliasCounter {
  int _next = 0;

  String take(String prefix) => '"_$prefix${_next++}"';
}

/// Conditions on related models ([FluentFilter.related], [FluentFilter.notRelated], [FluentFilter.relatedCount]):
/// turned into `EXISTS` / `COUNT` subqueries when the task runs, from the resolved relation graph.
///
/// Every subquery reads its table under its own alias, so the caller's unqualified columns refer to the related
/// table (the innermost one) and a relation of a model to itself works. Related rows hidden from relation loads
/// (trash, expired) and rows outside the relation's own `where` never count.
extension _FluentRelationFilter<T extends FluentStorable> on FluentProvider<T> {
  /// [task] with the deferred conditions of its filter (related models, search) written out as SQL.
  FluentTask _withDeferredResolved(FluentTask task) {
    final TableHelper h = task.helper!;
    final FluentFilter resolved = _resolveClause(h.where ?? '', h.whereArgs ?? const [], h.deferred!, tableName.quotedIdentifier, _AliasCounter());
    // The helper's own arguments are stored values already; the resolved conditions bring Dart values (keys).
    return task.copyWith(helper: h.copyWith(where: resolved.whereClause, whereArgs: _sqlArgs(resolved.whereArgs), deferred: const []));
  }

  /// [filter] with its related conditions written out as SQL; [outer] is how the statement names this table.
  /// The arguments keep their columns: pass them through [_sqlArgs] before they reach SQLite.
  FluentFilter _resolveRelated(FluentFilter filter, [String? outer, _AliasCounter? aliases]) => filter.deferred.isEmpty
      ? filter
      : _resolveClause(filter.whereClause, filter.whereArgs, filter.deferred, outer ?? tableName.quotedIdentifier, aliases ?? _AliasCounter());

  FluentFilter _resolveClause(String clause, List<Object?> args, List<FluentDeferredCondition> conditions, String outer, _AliasCounter aliases) {
    final List<Object?> raw = FluentFilterArgs.rawOf(args);
    String? columnAt(int i) => args is FluentFilterArgs ? args.columnAt(i) : null;
    final StringBuffer sql = StringBuffer();
    final List<Object?> out = [];
    final List<String?> outColumns = [];
    void take(int from, int to) {
      if (to > raw.length) {
        throw FluentLog.raise(
          FluentArgumentException(
            'whereArgs',
            'A filter of "$tableName" has more "?" placeholders than arguments (${raw.length} argument(s), at least $to needed), so its related / search / ids conditions cannot be placed.',
            hint: "Give one argument for every '?' of a hand-written FluentFilter(sql, args), e.g. FluentFilter('\"title\" = ?', ['x']).",
          ),
          tag: '$tableName:related',
        );
      }
      for (int i = from; i < to; i++) {
        out.add(raw[i]);
        outColumns.add(columnAt(i));
      }
    }

    int argIndex = 0;
    int pos = 0;
    for (final RegExpMatch m in FluentFilterInternals.marker.allMatches(clause)) {
      final String text = clause.substring(pos, m.start);
      final int placeholders = _placeholders(text);
      sql.write(text);
      take(argIndex, argIndex + placeholders);
      argIndex += placeholders;
      final FluentFilter condition = switch (conditions[int.parse(m[1]!)]) {
        final FluentRelatedCondition related => _relatedSql(related, outer, aliases),
        final FluentSearchCondition search => _searchSql(search, outer),
        final FluentKeyCondition keys => _idsSql(keys),
        final FluentListCondition list => _listSql(list),
      };
      sql.write(condition.whereClause);
      final List<Object?> conditionArgs = condition.whereArgs;
      for (int i = 0; i < conditionArgs.length; i++) {
        out.add(FluentFilterArgs.rawOf(conditionArgs)[i]);
        outColumns.add(conditionArgs is FluentFilterArgs ? conditionArgs.columnAt(i) : null);
      }
      pos = m.end;
    }
    sql.write(clause.substring(pos));
    take(argIndex, raw.length);
    return FluentFilter(sql.toString(), FluentFilterArgs(out, outColumns.every((c) => c == null) ? const [] : outColumns));
  }

  /// The `?` placeholders in [sql], outside string literals, quoted identifiers and comments.
  static int _placeholders(String sql) {
    int count = 0;
    int i = 0;
    while (i < sql.length) {
      final String c = sql[i];
      if (c == "'" || c == '"' || c == '`' || c == '[') {
        final String close = c == '[' ? ']' : c;
        i = sql.indexOf(close, i + 1);
        if (i < 0) return count; // unterminated: SQLite rejects the statement anyway
      } else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
        i = sql.indexOf('\n', i);
        if (i < 0) return count;
      } else if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
        i = sql.indexOf('*/', i + 2);
        if (i < 0) return count;
        i++;
      } else if (c == '?') {
        count++;
      }
      i++;
    }
    return count;
  }

  /// A condition on a `oneOf` reference: an OR over its tables (only [FluentRelatedCondition.type], when given),
  /// each matched by the type column and its own key columns. A path ([rest]) follows the tables that have the next
  /// relation.
  FluentFilter _oneOfSql(FluentRelationLink link, FluentRelatedCondition condition, FluentFilter? inner, String outer, _AliasCounter aliases, {String? rest}) {
    String col(String alias, String column) => '$alias.${column.quotedIdentifier}';
    final Iterable<MapEntry<String, FluentProvider>> targets = link.targets.entries.where(
      (t) => (condition.type == FluentStorable || t.value.modelType == condition.type) && (rest == null || t.value._links.any((l) => l.name == rest)),
    );
    if (targets.isEmpty) {
      throw FluentLog.raise(
        FluentArgumentException(
          'R',
          '$condition: "${link.name}" points to ${link.targets.values.map((p) => p.modelType).join(', ')}; '
              '${rest == null ? 'none of them is ${condition.type}' : 'none of them has a relation "$rest"'}.',
          hint: "Use one of its types: FluentFilter.related<${link.targets.values.first.modelType}>('${link.name}', ...).",
        ),
        tag: '$tableName:related',
      );
    }
    final List<String> parts = [];
    final List<Object?> args = [];
    for (final MapEntry<String, FluentProvider> t in targets) {
      final FluentProvider target = t.value;
      final String r = aliases.take('r');
      FluentFilter onTarget = inner == null ? FluentFilter.empty : target._resolveRelated(inner, r, aliases);
      onTarget = onTarget.and(target._relationVisibility(link));
      final List<String> columns = link.columnsFor(t.key);
      final List<String> keys = target.keyColumnNames.toList();
      final String match = [for (int i = 0; i < columns.length; i++) '${col(r, keys[i])} = ${col(outer, columns[i])}'].join(' AND ');
      final String condition = onTarget.whereClause.isEmpty ? '' : ' AND (${onTarget.whereClause})';
      parts.add('(${col(outer, link.typeColumn!)} = ? AND EXISTS (SELECT 1 FROM ${target.tableName.quotedIdentifier} AS $r WHERE $match$condition))');
      args
        ..add(t.key)
        ..addAll(target._sqlArgs(onTarget.whereArgs) ?? const []);
    }
    final String any = '(${parts.join(' OR ')})';
    switch (condition.mode) {
      case FluentRelatedMode.exists:
        return FluentFilter(any, args);
      case FluentRelatedMode.none:
        return FluentFilter('NOT $any', args);
      case FluentRelatedMode.count:
        // A reference holds one model: the count is 0 or 1.
        final String count = '(CASE WHEN $any THEN 1 ELSE 0 END)';
        final int? min = condition.min;
        final int? max = condition.max;
        if (min != null && max != null) return FluentFilter('$count BETWEEN ? AND ?', [...args, min, max]);
        return min != null ? FluentFilter('$count >= ?', [...args, min]) : FluentFilter('$count <= ?', [...args, max]);
    }
  }

  FluentRelationLink _relationFor(String name, String call) {
    for (final FluentRelationLink l in _links) {
      if (l.name == name) return l;
    }
    throw FluentLog.raise(
      FluentRelationException(
        '$call: "$tableName" has no relation "$name".',
        hint: _links.isEmpty
            ? 'Declare the relation in $modelType.relations (with FluentRelations) and register both providers in one FluentGroup.'
            : 'Relations of "$tableName": ${_links.map((l) => l.name).join(', ')}. Paths follow several relations: \'author.company\'.',
      ),
      tag: '$tableName:related',
    );
  }

  FluentFilter _relatedSql(FluentRelatedCondition condition, String outer, _AliasCounter aliases) {
    final String call = condition.toString();
    final List<String> path = condition.relation.split('.');
    final FluentRelationLink link = _relationFor(path.first, call);
    FluentFilter? inner = condition.where;
    if (path.length > 1) {
      if (condition.mode == FluentRelatedMode.count) {
        throw FluentLog.raise(
          FluentArgumentException('relation', '$call: relatedCount takes one relation, not a path.', hint: "Count the last relation and filter the first: FluentFilter.related('author', FluentFilter.relatedCount('posts', min: 5))."),
          tag: '$tableName:related',
        );
      }
      inner = FluentFilter.related(path.skip(1).join('.'), inner);
    }
    if (condition.mode == FluentRelatedMode.count && condition.min == null && condition.max == null) {
      throw FluentLog.raise(FluentArgumentException('min', '$call needs min, max or both.', hint: "FluentFilter.relatedCount('${condition.relation}', min: 1)"), tag: '$tableName:related');
    }
    _hintReferenceIndex(link);
    if (link.type == FluentRelationType.oneOf) return _oneOfSql(link, condition, inner, outer, aliases, rest: path.skip(1).firstOrNull);
    if (condition.type != FluentStorable && condition.type != link.target.modelType) {
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        '$call: "${link.name}" always holds ${link.target.modelType}; the type ${condition.type} is ignored.',
        table: tableName,
        database: dbName,
        subject: link.name,
        tag: '$tableName:related',
        hint: "A type is only needed for oneOf relations: FluentFilter.related('${link.name}', ...).",
      );
    }

    final FluentProvider target = link.target;
    final String r = aliases.take('r');
    String col(String alias, String column) => '$alias.${column.quotedIdentifier}';

    // What the related rows must satisfy: the caller's condition (its own related conditions resolved on the target),
    // the relation's `where`, and the visibility of relation loads.
    FluentFilter onTarget = inner == null ? FluentFilter.empty : target._resolveRelated(inner, r, aliases);
    if (link.relation.where != null) onTarget = onTarget.and(target._resolveRelated(link.relation.where!, r, aliases));
    onTarget = onTarget.and(target._relationVisibility(link));
    final String targetCondition = onTarget.whereClause.isEmpty ? '' : ' AND (${onTarget.whereClause})';
    final List<Object?> args = [...?target._sqlArgs(onTarget.whereArgs)];

    final String from;
    if (link.type == FluentRelationType.manyToMany) {
      final String l = aliases.take('l');
      final List<String> ownerKeys = keyColumnNames.toList();
      final List<String> targetKeys = target.keyColumnNames.toList();
      final String ownerMatch = [for (int i = 0; i < link.linkOwnerColumns.length; i++) '${col(l, link.linkOwnerColumns[i])} = ${col(outer, ownerKeys[i])}'].join(' AND ');
      final String targetMatch = [for (int i = 0; i < link.linkTargetColumns.length; i++) '${col(r, targetKeys[i])} = ${col(l, link.linkTargetColumns[i])}'].join(' AND ');
      from = '${link.linkSource} AS $l WHERE $ownerMatch AND EXISTS (SELECT 1 FROM ${target.tableName.quotedIdentifier} AS $r WHERE $targetMatch$targetCondition)';
    } else {
      final List<String> correlation = [
        for (int i = 0; i < link.foreignKeys.length; i++)
          link.isReference
              ? '${col(r, link.referencedColumns[i])} = ${col(outer, link.foreignKeys[i])}' // the reference is on this table
              : '${col(r, link.foreignKeys[i])} = ${col(outer, link.referencedColumns[i])}', // owned: the reference is on the child
      ];
      from = '${target.tableName.quotedIdentifier} AS $r WHERE ${correlation.join(' AND ')}${link.typeCondition(r)}$targetCondition';
    }

    switch (condition.mode) {
      case FluentRelatedMode.exists:
        return FluentFilter('EXISTS (SELECT 1 FROM $from)', args);
      case FluentRelatedMode.none:
        return FluentFilter('NOT EXISTS (SELECT 1 FROM $from)', args);
      case FluentRelatedMode.count:
        final String count = '(SELECT COUNT(*) FROM $from)';
        final int? min = condition.min;
        final int? max = condition.max;
        if (min != null && max != null) return FluentFilter('$count BETWEEN ? AND ?', [...args, min, max]);
        return min != null ? FluentFilter('$count >= ?', [...args, min]) : FluentFilter('$count <= ?', [...args, max]);
    }
  }

  /// A hint when the reference columns of [link] have no index because `indexReferences` is off, while a relation
  /// load or a relation filter reads by them (`one` relations read by the target's key, which is always indexed).
  void _hintReferenceIndex(FluentRelationLink link) {
    if (link.owner._indexReferences || link.isReference || link.type == FluentRelationType.oneOf) return;
    final bool linked = link.type == FluentRelationType.manyToMany;
    final String table = linked ? link.linkTable! : link.target.tableName;
    final List<String> columns = linked ? link.linkTargetColumns : link.foreignKeys;
    FluentLog.publish(
      FluentIssue(
        kind: FluentIssueKind.refIndex,
        database: dbName,
        subject: columns.join(','),
        table: table,
        title: 'Index the reference columns of relation "${link.name}"',
        details: 'indexReferences is off for "$dbName", so "$table"(${columns.join(', ')}) has no index: loading "${link.name}" or '
            'filtering by it reads every row of "$table", and so does deleting a "${link.owner.tableName}" row.',
        fix: 'Turn on FluentDbConfig(indexReferences: true), or add a FluentIndex on the reference columns of the model.',
        code: linked
            ? 'FluentGroup(..., config: const FluentDbConfig(indexReferences: true))'
            : 'FluentGroup(..., config: const FluentDbConfig(indexReferences: true))\n'
                '// or only this one, in ${link.target.modelType}:\n'
                "List<FluentIndex> get indexes => [FluentIndex([${columns.map((c) => "'$c'").join(', ')}])];",
      ),
    );
  }
}
