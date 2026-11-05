// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Registration of providers in the registry.
extension _FluentDbLocator on FluentDb {
  /// Forgets the registered providers and the groups of the last init, without closing anything (test resets and the
  /// `resetOnSchemaError` retry of init).
  void _reset() {
    FluentLog.debug('Resetting registry state: clearing providers and flags.', tag: 'FluentDb:reset');

    _groupedRegistry.clear();
    FluentDb._lastConfig?.clear();
    _isInitialized = false;
    // The maintenance timers belong to the forgotten databases.
    _trashPurgeTimer?.cancel();
    _optimizeTimer?.cancel();
    _trashPurgeTimer = _optimizeTimer = null;

    FluentLog.debug('Registry state has been fully reset.', tag: 'FluentDb:reset');
  }

  /// Registers [provider] in database [dbName], indexed by model type, provider class and table name.
  ///
  /// Registering the same provider instance again does nothing.
  void _register<T extends FluentStorable>(FluentProvider<T> provider, String dbName) {
    final Type modelType = T;
    final Type providerType = provider.runtimeType;

    if (!_groupedRegistry.putIfAbsent(dbName, _FluentProviderIndex.new)._add(provider)) return;

    FluentLog.debug(
      'Provider registered successfully',
      tag: 'FluentDb:register',
      context: {'provider': providerType.toString(), 'table': provider.tableName, 'model': modelType.toString(), 'dbName': dbName},
    );
  }
}
