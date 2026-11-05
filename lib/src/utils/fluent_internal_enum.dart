// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// Enums the library uses internally; not exported by package:fluent_sqflite/fluent_sqflite.dart.

import 'fluent_enum.dart';

/// The operation of a `FluentTask`: the engine schedules by it (reads vs. writes) and the provider routes the task
/// to its executor.
enum FluentDbAction {
  /// Reads models (`find`, `findAll`, `findFirst`, `findByIds`, `findPage`, `search`, trash reads).
  find,

  /// Reads one model by its key.
  findById,

  /// Counts visible rows.
  count,

  /// Checks that a visible row exists (`exists`, `existsWhere`).
  exists,

  /// Reads rows as maps (`findMaps`).
  findMaps,

  /// Computes aggregates (`sum`, `avg`, `min`, `max`, `countDistinct`, `aggregate`).
  aggregate,

  /// Runs a read-only SQL query (`rawQuery`).
  rawQuery,

  /// Runs a SQL statement (`execute`); publishes a change event only when it changes rows (see `FluentTask.isStreamOp`).
  execute,

  /// Inserts / updates models (`save`, `saveAll`).
  save,

  /// Updates existing models (`update`, `updateAll`).
  update,

  /// Updates columns of rows by key or filter (`updateById`, `updateWhere`).
  updateFields,

  /// Soft-deletes rows (hard delete for models without soft delete).
  delete,

  /// Removes rows permanently (`hard: true`).
  hardDelete,

  /// Restores soft-deleted rows.
  restore,

  /// Permanently removes soft-deleted rows older than a period (`purgeDeleted`).
  purgeDeleted,

  /// Removes rows whose expiry date has passed.
  clearExpired,

  /// Removes all rows of a table.
  clearTable,

  /// Removes all rows of all tables of a database.
  clearDatabase,

  /// Broadcast after the databases were deleted (`FluentDb.deleteDatabases`): listeners clear their state.
  wipeAll,

  /// A user transaction ([FluentDb.transaction]): holds the database's write slot while its body runs.
  transaction,

  /// Reads of relations (`loadRelations`, `findRelated`, `countRelated`): queued like any read.
  relationRead,

  /// Changes of relations (`attach`, `detach`): a write; the changed tables publish their own events.
  relationWrite,
}

/// Classification of [FluentDbAction]s for scheduling and change events.
extension FluentDbActionX on FluentDbAction {
  /// Actions that write: the engine runs them as barriers (alone, in call order).
  static const Set<FluentDbAction> _writeActions = {
    FluentDbAction.save,
    FluentDbAction.update,
    FluentDbAction.updateFields,
    FluentDbAction.delete,
    FluentDbAction.hardDelete,
    FluentDbAction.restore,
    FluentDbAction.purgeDeleted,
    FluentDbAction.clearExpired,
    FluentDbAction.clearTable,
    FluentDbAction.clearDatabase,
    FluentDbAction.execute,
    FluentDbAction.wipeAll,
    FluentDbAction.transaction,
    FluentDbAction.relationWrite,
  };


  /// Writes that publish a change event of their table. Not here: database-wide actions (they broadcast
  /// themselves), `execute` (only when it changes rows), transactions and relation writes (the changed tables
  /// publish their own events).
  static final Set<FluentDbAction> _streamActions = Set.from(_writeActions)..removeAll([FluentDbAction.clearDatabase, FluentDbAction.wipeAll, FluentDbAction.execute, FluentDbAction.transaction, FluentDbAction.relationWrite]);

  /// Whether the action writes (see [_writeActions]).
  bool get isWriteOp => _writeActions.contains(this);

  /// Whether the action itself publishes a change event of its table.
  bool get isStreamOp => _streamActions.contains(this);

  /// The kind of change this action reports to `FluentDb.onEvent` listeners.
  FluentChangeKind get changeKind => switch (this) {
    FluentDbAction.save => FluentChangeKind.save,
    FluentDbAction.delete || FluentDbAction.hardDelete || FluentDbAction.purgeDeleted || FluentDbAction.clearExpired => FluentChangeKind.delete,
    FluentDbAction.restore => FluentChangeKind.restore,
    FluentDbAction.clearTable || FluentDbAction.clearDatabase || FluentDbAction.wipeAll => FluentChangeKind.clear,
    _ => FluentChangeKind.update,
  };
}
