// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_db.dart';

/// Schema synchronization of a whole database group.
///
/// When every table's fingerprint matches its snapshot in `__fluent_schema` (`fluentSchemaUpToDate`) the sync is
/// skipped. Otherwise every table is compared with its snapshot (see [FluentSchemaSync.syncTable]) and the changes are
/// applied in a single transaction with foreign keys switched off (so table rebuilds never cascade); every applied
/// change or failure is written to `__fluent_schema_history`.
extension _FluentDbSchema on FluentDb {
  /// Synchronizes all tables of [group] with their models.
  ///
  /// Returns `true` when `PRAGMA foreign_key_check` found rows referencing missing rows afterwards
  /// (the start-up maintenance then cleans dangling references).
  Future<bool> _syncSchema(Database db, FluentGroup group, {List<FluentProvider>? sortedProviders}) async {
    FluentLog.debug('Synchronizing schema for group: "${group.dbKey.dbName}"', tag: 'FluentDb:syncSchema');
    final Iterable<FluentProvider<FluentStorable>> providers = sortedProviders ?? group.providerList;

    final FluentSchemaSyncContext ctx = await _schemaContext(db, group, group.archiveRetention);
    await FluentRelationSchema.keepOneToOneSides(db, providers);
    if (await fluentSchemaUpToDate(db, providers, ctx)) {
      FluentLog.debug('Schema of "${group.dbKey.dbName}" is unchanged: sync skipped', tag: 'FluentDb:syncSchema');
      return false;
    }
    final MigrationPlanCallback? guard = group.onMigrationPlan;
    if (guard != null) {
      final FluentMigrationPlan plan = await _planSchema(db, group, providers, runCode: false);
      // A plan that fails is not asked about: the start below fails the same way and reports it.
      if (plan.failure == null && !plan.isEmpty && !await guard(plan)) {
        throw FluentSchemaException(
          'The schema changes of "${group.dbKey.dbName}" were refused by onMigrationPlan; nothing was changed.',
          code: FluentErrorCode.migrationRefused,
          hint: 'Review the plan and allow it, or change the models:\n$plan',
        );
      }
    }
    // Foreign keys switched from off to on: rows written while they were off may point nowhere. Nothing else differs
    // from the last start then (the setting is part of the fingerprint), so the rows are checked at this start.
    final bool switchedOn = ctx.foreignKeys && await fluentSchemaUpToDate(db, providers, await _schemaContext(db, group, group.archiveRetention, foreignKeys: false));
    return _runSchemaTransaction(db, group, ctx, (txn) => _syncTables(txn, group, providers, ctx), checkForeignKeys: switchedOn);
  }

