// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'models.dart';

/// Defines a schema evolution step for a [FluentStorable] model.
///
/// [FluentDbMigration] provides a structured way to apply schema changes (like adding
/// new columns) or executing arbitrary SQL during database upgrades.
class FluentDbMigration {
  /// The list of new columns to be added or updated in the schema.
  final List<FluentDbColumn> columns;

  /// Optional raw SQL commands to be executed during the migration
  /// (e.g., table renaming, index creation, or data transformation).
  // final List<String>? rawSql;

  /// Creates a [FluentDbMigration] instance representing a specific schema evolution step.
  ///
  /// This constructor defines the structural changes required for an incremental
  /// update of the database schema.
  ///
  /// [columns] A collection of [FluentDbColumn] definitions to be added or modified.
  /// [rawSql] An optional list of custom SQL strings for operations that cannot
  /// be represented by column metadata alone, such as dropping constraints,
  /// creating indexes, or migrating legacy data.
  const FluentDbMigration({required this.columns});

  @override
  String toString() {
    return 'FluentDbMigration{columns: $columns}';
  }
}
