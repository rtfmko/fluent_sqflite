// G25 / G26 (static): every error the library throws is a typed Fluent*Exception with a hint, every issue it reports
// tells how to fix it, and the documented codes and kinds all have their text. The checks read the sources in lib/,
// so a new throw or issue without its hint fails here, not in the field.
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every Dart file under lib/ as (repo-relative path with `/`, text).
List<(String, String)> _libSources() {
  final List<(String, String)> files = [];
  for (final FileSystemEntity f in Directory('lib').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    files.add((f.path.replaceAll('\\', '/'), f.readAsStringSync()));
  }
  return files;
}

/// The text of the call whose opening bracket is at [open] (up to the matching close), skipping string literals.
/// Returns the text between the brackets, or the rest of the file when the brackets never close.
String _argumentsOf(String src, int open) {
  int depth = 0;
  String? quote;
  for (int i = open; i < src.length; i++) {
    final String ch = src[i];
    if (quote != null) {
      if (ch == '\\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
    } else if (ch == '(' || ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ')' || ch == ']' || ch == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return src.substring(open + 1);
}

/// Line number (1-based) of [index] in [src].
int _lineOf(String src, int index) => '\n'.allMatches(src.substring(0, index)).length + 1;

/// Every match of [pattern] in the lib sources: (`file:line`, the text of the call's arguments).
List<(String, String)> _callsOf(RegExp pattern) {
  final List<(String, String)> sites = [];
  for (final (String path, String src) in _libSources()) {
    for (final RegExpMatch m in pattern.allMatches(src)) {
      final int open = m.end - 1; // the pattern ends with the opening bracket
      sites.add(('$path:${_lineOf(src, m.start)}', _argumentsOf(src, open)));
    }
  }
  return sites;
}

/// The cells of a markdown table row, trimmed (the leading and trailing pipes give empty ends that are dropped).
List<String> _cells(String row) => row.split('|').map((c) => c.trim()).toList()..removeAt(0)..removeLast();

void main() {
  test('G25: the library throws no raw Dart error (ArgumentError, StateError, DatabaseException, ...) outside reviewed internal sites', () {
    // Raw errors that never reach the caller: each is converted to a typed exception by its caller (see the reason).
    const Map<String, (int, String)> reviewed = {
      // Enum decoding: caught in FluentRowMapping._decodeConverted and rethrown as FluentSchemaException with a hint.
      'lib/src/models/db/fluent_converter.dart': (1, 'FluentEnumConverter.fromSql, converted by _decodeConverted'),
      // The same enum path: FormatException for a name unknown to the enum, converted in _decodeConverted.
      'lib/src/core/fluent_provider/parts/fluent_row_mapping.dart': (1, 'unknown enum name, converted by _decodeConverted'),
      // FluentFilterArgs is a List: the Dart List contract requires UnsupportedError on the fixed-length list writes.
      'lib/src/utils/fluent_filter.dart': (2, 'List protocol of FluentFilterArgs (never a user error path)'),
    };
    final RegExp raw = RegExp(r'throw\s+(ArgumentError|StateError|DatabaseException|UnsupportedError|FormatException|TypeError|Exception)\b');
    final Map<String, List<String>> found = {};
    for (final (String path, String src) in _libSources()) {
      for (final RegExpMatch m in raw.allMatches(src)) {
        found.putIfAbsent(path, () => []).add('${_lineOf(src, m.start)}: ${m.group(1)}');
      }
    }
    for (final MapEntry<String, List<String>> e in found.entries) {
      final int allowed = reviewed[e.key]?.$1 ?? 0;
      expect(e.value.length, lessThanOrEqualTo(allowed), reason: '${e.key} throws a raw error: ${e.value}. Throw a Fluent*Exception with a hint.');
    }
    for (final MapEntry<String, (int, String)> e in reviewed.entries) {
      expect(found[e.key]?.length ?? 0, e.value.$1, reason: 'reviewed site of ${e.key} (${e.value.$2}) is gone: update the list.');
    }
  });

  test('G26: every FluentLog.issue( call gives a non-empty hint', () {
    final List<String> missing = [];
    for (final (String site, String args) in _callsOf(RegExp(r'FluentLog\.issue\('))) {
      final RegExpMatch? hint = RegExp(r'hint:\s*(\S[^,\n]*)').firstMatch(args);
      if (hint == null || hint.group(1)!.trim() == "''" || hint.group(1)!.trim() == '""') missing.add(site);
    }
    expect(missing, isEmpty, reason: 'issues without a hint: $missing');
  });

  test('G26: every FluentLog.publish( call with a FluentIssue( literal gives a fix', () {
    final List<String> missing = [];
    for (final (String site, String args) in _callsOf(RegExp(r'FluentLog\.publish\(FluentIssue\('))) {
      if (!args.contains('fix:')) missing.add(site);
    }
    expect(missing, isEmpty, reason: 'issues published without a fix: $missing');
  });

  test('G26: every FluentIssue( construction in lib/ gives a fix (also when not passed straight to publish)', () {
    final List<String> missing = [];
    for (final (String site, String args) in _callsOf(RegExp(r'(?<![\w.])FluentIssue\('))) {
      if (args.trimLeft().startsWith('{')) continue; // the constructor itself
      if (!args.contains('fix:')) missing.add(site);
    }
    expect(missing, isEmpty, reason: 'FluentIssue constructions without a fix: $missing');
  });

  test('G26: every typed exception built in lib/ gives a hint (inside throw or FluentLog.raise)', () {
    // The constructors are declared in fluent_exceptions.dart; every use elsewhere names its hint.
    final RegExp build = RegExp(r'(?<![\w.])(Fluent(Config|Schema|Argument|Constraint|Query|Relation|Sync|Cancelled|Engine)?Exception)\(');
    final List<String> missing = [];
    for (final (String path, String src) in _libSources()) {
      if (path.endsWith('lib/src/exceptions/fluent_exceptions.dart')) continue;
      for (final RegExpMatch m in build.allMatches(src)) {
        final String before = src.substring(m.start > 40 ? m.start - 40 : 0, m.start);
        // Only constructions: a throw, a raise, a return or an arrow body (not a type, a class header or a cast).
        if (!RegExp(r'(throw|raise\(|return|=>|\?\?|:)\s*$').hasMatch(before)) continue;
        if (!_argumentsOf(src, m.end - 1).contains('hint')) missing.add('$path:${_lineOf(src, m.start)}');
      }
    }
    expect(missing, isEmpty, reason: 'typed exceptions without a hint: $missing');
  });

  test('G26: every error code is documented with a non-empty fix in doc/ai/error-codes.md', () {
    final List<String> rows = File('doc/ai/error-codes.md').readAsLinesSync().where((l) => l.startsWith('| `')).toList();
    for (final FluentErrorCode code in FluentErrorCode.values) {
      final String? row = rows.where((r) => r.startsWith('| `${code.name}` |')).firstOrNull;
      expect(row, isNotNull, reason: '${code.name} has a row');
      final List<String> cells = _cells(row!);
      expect(cells.length, 5, reason: '${code.name}: Code | Class | Meaning | Typical cause | Fix');
      expect(cells[4], isNotEmpty, reason: '${code.name} has a fix');
      expect(cells[2], isNotEmpty, reason: '${code.name} has a meaning');
    }
  });

  test('G26: every issue kind is documented with a non-empty description in doc/ai/issues.md', () {
    // issues.md has no fix column (the fix is written per occurrence in the hint): the "When" column is checked.
    final List<String> rows = File('doc/ai/issues.md').readAsLinesSync().where((l) => l.startsWith('| `')).toList();
    for (final FluentIssueKind kind in FluentIssueKind.values) {
      final String? row = rows.where((r) => r.startsWith('| `${kind.name}` |')).firstOrNull;
      expect(row, isNotNull, reason: '${kind.name} has a row');
      final List<String> cells = _cells(row!);
      expect(cells.length, 5, reason: '${kind.name}: Kind | Type | Impact | Reported | When');
      expect(cells[4], isNotEmpty, reason: '${kind.name} says when it is reported');
    }
  });
}
