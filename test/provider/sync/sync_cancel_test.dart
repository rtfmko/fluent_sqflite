// Cancelling syncWithServer (FluentCancelToken): stops at once while waiting for onPull / onPush, between pages and
// batches, during a retry and while waiting for a running sync; what was stored stays, an unfinished pull does not
// move `since`, a late answer is ignored, nothing is retried or logged as a failure.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:fluent_sqflite/src/internal.dart';
import 'package:fluent_sqflite_test/fluent_sqflite_test.dart';
import 'package:flutter_test/flutter_test.dart';

class CNote extends FluentStorable {
  CNote({this.id, required this.text});

  final int? id;
  final String text;

  @override
  Map<String, dynamic> buildJson() => {'id': id, 'text': text};
}

class CNoteProvider extends FluentProvider<CNote> with FluentSyncable<CNote> {
  @override
  String get tableName => 'cancel_notes';

  @override
  CNote get modelSample => CNote(text: '');

  @override
  CNote fromCacheJson(Map<String, dynamic> json) => CNote(id: json['id'] as int?, text: json['text'] as String);
}

void main() {
  setUpFluentTests();
  late FluentTestDb db;
  late CNoteProvider notes;

  setUp(() async {
    db = FluentTestDb(name: 'sync_cancel');
    notes = CNoteProvider();
    await db.open([notes]);
  });
  tearDown(() => db.close());

  Future<FluentPushResult<CNote>> pushOk(FluentSyncBatch<CNote> _) async => const FluentPushResult.accepted();
  List<FluentIssue> failures() => [for (final FluentIssue i in db.issues) if (i.kind == FluentIssueKind.syncFailed) i];

  test('a token cancelled before the call: nothing runs', () async {
    final FluentCancelToken token = FluentCancelToken()..cancel();
    bool asked = false;
    final FluentSyncResult<CNote> r = await notes.syncWithServer(
      onPush: pushOk,
      onPull: (_) async {
        asked = true;
        return const FluentPullResult<CNote>();
      },
      cancel: token,
    );
    expect(r.isCancelled, isTrue);
    expect(r.isSuccess, isFalse);
    expect(r.error, isA<FluentCancelledException>().having((e) => e.code, 'code', FluentErrorCode.syncCancelled));
    expect('$r', contains('cancelled'));
    expect(asked, isFalse);
    expect(failures(), isEmpty);
  });

  test('cancel while onPull is waiting: returns at once, the late page is not stored, since does not move', () async {
    final Completer<FluentPullResult<CNote>> answer = Completer();
    final FluentCancelToken token = FluentCancelToken();
    final Future<FluentSyncResult<CNote>> sync = notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) => answer.future, cancel: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    final FluentSyncResult<CNote> r = await sync.timeout(const Duration(seconds: 2));
    expect(r.isCancelled, isTrue);
    answer.complete(FluentPullResult(items: [CNote(id: 1, text: 'late')], serverTime: DateTime.utc(2026)));
    await db.settle();
    expect(await notes.count(), 0, reason: 'the late answer is ignored');
    expect(await notes.lastPull(), isNull);
    expect(failures(), isEmpty);
    expect((await notes.watchSyncStatus().first).state, FluentSyncState.idle);
  });

  test('cancel between pages: earlier pages stay stored, since does not move, the next sync starts over', () async {
    final FluentCancelToken token = FluentCancelToken();
    final List<int> pages = [];
    final FluentSyncResult<CNote> r = await notes.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      cancel: token,
      onPull: (request) async {
        pages.add(request.page);
        if (request.page == 1) token.cancel(); // the answer of this page arrives with the cancel
        return FluentPullResult(items: [CNote(id: request.page + 1, text: 'p${request.page}')], hasMore: true, cursor: request.page + 1, serverTime: DateTime.utc(2026));
      },
    );
    expect(r.isCancelled, isTrue);
    expect(pages, [0, 1]);
    expect(r.pulled, 1);
    expect([for (final CNote n in await notes.find(orderBy: 'id')) n.text], ['p0']);
    expect(await notes.lastPull(), isNull, reason: 'only the last page moves since');

    final List<Object?> cursors = [];
    final FluentSyncResult<CNote> again = await notes.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (request) async {
        cursors.add(request.cursor);
        return FluentPullResult(items: [CNote(id: 2, text: 'p1')], serverTime: DateTime.utc(2026));
      },
    );
    expect(again.isSuccess, isTrue);
    expect(cursors, [null], reason: 'starts from the first page');
    expect(await notes.lastPull(), isNotNull);
  });

  test('cancel while onPush is waiting: the batch stays pending and is sent next time', () async {
    await notes.saveAll([CNote(text: 'a'), CNote(text: 'b')]);
    final Completer<FluentPushResult<CNote>> answer = Completer();
    final FluentCancelToken token = FluentCancelToken();
    final Future<FluentSyncResult<CNote>> sync = notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: (_) => answer.future, cancel: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    final FluentSyncResult<CNote> r = await sync.timeout(const Duration(seconds: 2));
    expect(r.isCancelled, isTrue);
    expect(r.pushed, 0);
    answer.complete(const FluentPushResult.accepted());
    await db.settle();
    expect(await notes.pendingChanges(), 2, reason: 'not marked as synced');
    final FluentSyncResult<CNote> again = await notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: pushOk);
    expect(again.pushed, 2);
    expect(await notes.pendingChanges(), 0);
  });

  test('cancel between push batches: earlier batches stay synced', () async {
    await notes.saveAll([for (int i = 0; i < 5; i++) CNote(text: 'n$i')]);
    final FluentCancelToken token = FluentCancelToken();
    int calls = 0;
    final FluentSyncResult<CNote> r = await notes.syncWithServer(
      strategy: FluentSyncStrategy.push,
      batchSize: 2,
      cancel: token,
      onPush: (batch) async {
        calls++;
        // The first batch is answered; the second is cancelled while on its way (its answer is ignored).
        if (calls == 2) token.cancel();
        return const FluentPushResult.accepted();
      },
    );
    expect(r.isCancelled, isTrue);
    expect(calls, 2);
    expect(r.pushed, 2);
    expect(await notes.pendingChanges(), 3);
  });

  test('cancel during the wait before a retry stops the retries', () async {
    final FluentCancelToken token = FluentCancelToken();
    int calls = 0;
    final Future<FluentSyncResult<CNote>> sync = notes.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      retries: 5,
      retryDelay: const Duration(seconds: 30),
      cancel: token,
      onPull: (_) async {
        calls++;
        throw FluentSyncException('offline', statusCode: 503);
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel();
    final FluentSyncResult<CNote> r = await sync.timeout(const Duration(seconds: 2));
    expect(r.isCancelled, isTrue);
    expect(calls, 1);
    expect(failures(), isEmpty);
  });

  test('a cancelled call waiting for a running sync returns at once; the running sync goes on', () async {
    final Completer<FluentPullResult<CNote>> first = Completer();
    final Future<FluentSyncResult<CNote>> running = notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) => first.future);
    await Future<void>.delayed(Duration.zero);
    final FluentCancelToken token = FluentCancelToken();
    final Future<FluentSyncResult<CNote>> waiting = notes.syncWithServer(strategy: FluentSyncStrategy.push, onPush: pushOk, cancel: token);
    token.cancel();
    expect((await waiting.timeout(const Duration(seconds: 2))).isCancelled, isTrue);
    first.complete(FluentPullResult(items: [CNote(id: 1, text: 'x')]));
    expect((await running).isSuccess, isTrue);
    expect(await notes.count(), 1);
  });

  test('a call waiting for the same sync is not answered by a cancelled one: it runs itself', () async {
    final Completer<FluentPullResult<CNote>> first = Completer();
    final FluentCancelToken token = FluentCancelToken();
    final Future<FluentSyncResult<CNote>> cancelled = notes.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) => first.future, cancel: token);
    await Future<void>.delayed(Duration.zero);
    final Future<FluentSyncResult<CNote>> second = notes.syncWithServer(
      strategy: FluentSyncStrategy.pull,
      onPull: (_) async => FluentPullResult(items: [CNote(id: 5, text: 'second')]),
    );
    token.cancel();
    expect((await cancelled).isCancelled, isTrue);
    final FluentSyncResult<CNote> r = await second.timeout(const Duration(seconds: 2));
    expect(r.isSuccess, isTrue);
    expect(r.isCancelled, isFalse);
    expect((await notes.findById(5))?.text, 'second');
    first.complete(const FluentPullResult<CNote>());
  });

  test('one token cancels several syncs; a sync without a token is unaffected', () async {
    final FluentCancelToken token = FluentCancelToken();
    final CNoteProvider other = notes;
    final Completer<FluentPullResult<CNote>> never = Completer();
    final Future<FluentSyncResult<CNote>> a = other.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) => never.future, cancel: token);
    token.cancel();
    token.cancel(); // twice: nothing more happens
    expect((await a.timeout(const Duration(seconds: 2))).isCancelled, isTrue);
    expect(token.isCancelled, isTrue);
    final FluentSyncResult<CNote> b = await other.syncWithServer(strategy: FluentSyncStrategy.pull, onPull: (_) async => const FluentPullResult<CNote>());
    expect(b.isSuccess, isTrue);
    never.complete(const FluentPullResult<CNote>());
  });
}
