import 'package:calculator_app/realtime/realtime_address.dart';
import 'package:calculator_app/realtime/realtime_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an empty value is not configured and has no connection address', () {
    for (final raw in ['', '   ']) {
      final address = RealtimeAddress.parse(raw);
      expect(address.state, RealtimeAddressState.notConfigured);
      expect(address.isUsable, isFalse);
      expect(address.problemMessage, RealtimeConstants.notConfiguredMessage);
      expect(() => address.connectionUri('t'), throwsStateError);
    }
  });

  test('the build setting is empty when it is not defined', () {
    expect(RealtimeAddress.fromEnvironment().state,
        RealtimeAddressState.notConfigured);
  });

  group('invalid addresses', () {
    for (final raw in [
      'https://example.invalid/dev',
      'http://localhost/dev',
      'ws://example.invalid/dev',
      'wss://',
      'example.invalid/dev',
      'wss://example.invalid/dev?token=abc',
      'wss://example.invalid/dev#frag',
      'wss://user:pass@example.invalid/dev',
    ]) {
      test(raw, () {
        final address = RealtimeAddress.parse(raw);
        expect(address.state, RealtimeAddressState.invalid);
        expect(address.isUsable, isFalse);
        expect(address.problemMessage, RealtimeConstants.invalidAddressMessage);
      });
    }
  });

  test('wss is accepted; ws only for localhost and 127.0.0.1', () {
    expect(RealtimeAddress.parse('wss://example.invalid/dev').isUsable, isTrue);
    expect(RealtimeAddress.parse('ws://localhost:8080/dev').isUsable, isTrue);
    expect(RealtimeAddress.parse('ws://127.0.0.1/dev').isUsable, isTrue);
    expect(RealtimeAddress.parse('wss://example.invalid/dev').problemMessage,
        isNull);
  });

  test('the token is the single percent-encoded query parameter', () {
    final address = RealtimeAddress.parse('wss://example.invalid/dev');
    final uri = address.connectionUri('a.b-c_d&x=y z/+');
    expect(uri.queryParameters.keys, ['token']);
    expect(uri.queryParameters['token'], 'a.b-c_d&x=y z/+');
    expect(uri.query, isNot(contains('&x=')));
    expect(uri.scheme, 'wss');
    expect(uri.path, '/dev');
  });

  test('toString and the problem text never contain the address or token', () {
    final address = RealtimeAddress.parse('wss://example.invalid/dev');
    address.connectionUri('secret-token');
    expect(address.toString(), isNot(contains('example')));
    expect(address.toString(), isNot(contains('secret-token')));
    final invalid = RealtimeAddress.parse('https://example.invalid/dev');
    expect(invalid.problemMessage, isNot(contains('example')));
  });
}
