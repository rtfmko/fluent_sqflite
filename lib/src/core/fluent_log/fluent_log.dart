// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The library's logger: one entry point for every log line, error report and issue.
///
/// Configured through `FluentDb.setupLogging`. Rules:
/// * records below [level] are dropped (default: info in debug / profile, warning in release);
/// * issues ([FluentIssue]: hints, automatic changes, warnings, errors nobody receives) all go through [issue] /
///   [publish]: muted keys are dropped, hints only while the diagnostics of their database collect them, hints and
///   warnings once per run (automatic changes and errors every time); each is kept for the report, published on
///   [issues] (whatever the level) and logged at the level of its type;
/// * an error thrown to a caller is logged once, as a warning (the caller decides what it means), not as an issue;
/// * SQL arguments and database paths are hidden unless `showSqlArguments` is on.
class FluentLog {
  FluentLog._();

  static bool _enabled = true;
  static FluentLogLevel? _level;
  static void Function(FluentLogRecord record)? _onRecord;
  static bool _console = true;
  static bool? _colors;
  static bool _showSqlArguments = false;
  static Set<String> _muted = const {};
  static final Map<String, FluentIssue> _seen = {};
  static final List<FluentIssue> _repeated = [];
  static final StreamController<FluentIssue> _issueBus = StreamController<FluentIssue>.broadcast();

  /// How many repeating issues (automatic changes, errors) the report keeps.
  static const int _repeatedLimit = 200;

  /// The lowest level that is logged.
  static FluentLogLevel get level => _level ?? (kReleaseMode ? FluentLogLevel.warning : FluentLogLevel.info);

  /// Whether logging is on at all.
  static bool get isEnabled => _enabled;

  /// Whether SQL arguments and database paths are shown in logs and error texts.
  static bool get showSqlArguments => _showSqlArguments;

  /// Every issue as it happens (muted ones excepted), whatever the log level.
  static Stream<FluentIssue> get issues => _issueBus.stream;

  /// Muted issue keys; an entry ending in `*` mutes every key starting with the rest (`missingIndex:*`).
  static Set<String> get mute => _muted;

  /// The issues of this run (muted ones excepted): each hint / warning once, the latest automatic changes and errors.
  static List<FluentIssue> get seen => [for (final FluentIssue i in [..._seen.values, ..._repeated]) if (!isMuted(i.key)) i];

  /// The hints of this run (muted ones excepted), in the order they were found.
  static List<FluentIssue> get shownHints => [for (final FluentIssue i in seen) if (i.type == FluentIssueType.hint) i];

  /// Whether [key] is muted ([mute]).
  static bool isMuted(String key) => _muted.any((m) => m.endsWith('*') ? key.startsWith(m.substring(0, m.length - 1)) : key == m);

  /// Changes the logging setup; `null` keeps the current value; [removeOnRecord] removes the record sink first (a new
  /// [onRecord] given with it is set after).
  static void configure({
    bool? enabled,
    FluentLogLevel? level,
    void Function(FluentLogRecord record)? onRecord,
    bool? console,
    bool? colors,
    bool? showSqlArguments,
    Set<String>? mute,
    bool removeOnRecord = false,
  }) {
    if (removeOnRecord) _onRecord = null;
    if (mute != null) _muted = Set.unmodifiable(mute);
    if (enabled != null) _enabled = enabled;
    if (level != null) _level = level;
    if (onRecord != null) _onRecord = onRecord;
    if (console != null) _console = console;
    if (colors != null) _colors = colors;
    if (showSqlArguments != null) _showSqlArguments = showSqlArguments;
  }

  /// Forgets which issues were shown, so "once per run" issues are reported again (the test package does it for
  /// every test database).
  static void forgetIssues() {
    _seen.clear();
    _repeated.clear();
  }

  /// Back to the defaults (used by tests).
  @visibleForTesting
  static void reset() {
    _enabled = true;
    _level = null;
    _onRecord = null;
    _console = true;
    _colors = null;
    _showSqlArguments = false;
    _muted = const {};
    _seen.clear();
    _repeated.clear();
  }

  /// Whether a record of [level] would be logged.
  static bool isOn(FluentLogLevel level) => _enabled && level.index >= FluentLog.level.index;

