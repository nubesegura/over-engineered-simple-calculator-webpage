import 'dart:math';

import 'package:calculator_app/realtime/tx_id.dart';
import 'package:flutter_test/flutter_test.dart';

final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  test('every id is a lowercase UUID v4', () {
    for (var i = 0; i < 500; i++) {
      expect(generateTxId(), matches(_uuidV4));
    }
  });

  test('two ids differ', () {
    expect(generateTxId(), isNot(generateTxId()));
  });

  test('a fixed random source gives a fixed id', () {
    expect(generateTxId(Random(7)), generateTxId(Random(7)));
    expect(generateTxId(Random(7)), matches(_uuidV4));
  });

  test('an all-ones source still sets version and variant bits', () {
    expect(
        generateTxId(_Constant(255)), 'ffffffff-ffff-4fff-bfff-ffffffffffff');
    expect(generateTxId(_Constant(0)), '00000000-0000-4000-8000-000000000000');
  });
}

class _Constant implements Random {
  _Constant(this.value);

  final int value;

  @override
  int nextInt(int max) => value;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
