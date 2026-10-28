import 'realtime_constants.dart';

enum RealtimeStatusKind {
  connecting,
  connected,
  reconnecting,
  disconnected,
  notAuthorized,
  notConfigured,
}

/// The connection state shown in the status chip. Holds no address or token.
class RealtimeStatus {
  const RealtimeStatus._(this.kind, {this.attempt = 0, this.detail});

  static const RealtimeStatus connecting =
      RealtimeStatus._(RealtimeStatusKind.connecting);
  static const RealtimeStatus connected =
      RealtimeStatus._(RealtimeStatusKind.connected);
  static const RealtimeStatus disconnected =
      RealtimeStatus._(RealtimeStatusKind.disconnected);
  static const RealtimeStatus notAuthorized =
      RealtimeStatus._(RealtimeStatusKind.notAuthorized);

  factory RealtimeStatus.reconnecting(int attempt) =>
      RealtimeStatus._(RealtimeStatusKind.reconnecting, attempt: attempt);

  /// [detail] explains why (empty or invalid address).
  factory RealtimeStatus.notConfigured(String detail) =>
      RealtimeStatus._(RealtimeStatusKind.notConfigured, detail: detail);

  final RealtimeStatusKind kind;

  /// Reconnection attempt in progress (1 to 5); 0 for other statuses.
  final int attempt;

  final String? detail;

  String get label => switch (kind) {
        RealtimeStatusKind.connecting => RealtimeConstants.connectingLabel,
        RealtimeStatusKind.connected => RealtimeConstants.connectedLabel,
        RealtimeStatusKind.reconnecting =>
          RealtimeConstants.reconnectingLabel(attempt),
        RealtimeStatusKind.disconnected => RealtimeConstants.disconnectedLabel,
        RealtimeStatusKind.notAuthorized =>
          RealtimeConstants.notAuthorizedLabel,
        RealtimeStatusKind.notConfigured =>
          RealtimeConstants.notConfiguredLabel,
      };

  @override
  bool operator ==(Object other) =>
      other is RealtimeStatus &&
      other.kind == kind &&
      other.attempt == attempt &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, attempt, detail);

  @override
  String toString() => 'RealtimeStatus($label)';
}
