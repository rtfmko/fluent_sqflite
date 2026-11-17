// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart' show getDatabasesPath, inMemoryDatabasePath;

import '../core/core.dart';
import '../core/fluent_sqlite_internal.dart';
import '../exceptions/exceptions.dart';
import '../interfaces/interfaces.dart';
import '../relations/fluent_relation.dart';
import 'models.dart';

/// Decides whether the schema changes of [plan] may be applied (`FluentGroup.onMigrationPlan`).
typedef MigrationPlanCallback = FutureOr<bool> Function(FluentMigrationPlan plan);

/// One database: its key (file name), the providers of its tables, and its settings ([FluentDbConfig] plus the
/// schema options below). Passed to `FluentDb.init`.
class FluentGroup {
  /// The key of this database (an enum or a class implementing [FluentDbKey]); its `dbName` plus `.db` is the
  /// file name.
  final FluentDbKey dbKey;

  /// The providers of the tables of this database, each registered once. Two providers with the same table name
  /// throw a [FluentSchemaException] when the group is created.
  final Set<FluentProvider> providerList;

  /// Settings of this database: SQLite pragmas and overrides of the global `FluentConfig` (see [FluentDbConfig]).
  final FluentDbConfig config;

  /// Folder of the database file. Defaults to the platform databases folder ([getDatabasesPath]).
  ///
  /// Use it to keep a database next to other app files, on external storage, or in a temp folder.
  final String? directory;

  /// Opens an existing database read-only (e.g. a prebuilt catalog shipped with the app).
  ///
  /// Schema synchronization, migrations and maintenance are skipped and write operations fail; the full-text index
  /// the file was built with is used when it fits the model. A missing file fails `init` with
  /// `FluentErrorCode.databaseNotFound`. Ignored (with a warning) for an [inMemory] database.
  final bool readOnly;

  /// What happens to columns that disappeared from a model: kept as an archive (default) or dropped.
  final FluentColumnRemoval removedColumns;

  /// Archived columns older than this are deleted at start-up. `null` keeps them until
  /// `FluentDb.purgeArchivedColumns` or a `dropColumns` migration step removes them.
  final Duration? archiveRetention;

  /// How many schema history entries are kept per table.
  final int historyLimit;

  /// Delete and recreate the database file when its initialization fails: every database of that `init` is closed,
  /// the file deleted, and the whole `init` runs once more. A plan refused by [onMigrationPlan] never deletes it.
  ///
  /// Destroys all data of this database — meant for throw-away caches only. Off by default:
  /// a failure is reported as an exception with a hint and the file is left untouched.
  final bool resetOnSchemaError;

  /// Type used for `FluentRelation.auto` lists when the database gives no clear signal
  /// (single models default to [FluentRelationType.one]). `manyToMany` never deletes shared data.
  final FluentRelationType autoRelationFallback;

  /// Decides on the schema changes of a start before they are applied: called with the plan (see
  /// `FluentDb.planMigrations`) when something would change; returning `false` stops the start of this database
  /// with a `FluentSchemaException` (`migrationRefused`) and changes nothing.
  ///
  /// ```dart
  /// FluentGroup(..., onMigrationPlan: (plan) => !plan.losesData) // never drop data without a release that allows it
  /// ```
  final MigrationPlanCallback? onMigrationPlan;

  /// Keeps the database in memory only: nothing is written to disk and all data is gone when it is closed
  /// (`FluentDb.close`) or the app stops. Meant for tests and throw-away caches; [directory] is ignored.
  final bool inMemory;

  /// Creates a group: [dbKey] names the database, [providerList] holds the providers of its tables.
  ///
  /// **Example:**
  /// ```dart
  /// final FluentGroup cacheGroup = FluentGroup(
  ///   dbKey: AppDatabases.cache,
  ///   providerList: [
  ///     ImageCacheProvider(),
  ///     SessionProvider(),
  ///   ],
  /// );
  /// ```
  FluentGroup({
    required this.dbKey,
    required Iterable<FluentProvider> providerList,
    this.config = const FluentDbConfig(),
    this.directory,
    this.readOnly = false,
    this.removedColumns = FluentColumnRemoval.archive,
    this.archiveRetention = const Duration(days: 30),
    this.historyLimit = 100,
    this.resetOnSchemaError = false,
    this.autoRelationFallback = FluentRelationType.manyToMany,
    this.inMemory = false,
    this.onMigrationPlan,
  }) : providerList = providerList.toSet() {
    _validateTableNames();
  }

