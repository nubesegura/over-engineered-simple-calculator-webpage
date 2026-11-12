// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:calculator_app/realtime/realtime_calculator_client.dart';
import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_realtime_channel.dart';

const String _secret = 'secret-token-value';

void main() {
  late FakeRealtimeChannel channel;
  late RealtimeCalculatorClient client;
  var ids = 0;

  setUp(() {
    ids = 0;
    channel = FakeRealtimeChannel();
    client = RealtimeCalculatorClient(newTxId: () => 'tx-${++ids}');
    client.attach(channel);
  });

  /// Runs the calculation and replies to the first request with [reply].
  CalculationOutcome? runWith(
    FakeAsync async,
    String Function(String txId) reply, {
    String a = '6',
    String b = '7',
    String op = 'mul',
  }) {
    CalculationOutcome? outcome;
    channel.onRequest = (r) => client.handleMessage(reply(r['txId'] as String));
    client.calculate(operation: op, a: a, b: b).then((o) => outcome = o);
    async.flushMicrotasks();
    return outcome;
  }

  test('sends the request with string operands and shows the result', () {
    fakeAsync((async) {
      final outcome = runWith(async, (id) => resultReply(id), a: ' 6 ');
      expect(outcome, isA<CalculationSuccess>());
      expect((outcome! as CalculationSuccess).result, '42');
      final request = channel.sentRequests.single;
      expect(request, {
        'action': 'calculate',
        'txId': 'tx-1',
        'a': '6',
        'b': '7',
        'op': 'MULTIPLY',
      });
    });
  });

  test('maps the REST operation keys to the backend names', () {
    fakeAsync((async) {
      for (final entry in {
        'add': 'ADD',
        'sub': 'SUBTRACT',
        'mul': 'MULTIPLY',
        'div': 'DIVIDE',
      }.entries) {
        runWith(async, (id) => resultReply(id), op: entry.key);
        expect(channel.sentRequests.last['op'], entry.value);
      }
    });
  });

  test('DIVIDE_BY_ZERO result shows the fixed text', () {
    fakeAsync((async) {
      final outcome = runWith(
        async,
        (id) => resultReply(id, status: 'ERROR', errorCode: 'DIVIDE_BY_ZERO'),
        op: 'div',
      );
      expect(outcome, isA<CalculationFailure>());
      expect(
          (outcome! as CalculationFailure).message, 'Cannot divide by zero.');
    });
  });

  test('unknown error code in a result shows the generic text with the code',
      () {
    fakeAsync((async) {
      final outcome = runWith(
        async,
        (id) => resultReply(id, status: 'ERROR', errorCode: 'OVERFLOW'),
      );
      expect((outcome! as CalculationFailure).message,
          'The calculation failed (code OVERFLOW).');
    });
  });

  test('a status that is neither OK nor ERROR is an unexpected response', () {
    fakeAsync((async) {
      final outcome = runWith(async, (id) => resultReply(id, status: 'WAT'));
      expect((outcome! as CalculationFailure).message,
          RealtimeConstants.unexpectedResponseMessage);
    });
  });

  group('error replies', () {
    final cases = {
      'INVALID_REQUEST': 'The request was not valid.',
      'IDEMPOTENCY_CONFLICT':
          'This calculation id was already used. Try again.',
      'INTERNAL_ERROR': 'Something went wrong. Try again shortly.',
      'SOMETHING_ELSE': 'Unexpected response from the server.',
    };
    for (final entry in cases.entries) {
      test('${entry.key} shows a fixed text, never the server message', () {
        fakeAsync((async) {
          final outcome = runWith(async, (_) => errorReply(entry.key));
          final failure = outcome! as CalculationFailure;
          expect(failure.message, entry.value);
          expect(failure.message, isNot(contains('server text')));
          expect(failure.kind, FailureKind.calculation);
        });
      });
    }

    test('UNAUTHORIZED is reported so the controller can react', () {
      fakeAsync((async) {
        final outcome = runWith(async, (_) => errorReply('UNAUTHORIZED'));
        expect((outcome! as CalculationFailure).kind, FailureKind.unauthorized);
      });
    });

    test('an error without a code is an unexpected response', () {
      fakeAsync((async) {
        final outcome = runWith(async, (_) => jsonEncode({'type': 'error'}));
        expect((outcome! as CalculationFailure).message,
            RealtimeConstants.unexpectedResponseMessage);
      });
    });
  });

  test('times out after 15 s, retries once with the same txId, then fails', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.elapse(const Duration(seconds: 14));
      expect(channel.sentRequests, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(channel.sentRequests, hasLength(2));
      expect(channel.sentRequests[1]['txId'], channel.sentRequests[0]['txId']);
      expect(outcome, isNull);
      async.elapse(const Duration(seconds: 15));
      final failure = outcome! as CalculationFailure;
      expect(failure.message, RealtimeConstants.noAnswerMessage);
      expect(failure.kind, FailureKind.noAnswer);
      expect(client.isBusy, isFalse);

      client.calculate(operation: 'mul', a: '6', b: '7');
      async.flushMicrotasks();
      expect(channel.sentRequests.last['txId'], 'tx-2');
    });
  });

  test('the retry answer is accepted', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.elapse(RealtimeConstants.requestTimeout);
      client.handleMessage(resultReply('tx-1'));
      async.flushMicrotasks();
      expect(outcome, isA<CalculationSuccess>());
    });
  });

  test('a lost connection keeps the txId and resends it after reattaching', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      client.detach();
      final second = FakeRealtimeChannel();
      client.attach(second);
      expect(second.sentRequests.single['txId'], 'tx-1');
      client.handleMessage(resultReply('tx-1'));
      async.flushMicrotasks();
      expect(outcome, isA<CalculationSuccess>());
    });
  });

  test('without a connection after the first timeout, waits for a new one', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      client.detach();
      async.elapse(RealtimeConstants.requestTimeout * 4);
      expect(outcome, isNull);
      final next = FakeRealtimeChannel();
      client.attach(next);
      expect(next.sentRequests, hasLength(1));
      async.elapse(RealtimeConstants.requestTimeout);
      expect(next.sentRequests, hasLength(2));
      async.elapse(RealtimeConstants.requestTimeout);
      expect((outcome! as CalculationFailure).kind, FailureKind.noAnswer);
    });
  });

  test('IN_PROGRESS waits 1 s and resends the same txId, at most 3 times', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      for (var i = 1; i <= 3; i++) {
        client.handleMessage(errorReply('IN_PROGRESS'));
        expect(channel.sentRequests, hasLength(i));
        async.elapse(RealtimeConstants.inProgressDelay);
        expect(channel.sentRequests, hasLength(i + 1));
        expect(channel.sentRequests.last['txId'], 'tx-1');
      }
      expect(outcome, isNull);
      client.handleMessage(errorReply('IN_PROGRESS'));
      async.flushMicrotasks();
      expect((outcome! as CalculationFailure).message,
          RealtimeConstants.noAnswerMessage);
    });
  });

  test('IN_PROGRESS then the result completes the request', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      client.handleMessage(errorReply('IN_PROGRESS'));
      async.elapse(RealtimeConstants.inProgressDelay);
      client.handleMessage(resultReply('tx-1'));
      async.flushMicrotasks();
      expect(outcome, isA<CalculationSuccess>());
    });
  });

  group('ignored replies', () {
    void expectIgnored(FakeAsync async, String text) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      final before = client.ignoredCount;
      client.handleMessage(text);
      async.flushMicrotasks();
      expect(outcome, isNull);
      expect(client.ignoredCount, before + 1);
      client.handleMessage(resultReply('tx-1'));
      async.flushMicrotasks();
      expect(outcome, isA<CalculationSuccess>());
    }

    test('unknown txId', () {
      fakeAsync((async) => expectIgnored(async, resultReply('other')));
    });

    test('invalid JSON', () {
      fakeAsync((async) => expectIgnored(async, 'not json {'));
    });

    test('not an object', () {
      fakeAsync((async) => expectIgnored(async, '[1,2]'));
    });

    test('more than 64 KiB', () {
      fakeAsync((async) => expectIgnored(
          async, resultReply('tx-1', result: 'x' * (64 * 1024 + 1))));
    });

    test('a result when nothing is pending', () {
      client.handleMessage(resultReply('tx-1'));
      expect(client.ignoredCount, 1);
    });

    test('UNKNOWN_ACTION (the ping answer) is dropped without counting', () {
      client.handleMessage(errorReply('UNKNOWN_ACTION'));
      expect(client.ignoredCount, 0);
    });
  });

  group('input checks', () {
    test('text that is not a plain number is refused without sending', () {
      fakeAsync((async) {
        for (final bad in ['', 'abc', '0x1A', 'NaN', 'Infinity', '1,5']) {
          CalculationOutcome? outcome;
          client
              .calculate(operation: 'add', a: bad, b: '1')
              .then((o) => outcome = o);
          async.flushMicrotasks();
          expect((outcome! as CalculationFailure).message,
              RealtimeConstants.invalidNumbersMessage,
              reason: bad);
        }
        expect(channel.sent, isEmpty);
      });
    });

    test('more than 38 digits in an operand is too long', () {
      fakeAsync((async) {
        CalculationOutcome? outcome;
        client
            .calculate(operation: 'add', a: '1' * 39, b: '1')
            .then((o) => outcome = o);
        async.flushMicrotasks();
        expect((outcome! as CalculationFailure).message,
            RealtimeConstants.tooLongMessage);
        expect(channel.sent, isEmpty);
      });
    });

    test('38 digits are sent', () {
      fakeAsync((async) {
        client.calculate(operation: 'add', a: '1' * 38, b: '1');
        async.flushMicrotasks();
        expect(channel.sent, hasLength(1));
      });
    });

    test('a message over 1024 bytes is not sent', () {
      fakeAsync((async) {
        CalculationOutcome? outcome;
        client
            .calculate(
                operation: 'add', a: '1.${'0' * 600}', b: '1.${'0' * 600}')
            .then((o) => outcome = o);
        async.flushMicrotasks();
        expect((outcome! as CalculationFailure).message,
            RealtimeConstants.tooLongMessage);
        expect(channel.sent, isEmpty);
      });
    });

    test('an unknown operation is refused', () {
      fakeAsync((async) {
        CalculationOutcome? outcome;
        client
            .calculate(operation: 'pow', a: '1', b: '1')
            .then((o) => outcome = o);
        async.flushMicrotasks();
        expect(outcome, isA<CalculationFailure>());
        expect(channel.sent, isEmpty);
      });
    });
  });

  test('a second calculation while one is pending is refused', () {
    fakeAsync((async) {
      client.calculate(operation: 'mul', a: '6', b: '7');
      CalculationOutcome? second;
      client
          .calculate(operation: 'mul', a: '1', b: '1')
          .then((o) => second = o);
      async.flushMicrotasks();
      expect((second! as CalculationFailure).message,
          RealtimeConstants.busyMessage);
      expect(channel.sentRequests, hasLength(1));
    });
  });

  test('calculating without a connection sends nothing', () {
    fakeAsync((async) {
      client.detach();
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      expect((outcome! as CalculationFailure).kind, FailureKind.notConnected);
    });
  });

  test('editing the inputs discards the pending result', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      client.discardPending();
      async.flushMicrotasks();
      expect(outcome, isA<CalculationCancelled>());
      expect(client.isBusy, isFalse);
      client.handleMessage(resultReply('tx-1'));
      expect(client.ignoredCount, 1);
    });
  });

  test('failPending completes the request with the given failure', () {
    fakeAsync((async) {
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      client.failPending(const CalculationFailure(
        'Your session has expired. Please log in again.',
        FailureKind.sessionExpired,
      ));
      async.flushMicrotasks();
      expect((outcome! as CalculationFailure).kind, FailureKind.sessionExpired);
    });
  });

  test('a send that throws is treated as a lost connection', () {
    fakeAsync((async) {
      channel.close();
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.flushMicrotasks();
      expect(outcome, isNull);
      final second = FakeRealtimeChannel();
      client.attach(second);
      expect(second.sentRequests.single['txId'], 'tx-1');
    });
  });

  test('a failed send does not use up the retry while waiting', () {
    fakeAsync((async) {
      channel.close();
      CalculationOutcome? outcome;
      client
          .calculate(operation: 'mul', a: '6', b: '7')
          .then((o) => outcome = o);
      async.elapse(const Duration(seconds: 20));
      expect(outcome, isNull);
      final second = FakeRealtimeChannel();
      client.attach(second);
      expect(second.sentRequests.map((r) => r['txId']), ['tx-1']);
      async.elapse(
          RealtimeConstants.requestTimeout - const Duration(seconds: 1));
      expect(second.sentRequests, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(second.sentRequests.map((r) => r['txId']), ['tx-1', 'tx-1']);
      expect(outcome, isNull);
      async.elapse(RealtimeConstants.requestTimeout);
      expect((outcome! as CalculationFailure).kind, FailureKind.noAnswer);
    });
  });

  test('no outcome text contains the token', () {
    fakeAsync((async) {
      final outcomes = [
        runWith(async, (id) => resultReply(id)),
        runWith(async, (_) => errorReply('INTERNAL_ERROR', message: _secret)),
        runWith(async, (_) => errorReply('UNAUTHORIZED', message: _secret)),
        runWith(
            async, (id) => resultReply(id, status: 'ERROR', errorCode: 'X')),
      ];
      for (final o in outcomes) {
        expect(o.toString(), isNot(contains(_secret)));
        if (o is CalculationFailure) {
          expect(o.message, isNot(contains(_secret)));
        }
      }
    });
  });
}
