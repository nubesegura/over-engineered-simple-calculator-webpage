import 'dart:async';

import 'package:calculator_app/ai/ai_assistant_controller.dart';
import 'package:calculator_app/ai/ai_assistant_view.dart';
import 'package:calculator_app/ai/ai_calculator_client.dart';
import 'package:calculator_app/ai/ai_constants.dart';
import 'package:calculator_app/ai/ai_errors.dart';
import 'package:calculator_app/ai/ai_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockAiClient implements AiCalculatorClient {
  _MockAiClient({this.onCalculate});

  Future<AiCalculateResponse> Function(AiCalculateRequest)? onCalculate;
  int calculateCallCount = 0;
  AiCalculateRequest? lastRequest;

  @override
  bool get hasValidBaseUrl => true;

  @override
  bool get hasTrustedBaseUrl => true;

  @override
  Future<AiCalculateResponse> calculate(AiCalculateRequest request) async {
    calculateCallCount++;
    lastRequest = request;
    if (onCalculate != null) {
      return onCalculate!(request);
    }
    return const AiCalculateResponse(
      answer: 'Mock result answer',
      language: 'en',
      mode: AiMode.tool,
      requestId: 'mock-req-id',
      calculation: AiCalculationBreakdown(
        a: 12.5,
        b: 4,
        operation: 'mul',
        result: 50,
      ),
    );
  }
}

Widget _wrapView(AiAssistantController controller) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      body: AiAssistantView(controller: controller),
    ),
  );
}

void main() {
  group('AiAssistantView rendering and interaction', () {
    testWidgets('renders all initial components correctly', (tester) async {
      final client = _MockAiClient();
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      expect(find.byKey(const Key('ai-assistant-view')), findsOneWidget);
      expect(find.byKey(const Key('ai-mode-selector')), findsOneWidget);
      expect(find.byKey(const Key('ai-prompt-field')), findsOneWidget);
      expect(find.byKey(const Key('ai-calculate-button')), findsOneWidget);
      expect(find.byKey(const Key('ai-history-notice')), findsOneWidget);
      expect(find.text(AiConstants.calculationHistoryNotice), findsOneWidget);

      // Initially, calculate button is disabled because sentence is empty
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('ai-calculate-button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets(
        'typing prompt enables calculate button; clear button clears input',
        (tester) async {
      final client = _MockAiClient();
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      // Enter prompt
      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        'What is 10 plus 20?',
      );
      await tester.pump();

      expect(controller.sentence, 'What is 10 plus 20?');
      var button = tester.widget<FilledButton>(
        find.byKey(const Key('ai-calculate-button')),
      );
      expect(button.onPressed, isNotNull);

      // Clear button should be visible
      expect(find.byKey(const Key('ai-prompt-clear-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai-prompt-clear-button')));
      await tester.pump();

      expect(controller.sentence, '');
      button = tester.widget<FilledButton>(
        find.byKey(const Key('ai-calculate-button')),
      );
      expect(button.onPressed, isNull);
      expect(find.byKey(const Key('ai-prompt-clear-button')), findsNothing);
    });

    testWidgets('mode selector switches between Tool and Model modes',
        (tester) async {
      final client = _MockAiClient();
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      expect(controller.mode, AiMode.tool);

      // Tap direct model
      await tester.tap(find.text('Direct Model (Probabilistic)'));
      await tester.pump();

      expect(controller.mode, AiMode.model);

      // Tap tool-assisted
      await tester.tap(find.text('Tool-Assisted (Deterministic)'));
      await tester.pump();

      expect(controller.mode, AiMode.tool);
    });

    testWidgets(
        'successful calculation displays result card with math breakdown badge',
        (tester) async {
      final client = _MockAiClient(
        onCalculate: (req) async => const AiCalculateResponse(
          answer: 'El resultado de multiplicar 12.5 por 4 es 50.',
          language: 'es',
          mode: AiMode.tool,
          requestId: 'req-success-789',
          calculation: AiCalculationBreakdown(
            a: 12.5,
            b: 4,
            operation: 'mul',
            result: 50,
          ),
        ),
      );
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        'Multiplica 12.5 por 4',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai-calculate-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-result-card')), findsOneWidget);
      expect(
        find.text('El resultado de multiplicar 12.5 por 4 es 50.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ai-calculation-badge')), findsOneWidget);
      expect(find.text('12.5 × 4 = 50'), findsOneWidget);
      expect(find.text('ES'), findsOneWidget);
      expect(find.text('Tool-Assisted'), findsOneWidget);
      expect(find.textContaining('req-success-789'), findsOneWidget);
    });

    testWidgets(
        'shows loading progress indicator while calculation is in-flight',
        (tester) async {
      final completer = Completer<AiCalculateResponse>();
      final client = _MockAiClient(onCalculate: (_) => completer.future);
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        '2 + 2',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai-calculate-button')));
      await tester.pump();

      expect(find.byKey(const Key('ai-loading-indicator')), findsOneWidget);

      completer.complete(
        const AiCalculateResponse(
          answer: '4',
          language: 'en',
          mode: AiMode.tool,
          requestId: 'req-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-loading-indicator')), findsNothing);
      expect(find.byKey(const Key('ai-result-card')), findsOneWidget);
    });

    testWidgets('displays error banner when backend returns typed error',
        (tester) async {
      final client = _MockAiClient(
        onCalculate: (_) async => throw const GuardrailInterventionException(
          'Query was blocked by safety guardrails.',
          requestId: 'req-guard-123',
        ),
      );
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        'test prompt',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai-calculate-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-error-banner')), findsOneWidget);
      expect(
        find.text('Query was blocked by safety guardrails.'),
        findsOneWidget,
      );
      expect(find.textContaining('req-guard-123'), findsOneWidget);
      expect(find.byKey(const Key('ai-result-card')), findsNothing);
    });

    testWidgets('editing input or mode clears previous result and error banner',
        (tester) async {
      final client = _MockAiClient();
      final controller = AiAssistantController(client: client);

      await tester.pumpWidget(_wrapView(controller));

      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        '10 + 10',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('ai-calculate-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ai-result-card')), findsOneWidget);

      // Edit prompt
      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        '10 + 20',
      );
      await tester.pump();

      expect(find.byKey(const Key('ai-result-card')), findsNothing);
    });
  });
}
