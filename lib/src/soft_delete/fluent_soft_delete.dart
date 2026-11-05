// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../interfaces/interfaces.dart';

/// Soft delete (a trash) for a model: `delete` only stamps the row's [softDeleteColumn]; reads hide it until
/// `trash.restore` brings it back. Owned soft-deletable children go to the trash and come back with their owner.
///
/// Rows stay in the trash for `trashRetention` (`FluentTableConfig` of the model, else `FluentDbConfig`, else
/// `FluentConfig`, default 7 days) and are then removed for good by the periodic purge
/// (`FluentConfig.trashPurgeInterval`) or `trash.empty()`. The provider gets `trash` and `withTrash`, the model
/// `restore()` / `deleteForever()`.
///
/// ```dart
/// class Note extends FluentStorable with FluentSoftDeletable { ... }
///
/// await note.delete();                            // note.isDeleted == true
/// final List<Note> trashed = await notes.trash.find();
/// await note.restore();
/// ```
mixin FluentSoftDeletable on FluentStorable {
  /// When the row was moved to the trash, `null` for a live row. Set by the library (delete, restore, reads); a
  /// value set by hand is ignored by `save` (reported as a `deletedAtIgnored` issue).
  DateTime? deletedAt;

  /// Whether this model is in the trash (read through `withTrash` or `trash`).
  bool get isDeleted => deletedAt != null;

  /// The column holding [deletedAt] (default `deleted_at`); added to the table by the library.
  String get softDeleteColumn => 'deleted_at';
}
