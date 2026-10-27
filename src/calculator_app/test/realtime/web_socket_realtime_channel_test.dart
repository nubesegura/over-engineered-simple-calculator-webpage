import 'dart:async';

import 'package:calculator_app/realtime/realtime_channel.dart';
import 'package:calculator_app/realtime/web_socket_realtime_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Stand-in for a browser socket: no network.
class _StubChannel implements WebSocketChannel {
  _StubChannel({Future<void>? ready}) : _ready = ready ?? Future<void>.value();

  final Future<void> _ready;
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final _StubSink stubSink = _StubSink();

  @override
  Future<void> get ready => _ready;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => stubSink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSink implements WebSocketSink {
  final List<Object?> added = [];
  int? closeCode;

  @override
  void add(Object? data) => added.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    this.closeCode = closeCode;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a ready socket becomes a channel that sends and receives text',
      () async {
    final stub = _StubChannel();
    final factory = WebSocketRealtimeChannelFactory(connector: (_) => stub);
    final channel =
        await factory.connect(Uri.parse('wss://example.invalid/dev'));

    final received = <String>[];
    final done = Completer<void>();
    channel.messages.listen(received.add, onDone: done.complete);
    stub.incoming
      ..add('hello')
      ..add(<int>[1, 2, 3]);
    channel.send('ping');
    await Future<void>.delayed(Duration.zero);
    expect(received, ['hello']);
    expect(stub.stubSink.added, ['ping']);

    stub.incoming.addError(StateError('boom'));
    await done.future;
  });

  test('close uses the normal closure code', () async {
    final stub = _StubChannel();
    final channel =
        await WebSocketRealtimeChannelFactory(connector: (_) => stub)
            .connect(Uri.parse('wss://example.invalid/dev'));
    await channel.close();
    expect(stub.stubSink.closeCode, 1000);
  });

  test('a failed upgrade is refused and carries no address', () async {
    final stub = _StubChannel(ready: Future<void>.error(StateError('403')));
    final factory = WebSocketRealtimeChannelFactory(connector: (_) => stub);
    await expectLater(
      factory.connect(Uri.parse('wss://example.invalid/dev?token=abc')),
      throwsA(isA<RealtimeChannelException>()
          .having((e) => e.failure, 'failure', RealtimeFailure.refused)
          .having((e) => e.toString(), 'text', isNot(contains('example')))),
    );
    expect(stub.stubSink.closeCode, 1000);
  });

  test('a socket that never opens times out', () async {
    final stub = _StubChannel(ready: Completer<void>().future);
    final factory = WebSocketRealtimeChannelFactory(
      connector: (_) => stub,
      connectTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      factory.connect(Uri.parse('wss://example.invalid/dev')),
      throwsA(isA<RealtimeChannelException>()
          .having((e) => e.failure, 'failure', RealtimeFailure.timeout)),
    );
  });

  test('a connector that throws is an invalid address', () async {
    final factory = WebSocketRealtimeChannelFactory(
      connector: (_) => throw ArgumentError('bad'),
    );
    await expectLater(
      factory.connect(Uri.parse('wss://example.invalid/dev')),
      throwsA(isA<RealtimeChannelException>()
          .having((e) => e.failure, 'failure', RealtimeFailure.invalidAddress)),
    );
  });
}
