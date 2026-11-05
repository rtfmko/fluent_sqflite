// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:async';

/// Stops a running `syncWithServer` from outside: pass it as `cancel:`, then call [cancel] (a screen that closes, a
/// sign-out, a user tapping "Stop").
///
/// The sync stops at once: an answer of `onPush` / `onPull` that is still on its way is no longer waited for and is
/// ignored when it arrives, and no further batch or page is asked for. What was stored before stays (pushed batches
/// stay synced, pulled pages stay stored); a pull that did not reach its last page does not move its `since`, so the
/// next sync asks for those changes again. The result has `isCancelled: true`; a cancelled sync is not retried and
/// not logged as a failure. One token can cancel several syncs; a cancelled token stays cancelled.
///
/// ```dart
/// final FluentCancelToken token = FluentCancelToken();
/// final Future<FluentSyncResult<Todo>> sync = todos.syncWithServer(onPush: push, onPull: pull, cancel: token);
/// // later, e.g. in dispose():
/// token.cancel();
/// final FluentSyncResult<Todo> result = await sync; // result.isCancelled
/// ```
class FluentCancelToken {
  /// Creates a token that is not cancelled yet.
  FluentCancelToken();

  final Completer<void> _cancelled = Completer<void>();

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  /// Cancels every sync that uses this token; calling it again does nothing.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
