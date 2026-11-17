---
name: fluent-sqflite-troubleshooting
description: >-
  Use when the user hits a fluent_sqflite error or warning, or wants to debug or speed up database code:
  FluentException and FluentErrorCode, FluentIssue (hints, automatic changes, warnings) and onIssue, FluentDb.report,
  setupLogging / onRecord / mute, FluentDiagnostics and the tuner, slow queries, janky lists, isolateFactory, read
  connections, engineStats and FluentBenchmark.
license: Apache-2.0
metadata:
  package: fluent_sqflite
  version: "2.0.0"
---

# fluent_sqflite: errors, logs and performance

## Rules

- Every error is a `FluentException` with `code`, `message`, `hint` and `cause`. **Apply the `hint`**: it names the
  exact fix for that call. Look the code up in [references/error-codes.md](references/error-codes.md).
- Branch on `e.code` (`FluentErrorCode`), never on the message text.
- Do not catch `DatabaseException` around fluent_sqflite calls: SQLite errors are wrapped in typed exceptions.
- Everything else is a `FluentIssue` (`kind`, `type`, `title`, `details`, `fix`, `code`, `key`), listed in
  [references/issues.md](references/issues.md): `hint` (optimization with code to copy — apply it), `autoFix` (the
  library changed something by itself — read it), `warning` (the code or setup is wrong, a safe fallback was used —
  fix it), `error` (a background failure).
- The library never crashes over a wrong call or setting: it falls back and reports an issue. Do not wrap calls in
  try / catch to hide warnings; fix what the `fix` says, or mute the key when it does not apply.
- Turn on details only while debugging: `FluentDb.setupLogging(level: FluentLogLevel.debug)` (`sql` shows statements;
  arguments and paths (`<path hidden>`) stay hidden unless `showSqlArguments: true`). `setupLogging(removeOnRecord: true)`
  removes the `onRecord` sink (`onRecord: null` keeps it). `storedFormatAdopted` is an `autoFix`: values written by an
  earlier version were converted once at start; nothing to do.

- `FluentLogRecord.error` / `FluentIssue.error` of a foreign error is a `FluentRedactedError` (`type`, redacted
  `message`) unless `FluentLog.showSqlArguments` is on; send that to crash reporters.

- `brokenTrigger`: drop and recreate the trigger with SQL that uses the current columns (the issue has both).
  `legacyNameAdopted`: a 1.x table / column got its 2.0 name, nothing to do. `precisionLost`: use iso8601 or round to
  milliseconds. `batchKeysMismatch`: a key matched in another form (case-insensitive); set `batchKeys: fromModels` if
  it is frequent.

## Logging

```dart
FluentDb.setupLogging(
  level: kDebugMode ? FluentLogLevel.info : FluentLogLevel.warning,
  onRecord: (FluentLogRecord r) {
    if (r.level == FluentLogLevel.error) FirebaseCrashlytics.instance.recordError(r.error ?? r.message, r.stackTrace);
  },
);
FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error}).listen((i) => Sentry.captureMessage('${i.title}\n${i.fix}'));
FluentDb.onIssue(types: {FluentIssueType.hint}).listen((i) => debugPrint('$i'));
FluentDb.setupLogging(mute: {'unordered:*'});        // mute an issue everywhere by key or prefix
debugPrint('${FluentDb.report()}');                  // hints by impact, automatic changes, warnings, errors
```

Hints are not errors: never route them into error reporting. To collect them from release builds use
`FluentConfig(diagnostics: FluentDiagnostics(hintsInRelease: true))`. `FluentDiagnostics.none` / `quiet` / `recommend`
(default) / `auto` decide what is measured, suggested and tuned; per database in `FluentDbConfig(diagnostics:)`. With
`auto` the tuner creates indexes, sizes the read pool, frees memory, maintains in the background — each lever switchable
in `FluentTuning` (`FluentTuning.full.copyWith(indexes: false)`); every change is a `tuned` issue, taken back as
`tuningReverted` when it does not help.

