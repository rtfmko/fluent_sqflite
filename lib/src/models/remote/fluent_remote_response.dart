// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// What `fetch` / `fetchPage` of `watchRemote` returns: the rows, or the status of a failed request.
///
/// ```dart
/// fetch: () async {
///   final http.Response res = await http.get(Uri.parse('https://api.example.com/posts'));
///   if (res.statusCode != 200) return FluentRemoteResponse.failed(res.statusCode, res.body);
///   return FluentRemoteResponse([for (final Object? e in jsonDecode(res.body) as List) Post.fromJson(e! as Map<String, dynamic>)]);
/// },
/// ```
///
/// Throwing from `fetch` works too (the error is reported in a `failed` event); return [FluentRemoteResponse.failed]
/// when the status matters (`clearCacheOn`, no retry on 4xx). A big answer comes in pages: set [hasMore] and [cursor]
/// (see `fetchPage`).
class FluentRemoteResponse<T> {
  /// The rows the server returned. With [hasMore], this is one page and `fetchPage` is called again with [cursor].
  const FluentRemoteResponse(this.items, {this.statusCode = 200, this.hasMore = false, this.cursor}) : error = null;

  /// One row (none when [item] is `null`).
  FluentRemoteResponse.single(T? item, {this.statusCode = 200}) : items = [?item], error = null, hasMore = false, cursor = null;

  /// The request failed with HTTP [statusCode]; [error] is kept as the cause.
  const FluentRemoteResponse.failed(this.statusCode, [this.error]) : items = const [], hasMore = false, cursor = null;

  /// The rows the server returned.
  final List<T> items;

  /// The HTTP status of the answer; 200–299 count as success.
  final int statusCode;

  /// What the server or the client said about a failure.
  final Object? error;

  /// Whether more pages follow: `fetchPage` is called again with [cursor]. Each page is stored when it arrives;
  /// `mirror` / `replace` delete cached rows only after the last page.
  final bool hasMore;

  /// Where the next page starts (any value your API understands), passed back in `FluentRemoteRequest.cursor`.
  final Object? cursor;

  /// Whether the request succeeded ([statusCode] 200–299).
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}
