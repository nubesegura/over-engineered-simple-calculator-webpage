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
import 'package:calculator_app/live_history/live_history_status_chip.dart';
import 'package:calculator_app/main.dart';
import 'package:calculator_app/realtime/realtime_mode_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../realtime/fake_realtime_channel.dart';

String _unpaddedBase64Url(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _jwtWithSub(String sub) {
  final header = _unpaddedBase64Url(jsonEncode({'alg': 'RS256'}));
  final payload = _unpaddedBase64Url(jsonEncode({'sub': sub}));
  return '$header.$payload.sig';
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

class _FakeHistoryStore implements HistoryStoreClient {
  int fetchCalls = 0;

  @override
  Future<HistoryPage> fetchHistory({
    int limit = LiveHistoryConstants.defaultPageLimit,
    String? nextToken,
    String? since,
  }) async {
    fetchCalls++;
    return HistoryPage(
      items: [
        LiveCalculation.fromJson({
          'txId': 'tx-$fetchCalls',
          'a': '6',
          'b': '7',
          'op': 'MULTIPLY',
          'result': '42',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        })!,
      ],
      nextToken: nextToken == null ? 'next-page-cursor' : null,
    );
  }
}

FakeRealtimeChannel _autoAckEventsChannel() {
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
          jsonEncode({'type': 'subscribe_success', 'id': req['id']}),
        );
      });
    }
  };
  return channel;
}

final Map<LiveHistoryStatusKind, LiveHistoryStatus> _visibleStatuses = {
  LiveHistoryStatusKind.connecting: LiveHistoryStatus.connecting,
  LiveHistoryStatusKind.live: LiveHistoryStatus.live,
  LiveHistoryStatusKind.reconnecting: LiveHistoryStatus.reconnecting(2),
  LiveHistoryStatusKind.offline: LiveHistoryStatus.offline,
  LiveHistoryStatusKind.notAuthorized: LiveHistoryStatus.notAuthorized,
  LiveHistoryStatusKind.invalidAddress: LiveHistoryStatus.invalidAddress,
};

final LiveHistoryConfig _validLiveConfig = LiveHistoryConfig.parse(
  realtimeDomain: 'example.appsync-realtime-api.us-east-2.amazonaws.com',
  httpDomain: 'example.appsync-api.us-east-2.amazonaws.com',
  graphQlUrl: 'https://example.appsync-api.us-east-2.amazonaws.com/graphql',
);

double _contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final light = l1 > l2 ? l1 : l2;
  final dark = l1 > l2 ? l2 : l1;
  return (light + 0.05) / (dark + 0.05);
}

bool _isInside(Finder root, BuildContext? context) {
  if (context == null) return false;
  final rootElement = root.evaluate().first;
  var found = identical(context, rootElement);
  context.visitAncestorElements((element) {
    if (identical(element, rootElement)) found = true;
    return !found;
  });
  return found;
}

/// Presses Tab until the focus is inside [target]; false when it never is.
Future<bool> _tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 40; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (_isInside(target, FocusManager.instance.primaryFocus?.context)) {
      return true;
    }
  }
  return false;
}

void main() {
  group('live history status chip', () {
    for (final entry in _visibleStatuses.entries) {
      testWidgets('${entry.key.name} renders BOTH an icon and a text label',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: LiveHistoryStatusChip(status: entry.value)),
        ));

        expect(find.text(entry.value.label), findsOneWidget);
        expect(
          find.byIcon(LiveHistoryStatusChip.iconFor(entry.key)),
          findsOneWidget,
        );
      });

      testWidgets('${entry.key.name} text has a contrast of at least 4.5:1',
          (tester) async {
        final theme = ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        );
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(body: LiveHistoryStatusChip(status: entry.value)),
        ));

        final colors = LiveHistoryStatusChip.colorsFor(
          entry.key,
          theme.colorScheme,
        );
        final text = tester.widget<Text>(
          find.byKey(const Key('live-history-status-text')),
        );
        expect(text.style?.color, colors.foreground);
        expect(
          _contrast(colors.foreground, colors.background),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    testWidgets('notConfigured renders nothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LiveHistoryStatusChip(status: LiveHistoryStatus.notConfigured),
        ),
      ));

      expect(find.byKey(const Key('live-history-status-text')), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });

    test('every status kind has its own distinct icon', () {
      final icons = {
        for (final kind in LiveHistoryStatusKind.values)
          LiveHistoryStatusChip.iconFor(kind),
      };
      expect(icons, hasLength(LiveHistoryStatusKind.values.length));
    });

    testWidgets('is a labelled polite live region that follows status changes',
        (tester) async {
      final handle = tester.ensureSemantics();
      Future<void> show(LiveHistoryStatus status) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: LiveHistoryStatusChip(status: status)),
            ),
          );

      await show(LiveHistoryStatus.connecting);
      final chip = find.byType(LiveHistoryStatusChip);
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: 'Live history status: Connecting',
          isLiveRegion: true,
        ),
      );

      await show(LiveHistoryStatus.live);
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: 'Live history status: Live',
          isLiveRegion: true,
        ),
      );

      await show(LiveHistoryStatus.reconnecting(2));
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: 'Live history status: Reconnecting (2/5)',
          isLiveRegion: true,
        ),
      );
      handle.dispose();
    });
  });

  group('live history actions', () {
    testWidgets(
        'Refresh and Load more buttons are keyboard-focusable and at least 48x48 px',
        (tester) async {
      final session = SessionController(_SignedInAuthApi());
      final store = _FakeHistoryStore();
      final factory = FakeChannelFactory([_autoAckEventsChannel()]);
      final controller = LiveHistoryController(
        config: _validLiveConfig,
        tokens: session,
        historyClient: store,
        eventsClient: AppSyncEventsClient(channels: factory),
      );

      await tester.pumpWidget(CalculatorApp(
        loginSupported: true,
        apiBaseUrl: 'https://api.calc.example.test/api/v1',
        session: session,
        liveHistoryController: controller,
      ));
      await tester.pumpAndSettle();

      final refreshButton = find.byKey(const Key('history-refresh'));
      final loadMoreButton = find.byKey(const Key('history-load-more'));

      final refreshSize = tester.getSize(refreshButton);
      expect(refreshSize.width, greaterThanOrEqualTo(kRealtimeTouchTarget));
      expect(refreshSize.height, greaterThanOrEqualTo(kRealtimeTouchTarget));

      final loadMoreSize = tester.getSize(loadMoreButton);
      expect(loadMoreSize.width, greaterThanOrEqualTo(kRealtimeTouchTarget));
      expect(loadMoreSize.height, greaterThanOrEqualTo(kRealtimeTouchTarget));

      expect(await _tabTo(tester, refreshButton), isTrue);
      expect(FocusManager.instance.primaryFocus!.hasPrimaryFocus, isTrue);

      expect(await _tabTo(tester, loadMoreButton), isTrue);
      expect(FocusManager.instance.primaryFocus!.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(store.fetchCalls, 2);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      controller.dispose();
    });
  });
}
