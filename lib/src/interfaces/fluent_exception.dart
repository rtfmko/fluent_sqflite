// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// The base abstract class for all framework-specific database exceptions.
///
/// [FluentException] standardizes error reporting across the library by capturing
/// the error context, the original triggering error, and the associated
/// stack trace, ensuring that debugging information is preserved and formatted
/// consistently.
abstract class FluentException implements Exception {
  /// A high-level description of the error.
  final String message;

  /// The underlying error or exception (e.g., SQLite exception) that caused this failure.
  final dynamic originalError;

  /// The stack trace captured at the moment of the exception.
  final StackTrace? stackTrace;

  /// Creates a base [FluentException].
  FluentException(this.message, this.stackTrace, [this.originalError]);

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('[$runtimeType]: $message');

    if (originalError != null) {
      sb.write('\nCause: $originalError');
    }

    return sb.toString();
  }
}
