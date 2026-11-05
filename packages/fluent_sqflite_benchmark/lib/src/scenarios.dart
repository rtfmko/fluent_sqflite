// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.
// Internal to the package (not exported): no public API docs needed.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:sqflite/sqflite.dart';

import 'benchmark_result.dart';
import 'scenario_models.dart';
import 'statement_counter.dart';

/// Runs the queue / save / relation / delete scenarios of `FluentBenchmark.runScenarios`.
class FluentScenarioRunner {
  FluentScenarioRunner({required this.size, required this.bulkSizes, required this.runs, required this.warmUp, this.counter});

  final int size;
  final List<int> bulkSizes;
  final int runs;
  final int warmUp;
  final FluentStatementCounter? counter;
  final List<FluentBenchmarkResult> results = [];

  /// Parents of the small and the large relation load: the statements must not differ.
  List<int> get _relationSizes => [size, size * 4];

  Future<void> run(Set<FluentBenchmarkSuite> suites) async {
    if (suites.contains(FluentBenchmarkSuite.queue)) await queue();
    if (suites.contains(FluentBenchmarkSuite.save)) await save();
    if (suites.contains(FluentBenchmarkSuite.relations)) await relations();
    if (suites.contains(FluentBenchmarkSuite.deletes)) await deletes();
  }

  // ---------------------------------------------------------------- queue

  Future<void> queue() => _withDb('queue', [BenchNoteProvider()], (providers) async {
    final FluentProvider<BenchNote> notes = providers.single as FluentProvider<BenchNote>;
    await notes.saveAll([for (int i = 1; i <= size; i++) BenchNote(id: i, text: 'note $i')]);
    await _measure(
      group: 'queue.concurrentReads',
      label: 'queue.concurrentReads ($size findById)',
      size: size,
      operations: size,
      body: () => Future.wait([for (int i = 1; i <= size; i++) notes.findById(i)]),
    );
    await _measure(
      group: 'queue.identicalReads',
      label: 'queue.identicalReads ($size equal counts)',
      size: size,
      operations: size,
      body: () => Future.wait([for (int i = 0; i < size; i++) notes.count(where: FluentFilter.gt('id', 0))]),
    );
    await _measure(
      group: 'queue.distinctReads',
      label: 'queue.distinctReads ($size different counts)',
      size: size,
      operations: size,
      body: () => Future.wait([for (int i = 0; i < size; i++) notes.count(where: FluentFilter.gt('id', i))]),
    );
    await _measure(
      group: 'queue.readsAndWrites',
      label: 'queue.readsAndWrites ($size calls, 1 in 2 saves)',
      size: size,
      operations: size,
      setup: () async {
        await notes.deleteWhere(FluentFilter.gt('id', size));
      },
      body: () => Future.wait<Object?>([
        for (int i = 0; i < size; i++) i.isEven ? notes.findById(i + 1) : notes.save(BenchNote(id: size + i, text: 'extra $i')),
      ]),
    );
    await _measure(
      group: 'queue.sequentialCalls',
      label: 'queue.sequentialCalls ($size awaited exists)',
      size: size,
      operations: size,
      body: () async {
        for (int i = 1; i <= size; i++) {
          await notes.exists(i);
        }
      },
    );
  });

  // ----------------------------------------------------------------- save

