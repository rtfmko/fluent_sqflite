// Every member of FluentStorable: keys, schema inference, defaults and the internals the library uses.
import 'dart:typed_data';
import 'dart:ui' show Color, Locale;

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

enum Mood { happy, sad }

class Plain extends FluentStorable {
  Plain({this.id, this.name = 'n', super.timeToLive});

  int? id;
  String name;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'name': name};
}

class Everything extends FluentStorable {
  @override
  Map<String, Object?> buildJson() => {
    'id': 1,
    'i': 1,
    'd': 1.5,
    'b': true,
    'dt': DateTime(2026),
    's': 'x',
    'blob': Uint8List(1),
    'dur': const Duration(seconds: 1),
    'big': BigInt.one,
    're': RegExp('a'),
    'uri': Uri.parse('http://x'),
    'color': const Color(0xFF000000),
    'locale': const Locale('en'),
    'tod': const TimeOfDay(hour: 1, minute: 2),
    'list': [1],
    'map': {'a': 1},
    'mood': Mood.happy,
    'model': Plain(),
    'models': [Plain()],
  };

  @override
  Map<String, List<Enum>> get enumValues => {'mood': Mood.values};
}

class EnumWithoutEntry extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1, 'mood': Mood.sad};
}

class WithNull extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1, 'nick': null};
}

class WithNullCovered extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1, 'nick': null};

  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.text('nick')];
}

class Weird {}

class Unknowns extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1, 'a': Weird(), 'b': null, '': Weird(), 'c': Object()};
}

class Duplicate extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1, 'email': 'a'};

  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.text('email', isUnique: true), FluentDbColumn.integer('extra')];
}

class DeclaredTwice extends FluentStorable {
  @override
  Map<String, dynamic> buildJson() => {'id': 1};

  @override
  List<FluentDbColumn> get missingColumns => [FluentDbColumn.text('tag'), FluentDbColumn.text('tag', isUnique: true)];
}

class Composite extends FluentStorable {
  Composite(this.userId, this.day);
  final int userId;
  final String day;

  @override
  List<FluentDbColumn> get primaryKeys => [FluentDbColumn.integer('user_id'), FluentDbColumn.text('day')];

  @override
  Map<String, dynamic> buildJson() => {'user_id': userId, 'day': day, 'score': 3};
}

class EmptyKeys extends FluentStorable {
  @override
  List<FluentDbColumn> get primaryKeys => const [];

  @override
  Map<String, dynamic> buildJson() => {'id': 5};
}

class Custom extends FluentStorable {
  @override
  FluentDbColumn get primaryKey => FluentDbColumn(name: 'uuid', type: FluentDbDataType.text, isPrimaryKey: true);

  @override
  Map<String, dynamic> buildJson() => {'uuid': 'u1', 'v': 1};
}

class Fmt extends FluentStorable {
  String format(Map<String, Object?> f) => formatToString(f);

  @override
  Map<String, dynamic> buildJson() => {};
}

