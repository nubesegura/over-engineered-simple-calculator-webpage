// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:math';

import 'package:calculator_app/auth/auth_api.dart';
import 'package:calculator_app/auth/token_source.dart';
import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_calculator_client.dart';
import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:calculator_app/realtime/realtime_controller.dart';
import 'package:calculator_app/realtime/realtime_status.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_realtime_channel.dart';

class FakeTokenSource implements TokenSource {
  int validCalls = 0;
  int renewCalls = 0;
  final List<String> rejected = [];
  Object? validError;
  Object? renewError;
  int _generation = 1;

  String get current => 'idtoken-$_generation';

  @override
  Future<String> validIdToken() async {
    validCalls++;
    final error = validError;
    if (error != null) throw error;
    return current;
  }

  @override
  Future<String> renewAfterRejection(String rejectedToken) async {
    renewCalls++;
    rejected.add(rejectedToken);
    final error = renewError;
    if (error != null) throw error;
    _generation++;
    return current;
  }

  /// A silent renewal by the session: the next connection uses the new token.
  void renewInBackground() => _generation++;

  @override
  void markExpired(String rejectedToken) {}
}

/// Returns a fixed fraction so the jitter is predictable.
class _FixedRandom implements Random {
  _FixedRandom(this.fraction);

  final double fraction;

  @override
  double nextDouble() => fraction;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

class _GatedFactory implements RealtimeChannelFactory {
  _GatedFactory(this._next);

  final Future<RealtimeChannel> _next;

  @override
  Future<RealtimeChannel> connect(Uri uri, {Iterable<String>? protocols}) =>
      _next;
}

class _SequenceFactory implements RealtimeChannelFactory {
  _SequenceFactory(this._results);

  final List<Future<RealtimeChannel>> _results;

  @override
  Future<RealtimeChannel> connect(Uri uri, {Iterable<String>? protocols}) =>
      _results.removeAt(0);
}

const String _address = 'wss://example.invalid/dev';

int _timers(FakeAsync async) =>
    async.nonPeriodicTimerCount + async.periodicTimerCount;

String _tokenOf(Uri uri) => uri.queryParameters['token']!;

void main() {
  late FakeTokenSource tokens;

  setUp(() => tokens = FakeTokenSource());

  RealtimeController build(
    FakeChannelFactory factory, {
    String address = _address,
    double jitter = 0,
    bool tabVisible = true,
  }) =>
      RealtimeController(
        tokens: tokens,
        address: RealtimeAddress.parse(address),
        channels: factory,
        client: RealtimeCalculatorClient(newTxId: () => 'tx-1'),
        random: _FixedRandom(jitter),
        tabVisible: tabVisible,
      );

  void settle(FakeAsync async) => async.flushMicrotasks();

  group('address', () {
    test('an empty address opens nothing and never uses the token', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([]);
        final controller = build(factory, address: '');
        controller.activate();
        settle(async);
        expect(controller.status.kind, RealtimeStatusKind.notConfigured);
        expect(
            controller.status.detail, RealtimeConstants.notConfiguredMessage);
        expect(factory.uris, isEmpty);
        expect(tokens.validCalls, 0);
        async.elapse(const Duration(hours: 3));
        expect(factory.uris, isEmpty);
      });
    });

