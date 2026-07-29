// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_provider.dart';

/// Enterprise-grade schema management and reconciliation engine for [FluentProvider].
///
/// The [FluentProviderSchema] extension provides a unified, reactive interface for
/// structural lifecycle management. It bridges the gap between static Dart
/// object models and the dynamic SQL persistence layer, ensuring that table
/// definitions are always in sync with domain model requirements.
///
/// ### Core Responsibilities & Functional Domains
///
/// * **Deterministic Schema Synthesis ([getFullSchema]):** Performs a multi-stage
///   reconciliation process, merging base model definitions with incremental
///   migration overlays and relational foreign-key injections. It acts as the
///   "Source of Truth" for physical storage layout.
/// * **Intelligent DDL Generation:** Provides robust generators for `CREATE TABLE`,
///   `CREATE INDEX`, and junction (pivot) table structures, utilizing safe
///   SQL modes (e.g., `IF NOT EXISTS`) to prevent initialization collisions.
/// * **Smart Migration & Reconstruction ([handleSmartMigration]):** Orchestrates
///   schema evolution workflows. It detects structural drifts (column additions,
///   type mismatches, or legacy renames) and intelligently routes operations
///   between non-destructive `ALTER` statements and full table reconstruction.
/// * **Storage Observability:** Integrates deeply with the [FluentLog] facade, providing
///   granular telemetry for DDL execution, index verification, and schema validation.
///
/// ### Architectural Contract
/// This extension is designed to operate within the global database initialization
/// sequence managed by the `FluentDb`. It relies on the provider's `modelSample`
/// definition and the database's `PRAGMA` introspection capabilities to enforce
/// referential and structural integrity.
///
/// See also:
/// * [FluentLog], for structured DDL audit tracing.
/// * [FluentProviderRelations], for relational traversal orchestration.
extension FluentSchema<T extends FluentStorable> on FluentProvider<T> {
  /// Generates a standardized `CREATE TABLE` SQL statement based on the provider's schema definition.
  ///
  /// This operational utility ensures uniform schema creation across the persistence layer:
  /// * Schema Flattening: Iterates over the full schema definition list and serializes column definitions
  ///   into a multi-line SQL-compliant format.
  /// * Execution Mode: Supports both [SAFE MODE] (using `IF NOT EXISTS`) and [STRICT MODE]
  ///   for clean-slate database migrations.
  /// * Telemetry: Records the generated schema structure for auditability and debugging using the
  ///   unified logging system.
  ///
  /// [alternateName] Overrides the default provider table name if specified.
  /// [ifNotExists] Toggles the inclusion of the `IF NOT EXISTS` clause to prevent constraint errors.
  ///
  /// Returns the formatted `CREATE TABLE` SQL statement string.
  String generateCreateTableSql({String? alternateName, bool ifNotExists = true}) {
    final String targetName = alternateName ?? tableName;
    final List<FluentDbColumn> columns = getFullSchema;

    final String mode = ifNotExists ? "[SAFE MODE]" : "[STRICT MODE]";
    FluentLog.debug('Generating CREATE TABLE DDL statement', tag: '$tableName:schema', context: {'targetTable': targetName, 'executionMode': mode, 'columnCount': columns.length});

    final String existsClause = ifNotExists ? 'IF NOT EXISTS ' : '';
    final String columnPart = columns.map((c) => c.sqlDefinition).join(',\n  ');
    final String rawSql = 'CREATE TABLE $existsClause$targetName (\n  $columnPart\n);';

    FluentLog.sql(rawSql, tag: '$tableName:schema');

    return rawSql;
  }

