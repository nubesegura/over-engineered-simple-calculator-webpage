import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

/// Tokens returned by the BFF. They live in memory only.
class TokenSet {
  const TokenSet({
    required this.idToken,
    required this.accessToken,
    required this.expiresIn,
  });

  final String idToken;
  final String accessToken;
  final Duration expiresIn;

  @override
  String toString() => 'TokenSet(<redacted>)';
}

/// An error answered by the BFF (or a failure to reach it).
class AuthApiException implements Exception {
  const AuthApiException(this.message, {this.statusCode});

  final String message;

  /// HTTP status, or null when the BFF could not be reached.
  final int? statusCode;

  @override
  String toString() => message;
}

/// Lowercase hexadecimal SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The login, refresh and logout calls of the BFF.
abstract interface class AuthApi {
  Future<TokenSet> login(String username, String password);

  /// Renews the tokens with the HttpOnly cookie the browser sends by itself.
  Future<TokenSet> refresh();

  Future<void> logout();
}

/// Calls the BFF on the page's own origin with relative URLs.
class HttpAuthApi implements AuthApi {
  HttpAuthApi({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  @override
  Future<TokenSet> login(String username, String password) async {
    final body = utf8.encode(jsonEncode({
      'username': username,
      'password': password,
    }));
    return _parseTokens(await _post(AuthConstants.loginPath, body));
  }

  @override
  Future<TokenSet> refresh() async =>
      _parseTokens(await _post(AuthConstants.refreshPath, const []));

  @override
  Future<void> logout() async {
    await _post(AuthConstants.logoutPath, const []);
  }

  Future<http.Response> _post(String path, List<int> body) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri(path: path),
            headers: {
              'Content-Type': 'application/json',
              AuthConstants.requestedWithHeader:
                  AuthConstants.requestedWithValue,
              AuthConstants.contentHashHeader: sha256Hex(body),
            },
            body: body,
          )
          .timeout(ApiConstants.requestTimeout);
    } catch (_) {
      throw const AuthApiException('Connection to the server failed.');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw AuthApiException(
      _errorMessage(response),
      statusCode: response.statusCode,
    );
  }

  TokenSet _parseTokens(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map) {
        final id = data['id_token'];
        final access = data['access_token'];
        final expiresIn = data['expires_in'];
        if (id is String && access is String && expiresIn is int) {
          return TokenSet(
            idToken: id,
            accessToken: access,
            expiresIn: Duration(seconds: expiresIn),
          );
        }
      }
    } on FormatException {
      // Falls through to the unexpected response error.
    }
    throw const AuthApiException('Unexpected response from the server.');
  }

  /// The BFF answers `{"error": {"code", "message", "request_id"}}`.
  String _errorMessage(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map) {
        final error = data['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
      }
    } on FormatException {
      // The body is not JSON: fall back to the status code.
    }
    return 'Request failed (HTTP ${response.statusCode}).';
  }
}
