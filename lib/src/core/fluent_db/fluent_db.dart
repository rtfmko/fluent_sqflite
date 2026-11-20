// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_redundant_argument_values

import 'dart:async';
import 'dart:io' show Directory;

import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../../internal.dart';

part 'parts/fluent_db_lifecycle.dart';
part 'parts/fluent_db_locator.dart';
part 'parts/fluent_db_maintenance.dart';
part 'parts/fluent_db_schema.dart';

/// The entry point of the library; every member is static.
///
/// * **Lifecycle:** [init] opens the databases of the given [FluentGroup]s (schema sync, migrations, start-up
///   clean-up); [close], [restart], [deleteDatabases] and [clear] end or reset them.
/// * **Calls by model type:** `FluentDb.find<User>()`, `FluentDb.save(user)`, ... mirror the [FluentProvider] API and
///   resolve the provider from the model type ([providerOf], [provider]); `dbKey:` picks the database when a model is
///   stored in several.
/// * **Transactions, events, diagnostics:** [transaction], [onEvent], [onIssue], [report], [queryStats],
///   [schemaReport], [planMigrations].
/// * **Settings:** `init(config:)` and [configure] hold the global [FluentConfig]; [setupLogging] the log.
///
/// ```dart
/// await FluentDb.init([FluentGroup(dbKey: AppDatabases.main, providerList: [UserProvider()])]);
/// final List<User> admins = await FluentDb.find<User>(where: FluentFilter.eq('role', 'admin'));
/// ```
class FluentDb {
  /// Singleton instance of the registry.
  static final FluentDb _instance = FluentDb._internal();

  /// The groups of the last [init] (kept for [restart], [deleteDatabases] and [purgeArchivedColumns]).
  static List<FluentGroup>? _lastConfig;

  /// The global settings of the last `init` (kept for [restart]).
  static FluentConfig _lastFluentConfig = const FluentConfig();

  /// Internal storage mapping database group names (dbName) to their respective
  /// provider registries.
  ///
  /// This multi-level registry ensures strict isolation between different
  /// database contexts and enables both strict-context resolution and system-wide "smart" lookups.
  final Map<String, _FluentProviderIndex> _groupedRegistry = {};

  /// Tracks the initialization status of the registry.
  bool _isInitialized = false;

  /// Periodic trash purge while the app runs (`FluentConfig.trashPurgeInterval`).
  FluentClockTimer? _trashPurgeTimer;

  /// Periodic `PRAGMA optimize` while the app runs (`FluentConfig.optimizeInterval`).
  FluentClockTimer? _optimizeTimer;

  /// The [init] in progress: concurrent calls wait for it instead of registering every provider again.
  Future<void>? _pendingInit;

  /// The number of lifecycle calls made so far, and the number at the moment [_pendingInit] was queued: a later
  /// [init] shares the pending one only while no other lifecycle call was queued after it.
  int _lifecycleCalls = 0;
  int _pendingInitCall = 0;

  /// Counts the calls of [FluentDb.configure]: an [FluentDb.init] that was called before one does not overwrite it.
  static int _configEpoch = 0;

  /// The end of the last lifecycle call ([init], [close], [restart], [deleteDatabases]): they run one after another.
  Future<void> _lifecycleTail = Future<void>.value();

