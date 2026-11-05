// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// On-device benchmark of the read path: parallel reads (read connection pool) and how long a big list blocks the
/// UI isolate while it is turned into models (on the UI isolate, sliced, or in a background isolate).
///
/// Run it in any app on a real phone (add `fluent_sqflite_benchmark` to the app's dependencies for the run):
/// ```dart
/// import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart';
///
/// debugPrint(await FluentBenchmark.run());
/// ```
///
/// The scenarios of the engine, saves, relation loads and deletes report timings (median of several runs after a
/// warm-up) and SQL statement counts, and can be compared with an earlier run to catch regressions:
/// ```dart
/// final FluentBenchmarkReport report = await FluentBenchmark.runScenarios(); // all suites
/// debugPrint(report.toString());
/// assert(report.nPlusOneSuspects.isEmpty); // statements must not grow with the number of parents
/// ```
library;

import 'dart:async';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:sqflite/sqflite.dart';

import 'src/benchmark_result.dart';
import 'src/scenarios.dart';
import 'src/statement_counter.dart';

export 'src/benchmark_result.dart' show FluentBenchmarkDelta, FluentBenchmarkReport, FluentBenchmarkResult, FluentBenchmarkSuite;
export 'src/statement_counter.dart' show FluentStatementCounter;

/// Runs the benchmark scenarios and reports them as text.
// ignore: avoid_classes_with_only_static_members
abstract final class FluentBenchmark {
  /// Runs every scenario with [rows] rows ([parallelReads] concurrent counts for the read pool scenario); each
  /// database is a file in the app's databases directory, deleted afterwards.
  static Future<String> run({int rows = 5000, int parallelReads = 20}) async {
    final StringBuffer out = StringBuffer('fluent_sqflite benchmark ($rows rows)\n');
    for (final int connections in [0, 2, 4]) {
      final int ms = await _withDb('bench_reads_$connections', FluentDbConfig(readConnections: connections), const FluentConfig(), rows, (p) async {
        final Stopwatch sw = Stopwatch()..start();
        await Future.wait([for (int i = 0; i < parallelReads; i++) p.count(where: FluentFilter('"label" LIKE ? AND "n" > ?', ['%${i}7%', i]))]);
        return sw.elapsedMilliseconds;
      });
      out.writeln('  $parallelReads parallel reads, $connections read connection(s): $ms ms');
    }
    final Map<String, FluentConfig> mappings = {
      'UI isolate, not sliced': const FluentConfig(isolateMapping: FluentIsolateMapping.never, sliceAfterRows: 0),
      'UI isolate, sliced': const FluentConfig(isolateMapping: FluentIsolateMapping.never),
      'background isolate': const FluentConfig(isolateMapping: FluentIsolateMapping.always),
    };
    for (final MapEntry<String, FluentConfig> m in mappings.entries) {
      final (int total, int stall) = await _withDb('bench_map', const FluentDbConfig(), m.value, rows, (p) async {
        final _StallMeter meter = _StallMeter()..start();
        final Stopwatch sw = Stopwatch()..start();
        await p.findAll();
        sw.stop();
        return (sw.elapsedMilliseconds, meter.stop());
      });
      out.writeln('  findAll $rows rows, ${m.key}: $total ms, longest UI stall $stall ms');
    }
    return out.toString();
  }

  /// Runs the scenario [suites] (default: all) and returns timings and statement counts.
  ///
  /// * [size]: calls per queue scenario, rows per save / delete scenario, parents of the smaller relation load (the
  ///   larger one has four times as many: the statements of both are compared for N+1 patterns).
  /// * [bulkSizes]: rows of the `saveAll` scenarios (and the first one for the hard delete).
  /// * [runs] timed runs per scenario after [warmUp] untimed ones; the result holds the median.
  ///
  /// Every scenario uses its own database file, deleted afterwards. Statements are counted when the platform's
  /// database factory allows it (`FluentBenchmarkResult.statements` is `null` otherwise).
  ///
  /// ```dart
  /// final FluentBenchmarkReport report = await FluentBenchmark.runScenarios(suites: {FluentBenchmarkSuite.save}, bulkSizes: [1000, 10000]);
  /// for (final FluentBenchmarkResult r in report['save.saveAll']) {
  ///   print('${r.size} rows: ${r.median.inMilliseconds} ms');
  /// }
  /// ```
  static Future<FluentBenchmarkReport> runScenarios({
    Set<FluentBenchmarkSuite> suites = const {...FluentBenchmarkSuite.values},
    int size = 200,
    List<int> bulkSizes = const [1000, 10000],
    int runs = 5,
    int warmUp = 1,
  }) async {
    assert(runs > 0 && warmUp >= 0 && size > 0, 'runs and size must be positive');
    final FluentStatementCounter? counter = await FluentStatementCounter.tryInstall();
    final FluentScenarioRunner runner = FluentScenarioRunner(size: size, bulkSizes: bulkSizes, runs: runs, warmUp: warmUp, counter: counter);
    try {
      await runner.run(suites);
    } finally {
      counter?.uninstall();
    }
    return FluentBenchmarkReport(runner.results);
  }

  static Future<R> _withDb<R>(String name, FluentDbConfig config, FluentConfig engine, int rows, Future<R> Function(_BenchProvider p) body) async {
    final _BenchProvider provider = _BenchProvider();
    final FluentDbKey key = FluentDbKey(name);
    await FluentDb.init([FluentGroup(dbKey: key, providerList: [provider], config: config)], config: engine);
    try {
      await provider.saveAll([for (int i = 1; i <= rows; i++) _BenchItem(id: i, label: 'item $i ${i * 31}', n: i % 97, at: DateTime(2026).add(Duration(minutes: i)), tags: ['a$i', 'b'])]);
      return await body(provider);
    } finally {
      await FluentDb.close();
      await databaseFactory.deleteDatabase('${await getDatabasesPath()}/$name.db');
    }
  }
}

/// Measures the longest gap between ticks of a 1 ms timer: how long the UI isolate could not render.
class _StallMeter {
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  int _last = 0;
  int _longest = 0;

  void start() {
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = _clock.elapsedMilliseconds;
      if (now - _last > _longest) _longest = now - _last;
      _last = now;
    });
  }

  int stop() {
    _timer?.cancel();
    final int now = _clock.elapsedMilliseconds;
    return now - _last > _longest ? now - _last : _longest;
  }
}

class _BenchItem extends FluentStorable {
  _BenchItem({this.id, required this.label, required this.n, required this.at, required this.tags});

  final int? id;
  final String label;
  final int n;
  final DateTime at;
  final List<String> tags;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'label': label, 'n': n, 'at': at, 'tags': tags};

  static _BenchItem fromJson(Map<String, dynamic> json) =>
      _BenchItem(id: json['id'] as int?, label: json['label'] as String, n: json['n'] as int, at: json['at'] as DateTime, tags: (json['tags'] as List).cast<String>());
}

class _BenchProvider extends FluentProvider<_BenchItem> {
  @override
  String get tableName => 'bench_items';

  @override
  _BenchItem get modelSample => _BenchItem(label: '', n: 0, at: DateTime(2000), tags: const ['']);

  @override
  _BenchItem fromCacheJson(Map<String, dynamic> json) => _BenchItem.fromJson(json);

  @override
  _BenchItem Function(Map<String, dynamic> json)? get isolateFactory => _BenchItem.fromJson;
}
