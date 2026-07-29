// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../core/fluent_sqlite_internal.dart';
import '../interfaces/interfaces.dart';

/// Exception thrown when attempting to perform a database operation
/// before the provider is initialized.
///
/// This usually happens if a DAO is accessed before the global initialization
/// logic or [FluentGroup] setup is complete.
class FluentNotInitializedException extends FluentException {
  /// The name of the provider that was accessed.
  final String providerName;

  /// Creates a [FluentNotInitializedException].
  ///
  /// * [providerName]: The name of the provider that was accessed.
  /// * [stackTrace]: Stack trace to locate the call point in the code.
  FluentNotInitializedException(this.providerName, [StackTrace? stackTrace])
    : super(
        'The database for "$providerName" has not been initialized. '
        'Ensure that you have called "await FluentDb.init()" before accessing this DAO.',
        stackTrace,
      );
}

/// Exception thrown when a [FluentDbMigration] fails to execute.
///
/// Wraps the original database error to help identify which table and
/// which migration step caused the failure.
class MigrationFailedException extends FluentException {
  /// The name of the table where the migration was being applied.
  final String tableName;

  /// Creates a [MigrationFailedException].
  ///
  /// * [tableName]: The name of the table where the migration failed.
  /// * [originalError]: The raw error from the database engine.
  /// * [stackTrace]: Full stack trace for deep debugging.
  MigrationFailedException(this.tableName, dynamic originalError, StackTrace stackTrace) : super('Migration failed in table "$tableName".', stackTrace, originalError);
}

/// Exception thrown when [FluentDb] cannot find a provider for a given model type.
///
/// Most commonly occurs during recursive operations like `updateWithRelations`
/// or `add` when a related model's DAO hasn't been registered.
class ProviderNotFoundException extends FluentException {
  /// The type of the model that lacks a registered provider.
  final String searchTarget;

  /// Creates a [ProviderNotFoundException].
  ///
  /// * [modelType]: The type of model (e.g., AddressModel) that is missing a DAO.
  /// * [stackTrace]: Helps pinpoint which relation caused the error.
  ProviderNotFoundException(this.searchTarget, {StackTrace? stackTrace})
    : super(
        'No registered DAO found for "$searchTarget". '
        'Check if you added it to the FluentGroup in your init() call.',
        stackTrace,
      );
}

/// Exception thrown when [FluentDb] configuration is invalid or inconsistent.
///
/// This typically occurs during the `init()` phase if there are issues with
/// database naming, duplicate groups, or misconfigured performance settings.
class FluentConfigurationException extends FluentException {
  /// The specific reason for the configuration failure.
  final String reason;

  /// Creates a [FluentConfigurationException].
  ///
  /// * [reason]: A clear explanation of why the configuration failed.
  /// * [stackTrace]: Useful for tracing back to the incorrect setup call.
  FluentConfigurationException(this.reason, {StackTrace? stackTrace}) : super('FluentDb configuration error: $reason', stackTrace);
}

/// Exception thrown when a lookup operation results in multiple potential providers.
///
/// Occurs when a specific model type or table exists in multiple database groups
/// simultaneously. To resolve this, the caller must specify a [dbName].
class AmbiguousProviderException extends FluentException {
  /// The model type or table name that was requested.
  final String searchTarget;

  /// The list of database group names where this target was found.
  final List<String> availableGroups;

  /// Creates an [AmbiguousProviderException].
  ///
  /// * [searchTarget]: The model type or table that caused the ambiguity.
  /// * [availableGroups]: List of databases that contain this target.
  /// * [stackTrace]: Helps track where the ambiguous lookup was performed.
  AmbiguousProviderException(this.searchTarget, this.availableGroups, {StackTrace? stackTrace})
    : super(
        'Ambiguous resolution: "$searchTarget" exists in multiple databases: ${availableGroups.join(', ')}. '
        'You must explicitly provide the "dbName" parameter to resolve this conflict.',
        stackTrace,
      );
}

/// Exception thrown when a [FluentGroup] is initialized with an invalid database name.
///
/// Database names must adhere to strict formatting rules to ensure compatibility
/// across different file systems and prevent security issues like path traversal.
class FluentDatabaseNameException extends FluentException {
  /// The invalid name that caused the failure.
  final String invalidName;