Hint kinds (`kind`, the key prefix): `missingIndex` (from `EXPLAIN QUERY PLAN` of a slow read), `slowRead`, `bigRead` /
`deepOffset` / `unordered` (use `findPage`), `like` (`startsWith`), `relations` (`maxDepth: 1`, `lazy`), `isolate`
(`isolateFactory`), `saveLoop` (`saveAll`), `lookupLoop` (`findByIds(ids)`), `flood`, `polling` (`watch`), `queueWait`,
`slowWrite` (smaller transactions / chunks), `refIndex` (`indexReferences`), `fullTextOff`, `pullClock` (return
`serverTime`); at `init`: `enumValues`, `redundantIndex`, `syncKey`, `autoRelations` (relations decided for you),
`columnRestorable`, `stepOnNewTable`, `unusedLinkTable`. Every kind with its type is in
[references/issues.md](references/issues.md). Apply the code of the hint.

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| `notInitialized` at start | a call before `init` finished | `await FluentDb.init([...])` before `runApp` |
| `schemaConflict` with a field table at init | a field is `null` in `modelSample` | give it a value or declare it in `missingColumns` |
| `TypeError` text in a `schemaConflict` | `fromCacheJson` casts a wrong type | use the types listed in the message (`as List`, `as DateTime`, `as Enum?`) |
| enum field comes back as `String` | `enumValues` missing | `Map<String, List<Enum>> get enumValues => {'status': Status.values};` |
| `ambiguousProvider` | the model is in two databases / tables | pass `dbKey:` or call the provider itself |
| `uniqueViolation` on server data | same unique value, other id | `saveAll(rows, conflictOn: ['email'])` |
| a relation is always `null` | not in `fromCacheJson`, or `lazy: true`, or provider not in the group | read `json['name']`; `loadRelations`; same `FluentGroup` |
| list scrolls with jank | mapping big lists on the UI isolate | add `isolateFactory` (static factory); page with `findPage` |
| slow filter | no index | follow the index hint, or `FluentIndex([...])` / `indexed: true` |
| a call hangs, then a transaction warning | awaiting an outside Future inside `FluentDb.transaction` | make the call inside the transaction, or await it before |
| `engineClosed` | a call after `FluentDb.close()` | await pending work before closing; `init` again |
| `migrationRefused` at start | `FluentGroup.onMigrationPlan` returned `false` | read the plan in the hint; allow it or change the model |
| `invalidArgument` for `orderBy` | `orderBy` contains SQL (sub-query, `CASE`, `;`) | order by columns only; map user choices to column names |
| `possibleRename` / `columnTypeChanged` warning | a field was renamed without `oldName`, or its type changed | apply the code: `restoreColumns` / a `CAST` step |
| `relationDeclaration`: "it is not saved" | a field holds models nobody stores, or `autoRelations` is off | register the provider, declare the relation, or drop the field from `buildJson` |
| a relation found automatically has the wrong kind | no back-reference tells the kind | copy the declaration from the `autoRelations` hint and fix it |
| `ignoredCall`: "read-only" on save | new models put into a `through` list | `attach(..., link: (x) => Link(...))` or save the link models |

## Performance tools

```dart
@override
Note Function(Map<String, dynamic> json)? get isolateFactory => Note.fromJson; // background mapping of big lists

final FluentEngineStats stats = FluentDb.engineStats();       // queue, waits, merged / collapsed calls
debugPrint('${FluentDb.report()}');                            // every current issue with how to fix it
debugPrint('${FluentDb.queryStats()}');                         // FluentQueryStats: measured costs (time, rows), slowest first
```

Settings: global `FluentConfig` (`init(config:)`, `FluentDb.configure`) → per database `FluentGroup(config: FluentDbConfig(...))`
→ per table `FluentTableConfig` on the model; the narrower one wins. Read connections: `readConnections` (default 2, or by cores with
`FluentTuning.readConnections`; WAL only). Mapping of big lists: `FluentConfig(isolateMapping: FluentIsolateMapping.smart, sliceAfterRows: 300, frameBudget: Duration(milliseconds: 4))`.
Measure on a phone with the `fluent_sqflite_benchmark` package: `import 'package:fluent_sqflite_benchmark/fluent_sqflite_benchmark.dart'; debugPrint(await FluentBenchmark.run());`.
