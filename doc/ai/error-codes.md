# Error codes

Version: 2.0.0. Every fluent_sqflite error is a `FluentException` with a stable `code` (`FluentErrorCode`), a `message`,
a `hint` (the fix, often with code) and the original error as `cause`. Read the `hint` first: it is specific to the
call. This table is the general meaning of each code. Errors always arrive through the returned `Future` / `Stream`.

| Code | Class | Meaning | Typical cause | Fix |
|---|---|---|---|---|
| `notInitialized` | `FluentConfigException` | the database was used before `FluentDb.init` finished | a call in `main` before `await FluentDb.init(...)`, or a provider missing from every group | `await FluentDb.init([...])` before any call; add the provider to a `FluentGroup` |
| `invalidDatabaseName` | `FluentConfigException` | the database name is not a valid file name | `FluentDbKey('my-db')` | use letters, digits and `_` only |
| `databaseNotFound` | `FluentConfigException` | the file of a read-only group is missing | `readOnly: true` without the prebuilt file | copy the file to `FluentGroup.resolvePath()` before init, or set `readOnly: false` |
| `databaseNotOpen` | `FluentConfigException` | a call names a database (`dbKey`) that is not open | a `dbKey` that was never passed to `init`; a typo; the database was closed (`FluentDb.close`) or deleted with `reopen: false`; `FluentDb.clear` / `transaction` / `deleteDatabases` on it | pass the key of an initialized group (the hint lists the open ones); `await FluentDb.init([...])` or `FluentDb.restart()` first |
| `databaseCorrupt` | `FluentConfigException` (at `init`), `FluentQueryException` (later) | SQLite reports the file as damaged or not a database (`SQLITE_NOTADB` / `SQLITE_CORRUPT`) | a truncated or overwritten file; a bad restore; a failing disk | restore a backup; or `FluentGroup(resetOnSchemaError: true)` starts empty (all data in the file is lost; the library never deletes the file on its own) |
| `providerNotFound` | `FluentConfigException` | no provider is registered for the model / table | `FluentDb.find<Note>()` with no `NoteProvider` in `init` | add the provider to a group |
| `ambiguousProvider` | `FluentConfigException` | the type is registered in several databases or tables | one model in two groups; one model stored by two providers | pass `dbKey:`; call the provider itself (`notesArchive.find()`) |
| `invalidConfiguration` | `FluentConfigException` | any other setup mistake | — | follow the hint |
| `schemaConflict` | `FluentSchemaException` | the model contradicts itself or the stored schema | a field `null` in `modelSample`; a converter that cannot read a stored value; `fromCacheJson` reading a wrong type | give the sample non-null values or declare `missingColumns`; read the types listed in the message |
| `migrationRefused` | `FluentSchemaException` | `FluentGroup.onMigrationPlan` returned `false`; nothing was changed | the plan drops data or rebuilds a table the callback does not allow | read the plan in the hint; allow it (a release that may drop the data) or change the model |
| `migrationFailed` | `FluentSchemaException` | a migration step failed; the whole start was rolled back | invalid `rawSql`; `onMigrate` threw | fix the step (the database is unchanged); never edit an applied step, add a new one |
| `invalidArgument` | `FluentArgumentException` | an argument is not valid | unknown column in `updateById` / `conflictOn` / `orderBy`; `rawQuery` with `INSERT` | use column names of the table; use `execute` for writes |
| `invalidKey` | `FluentArgumentException` | the key does not identify a row | a plain value for a composite key; `null` key | pass `FluentKey({...})` or `model.key` |
| `unsupportedValue` | `FluentArgumentException` | SQLite cannot store the value | an object or a `DateTime` inside a `Map` / `List` field | convert it in `buildJson`, or attach a `FluentConverter` |
| `uniqueViolation` | `FluentConstraintException` | another row has the value of a UNIQUE column / key | saving a duplicate e-mail; a server row with a new id but an existing unique value | update that row, or `save(x, conflictOn: ['email'])` |
| `foreignKeyViolation` | `FluentConstraintException` | the referenced row does not exist | saving a child before its owner | save the owner first, or save the graph through the relation |
| `notNullViolation` | `FluentConstraintException` | a NOT NULL column got no value | a field missing from `buildJson` | give it a value or a `defaultValue` |
| `checkViolation` | `FluentConstraintException` | a value breaks a CHECK constraint | out-of-range data | fix the value; check the model's `checks` |
| `readOnly` | `FluentQueryException` | a write on a read-only database | `FluentGroup(readOnly: true)`; a `PRAGMA x = y` through `rawQuery` | open a writable group; use `execute` for statements that change data |
| `noSuchTable` | `FluentQueryException` | the table does not exist | a typo in raw SQL; a provider not registered | check the SQL; register the provider |
| `sqlError` | `FluentQueryException` | SQLite rejected the statement | a syntax error or unknown column in a raw filter / `rawQuery` | fix the SQL (the SQLite message is the `cause`) |
| `invalidRelation` | `FluentRelationException` | a relation is declared or used incorrectly | wrong generic types; unknown relation name in `attach` | declare `FluentRelation<Owner, Target>`; use a declared name |
| `syncNotSupported` | `FluentSyncException` | the provider does not sync | `syncWithServer` on a provider without `FluentSyncable` | add `with FluentSyncable<T>` |
| `apiError` | `FluentSyncException` | the API answered with an error status (`statusCode`) | 401 / 500 from `fetch` of `watchRemote` | the `failed` event carries it; `clearCacheOn: {401}` also removes the cached rows |
| `syncFailed` | `FluentSyncException` | a sync step failed | a callback threw; network error | nothing local was lost; retry later |
| `syncCancelled` | `FluentCancelledException` | a sync was stopped by its `FluentCancelToken` | `token.cancel()` while it ran | in the result (`isCancelled`), never thrown; what was stored stays, the rest comes with the next sync |
| `engineClosed` | `FluentCancelledException` | the call came while the databases were closed | a call after `FluentDb.close()` | call `init` again; await calls before closing |
| `deadlock` | `FluentEngineException` | the call was refused: it would close a wait cycle between databases (a transaction holding A waits for B while B's transaction waits for A) | a transaction on A calls `FluentDb.transaction(dbKey: B)` / a B call while a transaction on B calls into A (also A → B → C → A) | take the databases in one order everywhere, or make the cross-database call after the transaction; let the error leave the body (it rolls back) and run it again |
| `databaseBusy` | `FluentEngineException` | a sync read waited longer than `FluentConfig.committedReadTimeout` (30 s) for a transaction on its database and was not run (sync never reads uncommitted data) | a long transaction (an import) while `syncWithServer` / `watchRemote` runs; a transaction that awaits a sync started outside it | transient, nothing lost: sync with `retries`, or call the sync inside the transaction or after it; keep transactions short or raise `committedReadTimeout` |
| `engineError` | `FluentEngineException` | an unexpected internal failure | a bug | report it with the message and `cause` |

```dart
try {
  await users.save(user);
} on FluentException catch (e) {
  switch (e.code) {
    case FluentErrorCode.uniqueViolation:
      showError('Already taken');
    case FluentErrorCode.engineClosed:
      break; // app is shutting down
    default:
      rethrow;
  }
}
```
