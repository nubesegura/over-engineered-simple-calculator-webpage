/// Settings, GraphQL query and texts of the AppSync live calculation history.
const String kHistoryQuery =
    r'query History($limit: Int, $nextToken: String, $since: AWSDateTime) { '
    r'history(limit: $limit, nextToken: $nextToken, since: $since) { '
    r'items { txId a b op result status errorCode source createdAt } '
    r'nextToken '
    r'} '
    r'}';

class LiveHistoryConstants {
  const LiveHistoryConstants._();

  // Build-time configuration keys.
  static const String realtimeDomainSetting = 'EVENTS_REALTIME_DOMAIN';
  static const String httpDomainSetting = 'EVENTS_HTTP_DOMAIN';
  static const String graphQlUrlSetting = 'GRAPHQL_URL';

  // AppSync Events WebSocket paths, subprotocols and channel prefix.
  static const String realtimePath = '/event/realtime';
  static const String eventWsSubprotocol = 'aws-appsync-event-ws';
  static const String authSubprotocolPrefix = 'header-';
  static const String historyChannelPrefix = '/history/';

  // GraphQL query and page size.
  static const String historyQuery = kHistoryQuery;
  static const int defaultPageLimit = 20;

  // Timeouts and limits.
  static const Duration requestTimeout = Duration(seconds: 15);
  static const Duration handshakeTimeout = Duration(seconds: 15);
  static const Duration closeTimeout = Duration(seconds: 5);
  static const int minKeepAliveTimeoutMs = 10000;
  static const int maxKeepAliveTimeoutMs = 600000;
  static const int defaultKeepAliveTimeoutMs = 300000;
  static const Duration stableConnection = Duration(seconds: 30);
  static const Duration backoffBase = Duration(seconds: 1);
  static const Duration backoffCap = Duration(seconds: 30);
  static const double backoffJitter = 0.25;
  static const int maxReconnectAttempts = 5;
  static const int maxFrameBytes = 64 * 1024;
  static const int normalClosure = 1000;

  // Operations and symbols.
  static const Map<String, String> operationSymbols = {
    'ADD': '+',
    'SUBTRACT': '-',
    'MULTIPLY': '×',
    'DIVIDE': '÷',
  };

  // Status labels.
  static const String liveLabel = 'Live';
  static const String connectingLabel = 'Connecting';
  static const String offlineLabel = 'Offline';
  static const String notAuthorizedLabel = 'Not authorized';
  static const String invalidAddressLabel = 'Invalid address';
  static const String notConfiguredLabel = 'Not configured';
  static String reconnectingLabel(int attempt) =>
      'Reconnecting ($attempt/$maxReconnectAttempts)';
  static String statusSemanticsLabel(String status) =>
      'Live history status: $status';

  // UI and error texts.
  static const String invalidAddressMessage =
      'The live history address is not valid.';
  static const String loadErrorMessage =
      'Could not load calculation history. Try again.';
  static const String divideByZeroMessage = 'Cannot divide by zero.';
  static const String unexpectedErrorMessage = 'The calculation failed.';
  static String calculationFailedMessage(String code) =>
      'The calculation failed (code $code).';

  static const String historyTitle = 'History';
  static const String emptyHistoryMessage = 'No calculations yet.';
  static const String loadingMessage = 'Loading...';
  static const String loadMoreLabel = 'Load more';
  static const String refreshTooltip = 'Refresh history';
}
