// Regression tests of the CRUD items of audit 2 (KNOWN_BUGS 18-24): cursors over ISO DateTime columns, deletes through
// a base type, model changes only after the commit, one soft-delete stamp format, the watch expiry on the library
// clock, field updates and expired rows, active-record calls by the runtime type.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class Memo extends FluentStorable with FluentSoftDeletable {
  Memo({this.id, required this.text, super.timeToLive});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class MemoProvider extends FluentProvider<Memo> {
  @override
  String get tableName => 'memos';

  @override
  Memo get modelSample => Memo(text: '');

  @override
  Memo fromCacheJson(Map<String, dynamic> json) => Memo(id: json['id'] as int?, text: json['text'] as String);
}

/// Soft delete in a table that stores DateTime values as ISO text.
class IsoMemo extends FluentStorable with FluentSoftDeletable {
  IsoMemo({this.id, required this.text});

  final int? id;
  final String text;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class IsoMemoProvider extends FluentProvider<IsoMemo> {
  @override
  String get tableName => 'iso_memos';

  @override
  IsoMemo get modelSample => IsoMemo(text: '');

  @override
  IsoMemo fromCacheJson(Map<String, dynamic> json) => IsoMemo(id: json['id'] as int?, text: json['text'] as String);
}

class Event extends FluentStorable {
  Event({this.id, required this.at});

  final int? id;
  final DateTime at;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'at': at};
}

class EventProvider extends FluentProvider<Event> {
  @override
  String get tableName => 'events';

  @override
  Event get modelSample => Event(at: DateTime(2000));

  @override
  Event fromCacheJson(Map<String, dynamic> json) => Event(id: json['id'] as int?, at: json['at'] as DateTime);
}

/// Owner in an ISO table, its owned children in a millisecond table.
class Folder extends FluentStorable with FluentSoftDeletable, FluentRelations {
  Folder({this.id, required this.name, this.docs});

  final int? id;
  final String name;
  final List<Doc>? docs;

  @override
  FluentTableConfig get tableConfig => const FluentTableConfig(dateTimeFormat: FluentDateTimeFormat.iso8601);

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};

  @override
  List<FluentRelation> get relations => [FluentRelation.many<Folder, Doc>('docs', (f) => f.docs, orderBy: 'id')];
}

class Doc extends FluentStorable with FluentSoftDeletable {
  Doc({this.id, required this.title});

  final int? id;
  final String title;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'title': title};
}

class FolderProvider extends FluentProvider<Folder> {
  @override
  String get tableName => 'folders';

  @override
  Folder get modelSample => Folder(name: '');

  @override
  Folder fromCacheJson(Map<String, dynamic> json) => Folder(id: json['id'] as int?, name: json['name'] as String, docs: (json['docs'] as List?)?.cast<Doc>());
}

class DocProvider extends FluentProvider<Doc> {
  @override
  String get tableName => 'docs';

  @override
  Doc get modelSample => Doc(title: '');

  @override
  Doc fromCacheJson(Map<String, dynamic> json) => Doc(id: json['id'] as int?, title: json['title'] as String);
}

/// A base model and a subtype stored in its own table.
class Shape extends FluentStorable with FluentSoftDeletable {
  Shape({this.id, required this.name});

  final int? id;
  final String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Circle extends Shape {
  Circle({super.id, required super.name});
}

class ShapeProvider extends FluentProvider<Shape> {
  @override
  String get tableName => 'shapes';

  @override
  Shape get modelSample => Shape(name: '');

  @override
  Shape fromCacheJson(Map<String, dynamic> json) => Shape(id: json['id'] as int?, name: json['name'] as String);
}

class CircleProvider extends FluentProvider<Circle> {
  @override
  String get tableName => 'circles';

  @override
  Circle get modelSample => Circle(name: '');

