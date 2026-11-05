part of '../core/fluent_sqlite_internal.dart';

/// One built-in conversion between a Dart type SQLite cannot store and the stored value.
///
/// [tag] is what `_fs_metadata` and [FluentValueKind.tag] record, so stored rows keep reading back after upgrades;
/// [decode] is lenient and idempotent (a value that already has its Dart type, or text written by raw SQL, works).
/// [lost] says what [encode] drops of a value (`null`: nothing), so the sanitizer can report it.
class _FluentCodec {
  const _FluentCodec(this.tag, this.accepts, this.encode, this.decode, {this.lost});

  final String tag;
  final bool Function(Object value) accepts;
  final Object Function(Object value, FluentTableConfig config) encode;
  final Object Function(Object stored) decode;
  final String? Function(Object value, FluentTableConfig config)? lost;
}

/// The built-in conversions, in the order they are tried when writing: one table for writing (`sanitize`) and reading
/// (`restore`). Columns with a [FluentConverter] (explicit, or an enum with `enumValues`) bypass it.
// ignore: avoid_classes_with_only_static_members
abstract final class FluentTypeCodecs {
  static final List<_FluentCodec> _codecs = [
    _FluentCodec('bool', (v) => v is bool, (v, _) => (v as bool) ? 1 : 0, (s) {
      if (s is num) return s != 0;
      if (s is String) return s == '1' || s.toLowerCase() == 'true';
      return s;
    }),
    _FluentCodec(
      'datetime_utc',
      (v) => v is DateTime && v.isUtc,
      (v, c) => c.dateTimeFormat == FluentDateTimeFormat.timestamp ? (v as DateTime).millisecondsSinceEpoch : (v as DateTime).toIso8601String(),
      (s) => _dateTime(s, utc: true),
      lost: _lostMicroseconds,
    ),
    _FluentCodec(
      'datetime',
      (v) => v is DateTime,
      (v, c) => c.dateTimeFormat == FluentDateTimeFormat.timestamp ? (v as DateTime).millisecondsSinceEpoch : (v as DateTime).toIso8601String(),
      (s) => _dateTime(s, utc: false),
      lost: _lostMicroseconds,
    ),
    _FluentCodec('duration', (v) => v is Duration, (v, _) => (v as Duration).inMicroseconds, (s) => s is int ? Duration(microseconds: s) : s),
    _FluentCodec('bigint', (v) => v is BigInt, (v, _) => v.toString(), (s) => s is BigInt ? s : (BigInt.tryParse(s.toString()) ?? s)),
    // A RegExp with the default flags is stored as its pattern (the only form before 2.0, still read); any other flag
    // makes it a JSON list [pattern, caseSensitive, multiLine, unicode, dotAll] under its own tag.
    _FluentCodec('regexp', (v) => v is RegExp && v.isCaseSensitive && !v.isMultiLine && !v.isUnicode && !v.isDotAll, (v, _) => (v as RegExp).pattern, (s) => s is RegExp ? s : RegExp(s.toString())),
    _FluentCodec(
      'regexp_flags',
      (v) => v is RegExp,
      (v, _) {
        final RegExp r = v as RegExp;
        return jsonEncode([r.pattern, r.isCaseSensitive, r.isMultiLine, r.isUnicode, r.isDotAll]);
      },
      (s) {
        if (s is RegExp) return s;
        final List<dynamic> parts = jsonDecode(s.toString()) as List<dynamic>;
        return RegExp(parts[0] as String, caseSensitive: parts[1] as bool, multiLine: parts[2] as bool, unicode: parts[3] as bool, dotAll: parts[4] as bool);
      },
    ),
    _FluentCodec('uri', (v) => v is Uri, (v, _) => v.toString(), (s) => s is Uri ? s : (Uri.tryParse(s.toString()) ?? s)),
    _FluentCodec('color', (v) => v is Color, (v, _) => (v as Color).toARGB32(), (s) => s is int ? Color(s) : s),
    _FluentCodec('locale', (v) => v is Locale, (v, _) => (v as Locale).toLanguageTag(), (s) {
      if (s is! String) return s;
      // language[-Script][-REGION]: `zh-Hant-TW` keeps its script and region.
      final List<String> parts = s.split(RegExp('[-_]'));
      String? script;
      String? country;
      for (final String part in parts.skip(1)) {
        if (script == null && country == null && part.length == 4) {
          script = part;
        } else if (country == null && (part.length == 2 || part.length == 3)) {
          country = part;
        }
      }
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: script, countryCode: country);
    }),
    _FluentCodec('timeofday', (v) => v is TimeOfDay, (v, _) {
      final TimeOfDay t = v as TimeOfDay;
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }, (s) {
      if (s is! String) return s;
      final List<String> parts = s.split(':');
      return parts.length == 2 ? TimeOfDay(hour: int.tryParse(parts[0]) ?? 0, minute: int.tryParse(parts[1]) ?? 0) : s;
    }),
    _FluentCodec('json', (v) => v is Map || v is List, (v, _) => jsonEncode(v), (s) {
      if (s is! String) return s;
      try {
        return jsonDecode(s) as Object;
      } catch (_) {
        return s;
      }
    }),
    _FluentCodec('enum', (v) => v is Enum, (v, c) => c.storeEnumsAsNames ? (v as Enum).name : (v as Enum).index, (s) => s),
  ];

  static final Map<String, _FluentCodec> _byTag = {for (final _FluentCodec c in _codecs) c.tag: c};

  /// The timestamp format keeps milliseconds: the microseconds of [value] are dropped.
  static String? _lostMicroseconds(Object value, FluentTableConfig config) =>
      config.dateTimeFormat == FluentDateTimeFormat.timestamp && (value as DateTime).microsecond != 0 ? 'microseconds' : null;

  static Object _dateTime(Object s, {required bool utc}) {
    if (s is DateTime) return s;
    if (s is num) return DateTime.fromMillisecondsSinceEpoch(s.toInt(), isUtc: utc);
    final String text = s.toString();
    final int? millis = int.tryParse(text);
    if (millis != null) return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: utc);
    final DateTime? parsed = DateTime.tryParse(text);
    return parsed == null ? s : (utc ? parsed.toUtc() : parsed);
  }

  /// The stored value of [value], its type tag (`null` for plain SQLite values) and what the stored form drops of it
  /// ([lost], e.g. `'microseconds'`; `null`: nothing), or `null` for a type no codec takes. A collection JSON cannot
  /// encode throws a `JsonUnsupportedObjectError` (the sanitizer reports both).
  static ({Object value, String? tag, String? lost})? encode(Object value, FluentTableConfig config) {
    if (value is String || value is num || value is Uint8List) return (value: value, tag: null, lost: null);
    for (final _FluentCodec c in _codecs) {
      if (c.accepts(value)) return (value: c.encode(value, config), tag: c.tag, lost: c.lost?.call(value, config));
    }
    return null;
  }

  /// [stored] read back as the Dart type of [tag]; [stored] itself when the tag is unknown or nothing applies.
  /// Enums need their [enumValues] (`FluentStorable.enumValues`). Stored text that cannot become the type (a RegExp
  /// that does not compile, a time outside the DateTime range) throws; the row mapping turns that into a
  /// [FluentSchemaException] naming the table and column.
  static Object? decode(String tag, Object stored, {List<Enum>? enumValues}) {
    if (tag == 'enum') return enumValues == null ? stored : (FluentEnumConverter.lookup(enumValues, stored) ?? stored);
    return _byTag[tag]?.decode(stored) ?? stored;
  }
}
