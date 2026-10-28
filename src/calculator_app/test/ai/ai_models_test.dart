import 'package:calculator_app/ai/ai_constants.dart';
import 'package:calculator_app/ai/ai_errors.dart';
import 'package:calculator_app/ai/ai_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AiConstants', () {
    test('has expected default configuration values', () {
      expect(
        AiConstants.defaultBaseUrl,
        'https://ai.over-engineered-simple-calculator.dev.nube-segura.com',
      );
      expect(AiConstants.calculatePath, '/calculate');
      expect(AiConstants.maxSentenceLength, 200);
      expect(AiConstants.defaultMode, AiMode.tool);
      expect(AiConstants.requestTimeout, const Duration(seconds: 30));
    });

    test('effectiveBaseUrl falls back to defaultBaseUrl when env is not set',
        () {
      expect(
        AiConstants.effectiveBaseUrl(),
        AiConstants.defaultBaseUrl,
      );
    });
  });

  group('AiMode', () {
    test('serializes and parses correctly', () {
      expect(AiMode.tool.name, 'tool');
      expect(AiMode.model.name, 'model');

      expect(AiMode.fromString('tool'), AiMode.tool);
      expect(AiMode.fromString('model'), AiMode.model);
      expect(AiMode.fromString('invalid'), AiMode.tool);
    });

    test('has user-friendly display labels', () {
      expect(AiMode.tool.label, 'Tool-Assisted');
      expect(AiMode.model.label, 'Direct Model');
    });
  });

  group('AiCalculateRequest', () {
    test('serializes to JSON with defaults', () {
      const req = AiCalculateRequest(sentence: 'What is 2 plus 2?');
      expect(req.sentence, 'What is 2 plus 2?');
      expect(req.mode, AiMode.tool);
      expect(req.toJson(), {
        'sentence': 'What is 2 plus 2?',
        'mode': 'tool',
      });
    });

    test('serializes to JSON with custom mode', () {
      const req = AiCalculateRequest(
        sentence: 'Multiplica 5 por 6',
        mode: AiMode.model,
      );
      expect(req.toJson(), {
        'sentence': 'Multiplica 5 por 6',
        'mode': 'model',
      });
    });
  });

  group('AiCalculationBreakdown', () {
    test('deserializes from JSON and formats formula', () {
      final breakdown = AiCalculationBreakdown.fromJson({
        'a': 12.5,
        'b': 4,
        'operation': 'mul',
        'result': 50,
      });

      expect(breakdown.a, 12.5);
      expect(breakdown.b, 4);
      expect(breakdown.operation, 'mul');
      expect(breakdown.result, 50);
      expect(breakdown.formattedFormula, '12.5 × 4 = 50');
    });

    test('formats other operations correctly', () {
      expect(
        AiCalculationBreakdown(a: 10, b: 2, operation: 'add', result: 12)
            .formattedFormula,
        '10 + 2 = 12',
      );
      expect(
        AiCalculationBreakdown(a: 10, b: 2, operation: 'sub', result: 8)
            .formattedFormula,
        '10 - 2 = 8',
      );
      expect(
        AiCalculationBreakdown(a: 10, b: 2, operation: 'div', result: 5)
            .formattedFormula,
        '10 ÷ 2 = 5',
      );
      expect(
        AiCalculationBreakdown(a: 10, b: 2, operation: 'unknown_op', result: 10)
            .formattedFormula,
        '10 unknown_op 2 = 10',
      );
    });
  });

  group('AiCalculateResponse', () {
    test('deserializes complete 200 OK response with calculation breakdown',
        () {
      final json = {
        'answer': 'El resultado de multiplicar 12.5 por 4 es 50.',
        'language': 'es',
        'mode': 'tool',
        'request_id': 'req-abc-123',
        'calculation': {
          'a': 12.5,
          'b': 4,
          'operation': 'mul',
          'result': 50,
        },
      };

      final response = AiCalculateResponse.fromJson(json);
      expect(
        response.answer,
        'El resultado de multiplicar 12.5 por 4 es 50.',
      );
      expect(response.language, 'es');
      expect(response.mode, AiMode.tool);
      expect(response.requestId, 'req-abc-123');
      expect(response.calculation, isNotNull);
      expect(response.calculation!.formattedFormula, '12.5 × 4 = 50');
    });

    test('deserializes response without calculation breakdown', () {
      final json = {
        'answer': 'Hello, how can I help you?',
        'language': 'en',
        'mode': 'model',
        'request_id': 'req-xyz-789',
      };

      final response = AiCalculateResponse.fromJson(json);
      expect(response.answer, 'Hello, how can I help you?');
      expect(response.language, 'en');
      expect(response.mode, AiMode.model);
      expect(response.requestId, 'req-xyz-789');
      expect(response.calculation, isNull);
    });

    test('supports equality, hashCode, and toString across models', () {
      const req1 = AiCalculateRequest(sentence: '2 + 2', mode: AiMode.tool);
      const req2 = AiCalculateRequest(sentence: '2 + 2', mode: AiMode.tool);
      const req3 = AiCalculateRequest(sentence: '2 + 3', mode: AiMode.model);

      expect(req1, req2);
      expect(req1 == req3, isFalse);
      expect(req1.hashCode, req2.hashCode);
      expect(req1.toString(), contains('2 + 2'));

      const b1 =
          AiCalculationBreakdown(a: 2, b: 2, operation: 'add', result: 4);
      const b2 =
          AiCalculationBreakdown(a: 2, b: 2, operation: 'add', result: 4);
      const b3 =
          AiCalculationBreakdown(a: 2, b: 3, operation: 'add', result: 5);

      expect(b1, b2);
      expect(b1 == b3, isFalse);
      expect(b1.hashCode, b2.hashCode);
      expect(b1.toString(), contains('add'));

      const res1 = AiCalculateResponse(
        answer: 'Ans',
        language: 'en',
        mode: AiMode.tool,
        requestId: 'req-1',
        calculation: b1,
      );
      const res2 = AiCalculateResponse(
        answer: 'Ans',
        language: 'en',
        mode: AiMode.tool,
        requestId: 'req-1',
        calculation: b2,
      );
      const res3 = AiCalculateResponse(
        answer: 'Other',
        language: 'es',
        mode: AiMode.model,
        requestId: 'req-2',
      );

      expect(res1, res2);
      expect(res1 == res3, isFalse);
      expect(res1.hashCode, res2.hashCode);
      expect(res1.toString(), contains('req-1'));
    });
  });

  group('AiException Taxonomy & Parser', () {
    test('maps 400 INVALID_PAYLOAD to InvalidPayloadException', () {
      final exc = AiException.fromResponse(
        statusCode: 400,
        body: {
          'error': {
            'code': 'INVALID_PAYLOAD',
            'message': 'Sentence cannot be empty.',
            'request_id': 'req-400',
          }
        },
      );
      expect(exc, isA<InvalidPayloadException>());
      expect(exc.statusCode, 400);
      expect(exc.code, 'INVALID_PAYLOAD');
      expect(exc.message, 'Sentence cannot be empty.');
      expect(exc.requestId, 'req-400');
    });

    test('maps 401 UNAUTHORIZED to AiUnauthorizedException', () {
      final exc = AiException.fromResponse(
        statusCode: 401,
        body: {
          'error': {
            'code': 'UNAUTHORIZED',
            'message': 'Token expired.',
            'request_id': 'req-401',
          }
        },
      );
      expect(exc, isA<AiUnauthorizedException>());
      expect(exc.statusCode, 401);
      expect(exc.code, 'UNAUTHORIZED');
    });

    test('maps 422 UNPARSEABLE_SENTENCE to UnparseableSentenceException', () {
      final exc = AiException.fromResponse(
        statusCode: 422,
        body: {
          'error': {
            'code': 'UNPARSEABLE_SENTENCE',
            'message': 'Could not extract arithmetic expression.',
            'request_id': 'req-422-1',
          }
        },
      );
      expect(exc, isA<UnparseableSentenceException>());
      expect(exc.statusCode, 422);
      expect(exc.code, 'UNPARSEABLE_SENTENCE');
    });

    test('maps 422 DIVISION_BY_ZERO to DivisionByZeroException', () {
      final exc = AiException.fromResponse(
        statusCode: 422,
        body: {
          'error': {
            'code': 'DIVISION_BY_ZERO',
            'message': 'Division by zero is not allowed.',
            'request_id': 'req-422-2',
          }
        },
      );
      expect(exc, isA<DivisionByZeroException>());
      expect(exc.statusCode, 422);
      expect(exc.code, 'DIVISION_BY_ZERO');
    });

    test('maps 422 GUARDRAIL_INTERVENTION to GuardrailInterventionException',
        () {
      final exc = AiException.fromResponse(
        statusCode: 422,
        body: {
          'error': {
            'code': 'GUARDRAIL_INTERVENTION',
            'message': 'Blocked by safety guardrails.',
            'request_id': 'req-422-3',
          }
        },
      );
      expect(exc, isA<GuardrailInterventionException>());
      expect(exc.statusCode, 422);
      expect(exc.code, 'GUARDRAIL_INTERVENTION');
    });

    test(
        'maps 429 RATE_LIMIT_EXCEEDED and QUOTA_EXCEEDED to AiRateLimitException',
        () {
      final exc1 = AiException.fromResponse(
        statusCode: 429,
        body: {
          'error': {
            'code': 'RATE_LIMIT_EXCEEDED',
            'message': 'Rate limit exceeded.',
            'request_id': 'req-429-1',
          }
        },
      );
      expect(exc1, isA<AiRateLimitException>());
      expect(exc1.statusCode, 429);
      expect(exc1.code, 'RATE_LIMIT_EXCEEDED');

      final exc2 = AiException.fromResponse(
        statusCode: 429,
        body: {
          'error': {
            'code': 'QUOTA_EXCEEDED',
            'message': 'Daily quota exceeded.',
            'request_id': 'req-429-2',
          }
        },
      );
      expect(exc2, isA<AiRateLimitException>());
      expect(exc2.code, 'QUOTA_EXCEEDED');
    });

    test('maps 504 UPSTREAM_TIMEOUT to AiUpstreamTimeoutException', () {
      final exc = AiException.fromResponse(
        statusCode: 504,
        body: {
          'error': {
            'code': 'UPSTREAM_TIMEOUT',
            'message': 'Upstream timed out.',
            'request_id': 'req-504',
          }
        },
      );
      expect(exc, isA<AiUpstreamTimeoutException>());
      expect(exc.statusCode, 504);
      expect(exc.code, 'UPSTREAM_TIMEOUT');
    });

    test('maps unknown status codes to generic AiUnknownException', () {
      final exc = AiException.fromResponse(
        statusCode: 500,
        body: {
          'error': {
            'code': 'INTERNAL_ERROR',
            'message': 'Internal server error occurred.',
            'request_id': 'req-500',
          }
        },
      );
      expect(exc, isA<AiUnknownException>());
      expect(exc.statusCode, 500);
      expect(exc.code, 'INTERNAL_ERROR');
      expect(exc.message, 'Internal server error occurred.');
    });

    test('handles empty body or missing fields with default messages', () {
      final exc = AiException.fromResponse(
        statusCode: 500,
        body: null,
        fallbackMessage: 'Fallback message',
      );
      expect(exc, isA<AiUnknownException>());
      expect(exc.message, 'Fallback message');
    });

    test('network exception has appropriate default message', () {
      const exc = AiNetworkException('Cannot connect to AI service');
      expect(exc.message, 'Cannot connect to AI service');
      expect(exc.statusCode, isNull);
    });

    test('extracts top-level fields when error object is omitted', () {
      final exc = AiException.fromResponse(
        statusCode: 422,
        body: {
          'code': 'UNPARSEABLE_SENTENCE',
          'message': 'Direct message',
          'requestId': 'req-top-level',
        },
      );
      expect(exc, isA<UnparseableSentenceException>());
      expect(exc.message, 'Direct message');
      expect(exc.requestId, 'req-top-level');
      expect(exc.toString(), 'Direct message');
    });
  });
}
