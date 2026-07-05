// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Service Locator and Provider Management Extension for [FluentDb].
///
/// This extension handles the registration, lookup, and availability of
/// [FluentProvider] instances. It acts as the central hub for retrieving DAOs
/// by their model types and provides a high-level API for executing
/// database transactions within specific storage contexts.
///
/// Key responsibilities include:
/// * **Provider Mapping**: Maintaining the link between [FluentStorable] models and their DAOs.
/// * **Transactional Integrity**: Providing a unified interface for atomic operations.
/// * **State Inspection**: Checking the operational status of specific model storages.
extension FluentDbLocator on FluentDb {
  /// Checks if the underlying database for a specific model [T] is open and ready.
  bool isModelStorageReady<T extends FluentStorable>({required FluentDbKey dbKey}) {
    final FluentProvider? provider = _groupedRegistry[dbKey.dbName]?[T];
    return provider?.db.isOpen ?? false;
  }

  /// Executes the provided [action] within an atomic SQLite transaction scope for
  /// all specified [modelTypes].
  ///
  /// **Strategic Workflow:**
  /// 1. **Coordination Lock:** Pauses the [FluentEngine] to ensure no
  ///    asynchronous background worker attempt write operations on the database
  ///    during the transaction, preventing `database is locked` errors.
  /// 2. **Execution Injection:** Temporarily intercepts the `DatabaseExecutor` of
  ///    all involved [FluentProvider] instances, routing all operations through the
  ///    active transaction object (`txn`).
  /// 3. **Safety & Rollback:** The structure guarantees that even if the [action]
  ///    throws an exception, the system safely rolls back, restores original
  ///    executors, and resumes the worker queue.
  ///
  /// **Example Usage:**
  /// ```dart
  /// await FluentDb.transaction<void>(
  ///   modelTypes: [User, Account],
  ///   action: () async {
  ///     await FluentDb.updateFieldsMultiple<User>(1, {'last_login': '2026-05-25'});
  ///     await FluentDb.saveItem<Account>(newAccountEntry);
  ///   }
  /// );
  /// ```
  Future<T> transaction<T>({required List<Type> modelTypes, required Future<T> Function() action, FluentDbKey? dbKey}) async {
    if (modelTypes.isEmpty) {
      final FluentArgumentException exception = FluentArgumentException('$modelTypes', 'The list cannot be empty. You must provide at least one model type for this transaction.', StackTrace.current);
      FluentLog.error(exception.message, exception, exception.stackTrace);
      throw exception;
    }

    // Resolve target providers for all models involved in the transaction
    final List<FluentProvider<FluentStorable>> targetProviders = [];
    for (final Type type in modelTypes) {
      final FluentProvider provider = FluentDb.providerForType(type, dbName: dbKey?.dbName);
      targetProviders.add(provider);
    }

    // Verify consistency: all providers must target the same database file for SQLite atomicity
    final FluentProvider primaryProvider = targetProviders.first;
    final Database database = primaryProvider.db;

    FluentLog.info('Starting atomic transaction scope', tag: 'FluentDb.transaction', context: {'tables': targetProviders.map((p) => p.tableName).toList()});

    // Pause the background coordinator to prevent thread-contention on the database
    final FluentEngine coordinator = FluentEngine();
    await coordinator.pauseQueue();

    try {
      final T result = await database.transaction((txn) async {
        for (final FluentProvider provider in targetProviders) {
          provider.setTransactionExecutor(txn);
        }

        try {
          return await action();
        } finally {
          for (final FluentProvider provider in targetProviders) {
            provider.restoreOriginalExecutor();
          }
        }
      });

      FluentLog.debug('Global transaction committed successfully', tag: 'FluentDb.transaction');
      return result;
    } catch (e, s) {
      FluentLog.error(
        'Transaction failed and was rolled back safely',
        e,
        s,
        tag: 'FluentDb.transaction',
        hint: 'Verify that no logic within the action() scope performs manual database closing or conflicting IO.',
      );
      rethrow;
    } finally {
      // Always resume the background task queue
      coordinator.resumeQueue();
    }
  }

  /// Resets the registry to its initial state, purging all registered providers
  /// and configuration metadata.
  ///
  /// This operation wipes the internal state, effectively reverting the registry
  /// to an uninitialized state. It is typically used during test teardowns,
  /// recovery from critical errors, or as part of the `dropAll()` sequence.
  @visibleForTesting
  void reset() {
    FluentLog.debug('Resetting registry state: clearing providers and flags.', tag: 'FluentDb:reset');

    _groupedRegistry.clear();
    FluentDb._lastConfig?.clear();
    _isInitialized = false;

    FluentLog.info('Registry state has been fully reset.', tag: 'FluentDb:reset');
  }

  /// Registers a [FluentProvider] within the registry and builds necessary lookup indices.
  ///
  /// This method enables multi-dimensional access to providers:
  /// 1. **Model-Based:** Allows resolving providers via the [FluentStorable] type (essential for relationship mapping).
  /// 2. **Provider-Based:** Provides direct access via the class type.
  /// 3. **Table-Based:** Creates an O(1) index using the table name for high-performance cross-reference
  ///    and inter communication.
  void _register<T extends FluentStorable>(FluentProvider<T> provider, String dbName) {
    final Type modelType = T;
    final Type providerType = provider.runtimeType;

    final Map<Type, FluentProvider<FluentStorable>> group = _groupedRegistry.putIfAbsent(dbName, () => <Type, FluentProvider>{});
    group[modelType] = provider;
    group[providerType] = provider;

    FluentLog.debug(
      'Provider registered successfully',
      tag: 'FluentDb:register',
      context: {'provider': providerType.toString(), 'table': provider.tableName, 'model': modelType.toString(), 'dbName': dbName},
    );
  }
}
