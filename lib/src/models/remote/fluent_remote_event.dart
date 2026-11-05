// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../../utils/utils.dart';

/// One state of `watchRemote`: the rows to show and where they stand.
///
/// ```dart
/// StreamBuilder<FluentRemoteEvent<Post>>(
///   stream: posts.watchRemote(fetch: () async => FluentRemoteResponse(await api.posts())),
///   builder: (context, s) {
///     final FluentRemoteEvent<Post>? e = s.data;
///     if (e == null || (e.isEmpty && e.isFetching)) return const CircularProgressIndicator();
///     return PostList(e.items, refreshing: e.isFetching, error: e.error);
///   },
/// );
/// ```
@immutable
class FluentRemoteEvent<T> {
  /// Creates an event (by the library).
  @internal
  const FluentRemoteEvent({required this.phase, this.items = const [], this.error});

  /// Cached, fetching, fresh or failed.
  final FluentRemotePhase phase;

  /// The rows to show: the cache, or once [phase] is [FluentRemotePhase.fresh] the stored answer (with
  /// `store: none` the fetched rows themselves).
  final List<T> items;

  /// Why the fetch or storing failed ([FluentRemotePhase.failed]); later events of the stream keep it.
  final Object? error;

  /// Whether `fetch` is running (show a refresh indicator over [items]).
  bool get isFetching => phase == FluentRemotePhase.fetching;

  /// Whether [items] reflect the server's answer.
  bool get isFresh => phase == FluentRemotePhase.fresh;

  /// Whether the fetch or storing failed.
  bool get hasError => phase == FluentRemotePhase.failed;

  /// Whether there are no rows.
  bool get isEmpty => items.isEmpty;

  @override
  String toString() => 'FluentRemoteEvent(${phase.name}, ${items.length} item(s)${error == null ? '' : ', error: $error'})';
}
