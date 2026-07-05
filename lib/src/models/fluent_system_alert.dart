// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file

import '../interfaces/interfaces.dart';

/// Represents a critical system-level notification triggered by the engine.
///
/// **Role:**
/// Used by the [FluentEngine] to propagate internal failures, watchdog alerts,
/// or system anomalies to the observation layer (e.g., Sentry, Crashlytics, or
/// custom debug dashboards) via the [alertStream].
class FluentSystemAlert {
  /// A human-readable description of the error or event.
  final String message;

  /// A category or module identifier.
  final String tag;

  /// Optional metadata providing additional diagnostic context for the alert.
  final Map<String, dynamic>? context;

  /// The associated exception, if the alert was triggered by a runtime failure.
  final FluentException? exception;

  /// Creates a new system alert.
  ///
  /// [message] - The primary alert text.
  /// [tag] - The category identifier for filtering logs/telemetry.
  /// [context] - Key-value pairs for debugging state.
  /// [exception] - The optional source exception.
  FluentSystemAlert({required this.message, required this.tag, this.context, this.exception});

  @override
  String toString() {
    return 'FluentSystemAlert{message: $message, tag: $tag, context: $context, exception: $exception}';
  }
}
