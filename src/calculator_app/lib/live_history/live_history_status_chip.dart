import 'package:flutter/material.dart';

import 'live_history_status.dart';

/// Colours of the live history status badge; the foreground text and icon
/// always meet the 4.5:1 contrast bar against [background].
class LiveHistoryChipColors {
  const LiveHistoryChipColors(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

/// Compact badge showing the AppSync Events live history connection status with
/// both an icon and a text label inside a polite live region.
class LiveHistoryStatusChip extends StatelessWidget {
  const LiveHistoryStatusChip({
    super.key = const Key('live-history-status'),
    required this.status,
  });

  final LiveHistoryStatus status;

  static IconData iconFor(LiveHistoryStatusKind kind) => switch (kind) {
        LiveHistoryStatusKind.connecting => Icons.sync,
        LiveHistoryStatusKind.live => Icons.check_circle,
        LiveHistoryStatusKind.reconnecting => Icons.sync_problem,
        LiveHistoryStatusKind.offline => Icons.cloud_off,
        LiveHistoryStatusKind.notAuthorized => Icons.lock,
        LiveHistoryStatusKind.invalidAddress => Icons.error_outline,
        LiveHistoryStatusKind.notConfigured => Icons.settings_suggest,
      };

  static LiveHistoryChipColors colorsFor(
    LiveHistoryStatusKind kind,
    ColorScheme scheme,
  ) =>
      switch (kind) {
        LiveHistoryStatusKind.live => LiveHistoryChipColors(
            scheme.primaryContainer,
            scheme.onPrimaryContainer,
          ),
        LiveHistoryStatusKind.connecting ||
        LiveHistoryStatusKind.reconnecting =>
          LiveHistoryChipColors(
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
          ),
        LiveHistoryStatusKind.notAuthorized ||
        LiveHistoryStatusKind.invalidAddress =>
          LiveHistoryChipColors(
            scheme.errorContainer,
            scheme.onErrorContainer,
          ),
        LiveHistoryStatusKind.offline ||
        LiveHistoryStatusKind.notConfigured =>
          LiveHistoryChipColors(
            scheme.surfaceContainerHighest,
            scheme.onSurface,
          ),
      };

  @override
  Widget build(BuildContext context) {
    if (status.kind == LiveHistoryStatusKind.notConfigured) {
      return const SizedBox.shrink();
    }
    final colors = colorsFor(status.kind, Theme.of(context).colorScheme);
    return Semantics(
      container: true,
      liveRegion: true,
      label: status.semanticsLabel,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconFor(status.kind), size: 16, color: colors.foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  status.label,
                  key: const Key('live-history-status-text'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
