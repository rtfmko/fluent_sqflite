// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../core/fluent_sqlite_internal.dart';
import '../exceptions/exceptions.dart';

/// The base class of every error thrown by fluent_sqflite.
///
/// Each error says **what** went wrong ([message]), **how to fix it** ([hint]) and carries a stable [code] for
/// handling it in code or showing a localized text in the UI. The error that caused it (usually a SQLite error)
/// stays attached as [cause].
///
/// ```dart
/// try {
///   await users.save(user);
/// } on FluentConstraintException catch (e) {
///   if (e.code == FluentErrorCode.uniqueViolation) showSnackBar('This e-mail is already taken');
/// }
/// ```
abstract class FluentException implements Exception {
  /// Creates an error; [stackTrace] defaults to the current one.
  FluentException(this.message, {required this.code, this.hint, this.cause, StackTrace? stackTrace}) : stackTrace = stackTrace ?? StackTrace.current;

  /// What went wrong (and why, when it is known).
  final String message;

  /// A stable identifier of the kind of error, e.g. for UI texts or localization.
  final FluentErrorCode code;

  /// How to fix it, often with code to copy.
  final String? hint;

  /// The underlying error (e.g. the SQLite error), if any.
  final Object? cause;

  /// Where the error happened.
  final StackTrace stackTrace;

  /// Set once the error was logged, so it is logged only once on its way to the caller.
  @internal
  bool reported = false;

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('$runtimeType(${code.name}): $message');
    if (hint != null) sb.write('\n  Hint: $hint');
    if (cause != null) sb.write('\n  Cause: ${FluentLog.redact('$cause')}');
    return sb.toString();
  }
}
