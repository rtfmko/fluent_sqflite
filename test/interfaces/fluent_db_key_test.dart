// FluentDbKey(name): value equality, hash and text, usable as a map key.
import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpFluentTests();

  test('keys of the same name are equal, share a hash and work as map keys', () {
    final FluentDbKey a = FluentDbKey('cache_db');
    final FluentDbKey b = FluentDbKey('cache_db');
    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
    expect(a == a, isTrue);
    expect(a == FluentDbKey('other'), isFalse);
    expect(a == ('cache_db' as Object), isFalse);
    expect({a: 1}[b], 1);
    expect({a, b}, hasLength(1));
  });

  test('toString is the database name', () {
    expect(FluentDbKey('cache_db').toString(), 'cache_db');
    expect(FluentDbKey('cache_db').dbName, 'cache_db');
  });
}
