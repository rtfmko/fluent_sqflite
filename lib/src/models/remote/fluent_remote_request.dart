// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// What `fetchPage` of `watchRemote` is asked for: one page of the server's answer.
///
/// ```dart
/// fetchPage: (request) async {
///   final Map<String, dynamic> json = await api.posts(after: request.cursor as String?);
///   return FluentRemoteResponse(
///     [for (final Object? e in json['items'] as List) Post.fromJson(e! as Map<String, dynamic>)],
///     hasMore: json['next'] != null,
///     cursor: json['next'],
///   );
/// },
/// ```
@immutable
class FluentRemoteRequest {
  /// Creates a request (by the library).
  @internal
  const FluentRemoteRequest({this.cursor, this.page = 0});

  /// The `cursor` of the previous page when it said `hasMore`; `null` for the first page.
  final Object? cursor;

  /// The number of this page in the fetch, from 0.
  final int page;

  @override
  String toString() => 'FluentRemoteRequest(page: $page${cursor == null ? '' : ', cursor: $cursor'})';
}
