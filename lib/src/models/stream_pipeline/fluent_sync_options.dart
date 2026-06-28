// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/utils.dart';

/// Configuration options for the [reactiveSync] pipeline.
///
/// This class encapsulates all parameters governing the synchronization lifecycle,
/// including execution strategies, merge logic, relational behavior, and error handling.
///
/// ### Example
/// ```dart
/// final FluentSyncOptions options = FluentSyncOptions<User>(
///   executionStrategy: FluentExecutionStrategy.cacheThenApiYieldThenSave,
///   mergeStrategy: FluentMergeStrategy.syncDeletions,
///   retryCount: 3,
///   baseRetryBackoff: Duration(seconds: 1),
///   statusBehaviors: {
///     401: FluentApiErrorBehavior.clearCacheAndYieldError,
///     404: FluentApiErrorBehavior.preserveCacheAndComplete,
///   },
///   beforeSave: (items) async {
///     // Perform custom logic, e.g., mapping or filtering
///     return items.map((e) => e.copyWith(syncedAt: DateTime.now())).toList();
///   },
/// );
/// ```
class FluentSyncOptions<T> {
  /// Defines how the pipeline orchestrates data delivery between cache, API, and persistence.
  final FluentExecutionStrategy executionStrategy;

  /// Determines how incoming API data is reconciled with existing local records.
  final FluentMergeStrategy mergeStrategy;

  /// Specifies the action to take when the API returns an empty collection.
  final FluentEmptyApiBehavior emptyApiBehavior;

  /// The default behavior for handling API errors or unexpected status codes.
  final FluentApiErrorBehavior defaultErrorBehavior;

  /// Governs how nested relational entities are merged during synchronization.
  final FluentRelationSyncMode relationSyncMode;

  /// Custom error behaviors mapped to specific HTTP status codes.
  ///
  /// Use this to override the [defaultErrorBehavior] for specific scenarios,
  /// such as clearing cache on 401 Unauthorized or ignoring 404s.
  final Map<int, FluentApiErrorBehavior>? statusBehaviors;

  /// Callback executed upon a successful synchronization lifecycle completion.
  final void Function(List<T>)? onSuccess;

  /// Callback executed when a terminal error occurs during the pipeline process.
  final void Function(Object, StackTrace)? onError;

  /// A hook for data transformation/manipulation before persisting to the database.
  ///
  /// Returning a modified list allows for last-minute adjustments before the
  /// transaction is committed.
  final Future<List<T>> Function(List<T>)? beforeSave;

  /// Maximum number of automatic retries for failed network requests.
  ///
  /// The pipeline will re-attempt the [fetchFromApi] call this many times
  /// before falling back to [defaultErrorBehavior].
  final int retryCount;

  /// HTTP status codes considered as successful responses.
  ///
  /// If the API returns a status not present in this set, it is treated as an error.
  final Set<int> validStatusCodes;

  /// The base duration for exponential backoff between retry attempts.
  ///
  /// The delay between retries is calculated as:
  /// `baseRetryBackoff * (2 ^ attemptNumber)`.
  final Duration baseRetryBackoff;

  /// If `true`, filters cache for non-expired and non-deleted records.
  final bool loadOnlyValidCache;

  /// Max rows to return from cache; `null` for unlimited.
  final int? limit;

  /// Hydration depth for nested relations.
  final int maxDepth;

  /// Expiration-based sorting direction.
  final SortDirection? sortDirection;

  /// If `true`, loads all relations immediately, bypassing lazy-loading.
  final bool ignoreLazy;

  /// Creates a [FluentSyncOptions] instance with defined synchronization behavior.
  ///
  /// The pipeline processes the request as follows:
  /// 1. Executes [fetchFromApi] with [retryCount] logic if failures occur.
  /// 2. If a status code is returned, it is checked against [validStatusCodes].
  /// 3. If invalid, the strategy defined in [statusBehaviors] or [defaultErrorBehavior] is applied.
  /// 4. Upon success, [beforeSave] is invoked for data transformation.
  /// 5. Finally, the data is persisted using [mergeStrategy] and [relationSyncMode].
  ///
  /// *Note: All callbacks ([onSuccess], [onError]) are non-blocking and do not
  /// interrupt the primary data flow.*
  const FluentSyncOptions({
    this.executionStrategy = FluentExecutionStrategy.cacheThenApiYieldThenSave,
    this.mergeStrategy = FluentMergeStrategy.upsert,
    this.emptyApiBehavior = FluentEmptyApiBehavior.preserveCache,
    this.defaultErrorBehavior = FluentApiErrorBehavior.yieldError,
    this.relationSyncMode = FluentRelationSyncMode.preserveLocal,
    this.statusBehaviors,
    this.onSuccess,
    this.onError,
    this.beforeSave,
    this.retryCount = 0,
    this.validStatusCodes = const {200, 201, 202, 204},
    this.baseRetryBackoff = const Duration(milliseconds: 500),
    this.loadOnlyValidCache = false,
    this.limit,
    this.maxDepth = 1,
    this.sortDirection,
    this.ignoreLazy = false,
  });
}
