@Timeout(Duration(seconds: 20))
library;

import 'dart:io';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/relation_models.dart';
import '_helpers.dart';

void main() {
  setUpFluentTests();

  late FluentTestDb db;

  tearDown(() async {
    await db.close();
  });

  group('onEvent', () {
    setUp(() async {
      db = FluentTestDb();
      await db.open([GadgetProvider(), PageProvider()]);
    });

    test('by model type: only that model, with the written items', () async {
      final gadgets = <FluentChangeEvent<Gadget>>[];
      final sub = FluentDb.onEvent<Gadget>().listen(gadgets.add);
      await FluentDb.save<Gadget>(Gadget(name: 'g'));
      await FluentDb.save<Page>(Page(title: 'p'));
      await db.settle();
      expect(gadgets, hasLength(1));
      expect(gadgets.single.kind, FluentChangeKind.save);
      expect(gadgets.single.table, 'gadgets');
      expect(gadgets.single.dbName, db.name);
      await sub.cancel();
    });

    test('FluentStorable sees every model', () async {
      final tables = <String>[];
      final sub = FluentDb.onEvent<FluentStorable>().listen((e) => tables.add(e.table));
      await FluentDb.save<Gadget>(Gadget(name: 'g'));
      await FluentDb.save<Page>(Page(title: 'p'));
      await db.settle();
      expect(tables, containsAll(['gadgets', 'pages']));
      await sub.cancel();
    });

    test('tag and kinds filter; an empty kinds set filters nothing', () async {
      final tagged = <FluentChangeKind>[];
      final deletes = <FluentChangeKind>[];
      final emptyKinds = <FluentChangeKind>[];
      final subs = [
        FluentDb.onEvent<Gadget>(tag: 'api').listen((e) => tagged.add(e.kind)),
        FluentDb.onEvent<Gadget>(kinds: {FluentChangeKind.delete}).listen((e) => deletes.add(e.kind)),
        FluentDb.onEvent<Gadget>(kinds: const {}).listen((e) => emptyKinds.add(e.kind)),
      ];
      await FluentDb.save<Gadget>(Gadget(name: 'g'), tag: 'api');
      await FluentDb.save<Gadget>(Gadget(name: 'h'), tag: 'ui');
      await FluentDb.deleteById<Gadget>(1);
      await db.settle();
      expect(tagged, [FluentChangeKind.save]);
      expect(deletes, [FluentChangeKind.delete]);
      expect(emptyKinds, hasLength(3));
      for (final s in subs) {
        await s.cancel();
      }
    });

    test('writes inside a transaction publish after the commit, none on rollback', () async {
      final kinds = <FluentChangeKind>[];
      final sub = FluentDb.onEvent<Gadget>().listen((e) => kinds.add(e.kind));
      await expectLater(
        FluentDb.transaction(() async {
          await FluentDb.save<Gadget>(Gadget(name: 'rolled back'));
          throw StateError('x');
        }),
        throwsStateError,
      );
      await db.settle();
      expect(kinds, isEmpty);
      await FluentDb.transaction(() async {
        await FluentDb.save<Gadget>(Gadget(name: 'one'));
        await FluentDb.save<Gadget>(Gadget(name: 'two'));
        expect(kinds, isEmpty, reason: 'nothing is published before the commit');
      });
      await db.settle();
      expect(kinds, isNotEmpty);
      await sub.cancel();
    });
  });

  group('relation statics', () {
    late Article article;

    setUp(() async {
      db = FluentTestDb();
      await db.open(relationProviders());
      final Person ann = Person(name: 'Ann');
      await FluentDb.save<Person>(ann);
      final Person savedAnn = (await FluentDb.findFirst<Person>(where: FluentFilter.eq('name', 'Ann'), relations: FluentLoad.none))!;
      await FluentDb.save<Article>(
        Article(title: 'A', author: savedAnn, comments: [Comment(text: 'c1', likes: 3), Comment(text: 'c2', likes: 1), Comment(text: 'c3')], tags: [Tag(label: 't1'), Tag(label: 't2')]),
      );
      article = (await FluentDb.findFirst<Article>(relations: FluentLoad.none))!;
    });

    test('loadRelations loads the named (lazy) relations', () async {
      final Article full = await FluentDb.loadRelations<Article>(article, names: ['topComments']);
      expect(full.topComments!.map((c) => c.text), ['c1', 'c2']);
      final Article all = await FluentDb.loadRelations<Article>(article);
      expect(all.comments, hasLength(3));
      expect(all.author?.name, 'Ann');
    });

    test('countRelated counts without loading', () async {
      expect(await FluentDb.countRelated<Article>(article, 'comments'), 3);
      expect(await FluentDb.countRelated<Article>(article, 'tags'), 2);
    });

    test('findRelated queries with filter, order and paging', () async {
      final List<Comment> liked = await FluentDb.findRelated<Article, Comment>(article, 'comments', where: FluentFilter.gt('likes', 0), orderBy: 'likes DESC');
      expect(liked.map((c) => c.text), ['c1', 'c2']);
      final List<Comment> paged = await FluentDb.findRelated<Article, Comment>(article, 'comments', orderBy: 'id', limit: 1, offset: 1);
      expect(paged.map((c) => c.text), ['c2']);
    });

    test('findParents finds the owners of a child', () async {
      final Comment c = (await FluentDb.findFirst<Comment>(where: FluentFilter.eq('text', 'c1')))!;
      final List<Article> parents = await FluentDb.findParents<Article>(c, via: 'comments');
      expect(parents.map((a) => a.title), ['A']);
      expect(await FluentDb.findParents<Article>(c, where: FluentFilter.eq('title', 'nope')), isEmpty);
    });

    test('attach and detach change links without rewriting the list', () async {
      final Tag extra = Tag(label: 't3');
      await FluentDb.save<Tag>(extra);
      final Tag saved = (await FluentDb.findFirst<Tag>(where: FluentFilter.eq('label', 't3'), relations: FluentLoad.none))!;
      await FluentDb.attach<Article>(article, 'tags', [saved]);
      expect(await FluentDb.countRelated<Article>(article, 'tags'), 3);
      await FluentDb.detach<Article>(article, 'tags', [saved]);
      expect(await FluentDb.countRelated<Article>(article, 'tags'), 2);
      expect(await FluentDb.count<Tag>(), 3, reason: 'detaching a many-to-many link keeps the tag');
    });

    test('countRelated of an unknown relation name counts nothing and reports it', () async {
      expect(await FluentDb.countRelated<Article>(article, 'nope'), 0);
      expect(db.issues.where((i) => i.type == FluentIssueType.warning || i.type == FluentIssueType.error), isNotEmpty);
    });

    test('unknown model types fail through the future', () async {
      await expectLater(FluentDb.loadRelations<Article>(article, dbKey: FluentDbKey('elsewhere')), throwsA(isA<FluentConfigException>()));
      await expectLater(FluentDb.detach<Article>(article, 'tags', const [], dbKey: FluentDbKey('elsewhere')), throwsA(isA<FluentConfigException>()));
    });
  });

  group('restart', () {
    tearDown(() async {
      await FluentDb.close();
      FluentDbInternals.reset();
    });

    test('an update callback that throws leaves the databases open as they were', () async {
      db = FluentTestDb();
      await db.open([GadgetProvider()]);
      await FluentDb.save<Gadget>(Gadget(name: 'kept'));
      await expectLater(
        FluentDb.restart(update: (groups) => throw StateError('callback')),
        throwsA(isA<FluentConfigException>().having((e) => e.message, 'message', contains('callback')).having((e) => e.cause, 'cause', isA<StateError>())),
      );
      expect(FluentDb.isOpen(), isTrue);
      expect(await FluentDb.count<Gadget>(), 1);
    });
  });

  group('group directory', () {
    test('a missing directory of a group is created', () async {
      db = FluentTestDb(name: 'dir_unused');
      await FluentTestDb.closeCurrent();
      FluentDbInternals.reset();
      final Directory root = await Directory.systemTemp.createTemp('fluent_dir_');
      final String dir = '${root.path}${Platform.pathSeparator}a${Platform.pathSeparator}b';
      addTearDown(() async {
        await FluentDb.close();
        FluentDbInternals.reset();
        try {
          await root.delete(recursive: true);
        } on FileSystemException {
          // best effort
        }
      });
      await FluentDb.init([FluentGroup(dbKey: FluentDbKey('dir_group'), providerList: [GadgetProvider()], directory: dir)]);
      await FluentDb.save<Gadget>(Gadget(name: 'x'));
      expect(File('$dir${Platform.pathSeparator}dir_group.db').existsSync(), isTrue);
      expect(databaseFactory, isNotNull);
    });
  });
}