  /// Generates the SQL statement for a many-to-many junction (pivot) table.
  ///
  /// This utility creates the associative storage container required to link two entities.
  /// * Referential Integrity: Defines foreign key constraints with `ON DELETE CASCADE`
  ///   to ensure that pivot associations are automatically purged when either parent or child
  ///   entities are removed.
  /// * Identity Management: Enforces a composite primary key consisting of both foreign
  ///   keys to prevent duplicate link entries.
  /// * Observability: Traces the DDL generation through the [FluentLog] facade, capturing the
  ///   table identity and foreign key linkage points.
  String generatePivotTableSql(FluentDbRelation rel, FluentProvider childDao) {
    final String pivotName = rel.pivotTable ?? '${tableName}_${childDao.tableName}';

    final String parentKey = rel.localKey ?? '${tableName}_id';
    final String childKey = rel.remoteKey ?? '${childDao.tableName}_id';

    FluentLog.debug('Generating many-to-many pivot table DDL', tag: '$tableName:schema', context: {'pivotTable': pivotName, 'parentLink': parentKey, 'childLink': childKey});

    final String rawSql =
        '''
CREATE TABLE IF NOT EXISTS $pivotName (
  $parentKey INTEGER NOT NULL,
  $childKey INTEGER NOT NULL,
  PRIMARY KEY ($parentKey, $childKey),
  FOREIGN KEY ($parentKey) REFERENCES $tableName (${primaryKeyColumn.name}) ON DELETE CASCADE,
  FOREIGN KEY ($childKey) REFERENCES ${childDao.tableName} (${childDao.primaryKeyColumn.name}) ON DELETE CASCADE
);''';

    FluentLog.sql(rawSql, tag: '$tableName:schema');

    return rawSql;
  }

  /// Generates the `CREATE INDEX` DDL statements for all columns marked with `indexed` property.
  ///
  /// This utility enforces performance optimization across the schema:
  /// * Schema Audit: Scans the provider's [getFullSchema] to identify columns requiring indexing.
  /// * Constraint Safety: Omits the primary key from indexing (as it is indexed by default).
  /// * Operational Traceability: Emits DDL statements through [FluentLog.sql] for auditability.
  ///
  /// Returns a list of `CREATE INDEX` SQL strings ready for database migration execution.
  List<String> generateIndicesSql() {
    final List<FluentDbColumn> columns = getFullSchema;
    final List<String> sqlStatements = [];

    for (final FluentDbColumn col in columns) {
      if (col.indexed && !col.isPrimaryKey) {
        final String indexName = 'idx_${tableName}_${col.name}';
        final String sql = 'CREATE INDEX IF NOT EXISTS $indexName ON $tableName (${col.name});';

        sqlStatements.add(sql);

        FluentLog.sql(sql, tag: '$tableName:schema');
      }
    }

    FluentLog.debug('Schema indices generation completed', tag: '$tableName:schema', context: {'totalIndicesCreated': sqlStatements.length});

    return sqlStatements;
  }

  /// Executes the atomic initialization sequence for the table schema, including DDL generation
  /// and index application.
  ///
  /// This routine acts as the primary gateway for database initialization:
  /// * Atomic Execution: Wraps table creation and index application in a scoped transaction
  ///   to ensure schema consistency.
  /// * Resilience: Implements index-application error handling to prevent failure cascades if
  ///   indices already exist or conflict with legacy schema versions.
  /// * Telemetry: Provides high-fidelity audit trails for the schema migration lifecycle.
  ///
  /// [executor] The database handle used to dispatch SQL commands.
  Future<void> createTable(DatabaseExecutor executor) async {
    FluentLog.info('Executing table initialization sequence', tag: '$tableName:schema', context: {'targetTable': tableName});

    try {
      final String tableSql = generateCreateTableSql();
      final List<String> indexQueries = generateIndicesSql();

      await _runScoped(executor, (exec) async {
        await exec.execute(tableSql);

        if (indexQueries.isNotEmpty) {
          await Future.wait(
            indexQueries.map((query) async {
              try {
                await exec.execute(query);
              } catch (e) {
                FluentLog.warning(
                  'Index initialization skipped or failed',
                  tag: '$tableName:schema',
                  hint: 'This is expected if indices were pre-configured or table schema mismatches exist.',
                  context: {'query': query, 'error': e.toString()},
                );
              }
            }),
          );
        }
      });

      FluentLog.info('Table initialization sequence finalized successfully', tag: '$tableName:schema', context: {'tableName': tableName});
    } catch (e, s) {
      FluentLog.error(
        'Failed to execute CREATE TABLE initialization',
        e,
        s,
        tag: '$tableName:schema',
        hint: 'Verify database connectivity, schema locks, and sufficient write permissions for DDL operations.',
        context: {'tableName': tableName},
      );
      rethrow;
    }
  }

