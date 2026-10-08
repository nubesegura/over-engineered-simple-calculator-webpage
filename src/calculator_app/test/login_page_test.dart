import 'dart:async';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/session_controller.dart';
import 'package:calculator_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _tokens = TokenSet(
  idToken: 'id',
  accessToken: 'access',
  expiresIn: Duration(hours: 1),
);

/// Every call waits for the test to answer it.
class ScriptedAuthApi implements AuthApi {
  final List<String> calls = [];
  final List<String> loginUsers = [];
  // Created lazily so they belong to the zone of the running test.
  late Completer<TokenSet> refreshAnswer = Completer();
  late Completer<TokenSet> loginAnswer = Completer();
  late Completer<void> logoutAnswer = Completer();

  @override
  Future<TokenSet> refresh() {
    calls.add('refresh');
    return refreshAnswer.future;
  }

  @override
  Future<TokenSet> login(String username, String password) {
    calls.add('login');
    loginUsers.add(username);
    loginAnswer = Completer();
    return loginAnswer.future;
  }

  @override
  Future<void> logout() {
    calls.add('logout');
    return logoutAnswer.future;
  }
}

void main() {
  late ScriptedAuthApi api;

  setUp(() => api = ScriptedAuthApi());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(CalculatorApp(
      loginSupported: true,
      session: SessionController(api),
    ));
  }

  Future<void> showLogin(WidgetTester tester) async {
    await pumpApp(tester);
    api.refreshAnswer
        .completeError(const AuthApiException('No session.', statusCode: 401));
    await tester.pumpAndSettle();
  }

  Future<void> typeCredentials(WidgetTester tester) async {
    await tester.enterText(
        find.byKey(const Key('login-email-field')), 'me@example.com');
    await tester.enterText(
        find.byKey(const Key('login-password-field')), 'secret-pw');
  }

  testWidgets('shows a loading state while the session is restored',
      (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('session-loading')), findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsNothing);
    expect(api.calls, ['refresh']);
  });

  testWidgets('shows the login screen after a 401 refresh', (tester) async {
    await showLogin(tester);

    expect(find.byKey(const Key('login-email-field')), findsOneWidget);
    expect(find.byKey(const Key('login-password-field')), findsOneWidget);
    expect(find.byKey(const Key('login-message')), findsNothing);
    expect(find.byKey(const Key('first-number-field')), findsNothing);
    final password =
        tester.widget<TextField>(find.byKey(const Key('login-password-field')));
    expect(password.obscureText, isTrue);
  });

  testWidgets('shows the calculator right away when the refresh succeeds',
      (tester) async {
    await pumpApp(tester);
    api.refreshAnswer.complete(_tokens);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-number-field')), findsOneWidget);
    expect(find.byKey(const Key('logout-button')), findsOneWidget);
  });

  testWidgets('a successful login shows the calculator with progress before',
      (tester) async {
    await showLogin(tester);
    await typeCredentials(tester);

    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    expect(find.byKey(const Key('login-progress')), findsOneWidget);
    expect(api.loginUsers, ['me@example.com']);

    api.loginAnswer.complete(_tokens);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-number-field')), findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsNothing);
  });

  testWidgets(
      'a failed login keeps the email, clears the password and shows '
      'the message', (tester) async {
    await showLogin(tester);
    await typeCredentials(tester);

    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    api.loginAnswer.completeError(const AuthApiException(
        'The username or password is incorrect.',
        statusCode: 401));
    await tester.pumpAndSettle();

    final email =
        tester.widget<TextField>(find.byKey(const Key('login-email-field')));
    final password =
        tester.widget<TextField>(find.byKey(const Key('login-password-field')));
    expect(email.controller!.text, 'me@example.com');
    expect(password.controller!.text, isEmpty);
    expect(find.text('The username or password is incorrect.'), findsOneWidget);
    expect(find.byKey(const Key('login-progress')), findsNothing);
  });

  testWidgets('an empty form does not call the BFF', (tester) async {
    await showLogin(tester);

    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();

    expect(api.calls, ['refresh']);
  });

  testWidgets('logout returns to the login screen', (tester) async {
    await pumpApp(tester);
    api.refreshAnswer.complete(_tokens);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logout-button')));
    await tester.pump();
    api.logoutAnswer.complete();
    await tester.pumpAndSettle();

    expect(api.calls, ['refresh', 'logout']);
    expect(find.byKey(const Key('login-email-field')), findsOneWidget);
    expect(find.byKey(const Key('first-number-field')), findsNothing);
    expect(find.byKey(const Key('login-message')), findsNothing);
  });

  testWidgets('an expired session shows the expiry message on the login screen',
      (tester) async {
    final session = SessionController(api);
    await tester
        .pumpWidget(CalculatorApp(loginSupported: true, session: session));
    api.refreshAnswer.complete(_tokens);
    await tester.pumpAndSettle();

    session.markExpired('id');
    await tester.pumpAndSettle();

    expect(find.text('Your session has expired. Please log in again.'),
        findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsOneWidget);
  });

  testWidgets('a failed first refresh offers a retry', (tester) async {
    await pumpApp(tester);
    api.refreshAnswer.completeError(
        const AuthApiException('Try again shortly.', statusCode: 503));
    await tester.pumpAndSettle();

    expect(find.text('Try again shortly.'), findsOneWidget);

    api.refreshAnswer = Completer();
    await tester.tap(find.byKey(const Key('login-retry')));
    await tester.pump();
    expect(find.byKey(const Key('session-loading')), findsOneWidget);
    api.refreshAnswer.complete(_tokens);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-number-field')), findsOneWidget);
  });

  testWidgets(
      'outside the web the login is replaced by a notice and the BFF '
      'is never called', (tester) async {
    await tester.pumpWidget(CalculatorApp(
      loginSupported: false,
      session: SessionController(api),
    ));

    expect(find.text('Login is only available in the web version.'),
        findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsNothing);
    expect(api.calls, isEmpty);
  });
}
