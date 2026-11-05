// The on-device benchmark runs end to end (small sizes; numbers under FFI are not meaningful for phones).
import 'dart:convert';

import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  test('FluentBenchmark.run reports every scenario', () async {
    final String report = await FluentBenchmark.run(rows: const int.fromEnvironment('FLUENT_BENCH_ROWS', defaultValue: 400), parallelReads: 4);
    expect(report, allOf(contains('0 read connection'), contains('2 read connection'), contains('background isolate'), contains('longest UI stall')));
    // ignore: avoid_print
    if (const bool.fromEnvironment('FLUENT_BENCH')) print(report);
  });

  group('FluentBenchmark.runScenarios', () {
    late FluentBenchmarkReport report;

    setUpAll(() async {
      report = await FluentBenchmark.runScenarios(size: const int.fromEnvironment('FLUENT_BENCH_SIZE', defaultValue: 30), bulkSizes: const [100, 400], runs: 3);
      // ignore: avoid_print
      if (const bool.fromEnvironment('FLUENT_BENCH')) print(report);
    });

    test('every scenario runs and returns sane numbers', () {
      const List<String> groups = [
        'queue.concurrentReads',
        'queue.identicalReads',
        'queue.distinctReads',
        'queue.readsAndWrites',
        'queue.sequentialCalls',
        'save.single',
        'save.merged',
        'save.saveAll',
        'save.conflictOn',
        'save.graphChildren',
        'save.graphManyToMany',
        'relations.one',
        'relations.many',
        'relations.manyToMany',
        'relations.nested',
        'relations.limited',
        'deletes.softCascade',
        'deletes.trashForever',
        'deletes.hardByFilter',
      ];
      for (final String group in groups) {
        final List<FluentBenchmarkResult> results = report[group];
        expect(results, isNotEmpty, reason: group);
        for (final FluentBenchmarkResult r in results) {
          expect(r.runs, hasLength(3), reason: r.name);
          expect(r.median, greaterThan(Duration.zero), reason: r.name);
          expect(r.min, lessThanOrEqualTo(r.median));
          expect(r.max, greaterThanOrEqualTo(r.median));
          expect(r.perOperationMicros, greaterThan(0), reason: r.name);
          expect(r.statements, isNotNull, reason: '${r.name}: statements are counted under FFI');
          expect(r.statements, greaterThan(0), reason: r.name);
        }
      }
      expect(report['save.saveAll'].map((r) => r.size), [100, 400]);
    });

    test('the engine merges and collapses', () {
      expect(report['queue.identicalReads'].single.counters['collapsedReads'], greaterThan(0));
      expect(report['queue.concurrentReads'].single.counters['batchedLookups'], greaterThan(0));
      expect(report['save.merged'].single.counters['mergedSaves'], greaterThan(0));
      // Merged saves send fewer statements than the same saves one by one.
      expect(report['save.merged'].single.statements!, lessThan(report['save.single'].single.statements!));
    });

    test('relation loads do not send more statements for more parents (N+1 guard)', () {
      expect(report.nPlusOneSuspects, isEmpty, reason: report.toString());
      for (final String group in ['relations.one', 'relations.many', 'relations.manyToMany', 'relations.nested', 'relations.limited']) {
        final List<FluentBenchmarkResult> sizes = report[group];
        expect(sizes, hasLength(2));
        expect(sizes.last.size, sizes.first.size * 4);
        expect(sizes.last.statements, lessThanOrEqualTo(sizes.first.statements!), reason: group);
      }
    });

    test('a report prints, round-trips as JSON and compares with a baseline', () {
      expect(report.toString(), allOf(contains('queue.concurrentReads'), contains('deletes.hardByFilter'), contains('statements')));
      final FluentBenchmarkReport copy = FluentBenchmarkReport.fromJson(jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>);
      expect(copy.results, hasLength(report.results.length));
      expect(copy.results.first.median, report.results.first.median);
      expect(report.compareTo(copy).where((d) => d.regressed), isEmpty);
      // A baseline ten times faster than this run flags every scenario.
      final FluentBenchmarkReport fast = FluentBenchmarkReport([
        for (final FluentBenchmarkResult r in report.results)
          FluentBenchmarkResult(group: r.group, name: r.name, size: r.size, operations: r.operations, runs: [for (final Duration d in r.runs) d ~/ 10]),
      ]);
      final List<FluentBenchmarkDelta> deltas = report.compareTo(fast, minimum: Duration.zero);
      expect(deltas, hasLength(report.results.length));
      expect(deltas.every((d) => d.regressed), isTrue);
      expect(deltas.first.toString(), contains('SLOWER'));
    });
  });

  test('suites can be selected', () async {
    final FluentBenchmarkReport report = await FluentBenchmark.runScenarios(suites: {FluentBenchmarkSuite.deletes}, size: 10, bulkSizes: const [20], runs: 1, warmUp: 0);
    expect(report.results.map((r) => r.group).toSet(), {'deletes.softCascade', 'deletes.trashForever', 'deletes.hardByFilter'});
  });
}
