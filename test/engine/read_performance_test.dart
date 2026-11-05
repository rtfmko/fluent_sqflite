// Reads that keep the UI smooth: the read connection pool, big lists sliced across frames, mapping in an isolate.
import 'dart:isolate';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records where it was built, to see which isolate mapped it.
class Reading extends FluentStorable {
  Reading({this.id, required this.at, required this.ok, this.builtIn = ''});

  final int? id;
  final DateTime at;
  final bool ok;
  final String builtIn;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'at': at, 'ok': ok};

  /// The isolate factory: static, no provider access.
  static Reading fromJson(Map<String, dynamic> json) =>
      Reading(id: json['id'] as int?, at: json['at'] as DateTime, ok: json['ok'] as bool, builtIn: Isolate.current.debugName ?? 'main');
}

class ReadingProvider extends FluentProvider<Reading> {
  ReadingProvider({this.withFactory = true, this.slow = Duration.zero});

  final bool withFactory;

  /// Extra work per row, to make mapping measurably heavy.
  final Duration slow;

  @override
  String get tableName => 'readings';

  @override
  Reading get modelSample => Reading(at: DateTime(2000), ok: false);

  @override
  Reading fromCacheJson(Map<String, dynamic> json) {
    if (slow > Duration.zero) {
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < slow) {}
    }
    return Reading.fromJson(json);
  }

  @override
  Reading Function(Map<String, dynamic> json)? get isolateFactory => withFactory ? Reading.fromJson : null;
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  setUp(() => db = FluentTestDb(name: 'perf_${DateTime.now().microsecondsSinceEpoch}', persistent: true));
  tearDown(() => db.close());

  Future<void> seed(ReadingProvider p, int count) =>
      p.saveAll([for (int i = 1; i <= count; i++) Reading(id: i, at: DateTime.utc(2026).add(Duration(minutes: i)), ok: i.isEven)]);

  group('Read pool', () {
    test('a file database in WAL gets read connections; reads see every write called before them', () async {
      final ReadingProvider p = ReadingProvider();
      await db.open([p]);
      expect(FluentEngine().readConnectionCount(db.name), 2);

      final Future<FluentSaveResult> write = p.save(Reading(id: 1, at: DateTime.utc(2026), ok: true));
      final Future<Reading?> read = p.findById(1);
      await write;
      expect((await read)?.ok, isTrue, reason: 'a read called after a write sees it, even on a read connection');

      await seed(p, 50);
      final List<int> counts = await Future.wait([for (int i = 0; i < 10; i++) p.count()]);
      expect(counts.toSet(), {50});
    });

    test('no read connections for in-memory databases or readConnections: 0', () async {
      final FluentTestDb memory = FluentTestDb();
      await memory.open([ReadingProvider()]);
      expect(FluentEngine().readConnectionCount(memory.name), 0);
      await memory.close();
      await db.open([ReadingProvider()], config: const FluentDbConfig(readConnections: 0));
      expect(FluentEngine().readConnectionCount(db.name), 0);
    });
  });

  group('Mapping big lists', () {
    test('always: lists are built in a background isolate with the same values', () async {
      final ReadingProvider p = ReadingProvider();
      await db.open([p], fluentConfig: const FluentConfig(isolateMapping: FluentIsolateMapping.always));
      await seed(p, 120);
      final List<Reading> all = await p.findAll(orderBy: 'id');
      expect(all, hasLength(120));
      expect(all.first.builtIn, startsWith('fluent_sqflite:readings'));
      expect(all.first.at, DateTime.utc(2026, 1, 1, 0, 1), reason: 'types are restored in the isolate too');
      expect(all[1].ok, isTrue);
    });

    test('never: on the UI isolate; slicing keeps the result complete and ordered', () async {
      final ReadingProvider p = ReadingProvider();
      await db.open([p], fluentConfig: const FluentConfig(isolateMapping: FluentIsolateMapping.never, sliceAfterRows: 10, frameBudget: Duration.zero));
      await seed(p, 200);
      final List<Reading> all = await p.findAll(orderBy: 'id');
      expect([for (final Reading r in all) r.id], [for (int i = 1; i <= 200; i++) i]);
      expect(all.first.builtIn, isNot(startsWith('fluent_sqflite:')));
    });

    test('smart: heavy lists move to an isolate after one measurement; without a factory a hint suggests one', () async {
      final ReadingProvider heavy = ReadingProvider(slow: const Duration(microseconds: 100));
      await db.open([heavy]);
      await seed(heavy, 150);
      expect((await heavy.findAll()).first.builtIn, isNot(startsWith('fluent_sqflite:')), reason: 'first read is measured on the UI isolate');
      expect((await heavy.findAll()).first.builtIn, startsWith('fluent_sqflite:'), reason: '~15 ms per list: mapped in the background');

      final List<FluentIssue> hints = [];
      final sub = FluentDb.onIssue(types: {FluentIssueType.hint}).listen(hints.add);
      final ReadingProvider noFactory = ReadingProvider(withFactory: false, slow: const Duration(microseconds: 100));
      await db.open([noFactory]);
      await seed(noFactory, 150);
      await noFactory.findAll();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(hints.where((h) => h.key.startsWith('isolate:')), hasLength(1));
      expect(hints.firstWhere((h) => h.key.startsWith('isolate:')).code, contains('get isolateFactory => Reading.fromJson'));
    });
  });
}
