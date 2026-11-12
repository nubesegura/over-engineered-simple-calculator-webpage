import 'package:flutter/material.dart';

import '../ai_models.dart';

/// Card rendering the conversational answer, structured calculation breakdown badge,
/// and observability metadata (mode, language, response time, request ID).
class AiResultCard extends StatelessWidget {
  const AiResultCard({
    super.key,
    required this.response,
    this.responseMs,
  });

  final AiCalculateResponse response;
  final int? responseMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final calculation = response.calculation;

    return Card(
      key: const Key('ai-result-card'),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Conversational response
            SelectableText(
              response.answer,
              key: const Key('ai-conversational-answer'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 18,
                height: 1.4,
              ),
            ),

            // Structured arithmetic badge when calculation breakdown is present
            if (calculation != null) ...[
              const SizedBox(height: 16),
              Container(
                key: const Key('ai-calculation-badge'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.primary.withAlpha(50),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calculate,
                      color: colorScheme.onPrimaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    SelectableText(
                      calculation.formattedFormula,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),

            // Execution metadata chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  key: const Key('ai-mode-chip'),
                  avatar: Icon(
                    response.mode == AiMode.tool
                        ? Icons.build
                        : Icons.psychology,
                    size: 16,
                  ),
                  label: Text(
                    response.mode == AiMode.tool
                        ? 'Tool-Assisted'
                        : 'Direct Model',
                  ),
                ),
                Chip(
                  key: const Key('ai-language-chip'),
                  avatar: const Icon(Icons.language, size: 16),
                  label: Text(response.language.toUpperCase()),
                ),
                if (responseMs != null)
                  Chip(
                    key: const Key('ai-response-time-chip'),
                    avatar: const Icon(Icons.timer_outlined, size: 16),
                    label: Text('$responseMs ms'),
                  ),
              ],
            ),

            if (response.requestId.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                'Request ID: ${response.requestId}',
                key: const Key('ai-request-id-text'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withAlpha(180),
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
