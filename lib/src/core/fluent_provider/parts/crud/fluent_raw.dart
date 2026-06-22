// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

part of '../../fluent_provider.dart';

/// Enterprise data-layer extension providing a low-level, direct interface for native database
/// interactions for [FluentStorable] entities.
///
/// The [FluentRaw] extension serves as an "escape hatch" for complex scenarios where standardized
/// CRUD operations or query abstractions are insufficient. It grants direct access to the storage
/// engine's native execution capabilities, enabling highly optimized, engine-specific SQL commands
/// while strictly maintaining the architectural integrity of the [FluentDb] pipeline.
///
/// ### Core Execution Paradigms & Safety Boundaries
/// Operations within this extension offer total control over database interactions, requiring
/// heightened developer oversight and adherence to system lifecycle protocols:
///
/// * **Native Protocol Passthrough:** Bypasses high-level abstraction layers, allowing the
///   execution of complex analytical subqueries, engine-specific diagnostic commands, or
///   performance-critical SQL that falls outside standard CRUD scope.
/// * **Architectural Integrity:** Despite their raw nature, all commands are dispatched as
///   [FluentTask] instances. This ensures that raw queries respect transactional boundaries,
///   concurrency policies, and connection pool management enforced by the [FluentEngine].
/// * **Destructive DDL Safeguards:** The engine enforces strict validation on raw inputs,
///   proactively blocking destructive DDL operations (e.g., `DROP` or `ALTER`) to prevent
///   accidental structural schema degradation.
/// * **Transactional Transparency:** Raw operations remain fully composable within the
///   broader [FluentDb] transaction orchestration, ensuring that low-level changes remain
///   atomic and consistent with the broader data state.
///
/// See also:
/// * [FluentProvider], the core storage driver contract.
/// * [FluentEngine], which orchestrates the execution and safety monitoring of all tasks.
/// * [FluentTask], the unit of work enforced throughout the system.
extension FluentRaw<T extends FluentStorable> on FluentProvider<T> {
  /// Fetches a single un-materialized raw data map from [$tableName] matching a specific column condition.
  ///
  /// This low-level extraction routine bypasses model constructors, fast-paths, and relation
  /// enrichment steps completely, returning the raw database row format mapped directly by the engine.
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [column] specifies the targeted column field name to filter against. Defaults to the table's primary key name.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a JSON-compatible [Map<String, dynamic>] if a record satisfies constraints; otherwise, evaluates to `null`.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final rawDataMap = await userRepository.rawGetItemBy(
  ///   'usr_0192a3',
  ///   column: 'uuid',
  ///   policy: const ExecutionPolicy(useIsolate: false), // Run instantly on the Main thread thread-pool
  /// );
  ///
  /// if (rawDataMap != null) {
  ///   print(rawDataMap['encrypted_payload']); // Safely read raw fields before model parsing
  /// }
  /// ```
  @internal
  Future<Map<String, dynamic>?> rawGetItemBy(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) {
    // Fall back to the configured table primary key name if no explicit column is specified
    final String searchCol = column ?? primaryKeyColumn.name;

    FluentLog.debug(
      'Initiating global operational query pipeline for single raw map record extraction',
      tag: '$tableName:rawGetItemBy',
      context: {'tableName': tableName, 'searchColumn': searchCol, 'searchValue': value.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.rawGetItem,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(column: searchCol, value: value, where: '$searchCol = ?', whereArgs: [value], limit: 1, multiple: false),
      policy: policy,
    );

    return FluentDb.executeTask<T, Map<String, dynamic>?>(provider: this, task: task);
  }

  /// Fetches a batch collection of un-materialized raw data maps from [$tableName] matching a specific column criteria.
  ///
  /// This performance-focused routine extracts multiple matching row documents from SQLite while completely
  /// bypassing data-layer model hydration, model assembly constructors, and relational sub-worker loops.
  ///
  /// [value] defines the evaluation parameter bound to the target query constraint argument.
  /// [column] specifies the targeted column field name to filter against. Defaults to the table's primary key name.
  /// [policy] defines prioritization, query collapsing, and concurrency controls managed by the coordinator.
  ///
  /// Returns a [List<Map<String, dynamic>>] containing raw, row-index mapping structures.
  ///
  /// ### Usage Example:
  /// ```dart
  /// final rawLogsBatch = await auditRepository.rawGetItemsBy(
  ///   'ERROR',
  ///   column: 'log_level',
  ///   policy: const ExecutionPolicy(useIsolate: true), // Offload parsing overhead of large sets from Main
  /// );
  /// ```
  @internal
  Future<List<Map<String, dynamic>>> rawGetItemsBy(dynamic value, {String? column, ExecutionPolicy policy = const ExecutionPolicy()}) {
    // Fall back to the configured table primary key name if no explicit column is specified
    final String searchCol = column ?? primaryKeyColumn.name;

    FluentLog.debug(
      'Initiating global operational query pipeline for raw collection record batch extraction',
      tag: '$tableName:rawGetItemsBy',
      context: {'tableName': tableName, 'searchColumn': searchCol, 'searchValue': value.toString(), 'hasCustomPolicy': policy != const ExecutionPolicy()},
    );

    final FluentTask task = FluentTask(
      action: FluentDbAction.rawGetItems,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(column: searchCol, value: value, where: _injectSoftDelete('$searchCol = ?'), whereArgs: [value], multiple: true),
      policy: policy,
    );

    return FluentDb.executeTask<T, List<Map<String, dynamic>>>(provider: this, task: task);
  }

  /// Executes a custom SQL statement against the storage engine for the table [$tableName].
  ///
  /// This execution utility provides a secure gateway for performing complex DML
  /// (Data Manipulation Language) operations that fall outside standard CRUD abstractions:
  /// * Performs early-exit validation on empty SQL strings to prevent engine overhead.
  /// * Sanitizes inputs by enforcing strict DML-only execution to protect schema integrity (blocks DDL).
  /// * Monitors parameter binding integrity by reconciling `?` placeholders with provided arguments.
  ///
  /// [sql] represents the raw SQL query string. Use positional `?` placeholders for safe binding.
  /// [arguments] provides the data values to be bound to the SQL placeholders.
  /// [policy] defines execution controls, including priority, timeouts, and custom tags.
  ///
  /// Returns a [Future<int>] yielding the number of rows affected by the executed command.
  ///
  /// ### Usage Example:
  /// ```dart
  /// // Perform a bulk update and retrieve the count of modified rows
  /// final int updatedCount = await userRepository.execute(
  ///   "UPDATE users SET status = ? WHERE last_login < ?",
  ///   arguments: ['inactive', cutoffDate],
  /// );
  /// ```
  @internal
  Future<int> execute(String sql, {List<dynamic>? arguments, ExecutionPolicy policy = const ExecutionPolicy()}) {
    if (sql.trim().isEmpty) {
      throw FluentArgumentException(tableName, 'SQL query cannot be empty.', StackTrace.current);
    }

    final int placeholderCount = sql.split('?').length - 1;
    if (arguments != null && arguments.length != placeholderCount) {
      FluentLog.warning(
        'Potential SQL parameter mismatch',
        tag: '$tableName:execute',
        hint:
            'Ensure that the number of provided arguments matches the number of \'?\' placeholders in your SQL string. Mismatched parameters can lead to SQLite binding errors or unexpected query behavior.',
        context: {'expected': placeholderCount, 'actual': arguments.length, 'sql': sql},
      );
    }

    final FluentTask task = FluentTask(
      action: FluentDbAction.execute,
      table: tableName,
      dbName: dbName,
      helper: TableHelper(sql: sql, whereArgs: arguments),
      policy: policy,
    );

    final String upperSql = sql.trim().toUpperCase();
    if (upperSql.startsWith('DROP') || upperSql.startsWith('ALTER')) {
      final FluentEngineException exception = FluentEngineException(
        'Destructive DDL operations (DROP/ALTER) are not allowed via execute()',
        component: 'execute',
        task: task,
        stackTrace: StackTrace.current,
      );
      FluentLog.error(
        exception.message,
        exception,
        exception.stackTrace,
        tag: '$tableName:execute',
        hint:
            'The execute() method is intended for DML (Data Manipulation Language) operations like UPDATE or DELETE. Use dedicated migration tools or engine-level administrative methods for structural schema changes (DDL).',
      );
      throw exception;
    }

    FluentLog.debug('SQL execution pipeline initiated', tag: '$tableName:execute', context: {'sql': sql, 'hasArguments': arguments != null && arguments.isNotEmpty});

    return FluentDb.executeTask<T, int>(provider: this, task: task);
  }
}
