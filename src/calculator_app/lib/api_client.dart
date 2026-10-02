import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'constants.dart';

/// An error to show to the user (the message is already human readable).
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
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
    String apiKey = '',
    http.Client? httpClient,
  })  : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _apiKey = apiKey.trim(),
        _http = httpClient ?? http.Client();

  final String _baseUrl;
  final String _apiKey;
  final http.Client _http;

  /// True when the service URL is an absolute http(s) URL.
  bool get hasValidBaseUrl {
    final base = Uri.tryParse(_baseUrl);
    return base != null &&
        base.hasAuthority &&
        (base.scheme == 'http' || base.scheme == 'https');
  }

  Map<String, String> get _headers => {
        if (_apiKey.isNotEmpty) ApiConstants.apiKeyHeader: _apiKey,
      };

  /// POST `<service url>/<operation>`; returns the result as the backend printed it.
  Future<String> calculate(String operation, double a, double b) async {
    final response = await _send(
      () => _http.post(
        Uri.parse('$_baseUrl/$operation'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'a': a, 'b': b}),
      ),
    );
    final data = _decode(response);
    if (data is! Map || data['result'] == null) {
      throw const ApiException('Unexpected response from the server.');
    }
    return data['result'].toString();
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
    final response = await _send(() => _http.get(uri, headers: _headers));
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

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      final response = await request().timeout(ApiConstants.requestTimeout);
      if (response.statusCode == 200) return response;
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      // Network failure, timeout or a CORS rejection (the browser hides the cause).
      throw const ApiException('Connection to the server failed.');
    }
  }

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
