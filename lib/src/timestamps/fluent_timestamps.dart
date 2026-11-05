// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../interfaces/interfaces.dart';

/// Automatic creation / modification times for a model.
///
/// The library adds the [createdAtColumn] / [updatedAtColumn] columns and fills them: an insert sets both, every
/// update (`save` of an existing row, `update`, `updateById`, `updateWhere`) sets [updatedAt]. The values are loaded
/// back into [createdAt] / [updatedAt]; `buildJson` does not need to contain them (values there are ignored).
/// Rows received from the server (`syncWithServer` pulls, `watchRemote` stores) keep the [createdAt] / [updatedAt]
/// the received model carries; only a `null` time is filled by the library.
///
/// ```dart
/// class Note extends FluentStorable with FluentTimestamps { ... }
///
/// final Note note = (await FluentDb.findById<Note>(1))!;
/// print(note.updatedAt);
/// ```
mixin FluentTimestamps on FluentStorable {
  /// When the row was inserted (set by the library).
  DateTime? createdAt;

  /// When the row was last written (set by the library).
  DateTime? updatedAt;

  /// Column of [createdAt].
  String get createdAtColumn => 'created_at';

  /// Column of [updatedAt].
  String get updatedAtColumn => 'updated_at';
}
