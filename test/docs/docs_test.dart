// Keeps the documentation honest: skill format (agentskills.io + Dart package skills), reference copies, links,
// and the error-code and issue tables covering every FluentErrorCode / FluentIssueKind.
import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:flutter_test/flutter_test.dart';

/// The YAML frontmatter fields of a SKILL.md (supports folded `>-` values).
Map<String, String> _frontmatter(String text) {
  final List<String> lines = text.split('\n');
  expect(lines.first.trim(), '---', reason: 'SKILL.md starts with YAML frontmatter');
  final int end = lines.indexWhere((l) => l.trim() == '---', 1);
  final Map<String, String> fields = {};
  String? folding;
  for (final String line in lines.sublist(1, end)) {
    final RegExpMatch? m = RegExp(r'^([a-z-]+):\s*(.*)$').firstMatch(line);
    if (m != null) {
      folding = m.group(2) == '>-' ? m.group(1) : null;
      fields[m.group(1)!] = folding != null ? '' : m.group(2)!.trim();
    } else if (folding != null && line.startsWith('  ')) {
      fields[folding] = '${fields[folding]} ${line.trim()}'.trim();
    }
  }
  return fields;
}

void main() {
  final Directory skills = Directory('skills');

  test('every skill follows the Agent Skills spec and the Dart prefix rule', () {
    final List<Directory> dirs = skills.listSync().whereType<Directory>().toList();
    expect(dirs, isNotEmpty);
    for (final Directory dir in dirs) {
      final String folder = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final File skill = File('${dir.path}/SKILL.md');
      expect(skill.existsSync(), isTrue, reason: '$folder has SKILL.md');
      final String text = skill.readAsStringSync();
      final Map<String, String> fm = _frontmatter(text);
      final String name = fm['name'] ?? '';
      expect(name, folder, reason: 'name matches the folder');
      expect(name, matches(RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$')), reason: 'lowercase, digits, single hyphens');
      expect(name.length, lessThanOrEqualTo(64));
      expect(name, startsWith('fluent-sqflite-'), reason: 'Dart package skills: prefixed with the package name');
      final String description = fm['description'] ?? '';
      expect(description, isNotEmpty);
      expect(description.length, lessThanOrEqualTo(1024));
      expect(description, startsWith('Use when'), reason: '$folder: description says when to use it');
      expect(text.split('\n').length, lessThan(500), reason: '$folder: SKILL.md under 500 lines');
    }
  });

  test('reference copies inside skills equal doc/ai', () {
    expect(File('skills/fluent-sqflite-upgrade/references/migrations.md').readAsStringSync(), File('doc/ai/migrations.md').readAsStringSync());
    expect(File('skills/fluent-sqflite-troubleshooting/references/error-codes.md').readAsStringSync(), File('doc/ai/error-codes.md').readAsStringSync());
    expect(File('skills/fluent-sqflite-troubleshooting/references/issues.md').readAsStringSync(), File('doc/ai/issues.md').readAsStringSync());
  });

  test('relative links in README, llms.txt, doc and skills point to existing files', () {
    final List<File> files = [
      File('README.md'),
      File('llms.txt'),
      ...Directory('doc').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.md')),
      ...skills.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.md')),
    ];
    final RegExp link = RegExp(r'\]\(([^)#\s]+)(#[^)]*)?\)');
    for (final File f in files) {
      for (final RegExpMatch m in link.allMatches(f.readAsStringSync())) {
        final String target = m.group(1)!;
        if (target.startsWith('http')) continue;
        final Uri resolved = f.absolute.uri.resolve(target);
        final bool exists = File.fromUri(resolved).existsSync() || Directory.fromUri(resolved).existsSync();
        expect(exists, isTrue, reason: '${f.path} links to $target');
      }
    }
  });

  test('the error-code table lists every FluentErrorCode', () {
    final String table = File('doc/ai/error-codes.md').readAsStringSync();
    for (final FluentErrorCode code in FluentErrorCode.values) {
      expect(table, contains('| `${code.name}` |'), reason: '${code.name} is documented');
    }
  });

  test('the issue table lists every FluentIssueKind with its type', () {
    final String table = File('doc/ai/issues.md').readAsStringSync();
    for (final FluentIssueKind kind in FluentIssueKind.values) {
      expect(table, contains('| `${kind.name}` | ${kind.type.name} |'), reason: '${kind.name} is documented');
    }
  });

  test('every public type is explained to agents (llms.txt, doc/ai, skills)', () {
    final String ai = [
      File('llms.txt').readAsStringSync(),
      for (final FileSystemEntity f in [...Directory('doc/ai').listSync(), ...skills.listSync(recursive: true)])
        if (f is File && f.path.endsWith('.md')) f.readAsStringSync(),
    ].join('\n');
    final String public = File('lib/fluent_sqflite.dart').readAsStringSync();
    final Set<String> hidden = {for (final RegExpMatch m in RegExp(r'hide([^;]*);').allMatches(public)) ...RegExp(r'\w+').allMatches(m[1]!).map((w) => w[0]!)};
    // Not exported (src/internal.dart only), or only reached through a documented member (enum behind FluentUpdate.*, …).
    const Set<String> notForAgents = {
      'FluentAnalyzer', 'FluentEngine', 'FluentLog', 'FluentSqlSanitizer', 'FluentTableStatsTracker', 'FluentTask',
      'FluentTuner', 'FluentTypeCodecs', 'FluentClockTimer', 'FluentClockAlarm', 'TableHelper', 'FluentTouchedTable', 'FluentTransactionScope', 'FluentReadScope',
      'FluentAggregateFunction', 'FluentQueryCost', 'FluentUpdateOperation', 'FluentValueKind', 'MigrationPlanCallback',
    };
    final List<String> missing = [];
    for (final File f in Directory('lib/src').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final RegExpMatch m in RegExp(r'^(?:abstract |sealed |final |base )*(?:class|enum|mixin|typedef) ([A-Z]\w*)', multiLine: true).allMatches(f.readAsStringSync())) {
        final String name = m[1]!;
        if (hidden.contains(name) || notForAgents.contains(name)) continue;
        if (!RegExp('\\b$name\\b').hasMatch(ai)) missing.add(name);
      }
    }
    expect(missing, isEmpty, reason: 'mention them in the matching skill (or list them above with a reason)');
  });
}
