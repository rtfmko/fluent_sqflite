// The scheduler stays linear: picking the next reads never scans every waiting read.
//
// Before the indexed queue (_FluentDbQueue) each finished read scanned, grouped, copied and filtered the whole waiting
// segment: a burst of thousands of reads that cannot be merged took quadratic time (8000 distinct reads: 23 times the
// time of 1000). Checked by statement-free counts of comparisons, never by wall-clock time.
@Timeout(Duration(seconds: 60))
library;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/relation_models.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late CommentProvider comments;

  setUp(() async {
    db = FluentTestDb(name: 'queue_complexity_${DateTime.now().microsecondsSinceEpoch}');
    final List<FluentProvider> providers = relationProviders();
    comments = providers.whereType<CommentProvider>().single;
    await db.open(providers);
    await comments.saveAll([for (int i = 1; i <= 50; i++) Comment(id: i, text: 't$i', likes: i % 5)]);
  });

  tearDown(() => db.close());

  /// A burst of [n] unawaited calls: distinct reads in three priorities, lookups, and a write every 400 calls; returns
  /// the comparisons the scheduler made.
  Future<int> burst(int n) async {
    FluentEngine().debugReadComparisons = 0;
    final List<Future<Object?>> calls = [];
    final List<Object? Function(Object?)> expected = [];
    for (int i = 0; i < n; i++) {
      if (i % 400 == 399) {
        calls.add(comments.save(Comment(id: 1 + i % 50, text: 't${1 + i % 50}', likes: i % 5)));
        expected.add((_) => null);
      } else if (i % 7 == 0) {
        final int id = 1 + i % 60;
        calls.add(comments.findById(id));
        expected.add((v) => expect((v as Comment?)?.id, id <= 50 ? id : null, reason: 'findById $id'));
      } else {
        final ExecutionPolicy policy = [ExecutionPolicy.background, const ExecutionPolicy(), ExecutionPolicy.fast][i % 3];
        calls.add(comments.findFirst(where: FluentFilter.eq('text', 'missing $i'), policy: policy));
        expected.add((v) => expect(v, isNull));
      }
    }
    final List<Object?> results = await Future.wait(calls);
    for (int i = 0; i < n; i++) {
      expected[i](results[i]);
    }
    return FluentEngine().debugReadComparisons;
  }

  test('picking the next read does not scan the waiting reads (a burst of distinct reads stays linear)', () async {
    final int small = await burst(1000);
    final int big = await burst(8000);
    // Linear: about 8 times the work for 8 times the calls. Quadratic scanning made ~64 times (millions).
    expect(big, lessThan(8000 * 20), reason: '8000 calls took $big comparisons (1000 calls: $small)');
    expect(big, lessThan(small * 16 + 1000), reason: 'the comparisons grow linearly with the calls (1000: $small, 8000: $big)');
  });
}
