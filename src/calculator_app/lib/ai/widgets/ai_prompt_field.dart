import 'package:flutter/material.dart';

import '../ai_constants.dart';

/// Text input field for entering a natural language arithmetic query.
class AiPromptField extends StatelessWidget {
  const AiPromptField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final hasText = value.text.isNotEmpty;
        return TextField(
          key: const Key('ai-prompt-field'),
          controller: controller,
          enabled: enabled,
          maxLength: AiConstants.maxSentenceLength,
          keyboardType: TextInputType.text,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            labelText: 'Natural Language Query',
            hintText: AiConstants.promptPlaceholder,
            border: const OutlineInputBorder(),
            suffixIcon: hasText
                ? IconButton(
                    key: const Key('ai-prompt-clear-button'),
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear input',
                    constraints: const BoxConstraints(
                      minWidth: AiConstants.minTouchTargetSize,
                      minHeight: AiConstants.minTouchTargetSize,
                    ),
                    onPressed: enabled
                        ? () {
                            controller.clear();
                            onChanged?.call('');
                          }
                        : null,
                  )
                : null,
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted != null ? (_) => onSubmitted!() : null,
        );
      },
    );
  }
}
