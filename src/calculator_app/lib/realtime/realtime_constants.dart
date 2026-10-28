/// Settings and texts of the real-time (WebSocket) calculation mode.
class RealtimeConstants {
  const RealtimeConstants._();

  /// Name of the build-time setting that holds the WebSocket address.
  static const String addressSetting = 'WS_BASE_URL';

  /// Single query parameter that carries the ID token in the upgrade request.
  static const String tokenParameter = 'token';

  // Timings.
  static const Duration requestTimeout = Duration(seconds: 15);
  static const Duration inProgressDelay = Duration(seconds: 1);
  static const int maxInProgressResends = 3;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration closeTimeout = Duration(seconds: 5);

  /// API Gateway closes a WebSocket connection after 2 hours; rotate before.
  static const Duration rotationInterval = Duration(minutes: 110);

  /// API Gateway closes an idle connection after 10 minutes; ping before.
  static const Duration pingInterval = Duration(seconds: 300);

  /// A connection that stays open this long resets the reconnection counter.
  static const Duration stableConnection = Duration(seconds: 30);

  // Reconnection: 1, 2, 4 ... seconds capped at 30, plus jitter.
  static const Duration backoffBase = Duration(seconds: 1);
  static const Duration backoffCap = Duration(seconds: 30);
  static const double backoffJitter = 0.25;
  static const int maxReconnectAttempts = 5;

  // Size limits.
  static const int maxRequestBytes = 1024;
  static const int maxReplyBytes = 64 * 1024;
  static const int maxOperandDigits = 38;

  /// Normal closure code sent when the page closes the connection.
  static const int normalClosure = 1000;

  static const String pingMessage = '{"action":"ping"}';

  /// Maps the operation keys of the REST page to the backend operation names.
  static const Map<String, String> operationNames = {
    'add': 'ADD',
    'sub': 'SUBTRACT',
    'mul': 'MULTIPLY',
    'div': 'DIVIDE',
  };

  // Status labels.
  static const String connectingLabel = 'Connecting';
  static const String connectedLabel = 'Connected';
  static const String disconnectedLabel = 'Disconnected';
  static const String notAuthorizedLabel = 'Not authorized';
  static const String notConfiguredLabel = 'Not configured';
  static String reconnectingLabel(int attempt) =>
      'Reconnecting ($attempt/$maxReconnectAttempts)';

  // Messages shown to the user.
  static const String notConfiguredMessage =
      'Real-time is not configured for this environment.';
  static const String invalidAddressMessage =
      'The real-time address is not a valid wss URL.';
  static const String notConnectedMessage =
      'Real-time is not connected. Use Standard (REST) or reconnect.';
  static const String invalidNumbersMessage = 'Enter valid numbers.';
  static const String tooLongMessage = 'The numbers are too long.';
  static const String busyMessage = 'A calculation is already in progress.';
  static const String divideByZeroMessage = 'Cannot divide by zero.';
  static const String invalidRequestMessage = 'The request was not valid.';
  static const String idempotencyConflictMessage =
      'This calculation id was already used. Try again.';
  static const String internalErrorMessage =
      'Something went wrong. Try again shortly.';
  static const String unexpectedResponseMessage =
      'Unexpected response from the server.';
  static const String noAnswerMessage = 'No answer from the server. Try again.';
  static const String notAuthorizedMessage =
      'Real-time access was refused. Sign in again or use Standard (REST).';
  static String calculationFailedMessage(String code) =>
      'The calculation failed (code $code).';

  // Screen texts.
  static const String modeLabel = 'Mode';
  static const String standardModeLabel = 'Standard (REST)';
  static const String realtimeModeLabel = 'Real-time (WebSocket)';
  static const String transportLine = 'Transport: WebSocket';
  static const String useRestLabel = 'Use REST for this calculation';
  static const String reconnectLabel = 'Reconnect';
  static const String progressLabel = 'Calculating';
  static String statusSemanticsLabel(String status) =>
      'Connection status: $status';
}
