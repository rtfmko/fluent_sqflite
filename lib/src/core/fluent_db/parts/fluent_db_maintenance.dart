// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Maintenance of [FluentDb]: the start-up clean-up (expired rows, dangling references), [FluentDb.cleanOrphans] and
/// the periodic trash purge.
extension _FluentDbMaintenance on FluentDb {
  /// [FluentDb.cleanOrphans] for one database: every table in one transaction, queued as a write (calls made before
  /// it finish first, nothing runs beside it), or joined when the caller's transaction of [dbName] is open. Every
  /// table it changed publishes a change event (after the commit inside a transaction). Inside another task of
  /// [dbName] it is skipped and reported (`ignoredCall`): queued, it would wait for that task.
  Future<void> _cleanOrphans(String dbName, List<FluentProvider> providers) async {
    if (providers.isEmpty) return;
    final FluentTransactionScope? open = FluentTransactionScope.of(dbName);
    if (open == null && FluentEngine().holdsDatabase(dbName)) {
      FluentLog.issue(
        FluentIssueKind.ignoredCall,
        'FluentDb.cleanOrphans was called from inside a running task of "$dbName"; nothing was done there.',
        database: dbName,
        subject: 'cleanOrphans',
        tag: 'FluentDb:cleanOrphans',
        hint: 'Queued, it would wait for the running task, which waits for it. Call it inside FluentDb.transaction (it '
            'then runs in the transaction) or after the task completed.',
      );
      return;
    }
    FluentLog.debug('Manual orphan cleanup started', tag: 'FluentDb:maintenance', context: {'dbName': dbName});
    // The tables whose rows changed (deleted, or their reference cleared).
    Future<List<FluentProvider>> clean() => FluentTransactionScope.inTransaction(providers.first.db, dbName, (txn) async {
      Future<int> changes() async => Sqflite.firstIntValue(await txn.rawQuery('SELECT total_changes()')) ?? 0;
      final List<FluentProvider> changed = [];
      for (final FluentProvider dao in providers) {
        final int before = await changes();
        await dao.cleanupOrphans(txn);
        if (await changes() != before) changed.add(dao);
      }
      return changed;
    });
    try {
      if (open != null) {
        for (final FluentProvider dao in await clean()) {
          open.pendingEvents.add((FluentTask(action: FluentDbAction.update, table: dao.tableName, dbName: dbName), dao, 1));
        }
      } else {
        final Object? changed = await FluentEngine().dispatch(FluentTask(action: FluentDbAction.transaction, dbName: dbName, data: clean));
        for (final FluentProvider dao in changed! as List<FluentProvider>) {
          FluentEngine().broadcastSystemAction(FluentDbAction.update, dao);
        }
      }
      FluentLog.info('Database "$dbName": dangling references removed.', tag: 'FluentDb:maintenance');
    } catch (e, st) {
      // The caller receives the error: logged once on its way (nothing was changed).
      FluentLog.report(e, stackTrace: st, tag: 'FluentDb:maintenance');
      rethrow;
    }
  }

  /// The start-up clean-up of [group], in one transaction: deletes expired rows of every table and, with
  /// [cleanOrphans], dangling references. A failure is reported (`maintenanceFailed`), never thrown: the database works
  /// without it and the next start tries again.
  Future<void> _runInitialMaintenance(FluentGroup group, {bool cleanOrphans = true}) async {
    if (group.providerList.isEmpty) return;

    final Database db = group.providerList.first.db;
    FluentLog.debug('Starting hygiene maintenance for group "${group.dbKey.dbName}"', tag: 'FluentDb:maintenance');
    try {
      // A scope (not a bare db.transaction): the provider calls below join it instead of queueing behind it.
      await FluentTransactionScope.inTransaction(db, group.dbKey.dbName, (txn) async {
        int expiredCleaned = 0;
        int orphansCleaned = 0;

        for (final FluentProvider dao in group.providerList) {
          // 1. TTL Cleanup
          try {
            await dao.clearExpired();
            expiredCleaned++;
          } catch (e, st) {
            // Logged by the failed call; expired rows stay hidden from reads and are removed on the next start.
            FluentLog.report(e, stackTrace: st, tag: 'FluentDb:maintenance');
          }

          // 2. Orphan Cleanup (only when SQLite does not guarantee integrity by itself)
          if (cleanOrphans) {
            try {
              await dao.cleanupOrphans(txn);
              orphansCleaned++;
            } catch (e, st) {
              FluentLog.issue(
                FluentIssueKind.maintenanceFailed,
                'Failed to clean up dangling references in "${dao.tableName}"',
                error: e,
                stackTrace: st,
                table: dao.tableName,
                tag: 'FluentDb:maintenance',
                hint: 'Nothing was deleted; it is retried on the next start. Check the cause (often a locked database).',
              );
            }
          }
        }

        FluentLog.debug(
          'Maintenance routine completed for group',
          tag: 'FluentDb:maintenance',
          context: {'dbName': group.dbKey.dbName, 'tablesProcessedTTL': expiredCleaned, 'tablesProcessedOrphans': orphansCleaned},
        );
      });

      FluentLog.debug('Maintenance for "${group.dbKey.dbName}" completed.', tag: 'FluentDb:maintenance');
    } catch (e, st) {
      FluentLog.issue(
        FluentIssueKind.maintenanceFailed,
        'Start-up maintenance of "${group.dbKey.dbName}" failed',
        error: e,
        stackTrace: st,
        database: group.dbKey.dbName,
        tag: 'FluentDb:maintenance',
        hint: 'The database works without it (expired rows and dangling references are cleaned on the next start). '
            'A disk-full or locked-file error is the usual cause.',
      );
    }
  }

  /// Whether [dbName] was opened read-only (maintenance never writes to it).
  bool _isReadOnly(String dbName) =>
      FluentDb._lastConfig?.any((g) => g.dbKey.dbName == dbName && g.readOnly && !g.inMemory) ?? false;

  /// Deletes the trashed rows past their retention in every [FluentSoftDeletable] table (after `init` and on the
  /// `trashPurgeInterval` timer). Databases the tuner keeps busy are skipped; a failing table does not stop the others.
  Future<void> _purgeSoftDeletedGlobal() async {
    FluentLog.debug('Starting global soft-delete purge procedure', tag: 'FluentDb:purge');

    // A copy: close / init may change the registry while a purge waits.
    for (final MapEntry<String, _FluentProviderIndex> group in List.of(_groupedRegistry.entries)) {
      if (group.value.all.isEmpty || _isReadOnly(group.key) || FluentTuner().defersMaintenance(group.key)) continue;
      for (final FluentProvider provider in group.value.all) {
        try {
          await provider.purgeTrash(); // nothing (no call queued) for tables without soft delete
        } catch (e, s) {
          // Already logged by the failed call, unless it failed before running; the rows stay for the next run.
          FluentLog.report(e, stackTrace: s, tag: 'FluentDb:purge');
        }
      }
    }
  }
}
