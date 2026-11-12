// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/token_source.dart';
import 'package:calculator_app/live_history/appsync_events_client.dart';
import 'package:calculator_app/live_history/graphql_history_client.dart';
import 'package:calculator_app/live_history/live_calculation.dart';
import 'package:calculator_app/live_history/live_history_config.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:calculator_app/live_history/live_history_controller.dart';
import 'package:calculator_app/live_history/live_history_status.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../realtime/fake_realtime_channel.dart';

String _unpaddedBase64Url(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _jwtWithSub(String sub, int generation) {
  final header = _unpaddedBase64Url(jsonEncode({'alg': 'RS256'}));
  final payload = _unpaddedBase64Url(
    jsonEncode({'sub': sub, 'gen': generation}),
  );
  return '$header.$payload.sig-$generation';
}

class _FakeTokenSource implements TokenSource {
  String sub = '11111111-2222-4333-8444-555555555555';
  int validCalls = 0;
  int renewCalls = 0;
  final List<String> rejectedTokens = [];
  Object? validError;
  Object? renewError;
  int _generation = 1;

  String get current => _jwtWithSub(sub, _generation);

  @override
  Future<String> validIdToken() async {
    validCalls++;
    if (validError != null) throw validError!;
    return current;
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    renewCalls++;
    rejectedTokens.add(rejectedToken);
    if (renewError != null) throw renewError!;
    _generation++;
    return current;
  }

  @override
  void markExpired(String rejectedToken) {}
}

class _FakeHistoryStoreClient implements HistoryStoreClient {
  final List<Future<HistoryPage> Function(int limit, String? nextToken)>
      _handlers = [];
  final List<String> callLog = [];

  void enqueuePage(
    List<LiveCalculation> items, {
    String? nextToken,
  }) {
    _handlers.add(
      (limit, cursor) async => HistoryPage(items: items, nextToken: nextToken),
    );
  }

  void enqueueError(Exception error) {
    _handlers.add((limit, cursor) => Future<HistoryPage>.error(error));
  }

  void enqueueCustom(
    Future<HistoryPage> Function(int limit, String? nextToken) fn,
  ) {
    _handlers.add(fn);
  }

  @override
  Future<HistoryPage> fetchHistory({
    int limit = LiveHistoryConstants.defaultPageLimit,
    String? nextToken,
    String? since,
  }) {
    callLog.add('fetchHistory(limit:$limit,nextToken:$nextToken)');
    if (_handlers.isEmpty) {
      return Future.value(const HistoryPage(items: []));
    }
    final handler = _handlers.removeAt(0);
    return handler(limit, nextToken);
  }
}

class _FixedRandom implements Random {
  const _FixedRandom(this.fraction);

  final double fraction;

  @override
  double nextDouble() => fraction;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

final LiveHistoryConfig _validConfig = LiveHistoryConfig.parse(
  realtimeDomain: 'example.appsync-realtime-api.us-east-2.amazonaws.com',
  httpDomain: 'example.appsync-api.us-east-2.amazonaws.com',
  graphQlUrl: 'https://example.appsync-api.us-east-2.amazonaws.com/graphql',
);

LiveCalculation _calc(
  String txId, {
  required String createdAt,
  String a = '6',
  String b = '7',
  String op = 'MULTIPLY',
  String? result = '42',
  String status = 'OK',
  String? errorCode,
  String transport = 'websocket',
}) =>
    LiveCalculation.fromJson({
      'type': 'calculation',
      'txId': txId,
      'a': a,
      'b': b,
      'op': op,
      'result': result,
      'errorCode': errorCode,
      'status': status,
      'transport': transport,
      'createdAt': createdAt,
    })!;

String _liveDataFrame(LiveCalculation item) => jsonEncode({
      'type': 'data',
      'id': 'sub-1',
      'event': jsonEncode({
        'type': 'calculation',
        'txId': item.txId,
        'a': item.a,
        'b': item.b,
        'op': item.op,
        'result': item.result,
        'errorCode': item.errorCode,
        'status': item.status,
        'transport': item.transport,
        'createdAt': item.createdAt,
      }),
    });

FakeRealtimeChannel _autoAckChannel({List<String>? eventOrderLog}) {
  final channel = FakeRealtimeChannel();
  channel.onRequest = (req) {
    final type = req['type'];
    if (type == 'connection_init') {
      channel.receive(
        jsonEncode({'type': 'connection_ack', 'connectionTimeoutMs': 300000}),
      );
    } else if (type == 'subscribe') {
      eventOrderLog?.add('subscribe');
      channel.receive(
        jsonEncode({'type': 'subscribe_success', 'id': req['id']}),
      );
    }
  };
  return channel;
}

void main() {
  late _FakeTokenSource tokens;
  late _FakeHistoryStoreClient historyStore;

  setUp(() {
    tokens = _FakeTokenSource();
    historyStore = _FakeHistoryStoreClient();
  });

  LiveHistoryController buildController(
    FakeChannelFactory factory, {
    LiveHistoryConfig? config,
    double jitter = 0,
  }) =>
      LiveHistoryController(
        config: config ?? _validConfig,
        tokens: tokens,
        historyClient: historyStore,
        eventsClient: AppSyncEventsClient(
          channels: factory,
          newSubscriptionId: () => 'sub-1',
        ),
        random: _FixedRandom(jitter),
      );

  group('configuration states', () {
    test('notConfigured opens no socket and makes no GraphQL call', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([]);
        final controller = buildController(
          factory,
          config: LiveHistoryConfig.parse(),
        );
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.notConfigured);
        expect(
          controller.status.label,
          LiveHistoryConstants.notConfiguredLabel,
        );
        expect(
          controller.status.semanticsLabel,
          'Live history status: Not configured',
        );
        expect(
          LiveHistoryStatus.live.hashCode,
          isNot(LiveHistoryStatus.offline.hashCode),
        );
        expect(
          LiveHistoryStatus.live.toString(),
          'LiveHistoryStatus(Live)',
        );
        expect(factory.uris, isEmpty);
        expect(historyStore.callLog, isEmpty);
        expect(tokens.validCalls, 0);
      });
    });

    test('invalid configuration sets invalidAddress and errorMessage', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([]);
        final controller = buildController(
          factory,
          config: LiveHistoryConfig.parse(realtimeDomain: 'only-one'),
        );
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.invalidAddress);
        expect(
          controller.errorMessage,
          LiveHistoryConstants.invalidAddressMessage,
        );
        expect(factory.uris, isEmpty);
        expect(historyStore.callLog, isEmpty);
        expect(tokens.validCalls, 0);
      });
    });
  });

  group('5-step synchronization contract', () {
    test(
        'subscribes first (step 1), fetches history second (step 2), deduplicates by txId (step 3) and sorts newest first (step 4)',
        () {
      fakeAsync((async) {
        final orderLog = <String>[];
        final channel = _autoAckChannel(eventOrderLog: orderLog);
        final factory = FakeChannelFactory([channel]);

        final queryCompleter = Completer<HistoryPage>();
        historyStore.enqueueCustom((limit, nextToken) {
          orderLog.add('fetchHistory');
          return queryCompleter.future;
        });

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        // Step 1 happened before Step 2.
        expect(orderLog, ['subscribe', 'fetchHistory']);
        expect(controller.status, LiveHistoryStatus.live);

        // Live event arrives while Query.history is still in flight!
        final liveItem = _calc(
          'tx-shared',
          createdAt: '2026-10-27T15:02:00Z',
          result: '42',
        );
        channel.receive(_liveDataFrame(liveItem));
        // Duplicate live event with the same txId is ignored.
        channel.receive(_liveDataFrame(liveItem));
        async.flushMicrotasks();
        expect(controller.items.map((e) => e.txId).toList(), ['tx-shared']);

        // Now Query.history finishes with the same tx-shared plus an older and a newer item.
        final olderItem = _calc(
          'tx-older',
          createdAt: '2026-10-27T15:00:00Z',
          result: '10',
        );
        final newestItem = _calc(
          'tx-newest',
          createdAt: '2026-10-27T15:05:00Z',
          result: '99',
        );
        queryCompleter.complete(
          HistoryPage(
            items: [olderItem, liveItem, newestItem],
            nextToken: 'cursor-2',
          ),
        );
        async.flushMicrotasks();

        // Deduplicated (3 unique txIds) and sorted newest first.
        expect(
          controller.items.map((e) => e.txId).toList(),
          ['tx-newest', 'tx-shared', 'tx-older'],
        );
        expect(controller.hasMore, isTrue);
        expect(controller.nextCursor, 'cursor-2');
      });
    });

    test('loads stored history from GraphQL even if initial WebSocket fails',
        () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([RealtimeFailure.timeout]);
        historyStore.enqueuePage([
          _calc('tx-stored', createdAt: '2026-10-27T12:00:00Z'),
        ]);

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        expect(controller.status, LiveHistoryStatus.reconnecting(1));
        expect(controller.items.map((e) => e.txId).toList(), ['tx-stored']);
      });
    });

    test(
        'step 5: unexpected close reconnects with backoff and re-queries Query.history on subscribe_success',
        () {
      fakeAsync((async) {
        final firstChannel = _autoAckChannel();
        final secondChannel = _autoAckChannel();
        final factory = FakeChannelFactory([
          firstChannel,
          RealtimeFailure.timeout,
          secondChannel,
        ]);

        historyStore.enqueuePage([
          _calc('tx-1', createdAt: '2026-10-27T15:00:00Z'),
        ]);
        // Second page returned during step 5 gap recovery after reconnect:
        historyStore.enqueuePage([
          _calc('tx-gap', createdAt: '2026-10-27T15:03:00Z'),
          _calc('tx-1', createdAt: '2026-10-27T15:00:00Z'),
        ]);

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.live);
        expect(controller.items.map((e) => e.txId).toList(), ['tx-1']);

        // Drop the first connection.
        firstChannel.serverClose();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.reconnecting(1));

        // Attempt 1 after 1 s fails with timeout -> schedules attempt 2 (2 s).
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, LiveHistoryStatus.reconnecting(2));

        // Attempt 2 after 2 s succeeds and automatically triggers Query.history gap recovery.
        async.elapse(const Duration(seconds: 2));
        expect(controller.status, LiveHistoryStatus.live);
        expect(historyStore.callLog, hasLength(2));
        expect(
          controller.items.map((e) => e.txId).toList(),
          ['tx-gap', 'tx-1'],
        );

        // Staying connected for 30 s resets the failure counter.
        async.elapse(LiveHistoryConstants.stableConnection);
        secondChannel.serverClose();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.reconnecting(1));
      });
    });

    test('stops reconnecting after 5 failed attempts and enters Offline status',
        () {
      fakeAsync((async) {
        final firstChannel = _autoAckChannel();
        final factory = FakeChannelFactory([
          firstChannel,
          for (var i = 0; i < 5; i++) RealtimeFailure.timeout,
        ]);
        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.live);

        firstChannel.serverClose();
        async.flushMicrotasks();

        for (var attempt = 1; attempt <= 5; attempt++) {
          expect(controller.status, LiveHistoryStatus.reconnecting(attempt));
          async.elapse(LiveHistoryController.reconnectDelay(attempt, 0));
        }
        expect(controller.status, LiveHistoryStatus.offline);
        expect(controller.status.canReconnect, isTrue);

        // Manual refresh reconnects when Offline.
        final recoveredChannel = _autoAckChannel();
        factory.add(recoveredChannel);
        historyStore.enqueuePage([
          _calc('tx-manual', createdAt: '2026-10-27T16:00:00Z'),
        ]);
        controller.refresh();
        async.flushMicrotasks();
        expect(controller.status, LiveHistoryStatus.live);
        expect(controller.items.map((e) => e.txId).toList(), ['tx-manual']);
      });
    });
  });

  group('auth rejection, pagination, errors and logout cleanup', () {
    test('auth rejection on first handshake renews token once and succeeds',
        () {
      fakeAsync((async) {
        final secondChannel = _autoAckChannel();
        final factory = FakeChannelFactory([
          RealtimeFailure.refused,
          secondChannel,
        ]);
        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        expect(tokens.renewCalls, 1);
        expect(controller.status, LiveHistoryStatus.live);
      });
    });

    test('two consecutive auth rejections set status to notAuthorized', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([
          RealtimeFailure.refused,
          RealtimeFailure.refused,
        ]);
        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        expect(tokens.renewCalls, 1);
        expect(controller.status, LiveHistoryStatus.notAuthorized);
      });
    });

    test('invalid JWT sub prevents opening WebSocket and marks notAuthorized',
        () {
      fakeAsync((async) {
        tokens.sub = 'invalid/sub!';
        final factory = FakeChannelFactory([_autoAckChannel()]);
        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        expect(factory.uris, isEmpty);
        expect(controller.status, LiveHistoryStatus.notAuthorized);
      });
    });

    test('401 during token renewal stops live history cleanly', () {
      fakeAsync((async) {
        tokens.renewError = const AuthApiException('expired', statusCode: 401);
        final factory = FakeChannelFactory([RealtimeFailure.refused]);
        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();

        expect(controller.status, LiveHistoryStatus.notAuthorized);
      });
    });

    test('GraphQL error keeps existing live items and sets errorMessage', () {
      fakeAsync((async) {
        final channel = _autoAckChannel();
        final factory = FakeChannelFactory([channel]);
        historyStore.enqueuePage([
          _calc('tx-1', createdAt: '2026-10-27T15:00:00Z'),
        ]);
        historyStore.enqueueError(const LiveHistoryException());

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();
        expect(controller.items, hasLength(1));
        expect(controller.errorMessage, isNull);

        controller.refresh();
        async.flushMicrotasks();
        expect(controller.items, hasLength(1));
        expect(
          controller.errorMessage,
          LiveHistoryConstants.loadErrorMessage,
        );
      });
    });

    test('loadMore fetches next page with nextCursor and merges older items',
        () {
      fakeAsync((async) {
        final channel = _autoAckChannel();
        final factory = FakeChannelFactory([channel]);
        historyStore.enqueuePage(
          [_calc('tx-2', createdAt: '2026-10-27T15:02:00Z')],
          nextToken: 'page-2',
        );
        historyStore.enqueuePage(
          [_calc('tx-1', createdAt: '2026-10-27T15:01:00Z')],
          nextToken: null,
        );

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();
        expect(controller.hasMore, isTrue);

        controller.loadMore();
        async.flushMicrotasks();
        expect(controller.items.map((e) => e.txId).toList(), ['tx-2', 'tx-1']);
        expect(controller.hasMore, isFalse);
        expect(
          historyStore.callLog,
          [
            'fetchHistory(limit:20,nextToken:null)',
            'fetchHistory(limit:20,nextToken:page-2)',
          ],
        );
      });
    });

    test(
        'resetForLogout and dispose send unsubscribe, close socket and clear memory',
        () {
      fakeAsync((async) {
        final channel = _autoAckChannel();
        final factory = FakeChannelFactory([channel]);
        historyStore.enqueuePage([
          _calc('tx-1', createdAt: '2026-10-27T15:00:00Z'),
        ]);

        final controller = buildController(factory);
        controller.start();
        async.flushMicrotasks();
        expect(controller.items, hasLength(1));

        controller.resetForLogout();
        async.flushMicrotasks();
        expect(controller.items, isEmpty);
        expect(channel.closedByClient, isTrue);
        expect(channel.sentRequests.last['type'], 'unsubscribe');
        expect(controller.toString(), isNot(contains(tokens.sub)));

        controller.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
