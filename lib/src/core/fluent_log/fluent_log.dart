// ignore_for_file: avoid_redundant_argument_values

part of '../fluent_sqlite_internal.dart';

/// A centralized logging utility for the database layer.
///
/// [FluentLog] provides a structured facade for tracking database operations,
/// lifecycle events, and error states. It supports dual-channel logging:
/// * **User Logger:** For surface-level application events or developer-defined logging.
/// * **Internal Logger:** For low-level framework telemetry, performance profiling,
///   and deep diagnostic traces.
class FluentLog {
  FluentLog._();

  /// The primary logger instance for application-level monitoring.
  static FluentTelemetry? _userLogger;

  /// The high-fidelity logger instance for internal framework diagnostics.
  static FluentTelemetry? _internalLogger;

  /// Global toggle for the logging system.
  ///
  /// When `false`, all logging calls are short-circuited to minimize overhead
  /// in production-critical environments.
  static bool _isEnabled = true;

  /// Returns whether logging is currently active.
  static bool get isEnabled => _isEnabled;

  /// Dynamically toggles the global state of the database logging system.
  ///
  /// This method provides an administrative interface to suspend or resume
  /// telemetry, which is useful for reducing log noise during high-volume
  /// background tasks or sensitive operations.
  ///
  /// ### Example:
  /// ```dart
  /// // Temporarily silence database logs for a noisy batch migration
  /// FluentLog.isGloballyEnabled(false);
  /// await performBulkMigration();
  /// FluentLog.isGloballyEnabled(true);
  /// ```
  static void isGloballyEnabled(bool enabled) {
    if (_isEnabled == enabled) return;

    if (!enabled && _shouldLog(FluentLogLevel.info)) {
      _userLogger?.info('Database logging session suspended by the supervisor.', tag: 'System');
    }

    _isEnabled = enabled;

    if (enabled && _shouldLog(FluentLogLevel.info)) {
      _userLogger?.info('Database logging session successfully resumed.', tag: 'System');
    }
  }

  /// Initializes the logging system with a default [FluentLogger].
  ///
  /// This is the recommended entry point for standard applications,
  /// providing color-coded terminal output for easier local debugging.
  static void initDefault() {
    _userLogger ??= FluentLogger(isLogOn: true, isDebug: false, useColors: true, tag: 'FluentSQFLite');
  }

  /// Initializes the logging system with a default [FluentLogger] with debug mode.
  ///
  /// This is the recommended entry point for standard applications debugging,
  /// providing color-coded terminal output for easier local debugging.
  static void initDefaultDebug() {
    _userLogger ??= FluentLogger(isLogOn: true, isDebug: true, useColors: true, tag: 'FluentSQFLite');
  }

  /// Configures the logging infrastructure with custom logger instances.
  ///
  /// This should be called during app bootstrap to inject your preferred
  /// logging implementations.
  ///
  /// ### Example:
  /// ```dart
  /// FluentLog.setup(
  ///   userLogger: CrashlyticsLogger(),
  ///   internalLogger: ConsoleLogger(),
  ///   enable: kDebugMode,
  /// );
  /// ```
  static void setup({FluentTelemetry? userLogger, FluentTelemetry? internalLogger, bool? enable}) {
    if (userLogger != null) _userLogger = userLogger;
    if (internalLogger != null) _internalLogger = internalLogger;
    if (enable != null) isGloballyEnabled(enable);
  }

  /// Evaluates whether a log entry should be processed based on the current
  /// global state and configuration.
  ///
  /// This acts as a primary filter to ensure that logging overhead is
  /// minimized when the system is disabled, performing a lazy initialization
  /// of the default logger if none is currently registered.
  ///
  /// Returns `true` if logging is enabled and the logger is active.
  static bool _shouldLog(FluentLogLevel level) {
    if (!_isEnabled) return false;
    if (_userLogger == null) initDefault();
    return _userLogger?.isLogOn ?? false;
  }

  /// Utility to inject vertical whitespace around log messages for improved
  /// terminal readability.
  ///
  /// [message] The raw log message content.
  /// [linesBefore] Number of newlines to prepend.
  /// [linesAfter] Number of newlines to append.
  static String _applySpacing(String message, int linesBefore, int linesAfter) {
    final String prefix = '\n' * linesBefore;
    final String suffix = '\n' * linesAfter;
    return '$prefix$message$suffix';
  }

