// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../../../core/fluent_sqlite_internal.dart';

/// A configuration container used to transfer database connection information
/// and schema metadata to a background worker isolate.
///
/// Because isolates do not share memory, this helper serializes the structural
/// details (paths, relationships, and configurations) required by the isolate
/// to initialize its internal database engines and perform complex relational
/// operations independently of the main UI thread.
class IsolateHelper {
  /// A mapping of database identifier keys to their respective filesystem paths.
  /// Used by the worker isolate to establish connections to the correct storage files.
  final Map<String, String> dbPaths;

  /// A registry of foreign key relationships or join definitions.
  /// This enables the worker to perform complex relational lookups and cascading
  /// updates without needing external instructions from the main thread.
  final Map<String, List<Map<String, dynamic>>> relationMap;

  /// A store of configuration parameters for each database instance.
  /// This includes specific engine settings (e.g., encryption keys, page sizes,
  /// or performance flags) applied during the [IsolateCmd.init] phase.
  final Map<String, Map<String, dynamic>> dbConfigs;

  /// Creates a configuration container used to bootstrap the background database worker.
  ///
  /// This constructor facilitates the transfer of immutable initialization data
  /// from the main isolate to the background isolate. Because isolates have
  /// separate memory heaps, passing this data via the [SendPort] is the standard
  /// way to ensure the worker has access to the filesystem locations and
  /// operational configurations it needs to manage its [SQLite] connections.
  ///
  /// [dbPaths]: A map of database names to absolute system paths.
  /// [relationMap]: Schema metadata to resolve inter-table dependencies during complex queries.
  /// [dbConfigs]: Per-database settings (e.g., performance tuning, encryption flags).
  IsolateHelper({required this.dbPaths, required this.relationMap, required this.dbConfigs});

  /// Serializes the [IsolateHelper] instance into a JSON-compatible map.
  Map<String, dynamic> toMap() => {'dbPaths': dbPaths, 'relationMap': relationMap, 'dbConfigs': dbConfigs};

  /// Deserializes a [Map] back into a [IsolateHelper] instance.
  factory IsolateHelper.fromMap(Map<String, dynamic> map) => IsolateHelper(
    dbPaths: map['dbPaths'] is Map ? (map['dbPaths'] as Map).map((key, value) => MapEntry(key.toString(), value.toString())) : {},
    relationMap: map['relationMap'] is Map
        ? (map['relationMap'] as Map).map((key, value) {
            final list = (value as List? ?? []).map((item) => Map<String, dynamic>.from(item as Map)).toList();
            return MapEntry(key.toString(), list);
          })
        : {},
    dbConfigs: map['dbConfigs'] is Map ? (map['dbConfigs'] as Map).map((key, value) => MapEntry(key.toString(), value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{})) : {},
  );
}