  /// Creates a copy of this [FluentGroup] with the given fields replaced (same [dbKey] and providers). An argument
  /// left out keeps the current value; the nullable [directory], [archiveRetention] and [onMigrationPlan] can be
  /// cleared by passing `null`:
  ///
  /// ```dart
  /// await FluentDb.restart(update: (groups) => [for (final g in groups) g.copyWith(archiveRetention: null)]);
  /// ```
  FluentGroup copyWith({
    FluentDbConfig? config,
    Object? directory = _keep,
    bool? readOnly,
    FluentColumnRemoval? removedColumns,
    Object? archiveRetention = _keep,
    int? historyLimit,
    bool? resetOnSchemaError,
    FluentRelationType? autoRelationFallback,
    bool? inMemory,
    Object? onMigrationPlan = _keep,
  }) => FluentGroup(
    dbKey: dbKey,
    providerList: providerList,
    config: config ?? this.config,
    directory: identical(directory, _keep) ? this.directory : directory as String?,
    readOnly: readOnly ?? this.readOnly,
    removedColumns: removedColumns ?? this.removedColumns,
    archiveRetention: identical(archiveRetention, _keep) ? this.archiveRetention : archiveRetention as Duration?,
    historyLimit: historyLimit ?? this.historyLimit,
    resetOnSchemaError: resetOnSchemaError ?? this.resetOnSchemaError,
    autoRelationFallback: autoRelationFallback ?? this.autoRelationFallback,
    inMemory: inMemory ?? this.inMemory,
    onMigrationPlan: identical(onMigrationPlan, _keep) ? this.onMigrationPlan : onMigrationPlan as MigrationPlanCallback?,
  );

  /// "Keep the current value" in [copyWith] (so `null` can clear a field).
  static const Object _keep = Object();

  /// Full path of the database file ([inMemoryDatabasePath] for an [inMemory] database).
  Future<String> resolvePath() async => inMemory ? inMemoryDatabasePath : join(directory ?? await getDatabasesPath(), '${dbKey.dbName}.db');

  /// Throws a [FluentSchemaException] when two providers of the group use the same table name.
  void _validateTableNames() {
    final Map<String, Type> names = <String, Type>{};
    for (final FluentProvider dao in providerList) {
      final String tableName = dao.tableName;
      if (names.containsKey(tableName)) {
        throw FluentLog.raise(
          FluentSchemaException(
            '${names[tableName]} and ${dao.runtimeType} both use table "$tableName" in database "${dbKey.dbName}".',
            modelName: tableName,
            hint: 'Give one of them its own table: @override String get tableName => \'...\'; (each provider of a group needs a unique table).',
          ),
          tag: 'FluentGroup:validation',
        );
      }
      names[tableName] = dao.runtimeType;
    }
  }

  @override
  bool operator ==(Object other) => identical(this, other) || other is FluentGroup && runtimeType == other.runtimeType && dbKey.dbName == other.dbKey.dbName;

  @override
  int get hashCode => dbKey.dbName.hashCode;

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentGroup{');
    final List<String> parts = [];

    parts.add('dbKey: $dbKey');
    parts.add('providerCount: ${providerList.length}');
    parts.add('config: $config');
    // The folder is a path: shown only when the log may show paths (showSqlArguments).
    if (directory != null) parts.add(FluentLog.showSqlArguments ? 'directory: $directory' : 'directory: <path hidden>');
    if (readOnly) parts.add('readOnly: true');

    sb.write(parts.join(', '));
    sb.write('}');
    return sb.toString();
  }
}
