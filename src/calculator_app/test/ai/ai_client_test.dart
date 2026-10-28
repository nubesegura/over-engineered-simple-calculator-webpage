import 'dart:convert';

import 'package:calculator_app/ai/ai_calculator_client.dart';
import 'package:calculator_app/ai/ai_errors.dart';
import 'package:calculator_app/ai/ai_models.dart';
import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/token_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeTokenSource implements TokenSource {
  _FakeTokenSource({
    this.currentToken = 'initial-token',
    this.renewedToken = 'renewed-token',
    this.failValidToken = false,
  });

  String currentToken;
  final String renewedToken;
  final bool failValidToken;
  int renewCallCount = 0;
  String? markedExpiredToken;

  @override
  Future<String> validIdToken() async {
    if (failValidToken) {
      throw const AuthApiException('No active session found.');
    }
    return currentToken;
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    renewCallCount++;
    currentToken = renewedToken;
    return renewedToken;
  }

  @override
  void markExpired(String rejectedToken) {
    markedExpiredToken = rejectedToken;
  }
}

class _FailingRenewalTokenSource implements TokenSource {
  @override
  Future<String> validIdToken() async => 'test-token';

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    throw Exception('Failed to renew token');
  }

  @override
  void markExpired(String rejectedToken) {}
}

