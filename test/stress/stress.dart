// Shared parts of the stress tests (test/stress): a scale factor and a report of sizes and timings.
//
// The stress tests check the same guarantees as the rest of the suite (G1, G6, G7, G12, G16, G19, ...), only on a big
// world: many rows, wide rows, deep relation graphs, many tables and databases, many concurrent callers. They run in
// the normal suite at scale 1 (seconds) so they never rot; a longer run scales them up:
//
//   FLUENT_STRESS=20 bash tool/mirror_test.sh stress test/stress
//
// Timings are printed and written to a Markdown report, never asserted: only statement counts, complexity and
// correctness are. The report: FLUENT_STRESS_REPORT=<file> (tool/mirror_test.sh sets
// .mirrors/stress_<name>_<date-time>.md, one file per run), else build/stress_report.md. Each test adds a table
// (step, time, memory, details); the path is printed at the end of each test.
import 'dart:io';
import 'dart:math';

/// The scale of this run: env `FLUENT_STRESS`, default 1.
int stressScale() => max(1, int.tryParse(Platform.environment['FLUENT_STRESS'] ?? '') ?? 1);

/// [base] scaled by [stressScale].
int scaled(int base) => base * stressScale();

/// A time limit for one stress test that grows with the scale.
Duration stressLimit({int secondsPerScale = 60}) => Duration(seconds: secondsPerScale * stressScale());

/// The resident memory of this process in MB.
int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

/// Measures the steps of one stress test and appends them to the report.
class StressReport {
  StressReport(this.test);

  /// The test this report is about.
  final String test;
  final List<String> _lines = [];
  final List<(String step, int ms, int rss, String detail)> _steps = [];
  final Stopwatch _total = Stopwatch()..start();

  /// Runs [step], recording its time, the memory after it and [detail] (sizes, statement counts).
  Future<R> step<R>(String name, Future<R> Function() step, {String Function(R result)? detail}) async {
    final Stopwatch sw = Stopwatch()..start();
    final R result = await step();
    sw.stop();
    final String more = detail == null ? '' : detail(result);
    _steps.add((name, sw.elapsedMilliseconds, rssMb(), more));
    _print('$name: ${sw.elapsedMilliseconds} ms, rss ${rssMb()} MB${more.isEmpty ? '' : ', $more'}');
    return result;
  }

  /// Adds a free line (listed under the table).
  void note(String line) {
    _lines.add(line);
    _print(line);
  }

  void _print(String line) {
    // ignore: avoid_print
    print('[stress x${stressScale()}] $test: $line');
  }

  /// Appends this test's table (and its notes) to the report file and prints where it is.
  void save() {
    final String path = Platform.environment['FLUENT_STRESS_REPORT'] ?? 'build/stress_report.md';
    final int peak = _steps.fold(rssMb(), (m, s) => s.$3 > m ? s.$3 : m);
    final StringBuffer sb = StringBuffer()
      ..writeln()
      ..writeln('## $test')
      ..writeln()
      ..writeln('Scale ${stressScale()}, total ${(_total.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, peak rss $peak MB, ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('| step | ms | rss MB | details |')
      ..writeln('|---|---:|---:|---|');
    for (final (String step, int ms, int rss, String detail) in _steps) {
      sb.writeln('| $step | $ms | $rss | $detail |');
    }
    if (_lines.isNotEmpty) {
      sb.writeln();
      for (final String l in _lines) {
        sb.writeln('- $l');
      }
    }
    try {
      final File file = File(path)..parent.createSync(recursive: true);
      if (!file.existsSync()) file.writeAsStringSync('# Stress report\n');
      file.writeAsStringSync(sb.toString(), mode: FileMode.append);
      _print('report ${file.absolute.path}');
    } on FileSystemException {
      // The report is a convenience; the test result does not depend on it.
    }
  }
}