  // ANSI colors only where the console shows them (desktop terminals); Xcode / logcat print the escape codes.
  static bool get _useColors =>
      _colors ?? (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS));

  /// Delivers [record] to the console and the sink with SQL arguments and paths hidden in its texts (message, hint,
  /// context values); [FluentLogRecord.error] is the original object only with `showSqlArguments` on, else a
  /// [FluentRedactedError] (a [FluentException] stays, it redacts its own texts).
  static void _emit(FluentLogRecord record) {
    final FluentLogRecord shown = _showSqlArguments ? record : _redacted(record);
    if (_console) debugPrint(shown.format(colors: _useColors, redact: redact));
    _sink(shown);
  }

  static FluentLogRecord _redacted(FluentLogRecord r) => FluentLogRecord(
    level: r.level,
    message: redact(r.message),
    time: r.time,
    tag: r.tag,
    hint: r.hint == null ? null : redact(r.hint!),
    context: r.context?.map((k, v) => MapEntry(k, v is String ? redact(v) : v)),
    error: _redactedError(r.error),
    stackTrace: r.stackTrace,
    issue: r.issue,
  );

  /// [error] as handed to sinks: a foreign error becomes a [FluentRedactedError] (its text can carry SQL arguments)
  /// unless `showSqlArguments` is on; a [FluentException] redacts its own texts.
  static Object? _redactedError(Object? error) {
    if (error == null || _showSqlArguments || error is FluentException || error is FluentRedactedError) return error;
    return FluentRedactedError(type: '${error.runtimeType}', message: redact('$error'));
  }

  static FluentIssue _redactedIssue(FluentIssue i) {
    final Object? error = _redactedError(i.error);
    if (identical(error, i.error)) return i;
    return FluentIssue(
      kind: i.kind,
      title: i.title,
      details: i.details,
      fix: i.fix,
      code: i.code,
      database: i.database,
      table: i.table,
      subject: i.subject,
      impact: i.impact,
      error: error,
      stackTrace: i.stackTrace,
    );
  }

  static void _sink(FluentLogRecord record) {
    final void Function(FluentLogRecord)? sink = _onRecord;
    if (sink == null) return;
    try {
      sink(record);
    } catch (e) {
      // A failing user sink must not break the database call that logged.
      if (_console) debugPrint('fluent_sqflite: the onRecord callback of setupLogging threw: $e');
    }
  }

  static void _log(FluentLogLevel level, String message, {String? tag, String? hint, Map<String, dynamic>? context, Object? error, StackTrace? stackTrace}) {
    if (!isOn(level)) return;
    _emit(FluentLogRecord(level: level, message: message, time: FluentClock.now(), tag: tag, hint: hint, context: context, error: error, stackTrace: stackTrace));
  }

  /// Logs normal operation (init, migrations, maintenance).
  static void info(String message, {String? tag, Map<String, dynamic>? context}) => _log(FluentLogLevel.info, message, tag: tag, context: context);

  /// Logs internal details for troubleshooting.
  static void debug(String message, {String? tag, Map<String, dynamic>? context}) => _log(FluentLogLevel.debug, message, tag: tag, context: context);

  /// Logs a SQL statement; [arguments] are hidden unless `showSqlArguments` is on.
  static void sql(String message, {List<Object?>? arguments, String? tag}) {
    if (!isOn(FluentLogLevel.sql)) return;
    final String args = arguments == null || arguments.isEmpty ? '' : (_showSqlArguments ? ' | Args: $arguments' : ' | Args: ${arguments.length} hidden');
    _log(FluentLogLevel.sql, '$message$args', tag: tag);
  }

  /// Reports an issue of [kind]: [message] says what happened, [hint] how to fix it (required: every issue tells how).
  ///
  /// [table] / [database] / [subject] make its key; [code] is code to copy. The type comes from [kind].
  static void issue(
    FluentIssueKind kind,
    String message, {
    required String hint,
    String? details,
    String? code,
    String? table,
    String? database,
    String? subject,
    String? tag,
    Map<String, dynamic>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (error is FluentException) error.reported = true;
    publish(
      FluentIssue(kind: kind, title: message, details: details, fix: hint, code: code, database: database, table: table, subject: subject, error: error, stackTrace: stackTrace),
      tag: tag,
      context: context,
    );
  }

  /// Reports [issue] (see the class rules): kept for the report, published on [issues], logged at its type's level.
  static void publish(FluentIssue original, {String? tag, Map<String, dynamic>? context}) {
    final FluentIssue issue = _redactedIssue(original);
    final List<FluentIssue>? captured = Zone.current[_captureKey] as List<FluentIssue>?;
    if (captured != null) {
      captured.add(issue); // a migration plan: collected, not reported (the real start reports them)
      return;
    }
    if (isMuted(issue.key)) return;
    if (issue.type == FluentIssueType.hint && !FluentAnalyzer().collects(issue.database)) return;
    if (issue.kind.repeats) {
      _repeated.add(issue);
      if (_repeated.length > _repeatedLimit) _repeated.removeAt(0);
    } else {
      // Once per key and title without its numbers: a title with a count in it ("3 rows", "4 rows") does not repeat
      // the issue nor grow the memory, while different situations of one kind without a subject stay apart.
      final String id = '${issue.key}|${issue.title.replaceAll(_numbers, '#')}';
      if (_seen.containsKey(id)) return;
      _seen[id] = issue;
    }
    if (_issueBus.hasListener) _issueBus.add(issue);
    final FluentLogLevel level = switch (issue.type) {
      FluentIssueType.hint => FluentLogLevel.hint,
      FluentIssueType.autoFix => FluentLogLevel.autoFix,
      FluentIssueType.warning => FluentLogLevel.warning,
      FluentIssueType.error => FluentLogLevel.error,
    };
    if (!isOn(level)) return;
    _emit(
      FluentLogRecord(
        level: level,
        message: issue.title,
        time: FluentClock.now(),
        tag: tag ?? (issue.table == null ? 'FluentDb:${issue.kind.name}' : '${issue.table}:${issue.kind.name}'),
        hint: issue.fix,
        context: context,
        error: issue.error,
        stackTrace: issue.stackTrace,
        issue: issue,
      ),
    );
  }

  static final Object _captureKey = Object();

  static final RegExp _numbers = RegExp(r'\d+(\.\d+)?');

  /// Runs [body] collecting the issues it raises into [into] instead of reporting them (migration plans).
  static Future<R> captureIssues<R>(List<FluentIssue> into, Future<R> Function() body) => runZoned(body, zoneValues: {_captureKey: into});

  /// [captureIssues] for a synchronous [body].
  static R captureIssuesSync<R>(List<FluentIssue> into, R Function() body) => runZoned(body, zoneValues: {_captureKey: into});

  /// Whether an issue with [key] was already reported in this run.
  static bool reported(String key) => _seen.values.any((i) => i.key == key) || _repeated.any((i) => i.key == key);

  /// Zone marker of a running provider call: errors raised inside are logged where the call ends
  /// (`FluentProvider.internalExecute`), which knows whether it is a merged batch that will be re-run.
  @internal
  static const Object deferKey = #fluentDeferReport;

  /// Logs [exception] once (as a warning: the caller receives it) and returns it, for `throw FluentLog.raise(e)`.
  ///
  /// Inside a provider call the logging is left to the end of the call.
  static T raise<T extends FluentException>(T exception, {String? tag, Map<String, dynamic>? context}) {
    if (Zone.current[deferKey] != true) report(exception, tag: tag, context: context);
    return exception;
  }

  /// Logs [error] on its way to the caller, once: a [FluentException] that was already logged is skipped.
  static void report(Object error, {StackTrace? stackTrace, String? tag, Map<String, dynamic>? context}) {
    if (error is FluentException) {
      if (error.reported) return;
      error.reported = true;
      _log(FluentLogLevel.warning, error.message, tag: tag, hint: error.hint, context: context, error: error, stackTrace: error.stackTrace);
    } else {
      _log(FluentLogLevel.warning, 'Unexpected error: $error', tag: tag, context: context, error: error, stackTrace: stackTrace);
    }
  }

  static final RegExp _ffiParameters = RegExp(r'parameters: .*?(?=\}\) |\) sql |\n|$)');
  // From ` args [` to the end of the text (sqflite prints the arguments last, before `{details`, which `_details`
  // already cut): the values may hold newlines, `]`, `}` or anything else, so nothing after the opening bracket stays.
  static final RegExp _args = RegExp(r'args \[[\s\S]*');
  static final RegExp _details = RegExp(r'\s*\{details: .*$', dotAll: true);

  // A quoted path (`path = 'C:\x\y.db'`, `'/home/x/y.db'`; it may hold spaces): the whole quoted text goes.
  static final RegExp _quotedPath = RegExp(r'''(['"])(?:[A-Za-z]:[\\/]|\\\\|/[^'"\n/]*/)[^'"\n]*\1''');
  // An unquoted absolute path: a drive path, a UNC path, or a POSIX path of at least two segments (a word before the
  // slash, or the `//` of a URL, is not a path start).
  static final RegExp _barePath = RegExp(r'''(?<![A-Za-z])[A-Za-z]:[\\/][^\s'"<>|]*|\\\\[^\s'"<>|]+|(?<![\w:/.)\]])/(?:[^\s'"/:]+/)+[^\s'"/:]*''');

  /// Hides SQL arguments and the database path in an error [text], unless `showSqlArguments` is on.
  static String redact(String text) {
    if (_showSqlArguments) return text;
    return text
        .replaceAll(_details, '')
        .replaceAll(_args, 'args [hidden]')
        .replaceAll(_ffiParameters, 'parameters: hidden')
        .replaceAllMapped(_quotedPath, (m) => "${m[1]}<path hidden>${m[1]}")
        .replaceAll(_barePath, '<path hidden>');
  }
}