  /// Dispatches a database operation within a unified transaction scope.
  ///
  /// This operational utility abstracts the complexity of transaction management:
  /// * Context Propagation: If an existing [Transaction] is passed, it executes the action
  ///   within that transaction to preserve atomicity.
  /// * Implicit Transaction Initiation: If a [Database] handle is provided, it wraps the
  ///   action in a `transaction` block, ensuring ACID compliance for DDL or multi-step CRUD sequences.
  /// * Passthrough Execution: Fallback support for generic [DatabaseExecutor] handles
  ///   (e.g., [Batch] or others) where explicit transaction nesting is unavailable.
  ///
  /// [executor] The storage access handle (Database, Transaction, or Batch).
  /// [action] The unit-of-work function to execute within the determined scope.
  Future<void> _runScoped(DatabaseExecutor executor, Future<void> Function(DatabaseExecutor) action) {
    // Already in a transaction: execute directly
    if (executor is Transaction) {
      return action(executor);
    }

    // Database handle provided: initiate an atomic transaction block
    if (executor is Database) {
      return executor.transaction((txn) async {
        FluentLog.debug('Initiating atomic transaction scope', tag: '$tableName:transaction');
        await action(txn);
        FluentLog.debug('Atomic transaction scope committed successfully', tag: '$tableName:transaction');
      });
    }

    return action(executor);
  }

  /// Orchestrates an intelligent schema migration pipeline, reconciling the physical storage state
  /// with the current domain model schema.
  ///
  /// This migration engine performs a three-stage reconciliation:
  /// * Schema Analysis: Queries [PRAGMA table_info] to introspect current storage layout.
  /// * Structural Validation: Detects incompatible schema drifts (column removals, renames, or type mutations).
  /// * Reconciliation Routing: Automatically executes `ALTER TABLE` for additive changes or performs
  ///   a full table reconstruction for destructive/complex schema evolutions.
  Future<void> handleSmartMigration(Transaction txn) async {
    refreshSchema();

    FluentLog.debug('Analyzing schema differences for smart migration', tag: '$tableName:migration', context: {'table': tableName});

    try {
      final List<Map<String, Object?>> prisma = await txn.rawQuery("PRAGMA table_info('$tableName')");
      final Map<String, String> existingColumns = {for (final c in prisma) (c['name'] as String): (c['type'] as String).toUpperCase()};

      final List<FluentDbColumn> expectedCols = getFullSchema;
      final Set<String> expectedNames = expectedCols.map((e) => e.name).toSet();
      final Set<String> plannedRenames = {
        for (final FluentDbColumn c in expectedCols)
          if (c.oldName != null) c.oldName!,
      };

      FluentLog.debug('Schema state analysis', tag: '$tableName:migration', context: {'expected': expectedNames.toList(), 'existing': existingColumns.keys.toList()});

      bool needsReconstruction = false;

      // Detect destructive schema changes requiring table recreation
      for (final String name in existingColumns.keys) {
        if (!expectedNames.contains(name) && !plannedRenames.contains(name)) {
          FluentLog.warning('Obsolete column detected: "$name". Triggering reconstruction.', tag: '$tableName:migration');
          needsReconstruction = true;
          break;
        }

        if (plannedRenames.contains(name)) {
          FluentLog.warning('Rename operation pending for: "$name". Triggering reconstruction.', tag: '$tableName:migration');
          needsReconstruction = true;
          break;
        }
      }

      // Detect type incompatibilities
      if (!needsReconstruction) {
        for (final FluentDbColumn col in expectedCols) {
          final String? diskType = existingColumns[col.name];
          if (diskType == null) continue;
          final String codeType = col.type.sql.toUpperCase();
          if (!_isTypeCompatible(diskType, codeType)) {
            FluentLog.warning('Type mismatch for "${col.name}"', tag: '$tableName:migration', hint: 'Disk type $diskType is incompatible with code type ${col.type.sql}.');
            needsReconstruction = true;
            break;
          }
        }
      }

      if (needsReconstruction) {
        FluentLog.debug('Initiating destructive table reconstruction', tag: '$tableName:migration');
        await _reconstructTable(txn, expectedCols, existingColumns.keys.toSet());
      } else {
        // Incremental Additive Migration
        for (final FluentDbColumn col in expectedCols) {
          if (!existingColumns.containsKey(col.name)) {
            final String addSql = 'ALTER TABLE $tableName ADD COLUMN ${col.sqlDefinition}';

            FluentLog.debug('Applying additive migration for column: ${col.name}', tag: '$tableName:migration');
            FluentLog.sql(addSql, tag: '$tableName:migration');

            await txn.execute(addSql);
          }
        }
      }

      final bool structureChanged = needsReconstruction || (existingColumns.length != expectedCols.length);

      await syncIndexes(txn, tablePragma: structureChanged ? null : prisma);
      FluentLog.info('Schema synchronization completed successfully', tag: '$tableName:migration');
    } catch (e, st) {
      FluentLog.error(
        'Critical failure during smart migration sequence',
        e,
        st,
        tag: '$tableName:migration',
        hint: 'Verify that the current transaction is not locked and that the schema definition matches the underlying driver constraints.',
        context: {'tableName': tableName},
      );
      throw MigrationFailedException(tableName, e, st);
    }
  }

