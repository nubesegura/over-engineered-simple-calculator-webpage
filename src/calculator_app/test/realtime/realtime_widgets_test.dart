import 'dart:async';
import 'dart:convert';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/main.dart';
import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_realtime_channel.dart';

const _restAddress = 'https://api.calc.example.test/api/v1';
const _wsAddress = 'wss://example.invalid/dev';

class _SignedInAuthApi implements AuthApi {
  @override
  Future<TokenSet> refresh() async => const TokenSet(
        idToken: 'id',
        accessToken: 'access',
        expiresIn: Duration(hours: 1),
      );

  @override
  Future<TokenSet> login(String username, String password) => refresh();

  @override
  Future<void> logout() async {}
}

class _FakeStopwatch extends Fake implements Stopwatch {
  @override
  void start() {}

  @override
  void stop() {}

  @override
  int get elapsedMilliseconds => 12;
}

/// A channel that answers every calculation with the product of 6 and 7, or a
/// division error when the divisor is zero.
FakeRealtimeChannel _answeringChannel() {
  final channel = FakeRealtimeChannel();
  channel.onRequest = (request) {
    if (request['action'] != 'calculate') return;
    final txId = request['txId'] as String;
    final reply = request['op'] == 'DIVIDE'
        ? resultReply(txId, status: 'ERROR', errorCode: 'DIVIDE_BY_ZERO')
        : resultReply(txId);
    scheduleMicrotask(() => channel.receive(reply));
  };
  return channel;
}

class _Harness {
  _Harness({
    List<Object>? script,
    this.address = _wsAddress,
  }) : factory = FakeChannelFactory(script ?? [_answeringChannel()]);

  final FakeChannelFactory factory;
  final String address;
  final SessionController session = SessionController(_SignedInAuthApi());
  final List<String> restCalls = [];

  http.Client get backend => MockClient((request) async {
        restCalls.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('history')) {
          return http.Response(
            jsonEncode({'items': <Object>[], 'nextCursor': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'result': '5', 'backend': 'lambda'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(CalculatorApp(
      httpClient: backend,
      loginSupported: true,
      apiBaseUrl: _restAddress,
      session: session,
      stopwatchFactory: _FakeStopwatch.new,
      realtimeAddress: RealtimeAddress.parse(address),
      realtimeChannels: factory,
    ));
    await tester.pumpAndSettle();
  }
}

Future<void> _selectMode(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _selectRealtime(WidgetTester tester) =>
    _selectMode(tester, RealtimeConstants.realtimeModeLabel);

Future<void> _enter(WidgetTester tester, String a, String b) async {
  await tester.enterText(find.byKey(const Key('first-number-field')), a);
  await tester.enterText(find.byKey(const Key('second-number-field')), b);
  await tester.pump();
}

Future<void> _press(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('REST is the default: no connection and no status chip',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);

    expect(find.text(RealtimeConstants.standardModeLabel), findsOneWidget);
    expect(find.byKey(const Key('realtime-status-text')), findsNothing);
    expect(h.factory.uris, isEmpty);
    await _leave(tester);
  });

  testWidgets('selecting Real-time connects and shows the chip',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await _selectRealtime(tester);

    expect(find.text(RealtimeConstants.connectedLabel), findsOneWidget);
    expect(h.factory.uris, hasLength(1));
    expect(find.text(RealtimeConstants.reconnectLabel), findsNothing);
    await _leave(tester);
  });

  testWidgets('6 x 7 shows 42, the time and the transport, not the backend',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await _selectRealtime(tester);
    await _enter(tester, '6', '7');
    await _press(tester, '×');
    await _press(tester, 'Calculate');

    expect(find.text('Result: 42'), findsOneWidget);
    expect(find.text('Response time: 12 ms'), findsOneWidget);
    expect(find.text(RealtimeConstants.transportLine), findsOneWidget);
    expect(find.textContaining('Backend:'), findsNothing);
    expect(h.restCalls, isEmpty);
    await _leave(tester);
  });

  testWidgets('1 / 0 shows the division text', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await _selectRealtime(tester);
    await _enter(tester, '1', '0');
    await _press(tester, '÷');
    await _press(tester, 'Calculate');

    expect(find.text('Result: Cannot divide by zero.'), findsOneWidget);
    expect(find.text(RealtimeConstants.transportLine), findsNothing);
    await _leave(tester);
  });

