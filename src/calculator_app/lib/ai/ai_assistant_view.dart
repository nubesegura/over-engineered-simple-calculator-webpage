import 'package:flutter/material.dart';

import 'ai_assistant_controller.dart';
import 'widgets/ai_history_notice.dart';
import 'widgets/ai_mode_selector.dart';
import 'widgets/ai_prompt_field.dart';
import 'widgets/ai_result_card.dart';

/// Full interactive view for the AI Natural Language Assistant tab.
class AiAssistantView extends StatefulWidget {
  const AiAssistantView({
    super.key,
    required this.controller,
  });

  final AiAssistantController controller;

  @override
  State<AiAssistantView> createState() => _AiAssistantViewState();
}

class _AiAssistantViewState extends State<AiAssistantView> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.controller.sentence);
  }

  @override
  void didUpdateWidget(AiAssistantView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.sentence != _textController.text) {
      _textController.text = widget.controller.sentence;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;

        // Keep text controller in sync if controller is reset externally
        if (_textController.text != ctrl.sentence && !ctrl.isLoading) {
          _textController.text = ctrl.sentence;
        }

        return SingleChildScrollView(
          key: const Key('ai-assistant-view'),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Mode toggle
                  Center(
                    child: AiModeSelector(
                      selectedMode: ctrl.mode,
                      enabled: !ctrl.isLoading,
                      onChanged: (mode) => ctrl.setMode(mode),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Prompt text field
                  AiPromptField(
                    controller: _textController,
                    enabled: !ctrl.isLoading,
                    onChanged: (value) => ctrl.setSentence(value),
                    onSubmitted: ctrl.canSubmit ? () => ctrl.submit() : null,
                  ),
                  const SizedBox(height: 16),

                  // Submit action button
                  FilledButton.icon(
                    key: const Key('ai-calculate-button'),
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text(
                      'Calculate with AI',
                      style: TextStyle(fontSize: 18),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: ctrl.canSubmit ? () => ctrl.submit() : null,
                  ),

                  // Loading progress indicator
                  if (ctrl.isLoading) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(
                      key: Key('ai-loading-indicator'),
                      semanticsLabel: 'Calculating with AI...',
                    ),
                  ],

                  // Error banner
                  if (ctrl.errorMessage != null) ...[
                    const SizedBox(height: 20),
                    Card(
                      key: const Key('ai-error-banner'),
                      color: colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: colorScheme.onErrorContainer,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    ctrl.errorMessage!,
                                    style: TextStyle(
                                      color: colorScheme.onErrorContainer,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (ctrl.requestId != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Request ID: ${ctrl.requestId}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onErrorContainer
                                      .withAlpha(200),
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],

                  // AI calculation result card
                  if (ctrl.response != null) ...[
                    const SizedBox(height: 20),
                    AiResultCard(
                      response: ctrl.response!,
                      responseMs: ctrl.responseMs,
                    ),
                  ],

                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 16),

                  // History informational notice
                  const AiHistoryNotice(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