  /// Determines structural compatibility between the database's existing column type
  /// and the application's domain model type.
  ///
  /// This compatibility check facilitates "soft migrations" by allowing minor type
  /// variations (e.g., `INTEGER` vs `BIGINT`) without triggering a destructive
  /// table reconstruction.
  ///
  /// * Identity Match: Returns `true` if types are identical.
  /// * Category Match: Validates cross-compatibility within logical type families
  ///   (e.g., all integer-based variants are compatible with each other).
  /// * Strictness: Returns `false` for cross-category mismatches (e.g., `TEXT` vs `INT`),
  ///   forcing a reconstruction to ensure data integrity.
  bool _isTypeCompatible(String diskType, String codeType) {
    if (diskType == codeType) return true;
    if (diskType.contains('INT') && codeType.contains('INT')) return true;
    if (diskType.contains('TEXT') && codeType.contains('TEXT')) return true;
    return false;
  }

  /// Synchronizes database indices with the current schema definition.
  ///
  /// This maintenance routine ensures that all columns marked with the `indexed` flag
  /// have corresponding indices physically present in the SQLite storage layer.
  ///
  /// * Schema Introspection: Uses `PRAGMA table_info` to verify column existence before indexing.
  /// * Atomic Batching: Executes index creation in parallel to minimize initialization latency.
  /// * Resilience: Prevents corruption by aborting index operations for columns missing from the disk.
  Future<void> syncIndexes(DatabaseExecutor executor, {final List<Map<String, Object?>>? tablePragma}) async {
    final List<FluentDbColumn> expectedCols = getFullSchema;
    final Iterable<FluentDbColumn> toIndex = expectedCols.where((c) => c.indexed && !c.isPrimaryKey);

    if (toIndex.isEmpty) {
      return;
    }

    FluentLog.debug('Synchronizing table indices', tag: '$tableName:schema', context: {'totalPotentialIndices': toIndex.length});

    try {
      final List<Map<String, Object?>> tableInfo = tablePragma ?? await executor.rawQuery("PRAGMA table_info('$tableName')");
      final Set<String> actualColumnsOnDisk = {for (final row in tableInfo) (row['name'] as String)};

      for (final FluentDbColumn col in toIndex) {
        final String indexName = 'idx_${tableName}_${col.name}';

        if (!actualColumnsOnDisk.contains(col.name)) {
          FluentLog.warning(
            'Index creation aborted: Target column missing from disk',
            tag: '$tableName:schema',
            hint: 'Ensure your migration pipeline successfully executed the ALTER TABLE column add-op.',
            context: {'tableName': tableName, 'missingColumn': col.name},
          );
          continue;
        }

        final String sql = 'CREATE INDEX IF NOT EXISTS $indexName ON $tableName (${col.name});';

        try {
          FluentLog.sql(sql, tag: '$tableName:schema');

          FluentLog.debug('Verifying/Creating index: $indexName', tag: '$tableName:schema');
          await executor.execute(sql);
        } catch (e, s) {
          FluentLog.error('Failed to create index', e, s, tag: '$tableName:schema', context: {'indexName': indexName});
        }
      }
    } catch (e, s) {
      FluentLog.error('Critical failure during index synchronization', e, s, tag: '$tableName:schema', context: {'tableName': tableName});
    }
  }

