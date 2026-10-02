/// API settings shared by every deployment of the calculator frontend.
///
/// The same build is served in dev and prod: the only thing that changes between
/// backends (sls, ecs, eks) and environments is the service URL. Edit
/// [defaultApiBaseUrl] to point the "Service URL" field at another backend by
/// default; users can still override it (and set the API key) from the UI.
class ApiConstants {
  const ApiConstants._();

  /// Backend used to prefill the "Service URL" field. Include the version path,
  /// without a trailing slash. Known backends:
  ///   sls: https://api.over-engineered-simple-calculator.nube-segura.com/api/sls/v1
  ///   ecs: https://ECS_DOMAIN/api/ecs/v1 (no history endpoint)
  ///   eks: https://EKS_DOMAIN/api/eks/v1
  static const String defaultApiBaseUrl =
      'https://api.over-engineered-simple-calculator.nube-segura.com/api/sls/v1';

  /// Header read by API Gateway to authorize a request (sls backend).
  static const String apiKeyHeader = 'x-api-key';

  /// Operations exposed by the backend. Each key is the path appended to the
  /// service URL (POST `<service url>/<key>`).
  static const Map<String, String> operations = {
    'add': '+',
    'sub': '-',
    'mul': '×',
    'div': '÷',
  };

  static const String defaultOperation = 'add';

  /// Path of the history endpoint (GET `<service url>/history?limit=&cursor=`).
  static const String historyPath = 'history';

  /// Calculations requested per history page (the backend caps it at 100).
  static const int historyPageSize = 10;

  /// History is written asynchronously (EventBridge -> SQS -> DynamoDB), so the
  /// list is refreshed shortly after a calculation instead of immediately.
  static const Duration historyRefreshDelay = Duration(seconds: 2);

  static const Duration requestTimeout = Duration(seconds: 15);
}
