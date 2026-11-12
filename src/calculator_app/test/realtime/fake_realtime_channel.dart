import 'dart:async';
import 'dart:convert';

import 'package:calculator_app/realtime/realtime_channel.dart';

/// A scripted connection: records what is sent, lets the test push replies.
class FakeRealtimeChannel implements RealtimeChannel {
  final StreamController<String> _incoming =
      StreamController<String>(sync: true);

  final List<String> sent = [];
  bool closedByClient = false;

  /// Called after each message is sent; use it to script a reply.
  void Function(Map<String, dynamic> request)? onRequest;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String text) {
    if (_incoming.isClosed) throw StateError('closed');
    sent.add(text);
    onRequest?.call(jsonDecode(text) as Map<String, dynamic>);
  }

  @override
  Future<void> close() async {
    closedByClient = true;
    await _incoming.close();
  }

  /// A message from the server.
  void receive(String text) => _incoming.add(text);

  /// The server (or the network) ends the connection.
  void serverClose() => unawaited(_incoming.close());

  List<Map<String, dynamic>> get sentRequests => [
        for (final text in sent)
          if (text != '{"action":"ping"}')
            jsonDecode(text) as Map<String, dynamic>,
      ];

  int get pingCount => sent.where((t) => t == '{"action":"ping"}').length;
}

String resultReply(
  String txId, {
  String result = '42',
  String status = 'OK',
  String? errorCode,
}) =>
    jsonEncode({
      'type': 'result',
      'calculation': {
        'txId': txId,
        'a': '6',
        'b': '7',
        'op': 'MULTIPLY',
        'result': status == 'OK' ? result : null,
        'status': status,
        'errorCode': errorCode,
      },
    });

String errorReply(String code, {String message = 'server text'}) =>
    jsonEncode({'type': 'error', 'code': code, 'message': message});

/// Hands out scripted outcomes in order: a channel, or a failure to throw.
class FakeChannelFactory implements RealtimeChannelFactory {
  FakeChannelFactory(this._script);

  final List<Object> _script;
  final List<Uri> uris = [];
  final List<List<String>?> connectedProtocols = [];

  List<String>? get lastProtocols =>
      connectedProtocols.isEmpty ? null : connectedProtocols.last;

  void add(Object outcome) => _script.add(outcome);

  @override
  Future<RealtimeChannel> connect(
    Uri uri, {
    Iterable<String>? protocols,
  }) async {
    uris.add(uri);
    connectedProtocols.add(protocols == null ? null : List.of(protocols));
    final next = _script.isEmpty
        ? const RealtimeChannelException(RealtimeFailure.refused)
        : _script.removeAt(0);
    if (next is RealtimeFailure) throw RealtimeChannelException(next);
    return next as FakeRealtimeChannel;
  }
}
