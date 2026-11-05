// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// How a call is scheduled: its priority among the reads that may run, and whether an identical read in flight may
/// answer it. Unset values come from the provider's `policy`, then from `FluentConfig.defaultPolicy`.
///
/// There is deliberately no timeout: a database operation that was started is never abandoned (an abandoned write
/// may still commit), and a call never fails just because the queue was busy.
///
/// ```dart
/// await FluentDb.find<Message>(where: FluentFilter.eq('read', false), policy: ExecutionPolicy.fast); // the UI waits for it
/// await FluentDb.find<Message>(where: FluentFilter.eq('archived', true), policy: ExecutionPolicy.background); // prefetch
/// ```
class ExecutionPolicy {
  /// Creates a policy; unset values are inherited.
  const ExecutionPolicy({this.priority, this.cancelIfDuplicate});

  /// Importance among the reads that may run now (higher runs earlier; default 0). A waiting read gains one point per
  /// second, so low priorities never starve; an identical read that joins a queued one raises it to the higher of
  /// both. Writes always keep call order.
  final int? priority;

  /// Whether an identical read already in flight (no write called between them) may answer this call (default
  /// `true`). A collapsed read gets its own list, but the same model instances as the read that answered it.
  final bool? cancelIfDuplicate;

  /// Reads the UI waits for: they run before other queued reads.
  static const fast = ExecutionPolicy(priority: 10);

  /// Work nobody waits for (prefetch, clean-ups, big imports): runs after other queued reads.
  static const background = ExecutionPolicy(priority: -10);

  /// Always run the query itself, never answered by an identical read already in flight.
  static const fresh = ExecutionPolicy(cancelIfDuplicate: false);

  @override
  bool operator ==(Object other) => identical(this, other) || other is ExecutionPolicy && priority == other.priority && cancelIfDuplicate == other.cancelIfDuplicate;

  @override
  int get hashCode => Object.hash(priority, cancelIfDuplicate);

  @override
  String toString() {
    final List<String> parts = [
      if (priority != null) 'priority: $priority',
      if (cancelIfDuplicate != null) 'cancelIfDuplicate: $cancelIfDuplicate',
    ];
    return 'ExecutionPolicy{${parts.join(', ')}}';
  }
}
