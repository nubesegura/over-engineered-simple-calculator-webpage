import 'dart:convert';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _emptyHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

http.Response _tokens() => http.Response(
      jsonEncode(
          {'id_token': 'id', 'access_token': 'access', 'expires_in': 3600}),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _error(int status, String message) => http.Response(
      jsonEncode({
        'error': {'code': 'X', 'message': message, 'request_id': 'r'},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('HttpAuthApi', () {
    late http.Request captured;

    HttpAuthApi apiAnswering(http.Response response) =>
        HttpAuthApi(httpClient: MockClient((request) async {
          captured = request;
          return response;
        }));

    test('login posts the credentials to the relative URL with the headers',
        () async {
      final api = apiAnswering(_tokens());

      final tokens = await api.login('me@example.com', 'pw');

      expect(captured.method, 'POST');
      expect(captured.url.toString(), '/auth/login');
      expect(captured.headers['Content-Type'], startsWith('application/json'));
      expect(captured.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(jsonDecode(captured.body), {
        'username': 'me@example.com',
        'password': 'pw',
      });
      expect(tokens.idToken, 'id');
      expect(tokens.accessToken, 'access');
      expect(tokens.expiresIn, const Duration(seconds: 3600));
    });

    test('the content hash is the SHA-256 of the exact body bytes', () async {
      final api = apiAnswering(_tokens());

      await api.login('a', 'b');

      final expected = sha256Hex(captured.bodyBytes);
      expect(captured.headers['x-amz-content-sha256'], expected);
      expect(expected, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('sha256Hex matches known vectors', () {
      expect(sha256Hex(const []), _emptyHash);
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('refresh and logout send an empty body with the empty hash', () async {
      final api = apiAnswering(_tokens());
      await api.refresh();
      expect(captured.url.toString(), '/auth/refresh');
      expect(captured.bodyBytes, isEmpty);
      expect(captured.headers['x-amz-content-sha256'], _emptyHash);
      expect(captured.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(captured.headers['Content-Type'], startsWith('application/json'));

      final logoutApi = apiAnswering(http.Response('', 204));
      await logoutApi.logout();
      expect(captured.url.toString(), '/auth/logout');
      expect(captured.bodyBytes, isEmpty);
      expect(captured.headers['x-amz-content-sha256'], _emptyHash);
    });

    test('BFF errors become typed errors with message and status', () async {
      for (final status in [400, 401, 409, 429, 503]) {
        final api = apiAnswering(_error(status, 'msg $status'));
        await expectLater(
          api.refresh(),
          throwsA(isA<AuthApiException>()
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.message, 'message', 'msg $status')),
        );
      }
    });

    test('a non JSON error falls back to the status code', () async {
      final api = apiAnswering(http.Response('<html></html>', 502));

      await expectLater(
        api.login('a', 'b'),
        throwsA(isA<AuthApiException>()
            .having((e) => e.message, 'message', 'Request failed (HTTP 502).')),
      );
    });

    test('a malformed success body is an unexpected response', () async {
      final api = apiAnswering(http.Response('{"id_token": "x"}', 200));

      await expectLater(
        api.refresh(),
        throwsA(isA<AuthApiException>().having((e) => e.message, 'message',
            'Unexpected response from the server.')),
      );
    });

    test('network failures are reported without details', () async {
      final api = HttpAuthApi(
        httpClient: MockClient((_) async => throw http.ClientException('boom')),
      );

      await expectLater(
        api.logout(),
        throwsA(isA<AuthApiException>()
            .having(
                (e) => e.message, 'message', 'Connection to the server failed.')
            .having((e) => e.statusCode, 'status', isNull)),
      );
    });

    test('token sets never reveal the tokens when printed', () {
      const tokens = TokenSet(
        idToken: 'secret-id',
        accessToken: 'secret-access',
        expiresIn: Duration(seconds: 1),
      );

      expect(tokens.toString(), isNot(contains('secret')));
    });
  });
}
