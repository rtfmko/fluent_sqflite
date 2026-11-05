// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

// Retry timing shared by `syncWithServer` and `watchRemote`.

import 'dart:math' as math;

import '../exceptions/exceptions.dart';

final math.Random _jitter = math.Random();

/// The wait before retry number [attempt] (from 0): [base] doubled per attempt, ±50 % at random, so many devices do
/// not retry at the same moment; never longer than [fluentMaxRetryDelay] (and finite for any attempt).
Duration fluentRetryDelay(Duration base, int attempt) {
  final Duration delay = base * (math.pow(2, attempt.clamp(0, 30)) * (0.5 + _jitter.nextDouble()));
  return delay > fluentMaxRetryDelay ? fluentMaxRetryDelay : delay;
}

/// The longest wait between two retries.
const Duration fluentMaxRetryDelay = Duration(hours: 1);

/// Whether asking again can help: not for client errors (HTTP 4xx) other than 408 (timeout) and 429 (rate limit).
bool fluentRetryCanHelp(Object? error) {
  final int? status = error is FluentSyncException ? error.statusCode : null;
  return status == null || status < 400 || status >= 500 || status == 408 || status == 429;
}
