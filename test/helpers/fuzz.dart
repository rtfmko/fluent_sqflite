// Seeded random sequences for the guarantee tests (TEST_PLAN.md, technique 1 and 7).
//
// Every random test is replayable: it runs fuzzSeeds() sequences; a failure prints the seed, the step and the
// operations so far. Replay one: FLUENT_SEED=<seed> bash tool/mirror_test.sh <name> <file>.
// Night-size run: FLUENT_FUZZ=2000 (default 25 per test in the normal suite).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

/// Sequences per random test: env `FLUENT_FUZZ`, else [normal].
int fuzzRuns({int normal = 25}) => int.tryParse(Platform.environment['FLUENT_FUZZ'] ?? '') ?? normal;

/// The seed to replay (env `FLUENT_SEED`), or `null`.
int? fuzzSeed() => int.tryParse(Platform.environment['FLUENT_SEED'] ?? '');

/// The seeds one random test runs: only `FLUENT_SEED` when set, else [fuzzRuns] seeds from [base] (give each test its
/// own base so tests do not share sequences).
List<int> fuzzSeeds({int base = 1000, int? count}) {
  final int? one = fuzzSeed();
  if (one != null) return [one];
  return [for (int i = 0; i < (count ?? fuzzRuns()); i++) base + i];
}

/// Random values from one seed.
class FluentFuzz {
  FluentFuzz(this.seed) : _r = Random(seed);

  /// The seed (print it on failure).
  final int seed;
  final Random _r;

  /// `true` with [probability].
  bool chance(double probability) => _r.nextDouble() < probability;

  /// An int in [min] .. [max] (both included).
  int intIn(int min, int max) => min + _r.nextInt(max - min + 1);

  /// One element of [items].
  T pick<T>(List<T> items) => items[_r.nextInt(items.length)];

  /// One of [weighted]'s keys, chosen by its weight.
  T weighted<T>(Map<T, int> weighted) {
    int n = _r.nextInt(weighted.values.fold(0, (a, b) => a + b));
    for (final MapEntry<T, int> e in weighted.entries) {
      if (n < e.value) return e.key;
      n -= e.value;
    }
    return weighted.keys.last;
  }

  /// A random subset of [items] (each kept with [keep]).
  List<T> subset<T>(List<T> items, {double keep = 0.5}) => [for (final T i in items) if (chance(keep)) i];

  /// [items] shuffled (a copy).
  List<T> shuffled<T>(List<T> items) => List.of(items)..shuffle(_r);

  /// A string of up to [max] characters; [unicode] adds non-ASCII, quotes, `%`, `_`, NUL-free control characters.
  String string({int max = 12, bool unicode = true}) {
    const String ascii = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ';
    const List<String> special = ["'", '"', '%', '_', r'\', '\n', '\t', 'ä', 'ß', 'ж', '漢', '🙂', '​', '؟'];
    final int len = _r.nextInt(max + 1);
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < len; i++) {
      sb.write(unicode && chance(0.2) ? pick(special) : ascii[_r.nextInt(ascii.length)]);
    }
    return sb.toString();
  }

  /// A DateTime between 1970 and 2100 with microseconds; [utc] `null` picks at random.
  DateTime dateTime({bool? utc}) {
    final int micros = _r.nextInt(1 << 32) * 1000000 + _r.nextInt(1000000);
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: utc ?? chance(0.5));
  }

  /// A double including edge values (0, -0, tiny, huge) now and then.
  double float() => chance(0.1) ? pick(const [0.0, -0.0, 1e-300, 1e300, -1.5, 0.1]) : (_r.nextDouble() - 0.5) * pow(10, _r.nextInt(12));
}

/// One step of a random sequence.
class FuzzOp {
  FuzzOp(this.name, this.run);

  /// What it does, for the failure report (include the arguments).
  final String name;

  /// The step.
  final Future<void> Function() run;

  @override
  String toString() => name;
}

/// Runs [steps] operations from [next] with seed [seed], calling [check] after each one (the comparison with the
/// reference model). On any failure the test fails with the seed, the step and every operation so far.
Future<void> runSequence({
  required int seed,
  required int steps,
  required FuzzOp Function(FluentFuzz fuzz, int step) next,
  required FutureOr<void> Function(int step) check,
  Duration stepTimeout = const Duration(seconds: 10),
}) async {
  final FluentFuzz fuzz = FluentFuzz(seed);
  final List<FuzzOp> done = [];
  for (int i = 0; i < steps; i++) {
    final FuzzOp op = next(fuzz, i);
    done.add(op);
    try {
      await op.run().timeout(stepTimeout);
      await check(i);
    } catch (e, st) {
      fail(
        'Sequence failed: seed $seed, step $i ($op)\n'
        'Replay: FLUENT_SEED=$seed\n'
        'Operations:\n${[for (int k = 0; k < done.length; k++) '  $k: ${done[k]}'].join('\n')}\n'
        'Error: $e\n$st',
      );
    }
  }
}
