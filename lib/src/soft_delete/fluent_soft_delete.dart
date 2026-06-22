// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../interfaces/interfaces.dart';

/// A mixin that implements advanced soft-deletion capabilities for [FluentStorable] entities.
///
/// Instead of physically removing records from the SQLite table, models using this mixin
/// are flagged with a [deletedAt] timestamp. This hides them from public query APIs
/// and schedules them for automated background purging based on the retention policy.
mixin FluentSoftDeletable on FluentStorable {
  /// The absolute timestamp when this record was soft-deleted.
  /// If null, the record is considered active.
  DateTime? deletedAt;

  /// The database column name utilized to persist the soft-deletion state.
  /// Defaults to 'deleted_at'.
  String get softDeleteColumn => 'deleted_at';
}
