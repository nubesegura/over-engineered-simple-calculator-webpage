import 'package:calculator_app/ai/ai_assistant_controller.dart';
import 'package:calculator_app/ai/ai_calculator_client.dart';
import 'package:calculator_app/ai/ai_errors.dart';
import 'package:calculator_app/ai/ai_models.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements AiCalculatorClient {
  _FakeClient({this.calculateHandler});

  Future<AiCalculateResponse> Function(AiCalculateRequest)? calculateHandler;
  int calculateCount = 0;
  AiCalculateRequest? lastRequest;

  @override
  bool get hasValidBaseUrl => true;

  @override
  bool get hasTrustedBaseUrl => true;

  @override
  Future<AiCalculateResponse> calculate(AiCalculateRequest request) async {
    calculateCount++;
    lastRequest = request;
    if (calculateHandler != null) {
      return calculateHandler!(request);
    }
    return const AiCalculateResponse(
      answer: 'Mock Answer',
      language: 'en',
      mode: AiMode.tool,
      requestId: 'req-fake-123',
    );
  }
}

class _FakeStopwatch implements Stopwatch {
  final int _elapsed = 150;

  @override
  int get elapsedMilliseconds => _elapsed;

  @override
  Duration get elapsed => Duration(milliseconds: _elapsed);

  @override
  int get elapsedMicroseconds => _elapsed * 1000;

  @override
  int get elapsedTicks => _elapsed;

  @override
  int get frequency => 1000;

  @override
  bool get isRunning => false;

  @override
  void reset() {}

  @override
  void start() {}

  @override
  void stop() {}
}

void main() {
  group('AiAssistantController initialization & property updates', () {
    test('initializes with default state', () {
      final client = _FakeClient();
      final controller = AiAssistantController(client: client);

      expect(controller.sentence, '');
      expect(controller.mode, AiMode.tool);
      expect(controller.isLoading, isFalse);
      expect(controller.response, isNull);
      expect(controller.errorMessage, isNull);
      expect(controller.responseMs, isNull);
      expect(controller.requestId, isNull);
      expect(controller.canSubmit, isFalse);
    });

    test('setSentence updates sentence and canSubmit', () {
      final controller = AiAssistantController(client: _FakeClient());
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.setSentence('What is 5 plus 5?');
      expect(controller.sentence, 'What is 5 plus 5?');
      expect(controller.canSubmit, isTrue);
      expect(notifyCount, 1);

      controller.setSentence('   ');
      expect(controller.canSubmit, isFalse);
      expect(notifyCount, 2);

      final overLimit = 'a' * 201;
      controller.setSentence(overLimit);
      expect(controller.canSubmit, isFalse);
    });

    test('editing sentence or mode clears previous result and metrics',
        () async {
      final controller = AiAssistantController(
        client: _FakeClient(),
        stopwatchFactory: _FakeStopwatch.new,
      );

      controller.setSentence('2 + 2');
      await controller.submit();

      expect(controller.response, isNotNull);
      expect(controller.responseMs, 150);
      expect(controller.requestId, 'req-fake-123');

      // Edit sentence
      controller.setSentence('2 + 3');
      expect(controller.response, isNull);
      expect(controller.responseMs, isNull);
      expect(controller.requestId, isNull);

      // Submit again
      await controller.submit();
      expect(controller.response, isNotNull);

      // Change mode
      controller.setMode(AiMode.model);
      expect(controller.mode, AiMode.model);
      expect(controller.response, isNull);
      expect(controller.responseMs, isNull);
    });

    test('reset restores initial state', () async {
      final controller = AiAssistantController(client: _FakeClient());
      controller.setSentence('2 + 2');
      controller.setMode(AiMode.model);
      await controller.submit();

      controller.reset();

      expect(controller.sentence, '');
      expect(controller.mode, AiMode.tool);
      expect(controller.isLoading, isFalse);
      expect(controller.response, isNull);
      expect(controller.errorMessage, isNull);
      expect(controller.responseMs, isNull);
      expect(controller.requestId, isNull);
      expect(controller.canSubmit, isFalse);
    });
  });

  group('AiAssistantController submit workflow', () {
    test('does not submit when canSubmit is false', () async {
      final client = _FakeClient();
      final controller = AiAssistantController(client: client);

      await controller.submit();
      expect(client.calculateCount, 0);

      controller.setSentence('   ');
      await controller.submit();
      expect(client.calculateCount, 0);
    });

    test('successful submission sets response, requestId, and responseMs',
        () async {
      final client = _FakeClient(
        calculateHandler: (req) async => const AiCalculateResponse(
          answer: '3 por 3 es 9',
          language: 'es',
          mode: AiMode.tool,
          requestId: 'req-success-123',
          calculation: AiCalculationBreakdown(
            a: 3,
            b: 3,
            operation: 'mul',
            result: 9,
          ),
        ),
      );

      final controller = AiAssistantController(
        client: client,
        stopwatchFactory: _FakeStopwatch.new,
      );

      controller.setSentence('3 * 3');
      final submitFuture = controller.submit();

      expect(controller.isLoading, isTrue);

      await submitFuture;

      expect(controller.isLoading, isFalse);
      expect(controller.errorMessage, isNull);
      expect(controller.response?.answer, '3 por 3 es 9');
      expect(controller.response?.calculation?.formattedFormula, '3 × 3 = 9');
      expect(controller.requestId, 'req-success-123');
      expect(controller.responseMs, 150);
      expect(client.lastRequest?.sentence, '3 * 3');
      expect(client.lastRequest?.mode, AiMode.tool);
    });

    test('handles AiException by extracting message and requestId', () async {
      final client = _FakeClient(
        calculateHandler: (_) async =>
            throw const GuardrailInterventionException(
          'Input violates safety guardrails.',
          requestId: 'req-guardrail-999',
        ),
      );

      final controller = AiAssistantController(
        client: client,
        stopwatchFactory: _FakeStopwatch.new,
      );

      controller.setSentence('Harmful prompt');
      await controller.submit();

      expect(controller.isLoading, isFalse);
      expect(controller.response, isNull);
      expect(
        controller.errorMessage,
        'Input violates safety guardrails.',
      );
      expect(controller.requestId, 'req-guardrail-999');
      expect(controller.responseMs, 150);
    });

    test('handles general unexpected exceptions', () async {
      final client = _FakeClient(
        calculateHandler: (_) async => throw Exception('Unexpected failure'),
      );

      final controller = AiAssistantController(
        client: client,
        stopwatchFactory: _FakeStopwatch.new,
      );

      controller.setSentence('Divide 10 by 2');
      await controller.submit();

      expect(controller.isLoading, isFalse);
      expect(controller.response, isNull);
      expect(controller.errorMessage, contains('Unexpected failure'));
    });
  });
}
