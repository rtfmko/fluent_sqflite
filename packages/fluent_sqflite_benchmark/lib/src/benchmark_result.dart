// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// The scenario groups of `FluentBenchmark.runScenarios`.
enum FluentBenchmarkSuite {
  /// Many concurrent small reads (collapsing, `findById` to `IN`), reads between writes, call overhead.
  queue,

  /// Single saves, bulk saves, merged saves, `conflictOn` upserts, saves of models with relations.
  save,

  /// Eager relation loads with growing parent counts (N+1 guard), limited lists, nested depth.
  relations,

  /// Soft delete with cascade, hard delete by filter.
  deletes,
}

/// The outcome of one scenario: the timings of its measured runs and what the engine did meanwhile.
///
/// ```dart
/// final FluentBenchmarkResult r = report['save.saveAll'].first;
/// print('${r.name}: median ${r.median.inMilliseconds} ms, ${r.perOperationMicros.toStringAsFixed(1)} us per row');
/// ```
class FluentBenchmarkResult {
  /// Creates a result; [runs] must not be empty.
  FluentBenchmarkResult({
    required this.group,
    required this.name,
    required this.size,
    required this.operations,
    required this.runs,
    this.statements,
    this.statementsConstant = false,
    this.counters = const {},
  }) : assert(runs.isNotEmpty, 'a result needs at least one run');

  /// Reads a result written by [toJson].
  factory FluentBenchmarkResult.fromJson(Map<String, dynamic> json) => FluentBenchmarkResult(
    group: json['group'] as String,
    name: json['name'] as String,
    size: json['size'] as int,
    operations: json['operations'] as int,
    runs: [for (final Object? us in json['runsMicros'] as List<dynamic>) Duration(microseconds: us! as int)],
    statements: json['statements'] as int?,
    statementsConstant: json['statementsConstant'] as bool? ?? false,
    counters: {for (final MapEntry<String, dynamic> e in (json['counters'] as Map<String, dynamic>).entries) e.key: e.value as int},
  );

  /// The scenario family, e.g. `queue.concurrentReads`; results of one family differ in [size] only.
  final String group;

  /// A readable name with the size, e.g. `save.saveAll (1000 rows)`.
  final String name;

  /// The data size of the run (rows, parents): scenarios of one [group] with different sizes show how a call scales.
  final int size;

  /// How many calls or rows one run handles (the divisor of [perOperationMicros]).
  final int operations;

  /// The timed runs (warm-up excluded), in order.
  final List<Duration> runs;

  /// SQL statements one run sent to SQLite, or `null` when they could not be counted (see `FluentStatementCounter`).
  final int? statements;

  /// Whether [statements] must not grow with [size] (relation loads: one batched query per relation, never one per
  /// parent); `FluentBenchmarkReport.nPlusOneSuspects` checks these.
  final bool statementsConstant;

  /// What the engine did during one run: `collapsedReads`, `mergedSaves`, `batchedLookups`, `tasks` (zero entries are left out).
  final Map<String, int> counters;

  /// The middle run: robust against one slow run (GC, a frame, another app).
  Duration get median {
    final List<Duration> sorted = [...runs]..sort();
    final int mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : Duration(microseconds: (sorted[mid - 1].inMicroseconds + sorted[mid].inMicroseconds) ~/ 2);
  }

  /// The fastest run.
  Duration get min => runs.reduce((a, b) => a < b ? a : b);

  /// The slowest run.
  Duration get max => runs.reduce((a, b) => a > b ? a : b);

  /// Median microseconds per operation.
  double get perOperationMicros => operations == 0 ? 0 : median.inMicroseconds / operations;

  /// A form that [FluentBenchmarkResult.fromJson] reads back (store a report as a baseline).
  Map<String, dynamic> toJson() => {
    'group': group,
    'name': name,
    'size': size,
    'operations': operations,
    'runsMicros': [for (final Duration d in runs) d.inMicroseconds],
    'statements': statements,
    'statementsConstant': statementsConstant,
    'counters': counters,
  };

  @override
  String toString() {
    final StringBuffer b = StringBuffer(name.padRight(46))
      ..write('${_ms(median)} ms'.padLeft(11))
      ..write('  (min ${_ms(min)}, max ${_ms(max)}; ${perOperationMicros.toStringAsFixed(1)} us/op)');
    if (statements != null) b.write(', $statements statements');
    if (counters.isNotEmpty) b.write(', ${counters.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
    return b.toString();
  }

  static String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);
}