void main() {
  const validBaseUrl =
      'https://ai.over-engineered-simple-calculator.dev.nube-segura.com';

  group('AiCalculatorClient URL validation', () {
    test('accepts trusted https URL and localhost', () {
      final tokens = _FakeTokenSource();
      final clientHttps = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: tokens,
      );
      expect(clientHttps.hasValidBaseUrl, isTrue);
      expect(clientHttps.hasTrustedBaseUrl, isTrue);

      final clientLocal = AiCalculatorClient(
        baseUrl: 'http://localhost:8000',
        tokenSource: tokens,
      );
      expect(clientLocal.hasValidBaseUrl, isTrue);
      expect(clientLocal.hasTrustedBaseUrl, isTrue);
    });

    test('rejects untrusted plain HTTP non-localhost URL', () async {
      final tokens = _FakeTokenSource();
      final client = AiCalculatorClient(
        baseUrl: 'http://insecure-domain.com',
        tokenSource: tokens,
      );
      expect(client.hasTrustedBaseUrl, isFalse);

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: '2 + 2')),
        throwsA(isA<AiException>()),
      );
    });

    test('rejects invalid or malformed URL', () async {
      final tokens = _FakeTokenSource();
      final client = AiCalculatorClient(
        baseUrl: 'not-a-valid-url',
        tokenSource: tokens,
      );
      expect(client.hasValidBaseUrl, isFalse);

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: '2 + 2')),
        throwsA(isA<AiException>()),
      );
    });
  });

  group('AiCalculatorClient execution', () {
    test('sends POST /calculate with authorization header and parses 200 OK',
        () async {
      final tokens = _FakeTokenSource(currentToken: 'secret-token-123');
      late http.Request capturedRequest;

      final mockHttp = MockClient((request) async {
        capturedRequest = request;
        final responseData = {
          'answer': '2 + 2 es 4',
          'language': 'es',
          'mode': 'tool',
          'request_id': 'req-mock-1',
          'calculation': {
            'a': 2,
            'b': 2,
            'operation': 'add',
            'result': 4,
          },
        };
        return http.Response(
          jsonEncode(responseData),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: tokens,
        httpClient: mockHttp,
      );

      final response = await client.calculate(
        const AiCalculateRequest(sentence: '2 + 2', mode: AiMode.tool),
      );

      expect(capturedRequest.method, 'POST');
      expect(
        capturedRequest.url.toString(),
        '$validBaseUrl/calculate',
      );
      expect(
        capturedRequest.headers['authorization'],
        'Bearer secret-token-123',
      );
      expect(
        capturedRequest.headers['content-type'],
        contains('application/json'),
      );
      expect(
        jsonDecode(capturedRequest.body),
        {'sentence': '2 + 2', 'mode': 'tool'},
      );

      expect(response.answer, '2 + 2 es 4');
      expect(response.language, 'es');
      expect(response.mode, AiMode.tool);
      expect(response.requestId, 'req-mock-1');
      expect(response.calculation?.formattedFormula, '2 + 2 = 4');
    });

    test('retries on 401 with renewed token and succeeds if second call passes',
        () async {
      final tokens = _FakeTokenSource(
        currentToken: 'expired-token',
        renewedToken: 'fresh-token',
      );
      int callCount = 0;

      final mockHttp = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          expect(request.headers['authorization'], 'Bearer expired-token');
          return http.Response(
            jsonEncode({
              'error': {'code': 'UNAUTHORIZED', 'message': 'Token expired'}
            }),
            401,
          );
        }
        expect(request.headers['authorization'], 'Bearer fresh-token');
        return http.Response(
          jsonEncode({
            'answer': 'Success after refresh',
            'language': 'en',
            'mode': 'model',
            'request_id': 'req-refreshed',
          }),
          200,
        );
      });

      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: tokens,
        httpClient: mockHttp,
      );

      final result = await client.calculate(
        const AiCalculateRequest(sentence: 'hello', mode: AiMode.model),
      );

      expect(callCount, 2);
      expect(tokens.renewCallCount, 1);
      expect(result.answer, 'Success after refresh');
    });

    test(
        'marks token expired and throws AiUnauthorizedException if second 401 occurs',
        () async {
      final tokens = _FakeTokenSource(
        currentToken: 'bad-token-1',
        renewedToken: 'bad-token-2',
      );

      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {'code': 'UNAUTHORIZED', 'message': 'Invalid token'}
          }),
          401,
        );
      });

      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: tokens,
        httpClient: mockHttp,
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'test')),
        throwsA(isA<AiUnauthorizedException>()),
      );
      // Wait for async throw
      try {
        await client.calculate(const AiCalculateRequest(sentence: 'test'));
      } catch (_) {}

      expect(tokens.markedExpiredToken, 'bad-token-2');
    });

    test(
        'throws AiUnauthorizedException when TokenSource fails to provide valid token',
        () async {
      final tokens = _FakeTokenSource(failValidToken: true);
      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: tokens,
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'test')),
        throwsA(isA<AiUnauthorizedException>()),
      );
    });

    test('throws AiUnauthorizedException when valid token is empty string',
        () async {
      final tokens = _FakeTokenSource(currentToken: '');
      final client = AiCalculatorClient(
        baseUrl: '$validBaseUrl/', // test trailing slash trimming too
        tokenSource: tokens,
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'test')),
        throwsA(isA<AiUnauthorizedException>()),
      );
    });

    test('marks token expired and throws if renewal throws an exception',
        () async {
      // Create a mock that returns 401
      final mockHttp =
          MockClient((_) async => http.Response('Unauthorized', 401));

      // Token source whose renewal throws
      final failingTokens = _FailingRenewalTokenSource();
      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: failingTokens,
        httpClient: mockHttp,
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'test')),
        throwsA(isA<AiUnauthorizedException>()),
      );
    });

    test('maps 400, 422, 429, 504 to typed exceptions', () async {
      final errorCodes = [
        (400, 'INVALID_PAYLOAD', InvalidPayloadException),
        (422, 'UNPARSEABLE_SENTENCE', UnparseableSentenceException),
        (422, 'DIVISION_BY_ZERO', DivisionByZeroException),
        (422, 'GUARDRAIL_INTERVENTION', GuardrailInterventionException),
        (429, 'RATE_LIMIT_EXCEEDED', AiRateLimitException),
        (504, 'UPSTREAM_TIMEOUT', AiUpstreamTimeoutException),
        (500, 'UNKNOWN_ERROR', AiUnknownException),
      ];

      for (final (statusCode, code, expectedType) in errorCodes) {
        final mockHttp = MockClient((_) async {
          return http.Response(
            jsonEncode({
              'error': {
                'code': code,
                'message': 'Error message for $code',
                'request_id': 'req-$code',
              }
            }),
            statusCode,
          );
        });

        final client = AiCalculatorClient(
          baseUrl: validBaseUrl,
          tokenSource: _FakeTokenSource(),
          httpClient: mockHttp,
        );

        try {
          await client.calculate(const AiCalculateRequest(sentence: 'calc'));
          fail('Should have thrown an exception for $code');
        } catch (e) {
          expect(e.runtimeType, expectedType);
          expect((e as AiException).code, code);
          expect(e.requestId, 'req-$code');
        }
      }
    });

    test('maps socket or network failures to AiNetworkException', () async {
      final mockHttp = MockClient((_) async {
        throw http.ClientException('Network down');
      });

      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: _FakeTokenSource(),
        httpClient: mockHttp,
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'calc')),
        throwsA(isA<AiNetworkException>()),
      );
    });

    test('maps client request timeout to AiUpstreamTimeoutException', () async {
      final mockHttp = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('{}', 200);
      });

      final client = AiCalculatorClient(
        baseUrl: validBaseUrl,
        tokenSource: _FakeTokenSource(),
        httpClient: mockHttp,
        requestTimeout: const Duration(milliseconds: 10),
      );

      expect(
        () => client.calculate(const AiCalculateRequest(sentence: 'calc')),
        throwsA(isA<AiUpstreamTimeoutException>()),
      );
    });
  });
}
