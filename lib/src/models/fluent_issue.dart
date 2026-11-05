// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// What a [FluentIssue] is about, from the mildest to the most severe.
///
/// Route them by type: e.g. only `warning` and `error` to Crashlytics / Sentry
/// (`FluentDb.onIssue(types: {FluentIssueType.warning, FluentIssueType.error})`), hints to a debug panel.
enum FluentIssueType {
  /// A suggestion: it works, but could be faster or safer (with code to copy). Shown once per run, only while the
  /// database's `FluentDiagnostics` collect hints.
  hint,

  /// The library changed something by itself while the app runs: a fallback it chose, a setting the tuner applied or
  /// reverted, rows it moved to keep them. Always reported: nothing changes silently.
  autoFix,

  /// Something in the code or the setup is wrong; the library ignored it or fell back to a safe choice, and says how
  /// to fix it. Shown once per run, unless its kind [FluentIssueKind.repeats].
  warning,

  /// Something failed that no caller receives (background work, maintenance, listeners). Errors your code receives
  /// as exceptions are not issues.
  error,
}

/// How much fixing a hint helps; the report groups hints by it.
enum FluentIssueImpact {
  /// Noticeably slower or wrong results today (missing indexes, N+1 loops, long waits).
  high,

  /// Slower under load or with more data.
  medium,

  /// Tidiness and small wins.
  low,
}

/// The stable kinds of issues. The kind is the first part of [FluentIssue.key], so a whole kind can be muted
/// (`FluentDb.setupLogging(mute: {'unordered:*'})`). Every kind is described in `doc/ai/issues.md`.
enum FluentIssueKind {
  // ---- hints ---------------------------------------------------------------------------------------------------------

