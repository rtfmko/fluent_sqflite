// Reproductions of bugs found by the code audit. Each test states the expected behaviour; a failing test is a
// confirmed bug (see the bug list for the file and line).
import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/schema_models.dart';

/// A model whose `buildJson` throws when [breaks] is set (user code the library must not trust).
class _FragileModel extends DynamicModel {
  _FragileModel(
    this.provider,
    Map<String, dynamic> values, {
    this.breaks = false,
  }) : super(provider.spec, values: values);

  final _FragileProvider provider;

  /// Whether this instance's `buildJson` throws.
  final bool breaks;

  @override
  Map<String, dynamic> buildJson() {
    if (breaks) throw StateError('buildJson of a broken model');
    return super.buildJson();
  }
}

class _FragileProvider extends DynamicProvider {
  _FragileProvider()
    : super(
        'items',
        () => [FluentDbColumn.integer('id'), FluentDbColumn.text('name')],
      );
}

/// A value without its own `toString`: two instances print the same.
class _Opaque {
  const _Opaque(this.v);
  final int v;
}

void main() {
  setUpFluentTests();

  group('audit: value keys', () {
    test('two different values with the same text get different read keys', () {
      // Bug: fluentValueKey falls back to '$value', so distinct instances share a key and identical-looking reads
      // can be answered with the result of another read (lib/src/utils/fluent_filter.dart, fluentValueKey).
      expect(
        fluentValueKey(const _Opaque(1)),
        isNot(fluentValueKey(const _Opaque(2))),
      );
    });
  });

  group('audit: scheduler', () {
    test(
      'a model whose buildJson throws does not block the queue of its database',
      () async {
        // Bug: _matchKeys (lib/src/core/fluent_engine/fluent_engine.dart) calls buildJson inside the scheduler, outside
        // the error handler. The throw leaves the head task queued, so every later write of the database fails too.
        final _FragileProvider items = _FragileProvider();
        final FluentTestDb db = FluentTestDb(
          name: 'audit_wedge_${DateTime.now().microsecondsSinceEpoch}',
        );
        await db.open([items]);
        addTearDown(db.close);

        // Hold the write slot so the two saves queue up side by side.
        final Completer<void> started = Completer<void>();
        final Completer<void> release = Completer<void>();
        final Future<void> hold = FluentDb.transaction(() async {
          started.complete();
          await release.future;
        });
        await started.future;

        final Future<Object?> broken = items
            .save(_FragileModel(items, {'id': 1, 'name': 'bad'}, breaks: true))
            .then<Object?>((_) => null, onError: (Object e) => e);
        final Future<Object?> good = items
            .save(_FragileModel(items, {'id': 2, 'name': 'good'}))
            .then<Object?>((_) => null, onError: (Object e) => e);

        release.complete();
        await hold;

        // The broken save fails alone; the good one and later calls still run.
        expect(await broken.timeout(const Duration(seconds: 5)), isNotNull);
        expect(await good.timeout(const Duration(seconds: 5)), isNull);
        expect(await items.count().timeout(const Duration(seconds: 5)), 1);
      },
    );
  });
}
