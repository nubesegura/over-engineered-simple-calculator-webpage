import 'dart:async';
import 'dart:convert';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/live_history/appsync_events_client.dart';
import 'package:calculator_app/live_history/graphql_history_client.dart';
import 'package:calculator_app/live_history/live_calculation.dart';
import 'package:calculator_app/live_history/live_history_config.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:calculator_app/live_history/live_history_controller.dart';
import 'package:calculator_app/live_history/live_history_status.dart';
import 'package:calculator_app/main.dart';
import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../realtime/fake_realtime_channel.dart';

const _restAddress = 'https://api.calc.example.test/api/v1';
const _wsAddress = 'wss://example.invalid/dev';

final LiveHistoryConfig _validLiveConfig = LiveHistoryConfig.parse(
  realtimeDomain: 'example.appsync-realtime-api.us-east-2.amazonaws.com',
  httpDomain: 'example.appsync-api.us-east-2.amazonaws.com',
  graphQlUrl: 'https://example.appsync-api.us-east-2.amazonaws.com/graphql',
);

String _unpaddedBase64Url(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _jwtWithSub(String sub) {
  final header = _unpaddedBase64Url(jsonEncode({'alg': 'RS256'}));
  final payload = _unpaddedBase64Url(jsonEncode({'sub': sub}));
  return '$header.$payload.sig';
}

String _formatExpectedLocal(String isoUtc) {
  final t = DateTime.parse(isoUtc).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

class _SignedInAuthApi implements AuthApi {
  @override
  Future<TokenSet> refresh() async => TokenSet(
        idToken: _jwtWithSub('11111111-2222-4333-8444-555555555555'),
        accessToken: 'access',
        expiresIn: const Duration(hours: 1),
      );

  @override
  Future<TokenSet> login(String username, String password) => refresh();

  @override
  Future<void> logout() async {}
}

FakeRealtimeChannel _autoAckEventsChannel({String subId = 'sub-1'}) {
  final channel = FakeRealtimeChannel();
  channel.onRequest = (req) {
    final type = req['type'];
    if (type == 'connection_init') {
      scheduleMicrotask(() {
        channel.receive(
          jsonEncode({'type': 'connection_ack', 'connectionTimeoutMs': 300000}),
        );
      });
    } else if (type == 'subscribe') {
      scheduleMicrotask(() {
        channel.receive(
          jsonEncode({'type': 'subscribe_success', 'id': req['id'] ?? subId}),
        );
      });
    }
  };
  return channel;
}

String _liveDataFrame(Map<String, Object?> eventMap) => jsonEncode({
      'type': 'data',
      'id': 'sub-1',
      'event': jsonEncode(eventMap),
    });

class _ScriptedHistoryStore implements HistoryStoreClient {
  final List<Future<HistoryPage> Function(int limit, String? nextToken)>
      _pages = [];
  final List<String?> seenCursors = [];

  void addPage(List<LiveCalculation> items, {String? nextToken}) {
    _pages.add(
      (limit, next) async => HistoryPage(items: items, nextToken: nextToken),
    );
  }

  void addError(Exception error) {
    _pages.add((limit, next) => Future<HistoryPage>.error(error));
  }

  @override
  Future<HistoryPage> fetchHistory({
    int limit = LiveHistoryConstants.defaultPageLimit,
    String? nextToken,
    String? since,
  }) {
    seenCursors.add(nextToken);
    if (_pages.isEmpty) {
      return Future.value(const HistoryPage(items: []));
    }
    return _pages.removeAt(0)(limit, nextToken);
  }
}

Future<void> _selectWebSocket(WidgetTester tester) async {
  await tester.tap(find.text('WebSocket'));
  await tester.pumpAndSettle();
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets(
      '1. unconfigured mode preserves legacy REST history and hides live status chip',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final restCalls = <String>[];
    final client = MockClient((request) async {
      restCalls.add('${request.method} ${request.url.path}');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'calculation_id': 'rest-1',
              'operation': 'add',
              'a': '2',
              'b': '3',
              'result': '5',
              'occurred_at': '2026-10-27T10:00:00Z',
            },
          ],
          'next_cursor': null,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(CalculatorApp(
      httpClient: client,
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      liveHistoryConfig: LiveHistoryConfig.parse(),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('live-history-status')), findsNothing);
    expect(
      find.text('Press refresh to load your calculations.'),
      findsOneWidget,
    );
    expect(restCalls, isEmpty);

    await tester.ensureVisible(find.byKey(const Key('history-refresh')));
    await tester.tap(find.byKey(const Key('history-refresh')));
    await tester.pumpAndSettle();

    expect(restCalls, ['GET /api/v1/history']);
    expect(find.text('2 + 3 = 5'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets(
      '2. configured mode auto-starts in Standard (REST) mode, shows Live chip, and renders Query.history items with local timestamp and transport',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final eventsChannel = _autoAckEventsChannel();
    final factory = FakeChannelFactory([eventsChannel]);
    final graphQlCalls = <Map<String, Object?>>[];

    final client = MockClient((request) async {
      graphQlCalls.add(
        Map<String, Object?>.from(jsonDecode(request.body) as Map),
      );
      return http.Response(
        jsonEncode({
          'data': {
            'history': {
              'items': [
                {
                  'txId': 'tx-ws-1',
                  'a': '6.0',
                  'b': '7.0',
                  'op': 'MULTIPLY',
                  'result': '42.0',
                  'status': 'OK',
                  'errorCode': null,
                  'source': 'ws',
                  'createdAt': '2026-10-27T15:02:00Z',
                },
                {
                  'txId': 'tx-gql-1',
                  'a': '10.0',
                  'b': '4.0',
                  'op': 'SUBTRACT',
                  'result': '6.0',
                  'status': 'OK',
                  'errorCode': null,
                  'source': 'single',
                  'createdAt': '2026-10-27T15:01:00Z',
                },
              ],
              'nextToken': null,
            },
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(CalculatorApp(
      httpClient: client,
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      realtimeAddress: RealtimeAddress.parse(_wsAddress),
      realtimeChannels: factory,
      liveHistoryConfig: _validLiveConfig,
    ));
    await tester.pumpAndSettle();

    // Default is REST API tab, switch to WebSocket tab to view live history.
    expect(find.text('REST API'), findsOneWidget);
    await _selectWebSocket(tester);
    expect(find.byKey(const Key('live-history-status')), findsOneWidget);
    expect(find.text(LiveHistoryConstants.liveLabel), findsOneWidget);
    expect(graphQlCalls, hasLength(1));

    expect(find.byKey(const Key('history-tx-ws-1')), findsOneWidget);
    expect(find.text('6 × 7 = 42'), findsOneWidget);
    expect(
      find.text('${_formatExpectedLocal('2026-10-27T15:02:00Z')} · websocket'),
      findsOneWidget,
    );

    expect(find.byKey(const Key('history-tx-gql-1')), findsOneWidget);
    expect(find.text('10 - 4 = 6'), findsOneWidget);
    expect(
      find.text('${_formatExpectedLocal('2026-10-27T15:01:00Z')} · graphql'),
      findsOneWidget,
    );
    await _leave(tester);
  });

  testWidgets(
      '3 & 4. incoming live OK and ERROR calculations appear immediately at the top without tapping Refresh',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final eventsChannel = _autoAckEventsChannel();
    final factory = FakeChannelFactory([eventsChannel]);
    final store = _ScriptedHistoryStore()
      ..addPage([
        LiveCalculation.fromJson({
          'txId': 'tx-old',
          'a': '2',
          'b': '3',
          'op': 'ADD',
          'result': '5',
          'status': 'OK',
          'source': 'single',
          'createdAt': '2026-10-27T14:00:00Z',
        })!,
      ]);
    final controller = LiveHistoryController(
      config: _validLiveConfig,
      tokens: session,
      historyClient: store,
      eventsClient: AppSyncEventsClient(channels: factory),
    );

    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      liveHistoryController: controller,
    ));
    await tester.pumpAndSettle();
    await _selectWebSocket(tester);

    expect(find.text('2 + 3 = 5'), findsOneWidget);

    // Push live OK event: 6 × 7 = 42
    eventsChannel.receive(
      _liveDataFrame({
        'type': 'calculation',
        'txId': 'tx-live-42',
        'a': '6.0',
        'b': '7.0',
        'op': 'MULTIPLY',
        'result': '42.0',
        'errorCode': null,
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T15:10:00Z',
      }),
    );
    await tester.pump();

    expect(find.byKey(const Key('history-tx-live-42')), findsOneWidget);
    expect(find.text('6 × 7 = 42'), findsOneWidget);
    expect(
      find.text('${_formatExpectedLocal('2026-10-27T15:10:00Z')} · websocket'),
      findsOneWidget,
    );

    // Push live ERROR event: 1 ÷ 0 -> Cannot divide by zero.
    eventsChannel.receive(
      _liveDataFrame({
        'type': 'calculation',
        'txId': 'tx-live-div0',
        'a': '1',
        'b': '0',
        'op': 'DIVIDE',
        'result': null,
        'errorCode': 'DIVISION_BY_ZERO',
        'status': 'ERROR',
        'transport': 'websocket',
        'createdAt': '2026-10-27T15:11:00Z',
      }),
    );
    await tester.pump();

    expect(find.byKey(const Key('history-tx-live-div0')), findsOneWidget);
    expect(find.text('1 ÷ 0 = Cannot divide by zero.'), findsOneWidget);

    // Verify newest item is rendered above older items.
    final div0Top =
        tester.getTopLeft(find.byKey(const Key('history-tx-live-div0'))).dy;
    final multTop =
        tester.getTopLeft(find.byKey(const Key('history-tx-live-42'))).dy;
    final oldTop =
        tester.getTopLeft(find.byKey(const Key('history-tx-old'))).dy;
    expect(div0Top, lessThan(multTop));
    expect(multTop, lessThan(oldTop));

    await _leave(tester);
    controller.dispose();
  });

  testWidgets(
      '5 & 6. deduplicates matching txId across live stream and Query.history, and Load more appends older page',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final eventsChannel = _autoAckEventsChannel();
    final factory = FakeChannelFactory([eventsChannel]);
    final sharedCalc = LiveCalculation.fromJson({
      'txId': 'tx-dup',
      'a': '6',
      'b': '7',
      'op': 'MULTIPLY',
      'result': '42',
      'status': 'OK',
      'transport': 'websocket',
      'createdAt': '2026-10-27T15:05:00Z',
    })!;
    final olderCalc = LiveCalculation.fromJson({
      'txId': 'tx-older-page',
      'a': '8',
      'b': '2',
      'op': 'DIVIDE',
      'result': '4',
      'status': 'OK',
      'transport': 'graphql',
      'createdAt': '2026-10-27T14:50:00Z',
    })!;
    final store = _ScriptedHistoryStore()
      ..addPage([sharedCalc], nextToken: 'cursor-page-2')
      ..addPage([olderCalc], nextToken: null);
    final controller = LiveHistoryController(
      config: _validLiveConfig,
      tokens: session,
      historyClient: store,
      eventsClient: AppSyncEventsClient(channels: factory),
    );

    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      liveHistoryController: controller,
    ));
    await tester.pumpAndSettle();
    await _selectWebSocket(tester);

    // Emit the same txId on the live channel.
    eventsChannel.receive(
      _liveDataFrame({
        'type': 'calculation',
        'txId': 'tx-dup',
        'a': '6',
        'b': '7',
        'op': 'MULTIPLY',
        'result': '42',
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T15:05:00Z',
      }),
    );
    await tester.pump();

    // Only one ListTile for tx-dup.
    expect(find.byKey(const Key('history-tx-dup')), findsOneWidget);
    expect(find.text('6 × 7 = 42'), findsOneWidget);

    // Load more button is visible because nextToken was 'cursor-page-2'.
    final loadMoreButton = find.byKey(const Key('history-load-more'));
    expect(loadMoreButton, findsOneWidget);
    await tester.ensureVisible(loadMoreButton);
    await tester.pumpAndSettle();
    await tester.tap(loadMoreButton);
    await tester.pumpAndSettle();

    expect(store.seenCursors, [null, 'cursor-page-2']);
    expect(find.byKey(const Key('history-tx-older-page')), findsOneWidget);
    expect(find.text('8 ÷ 2 = 4'), findsOneWidget);
    expect(find.byKey(const Key('history-load-more')), findsNothing);

    await _leave(tester);
    controller.dispose();
  });

  testWidgets(
      '7. tapping Refresh reconnects when Offline and keeps existing items visible if refresh fails',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final recoveredChannel = _autoAckEventsChannel();
    // 2 auth rejections put the controller into NotAuthorized (canReconnect == true),
    // then the 3rd channel succeeds when the user taps Refresh.
    final factory = FakeChannelFactory([
      RealtimeFailure.refused,
      RealtimeFailure.refused,
      recoveredChannel,
    ]);
    final store = _ScriptedHistoryStore()
      ..addPage([
        LiveCalculation.fromJson({
          'txId': 'tx-initial',
          'a': '3',
          'b': '4',
          'op': 'ADD',
          'result': '7',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        })!,
      ])
      ..addError(const LiveHistoryException());

    final controller = LiveHistoryController(
      config: _validLiveConfig,
      tokens: session,
      historyClient: store,
      eventsClient: AppSyncEventsClient(channels: factory),
    );

    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      liveHistoryController: controller,
    ));
    await tester.pumpAndSettle();
    await _selectWebSocket(tester);

    expect(controller.status, LiveHistoryStatus.notAuthorized);
    expect(find.text(LiveHistoryConstants.notAuthorizedLabel), findsOneWidget);
    expect(find.text('3 + 4 = 7'), findsOneWidget);

    // Tap Refresh: reconnects channel to Live AND runs Query.history (which fails),
    // showing the error message while keeping '3 + 4 = 7' visible!
    final refreshButton = find.byKey(const Key('history-refresh'));
    await tester.ensureVisible(refreshButton);
    await tester.pumpAndSettle();
    await tester.tap(refreshButton);
    await tester.pumpAndSettle();

    expect(controller.status, LiveHistoryStatus.live);
    expect(find.text(LiveHistoryConstants.liveLabel), findsOneWidget);
    expect(find.text(LiveHistoryConstants.loadErrorMessage), findsOneWidget);
    expect(find.text('3 + 4 = 7'), findsOneWidget);

    await _leave(tester);
    controller.dispose();
  });

  testWidgets(
      '8. invalid configuration shows Invalid address chip and problem message',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final factory = FakeChannelFactory([]);

    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      realtimeChannels: factory,
      liveHistoryConfig: LiveHistoryConfig.parse(
        realtimeDomain: 'only-one.amazonaws.com',
      ),
    ));
    await tester.pumpAndSettle();
    await _selectWebSocket(tester);

    expect(find.byKey(const Key('live-history-status')), findsOneWidget);
    expect(find.text(LiveHistoryConstants.invalidAddressLabel), findsOneWidget);
    expect(
      find.text(LiveHistoryConstants.invalidAddressMessage),
      findsOneWidget,
    );
    expect(factory.uris, isEmpty);
    await _leave(tester);
  });

  testWidgets(
      '9. logout resets live history controller, sends unsubscribe, closes socket, and clears items',
      (tester) async {
    final session = SessionController(_SignedInAuthApi());
    final eventsChannel = _autoAckEventsChannel();
    final factory = FakeChannelFactory([eventsChannel]);
    final store = _ScriptedHistoryStore()
      ..addPage([
        LiveCalculation.fromJson({
          'txId': 'tx-before-logout',
          'a': '9',
          'b': '1',
          'op': 'ADD',
          'result': '10',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        })!,
      ]);
    final controller = LiveHistoryController(
      config: _validLiveConfig,
      tokens: session,
      historyClient: store,
      eventsClient: AppSyncEventsClient(channels: factory),
    );

    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      liveHistoryController: controller,
    ));
    await tester.pumpAndSettle();
    await _selectWebSocket(tester);

    expect(find.text('9 + 1 = 10'), findsOneWidget);
    expect(controller.items, hasLength(1));
    expect(eventsChannel.closedByClient, isFalse);

    await tester.tap(find.byKey(const Key('logout-button')));
    await tester.pumpAndSettle();

    expect(eventsChannel.closedByClient, isTrue);
    expect(eventsChannel.sentRequests.last['type'], 'unsubscribe');
    expect(controller.items, isEmpty);
    expect(find.byKey(const Key('logout-button')), findsNothing);

    await _leave(tester);
    controller.dispose();
  });
}