  testWidgets('not connected: sends nothing and offers REST once',
      (tester) async {
    final h = _Harness(script: [
      RealtimeFailure.refused,
      RealtimeFailure.refused,
    ]);
    await h.pump(tester);
    await _selectRealtime(tester);

    expect(find.text(RealtimeConstants.notAuthorizedLabel), findsOneWidget);
    await _enter(tester, '2', '3');
    await _press(tester, 'Calculate');

    expect(find.text('Result: ${RealtimeConstants.notConnectedMessage}'),
        findsOneWidget);
    expect(h.restCalls, isEmpty);

    await _press(tester, RealtimeConstants.useRestLabel);

    expect(find.text('Result: 5'), findsOneWidget);
    expect(find.text('Backend: lambda'), findsOneWidget);
    expect(h.restCalls, ['POST /api/v1/add']);
    expect(find.byKey(const Key('realtime-status-text')), findsOneWidget);
    expect(find.text(RealtimeConstants.useRestLabel), findsNothing);
    await _leave(tester);
  });

  testWidgets('Reconnect after a refusal connects again', (tester) async {
    final h = _Harness(script: [
      RealtimeFailure.refused,
      RealtimeFailure.refused,
      _answeringChannel(),
    ]);
    await h.pump(tester);
    await _selectRealtime(tester);

    await _press(tester, RealtimeConstants.reconnectLabel);

    expect(find.text(RealtimeConstants.connectedLabel), findsOneWidget);
    expect(find.text(RealtimeConstants.reconnectLabel), findsNothing);
    await _leave(tester);
  });

  testWidgets('without an address Real-time is not configured and REST works',
      (tester) async {
    final h = _Harness(address: '');
    await h.pump(tester);
    await _selectRealtime(tester);

    expect(find.text(RealtimeConstants.notConfiguredLabel), findsOneWidget);
    expect(find.text(RealtimeConstants.notConfiguredMessage), findsOneWidget);
    expect(h.factory.uris, isEmpty);

    await _selectMode(tester, RealtimeConstants.standardModeLabel);
    await _enter(tester, '2', '3');
    await _press(tester, 'Calculate');

    expect(find.text('Result: 5'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('changing the mode resets the result and leaving closes',
      (tester) async {
    final channel = _answeringChannel();
    final h = _Harness(script: [channel]);
    await h.pump(tester);
    await _selectRealtime(tester);
    await _enter(tester, '6', '7');
    await _press(tester, 'Calculate');
    expect(find.text('Result: 42'), findsOneWidget);

    await _selectMode(tester, RealtimeConstants.standardModeLabel);

    expect(find.text('Result: 0'), findsOneWidget);
    expect(find.text(RealtimeConstants.transportLine), findsNothing);
    expect(channel.closedByClient, isTrue);
    await _leave(tester);
  });

  testWidgets('a pending calculation disables Calculate; editing resets it',
      (tester) async {
    final silent = FakeRealtimeChannel();
    final h = _Harness(script: [silent]);
    await h.pump(tester);
    await _selectRealtime(tester);
    await _enter(tester, '6', '7');
    await tester.ensureVisible(find.text('Calculate'));
    await tester.tap(find.text('Calculate'));
    await tester.pump();

    expect(find.byKey(const Key('realtime-progress')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Calculate'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('first-number-field')), '8');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('realtime-progress')), findsNothing);
    expect(find.text('Result: 0'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Calculate'))
          .onPressed,
      isNotNull,
    );
    await _leave(tester);
  });

  testWidgets('a real-time calculation does not touch the REST history',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.ensureVisible(find.byKey(const Key('history-refresh')));
    await tester.tap(find.byKey(const Key('history-refresh')));
    await tester.pumpAndSettle();
    expect(h.restCalls, ['GET /api/v1/history']);

    await _selectRealtime(tester);
    await _enter(tester, '6', '7');
    await _press(tester, 'Calculate');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(h.restCalls, ['GET /api/v1/history']);
    await _leave(tester);
  });

  testWidgets('logout closes the real-time connection', (tester) async {
    final channel = _answeringChannel();
    final h = _Harness(script: [channel]);
    await h.pump(tester);
    await _selectRealtime(tester);
    expect(channel.closedByClient, isFalse);

    await tester.tap(find.byKey(const Key('logout-button')));
    await tester.pumpAndSettle();

    expect(channel.closedByClient, isTrue);
    expect(find.byKey(const Key('logout-button')), findsNothing);
    await _leave(tester);
  });

  testWidgets('session expiry closes the real-time connection', (tester) async {
    final channel = _answeringChannel();
    final h = _Harness(script: [channel]);
    await h.pump(tester);
    await _selectRealtime(tester);

    h.session.markExpired('id');
    await tester.pumpAndSettle();

    expect(channel.closedByClient, isTrue);
    expect(find.byKey(const Key('logout-button')), findsNothing);
    await _leave(tester);
  });
}
