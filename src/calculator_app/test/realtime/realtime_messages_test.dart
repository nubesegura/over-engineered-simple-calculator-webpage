import 'dart:convert';

import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:calculator_app/realtime/realtime_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateOperands', () {
    test('accepts plain decimals and exponents', () {
      for (final ok in ['1', '-2.5', '+3', '.5', '5.', '1e10', '1E-3', ' 7 ']) {
        expect(validateOperands(ok, '1'), isNull, reason: ok);
      }
    });

    test('rejects text that is not a plain number', () {
      for (final bad in ['', 'x', '0x10', 'NaN', 'Infinity', '1 2', '--1']) {
        expect(
            validateOperands('1', bad), RealtimeConstants.invalidNumbersMessage,
            reason: bad);
      }
    });

    test('limits the digits of each operand to 38', () {
      expect(validateOperands('1' * 38, '1' * 38), isNull);
      expect(validateOperands('1' * 39, '1'), RealtimeConstants.tooLongMessage);
      expect(validateOperands('1', '1.${'2' * 38}'),
          RealtimeConstants.tooLongMessage);
    });
  });

  test('the request keeps the operands as trimmed strings', () {
    final text = buildCalculateRequest(
      txId: 'id',
      a: ' 0.1 ',
      b: '3',
      operation: 'ADD',
    );
    expect(jsonDecode(text), {
      'action': 'calculate',
      'txId': 'id',
      'a': '0.1',
      'b': '3',
      'op': 'ADD'
    });
  });

  test('operation keys map to backend names in one place', () {
    expect(backendOperation('add'), 'ADD');
    expect(backendOperation('sub'), 'SUBTRACT');
    expect(backendOperation('mul'), 'MULTIPLY');
    expect(backendOperation('div'), 'DIVIDE');
    expect(backendOperation('pow'), isNull);
  });

  group('parseReply', () {
    test('a result reply', () {
      final reply = parseReply(jsonEncode({
        'type': 'result',
        'calculation': {'txId': 't', 'status': 'OK', 'result': 42},
      }));
      expect(reply, isA<ResultReply>());
      expect((reply! as ResultReply).result, '42');
      expect((reply as ResultReply).errorCode, isNull);
    });

    test('an error reply and the unknown action reply', () {
      expect(
          (parseReply('{"type":"error","code":"X"}')! as ErrorReply).code, 'X');
      expect(parseReply('{"type":"error","code":"UNKNOWN_ACTION"}'),
          isA<UnknownActionReply>());
    });

    test('shapes that are not replies are null', () {
      for (final bad in [
        'nope',
        '[]',
        '{}',
        '{"type":"other"}',
        '{"type":"result"}',
        '{"type":"result","calculation":{"txId":1}}',
      ]) {
        expect(parseReply(bad), isNull, reason: bad);
      }
    });

    test('text over 64 KiB is null', () {
      expect(parseReply('{"type":"error","pad":"${'x' * 70000}"}'), isNull);
    });
  });

  group('fixed texts', () {
    test('calculation errors', () {
      expect(
          calculationErrorMessage('DIVIDE_BY_ZERO'), 'Cannot divide by zero.');
      expect(calculationErrorMessage('BAD_THING'),
          'The calculation failed (code BAD_THING).');
      expect(calculationErrorMessage(null),
          RealtimeConstants.unexpectedResponseMessage);
      expect(calculationErrorMessage('<script>alert(1)</script>'),
          RealtimeConstants.unexpectedResponseMessage);
    });

    test('error replies', () {
      expect(errorReplyMessage('INVALID_REQUEST'),
          RealtimeConstants.invalidRequestMessage);
      expect(errorReplyMessage('UNAUTHORIZED'),
          RealtimeConstants.notAuthorizedMessage);
      expect(errorReplyMessage('weird'),
          RealtimeConstants.unexpectedResponseMessage);
    });
  });
}
