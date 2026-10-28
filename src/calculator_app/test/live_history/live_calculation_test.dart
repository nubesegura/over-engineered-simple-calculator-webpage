import 'package:calculator_app/live_history/live_calculation.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveCalculation', () {
    test('parses live calculation event and strips trailing .0', () {
      final item = LiveCalculation.fromJson({
        'type': 'calculation',
        'txId': 'tx-1',
        'a': 12.0,
        'b': '3.5',
        'op': 'MULTIPLY',
        'result': '42.0',
        'errorCode': null,
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T15:04:05Z',
      });
      expect(item, isNotNull);
      expect(item!.txId, 'tx-1');
      expect(item.a, '12');
      expect(item.b, '3.5');
      expect(item.op, 'MULTIPLY');
      expect(item.symbol, '×');
      expect(item.result, '42');
      expect(item.status, 'OK');
      expect(item.transport, 'websocket');
      expect(item.displayOutcome, '42');
      final local = DateTime.utc(2026, 10, 27, 15, 4, 5).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final expectedLocal =
          '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
      expect(item.formattedTimestamp, expectedLocal);
      expect(item.toString(), 'LiveCalculation(tx-1, OK, websocket)');
    });

    test('normalizes GraphQL source ws and single to websocket and graphql',
        () {
      final wsItem = LiveCalculation.fromJson({
        'txId': 'tx-ws',
        'a': '6.0',
        'b': '7.0',
        'op': 'ADD',
        'result': '13.0',
        'status': 'OK',
        'source': 'ws',
        'createdAt': '2026-10-27T15:00:00Z',
      });
      final singleItem = LiveCalculation.fromJson({
        'txId': 'tx-gql',
        'a': '-0.0',
        'b': '5',
        'op': 'SUBTRACT',
        'result': '-5.0',
        'status': 'OK',
        'source': 'single',
        'createdAt': '2026-10-27T15:01:00Z',
      });
      expect(wsItem?.transport, 'websocket');
      expect(wsItem?.symbol, '+');
      expect(singleItem?.transport, 'graphql');
      expect(singleItem?.a, '0');
      expect(singleItem?.result, '-5');
      expect(singleItem?.symbol, '-');
    });

    test('maps DIVIDE_BY_ZERO and DIVISION_BY_ZERO to Cannot divide by zero.',
        () {
      for (final code in ['DIVIDE_BY_ZERO', 'DIVISION_BY_ZERO']) {
        final item = LiveCalculation.fromJson({
          'txId': 'tx-$code',
          'a': '1',
          'b': '0',
          'op': 'DIVIDE',
          'result': null,
          'errorCode': code,
          'status': 'ERROR',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:02:00Z',
        });
        expect(item, isNotNull);
        expect(item!.symbol, '÷');
        expect(item.result, isNull);
        expect(item.displayOutcome, LiveHistoryConstants.divideByZeroMessage);
      }
    });

    test('maps other valid error codes and hides malformed error codes', () {
      final coded = LiveCalculation.fromJson({
        'txId': 'tx-err',
        'a': '1',
        'b': '2',
        'op': 'ADD',
        'result': null,
        'errorCode': 'OVERFLOW_LIMIT',
        'status': 'ERROR',
        'transport': 'graphql',
        'createdAt': '2026-10-27T15:03:00Z',
      });
      expect(coded?.displayOutcome,
          'The calculation failed (code OVERFLOW_LIMIT).');

      final missingCode = LiveCalculation.fromJson({
        'txId': 'tx-nocode',
        'a': '1',
        'b': '2',
        'op': 'ADD',
        'result': null,
        'errorCode': 'bad code!',
        'status': 'ERROR',
        'transport': 'graphql',
        'createdAt': '2026-10-27T15:03:00Z',
      });
      expect(
        missingCode?.displayOutcome,
        LiveHistoryConstants.unexpectedErrorMessage,
      );
    });

    test('returns null on non-calculation type or missing fields', () {
      expect(
        LiveCalculation.fromJson({
          'type': 'heartbeat',
          'txId': 'tx-1',
          'a': '1',
          'b': '2',
          'op': 'ADD',
          'result': '3',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveCalculation.fromJson({
          'txId': '',
          'a': '1',
          'b': '2',
          'op': 'ADD',
          'result': '3',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveCalculation.fromJson({
          'txId': 'tx-1',
          'a': '1',
          'b': '2',
          'op': 'MODULO',
          'result': '1',
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveCalculation.fromJson({
          'txId': 'tx-1',
          'a': '1',
          'b': '2',
          'op': 'ADD',
          'result': null,
          'status': 'OK',
          'transport': 'websocket',
          'createdAt': '2026-10-27T15:00:00Z',
        }),
        isNull,
      );
      expect(
        LiveCalculation.fromJson({
          'txId': 'tx-1',
          'a': '1',
          'b': '2',
          'op': 'ADD',
          'result': '3',
          'status': 'OK',
          'transport': 'unknown',
          'createdAt': '2026-10-27T15:00:00Z',
        }),
        isNull,
      );
    });

    test('compareNewestFirst sorts descending by timestamp, string, then txId',
        () {
      final older = LiveCalculation.fromJson({
        'txId': 'tx-a',
        'a': '1',
        'b': '1',
        'op': 'ADD',
        'result': '2',
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T10:00:00Z',
      })!;
      final newer = LiveCalculation.fromJson({
        'txId': 'tx-b',
        'a': '2',
        'b': '2',
        'op': 'ADD',
        'result': '4',
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T11:00:00Z',
      })!;
      final newerTie = LiveCalculation.fromJson({
        'txId': 'tx-c',
        'a': '3',
        'b': '3',
        'op': 'ADD',
        'result': '6',
        'status': 'OK',
        'transport': 'websocket',
        'createdAt': '2026-10-27T11:00:00Z',
      })!;
      final list = [older, newer, newerTie]
        ..sort(LiveCalculation.compareNewestFirst);
      expect(list.map((e) => e.txId).toList(), ['tx-c', 'tx-b', 'tx-a']);
      expect(older == older, isTrue);
      expect(older.hashCode, isNot(newer.hashCode));
    });
  });
}