  /// Creates a [FluentDatabaseNameException].
  ///
  /// * [invalidName]: The name that failed validation.
  /// * [stackTrace]: Pinpoints where the invalid configuration was defined.
  FluentDatabaseNameException(this.invalidName, {StackTrace? stackTrace})
    : super(
        'Invalid database name: "$invalidName". '
        'Database names must contain only alphanumeric characters and underscores (a-z, A-Z, 0-9, _).',
        stackTrace,
      );
}

/// Exception thrown when a value in [buildJson] cannot be converted to a valid SQLite type.
///
/// SQLite supports NULL, INTEGER, REAL, TEXT, and BLOB. If you pass a complex object
/// (like another Model) directly into the map, this error will be triggered.
class InvalidSqlTypeException extends FluentException {
  /// The key in the JSON map that caused the failure.
  final String key;

  /// The actual value that is not supported.
  final dynamic value;

  /// Creates an [InvalidSqlTypeException].
  ///
  /// * [key]: The database column name where the error occurred.
  /// * [value]: The unsupported object (e.g., a complex Class or Model).
  /// * [stackTrace]: Helps pinpoint which relation caused the error.
  InvalidSqlTypeException(this.key, this.value, {StackTrace? stackTrace, String? details})
    : super(
        'The value for key "$key" has an unsupported type: ${value.runtimeType}. '
        'SQLite only supports simple types. If this is a relation, ensure it is handled via FluentRelation.\n'
        'Value: $value',
        stackTrace,
      );
}

/// Exception thrown when a database batch operation encounters failures.
///
/// This exception encapsulates the results of a multi-operation batch,
/// allowing the caller to inspect specific errors for each individual task
/// that failed during the transaction.
class FluentBatchException extends FluentException {
  /// The list of results from the batch operation (typically a mix of
  /// [int] success values and [Exception] objects for failures).
  final List<dynamic> results;

  /// The name of the table targeted by the failed batch operation.
  final String tableName;

  /// Creates a [FluentBatchException].
  ///
  /// * [tableName]: The table involved in the batch operation.
  /// * [results]: The outcome list containing successes and errors.
  /// * [originalError]: The underlying database error (if applicable).
  /// * [stackTrace]: The location where the batch operation failed.
  FluentBatchException(this.tableName, this.results, {dynamic originalError, StackTrace? stackTrace})
    : super('Batch operation failed for table "$tableName". Check "results" for details.', stackTrace, originalError);

  @override
  String toString() {
    final List<Exception> errors = results.whereType<Exception>().toList();
    final StringBuffer sb = StringBuffer('FluentBatchException: [$tableName] ');

    sb.write('${errors.length} error(s) occurred during batch execution.');

    if (errors.isNotEmpty) {
      const int displayLimit = 3;
      for (int i = 0; i < errors.length && i < displayLimit; i++) {
        sb.write('\n  - ${errors[i]}');
      }
      if (errors.length > displayLimit) {
        sb.write('\n  ... and ${errors.length - displayLimit} more error(s).');
      }
    }

    return sb.toString();
  }
}

/// Exception thrown when a database constraint (e.g., UNIQUE, FOREIGN KEY,
/// NOT NULL) is violated during a write operation.
///
/// This helps developers identify specific data integrity issues, such as
/// duplicate entry attempts or orphaned foreign keys, which are common
/// in reactive database-driven applications.
class FluentConstraintException extends FluentException {
  /// Creates a [FluentConstraintException].
  ///
  /// * [message]: A human-readable description of the violated constraint.
  /// * [originalError]: The underlying SQLite error, useful for debugging
  ///   specific constraint types (e.g., SQLITE_CONSTRAINT_UNIQUE).
  /// * [stackTrace]: The execution path where the violation occurred.
  FluentConstraintException(String message, {dynamic originalError, StackTrace? stackTrace}) : super(message, stackTrace, originalError);
}

/// Exception thrown when the application's data model definition conflicts
/// with the actual physical structure of the database table (e.g., missing
/// columns, type mismatches, or schema versioning drift).
///
/// This exception acts as a safeguard during development, surfacing mismatches
/// early before they cause runtime data corruption or silent query failures.
class FluentSchemaException extends FluentException {
  /// The identifier (e.g., class name or table name) of the model in conflict.
  final String modelName;