  /// Executes a multi-stage destructive reconstruction of the database table.
  ///
  /// This routine is invoked when schema evolution renders the existing storage
  /// structure incompatible (e.g., column renaming, removal, or type shifts).
  ///
  /// * Lifecycle: Temporary table creation -> Data migration -> Original table drop -> Rename -> Index restoration.
  /// * Integrity Guard: Disables `foreign_keys` during the migration to prevent constraint
  ///   violations during the intermediate data-copy phase.
  /// * Auditability: Tracks column lineage and maps legacy column names to new identifiers.
  Future<void> _reconstructTable(Transaction txn, List<FluentDbColumn> newSchema, Set<String> oldColumnNames) async {
    final String tempTableName = 'temp_$tableName';

    FluentLog.info('Initiating destructive table reconstruction', tag: '$tableName:migration', context: {'targetTable': tableName});

    await txn.execute('PRAGMA foreign_keys = OFF;');

    try {
      final String createSql = generateCreateTableSql(alternateName: tempTableName);
      FluentLog.sql(createSql, tag: '$tableName:migration');
      await txn.execute(createSql);

      final List<String> targetCols = [];
      final List<String> sourceCols = [];

      final Set<String> unusedOldCols = Set<String>.of(oldColumnNames);

      for (final FluentDbColumn col in newSchema) {
        if (oldColumnNames.contains(col.name)) {
          targetCols.add(col.name);
          sourceCols.add(col.name);
          unusedOldCols.remove(col.name);
          continue;
        }

        if (col.oldName != null && oldColumnNames.contains(col.oldName)) {
          FluentLog.debug('Mapping legacy column identifier', tag: '$tableName:migration', context: {'oldName': col.oldName, 'newName': col.name});

          targetCols.add(col.name);
          sourceCols.add(col.oldName!);
          unusedOldCols.remove(col.oldName);
        }
      }

      for (final String abandoned in unusedOldCols) {
        FluentLog.warning('Column migration aborted: Data loss imminent', tag: '$tableName:migration', hint: 'Column "$abandoned" is not mapped in the current schema and will be purged.');
      }

      if (targetCols.isNotEmpty) {
        final String targetSql = targetCols.join(', ');
        final String sourceSql = sourceCols.join(', ');
        final String insertSql = 'INSERT INTO $tempTableName ($targetSql) SELECT $sourceSql FROM $tableName';

        FluentLog.sql(insertSql, arguments: const [], tag: '$tableName:migration');
        await txn.execute(insertSql);
      } else {
        FluentLog.warning('Table reconstruction resulted in empty schema match', tag: '$tableName:migration');
      }

      await txn.execute('DROP TABLE IF EXISTS $tableName');
      await txn.execute('ALTER TABLE $tempTableName RENAME TO $tableName');

      FluentLog.info('Table reconstruction finalized successfully', tag: '$tableName:migration', context: {'table': tableName});
    } catch (e, s) {
      FluentLog.error('Critical failure during table reconstruction', e, s, tag: '$tableName:migration', context: {'tableName': tableName});
      rethrow;
    } finally {
      await txn.execute('PRAGMA foreign_keys = ON;');
    }
  }