void main() {
  setUpFluentTests();

  group('defaults', () {
    test('every default member', () {
      final Plain p = Plain();
      expect(p.expiryColumn, 'expiry_date');
      expect(p.primaryKey.name, 'id');
      expect(p.primaryKey.isPrimaryKey, isTrue);
      expect(p.primaryKeys.map((c) => c.name), ['id']);
      expect(p.indexes, isEmpty);
      expect(p.checks, isEmpty);
      expect(p.withoutRowId, isFalse);
      expect(p.enumValues, isEmpty);
      expect(p.missingColumns, isEmpty);
      expect(p.migrations, isEmpty);
      expect(p.tableConfig, isA<FluentTableConfig>());
      expect(p.timeToLive, isNull);
      expect(Plain(timeToLive: const Duration(hours: 1)).timeToLive, const Duration(hours: 1));
    });

    test('isRelationLoaded: loaded unless the library marked it unloaded', () {
      final Plain p = Plain();
      expect(p.isRelationLoaded('x'), isTrue);
      p.unloadedRelations.add('x');
      expect(p.isRelationLoaded('x'), isFalse);
      expect(p.isRelationLoaded('y'), isTrue);
    });

    test('toString: skips null and empty values', () {
      expect(Plain().toString(), 'Plain{}', reason: 'a model without a key value prints no key');
      final Plain p = Plain(id: 3, timeToLive: const Duration(seconds: 2));
      expect(p.toString(), contains('timeToLive: 0:00:02'));
      expect(p.toString(), contains('key: 3'));
            p.unloadedRelations.add('rel');
      expect(p.toString(), contains('unloadedRelations: {rel}'));
    });

    test('formatToString drops null, empty iterables and empty maps', () {
      expect(Fmt().format({'a': 1, 'b': null, 'c': <int>[], 'd': <String, int>{}, 'e': [1], 'f': {'k': 1}}), 'Fmt{a: 1, e: [1], f: {k: 1}}');
    });
  });

  group('keys', () {
    test('primaryKeyValue / key of a single key; null id stays null', () {
      expect(Plain(id: 4).primaryKeyValue, 4);
      expect(Plain().primaryKeyValue, isNull);
      expect(Plain(id: 4).key, FluentKey({'id': 4}));
      expect(Custom().primaryKeyValue, 'u1');
      expect(Custom().key, FluentKey({'uuid': 'u1'}));
    });

    test('composite key: primaryKeyValue is the FluentKey', () {
      final Composite c = Composite(7, 'mon');
      expect(c.primaryKeyValue, FluentKey({'user_id': 7, 'day': 'mon'}));
      expect(c.key, c.primaryKeyValue);
      expect(c.tableSchema.map((e) => e.name), ['user_id', 'day', 'score']);
    });

    test('empty primaryKeys fall back to id', () {
      expect(EmptyKeys().primaryKeyValue, 5);
      expect(EmptyKeys().key, FluentKey({'id': 5}));
    });

    test('injectRelationId fills a null key; the model value wins when present', () {
      final Plain p = Plain();
      p.injectRelationId('id', 9);
      expect(p.metadata['id'], 9);
      expect(p.primaryKeyValue, 9);
      expect(p.key, FluentKey({'id': 9}));
      p.id = 2;
      expect(p.primaryKeyValue, 2);
      expect(p.keyValueOf('id', null), 9);
      expect(p.keyValueOf('id', 2), 2);
    });

    test('forceKey: the replaced value maps to the forced one, until the model key changes', () {
      final Plain p = Plain(id: 1);
      p.forceKey('id', 10, replaced: 1);
      expect(p.primaryKeyValue, 10);
      expect(p.key, FluentKey({'id': 10}));
      expect(p.keyValueOf('id', '1'), 10, reason: 'same key by affinity');
      expect(p.keyValueOf('id', null), 10);
      p.id = 3;
      expect(p.primaryKeyValue, 3);
      expect(p.metadata['id'], 10);
    });

    test('fluentSameKeyValue: equal values or equal text', () {
      expect(fluentSameKeyValue(1, '1'), isTrue);
      expect(fluentSameKeyValue(1, 1), isTrue);
      expect(fluentSameKeyValue(1, 2), isFalse);
      expect(fluentSameKeyValue(null, null), isTrue);
      expect(fluentSameKeyValue(null, 'null'), isTrue);
    });
  });

  group('tableSchema inference', () {
    test('every supported type', () {
      final Map<String, FluentDbColumn> cols = {for (final FluentDbColumn c in Everything().tableSchema) c.name: c};
      expect(cols.containsKey('model'), isFalse, reason: 'stored models are relations, not columns');
      expect(cols.containsKey('models'), isFalse);
      expect(cols['id']!.isPrimaryKey, isTrue);
      expect(cols['i']!.type, FluentDbDataType.integer);
      expect(cols['d']!.type, FluentDbDataType.real);
      expect(cols['b']!.type, FluentDbDataType.integer);
      expect(cols['dt']!.type, FluentDbDataType.integer);
      expect(cols['s']!.type, FluentDbDataType.text);
      expect(cols['blob']!.type, FluentDbDataType.blob);
      expect(cols['dur']!.valueKind, FluentValueKind.duration);
      expect(cols['dur']!.type, FluentDbDataType.integer);
      expect(cols['big']!.valueKind, FluentValueKind.bigInt);
      expect(cols['re']!.type, FluentDbDataType.text);
      expect(cols['uri']!.valueKind, FluentValueKind.uri);
      expect(cols['color']!.valueKind, FluentValueKind.color);
      expect(cols['color']!.type, FluentDbDataType.integer);
      expect(cols['locale']!.valueKind, FluentValueKind.locale);
      expect(cols['tod']!.valueKind, FluentValueKind.timeOfDay);
      expect(cols['list']!.valueKind, FluentValueKind.json);
      expect(cols['map']!.valueKind, FluentValueKind.json);
      expect(cols['mood']!.valueKind, FluentValueKind.enumValue);
    });

    test('the schema is cached per type', () {
      expect(identical(Plain().tableSchema, Plain().tableSchema), isTrue);
    });

    test('an enum field without an enumValues entry raises a schemaFallback issue; with one it does not', () async {
      final FluentTestDb db = FluentTestDb();
      await db.open([]);
      Everything().tableSchema;
      await db.settle();
      // Everything is cached from the test above or computed here; either way its enum has an entry.
      expect(db.issues.where((i) => i.kind == FluentIssueKind.schemaFallback), isEmpty);
      final List<FluentDbColumn> cols = EnumWithoutEntry().tableSchema;
      await db.settle();
      expect(cols.last.valueKind, FluentValueKind.enumValue);
      final List<FluentIssue> fallback = db.issues.where((i) => i.kind == FluentIssueKind.schemaFallback).toList();
      expect(fallback, hasLength(1));
      expect(fallback.single.title, contains('mood'));
      expect(fallback.single.fix, contains('enumValues'));
      await db.close();
    });

    test('a null field outside missingColumns throws a schema report with a copy-paste fix', () {
      try {
        WithNull().tableSchema;
        fail('expected FluentSchemaException');
      } on FluentSchemaException catch (e) {
        expect(e.modelName, 'WithNull');
        expect(e.message, contains('nick'));
        expect(e.hint, contains("FluentDbColumn.text('nick')"), reason: 'null suggests text');
        expect(e.hint, contains('missingColumns'));
      }
    });

    test('a null field covered by missingColumns is fine', () {
      expect(WithNullCovered().tableSchema.map((c) => c.name), ['id', 'nick']);
    });

    test('the report lists every unknown field and names an empty key', () {
      try {
        Unknowns().tableSchema;
        fail('expected FluentSchemaException');
      } on FluentSchemaException catch (e) {
        expect(e.message, contains('4 field(s)'));
        expect(e.hint, contains('[ EMPTY KEY ]'));
        expect(e.hint, contains("FluentDbColumn.text('ENTER_NAME')"));
        expect(e.hint, contains("FluentDbColumn.text('a')"));
        expect(e.hint, contains('Weird'));
      }
    });

    test('missingColumns override an inferred column and add new ones; no warning for the override; a name declared twice in missingColumns is a schemaFallback issue', () async {
      final FluentTestDb db = FluentTestDb();
      await db.open([]);
      final List<FluentDbColumn> cols = Duplicate().tableSchema;
      expect(cols.map((c) => c.name), ['id', 'email', 'extra']);
      await db.settle();
      expect(cols.firstWhere((c) => c.name == 'email').isUnique, isTrue);
      expect(db.issues.where((i) => i.kind == FluentIssueKind.schemaFallback && i.title.contains('email')), isEmpty, reason: 'overriding a buildJson field is the documented usage');
      final List<FluentDbColumn> twice = DeclaredTwice().tableSchema;
      await db.settle();
      expect(twice.firstWhere((c) => c.name == 'tag').isUnique, isTrue, reason: 'the last declaration wins');
      expect(db.issues.where((i) => i.kind == FluentIssueKind.schemaFallback && i.title.contains('"tag"')), isNotEmpty);
      await db.close();
    });
  });
}
