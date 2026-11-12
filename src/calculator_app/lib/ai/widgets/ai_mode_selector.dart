import 'package:flutter/material.dart';

import '../ai_constants.dart';
import '../ai_models.dart';

/// Segmented selector allowing the user to pick between deterministic tool-assisted
/// calculation and direct LLM probabilistic reasoning.
class AiModeSelector extends StatelessWidget {
  const AiModeSelector({
    super.key,
    required this.selectedMode,
    required this.onChanged,
    this.enabled = true,
  });

  final AiMode selectedMode;
  final ValueChanged<AiMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Calculation Mode',
      child: SegmentedButton<AiMode>(
        key: const Key('ai-mode-selector'),
        showSelectedIcon: true,
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(
            Size(
              AiConstants.minTouchTargetSize,
              AiConstants.minTouchTargetSize,
            ),
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        segments: const [
          ButtonSegment<AiMode>(
            value: AiMode.tool,
            icon: Icon(Icons.build),
            label: Text('Tool-Assisted (Deterministic)'),
          ),
          ButtonSegment<AiMode>(
            value: AiMode.model,
            icon: Icon(Icons.psychology),
            label: Text('Direct Model (Probabilistic)'),
          ),
        ],
        selected: {selectedMode},
        onSelectionChanged: enabled
            ? (newSelection) {
                if (newSelection.isNotEmpty) {
                  onChanged(newSelection.first);
                }
              }
            : null,
      ),
    );
  }
}