  /// Assembles and initializes the full table schema by reconciling model definitions,
  /// migration history, relational dependency constraints, and feature extensions.
  ///
  /// This compilation routine executes a deterministic multi-stage lifecycle to generate
  /// the definitive structural mapping for the database storage layer:
  ///
  /// 1. **Base Model Resolution:** Initializes columns from [modelSample], filtering
  ///    out system-reserved fields to prevent definition collisions.
  /// 2. **Migration Overlay:** Sequentially applies incremental DDL schema transformations
  ///    (renames, additions) defined in [modelSample.migrations], ensuring the schema
  ///    remains compatible with versioned data states.
  /// 3. **Relational Mapping:** Dynamically injects foreign-key constraints via
  ///    [FluentRelationsMixin]. It reconciles cross-table references, automatically
  ///    deriving data types from target schemas and applying `ON DELETE` cascading
  ///    logic where defined.
  /// 4. **Feature Extensions Injection:** Safely merges system and extension columns
  ///    (such as soft-delete tracking via [FluentSoftDeletable] and automated
  ///    synchronization columns via [FluentSyncable]) using non-destructive insertion
  ///    to respect any explicit user-defined overrides.
  ///
  /// Additionally, this routine performs internal housekeeping:
  /// * Resolves the primary key (defaulting to 'id' if not explicitly defined).
  /// * Populates schema caches for query optimization (`_cachedTableColumns`, `_cachedRelationKeys`).
  ///
  /// Returns a cached, immutable list of [FluentDbColumn] definitions reflecting
  /// the final physical state of the table.
  List<FluentDbColumn> get getFullSchema {
    if (_cachedFullSchema != null && _isSchemaInitialized) {
      return _cachedFullSchema!;
    }

    _cachedFullSchema = const <FluentDbColumn>[];

    FluentLog.debug('Initiating schema compilation sequence', tag: '$tableName:schema', context: {'table': tableName});

    final Map<String, FluentDbColumn> finalMap = <String, FluentDbColumn>{};
    final List<FluentDbColumn> systemColumns = FluentDbColumn.systemColumns(modelSample.expiryColumn);

    // Stage 1: Base Model Processing
    for (final FluentDbColumn col in modelSample.tableSchema) {
      finalMap[col.name] = col;
    }

    // Stage 2: Migration Overlay
    for (final FluentDbMigration migration in modelSample.migrations) {
      for (final col in migration.columns) {
        if (col.oldName != null) {
          finalMap.remove(col.oldName);
        }
        finalMap[col.name] = col;
      }
    }

    for (final FluentDbColumn sysCol in systemColumns) {
      finalMap[sysCol.name] = sysCol;
    }

    // Stage 3: Relational Hydration (Foreign Key Injection)
    if (this is FluentRelationsMixin) {
      final mixin = this as FluentRelationsMixin;

      void processRelation(FluentDbRelation rel, String collectionName) {
        if (rel.relationType == FluentDbRelationType.manyToMany) return;
        if (rel.modelType == FluentStorable) {
          return;
        }

        try {
          String? targetTable = rel.targetTable;
          String? targetPk = rel.remoteKey;

          final FluentProvider<FluentStorable> targetProvider = relatedProvider(rel.modelType);
          if (targetTable == null || targetPk == null) {
            targetTable ??= targetProvider.tableName;
            targetPk ??= targetProvider.modelSample.primaryKey.name;
          }

          final String? keyName = (rel.relationType == FluentDbRelationType.manyToOne) ? rel.localKey : (rel.relationType == FluentDbRelationType.oneToMany ? null : rel.localKey);

          if (keyName != null) {
            final existingColumn = finalMap[keyName];

            if (existingColumn != null && existingColumn.isPrimaryKey) {
              return;
            }

            final String fkSql =
                'REFERENCES $targetTable($targetPk) '
                'ON DELETE ${rel.onDeleteCascade ? "CASCADE" : "SET NULL"}';

            if (existingColumn != null) {
              existingColumn.customSql = fkSql;
              existingColumn.indexed = true;
            } else {
              FluentDbDataType targetDataType = FluentDbDataType.integer;
              final FluentDbColumn targetColMatch = targetProvider.modelSample.tableSchema.firstWhere(
                (c) => c.name == targetPk,
                orElse: () => targetProvider.modelSample.migrations.expand((m) => m.columns).firstWhere((c) => c.name == targetPk),
              );
              targetDataType = targetColMatch.type;
              finalMap[keyName] = FluentDbColumn(name: keyName, type: targetDataType, customSql: fkSql, indexed: true);
            }
          }
        } catch (e, s) {
          FluentLog.error('Failed to resolve relational mapping', e, s, tag: '$tableName:relations', context: {'relationMapToKey': rel.mapToKey});
        }
      }

      for (final FluentDbRelation<FluentStorable, FluentStorable> rel in mixin.resolvedRelations.values) {
        processRelation(rel, 'SYNC');
      }
      for (final FluentDbRelation<FluentStorable, FluentStorable> rel in mixin.incomingRelations.values) {
        processRelation(rel, 'INCOMING');
      }
    }

    if (modelSample is FluentSoftDeletable) {
      final FluentSoftDeletable sample = modelSample as FluentSoftDeletable;
      finalMap.putIfAbsent(sample.softDeleteColumn, () => FluentDbColumn.systemSoftDelete(sample.softDeleteColumn));
    }

    if (this is FluentSyncable) {
      final FluentSyncable syncProvider = this as FluentSyncable;
      for (final FluentDbColumn col in syncProvider.syncColumns) {
        finalMap.putIfAbsent(col.name, () => col);
      }
    }

    final List<FluentDbColumn> finalizedSchema = finalMap.values.toList(growable: false);

    _cachedTableColumns = finalMap.keys.toSet();

    _cachedPrimaryKey = modelSample.primaryKey;

    final bool isRelationsProvider = this is FluentRelationsMixin<T>;
    _hasRelations = isRelationsProvider;

    if (isRelationsProvider) {
      final castedMixin = this as FluentRelationsMixin<T>;
      _relationsMixin = castedMixin;
      _cachedRelationKeys = castedMixin.resolvedRelations.values.map((r) => r.mapToKey).toSet();
    } else {
      _relationsMixin = null;
      _cachedRelationKeys = const <String>{};
    }

    _cachedFullSchema = finalizedSchema;
    _isSchemaInitialized = true;

    FluentLog.info('Schema compilation finalized', tag: '$tableName:schema', context: {'finalColumnCount': finalizedSchema.length});
    return _cachedFullSchema!;
  }