  /// Logs an informational message to the database logging system.
  ///
  /// Use this for tracking significant application events (e.g., initialization,
  /// transaction starts, or configuration changes).
  ///
  /// ### Example:
  /// ```dart
  /// FluentLog.info('User profile saved successfully', tag: 'UserRepository', context: {'userId': 123});
  /// ```
  static void info(String message, {String? tag, int linesBefore = 0, int linesAfter = 0, Map<String, dynamic>? context}) {
    if (!_shouldLog(FluentLogLevel.info)) return;
    final String preparedMsg = _applySpacing(message, linesBefore, linesAfter);

    _userLogger?.info(preparedMsg, tag: tag, context: context);
    _internalLogger?.info(preparedMsg, tag: tag, context: context);
  }

  /// Logs a debug message, primarily used for diagnostic purposes.
  ///
  /// Debug logs are only propagated to the user-facing logger if the logger is
  /// explicitly configured in debug mode, otherwise, they are captured
  /// exclusively by the internal logger.
  ///
  /// ### Example:
  /// ```dart
  /// FluentLog.debug('Cache miss, fetching from disk...', tag: 'DiskCache', context: {'key': 'settings'});
  /// ```
  static void debug(String message, {String? tag, int linesBefore = 0, int linesAfter = 0, Map<String, dynamic>? context}) {
    if (!_shouldLog(FluentLogLevel.debug)) return;
    final String preparedMsg = _applySpacing(message, linesBefore, linesAfter);

    _internalLogger?.debug(preparedMsg, tag: tag, context: context);
    if (_userLogger?.isDebug ?? false) {
      _userLogger?.debug(preparedMsg, tag: tag, context: context);
    }
  }

  /// Logs raw SQL queries and their associated arguments.
  ///
  /// This is critical for performance tuning and resolving syntax errors in
  /// complex SQLite queries.
  ///
  /// ### Example:
  /// ```dart
  /// FluentLog.sql('SELECT * FROM users WHERE id = ?', arguments: [123], tag: 'QueryLogger');
  /// ```
  static void sql(String message, {List<Object?>? arguments, String? tag, int linesBefore = 0, int linesAfter = 0}) {
    if (!_shouldLog(FluentLogLevel.debug)) return;
    final String preparedMsg = _applySpacing(message, linesBefore, linesAfter);

    _internalLogger?.sql(preparedMsg, arguments: arguments, tag: tag);
    _userLogger?.sql(preparedMsg, arguments: arguments, tag: tag);
  }

  /// Logs a warning message.
  ///
  /// Use this to signal non-critical issues that may require developer
  /// attention, such as deprecated method usage or suboptimal performance.
  ///
  /// ### Example:
  /// ```dart
  /// FluentLog.warning(
  ///   'Query returned no results, check input parameters',
  ///   tag: 'QueryValidator',
  ///   hint: 'Ensure foreign keys exist before fetching.'
  /// );
  /// ```
  static void warning(String message, {String? tag, String? hint, int linesBefore = 0, int linesAfter = 0, Map<String, dynamic>? context}) {
    if (!_isEnabled) return;
    initDefault();

    final String preparedMsg = _applySpacing(message, linesBefore, linesAfter);
    _userLogger?.warning(preparedMsg, tag: tag, hint: hint, context: context);
    _internalLogger?.warning(preparedMsg, tag: tag, hint: hint, context: context);
  }

  /// Logs a critical error, including the associated exception and stack trace.
  ///
  /// This is the primary method for capturing operational failures, database
  /// connection drops, or malformed schema migrations.
  ///
  /// ### Example:
  /// ```dart
  /// try {
  ///   await database.execute('...');
  /// } catch (e, stack) {
  ///   FluentLog.error('Critical database failure', e, stack, tag: 'FluentEngine', hint: 'Check disk space.');
  /// }
  /// ```
  static void error(String message, Object error, StackTrace? stackTrace, {String? tag, String? hint, int linesBefore = 0, int linesAfter = 0, Map<String, dynamic>? context}) {
    if (!_isEnabled) return;
    initDefault();

    final String preparedMsg = _applySpacing(message, linesBefore, linesAfter);
    _userLogger?.error(preparedMsg, error, stackTrace, tag: tag, hint: hint, context: context);
    _internalLogger?.error(preparedMsg, error, stackTrace, tag: tag, hint: hint, context: context);
  }
}
