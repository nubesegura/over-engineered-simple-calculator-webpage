import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth/auth_api.dart';
import 'auth/token_source.dart';
import 'constants.dart';

/// An error to show to the user (the message is already human readable).
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Shown instead of sending the bearer token to an untrusted API address.
const String untrustedUrlMessage = 'The API address must use https.';

/// The answer of `POST <service url>/<operation>`.
class CalculationResult {
  const CalculationResult({required this.result, this.backend});

  final String result;

  /// Name of the backend that answered; null when the field is missing or not
  /// a string. Display only.
  final String? backend;
}

/// One calculation returned by `GET <service url>/history`.
class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.operation,
    required this.a,
    required this.b,
    required this.result,
    required this.occurredAt,
  });

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
        id: json['calculation_id'].toString(),
        operation: json['operation'].toString(),
        a: json['a'].toString(),
        b: json['b'].toString(),
        result: json['result'].toString(),
        occurredAt: DateTime.tryParse(json['occurred_at']?.toString() ?? ''),
      );

  final String id;
  final String operation;
  final String a;
  final String b;
  final String result;
  final DateTime? occurredAt;
}

class HistoryPage {
  const HistoryPage({required this.items, this.nextCursor});

  final List<HistoryItem> items;

  /// Opaque cursor of the next (older) page, or null on the last page.
  final String? nextCursor;
}

/// Client of the calculator REST API (sls, ecs and eks backends share the contract).
class CalculatorApiClient {
  CalculatorApiClient({
    required String baseUrl,
    required TokenSource tokens,
    http.Client? httpClient,
  })  : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _tokens = tokens,
        _http = httpClient ?? http.Client();

  final String _baseUrl;
  final TokenSource _tokens;
  final http.Client _http;

  /// True when the service URL is an absolute http(s) URL.
  bool get hasValidBaseUrl {
    final base = Uri.tryParse(_baseUrl);
    return base != null &&
        base.hasAuthority &&
        (base.scheme == 'http' || base.scheme == 'https');
  }

  /// True when the bearer token may be sent to the service URL: `https`, or
  /// `http` to `localhost` / `127.0.0.1` for local runs.
  bool get hasTrustedBaseUrl {
    final base = Uri.tryParse(_baseUrl);
    if (base == null || !base.hasAuthority) return false;
    if (base.scheme == 'https') return base.host.isNotEmpty;
    return base.scheme == 'http' &&
        (base.host == 'localhost' || base.host == '127.0.0.1');
  }

  /// POST `<service url>/<operation>`; returns the result as the backend
  /// printed it, plus the optional name of the backend that answered.
  Future<CalculationResult> calculate(
    String operation,
    double a,
    double b,
  ) async {
    final response = await _send(
      (headers) => _http.post(
        Uri.parse('$_baseUrl/$operation'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'a': a, 'b': b}),
      ),
    );
    final data = _decode(response);
    if (data is! Map || data['result'] == null) {
      throw const ApiException('Unexpected response from the server.');
    }
    final backend = data['backend'];
    return CalculationResult(
      result: data['result'].toString(),
      backend: backend is String ? backend : null,
    );
  }

  /// GET `<service url>/history`, newest first. Pass the previous page's
  /// `nextCursor` to get the next one.
  Future<HistoryPage> fetchHistory({
    int limit = ApiConstants.historyPageSize,
    String? cursor,
  }) async {
    final uri = Uri.parse('$_baseUrl/${ApiConstants.historyPath}').replace(
      queryParameters: {
        'limit': limit.toString(),
        if (cursor != null) 'cursor': cursor,
      },
    );
    final response = await _send((headers) => _http.get(uri, headers: headers));
    final data = _decode(response);
    if (data is! Map || data['items'] is! List) {
      throw const ApiException('Unexpected response from the server.');
    }
    return HistoryPage(
      items: [
        for (final item in data['items'] as List)
          HistoryItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
      nextCursor: data['next_cursor']?.toString(),
    );
  }

  /// Sends the request with the bearer token. A 401 renews the token once and
  /// repeats the request once; a second 401 ends the session.
  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) request,
  ) async {
    if (!hasTrustedBaseUrl) throw const ApiException(untrustedUrlMessage);
    try {
      var token = await _tokens.validIdToken();
      var response = await _attempt(request, token);
      if (response.statusCode == 401) {
        token = await _tokens.renewAfterRejection(token);
        response = await _attempt(request, token);
        if (response.statusCode == 401) {
          _tokens.markExpired(token);
          throw const ApiException(
            AuthConstants.sessionExpiredMessage,
            statusCode: 401,
          );
        }
      }
      if (response.statusCode == 200) return response;
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    } on ApiException {
      rethrow;
    } on AuthApiException catch (e) {
      throw ApiException(e.message, statusCode: e.statusCode);
    } catch (_) {
      // Network failure, timeout or a CORS rejection (the browser hides the cause).
      throw const ApiException('Connection to the server failed.');
    }
  }

  Future<http.Response> _attempt(
    Future<http.Response> Function(Map<String, String> headers) request,
    String token,
  ) =>
      request({'Authorization': 'Bearer $token'})
          .timeout(ApiConstants.requestTimeout);

  dynamic _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const ApiException('Unexpected response from the server.');
    }
  }

  /// Extracts the message of the error body. The backends answer
  /// `{"error": {"code", "message"}}`; API Gateway may answer `{"message": ...}`.
  String _errorMessage(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map) {
        final error = data['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
        if (error != null) return error.toString();
        if (data['message'] != null) return data['message'].toString();
      }
    } on FormatException {
      // The body is not JSON: fall back to the status code.
    }
    return 'Request failed (HTTP ${response.statusCode}).';
  }
}
