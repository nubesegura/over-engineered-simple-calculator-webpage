import 'dart:async';

/// Why a connection could not be opened. Carries no address and no token.
enum RealtimeFailure { refused, timeout, closed, invalidAddress }

class RealtimeChannelException implements Exception {
  const RealtimeChannelException(this.failure);

  final RealtimeFailure failure;

  @override
  String toString() => 'RealtimeChannelException(${failure.name})';
}

/// An open text connection to the real-time backend.
abstract interface class RealtimeChannel {
  /// Text messages received. The stream ends when the connection is closed,
  /// whoever closed it.
  Stream<String> get messages;

  /// Sends one text message. Throws when the connection is already closed.
  void send(String text);

  /// Closes the connection with the normal closure code. Never throws.
  Future<void> close();
}

/// Opens connections. Throws [RealtimeChannelException] when it cannot: any
/// failed upgrade (401, 403, 500, any non-101 answer) is `refused`.
abstract interface class RealtimeChannelFactory {
  Future<RealtimeChannel> connect(Uri uri, {Iterable<String>? protocols});
}
