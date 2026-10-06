/// API settings shared by every deployment of the calculator frontend.
///
/// The same build is served in dev and prod. The API address is derived from the
/// host of the page (see `api_address.dart`); one shared hostname serves every
/// backend, so the page never names a backend.
class ApiConstants {
  const ApiConstants._();

  /// Version path appended to the API hostname, without a trailing slash.
  static const String apiVersionPath = '/api/v1';

  /// Subdomain prepended to the host of the page to get the API hostname.
  static const String apiSubdomain = 'api';

  /// Shown instead of sending requests when the page has no API address.
  static const String noApiAddressMessage =
      'No API address for this host. Open the site through its domain name.';

  /// Shown when the build-time API address is not an absolute http(s) URL.
  static const String invalidApiAddressMessage =
      'The API address is not a valid http(s) URL.';

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

/// Settings of the login flow against the BFF served on the page's own origin.
class AuthConstants {
  const AuthConstants._();

  static const String loginPath = '/auth/login';
  static const String refreshPath = '/auth/refresh';
  static const String logoutPath = '/auth/logout';

  static const String requestedWithHeader = 'X-Requested-With';
  static const String requestedWithValue = 'XMLHttpRequest';

  /// Hex SHA-256 of the body; CloudFront needs it to sign POST requests.
  static const String contentHashHeader = 'x-amz-content-sha256';

  /// An ID token that expires in less than this is renewed before use.
  static const Duration renewalMargin = Duration(seconds: 60);

  static const String sessionExpiredMessage =
      'Your session has expired. Please log in again.';

  static const String webOnlyMessage =
      'Login is only available in the web version.';
}
