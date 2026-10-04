import 'dart:convert';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/constants.dart';
import 'package:calculator_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// A BFF that always has a valid session.
class SignedInAuthApi implements AuthApi {
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

Future<void> _pumpCalculator(WidgetTester tester,
    {http.Client? backend}) async {
  await tester.pumpWidget(CalculatorApp(
    httpClient: backend,
    loginSupported: true,
    session: SessionController(SignedInAuthApi()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('CalculatorApp', () {
    testWidgets('smoke test', (WidgetTester tester) async {
      await _pumpCalculator(tester);

      expect(find.text('Over-Engineered Calculator'), findsWidgets);
    });

    testWidgets('Service URL is prefilled and there is no API key field',
        (WidgetTester tester) async {
      await _pumpCalculator(tester);

      final urlField =
          tester.widget<TextField>(find.byKey(const Key('service-url-field')));

      expect(urlField.controller!.text, ApiConstants.defaultApiBaseUrl);
      expect(find.byKey(const Key('api-key-field')), findsNothing);
      expect(find.text('API Key'), findsNothing);
    });

    testWidgets('an empty or invalid Service URL keeps the validation message',
        (WidgetTester tester) async {
      await _pumpCalculator(tester);

      await tester.enterText(find.byKey(const Key('service-url-field')), '');
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pump();

      expect(
        find.text('Result: Enter a valid Service URL (http:// or https://).'),
        findsOneWidget,
      );
    });

    testWidgets(
        'a plain http Service URL shows the https message and sends '
        'nothing', (tester) async {
      var requests = 0;
      final backend = MockClient((request) async {
        requests++;
        return _json({'result': '5'});
      });
      await _pumpCalculator(tester, backend: backend);

      await tester.enterText(find.byKey(const Key('service-url-field')),
          'http://api.example.com/api');
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();

      expect(
          find.text('Result: The Service URL must use https.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('history-refresh')));
      await tester.tap(find.byKey(const Key('history-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('The Service URL must use https.'), findsOneWidget);
      expect(requests, 0);
    });

    testWidgets('an http://localhost Service URL is allowed', (tester) async {
      late http.Request captured;
      final backend = MockClient((request) async {
        captured = request;
        return _json({'result': '5'});
      });
      await _pumpCalculator(tester, backend: backend);

      await tester.enterText(find.byKey(const Key('service-url-field')),
          'http://localhost:8080/api');
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();

      expect(find.text('Result: 5'), findsOneWidget);
      expect(captured.headers['Authorization'], 'Bearer id');
    });

    testWidgets('calculations send the bearer token', (tester) async {
      late http.Request captured;
      final backend = MockClient((request) async {
        captured = request;
        return _json({'result': '5'});
      });
      await _pumpCalculator(tester, backend: backend);

      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();

      expect(find.text('Result: 5'), findsOneWidget);
      expect(captured.headers['Authorization'], 'Bearer id');
      expect(captured.headers.containsKey('x-api-key'), isFalse);
    });

    testWidgets('history is loaded on demand and refreshed after a calculation',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var historyCalls = 0;
      final mock = MockClient((request) async {
        if (request.method == 'GET') {
          historyCalls++;
          return _json({
            'items': [
              {
                'calculation_id': 'id-$historyCalls',
                'operation': 'add',
                'a': '2',
                'b': '3',
                'result': '5',
                'occurred_at': '2026-10-02T10:00:00+00:00',
              },
            ],
            'next_cursor': null,
          });
        }
        return _json({'result': '5'});
      });

      await _pumpCalculator(tester, backend: mock);
      expect(historyCalls, 0);
      expect(find.text('Press refresh to load your calculations.'),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('history-refresh')));
      await tester.pumpAndSettle();
      expect(historyCalls, 1);
      expect(find.text('2 + 3 = 5'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.tap(find.text('Calculate'));
      await tester.pump();
      await tester.pump(ApiConstants.historyRefreshDelay);
      await tester.pumpAndSettle();

      expect(find.text('Result: 5'), findsOneWidget);
      expect(historyCalls, 2);
    });

    testWidgets('a service without history shows a friendly message',
        (WidgetTester tester) async {
      final mock =
          MockClient((_) async => _json({'message': 'Not Found'}, 404));

      await _pumpCalculator(tester, backend: mock);
      await tester.ensureVisible(find.byKey(const Key('history-refresh')));
      await tester.tap(find.byKey(const Key('history-refresh')));
      await tester.pumpAndSettle();

      expect(find.text('This service does not provide a history.'),
          findsOneWidget);
    });

    testWidgets(
        'a backend that keeps answering 401 returns to the login screen '
        'with the expiry message', (WidgetTester tester) async {
      final mock = MockClient((_) async => _json({'message': 'No'}, 401));

      await _pumpCalculator(tester, backend: mock);
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('login-email-field')), findsOneWidget);
      expect(find.text('Your session has expired. Please log in again.'),
          findsOneWidget);
    });

    testWidgets('a 403 keeps the calculator and shows the error',
        (WidgetTester tester) async {
      final mock = MockClient((_) async => _json({
            'error': {'code': 'FORBIDDEN', 'message': 'Not allowed.'},
          }, 403));

      await _pumpCalculator(tester, backend: mock);
      await tester.enterText(find.byKey(const Key('first-number-field')), '2');
      await tester.enterText(find.byKey(const Key('second-number-field')), '3');
      await tester.ensureVisible(find.text('Calculate'));
      await tester.tap(find.text('Calculate'));
      await tester.pumpAndSettle();

      expect(find.text('Result: Error: Not allowed.'), findsOneWidget);
      expect(find.byKey(const Key('logout-button')), findsOneWidget);
    });
  });
}
