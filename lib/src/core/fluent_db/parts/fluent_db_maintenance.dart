// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Provides automated and manual maintenance operations for the [FluentDb].
///
/// This extension orchestrates background storage hygiene and data integrity
/// routines, ensuring the database remains performant and consistent over time.
/// It encapsulates:
///
/// * **Automated Hygiene:** Routine maintenance tasks such as clearing expired records
///   (TTL) and purging orphaned relational data.
/// * **Manual Intervention:** Explicit triggers for manual orphan cleanup across
///   database groups.
///
/// These operations are designed to run atomically within transactions to prevent
/// data corruption and reduce I/O overhead during routine system upkeep.
extension FluentDbMaintenance on FluentDb {
  /// Executes a manual cleanup of orphaned records across all DAOs within a [FluentGroup].
  ///
  /// This method iterates through all registered [FluentRelationsMixin] providers and
  /// executes their orphan cleanup logic within a single atomic database
  /// transaction to maintain relational integrity and prevent partial cleanup state.
  Future<void> cleanOrphans(FluentGroup group) async {
    if (group.daos.isEmpty) return;

    FluentLog.info('Manual orphan cleanup started', tag: 'FluentDb:maintenance', context: {'dbName': group.dbName});

    try {
      final Database db = group.daos.first.db;

      await db.transaction((txn) async {
        for (final FluentProvider dao in group.daos) {
          if (dao is FluentRelationsMixin) {
            FluentLog.debug('Cleaning orphans for table', tag: 'FluentDb:maintenance', context: {'table': dao.tableName});
            await (dao as FluentProvider).cleanupOrphans(txn);
          }
        }
      });

      FluentLog.info('Group "${group.dbName}": All orphans removed successfully.', tag: 'FluentDb:maintenance');
    } catch (e, st) {
      FluentLog.error(
        'Failed to execute manual orphan cleanup for "${group.dbName}"',
        e,
        st,
        tag: 'FluentDb:maintenance',
        hint: 'Ensure that the database is not in a read-only state and that all transactions are committed correctly.',
      );
      rethrow;
    }
  }

  /// Executes automated storage hygiene for a [FluentGroup].
  ///
  /// This maintenance routine ensures database health by:
  /// 1. **TTL Management:** Purging records that have exceeded their time-to-live.
  /// 2. **Referential Integrity:** Removing orphaned relations to keep the database graph clean.
  ///
  /// All operations are executed within a single transaction to minimize I/O overhead
  /// and ensure global consistency across tables.
  Future<void> _runInitialMaintenance(FluentGroup group) async {
    if (group.daos.isEmpty) return;

    final Database db = group.daos.first.db;
    FluentLog.info('Starting hygiene maintenance for group "${group.dbName}"', tag: 'FluentDb:maintenance');
    try {
      await db.transaction((txn) async {
        int expiredCleaned = 0;
        int orphansCleaned = 0;

        for (final FluentProvider dao in group.daos) {
          // 1. TTL Cleanup
          try {
            await dao.clearExpiredItems(executor: txn);
            expiredCleaned++;
          } catch (e, st) {
            FluentLog.error('Failed to clear expired items in "${dao.tableName}"', e, st, tag: 'FluentDb:maintenance', hint: 'Check if the TTL column is indexed properly for performance.');
          }

          // 2. Orphan Cleanup
          if (dao is FluentRelationsMixin) {
            try {
              await (dao as FluentProvider).cleanupOrphans(txn);
              orphansCleaned++;
            } catch (e, st) {
              FluentLog.error('Failed to cleanup orphans for "${dao.tableName}"', e, st, tag: 'FluentDb:maintenance');
            }
          }
        }

        FluentLog.debug(
          'Maintenance routine completed for group',
          tag: 'FluentDb:maintenance',
          context: {'dbName': group.dbName, 'tablesProcessedTTL': expiredCleaned, 'tablesProcessedOrphans': orphansCleaned},
        );
      });

      FluentLog.info('Maintenance for "${group.dbName}" completed.', tag: 'FluentDb:maintenance');
    } catch (e, st) {
      FluentLog.error('Critical storage error during maintenance of "${group.dbName}"', e, st, tag: 'FluentDb:maintenance');
      if (isDevMod) rethrow;
    }
  }
}