  /// The specific column, if any, that caused the validation failure.
  final String? columnName;

  /// Creates a [FluentSchemaException].
  ///
  /// * [modelName]: The model being validated.
  /// * [columnName]: The specific field/column causing the issue (optional).
  /// * [details]: A descriptive explanation of why the schema conflict occurred.
  /// * [stackTrace]: The point in the initialization or migration logic where
  ///   the mismatch was detected.
  FluentSchemaException({required this.modelName, this.columnName, required String details, StackTrace? stackTrace})
    : super('Schema conflict in model "$modelName"${columnName != null ? ' (column: "$columnName")' : ''}: $details', stackTrace);
}

/// The default implementation of [FluentDbException].
///
/// This class serves as the standard error type for generic failures
/// within the library when a more specific exception type (e.g., [FluentSchemaException])
/// is not applicable.
class FluentBaseException extends FluentException {
  /// Creates a [FluentBaseException].
  ///
  /// * [message]: A human-readable description of the error.
  /// * [stackTrace]: The location in code where the error occurred.
  /// * [originalError]: The underlying technical error, if available.
  FluentBaseException(String message, [dynamic originalError, StackTrace? stackTrace]) : super(message, stackTrace, originalError);
}

/// Exception thrown when a method receives invalid arguments.
///
/// Use this to replace standard [ArgumentError] to maintain consistency
/// with the `fluent_db_exceptions` library and enable centralized error
/// handling for validation issues.
class FluentArgumentException extends FluentException {
  /// Creates a [FluentArgumentException].
  ///
  /// * [argumentName]: The name of the parameter that is invalid.
  /// * [details]: A descriptive message explaining why the argument is invalid.
  FluentArgumentException(String argumentName, String details, [StackTrace? stackTrace]) : super('Invalid argument "$argumentName": $details', stackTrace);
}

/// Exception thrown when the [FluentEngine] encounters a systemic failure.
///
/// These errors typically indicate a breakdown in the orchestration layer,
/// such as thread blocking, or internal
/// state corruption.
class FluentEngineException extends FluentException {
  /// The specific component within the engine that failed.
  final String component;

  /// The engine working task
  final FluentTask? task;

  /// Creates a [FluentEngineException].
  ///
  /// * [message]: A brief explanation of the engine failure.
  /// * [component]: The internal module where the failure originated.
  /// * [engineState]: Optional snapshot of the engine state for debugging.
  /// * [stackTrace]: The execution path leading to the systemic failure.
  FluentEngineException(String message, {required this.component, this.task, dynamic originalError, StackTrace? stackTrace}) : super(message, stackTrace, originalError);

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentEngineException: [$component] $message');

    if (task != null) {
      sb.write('\nTask: $task');
    }

    if (originalError != null) {
      sb.write('\nDetails: $originalError');
    }

    return sb.toString();
  }
}

/// Exception thrown when a synchronization operation between the local
/// database and a remote server fails.
///
/// Use this to signal errors related to network transport, invalid sync
/// strategies, or missing callbacks. This exception allows for centralized
/// error handling within the synchronization pipeline.
class FluentSyncException extends FluentException {
  /// Creates a [FluentSyncException].
  ///
  /// * [message]: A descriptive explanation of the sync failure.
  /// * [stackTrace]: The execution path leading to the failure.
  FluentSyncException(String message, {StackTrace? stackTrace}) : super(message, stackTrace);
}

/// Exception thrown when a low-level SQLite operation or relational
/// constraint violation occurs.
///
/// This exception is used to signal critical database-layer failures,
/// such as schema inconsistencies, failed batch executions, or unresolved
/// entity relationships. It facilitates centralized error tracking and
/// debugging of complex transactional workflows.
class FluentSQFLiteException extends FluentException {
  /// Creates a [FluentSQFLiteException].
  ///
  /// * [message]: A descriptive explanation of the database failure.
  /// * [stackTrace]: The execution path leading to the failure.
  FluentSQFLiteException(String message, {StackTrace? stackTrace}) : super(message, stackTrace);
}

