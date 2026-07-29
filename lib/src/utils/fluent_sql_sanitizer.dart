part of '../core/fluent_sqlite_internal.dart';

/// A utility mixin responsible for serializing high-level Dart and Flutter types
/// into SQLite-compatible primitives.
///
/// [FluentSqlSanitizer] acts as a central translation gateway for database operations,
/// ensuring consistent type coercion (such as handling [DateTime], [Enum], [Color], or collections)
/// across queries, insertions, and updates based on the active [FluentTableConfig].
mixin FluentSqlSanitizer {
  /// Sanitizes Dart domain types into SQLite-compatible primitives while tracking
  /// structural metadata for accurate reconstruction.
  ///
  /// This method acts as the serialization gateway:
  /// * **Primitive Passthrough:** Allows `String`, `num`, and `Uint8List` to persist without overhead.
  /// * **Type Coercion:** Maps high-level types (e.g., `DateTime`, `Enum`, `Color`) into
  ///   SQL-compliant formats (timestamps, indices, or hex/integer equivalents) based on the provided [config].
  /// * **Metadata Tracking:** Returns an optional [metaType] hint which is stored in the
  ///   system metadata column, enabling strict type-resurrection during hydration.
  ///
  /// **Parameters:**
  /// * [value] — The raw field value from the domain model.
  /// * [config] — The [FluentTableConfig] defining formatting rules (e.g., date formats, enum storage).
  /// * [tableName] — Optional table name used for descriptive error handling if serialization fails.
  ///
  /// **Returns:**
  /// A record containing the sanitized primitive [value] and its associated type identifier [metaType].
  static ({dynamic value, String? metaType}) sanitize({required dynamic value, required FluentTableConfig config, String? tableName}) {
    if (value == null) return (value: null, metaType: null);

    if (value is String || value is num || value is Uint8List) {
      return (value: value, metaType: null);
    }

    if (value is bool) return (value: value ? 1 : 0, metaType: 'bool');

    // --- Dart Core ---

    if (value is DateTime) {
      final dynamic formattedDate = config.dateTimeFormat == FluentDateTimeFormat.timestamp ? value.millisecondsSinceEpoch : value.toIso8601String();
      return (value: formattedDate, metaType: 'datetime');
    }

    if (value is Duration) {
      return (value: value.inMicroseconds, metaType: 'duration');
    }

    if (value is BigInt) {
      return (value: value.toString(), metaType: 'bigint');
    }

    if (value is RegExp) {
      return (value: value.pattern, metaType: 'regexp');
    }

    if (value is Uri) {
      return (value: value.toString(), metaType: 'uri');
    }

    // --- Flutter Specific ---

    if (value is Color) {
      return (value: value.toARGB32(), metaType: 'color');
    }

    if (value is Locale) {
      return (value: value.toLanguageTag(), metaType: 'locale');
    }

    if (value is TimeOfDay) {
      final String timeString = '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
      return (value: timeString, metaType: 'timeofday');
    }

    // --- Complex/Collections ---

    if (value is Map || value is List) {
      try {
        return (value: jsonEncode(value), metaType: 'json');
      } catch (_) {
        throw InvalidSqlTypeException(tableName ?? 'unknown', value);
      }
    }

    if (value is Enum) {
      final dynamic formattedEnum = config.storeEnumsAsNames ? value.name : value.index;
      return (value: formattedEnum, metaType: 'enum');
    }

    throw InvalidSqlTypeException(tableName ?? 'unknown', value);
  }

  /// A simplified wrapper for [sanitize] specifically tailored for query builders (e.g., [FluentFilter]).
  ///
  /// Extracts only the sanitized primitive value, discarding the [metaType] metadata,
  /// since query arguments do not require hydration hints.
  static dynamic sanitizeValueOnly(dynamic value, FluentTableConfig config) => sanitize(value: value, config: config, tableName: 'query_builder').value;
}
