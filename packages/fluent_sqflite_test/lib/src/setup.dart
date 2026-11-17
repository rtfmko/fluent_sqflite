// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// The log is reset through the library's own reset (an internal; this package always ships with the same version).
// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:fluent_sqflite/src/internal.dart' show FluentLog;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fluent_test_db.dart';

/// Prepares fluent_sqflite for the tests of one file; call it once at the top of `main()`.
///
/// * sqflite runs through FFI (SQLite of the desktop; no device or emulator needed);
/// * the file gets its own temporary databases directory, removed after its last test;
/// * library logs are off unless [logging] (default: when the `FLUENT_LOG` environment variable is set) — the issues
///   are still collected in `FluentTestDb.issues`;
/// * the logging setup (sink, level, mute, `showSqlArguments`) is reset after every test, so a test that calls
///   `FluentDb.setupLogging` does not leak into the next one (configure it in `setUp` or in the test, not in `setUpAll`);
/// * a `FluentTestDb` left open is closed after the last test.
void setUpFluentTests({bool? logging}) {
  late Directory dir;
  final bool logsOn = logging ?? Platform.environment.containsKey('FLUENT_LOG');

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactoryOrNull = databaseFactoryFfi; // the setter without the "changing the default factory" warning
    dir = await Directory.systemTemp.createTemp('fluent_sqflite_test_');
    await databaseFactory.setDatabasesPath(dir.path);
    FluentDb.setupLogging(enabled: logsOn);
  });

  tearDown(() {
    // ignore: invalid_use_of_visible_for_testing_member
    FluentLog.reset();
    FluentDb.setupLogging(enabled: logsOn);
  });

  tearDownAll(() async {
    await FluentTestDb.closeCurrent();
    // On Windows a file closed a moment ago can still be locked; the system cleans its temporary directory.
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });
}