    test('an invalid address opens nothing and says why', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([]);
        final controller = build(factory, address: 'https://example.invalid');
        controller.activate();
        settle(async);
        expect(controller.status.kind, RealtimeStatusKind.notConfigured);
        expect(
            controller.status.detail, RealtimeConstants.invalidAddressMessage);
        expect(factory.uris, isEmpty);
        expect(tokens.validCalls, 0);
      });
    });
  });

  group('mode selection', () {
    test('no connection and no token use while real-time is not selected', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([FakeRealtimeChannel()]);
        final controller = build(factory);
        async.elapse(const Duration(hours: 1));
        expect(controller.isActive, isFalse);
        expect(factory.uris, isEmpty);
        expect(tokens.validCalls, 0);
      });
    });

    test('selecting real-time connects with the ID token in the address', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        final controller = build(factory);
        final seen = <RealtimeStatus>[];
        controller.addListener(() => seen.add(controller.status));
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.connected);
        expect(_tokenOf(factory.uris.single), 'idtoken-1');
        expect(seen.first, RealtimeStatus.connecting);
      });
    });

    test('leaving real-time closes with the normal code and stops everything',
        () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        controller.deactivate();
        settle(async);
        expect(channel.closedByClient, isTrue);
        expect(outcome, isA<CalculationCancelled>());
        expect(controller.isActive, isFalse);
        async.elapse(const Duration(hours: 4));
        expect(factory.uris, hasLength(1));
        expect(channel.pingCount, 0);
        expect(_timers(async), 0);
      });
    });

    test('dispose closes the socket and cancels every timer', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        controller.dispose();
        settle(async);
        expect(channel.closedByClient, isTrue);
        expect(_timers(async), 0);
      });
    });

    test('closing before the connection finishes drops the late socket', () {
      fakeAsync((async) {
        final late = FakeRealtimeChannel();
        final gate = Completer<RealtimeChannel>();
        final controller = RealtimeController(
          tokens: tokens,
          address: RealtimeAddress.parse(_address),
          channels: _GatedFactory(gate.future),
        );
        controller.activate();
        settle(async);
        controller.deactivate();
        gate.complete(late);
        settle(async);
        expect(late.closedByClient, isTrue);
        expect(controller.status, RealtimeStatus.disconnected);
      });
    });
  });

  group('token and refusal', () {
    test('a refusal renews the session once and the retry connects', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory(
          [RealtimeFailure.refused, FakeRealtimeChannel()],
        );
        final controller = build(factory);
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.connected);
        expect(tokens.renewCalls, 1);
        expect(tokens.rejected, ['idtoken-1']);
        expect(_tokenOf(factory.uris[0]), 'idtoken-1');
        expect(_tokenOf(factory.uris[1]), 'idtoken-2');
      });
    });

    test('a second refusal is Not authorized, with no loop', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory(
          [RealtimeFailure.refused, RealtimeFailure.refused],
        );
        final controller = build(factory);
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.notAuthorized);
        async.elapse(const Duration(minutes: 5));
        expect(factory.uris, hasLength(2));
        expect(tokens.renewCalls, 1);
      });
    });

    test('a session that ended during renewal closes everything', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([RealtimeFailure.refused]);
        tokens.renewError = const AuthApiException('gone', statusCode: 401);
        final controller = build(factory);
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.disconnected);
        async.elapse(const Duration(minutes: 5));
        expect(factory.uris, hasLength(1));
      });
    });

    test('a pending request fails with Session expired when the session ends',
        () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        tokens.validError = const AuthApiException('gone', statusCode: 401);
        channel.serverClose();
        async.elapse(const Duration(seconds: 2));
        final failure = outcome! as CalculationFailure;
        expect(failure.kind, FailureKind.sessionExpired);
        expect(controller.status, RealtimeStatus.disconnected);
        expect(controller.isActive, isFalse);
      });
    });

    test('a token that cannot be read for a network reason is retried', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([FakeRealtimeChannel()]);
        tokens.validError = const AuthApiException('offline');
        final controller = build(factory);
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.reconnecting(1));
        tokens.validError = null;
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('a renewal done by the session leaves the open connection alone', () {
      fakeAsync((async) {
        final factory = FakeChannelFactory([FakeRealtimeChannel()]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        tokens.renewInBackground();
        async.elapse(const Duration(minutes: 60));
        expect(factory.uris, hasLength(1));
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('the token appears in no status, label, detail or failure text', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([
          RealtimeFailure.refused,
          channel,
          RealtimeFailure.refused,
          RealtimeFailure.refused,
        ]);
        final controller = build(factory);
        final texts = <String>[];
        controller.addListener(() {
          texts
            ..add(controller.status.toString())
            ..add(controller.status.label)
            ..add(controller.status.detail ?? '');
        });
        controller.activate();
        settle(async);
        channel.onRequest = (_) => channel.receive(errorReply('UNAUTHORIZED'));
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => texts.add(o.toString()));
        settle(async);
        async.elapse(const Duration(minutes: 2));
        texts.add(controller.toString());
        expect(texts, isNotEmpty);
        for (final text in texts) {
          expect(text, isNot(contains('idtoken')));
          expect(text, isNot(contains('example')));
        }
      });
    });
  });

  group('reconnection', () {
    Duration delayOf(int attempt) =>
        RealtimeController.reconnectDelay(attempt, 0);

    test('delays double from 1 s and are capped at 30 s, with jitter', () {
      expect([for (var i = 1; i <= 5; i++) delayOf(i).inSeconds],
          [1, 2, 4, 8, 16]);
      expect(delayOf(6), const Duration(seconds: 30));
      expect(delayOf(20), const Duration(seconds: 30));
      expect(RealtimeController.reconnectDelay(1, 1),
          const Duration(milliseconds: 1250));
      expect(RealtimeController.reconnectDelay(10, 1),
          const Duration(seconds: 30));
    });

    test('follows the backoff schedule and stops after 5 attempts', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        for (var i = 0; i < 6; i++) {
          factory.add(RealtimeFailure.timeout);
        }
        final controller = build(factory);
        controller.activate();
        settle(async);
        channel.serverClose();
        expect(controller.status, RealtimeStatus.reconnecting(1));
        expect(factory.uris, hasLength(1));

        var expectedUris = 1;
        for (var attempt = 1; attempt <= 5; attempt++) {
          final wait = delayOf(attempt);
          async.elapse(wait - const Duration(milliseconds: 1));
          expect(factory.uris, hasLength(expectedUris),
              reason: 'before $attempt');
          async.elapse(const Duration(milliseconds: 1));
          expectedUris++;
          expect(factory.uris, hasLength(expectedUris),
              reason: 'attempt $attempt');
          if (attempt < 5) {
            expect(controller.status, RealtimeStatus.reconnecting(attempt + 1));
          }
        }
        expect(controller.status, RealtimeStatus.disconnected);
        async.elapse(const Duration(hours: 1));
        expect(factory.uris, hasLength(6));
      });
    });

    test('the jitter lengthens the wait', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel, FakeRealtimeChannel()]);
        final controller = build(factory, jitter: 1);
        controller.activate();
        settle(async);
        channel.serverClose();
        async.elapse(const Duration(seconds: 1));
        expect(factory.uris, hasLength(1));
        async.elapse(const Duration(milliseconds: 250));
        expect(factory.uris, hasLength(2));
      });
    });

    test('a manual reconnect starts again after Disconnected', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        for (var i = 0; i < 5; i++) {
          factory.add(RealtimeFailure.timeout);
        }
        final controller = build(factory);
        controller.activate();
        settle(async);
        channel.serverClose();
        async.elapse(const Duration(minutes: 5));
        expect(controller.status, RealtimeStatus.disconnected);

        factory.add(FakeRealtimeChannel());
        controller.reconnect();
        settle(async);
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('a connection that stays open resets the attempt counter', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory =
            FakeChannelFactory([first, second, FakeRealtimeChannel()]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        first.serverClose();
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, RealtimeStatus.connected);
        async.elapse(RealtimeConstants.stableConnection);
        second.serverClose();
        expect(controller.status, RealtimeStatus.reconnecting(1));
        async.elapse(const Duration(seconds: 1));
        expect(factory.uris, hasLength(3));
      });
    });

    test('a connection that closes at once does not reset the counter', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory =
            FakeChannelFactory([first, second, FakeRealtimeChannel()]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        first.serverClose();
        async.elapse(const Duration(seconds: 1));
        second.serverClose();
        expect(controller.status, RealtimeStatus.reconnecting(2));
      });
    });

    test('the same txId is resent on the new connection', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([first, second]));
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        first.serverClose();
        async.elapse(const Duration(seconds: 1));
        expect(second.sentRequests.single['txId'], 'tx-1');
        controller.discardPending();
        settle(async);
        expect(outcome, isA<CalculationCancelled>());
      });
    });

    test('a pending request fails when the attempts run out', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        for (var i = 0; i < 5; i++) {
          factory.add(RealtimeFailure.timeout);
        }
        final controller = build(factory);
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        channel.serverClose();
        async.elapse(const Duration(minutes: 2));
        expect(controller.status, RealtimeStatus.disconnected);
        expect(outcome, isA<CalculationFailure>());
      });
    });
  });

  group('rotation', () {
    test('an idle connection is replaced after 110 minutes with a new token',
        () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first, second]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        tokens.renewInBackground();
        async.elapse(
            RealtimeConstants.rotationInterval - const Duration(seconds: 1));
        expect(first.closedByClient, isFalse);
        async.elapse(const Duration(seconds: 1));
        settle(async);
        expect(first.closedByClient, isTrue);
        expect(factory.uris, hasLength(2));
        expect(_tokenOf(factory.uris[1]), 'idtoken-2');
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('with a request pending, it rotates right after the answer', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first, second]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        async.elapse(
            RealtimeConstants.rotationInterval - const Duration(seconds: 5));
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        async.elapse(const Duration(seconds: 5));
        expect(first.closedByClient, isFalse);
        first.receive(resultReply('tx-1'));
        settle(async);
        expect(outcome, isA<CalculationSuccess>());
        expect(first.closedByClient, isTrue);
        expect(factory.uris, hasLength(2));
      });
    });
  });

  group('ping', () {
    test('every 300 s while selected, visible and idle', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        async.elapse(const Duration(seconds: 299));
        expect(channel.pingCount, 0);
        async.elapse(const Duration(seconds: 1));
        expect(channel.pingCount, 1);
        async.elapse(const Duration(seconds: 300));
        expect(channel.pingCount, 2);
      });
    });

    test('the reply to a ping is ignored', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        async.elapse(const Duration(seconds: 300));
        channel.receive(errorReply('UNKNOWN_ACTION'));
        settle(async);
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('none while the tab is hidden; it resumes when visible again', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        controller.setTabVisible(false);
        async.elapse(const Duration(minutes: 5));
        expect(channel.pingCount, 0);
        controller.setTabVisible(true);
        async.elapse(const Duration(seconds: 300));
        expect(channel.pingCount, 1);
      });
    });

    test('none while a request is pending', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        async.elapse(const Duration(seconds: 299));
        controller.calculate(operation: 'mul', a: '6', b: '7');
        settle(async);
        async.elapse(const Duration(seconds: 1));
        expect(channel.pingCount, 0);
      });
    });
  });

  group('hidden tab', () {
    test('an idle close while hidden reconnects on demand, not by itself', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first, second]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        controller.setTabVisible(false);
        first.serverClose();
        async.elapse(const Duration(minutes: 10));
        expect(controller.status, RealtimeStatus.disconnected);
        expect(factory.uris, hasLength(1));
        controller.setTabVisible(true);
        settle(async);
        expect(factory.uris, hasLength(2));
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('Calculate while waiting on demand sends nothing and reconnects', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first, second]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        controller.setTabVisible(false);
        first.serverClose();
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        expect((outcome! as CalculationFailure).kind, FailureKind.notConnected);
        expect(first.sent, isEmpty);
        expect(controller.status, RealtimeStatus.connected);
        expect(factory.uris, hasLength(2));
      });
    });
  });

  group('calculate', () {
    test('sends and returns the result when connected', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([channel]));
        controller.activate();
        settle(async);
        channel.onRequest =
            (r) => channel.receive(resultReply(r['txId'] as String));
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        expect((outcome! as CalculationSuccess).result, '42');
        expect(controller.isBusy, isFalse);
      });
    });

    test('sends nothing when not connected', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final controller = build(FakeChannelFactory([RealtimeFailure.timeout]));
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        expect((outcome! as CalculationFailure).kind, FailureKind.notConnected);
        expect(channel.sent, isEmpty);
      });
    });

    test('an UNAUTHORIZED reply drops the connection and reconnects', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first, second]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        first.onRequest = (_) => first.receive(errorReply('UNAUTHORIZED'));
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        expect((outcome! as CalculationFailure).kind, FailureKind.unauthorized);
        expect(first.closedByClient, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, RealtimeStatus.connected);
        expect(factory.uris, hasLength(2));
      });
    });

    test('a refusal while the network is down keeps backing off', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([
          channel,
          RealtimeFailure.refused,
          RealtimeFailure.refused,
          FakeRealtimeChannel(),
        ]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        channel.serverClose();
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, RealtimeStatus.reconnecting(2));
        async.elapse(const Duration(seconds: 2));
        expect(controller.status, RealtimeStatus.reconnecting(3));
        async.elapse(const Duration(seconds: 4));
        expect(controller.status, RealtimeStatus.connected);
        expect(tokens.renewCalls, 0);
        expect(factory.uris, hasLength(4));
      });
    });

    test('refusals after a drop end as Disconnected, never Not authorized', () {
      fakeAsync((async) {
        final channel = FakeRealtimeChannel();
        final factory = FakeChannelFactory([channel]);
        final controller = build(factory);
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        channel.serverClose();
        async.elapse(const Duration(minutes: 2));
        expect(controller.status, RealtimeStatus.disconnected);
        expect(tokens.renewCalls, 0);
        expect((outcome! as CalculationFailure).kind, FailureKind.notConnected);
      });
    });

    test('an unexpected error while connecting ends in a defined state', () {
      fakeAsync((async) {
        tokens.validError = StateError('boom');
        final controller = build(FakeChannelFactory([]));
        controller.activate();
        settle(async);
        expect(controller.status, RealtimeStatus.reconnecting(1));
        tokens.validError = null;
        async.elapse(const Duration(minutes: 2));
        expect(controller.status, RealtimeStatus.disconnected);
      });
    });

    test('rotation opens the new socket before closing the old one', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final gate = Completer<RealtimeChannel>();
        final seen = <RealtimeStatus>[];
        final controller = RealtimeController(
          tokens: tokens,
          address: RealtimeAddress.parse(_address),
          channels: _SequenceFactory([Future.value(first), gate.future]),
          client: RealtimeCalculatorClient(newTxId: () => 'tx-1'),
          random: _FixedRandom(0),
        );
        controller.addListener(() => seen.add(controller.status));
        controller.activate();
        settle(async);
        seen.clear();
        async.elapse(RealtimeConstants.rotationInterval);
        settle(async);
        expect(first.closedByClient, isFalse);
        expect(controller.status, RealtimeStatus.connected);
        gate.complete(second);
        settle(async);
        expect(first.closedByClient, isTrue);
        expect(second.closedByClient, isFalse);
        expect(controller.status, RealtimeStatus.connected);
        expect(seen, isNot(contains(RealtimeStatus.connecting)));
      });
    });

    test('a failed rotation falls back to the backoff', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final factory = FakeChannelFactory(
          [first, RealtimeFailure.timeout, FakeRealtimeChannel()],
        );
        final controller = build(factory);
        controller.activate();
        settle(async);
        async.elapse(RealtimeConstants.rotationInterval);
        settle(async);
        expect(first.closedByClient, isTrue);
        expect(controller.status, RealtimeStatus.reconnecting(1));
        async.elapse(const Duration(seconds: 1));
        expect(controller.status, RealtimeStatus.connected);
      });
    });

    test('a 20 s outage does not use up the single retry', () {
      fakeAsync((async) {
        final first = FakeRealtimeChannel();
        final second = FakeRealtimeChannel();
        final factory = FakeChannelFactory([first]);
        for (var i = 0; i < 3; i++) {
          factory.add(RealtimeFailure.timeout);
        }
        factory.add(second);
        final controller = build(factory);
        controller.activate();
        settle(async);
        CalculationOutcome? outcome;
        controller
            .calculate(operation: 'mul', a: '6', b: '7')
            .then((o) => outcome = o);
        settle(async);
        first.serverClose();
        async.elapse(const Duration(seconds: 20));
        expect(controller.status, RealtimeStatus.connected);
        expect(outcome, isNull);
        expect(second.sentRequests, hasLength(1));
        expect(second.sentRequests.single['txId'], 'tx-1');
        second.receive(resultReply('tx-1'));
        settle(async);
        expect(outcome, isA<CalculationSuccess>());
      });
    });
  });
}