  Future<void> save() async {
    await _withDb('save_items', [BenchNoteProvider()], (providers) async {
      final FluentProvider<BenchNote> notes = providers.single as FluentProvider<BenchNote>;
      Future<void> reset() async {
        await notes.clearTable();
      }

      await _measure(
        group: 'save.single',
        label: 'save.single ($size awaited saves)',
        size: size,
        operations: size,
        setup: reset,
        body: () async {
          for (int i = 0; i < size; i++) {
            await notes.save(BenchNote(text: 'note $i'));
          }
        },
      );
      await _measure(
        group: 'save.merged',
        label: 'save.merged ($size saves called together)',
        size: size,
        operations: size,
        setup: reset,
        body: () => Future.wait([for (int i = 0; i < size; i++) notes.save(BenchNote(text: 'note $i'))]),
      );
      for (final int rows in bulkSizes) {
        await _measure(
          group: 'save.saveAll',
          label: 'save.saveAll ($rows rows)',
          size: rows,
          operations: rows,
          setup: reset,
          body: () => notes.saveAll([for (int i = 0; i < rows; i++) BenchNote(text: 'note $i')]),
        );
      }
    });

    await _withDb('save_accounts', [BenchAccountProvider()], (providers) async {
      final FluentProvider<BenchAccount> accounts = providers.single as FluentProvider<BenchAccount>;
      await _measure(
        group: 'save.conflictOn',
        label: 'save.conflictOn ($size upserts by e-mail)',
        size: size,
        operations: size,
        setup: () async {
          await accounts.clearTable();
          await accounts.saveAll([for (int i = 0; i < size; i++) BenchAccount(email: 'user$i@example.com', name: 'old')]);
        },
        body: () async {
          final FluentSaveResult r = await accounts.saveAll([for (int i = 0; i < size; i++) BenchAccount(email: 'user$i@example.com', name: 'new')], conflictOn: const ['email']);
          _check(r.updated == size, 'conflictOn upsert updated ${r.updated} of $size rows');
        },
      );
    });

    await _withDb('save_graph', [BenchPostProvider(), BenchCommentProvider(), BenchPersonProvider(), BenchTagProvider()], (providers) async {
      final FluentProvider<BenchPost> posts = providers[0] as FluentProvider<BenchPost>;
      Future<void> reset() async {
        for (final FluentProvider<FluentStorable> p in providers) {
          await p.clearTable();
        }
      }

      const int childrenPerPost = 5;
      await _measure(
        group: 'save.graphChildren',
        label: 'save.graphChildren ($size posts x $childrenPerPost comments)',
        size: size,
        operations: size,
        setup: reset,
        body: () => posts.saveAll([
          for (int i = 0; i < size; i++) BenchPost(title: 'post $i', comments: [for (int c = 0; c < childrenPerPost; c++) BenchComment(text: 'comment $c')]),
        ]),
      );
      const int tagsPerPost = 3;
      const int tagPool = 20;
      await _measure(
        group: 'save.graphManyToMany',
        label: 'save.graphManyToMany ($size posts x $tagsPerPost tags)',
        size: size,
        operations: size,
        setup: reset,
        body: () => posts.saveAll([
          for (int i = 0; i < size; i++)
            BenchPost(title: 'post $i', tags: [for (int t = 0; t < tagsPerPost; t++) BenchTag(id: (i + t) % tagPool + 1, label: 'tag ${(i + t) % tagPool + 1}')]),
        ]),
      );
    });
  }

  // ------------------------------------------------------------ relations

  Future<void> relations() async {
    // One database per relation kind: the post model declares only that relation, so the numbers are not mixed.
    await _relationLoad('one', {'author'}, (i) => BenchPost(title: 'post $i', author: BenchPerson(id: i % 10 + 1, name: 'person ${i % 10}')));
    await _relationLoad(
      'many',
      {'comments'},
      (i) => BenchPost(title: 'post $i', comments: [for (int c = 0; c < 4; c++) BenchComment(text: 'comment $c')]),
    );
    await _relationLoad(
      'manyToMany',
      {'tags'},
      (i) => BenchPost(title: 'post $i', tags: [for (int t = 0; t < 3; t++) BenchTag(id: (i + t) % 20 + 1, label: 'tag ${(i + t) % 20 + 1}')]),
    );
    await _relationLoad(
      'nested',
      {'comments'},
      (i) => BenchPost(
        title: 'post $i',
        comments: [for (int c = 0; c < 3; c++) BenchComment(text: 'comment $c', author: BenchPerson(id: (i + c) % 10 + 1, name: 'person ${(i + c) % 10}'))],
      ),
      depth: 2,
    );

    await _withDb('relations_limited', [BenchEntryProvider(), BenchNoteProvider()], (providers) async {
      final FluentProvider<BenchEntry> entries = providers[0] as FluentProvider<BenchEntry>;
      final int max = _relationSizes.last;
      await entries.saveAll([for (int i = 0; i < max; i++) BenchEntry(title: 'entry $i', notes: [for (int n = 0; n < 10; n++) BenchNote(text: 'note $n')])]);
      for (final int parents in _relationSizes) {
        await _measure(
          group: 'relations.limited',
          label: 'relations.limited ($parents parents, last ${BenchEntry.limit} of 10)',
          size: parents,
          operations: parents,
          constantStatements: true,
          body: () async {
            final List<BenchEntry> list = await entries.findAll(limit: parents);
            _check(list.length == parents && list.first.notes?.length == BenchEntry.limit, 'limited relation list returned ${list.first.notes?.length} notes');
          },
        );
      }
    });
  }

  Future<void> _relationLoad(String kind, Set<String> only, BenchPost Function(int i) build, {int depth = 1}) {
    return _withDb('relations_$kind', [BenchPostProvider(only: only), BenchCommentProvider(), BenchPersonProvider(), BenchTagProvider()], (providers) async {
      final FluentProvider<BenchPost> posts = providers[0] as FluentProvider<BenchPost>;
      final int max = _relationSizes.last;
      await posts.saveAll([for (int i = 0; i < max; i++) build(i)]);
      for (final int parents in _relationSizes) {
        await _measure(
          group: 'relations.$kind',
          label: 'relations.$kind ($parents parents${depth > 1 ? ', depth $depth' : ''})',
          size: parents,
          operations: parents,
          constantStatements: true,
          body: () async {
            final List<BenchPost> list = await posts.findAll(limit: parents, maxDepth: depth);
            _check(list.length == parents, 'relation load returned ${list.length} of $parents posts');
          },
        );
      }
    });
  }

