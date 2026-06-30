// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Represents a unique identifier for a database within [FluentDb].
///
/// By using [FluentDbKey] instead of raw [String] identifiers, you ensure type safety,
/// prevent typos, and enable better refactoring across your codebase.
///
/// ### Examples
///
/// #### 1. Using [Enum] for predefined databases:
/// ```dart
/// enum AppDatabases implements FluentDbKey {
///   cache('cache_db'),
///   user('user_db');
///
///   @override
///   final String dbName;
///   const AppDatabases(this.dbName);
/// }
///
/// // Usage:
/// FluentDb.saveItem(model, dbKey: AppDatabases.cache);
/// ```
///
/// #### 2. Using [Class] for dynamic databases:
/// ```dart
/// class UserDatabase implements FluentDbKey {
///   final String userId;
///   const UserDatabase(this.userId);
///
///   @override
///   String get dbName => 'user_${userId}_db';
/// }
///
/// // Usage:
/// FluentDb.saveItem(model, dbKey: UserDatabase('user_123'));
/// ```
abstract class FluentDbKey {
  /// The physical file name (or unique key) associated with this database.
  String get dbName;

  @override
  String toString() => dbName;
}
