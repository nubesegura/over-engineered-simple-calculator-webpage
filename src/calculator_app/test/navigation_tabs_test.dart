import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/live_history/live_history_config.dart';
import 'package:calculator_app/main.dart';
import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'realtime/fake_realtime_channel.dart';

class _FakeAuthApi implements AuthApi {
  @override
  Future<TokenSet> refresh() async => const TokenSet(
        idToken: 'test-id-token',
        accessToken: 'test-access-token',
        expiresIn: Duration(hours: 1),
      );

  @override
  Future<TokenSet> login(String username, String password) => refresh();

  @override
  Future<void> logout() async {}
}

const _testApiUrl = 'https://api.calc.example.test/api/v1';
const _testWsUrl = 'wss://example.invalid/dev';

Future<void> _pumpApp(
  WidgetTester tester, {
  SessionController? session,
  RealtimeChannelFactory? channels,
  LiveHistoryConfig? liveConfig,
}) async {
  await tester.pumpWidget(CalculatorApp(
    loginSupported: true,
    apiBaseUrl: _testApiUrl,
    session: session ?? SessionController(_FakeAuthApi()),
    realtimeAddress: RealtimeAddress.parse(_testWsUrl),
    realtimeChannels: channels ?? FakeChannelFactory([FakeRealtimeChannel()]),
    liveHistoryConfig: liveConfig ?? LiveHistoryConfig.parse(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('Three-Tab Navigation', () {
    testWidgets('renders three distinct tabs with expected labels and icons',
        (tester) async {
      await _pumpApp(tester);

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('REST API'), findsOneWidget);
      expect(find.text('WebSocket'), findsOneWidget);
      expect(find.text('AI Assistant'), findsOneWidget);

      expect(find.byIcon(Icons.calculate), findsOneWidget);
      expect(find.byIcon(Icons.sync_alt), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('default tab is REST API displaying classic controls',
        (tester) async {
      await _pumpApp(tester);

      expect(find.byKey(const Key('service-url-label')), findsOneWidget);
      expect(find.text(_testApiUrl), findsOneWidget);
      expect(
          find.byKey(const Key('ai-assistant-tab-placeholder')), findsNothing);
    });

    testWidgets(
        'tapping WebSocket tab switches view and displays WebSocket controls',
        (tester) async {
      final channel = FakeRealtimeChannel();
      await _pumpApp(tester, channels: FakeChannelFactory([channel]));

      await tester.tap(find.text('WebSocket'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('realtime-status-chip')), findsOneWidget);
      expect(find.byKey(const Key('service-url-label')), findsNothing);
      expect(
          find.byKey(const Key('ai-assistant-tab-placeholder')), findsNothing);
    });

    testWidgets(
        'tapping AI Assistant tab switches view and displays AI placeholder',
        (tester) async {
      await _pumpApp(tester);

      await tester.tap(find.text('AI Assistant'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-assistant-tab-placeholder')),
          findsOneWidget);
      expect(find.byKey(const Key('service-url-label')), findsNothing);
      expect(find.byKey(const Key('realtime-status-chip')), findsNothing);
    });

    testWidgets(
        'session authentication and background WebSocket remain alive when switching tabs',
        (tester) async {
      final session = SessionController(_FakeAuthApi());
      final channel = FakeRealtimeChannel();
      await _pumpApp(tester,
          session: session, channels: FakeChannelFactory([channel]));

      expect(session.state, SessionState.authenticated);

      // Switch to WebSocket tab to activate connection
      await tester.tap(find.text('WebSocket'));
      await tester.pumpAndSettle();
      expect(channel.closedByClient, isFalse);

      // Switch to AI Assistant tab
      await tester.tap(find.text('AI Assistant'));
      await tester.pumpAndSettle();
      expect(session.state, SessionState.authenticated);
      expect(channel.closedByClient, isFalse);

      // Switch back to REST API tab
      await tester.tap(find.text('REST API'));
      await tester.pumpAndSettle();
      expect(session.state, SessionState.authenticated);
      expect(channel.closedByClient, isFalse);
    });
  });
}
