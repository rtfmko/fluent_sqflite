// Writes the 2.0.0-dev.N upgrade fixtures. Not a test of the checkout (no `_test` suffix): copy this file as
// `test/gen_fixture_test.dart` and `test/fixtures/upgrade_models.dart` as `test/upgrade_models.dart` into a git
// worktree of the old version, set the import below to 'upgrade_models.dart', run it and commit the resulting `.db` + `.dump.json` files.
//   git worktree add --detach <tmp>/dev1 ebab34b   # 2.0.0-dev.1
//   git worktree add --detach <tmp>/dev2 7972bf3   # 2.0.0-dev.2
//   OUT=<folder> NAME=dev1 fvm flutter test test/gen_fixture_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../upgrade_models.dart';

void main() {
  setUpFluentTests();

  test('write the fixture', () async {
    final String out = Platform.environment['OUT']!;
    final String name = Platform.environment['NAME']!;
    Directory(out).createSync(recursive: true);
    final FluentTestDb db = FluentTestDb(name: 'fx_$name', persistent: true);
    db.clock.set(DateTime.utc(2026, 3, 1, 12));
    final List<FluentProvider<FluentStorable>> p = fxProviders();
    await db.open(p);
    final FxAuthorProvider authors = p[2] as FxAuthorProvider;
    final FxBookProvider books = p[1] as FxBookProvider;
    final FxEventProvider events = p[3] as FxEventProvider;
    final FxTodoProvider todos = p[4] as FxTodoProvider;
    final FxCachedProvider cached = p[5] as FxCachedProvider;

    await authors.save(
      FxAuthor(
        id: 1,
        name: 'Ann',
        born: DateTime.utc(1980, 5, 17, 8, 30, 15, 123, 456),
        rating: 4.5,
        active: true,
        books: [FxBook(id: 10, title: 'First', pages: 100), FxBook(id: 11, title: 'Second', pages: 250)],
        tags: [FxTag(id: 20, label: 'x'), FxTag(id: 21, label: 'y')],
      ),
    );
    await authors.save(FxAuthor(id: 2, name: 'Bob', born: DateTime.utc(1990, 1, 2, 3, 4, 5), rating: -0.125, active: false, books: [FxBook(id: 12, title: 'Third', pages: 7)], tags: [FxTag(id: 20, label: 'x')]));
    db.clock.advance(const Duration(hours: 1));
    await books.deleteById(11); // trash (soft delete)
    await events.save(FxEvent(id: 1, at: DateTime.utc(2026, 2, 3, 4, 5, 6, 7, 8), note: 'utc'));
    await events.save(FxEvent(id: 2, at: DateTime.utc(2026, 2, 3, 4, 5, 6), note: 'second'));
    await todos.save(FxTodo(id: 1, text: 'pushed', done: true));
    await todos.save(FxTodo(id: 3, text: 'doomed'));
    await todos.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) async => FluentPushResult<FxTodo>.accepted());
    await todos.save(FxTodo(id: 2, text: 'pending', done: false));
    await todos.deleteById(3); // a tombstone to push
    await todos.save(FxTodo(id: 1, text: 'pushed then edited', done: true)); // a synced row with a local edit
    await cached.save(FxCached(id: 1, value: 'fresh', timeToLive: const Duration(days: 3650)));
    await cached.save(FxCached(id: 2, value: 'forever'));
    await db.settle();
    await db.close(keepFile: true);

    final String file = '${await getDatabasesPath()}/fx_$name.db';
    final Database raw = await databaseFactoryFfi.openDatabase(file);
    final Map<String, Object?> dump = {};
    for (final Map<String, Object?> r in await raw.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) {
      final String t = r['name']! as String;
      dump[t] = {'sql': r['sql'], 'rows': await raw.rawQuery('SELECT * FROM "$t"')};
    }
    File('$out/$name.dump.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(dump));
    await raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    await raw.close();
    File(file).copySync('$out/$name.db');
  });
}
