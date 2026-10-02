import 'dart:convert';

import 'package:calculator_app/api_client.dart';
import 'package:calculator_app/constants.dart';
import 'package:calculator_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _baseUrl = 'https://api.example.com/api/sls/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('CalculatorApiClient', () {
    test('calculate posts the operands with the API key', () async {
      late http.Request captured;
      final client = CalculatorApiClient(
        baseUrl: '$_baseUrl/',
        apiKey: ' secret ',
        httpClient: MockClient((request) async {
          captured = request;
          return _json({'result': '5'});
        }),
      );

      expect(await client.calculate('add', 2, 3), '5');
      expect(captured.method, 'POST');
      expect(captured.url.toString(), '$_baseUrl/add');
      expect(captured.headers['x-api-key'], 'secret');
      expect(jsonDecode(captured.body), {'a': 2.0, 'b': 3.0});
    });

    test('the API key header is omitted when empty', () async {
      late http.Request captured;
      final client = CalculatorApiClient(
        baseUrl: _baseUrl,
        httpClient: MockClient((request) async {
          captured = request;
          return _json({'result': '5'});
        }),
      );

      await client.calculate('add', 2, 3);
      expect(captured.headers.containsKey('x-api-key'), isFalse);
    });

    test('fetchHistory sends limit and cursor and parses the page', () async {
      late http.Request captured;
      final client = CalculatorApiClient(
        baseUrl: _baseUrl,
        httpClient: MockClient((request) async {
          captured = request;
          return _json({
            'items': [
              {
                'calculation_id': 'id-1',
                'operation': 'mul',
                'a': '2',
                'b': '4',
                'result': '8',
                'occurred_at': '2026-10-02T10:00:00+00:00',
              },
            ],
            'next_cursor': 'next',
          });
        }),
      );

      final page = await client.fetchHistory(limit: 5, cursor: 'abc');

      expect(captured.method, 'GET');
      expect(captured.url.path, '/api/sls/v1/history');
      expect(captured.url.queryParameters, {'limit': '5', 'cursor': 'abc'});
      expect(page.nextCursor, 'next');
      expect(page.items.single.result, '8');
      expect(page.items.single.occurredAt, isNotNull);
    });

    test('error bodies are turned into readable messages', () async {
      Future<ApiException> failWith(http.Response response) async {
        final client = CalculatorApiClient(
          baseUrl: _baseUrl,
          httpClient: MockClient((_) async => response),
        );
        try {
          await client.calculate('div', 1, 0);
        } on ApiException catch (e) {
          return e;
        }
        fail('ApiException expected');
      }

      final domain = await failWith(_json({
        'error': {'code': 'DIVISION_BY_ZERO', 'message': 'Cannot divide by zero.'},
      }, 400));
      expect(domain.message, 'Cannot divide by zero.');
      expect(domain.statusCode, 400);

      final forbidden = await failWith(_json({'message': 'Forbidden'}, 403));
      expect(forbidden.message, 'Forbidden');

      final html = await failWith(http.Response('<html></html>', 502));
      expect(html.message, 'Request failed (HTTP 502).');
    });

    test('network failures are reported without details', () async {
      final client = CalculatorApiClient(
        baseUrl: _baseUrl,
        httpClient: MockClient((_) async => throw http.ClientException('boom')),
      );

      expect(
        client.fetchHistory(),
        throwsA(isA<ApiException>().having(
          (e) => e.message,
          'message',
          'Connection to the server failed.',
        )),
      );
    });

    test('hasValidBaseUrl requires an absolute http(s) URL', () {
      bool valid(String url) => CalculatorApiClient(baseUrl: url).hasValidBaseUrl;

      expect(valid(_baseUrl), isTrue);
      expect(valid('/api/ecs/v1'), isFalse);
      expect(valid('ftp://example.com'), isFalse);
      expect(valid(''), isFalse);
    });
  });

  group('CalculatorApp', () {
    testWidgets('smoke test', (WidgetTester tester) async {
      await tester.pumpWidget(const CalculatorApp());

      expect(find.text('Over-Engineered Calculator'), findsWidgets);
    });

    testWidgets('Service URL is prefilled and API key starts empty',
        (WidgetTester tester) async {
      await tester.pumpWidget(const CalculatorApp());

      final urlField =
          tester.widget<TextField>(find.byKey(const Key('service-url-field')));
      final apiKeyField =
          tester.widget<TextField>(find.byKey(const Key('api-key-field')));

      expect(urlField.controller!.text, ApiConstants.defaultApiBaseUrl);
      expect(apiKeyField.controller!.text, isEmpty);
      expect(apiKeyField.obscureText, isTrue);
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

      await tester.pumpWidget(CalculatorApp(httpClient: mock));
      expect(historyCalls, 0);
      expect(find.text('Press refresh to load your calculations.'), findsOneWidget);

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
      final mock = MockClient((_) async => _json({'message': 'Not Found'}, 404));

      await tester.pumpWidget(CalculatorApp(httpClient: mock));
      await tester.ensureVisible(find.byKey(const Key('history-refresh')));
      await tester.tap(find.byKey(const Key('history-refresh')));
      await tester.pumpAndSettle();

      expect(find.text('This service does not provide a history.'), findsOneWidget);
    });
  });
}
