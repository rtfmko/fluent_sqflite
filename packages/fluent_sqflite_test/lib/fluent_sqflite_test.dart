// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Test helpers for fluent_sqflite: databases in memory, a clock you can move, waiting for streams, and the issues a
/// test raised.
///
/// ```dart
/// void main() {
///   setUpFluentTests();
///
///   late FluentTestDb db;
///   final TodoProvider todos = TodoProvider();
///   setUp(() async {
///     db = FluentTestDb();
///     await db.open([todos]);
///   });
///   tearDown(() => db.close());
///
///   test('deleted todos leave the trash after the retention (default 7 days)', () async {
///     final Todo todo = Todo(id: 1, title: 'Milk');
///     await todos.save(todo);
///     await todos.delete(todo);
///     db.clock.advance(const Duration(days: 8));
///     expect(await todos.trash.empty(), 1); // past the trash retention
///   });
/// }
/// ```
library;

export 'src/fluent_test_clock.dart';
export 'src/fluent_test_db.dart';
export 'src/setup.dart';
