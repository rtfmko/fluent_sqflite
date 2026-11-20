// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../fluent_sqlite_internal.dart';

/// The queued calls of one database, in call order, indexed for the scheduler ([FluentEngine._processNext]).
///
/// The calls form segments: a write alone, or the reads between two writes. Only the reads of the first segment may
/// start (a write is a barrier); among them the scheduler starts the best by `_readOrder` (aged priority, aged weight,
/// arrival). Reads with equal priority and weight keep their arrival order under that ordering (aging moves them all
/// alike), so a read segment keeps one set per (priority, weight) class ordered by id, and the best read is the best
/// of the class heads: picking costs O(classes · log n) instead of a scan of every waiting read. Queued `findById`
/// calls of one lookup shape are indexed too (one `IN (...)` query answers them all).
///
/// Before this index every finished read scanned, grouped, copied and filtered the whole waiting segment: a burst of
/// thousands of reads that cannot be merged took quadratic time.
class _FluentDbQueue extends Iterable<FluentTask> {
  _FluentDbQueue(this._classOf, this._lookupShapeOf);

  /// The (priority, weight) class of a read.
  final String Function(FluentTask read) _classOf;

  /// The lookup shape of a `findById` read.
  final String Function(FluentTask read) _lookupShapeOf;

  final ListQueue<_FluentQueueSegment> _segments = ListQueue();
  final Map<FluentTask, _FluentReadSegment> _segmentOfRead = Map.identity();
  int _length = 0;

  @override
  int get length => _length;

  @override
  bool get isEmpty => _length == 0;

  @override
  bool get isNotEmpty => _length > 0;

  @override
  Iterator<FluentTask> get iterator => _segments.expand((s) => s.tasks).iterator;

  /// Whether the first queued call is a write.
  bool get headIsWrite => _segments.isNotEmpty && _segments.first is _FluentWriteSegment;

  /// Whether a write that got its id before [id] waits.
  bool hasWriteBefore(int id) {
    for (final _FluentQueueSegment s in _segments) {
      if (s is _FluentWriteSegment) {
        if (s.task.id < id) return true;
        return false; // later writes have larger ids
      }
    }
    return false;
  }

  /// Number of queued writes.
  int get writeCount => _segments.whereType<_FluentWriteSegment>().length;

  /// Appends [task] (call order).
  void add(FluentTask task) {
    _length++;
    if (task.isWriteOp) {
      _segments.add(_FluentWriteSegment(task));
      return;
    }
    final _FluentQueueSegment? last = _segments.isEmpty ? null : _segments.last;
    final _FluentReadSegment segment = last is _FluentReadSegment ? last : (_FluentReadSegment()..also(_segments.add));
    segment.add(task, _classOf(task), task.action == FluentDbAction.findById ? _lookupShapeOf(task) : null);
    _segmentOfRead[task] = segment;
  }

  /// The writes at the head of the queue, in call order (lazily: the scheduler merges only the first few).
  Iterable<FluentTask> get leadingWrites sync* {
    for (final _FluentQueueSegment s in _segments) {
      if (s is! _FluentWriteSegment) return;
      yield s.task;
    }
  }

  /// Removes the first [count] calls, which are writes ([leadingWrites]).
  void removeLeadingWrites(int count) {
    for (int i = 0; i < count; i++) {
      final _FluentQueueSegment s = _segments.removeFirst();
      assert(s is _FluentWriteSegment, 'removeLeadingWrites removed a read');
      _length--;
    }
  }

  /// The reads that may start now (the first segment, when it holds reads), in call order.
  Iterable<FluentTask> get headReads => _segments.isNotEmpty && _segments.first is _FluentReadSegment ? _segments.first.tasks : const [];

  /// The best read of the first segment by [order] (`< 0`: the first argument runs first), or `null`.
  FluentTask? bestHeadRead(int Function(FluentTask a, FluentTask b) order) {
    if (_segments.isEmpty) return null;
    final _FluentQueueSegment head = _segments.first;
    if (head is! _FluentReadSegment) return null;
    FluentTask? best;
    for (final SplayTreeSet<FluentTask> c in head.classes.values) {
      final FluentTask candidate = c.first;
      if (best == null || order(candidate, best) < 0) best = candidate;
    }
    return best;
  }

