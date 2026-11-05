// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// What happened to one row of a save.
enum FluentRowOutcome {
  /// A new row was inserted.
  inserted,

  /// An existing row was updated (also a trashed row updated in place by a write from the server: it stays in the
  /// trash).
  updated,

  /// The row was in the trash (soft delete): it was brought back and updated.
  restored,

  /// Nothing was written: the row already existed (`insertOnly`), did not exist or is in the trash (`updateOnly` /
  /// `patch`), or its row is in the trash together with its still deleted owner.
  skipped,
}

/// The result of `save` / `saveAll`: how many rows were inserted, updated, restored and skipped.
///
/// Generated keys are written back into the saved models (`item.primaryKeyValue`).
///
/// ```dart
/// final FluentSaveResult r = await users.saveAll(list, strategy: FluentSaveStrategy.insertOnly);
/// if (r.skipped > 0) print('${r.skipped} already stored');
/// ```
class FluentSaveResult {
  /// Builds a result from the [outcomes] of the saved rows, in the order of the items.
  FluentSaveResult(this.outcomes);

  /// An empty result (nothing to save).
  static final FluentSaveResult empty = FluentSaveResult(const []);

  /// The outcome of every item, in the order the items were passed.
  final List<FluentRowOutcome> outcomes;

  /// Number of inserted rows.
  int get inserted => outcomes.where((o) => o == FluentRowOutcome.inserted).length;

  /// Number of updated rows.
  int get updated => outcomes.where((o) => o == FluentRowOutcome.updated).length;

  /// Number of rows brought back from the trash (and updated).
  int get restored => outcomes.where((o) => o == FluentRowOutcome.restored).length;

  /// Number of items that were not written (see [FluentRowOutcome.skipped]).
  int get skipped => outcomes.where((o) => o == FluentRowOutcome.skipped).length;

  /// Number of written rows (inserted + updated + restored).
  int get saved => outcomes.length - skipped;

  @override
  String toString() => 'FluentSaveResult(inserted: $inserted, updated: $updated, restored: $restored, skipped: $skipped)';
}
