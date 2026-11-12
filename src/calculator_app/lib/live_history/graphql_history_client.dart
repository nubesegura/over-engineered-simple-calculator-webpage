import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_api.dart';
import '../auth/token_source.dart';
import '../constants.dart';
import 'live_calculation.dart';
import 'live_history_constants.dart';

/// One page of stored calculations returned by AppSync `Query.history`.
class HistoryPage {
  const HistoryPage({
    required this.items,
    this.nextToken,
  });

  final List<LiveCalculation> items;

  /// Cursor for the next (older) page, or `null` when there are no more pages.
  final String? nextToken;

  /// Alias matching the REST history page property name.
  String? get nextCursor => nextToken;
}

/// Port for fetching stored calculation history pages.
abstract interface class HistoryStoreClient {
  Future<HistoryPage> fetchHistory({
    int limit = LiveHistoryConstants.defaultPageLimit,
    String? nextToken,
    String? since,
  });
}

/// Fixed-message exception for GraphQL history failures. Never holds a URL,
/// token or raw server error message.
class LiveHistoryException implements Exception {
  const LiveHistoryException([
    this.message = LiveHistoryConstants.loadErrorMessage,
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the Cognito session is rejected even after token renewal.
class LiveHistoryAuthException extends LiveHistoryException {
  const LiveHistoryAuthException([
    super.message = AuthConstants.sessionExpiredMessage,
  ]);
}

/// Queries `Query.history` on the AppSync GraphQL endpoint using the Cognito
/// ID token in memory.
class GraphQlHistoryClient implements HistoryStoreClient {
  GraphQlHistoryClient({
    required Uri graphQlUri,
    required TokenSource tokens,
    http.Client? httpClient,
    Duration requestTimeout = LiveHistoryConstants.requestTimeout,
  })  : _graphQlUri = graphQlUri,
        _tokens = tokens,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _requestTimeout = requestTimeout;

  final Uri _graphQlUri;
  final TokenSource _tokens;
  final http.Client _http;
  final bool _ownsHttp;
  final Duration _requestTimeout;

  /// Closes the underlying HTTP client when it was created internally.
  void close() {
    if (_ownsHttp) _http.close();
  }

  @override
  Future<HistoryPage> fetchHistory({
    int limit = LiveHistoryConstants.defaultPageLimit,
    String? nextToken,
    String? since,
  }) async {
    try {
      var token = await _tokens.validIdToken();
      var response = await _postQuery(
        token: token,
        limit: limit,
        nextToken: nextToken,
        since: since,
      );
      if (_isUnauthorized(response)) {
        token = await _tokens.renewAfterRejection(token);
        response = await _postQuery(
          token: token,
          limit: limit,
          nextToken: nextToken,
          since: since,
        );
        if (_isUnauthorized(response)) {
          _tokens.markExpired(token);
          throw const LiveHistoryAuthException();
        }
      }
      if (response.statusCode != 200) {
        throw const LiveHistoryException();
      }
      return _parseResponse(response.body);
    } on LiveHistoryException {
      rethrow;
    } on AuthApiException catch (e) {
      if (e.statusCode == 401) {
        throw const LiveHistoryAuthException();
      }
      throw const LiveHistoryException();
    } catch (_) {
      throw const LiveHistoryException();
    }
  }

  Future<http.Response> _postQuery({
    required String token,
    required int limit,
    required String? nextToken,
    required String? since,
  }) =>
      _http
          .post(
            _graphQlUri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': token,
            },
            body: jsonEncode({
              'query': LiveHistoryConstants.historyQuery,
              'variables': {
                'limit': limit,
                'nextToken': nextToken,
                'since': since,
              },
            }),
          )
          .timeout(_requestTimeout);

  static bool _isUnauthorized(http.Response response) {
    if (response.statusCode == 401) return true;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return false;
      final errors = decoded['errors'];
      if (errors is List) {
        for (final err in errors) {
          if (err is Map) {
            final errorType = err['errorType']?.toString().toLowerCase() ?? '';
            if (errorType.contains('unauthorized')) return true;
          }
        }
      }
      if (response.statusCode == 403) {
        final msg = decoded['message']?.toString().toLowerCase() ?? '';
        if (msg.contains('unauthorized')) return true;
      }
    } catch (_) {
      // Non-JSON error body is handled by the status code check.
    }
    return false;
  }

  static HistoryPage _parseResponse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const LiveHistoryException();
    }
    if (decoded is! Map) throw const LiveHistoryException();
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw const LiveHistoryException();
    }
    final data = decoded['data'];
    if (data is! Map) throw const LiveHistoryException();
    final history = data['history'];
    if (history is! Map) throw const LiveHistoryException();
    final rawItems = history['items'];
    if (rawItems is! List) throw const LiveHistoryException();

    final items = <LiveCalculation>[];
    for (final raw in rawItems) {
      if (raw is Map) {
        final parsed = LiveCalculation.fromJson(
          Map<String, Object?>.from(raw),
        );
        if (parsed != null) items.add(parsed);
      }
    }
    final rawNext = history['nextToken']?.toString().trim();
    final nextToken = (rawNext == null || rawNext.isEmpty) ? null : rawNext;
    return HistoryPage(items: items, nextToken: nextToken);
  }

  @override
  String toString() => 'GraphQlHistoryClient()';
}
