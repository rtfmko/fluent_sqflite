import 'package:fluent_sqflite/src/internal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExecutionPolicy equality', () {
    test('policies with the same values are equal and share a hashCode', () {
      const a = ExecutionPolicy(priority: 1, cancelIfDuplicate: false);
      // ignore: prefer_const_constructors
      final b = ExecutionPolicy(priority: 1, cancelIfDuplicate: false);

      expect(b, equals(a));
      expect(b.hashCode, a.hashCode);
    });

    test('a non-const empty policy equals the const default', () {
      // ignore: prefer_const_constructors
      expect(ExecutionPolicy(), equals(const ExecutionPolicy()));
    });

    test('policies differing in any field are not equal', () {
      const base = ExecutionPolicy(priority: 1);
      expect(base, isNot(equals(const ExecutionPolicy(priority: 2))));
      expect(base, isNot(equals(const ExecutionPolicy(priority: 1, cancelIfDuplicate: true))));
    });
  });

  group('ExecutionPolicy resolution', () {
    test('flatten fills every field from the defaults', () {
      final flat = const ExecutionPolicy().flatten();
      expect(flat.priority, 0);
      expect(flat.cancelIfDuplicate, isTrue);
    });

    test('merge keeps own values and takes the rest from the parent', () {
      const own = ExecutionPolicy(priority: 5);
      const parent = ExecutionPolicy(priority: 1, cancelIfDuplicate: false);

      final merged = own.merge(parent);

      expect(merged, const ExecutionPolicy(priority: 5, cancelIfDuplicate: false));
      expect(own.merge(null), same(own));
    });
  });
}