/// One scenario compared with the same scenario of a baseline report.
class FluentBenchmarkDelta {
  /// Creates a comparison.
  const FluentBenchmarkDelta({required this.name, required this.baseline, required this.current, required this.regressed});

  /// The scenario name.
  final String name;

  /// Median of the baseline run.
  final Duration baseline;

  /// Median of this run.
  final Duration current;

  /// Whether [current] is slower than [baseline] by more than the tolerance given to `compareTo`.
  final bool regressed;

  /// `current / baseline` (above 1: slower).
  double get ratio => baseline.inMicroseconds == 0 ? 1 : current.inMicroseconds / baseline.inMicroseconds;

  @override
  String toString() =>
      '${regressed ? 'SLOWER ' : '       '}$name: ${(baseline.inMicroseconds / 1000).toStringAsFixed(1)} ms -> '
      '${(current.inMicroseconds / 1000).toStringAsFixed(1)} ms (x${ratio.toStringAsFixed(2)})';
}

/// The results of a benchmark run: print it, store it as a baseline, compare a later run with it.
///
/// ```dart
/// final FluentBenchmarkReport report = await FluentBenchmark.runScenarios();
/// debugPrint(report.toString());
/// final String baseline = jsonEncode(report.toJson()); // keep it, e.g. in a file
/// // later:
/// final FluentBenchmarkReport now = await FluentBenchmark.runScenarios();
/// final slower = now.compareTo(FluentBenchmarkReport.fromJson(jsonDecode(baseline) as Map<String, dynamic>)).where((d) => d.regressed);
/// ```
class FluentBenchmarkReport {
  /// Creates a report.
  FluentBenchmarkReport(this.results);

  /// Reads a report written by [toJson].
  factory FluentBenchmarkReport.fromJson(Map<String, dynamic> json) =>
      FluentBenchmarkReport([for (final Object? r in json['results'] as List<dynamic>) FluentBenchmarkResult.fromJson(r! as Map<String, dynamic>)]);

  /// Every scenario, in run order.
  final List<FluentBenchmarkResult> results;

  /// The results of one [FluentBenchmarkResult.group], smallest size first.
  List<FluentBenchmarkResult> operator [](String group) => results.where((r) => r.group == group).toList()..sort((a, b) => a.size.compareTo(b.size));

  /// Groups that must send the same statements for any size (`statementsConstant`: relation loads) but send more for
  /// more parents: an N+1 pattern. Groups whose statements could not be counted are skipped.
  List<String> get nPlusOneSuspects {
    final List<String> suspects = [];
    for (final String group in {for (final FluentBenchmarkResult r in results) r.group}) {
      final List<FluentBenchmarkResult> sizes = this[group].where((r) => r.statements != null && r.statementsConstant).toList();
      if (sizes.length >= 2 && sizes.first.size < sizes.last.size && sizes.last.statements! > sizes.first.statements!) suspects.add(group);
    }
    return suspects;
  }

  /// Compares the median of every scenario with the same name in [baseline]; scenarios missing there are skipped.
  /// [tolerance] 0.25 flags runs more than 25 % slower; runs under [minimum] are never flagged (timer noise).
  List<FluentBenchmarkDelta> compareTo(FluentBenchmarkReport baseline, {double tolerance = 0.25, Duration minimum = const Duration(milliseconds: 2)}) {
    final Map<String, FluentBenchmarkResult> before = {for (final FluentBenchmarkResult r in baseline.results) r.name: r};
    final List<FluentBenchmarkDelta> out = [];
    for (final FluentBenchmarkResult r in results) {
      final FluentBenchmarkResult? old = before[r.name];
      if (old == null) continue;
      final bool slower = r.median.inMicroseconds > old.median.inMicroseconds * (1 + tolerance) && r.median > minimum;
      out.add(FluentBenchmarkDelta(name: r.name, baseline: old.median, current: r.median, regressed: slower));
    }
    return out;
  }

  /// A form that [FluentBenchmarkReport.fromJson] reads back.
  Map<String, dynamic> toJson() => {'results': [for (final FluentBenchmarkResult r in results) r.toJson()]};

  @override
  String toString() {
    final StringBuffer b = StringBuffer('fluent_sqflite scenarios\n');
    for (final FluentBenchmarkResult r in results) {
      b.writeln('  $r');
    }
    final List<String> suspects = nPlusOneSuspects;
    if (suspects.isNotEmpty) b.writeln('  N+1 suspects (statements grow with the size): ${suspects.join(', ')}');
    return b.toString();
  }
}
