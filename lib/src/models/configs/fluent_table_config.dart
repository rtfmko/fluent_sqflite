// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/fluent_enum.dart';

/// Settings of one table, declared on its model (`FluentStorable.tableConfig`): how values are stored, plus overrides
/// of the database ([FluentDbConfig]) and global ([FluentConfig]) settings.
///
/// The override fields are `null` by default: the table follows its database, which follows the global settings.
///
/// ```dart
/// @override
/// FluentTableConfig get tableConfig => const FluentTableConfig(trashRetention: Duration(days: 90), isolateMapping: FluentIsolateMapping.always);
/// ```
class FluentTableConfig {
  /// How `DateTime` values are stored (default [FluentDateTimeFormat.timestamp]: milliseconds since epoch, fast to
  /// compare and index).
  final FluentDateTimeFormat dateTimeFormat;

  /// Whether enums are stored by name (default `true`, survives reordering the enum) or by index. Reading accepts
  /// both, so switching keeps old rows readable.
  final bool storeEnumsAsNames;

  /// How long soft-deleted rows of this table stay in the trash; `null` follows the database / global setting.
  final Duration? trashRetention;

  /// Whether reference columns of this table's relations get an index; `null` follows the database / global setting.
  final bool? indexReferences;

  /// Whether fields of this model holding stored models become relations without a declaration; `null` follows the
  /// database / global setting.
  final bool? autoRelations;

  /// How this table's full-text index is kept; `null` follows the database / global setting.
  final FluentFullText? fullText;

  /// Whether big lists of this table are mapped in a background isolate; `null` follows `FluentConfig.isolateMapping`.
  final FluentIsolateMapping? isolateMapping;

  /// Columns that identify a row on the server, when they are not the local primary key (e.g. `['server_id']` next to
  /// a local auto-increment `id`). Sync and `watchRemote` match server rows and deletions by them; they should be
  /// unique (`isUnique: true`). `null`: the primary key.
  final List<String>? serverKey;

  /// Where the keys of batched `findById` / `findByIds` lookups of this table come from (`fromModels` when the
  /// model's `fromCacheJson` changes the key); `null` follows the database / global setting.
  final FluentBatchKeys? batchKeys;

  /// Creates the settings of a table.
  const FluentTableConfig({
    this.dateTimeFormat = FluentDateTimeFormat.timestamp,
    this.storeEnumsAsNames = true,
    this.trashRetention,
    this.indexReferences,
    this.autoRelations,
    this.fullText,
    this.isolateMapping,
    this.serverKey,
    this.batchKeys,
  });
}
