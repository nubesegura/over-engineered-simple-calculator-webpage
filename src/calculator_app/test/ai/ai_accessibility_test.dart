import 'package:calculator_app/ai/ai_assistant_controller.dart';
import 'package:calculator_app/ai/ai_assistant_view.dart';
import 'package:calculator_app/ai/ai_calculator_client.dart';
import 'package:calculator_app/ai/ai_constants.dart';
import 'package:calculator_app/ai/ai_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAiClient implements AiCalculatorClient {
  @override
  bool get hasValidBaseUrl => true;

  @override
  bool get hasTrustedBaseUrl => true;

  @override
  Future<AiCalculateResponse> calculate(AiCalculateRequest request) async {
    return const AiCalculateResponse(
      answer: 'Accessibility mock answer',
      language: 'en',
      mode: AiMode.tool,
      requestId: 'req-a11y-123',
    );
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: child),
  );
}

void main() {
  group('AI Assistant Accessibility', () {
    testWidgets('interactive controls meet minimum 48x48 touch target size',
        (tester) async {
      final controller = AiAssistantController(client: _FakeAiClient());

      await tester.pumpWidget(_wrap(AiAssistantView(controller: controller)));

      // Check calculate button touch target size
      final calculateButtonFinder =
          find.byKey(const Key('ai-calculate-button'));
      final calculateButtonSize = tester.getSize(calculateButtonFinder);
      expect(
        calculateButtonSize.height,
        greaterThanOrEqualTo(AiConstants.minTouchTargetSize),
      );
      expect(
        calculateButtonSize.width,
        greaterThanOrEqualTo(AiConstants.minTouchTargetSize),
      );

      // Check mode selector touch target sizes
      final modeSelectorFinder = find.byKey(const Key('ai-mode-selector'));
      final modeSelectorSize = tester.getSize(modeSelectorFinder);
      expect(
        modeSelectorSize.height,
        greaterThanOrEqualTo(AiConstants.minTouchTargetSize),
      );

      // Enter text to reveal clear button
      await tester.enterText(
        find.byKey(const Key('ai-prompt-field')),
        'Sample query',
      );
      await tester.pump();

      final clearButtonFinder = find.byKey(const Key('ai-prompt-clear-button'));
      final clearButtonSize = tester.getSize(clearButtonFinder);
      expect(
        clearButtonSize.width,
        greaterThanOrEqualTo(AiConstants.minTouchTargetSize),
      );
      expect(
        clearButtonSize.height,
        greaterThanOrEqualTo(AiConstants.minTouchTargetSize),
      );
    });

    testWidgets('mode selector provides container semantics and clear label',
        (tester) async {
      final controller = AiAssistantController(client: _FakeAiClient());

      await tester.pumpWidget(_wrap(AiAssistantView(controller: controller)));

      expect(
        find.bySemanticsLabel('Calculation Mode'),
        findsOneWidget,
      );
    });

    testWidgets('history notice renders with accessible text content',
        (tester) async {
      final controller = AiAssistantController(client: _FakeAiClient());

      await tester.pumpWidget(_wrap(AiAssistantView(controller: controller)));

      expect(find.byKey(const Key('ai-history-notice')), findsOneWidget);
      expect(find.text(AiConstants.calculationHistoryNotice), findsOneWidget);
    });
  });
}
