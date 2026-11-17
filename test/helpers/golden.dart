// Golden files for formats that are a contract (G6, G17): stored forms, cursor text, generated DDL, migration plans.
//
// Golden contents are generated, never written by hand:
//   FLUENT_GOLDEN_UPDATE=1 FLUENT_GOLDEN_DIR="$PWD/test/golden" bash tool/mirror_test.sh <name> <file>
// writes them into the checkout; the lead reviews each new or changed golden line by line (a golden generated from
// buggy code pins the bug).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Whether goldens are rewritten in this run (env `FLUENT_GOLDEN_UPDATE=1`).
bool get goldenUpdate => Platform.environment['FLUENT_GOLDEN_UPDATE'] == '1';

/// Compares [actual] with `test/golden/<name>`; with [goldenUpdate] it writes the file instead — into
/// `FLUENT_GOLDEN_DIR` when set (the checkout's absolute `test/golden`, so a mirror run writes there).
void expectGolden(String name, String actual) {
  final File file = File('test/golden/$name');
  final String text = '${actual.replaceAll('\r\n', '\n').trimRight()}\n';
  if (goldenUpdate) {
    final String? dir = Platform.environment['FLUENT_GOLDEN_DIR'];
    final File target = dir == null ? file : File('$dir/$name');
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(text);
    return;
  }
  if (!file.existsSync()) fail('G17: golden "test/golden/$name" is missing; generate it with FLUENT_GOLDEN_UPDATE=1 and review it');
  final String expected = file.readAsStringSync().replaceAll('\r\n', '\n');
  if (expected == text) return;
  final List<String> e = expected.split('\n');
  final List<String> a = text.split('\n');
  final int first = Iterable<int>.generate(e.length < a.length ? e.length : a.length).firstWhere((i) => e[i] != a[i], orElse: () => e.length < a.length ? e.length : a.length);
  fail(
    'G17: "$name" differs from its golden at line ${first + 1}\n'
    '  golden: ${first < e.length ? e[first] : '<end>'}\n'
    '  actual: ${first < a.length ? a[first] : '<end>'}\n'
    'If the change is deliberate: FLUENT_GOLDEN_UPDATE=1, review the diff, add a CHANGELOG line.',
  );
}