  /// One schema pass over [providers] inside [txn]: relation data that must move first, the tables (with their link
  /// tables, sync and full-text tables), then relation data that moves into the synchronized tables.
  Future<void> _syncTables(Transaction txn, FluentGroup group, Iterable<FluentProvider> providers, FluentSchemaSyncContext ctx) async {
    await ensureFluentSchemaTables(txn);
    final Set<String> existing = {
      for (final Map<String, Object?> row in await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")) row['name']! as String,
    };
    // Tables and link columns a 1.x database named with the old rule get their current names first.
    final Map<String, String> renamedTables = await fluentAdoptLegacyNames(txn, providers, existing, ctx.changes);
    // Relations that changed their kind since the last start keep their data (see fluentMigrateRelations).
    final Map<String, FluentTableSnapshot> before = {for (final FluentTableSnapshot s in await readFluentSchemaSnapshots(txn)) s.table: s};
    await fluentMigrateRelations(txn, providers, before, beforeTables: true, changes: ctx.changes);
    for (final FluentProvider dao in providers) {
      await dao.syncTable(txn, ctx, existsOnDisk: existing.contains(dao.tableName));
      await dao.syncLinkTables(txn, changes: ctx.changes);
      await dao.prepareSyncTables(txn);
      await dao.syncFullText(txn, group.config.fullText, changes: ctx.changes);
    }
    await fluentMigrateRelations(txn, providers, before, beforeTables: false, changes: ctx.changes);
    // Only the values of tables renamed at this start: no scan on every full sync, and a free 1.x name is never rewritten.
    await fluentAdoptLegacyTypeValues(txn, providers, ctx.changes, renamedTables: renamedTables);
  }

  /// What [_syncSchema] would change: the same pass in a transaction that is rolled back, its issues collected
  /// instead of reported. With [runCode] `false` the `onMigrate` code of steps is left out.
  Future<FluentMigrationPlan> _planSchema(Database db, FluentGroup group, Iterable<FluentProvider> providers, {required bool runCode, bool isNewDatabase = false}) async {
    final FluentSchemaSyncContext ctx = await _schemaContext(db, group, group.archiveRetention, runCode: runCode);
    await FluentRelationSchema.keepOneToOneSides(db, providers);
    final List<FluentIssue> issues = [];
    FluentException? failure;
    if (!await fluentSchemaUpToDate(db, providers, ctx)) {
      await FluentLog.captureIssues(issues, () async {
        final bool foreignKeysOn = ((await db.rawQuery('PRAGMA foreign_keys')).first.values.first as int? ?? 0) == 1;
        if (foreignKeysOn) await db.execute('PRAGMA foreign_keys = OFF');
        try {
          await db.transaction((txn) async {
            await _syncTables(txn, group, providers, ctx);
            throw const _PlanRollback();
          });
        } on _PlanRollback {
          // Everything above is undone: the plan only looked.
        } on FluentException catch (e) {
          failure = e; // rolled back as well; the plan says why the start would fail
        } on DatabaseException catch (e, st) {
          failure = FluentSchemaException(
            'The schema of "${group.dbKey.dbName}" cannot be applied: ${FluentLog.redact('$e')}',
            hint: 'Fix the model (a constraint the data violates, an invalid CHECK or default); the database is unchanged.',
            cause: e,
            stackTrace: st,
          );
        } finally {
          if (foreignKeysOn) await db.execute('PRAGMA foreign_keys = ON');
        }
      });
      for (final FluentProvider p in providers) {
        p.refreshSchema();
      }
    }
    return FluentMigrationPlan(database: group.dbKey.dbName, changes: ctx.changes, issues: issues, isNewDatabase: isNewDatabase, skippedCode: ctx.skippedCode, failure: failure);
  }

  /// Runs [action] in one transaction with foreign keys off, records history (also for failures),
  /// and returns whether `PRAGMA foreign_key_check` reported violations afterwards.
  Future<bool> _runSchemaTransaction(Database db, FluentGroup group, FluentSchemaSyncContext ctx, Future<void> Function(Transaction txn) action, {bool checkForeignKeys = false}) async {
    // SQLite ignores `PRAGMA foreign_keys` inside a transaction, so it is switched off here. Otherwise
    // rebuilding a parent table (DROP + rename) would cascade-delete its children.
    final bool foreignKeysOn = ((await db.rawQuery('PRAGMA foreign_keys')).first.values.first as int? ?? 0) == 1;
    if (foreignKeysOn) await db.execute('PRAGMA foreign_keys = OFF');

    bool violations = false;
    try {
      await db.transaction((txn) async {
        await action(txn);
        await writeFluentSchemaHistory(txn, ctx.history, group.historyLimit);
      });

      // Only a schema change (a rebuild with foreign keys off) can leave rows pointing nowhere.
      if (foreignKeysOn && (ctx.changes.isNotEmpty || checkForeignKeys)) {
        final List<Map<String, Object?>> found = await db.rawQuery('PRAGMA foreign_key_check');
        if (found.isNotEmpty) {
          violations = true;
          FluentLog.issue(
            FluentIssueKind.danglingReferences,
            '${found.length} row(s) reference rows that do not exist.',
            tag: 'FluentDb:syncSchema',
            hint: 'Usually left over from older app versions; dangling references are cleaned by the start-up maintenance. '
                'First rows: ${found.take(3).toList()}',
          );
        }
      }
    } catch (e) {
      // The transaction was rolled back; record the failed attempt separately.
      try {
        await writeFluentSchemaHistory(db, [
          FluentSchemaHistoryEntry(table: ctx.currentTable ?? '*', fromRevision: 0, toRevision: 0, changes: const [], success: false, error: '$e', appliedAt: ctx.now),
        ], group.historyLimit);
      } catch (_) {
        // History is best-effort; the original error matters.
      }
      rethrow;
    } finally {
      if (foreignKeysOn) await db.execute('PRAGMA foreign_keys = ON');
    }

    FluentLog.debug('Schema synchronization completed for group: "${group.dbKey.dbName}"', tag: 'FluentDb:syncSchema', context: {'changedTables': ctx.history.length});
    return violations;
  }

  /// The settings of one schema run. `ALTER TABLE ... RENAME COLUMN` needs SQLite 3.25 (Android 11+, iOS 13+),
  /// `DROP COLUMN` 3.35; older versions rebuild the table instead.
  Future<FluentSchemaSyncContext> _schemaContext(Database db, FluentGroup group, Duration? archiveRetention, {bool runCode = true, bool? foreignKeys}) async {
    final String version = (await db.rawQuery('SELECT sqlite_version() AS v')).first['v']! as String;
    final List<int> parts = version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final int major = parts.isNotEmpty ? parts[0] : 0;
    final int minor = parts.length > 1 ? parts[1] : 0;
    return FluentSchemaSyncContext(
      removal: group.removedColumns,
      archiveRetention: archiveRetention,
      supportsRenameColumn: major > 3 || (major == 3 && minor >= 25),
      supportsDropColumn: major > 3 || (major == 3 && minor >= 35),
      fullText: group.config.fullText,
      runCode: runCode,
      foreignKeys: foreignKeys ?? group.config.enableForeignKeys,
    );
  }

  /// Deletes archived columns of [group] older than [olderThan] right away.
  Future<void> _purgeArchivedColumns(Database db, FluentGroup group, Duration olderThan) async {
    await ensureFluentSchemaTables(db);
    final FluentSchemaSyncContext ctx = await _schemaContext(db, group, olderThan);
    await _runSchemaTransaction(db, group, ctx, (txn) async {
      for (final FluentProvider dao in group.providerList) {
        await dao.purgeArchives(txn, ctx);
      }
    });
  }
}

/// Thrown inside the plan transaction to roll it back.
class _PlanRollback implements Exception {
  const _PlanRollback();
}
