// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Provides schema management and synchronization capabilities for the [FluentDb].
///
/// This extension handles the structural evolution of the database, ensuring that
/// the physical database state matches the defined [FluentProvider] models. It encapsulates:
///
/// * **Schema Discovery:** Introspecting the SQLite master tables to identify
///   existing structures versus pending migrations.
/// * **Smart Migration:** Orchestrating table creation, intelligent schema
///   updates (`handleSmartMigration`), and index synchronization.
/// * **Integrity Verification:** Ensuring that relational dependencies and table
///   integrity constraints are validated and self-healed before the application
///   begins high-level data operations.
///
/// Use this extension to maintain the structural health of your database
/// persistence layer during initialization and runtime migrations.
extension FluentDbSchema on FluentDb {
  /// Synchronizes the database schema with the defined [FluentProvider] structures.
  ///
  /// This routine acts as a migration engine by:
  /// 1. **Schema Discovery:** Queries the `sqlite_master` table to identify existing tables.
  /// 2. **Creation/Migration:** Conditionally executes `createTable` for new tables or
  ///    `handleSmartMigration` for existing ones to ensure data structure alignment.
  /// 3. **Index Synchronization:** Updates or recreates indexes within a dedicated
  ///    transaction to ensure query performance is maintained.
  Future<void> _syncSchema(Database db, FluentGroup group, {List<FluentProvider>? sortedProviders}) async {
    FluentLog.info('Synchronizing schema for group: "${group.dbName}"', tag: 'FluentDb:syncSchema');

    final Iterable<FluentProvider<FluentStorable>> providersToSync = sortedProviders ?? group.daos;

    const String rawSql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";
    FluentLog.sql(rawSql, tag: 'FluentDb:syncSchema');
    final List<Map<String, Object?>> masterData = await db.rawQuery(rawSql);

    final Set<String> existingTables = {for (final Map<String, Object?> row in masterData) row['name'] as String};

    await db.transaction((txn) async {
      for (final FluentProvider dao in providersToSync) {
        final String tableName = dao.tableName;

        if (!existingTables.contains(tableName)) {
          FluentLog.info('Creating fresh schema for table: "$tableName"', tag: 'FluentDb:syncSchema');
          await dao.createTable(txn);
        } else {
          FluentLog.debug('Analyzing structure for "$tableName"', tag: 'FluentDb:syncSchema');

          await dao.handleSmartMigration(txn);
        }
      }
    });

    await db.transaction((txn) async {
      for (final FluentProvider dao in providersToSync) {
        FluentLog.debug('Syncing indexes for table', tag: 'FluentDb:syncSchema', context: {'table': dao.tableName});
        await dao.syncIndexes(txn);
        await dao.syncPivotTables(txn, dao);
      }
    });

    FluentLog.info('Schema synchronization completed for group: "${group.dbName}"', tag: 'FluentDb:syncSchema');
  }
}
