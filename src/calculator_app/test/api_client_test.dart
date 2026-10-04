import 'dart:convert';

import 'package:calculator_app/api_client.dart';
import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/token_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _baseUrl = 'https://api.example.com/api/sls/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

class FakeTokens implements TokenSource {
  String current = 'token-1';
  String renewed = 'token-2';
  int renewals = 0;
  bool expired = false;
  Object? validError;

  @override
  Future<String> validIdToken() async {
    if (validError != null) throw validError!;
    return current;
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    renewals++;
    current = renewed;
    return current;
  }

  @override
  void markExpired(String rejectedToken) => expired = true;
}

void main() {
  late FakeTokens tokens;
  final requests = <http.Request>[];

  setUp(() {
    tokens = FakeTokens();
    requests.clear();
  });

  CalculatorApiClient clientAnswering(
    http.Response Function(http.Request request) answer, {
    String baseUrl = _baseUrl,
  }) =>
      CalculatorApiClient(
        baseUrl: baseUrl,
        tokens: tokens,
        httpClient: MockClient((request) async {
          requests.add(request);
          return answer(request);
        }),
      );

  group('calculate', () {
    test('posts the operands with the bearer token and no API key', () async {
      final client =
          clientAnswering((_) => _json({'result': '5'}), baseUrl: '$_baseUrl/');

      expect(await client.calculate('add', 2, 3), '5');

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$_baseUrl/add');
      expect(request.headers['Authorization'], 'Bearer token-1');
      expect(request.headers.containsKey('x-api-key'), isFalse);
      expect(jsonDecode(request.body), {'a': 2.0, 'b': 3.0});
    });

    test('a 401 renews the token once and repeats the request once', () async {
      var calls = 0;
      final client = clientAnswering((request) {
        calls++;
        return calls == 1
            ? _json({'message': 'Unauthorized'}, 401)
            : _json({'result': '5'});
      });

      expect(await client.calculate('add', 2, 3), '5');

      expect(tokens.renewals, 1);
      expect(requests.map((r) => r.headers['Authorization']),
          ['Bearer token-1', 'Bearer token-2']);
      expect(tokens.expired, isFalse);
    });

    test('a second 401 expires the session', () async {
      final client = clientAnswering((_) => _json({'message': 'No'}, 401));

      await expectLater(
        client.calculate('add', 2, 3),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.message, 'message',
                'Your session has expired. Please log in again.')),
      );

      expect(requests, hasLength(2));
      expect(tokens.renewals, 1);
      expect(tokens.expired, isTrue);
    });

    test('a 403 shows the backend error and keeps the session', () async {
      final client = clientAnswering((_) => _json({
            'error': {'code': 'FORBIDDEN', 'message': 'Not allowed.'},
          }, 403));

      await expectLater(
        client.calculate('add', 2, 3),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 403)
            .having((e) => e.message, 'message', 'Not allowed.')),
      );

      expect(requests, hasLength(1));
      expect(tokens.renewals, 0);
      expect(tokens.expired, isFalse);
    });

    test('a token that cannot be obtained stops the request', () async {
      tokens.validError = const AuthApiException('Down.', statusCode: 503);
      final client = clientAnswering((_) => _json({'result': '5'}));

      await expectLater(
        client.calculate('add', 2, 3),
        throwsA(
            isA<ApiException>().having((e) => e.message, 'message', 'Down.')),
      );

      expect(requests, isEmpty);
    });

    test('error bodies are turned into readable messages', () async {
      Future<ApiException> failWith(http.Response response) async {
        final client = clientAnswering((_) => response);
        try {
          await client.calculate('div', 1, 0);
        } on ApiException catch (e) {
          return e;
        }
        fail('ApiException expected');
      }

      final domain = await failWith(_json({
        'error': {
          'code': 'DIVISION_BY_ZERO',
          'message': 'Cannot divide by zero.',
        },
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
        tokens: tokens,
        httpClient: MockClient((_) async => throw http.ClientException('boom')),
      );

      await expectLater(
        client.fetchHistory(),
        throwsA(isA<ApiException>().having(
          (e) => e.message,
          'message',
          'Connection to the server failed.',
        )),
      );
    });
  });

  group('fetchHistory', () {
    http.Response page() => _json({
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

    test('sends limit, cursor and the bearer token and parses the page',
        () async {
      final client = clientAnswering((_) => page());

      final result = await client.fetchHistory(limit: 5, cursor: 'abc');

      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/sls/v1/history');
      expect(request.url.queryParameters, {'limit': '5', 'cursor': 'abc'});
      expect(request.headers['Authorization'], 'Bearer token-1');
      expect(request.headers.containsKey('x-api-key'), isFalse);
      expect(result.nextCursor, 'next');
      expect(result.items.single.result, '8');
      expect(result.items.single.occurredAt, isNotNull);
    });

    test('a 401 is retried once with a renewed token', () async {
      var calls = 0;
      final client = clientAnswering(
          (_) => ++calls == 1 ? _json({'message': 'No'}, 401) : page());

      await client.fetchHistory();

      expect(requests.map((r) => r.headers['Authorization']),
          ['Bearer token-1', 'Bearer token-2']);
    });

    test('a second 401 expires the session', () async {
      final client = clientAnswering((_) => _json({'message': 'No'}, 401));

      await expectLater(client.fetchHistory(), throwsA(isA<ApiException>()));

      expect(requests, hasLength(2));
      expect(tokens.expired, isTrue);
    });

    test('a 403 keeps the session', () async {
      final client = clientAnswering((_) => _json({'message': 'No'}, 403));

      await expectLater(client.fetchHistory(), throwsA(isA<ApiException>()));

      expect(requests, hasLength(1));
      expect(tokens.expired, isFalse);
    });

    test('a 404 keeps its status code', () async {
      final client =
          clientAnswering((_) => _json({'message': 'Not Found'}, 404));

      await expectLater(
        client.fetchHistory(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });

  group('trusted Service URL', () {
    bool trusted(String url) =>
        CalculatorApiClient(baseUrl: url, tokens: tokens).hasTrustedBaseUrl;

    test('only https, http://localhost and http://127.0.0.1 are trusted', () {
      expect(trusted(_baseUrl), isTrue);
      expect(trusted('http://localhost:8080/api'), isTrue);
      expect(trusted('http://127.0.0.1:8080/api'), isTrue);
      expect(trusted('http://api.example.com/api'), isFalse);
      expect(trusted('http://localhost.evil.com/api'), isFalse);
      expect(trusted('ftp://example.com'), isFalse);
      expect(trusted('not a url'), isFalse);
      expect(trusted(''), isFalse);
    });

    test('https and localhost requests carry the bearer token', () async {
      for (final url in [_baseUrl, 'http://localhost:8080/api']) {
        requests.clear();
        final client =
            clientAnswering((_) => _json({'result': '5'}), baseUrl: url);

        await client.calculate('add', 2, 3);

        expect(requests.single.headers['Authorization'], 'Bearer token-1');
      }
    });

    test('an http URL makes no request and asks for the token never', () async {
      final client = clientAnswering((_) => _json({'result': '5'}),
          baseUrl: 'http://api.example.com/api');
      tokens.validError = StateError('the token must not be requested');

      await expectLater(
        client.calculate('add', 2, 3),
        throwsA(isA<ApiException>().having(
            (e) => e.message, 'message', 'The Service URL must use https.')),
      );
      await expectLater(
        client.fetchHistory(),
        throwsA(isA<ApiException>().having(
            (e) => e.message, 'message', 'The Service URL must use https.')),
      );

      expect(requests, isEmpty);
    });
  });

  test('hasValidBaseUrl requires an absolute http(s) URL', () {
    bool valid(String url) =>
        CalculatorApiClient(baseUrl: url, tokens: tokens).hasValidBaseUrl;

    expect(valid(_baseUrl), isTrue);
    expect(valid('/api/ecs/v1'), isFalse);
    expect(valid('ftp://example.com'), isFalse);
    expect(valid(''), isFalse);
  });
}
