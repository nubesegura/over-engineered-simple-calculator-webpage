import 'dart:async';
import 'dart:convert';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/token_source.dart';
import 'package:calculator_app/constants.dart';
import 'package:calculator_app/live_history/graphql_history_client.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeTokenSource implements TokenSource {
  int validCalls = 0;
  int renewCalls = 0;
  final List<String> rejectedTokens = [];
  final List<String> expiredTokens = [];
  Object? validError;
  Object? renewError;
  int _generation = 1;

  String get current => 'secret-jwt-token-$_generation';

  @override
  Future<String> validIdToken() async {
    validCalls++;
    if (validError != null) throw validError!;
    return current;
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    renewCalls++;
    rejectedTokens.add(rejectedToken);
    if (renewError != null) throw renewError!;
    _generation++;
    return current;
  }

  @override
  void markExpired(String rejectedToken) {
    expiredTokens.add(rejectedToken);
  }
}

final Uri _graphQlUri = Uri.parse(
  'https://example.appsync-api.us-east-2.amazonaws.com/graphql',
);

void main() {
  late _FakeTokenSource tokens;

  setUp(() {
    tokens = _FakeTokenSource();
  });

  group('GraphQlHistoryClient', () {
    test('sends POST with raw JWT, parses items, normalizes source and cursor',
        () async {
      http.Request? captured;
      final client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'data': {
                'history': {
                  'items': [
                    {
                      'txId': 'tx-1',
                      'a': 6.0,
                      'b': 7.0,
                      'op': 'MULTIPLY',
                      'result': 42.0,
                      'status': 'OK',
                      'errorCode': null,
                      'source': 'ws',
                      'createdAt': '2026-10-27T15:00:00Z',
                    },
                    {
                      'txId': 'tx-2',
                      'a': 1.0,
                      'b': 0.0,
                      'op': 'DIVIDE',
                      'result': null,
                      'status': 'ERROR',
                      'errorCode': 'DIVISION_BY_ZERO',
                      'source': 'single',
                      'createdAt': '2026-10-27T14:59:00Z',
                    },
                    {
                      'txId': '',
                      'broken': true,
                    },
                  ],
                  'nextToken': 'cursor-page-2',
                },
              },
            }),
            200,
          );
        }),
      );

      final page = await client.fetchHistory(limit: 20, nextToken: 'cursor-1');
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.url, _graphQlUri);
      expect(captured!.headers['Authorization'], 'secret-jwt-token-1');
      expect(
        captured!.headers['Content-Type'],
        startsWith('application/json'),
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['query'], kHistoryQuery);
      expect(body['variables'], {
        'limit': 20,
        'nextToken': 'cursor-1',
        'since': null,
      });

      expect(page.items, hasLength(2));
      expect(page.items[0].txId, 'tx-1');
      expect(page.items[0].a, '6');
      expect(page.items[0].b, '7');
      expect(page.items[0].result, '42');
      expect(page.items[0].transport, 'websocket');
      expect(page.items[1].txId, 'tx-2');
      expect(page.items[1].transport, 'graphql');
      expect(
        page.items[1].displayOutcome,
        LiveHistoryConstants.divideByZeroMessage,
      );
      expect(page.nextToken, 'cursor-page-2');
      expect(page.nextCursor, 'cursor-page-2');
    });

    test('HTTP 401 renews token once and succeeds on retry', () async {
      final seenAuth = <String?>[];
      var calls = 0;
      final client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((request) async {
          calls++;
          seenAuth.add(request.headers['Authorization']);
          if (calls == 1) {
            return http.Response('{"message":"Unauthorized"}', 401);
          }
          return http.Response(
            jsonEncode({
              'data': {
                'history': {'items': <Object>[], 'nextToken': null},
              },
            }),
            200,
          );
        }),
      );

      final page = await client.fetchHistory();
      expect(page.items, isEmpty);
      expect(page.nextToken, isNull);
      expect(tokens.renewCalls, 1);
      expect(tokens.rejectedTokens, ['secret-jwt-token-1']);
      expect(seenAuth, ['secret-jwt-token-1', 'secret-jwt-token-2']);
      expect(tokens.expiredTokens, isEmpty);
    });

    test('GraphQL Unauthorized errorType renews token once and retries',
        () async {
      var calls = 0;
      final client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((_) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'errors': [
                  {
                    'errorType': 'UnauthorizedException',
                    'message': 'Token expired',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'data': {
                'history': {'items': <Object>[], 'nextToken': null},
              },
            }),
            200,
          );
        }),
      );

      final page = await client.fetchHistory();
      expect(page.items, isEmpty);
      expect(tokens.renewCalls, 1);
      expect(tokens.expiredTokens, isEmpty);
    });

    test('two consecutive 401/Unauthorized responses call markExpired',
        () async {
      final client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((_) async {
          return http.Response('{"message":"Unauthorized"}', 401);
        }),
      );

      await expectLater(
        client.fetchHistory(),
        throwsA(
          isA<LiveHistoryAuthException>().having(
            (e) => e.message,
            'message',
            AuthConstants.sessionExpiredMessage,
          ),
        ),
      );
      expect(tokens.renewCalls, 1);
      expect(tokens.expiredTokens, ['secret-jwt-token-2']);
    });

    test('401 during token renewal surfaces LiveHistoryAuthException',
        () async {
      tokens.renewError = const AuthApiException('expired', statusCode: 401);
      final client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient(
          (_) async => http.Response('{"message":"Unauthorized"}', 401),
        ),
      );

      await expectLater(
        client.fetchHistory(),
        throwsA(isA<LiveHistoryAuthException>()),
      );
    });

    test(
        'GraphQL InternalError, HTTP 500, malformed JSON and timeout redact details',
        () async {
      final internalErrorClient = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((_) async {
          return http.Response(
            jsonEncode({
              'errors': [
                {
                  'errorType': 'InternalError',
                  'message': 'DynamoDB table secret-table failed',
                },
              ],
            }),
            200,
          );
        }),
      );
      await expectLater(
        internalErrorClient.fetchHistory(),
        throwsA(
          isA<LiveHistoryException>()
              .having(
                (e) => e.toString(),
                'toString',
                LiveHistoryConstants.loadErrorMessage,
              )
              .having(
                  (e) => e.toString(), 'no table', isNot(contains('secret')))
              .having(
                (e) => e.toString(),
                'no domain',
                isNot(contains('example')),
              ),
        ),
      );

      final http500Client = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient(
          (_) async => http.Response('internal crash', 500),
        ),
      );
      await expectLater(
        http500Client.fetchHistory(),
        throwsA(isA<LiveHistoryException>()),
      );

      final badJsonClient = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        httpClient: MockClient((_) async => http.Response('not-json', 200)),
      );
      await expectLater(
        badJsonClient.fetchHistory(),
        throwsA(isA<LiveHistoryException>()),
      );

      final timeoutClient = GraphQlHistoryClient(
        graphQlUri: _graphQlUri,
        tokens: tokens,
        requestTimeout: const Duration(milliseconds: 5),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(
        timeoutClient.fetchHistory(),
        throwsA(isA<LiveHistoryException>()),
      );

      expect(clientToString(internalErrorClient), 'GraphQlHistoryClient()');
    });
  });
}

String clientToString(GraphQlHistoryClient client) => client.toString();
