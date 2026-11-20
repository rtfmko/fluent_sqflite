// Raw views of a database file for the schema guarantee tests (G4, G5, G21, G31): what is in the file, read with a
// separate connection, so a test sees exactly what the library left behind.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens `<databases dir>/<name>.db` with its own connection (read only: it cannot change the file).
Future<Database> openRaw(String name, {bool readOnly = true}) async =>
    databaseFactoryFfi.openDatabase('${await getDatabasesPath()}/$name.db', options: OpenDatabaseOptions(singleInstance: false, readOnly: readOnly));

/// Every table of the file with its SQL and rows (ordered by rowid), plus the indexes / triggers / views, as plain
/// data that compares with `==` through [dumpText]. [skip] names tables left out (e.g. the stats written on close).
Future<Map<String, Object?>> dumpFile(String name, {Set<String> skip = const {'__fluent_stats'}, bool readOnly = true}) async {
  final Database raw = await openRaw(name, readOnly: readOnly);
  try {
    return await dumpDatabase(raw, skip: skip);
  } finally {
    await raw.close();
  }
}

/// [dumpFile] of an open [db].
Future<Map<String, Object?>> dumpDatabase(Database db, {Set<String> skip = const {'__fluent_stats'}}) async {
  final Map<String, Object?> out = {};
  for (final Map<String, Object?> r in await db.rawQuery("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name")) {
    final String name = r['name']! as String;
    if (skip.contains(name) || skip.contains(r['tbl_name'])) continue;
    if (r['type'] == 'table') {
      List<Map<String, Object?>> rows;
      try {
        rows = await db.rawQuery('SELECT * FROM "$name" ORDER BY rowid');
      } on DatabaseException {
        rows = await db.rawQuery('SELECT * FROM "$name"');
      }
      out['table:$name'] = {'sql': r['sql'], 'rows': rows};
    } else {
      out['${r['type']}:$name'] = r['sql'];
    }
  }
  return out;
}

/// A text form of [dump] for equality checks and failure messages.
String dumpText(Map<String, Object?> dump) => [for (final MapEntry<String, Object?> e in dump.entries) '${e.key}: ${e.value}'].join('\n');

/// The first difference between two dumps as one line, or `null` when equal (for readable failures).
String? dumpDiff(Map<String, Object?> before, Map<String, Object?> after) {
  for (final String k in {...before.keys, ...after.keys}) {
    if (!before.containsKey(k)) return 'new: $k = ${after[k]}';
    if (!after.containsKey(k)) return 'gone: $k (was ${before[k]})';
    if ('${before[k]}' != '${after[k]}') return 'changed: $k\n  before: ${before[k]}\n  after:  ${after[k]}';
  }
  return null;
}

/// Column names of [table] in file order.
Future<List<String>> columnNames(Database db, String table) async => [for (final Map<String, Object?> r in await db.rawQuery('PRAGMA table_info("$table")')) r['name']! as String];

/// Names of the user tables (without `sqlite_` ones).
Future<List<String>> tableNames(Database db) async =>
    [for (final Map<String, Object?> r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) r['name']! as String];

/// The archived columns (`__fluent_removed_*`) of [table].
Future<List<String>> archivedColumns(Database db, String table) async => [for (final String c in await columnNames(db, table)) if (c.startsWith('__fluent_removed_')) c];

/// Quarantine tables (`__fluent_rejected_<table>_r*`) of [table].
Future<List<String>> quarantineTables(Database db, String table) async => [for (final String t in await tableNames(db)) if (t.startsWith('__fluent_rejected_${table}_r')) t];

/// Every value of [row] as text (null skipped), for "the value is somewhere in the row" checks.
Set<String> valuesOf(Map<String, Object?> row) => {for (final Object? v in row.values) if (v != null) _norm(v)};

String _norm(Object v) => v is double && v == v.truncateToDouble() ? v.toInt().toString() : '$v';

/// Normalizes a stored value for comparisons across storage classes (`5`, `5.0` and `'5'` are the same).
String normValue(Object? v) => v == null ? 'NULL' : _norm(v);
