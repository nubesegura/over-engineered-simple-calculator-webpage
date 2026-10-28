import 'package:flutter/material.dart';

import 'realtime_constants.dart';
import 'realtime_status.dart';

/// Colours of the chip for one status; the text colour is always readable on
/// the background (checked by the accessibility tests).
class RealtimeChipColors {
  const RealtimeChipColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

/// The connection state: an icon AND a text, in a polite live region so that
/// assistive technology announces changes without moving focus.
class RealtimeStatusChip extends StatelessWidget {
  const RealtimeStatusChip({super.key, required this.status});

  final RealtimeStatus status;

  static IconData iconFor(RealtimeStatusKind kind) => switch (kind) {
        RealtimeStatusKind.connecting => Icons.sync,
        RealtimeStatusKind.connected => Icons.check_circle,
        RealtimeStatusKind.reconnecting => Icons.sync_problem,
        RealtimeStatusKind.disconnected => Icons.cloud_off,
        RealtimeStatusKind.notAuthorized => Icons.lock,
        RealtimeStatusKind.notConfigured => Icons.settings_suggest,
      };

  static RealtimeChipColors colorsFor(
    RealtimeStatusKind kind,
    ColorScheme scheme,
  ) =>
      switch (kind) {
        RealtimeStatusKind.connected => RealtimeChipColors(
            scheme.primaryContainer, scheme.onPrimaryContainer),
        RealtimeStatusKind.connecting ||
        RealtimeStatusKind.reconnecting =>
          RealtimeChipColors(
              scheme.secondaryContainer, scheme.onSecondaryContainer),
        RealtimeStatusKind.notAuthorized =>
          RealtimeChipColors(scheme.errorContainer, scheme.onErrorContainer),
        RealtimeStatusKind.disconnected ||
        RealtimeStatusKind.notConfigured =>
          RealtimeChipColors(scheme.surfaceContainerHighest, scheme.onSurface),
      };

  @override
  Widget build(BuildContext context) {
    final colors = colorsFor(status.kind, Theme.of(context).colorScheme);
    return Semantics(
      container: true,
      liveRegion: true,
      label: RealtimeConstants.statusSemanticsLabel(status.label),
      child: ExcludeSemantics(
        child: Container(
          constraints:
              const BoxConstraints(minHeight: kMinInteractiveDimension),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconFor(status.kind), size: 20, color: colors.foreground),
              const SizedBox(width: 8),
              Text(
                status.label,
                key: const Key('realtime-status-text'),
                style: TextStyle(color: colors.foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
