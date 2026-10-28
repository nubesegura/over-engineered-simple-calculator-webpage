import 'dart:async';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

TokenSet _tokens(String id, {int expiresIn = 3600}) => TokenSet(
      idToken: id,
      accessToken: 'access-$id',
      expiresIn: Duration(seconds: expiresIn),
    );

/// Answers from queues; every call is recorded.
class FakeAuthApi implements AuthApi {
  final List<String> calls = [];
  final List<Future<TokenSet> Function()> refreshAnswers = [];
  Future<TokenSet> Function()? loginAnswer;
  Object? logoutError;
  Completer<void>? logoutGate;

  @override
  Future<TokenSet> login(String username, String password) {
    calls.add('login');
    return loginAnswer!();
  }

  @override
  Future<TokenSet> refresh() {
    calls.add('refresh');
    return refreshAnswers.removeAt(0)();
  }

  @override
  Future<void> logout() async {
    calls.add('logout');
    await logoutGate?.future;
    if (logoutError != null) throw logoutError!;
  }

  void refreshReturns(TokenSet tokens) =>
      refreshAnswers.add(() async => tokens);

  void refreshFails(int? status, [String message = 'failure']) => refreshAnswers
      .add(() async => throw AuthApiException(message, statusCode: status));
}

void main() {
  late FakeAuthApi api;
  late DateTime now;
  late SessionController session;

  setUp(() {
    api = FakeAuthApi();
    now = DateTime.utc(2026, 10, 4, 12);
    session = SessionController(api, clock: () => now);
  });

  Future<void> authenticate({int expiresIn = 3600}) async {
    api.refreshReturns(_tokens('id-1', expiresIn: expiresIn));
    await session.restore();
  }

  group('restore', () {
    test('starts restoring', () {
      expect(session.state, SessionState.restoring);
    });

    test('a successful refresh authenticates', () async {
      await authenticate();

      expect(session.state, SessionState.authenticated);
      expect(api.calls, ['refresh']);
      expect(await session.validIdToken(), 'id-1');
    });

    test('a 401 leaves the user unauthenticated without a message', () async {
      api.refreshFails(401);

      await session.restore();

      expect(session.state, SessionState.unauthenticated);
      expect(session.message, isNull);
      expect(session.canRetryRestore, isFalse);
    });

    test('other errors are unauthenticated with a retryable message', () async {
      api.refreshFails(503, 'Try again shortly.');

      await session.restore();

      expect(session.state, SessionState.unauthenticated);
      expect(session.message, 'Try again shortly.');
      expect(session.canRetryRestore, isTrue);
    });
  });

  group('login and logout', () {
    test('login keeps the tokens and authenticates', () async {
      api.loginAnswer = () async => _tokens('id-login');

      final ok = await session.login('me@example.com', 'pw');

      expect(ok, isTrue);
      expect(session.state, SessionState.authenticated);
      expect(session.message, isNull);
      expect(await session.validIdToken(), 'id-login');
    });

    test('a failed login reports the BFF message', () async {
      api.loginAnswer =
          () async => throw const AuthApiException('Wrong.', statusCode: 401);

      final ok = await session.login('me@example.com', 'pw');

      expect(ok, isFalse);
      expect(session.state, SessionState.unauthenticated);
      expect(session.message, 'Wrong.');
    });

    test('logout clears the memory', () async {
      await authenticate();

      await session.logout();

      expect(api.calls, ['refresh', 'logout']);
      expect(session.state, SessionState.unauthenticated);
      expect(session.message, isNull);
      await expectLater(
          session.validIdToken(), throwsA(isA<AuthApiException>()));
    });

    test('logout ends the session even when the call fails', () async {
      await authenticate();
      api.logoutError = const AuthApiException('down', statusCode: 502);

      await session.logout();

      expect(session.state, SessionState.unauthenticated);
      await expectLater(
          session.validIdToken(), throwsA(isA<AuthApiException>()));
    });
  });

  group('validIdToken', () {
    test('does not renew when the token has more than the margin left',
        () async {
      await authenticate(expiresIn: 3600);
      now = now.add(const Duration(seconds: 3600 - 61));

      expect(await session.validIdToken(), 'id-1');
      expect(api.calls, ['refresh']);
    });

    test('renews when less than 60 seconds are left', () async {
      await authenticate(expiresIn: 3600);
      now = now.add(const Duration(seconds: 3600 - 59));
      api.refreshReturns(_tokens('id-2'));

      expect(await session.validIdToken(), 'id-2');
      expect(api.calls, ['refresh', 'refresh']);
    });

    test('does not renew at exactly the margin', () async {
      await authenticate(expiresIn: 3600);
      now = now.add(const Duration(seconds: 3600 - 60));

      expect(await session.validIdToken(), 'id-1');
      expect(api.calls, ['refresh']);
    });

    test('ten concurrent callers share one renewal', () async {
      await authenticate(expiresIn: 30);
      final completer = Completer<TokenSet>();
      api.refreshAnswers.add(() => completer.future);

      final calls = [for (var i = 0; i < 10; i++) session.validIdToken()];
      completer.complete(_tokens('id-2'));

      expect(await Future.wait(calls), List.filled(10, 'id-2'));
      expect(api.calls.where((c) => c == 'refresh'), hasLength(2));
    });

    test('a 401 while renewing expires the session', () async {
      await authenticate(expiresIn: 30);
      api.refreshFails(401);

      await expectLater(
        session.validIdToken(),
        throwsA(
            isA<AuthApiException>().having((e) => e.statusCode, 'status', 401)),
      );

      expect(session.state, SessionState.expired);
      expect(session.message, 'Your session has expired. Please log in again.');
    });

    test('another renewal error keeps the session', () async {
      await authenticate(expiresIn: 30);
      api.refreshFails(503, 'Try again shortly.');

      await expectLater(
        session.validIdToken(),
        throwsA(isA<AuthApiException>()
            .having((e) => e.message, 'message', 'Try again shortly.')),
      );

      expect(session.state, SessionState.authenticated);
    });

    test('a renewal that ends after logout does not restore the session',
        () async {
      await authenticate(expiresIn: 30);
      final completer = Completer<TokenSet>();
      api.refreshAnswers.add(() => completer.future);

      final pending = session.validIdToken();
      pending.ignore();
      await session.logout();
      completer.complete(_tokens('id-late'));
      await Future<void>.delayed(Duration.zero);

      expect(session.state, SessionState.unauthenticated);
      await expectLater(
          session.validIdToken(), throwsA(isA<AuthApiException>()));
    });
  });

  group('renewAfterRejection', () {
    test('forces a renewal of the rejected token', () async {
      await authenticate();
      api.refreshReturns(_tokens('id-2'));

      expect(await session.renewAfterRejection('id-1'), 'id-2');
    });

    test('reuses a newer token that another caller already obtained', () async {
      await authenticate();
      api.refreshReturns(_tokens('id-2'));
      await session.renewAfterRejection('id-1');

      expect(await session.renewAfterRejection('id-1'), 'id-2');
      expect(api.calls.where((c) => c == 'refresh'), hasLength(2));
    });
  });

  group('stale results', () {
    test('a logout that ends after a new login does not notify or overwrite',
        () async {
      await authenticate();
      final logoutGate = Completer<void>();
      api.logoutGate = logoutGate;

      final loggingOut = session.logout();
      api.loginAnswer = () async => _tokens('id-new');
      await session.login('me@example.com', 'pw');
      var notifications = 0;
      session.addListener(() => notifications++);
      logoutGate.complete();
      await loggingOut;

      expect(notifications, 0);
      expect(session.state, SessionState.authenticated);
      expect(await session.validIdToken(), 'id-new');
    });

    test('an old renewal that ends does not clear a newer renewal', () async {
      await authenticate(expiresIn: 30);
      final oldRenewal = Completer<TokenSet>();
      final newRenewal = Completer<TokenSet>();
      api.refreshAnswers.add(() => oldRenewal.future);
      final stale = session.validIdToken();
      stale.ignore();
      final loggingOut = session.logout();
      api.loginAnswer = () async => _tokens('id-new', expiresIn: 30);
      await loggingOut;
      await session.login('me@example.com', 'pw');
      api.refreshAnswers.add(() => newRenewal.future);
      final current = session.validIdToken();

      oldRenewal.complete(_tokens('id-late'));
      await Future<void>.delayed(Duration.zero);
      final joined = session.validIdToken();
      newRenewal.complete(_tokens('id-renewed'));

      expect(await current, 'id-renewed');
      expect(await joined, 'id-renewed');
      expect(api.calls.where((c) => c == 'refresh'), hasLength(3));
    });

    test('markExpired for a token that was already replaced keeps the session',
        () async {
      await authenticate();
      api.refreshReturns(_tokens('id-2'));
      await session.renewAfterRejection('id-1');

      session.markExpired('id-1');

      expect(session.state, SessionState.authenticated);
      expect(await session.validIdToken(), 'id-2');
    });

    test('markExpired without a session does not show the expiry message',
        () async {
      await authenticate();
      await session.logout();

      session.markExpired('id-1');

      expect(session.state, SessionState.unauthenticated);
      expect(session.message, isNull);
    });
  });

  group('markExpired', () {
    test('drops the tokens and shows the expiry message', () async {
      await authenticate();

      session.markExpired('id-1');

      expect(session.state, SessionState.expired);
      expect(session.message, 'Your session has expired. Please log in again.');
      await expectLater(
          session.validIdToken(), throwsA(isA<AuthApiException>()));
    });
  });

  test('listeners are notified on every state change', () async {
    var notifications = 0;
    session.addListener(() => notifications++);

    await authenticate();
    await session.logout();

    expect(notifications, greaterThanOrEqualTo(2));
  });
}
