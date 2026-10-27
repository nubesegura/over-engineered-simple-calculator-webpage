import 'package:flutter/material.dart';

import 'realtime_constants.dart';

/// Minimum size of a touch target, in logical pixels.
const double kRealtimeTouchTarget = 48;

/// The "Mode" control: Standard (REST), the default, or Real-time (WebSocket).
class RealtimeModeSelector extends StatelessWidget {
  const RealtimeModeSelector({
    super.key,
    required this.realtime,
    required this.onChanged,
  });

  /// True when Real-time is the selected mode.
  final bool realtime;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: RealtimeConstants.modeLabel,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(
            Size(kRealtimeTouchTarget, kRealtimeTouchTarget),
          ),
        ),
        segments: const [
          ButtonSegment<bool>(
            value: false,
            label: Text(RealtimeConstants.standardModeLabel),
          ),
          ButtonSegment<bool>(
            value: true,
            label: Text(RealtimeConstants.realtimeModeLabel),
          ),
        ],
        selected: {realtime},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}