/// Exception thrown when a relational mapping or evaluation fails.
///
/// Use this to signal errors related to type mismatches during relation
/// resolution, invalid foreign key configurations, or missing entity selectors.
class FluentRelationException extends FluentException {
  /// Creates a [FluentRelationException].
  ///
  /// * [message]: A descriptive explanation of the relational mapping failure.
  /// * [stackTrace]: The execution path leading to the failure.
  FluentRelationException(String message, {StackTrace? stackTrace}) : super(message, stackTrace);
}

/// Exception thrown when a network request returns an unexpected or error
/// HTTP status code.
///
/// Use this to signal synchronization failures where the server response
/// falls outside the [FluentSyncOptions.validStatusCodes] range.
class FluentApiException extends FluentException {
  /// The HTTP status code returned by the server.
  final int statusCode;

  /// Creates a [FluentApiException].
  ///
  /// * [statusCode]: The HTTP status code received from the API.
  /// * [message]: A brief explanation of the API error.
  /// * [originalError]: The underlying error (e.g., [DioException] or [SocketException]).
  /// * [stackTrace]: The execution path leading to the failure.
  FluentApiException(this.statusCode, {String message = 'Invalid API status code', Object? originalError, StackTrace? stackTrace}) : super(message, stackTrace, originalError);

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentApiException: [StatusCode: $statusCode] $message');
    if (originalError != null) {
      sb.write('\nDetails: $originalError');
    }
    return sb.toString();
  }
}

/// Exception thrown when an operation is performed on a database key
/// that has not been registered in the [FluentDb] registry.
class FluentDatabaseNotFoundException extends FluentException {
  /// The identifier of the database that was not found.
  final String dbName;

  /// Creates a [FluentDatabaseNotFoundException].
  ///
  /// * [dbName]: The name of the database that was not found.
  /// * [stackTrace]: Execution path leading to this error.
  FluentDatabaseNotFoundException(this.dbName, [StackTrace? stackTrace])
    : super('Database "$dbName" is not registered. Ensure that it was initialized in FluentDb.init() or FluentEngine.', stackTrace);
}

/// Exception thrown when a [FluentTask] is aborted or purged from the queue
/// before execution.
///
/// Typically occurs during structural changes, such as clearing a database
/// or table context, where pending tasks are invalidated to ensure safety.
class FluentTaskCancelledException extends FluentException {
  /// The specific component within the engine where the task was cancelled.
  final String component;

  /// The engine working task that was cancelled.
  final FluentTask? task;

  /// Creates a [FluentTaskCancelledException].
  ///
  /// * [message]: A brief explanation of why the task was cancelled.
  /// * [component]: The internal module where the cancellation originated.
  /// * [task]: Optional reference to the task that was aborted.
  /// * [originalError]: Optional underlying error or reason for cancellation.
  /// * [stackTrace]: The execution path leading to the task cancellation.
  FluentTaskCancelledException(String message, {required this.component, this.task, dynamic originalError, StackTrace? stackTrace}) : super(message, stackTrace, originalError);

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentTaskCancelledException: [$component] $message');

    if (task != null) {
      sb.write('\nTask: $task');
    }

    if (originalError != null) {
      sb.write('\nDetails: $originalError');
    }

    return sb.toString();
  }
}

/// Exception thrown when attempting synchronization operations on a provider
/// or model that does not support synchronization.
///
/// Typically occurs when [syncWithServer] is called on a [FluentProvider]
/// that lacks the [FluentSyncable] mixin.
class FluentSyncableException extends FluentException {
  /// The name of the table or model where the synchronization error occurred.
  final String? tableOrModel;

  /// Creates a [FluentSyncableException].
  ///
  /// * [message]: A brief explanation of the error.
  /// * [tableOrModel]: Optional identifier of the target table/model.
  /// * [stackTrace]: The execution path leading to the exception.
  FluentSyncableException(String message, {this.tableOrModel, StackTrace? stackTrace}) : super(message, stackTrace);

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('FluentSyncableException: ');
    if (tableOrModel != null) {
      sb.write('[$tableOrModel] ');
    }
    sb.write(message);
    return sb.toString();
  }
}