  @override
  Circle fromCacheJson(Map<String, dynamic> json) => Circle(id: json['id'] as int?, name: json['name'] as String);
}

/// Pages through [read] until the last page; at most [maxPages].
Future<List<int?>> _allPages<T extends FluentStorable>(Future<FluentPage<T>> Function(FluentCursor? after) read, int? Function(T m) id, {int maxPages = 10}) async {
  final List<int?> seen = [];
  FluentCursor? after;
  int pages = 0;
  do {
    final FluentPage<T> page = await read(after);
    seen.addAll(page.items.map(id));
    after = page.next;
    pages++;
  } while (after != null && pages < maxPages);
  return seen;
}

void main() {
  setUpFluentTests();

  late FluentTestDb db;
  late MemoProvider memos;
  late IsoMemoProvider isoMemos;
  late EventProvider events;
  late FolderProvider folders;
  late DocProvider docs;

  List<FluentProvider> all() => [memos, isoMemos, events, folders, docs];

  setUp(() async {
    db = FluentTestDb(name: 'crud_audit2_${DateTime.now().microsecondsSinceEpoch}');
    memos = MemoProvider();
    isoMemos = IsoMemoProvider();
    events = EventProvider();
    folders = FolderProvider();
    docs = DocProvider();
    await db.open(all());
  });

  tearDown(() => db.close());

  group('18: findPage cursors over DateTime columns of iso8601 tables', () {
    test('pages through a DateTime column stored as ISO text', () async {
      for (int i = 1; i <= 3; i++) {
        await events.save(Event(id: i, at: DateTime(2026, 1, i)));
      }
      final List<Map<String, dynamic>> raw = await events.rawQuery('SELECT typeof("at") AS t FROM "events"');
      expect(raw.first['t'], 'text');
      expect(await _allPages<Event>((after) => events.findPage(orderBy: 'at', limit: 1, after: after), (e) => e.id), [1, 2, 3]);
      expect(await _allPages<Event>((after) => events.findPage(orderBy: 'at', descending: true, limit: 2, after: after), (e) => e.id), [3, 2, 1]);
    });

    test('a cursor survives encode / decode', () async {
      for (int i = 1; i <= 3; i++) {
        await events.save(Event(id: i, at: DateTime(2026, 1, i)));
      }
      final FluentPage<Event> first = await events.findPage(orderBy: 'at', limit: 1);
      final FluentCursor decoded = FluentCursor.decode(first.next!.encode());
      final FluentPage<Event> second = await events.findPage(orderBy: 'at', limit: 1, after: decoded);
      expect(second.items.single.id, 2);
    });

    test('text that is no date still fails before SQL, on DateTime and on number columns', () async {
      await events.save(Event(id: 1, at: DateTime(2026)));
      await expectLater(
        events.findPage(orderBy: 'at', limit: 1, after: const FluentCursor(orderBy: 'at', descending: false, value: 'yesterday', key: {'id': 1})),
        throwsA(isA<FluentArgumentException>()),
      );
      await expectLater(
        events.findPage(limit: 1, after: const FluentCursor(orderBy: 'id', descending: false, value: 'abc', key: {'id': 'abc'})),
        throwsA(isA<FluentArgumentException>()),
      );
    });

    test('a DateTime column of a timestamp table also takes an ISO cursor (stored ISO text from an older format)', () async {
      await memos.save(Memo(id: 1, text: 'a'));
      await memos.delete(Memo(id: 1, text: 'a'));
      final String iso = DateTime(2000).toIso8601String();
      final FluentPage<Memo> page = await memos.withTrash.findPage(orderBy: 'deleted_at', limit: 5, after: FluentCursor(orderBy: 'deleted_at', descending: false, value: iso, key: const {'id': 0}));
      expect(page.items, isA<List<Memo>>()); // accepted: no FluentArgumentException
    });
  });

  group('19: deletes through a base type set deletedAt', () {
    test('FluentDb.deleteAll and Iterable.deleteAll stamp the models like provider.deleteAll', () async {
      final Memo a = Memo(id: 1, text: 'a');
      final Memo b = Memo(id: 2, text: 'b');
      final Memo c = Memo(id: 3, text: 'c');
      await memos.saveAll([a, b, c]);
      await memos.deleteAll([a]);
      await FluentDb.deleteAll<Memo>([b]);
      await <Memo>[c].deleteAll();
      expect(a.isDeleted, isTrue, reason: 'provider.deleteAll');
      expect(b.isDeleted, isTrue, reason: 'FluentDb.deleteAll');
      expect(c.isDeleted, isTrue, reason: 'Iterable.deleteAll');
    });

    test('a mixed collection typed as FluentStorable stamps every soft-deletable model with its stored stamp', () async {
      final Memo a = Memo(id: 1, text: 'a');
      final IsoMemo b = IsoMemo(id: 1, text: 'b');
      final Event e = Event(id: 1, at: DateTime(2026));
      await FluentDb.saveAll<FluentStorable>([a, b, e]);
      expect(await FluentDb.deleteAll<FluentStorable>([a, b, e]), 3);
      expect(a.isDeleted, isTrue);
      expect(b.isDeleted, isTrue);
      expect((await memos.trash.find()).single.deletedAt, a.deletedAt);
      expect((await isoMemos.trash.find()).single.deletedAt, b.deletedAt);
      expect(await events.exists(1), isFalse);
    });
  });

  group('20: delete / restore change the models only after the commit', () {
    test('delete inside a rolled-back transaction leaves the model live', () async {
      final Memo a = Memo(id: 1, text: 'a');
      await memos.save(a);
      await expectLater(
        FluentDb.transaction(() async {
          await memos.delete(a);
          throw StateError('rollback');
        }).timeout(const Duration(seconds: 10)),
        throwsA(isA<StateError>()),
      );
      expect(await memos.exists(1), isTrue);
      expect(a.deletedAt, isNull);
    });

    test('restore inside a rolled-back transaction leaves the model deleted', () async {
      final Memo a = Memo(id: 1, text: 'a');
      await memos.save(a);
      await memos.delete(a);
      final DateTime? stamp = a.deletedAt;
      expect(stamp, isNotNull);
      await expectLater(
        FluentDb.transaction(() async {
          await memos.trash.restore(a);
          throw StateError('rollback');
        }).timeout(const Duration(seconds: 10)),
        throwsA(isA<StateError>()),
      );
      expect(await memos.exists(1), isFalse);
      expect(a.deletedAt, stamp);
    });

    test('a nested transaction that fails drops its model changes, the committed outer one keeps its own', () async {
      final Memo a = Memo(id: 1, text: 'a');
      final Memo b = Memo(id: 2, text: 'b');
      await memos.saveAll([a, b]);
      await FluentDb.transaction(() async {
        await memos.delete(a);
        try {
          await FluentDb.transaction(() async {
            await memos.delete(b);
            throw StateError('inner');
          });
        } on StateError {
          // the savepoint is rolled back; the outer transaction goes on
        }
      }).timeout(const Duration(seconds: 10));
      expect(a.isDeleted, isTrue);
      expect(b.isDeleted, isFalse);
      expect(await memos.exists(2), isTrue);
    });

    test('committed restore clears deletedAt; a row that stays in the trash keeps it', () async {
      final Folder f = Folder(id: 1, name: 'f', docs: [Doc(id: 1, title: 'd')]);
      await folders.save(f);
      await folders.delete(f);
      final Doc d = (await docs.trash.find()).single;
      expect(d.isDeleted, isTrue);
      expect(await docs.trash.restore(d), 0); // its owner is still in the trash
      expect(d.isDeleted, isTrue);
      expect(await folders.trash.restore(f), 1);
      expect(f.isDeleted, isFalse);
    });
  });

  group('21: one soft-delete stamp format (epoch milliseconds)', () {
    test('iso8601 tables store the stamp as milliseconds; DateTime filters on it match', () async {
      final IsoMemo a = IsoMemo(id: 1, text: 'a');
      await isoMemos.save(a);
      await isoMemos.delete(a);
      final List<Map<String, dynamic>> raw = await isoMemos.rawQuery('SELECT typeof("deleted_at") AS t, "deleted_at" AS v FROM "iso_memos"');
      expect(raw.single['t'], 'integer');
      expect(raw.single['v'], a.deletedAt!.millisecondsSinceEpoch);
      expect(await isoMemos.trash.count(where: FluentFilter.gt('deleted_at', FluentClock.now().subtract(const Duration(hours: 1)))), 1);
      expect(await isoMemos.trash.count(where: FluentFilter.lt('deleted_at', FluentClock.now().add(const Duration(hours: 1)))), 1);
      expect(await isoMemos.trash.count(where: FluentFilter.eq('deleted_at', a.deletedAt!)), 1);
      expect(await isoMemos.trash.count(where: FluentFilter.gt('deleted_at', FluentClock.now().add(const Duration(hours: 1)))), 0);
    });

    test('withTrash.findPage ordered by deleted_at ends in iso8601 tables', () async {
      for (int i = 1; i <= 3; i++) {
        final IsoMemo m = IsoMemo(id: i, text: '$i');
        await isoMemos.save(m);
        await isoMemos.delete(m);
      }
      expect(await _allPages<IsoMemo>((after) => isoMemos.withTrash.findPage(orderBy: 'deleted_at', limit: 1, after: after), (m) => m.id), [1, 2, 3]);
    });

    test('the cascade from an ISO owner into a millisecond child keeps one stamp; restore and purge follow it', () async {
      final Folder f = Folder(id: 1, name: 'f', docs: [Doc(id: 1, title: 'a'), Doc(id: 2, title: 'b')]);
      await folders.save(f);
      await folders.delete(f);
      final List<Map<String, dynamic>> owner = await folders.rawQuery('SELECT "deleted_at" AS v FROM "folders"');
      final List<Map<String, dynamic>> children = await docs.rawQuery('SELECT typeof("deleted_at") AS t, "deleted_at" AS v FROM "docs"');
      expect(children.map((r) => r['t']).toSet(), {'integer'});
      expect(children.map((r) => r['v']).toSet(), {owner.single['v']});
      expect(await docs.trash.count(where: FluentFilter.eq('deleted_at', f.deletedAt!)), 2);
      expect(await folders.trash.restore(f), 1);
      expect(await docs.count(), 2);
      await folders.delete(f);
      db.clock.advance(const Duration(days: 2));
      expect(await folders.trash.empty(olderThan: const Duration(days: 1)), 1);
      expect(await docs.withTrash.count(), 0);
    });

    test('ISO text stamps of an older database are converted once at the start (autoFix), restore by stamp still works', () async {
      await db.close();
      db = FluentTestDb(name: 'crud_audit2_conv_${DateTime.now().microsecondsSinceEpoch}', persistent: true);
      await db.open([IsoMemoProvider(), FolderProvider(), DocProvider()]);
      final FolderProvider f = FluentDb.provider<FolderProvider>();
      final IsoMemoProvider m = FluentDb.provider<IsoMemoProvider>();
      await f.save(Folder(id: 1, name: 'f', docs: [Doc(id: 1, title: 'a')]));
      await f.delete(Folder(id: 1, name: 'f'));
      for (int i = 1; i <= 2; i++) {
        await m.save(IsoMemo(id: i, text: '$i'));
      }
      await m.deleteById(1);
      await m.deleteById(2);
      // What an older version wrote: ISO text stamps (also copied into the child by the cascade) and one that is no date.
      final DateTime at = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch - 3600000); // inside the trash retention
      final String iso = at.toIso8601String();
      await f.execute('UPDATE "folders" SET "deleted_at" = ?', arguments: [iso]);
      await f.execute('UPDATE "docs" SET "deleted_at" = ?', arguments: [iso]);
      await m.execute('UPDATE "iso_memos" SET "deleted_at" = ? WHERE "id" = 1', arguments: [iso]);
      await m.execute('UPDATE "iso_memos" SET "deleted_at" = ? WHERE "id" = 2', arguments: ['garbage']);
      // The snapshot of an older version: its fingerprint differs, so the start runs the full sync once.
      await m.execute(r'''UPDATE "__fluent_schema" SET "snapshot" = json_set("snapshot", '$.fingerprint', 'old')''');

      await db.restart([IsoMemoProvider(), FolderProvider(), DocProvider()]);
      final FolderProvider f2 = FluentDb.provider<FolderProvider>();
      final IsoMemoProvider m2 = FluentDb.provider<IsoMemoProvider>();
      final DocProvider d2 = FluentDb.provider<DocProvider>();
      Future<List<Map<String, dynamic>>> stamps(FluentProvider p) => p.rawQuery('SELECT "id", typeof("deleted_at") AS t, "deleted_at" AS v FROM "${p.tableName}" ORDER BY "id"');
      expect((await stamps(f2)).single, {'id': 1, 't': 'integer', 'v': at.millisecondsSinceEpoch});
      expect((await stamps(d2)).single, {'id': 1, 't': 'integer', 'v': at.millisecondsSinceEpoch});
      final List<Map<String, dynamic>> memoRows = await stamps(m2);
      expect(memoRows.first, {'id': 1, 't': 'integer', 'v': at.millisecondsSinceEpoch});
      expect(memoRows.last['v'], 'garbage', reason: 'text that is no date is left as it is');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.storedFormatAdopted && i.table == 'iso_memos'), hasLength(1));
      expect(db.issues.where((i) => i.kind == FluentIssueKind.storedFormatAdopted && i.table == 'docs'), hasLength(1));
      expect((await m2.trash.find(where: FluentFilter.eq('id', 1))).single.deletedAt, at);
      expect(await m2.trash.count(where: FluentFilter.eq('deleted_at', at)), 1);
      // The owner's converted stamp still finds the child deleted together with it.
      expect(await f2.trash.restoreById(1), 1);
      expect(await d2.count(), 1);

      // Nothing left to convert: a second start reports nothing.
      await db.restart([IsoMemoProvider(), FolderProvider(), DocProvider()]);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.storedFormatAdopted), hasLength(3)); // folders, docs, iso_memos: once
    });
  });

  group('22: watch expiry follows the library clock', () {
    test('a row whose timeToLive passes on the library clock leaves the watch', () async {
      db.clock.set(DateTime(2026, 1, 1, 12));
      await memos.save(Memo(id: 1, text: 'a', timeToLive: const Duration(minutes: 1)));
      final List<List<Memo>> emitted = [];
      final StreamSubscription<List<Memo>> sub = memos.watch().listen(emitted.add);
      await db.settle();
      expect(emitted.last, hasLength(1));
      db.clock.advance(const Duration(minutes: 2));
      await db.settle();
      await sub.cancel();
      expect(emitted.last, isEmpty);
    });

    test('a clock moved short of the expiry keeps the row; a cancelled watch arms nothing', () async {
      db.clock.set(DateTime(2026, 1, 1, 12));
      await memos.save(Memo(id: 1, text: 'a', timeToLive: const Duration(minutes: 10)));
      await memos.save(Memo(id: 2, text: 'b', timeToLive: const Duration(minutes: 1)));
      final List<List<Memo>> emitted = [];
      final StreamSubscription<List<Memo>> sub = memos.watch(orderBy: 'id').listen(emitted.add);
      await db.settle();
      db.clock.advance(const Duration(seconds: 30));
      await db.settle();
      expect(emitted.last.map((m) => m.id), [1, 2]);
      db.clock.advance(const Duration(minutes: 1));
      await db.settle();
      expect(emitted.last.map((m) => m.id), [1]);
      await sub.cancel();
      final int count = emitted.length;
      db.clock.advance(const Duration(minutes: 20));
      await db.settle();
      expect(emitted, hasLength(count));
    });

    test('FluentClockAlarm runs once when the clock passes its due time, never after cancel', () async {
      db.clock.set(DateTime(2026, 1, 2));
      int runs = 0;
      final FluentClockAlarm alarm = FluentClockAlarm(FluentClock.millis + 60000, () => runs++);
      db.clock.advance(const Duration(seconds: 59));
      expect(runs, 0);
      db.clock.advance(const Duration(seconds: 2));
      expect(runs, 1);
      expect(alarm.isDone, isTrue);
      db.clock.advance(const Duration(hours: 1));
      expect(runs, 1);
      final FluentClockAlarm cancelled = FluentClockAlarm(FluentClock.millis + 1000, () => runs++)..cancel();
      db.clock.advance(const Duration(hours: 1));
      expect(runs, 1);
      expect(cancelled.isDone, isTrue);
    });
  });

  group('23: field updates and expired rows', () {
    setUp(() async {
      db.clock.set(DateTime(2026, 1, 1, 12));
      await memos.save(Memo(id: 1, text: 'a', timeToLive: const Duration(minutes: 1)));
      db.clock.advance(const Duration(minutes: 2));
    });

    test('updateById / update / updateWhere do not reach a row findById hides', () async {
      expect(await memos.findById(1), isNull);
      expect(await memos.updateById(1, {'text': 'b'}), 0);
      expect(await memos.update(Memo(id: 1, text: 'c')), 0);
      expect(await memos.updateWhere(FluentFilter.eq('id', 1), {'text': 'd'}), 0);
      expect(await memos.save(Memo(id: 1, text: 'e'), strategy: FluentSaveStrategy.patch).then((r) => r.outcomes.single), FluentRowOutcome.skipped);
      expect((await memos.findById(1, includeExpired: true))!.text, 'a');
    });

    test('includeExpired reaches it (the expiry stays); FluentDb mirrors it', () async {
      expect(await memos.updateById(1, {'text': 'b'}, includeExpired: true), 1);
      expect(await FluentDb.updateWhere<Memo>(FluentFilter.eq('id', 1), {'text': 'c'}, includeExpired: true), 1);
      expect((await memos.findById(1, includeExpired: true))!.text, 'c');
      expect(await memos.findById(1), isNull);
    });

    test('save (upsert) renews the row; insertOnly writes over it as a new row', () async {
      final FluentSaveResult upsert = await memos.save(Memo(id: 1, text: 'renewed'));
      expect(upsert.outcomes.single, FluentRowOutcome.updated);
      expect((await memos.findById(1))!.text, 'renewed');

      await memos.save(Memo(id: 2, text: 'old', timeToLive: const Duration(minutes: 1)));
      db.clock.advance(const Duration(minutes: 2));
      final FluentSaveResult insert = await memos.save(Memo(id: 2, text: 'new'), strategy: FluentSaveStrategy.insertOnly);
      expect(insert.outcomes.single, FluentRowOutcome.inserted);
      expect((await memos.findById(2))!.text, 'new');
      // A live row is still skipped by insertOnly.
      final FluentSaveResult again = await memos.save(Memo(id: 2, text: 'other'), strategy: FluentSaveStrategy.insertOnly);
      expect(again.outcomes.single, FluentRowOutcome.skipped);
      expect((await memos.findById(2))!.text, 'new');
    });
  });

  group('24: active-record calls resolve the provider by the runtime type', () {
    late ShapeProvider shapes;
    late CircleProvider circles;

    setUp(() async {
      shapes = ShapeProvider();
      circles = CircleProvider();
      await db.open([shapes, circles]);
    });

    test('refresh / exists of a Circle held as a Shape read the circles table, like save', () async {
      final Shape s = Circle(id: 1, name: 'c');
      await s.save();
      expect(await circles.exists(1), isTrue);
      expect(await shapes.exists(1), isFalse);
      expect(await s.exists(), isTrue);
      final Shape? fresh = await s.refresh();
      expect(fresh, isA<Circle>());
    });

    test('delete / restore / deleteForever of a Circle held as a Shape stay in the circles table', () async {
      final Shape s = Circle(id: 1, name: 'c');
      await shapes.save(Shape(id: 1, name: 'plain'));
      await s.save();
      expect(await s.delete(), 1);
      expect(s.isDeleted, isTrue);
      expect(await shapes.exists(1), isTrue);
      expect(await s.restore(), 1);
      expect(s.isDeleted, isFalse);
      expect(await circles.exists(1), isTrue);
      expect(await s.deleteForever(), 1);
      expect(await circles.withTrash.count(), 0);
      expect(await shapes.exists(1), isTrue);
    });
  });
}