  // -------------------------------------------------------------- deletes

  Future<void> deletes() async {
    await _withDb('deletes_posts', [BenchPostProvider(), BenchCommentProvider(), BenchPersonProvider(), BenchTagProvider()], (providers) async {
      final FluentProvider<BenchPost> posts = providers[0] as FluentProvider<BenchPost>;
      Future<void> seed() async {
        for (final FluentProvider<FluentStorable> p in providers) {
          await p.clearTable();
        }
        await posts.saveAll([for (int i = 0; i < size; i++) BenchPost(title: 'post $i', comments: [for (int c = 0; c < 3; c++) BenchComment(text: 'comment $c')])]);
      }

      await _measure(
        group: 'deletes.softCascade',
        label: 'deletes.softCascade ($size posts x 3 comments)',
        size: size,
        operations: size,
        setup: seed,
        body: () async {
          final int n = await posts.deleteWhere(FluentFilter.gte('id', 0));
          _check(n == size, 'soft delete removed $n of $size posts');
        },
      );
      await _measure(
        group: 'deletes.trashForever',
        label: 'deletes.trashForever ($size posts x 3 comments)',
        size: size,
        operations: size,
        setup: () async {
          await seed();
          await posts.deleteWhere(FluentFilter.gte('id', 0));
        },
        body: () async {
          final int n = await posts.trash.deleteForeverWhere(FluentFilter.gte('id', 0));
          _check(n == size, 'deleteForever removed $n of $size posts');
        },
      );
    });

    await _withDb('deletes_notes', [BenchNoteProvider()], (providers) async {
      final FluentProvider<BenchNote> notes = providers.single as FluentProvider<BenchNote>;
      final int rows = bulkSizes.isEmpty ? size : bulkSizes.first;
      await _measure(
        group: 'deletes.hardByFilter',
        label: 'deletes.hardByFilter ($rows rows)',
        size: rows,
        operations: rows,
        setup: () async {
          await notes.clearTable();
          await notes.saveAll([for (int i = 0; i < rows; i++) BenchNote(text: 'note $i')]);
        },
        body: () async {
          final int n = await notes.deleteWhere(FluentFilter.gte('id', 0));
          _check(n == rows, 'hard delete removed $n of $rows rows');
        },
      );
    });
  }

  // -------------------------------------------------------------- helpers

  /// Runs [body] [warmUp] + [runs] times: [setup] (not timed) before each, only [body] is timed.
  Future<void> _measure({
    required String group,
    required String label,
    required int size,
    required int operations,
    required Future<void> Function() body,
    Future<void> Function()? setup,
    bool constantStatements = false,
  }) async {
    final List<Duration> timed = [];
    int? statements;
    Map<String, int> counters = const {};
    for (int i = 0; i < warmUp + runs; i++) {
      await setup?.call();
      final FluentEngineStats before = FluentDb.engineStats();
      counter?.reset();
      final Stopwatch sw = Stopwatch()..start();
      await body();
      sw.stop();
      final FluentEngineStats after = FluentDb.engineStats();
      if (i < warmUp) continue;
      timed.add(sw.elapsed);
      // The fewest statements of all runs: a stray background write must not look like an N+1.
      final int? seen = counter?.count;
      if (seen != null) statements = statements == null || seen < statements ? seen : statements;
      counters = {
        'tasks': after.completed - before.completed,
        'collapsedReads': after.collapsedReads - before.collapsedReads,
        'mergedSaves': after.mergedSaves - before.mergedSaves,
        'batchedLookups': after.batchedLookups - before.batchedLookups,
      }..removeWhere((_, v) => v <= 0);
    }
    results.add(FluentBenchmarkResult(group: group, name: label, size: size, operations: operations, runs: timed, statements: statements, statementsConstant: constantStatements, counters: counters));
  }

  Future<void> _withDb(String name, List<FluentProvider<FluentStorable>> providers, Future<void> Function(List<FluentProvider<FluentStorable>> providers) body) async {
    final String dbName = 'bench_$name';
    final String path = '${await getDatabasesPath()}/$dbName.db';
    await databaseFactory.deleteDatabase(path);
    await FluentDb.init([FluentGroup(dbKey: FluentDbKey(dbName), providerList: providers)]);
    try {
      await body(providers);
    } finally {
      await FluentDb.close();
      await databaseFactory.deleteDatabase(path);
    }
  }

  static void _check(bool ok, String message) {
    if (!ok) throw StateError('benchmark scenario produced a wrong result: $message');
  }
}