  /// The queued `findById` reads of [read]'s segment with its lookup shape (at least [read]).
  List<FluentTask> lookupGroupOf(FluentTask read) {
    final _FluentReadSegment? segment = _segmentOfRead[read];
    if (segment == null || read.action != FluentDbAction.findById) return [read];
    return segment.lookups[_lookupShapeOf(read)]?.toList() ?? [read];
  }

  /// Number of queued `findById` reads of [read]'s lookup shape in its segment.
  int lookupGroupSize(FluentTask read) {
    final _FluentReadSegment? segment = _segmentOfRead[read];
    if (segment == null || read.action != FluentDbAction.findById) return 1;
    return segment.lookups[_lookupShapeOf(read)]?.length ?? 1;
  }

  /// Removes [task] wherever it waits; `false` when it is not queued.
  bool remove(Object? task) {
    if (task is! FluentTask) return false;
    final _FluentReadSegment? segment = _segmentOfRead.remove(task);
    if (segment != null) {
      segment.remove(task, _classOf(task), task.action == FluentDbAction.findById ? _lookupShapeOf(task) : null);
      _length--;
      if (segment.isEmpty) _segments.remove(segment);
      return true;
    }
    for (final _FluentQueueSegment s in _segments) {
      if (s is _FluentWriteSegment && identical(s.task, task)) {
        _segments.remove(s);
        _length--;
        return true;
      }
    }
    return false;
  }

  /// Moves [read] to its class after its priority changed ([oldClass]: the class it was filed under).
  void reclassify(FluentTask read, String oldClass) {
    final _FluentReadSegment? segment = _segmentOfRead[read];
    if (segment == null) return;
    final String now = _classOf(read);
    if (now == oldClass) return;
    segment.moveClass(read, oldClass, now);
  }

  /// Removes every call.
  void clear() {
    _segments.clear();
    _segmentOfRead.clear();
    _length = 0;
  }
}

sealed class _FluentQueueSegment {
  Iterable<FluentTask> get tasks;
}

class _FluentWriteSegment extends _FluentQueueSegment {
  _FluentWriteSegment(this.task);

  final FluentTask task;

  @override
  Iterable<FluentTask> get tasks => [task];
}

class _FluentReadSegment extends _FluentQueueSegment {
  /// Every read, in call order.
  final LinkedHashSet<FluentTask> all = LinkedHashSet.identity();

  /// The reads by (priority, weight) class, each ordered by id (= arrival).
  final Map<String, SplayTreeSet<FluentTask>> classes = {};

  /// The `findById` reads by lookup shape, in call order.
  final Map<String, LinkedHashSet<FluentTask>> lookups = {};

  @override
  Iterable<FluentTask> get tasks => all;

  bool get isEmpty => all.isEmpty;

  static int _byId(FluentTask a, FluentTask b) => a.id.compareTo(b.id);

  void add(FluentTask task, String cls, String? lookup) {
    all.add(task);
    (classes[cls] ??= SplayTreeSet<FluentTask>(_byId)).add(task);
    if (lookup != null) (lookups[lookup] ??= LinkedHashSet.identity()).add(task);
  }

  void remove(FluentTask task, String cls, String? lookup) {
    all.remove(task);
    final SplayTreeSet<FluentTask>? c = classes[cls];
    if (c != null && c.remove(task) && c.isEmpty) classes.remove(cls);
    if (lookup != null) {
      final LinkedHashSet<FluentTask>? l = lookups[lookup];
      if (l != null && l.remove(task) && l.isEmpty) lookups.remove(lookup);
    }
  }

  void moveClass(FluentTask task, String from, String to) {
    final SplayTreeSet<FluentTask>? c = classes[from];
    if (c == null || !c.remove(task)) return;
    if (c.isEmpty) classes.remove(from);
    (classes[to] ??= SplayTreeSet<FluentTask>(_byId)).add(task);
  }

  /// Runs [f] with this segment (chaining in a conditional expression).
  _FluentReadSegment also(void Function(_FluentReadSegment s) f) {
    f(this);
    return this;
  }
}
