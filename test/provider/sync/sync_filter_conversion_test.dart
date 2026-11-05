// Filter values in sync paths (pending count / batch, cache clear and replace) are stored like their column on save.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

enum Level { low, high }

class Task extends FluentStorable {
  Task({this.id, required this.title, this.level = Level.low});

  final int? id;
  final String title;
  final Level level;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(storeEnumsAsNames: false);

  @override
  Map<String, List<Enum>> get enumValues => {'level': Level.values};

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title, 'level': level};
}

class TaskProvider extends FluentProvider<Task> with FluentSyncable<Task> {
  @override
  String get tableName => 'tasks';

  @override
  Task get modelSample => Task(title: '');

  @override
  Task fromCacheJson(Map<String, dynamic> json) => Task(id: json['id'] as int?, title: json['title'] as String, level: json['level'] as Level);
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late TaskProvider tasks;

  setUp(() async {
    tasks = TaskProvider();
    db = FluentTestDb(name: 'sync_filter_conversion');
    await db.open([tasks]);
    await tasks.saveAll([Task(id: 1, title: 'a'), Task(id: 2, title: 'b', level: Level.high)]);
  });

  tearDown(() => db.close());

  test('pendingChanges(where:) converts an enum stored by index', () async {
    expect(await tasks.pendingChanges(where: FluentFilter.eq('level', Level.high)), 1);
    expect(await tasks.pendingSyncBatch(where: FluentFilter.eq('level', Level.high)).then((FluentSyncBatch<Task> b) => b.changed.map((t) => t.id)), [2]);
  });

  test('concurrent syncs with different ids filters are not shared (the key holds the values)', () async {
    final List<List<int?>> pushed = [];
    Future<FluentSyncResult<Task>> push(int id) => tasks.syncWithServer(
      strategy: FluentSyncStrategy.push,
      where: FluentFilter.ids([id]),
      onPush: (FluentSyncBatch<Task> batch) async {
        pushed.add([for (final Task t in batch.changed) t.id]);
        return const FluentPushResult<Task>.accepted();
      },
    );
    await Future.wait([push(1), push(2)]);
    expect(pushed, unorderedEquals([[1], [2]]));
    expect(await tasks.pendingChanges(), 0);
  });

  test('clearLocally and replaceLocally convert their filter', () async {
    await tasks.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => const FluentPushResult<Task>.accepted());
    expect(await tasks.clearLocally(FluentFilter.eq('level', Level.high)), 1);
    expect((await tasks.findAll()).map((t) => t.id), [1]);
    await tasks.replaceLocally(FluentFilter.eq('level', Level.low), [Task(id: 3, title: 'c')]);
    expect((await tasks.findAll()).map((t) => t.id), [3]);
  });
}
