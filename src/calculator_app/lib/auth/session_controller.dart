import 'dart:async';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import 'auth_api.dart';
import 'token_source.dart';

enum SessionState { restoring, unauthenticated, authenticated, expired }

/// Holds the session of the user. The tokens live only in this object's memory:
/// they are never written to storage, cookies or logs.
class SessionController extends ChangeNotifier implements TokenSource {
  SessionController(this._api, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final AuthApi _api;
  final DateTime Function() _clock;

  SessionState _state = SessionState.restoring;
  String? _message;
  bool _canRetryRestore = false;
  TokenSet? _tokens;
  DateTime? _expiresAt;
  Future<String>? _renewal;
  int _epoch = 0;

  SessionState get state => _state;

  /// The last failure or expiry text to show on the login screen.
  String? get message => _message;

  /// True when the first refresh failed for a reason other than "no session".
  bool get canRetryRestore => _canRetryRestore;

  /// Asks the BFF for the tokens of the session the browser cookie belongs to.
  Future<void> restore() async {
    _canRetryRestore = false;
    _setState(SessionState.restoring, null);
    final epoch = _epoch;
    try {
      final tokens = await _api.refresh();
      if (epoch != _epoch) return;
      _store(tokens);
      _setState(SessionState.authenticated, null);
    } on AuthApiException catch (e) {
      if (epoch != _epoch) return;
      _canRetryRestore = e.statusCode != 401;
      _setState(
        SessionState.unauthenticated,
        e.statusCode == 401 ? null : e.message,
      );
    }
  }

  /// Returns true on success; on failure the BFF message is in [message].
  Future<bool> login(String username, String password) async {
    final epoch = ++_epoch;
    try {
      final tokens = await _api.login(username, password);
      if (epoch != _epoch) return false;
      _store(tokens);
      _setState(SessionState.authenticated, null);
      return true;
    } on AuthApiException catch (e) {
      if (epoch == _epoch) _setState(SessionState.unauthenticated, e.message);
      return false;
    }
  }

  /// Ends the session here even when the BFF cannot be reached.
  Future<void> logout() async {
    _clear();
    final epoch = _epoch;
    try {
      await _api.logout();
    } on AuthApiException {
      // The session is already gone locally; the cookie expires by itself.
    }
    if (epoch != _epoch) return;
    _setState(SessionState.unauthenticated, null);
  }

  @override
  Future<String> validIdToken() {
    final tokens = _tokens;
    final expiresAt = _expiresAt;
    if (tokens == null || expiresAt == null) {
      return Future.error(_noSession());
    }
    if (expiresAt.difference(_clock()) < AuthConstants.renewalMargin) {
      return _renew();
    }
    return Future.value(tokens.idToken);
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) {
    final tokens = _tokens;
    if (tokens == null) return Future.error(_noSession());
    if (tokens.idToken != rejectedToken) return Future.value(tokens.idToken);
    return _renew();
  }

  @override
  void markExpired(String rejectedToken) {
    if (_tokens?.idToken != rejectedToken) return;
    _expire();
  }

  void _expire() {
    _clear();
    _setState(SessionState.expired, AuthConstants.sessionExpiredMessage);
  }

  Future<String> _renew() {
    final running = _renewal;
    if (running != null) return running;
    late final Future<String> renewal;
    renewal = _doRenew().whenComplete(() {
      if (identical(_renewal, renewal)) _renewal = null;
    });
    return _renewal = renewal;
  }

  Future<String> _doRenew() async {
    final epoch = _epoch;
    try {
      final tokens = await _api.refresh();
      if (epoch != _epoch) throw _noSession();
      _store(tokens);
      return tokens.idToken;
    } on AuthApiException catch (e) {
      if (epoch == _epoch && e.statusCode == 401) _expire();
      rethrow;
    }
  }

  void _store(TokenSet tokens) {
    _tokens = tokens;
    _expiresAt = _clock().add(tokens.expiresIn);
  }

  void _clear() {
    _epoch++;
    _tokens = null;
    _expiresAt = null;
    _renewal = null;
  }

  void _setState(SessionState state, String? message) {
    _state = state;
    _message = message;
    notifyListeners();
  }

  AuthApiException _noSession() => const AuthApiException(
        AuthConstants.sessionExpiredMessage,
        statusCode: 401,
      );
}