  /// Ensures that all required pivot tables for [manyToMany] relationships are
  /// present in the database schema.
  ///
  /// This method performs an introspection of the [FluentRelationsMixin] registered
  /// within the [dao]. If a [FluentDbRelationType.manyToMany] is detected, it
  /// invokes the schema generator to produce and execute the necessary DDL
  /// (Data Definition Language) to initialize the junction table.
  ///
  /// [executor] The database transaction or instance to execute the schema setup against.
  /// [dao] The provider instance being synchronized.
  Future<void> syncPivotTables(DatabaseExecutor executor, Set<String> existingTables) async {
    final bool hasRelations = this is FluentRelationsMixin;
    FluentLog.debug(
      'Syncing pivot tables for table',
      tag: 'FluentDb:syncSchema',
      context: {'table': tableName, 'hasRelations': hasRelations, 'totalRelations': hasRelations ? (this as FluentRelationsMixin).resolvedRelations.length : 0},
    );

    if (!hasRelations) return;

    final Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> relations = (this as FluentRelationsMixin).resolvedRelations;
    final List<String> relationDetails = relations.entries.map((e) => '${e.key}(${e.value.relationType.name})').toList();
    FluentLog.debug('Checking M2M pivot table integrity', tag: '$tableName:syncPivotTables', context: {'totalRelations': relations.length, 'relationsList': relationDetails.join(', ')});

    for (final FluentDbRelation<FluentStorable, FluentStorable> rel in relations.values) {
      if (rel.relationType == FluentDbRelationType.manyToMany && rel.pivotTable != null) {
        final String pivotName = rel.pivotTable!;

        if (existingTables.contains(pivotName)) {
          FluentLog.debug('Pivot table $pivotName already exists, skipping creation', tag: '$tableName:syncPivotTables');
          continue;
        }

        final FluentProvider<FluentStorable> childDao = relatedProvider(rel.modelType);

        FluentLog.info('Creating missing pivot table: $pivotName', tag: '$tableName:syncPivotTables', context: {'parent': tableName, 'child': childDao.tableName});

        try {
          final String sql = generatePivotTableSql(rel, childDao);
          await executor.execute(sql);

          existingTables.add(pivotName);
          FluentLog.debug('Pivot table ${rel.pivotTable} verified successfully', tag: '$tableName:syncPivotTables');
        } catch (e, st) {
          FluentLog.error('Failed to sync pivot table: ${rel.pivotTable}', e, st, tag: '$tableName:syncPivotTables');
          rethrow;
        }
      }
    }
  }

  /// Invalidates the schema cache and forces a re-compilation on the next access.
  ///
  /// This utility is critical for maintaining consistency during runtime schema
  /// mutations (e.g., dynamic migrations or hot-swapping model definitions).
  ///
  /// * Lifecycle: Resets `_cachedFullSchema` and `_isSchemaInitialized` flags.
  /// * Telemetry: Traces the invalidation event to allow for correlation with
  ///   subsequent "schema compilation" log events.
  void refreshSchema() {
    FluentLog.debug('Invalidating schema cache', tag: '$tableName:schema', context: {'tableName': tableName});
    _cachedFullSchema = null;
    _isSchemaInitialized = false;
  }
}
