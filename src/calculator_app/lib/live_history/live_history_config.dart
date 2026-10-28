import 'live_history_constants.dart';

/// Configuration state for the AppSync live calculation history endpoints.
enum LiveHistoryConfigState { notConfigured, invalid, valid }

final RegExp _awsDomainPattern = RegExp(
  r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?'
  r'(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*'
  r'\.amazonaws\.com$',
);

final RegExp _localDomainPattern = RegExp(
  r'^(?:localhost|127\.0\.0\.1)(?::\d{1,5})?$',
);

final RegExp _whitespacePattern = RegExp(r'\s');

/// Validated build-time configuration for AppSync Events and AppSync GraphQL.
///
/// Holds no tokens and never exposes domains or URLs in [toString].
class LiveHistoryConfig {
  const LiveHistoryConfig._({
    required this.state,
    Uri? realtimeUri,
    String? httpDomain,
    Uri? graphQlUri,
  })  : _realtimeUri = realtimeUri,
        _httpDomain = httpDomain,
        _graphQlUri = graphQlUri;

  /// Reads `EVENTS_REALTIME_DOMAIN`, `EVENTS_HTTP_DOMAIN` and `GRAPHQL_URL`
  /// from `--dart-define`.
  factory LiveHistoryConfig.fromEnvironment() => LiveHistoryConfig.parse(
        realtimeDomain: const String.fromEnvironment(
          LiveHistoryConstants.realtimeDomainSetting,
        ),
        httpDomain: const String.fromEnvironment(
          LiveHistoryConstants.httpDomainSetting,
        ),
        graphQlUrl: const String.fromEnvironment(
          LiveHistoryConstants.graphQlUrlSetting,
        ),
      );

  /// Validates the three endpoint settings.
  factory LiveHistoryConfig.parse({
    String realtimeDomain = '',
    String httpDomain = '',
    String graphQlUrl = '',
  }) {
    if (realtimeDomain.isEmpty && httpDomain.isEmpty && graphQlUrl.isEmpty) {
      return const LiveHistoryConfig._(
        state: LiveHistoryConfigState.notConfigured,
      );
    }
    if (realtimeDomain.isEmpty ||
        httpDomain.isEmpty ||
        graphQlUrl.isEmpty ||
        !_isValidDomain(realtimeDomain) ||
        !_isValidDomain(httpDomain)) {
      return const LiveHistoryConfig._(state: LiveHistoryConfigState.invalid);
    }
    final parsedGraphQl = _parseTrustedGraphQlUri(graphQlUrl);
    if (parsedGraphQl == null) {
      return const LiveHistoryConfig._(state: LiveHistoryConfigState.invalid);
    }
    final isLocalRealtime = _localDomainPattern.hasMatch(realtimeDomain);
    final realtimeScheme = isLocalRealtime ? 'ws' : 'wss';
    final parsedRealtime = Uri.tryParse(
      '$realtimeScheme://$realtimeDomain${LiveHistoryConstants.realtimePath}',
    );
    if (parsedRealtime == null) {
      return const LiveHistoryConfig._(state: LiveHistoryConfigState.invalid);
    }
    return LiveHistoryConfig._(
      state: LiveHistoryConfigState.valid,
      realtimeUri: parsedRealtime,
      httpDomain: httpDomain,
      graphQlUri: parsedGraphQl,
    );
  }

  final LiveHistoryConfigState state;
  final Uri? _realtimeUri;
  final String? _httpDomain;
  final Uri? _graphQlUri;

  bool get isConfigured => state != LiveHistoryConfigState.notConfigured;
  bool get isValid => state == LiveHistoryConfigState.valid;

  String? get problemMessage => state == LiveHistoryConfigState.invalid
      ? LiveHistoryConstants.invalidAddressMessage
      : null;

  Uri get realtimeUri {
    final uri = _realtimeUri;
    if (uri == null) {
      throw StateError('The live history configuration is not valid.');
    }
    return uri;
  }

  String get httpDomain {
    final domain = _httpDomain;
    if (domain == null) {
      throw StateError('The live history configuration is not valid.');
    }
    return domain;
  }

  Uri get graphQlUri {
    final uri = _graphQlUri;
    if (uri == null) {
      throw StateError('The live history configuration is not valid.');
    }
    return uri;
  }

  static bool _isValidDomain(String raw) {
    if (raw.isEmpty || _whitespacePattern.hasMatch(raw)) return false;
    if (raw.contains('/') ||
        raw.contains('?') ||
        raw.contains('#') ||
        raw.contains('@')) {
      return false;
    }
    if (_localDomainPattern.hasMatch(raw)) return true;
    if (raw.contains(':')) return false;
    return _awsDomainPattern.hasMatch(raw);
  }

  static Uri? _parseTrustedGraphQlUri(String raw) {
    if (raw.isEmpty || _whitespacePattern.hasMatch(raw)) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      return null;
    }
    final isLocalHost = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (uri.scheme == 'http' && isLocalHost) return uri;
    if (uri.scheme == 'https' &&
        (isLocalHost || _awsDomainPattern.hasMatch(uri.host))) {
      return uri;
    }
    return null;
  }

  @override
  String toString() => 'LiveHistoryConfig(${state.name})';
}
