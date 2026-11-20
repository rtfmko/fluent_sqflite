part of '../core/fluent_sqlite_internal.dart';

/// Dart values → SQLite values for columns without a converter, through the built-in codecs ([FluentTypeCodecs])
/// with the table's [FluentTableConfig]. Type special cases belong in the codecs, never here.
mixin FluentSqlSanitizer {
  /// The stored form of [value] with [config] and its type tag (`metaType`, `null` for plain `String` / `num` /
  /// `Uint8List` values and `null`), which the row writer puts into `_fs_metadata` when the column kind does not
  /// tell it. An unsupported type throws a [FluentArgumentException] ([FluentErrorCode.unsupportedValue]) naming
  /// [key] (else [tableName]). A `NaN` throws the same exception: SQLite stores it as `NULL`, which would silently
  /// lose the value (infinite doubles are stored as they are). A stored form that drops part of the value (the
  /// microseconds of a `DateTime` in the timestamp format) is written and reported once per column
  /// ([FluentIssueKind.precisionLost]). Query arguments ([sanitizeValueOnly]) are not checked.
  static ({dynamic value, String? metaType}) sanitize({required dynamic value, required FluentTableConfig config, String? tableName, String? key, bool allowNaN = false}) {
    if (value == null) return (value: null, metaType: null);
    if (!allowNaN && value is double && value.isNaN) {
      throw _unsupported(key ?? tableName ?? 'unknown', value, 'SQLite cannot store NaN (it would become NULL)',
        'Store null for "no value", or a finite number. If NaN is a real state of the field, keep it in a separate bool column or attach a FluentConverter that encodes it.',
      );
    }

    final ({Object value, String? tag, String? lost})? encoded;
    try {
      encoded = FluentTypeCodecs.encode(value as Object, config);
    } on JsonUnsupportedObjectError {
      throw _unsupported(key ?? tableName ?? 'unknown', value, 'the collection contains values JSON cannot encode (e.g. DateTime or a model)',
        'Convert them in buildJson (e.g. date.toIso8601String()), or attach a FluentJsonConverter with your own encoding.',
      );
    }
    if (encoded == null) {
      throw _unsupported(key ?? tableName ?? 'unknown', value, 'SQLite cannot store a ${value.runtimeType}',
        'Return a supported value from buildJson, or attach a FluentConverter to this column (FluentDbColumn.converted). '
        'A relation must be declared as a FluentRelation.',
      );
    }
    if (encoded.lost != null && !allowNaN) _reportLost(encoded.lost!, tableName, key, value);
    return (value: encoded.value, metaType: encoded.tag);
  }

  static final RegExp _decimalText = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');
  static final RegExp _integerText = RegExp(r'^[+-]?\d+$');

  /// The last check before a value (already in its stored form: after the codec or the column's converter) is written:
  /// the one place for what SQLite would silently change. Refused with a [FluentArgumentException]
  /// ([FluentErrorCode.unsupportedValue]) and a hint, nothing is written:
  /// - text that is no number (or an integer beyond 64 bits, which SQLite turns into a rounded double) in an
  ///   INTEGER / REAL column ([type]; numeric text that converts without loss stays allowed);
  /// - text with a lone UTF-16 surrogate (UTF-8 would replace it with U+FFFD).
  /// Cheap: only text is looked at, the numeric rule only for numeric columns.
  static void checkStored(Object? stored, FluentDbDataType? type, {String? tableName, required String key}) {
    if (stored is! String) return;
    if (_hasLoneSurrogate(stored)) {
      throw _unsupported(key, stored, 'the text contains a lone UTF-16 surrogate, which UTF-8 storage would silently replace with U+FFFD${tableName == null ? '' : ' (table "$tableName")'}',
        'Remove or replace the broken character before saving or store the value as a Uint8List / with a FluentConverter that encodes it.',
      );
    }
    if (type != FluentDbDataType.integer && type != FluentDbDataType.real) return;
    final String text = stored.trim();
    final bool fits = _decimalText.hasMatch(text) && (!_integerText.hasMatch(text) || int.tryParse(text) != null);
    if (fits) return;
    throw _unsupported(key, stored, 'a text value cannot be stored in the ${type == FluentDbDataType.integer ? 'INTEGER' : 'REAL'} column without SQLite changing it (not a number, or an integer beyond 64 bits)${tableName == null ? '' : ' (table "$tableName")'}',
      'Save a number, or declare the column as TEXT (or a BigInt / FluentConverter column with a TEXT type) when it holds text or integers beyond 64 bits.',
    );
  }

  static bool _hasLoneSurrogate(String text) {
    final int n = text.length;
    for (int i = 0; i < n; i++) {
      final int c = text.codeUnitAt(i);
      if (c < 0xD800 || c > 0xDFFF) continue;
      if (c <= 0xDBFF && i + 1 < n && (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
        i++;
        continue;
      }
      return true;
    }
    return false;
  }

  /// Reports once per column that the stored form of [value] drops its [lost] part.
  static void _reportLost(String lost, String? tableName, String? key, Object? value) {
    final String column = key ?? 'unknown';
    if (lost == FluentTypeCodecs.ambiguousHour) {
      FluentLog.issue(
        FluentIssueKind.precisionLost,
        'A local DateTime of "$column"${tableName == null ? '' : ' in "$tableName"'} lies in the hour repeated when the clocks go back; '
        'ISO text of a local time has no offset, so it reads back one hour earlier (the first of the two instants with that wall-clock time).',
        table: tableName,
        subject: '$column:hour',
        tag: 'FluentSqlSanitizer',
        hint: 'Save UTC values (value.toUtc(), read back as UTC) or store the column as a timestamp, which keeps the instant: '
            'FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.timestamp). The wall-clock time itself was saved.',
        code: '@override\nFluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.timestamp);',
      );
      return;
    }
    FluentLog.issue(
      FluentIssueKind.precisionLost,
      'The ${value.runtimeType} values of "$column"${tableName == null ? '' : ' in "$tableName"'} lose their $lost: the timestamp format keeps milliseconds.',
      table: tableName,
      subject: column,
      tag: 'FluentSqlSanitizer',
      hint: 'Keep microseconds with FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601) (stored as ISO text) '
          'or a FluentConverter on the column; or round the value to milliseconds before saving.',
      code: '@override\nFluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);',
    );
  }

  static FluentArgumentException _unsupported(String key, Object? value, String why, String hint) => FluentLog.raise(
    FluentArgumentException(
      'value of "$key"',
      '$why${FluentLog.showSqlArguments ? ' (value: $value)' : ''}.',
      code: FluentErrorCode.unsupportedValue,
      hint: hint,
    ),
    tag: 'FluentSqlSanitizer',
  );

  /// Only the stored value of [sanitize] (query arguments need no type tag).
  static dynamic sanitizeValueOnly(dynamic value, FluentTableConfig config) => sanitize(value: value, config: config, tableName: 'query_builder', allowNaN: true).value;
}