  /// An index would serve a slow read (from the query plan or the measured costs).
  missingIndex(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// A read is slow on average and no index would help (big result, heavy relations, ...).
  slowRead(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// `findById` called in a loop (N+1): read the keys at once.
  lookupLoop(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// `save` called in a loop: one `saveAll` is one transaction.
  saveLoop(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// Thousands of calls queued at once.
  flood(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// Calls wait long in the queue behind a slow call.
  queueWait(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// A synced table uses auto-increment keys: two devices create the same id.
  syncKey(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// Reads load relations several levels deep and are slow.
  relations(FluentIssueType.hint),

  /// An unpaged read returns thousands of rows.
  bigRead(FluentIssueType.hint),

  /// Batched `findById` lookups read the keys of the stored rows (`FluentBatchKeys.fromRows`), but a returned model has
  /// another key than its row (its `fromCacheJson` changes the key). The library took the key from the model for those
  /// rows; `FluentTableConfig.batchKeys: FluentBatchKeys.fromModels` does it for every row.
  batchKeysMismatch(FluentIssueType.hint),

  /// A deep `offset`: keyset paging (`findPage`) costs the same on every page.
  deepOffset(FluentIssueType.hint),

  /// `LIKE '%…'` cannot use an index: full-text search can.
  like(FluentIssueType.hint),

  /// The same query polled while nothing changed: `watch` reads only after changes.
  polling(FluentIssueType.hint),

  /// A single write took long.
  slowWrite(FluentIssueType.hint),

  /// Big lists would map faster in a background isolate (`isolateFactory`).
  isolate(FluentIssueType.hint),

  /// A relation filter needs an index on the reference column (`indexReferences` is off).
  refIndex(FluentIssueType.hint),

  /// An enum field without `enumValues` comes back as a String.
  enumValues(FluentIssueType.hint),

  /// Paged reads without `orderBy` can repeat or skip rows.
  unordered(FluentIssueType.hint, impact: FluentIssueImpact.low),

  /// An index repeats another index or the key.
  redundantIndex(FluentIssueType.hint, impact: FluentIssueImpact.low),

  /// Full-text search is off for a table that searches.
  fullTextOff(FluentIssueType.hint, impact: FluentIssueImpact.low),

  /// Relations were decided automatically (`auto`, or fields found in `buildJson`); the hint lists them.
  autoRelations(FluentIssueType.hint, impact: FluentIssueImpact.low),

  /// A column is back in the model while its earlier values are archived: `restoreColumns` brings them back.
  columnRestorable(FluentIssueType.hint),

  /// A migration step that inserts rows was only marked as applied, because the table was just created.
  stepOnNewTable(FluentIssueType.hint),

  /// Pulls return no `serverTime`: the next `since` comes from the device clock.
  pullClock(FluentIssueType.hint, impact: FluentIssueImpact.high),

  /// A link table no relation uses any more is kept with its links.
  unusedLinkTable(FluentIssueType.hint, impact: FluentIssueImpact.low),

  // ---- automatic changes --------------------------------------------------------------------------------------------

  /// A paused queue ran past `FluentConfig.pauseWatchdog` and was resumed.
  queueResumed(FluentIssueType.autoFix),

  /// A transaction ran long while reads waited; the waiting reads were let in (they see its uncommitted changes).
  transactionWatchdog(FluentIssueType.autoFix),

  /// Rows of a table could not be sent to a background isolate; they are mapped on the UI isolate.
  isolateFallback(FluentIssueType.autoFix),

  /// The read connections could not be opened; reads run on the main connection.
  readPoolFallback(FluentIssueType.autoFix),

  /// The device has no FTS5 / FTS4; searches fall back (FTS4 or `LIKE`).
  fullTextFallback(FluentIssueType.autoFix),

  /// A database was deleted and created again after a failed start (`resetOnSchemaError`).
  databaseRecreated(FluentIssueType.autoFix),

  /// A column removed from the model was archived with its data.
  columnArchived(FluentIssueType.autoFix),

  /// A new NOT NULL column without a default stays nullable for the existing rows.
  columnKeptNullable(FluentIssueType.autoFix),

  /// A relation changed how it is stored (e.g. many-to-many → owned list); its data was copied to the new place.
  relationDataMoved(FluentIssueType.autoFix),

  /// Rows a new constraint rejects were moved to a quarantine table.
  rowsQuarantined(FluentIssueType.autoFix),

  /// Saved models whose rows were in the trash were restored.
  trashRevived(FluentIssueType.autoFix),

  /// The tuner applied a setting (`FluentDiagnostics.auto`).
  tuned(FluentIssueType.autoFix),

  /// The tuner took a setting back (it did not help, or it failed).
  tuningReverted(FluentIssueType.autoFix),

  // ---- warnings -----------------------------------------------------------------------------------------------------

  /// A setting that cannot work was replaced by a safe one.
  configFallback(FluentIssueType.warning),

  /// The same database name was given twice to `init`.
  duplicateGroup(FluentIssueType.warning),

  /// `init` got no group with providers.
  noGroups(FluentIssueType.warning),

  /// One model type is stored in several tables: calls by type cannot choose.
  sharedModelType(FluentIssueType.warning),

  /// Tables reference each other in a cycle.
  circularReference(FluentIssueType.warning),

  /// A call could not do what was asked and did nothing (unknown relation, no key, wrong place, ...).
  ignoredCall(FluentIssueType.warning),

  /// A collection of models spans several databases: each is written in its own transaction.
  crossDatabase(FluentIssueType.warning),

  /// The model declares something invalid (key, default value, column type); a safe choice was used.
  schemaFallback(FluentIssueType.warning),

  /// An index of the model was not created (unknown columns, duplicates in the data).
  indexSkipped(FluentIssueType.warning),

  /// A view, trigger or index of the app could not be recreated after a table rebuild.
  viewOrTrigger(FluentIssueType.warning),

  /// A trigger or view of the app was recreated after a table rebuild but no longer fits the table (it uses a removed or
  /// renamed column); SQLite would fail only when it fires. It is kept; the hint has the SQL to recreate it.
  brokenTrigger(FluentIssueType.warning),

  /// A column changed its type on a table with rows; values that do not fit stay as they were.
  columnTypeChanged(FluentIssueType.warning),

  /// A column was removed and one of the same type added: probably a rename without `oldName`.
  possibleRename(FluentIssueType.warning),

  /// A relation changed how it is stored, but its data could not be moved (shared children, composite keys).
  relationChanged(FluentIssueType.warning),

  /// A migration step was not run (no id, changed after it ran, nothing to do).
  migrationSkipped(FluentIssueType.warning),

  /// Rows reference rows that do not exist.
  danglingReferences(FluentIssueType.warning),

  /// A relation declaration is invalid or ambiguous; it was skipped or interpreted.
  relationDeclaration(FluentIssueType.warning),

  /// A soft-deletable model owns children without soft delete (or the other way round).
  relationSoftDelete(FluentIssueType.warning),

  /// Foreign keys are off: owned children are not deleted with their owner by SQLite.
  foreignKeysOff(FluentIssueType.warning),

  /// A relation field held a value of the wrong type; the relation was skipped for that model.
  relationValue(FluentIssueType.warning),

  /// `conflictOn` columns are not unique: one save may update several rows.
  conflictOn(FluentIssueType.warning),

  /// A save carried `deletedAt`; the rows stay live (delete them to move them to the trash).
  deletedAtIgnored(FluentIssueType.warning),

  /// Restored rows stay in the trash because their owner is deleted.
  trashStays(FluentIssueType.warning),

  /// `clearTable` emptied a synced table that still had local changes the server never received.
  unsentChangesDiscarded(FluentIssueType.warning, repeats: true),

  /// A stored value could not be read as the model expects; the field got a fallback.
  mappingValue(FluentIssueType.warning),

  /// A table, link table or column a 1.x database stored under its 1.x name (derived from a type or relation name
  /// with the old naming rule) was renamed to the current name; its data is kept.
  legacyNameAdopted(FluentIssueType.autoFix),

  /// A saved value lost part of itself in its stored form (the microseconds of a `DateTime` in the timestamp format,
  /// which keeps milliseconds); the rest was saved.
  precisionLost(FluentIssueType.warning),

  /// A column of a full-text index was skipped, or the table cannot have one.
  fullTextSkipped(FluentIssueType.warning),

  /// The server deleted rows the model cannot keep in a trash; they are kept.
  remoteDeleteKept(FluentIssueType.warning),

  /// `FluentTableConfig.serverKey` names unknown columns; the primary key is used.
  serverKeyIgnored(FluentIssueType.warning),

  /// A permanently deleted row has no server key yet, so the server cannot be told about the deletion.
  tombstoneWithoutKey(FluentIssueType.warning, repeats: true),

  /// A database could not be opened.
  initFailed(FluentIssueType.warning, repeats: true),

  /// A synchronization failed.
  syncFailed(FluentIssueType.warning, repeats: true),

  /// `fetch` of `watchRemote` failed.
  apiFailed(FluentIssueType.warning, repeats: true),

  /// `watchRemote` could not store the answer of `fetch`.
  syncStoreFailed(FluentIssueType.warning, repeats: true),

  /// The engine stopped before every queued call finished.
  shutdownTimeout(FluentIssueType.warning, repeats: true),

  /// A connection could not be closed (harmless).
  closeFailed(FluentIssueType.warning, repeats: true),

  // ---- errors -------------------------------------------------------------------------------------------------------

  /// A database file could not be deleted.
  fileDeleteFailed(FluentIssueType.error),

  /// Start-up or periodic maintenance failed (expired rows, dangling references, trash).
  maintenanceFailed(FluentIssueType.error),

  /// Loading a relation failed; it was left unloaded.
  relationLoadFailed(FluentIssueType.error),

  /// A callback of the app (`onSuccess`, ...) threw.
  callbackFailed(FluentIssueType.error),

  /// An unexpected internal failure.
  engineFailure(FluentIssueType.error);

  const FluentIssueKind(this.type, {this.impact = FluentIssueImpact.medium, this._repeats = false});

  /// What the issues of this kind are.
  final FluentIssueType type;

  /// How much fixing a hint of this kind helps (report order).
  final FluentIssueImpact impact;

  final bool _repeats;

  /// Whether every occurrence is reported (automatic changes, errors, failures), not only the first one per run.
  /// Other issues are reported once per key and title (numbers in the title ignored).
  bool get repeats => _repeats || type == FluentIssueType.autoFix || type == FluentIssueType.error;
}

/// One thing the library tells you: a hint, an automatic change, a warning or an error nobody received.
///
/// Every issue says what happened ([title], [details]) and how to fix it ([fix], [code]). Listen to them with
/// `FluentDb.onIssue`, read them in `FluentDb.report()`, mute them by [key] (`FluentDb.setupLogging(mute: ...)`).
@immutable
class FluentIssue {
  /// Creates an issue.
  const FluentIssue({
    required this.kind,
    required this.title,
    this.details,
    this.fix,
    this.code,
    this.database,
    this.table,
    this.subject,
    this.impact,
    this.error,
    this.stackTrace,
  });

  /// The kind; decides [type] and the first part of [key].
  final FluentIssueKind kind;

  /// What happened or what to do, in one line.
  final String title;

  /// Why it matters: what was found or measured.
  final String? details;

  /// How to fix it.
  final String? fix;

  /// Code to copy, when the fix is a code change.
  final String? code;

  /// The database it is about, if one.
  final String? database;

  /// The table it is about, if one.
  final String? table;

  /// What exactly inside the table (columns, index, relation), part of [key].
  final String? subject;

  /// How much fixing it helps, when it differs from the kind's impact.
  final FluentIssueImpact? impact;

  /// The underlying error, if any.
  final Object? error;

  /// Where [error] happened.
  final StackTrace? stackTrace;

  /// What the issue is: hint, automatic change, warning or error.
  FluentIssueType get type => kind.type;

  /// How much fixing it helps (hints; the kind's impact unless the issue set its own).
  FluentIssueImpact get priority => impact ?? kind.impact;

  /// Identifies the issue: `<kind>:<database>:<table>:<subject>`, trailing empty parts left out (e.g.
  /// `missingIndex:app:users:email`, `queueWait:app`). Mute a key or a prefix ending in `*`: `missingIndex:app:*`.
  String get key {
    final List<String> parts = [kind.name, database ?? '', table ?? '', subject ?? ''];
    while (parts.length > 1 && parts.last.isEmpty) {
      parts.removeLast();
    }
    return parts.join(':');
  }

  @override
  String toString() => [title, ?details, if (fix != null) 'Fix: $fix', ?code, '(${type.name} $key)'].join('\n');

  @override
  bool operator ==(Object other) => other is FluentIssue && other.key == key && other.title == title;

  @override
  int get hashCode => Object.hash(key, title);
}

/// What the library found and did in this run (`FluentDb.report()`): hints by impact, automatic changes, warnings and
/// errors. Print it while optimizing: `debugPrint('${FluentDb.report()}')`.
@immutable
class FluentReport {
  /// Creates a report of [issues] (muted ones are left out by `FluentDb.report()`).
  const FluentReport(this.issues);

  /// Every issue, hints first by impact.
  final List<FluentIssue> issues;

  /// The hints of [impact].
  List<FluentIssue> hints(FluentIssueImpact impact) => [for (final FluentIssue i in issues) if (i.type == FluentIssueType.hint && i.priority == impact) i];

  /// The issues of [type].
  List<FluentIssue> ofType(FluentIssueType type) => [for (final FluentIssue i in issues) if (i.type == type) i];

  /// Whether nothing was found.
  bool get isEmpty => issues.isEmpty;

  @override
  String toString() {
    if (issues.isEmpty) return 'Nothing to report: no hints, no automatic changes, no warnings.';
    final StringBuffer out = StringBuffer();
    void section(String name, List<FluentIssue> list) {
      if (list.isEmpty) return;
      out.writeln('$name (${list.length})');
      for (final FluentIssue i in list) {
        out.writeln('  • ${i.title}');
        if (i.details != null) out.writeln('    ${i.details!.replaceAll('\n', '\n    ')}');
        if (i.fix != null) out.writeln('    Fix: ${i.fix!.replaceAll('\n', '\n    ')}');
        if (i.code != null) out.writeln(i.code!.split('\n').map((l) => '      $l').join('\n'));
        out.writeln('    (${i.key})');
      }
      out.writeln();
    }

    section('Important — fix first', hints(FluentIssueImpact.high));
    section('Medium', hints(FluentIssueImpact.medium));
    section('Small wins', hints(FluentIssueImpact.low));
    section('Changed automatically', ofType(FluentIssueType.autoFix));
    section('Warnings', ofType(FluentIssueType.warning));
    section('Errors nobody received', ofType(FluentIssueType.error));
    return out.toString().trimRight();
  }
}
