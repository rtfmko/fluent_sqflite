// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../interfaces/interfaces.dart';

/// Stable identifiers of fluent_sqflite errors ([FluentException.code]).
///
/// Use them to react to a specific error or to show a localized message; the English [FluentException.message]
/// is meant for developers and may change between versions.
enum FluentErrorCode {
  /// The database (or a provider) was used before `FluentDb.init` finished.
  notInitialized,

  /// A database name contains characters other than letters, digits and `_`.
  invalidDatabaseName,

  /// No database group with the requested key is open, or the file of a read-only group does not exist.
  databaseNotFound,

  /// No provider is registered for the requested model / table.
  providerNotFound,

  /// The model is registered in several database groups and the call did not say which one to use.
  ambiguousProvider,

  /// Any other setup / configuration mistake.
  invalidConfiguration,

  /// The model, its columns or keys contradict each other or the stored schema.
  schemaConflict,

  /// A migration step failed; the schema change was rolled back.
  migrationFailed,

  /// `FluentGroup.onMigrationPlan` refused the schema changes of a start; nothing was changed.
  migrationRefused,

  /// An argument of a call is not valid.
  invalidArgument,

  /// A key value does not identify a row of the table (wrong columns, null, composite key given as one value).
  invalidKey,

  /// A value cannot be stored in SQLite (unsupported type).
  unsupportedValue,

  /// Another row already has the value of a UNIQUE column / key.
  uniqueViolation,

  /// The referenced row does not exist (FOREIGN KEY).
  foreignKeyViolation,

  /// A NOT NULL column got no value.
  notNullViolation,

  /// A value is outside the range allowed by a CHECK constraint.
  checkViolation,

  /// A write to a database opened read-only.
  readOnly,

  /// The table does not exist in the database.
  noSuchTable,

  /// SQLite rejected the statement (syntax error, unknown column, ...).
  sqlError,

  /// A relation is declared or used incorrectly.
  invalidRelation,

  /// The provider does not support synchronization (`FluentSyncable` is missing).
  syncNotSupported,

  /// The server answered with an error status.
  apiError,

  /// A synchronization step failed.
  syncFailed,

  /// A `syncWithServer` was stopped through its `FluentCancelToken`.
  syncCancelled,

  /// The call came while the databases were closed (`FluentDb.close`), or they were closed before it ran.
  engineClosed,

  /// An unexpected internal failure.
  engineError,
}

/// A setup or configuration mistake: not initialized, unknown or ambiguous provider, invalid database name, ...
class FluentConfigException extends FluentException {
  /// Creates a configuration error.
  FluentConfigException(super.message, {super.code = FluentErrorCode.invalidConfiguration, super.hint, super.cause, super.stackTrace});
}

/// The model's schema is inconsistent, or a migration failed.
class FluentSchemaException extends FluentException {
  /// Creates a schema error for [modelName] (and [columnName], when one column is at fault).
  FluentSchemaException(super.message, {this.modelName, this.columnName, super.code = FluentErrorCode.schemaConflict, super.hint, super.cause, super.stackTrace});

  /// The model (or table) at fault.
  final String? modelName;

  /// The column at fault, if one.
  final String? columnName;
}

/// An argument of a call is not valid: unknown columns, a wrong key, a value SQLite cannot store, ...
class FluentArgumentException extends FluentException {
  /// Creates an argument error about [argument].
  FluentArgumentException(this.argument, String details, {super.code = FluentErrorCode.invalidArgument, super.hint, super.cause, super.stackTrace}) : super('Invalid $argument: $details');

  /// The argument (or field) at fault.
  final String argument;
}

/// A write violates a UNIQUE, FOREIGN KEY, NOT NULL or CHECK constraint.
class FluentConstraintException extends FluentException {
  /// Creates a constraint error; [code] says which constraint.
  FluentConstraintException(super.message, {required super.code, super.hint, super.cause, super.stackTrace});
}

/// SQLite rejected a statement: SQL error, missing table, read-only database.
class FluentQueryException extends FluentException {
  /// Creates a query error.
  FluentQueryException(super.message, {super.code = FluentErrorCode.sqlError, super.hint, super.cause, super.stackTrace});
}

/// A relation is declared or used incorrectly.
class FluentRelationException extends FluentException {
  /// Creates a relation error.
  FluentRelationException(super.message, {super.code = FluentErrorCode.invalidRelation, super.hint, super.cause, super.stackTrace});
}

/// Synchronization failed or is not available.
class FluentSyncException extends FluentException {
  /// Creates a sync error; [statusCode] is the HTTP status of a failed API answer.
  FluentSyncException(super.message, {this.statusCode, super.code = FluentErrorCode.syncFailed, super.hint, super.cause, super.stackTrace});

  /// The HTTP status code of the failed API answer, if any.
  final int? statusCode;
}

/// The call was not run: the databases were closed before it ran, or it came after `FluentDb.close`.
class FluentCancelledException extends FluentException {
  /// Creates a cancellation error.
  FluentCancelledException(super.message, {super.code = FluentErrorCode.engineClosed, super.hint, super.cause, super.stackTrace});
}

/// An internal failure of the task engine.
class FluentEngineException extends FluentException {
  /// Creates an engine error.
  FluentEngineException(super.message, {super.code = FluentErrorCode.engineError, super.hint, super.cause, super.stackTrace});
}
