import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_api.dart';
import '../auth/token_source.dart';
import 'ai_constants.dart';
import 'ai_errors.dart';
import 'ai_models.dart';

/// HTTP client for interacting with the Amazon Bedrock-powered Natural Language Calculator API.
class AiCalculatorClient {
  AiCalculatorClient({
    required String baseUrl,
    required TokenSource tokenSource,
    http.Client? httpClient,
    Duration requestTimeout = AiConstants.requestTimeout,
  })  : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _tokenSource = tokenSource,
        _http = httpClient ?? http.Client(),
        _requestTimeout = requestTimeout;

  final String _baseUrl;
  final TokenSource _tokenSource;
  final http.Client _http;
  final Duration _requestTimeout;

  /// True when the base URL is an absolute http or https URI.
  bool get hasValidBaseUrl {
    final uri = Uri.tryParse(_baseUrl);
    return uri != null &&
        uri.hasAuthority &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  /// True when the base URL is considered trusted for transmitting JWT credentials.
  /// (HTTPS, or localhost/127.0.0.1 for local development).
  bool get hasTrustedBaseUrl {
    final uri = Uri.tryParse(_baseUrl);
    if (uri == null || !uri.hasAuthority) return false;
    if (uri.scheme == 'https') return uri.host.isNotEmpty;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
  }

  /// Submits a natural language calculation prompt to `POST /calculate`.
  Future<AiCalculateResponse> calculate(AiCalculateRequest request) async {
    if (!hasValidBaseUrl || !hasTrustedBaseUrl) {
      throw const InvalidPayloadException(
        'Invalid or untrusted AI service URL. Only HTTPS or localhost endpoints are allowed.',
      );
    }

    final targetUri = Uri.parse('$_baseUrl${AiConstants.calculatePath}');

    String token;
    try {
      token = await _tokenSource.validIdToken();
      if (token.isEmpty) {
        throw const AiUnauthorizedException(
          AiConstants.sessionExpiredMessage,
        );
      }
    } on AuthApiException catch (e) {
      throw AiUnauthorizedException(e.message);
    } catch (e) {
      if (e is AiUnauthorizedException) rethrow;
      throw const AiUnauthorizedException(
        AiConstants.sessionExpiredMessage,
      );
    }

    http.Response response;
    try {
      response = await _dispatch(targetUri, request, token);

      // Handle 401 token refresh retry
      if (response.statusCode == 401) {
        try {
          token = await _tokenSource.renewAfterRejection(token);
        } catch (_) {
          _tokenSource.markExpired(token);
          throw const AiUnauthorizedException(
            AiConstants.sessionExpiredMessage,
          );
        }

        response = await _dispatch(targetUri, request, token);

        if (response.statusCode == 401) {
          _tokenSource.markExpired(token);
          throw const AiUnauthorizedException(
            AiConstants.sessionExpiredMessage,
          );
        }
      }
    } on TimeoutException {
      throw const AiUpstreamTimeoutException(
        AiConstants.upstreamTimeoutMessage,
      );
    } on AiException {
      rethrow;
    } catch (_) {
      throw const AiNetworkException(
        AiConstants.networkErrorMessage,
      );
    }

    final bodyMap = _decodeJsonBody(response.body);

    if (response.statusCode == 200) {
      return AiCalculateResponse.fromJson(bodyMap);
    }

    throw AiException.fromResponse(
      statusCode: response.statusCode,
      body: bodyMap,
      fallbackMessage: response.body.isNotEmpty ? response.body : null,
    );
  }

  Future<http.Response> _dispatch(
    Uri uri,
    AiCalculateRequest request,
    String token,
  ) {
    return _http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(request.toJson()),
        )
        .timeout(_requestTimeout);
  }

  Map<String, dynamic> _decodeJsonBody(String body) {
    if (body.isEmpty) return {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }
}