  /// Runs [action] after every lifecycle call made before it (its error goes to its caller only).
  Future<R> _serialized<R>(Future<R> Function() action, {bool counts = true}) {
    if (counts) _lifecycleCalls++;
    final Future<R> result = _lifecycleTail.then((_) => action());
    _lifecycleTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Every member is static: `FluentDb.init(...)`, `FluentDb.find<User>()`.
  FluentDb._internal();

  /// The provider of model [T] (in database [dbKey] when [T] is stored in several databases).
  ///
  /// Throws a [FluentConfigException]: [FluentErrorCode.providerNotFound] when no open database stores [T],
  /// [FluentErrorCode.databaseNotOpen] when [dbKey] names a database that is not open,
  /// [FluentErrorCode.ambiguousProvider] when several do and [dbKey] is missing.
  ///
  /// ```dart
  /// final FluentProvider<User> users = FluentDb.providerOf<User>();
  /// ```
  static FluentProvider<T> providerOf<T extends FluentStorable>({FluentDbKey? dbKey}) => _resolveProvider(modelType: T, dbName: dbKey?.dbName) as FluentProvider<T>;

  /// The registered provider of class [P], to call methods you added to it.
  ///
  /// Throws like [providerOf] ([FluentErrorCode.ambiguousProvider] also when one class serves several tables).
  ///
  /// ```dart
  /// final UserProvider users = FluentDb.provider<UserProvider>();
  /// await users.findAdmins();
  /// ```
  static P provider<P extends FluentProvider>({FluentDbKey? dbKey}) => _resolveProvider(providerType: P, dbName: dbKey?.dbName) as P;

  /// The error of a call that names database [dbName], which is not open ([action] is the log tag).
  static FluentConfigException _databaseNotOpen(String dbName, String tag, {String? what}) => FluentLog.raise(
    FluentConfigException(
      what ?? 'Database "$dbName" is not open.',
      code: FluentErrorCode.databaseNotOpen,
      hint: 'Check the dbKey (open: ${_instance._groupedRegistry.keys.isEmpty ? 'none' : _instance._groupedRegistry.keys.join(', ')}); call FluentDb.init([FluentGroup(dbKey: ..., ...)]) first, or FluentDb.restart() if the database was closed.',
    ),
    tag: tag,
  );

  /// The provider of [modelType], [providerType] or [tableName]: only in database [dbName] when given, else in every
  /// open database.
  ///
  /// Every caller passes at least one criterion. Throws [FluentConfigException] ([FluentErrorCode.providerNotFound] /
  /// [FluentErrorCode.databaseNotOpen] / [FluentErrorCode.ambiguousProvider] / [FluentErrorCode.notInitialized])
  /// when there is not exactly one match.
  static FluentProvider _resolveProvider({Type? modelType, Type? providerType, String? tableName, String? dbName}) {
    final String target = modelType?.toString() ?? providerType?.toString() ?? tableName!;

    // Index lookup by the requested criterion. One model stored in several tables of a database cannot be found by
    // its model type: the call has to name the provider.
    FluentProvider? lookup(_FluentProviderIndex index) {
      if (tableName != null && modelType == null && providerType == null) return index.byTable(tableName);
      final List<FluentProvider> all = modelType != null ? index.allByModel(modelType) : index.allByProvider(providerType!);
      if (all.length > 1) {
        final bool sameClass = all.map((p) => p.runtimeType).toSet().length == 1;
        throw FluentLog.raise(
          FluentConfigException(
            '$target is used for several tables: ${all.map((p) => '${p.tableName} (${p.runtimeType})').join(', ')}; a call by type cannot choose.',
            code: FluentErrorCode.ambiguousProvider,
            hint: sameClass
                ? 'Keep a reference to each provider instance and call it directly (provider.find(...)).'
                : 'Call the provider itself: FluentDb.provider<${all.first.runtimeType}>().find(...), or keep a reference to it.',
          ),
          tag: 'FluentDb:resolve',
        );
      }
      return all.firstOrNull;
    }

    // Strict Search: Search only within the specified database group.
    if (dbName != null) {
      final _FluentProviderIndex? group = _instance._groupedRegistry[dbName];
      if (group == null) throw _databaseNotOpen(dbName, 'FluentDb:resolve');
      final FluentProvider? found = lookup(group);
      if (found != null) return found;
      throw FluentLog.raise(
        FluentConfigException(
          'No provider for "$target" is registered in database "$dbName".',
          code: FluentErrorCode.providerNotFound,
          hint: 'Add its provider to the FluentGroup of "$dbName" in FluentDb.init([...]).',
        ),
        tag: 'FluentDb:resolve',
      );
    }

    // Smart Search: Scan all registered database groups.
    final Map<String, FluentProvider> matches = {};
    for (final MapEntry<String, _FluentProviderIndex> entry in _instance._groupedRegistry.entries) {
      final FluentProvider? found = lookup(entry.value);
      if (found != null) matches[entry.key] = found;
    }

    if (matches.isEmpty) {
      throw FluentLog.raise(
        FluentConfigException(
          _instance._groupedRegistry.isEmpty ? 'No database is open, so "$target" has no provider.' : 'No provider for "$target" is registered in any open database.',
          code: _instance._groupedRegistry.isEmpty ? FluentErrorCode.notInitialized : FluentErrorCode.providerNotFound,
          hint: _instance._groupedRegistry.isEmpty
              ? 'Call `await FluentDb.init([...])` before using the database.'
              : 'Add its provider to a group: FluentDb.init([FluentGroup(dbKey: ..., providerList: [..., ${target}Provider()])]).',
        ),
        tag: 'FluentDb:resolve',
      );
    }

    // Handle Success: Single match found (the ideal scenario).
    if (matches.length == 1) {
      final String resolvedDbName = matches.keys.first;
      if (FluentLog.isOn(FluentLogLevel.debug)) FluentLog.debug('Successfully resolved "$target" to database "$resolvedDbName"', tag: 'fluentdb:resolve', context: {'target': target, 'dbName': resolvedDbName});
      return matches.values.first;
    }

    // Handle Collision: Same model found in multiple databases (Ambiguity).
    throw FluentLog.raise(
      FluentConfigException(
        '"$target" is registered in several databases: ${matches.keys.join(', ')}.',
        code: FluentErrorCode.ambiguousProvider,
        hint: 'Say which one to use: pass dbKey: ... to the FluentDb call (or call the provider directly).',
      ),
      tag: 'FluentDb:resolve',
    );
  }


  /// Change events of model [T] (of every model with `onEvent<FluentStorable>()`), optionally only those made by
  /// calls with [tag] and only of the given [kinds]. Writes inside a [transaction] publish after the commit.
  ///
  /// ```dart
  /// FluentDb.onEvent<Profile>(tag: 'api', kinds: {FluentChangeKind.save, FluentChangeKind.delete}).listen((event) {
  ///   debugPrint('${event.kind.name}: ${event.items.length} profiles');
  /// });
  /// ```
  static Stream<FluentChangeEvent<T>> onEvent<T extends FluentStorable>({Object? tag, Set<FluentChangeKind>? kinds}) {
    Stream<FluentChangeEvent<dynamic>> stream = FluentEngine().changeStream;

    if (T != FluentStorable) {
      stream = stream.where((event) => event.modelType == T);
    }

    if (tag != null) {
      stream = stream.where((event) => event.tag == tag);
    }

    if (kinds != null && kinds.isNotEmpty) {
      stream = stream.where((event) => kinds.contains(event.kind));
    }

    return stream.map((event) => FluentChangeEvent<T>(modelType: event.modelType, table: event.table, dbName: event.dbName, kind: event.kind, items: event.items.cast<T>(), tag: event.tag));
  }

  /// What the library tells you, as it happens: hints, automatic changes, warnings and errors nobody received (see
  /// [FluentIssue]), optionally only some [types] or [kinds]. Muted keys ([setupLogging] `mute`) are left out; the
  /// log level does not apply.
  ///
  /// Errors your code receives as exceptions are not issues: catch them where you call.
  ///
  /// ```dart
  /// // Crash reporting: only what is wrong.
  /// FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error}).listen((i) {
  ///   Sentry.captureMessage('${i.key}: ${i.title}');
  /// });
  /// // A debug panel: hints and automatic changes.
  /// FluentDb.onIssue(types: {FluentIssueType.hint, FluentIssueType.autoFix}).listen(panel.add);
  /// ```
  static Stream<FluentIssue> onIssue({Set<FluentIssueType>? types, Set<FluentIssueKind>? kinds}) {
    Stream<FluentIssue> stream = FluentLog.issues;
    if (types != null) stream = stream.where((i) => types.contains(i.type));
    if (kinds != null) stream = stream.where((i) => kinds.contains(i.kind));
    return stream;
  }


  // ---------------------------------------------------------------------------
  // CRUD — the same API as FluentProvider (see FluentRead / FluentWrite / FluentRemove), resolved by model type.
  //
  // [dbKey] picks the database group when a model is registered in several; [tag] marks the change events
  // (FluentDb.onEvent(tag: ...)). Collections may mix model types: each type goes to its own provider.
  // ---------------------------------------------------------------------------

  static FluentProvider<T> _typed<T extends FluentStorable>(FluentDbKey? dbKey) => providerOf<T>(dbKey: dbKey);

  // The statics never throw synchronously: a lookup error (no / ambiguous provider) becomes a failed future or an
  // error event, so `.catchError` / `onError` see it like every other database error.
  static Stream<R> _safeStream<R>(Stream<R> Function() open) {
    try {
      return open();
    } catch (e, s) {
      return Stream<R>.error(e, s);
    }
  }

  /// The provider of [item]: the one of its runtime type when that is registered (a `SpecialPost` held in a `Post`
  /// variable belongs to its own table), else by [T].
  static FluentProvider<T> _forItem<T extends FluentStorable>(T item, FluentDbKey? dbKey) {
    final Type runtime = item.runtimeType;
    if (T == FluentStorable || runtime != T) {
      final List<FluentProvider> own = [
        for (final MapEntry<String, _FluentProviderIndex> e in _instance._groupedRegistry.entries)
          if (dbKey == null || e.key == dbKey.dbName) ...e.value.allByModel(runtime),
      ];
      if (own.isNotEmpty || T == FluentStorable) return _resolveProvider(modelType: runtime, dbName: dbKey?.dbName) as FluentProvider<T>;
    }
    return providerOf<T>(dbKey: dbKey);
  }

  /// Runs [action] once per provider of [items] (indexes into [items] given along) and returns the results.
  ///
  /// Several model types of one database run in one transaction: the whole collection is written or nothing.
  /// Types spread over several database files cannot share a transaction; each file is written on its own.
  static Future<List<R>> _perProvider<T extends FluentStorable, R>(Iterable<T> items, FluentDbKey? dbKey, Future<R> Function(FluentProvider provider, List<FluentStorable> group, List<int> indexes) action) async {
    final List<T> list = items.toList(growable: false);
    final Map<FluentProvider, List<int>> groups = {};
    for (int i = 0; i < list.length; i++) {
      groups.putIfAbsent(_forItem<T>(list[i], dbKey), () => []).add(i);
    }
    Future<List<R>> runAll() async => [
      for (final MapEntry<FluentProvider, List<int>> g in groups.entries) await action(g.key, [for (final int i in g.value) list[i]], g.value),
    ];
    if (groups.length < 2) return runAll();
    final Set<String> databases = {for (final FluentProvider p in groups.keys) p.dbName};
    if (databases.length == 1) return _transactionOn(databases.single, runAll);
    FluentLog.issue(
      FluentIssueKind.crossDatabase,
      'The collection spans several databases (${databases.join(', ')}); each database is written in its own transaction.',
      tag: 'FluentDb:collection',
      hint: 'Keep models that must change together in one database group, or save each group separately.',
    );
    return runAll();
  }

  /// See [FluentRead.findById].
  static Future<T?> findById<T extends FluentStorable>(Object? id, {bool includeExpired = false, FluentLoad relations = FluentLoad.eager, int maxDepth = 1, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).findById(id, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findByIds]: the models with the keys [ids], in their order.
  static Future<List<T>> findByIds<T extends FluentStorable>(
    Iterable<Object?> ids, {
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _typed<T>(dbKey).findByIds(ids, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.find].
  ///
  /// ```dart
  /// final List<Order> open = await FluentDb.find<Order>(where: FluentFilter.eq('status', 'open'), orderBy: 'created_at DESC', limit: 20);
  /// ```
  static Future<List<T>> find<T extends FluentStorable>({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _typed<T>(dbKey).find(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findPage]: one page of models after the cursor of the previous page (keyset pagination).
  static Future<FluentPage<T>> findPage<T extends FluentStorable>({
    FluentFilter? where,
    String? orderBy,
    bool descending = false,
    int limit = 50,
    FluentCursor? after,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _typed<T>(dbKey).findPage(
      where: where,
      orderBy: orderBy,
      descending: descending,
      limit: limit,
      after: after,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    ),
  );

  /// See [FluentWatch.watch]: the matching models now and after every change.
  static Stream<List<T>> watch<T extends FluentStorable>({
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => _safeStream(() => _typed<T>(dbKey).watch(where: where, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentWatch.watchById]: one model now and whenever it changes.
  static Stream<T?> watchById<T extends FluentStorable>(
    Object? id, {
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => _safeStream(() => _typed<T>(dbKey).watchById(id, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findFirst].
  static Future<T?> findFirst<T extends FluentStorable>({
    FluentFilter? where,
    String? orderBy,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _typed<T>(dbKey).findFirst(where: where, orderBy: orderBy, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.findAll].
  static Future<List<T>> findAll<T extends FluentStorable>({
    String? orderBy,
    int? limit,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _typed<T>(dbKey).findAll(orderBy: orderBy, limit: limit, includeExpired: includeExpired, relations: relations, maxDepth: maxDepth, policy: policy));

  /// See [FluentRead.count].
  static Future<int> count<T extends FluentStorable>({FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).count(where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.exists].
  static Future<bool> exists<T extends FluentStorable>(Object? id, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).exists(id, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.existsWhere].
  static Future<bool> existsWhere<T extends FluentStorable>(FluentFilter where, {bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).existsWhere(where, includeExpired: includeExpired, policy: policy));

  /// See [FluentRead.findMaps]: rows as maps of Dart values, optionally only some [columns].
  static Future<List<Map<String, dynamic>>> findMaps<T extends FluentStorable>({
    FluentFilter? where,
    List<String>? columns,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _typed<T>(dbKey).findMaps(where: where, columns: columns, distinct: distinct, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, policy: policy),
  );

  /// See [FluentRead.pluck]: the values of one column.
  static Future<List<V>> pluck<T extends FluentStorable, V>(
    String column, {
    FluentFilter? where,
    bool distinct = false,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _typed<T>(dbKey).pluck<V>(column, where: where, distinct: distinct, orderBy: orderBy, limit: limit, offset: offset, includeExpired: includeExpired, policy: policy),
  );

  /// See [FluentRead.search]: full-text search, best matches first.
  static Future<List<T>> search<T extends FluentStorable>(
    String text, {
    FluentFilter? where,
    bool prefix = true,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _typed<T>(dbKey).search(
      text,
      where: where,
      prefix: prefix,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    ),
  );

  /// See [FluentAggregates.sum].
  static Future<num> sum<T extends FluentStorable>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).sum(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.avg].
  static Future<double?> avg<T extends FluentStorable>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).avg(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.min].
  static Future<V?> min<T extends FluentStorable, V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).min<V>(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.max].
  static Future<V?> max<T extends FluentStorable, V>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).max<V>(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.countDistinct].
  static Future<int> countDistinct<T extends FluentStorable>(String column, {FluentFilter? where, bool includeExpired = false, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).countDistinct(column, where: where, includeExpired: includeExpired, policy: policy));

  /// See [FluentAggregates.aggregate]: a grouped report.
  static Future<List<Map<String, dynamic>>> aggregate<T extends FluentStorable>({
    required Map<String, FluentAggregate> values,
    List<String> groupBy = const [],
    FluentFilter? where,
    FluentFilter? having,
    String? orderBy,
    int? limit,
    bool includeExpired = false,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _typed<T>(dbKey).aggregate(values: values, groupBy: groupBy, where: where, having: having, orderBy: orderBy, limit: limit, includeExpired: includeExpired, policy: policy),
  );

  /// See [FluentWatch.watchValue]: [query] now and after every change of [T]'s table (and of the tables of the model
  /// types in [alsoOn]).
  ///
  /// ```dart
  /// FluentDb.watchValue<Order, num>(() => FluentDb.sum<Order>('total')).listen((total) => debugPrint('$total'));
  /// ```
  static Stream<R> watchValue<T extends FluentStorable, R>(Future<R> Function() query, {List<Type> alsoOn = const [], FluentDbKey? dbKey}) =>
      _safeStream(() => _typed<T>(dbKey).watchValue<R>(query, alsoOn: [for (final Type type in alsoOn) _resolveProvider(modelType: type, dbName: dbKey?.dbName)]));

  /// See [FluentRead.rawQuery]. [T] selects the database the query runs on.
  static Future<List<Map<String, dynamic>>> rawQuery<T extends FluentStorable>(String sql, {List<Object?>? arguments, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).rawQuery(sql, arguments: arguments, policy: policy));

  /// See [FluentRead.execute]. [T] selects the database the statement runs on.
  static Future<int> execute<T extends FluentStorable>(String sql, {List<Object?>? arguments, Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).execute(sql, arguments: arguments, tag: tag, policy: policy));

  /// See [FluentWrite.save].
  static Future<FluentSaveResult> save<T extends FluentStorable>(
    T item, {
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _forItem<T>(item, dbKey).save(item, strategy: strategy, conflictOn: conflictOn, relationSync: relationSync, tag: tag, policy: policy));

  /// See [FluentWrite.saveAll]. Items of several model types are saved by their own providers.
  static Future<FluentSaveResult> saveAll<T extends FluentStorable>(
    Iterable<T> items, {
    FluentSaveStrategy strategy = FluentSaveStrategy.upsert,
    List<String>? conflictOn,
    FluentRelationSyncMode? relationSync,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) async {
    final List<T> list = items.toList(growable: false);
    final List<FluentRowOutcome> outcomes = List<FluentRowOutcome>.filled(list.length, FluentRowOutcome.skipped);
    await _perProvider<T, void>(list, dbKey, (provider, group, indexes) async {
      final FluentSaveResult result = await provider.saveAll(group, strategy: strategy, conflictOn: conflictOn, relationSync: relationSync, tag: tag, policy: policy);
      for (int k = 0; k < indexes.length; k++) {
        outcomes[indexes[k]] = result.outcomes[k];
      }
    });
    return FluentSaveResult(outcomes);
  }

  /// See [FluentWrite.update].
  static Future<int> update<T extends FluentStorable>(
    T item, {
    bool withRelations = false,
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(() => _forItem<T>(item, dbKey).update(item, withRelations: withRelations, syncMode: syncMode, tag: tag, policy: policy));

  /// See [FluentWrite.updateAll].
  static Future<int> updateAll<T extends FluentStorable>(
    Iterable<T> items, {
    bool withRelations = false,
    FluentRelationSyncMode syncMode = FluentRelationSyncMode.preserveLocal,
    Object? tag,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) async => _sum(await _perProvider<T, int>(items, dbKey, (p, group, _) => p.updateAll(group, withRelations: withRelations, syncMode: syncMode, tag: tag, policy: policy)));

  /// See [FluentWrite.updateById].
  static Future<int> updateById<T extends FluentStorable>(Object? id, Map<String, Object?> fields, {bool includeExpired = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).updateById(id, fields, includeExpired: includeExpired, tag: tag, policy: policy));

  /// See [FluentWrite.updateWhere].
  static Future<int> updateWhere<T extends FluentStorable>(FluentFilter where, Map<String, Object?> fields, {bool includeExpired = false, Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).updateWhere(where, fields, includeExpired: includeExpired, tag: tag, policy: policy));

  /// See [FluentRemove.delete].
  static Future<int> delete<T extends FluentStorable>(T item, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _forItem<T>(item, dbKey).delete(item, tag: tag, policy: policy));

  /// See [FluentRemove.deleteAll].
  static Future<int> deleteAll<T extends FluentStorable>(Iterable<T> items, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) async =>
      _sum(await _perProvider<T, int>(items, dbKey, (p, group, _) => p.deleteAll(group, tag: tag, policy: policy)));

  /// See [FluentRemove.deleteById].
  static Future<int> deleteById<T extends FluentStorable>(Object? id, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).deleteById(id, tag: tag, policy: policy));

  /// See [FluentRemove.deleteWhere].
  static Future<int> deleteWhere<T extends FluentStorable>(FluentFilter where, {Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).deleteWhere(where, tag: tag, policy: policy));

  /// The trash of [T] (see [FluentTrashAccess.trash]): `await FluentDb.trash<Note>().restore(note)`, `.find()`,
  /// `.empty()`.
  static FluentTrash<T> trash<T extends FluentSoftDeletable>({FluentDbKey? dbKey}) => fluentLazyTrash<T>(() => providerOf<T>(dbKey: dbKey));

  /// Reads of [T] that also see the trashed rows (see [FluentTrashAccess.withTrash]): `FluentDb.withTrash<Note>().findById(id)`.
  static FluentWithTrash<T> withTrash<T extends FluentSoftDeletable>({FluentDbKey? dbKey}) => fluentLazyWithTrash<T>(() => providerOf<T>(dbKey: dbKey));

  /// See [FluentRemove.clearExpired].
  static Future<int> clearExpired<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).clearExpired(tag: tag, policy: policy));

  /// See [FluentRemove.clearTable].
  static Future<int> clearTable<T extends FluentStorable>({Object? tag, ExecutionPolicy policy = const ExecutionPolicy(), FluentDbKey? dbKey}) =>
      Future.sync(() => _typed<T>(dbKey).clearTable(tag: tag, policy: policy));

  static int _sum(List<int> values) => values.fold(0, (a, b) => a + b);

  /// Returns a fresh copy of [item] with its relations loaded (see [FluentRelationOps.loadRelations]); [names] limits
  /// it to some relations (lazy ones included), empty loads all.
  ///
  /// ```dart
  /// final Article full = await FluentDb.loadRelations(article, names: ['comments']);
  /// ```
  static Future<T> loadRelations<T extends FluentRelations>(T item, {List<String> names = const [], int maxDepth = 1, FluentDbKey? dbKey}) =>
      Future.sync(() => providerOf<T>(dbKey: dbKey).loadRelations(item, names: names, maxDepth: maxDepth));

  /// See [FluentRelationOps.countRelated]: the number of models related to [item] through relation [name], without
  /// loading them.
  static Future<int> countRelated<T extends FluentRelations>(T item, String name, {FluentDbKey? dbKey}) => Future.sync(() => providerOf<T>(dbKey: dbKey).countRelated(item, name));

  /// See [FluentRelationOps.findRelated]: the models of relation [name] of [item], queried with filters and paging.
  static Future<List<R>> findRelated<T extends FluentRelations, R extends FluentStorable>(
    T item,
    String name, {
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => providerOf<T>(dbKey: dbKey).findRelated<R>(
      item,
      name,
      where: where,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    ),
  );

  /// See [FluentParentOps.findParents]: the models [P] whose relation points to [item].
  static Future<List<P>> findParents<P extends FluentRelations>(
    FluentStorable item, {
    String? via,
    FluentFilter? where,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeExpired = false,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => Future.sync(
    () => _forItem<FluentStorable>(item, dbKey).findParents<P>(
      item,
      via: via,
      where: where,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      policy: policy,
    ),
  );

  /// See [FluentRelationOps.attach]: adds [related] to relation [name] of [item] without rewriting the whole list
  /// (many-to-many: links; owned lists: saves them as children; `through`: [link] builds each link model).
  ///
  /// ```dart
  /// await FluentDb.attach(user, 'groups', [admins], link: (group) => Membership(role: 'admin'));
  /// ```
  static Future<void> attach<T extends FluentRelations>(T item, String name, List<FluentStorable> related, {FluentStorable Function(FluentStorable related)? link, FluentDbKey? dbKey}) =>
      Future.sync(() => providerOf<T>(dbKey: dbKey).attach(item, name, related, link: link));

  /// See [FluentRelationOps.detach]: removes [related] from relation [name] of [item]
  /// (many-to-many: only the links; owned lists: deletes the children).
  static Future<void> detach<T extends FluentRelations>(T item, String name, List<FluentStorable> related, {FluentDbKey? dbKey}) =>
      Future.sync(() => providerOf<T>(dbKey: dbKey).detach(item, name, related));

  /// Schema state and migration history of every open database (or only [dbKey]).
  ///
  /// It only reads: a database without the bookkeeping tables (read-only file, never synced) reports no tables.
  /// The reads are queued like a write: calls made before it finish first, calls made after it wait, so the report
  /// never shows a schema sync or a write half done. Inside [transaction] it reads through that transaction.
  ///
  /// ```dart
  /// for (final report in await FluentDb.schemaReport()) {
  ///   debugPrint(report.toString()); // tables, revisions, archived columns, pending NOT NULL, history
  /// }
  /// ```
  static Future<List<FluentSchemaReport>> schemaReport({FluentDbKey? dbKey}) async {
    if (dbKey != null && !_instance._groupedRegistry.containsKey(dbKey.dbName)) throw _databaseNotOpen(dbKey.dbName, 'FluentDb:schemaReport');
    final List<FluentSchemaReport> reports = [];
    for (final MapEntry<String, _FluentProviderIndex> entry in List.of(_instance._groupedRegistry.entries)) {
      if (dbKey != null && entry.key != dbKey.dbName) continue;
      final Database? db = entry.value.all.map((p) => p.dbOrNull).whereType<Database>().firstOrNull;
      if (db == null || !db.isOpen) continue;
      // Read only: a database without the bookkeeping tables (read-only file, never synced) reports nothing yet.
      Future<FluentSchemaReport> read(DatabaseExecutor ex) async {
        final Set<String> present = {
          for (final Map<String, Object?> r in await ex.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)", [fluentSchemaTable, fluentSchemaHistoryTable])) r['name']! as String,
        };
        return FluentSchemaReport(
          database: entry.key,
          tables: present.contains(fluentSchemaTable) ? await readFluentSchemaSnapshots(ex) : const [],
          history: present.contains(fluentSchemaHistoryTable) ? await readFluentSchemaHistory(ex) : const [],
        );
      }

      final FluentTransactionScope? open = FluentTransactionScope.of(entry.key);
      if (open != null) {
        reports.add(await read(open.txn));
        continue;
      }
      // Queued as a barrier: it starts after every earlier call and nothing later overtakes it.
      reports.add(
        await FluentEngine().dispatch(
              FluentTask(action: FluentDbAction.transaction, dbName: entry.key, data: () => read(db)),
            )
            as FluentSchemaReport,
      );
    }
    return reports;
  }

  /// Deletes archived columns (data of fields removed from models) older than [olderThan] right away,
  /// in every open database or only in [dbKey] (read-only databases are skipped). Pass `Duration.zero` to delete all
  /// archives. Full-text indexes of the changed tables are updated too.
  ///
  /// Archives are also purged automatically at start-up after `FluentGroup.archiveRetention`.
  ///
  /// It is a write like any other (it may rebuild tables): calls made before it finish first, calls made after it
  /// wait for it, and nothing runs beside it. Inside a transaction or task of a database it skips that database
  /// (reported as an `ignoredCall` issue): a rebuild needs foreign keys off, which SQLite ignores inside a transaction.
  ///
  /// ```dart
  /// await FluentDb.purgeArchivedColumns(olderThan: const Duration(days: 7));
  /// ```
  static Future<void> purgeArchivedColumns({required Duration olderThan, FluentDbKey? dbKey}) async {
    if (dbKey != null && !_instance._groupedRegistry.containsKey(dbKey.dbName)) throw _databaseNotOpen(dbKey.dbName, 'FluentDb:purgeArchivedColumns');
    for (final FluentGroup group in [...?_lastConfig]) {
      if (dbKey != null && group.dbKey.dbName != dbKey.dbName) continue;
      if (group.readOnly) continue;
      final Database? db = _instance._groupedRegistry[group.dbKey.dbName]?.all.map((p) => p.dbOrNull).whereType<Database>().firstOrNull;
      if (db == null || !db.isOpen) continue;
      // Never inside a transaction of this database: a rebuild needs foreign keys off, which SQLite ignores inside a
      // transaction (rebuilding a parent would delete its children), and queued it would wait for the transaction.
      if (_heldByTask(group.dbKey.dbName, 'purgeArchivedColumns')) continue;
      // Queued as a write: it holds the database alone, so switching foreign keys off for a rebuild affects no other call.
      await FluentEngine().dispatch(
        FluentTask(
          action: FluentDbAction.transaction,
          dbName: group.dbKey.dbName,
          data: () async {
            try {
              await _instance._purgeArchivedColumns(db, group, olderThan);
            } on DatabaseException catch (e, s) {
              throw FluentLog.raise(FluentTransactionScope.sqlError(group.dbKey.dbName, e, s), tag: 'FluentDb:purgeArchivedColumns'); // typed, the original is the cause
            }
            return null;
          },
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens the databases of [groups]: creates or updates every table from its model, runs the pending migrations and
  /// the start-up clean-up (expired rows, trash past its retention). Call it once, before any other call.
  ///
  /// [config] holds the settings of the whole library ([FluentConfig]); each group adds its own
  /// ([FluentGroup.config]), and each model its table settings (`FluentStorable.tableConfig`).
  ///
  /// When a database fails to start, every database this call opened is closed again and the error is thrown
  /// (typed, e.g. [FluentSchemaException], or [FluentConfigException] with [FluentErrorCode.invalidDatabaseName] /
  /// [FluentErrorCode.databaseNotFound] for a missing read-only file); the file is left untouched. With
  /// `FluentGroup.resetOnSchemaError` the failing file is deleted and the whole init runs once more (not for a plan
  /// refused by `onMigrationPlan`).
  ///
  /// ```dart
  /// await FluentDb.init([
  ///   FluentGroup(dbKey: AppDatabases.main, providerList: [UserProvider(), PostProvider()]),
  ///   FluentGroup(dbKey: AppDatabases.cache, providerList: [ImageProvider()], resetOnSchemaError: true),
  /// ]);
  /// ```
  ///
  /// Concurrent calls share one initialization (that of the first call; like a call after [init] completed, a later
  /// call changes nothing), unless a [close], [restart] or [deleteDatabases] was called after the pending [init]: then
  /// this call runs in call order, after it. [init], [close], [restart] and [deleteDatabases] run one after another,
  /// in call order.
  ///
  /// Without [config] the settings in use stay (the last [configure] or `init(config:)`, else the defaults). A
  /// [configure] called after this call (before it starts) wins over [config].
  static Future<void> init(Iterable<FluentGroup> groups, {FluentConfig? config}) {
    final Future<void>? running = _instance._pendingInit;
    // Shared only while nothing was queued after the pending init: else a close() / restart() in between would
    // drop this call (and its groups) for good.
    if (running != null && _instance._pendingInitCall == _instance._lifecycleCalls) return running;
    final int configEpoch = _configEpoch;
    final Future<void> started = _instance._serialized(() {
      final FluentConfig? given = configEpoch == _configEpoch ? config : null;
      return _instance._init(groups, given ?? _lastFluentConfig, isRetry: false);
    });
    _instance._pendingInit = started;
    _instance._pendingInitCall = _instance._lifecycleCalls;
    return started.whenComplete(() {
      if (identical(_instance._pendingInit, started)) _instance._pendingInit = null;
    });
  }

  /// What [init] would change in the databases of [groups], without changing them: one [FluentMigrationPlan] per
  /// database with every schema change (typed, [FluentSchemaChange]), the issues it would report and whether data
  /// would be lost.
  ///
  /// Call it before [init] (in a debug screen, a test, a release check): the files are opened, the sync runs in a
  /// transaction that is rolled back, and the files are closed. A database that does not exist yet is planned in
  /// memory (every table created) and not created. The `onMigrate` code of steps runs only with [runCode] (it may do
  /// things outside the database a rollback cannot undo); its changes are missing from the plan otherwise.
  ///
  /// ```dart
  /// for (final FluentMigrationPlan plan in await FluentDb.planMigrations(groups)) {
  ///   debugPrint('$plan');
  ///   assert(!plan.losesData, 'This release would drop data of ${plan.database}');
  /// }
  /// ```
  static Future<List<FluentMigrationPlan>> planMigrations(Iterable<FluentGroup> groups, {FluentConfig? config, bool runCode = false}) =>
      _instance._serialized(() => _instance._planMigrations(groups, config ?? _lastFluentConfig, runCode: runCode));

  /// Whether the database [dbKey] is open (without [dbKey]: whether [init] has completed).
  static bool isOpen({FluentDbKey? dbKey}) {
    if (dbKey == null) return _instance._isInitialized;
    return _instance._groupedRegistry[dbKey.dbName]?.all.any((p) => p.dbOrNull?.isOpen ?? false) ?? false;
  }

  /// Closes every database (after `PRAGMA optimize`). Calls made before finish first. Later calls through `FluentDb`
  /// (which look the provider up) fail with [FluentConfigException] ([FluentErrorCode.notInitialized]); calls on a
  /// provider you still hold fail with [FluentCancelledException] ([FluentErrorCode.engineClosed]); both until [init]
  /// runs again.
  static Future<void> close() => _insideTask('close') ? Future<void>.value() : _instance._serialized(_instance._closeAll);

  /// Closes the databases and opens them again with the groups and settings of the last [init] (or [configure]);
  /// [update] may change the groups (add a provider, another setting). Without an earlier [init] nothing happens
  /// (reported as an `ignoredCall` issue).
  ///
  /// ```dart
  /// await FluentDb.restart(update: (groups) => [for (final g in groups) g.copyWith(historyLimit: 20)]);
  /// ```
  static Future<void> restart({List<FluentGroup> Function(List<FluentGroup> groups)? update}) =>
      _insideTask('restart') ? Future<void>.value() : _instance._serialized(() => _instance._restart(update));

  /// Deletes every row of every table of [dbKey] (of all databases without it); the files, tables and schema stay.
  /// Watchers receive an empty result right away.
  ///
  /// It is a write like any other: calls made before it finish first, calls made after it see the empty tables.
  /// Inside [transaction] it runs in that transaction (a rollback keeps the rows; watchers hear of it after the
  /// commit); inside another task of the database (a callback) it skips that database (an `ignoredCall` issue).
  /// Throws [FluentConfigException] ([FluentErrorCode.databaseNotOpen]) when [dbKey] is not open, or ([FluentErrorCode.notInitialized]) when no database is open; a table that cannot be emptied (a restricting foreign key, a trigger) fails with a [FluentConstraintException] / [FluentQueryException], and nothing is reported as cleared.
  ///
  /// ```dart
  /// await FluentDb.clear(dbKey: AppDatabases.cache); // free the cache
  /// ```
  static Future<void> clear({FluentDbKey? dbKey}) async {
    if (dbKey != null && !_instance._groupedRegistry.containsKey(dbKey.dbName)) {
      throw _databaseNotOpen(dbKey.dbName, 'FluentDb:clear', what: 'Database "${dbKey.dbName}" is not open, so it cannot be cleared.');
    }
    if (dbKey == null && _instance._groupedRegistry.isEmpty) {
      throw FluentLog.raise(
        FluentConfigException(
          'No database is open, so nothing can be cleared.',
          code: FluentErrorCode.notInitialized,
          hint: 'Call FluentDb.init([...]) first (FluentDb.close() closes every database).',
        ),
        tag: 'FluentDb:clear',
      );
    }
    for (final String dbName in [if (dbKey != null) dbKey.dbName else ..._instance._groupedRegistry.keys]) {
      // Inside a transaction of this database: run in it (queued, the clear would wait for the transaction, and the
      // transaction for the clear). Its events follow the commit; a rollback keeps the rows.
      final FluentTransactionScope? open = FluentTransactionScope.of(dbName);
      if (open != null) {
        try {
          await open.serialized(() => FluentEngine().clearInTransaction(open, _instance._groupedRegistry[dbName]?.all ?? const <FluentProvider>[]));
        } on FluentException catch (e) {
          throw FluentLog.raise(e, tag: 'FluentDb:clear');
        }
        FluentLog.info('All rows of database "$dbName" deleted (committed with the transaction).', tag: 'FluentDb:clear');
        continue;
      }
      if (_heldByTask(dbName, 'clear')) continue;
      final Object? cleared = await FluentEngine().dispatch(FluentTask(action: FluentDbAction.clearDatabase, dbName: dbName));
      if (cleared != true) {
        throw FluentLog.raise(
          FluentConfigException(
            'Database "$dbName" is closed, so it was not cleared.',
            code: FluentErrorCode.databaseNotOpen,
            hint: 'Open the database again (FluentDb.init or FluentDb.restart) before clearing it.',
          ),
          tag: 'FluentDb:clear',
        );
      }
      for (final FluentProvider<FluentStorable> provider in _instance._groupedRegistry[dbName]?.all ?? const <FluentProvider>[]) {
        FluentEngine().broadcastSystemAction(FluentDbAction.clearTable, provider);
      }
      FluentLog.info('All rows of database "$dbName" deleted.', tag: 'FluentDb:clear');
    }
  }

  /// Deletes the database file of [dbKey] (all database files without it) — e.g. when the user signs out.
  ///
  /// Watchers receive an empty result first; then the databases are closed and the files deleted. With [reopen]
  /// (default) the databases are opened again right away (deleted ones empty, with fresh tables), so the app can go
  /// on; otherwise the deleted databases stay closed (the others are reopened). Throws [FluentConfigException]
  /// ([FluentErrorCode.databaseNotOpen]) when [dbKey] (or, without it, any database) is not open.
  ///
  /// ```dart
  /// Future<void> signOut() => FluentDb.deleteDatabases(); // a clean database for the next user
  /// ```
  static Future<void> deleteDatabases({FluentDbKey? dbKey, bool reopen = true}) =>
      _insideTask('deleteDatabases') ? Future<void>.value() : _instance._serialized(() => _instance._deleteDatabases(dbKey?.dbName, reopen: reopen));

  /// Whether the caller runs inside a task or transaction of [dbName]: a queued [call] (a write of the whole database)
  /// would wait for it, and it for the call. The call is skipped for that database and reported (`ignoredCall`).
  static bool _heldByTask(String dbName, String call) {
    if (FluentTransactionScope.of(dbName) == null && !FluentEngine().holdsDatabase(dbName)) return false;
    FluentLog.issue(
      FluentIssueKind.ignoredCall,
      'FluentDb.$call was called from inside a running task or transaction of "$dbName"; nothing was done there.',
      database: dbName,
      subject: call,
      tag: 'FluentDb:$call',
      hint: call == 'clear'
          ? 'Queued, it would wait for the running task, which waits for it. Call FluentDb.$call inside FluentDb.transaction '
              '(it then runs in the transaction) or after the task completed.'
          : 'It may rebuild tables, which needs foreign keys off: impossible inside a transaction. Call FluentDb.$call '
              'after the transaction or callback completed.',
    );
    return true;
  }

  /// Whether the caller runs inside a database task or transaction: closing waits for it, so the call would wait for itself.
  /// It is ignored and reported (`ignoredCall`); the databases stay as they were.
  static bool _insideTask(String call) {
    if (!FluentEngine().isInsideTask) return false;
    FluentLog.issue(
      FluentIssueKind.ignoredCall,
      'FluentDb.$call was called from inside a running database task or transaction; the call is ignored.',
      tag: 'FluentDb:$call',
      hint: 'Closing waits for the running tasks, including the one that asked for it, so it could never finish. '
          'Call FluentDb.$call after the transaction or callback completed.',
    );
    return true;
  }

  /// See [FluentSyncable.syncWithServer]; the provider of [T] must use `with FluentSyncable<T>` (otherwise nothing is
  /// done: an `ignoredCall` issue and a result with `isSuccess: false`).
  static Future<FluentSyncResult<T>> syncWithServer<T extends FluentStorable>({
    FluentSyncStrategy strategy = FluentSyncStrategy.full,
    Future<FluentPushResult<T>> Function(FluentSyncBatch<T> batch)? onPush,
    Future<FluentPullResult<T>> Function(FluentPullRequest request)? onPull,
    FluentFilter? where,
    int? batchSize = 500,
    FluentConflictPolicy<T> conflicts = const FluentConflictPolicy.keepLocal(),
    FluentRemoteDeleteBehavior remoteDeletes = FluentRemoteDeleteBehavior.auto,
    FluentRelationSyncMode? relationSync,
    int retries = 0,
    Duration retryDelay = const Duration(seconds: 1),
    FluentDbKey? dbKey,
  }) async =>
      (await _syncable<T>(dbKey, 'syncWithServer'))?.syncWithServer(
        strategy: strategy,
        onPush: onPush,
        onPull: onPull,
        where: where,
        batchSize: batchSize,
        conflicts: conflicts,
        remoteDeletes: remoteDeletes,
        relationSync: relationSync,
        retries: retries,
        retryDelay: retryDelay,
      ) ??
      FluentSyncResult<T>(strategy: strategy, isSuccess: false, errorMessage: 'The provider of $T does not use FluentSyncable');

  /// See [FluentSyncable.watchSyncStatus]: the sync state of [T]'s table (an error event when [T] does not sync).
  static Stream<FluentSyncStatus> watchSyncStatus<T extends FluentStorable>({FluentDbKey? dbKey}) => _safeStream(() {
    final FluentProvider<T> provider = _typed<T>(dbKey);
    if (provider is FluentSyncable) return (provider as FluentSyncable).watchSyncStatus();
    throw FluentLog.raise(
      FluentConfigException('watchSyncStatus<$T>: ${provider.runtimeType} does not sync.', code: FluentErrorCode.syncNotSupported, hint: 'Add `with FluentSyncable<$T>` to ${provider.runtimeType}.'),
      tag: 'FluentDb.watchSyncStatus',
    );
  });

  /// See [FluentSyncable.pendingChanges]: local changes of [T] waiting to be sent (0 when [T] does not sync).
  static Future<int> pendingChanges<T extends FluentStorable>({FluentFilter? where, FluentDbKey? dbKey}) async =>
      await (await _syncable<T>(dbKey, 'pendingChanges'))?.pendingChanges(where: where) ?? 0;

  static Future<FluentSyncable<T>?> _syncable<T extends FluentStorable>(FluentDbKey? dbKey, String operation) async {
    final FluentProvider<T> provider = providerOf<T>(dbKey: dbKey);
    if (provider is FluentSyncable<T>) return provider;
    FluentLog.issue(
      FluentIssueKind.ignoredCall,
      '$operation<$T>: ${provider.runtimeType} does not sync, nothing was done.',
      tag: 'FluentDb:$operation',
      hint: 'Add the mixin: class ${provider.runtimeType} extends FluentProvider<$T> with FluentSyncable<$T> { ... }',
    );
    return null;
  }

  /// See [FluentWatchRemote.watchRemote].
  static Stream<FluentRemoteEvent<T>> watchRemote<T extends FluentStorable>({
    required Future<FluentRemoteResponse<T>> Function() fetch,
    FluentFilter? where,
    String? orderBy,
    int? limit,
    FluentRemoteStore store = FluentRemoteStore.merge,
    FluentRemoteSource source = FluentRemoteSource.cacheThenRemote,
    Duration? maxAge,
    int retries = 0,
    Duration retryDelay = const Duration(milliseconds: 500),
    Set<int> clearCacheOn = const {},
    bool keepWatching = true,
    bool includeExpired = true,
    FluentLoad relations = FluentLoad.eager,
    int maxDepth = 1,
    FluentRelationSyncMode? relationSync,
    ExecutionPolicy policy = const ExecutionPolicy(),
    FluentDbKey? dbKey,
  }) => _safeStream(
    () => providerOf<T>(dbKey: dbKey).watchRemote(
      fetch: fetch,
      where: where,
      orderBy: orderBy,
      limit: limit,
      store: store,
      source: source,
      maxAge: maxAge,
      retries: retries,
      retryDelay: retryDelay,
      clearCacheOn: clearCacheOn,
      keepWatching: keepWatching,
      includeExpired: includeExpired,
      relations: relations,
      maxDepth: maxDepth,
      relationSync: relationSync,
      policy: policy,
    ),
  );

  /// A snapshot of the task engine: queue length, running tasks, waiting times, and how many reads / saves the
  /// scheduler collapsed, merged or batched. Useful for tuning and in tests.
  static FluentEngineStats engineStats() => FluentEngine().stats;

  /// Runs [action] atomically: every `FluentDb` / provider call inside it uses one SQLite transaction.
  ///
  /// If [action] throws, all its writes are rolled back and the error is rethrown. Each call inside is atomic on its
  /// own too (a savepoint): a failed call that [action] catches leaves no half-written rows, and the transaction goes
  /// on. Change events of the writes are published after the commit (none on rollback). The transaction waits for
  /// running operations of the database and holds its write slot; calls inside it run immediately. A nested
  /// [transaction] joins the open one in a savepoint: when it throws, only its own writes are rolled back and the
  /// error reaches the caller, so the outer transaction can catch it and go on. Code started inside but running after the end (timers, listeners, unawaited
  /// futures) runs outside it, as ordinary calls.
  ///
  /// Do not await a call made outside the transaction (it is queued behind it): the watchdog
  /// (`FluentConfig.transactionWatchdog`) warns and moves waiting reads into the transaction; writes keep waiting.
  ///
  /// [dbKey] selects the database group; it may be omitted when only one group is open (otherwise a
  /// [FluentArgumentException]). A transaction covers one database file.
  ///
  /// ```dart
  /// await FluentDb.transaction(() async {
  ///   await FluentDb.save<Order>(order);
  ///   await FluentDb.updateById<Stock>(order.stockId, {'reserved': order.quantity});
  /// });
  /// ```
  static Future<R> transaction<R>(Future<R> Function() action, {FluentDbKey? dbKey}) => Future.sync(() => _transactionOn(_transactionDbName(dbKey), action));

  /// [transaction] on the database group [dbName].
  static Future<R> _transactionOn<R>(String dbName, Future<R> Function() action) async {
    final FluentTransactionScope? open = FluentTransactionScope.of(dbName);
    if (open != null) return open.serialized(() => open.savepoint(action)); // in call order with the other calls of the transaction

    final Database database = _instance._groupedRegistry[dbName]!.all.first.db;
    FluentTransactionScope? scope;
    final Object? result;
    try {
      result = await FluentEngine().dispatch(
        FluentTask(
          action: FluentDbAction.transaction,
          table: '',
          dbName: dbName,
          data: () => database.transaction((txn) {
            final FluentTransactionScope open = scope = FluentTransactionScope(dbName, txn);
            final Timer? watchdog = FluentEngine().watchTransaction(open);
            return open.run(action).whenComplete(() => watchdog?.cancel());
          }),
        ),
      );
    } on DatabaseException catch (e, s) {
      scope?.rolledBack();
      throw FluentLog.raise(FluentTransactionScope.sqlError(dbName, e, s), tag: 'FluentDb.transaction'); // a failed COMMIT / BEGIN
    } catch (_) {
      scope?.rolledBack(); // keys its inserts gave the models are taken back: SQLite reuses the rowids
      rethrow;
    }
    scope?.committed();
    for (final (FluentTask task, FluentProvider provider, Object? written) in scope?.pendingEvents ?? const <(FluentTask, FluentProvider, Object?)>[]) {
      FluentEngine().publishChange(task, provider, written);
    }
    for (final (FluentTask task, FluentProvider provider, List<FluentTouchedTable> touched) in scope?.pendingTouched ?? const <(FluentTask, FluentProvider, List<FluentTouchedTable>)>[]) {
      FluentEngine().publishTouched(task, provider, touched);
    }
    return result as R;
  }

  /// The database group of a transaction: [dbKey], or the only open group.
  static String _transactionDbName(FluentDbKey? dbKey) {
    final Iterable<String> open = _instance._groupedRegistry.entries.where((e) => e.value.all.isNotEmpty).map((e) => e.key);
    final String? name = dbKey?.dbName ?? (open.length == 1 ? open.single : null);
    if (name != null && open.contains(name)) return name;

    if (dbKey != null) throw _databaseNotOpen(dbKey.dbName, 'FluentDb.transaction', what: 'Database "${dbKey.dbName}" is not open, so a transaction cannot run on it.');
    throw FluentLog.raise(
      FluentArgumentException(
        'dbKey',
        'several database groups are open (${open.join(', ')}), the transaction does not know which one to use',
        hint: 'Pass dbKey of the group whose models the transaction changes. A transaction covers one database file.',
      ),
      tag: 'FluentDb.transaction',
    );
  }


  /// The measured query costs (slowest first), of one database ([dbKey]) and / or one [table], or of everything.
  ///
  /// The library learns how long each query shape takes (and how many rows it returns) from real runs and keeps it
  /// in each database, so it is known right after a restart. Print it while optimizing: `debugPrint('${FluentDb.queryStats()}')`.
  static FluentQueryStats queryStats({FluentDbKey? dbKey, String? table}) => FluentQueryStats(FluentTableStatsTracker().costs(db: dbKey?.dbName, table: table));

  /// Forgets the measured query costs of [dbKey] / [table] (everything without them), e.g. after adding an index, so
  /// the hints and the scheduler start from fresh measurements.
  static void forgetQueryStats({FluentDbKey? dbKey, String? table}) => FluentTableStatsTracker().forget(db: dbKey?.dbName, table: table);

  /// Deletes rows that reference a missing row (dangling references) in [dbKey] (in every database without it).
  ///
  /// Rarely needed: with foreign keys on (the default) SQLite never leaves any; the start-up maintenance cleans them
  /// when foreign keys are off or a check found some.
  static Future<void> cleanOrphans({FluentDbKey? dbKey}) async {
    if (dbKey != null && !_instance._groupedRegistry.containsKey(dbKey.dbName)) throw _databaseNotOpen(dbKey.dbName, 'FluentDb:cleanOrphans');
    for (final MapEntry<String, _FluentProviderIndex> entry in List.of(_instance._groupedRegistry.entries)) {
      if (dbKey != null && entry.key != dbKey.dbName) continue;
      await _instance._cleanOrphans(entry.key, entry.value.all);
    }
  }

  /// What the library found and did in this run: hints grouped by impact (important / medium / small, plus those
  /// derived from the queries measured in earlier runs), automatic changes, warnings and errors nobody received —
  /// each with how to fix it. Muted keys are left out. Print it while optimizing: `debugPrint('${FluentDb.report()}')`.
  static FluentReport report() => FluentAnalyzer().report();

  /// Configures logging; every argument is optional and `null` keeps the current value.
  ///
  /// * [level] — the lowest level shown. Default: [FluentLogLevel.info] in debug / profile builds,
  ///   [FluentLogLevel.warning] in release builds. Use [FluentLogLevel.sql] to see every statement.
  /// * [onRecord] — receives every shown record; issues arrive at the level of their type (`hint`, `autoFix`,
  ///   `warning`, `error`) with `issue` set. To route issues by type use [onIssue].
  /// * [console] — print to the console with `debugPrint` (default `true`).
  /// * [colors] — ANSI colors (default: on for desktop terminals, off on Android / iOS whose consoles print the codes).
  /// * [showSqlArguments] — show SQL arguments and database paths in logs and error texts (default `false`: they
  ///   may contain user data).
  /// * [enabled] — the master switch: `false` silences the log (issues are still published on [onIssue]).
  /// * [mute] — issue keys to drop everywhere (log, [onIssue], [report]); an entry ending in `*` mutes a prefix:
  ///   `{'unordered:*', 'missingIndex:app:logs:*'}`. Every printed issue shows its key. Mute what does not apply to
  ///   your app — the library cannot know everything.
  /// * [removeOnRecord] — `true` removes the [onRecord] sink set earlier (`onRecord: null` keeps it, like every other
  ///   `null`); an [onRecord] given in the same call is set after the removal.
  ///
  /// ```dart
  /// FluentDb.setupLogging(
  ///   level: kDebugMode ? FluentLogLevel.debug : FluentLogLevel.warning,
  ///   onRecord: (r) {
  ///     if (r.level == FluentLogLevel.error) FirebaseCrashlytics.instance.recordError(r.error ?? r.message, r.stackTrace);
  ///   },
  /// );
  /// ```
  static void setupLogging({
    FluentLogLevel? level,
    void Function(FluentLogRecord record)? onRecord,
    bool? console,
    bool? colors,
    bool? showSqlArguments,
    bool? enabled,
    Set<String>? mute,
    bool removeOnRecord = false,
  }) => FluentLog.configure(
    level: level,
    onRecord: onRecord,
    console: console,
    colors: colors,
    showSqlArguments: showSqlArguments,
    enabled: enabled,
    mute: mute,
    removeOnRecord: removeOnRecord,
  );

  /// The global settings in use (`init(config:)`, or the last [configure]).
  static FluentConfig get config => FluentEngine().config;

  /// Replaces the global settings while the app runs, e.g. less maintenance in battery saver:
  /// `FluentDb.configure(const FluentConfig(optimizeInterval: null, trashPurgeInterval: null))`.
  ///
  /// Settings read at `init` (`indexReferences`, `autoRelations`, `fullText`, `readConnections`) take effect on the
  /// next start ([restart]);
  /// the others (mapping, watchdogs, retention, default policy, maintenance intervals) right away.
  ///
  /// An interval that cannot work (zero or negative: `trashPurgeInterval`, `optimizeInterval`, the watchdogs) is
  /// replaced by its default, with a `configFallback` warning.
  static void configure(FluentConfig config) {
    _configEpoch++;
    final FluentConfig safe = _checkedConfig(config);
    _lastFluentConfig = safe;
    FluentEngine().applyConfig(safe);
    _instance._restartTimers(safe);
    // A running init (or restart) ends with the timers of the config it started with: afterwards the timers follow the
    // latest stored config again, so the stored settings and the timers always agree.
    unawaited(_instance._serialized(() async => _instance._restartTimers(_lastFluentConfig), counts: false).catchError((Object _) {}));
  }

  /// [config] with every interval that cannot work replaced by its default (a `configFallback` warning each).
  static FluentConfig _checkedConfig(FluentConfig config) => config.withSafeIntervals((String name, Duration bad, Duration fallback) {
    if (name == 'readConnections') {
      FluentLog.issue(
        FluentIssueKind.configFallback,
        'FluentConfig.readConnections is ${bad.inMilliseconds}; the pool has 0 to 4 connections, so ${fallback.inMilliseconds} is used.',
        subject: name,
        tag: 'FluentDb:config',
        hint: 'Set FluentConfig(readConnections: n) with n from 0 to 4, or null to let the library choose.',
      );
      return;
    }
    if (bad > Duration.zero) {
      FluentLog.issue(
        FluentIssueKind.configFallback,
        'FluentConfig.$name is ${bad.inMicroseconds / 1000} ms; the job would run again as soon as it ends and the library would never be idle, so ${fallback.inSeconds} s is used.',
        subject: name,
        tag: 'FluentDb:config',
        hint: 'Use an interval of at least ${FluentConfig.minMaintenanceInterval.inSeconds} s (the default suits apps), or null to switch it off. '
            'Tests move the library clock instead of waiting: db.clock.advance(...) runs a due timer at once.',
      );
      return;
    }
    FluentLog.issue(
      FluentIssueKind.configFallback,
      'FluentConfig.$name is ${bad.inMilliseconds} ms; a zero or negative interval would run its job without waiting, so the default (${fallback.inSeconds} s) is used.',
      subject: name,
      tag: 'FluentDb:config',
      hint: 'Use a positive Duration, or null to switch it off: FluentConfig($name: null).',
    );
  });

  /// Pauses the task queue of [dbKey] (of every database without it): completes when the running tasks have
  /// finished; later calls wait until [resumeQueue]. Use it before copying the database file (backups).
  ///
  /// **Note:** so the app never hangs, the queue resumes by itself (with a warning) after
  /// [FluentConfig.pauseWatchdog].
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.pauseQueue(dbKey: myDbKey); // Drain active tasks and suspend
  /// await performExternalDbBackup();           // Safe to copy the .db file
  /// FluentDb.resumeQueue(dbKey: myDbKey);      // Resume normal operations
  /// ```
  static Future<void> pauseQueue({FluentDbKey? dbKey}) async => await FluentEngine().pauseQueue(dbName: dbKey?.dbName);

  /// Resumes the task queue paused by [pauseQueue]; the waiting calls run. Call it in a `finally` block.
  ///
  /// **Example:**
  /// ```dart
  /// await FluentDb.pauseQueue();
  /// try {
  ///   await executeCriticalMaintenance();
  /// } finally {
  ///   // Ensure the pipeline is unblocked even if maintenance throws an error
  ///   FluentDb.resumeQueue();
  /// }
  /// ```
  static void resumeQueue({FluentDbKey? dbKey}) => FluentEngine().resumeQueue(dbName: dbKey?.dbName);
}

/// Providers of one database, indexed for O(1) lookups by model type, provider type and table name.
class _FluentProviderIndex {
  final Map<Type, List<FluentProvider>> _byModel = {};
  final Map<Type, List<FluentProvider>> _byProvider = {};
  final Map<String, FluentProvider> _byTable = {};
  final List<FluentProvider> _all = [];

  /// All providers of the database, each exactly once, in registration order.
  List<FluentProvider> get all => List.unmodifiable(_all);

  /// Every provider storing the model type [type] (several when one model lives in several tables).
  List<FluentProvider> allByModel(Type type) => List.unmodifiable(_byModel[type] ?? const <FluentProvider>[]);

  /// Every provider whose runtime type is [type] (several when one provider class serves several tables).
  List<FluentProvider> allByProvider(Type type) => List.unmodifiable(_byProvider[type] ?? const <FluentProvider>[]);

  /// The provider of [table], if registered.
  FluentProvider? byTable(String table) => _byTable[table];

  /// Adds [provider]; `false` when this instance is registered already (nothing changes then).
  bool _add(FluentProvider provider) {
    if (_all.any((p) => identical(p, provider))) return false;
    _byModel.putIfAbsent(provider.modelType, () => []).add(provider);
    _byProvider.putIfAbsent(provider.runtimeType, () => []).add(provider);
    _byTable[provider.tableName] = provider;
    _all.add(provider);
    return true;
  }
}

/// Members the library itself uses (lookups by table / model, task execution, test resets); not part of the public API.
extension FluentDbInternals on FluentDb {
  /// The provider of [tableName] in database [dbName] (any database when `null`); throws when there is none.
  static FluentProvider providerForTable(String tableName, {String? dbName}) => FluentDb._resolveProvider(tableName: tableName, dbName: dbName);

  /// The provider of [tableName] in database [dbName], or `null` (no error, nothing logged).
  static FluentProvider? lookupByTable(String tableName, String dbName) => FluentDb._instance._groupedRegistry[dbName]?.byTable(tableName);

  /// The providers of the open database [dbName] (empty when it is not open).
  static List<FluentProvider> providersOf(String dbName) => FluentDb._instance._groupedRegistry[dbName]?.all ?? const [];

  /// The provider of the model type [type] (in database [dbName] when given); throws when there is none.
  static FluentProvider providerForType(Type type, {String? dbName}) => FluentDb._resolveProvider(modelType: type, dbName: dbName);

  /// The provider of [item] the way `FluentDb.save` / `delete` find it: by its runtime type when that is registered,
  /// else by [T] (the active-record calls on a model use it, so every call of one model reaches the same table).
  static FluentProvider<T> providerForItem<T extends FluentStorable>(T item, {FluentDbKey? dbKey}) => FluentDb._forItem<T>(item, dbKey);

  /// Forgets the registered providers and the last groups without closing anything (tests).
  static void reset() {
    FluentDb._instance._reset();
    FluentDb._lastFluentConfig = const FluentConfig();
  }

  /// Which maintenance timers run now (the trash purge and `PRAGMA optimize` of `FluentConfig`; tests).
  static ({bool purge, bool optimize}) get maintenanceTimers => (purge: FluentDb._instance._trashPurgeTimer != null, optimize: FluentDb._instance._optimizeTimer != null);

  /// Runs [task]: resolves its provider when [provider] is missing or the task names no table, merges the policies
  /// (call → provider → global default) and queues it in the `FluentEngine`, or, inside an open
  /// `FluentDb.transaction` of that database, runs it right away in the transaction.
  static Future<R> executeTask<T, R>({required FluentTask task, FluentProvider? provider}) async {
    // Resolve the provider when the task does not name its table.
    if (provider == null || task.table.isEmpty) {
      if (task.data is FluentStorable) provider = FluentDb._resolveProvider(modelType: task.data.runtimeType, dbName: task.dbName);
      provider ??= FluentDb._resolveProvider(modelType: T, dbName: task.dbName);
    }
    // Policy: call → provider → global default → defaults. One copy of the task carries everything.
    final ExecutionPolicy effectivePolicy = task.policy.merge(provider.policy).merge(FluentEngine().config.defaultPolicy).flatten();
    final FluentTask effectiveData = task.copyWith(table: provider.tableName, dbName: provider.dbName, policy: effectivePolicy);

    // Inside FluentDb.transaction the task runs right away in the open transaction: the transaction holds the
    // database's write slot, so queueing would wait for itself. Change events wait for the commit.
    final FluentTransactionScope? scope = FluentTransactionScope.of(provider.dbName);
    final dynamic result;
    if (scope != null) {
      final List<FluentTouchedTable> touched = [];
      final FluentProvider target = provider;
      result = await scope.serialized(() => scope.working(() => FluentEngine.collectingTouched(touched, () => target.internalExecute(effectiveData)))); // in call order (G7)
      if (effectiveData.isStreamOp) scope.pendingEvents.add((effectiveData, provider, result));
      if (touched.isNotEmpty) scope.pendingTouched.add((effectiveData, provider, touched));
    } else {
      result = await FluentEngine().dispatch(effectiveData);
    }

    return result as R;
  }
}
