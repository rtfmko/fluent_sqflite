# Errors and logging

## Errors

Every error is a `FluentException` with:

* `message` — what happened, and why when it is known;
* `code` — a stable `FluentErrorCode` (use it for UI texts and localization; messages may change);
* `hint` — how to fix it, often with code to copy;
* `cause` — the original error (e.g. the SQLite error), `stackTrace`.

| Class | Typical codes |
|---|---|
| `FluentConfigException` | `notInitialized`, `providerNotFound`, `ambiguousProvider`, `invalidDatabaseName`, `databaseNotFound` |
| `FluentSchemaException` | `schemaConflict`, `migrationFailed` |
| `FluentArgumentException` | `invalidArgument`, `invalidKey`, `unsupportedValue` |
| `FluentConstraintException` | `uniqueViolation`, `foreignKeyViolation`, `notNullViolation`, `checkViolation` |
| `FluentQueryException` | `sqlError`, `noSuchTable`, `readOnly` |
| `FluentRelationException` | `invalidRelation` |
| `FluentSyncException` | `syncFailed`, `apiError` (`statusCode`), `syncNotSupported` |
| `FluentCancelledException` | `engineClosed`, `syncCancelled` |
| `FluentEngineException` | `engineError` |

```dart
try {
  await users.save(user);
} on FluentConstraintException catch (e) {
  if (e.code == FluentErrorCode.uniqueViolation) showError('This e-mail is already taken');
}
```

Errors always arrive through the returned `Future` / `Stream` (never thrown synchronously). The full list of codes
with fixes is in [doc/ai/error-codes.md](ai/error-codes.md).

## Issues: hints, automatic changes, warnings

Everything else the library has to say is a `FluentIssue` — one structure for all of it:

| Type | Meaning | Reported |
|---|---|---|
| `hint` | it works, but could be faster or safer (with code to copy) | once per run |
| `autoFix` | the library changed something by itself: a fallback it chose, a tuner change or its revert | every time |
| `warning` | something in the code or setup is wrong; the library ignored it or fell back to a safe choice | once per run |
| `error` | something failed that no caller receives (maintenance, listeners, background work) | every time |

Every issue says what happened (`title`, `details`), how to fix it (`fix`, often `code`), has a stable `kind` and a
`key` (`<kind>:<database>:<table>:<subject>`). The library never crashes the app over a mistake in the code or the setup:
it falls back to a safe choice and tells you. All kinds are listed in [doc/ai/issues.md](ai/issues.md).

Route them by type — e.g. only what is wrong to crash reporting, hints to a debug panel:

```dart
FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error}).listen((FluentIssue i) {
  Sentry.captureMessage('${i.title}\n${i.fix}', params: [i.key]);
});
FluentDb.onIssue(types: {FluentIssueType.hint, FluentIssueType.autoFix}).listen(debugPanel.add);
debugPrint('${FluentDb.report()}'); // hints by impact, automatic changes, warnings, errors
```

Mute what does not apply to your app — the library cannot know everything: `FluentDb.setupLogging(mute:
{'unordered:*', 'missingIndex:app:logs:*'})` drops a key or a prefix everywhere (log, `onIssue`, report). Which hints are
collected, and whether the library may change anything by itself, is set by `FluentDiagnostics`
(see [Performance](performance.md#diagnostics-and-the-tuner)).

`close`, `restart`, `deleteDatabases` and `FluentEngine.shutdown` called from inside `FluentDb.transaction` or a
provider callback would wait for themselves; they are ignored and reported (`ignoredCall`). Call them after the
transaction completes. `clear`, `cleanOrphans` and `purgeArchivedColumns` called from inside another running task of the
same database are skipped the same way.

## Logging

```dart
FluentDb.setupLogging(
  level: FluentLogLevel.info,               // default: info in debug / profile, warning in release
  onRecord: (FluentLogRecord r) {           // e.g. forward to Crashlytics / Sentry
    if (r.level == FluentLogLevel.error) crashlytics.recordError(r.error ?? r.message, r.stackTrace);
  },
  showSqlArguments: false,                  // default: SQL arguments and paths are hidden (user data)
);
FluentDb.setupLogging(removeOnRecord: true); // remove the onRecord sink (onRecord: null keeps it)
FluentDb.setupLogging(enabled: false);      // everything off
```

Levels, from verbose to severe: `sql`, `debug` (every step of the library, like logcat without the noise), `info`
(milestones: databases opened / closed / cleared, schema changes), `hint`, `autoFix`, `warning`, `error`.

* An error your code receives is logged **once**, as a **warning** (you decide what it means); it is not an issue.
* Issues are logged at the level of their type, with `record.issue` set; `onIssue` gets them whatever the level.

Output goes through `debugPrint`, with colors only where the console shows them (desktop terminals).

SQL arguments are hidden from `args [` to the end of an error text. The `error` of a `FluentLogRecord` / `FluentIssue`
that is not a `FluentException` arrives as a `FluentRedactedError` (`type` and the redacted `message`) unless
`FluentLog.showSqlArguments` is on; database paths are shown only then as well (`<path hidden>`; `FluentGroup.toString`
never shows the directory).
