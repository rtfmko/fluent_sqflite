// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Identifies one database (`FluentGroup.dbKey`, the `dbKey:` of `FluentDb` calls).
///
/// [dbName] is also the file name (`<dbName>.db`): only letters, digits and `_` (otherwise `init` fails with
/// `FluentErrorCode.invalidDatabaseName`).
///
/// ### Examples
///
/// #### 1. An enum for fixed databases:
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
/// await FluentDb.save(model, dbKey: AppDatabases.cache);
/// ```
///
/// #### 2. A class for databases named at run time:
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
/// await FluentDb.save(model, dbKey: UserDatabase('user_123'));
/// // Or without a class of your own:
/// await FluentDb.clear(dbKey: FluentDbKey('cache_db'));
/// ```
abstract class FluentDbKey {
  /// A key for the database [dbName], without declaring a class or enum: `FluentDbKey('cache_db')`.
  factory FluentDbKey(String dbName) = _FluentDbKeyImpl;

  /// The database name: unique among the groups, and the file name without `.db`.
  String get dbName;
}

/// Internal concrete implementation of [FluentDbKey].
class _FluentDbKeyImpl implements FluentDbKey {
  /// The underlying database identifier.
  @override
  final String dbName;

  /// Creates a new instance of the database key.
  _FluentDbKeyImpl(this.dbName);

  /// Two keys made with `FluentDbKey(name)` for the same name are equal (usable in sets and as map keys).
  @override
  bool operator ==(Object other) => identical(this, other) || other is _FluentDbKeyImpl && other.dbName == dbName;

  @override
  int get hashCode => dbName.hashCode;

  @override
  String toString() => dbName;
}
