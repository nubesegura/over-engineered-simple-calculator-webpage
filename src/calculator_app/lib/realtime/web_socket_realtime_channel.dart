import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_channel.dart';
import 'realtime_constants.dart';

/// Opens a [WebSocketChannel]; replaced in tests.
typedef WebSocketConnector = WebSocketChannel Function(Uri uri);

/// Opens connections with the `web_socket_channel` package.
class WebSocketRealtimeChannelFactory implements RealtimeChannelFactory {
  WebSocketRealtimeChannelFactory({
    WebSocketConnector? connector,
    Duration connectTimeout = RealtimeConstants.connectTimeout,
  })  : _connector = connector ?? WebSocketChannel.connect,
        _connectTimeout = connectTimeout;

  final WebSocketConnector _connector;
  final Duration _connectTimeout;

  @override
  Future<RealtimeChannel> connect(Uri uri) async {
    final WebSocketChannel channel;
    try {
      channel = _connector(uri);
    } catch (_) {
      throw const RealtimeChannelException(RealtimeFailure.invalidAddress);
    }
    try {
      await channel.ready.timeout(_connectTimeout);
    } on TimeoutException {
      unawaited(_closeQuietly(channel));
      throw const RealtimeChannelException(RealtimeFailure.timeout);
    } catch (_) {
      unawaited(_closeQuietly(channel));
      throw const RealtimeChannelException(RealtimeFailure.refused);
    }
    return WebSocketRealtimeChannel(channel);
  }

  static Future<void> _closeQuietly(WebSocketChannel channel) async {
    try {
      await channel.sink.close(RealtimeConstants.normalClosure);
    } catch (_) {
      // The connection is already unusable; nothing else to release.
    }
  }
}

/// A [RealtimeChannel] over an open [WebSocketChannel].
class WebSocketRealtimeChannel implements RealtimeChannel {
  WebSocketRealtimeChannel(this._channel);

  final WebSocketChannel _channel;

  /// Text frames only; an error ends the stream like a close does.
  @override
  late final Stream<String> messages = _channel.stream.transform(
    StreamTransformer<dynamic, String>.fromHandlers(
      handleData: (data, sink) {
        if (data is String) sink.add(data);
      },
      handleError: (error, stackTrace, sink) => sink.close(),
    ),
  );

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() async {
    try {
      await _channel.sink
          .close(RealtimeConstants.normalClosure)
          .timeout(RealtimeConstants.closeTimeout);
    } catch (_) {
      // Already closed or not answering: the page is done with it either way.
    }
  }
}
