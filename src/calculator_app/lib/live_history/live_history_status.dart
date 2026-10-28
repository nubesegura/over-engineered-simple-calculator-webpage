import 'live_history_constants.dart';

/// Distinct connection states for the AppSync Events live calculation history.
enum LiveHistoryStatusKind {
  notConfigured,
  invalidAddress,
  connecting,
  live,
  reconnecting,
  offline,
  notAuthorized,
}

/// Immutable status value displayed in the History header badge. Holds no URL,
/// token or user identifier.
class LiveHistoryStatus {
  const LiveHistoryStatus._(this.kind, {this.attempt = 0});

  static const LiveHistoryStatus notConfigured =
      LiveHistoryStatus._(LiveHistoryStatusKind.notConfigured);
  static const LiveHistoryStatus invalidAddress =
      LiveHistoryStatus._(LiveHistoryStatusKind.invalidAddress);
  static const LiveHistoryStatus connecting =
      LiveHistoryStatus._(LiveHistoryStatusKind.connecting);
  static const LiveHistoryStatus live =
      LiveHistoryStatus._(LiveHistoryStatusKind.live);
  static const LiveHistoryStatus offline =
      LiveHistoryStatus._(LiveHistoryStatusKind.offline);
  static const LiveHistoryStatus notAuthorized =
      LiveHistoryStatus._(LiveHistoryStatusKind.notAuthorized);

  factory LiveHistoryStatus.reconnecting(int attempt) =>
      LiveHistoryStatus._(LiveHistoryStatusKind.reconnecting, attempt: attempt);

  final LiveHistoryStatusKind kind;

  /// Reconnection attempt number (`1..5`) when [kind] is `reconnecting`, else 0.
  final int attempt;

  /// True when a manual refresh should also attempt to reconnect the socket.
  bool get canReconnect =>
      kind == LiveHistoryStatusKind.offline ||
      kind == LiveHistoryStatusKind.notAuthorized;

  String get label => switch (kind) {
        LiveHistoryStatusKind.notConfigured =>
          LiveHistoryConstants.notConfiguredLabel,
        LiveHistoryStatusKind.invalidAddress =>
          LiveHistoryConstants.invalidAddressLabel,
        LiveHistoryStatusKind.connecting =>
          LiveHistoryConstants.connectingLabel,
        LiveHistoryStatusKind.live => LiveHistoryConstants.liveLabel,
        LiveHistoryStatusKind.reconnecting =>
          LiveHistoryConstants.reconnectingLabel(attempt),
        LiveHistoryStatusKind.offline => LiveHistoryConstants.offlineLabel,
        LiveHistoryStatusKind.notAuthorized =>
          LiveHistoryConstants.notAuthorizedLabel,
      };

  String get semanticsLabel => LiveHistoryConstants.statusSemanticsLabel(label);

  @override
  bool operator ==(Object other) =>
      other is LiveHistoryStatus &&
      other.kind == kind &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(kind, attempt);

  @override
  String toString() => 'LiveHistoryStatus($label)';
}
