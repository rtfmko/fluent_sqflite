// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Represents the cache size configuration for SQLite, controlling how many
/// database pages are held in memory.
///
/// **Understanding SQLite Cache Scaling:**
/// * **Negative Values (Bytes/KiB):** When the value is negative, SQLite interprets
///   the absolute value as the total size of the cache in **KiB**. This is the
///   standard way to define a memory budget (e.g., -10000 KiB ≈ 10MB).
/// * **Positive Values (Pages):** When the value is positive, it represents the
///   exact **number of pages** to cache. If a page size is 4096 bytes, a value
///   of 500 would result in a ~2MB cache.
class SQLiteCacheSize {
  final int _value;

  const SQLiteCacheSize._(this._value);

  /// Defines cache by Kilobytes (negative value).
  factory SQLiteCacheSize.kiloBytes(int kb) => SQLiteCacheSize._(-(kb.abs()));

  /// Defines cache by Megabytes (converts to negative KiB).
  factory SQLiteCacheSize.megaBytes(int mb) => SQLiteCacheSize._(-(mb * 1024).abs());

  /// Defines cache by specific page count (positive value).
  factory SQLiteCacheSize.pages(int count) => SQLiteCacheSize._(count.abs());

  /// Default configuration (approx. 10MB cache).
  static const defaultSize = SQLiteCacheSize._(-10000);

  /// Returns the raw integer value expected by the `PRAGMA cache_size` command.
  int get rawValue => _value;

  @override
  String toString() => 'SQLiteCacheSize(${_value < 0 ? "${_value.abs()} KB" : "$_value pages"})';
}
