// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../core/core.dart';
import '../core/fluent_sqlite_internal.dart';
import '../exceptions/exceptions.dart';
import '../interfaces/interfaces.dart';
import 'models.dart';

/// Represents a logical grouping of database providers (DAOs) associated
/// with a specific database instance.
///
/// This class serves as the configuration anchor for the [FluentEngine],
/// defining which DAO providers belong to which database file and applying
/// a specific [SQLitePerformanceConfig] to all operations within that group.
class FluentGroup {
  /// The unique identifier for this database instance.
  ///
  /// The [FluentDbKey] defines the underlying file name for the database
  /// (e.g., using an [Enum] or a custom [Class] implementation).
  /// The system will automatically append the '.db' extension during
  /// the initialization process.
  final FluentDbKey dbKey;

  /// The set of [FluentProvider] associated with this database.
  /// Using a [Set] ensures that each provider is registered exactly once.
  final Set<FluentProvider> providerList;

  /// The performance tuning parameters (e.g., WAL mode, cache size, journal mode)
  /// applied to the SQLite connection handle for this specific database.
  final SQLitePerformanceConfig performanceConfig;

  /// Creates a [FluentGroup] configuration.
  ///
  /// * [dbName]: The unique name of the database file.
  /// * [providerList]: The collection of Data Access Objects for this database.
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
  FluentGroup({required this.dbKey, required Iterable<FluentProvider> providerList, this.performanceConfig = const SQLitePerformanceConfig()}) : providerList = providerList.toSet() {
    _validateTableNames();
  }

  /// Creates a copy of this [FluentGroup] with the specified fields replaced.
  FluentGroup copyWith({SQLitePerformanceConfig? performanceConfig}) => FluentGroup(dbKey: dbKey, providerList: providerList, performanceConfig: performanceConfig ?? this.performanceConfig);

  /// Performs schema validation for the current [FluentGroup] by ensuring
  /// that no two [FluentProvider] instances map to the same table name.
  ///
  /// This check prevents "Data Collision" bugs where operations meant for one
  /// DAO inadvertently affect the data of another due to shared table mapping.
  void _validateTableNames() {
    final Map<String, Type> names = <String, Type>{};
    for (final FluentProvider dao in providerList) {
      final String tableName = dao.tableName;
      if (names.containsKey(tableName)) {
        final String existingClass = names[tableName].toString();
        final String newClass = dao.runtimeType.toString();
        final FluentSchemaException dbSchemaException = FluentSchemaException(
          modelName: tableName,
          details:
              'Conflict detected! Both "${names[tableName]}" and '
              '"${dao.runtimeType}" are trying to use the same table name "$tableName". '
              'Each Provider in a group must have a unique tableName.',
        );

        FluentLog.error(
          'Schema validation failed',
          dbSchemaException,
          hint:
              'HINT: Check the "tableName" getter in both '
              '$existingClass and $newClass. Ensure they are explicitly defined '
              'and not relying on an accidental default or shared constant.',
          StackTrace.current,
          tag: 'FluentGroup:validation',
        );

        throw dbSchemaException;
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
    return 'FluentGroup{dbName: $dbKey.dbName, providerList: $providerList, performanceConfig: $performanceConfig}';
  }
}
