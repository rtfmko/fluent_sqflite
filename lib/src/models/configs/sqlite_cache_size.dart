// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// The size of SQLite's page cache (`PRAGMA cache_size`, `FluentDbConfig.cacheSize`).
///
/// A memory budget ([SQLiteCacheSize.kiloBytes], [SQLiteCacheSize.megaBytes]) is stored as a negative value (KiB);
/// a page count ([SQLiteCacheSize.pages]) as a positive one (500 pages of 4 KiB ≈ 2 MB).
///
/// ```dart
/// const FluentDbConfig(cacheSize: SQLiteCacheSize.defaultSize); // about 10 MB
/// FluentDbConfig(cacheSize: SQLiteCacheSize.megaBytes(32));
/// ```
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
