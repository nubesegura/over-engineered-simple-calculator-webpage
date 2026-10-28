import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/main.dart';
import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:calculator_app/realtime/realtime_mode_selector.dart';
import 'package:calculator_app/realtime/realtime_status.dart';
import 'package:calculator_app/realtime/realtime_status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_realtime_channel.dart';

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

final Map<RealtimeStatusKind, RealtimeStatus> _statuses = {
  RealtimeStatusKind.connecting: RealtimeStatus.connecting,
  RealtimeStatusKind.connected: RealtimeStatus.connected,
  RealtimeStatusKind.reconnecting: RealtimeStatus.reconnecting(2),
  RealtimeStatusKind.disconnected: RealtimeStatus.disconnected,
  RealtimeStatusKind.notAuthorized: RealtimeStatus.notAuthorized,
  RealtimeStatusKind.notConfigured:
      RealtimeStatus.notConfigured(RealtimeConstants.notConfiguredMessage),
};

Future<void> _pump(
  WidgetTester tester, {
  List<Object>? script,
  String address = 'wss://example.invalid/dev',
}) async {
  await tester.pumpWidget(CalculatorApp(
    loginSupported: true,
    apiBaseUrl: 'https://api.calc.example.test/api/v1',
    session: SessionController(_SignedInAuthApi()),
    realtimeAddress: RealtimeAddress.parse(address),
    realtimeChannels: FakeChannelFactory(script ?? [FakeRealtimeChannel()]),
  ));
  await tester.pumpAndSettle();
}

Future<void> _selectRealtime(WidgetTester tester) async {
  await tester.tap(find.text('WebSocket'));
  await tester.pumpAndSettle();
}

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
  group('status chip', () {
    for (final entry in _statuses.entries) {
      testWidgets('${entry.key.name} has an icon AND a text', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: RealtimeStatusChip(status: entry.value)),
        ));

        expect(find.text(entry.value.label), findsOneWidget);
        expect(
          find.byIcon(RealtimeStatusChip.iconFor(entry.key)),
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
          home: Scaffold(body: RealtimeStatusChip(status: entry.value)),
        ));

        final colors = RealtimeStatusChip.colorsFor(
          entry.key,
          theme.colorScheme,
        );
        final text = tester.widget<Text>(
          find.byKey(const Key('realtime-status-text')),
        );
        expect(text.style?.color, colors.foreground);
        expect(_contrast(colors.foreground, colors.background),
            greaterThanOrEqualTo(4.5));
      });
    }

    test('every status kind has its own icon', () {
      final icons = {
        for (final kind in RealtimeStatusKind.values)
          RealtimeStatusChip.iconFor(kind),
      };
      expect(icons, hasLength(RealtimeStatusKind.values.length));
    });

    testWidgets('is a labelled polite live region that follows the status',
        (tester) async {
      final handle = tester.ensureSemantics();
      Future<void> show(RealtimeStatus status) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: RealtimeStatusChip(status: status)),
            ),
          );

      await show(RealtimeStatus.connecting);
      final chip = find.byType(RealtimeStatusChip);
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: 'Connection status: Connecting',
          isLiveRegion: true,
        ),
      );

      await show(RealtimeStatus.connected);
      expect(
        tester.getSemantics(chip),
        matchesSemantics(
          label: 'Connection status: Connected',
          isLiveRegion: true,
        ),
      );
      handle.dispose();
    });
  });

  Future<void> pumpModeSelector(
    WidgetTester tester, {
    bool realtime = false,
    ValueChanged<bool>? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RealtimeModeSelector(
          realtime: realtime,
          onChanged: onChanged ?? (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('mode control', () {
    testWidgets('has a label and both options in the semantics tree',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpModeSelector(tester);

      expect(
        find.bySemanticsLabel(RealtimeConstants.modeLabel),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RealtimeConstants.standardModeLabel),
          findsOneWidget);
      expect(find.bySemanticsLabel(RealtimeConstants.realtimeModeLabel),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('is reachable by keyboard and can be chosen with Enter',
        (tester) async {
      var selected = false;
      await pumpModeSelector(tester, onChanged: (v) => selected = v);
      final realtimeOption = find.ancestor(
        of: find.text(RealtimeConstants.realtimeModeLabel),
        matching: find.byType(TextButton),
      );

      expect(await _tabTo(tester, realtimeOption), isTrue);
      final focus = FocusManager.instance.primaryFocus!;
      expect(focus.hasPrimaryFocus, isTrue);
      expect(focus.canRequestFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, isTrue);
    });

    testWidgets('touch targets are at least 48 px', (tester) async {
      await pumpModeSelector(tester);

      for (final label in [
        RealtimeConstants.standardModeLabel,
        RealtimeConstants.realtimeModeLabel,
      ]) {
        final button = find.ancestor(
          of: find.text(label),
          matching: find.byType(TextButton),
        );
        final size = tester.getSize(button);
        expect(size.height, greaterThanOrEqualTo(kRealtimeTouchTarget));
        expect(size.width, greaterThanOrEqualTo(kRealtimeTouchTarget));
      }
    });
  });

  group('actions', () {
    testWidgets('Reconnect is keyboard reachable and 48 px high',
        (tester) async {
      await _pump(tester, script: [
        RealtimeFailure.refused,
        RealtimeFailure.refused,
        FakeRealtimeChannel(),
      ]);
      await _selectRealtime(tester);
      final reconnect = find.byKey(const Key('realtime-reconnect'));

      expect(tester.getSize(reconnect).height,
          greaterThanOrEqualTo(kRealtimeTouchTarget));
      expect(await _tabTo(tester, reconnect), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(RealtimeConstants.connectedLabel), findsOneWidget);
    });

    testWidgets('the REST fallback is keyboard reachable and 48 px high',
        (tester) async {
      await _pump(tester, address: '');
      await _selectRealtime(tester);
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();
      final fallback = find.byKey(const Key('use-rest-fallback'));

      expect(tester.getSize(fallback).height,
          greaterThanOrEqualTo(kRealtimeTouchTarget));
      expect(await _tabTo(tester, fallback), isTrue);
    });
  });
}
