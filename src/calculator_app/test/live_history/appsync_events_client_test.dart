// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:calculator_app/live_history/appsync_events_client.dart';
import 'package:calculator_app/live_history/live_calculation.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../realtime/fake_realtime_channel.dart';

final Uri _realtimeUri = Uri.parse(
  'wss://example.appsync-realtime-api.us-east-2.amazonaws.com/event/realtime',
);
const String _httpDomain = 'example.appsync-api.us-east-2.amazonaws.com';
const String _token = 'secret-id-token-value';
const String _sub = '11111111-2222-4333-8444-555555555555';

void _scriptHandshake(
  FakeRealtimeChannel channel, {
  int? connectionTimeoutMs = 20000,
}) {
  channel.onRequest = (request) {
    final type = request['type'];
    if (type == 'connection_init') {
      channel.receive(
        jsonEncode({
          'type': 'connection_ack',
          if (connectionTimeoutMs != null)
            'connectionTimeoutMs': connectionTimeoutMs,
        }),
      );
    } else if (type == 'subscribe') {
      channel.receive(
        jsonEncode({
          'type': 'subscribe_success',
          'id': request['id'],
        }),
      );
    }
  };
}

void main() {
  group('AppSyncEventsClient', () {
    test(
        'builds unpadded header-<base64url> subprotocol and completes handshake',
        () async {
      final channel = FakeRealtimeChannel();
      _scriptHandshake(channel, connectionTimeoutMs: 45000);
      final factory = FakeChannelFactory([channel]);
      final client = AppSyncEventsClient(
        channels: factory,
        newSubscriptionId: () => 'sub-uuid-1',
      );

      final session = await client.subscribe(
        realtimeUri: _realtimeUri,
        httpDomain: _httpDomain,
        idToken: _token,
        sub: _sub,
      );

      expect(factory.uris, [_realtimeUri]);
      final protocols = factory.lastProtocols!;
      expect(protocols, hasLength(2));
      expect(protocols[0], LiveHistoryConstants.eventWsSubprotocol);
      expect(protocols[1], startsWith('header-'));
      expect(protocols[1], isNot(contains('=')));

      final encodedHeader = protocols[1]
          .substring(LiveHistoryConstants.authSubprotocolPrefix.length);
      final decodedHeader = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encodedHeader))),
      ) as Map<String, dynamic>;
      expect(decodedHeader, {
        'host': _httpDomain,
        'Authorization': _token,
      });

      expect(channel.sentRequests, hasLength(2));
      expect(channel.sentRequests[0], {'type': 'connection_init'});
      expect(channel.sentRequests[1], {
        'type': 'subscribe',
        'id': 'sub-uuid-1',
        'channel': '/history/$_sub',
        'authorization': {
          'host': _httpDomain,
          'Authorization': _token,
        },
      });
      expect(session.keepAliveTimeout, const Duration(milliseconds: 45000));
      expect(session.subscriptionId, 'sub-uuid-1');

      await session.close();
      expect(channel.closedByClient, isTrue);
      expect(channel.sentRequests.last, {
        'type': 'unsubscribe',
        'id': 'sub-uuid-1',
      });
    });

    test('clamps connectionTimeoutMs between 10s and 600s with 300s default',
        () {
      expect(
        AppSyncEventsClient.clampKeepAliveTimeout(null),
        const Duration(seconds: 300),
      );
      expect(
        AppSyncEventsClient.clampKeepAliveTimeout(1000),
        const Duration(seconds: 10),
      );
      expect(
        AppSyncEventsClient.clampKeepAliveTimeout(999999),
        const Duration(seconds: 600),
      );
    });

    test('ka and data frames reset keep-alive watchdog; timeout closes session',
        () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        _scriptHandshake(channel, connectionTimeoutMs: 10000);
        final client = AppSyncEventsClient(
          channels: FakeChannelFactory([channel]),
          newSubscriptionId: () => 'sub-1',
        );

        AppSyncEventsSession? session;
        client
            .subscribe(
              realtimeUri: _realtimeUri,
              httpDomain: _httpDomain,
              idToken: _token,
              sub: _sub,
            )
            .then((s) => session = s);
        async.flushMicrotasks();
        expect(session, isNotNull);

        var doneCompleted = false;
        session!.done.then((_) => doneCompleted = true);

        async.elapse(const Duration(seconds: 9));
        expect(doneCompleted, isFalse);

        // A ka frame resets the 10s timer.
        channel.receive(jsonEncode({'type': 'ka'}));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));
        expect(doneCompleted, isFalse);
        expect(session!.ignoredCount, 0);

        // Letting the full 10s expire closes the session.
        async.elapse(const Duration(seconds: 2));
        expect(doneCompleted, isTrue);
        expect(channel.closedByClient, isTrue);
      });
    });

    test('parses string-encoded and map-encoded calculation data events',
        () async {
      final channel = FakeRealtimeChannel();
      _scriptHandshake(channel);
      final client = AppSyncEventsClient(
        channels: FakeChannelFactory([channel]),
        newSubscriptionId: () => 'sub-1',
      );
      final session = await client.subscribe(
        realtimeUri: _realtimeUri,
        httpDomain: _httpDomain,
        idToken: _token,
        sub: _sub,
      );

      final received = <LiveCalculation>[];
      session.calculations.listen(received.add);

      // String-encoded inner event.
      channel.receive(
        jsonEncode({
          'type': 'data',
          'id': 'sub-1',
          'event': jsonEncode({
            'type': 'calculation',
            'txId': 'tx-str',
            'a': '6',
            'b': '7',
            'op': 'MULTIPLY',
            'result': '42',
            'errorCode': null,
            'status': 'OK',
            'transport': 'websocket',
            'createdAt': '2026-10-27T15:00:00Z',
          }),
        }),
      );

      // Map-encoded inner event.
      channel.receive(
        jsonEncode({
          'type': 'data',
          'id': 'sub-1',
          'event': {
            'type': 'calculation',
            'txId': 'tx-map',
            'a': '1',
            'b': '0',
            'op': 'DIVIDE',
            'result': null,
            'errorCode': 'DIVISION_BY_ZERO',
            'status': 'ERROR',
            'transport': 'graphql',
            'createdAt': '2026-10-27T15:01:00Z',
          },
        }),
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(received[0].txId, 'tx-str');
      expect(received[0].result, '42');
      expect(received[1].txId, 'tx-map');
      expect(
        received[1].displayOutcome,
        LiveHistoryConstants.divideByZeroMessage,
      );
      expect(session.ignoredCount, 0);
      await session.close();
    });

    test('ignores and counts oversized, malformed and non-calculation frames',
        () async {
      final channel = FakeRealtimeChannel();
      _scriptHandshake(channel);
      final client = AppSyncEventsClient(
        channels: FakeChannelFactory([channel]),
      );
      final session = await client.subscribe(
        realtimeUri: _realtimeUri,
        httpDomain: _httpDomain,
        idToken: _token,
        sub: _sub,
      );

      final received = <LiveCalculation>[];
      session.calculations.listen(received.add);

      // 1. Oversized frame (> 64 KiB)
      channel.receive('x' * (64 * 1024 + 10));
      // 2. Invalid JSON
      channel.receive('{not-json');
      // 3. Non-map JSON
      channel.receive('[1, 2, 3]');
      // 4. Unknown frame type
      channel.receive(jsonEncode({'type': 'unknown_control'}));
      // 5. Data frame with invalid inner JSON string
      channel.receive(jsonEncode({'type': 'data', 'event': '{bad'}));
      // 6. Data frame with non-calculation event type
      channel.receive(
        jsonEncode({
          'type': 'data',
          'event': {'type': 'other', 'txId': 'tx-1'},
        }),
      );
      // 7. Data frame missing required calculation fields
      channel.receive(
        jsonEncode({
          'type': 'data',
          'event': {'type': 'calculation', 'txId': ''},
        }),
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      expect(session.ignoredCount, 7);
      await session.close();
    });

    test(
        'classifies upgrade refusal and subscribe_error Unauthorized as authRejected',
        () async {
      final refusedClient = AppSyncEventsClient(
        channels: FakeChannelFactory([RealtimeFailure.refused]),
      );
      await expectLater(
        refusedClient.subscribe(
          realtimeUri: _realtimeUri,
          httpDomain: _httpDomain,
          idToken: _token,
          sub: _sub,
        ),
        throwsA(
          isA<AppSyncHandshakeException>().having(
            (e) => e.isAuthRejected,
            'isAuthRejected',
            isTrue,
          ),
        ),
      );

      final subscribeErrorChannel = FakeRealtimeChannel();
      subscribeErrorChannel.onRequest = (request) {
        if (request['type'] == 'connection_init') {
          subscribeErrorChannel.receive(jsonEncode({'type': 'connection_ack'}));
        } else if (request['type'] == 'subscribe') {
          subscribeErrorChannel.receive(
            jsonEncode({
              'type': 'subscribe_error',
              'id': request['id'],
              'errors': [
                {'errorType': 'UnauthorizedException', 'message': 'Denied'},
              ],
            }),
          );
        }
      };
      final subErrorClient = AppSyncEventsClient(
        channels: FakeChannelFactory([subscribeErrorChannel]),
      );
      await expectLater(
        subErrorClient.subscribe(
          realtimeUri: _realtimeUri,
          httpDomain: _httpDomain,
          idToken: _token,
          sub: _sub,
        ),
        throwsA(
          isA<AppSyncHandshakeException>().having(
            (e) => e.isAuthRejected,
            'isAuthRejected',
            isTrue,
          ),
        ),
      );
      expect(subscribeErrorChannel.closedByClient, isTrue);
    });

    test('handshake timeout throws transient AppSyncHandshakeException', () {
      fakeAsync((async) {
        final silentChannel = FakeRealtimeChannel();
        final client = AppSyncEventsClient(
          channels: FakeChannelFactory([silentChannel]),
        );

        Object? caught;
        client
            .subscribe(
          realtimeUri: _realtimeUri,
          httpDomain: _httpDomain,
          idToken: _token,
          sub: _sub,
        )
            .then<void>(
          (_) {},
          onError: (Object e) {
            caught = e;
          },
        );

        async.elapse(const Duration(seconds: 16));
        async.flushMicrotasks();
        expect(caught, isA<AppSyncHandshakeException>());
        expect((caught! as AppSyncHandshakeException).isAuthRejected, isFalse);
        expect(silentChannel.closedByClient, isTrue);
      });
    });

    test('toString and exceptions never leak token, sub or domain', () async {
      final channel = FakeRealtimeChannel();
      _scriptHandshake(channel);
      final client = AppSyncEventsClient(
        channels: FakeChannelFactory([channel]),
      );
      final session = await client.subscribe(
        realtimeUri: _realtimeUri,
        httpDomain: _httpDomain,
        idToken: _token,
        sub: _sub,
      );
      const authEx = AppSyncHandshakeException.authRejected();
      const transEx = AppSyncHandshakeException.transient();

      for (final text in [
        client.toString(),
        session.toString(),
        authEx.toString(),
        transEx.toString(),
      ]) {
        expect(text, isNot(contains(_token)));
        expect(text, isNot(contains(_sub)));
        expect(text, isNot(contains('example')));
      }
      await session.close();
    });
  });
}
