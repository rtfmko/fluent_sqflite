// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:fluent_sqflite/fluent_sqflite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fluent_test_db.dart';

/// Prepares fluent_sqflite for the tests of one file; call it once at the top of `main()`.
///
/// * sqflite runs through FFI (SQLite of the desktop; no device or emulator needed);
/// * the file gets its own temporary databases directory, removed after its last test;
/// * library logs are off unless [logging] (default: when the `FLUENT_LOG` environment variable is set) — the issues
///   are still collected in `FluentTestDb.issues`;
/// * a `FluentTestDb` left open is closed after the last test.
void setUpFluentTests({bool? logging}) {
  late Directory dir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactoryOrNull = databaseFactoryFfi; // the setter without the "changing the default factory" warning
    dir = await Directory.systemTemp.createTemp('fluent_sqflite_test_');
    await databaseFactory.setDatabasesPath(dir.path);
    FluentDb.setupLogging(enabled: logging ?? Platform.environment.containsKey('FLUENT_LOG'));
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
